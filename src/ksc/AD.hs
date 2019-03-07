{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module AD where

import Lang
import Prim

-- for unit test
--import Test.Hspec

--------------- Generate names for gradded indentifiers

gradF :: Fun -> Fun
gradF (Fun f) = GradFun f Fwd
gradF f       = error ("gradF: bad function: " ++ show f)

gradV :: Var -> Var
gradV (Simple x) = Grad x Fwd
gradV v          = error ("gradV: bad variable: " ++ render (ppr v))

gradSelFun :: [TVar] -> TVar -> Int -> TExpr
-- (gradSelFun i n) selects the i'th component of a n-tuple
-- Result expr has type (t1, ..., tn) -o ti
gradSelFun params typaram i
  = lmHCat [ if i == j then lmOne             t
                       else lmZero (typeof p) t
           | (p,j) <- params `zip` [1..] ]
  where
    t = typeof typaram

-------------------------------------------------

gradDefs :: [TDef] -> [TDef]
gradDefs defs = map gradDef defs

gradDef :: TDef -> TDef
gradDef (DefX f params rhs)
  = DefX (gradTFun s f)
         params
         (mkLets lets (gradE s rhs))
  where
    s = case params of
          [TVar ty _] -> ty
          _           -> TypeTuple (map typeof params)

    lets = case params of
             [p] -> [ (gradTVar s p, lmOne (typeof p)) ]
             _   -> [ (gradTVar s p, gradSelFun params p i)
                    | (p,i) <- params `zip` [1..] ]


-- s -> (Expr :: t) -> (Expr :: s -o t)
gradE :: Type -> TExpr -> TExpr
gradE s (Konst k)      = lmZero s (typeofKonst k)
gradE s (Var tv)       = Var (gradTVar s tv)
gradE s (Assert e1 e2) = Assert e1 (gradE s e2)
gradE s (Tuple es)     = lmVCat (map (gradE s) es)
gradE s (If b t e)     = If b (gradE s t) (gradE s e)
gradE _ e@(Lam {})     = pprPanic "gradE: can't deal with lambda yet" (ppr e)
gradE s (Let v e1 e2)  = mkLet v e1                       $
                         mkLet (gradTVar s v) (gradE s e1) $
                         gradE s e2

-- grad[ build (\i.e ]
--  = B (\i. let Di = 0 in grad[e])
-- We need the Di binding in case 'i' is mentioned in
-- grad[e], e.g. build (\i. power(x, i))
gradE s (Call f (Tuple [n, Lam ti@(TVar TypeInteger _i) body]))
  | f `isThePrimFun` "build"
  = lmBuild n $ Lam ti $
    mkLet (gradTVar s ti) (lmZero s TypeInteger) $
    gradE s body

gradE s (Call f arg) = Call (gradTFun (typeof arg) f) arg
                       `lmCompose` gradE s arg

gradTFun :: Type -> TFun -> TFun
gradTFun arg_ty (TFun res_ty f) = TFun (TypeLM arg_ty res_ty) (gradF f)

gradTVar :: Type -> TVar -> TVar
gradTVar s (TVar ty v) = TVar (TypeLM s ty) (gradV v)

---------------------------------

-- Apply-to-dx
--
-- Local bindings of type (S -o T)
-- are transformed to ones of type T

applyD :: TDef -> TDef
applyD (DefX (TFun (TypeLM s t) (GradFun f Rev)) vars rhs)
  = DefX (TFun (tangentType t) (DrvFun f Rev)) (vars ++ [dr]) $
    lmApply rhs $ Var dr
  where
    dr = TVar (tangentType s) $ Delta "r"

applyD (DefX (TFun (TypeLM _ t) (GradFun f Fwd)) vars rhs)
  = DefX (TFun (tangentType t) (DrvFun f Fwd)) (vars ++ dvars) $
    lmApply rhs (mkTuple $ map Var dvars)
  where
    dvars = map to_delta vars

    to_delta (TVar ty (Simple x)) = TVar (tangentType ty) (Delta x)

applyDefs :: [TDef] -> [TDef]
applyDefs defs = map applyD defs

---------------------------------
-- Transpose

transposeD :: TDef -> TDef
transposeD (DefX (TFun (TypeLM s t) (GradFun f d)) args rhs)
  = DefX (TFun (TypeLM t s) (GradFun f (flipMode d))) args $
    lmTranspose rhs

----------------------------------
--- Unit test

{-

-- TODO make this work
test_AD =
  hspec $ do
    let e1 = runParserOrPanic pDef "(def f ((x : Float)) (* x 2.0))"
    let (env,ae1) = annotDef e1
    let de1_expected = runParserOrPanic pDef "(def D$f ((x : Float)) (lmScale 2.0))"
    let (env1,ade1_expected) = annotDef de1_expected
    let ade1 = gradDef emptyST ae1
    describe "AD" $ do
      it "AD" $
        ade1 `shouldBe` ade1_expected
-}
