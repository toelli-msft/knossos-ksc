import atexit
import os
import subprocess
import sysconfig
import sys
from tempfile import NamedTemporaryFile
from tempfile import gettempdir

from torch.utils import cpp_extension

from ksc import cgen, utils
from ksc.parse_ks import parse_ks_filename

preserve_temporary_files = False


def subprocess_run(cmd, env=None):
    return (
        subprocess.run(cmd, stdout=subprocess.PIPE, env=env).stdout.decode().strip("\n")
    )


def generate_cpp_from_ks(ks_str, use_aten=False):
    ksc_path, ksc_runtime_dir = utils.get_ksc_paths()

    with NamedTemporaryFile(mode="w", suffix=".ks", delete=False) as fks:
        fks.write(ks_str)
    with NamedTemporaryFile(mode="w", suffix=".kso", delete=False) as fkso:
        pass
    with NamedTemporaryFile(mode="w", suffix=".cpp", delete=False) as fcpp:
        pass

    print("generate_cpp_from_ks:", ksc_path, fks.name)
    ksc_command = [
        ksc_path,
        "--generate-cpp",
        "--ks-source-file",
        ksc_runtime_dir + "/prelude.ks",
        *(
            ("--ks-source-file", ksc_runtime_dir + "/prelude-aten.ks")
            if use_aten
            else ()
        ),
        "--ks-source-file",
        fks.name,
        "--ks-output-file",
        fkso.name,
        "--cpp-output-file",
        fcpp.name,
    ]

    try:
        e = subprocess.run(ksc_command, capture_output=True, check=True,)
        print(e.stdout.decode("ascii"))
        print(e.stderr.decode("ascii"))
        decls = list(parse_ks_filename(fkso.name))
    except subprocess.CalledProcessError as e:
        print(f"Command failed:\n{' '.join(ksc_command)}")
        print(f"files {fks.name} {fkso.name} {fcpp.name}")
        print(f"ks_str=\n{ks_str}")
        print(e.output.decode("ascii"))
        print(e.stderr.decode("ascii"))
        raise

    # Read from CPP back to string
    with open(fcpp.name) as f:
        generated_cpp = f.read()

    # only delete these file if no error
    if not preserve_temporary_files:

        @atexit.register
        def _():
            print(
                "ksc.compile.generate_cpp_from_ks: Deleting",
                fks.name,
                fcpp.name,
                fkso.name,
            )
            os.unlink(fks.name)
            os.unlink(fcpp.name)
            os.unlink(fkso.name)

    return generated_cpp, decls


def build_py_module_from_cpp(cpp_str, profiling=False, use_aten=False):
    """
    Build python module, independently of pytorch, non-ninja
    """
    _ksc_path, ksc_runtime_dir = utils.get_ksc_paths()
    pybind11_path = utils.get_ksc_dir() + "/extern/pybind11"

    with NamedTemporaryFile(mode="w", suffix=".cpp", delete=False) as fcpp:
        fcpp.write(cpp_str)

    extension_suffix = sysconfig.get_config_var("EXT_SUFFIX")
    if extension_suffix is None:
        extension_suffix = sysconfig.get_config_var("SO")

    with NamedTemporaryFile(mode="w", suffix=extension_suffix, delete=False) as fpymod:
        pass
    module_path = fpymod.name
    module_name = os.path.basename(module_path).split(".")[0]
    python_includes = subprocess_run(
        [sys.executable, "-m", "pybind11", "--includes"],
        env={"PYTHONPATH": pybind11_path},
    )
    try:
        cmd = (
            f"g++ -I{ksc_runtime_dir} -I{pybind11_path}/include "
            + python_includes
            + " -Wall -Wno-unused-variable -Wno-unused-but-set-variable"
            " -fmax-errors=1"
            " -std=c++17"
            " -O3"
            " -fPIC"
            + (" -g -pg -O3" if profiling else "")
            + " -shared"
            + (" -DKS_INCLUDE_ATEN" if use_aten else "")
            + f" -DPYTHON_MODULE_NAME={module_name}"
            f" -o {module_path} " + fcpp.name
        )
        print(cmd)
        subprocess.run(cmd, shell=True, capture_output=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"cpp_file={fcpp.name}")
        print(cmd)
        print(e.output.decode("utf-8"))
        print(e.stderr.decode("utf-8"))

        raise

    if not preserve_temporary_files:

        @atexit.register
        def _():
            print(
                "ksc.utils.build_py_module_from_cpp: Deleting", fcpp.name, fpymod.name,
            )
            os.unlink(fcpp.name)
            os.unlink(fpymod.name)

    return module_name, module_path


derivatives_to_generate_default = ["fwd", "rev"]


