import numpy as np
from typing import Optional


class KSTypeError(RuntimeError):
    pass


class Type:
    """
    Knossos AST node type.  Grouped into
        Scalars: Float, Integer, Bool, String
        Tensor N 'T
        Tuple 'T1 .. 'Tn
        Lam S T
        LM  S T
    """

    String: "Type"
    Float: "Type"
    Integer: "Type"
    Bool: "Type"
    Any: "Type"

    node_kinds = {
        "Tensor": 2,  # two children (Rank, Type)
        "Tuple": -1,  # special case two or more
        "Integer": 0,
        "Float": 0,
        "Bool": 0,
        "String": 0,
        "Any": 0,  # Parser parses for Rules only
        "Lam": 2,  # TODO: Lambda args are in reverse order, prefer src -> dst
        "LM": 2,  # Linear map, used in AD
    }

    def __init__(self, kind, children=[]):
        if kind not in Type.node_kinds:
            raise ValueError("bad kind:", kind)

        if kind != "Tuple":
            if Type.node_kinds[kind] != len(children):
                raise KSTypeError(
                    f"Type {kind} has {len(children)} parameters, but needs {Type.node_kinds[kind]}"
                )  # dont' check for 1-tuple
        if kind == "Tensor":
            assert isinstance(children[0], int) and isinstance(children[1], Type)
        else:
            assert all(isinstance(ch, Type) for ch in children)

        self.kind = kind
        self.children = children  # TODO: change to _children and use tuple_elem or tensor_* or lambda_* to access

    ################
    ## Constructors

    @staticmethod
    def Tensor(rank, elem_type):
        """
        Constructor: Type.Tensor(rank, T)
        """
        return Type("Tensor", [rank, elem_type])

    @staticmethod
    def Tuple(*args):
        """
        Constructor: Type.Tuple(T1, ..., Tn)
        """
        args = tuple(args)
        assert all(
            (isinstance(ch, Type) for ch in args)
        ), "Type.Tuple constructed with non-type arg"
        return Type("Tuple", args)

    @staticmethod
    def Lam(arg_type, return_type):
        """
        Constructor: Type.Lam(S, T)
        """
        return Type("Lam", [arg_type, return_type])

    @staticmethod
    def LM(arg_type, return_type):
        """
        Constructor: Type.LM(S, T)
        """
        return Type("LM", [arg_type, return_type])

    ################
    ## Predicates

    @property
    def is_scalar(self):
        return self.kind in ["Integer", "Float", "Bool", "String"]

    @property
    def is_lam_or_LM(self):
        return self.kind == "Lam" or self.kind == "LM"

    @property
    def is_tensor(self):
        return self.kind == "Tensor"

    @property
    def is_tuple(self):
        return self.kind == "Tuple"

    def can_accept_value_of_type(self, other):
        """ Finds if a variable of type 'other' can fit into this type.  """
        # Allow any argument to fit into an Any parameter (to a Rule)
        if self == Type.Any:
            return True
        if self.kind != other.kind:
            return False
        if len(self.children) != len(other.children):
            # Rules out different size tuples
            return False
        return all(
            (c.can_accept_value_of_type(o) if isinstance(c, Type) else c == o)
            for c, o in zip(self.children, other.children)
        )

    def contains_any(self):
        return self == Type.Any or any(
            isinstance(c, Type) and c.contains_any() for c in self.children
        )

    #################
    ## Tensor methods
    def is_tensor_of(self, ty):
        return self.is_tensor and self.tensor_elem_type == ty

    @property
    def tensor_rank(self):
        assert self.is_tensor
        return self.children[0]

    @property
    def tensor_elem_type(self):
        assert self.is_tensor
        return self.children[1]

    @staticmethod
    def Index(tensor):  # TODO: Call this elem_type for consistency with ksc-MLIR?
        """
        Index: Element type of a tensor
        """
        if tensor is None:
            return None
        return tensor.tensor_elem_type

    #################
    ## Tuple methods

    @property
    def tuple_len(self):
        assert self.is_tuple
        return len(self.children)

    def tuple_elems(self):
        assert self.is_tuple
        return (c for c in self.children)

    def tuple_elem(self, i):
        assert self.is_tuple
        return self.children[i]

    #################
    ## Lambda/LM methods

    @property
    def lam_return_type(self):
        assert self.is_lam_or_LM
        return self.children[1]

    @property
    def lam_arg_type(self):
        assert self.is_lam_or_LM
        return self.children[0]

    #################
    ## Accessors

    def num_elements(self, assumed_vector_size=100):
        # TODO: Move to cost.py, assumed_vector_size is not a core concept
        if self.is_tuple:
            return sum([c.num_elements(assumed_vector_size) for c in self.children])
        elif self.is_tensor:
            return (
                assumed_vector_size ** self.tensor_rank
            ) * self.tensor_elem_type.num_elements(assumed_vector_size)
        elif self.is_scalar or self.is_lam_or_LM:
            return 1

    def all_element_types(self):
        # TODO: rename to "element_types_as_set", probably move elsewhere
        if self.is_tuple:
            return set([t for c in self.children for t in c.all_element_types()])
        elif self.is_tensor:
            return self.tensor_elem_type.all_element_types()
        else:
            return set([self])

    def ndim_recursive(self):
        if self.is_tensor:
            child_ndim = self.tensor_elem_type.ndim_recursive()
            return child_ndim + 1 if child_ndim is not None else 1
        elif self.is_scalar:
            return 0
        return None

    def shortstr(self, tb="<", te=">"):
        el_types = {
            "Integer": "i",
            "Bool": "b",
            "String": "s",
            "Float": "f",
            "Lam": "l",
            "LM": "l",
        }
        if self.kind in el_types:
            return el_types[self.kind]
        if self.is_tuple:
            return tb + "".join([c.shortstr() for c in self.children]) + te
        if self.is_tensor:
            return f"T{self.tensor_rank}" + self.tensor_elem_type.shortstr()

        raise ValueError(f"Unknown Type.{self.kind}")

    @staticmethod
    def fromValue(val):
        """
        Construct type from a value
        """
        if isinstance(val, (bool)):
            return Type.Bool
        if isinstance(val, (int, np.integer, np.int32, np.int64)):
            return Type.Integer
        if isinstance(val, (float, np.float32, np.float64)):
            return Type.Float
        if isinstance(val, str):
            return Type.String
        raise NotImplementedError(f"Typeof {type(val)}")

    def shortstr_py_friendly(self):
        return self.shortstr("_t", "t_")

    @staticmethod
    def is_type_introducer(sym: str):
        """
        For parsers: could sym be the introducer of a type?
        True for "Tensor", "Float", etc
        """
        return sym in Type.node_kinds

    def __str__(self):
        if len(self.children) == 0 and (self.kind != "Tuple"):
            return self.kind
        elems = [str(c) for c in self.children]
        if self.is_lam_or_LM:
            elems = ["{}({})".format(*elems)]
        return "({})".format(" ".join([self.kind] + elems))

    def __repr__(self):
        res = "Type.{}".format(self.kind.capitalize())
        if Type.node_kinds[self.kind] != 0:
            res += "({})".format(", ".join([repr(c) for c in self.children]))
        return res

    def __eq__(self, other):
        if id(self) == id(other):
            return True
        if other is None or self.kind != other.kind:
            return False
        # Now self.kind == other.kind
        if self.is_scalar:
            return True
        if self.is_tuple and len(self.children) != len(other.children):
            return False
        return all([c == o for c, o in zip(self.children, other.children)])

    def __hash__(self):
        return hash(str(self))


