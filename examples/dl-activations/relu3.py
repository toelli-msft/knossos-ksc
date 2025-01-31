import torch
from torch import nn
import os
from collections import OrderedDict
from ksc import utils
import ksc.compile
import ksc.expr as expr
from ksc.type import Type
from ksc.torch_frontend import (
    ksc_string_to_autograd_function,
    cpp_string_to_autograd_function,
)
import ksc.torch_frontend as knossos

# DOC-KS
@knossos.elementwise
def vrelu3(x: float) -> float:
    """
    Like ReLu, but smoother
    Like GeLu, but cheaper
  """
    if x < 0.0:
        return 0.0
    elif x < 1.0:
        return 1 / 3 * x ** 3
    else:
        return x - 2 / 3


# ENDDOC-KS


# run-bench: PyTorch reference implementation
# DOC-PTREF
def vrelu3_pytorch(x: torch.Tensor):
    mask1_inf = x > 1.0
    mask0_1 = (x > 0.0) & ~mask1_inf
    val_0_1 = 1 / 3 * x ** 3
    val_1_inf = x - 2 / 3

    return mask0_1 * val_0_1 + mask1_inf * val_1_inf


# ENDDOC-PTREF


# run-bench: PyTorch "nice" implementation
# TODO: With torch 1.9.0 this leads to
# RuntimeError: Batching rule not implemented for aten::is_nonzero. We could not generate a fallback.
# See https://msrcambridge.visualstudio.com/Knossos/_backlogs/backlog/Knossos%20Team/Goals/?workitem=19587
if False:
    import torch._vmap_internals

    def relu3_pytorch_nice(x: float) -> float:
        if x < 0.0:
            return torch.zeros_like(x)  # [Note: zeros for PyTorch]
        elif x < 1.0:
            return 1 / 3 * x ** 3
        else:
            return x - 2 / 3

    vrelu3_pytorch_nice = torch._vmap_internals.vmap(relu3_pytorch_nice)

    # Note: Zeros for PyTorch
    # For PyTorch, a function which wants to use a zero as an intermediate needs to make
    # sure it's a zero tensor, a plain float zero will not propagate gradients.
    # This is something of a long story, related to tracing.
    # Sort of related discussion https://discuss.pytorch.org/t/custom-loss-function-error-element-0-of-tensors-does-not-require-grad-and-does-not-have-grad-fn/87944/16


embedded_cflags = ksc.compile.default_cflags


embedded_cflags_opts = ksc.compile.CFlags.GCCOnly(
    ["-march=native", "-funroll-loops", "-ffast-math", "-mprefer-vector-width=512",]
)


mtune_cflags = ksc.compile.CFlags.GCCOnly(["-mtune=native"])

cpp_mask_bool_to_float = """
        #include "knossos.h"
        #include "prelude.h"

        namespace ks{
        tensor<1, ks::Float> vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t) {
            auto tdata = t.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            ks::Float third = 1.0 / 3.0;
            ks::Float two_thirds = 2.0 / 3.0;
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float x = tdata[i];
                auto val0to1 = third * x * x * x;
                auto val1up = x - two_thirds;
                auto le1 = x <= 1;

                retdata[i] = bool_to_float$ab($alloc, x > 0)
                    * (bool_to_float$ab($alloc, le1) * val0to1
                       + bool_to_float$ab($alloc, !le1) * val1up);
            }
            return ret;
        }

        tensor<1, ks::Float> sufrev_vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t, tensor<1, ks::Float> dret) {
            auto tdata = t.data();
            auto dretdata = dret.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float x = tdata[i];
                ks::Float dreti = dretdata[i];
                auto val0to1 = x * x;
                auto val1up = 1.0;

                auto le1 = x <= 1;

                retdata[i] = bool_to_float$ab($alloc, x > 0)
                             * (bool_to_float$ab($alloc, le1) * val0to1
                                + bool_to_float$ab($alloc, !le1) * val1up)
                             * dreti;
            }
            return ret;
        }
        }
        """

cpp_mask = """
        #include "knossos.h"

        namespace ks{
        tensor<1, ks::Float> vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t) {
            auto tdata = t.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            ks::Float third = 1.0 / 3.0;
            ks::Float two_thirds = 2.0 / 3.0;
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float x = tdata[i];
                auto val0to1 = third * x * x * x;
                auto val1up = x - two_thirds;
                auto le1 = x <= 1;

                retdata[i] = (x>0)*(le1*val0to1 + (!le1)*val1up);
            }
            return ret;
        }

        tensor<1, ks::Float> sufrev_vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t, tensor<1, ks::Float> dret) {
            auto tdata = t.data();
            auto dretdata = dret.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float x = tdata[i];
                ks::Float dreti = dretdata[i];
                auto val0to1 = x * x;
                auto val1up = 1.0;

                auto le1 = x <= 1;

                retdata[i] = (x>0)*(le1*val0to1 + (!le1)*val1up)*dreti;
            }
            return ret;
        }
        }
        """


