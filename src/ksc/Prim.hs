-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.
{-# LANGUAGE LambdaCase #-}

module Prim where

import Lang
import GHC.Stack
import Control.Monad( zipWithM )
import Data.Tuple( swap )

--------------------------------------------
--  Simple call construction
--------------------------------------------

primCall :: PrimFun -> Type -> [TExpr] -> TExpr
primCall fun res_ty
  = Call (TFun res_ty (Fun (PrimFun fun)))

mkPrimCall :: HasCallStack => PrimFun -> [TExpr] -> TExpr
mkPrimCall fun args
  = primCall fun res_ty args
  where
    res_ty = primFunCallResultTy fun args

mkPrimCall1 :: HasCallStack => String -> TExpr -> TExpr
mkPrimCall1 f a = mkPrimCall f [a]

mkPrimCall2 :: HasCallStack => String -> TExpr -> TExpr -> TExpr
mkPrimCall2 f a b = mkPrimCall f [a, b]

mkPrimCall3 :: HasCallStack => String -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall3 f a b c = mkPrimCall f [a, b, c]

mkPrimCall4 :: HasCallStack => String -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall4 f a b c d = mkPrimCall f [a, b, c, d]

mkPrimCall5 :: HasCallStack => String -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall5 f a b c d e = mkPrimCall f [a, b, c, d, e]

mkPrimCall6 :: HasCallStack => String -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall6 f a b c d e g = mkPrimCall f [a, b, c, d, e, g]

mkPrimCall7 :: HasCallStack => String -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
mkPrimCall7 f a b c d e g h = mkPrimCall f [a, b, c, d, e, g, h]

mkZero :: HasCallStack => Type -> TExpr
-- (mkZero t) returns the zero of t
-- It should never be applied to types that don't have a zero
mkZero TypeFloat      = Konst (KFloat 0.0)
mkZero (TypeVec n t)  = pConstVec n (mkZero t)
mkZero (TypeTuple ts) = Tuple (map mkZero ts)
mkZero t              = pprPanic "mkZero" (ppr t)

--------------------------------------------
--  Parsing function names
--------------------------------------------

mk_fun :: String -> Fun
-- Parses the print-name of a top-level function into a Fun
-- In particular,
--
--   * Recognises D$f as (Grad f Fwd) etc
--     Keep this in sync with pprFun
--
--   * Distinguishes PrimFun from UserFun
mk_fun f = case find_dollar f of
             Just ("D",   s)  -> GradFun (mk_fun_id s) BasicAD
             Just ("Dt",   s) -> GradFun (mk_fun_id s) TupleAD
             Just ("fwd", s)  -> DrvFun  (mk_fun_id s) (AD BasicAD Fwd)
             Just ("fwdt", s) -> DrvFun  (mk_fun_id s) (AD TupleAD Fwd)
             Just ("rev", s)  -> DrvFun  (mk_fun_id s) (AD BasicAD Rev)
             Just ("revt", s) -> DrvFun  (mk_fun_id s) (AD TupleAD Rev)
             Just ("revl", s) -> LinearGradFun (mk_fun_id s)
             Just ("get", s) -> Fun     (mk_sel_fun s)
             _               -> Fun     (mk_fun_id f)
  where
    mk_fun_id f | isPrimFun_ f = PrimFun (translate_fun f)
                | otherwise   = UserFun f
    find_dollar f = case break (== '$') f of
                       (_, [])  -> Nothing  -- No $
                       (_, [_]) -> Nothing  -- Trailing $
                       (prefix, _ : suffix) -> Just (prefix, suffix)
    mk_sel_fun s = case break (== '$') s of
                     (i,_:n) -> SelFun (read i :: Int) (read n :: Int)
                     _ -> error $ "'get' should have form 'get$i$n', not [get$" ++ s ++ "]"
    isPrimFun_ f = (f `elem` (map fst translation)) || isPrimFun f
    translation = map swap $
                  [ ("mul", "*")
                  , ("div", "/")
                  , ("sub", "-")
                  , ("add", "+")
                  , ("eq" , "==")
                  , ("ne" , "!=")
                  , ("lt" , "<")
                  , ("gt" , ">")
                  , ("lte", "<=")
                  , ("gte", ">=") ]
    translate_fun f = case lookup f translation of
      Just s  -> s
      Nothing -> f


--------------------------------------------
--  Building simple calls
--------------------------------------------

lmZero :: Type -> Type -> TExpr
lmZero s t = mkPrimCall2 "lmZero" (mkDummy s) (mkDummy t)

lmZero_Dir :: ADDir -> Type -> Type -> TExpr
lmZero_Dir Fwd s t = lmZero s t
lmZero_Dir Rev s t = lmZero t s

lmOne :: Type -> TExpr
lmOne s = mkPrimCall1 "lmOne" (mkDummy s)

lmScale :: HasCallStack => Type -> TExpr -> TExpr
-- lmScale :: Float -> (s -o s)
lmScale s r = mkPrimCall2 "lmScale" (mkDummy s) r

lmAdd :: HasCallStack => TExpr -> TExpr -> TExpr
lmAdd = mkPrimCall2 "lmAdd"

lmAdds :: HasCallStack => [TExpr]-> TExpr
lmAdds [] = error "lmAdds of empty list (perhaps this should return lmZero?)"
lmAdds [x] = x
lmAdds (x:xs) = lmAdd x (lmAdds xs)

lmHCat :: HasCallStack => [TExpr] -> TExpr
lmHCat [e] = e
lmHCat es  = mkPrimCall "lmHCat" es

lmHCatV :: HasCallStack => TExpr -> TExpr
lmHCatV e  = mkPrimCall1 "lmHCatV" e

lmVCat :: HasCallStack => [TExpr] -> TExpr
lmVCat [e] = e
lmVCat es  = mkPrimCall "lmVCat" es

lmVCatV :: HasCallStack => TExpr -> TExpr
lmVCatV e  = mkPrimCall1 "lmVCatV" e

lmTranspose :: TExpr -> TExpr
lmTranspose = mkPrimCall1 "lmTranspose"

lmCompose :: TExpr -> TExpr -> TExpr
lmCompose = mkPrimCall2 "lmCompose"

lmApply :: HasCallStack => TExpr -> TExpr -> TExpr
lmApply = mkPrimCall2 "lmApply"

lmApplyR :: HasCallStack => TExpr -> TExpr -> TExpr
lmApplyR = mkPrimCall2 "lmApplyR"

lmApply_AD :: HasCallStack => ADMode -> TExpr -> TExpr -> TExpr
lmApply_AD (AD BasicAD dir) = lmApply_Dir  dir
lmApply_AD (AD TupleAD dir) = lmApplyT_Dir dir

lmApply_Dir :: HasCallStack => ADDir -> TExpr -> TExpr -> TExpr
lmApply_Dir Fwd e ds = lmApply  e ds
lmApply_Dir Rev e dt = lmApplyR dt e

lmApplyT_Dir :: HasCallStack => ADDir -> TExpr -> TExpr -> TExpr
lmApplyT_Dir Fwd e ds = mkPrimCall2 "lmApplyT"  e ds
lmApplyT_Dir Rev e dt = mkPrimCall2 "lmApplyTR" dt e

lmBuild :: HasCallStack => TExpr -> TExpr -> TExpr
lmBuild n b = lmVCatV (pBuild n b)

lmBuildT :: HasCallStack => TExpr -> TExpr -> TExpr
lmBuildT n b = lmHCatV (pBuild n b)

lmFold :: HasCallStack => TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
lmFold = mkPrimCall5 "lmFold"

pFFold :: HasCallStack => TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
pFFold = mkPrimCall6 "FFold"

pRFold :: HasCallStack => Type -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr -> TExpr
pRFold = mkPrimCall7 "RFold" . mkDummy

lmDummyFold :: HasCallStack => Type -> TExpr
lmDummyFold = mkPrimCall1 "lmDummyFold" . mkDummy

lmBuild_Dir :: ADDir -> TExpr -> TExpr -> TExpr
lmBuild_Dir Fwd = lmBuild
lmBuild_Dir Rev = lmBuildT

lmVCat_Dir :: ADDir -> [TExpr] -> TExpr
lmVCat_Dir Fwd = lmVCat
lmVCat_Dir Rev = lmHCat

lmVCatV_Dir :: ADDir -> TExpr -> TExpr
lmVCatV_Dir Fwd = lmVCatV
lmVCatV_Dir Rev = lmHCatV

lmHCat_Dir :: ADDir -> [TExpr] -> TExpr
lmHCat_Dir Fwd = lmHCat
lmHCat_Dir Rev = lmVCat

lmCompose_Dir :: ADDir -> TExpr -> TExpr -> TExpr
lmCompose_Dir Fwd m1 m2 = m1 `lmCompose` m2
lmCompose_Dir Rev m1 m2 = m2 `lmCompose` m1

isThePrimFun :: TFun -> String -> Bool
isThePrimFun (TFun _ (Fun (PrimFun f1))) f2 = f1 == f2
isThePrimFun _ _ = False

isLMOne, isLMZero :: TExpr -> Bool
isLMOne (Call f _) = f `isThePrimFun` "lmOne"
isLMOne _ = False

isLMZero (Call f _) =  f `isThePrimFun` "lmZero"
isLMZero _ = False

isKZero :: TExpr -> Bool
isKZero = \case
  Konst (KInteger 0  ) -> True
  Konst (KFloat   0.0) -> True
  Tuple ts -> all isKZero ts
  Call f [_,v] | f `isThePrimFun` "constVec" -> isKZero v
  _ -> False

isBuild_maybe :: TExpr -> Maybe (TExpr, TVar, TExpr)
isBuild_maybe (Call f [n,Lam i e])
  | f `isThePrimFun` "build"
  = Just (n, i, e)
isBuild_maybe _ = Nothing

fstArg :: TExpr -> TExpr
fstArg (Call _ [e,_]) = e
fstArg e = error $ "fstArg on non-duple" ++ pps e

sndArg :: TExpr -> TExpr
sndArg (Call _ [_,e]) = e
sndArg e = error $ "sndArg on non-duple" ++ pps e


lmDelta :: TExpr -> TExpr -> TExpr -> TExpr
lmDelta t i j = If (pEqual i j) (lmOne ty) (lmZero ty ty)
  where
    ty = typeof t

isEqualityCall :: TExpr -> Maybe (TExpr, TExpr)
isEqualityCall (Call f [e1,e2])
  | f `isThePrimFun` "eq" = Just (e1,e2)
isEqualityCall _          = Nothing

-----------------------
-- Delta and diag

pDelta :: TExpr -> TExpr -> TExpr -> TExpr
-- delta i j e  =  if i==j then e else zero
pDelta = mkPrimCall3 "delta"

pDeltaVec :: TExpr -> TExpr -> TExpr -> TExpr
-- deltaVec size i e = build size (\j. delta i j e)
-- Returns a size-vector with e at index i, and zeros elsewhere
pDeltaVec = mkPrimCall3 "deltaVec"

pConstVec :: TExpr -> TExpr -> TExpr
-- constVec size e = build size (\_. e)
pConstVec = mkPrimCall2 "constVec"

pDiag :: TExpr -> TExpr -> TExpr -> TExpr
-- diag rows cols (\i. e) = build row (\i. deltaVec cols i e)
pDiag = mkPrimCall3 "diag"

---------------------------
-- "User-defined" functions
---------------------------
pAdd, pMul, pDiv, pSub, pEqual :: HasCallStack => TExpr -> TExpr -> TExpr
pAdd   = mkPrimCall2 "add"
pMul   = mkPrimCall2 "mul"
pDiv   = mkPrimCall2 "div"
pSub   = mkPrimCall2 "sub"
pEqual = mkPrimCall2 "eq"

pNeg, pExp, pLog, pSin, pCos :: HasCallStack => TExpr -> TExpr
pNeg = mkPrimCall1 "neg"
pExp = mkPrimCall1 "exp"
pLog = mkPrimCall1 "log"
pSin = mkPrimCall1 "sin"
pCos = mkPrimCall1 "cos"

pBuild :: TExpr -> TExpr -> TExpr
pBuild = mkPrimCall2 "build"

pNewVec :: HasCallStack => Type -> TExpr -> TExpr
pNewVec = mkPrimCall2 "newVec" . mkDummy

pIndex :: TExpr -> TExpr -> TExpr
pIndex = mkPrimCall2 "index"

pIndexL :: TExpr -> TExpr -> TExpr
pIndexL = mkPrimCall2 "indexL"

pIncAt :: TExpr -> TExpr -> TExpr -> TExpr
pIncAt = mkPrimCall3 "incAt"

pSetAt :: TExpr -> TExpr -> TExpr -> TExpr
pSetAt = mkPrimCall3 "setAt"

pForRange :: TExpr -> TExpr -> TExpr -> TExpr
pForRange = mkPrimCall3 "forRange"

pForRangeRev :: TExpr -> TExpr -> TExpr -> TExpr
pForRangeRev = mkPrimCall3 "forRangeRev"

pSum :: TExpr -> TExpr
pSum = mkPrimCall1 "sum"

pSumBuild :: TExpr -> TExpr -> TExpr
pSumBuild = mkPrimCall2 "sumbuild"

pUnzip :: TExpr -> TExpr
pUnzip = mkPrimCall1 "unzip"

pSize :: TExpr -> TExpr
pSize e = mkPrimCall1 "size" e

pSel :: Int -> Int -> TExpr -> TExpr
pSel i n e = Call (TFun el_ty
                        (Fun (SelFun i n))) [e]
           where
             el_ty = case typeof e of
                        TypeTuple ts -> ts !! (i-1)
                        _ -> TypeUnknown  -- Better error from Lint

pFst,pSnd :: TExpr -> TExpr
pFst   = pSel 1 2
pSnd   = pSel 2 2

ensureTuple :: TExpr -> TExpr
ensureTuple x = case typeof x of
    TypeTuple _ -> x
    _ -> Tuple [x]


---------------------------------------------
--       Types of primitive functions
--
--  For each primitve, we give its type
--  And this is the /only/ place we do this
---------------------------------------------

primCallResultTy_maybe :: HasCallStack => Fun -> [TypedExpr]
                       -> Either SDoc Type
primCallResultTy_maybe fun args
  = case fun of
      Fun (PrimFun f)
         | Just ty <- primFunCallResultTy_maybe f args
         -> Right ty
         | otherwise
         -> Left (text "Ill-typed call to primitive:" <+> ppr fun)

      Fun (SelFun i n) -> selCallResultTy_maybe i n arg_tys

      GradFun f adp
        -> case primCallResultTy_maybe (Fun f) args of
            Left err -> Left err
            Right res_ty -> Right (mkGradType adp (mkTupleTy arg_tys) res_ty)

      LinearGradFun _s
        -> error "Prim.hs LinearGradFun"

      DrvFun f (AD _ Fwd)    -- f :: S1 S2 -> T, then fwd$f :: S1 S2 S1_t S2_t -> T_t
        | let n_s = length args
        , even n_s
        , let s_args = take (n_s `div` 2) args
        , Right t_ty <- primCallResultTy_maybe (Fun f) s_args
        -> Right (tangentType t_ty)
        | otherwise
        -> Left (text "Ill-typed call to:" <+> ppr fun)

      DrvFun _ (AD _ Rev)    -- f :: S1 S2 -> T, then rev$f :: S1 S2 T_t -> (S1_t, S2_t)
        | let s_tys = dropLast arg_tys
        -> Right (tangentType (mkTupleTy s_tys))

      Fun (UserFun _) -> Left (text "Not in scope: user fun:" <+> ppr fun)
  where
    arg_tys = map typeof args

selCallResultTy_maybe :: Int -> Int -> [Type] -> Either SDoc Type
selCallResultTy_maybe i n [TypeTuple arg_tys]
  | i <= length arg_tys
  , n == length arg_tys
  = Right (arg_tys !! (i - 1))
selCallResultTy_maybe _ _ _ = Left (text "Bad argument to selector")

primFunCallResultTy :: HasCallStack => PrimFun -> [TExpr] -> Type
primFunCallResultTy fun args
  = case primFunCallResultTy_maybe fun [TE arg (typeof arg) | arg <- args] of
      Just res_ty -> res_ty
      Nothing -> pprTrace "primCallResultTy: Could not determine result type for"
                          (vcat [ text fun <+> ppr args
                                , ppr (map typeof args)])
                 TypeUnknown

---------------------------------------
-- This is the function that does the heavy lifting for primitives

primFunCallResultTy_maybe :: PrimFun -> [TypedExpr] -> Maybe Type

-- build n (e :: Integer -> elt) :: Vec n elt
primFunCallResultTy_maybe "build" args
  | [n,f] <- args
  , sizeArgOK n
  , TypeLam TypeInteger elt_ty <- typeof f
    -- ToDo: add free-var check for 'n'
  = Just (TypeVec (toSize n) elt_ty)
  | otherwise = Nothing

primFunCallResultTy_maybe "newVec" args
  | [t,n] <- args
  , sizeArgOK n
  = Just (TypeVec (toSize n) (typeof t))

primFunCallResultTy_maybe "fold" args
  | [f,acc,v] <- args
  , TypeLam (TypeTuple [a1, b1]) a2 <- typeof f
  , TypeVec _n b2 <- typeof v
  , b1 `eqType` b2
  , Just a <- eqTypes a1 [a2, typeof acc]
  = Just a
  | otherwise = Nothing

primFunCallResultTy_maybe "forRange" args
  | [n,initialState,body] <- args
  , sizeArgOK n
  , s1 <- typeof initialState
  , TypeLam (TypeTuple [TypeInteger, s2]) s3 <- typeof body
  = eqTypes s1 [s2, s3]

primFunCallResultTy_maybe "lmFold" args
  | [ds_zero,f,f',acc,v] <- args
  , TypeLam t1 a1 <- typeof f
  , TypeLam t2 (TypeLM (TypeTuple [s1, t3]) a2) <- typeof f'
  , Just t <- eqTypes t1 [t2, t3]
  , TypeTuple [a3, b1] <- t
  , Just a <- eqTypes a1 [a2, a3, typeof acc]
  , Just _ <- eqTypes (typeof ds_zero) [tangentType s1]
  , v_ty@(TypeVec _n b2) <- typeof v
  , b2 `eqType` b1
  = Just (TypeLM (TypeTuple [s1, TypeTuple [a, v_ty]]) a)
  | otherwise = Nothing

--- Type checking is not comprehensive because we only ever generate
--- RFold through reverse applying to an lmFold, and we assume that is
--- done correctly.  We could add more comprehensive type checking
--- later if we want.
primFunCallResultTy_maybe "RFold" args
  | [_ty_dv,ty_in,_f,_f',acc,v,_dr] <- args
  = Just (TypeTuple [ typeof ty_in
                    , TypeTuple [ tangentType (typeof acc)
                                , tangentType (typeof v)]])
  | otherwise = Nothing

--- Type checking is not comprehensive because we only ever generate
--- FFold through forward applying to an lmFold, and we assume that is
--- done correctly.  We could add more comprehensive type checking
--- later if we want.
primFunCallResultTy_maybe "FFold" args
  | [_f,_acc,_v,_df,dacc,_dv] <- args
  = Just (typeof dacc)
  | otherwise = Nothing

primFunCallResultTy_maybe "lmDummyFold" args
  | [t] <- args
  = Just (typeof t)
  | otherwise = Nothing

-- constVec (n :: Integer) (e :: t) :: Vec n t
primFunCallResultTy_maybe "constVec" args
  | [n,e] <- args
  , sizeArgOK n
  = Just (TypeVec (toSize n) (typeof e))
  | otherwise = Nothing

-- deltaVec (n :: Integer) (i :: Integer) (e :: t) :: Vec n t
primFunCallResultTy_maybe "deltaVec" args
  | [n,i,e] <- args
  , sizeArgOK n
  , TypeInteger <- typeof i
  = Just (TypeVec (toSize n) (typeof e))
  | otherwise = Nothing

-- diag (rows :: Integer) (cols :: Integer) (f :: Integer -> t)
--      :: Vec rows (Vec cols t)
primFunCallResultTy_maybe "diag" args
  | [r,c,f] <- args
  , sizeArgOK r
  , sizeArgOK c
  , TypeLam TypeInteger t <- typeof f
  = Just (TypeVec (toSize r) (TypeVec (toSize c) t))
  | otherwise = Nothing

-- Addition is special: it can add any two things of the same type,
-- or it can add t to tangentType t, which is implemented somewhat loosely
-- here by allowing t + () -> t
primFunCallResultTy_maybe "add" args
  | [t1,t2] <- map typeof args
  = add t1 t2
  | otherwise = Nothing
  where
    add :: Type -> Type -> Maybe Type
    add TypeInteger TypeInteger   = Just TypeInteger
    add TypeFloat   TypeFloat     = Just TypeFloat
    add t (TypeTuple [])          = Just t
    add (TypeVec n1 t1) (TypeVec n2 t2)
      | eqSize n1 n2                    = do { tr <- add t1 t2
                                             ; return (TypeVec n1 tr) }
    add (TypeTuple t1s) (TypeTuple t2s)
      | length t1s == length t2s        = do { ts <- zipWithM add t1s t2s
                                             ; return (TypeTuple ts) }
    add _ _ = Nothing

primFunCallResultTy_maybe fun args
  = case (fun, map typeof args) of
      ("lmZero"   , [s, t])                                  -> Just (TypeLM s t)
      ("lmOne"    , [t])                                     -> Just (TypeLM t t)
      ("lmScale"  , [t, TypeFloat])                          -> Just (TypeLM t t)

      ("lmCompose", [TypeLM _ c, TypeLM a _])                -> Just (TypeLM a c)
      ("lmAdd"    , [TypeLM s1 t1, TypeLM _ _])              -> Just (TypeLM s1 t1)
      ("lmTranspose", [TypeLM s t])                          -> Just (TypeLM t s)

      ("lmApply"  , [TypeLM s1 t, s2]) | tangentType s1 `eqType` s2 -> Just (tangentType t)
           -- Linar map apply:  lmApply :: (s -o t) -> ds -> dt
      ("lmApplyR" , [t1, TypeLM s t2]) | t1 `eqType` tangentType t2 -> Just (tangentType s)
           -- Reverse apply:  lmApplyR :: dt -> (s -o t) -> ds

      ("lmApplyT" , [TypeTuple [_, TypeLM s1 t], s2])
                                | tangentType s1 `eqType` s2 -> Just (tangentType t)
           -- Tupled version:  lmApplyT :: (r, s -o t) -> ds -> dt

      ("lmVCat"   , tys) | Just (ss,ts) <- unzipLMTypes tys
                         , (s1:ss1) <- ss
                         , all (== s1) ss1                   -> Just (TypeLM s1 (TypeTuple ts))
      ("lmVCatV"  , [TypeVec n (TypeLM s t)])                -> Just (TypeLM s (TypeVec n t))
      ("lmHCat"   , tys) | Just (ss,ts) <- unzipLMTypes tys
                         , (t1:ts1) <- ts
                         , all (== t1) ts1                   -> Just (TypeLM (TypeTuple ss) t1)
      ("lmHCatV"  , [TypeVec n (TypeLM t s)])                -> Just (TypeLM (TypeVec n t) s)

      -- ($inline f args) forces f to be inlined here
      ("$inline"  , [t])                                     -> Just t

      -- ($check f rev$f s ds dt) verifies the derivatives rev$f at s in directions ds,dt.
      -- That is, ds and dt should be near-zero elements of the domain and range tangent spaces
      -- and the returned value dt'*Jacobian(f)*ds should be similar to dt'*(f(s+ds)-f(s))
      ("$check"   , [TypeLam s t, TypeLam s_dt _ds', s', ds, dt])
                      | s' `eqType` s
                      -- , ds' `eqType` ds -- fails in test0 for Tuple (Float) != Float
                      , tangentType s `eqType` ds
                      , tangentType t `eqType` dt
                      , s_dt `eqType` (typeTupleAppend s dt)
                       -> Just TypeFloat

      -- ($trace e) emits its argument's value to stdout and returns it
      ("$trace"   , [t])                                     -> Just t

      -- ($rand s) returns a uniform random float between 0 and s
      ("$rand"    , [TypeFloat])                             -> Just TypeFloat
      ("$ranhashdoub" , [TypeInteger])                           -> Just TypeFloat

      -- (pr a b c) prints its arguments to stdout, with banners.  We should deprecate it.
      ("pr"       , _)                                       -> Just TypeInteger
      -- (print a b c) prints its arguments to stdout with no separators
      ("print"    , _)                                       -> Just TypeInteger
      ("sumbuild" , [TypeInteger, TypeLam TypeInteger t])    -> Just t
      ("index"    , [TypeInteger, TypeVec _ t])              -> Just t
      ("indexL"   , [TypeInteger, vt@(TypeVec _ t)])         -> Just (TypeTuple [t, vt])
      ("incAt"    , [TypeInteger, t, vt@(TypeVec _ t')])
        | t == t'                                            -> Just vt
      ("setAt"    , [TypeInteger, t, vt@(TypeVec _ t')])
        | t == t'                                            -> Just vt
      ("size"     , [TypeVec _ _])                           -> Just TypeSize
      ("sum"      , [TypeVec _ t])                           -> Just t
      ("to_float" , [TypeInteger])                           -> Just TypeFloat
      ("dot"      , [t, t']) | t == t'                       -> Just TypeFloat
      ("dot"      , [t, t']) | tangentType t == t'           -> Just TypeFloat
      ("norm"     , [_])                                     -> Just TypeFloat

      ("unzip"    , [TypeVec n (TypeTuple ts)])              -> Just (TypeTuple (map (TypeVec n) ts))

      -- arithmetic ops.   See special case for "add" above
      ("mul"        , [TypeFloat,   t]             ) -> Just t
      ("mul"        , [TypeInteger, TypeInteger]   ) -> Just TypeInteger
      ("div"        , [TypeFloat,   TypeFloat]     ) -> Just TypeFloat
      ("div"        , [TypeInteger, TypeInteger]   ) -> Just TypeInteger
      ("sub"        , [TypeFloat,   TypeFloat]     ) -> Just TypeFloat
      ("sub"        , [TypeInteger, TypeInteger]   ) -> Just TypeInteger

      ("neg"      , [t]                                    ) -> Just t
      ("exp"      , [TypeFloat]                            ) -> Just TypeFloat
      ("log"      , [TypeFloat]                            ) -> Just TypeFloat
      ("sin"      , [TypeFloat]                            ) -> Just TypeFloat
      ("cos"      , [TypeFloat]                            ) -> Just TypeFloat
      ("eq"       , _                                      ) -> Just TypeBool
      ("ne"       , _                                      ) -> Just TypeBool
      ("lt"        , _                                     ) -> Just TypeBool
      ("gt"        , _                                     ) -> Just TypeBool
      ("lte"        , _                                    ) -> Just TypeBool
      ("gte"        , _                                    ) -> Just TypeBool

      ("abs"      , _                                      ) -> Just TypeFloat
      ("max"      , [TypeFloat, TypeFloat]                 ) -> Just TypeFloat

      ("delta"    , [TypeInteger, TypeInteger, t]          ) -> Just t

      ("or"       , [TypeBool, TypeBool]                   ) -> Just TypeBool
      ("and"      , [TypeBool, TypeBool]                   ) -> Just TypeBool
      _ -> Nothing

      where
        typeTupleAppend (TypeTuple t1s) t2 = TypeTuple (t1s ++ [t2])
        typeTupleAppend t1 t2 = TypeTuple [t1, t2]

isPrimFun :: String -> Bool
isPrimFun f = f `elem` [ "$inline"  -- ($inline f args...)        Force inline f at args
                       , "$check"   -- ($check f rev$f x dx df)   Derivative check df' * D$f * dx
                       , "$trace"   -- ($trace f args)            Print and return (f args)
                       , "$rand"    -- ($rand val)                Generate a random float between 0 and val
                       , "$ranhashdoub" -- ($ranhashdoub val)     Generate a random float between 0 and 1 purely
                       , "pr"       -- (pr "msg" 3)               Print "msg\n---3\n"
                       , "print"    -- (print "msg" 3)            Print "msg3"
                       , "build"    -- (build N f)                Build vector [(f i) for i = 1..n]
                       , "sumbuild" -- (sumbuild N f)             (sum (build N f))
                       , "fold"     -- (fold f z v)               (Left) fold over v
                       , "forRange"
                       , "index"
                       , "indexL"
                       , "newVec"
                       , "size"
                       , "sum"
                       , "unzip"   -- Takes a vector of tuples to a tuple of vectors
                       , "to_float"
                       , "neg", "exp", "log", "sin", "cos"
                       , "add", "sub", "mul", "div"
                       , "eq", "ne", "lt", "gt", "lte", "gte", "delta", "deltaVec", "diag", "constVec"
                       , "lmApply", "lmApplyT", "lmVCat", "lmHCat", "lmTranspose"
                       , "lmVCatV", "lmHCatV"
                       , "lmCompose", "lmAdd", "lmScale"
                       , "abs", "max"
                       , "or", "and"
                       ]

sizeArgOK :: TypedExpr -> Bool
-- In (build n f), is the expresion 'n' ok?
sizeArgOK (TE n_expr n_ty)
  | TypeSize <- n_ty
  = True
  | Konst (KInteger _) <- n_expr
  = True
  | otherwise
  = False

toSize :: TypedExpr -> TExpr
toSize (TE n_expr n_ty)
  | TypeSize <- n_ty
  = n_expr
  | Konst (KInteger n) <- n_expr
  = Konst (KSize n)
  | otherwise
  = error "toSize"
