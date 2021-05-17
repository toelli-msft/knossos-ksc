import pytest

from ksc.rewrites import rule, RuleSet
from ksc.rewrites_ast import lift_bind, lift_if
from ksc.parse_ks import parse_expr_string, parse_ks_file, parse_ks_filename
from ksc.type import Type
from ksc.type_propagate import type_propagate_decls
from ksc import utils


def sorted_rewrites(rule, expr):
    return [
        rw.apply_rewrite()
        for rw in sorted(rule.find_all_matches(expr), key=lambda rw: rw.path)
    ]


def test_lift_if():
    e = parse_expr_string("(add (if p 4.0 2.0) 3.0)")
    symtab = dict()
    type_propagate_decls(list(parse_ks_filename("src/runtime/prelude.ks")), symtab)
    expected = parse_expr_string("(if p (add 4.0 3.0) (add 2.0 3.0))")
    type_propagate_decls([e, expected], {**symtab, "p": Type.Bool})
    actual = utils.single_elem(list(lift_if.find_all_matches(e))).apply_rewrite()
    assert actual == expected


def test_lift_if_assert_cond():
    e = parse_expr_string("(assert (if p true false) 3.0)")
    expected = parse_expr_string("(if p (assert true 3.0) (assert false 3.0))")
    symtab = dict()
    type_propagate_decls(list(parse_ks_filename("src/runtime/prelude.ks")), symtab)
    type_propagate_decls([e, expected], {**symtab, "p": Type.Bool})
    actual = utils.single_elem(list(lift_if.find_all_matches(e))).apply_rewrite()
    assert actual == expected


def test_lift_if_assert_body():
    e = parse_expr_string("(assert q (if p 2.2 3.3))")
    expected = parse_expr_string("(if p (assert q 2.2) (assert q 3.3))")
    symtab = dict()
    type_propagate_decls(list(parse_ks_filename("src/runtime/prelude.ks")), symtab)
    type_propagate_decls([e, expected], {**symtab, "p": Type.Bool, "q": Type.Bool})
    actual = utils.single_elem(list(lift_if.find_all_matches(e))).apply_rewrite()
    assert actual == expected


def test_lift_if_from_let():
    e = parse_expr_string("(let (x 4) (if (gt y 0) x 0))")
    match = utils.single_elem(list(rule("lift_if").find_all_matches(e)))
    actual = match.apply_rewrite()
    expected = parse_expr_string("(if (gt y 0) (let (x 4) x) (let (x 4) 0))")
    assert actual == expected
    # Now check we can't lift out of the let if the if-condition uses the bound variable
    e = parse_expr_string("(let (x 4) (if (gt x 0) x 0))")
    assert len(list(rule("lift_if").find_all_matches(e))) == 0


def test_lift_bind():
    e = parse_expr_string("(add (let (x 4.0) (add x 2.0)) 3.0)")
    symtab = dict()
    type_propagate_decls(list(parse_ks_filename("src/runtime/prelude.ks")), symtab)
    expected = parse_expr_string("(let (x 4.0) (add (add x 2.0) 3.0))")
    type_propagate_decls([e, expected], symtab)
    match = utils.single_elem(list(lift_bind.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected


def test_interchange_lets():
    e = parse_expr_string("(let (x 4) (let (y 5) (add x y)))")
    e2 = parse_expr_string("(let (y 5) (let (x 4) (add x y)))")
    match = utils.single_elem(list(rule("lift_bind").find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == e2
    match2 = utils.single_elem(list(rule("lift_bind").find_all_matches(actual)))
    actual2 = match2.apply_rewrite()
    assert actual2 == e
    # But, can't lift if the inner let uses the outer bound variable
    cant_lift = parse_expr_string("(let (x 5) (let (y (add x 1)) (add x y)))")
    assert len(list(rule("lift_bind").find_all_matches(cant_lift))) == 0


def test_lift_bind_shadowing():
    e = parse_expr_string("(add (let (x (add x 1)) x) x)")
    symtab = dict()
    type_propagate_decls(list(parse_ks_filename("src/runtime/prelude.ks")), symtab)
    # The RHS of the let refers to another (free) x - just check:
    with pytest.raises(Exception):
        type_propagate_decls([e], symtab)
    # So, we must rename the bound x so as not to capture the free x
    expected = parse_expr_string("(let (x_0 (add x 1)) (add x_0 x))")
    type_propagate_decls([e, expected], {**symtab, "x": Type.Integer})
    match = utils.single_elem(list(rule("lift_bind").find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected

    # But, no need to rename if the uses of the free "x" are in the let RHS itself
    # (such uses will be lifted and stay outside the binder):
    e = parse_expr_string("(add (let (x (add x 1)) x) 2)")
    expected = parse_expr_string("(let (x (add x 1)) (add x 2))")
    renamed = parse_expr_string("(let (x_0 (add x 1)) (add x_0 2))")
    match = utils.single_elem(list(rule("lift_bind").find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected
    assert actual != renamed


@pytest.mark.skip(reason="lift_over_build not part of general lift")
def test_lifting_over_build():
    # 1. Lift "let" over build
    e = parse_expr_string(
        """
        (build 10 (lam (i : Integer) 
                     (let (x (add 5 7)) 
                        (if (gt x 5) x i))))
        """
    )
    rules = RuleSet([rule("lift_bind"), rule("lift_if")])
    match = utils.single_elem(list(rules.find_all_matches(e)))
    actual = match.apply_rewrite()
    # Let should have been lifted:
    assert actual == parse_expr_string(
        """
        (let (x (add 5 7))
           (build 10 (lam (i : Integer) 
                        (if (gt x 5) x i))))
        """
    )
    # 2. Lift the "if"
    match2 = utils.single_elem(list(rules.find_all_matches(actual)))
    actual2 = match2.apply_rewrite()
    assert actual2 == parse_expr_string(
        """
        (let (x (add 5 7)) 
           (if (gt x 5) 
              (build 10 (lam (i : Integer) x)) 
              (build 10 (lam (i : Integer) i))))
        """
    )

    # 3. But, don't allow lifting an expression that refers to the build/lam-bound 'i':
    # 3a. if over let:
    e3 = parse_expr_string(
        """
        (build 10 (lam (i : Integer) 
            (let (x (add 5 i))  # Refers to "i" 
                (if (gt i 5) x i))))
        """
    )
    match3 = utils.single_elem(list(rules.find_all_matches(e3)))
    actual3 = match3.apply_rewrite()
    assert actual3 == parse_expr_string(
        """
        (build 10 (lam (i : Integer) 
            (if (gt i 5) 
                (let (x (add 5 i)) x) 
                (let (x (add 5 i)) i))))"
        """
    )
    # Now we should be able to lift either of those let's, but not the 'if'
    # 3b. let over build:
    actual4 = sorted_rewrites(rules, actual3)
    assert actual4 == [
        parse_expr_string(
            """
            (build 10 (lam (i : Integer) (let (x (add 5 i)) (if (gt i 5) x (let (x (add 5 i)) i)))))"
            """
        ),
        parse_expr_string(
            """
            (build 10 (lam (i : Integer) (let (x (add 5 i)) (if (gt i 5) (let (x (add 5 i)) x) i))))
            """
        ),
    ]