cpp_inlined_map = """
        #include "knossos.h"

        namespace ks{
        tensor<1, ks::Float> vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t) {
            auto tdata = t.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float c$1;
                ks::Float x = tdata[i];
                if (x < 0.0) {
                    c$1 = 0.0;
                } else {
                    if (x < 1.0) {
                        c$1 = x * x * x / 3.0;
                    } else {
                        c$1 = x - 2.0 / 3.0;
                    }
                }
                retdata[i] = c$1;
            }
            return ret;
        }

        tensor<1, ks::Float> sufrev_vrelu3(ks::allocator * $alloc, tensor<1, ks::Float> t, tensor<1, ks::Float> dret) {
            auto tdata = t.data();
            auto dretdata = dret.data();
            auto ret = tensor<1, ks::Float>::create($alloc, t.size());
            auto retdata = ret.data();
            for (int i = 0, ne = t.num_elements(); i != ne; ++i) {
                ks::Float c$1;
                ks::Float x = tdata[i];
                ks::Float dreti = dretdata[i];
                if (x < 0.0) {
                    c$1 = 0.0;
                } else {
                    if (x < 1.0) {
                        c$1 = x * x;
                    } else {
                        c$1 = 1.0;
                    }
                }
                retdata[i] = c$1 * dreti;
            }
            return ret;
        }
        }
        """


def vrelu3_embedded_ks_checkpointed_map():
    return ksc_string_to_autograd_function(
        """(def relu3 Float (x : Float)
             (if (lt x 0.0)
                 0.0
             (if (lt x 1.0)
                 (div (mul x (mul x x)) 3.0)
             (sub x (div 2.0 3.0)))))

           (gdef suffwdpass [relu3 Float])
           (gdef sufrevpass [relu3 Float])
           (gdef sufrev [relu3 Float])

           (def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (ti : Float) (relu3 ti)) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                ; TODO: 1.0 should be dret[i] - luckily we are called with dret==1.0
                (map (lam (ti : Float) ([sufrev [relu3 Float]] ti 1.0)) t))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_ks_checkpointed_map",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_ks_checkpointed_map_flags():
    return ksc_string_to_autograd_function(
        """(def relu3 Float (x : Float)
             (if (lt x 0.0)
                 0.0
             (if (lt x 1.0)
                 (div (mul x (mul x x)) 3.0)
             (sub x (div 2.0 3.0)))))

           (gdef suffwdpass [relu3 Float])
           (gdef sufrevpass [relu3 Float])
           (gdef sufrev [relu3 Float])

           (def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (ti : Float) (relu3 ti)) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                ; TODO: 1.0 should be dret[i] - luckily we are called with dret==1.0
                (map (lam (ti : Float) ([sufrev [relu3 Float]] ti 1.0)) t))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_ks_checkpointed_map_flags",
        generate_lm=False,
        extra_cflags=embedded_cflags + embedded_cflags_opts,
    )


embedded_cpp_entry_points = """
#include "knossos-entry-points-torch.h"

torch::Tensor entry(torch::Tensor t) {
    using namespace ks::entry_points;
    auto ks_t = convert_argument<ks::tensor<1, ks::Float>>(t);
    auto ks_ret = ks::vrelu3(&g_alloc, ks_t);
    return convert_return_value<torch::Tensor>(ks_ret);
}

torch::Tensor entry_vjp(torch::Tensor t, torch::Tensor dret) {
    using namespace ks::entry_points;
    auto ks_t = convert_argument<ks::tensor<1, ks::Float>>(t);
    auto ks_dret = convert_argument<ks::tensor<1, ks::Float>>(dret);
    auto ks_ret = ks::sufrev_vrelu3(&g_alloc, ks_t, ks_dret);
    return convert_return_value<torch::Tensor>(ks_ret);
}
"""


