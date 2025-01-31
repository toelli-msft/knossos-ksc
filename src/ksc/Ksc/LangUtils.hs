-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.
{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# OPTIONS_GHC -Wno-orphans        #-}
{-# LANGUAGE TypeFamilies, DataKinds, FlexibleInstances,
             PatternSynonyms,
	     ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module Ksc.LangUtils (
  -- Functions over expressions
  isTrivial, splitTuple,

  -- Equality
  cmpExpr,

  -- Free vars
  InScopeSet, emptyInScopeSet, mkInScopeSet, extendInScopeSet,
  notInScope, notInScopeTV, notInScopeTVs,
  notFreeIn, newVarNotIn, freeVarsOf,

  -- Tests
  Ksc.LangUtils.hspec,

  -- Symbol table
  GblSymTab, extendGblST, lookupGblST, emptyGblST, modifyGblST,
  stInsertFun,
  LclSymTab, extendLclST,
  SymTab(..), newSymTab,

  -- NoTupPat
  noTupPatifyDef,
  noTupPatifyExpr

  ) where

import Ksc.Lang
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Char( isDigit )
import Data.List( mapAccumL )
import Test.Hspec

-----------------------------------------------
--     Functions over expressions
-----------------------------------------------

isTrivial :: TExpr -> Bool
isTrivial (Tuple [])    = True
isTrivial (Var {})      = True
isTrivial (Konst {})    = True
isTrivial (Call f args) = isDummy args
isTrivial (Assert _ e2) = isTrivial e2
isTrivial _ = False

isDummy :: TExpr -> Bool
isDummy (Dummy {}) = True
isDummy _          = False

-----------------------------------------------
--     Tuples
-----------------------------------------------

splitTuple :: TExpr -> Int -> [TExpr]
-- Expects e to be a tuple-typed expression;
-- returns its n components.
-- May duplicate e
splitTuple _ 0 = []
splitTuple e 1 = [e]
splitTuple (Tuple es) n
  | n == length es = es
  | otherwise      = pprPanic "splitTuple" (ppr n $$ ppr es)
splitTuple e n = [ pSel i n e | i <- [1..n] ]

-----------------------------------------------
--     Free variables
-----------------------------------------------

freeVarsOf :: TExpr -> S.Set TVar
freeVarsOf = go
  where
   go :: TExpr -> S.Set TVar
   go (Var v)        = S.singleton v
   go (Konst _)      = S.empty
   go (Dummy _)      = S.empty
   go (Tuple es)     = S.unions (map go es)
   go (If b t e)     = go b `S.union` go t `S.union` go e
   go (Call _ es)    = go es
   go (App f a)      = go f `S.union` go a
   go (Let v r b)    = go r `S.union` (go b S.\\ S.fromList (patVars v))
   go (Lam v e)      = S.delete v $ go e
   go (Assert e1 e2) = go e1 `S.union` go e2

notFreeIn :: TVar -> TExpr -> Bool
notFreeIn = go
 where
   go:: TVar -> TExpr -> Bool
   go v (Var v2)     = tVarVar v /= tVarVar v2
   go v (Dummy {})   = True
   go v (Konst _)    = True
   go v (Tuple es)   = all (go v) es
   go v (If b t e)   = go v b && go v t && go v e
   go v (Call _ e)   = go v e
   go v (App f a)    = go v f && go v a
   go v (Let v2 r b) = go v r && (v `elem` patVars v2 || go v b)
   go v (Lam v2 e)   = v == v2 || go v e
   go v (Assert e1 e2) = go v e1 && go v e2

-----------------

newVarNotIn :: Type -> TExpr -> TVar
newVarNotIn ty e = go ty e 1 -- FIXME start with hash of e to reduce retries
  where
    go ty e n
      | v `notFreeIn` e = v
      | otherwise       = go ty e (n + 1)
      where
         v = mkTVar ty ("_t" ++ show n)

hspec :: Spec
hspec = do
    let var :: String -> TVar
        var s = TVar TypeFloat (Simple s)
        fun :: String -> TFun Typed
        fun s = TFun TypeFloat (Fun JustFun (BaseFunId (BaseUserFunName s) TypeFloat))
        e  = Call (fun "f") (Var (var "i"))
        e2 = Call (fun "f") (Tuple [Var (var "_t1"), kInt 5])
    describe "notFreeIn" $ do
      it ("i notFreeIn " ++ show (ppr (e::TExpr))) $
        (var "i" `notFreeIn` e) `shouldBe` False
      it ("x not notFreeIn " ++ show (ppr (e::TExpr))) $
        (var "x" `notFreeIn` e) `shouldBe` True
    describe "newVarNotIn" $ do
      it "not in, so new var is _t1..." $
        newVarNotIn TypeFloat e `shouldBe` (var "_t1")
      it "in, so new var is _t2..." $
        newVarNotIn TypeFloat e2 `shouldBe` (var "_t2")


-----------------------------------------------
--     Symbol table, ST, maps variables to types
-----------------------------------------------

-- Global symbol table
type GblSymTab = M.Map (UserFun Typed) TDef
   -- Maps a function to its definition, which lets us
   --   * Find its return type
   --   * Inline it
   -- Domain is UserFun Typed

-- Local symbol table
type LclSymTab = M.Map Var Type
   -- The Type is the type of the variable

-- Entire symbol table
data SymTab
  = ST { gblST :: GblSymTab
       , lclST :: LclSymTab
    }

instance (Pretty k, Pretty v) => Pretty (M.Map k v) where
   ppr m = braces $ fsep  $ punctuate comma $
           [ ppr k <+> text ":->" <+> ppr v | (k,v) <- M.toList m ]

instance Pretty SymTab where
  ppr (ST { lclST = lcl_env, gblST = gbl_env })
    = vcat [ hang (text "Global symbol table:")
                2 (ppr gbl_env)
           , hang (text "Local symbol table:")
                2 (ppr lcl_env) ]

emptyGblST :: GblSymTab
emptyGblST = M.empty

newSymTab :: GblSymTab -> SymTab
newSymTab gbl_env = ST { gblST = gbl_env, lclST = M.empty }

stInsertFun :: TDef -> GblSymTab -> GblSymTab
stInsertFun def@(Def { def_fun = f }) = M.insert f def

lookupGblST :: HasCallStack => UserFun Typed -> GblSymTab -> Maybe TDef
lookupGblST = M.lookup

extendGblST :: GblSymTab -> [TDef] -> GblSymTab
extendGblST = foldl (flip stInsertFun)

modifyGblST :: (GblSymTab -> GblSymTab) -> SymTab -> SymTab
modifyGblST g = \env -> env { gblST = g (gblST env) }

extendLclST :: LclSymTab -> [TVar] -> LclSymTab
extendLclST lst vars = foldl add lst vars
  where
    add :: LclSymTab -> TVar -> LclSymTab
    add env (TVar ty v) = M.insert v ty env


-----------------------------------------------
--     InScopeSet, and name clash resolution
-----------------------------------------------

type InScopeSet = S.Set Var

emptyInScopeSet :: InScopeSet
emptyInScopeSet = S.empty

mkInScopeSet :: [TVar] -> InScopeSet
mkInScopeSet tvs = S.fromList (map tVarVar tvs)

extendInScopeSet :: TVar -> InScopeSet -> InScopeSet
extendInScopeSet tv in_scope
  = tVarVar tv `S.insert` in_scope


notInScopeTVs :: Traversable t => InScopeSet -> t TVar -> (InScopeSet, t TVar)
notInScopeTVs = mapAccumL notInScopeTV

notInScopeTV :: InScopeSet -> TVar -> (InScopeSet, TVar)
notInScopeTV is (TVar ty v)
  = (v' `S.insert` is, TVar ty v')
  where
    v' = notInScope v is

notInScope :: Var -> InScopeSet -> Var
-- Find a variant of the input Var that is not in the in-scope set
--
-- Do this by adding "_1", "_2" etc
notInScope v in_scope
  | not (v `S.member` in_scope)
  = v
  | otherwise
  = try (S.size in_scope)
  where
    (str, rebuild) = case v of
            Simple s -> (s, Simple)
            Delta  s -> (s, Delta)
            Grad s   -> (s, Grad)

    try :: Int -> Var
    try n | var' `S.member` in_scope = try (n+1)
          | otherwise                = var'
          where
            var' = rebuild str'
            str' = prefix ++ '_' : show n

    (prefix, _n) = parse_suffix [] (reverse str)

    parse_suffix :: String          -- Digits parsed from RH end (in order)
                 -> String          -- String being parsed (reversed)
                 -> (String, Int)   -- String before "_", plus number found after
    -- E.g. parse_suffix "foo_23" = ("foo",    23)
    --      parse_suffix "wombat" = ("wombat", 0)
    parse_suffix ds (c:cs)
      | c == '_'
      , not (null ds)
      = (reverse cs, read ds)
      | isDigit c
      = parse_suffix (c:ds) cs
    parse_suffix ds cs
      = (reverse cs ++ ds, 0)


-----------------------------------------------
--     noTupPatifyDef
-----------------------------------------------

{-
Note [Replacing TupPat with nested Let]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

noTupPatifyDef transforms a Def to an equivalent Def in which TupPat
does not appear. The rationale is as follows.

Expr supports tuple patterns. That is, one can write

  1. let (x1, ..., xn) = rhs in body

instead of

  2. let r = rhs
         x1 = get$1$n r
         ...
         xn = get$n$n r
     in body

When we come to implement AD based on Single Use Language the form 1
will be more than a simple convenience, it will be essential for the
algorithm to generate efficient code.

On the other hand, for AD based on linear maps and for CatLang there's
no great urgency to support differentiating code which contains tuple
patterns.  Therefore for convenience we just translate tuple patterns
into nested lets before running those parts of the code.  We can
always revisit this decision later.

Specifically, noTupPatifyDef does these two things:

* Makes the Def have a VarPat.  We transform

   f (a,b,c) = rhs
      ===>
   f s = let a = get$1$3 s in
            let b = get$2$3 s in
            let c = get$3$3 s in
            rhs

* Expands any tuple-let into a bunch of non-tuple lets

   let (a,b) = rhs in body
      ===>
   let t = rhs in
   let a = get$1$2 t
   let b = get$2$2 t in
   body

-}

-- Replaces all occurrences of TupPat in the Def (including the
-- def_pat of the Def itself) with nested Lets.  See Note [Replacing
-- TupPat with nested Let].
noTupPatifyDef :: TDef -> TDef
noTupPatifyDef def@(Def { def_pat = pat, def_rhs = UserRhs rhs })
  = def { def_pat = VarPat argVar
        , def_rhs = UserRhs (add_unpacking (noTupPatifyExpr in_scope rhs)) }
  where
     (argVar, add_unpacking, in_scope) = case pat of
       VarPat v -> (argVar, add_unpacking, in_scope)
         where
           argVar = v
           add_unpacking = id
           in_scope = mempty
       TupPat tvs -> (argVar, add_unpacking, in_scope')
         where
           in_scope = mkInScopeSet (patVars pat)
           argVar = TVar ty (notInScope (Simple "_t") in_scope)
           in_scope' = extendInScopeSet argVar in_scope
           ty = mkTupleTy (map typeof tvs)

           n = length tvs

           add_unpacking = mkLets [ (tv, pSel i n (Var argVar))
                                  | (tv, i) <- tvs `zip` [1..] ]

noTupPatifyDef def = def

-- Replaces all occurrences of TupPat in the Expr with nested Lets.
-- See Note [Replacing TupPat with nested Let].
noTupPatifyExpr :: InScopeSet -> TExpr -> TExpr
noTupPatifyExpr in_scope = \case
     Call f e -> Call f (noTupPatifyExpr in_scope e)
     Tuple es -> Tuple (fmap (noTupPatifyExpr in_scope) es)
     Lam v e  -> Lam v (noTupPatifyExpr in_scope' e)
       where in_scope' = extendInScopeSet v in_scope
     App f e  -> App (noTupPatifyExpr in_scope f) (noTupPatifyExpr in_scope e)
     Let (VarPat v) r b ->
       Let (VarPat v) (noTupPatifyExpr in_scope r) (noTupPatifyExpr in_scope' b)
       where in_scope' = extendInScopeSet v in_scope
     Let (TupPat t) r b ->
       mkLet fresh r
       $ mkLets (map (\(i, v) -> (v, pSel i n (Var fresh))) (zip [1..] t))
       $ noTupPatifyExpr in_scope' b
       where fresh = TVar ty (notInScope (Simple "_t") in_scope)
             ty = typeof r
             in_scope' = S.fromList (map tVarVar t) `S.union` in_scope
             n = length t
     If c t f  -> If (noTupPatifyExpr in_scope c)
                     (noTupPatifyExpr in_scope t)
                     (noTupPatifyExpr in_scope f)
     Assert c b -> Assert (noTupPatifyExpr in_scope c) (noTupPatifyExpr in_scope b)
     Konst k -> Konst k
     Var v   -> Var v
     Dummy d -> Dummy d
