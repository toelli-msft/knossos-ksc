{-# OPTIONS_GHC -fwarn-name-shadowing #-}
{-# OPTIONS_GHC -fmax-pmcheck-iterations=10000000 #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}

module Ksc.LinearAD where

import qualified Annotate                      as A
import           Parse                          ( parseF )
import qualified Prim
import           KMonad                         ( runKM
                                                , banner
                                                , KM
                                                )
import           Lang                           ( displayN
                                                , Decl
                                                )
import qualified Lang                          as L
import qualified LangUtils                     as LU
--import qualified Opt as O
import qualified Rules
import qualified ANF                           as A

import           Control.Category               ( (>>>) )
import           Data.Maybe                     ( mapMaybe )
import           Data.Set                       ( Set, (\\), union, toList )

demoF :: String -> IO ()
demoF file = do
  defs <- parseF file
  runKM (demoN defs)

demoN :: [Decl] -> KM ()
demoN decls = do
  banner "Original declarations"
  displayN decls

  (env, tc_decls) <- A.annotDecls LU.emptyGblST decls
  let (rules, defs) = L.partitionDecls tc_decls
      _rulebase     = Rules.mkRuleBase rules

  anf_defs <- A.anfDefs defs
  disp "Anf-ised original definition" env anf_defs

  let linear_defs = map lineariseD anf_defs
  disp "Linear original definition" env linear_defs

  let diff_defs = mapMaybe differentiateD linear_defs
  disp "Derivative" env diff_defs

disp :: String -> LU.GblSymTab -> [L.TDef] -> KM ()
disp what env decls = do
  banner what
  displayN decls
  A.lintDefs what env decls

lineariseD :: L.TDef -> L.TDef
lineariseD tdef@(L.Def { L.def_rhs = L.UserRhs rhs }) = L.Def
  { L.def_fun    = L.def_fun tdef
  , L.def_args   = L.def_args tdef
  , L.def_res_ty = L.def_res_ty tdef
  , L.def_rhs    = L.UserRhs (lineariseAndRemoveUnused rhs)
  }
  where elimUnusedArgs body =
          flip applyAll body
          $ flip map (L.def_args tdef)
          $ \arg ->
              if arg `LU.notFreeIn` body
              then L.Elim arg
              else id
        applyAll = foldr (.) id

        lineariseAndRemoveUnused =
          verySlowlyRemoveUnusedLets . elimUnusedArgs . lineariseE

lineariseD d@(L.Def { L.def_rhs = L.EDefRhs{} }) = d
lineariseD (L.Def { L.def_rhs = L.StubRhs{} }) =
  error "Didn't expect to see a StubRhs at this stage"

lineariseE :: L.TExpr -> L.TExpr
lineariseE = \case
  L.Let v rhs body -> case rhs of
    L.Call f args -> dups' (L.Let v (L.Call f new_args) (lineariseE body))
     where
      dups = flip map args $ \case
        L.Var argv -> if argv `LU.notFreeIn` body
          then (id, L.Var argv)
          else
            let argv' = renameTVar argv (++ "$1")
            in  (L.Dup (argv, argv') argv, L.Var argv')
        lam@(L.Lam{}) -> if any (f `Prim.isThePrimFun`) ["build", "forRange"]
          then (id, lam)
          else error "Didn't expect to see lam in Anf form"
        arg -> error ("Unexpected in Anf form " ++ L.render (L.ppr arg))
      dups' :: L.TExpr -> L.TExpr
      new_args :: [L.TExpr]
      (dups', new_args) =
        foldr (\(g, a) (gs, as) -> (g . gs, a : as)) (id, []) dups

    a@(L.Konst{}) -> L.Let v a (lineariseE body)
    a@(L.Var{}  ) -> L.Let v a (lineariseE body)
    a@(L.Tuple{}) -> L.Let v a (lineariseE body)
    -- I can't be bothered to deal with assert so I'm just going to
    -- remove it
    L.Assert cond assertbody -> case cond of
      vv@(L.Var{}) ->
        L.Let v (L.Assert vv (lineariseE assertbody)) (lineariseE body)
      o -> error ("lineariseE Let Assert unexpected " ++ show o)
    -- This is probably quite broken.  We need to be sure that both
    -- branches consume the same variables, otherwise we'll have
    -- problems.
    L.If cond true false -> case cond of
      vv@(L.Var{}) ->
        L.Let v (L.If vv
                      (elim (notIn inTrue) (lineariseE true))
                      (elim (notIn inFals) (lineariseE false))
                ) (lineariseE body)

        where
          elim :: Set L.TVar -> L.TExpr -> L.TExpr
          elim s t = foldr L.Elim t (toList s)

          inTrue :: Set L.TVar
          inTrue = LU.freeVarsOf true

          inFals :: Set L.TVar
          inFals = LU.freeVarsOf false

          inEither :: Set L.TVar
          inEither = inTrue `union` inFals

          notIn :: Set L.TVar -> Set L.TVar
          notIn = (inEither \\)

      o -> error ("lineariseE Let If unexpected " ++ show o)
    o -> error ("lineariseE Let unexpected " ++ show o)
  var@(L.Var{})       -> var
  L.Untuple vs r body -> L.Untuple vs r (lineariseE body)
  v                   -> error ("lineariseE unexpected " ++ show v)

differentiateD :: L.TDef -> Maybe L.TDef
differentiateD tdef@(L.Def { L.def_fun = L.Fun (L.UserFun f), L.def_rhs = L.UserRhs rhs })
  = Just
    (L.Def { L.def_fun    = L.LinearGradFun (L.UserFun f)
           , L.def_args   = args ++ [rev r]
           , L.def_res_ty = res_ty
           , L.def_rhs    = L.UserRhs d_rhs
           }
    )
 where
  (fwd, r, trace, rev') = differentiateE rhs
  d_rhs = (fwd . rev' trace . L.Tuple) (L.Var r : map (L.Var . rev) args)
  args                  = L.def_args tdef
  res_ty                =
    L.TypeTuple (L.def_res_ty tdef : map (L.tangentType . L.typeof) args)
differentiateD (L.Def { L.def_fun = L.Fun (L.PrimFun f) }) = error
  (  "Wasn't expecting to be asked to differentiate a PrimFun: "
  ++ L.render (L.ppr f)
  )
differentiateD (L.Def { L.def_fun = L.Fun (L.SelFun{}) }) =
  error "Wasn't expecting to be asked to differentiate a SelFun"
differentiateD (L.Def { L.def_rhs = L.StubRhs }) =
  error "Did not expect to see StubRhs"
-- Some things we don't expect to have to differentiate
differentiateD L.Def { L.def_rhs = L.EDefRhs }         = Nothing
differentiateD L.Def { L.def_fun = L.GradFun{} }       = Nothing
differentiateD L.Def { L.def_fun = L.DrvFun{} }        = Nothing
differentiateD L.Def { L.def_fun = L.LinearGradFun{} } = Nothing

differentiateE
  :: L.TExpr
  -> (L.TExpr -> L.TExpr, L.TVar, [[L.TVar]], [[L.TVar]] -> L.TExpr -> L.TExpr)
differentiateE = \case
  L.Dup (v1, v2) vv body ->
    ( L.Dup (v1, v2) vv . body'
    , r
    , xs
    , \xs' -> f xs' . L.Let (rev vv) (revVar v1 .+ revVar v2)
    )
    where (body', r, xs, f) = differentiateE body
  L.Elim a body -> differentiateComponent body
    ( id
    , []
    , \([]:xs) -> (xs, let ra = rev a
                           t  = L.typeof ra
                       in L.Let ra (Prim.mkZero t))
    )
  L.Let r rhs body -> case rhs of
    call@(L.Call (L.TFun _ (L.Fun (L.PrimFun op))) [L.Var a1, L.Var a2]) ->
      case op of
        "add" -> g
          ( L.Let r (v a1 .+ v a2)
          , []
          , \([]:xs') -> (xs', L.Let (rev a1) (revVar r)
                               . L.Let (rev a2) (revVar r))
          )
        "sub" -> g
          ( L.Let r (v a1 .- v a2)
          , []
          , \([]:xs') -> (xs', L.Let (rev a1) (revVar r)
                               . L.Let (rev a2) (Prim.pNeg (revVar r)))
          )
        "mul" -> g
          ( L.Let r (v a1 .* v a2)
          , [a1, a2]
          , \([a1_, a2_] : xs') ->
            ( xs'
            , L.Let (rev a1) (revVar r .* v a2_)
              . L.Let (rev a2) (revVar r .* v a1_)
            )
          )
        "div" -> g
          ( L.Let r (v a1 ./ v a2)
          , [a1, a2]
          , \([a1_, a2_] : xs') ->
            ( xs'
            , L.Let (rev a1) (revVar r ./ v a2_)
              . L.Let
                  (rev a2)
                  (Prim.pNeg ((v a1_ .* revVar r) ./ (v a2_ .* v a2_)))
            )
          )
        "eq" -> temporaryDummy
        "gt" -> g
          ( L.Let r call
          , []
          , (\([]:xs') -> (xs', let ra1 = rev a1
                                    ra2 = rev a2
                                    t1  = L.typeof ra1
                                    t2  = L.typeof ra2
                                in L.Let ra1 (Prim.mkZero t1)
                                   . L.Let ra2 (Prim.mkZero t2)))
          )
        "indexL" -> g
          ( L.Let r call
          , [a1]
          , (\([i]:xs') ->
               (xs', L.Let (rev a1) (L.Tuple [])
                     . L.Let (rev a2) (Prim.pIncAt
                                        (v i)
                                        (Prim.pSel 1 2 (revVar r))
                                        (Prim.pSel 2 2 (revVar r)))
               ))
          )
        s -> error ("differentiateE unexpected PrimFun: " ++ s)
    k@(L.Konst{}) -> g (L.Let r k, [], \([]:xs') -> (xs', id))
    L.Var vv ->
      g (L.Let r (v vv), [], \([]:xs') -> (xs', L.Let (rev vv) (revVar r)))
    call@(L.Call f args)
      | f `Prim.isThePrimFun` "build"
      , [L.Var _n, _lambda] <- args
        -> temporaryDummy
      | f `Prim.isThePrimFun` "sum"
      , [L.Var{}] <- args
        -> temporaryDummy
      | f `Prim.isThePrimFun` "forRange"
      -> g (differentiateForRange r args)
      | f `Prim.isThePrimFun` "eq"
      , [L.Var{}, L.Var{}] <- args
        -> temporaryDummy
      | f `Prim.isThePrimFun` "log"
      , [L.Var a] <- args
        -> g
        ( L.Let r call
        , [a]
        , \([a_]:xs') -> (xs', L.Let (rev a) (revVar r ./ v a_))
        )
      | f `Prim.isThePrimFun` "exp"
      , [L.Var a] <- args
        -> g
        ( L.Let r call
        , [a]
        -- Could share this exp
        , \([a_]:xs') -> (xs', L.Let (rev a) (revVar r .* Prim.pExp (v a_)))
        )
      | f `Prim.isThePrimFun` "to_float"
      , [L.Var{}] <- args
        -> temporaryDummy
      | f `Prim.isThePrimFun` "$ranhashdoub"
      , [L.Var{}] <- args
        -> temporaryDummy
      | L.TFun _ (L.Fun (L.UserFun{})) <- f
        -> temporaryDummy
      | L.TFun _ (L.Fun (L.SelFun i _)) <- f
      , [L.Var t] <- args
      , L.TypeTuple types <- L.typeof t
        -> g
        ( L.Let r call
        , []
        , \([]:xs) -> (xs, L.Let (rev t)
                           $ L.Tuple
                           $ flip map (zip [1..] types)
                           $ \(j, type_) ->
                               if i == j
                               then revVar r
                               else Prim.mkZero type_
                      )
        )

    L.Assert _cond _assertBody -> temporaryDummy
    L.If (L.Var cond) true fals -> g (differentiateIf r cond true fals)
    L.Tuple es -> g
      ( L.Let r (L.Tuple es)
      , []
      , \([]:xs) -> (xs, L.Untuple (map rev (unVar es)) (revVar r))
      )
      where unVar = \case
              [] -> []
              L.Var x:xs -> x:unVar xs
              _:_ -> error "differentiateE: Expected variable in Tuple"
    _ -> error ("Couldn't differentiate rhs: " ++ show rhs)
   where
    g = differentiateComponent body
    temporaryDummy = g (id,
              [],
              \([]:xs') -> (xs', id))


  L.Var vv -> (id, vv, [], \[] -> id)
  L.Untuple rs uv body -> case uv of
    L.Var vv -> differentiateComponent body
      ( L.Untuple rs uv
      , []
      , \([]:xs) -> (xs, L.Let (rev vv) (L.Tuple (map revVar rs)))
      )
    _        -> error ("Couldn't differentiate untuple rhs: " ++ show uv)
  s -> error ("Couldn't differentiate: " ++ show s)
 where
  (.*) = Prim.pMul
  (./) = Prim.pDiv
  (.+) = Prim.pAdd
  (.-) = Prim.pSub
  v    = L.Var

differentiateComponent
   :: L.TExpr
   -> (L.TExpr -> c, [L.TVar], p -> ([[L.TVar]], a -> L.TExpr))
   -> (L.TExpr -> c, L.TVar, [[L.TVar]], p -> a -> L.TExpr)
differentiateComponent body (myFwd, myTrace, fromTrace) =
      ( myFwd . theirFwd
      , final
      , myTrace:theirTrace
      , \fullTrace ->
        let (theirTrace_, myRev) = fromTrace fullTrace
        in  theirRev theirTrace_ . myRev
      )
      where (theirFwd, final, theirTrace, theirRev) = differentiateE body

differentiateIf
  :: L.TVar
  -> L.TVar
  -> L.TExpr
  -> L.TExpr
  -> (L.TExpr -> L.TExpr, [L.TVar],
       [[L.TVar]] -> ([[L.TVar]], L.TExpr -> L.TExpr))
differentiateIf r cond true fals =
      ( L.Let rtf (L.If (L.Var cond) trueFwd' falsFwd')
        . L.Let r (Prim.pSel 1 2 (v rtf))
        . L.Let tf (Prim.pSel 2 2 (v rtf))
      , [cond, tf]
      , \([cond_,tf_]:xs') ->
          (xs', untupleEverythingInScope
            (L.If (v cond_)
              (L.Let (rev trueR) (revVar r)
               $ untupleTrace (Prim.pSel 1 2 (v tf_)) trueTraceRevVars
               $ trueRev trueTraceRevVars
               $ tupleEverythingInScope)
              (L.Let (rev falsR) (revVar r)
               $ untupleTrace (Prim.pSel 2 2 (v tf_)) falsTraceRevVars
               $ falsRev falsTraceRevVars
               $ tupleEverythingInScope)
            )
          )
      )
      where (trueFwd, trueR, trueTrace, trueRev) = differentiateE true
            (falsFwd, falsR, falsTrace, falsRev) = differentiateE fals

            trueTraceFlat :: [L.TVar]
            trueTraceFlat = concat trueTrace

            falsTraceFlat :: [L.TVar]
            falsTraceFlat = concat falsTrace

            traceRevVars :: [[L.TVar]] -> [[L.TVar]]
            traceRevVars = (map . map) (flip renameTVar (++ "$rt"))

            trueTraceRevVars :: [[L.TVar]]
            trueTraceRevVars = traceRevVars trueTrace

            falsTraceRevVars :: [[L.TVar]]
            falsTraceRevVars = traceRevVars falsTrace

            untupleTrace :: L.TExpr -> [[L.TVar]] -> L.TExpr -> L.TExpr
            untupleTrace traceVar traceRevVars' =
              L.Untuple (concat traceRevVars') traceVar

            rtf :: L.TVar
            rtf = if trueT == falsT
                  then makeVarNameFrom r trueT "rtf"
                  else error "trueT /= falsT"
              where trueT = L.typeof trueFwd'
                    falsT = L.typeof falsFwd'

            trueFwd' :: L.TExpr
            trueFwd' = trueFwd (L.Tuple [L.Var trueR, onlyTrueTrace])

            falsFwd' :: L.TExpr
            falsFwd' = falsFwd (L.Tuple [L.Var falsR, onlyFalsTrace])

            tf :: L.TVar
            tf = if trueTraceT == falsTraceT
                 then makeVarNameFrom r trueTraceT "tf"
                 else error "trueTraceT /= falsTraceT"
              where trueTraceT = L.typeof onlyTrueTrace
                    falsTraceT = L.typeof onlyFalsTrace

            -- Really these should be put in a sum type but we don't
            -- have those at the moment
            onlyTrueTrace =
              L.Tuple [ L.Tuple (map L.Var trueTraceFlat)
                      , L.Tuple (map (Prim.mkZero . L.typeof) falsTraceFlat) ]
            onlyFalsTrace =
              L.Tuple [ L.Tuple (map (Prim.mkZero . L.typeof) trueTraceFlat)
                      , L.Tuple (map L.Var falsTraceFlat) ]

            untupleEverythingInScope :: L.TExpr -> L.TExpr -> L.TExpr
            untupleEverythingInScope = L.Untuple (map rev (toList inEither))

            tupleEverythingInScope :: L.TExpr
            tupleEverythingInScope = L.Tuple (map revVar (toList inEither))

            inEither :: Set L.TVar
            inEither = LU.freeVarsOf true `union` LU.freeVarsOf fals

            v = L.Var

differentiateForRange
  :: L.TVar
  -> [L.TExpr]
  -> (L.TExpr -> L.TExpr,
      [L.TVar],
      [[L.TVar]] -> ([[L.TVar]], L.TExpr -> L.TExpr))
differentiateForRange r args =
        let [L.Var n, L.Var s, L.Lam i_s loopbody] = args
            L.TypeTuple [_, typestate] = L.typeof i_s

            v = L.Var

            traceVec :: L.TExpr
            traceVec = Prim.pNewVec traceT (v n)

            i_v_s :: L.TVar
            i_v_s = unhygenicVarFIXME
                        (L.TypeTuple [ L.TypeInteger
                                     , L.TypeTuple [L.typeof vv, typestate]])
                        "i_v_s"

            unhygenicVarFIXME :: L.Type -> String -> L.TVar
            unhygenicVarFIXME t = L.TVar t . L.Simple

            v_s :: L.TVar
            v_s = unhygenicVarFIXME (L.TypeTuple [L.typeof vv, typestate]) "v_s"

            i :: L.TVar
            i = unhygenicVarFIXME L.TypeInteger "i"

            vv :: L.TVar
            vv = unhygenicVarFIXME (L.TypeVec (v n) (L.typeof tracef)) "vv"

            vv' :: L.TVar
            vv' = unhygenicVarFIXME (L.TypeVec (v n) (L.typeof tracef)) "vv_"

            traceT :: L.Type
            traceT = L.typeof tracef

            tracefVar :: L.TVar
            tracefVar = unhygenicVarFIXME (L.typeof tracef) "tracefVar"

            tracef :: L.TExpr
            tracef = (map (map L.Var >>> tuple) >>> tuple) tracefvarss

            makeTraceFVars :: L.TExpr -> L.TExpr -> L.TExpr
            makeTraceFVars tr =
              let (intermediates, untuples) =
                    foldr (\(a, ff) (as, fs) -> (a:as, ff . fs)) ([], id)
                    $ flip map (zip [1..] tracefvarss) $ \(ii, tracefvars) ->
                        let tracefvar :: L.TVar
                            tracefvar = unhygenicVarFIXME
                                           (typeTuple (map L.typeof tracefvars))
                                           ("tracefvar" ++ show ii)
                        in (tracefvar, untuple tracefvars (v tracefvar))

              in untuple intermediates tr . untuples


            -- This is really quite annoying.  We should just have a
            -- 1-tuple.
            tuple :: [L.TExpr] -> L.TExpr
            tuple [vvv] = vvv
            tuple vs  = L.Tuple vs

            typeTuple :: [L.Type] -> L.Type
            typeTuple [t] = t
            typeTuple ts  = L.TypeTuple ts

            untuple :: [L.TVar] -> L.TExpr -> L.TExpr -> L.TExpr
            untuple [var] = L.Let var
            untuple vars  = L.Untuple vars



            (fwdf,
             rf,
             tracefvarss,
             revf)
              = differentiateE loopbody

            newf = L.Lam i_v_s (L.Untuple [i, v_s] (v i_v_s)
                               (L.Untuple [vv, s] (v v_s)
                               (L.Let i_s (L.Tuple [v i, v s])
                               (fwdf
                               (L.Tuple [ Prim.pSetAt (Prim.pFst (v i_s)) tracef (v vv)
                                        , v rf
                                        ])))))

            newr = L.Lam i_v_s (L.Untuple [i, v_s] (v i_v_s)
                                 (L.Untuple [vv, rev rf] (v v_s)
                                 (L.Untuple [tracefVar, vv'] (Prim.pIndexL (v i) (v vv))
                                 (makeTraceFVars (v tracefVar)
                                 (revf tracefvarss
                                 (L.Untuple [rev i, rev s] (revVar i_s)
                                 (L.Tuple [v vv', revVar s])))))))
        in
        ( L.Untuple [vv, r]
            (Prim.pForRange (v n) (L.Tuple [traceVec, L.Var s]) newf)
        , [n, vv]
        , \([n_, vv_]:xs) ->
            (xs
            , L.Let (rev n) (L.Tuple [])
              . L.Untuple [vv_, rev s]
                  (Prim.pForRangeRev (v n_) (L.Tuple [v vv_, revVar r]) newr)
            )
        )

renameTVar :: L.TVar -> (String -> String) -> L.TVar
renameTVar (L.TVar t (L.Simple s)) f = L.TVar t (L.Simple (f s))
renameTVar _                       _ = error "renameTVar"

retypeTVar :: L.TVar -> (L.Type -> L.Type) -> L.TVar
retypeTVar (L.TVar t v) f = L.TVar (f t) v

verySlowlyRemoveUnusedLets :: L.TExpr -> L.TExpr
verySlowlyRemoveUnusedLets = \case
  e@L.Var{}       -> e
  e@L.Konst{}     -> e
  e@L.Call{}      -> e
  e@L.Tuple{}     -> e
  e@(L.App{})     -> e
  L.Lam v e       -> L.Lam v (recurse e)
  L.Let v r b     ->
    (L.Let v r
    . if v `LU.notFreeIn` b then L.Elim v else id
    . recurse) b
  L.If cond t f   -> L.If cond (recurse t) (recurse f)
  L.Assert cond e -> L.Assert cond (recurse e)
  L.Dup vs e body -> L.Dup vs e (recurse body)
  L.Elim v body   -> L.Elim v (recurse body)
  L.Untuple vs t body -> L.Untuple vs t (recurse body)
  where recurse = verySlowlyRemoveUnusedLets

unlineariseE :: L.TExpr -> L.TExpr
unlineariseE = \case
  L.Dup (v1, v2) v body ->
    L.Let v1 (L.Var v) (L.Let v2 (L.Var v) (unlineariseE body))
  L.Let v        e           body -> L.Let v (unlineariseE e) (unlineariseE body)
  L.If  cond     true        fals ->
    L.If cond (unlineariseE true) (unlineariseE fals)
  L.Elim _ body -> unlineariseE body
  L.Untuple vs t body ->
    L.Let tv
          (unlineariseE t)
          (foldr (\(i, v) -> L.Let v (Prim.pSel i n (L.Var tv)))
                 (unlineariseE body)
                 (zip [1..] vs))
    where n = length vs
          tv = (L.TVar (L.typeof t) (L.Simple "thisVariableIsUnhygenic"))
  L.Call f args
    | [n, s, L.Lam i_s loopbody] <- args
    , any (f `Prim.isThePrimFun`) ["forRange", "forRangeRev"]
    -> L.Call f [n, s, L.Lam i_s (unlineariseE loopbody)]
  noDups@(L.Tuple{}) -> noDups
  noDups@(L.Call{})  -> noDups
  noDups@(L.Konst{}) -> noDups
  noDups@(L.Var{})   -> noDups
  L.Lam{}    -> notImplemented "Lam"
  L.App{}    -> notImplemented "App"
  L.Assert{} -> notImplemented "Assert"
  where notImplemented c =
          error ("unlineariseE for " ++ c ++ " not implemented yet")

unlineariseD :: L.TDef -> L.TDef
unlineariseD def@(L.Def { L.def_rhs = L.UserRhs rhs }) =
  def { L.def_rhs = L.UserRhs (unlineariseE rhs) }
unlineariseD (L.Def { L.def_rhs = L.StubRhs }) =
  error "Did not expect to see StubRhs"
unlineariseD edef@(L.Def { L.def_rhs = L.EDefRhs }) = edef

rev :: L.TVar -> L.TVar
rev = flip retypeTVar L.tangentType . flip renameTVar (++ "$r")

revVar :: L.TVar -> L.TExpr
revVar = L.Var . rev

makeVarNameFrom :: L.TVar -> L.Type -> String -> L.TVar
makeVarNameFrom orig t s = L.TVar t (L.Simple (origS ++ "$" ++ s))
  where L.TVar _ (L.Simple origS) = orig