def generate_cpp_for_py_module_from_ks(
    ks_str, bindings_to_generate, python_module_name, use_aten=True, use_torch=False
):
    def mangled_with_type(structured_name):
        if not structured_name.has_type():
            raise ValueError(
                "Need a type on the structured name: " + str(structured_name)
            )
        return structured_name.mangled()

    bindings = [
        (python_name, "ks::entry_points::generated::" + python_name)
        for (python_name, _) in bindings_to_generate
    ]

    cpp_ks_functions, decls = generate_cpp_from_ks(ks_str, use_aten=use_aten)
    cpp_entry_points = cgen.generate_cpp_entry_points(
        bindings_to_generate, decls, use_torch=use_torch
    )
    cpp_pybind_module_declaration = generate_cpp_pybind_module_declaration(
        bindings, python_module_name
    )

    return cpp_ks_functions + cpp_entry_points + cpp_pybind_module_declaration


def generate_cpp_pybind_module_declaration(bindings_to_generate, python_module_name):
    def m_def(python_name, cpp_name):
        return f"""
        m.def("{python_name}", &{cpp_name});
        """

    return (
        """

#include "knossos-pybind.h"

PYBIND11_MODULE("""
        + python_module_name
        + """, m) {
    m.def("reset_allocator", &ks::entry_points::reset_allocator);
    m.def("allocator_top", &ks::entry_points::allocator_top);
    m.def("allocator_peak", &ks::entry_points::allocator_peak);
    m.def("logging", &ks::entry_points::logging);
"""
        + "\n".join(m_def(*t) for t in bindings_to_generate)
        + """
}

#include "knossos-entry-points.cpp"
"""
    )


def build_py_module_from_ks(
    ks_str, bindings_to_generate, use_aten=False, use_torch=False
):

    cpp_str = generate_cpp_for_py_module_from_ks(
        ks_str,
        bindings_to_generate,
        "PYTHON_MODULE_NAME",
        use_aten=use_aten,
        use_torch=use_torch,
    )

    cpp_fname = (
        gettempdir() + "/ksc-pybind.cpp"
    )  # TODO temp name, but I want to solve a GC problem with temp names
    print(f"Saving to {cpp_fname}")
    with open(cpp_fname, "w") as fcpp:
        fcpp.write(cpp_str)

    module_name, module_path = build_py_module_from_cpp(cpp_str, use_aten=use_aten)
    return utils.import_module_from_path(module_name, module_path)


def build_module_using_pytorch_from_ks(
    ks_str, bindings_to_generate, torch_extension_name, use_aten=False
):
    """Uses PyTorch C++ extension mechanism to build and load a module

    * ks_str: str

      The text of a ks source file

    * bindings_to_generate : Iterable[Tuple[str, StructuredName]]

      The StructuredName is the ksc function to expose to Python.  The
      str is the Python name given to that function when exposed.
      Each StructuredName must have a type attached
    """
    cpp_str = generate_cpp_for_py_module_from_ks(
        ks_str,
        bindings_to_generate,
        torch_extension_name,
        use_aten=use_aten,
        use_torch=True,
    )

    return build_module_using_pytorch_from_cpp_backend(
        cpp_str, torch_extension_name, use_aten
    )


def build_module_using_pytorch_from_cpp(
    cpp_str, bindings_to_generate, torch_extension_name, use_aten
):
    cpp_pybind = generate_cpp_pybind_module_declaration(
        bindings_to_generate, torch_extension_name
    )
    return build_module_using_pytorch_from_cpp_backend(
        cpp_str + cpp_pybind, torch_extension_name, use_aten
    )


def build_module_using_pytorch_from_cpp_backend(
    cpp_str, torch_extension_name, use_aten
):
    __ksc_path, ksc_runtime_dir = utils.get_ksc_paths()

    extra_cflags = ["-DKS_INCLUDE_ATEN"] if use_aten else []

    # I don't like this assumption about Windows -> cl but it matches what PyTorch is currently doing:
    # https://github.com/pytorch/pytorch/blob/ad8d1b2aaaf2ba28c51b1cb38f86311749eff755/torch/utils/cpp_extension.py#L1374-L1378
    # We're making a guess here if people recognifigure their C++ compiler on Windows it's because they're using non-MSVC
    # otherwise we need to inspect the end of the path path for cl[.exe].

    cpp_compiler = os.environ.get("CXX")
    if cpp_compiler == None and sys.platform == "win32":
        extra_cflags += ["/std:c++17", "/O2"]
    else:
        extra_cflags += [
            "-std=c++17",
            "-g",
            "-O3",
            # "-DKS_BOUNDS_CHECK",
        ]

    verbose = True

    # https://pytorch.org/docs/stable/cpp_extension.html
    build_directory = (
        utils.get_ksc_build_dir() + "/torch_extensions/" + torch_extension_name
    )
    os.makedirs(build_directory, exist_ok=True)

    cpp_str = "#include <torch/extension.h>\n" + cpp_str

    cpp_source_path = os.path.join(build_directory, "ksc-main.cpp")

    utils.write_file_if_different(cpp_str, cpp_source_path, verbose)

    module = cpp_extension.load(
        name=torch_extension_name,
        sources=[cpp_source_path],
        extra_include_paths=[ksc_runtime_dir],
        extra_cflags=extra_cflags,
        build_directory=build_directory,
        verbose=verbose,
    )

    return module
