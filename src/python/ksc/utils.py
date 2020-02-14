from collections import namedtuple
import importlib.util
import os
import numpy as np
import subprocess
import sys
from tempfile import NamedTemporaryFile

from ksc.type import Type

ShapeType = namedtuple("ShapeType", ["shape", "type"])


def import_module_from_path(module_name, path):
    # These three lines are for loading a module from a file in Python 3.5+
    # https://bugs.python.org/issue21436
    spec = importlib.util.spec_from_file_location(module_name, path)
    py_out = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(py_out)
    return py_out

def translate_and_import(*args):
    from ksc.translate import translate
    py_out = translate(*args, with_main=False)
    with NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write(py_out)
    print(f.name)
    module_name = os.path.basename(f.name).split(".")[0]
    return import_module_from_path(module_name, f.name)

def subprocess_run(cmd, env=None):
    return subprocess.run(cmd, stdout=subprocess.PIPE, env=env).stdout.decode().strip("\n")

def generate_cpp_from_ks(ks_str):
    if "KSC_PATH" in os.environ:
        ksc_path = os.environ["KSC_PATH"]
    else:
        ksc_path = "./ksc"
    with NamedTemporaryFile(mode="w", suffix=".ks", delete=False) as fks:
        fks.write(ks_str)
    with NamedTemporaryFile(mode="w", suffix=".kso", delete=False) as fkso:
        pass
    with NamedTemporaryFile(mode="w", suffix=".cpp", delete=False) as fcpp:
        pass
    try:
        subprocess.check_call([
            ksc_path,
            "--generate-cpp-without-diffs",
            "--ks-source-file", fks.name,
            "--ks-output-file", fkso.name,
            "--cpp-output-file", fcpp.name
        ])
    except subprocess.CalledProcessError:
        print(f"ks_str={ks_str}")
        raise
    finally:
        os.unlink(fks.name)
    with open(fcpp.name) as f:
        out = f.read()
    # only delete these file if no error
    os.unlink(fcpp.name)
    os.unlink(fkso.name)
    return out

def build_py_module_from_cpp(cpp_str, pybind11_path):
    if "KSC_RUNTIME_DIR" in os.environ:
        ksc_runtime_dir = os.environ["KSC_RUNTIME_DIR"]
    else:
        ksc_runtime_dir = "./src/runtime"

    with NamedTemporaryFile(mode="w", suffix=".cpp", delete=False) as fcpp:
        fcpp.write(cpp_str)

    extension_suffix = subprocess_run(['python3-config', '--extension-suffix'])

    with NamedTemporaryFile(mode="w", suffix=extension_suffix, delete=False) as fpymod:
        pass
    module_path = fpymod.name
    module_name = os.path.basename(module_path).split(".")[0]
    python_includes = subprocess_run(
        [sys.executable, "-m", "pybind11", "--includes"],
        env={"PYTHONPATH": "pybind11"}
    )
    try:
        cmd = (f"g++-7 -I{ksc_runtime_dir} -I{pybind11_path}/include "
               + python_includes
               + " -Wall"
                 " -std=c++17"
                 " -O3"
                 " -fPIC"
                 " -shared"
                 f" -DPYTHON_MODULE_NAME={module_name}"
                 f" -o {module_path} "
               + fcpp.name)
        print(cmd)
        subprocess.check_call(cmd, shell=True)
    except subprocess.CalledProcessError:
        print(f"cpp_str={cpp_str}")
        raise
    finally:
        os.unlink(fcpp.name)
    return module_name, module_path

def generate_and_compile_cpp_from_ks(ks_str, name_to_call, pybind11_path="pybind11"):

    cpp_str = """
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <pybind11/operators.h>

namespace py = pybind11;

{generated_cpp_source}

int ks::main() {{ return 0; }};

/* template<typename T>
void declare_vec(py::module &m, std::string typestr) {{
  using Class = ks::vec<T>;
  std::string pyclass_name = std::string("vec_") + typestr;
  py::class_<Class>(m, pyclass_name.c_str(), py::module_local())
    .def(py::init<>())
    .def(py::init<std::vector<T> const&>())
    .def("is_zero",     &Class::is_zero)
    .def("__getitem__", [](const ks::vec<T> &a, const int &b) {{
	return a[b];
      }})
    .def("__len__", [](const ks::vec<T> &a) {{ return a.size(); }});
}} */

PYBIND11_MODULE(PYTHON_MODULE_NAME, m) {{
  m.def("main", &ks::{name_to_call});
}}
""".format(
        generated_cpp_source=generate_cpp_from_ks(ks_str),
        name_to_call=name_to_call.replace("@", "$a")
    )
    module_name, module_path = build_py_module_from_cpp(cpp_str, pybind11_path)
    return import_module_from_path(module_name, module_path)

def shape_type_from_object(o):
    if hasattr(o, "shape") and hasattr(o, "dtype"):
        # numpy array-like object
        if np.issubdtype(o.dtype, np.floating):
            el_type = Type.Float
        elif np.issubdtype(o.dtype, np.integer):
            el_type = Type.Integer
        elif np.issubdtype(o.dtype, np.bool_):
            el_type = Type.Bool
        else:
            raise ValueError(f"Cannot handle element type {o.dtype}")
        vec_type = el_type
        for _ in range(o.ndim):
            vec_type = Type.Vec(vec_type)
        return ShapeType(o.shape, vec_type)
    elif hasattr(o, "data") and o.data is not None:
        # value node
        return shape_type_from_object(o.data)
    elif isinstance(o, list):
        s0, t0 = shape_type_from_object(o[0])
        assert all(shape_type_from_object(e) == (s0, t0) for e in o)
        return ShapeType((len(o),) + s0, Type.Vec(t0))
    elif isinstance(o, tuple):
        ss, ts = zip(*[shape_type_from_object(e) for e in o])
        return ShapeType(tuple(ss), Type.Tuple(*ts))
    elif isinstance(o, bool):
        return ShapeType((), Type.Bool)
    elif isinstance(o, int):
        return ShapeType((), Type.Integer)
    elif isinstance(o, float):
        return ShapeType((), Type.Float)
    else:
        raise ValueError(f"Cannot handle object {o}")