def vrelu3_embedded_cpp_inlined_map():
    return cpp_string_to_autograd_function(
        cpp_inlined_map + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_inlined_map",
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_cpp_inlined_map_flags():
    return cpp_string_to_autograd_function(
        cpp_inlined_map + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_inlined_map_flags",
        extra_cflags=embedded_cflags + embedded_cflags_opts,
    )


def vrelu3_embedded_cpp_mask():
    return cpp_string_to_autograd_function(
        cpp_mask + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask",
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_cpp_mask_bool_to_float():
    return cpp_string_to_autograd_function(
        cpp_mask_bool_to_float + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask_bool_to_float",
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_cpp_mask_flags():
    return cpp_string_to_autograd_function(
        cpp_mask + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask_flags",
        extra_cflags=embedded_cflags + embedded_cflags_opts,
    )


def vrelu3_embedded_cpp_mask_flags_tune():
    return cpp_string_to_autograd_function(
        cpp_mask + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask_flags_tune",
        extra_cflags=embedded_cflags + embedded_cflags_opts + mtune_cflags,
    )


def vrelu3_embedded_cpp_mask_bool_to_float_flags():
    return cpp_string_to_autograd_function(
        cpp_mask_bool_to_float + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask_bool_to_float_flags",
        extra_cflags=embedded_cflags + embedded_cflags_opts,
    )


def vrelu3_embedded_cpp_mask_bool_to_float_flags_tune():
    return cpp_string_to_autograd_function(
        cpp_mask_bool_to_float + embedded_cpp_entry_points,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_mask_bool_to_float_flags_tune",
        extra_cflags=embedded_cflags + embedded_cflags_opts + mtune_cflags,
    )


cpp_aten = """
torch::Tensor entry(torch::Tensor x) {
  torch::Tensor mask1_inf = x > 1.0;
  torch::Tensor mask0_1 = (x > 0.0) & ~mask1_inf;
  torch::Tensor val_0_1 = 1.0 / 3.0 * x * x * x;
  torch::Tensor val_1_inf = x - 2.0 / 3.0;

  return mask0_1 * val_0_1 + mask1_inf * val_1_inf;
}

torch::Tensor entry_vjp(torch::Tensor grad, torch::Tensor x) {
  torch::Tensor mask1_inf = x > 1.0;
  torch::Tensor mask0_1 = (x > 0.0) & ~mask1_inf;
  torch::Tensor val_0_1 = x * x;

  return (mask0_1 * val_0_1 + mask1_inf) * grad;
}
"""


def vrelu3_embedded_cpp_aten():
    return cpp_string_to_autograd_function(
        cpp_aten,
        "ksc_dl_activations__manual__vrelu3_embedded_cpp_aten",
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_ks_checkpointed_map_handwritten_relu3():
    return ksc_string_to_autograd_function(
        """(def relu3 Float (x : Float)
             (if (lt x 0.0)
                 0.0
             (if (lt x 1.0)
                 (div (mul x (mul x x)) 3.0)
             (sub x (div 2.0 3.0)))))

           (def [sufrev [relu3 Float]] Float ((x : Float) (ddr : Float))
               (if (lt x 0.0)
                   0.0
               (if (lt x 1.0)
                   (mul x (mul x ddr))
               ddr)))

           (def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (ti : Float) (relu3 ti)) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                ; TODO: 1.0 should be dret[i] - luckily we are called with dret==1.0
                (map (lam (ti : Float) ([sufrev [relu3 Float]] ti 1.0)) t))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_ks_checkpointed_map_handwritten_relu3",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_ks_checkpointed_map_handwritten_inlined_relu3():
    return ksc_string_to_autograd_function(
        """(def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (x : Float)
             (if (lt x 0.0)
                 0.0
             (if (lt x 1.0)
                 (div (mul x (mul x x)) 3.0)
             (sub x (div 2.0 3.0))))) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                (map2 (lam (x_ddri : Tuple Float Float)
               (let ((x ddri) x_ddri)
               (if (lt x 0.0)
                   0.0
               (if (lt x 1.0)
                   (mul x x)
               ddri)))) t dret))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_ks_checkpointed_map_handwritten_inlined_relu3",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_ks_checkpointed_map_mask():
    return ksc_string_to_autograd_function(
        """(def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (x : Float)
                   (let (val0to1 (mul x (mul x (div x 3.0))))
                   (let (val1up (sub x (div 2.0 3.0)))
                   (let (le1 (lte x 1.0))
                      (mul (bool_to_float (gt x 0.0))
                           (add (mul (bool_to_float le1) val0to1)
                                (mul (bool_to_float (not le1)) val1up))))))) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                (map2 (lam (x_ddri : Tuple Float Float)
                   (let ((x ddri) x_ddri)
                   (let (val0to1 (mul x x))
                   (let (val1up 1.0)
                   (let (le1 (lte x 1.0))
                      (mul (mul (bool_to_float (gt x 0.0))
                                (add (mul (bool_to_float le1) val0to1)
                                     (mul (bool_to_float (not le1)) val1up)))
                           ddri)))))) t dret))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_ks_checkpointed_map_mask",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_INCORRECT_ks_upper_bound_via_map():
    return ksc_string_to_autograd_function(
        """(def relu3 Float (x : Float) 0.0)

           (def [sufrev [relu3 Float]] Float ((x : Float) (ddr : Float)) ddr)

           (def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float)
                (map (lam (ti : Float) (relu3 ti)) t))

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                ; TODO: 1.0 should be dret[i] - luckily we are called with dret==1.0
                (map (lam (ti : Float) ([sufrev [relu3 Float]] ti 1.0)) t))
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_INCORRECT_ks_upper_bound_via_map",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_embedded_INCORRECT_ks_upper_bound():
    return ksc_string_to_autograd_function(
        """; These are not correct but they are as fast as a Knossos
           ; implementation could possibly be.
           (def [vrelu3 (Vec Float)] (Vec Float)
                (t : Vec Float) t)

           (def [sufrev [vrelu3 (Vec Float)]] (Vec Float)
                ((t : Vec Float) (dret : Vec Float))
                dret)
        """,
        expr.StructuredName(("vrelu3", Type.Tensor(1, Type.Float))),
        "ksc_dl_activations__manual__vrelu3_embedded_INCORRECT_ks_upper_bound",
        generate_lm=False,
        extra_cflags=embedded_cflags,
    )


def vrelu3_cuda_init():
    __ksc_path, ksc_runtime_dir = utils.get_ksc_paths()
    this_dir = os.path.dirname(__file__)

    # TODO: make this use compile.py?
    # There's no real need, as there's nothing machine-generated
    # or generated from a string
    build_directory = utils.get_ksc_build_dir() + "/torch_extensions/vrelu3_cuda"
    os.makedirs(build_directory, exist_ok=True)
    vrelu3_cuda = torch.utils.cpp_extension.load(
        "vrelu3_module",
        sources=[
            os.path.join(this_dir, "vrelu3_cuda.cpp"),
            os.path.join(this_dir, "vrelu3_cuda_kernel.cu"),
        ],
        build_directory=build_directory,
        extra_include_paths=[ksc_runtime_dir],
        verbose=True,
    )

    class VReLu3Function(torch.autograd.Function):
        @staticmethod
        def forward(ctx, input):
            output = vrelu3_cuda.forward(input)
            ctx.save_for_backward(input)
            return output

        @staticmethod
        def backward(ctx, grad):
            return vrelu3_cuda.backward(grad.contiguous(), *ctx.saved_tensors)

    class VReLu3(torch.nn.Module):
        def __init__(self):
            super(VReLu3, self).__init__()

        def forward(self, input):
            return VReLu3Function.apply(input)

    return VReLu3()


# run-bench: Define a range of values at which to call the methods
def vrelu3_bench_configs():
    yield torch.randn((16,))
    yield torch.randn((255 * 255,))
    yield torch.randn((1024 * 1024,))


# yield torch.randn((256,256)) too slow to bench...


def plot_relu3(filename):
    import matplotlib.pyplot as plt
    import numpy as np

    t = torch.arange(-3, 3, step=0.1)

    plt.plot(t, vrelu3(t), "b")
    plt.plot(t, vrelu3_pytorch(t), "r--")
    plt.gca().set_aspect(1)
    print(f"Saving figure to {filename}")
    plt.savefig(filename)


def relu3_in_fcdnn():
    # Initialize the model using nn.Sequential
    model = nn.Sequential(
        OrderedDict(
            [
                ("fc1", nn.Linear(784, 256)),
                ("activation1", vrelu3),
                ("fc2", nn.Linear(256, 128)),
                ("bn2", nn.BatchNorm1d(num_features=128)),
                ("activation2", vrelu3),
                ("dropout", nn.Dropout(0.3)),
                ("fc3", nn.Linear(128, 64)),
                ("bn3", nn.BatchNorm1d(num_features=64)),
                ("activation3", vrelu3),
                ("logits", nn.Linear(64, 10)),
                ("logsoftmax", nn.LogSoftmax(dim=1)),
            ]
        )
    )

    # Run training
    # train_model(model)


if __name__ == "__main__":
    xs = next(vrelu3_bench_configs())
    ys = vrelu3(xs)
    print(ys.sum())