def make_tuple_if_many(types):
    """
    Make a tuple type unless singleton
    """
    if isinstance(types, (list, tuple)):
        if len(types) == 1:
            return types[0]
        else:
            return Type.Tuple(*types)
    else:
        return types


class SizeType:
    @staticmethod
    def from_rank(n: int) -> Type:
        if n == 1:
            return Type.Integer
        else:
            return Type.Tuple(*tuple(Type.Integer for _ in range(n)))

    @staticmethod
    def get_rank(ty: Type) -> Optional[int]:
        if ty == Type.Integer:
            return 1
        if ty.is_tuple and all(ty == Type.Integer for ty in ty.tuple_elems()):
            return ty.tuple_len
        return None

    @staticmethod
    def isa(ty: Type) -> bool:
        return SizeType.get_rank(ty) is not None


# See AD.hs:tangentType
def tangent_type(ty: Type) -> Type:
    if ty in (Type.String, Type.Integer, Type.Bool):
        return Type.Tuple()
    if ty == Type.Float:
        return ty
    if ty.is_tuple:
        return Type.Tuple(*(tangent_type(ty) for ty in ty.children))
    if ty.is_tensor:
        return Type.Tensor(ty.tensor_rank, tangent_type(ty.tensor_elem_type))

    raise NotImplementedError("tangent_type")


# See Prim.hs:shapeType
def shape_type(t: Type) -> Type:
    if t.is_scalar:
        return Type.Tuple()
    if t.is_tuple:
        if all(shape_type(ti).is_scalar for ti in t.children):
            return Type.Tuple()
        else:
            return Type.Tuple(*(shape_type(ti) for ti in t.children))
    if t.is_tensor:
        if t.tensor_elem_type.is_scalar:
            return SizeType.from_rank(t.tensor_rank)
        else:
            return Type.Tensor(t.tensor_rank, shape_type(t.tensor_elem_type))

    raise NotImplementedError


Type.String = Type("String")
Type.Float = Type("Float")
Type.Integer = Type("Integer")
Type.Bool = Type("Bool")
Type.Any = Type("Any")
