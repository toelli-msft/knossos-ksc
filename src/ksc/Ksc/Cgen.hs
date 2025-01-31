-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.
{-# LANGUAGE LambdaCase, FlexibleInstances, PatternSynonyms  #-}
{-# LANGUAGE DataKinds  #-}

module Ksc.Cgen where

import           GHC.Stack
import           Prelude                 hiding ( lines
                                                , tail
                                                )

import qualified Data.Map                      as Map
import           Data.List                      ( intercalate )
import           Data.Maybe                     ( mapMaybe )
import           Control.Monad                  ( when )
import qualified Control.Monad.State           as S
import qualified System.Directory
import qualified System.FilePath
import qualified System.Process
import           System.Exit                    ( ExitCode(ExitSuccess) )

import           Ksc.Lang                hiding ( (<>) )
import qualified Ksc.OptLet

import Debug.Trace

data CType =  CType Type
            | CTuple [CType]
            | CFunction CType CType
            | TypeDef String CType
            | UseTypeDef String Type  -- See Note [Function return types]
            | LMZero Type Type
            | LMOne Type
            | LMScale Type
            | LMScaleR Type
            | LMHCat [CType]
            | LMVCat [CType]
            | LMBuild CType
            | LMCompose CType CType
            | LMAdd [CType]
            | LMVariant [CType]
            deriving (Eq, Ord, Show)

{- Note [Function return types]

A CType of (UseTypeDef name type) represents the return type of a def.
The "type" argument is the return type as declared in the ks file.
The C++ return type (for which "name" is a typedef) will only be known
once code has been generated for the function.

But even though a given ks type may be implemented by more than one
possible C++ type, we can still use the ks type for determining whether
the return value might refer to allocated memory:
see Note [Allocator usage of types].
-}

mkCType :: Type -> CType
mkCType (TypeTuple ts) = CTuple $ map mkCType ts
mkCType ty             = CType ty

stripTypeDef :: HasCallStack => CType -> CType
stripTypeDef (TypeDef _ t) = stripTypeDef t
stripTypeDef t             = t

stripCType :: CType -> Type
stripCType = \case
  CType  ty     -> ty
  CTuple tys    -> TypeTuple $ map stripCType tys
  TypeDef _ cty -> stripCType cty
  _             -> error "LM/Function type in stripCType"

cgenIsLM :: HasCallStack => CType -> Bool
cgenIsLM = \case
  CType  (TypeLM _ _) -> True
  CType  _            -> False
  CTuple ts           -> any cgenIsLM ts
  CFunction _ _       -> False
  TypeDef   _ ty      -> cgenIsLM ty
  UseTypeDef s _      -> error ("Don't know; it's a UseTypeDef: " ++ s)
  _                   -> True

isUseTypeDef :: CType -> Bool
isUseTypeDef (UseTypeDef _ _) = True
isUseTypeDef _ = False

makeUnionType :: HasCallStack => CType -> CType -> CType
makeUnionType (CTuple ts) (CTuple us) =
  if ts == us
  then CTuple ts
  else
    CTuple $ zipWith makeUnionType ts us

makeUnionType ty1 ty2 =
  if ty1 == ty2
  then ty1
  else if isUseTypeDef ty1  -- Punt and hope it's fine for now...
  then ty2
  else if isUseTypeDef ty2
  then ty1
  else if cgenIsLM (trace ("***Making variant from \n" ++ show ty1 ++ "\n" ++ show ty2) ty1)
  then  -- trace ("***Making variant from \n" ++ show ty1 ++ "\n" ++ show ty2)
        LMVariant [ty1, ty2]
  else
    let sty1 = stripCType ty1
        sty2 = stripCType ty2
    in  if sty1 == sty2
          then mkCType sty1
          else error
            ("GENVAR[\n" ++ show ty1 ++ "\n" ++ show ty2 ++ "\n]")

-------------- String utils

spc :: String -> String -> String
spc x y = x ++ " " ++ y

indent :: [String] -> [String]
indent = map ("  " ++)

makeBlock :: [String] -> [String]
makeBlock [] = []
makeBlock [line] = [line]
makeBlock lines = [ "{" ] ++ indent lines ++ [ "}" ]

-------------- State for var generator

type M = S.State Int

runM :: M a -> a
runM = flip S.evalState 0

freshCVar :: M String
freshCVar = do
  s <- S.get
  S.put (s + 1)
  return ("c$" ++ show s)

-------------------- Cgen

data AllocatorUsage = DoesNotUseAllocator | UsesAllocator | UsesAndResetsAllocator

instance Semigroup AllocatorUsage where
  (<>) = combineUsage

instance Monoid AllocatorUsage where
  mempty = DoesNotUseAllocator

combineUsage :: AllocatorUsage -> AllocatorUsage -> AllocatorUsage
combineUsage UsesAllocator _ = UsesAllocator
combineUsage _ UsesAllocator = UsesAllocator
combineUsage DoesNotUseAllocator DoesNotUseAllocator = DoesNotUseAllocator
combineUsage _ _ = UsesAndResetsAllocator

{- Note [Allocator usage of types]

The function allocatorUsageOfCType describes whether
a value of a given type may refer to allocated memory.
Or, equivalently, it describes whether making a (deep)
copy of a value requires an allocator.

Note that this ought to a property of the C++ type, not
the ks type: in general a Type may be implemented by more
than one possible CType. But currently we have

  allocatorUsageOfType ty == allocatorUsageOfCType cty

whenever cty implements the ks type ty. In future we
might want to allow these to differ, so that a ks type
which normally uses an allocator can be implemented
by a C++ type which does not require allocation.
However it should still always be the case that

  allocatorUsageOfType ty == DoesNotUseAllocator
    => allocatorUsageOfCType cty == DoesNotUseAllocator
-}

allocatorUsageOfType :: Type -> AllocatorUsage
allocatorUsageOfType = \case
  TypeBool      -> DoesNotUseAllocator
  TypeInteger   -> DoesNotUseAllocator
  TypeFloat     -> DoesNotUseAllocator
  TypeString    -> DoesNotUseAllocator
  TypeTuple ts  -> foldMap allocatorUsageOfType ts
  TypeTensor {} -> UsesAllocator
  TypeLam {}    -> UsesAllocator
  TypeLM     {} -> UsesAllocator
  TypeUnknown   -> error "Shouldn't see TypeUnknown at this stage of codegen"

allocatorUsageOfCType :: CType -> AllocatorUsage
allocatorUsageOfCType = \case
  CType  t       -> allocatorUsageOfType t
  CTuple ts      -> foldMap allocatorUsageOfCType ts
  CFunction _ _  -> UsesAllocator
  TypeDef   _ t  -> allocatorUsageOfCType t
  UseTypeDef _ t -> allocatorUsageOfType t
  LMZero _ _     -> UsesAllocator
  LMOne _        -> UsesAllocator
  LMScale  _     -> UsesAllocator
  LMScaleR _     -> UsesAllocator
  LMHCat   _     -> UsesAllocator
  LMVCat   _     -> UsesAllocator
  LMBuild  _     -> UsesAllocator
  LMCompose _ _  -> UsesAllocator
  LMAdd     _    -> UsesAllocator
  LMVariant _    -> UsesAllocator

-- CGenResult is (C declarations, C expression, CType)
-- e.g. (["ks::Float r; if (b) { r = 1; } else { r = 2; };"],
--       "r",
--       TypeFloat)
-- e.g. ([],         -- simple constant needs no pre-declaration
--       "1.0",      -- this is what we use at the occurrence
--       TypeFloat)
-- e.g. (["typedef LM::HCat<LM::VCat<LM::One, LM::Zero>,LM::Zero> v12_t;",
--        "v12_t v12 = v12_t::mk(a,b);"]
--       "v12",      -- this is what we use at the occurrence
--       LMHCat [LMVCat [LMOne, LMZero], LMZero])
data CGenResult = CG [String] CGenResultExpression CType AllocatorUsage -- TODO: rename CG CGenResult

-- The "C expression" of a CGenResult can only be "trivial".  The
-- CGenResultExpression type structurally enforces that condition.  In
-- particular, the C expression can't contain arbitrary computation.
-- If it could then we would have to be very careful not to duplicate
-- it.
--
-- On the other hand, allowing arbitrary expressions could lead to
-- nicer-looking C++ code.  For example, we could generate
--
--     g(f1(x1), f2(x2))
--
-- instead of
--
--     float fresh1 = f1(x1);
--     float fresh2 = f2(x2);
--     g(fresh1, freshf2);
--
-- Therefore if in the future we decide that we want nicer looking C++
-- then we can revisit the restriction.
data CGenResultExpression = CGREDummy CType
                          | CGREKonst Konst
                          | CGREVar Var
                          | CGRETuple [CGenResultExpression]

generateCGRE :: CGenResultExpression -> String
generateCGRE = \case
  CGREDummy cty -> cgenType cty ++ "{}"
  CGREKonst k   -> cgenKonst k
  CGREVar v     -> cgenVar v
  CGRETuple rs  -> "ks::make_Tuple("
                   ++ intercalate "," (map generateCGRE rs)
                   ++ ")"

cgreVar :: String -> CGenResultExpression
cgreVar = CGREVar . Simple

getDecl :: CGenResult -> [String]
getDecl (CG dc _ _ _) = dc

getExpr :: CGenResult -> CGenResultExpression
getExpr (CG _ ex _ _) = ex

getType :: CGenResult -> CType
getType (CG _ _ ty _) = ty

getAllocatorUsage :: CGenResult -> AllocatorUsage
getAllocatorUsage (CG _ _ _ au) = au

type CSTKey = UserFun Typed
type CST    = Map.Map CSTKey Type

cstMaybeLookupFun :: HasCallStack => CSTKey -> CST -> Maybe Type
cstMaybeLookupFun = Map.lookup

cComment :: String -> String
cComment s = "/* " ++ s ++ " */"

markAllocator :: String -> String -> String
markAllocator bumpmark allocVar = "KS_MARK(" ++ allocVar ++ ", " ++ bumpmark ++ ");"

resetAllocator :: String -> String -> String
resetAllocator bumpmark allocVar = "KS_RESET(" ++ allocVar ++ ", " ++ bumpmark ++ ");"

allocatorParameterName :: String
allocatorParameterName = "$alloc"

cgenArgList :: TFun p -> [String] -> String
cgenArgList tf cargs = intercalate ", " (allocatorIfUsed ++ cargs)
  where allocatorIfUsed = if funUsesAllocator tf
                          then [allocatorParameterName]
                          else []

cgenDefs :: [TDef] -> [String]
cgenDefs defs = concatMap cdecl $
                filter isUserDef defs
 where
  env = Map.fromList (mapMaybe (\(Def { def_fun = f
                                      , def_rhs = rhs
                                      , def_res_ty = res_ty
                                      }) ->
                                  case rhs of
                                    UserRhs _ -> Just (f, res_ty)
                                    _         -> Nothing) defs)

  cdecl def = cgenDefE env def ++ [ "" ]

{- Note [Unpack tuple arguments]

Defs of a tuple argument have their argument list unpacked,
that is, if f is a Def of type Tuple [S1, ..., SN] -> T
then the C++ function we generate for it will have N
arguments, not one tuple.

We choose N names for the argument variables and pack them into a
tuple before emitting the function body.  We ensure that the names
that we chose are not used in the function body by using ensureDon'tReuseParams.

A consequence of this translation is that we have to unpack tuples in
*calls* too.  When 'x' of type 'Tuple [S1, ..., SN]', 'Call f x' needs
to be rewritten to a C++ call like

    f(get<0>(x), ..., get<N-1>(x))

There is special case when x is a literal tuple.  In that case we take
the tuple components directly for the arguments of 'f'.  This seems to
be particularly important for avoiding a 5x slowdown.  See

    https://github.com/microsoft/knossos-ksc/pull/315

-}

params_withPackedParamsPat :: Pat -> ([TVarX], TExpr -> TExpr)
params_withPackedParamsPat (TupPat vs)    = (vs, id)
params_withPackedParamsPat (VarPat param) = params_withPackedParams param

params_withPackedParams :: TVarX -> ([TVarX], TExpr -> TExpr)
params_withPackedParams param = case typeof param of
  -- See Note [Unpack tuple arguments]
  TypeTuple tys ->
    let params  = zipWith mkParam [1..] tys
        mkParam i ty = TVar ty (Simple name)
          where name = nameOfVar (tVarVar param) ++ "arg" ++ show i
        packParams = mkLet param (Tuple (map Var params))
    in (params, Ksc.OptLet.ensureDon'tReuseParams params . packParams)
  _             -> ([param], id)

mkCTypedVar :: TVar -> String
mkCTypedVar (TVar ty var) = cgenType (mkCType ty) `spc` cgenVar var

cgenDefE :: CST -> TDef -> [String]
cgenDefE env (Def { def_fun = f, def_pat = param
                  , def_rhs = UserRhs body }) =
  let cf                         = cgenUserFun f
      (params, withPackedParams) = params_withPackedParamsPat param
      CG cbodydecl cbodyexpr cbodytype _callocusage =
        runM $ cgenExpr env (withPackedParams body)
      cbody       = cbodydecl ++ [ "return (" ++ generateCGRE cbodyexpr ++ ");" ]
      cvars       = map mkCTypedVar params
      cftypealias = "ty$" ++ cf
      cparams     = "ks::allocator * " ++ allocatorParameterName ++ concatMap (", " ++) cvars
  in (  [ "typedef " ++ cgenType cbodytype `spc` cftypealias ++ ";",
          "KS_DEF " ++ cftypealias `spc` cf ++ "(" ++ cparams ++ ") {" ]
     ++ indent cbody
     ++ [ "}" ]
     )

cgenDefE _ def = pprPanic "cgenDefE" (ppr def)
  -- Should not happen because of the 'filter isUserDef' in cgenDefs

cgenExpr :: CST -> TExpr -> M CGenResult
cgenExpr = cgenExprR

cgenExprR :: HasCallStack => CST -> TExpr -> M CGenResult
cgenExprR env e = do
  cg <- cgenExprWithoutResettingAlloc env e
  cgenWrapWithMarkReset cg

cgenWrapWithMarkReset :: HasCallStack => CGenResult -> M CGenResult
cgenWrapWithMarkReset (CG decl expr ty UsesAllocator)
  | DoesNotUseAllocator <- allocatorUsageOfCType ty = do
      bumpmark <- freshCVar
      return $ CG
        (  [ markAllocator bumpmark allocatorParameterName ]
        ++ decl
        ++ [ resetAllocator bumpmark allocatorParameterName ]
        )
        expr
        ty
        UsesAndResetsAllocator
cgenWrapWithMarkReset x = return x

cgenExprWithoutResettingAlloc :: HasCallStack => CST -> TExpr -> M CGenResult
cgenExprWithoutResettingAlloc env = \case
  Konst k -> return $ CG [] (CGREKonst k) (mkCType $ typeofKonst k) DoesNotUseAllocator
  Dummy ty ->
    let cty = mkCType ty in return $ CG [] (CGREDummy cty) cty DoesNotUseAllocator
  Var (TVar ty v)               -> return $ CG [] (CGREVar v) (mkCType ty) DoesNotUseAllocator

  -- Special case for copydown. Mark the allocator before evaluating the
  -- expression, then copydown the result to the marked position.
  Call (TFun _ (Fun JustFun (PrimFunT P_copydown))) e -> do
    CG cdecl cexpr ctype _callocusage <- cgenExprR env e
    ret <- freshCVar
    bumpmark <- freshCVar
    return $ CG
        (  [ cComment "Explicitly-requested copydown",
             markAllocator bumpmark allocatorParameterName ]
        ++ cdecl
        ++ [ cgenType ctype ++ " " ++ ret ++ " = KS_COPYDOWN(" ++ allocatorParameterName ++ ", " ++ bumpmark ++ ", (" ++ generateCGRE cexpr ++ "));" ]
        )
        (CGREVar (Simple ret))
        ctype
        (allocatorUsageOfCType ctype <> UsesAndResetsAllocator)

  -- Special case for literal tuples.  Don't unpack with std::get.
  -- Just use the tuple components as the arguments.  See Note [Unpack
  -- tuple arguments]
  Call tf (Tuple vs) -> do
    cgvs <- mapM (cgenExprR env) vs
    let cdecls = map getDecl cgvs
    let ctypes = map getType cgvs
    let callocusage = foldMap getAllocatorUsage cgvs

    let cftype = ctypeofFun env tf ctypes

    v        <- freshCVar

    let cf = cgenAnyFun tf cftype

    return $ CG
      (  concat cdecls
      ++ [ cgenType cftype ++ " " ++ v ++ " = "
                ++ cf ++ "(" ++ cgenArgList tf (map (generateCGRE . getExpr) cgvs) ++ ");" ]
      )
      (cgreVar v)
      cftype
      (funAllocatorUsage tf cftype <> callocusage)

  Call tf@(TFun _ fun) vs -> do
    cgvs <- cgenExprR env vs
    let cgargtype = typeof vs
    let cdecls = getDecl cgvs
    let ctypes = getType cgvs
    let callocusage = getAllocatorUsage cgvs

    let cftype = ctypeofFun env tf [ctypes]

    v        <- freshCVar

    let cf = cgenAnyFun tf cftype
    let cargs = case (not (isSelFun (baseFunOfFun fun)), getExpr cgvs, cgargtype) of
                  -- Untuple argument for C++ call
                  --
                  -- Calls of a tuple argument have their argument list
                  -- unpacked.  See Note [Unpack tuple arguments].
                  -- SelFuns translate to C++ get, so they don't have their
                  -- argument lists unpacked!
                  (True, cexpr, TypeTuple ts)
                    -> (flip map [0..length ts - 1] $ \i ->
                           "ks::get<" ++ show i ++ ">(" ++ generateCGRE cexpr ++ ")")
                  (_, cexpr, _) -> [generateCGRE cexpr]

    return $ CG
      (  cdecls
      ++ [  cgenType cftype ++ " " ++ v ++ " = "
              ++ cf ++ "(" ++ cgenArgList tf cargs ++ ");" ]
      )
      (cgreVar v)
      cftype
      (funAllocatorUsage tf cftype <> callocusage)

  Let pat e1 body -> do
    (CG decle1   ve1   type1  allocusagee1)   <- cgenExprR env e1
    (CG declbody vbody tybody allocusagebody) <- cgenExprR env body
    vartuple <- freshCVar

    let cgenBinder = case pat of
          VarPat v -> cgenVar (tVarVar v)
          TupPat _ -> vartuple
        cgenUntupling = case pat of
          VarPat _ -> []
          TupPat vs -> map (\(i, v) ->
            "auto " ++ cgenVar (tVarVar v) ++ " = ks::get<" ++ show i ++ ">(" ++ vartuple ++ ");"
            ) (zip [0..] vs)

    return $ CG
      (  decle1
      ++ [ cgenType type1 ++ " " ++ cgenBinder ++ " = " ++ generateCGRE ve1 ++ ";" ]
      ++ cgenUntupling
      ++ declbody
      )
      vbody
      tybody
      (allocusagee1 <> allocusagebody)

  Tuple vs  -> do
    cgvs <- mapM (cgenExprR env) vs
    let cdecls = map getDecl cgvs
    let cexprs = map getExpr cgvs
    let ctypes = map getType cgvs
    let callocusage = foldMap getAllocatorUsage cgvs
    let ctype  = CTuple ctypes

    return $ CG (concat cdecls)
                (CGRETuple cexprs)
                ctype
                callocusage

  Lam param@(TVar tyv _) body -> do
    lvar <- freshCVar
    let vtype = mkCType tyv
        (params, withPackedParams) = params_withPackedParams param
    (CG cdecl cexpr ctype _callocusage) <- cgenExprR env (withPackedParams body)
    return $ CG
      (  [ cComment "Lam" ++ "auto" `spc` lvar ++ " = [=](" -- TODO: capture only freeVars here
              ++ "ks::allocator * " ++ allocatorParameterName
              ++ concatMap ((", " ++) . mkCTypedVar) params
              ++ ") {" ]
      ++ indent (  cdecl
                ++ [ "return (" ++ generateCGRE cexpr ++ ");" ]
                )
      ++ [ "};" ]
      )
      (cgreVar lvar)
      (CFunction vtype ctype)
      DoesNotUseAllocator


  If c texpr fexpr -> do
    cret              <- freshCVar

    (CG declc vc _   auc) <- cgenExprR env c
    (CG declt vt tyt aut) <- cgenExprR env texpr
    (CG declf vf tyf auf) <- cgenExprR env fexpr
    let crettype = makeUnionType tyt tyf
    let dotv = case crettype of
          LMVariant _ -> ".v"  -- TODO: Ugh. Fix c++ to not require this.
          _           -> "" -- Ugh.

    return $ CG
      (  declc -- emit condition generation
      ++ [ cgenType crettype `spc` cret ++ ";", -- emit decl for "return" type
           "if (" ++ generateCGRE vc ++ ") {" ]
      ++ indent (  declt  -- compute true value
                ++ [ cret ++ dotv ++ " = (" ++ generateCGRE vt ++ ");" ]) -- assign to "return"
      ++ [ "} else {" ]
      ++ indent (  declf  -- compute false value
                ++ [ cret ++ dotv ++ " = (" ++ generateCGRE vf ++ ");" ]) -- assign to "return"
      ++ [ "}" ]
      )
      (cgreVar cret)
      crettype
      (auc <> aut <> auf)

  Assert cond body -> do
    (CG declcond vcond tycond aucond) <- cgenExprR env cond
    case tycond of CType TypeBool -> return ()
                   UseTypeDef _ TypeBool -> return ()
                   unexpected -> error ("tycond was: " ++ show unexpected)
    (CG declbody vbody tybody aubody) <- cgenExprR env body
    return $ CG (  makeBlock (  declcond
                             ++ [ "KS_ASSERT(" ++ generateCGRE vcond ++ ");" ]
                             )
                ++ declbody
                )
                vbody
                tybody
                (aucond <> aubody)

  App{} -> error "App"

substitute :: (a -> Maybe [a]) -> [a] -> [a]
substitute f = concatMap (\x -> case f x of Nothing -> [x]; Just s -> s)

mangleFun :: String -> String
mangleFun = substitute $ \case
    '@' -> Just "$a"
    ',' -> Just "$_"
    '[' -> Just "$6"
    ']' -> Just "$9"
    '<' -> Just "$d"
    '>' -> Just "$b"
    '*' -> Just "$x"
    ':' -> Just "$8"
    _   -> Nothing

-- | Produces a short string that uniquely identifies the input type.
--
-- This is used to prevent name clashes between generated functions in
-- the backend. When we emit names to C/C++ we want to ensure unique
-- names for each signature.  This is required in C, and desirable in
-- C++, as otherwise delicate interactions with C++ overloading rules
-- will impose a maintenance burden.  This function generates a string
-- encoding of a type that is C-compatible, and guaranteed 1-1.
mangleType :: TypeX -> String
mangleType = \case
    TypeBool      -> "b"
    TypeInteger   -> "i"
    TypeFloat     -> "f"
    TypeString    -> "s"
    TypeTuple tys -> "<" ++ concatMap mangleType tys ++ ">"
    TypeTensor d ty -> "T" ++ show d ++ mangleType ty
    TypeLam a b   -> "l<" ++ mangleType a ++ mangleType b ++ ">"
    TypeLM _ _    -> error "Can't mangle TypeLM"
    TypeUnknown   -> error "Can't mangle TypeUnknown"

cgenBaseUserFun :: BaseUserFun Typed -> String
cgenBaseUserFun = \case
  (BaseFunId fun (TypeTuple []))  -> mangleFun fun
  (BaseFunId fun (TypeTuple tys)) -> mangleFun (fun ++ "@" ++ concatMap mangleType tys)
  (BaseFunId fun ty)  -> mangleFun (fun ++ "@" ++ mangleType ty)

cgenBasePrimFun :: BasePrimFun Typed -> String
cgenBasePrimFun = \case
  (BaseFunId (P_SelFun i _) _)  -> "ks::get<" ++ show (i - 1) ++ ">"
  (BaseFunId fun _) -> render (ppr fun)

cgenUserFun :: HasCallStack => UserFun Typed -> String
cgenUserFun = cgenFun cgenBaseUserFun

cgenPrimFun :: HasCallStack => DerivedFun PrimFun Typed -> String
cgenPrimFun = cgenFun cgenBasePrimFun

cgenFun :: HasCallStack
        => (BaseFunId name Typed -> String) -> DerivedFun name Typed -> String
cgenFun cgenBaseFun f = case f of
  Fun JustFun baseFun   -> cgenBaseFun baseFun
  Fun GradFun{}  s  -> "D$" ++ cgenBaseFun s
  Fun (DrvFun Fwd) s -> "fwd$" ++ cgenBaseFun s
  Fun (DrvFun Rev) s -> "rev$" ++ cgenBaseFun s
  Fun (ShapeFun ds) ff   -> "shape$" ++ cgenFun cgenBaseFun (Fun ds ff)
  Fun CLFun s       -> "CL$" ++ cgenBaseFun s
  Fun SUFFwdPass s  -> "suffwdpass$" ++ cgenBaseFun s
  Fun SUFRevPass s  -> "sufrevpass$" ++ cgenBaseFun s
  Fun SUFRev   s    -> "sufrev$" ++ cgenBaseFun s

cgenAnyFun :: HasCallStack => TFun Typed -> CType -> String
cgenAnyFun tf cftype = case tf of
  TFun _ (Fun JustFun (PrimFunT P_lmApply)) -> "lmApply"
  TFun retty (Fun JustFun (PrimFunT P_build)) ->
    case retty of
      TypeTensor _ t -> "build<" ++ cgenType (mkCType t) ++ ">"
      _              -> error ("Unexpected return type for build: " ++ show retty)
  TFun retty (Fun JustFun (PrimFunT primname))
    | primname `elem` [P_sumbuild, P_buildFromSparse, P_buildFromSparseTupled]
    -> render (ppr primname) ++ "<" ++ cgenType (mkCType retty) ++ ">"
  -- This is one of the LM subtypes, e.g. HCat<...>  Name is just HCat<...>::mk
  TFun (TypeLM _ _) (Fun JustFun (PrimFunT _)) -> cgenType cftype ++ "::mk"
  TFun _            f -> case perhapsUserFun f of
    Left primFun  -> cgenPrimFun primFun
    Right userFun -> cgenUserFun userFun

{- Note [Allocator usage of function calls]

Every function takes an allocator as its first argument, with the
exception of a few special primitive functions.

The caller of a function does not know whether the allocator
argument will actually be used inside the function. But we can
make some assumptions based on the function return type. There
are two cases:

 1. If the return value may refer to allocated memory
    (allocatorUsageOfCType returns UsesAllocator):
    In this case we have to assume that the allocator will
    be used by the function.

 2. If the return value cannot refer to allocated memory
    (allocatorUsageOfCType returns DoesNotUseAllocator):
    In this case our calling convention is that, if the
    function does use the allocator, then it must reset
    the allocator to its initial position before returning.
    So in this case we know that the allocator usage of
    the function is UsesAndResetsAllocator.
    (Note: the usage can never be DoesNotUseAllocator because
    the allocator argument is still passed to the function.)
-}

funUsesAllocator :: HasCallStack => TFun p -> Bool
funUsesAllocator (TFun _ (Fun JustFun (PrimFunT (P_SelFun _ _)))) = False
funUsesAllocator (TFun _ (Fun JustFun (PrimFunT fname))) =
  not $ fname `elem` [P_index, P_size, P_eq, P_ne, P_trace, P_print, P_ts_dot]
funUsesAllocator _ = True

funAllocatorUsage :: HasCallStack => TFun p -> CType -> AllocatorUsage
funAllocatorUsage tf ty
  -- See Note [Allocator usage of function calls]
  | not $ funUsesAllocator tf = DoesNotUseAllocator
  | otherwise = allocatorUsageOfCType ty <> UsesAndResetsAllocator

cgenType :: HasCallStack => CType -> String
cgenType = \case
  CType  ty -> cgenTypeLang ty
  CTuple ts -> "ks::Tuple<" ++ intercalate "," (map cgenType ts) ++ ">"
  CFunction s t ->
    "std::function<" ++ cgenType t ++ "(" ++ cgenType s ++ ")>"
  TypeDef s _     -> s
  UseTypeDef s _  -> s
  LMZero s t      -> lmt "Zero" [s, t]
  LMOne t         -> lmt "One" [t]
  LMScale t       -> lmt "Scale" [t]
  LMScaleR t      -> lmt "ScaleR" [t]
  LMHCat   ts     -> lm "HCat" ts
  LMVCat   ts     -> lm "VCat" ts
  LMBuild  t      -> lm "Build" [t]
  LMCompose m1 m2 -> lm "Compose" [m1, m2]
  LMAdd     ms    -> lm "Add" ms
  LMVariant ts    -> lm "Variant" ts
 where
  lm s ts = "LM::" ++ s ++ "<" ++ intercalate "," (map cgenType ts) ++ ">"
  lmt s ts = "LM::" ++ s ++ "<" ++ intercalate "," (map cgenTypeLang ts) ++ ">"

cgenTypeLang :: HasCallStack => Type -> String
cgenTypeLang = \case
  TypeFloat      -> "ks::Float"
  TypeInteger    -> "ks::Integer"
  TypeString     -> "ks::String"
  TypeTuple ts   -> "ks::Tuple<" ++ intercalate "," (map cgenTypeLang ts) ++ ">"
  TypeTensor d t -> "ks::tensor<" ++ show d ++ ", " ++ cgenTypeLang t ++ ">"
  TypeBool       -> "ks::Bool"
  TypeUnknown    -> "void"
  TypeLam from to ->
    "std::function<" ++ cgenTypeLang to ++ "(" ++ cgenTypeLang from ++ ")>"
  TypeLM s t -> error $ "LM<" ++ cgenTypeLang s ++ "," ++ cgenTypeLang t ++ ">"

ctypeofFun :: HasCallStack => CST -> TFun Typed -> [CType] -> CType
ctypeofFun env (TFun ty f) ctys
  | Just f' <- maybeUserFun f
  , Just ret_ty <- cstMaybeLookupFun f' env
    -- trace ("Found fun " ++ show f) $
  = UseTypeDef ("ty$" ++ cgenUserFun f') ret_ty
  | otherwise
  = -- trace ("Did not find fun " ++ show tf ++ " in\n     " ++ show env) $
    ctypeofFun1 ty f ctys

ctypeofFun1 :: HasCallStack => Type -> Fun Typed -> [CType] -> CType
ctypeofFun1 ty (Fun JustFun (PrimFunT name)) ctys = ctypeofPrimFun ty name ctys
ctypeofFun1 (TypeLM _ _) (Fun GradFun{} f) ctys = ctypeofGradBuiltin f ctys
ctypeofFun1 (TypeLM _ _) f ctys =
  error $ "Did not match [" ++ show f ++ "]@\n  " ++ intercalate
    "\n  "
    (map show ctys)
ctypeofFun1 ty _ _ = mkCType ty

ctypeofPrimFun :: HasCallStack => Type -> PrimFun -> [CType] -> CType
ctypeofPrimFun ty s arg_types = case (s, map stripTypeDef arg_types) of
  (P_lmApply  , _         ) -> mkCType ty
  -- TODO: lmApplyR?
  (P_lmOne    , [ct]      ) -> LMOne (stripCType ct)
  (P_lmZero   , [cs, ct]  ) -> LMZero (stripCType cs) (stripCType ct)
  (P_lmScale  , [ct, CType TypeFloat]) -> LMScale (stripCType ct)
  (P_lmScaleR , [ct]      ) -> LMScaleR (stripCType ct)
  (P_lmHCat   , _         ) -> LMHCat arg_types
  (P_lmVCat   , _         ) -> LMVCat arg_types
  (P_lmCompose, [lm1, lm2]) -> LMCompose lm1 lm2
  (P_lmAdd    , _         ) -> LMAdd arg_types
  (P_lmVariant, _         ) -> LMVariant arg_types
  _                         -> case ty of
    TypeLM _ _ -> error
      (  "Unmatched prim ["
      ++ render (ppr s)
      ++ "] "
      ++ show ty
      ++ " @\n"
      ++ "  "
      ++ intercalate "\n  " (map show arg_types)
      )
    _ -> mkCType ty

pattern RR :: TypeX
pattern RR = TypeFloat

ctypeofGradBuiltin :: HasCallStack => BaseFun Typed -> [CType] -> CType
ctypeofGradBuiltin f ctys = case (f, map stripTypeDef ctys) of
  (PrimFunT P_ts_add   , [CType RR, CType RR]) -> LMHCat [LMScale RR, LMScale RR]
  (PrimFunT P_trace    , [CType ty]          ) -> LMOne ty
  (PrimFunT P_copydown , [CType ty]          ) -> LMOne ty
  (PrimFunT P_size     , [CType ty@(TypeTensor d _)]) -> LMZero ty (tensorIndexType d)
  _ -> error $ "Don't know grad of [" ++ show f ++ "]@\n  " ++ intercalate
    "\n  "
    (map (show . stripTypeDef) ctys)

cgenKonst :: Konst -> String
cgenKonst = \case
  KInteger i -> show i
  KFloat   f -> "Float(" ++ show f ++ ")"
  KString  s -> show s
  KBool    b -> if b then "true" else "false"

cgenVar :: Var -> String
cgenVar = render . ppr

makeDirectoryForFile :: FilePath -> IO ()
makeDirectoryForFile =
  System.Directory.createDirectoryIfMissing True
  . fst
  . System.FilePath.splitFileName

createDirectoryWriteFile :: FilePath -> String -> IO ()
createDirectoryWriteFile filepath contents = do
  makeDirectoryForFile filepath
  writeFile filepath contents

cppGen :: [String] -> [TDef] -> String
cppGen includefiles defs =
  let includes = map (\h -> "#include \"" ++ h ++ "\"") ("knossos.h":includefiles)
      head =
        [ ""
        , "namespace ks {"
        , ""
        ]
      lls   = cgenDefs defs
      tail =
        [ "}"
        , "#include \"knossos.cpp\""
        ]
      call_main =
        [ "int main() {"
        , "  ks::allocator alloc{ 1'000'000'000 };"
        , "  ks::main(&alloc);"
        , "  return 0;"
        , "}"
        ]
      call_main_if_present = if any isMainFunction defs then call_main else []

  in unlines (includes ++ head ++ lls ++ tail ++ call_main_if_present)

isMainFunction :: TDef -> Bool
isMainFunction Def{ def_fun = Fun JustFun f, def_res_ty = TypeInteger }
  | BaseFunId "main" (TypeTuple []) <- f = True
isMainFunction _ = False

ksoGen :: [TDef] -> String
ksoGen = unlines . map (renderSexp . ppr)

cppGenWithFiles :: String -> String -> [String] -> [TDef] -> IO (String, String)
cppGenWithFiles ksofile cppfile cppincludefiles defs = do
  let cppcontents = cppGen cppincludefiles defs
      ksocontents = ksoGen defs

  putStrLn $ "ksc: Writing to " ++ ksofile
  createDirectoryWriteFile ksofile ksocontents

  putStrLn $ "ksc: Writing to " ++ cppfile
  createDirectoryWriteFile cppfile cppcontents

  pure (cppcontents, ksocontents)

compile :: String -> String -> String -> IO String
compile = compileWithOpts []

compileWithProfiling :: String -> String -> String -> IO String
compileWithProfiling =
  compileWithOpts ["-Wl,--no-as-needed,-lprofiler,--as-needed"]

compileWithOpts :: [String] -> String -> String -> String -> IO String
compileWithOpts opts compilername cppfile exefile = do
  let compcmd =
        ( compilername
        , [ "-fmax-errors=5"
          , "-fdiagnostics-color=always"
          , "-Wall"
          , "-Wno-unused"
          , "-Wno-maybe-uninitialized"
          , "-Isrc/runtime"
          , "-O3"
          , "-g"
          , "-std=c++17"
          , "-o"
          , exefile
          ]
          ++ opts
          ++ [cppfile]
        )
  makeDirectoryForFile exefile
  putStrLn $ "ksc: Compiling: " ++ fst compcmd ++ " " ++ unwords (snd compcmd)
  uncurry readProcessPrintStderr compcmd
  return exefile

runExe :: String -> IO String
runExe exefile = do
  putStrLn "ksc: Running"
  readProcessPrintStderr exefile []

readProcessEnv
  :: FilePath -> [String] -> Maybe [(String, String)] -> IO (ExitCode, String, String)
readProcessEnv executable args env = do
  let stdin = ""
  System.Process.readCreateProcessWithExitCode
    (System.Process.proc executable args) { System.Process.env = env }
    stdin

readProcessEnvPrintStderr
  :: FilePath -> [String] -> Maybe [(String, String)] -> IO String
readProcessEnvPrintStderr executable args env = do
  (exitCode, stdout, stderr) <- readProcessEnv executable args env
  putStr stderr
  when (exitCode /= ExitSuccess) $ error "Compilation failed"
  return stdout

readProcessPrintStderrOnFail
  :: FilePath -> [String] -> IO String
readProcessPrintStderrOnFail executable args = do
  (exitCode, stdout, stderr) <- readProcessEnv executable args Nothing
  when (exitCode /= ExitSuccess) $ do
    putStr stderr
    error "Compilation failed"
  return stdout

readProcessPrintStderr :: FilePath -> [String] -> IO String
readProcessPrintStderr executable args =
  readProcessEnvPrintStderr executable args Nothing
