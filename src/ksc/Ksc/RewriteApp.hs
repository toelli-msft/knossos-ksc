-- To run it:
--
-- ~/.ghcup/bin/cabal v2-repl --ghc-option=-Wwarn --with-ghc ~/.ghcup/ghc/8.6.5/bin/ghc
--
-- :l src/ksc/Ksc/RewriteApp.hs
--
-- main
--
-- The go to http://localhost:3000/ in your browser

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE LambdaCase #-}

{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fdefer-typed-holes #-}

module Ksc.RewriteApp where

import qualified Rules
import qualified Lang
import qualified LangUtils
import qualified Parse
import qualified Annotate
import qualified KMonad
import qualified OptLet

import qualified Data.Map
import           Data.Maybe (mapMaybe)
import           Data.List (intercalate)
import           Data.IORef (newIORef, atomicModifyIORef)
import           Data.String (fromString)
import qualified Data.Text.Lazy

import           Web.Scotty (scotty, get, liftAndCatchIO, html, param)

import           Control.Monad.Free (Free(Pure, Free), liftF)
import qualified Control.Monad.Trans.State
import           Control.Monad.Trans.State hiding (get)
import           Data.Void (Void, absurd)
import qualified Data.List.NonEmpty as NEL

typeCheck :: [Lang.Decl] -> IO [Lang.TDecl]
typeCheck = fmap snd . KMonad.runKM . Annotate.annotDecls LangUtils.emptyGblST

parse :: [String] -> IO [Lang.Decl]
parse = fmap concat . mapM Parse.parseF

userFuns :: [Lang.DeclX p] -> [(String, Lang.ExprX p)]
userFuns = mapMaybe $ \case
       Lang.RuleDecl{} -> Nothing
       Lang.DefDecl d ->
         case (Lang.funIdOfFun (Lang.def_fun d), Lang.def_rhs d) of
           (Lang.UserFun f, Lang.UserRhs e) -> Just (f, e)
           _ -> Nothing

mkRuleBase :: [Lang.TDecl] -> Rules.RuleBase
mkRuleBase = Rules.mkRuleBase . mapMaybe (\case
       Lang.RuleDecl r -> Just r
       Lang.DefDecl{} -> Nothing)

main :: IO ()
main = do
  mapOfPages <- newIORef Data.Map.empty
  let withMap = liftAndCatchIO . atomicModifyIORef mapOfPages

  let sourceFile = "test/ksc/ex0.ks"
      functionName = "f"

  tc_decls <- typeCheck =<< parse [ "src/runtime/prelude.ks", sourceFile ]

  let rules = mkRuleBase tc_decls

  let prog = head $ flip mapMaybe (userFuns tc_decls) $ \(f, e) ->
        if f == functionName then Just e else Nothing

  let link = "<p><a href=\"/\">Start again</a></p>"

      comments = [ link
                 , "<ul>"
                 , "<li>Displays the body of the function "
                 , fromString functionName
                 , " from the source file "
                 , fromString sourceFile
                 , "</li>"
                 , "<li>TODO: format the expression</li>"
                 , "<li>TODO: breadcrumbs</li>"
                 , "</ul>"
                 ]

  scotty 3000 $ do
    get "/" $ do
      s <- withMap (\m -> renderPages m (rewritesPages rules prog))
      html $ mconcat (comments ++ [Data.Text.Lazy.pack s])
    get "/rewrite/:word" $ do
      beam <- param "word"
      let i = read (Data.Text.Lazy.unpack beam) :: Int

      ss <- withMap $ \m ->
        case Data.Map.lookup i m of
          Nothing -> (m, comments
                       ++ ["<p>Couldn't find ", beam, ". ",
                           "You may want to ",
                           "<a href=\"/\">start again</a>.</p>"
                          ])
          Just e -> let (m', s) = renderPages m e
                    in  (m', comments ++ [Data.Text.Lazy.pack s])

      html (mconcat ss)

data Document a = Left' String
                | Right' (String, a)
                | Branch [Document a]
                deriving Functor

data Page a = Document [Document a]
            | Rewrites [Document a] [(String, String, a)]
  deriving Functor

setList :: Int -> a -> [a] -> [a]
setList i a as = zipWith f [1..] as
  where f j a' = if i == j then a else a'

tryRules :: Rules.RuleBase -> Lang.TExpr -> [(Lang.TRule, Lang.TExpr)]
tryRules rulebase = (fmap . fmap) (OptLet.optLets (OptLet.mkEmptySubst []))
                    . Rules.tryRulesMany rulebase

rewrites :: Rules.RuleBase
         -> (Lang.TExpr -> e)
         -> Lang.TExpr
         -> [Document [(Lang.TRule, e)]]
rewrites rulebase k = \case
     c@(Lang.Call ff@(Lang.TFun _ f) e) ->
       [Left' "("]
       <> [Branch $ [Right' call] <> [Left' " "] <> rewrites_]
       <> [Left' ")"]
       where call = (fstr,
                     map (\(rule, rewritten)
                           -> (rule, k rewritten)) (tryRules rulebase c))
             fstr = Lang.renderSexp (Lang.pprFunId (Lang.funIdOfFun f))
             k' = k . Lang.Call ff
             rewrites_ = case e of
                Lang.Tuple es -> tupleRewrites rulebase k' es
                _ -> rewrites rulebase k' e

     Lang.Tuple es -> [Left' "(tuple "]
                      <> tupleRewrites rulebase k es
                      <> [Left' ")"]
     Lang.Var v -> [Left' (Lang.nameOfVar (Lang.tVarVar v))]
     Lang.Konst c -> case c of
       Lang.KFloat f -> [Left' (show f)]
       Lang.KBool b -> [Left' (show b)]
       Lang.KString s -> [Left' (show s)]
       Lang.KInteger i -> [Left' (show i)]
     Lang.Let v rhs body ->
       let rhs'  = rewrites rulebase (\rhs'' -> k (Lang.Let v rhs'' body)) rhs
           body' = rewrites rulebase (\body'' -> k (Lang.Let v rhs body'')) body
       in [Left' ("(let (" ++ show v ++ " ")] <> rhs' <> [Left' ") "] <> body'

     Lang.App _ _ -> error "We don't do App"
     Lang.Lam _ _ -> error "We don't do Lam"
     Lang.If _ _ _ -> error "We don't do If"
     Lang.Assert _ _ -> error "We don't do Assert"
     Lang.Dummy _ -> error "We don't do Dummy"

-- For avoiding "(tuple ...)" around multiple arguments
tupleRewrites :: Rules.RuleBase
              -> (Lang.TExpr -> e)
              -> [Lang.TExpr]
              -> [Document [(Lang.TRule, e)]]
tupleRewrites rulebase k es =
  intercalate [Left' " "] (map (\(j, e) ->
    rewrites rulebase (\e' ->
        k (Lang.Tuple (setList j e' es)) ) e)
    (zip [1..] es))

rewritesPage :: Rules.RuleBase
             -> Lang.TExpr
             -> Page [(Lang.TRule, Lang.TExpr)]
rewritesPage r e = Document (rewrites r id e)

choosePage :: Rules.RuleBase
           -> Lang.TExpr
           -> [(Lang.TRule, Lang.TExpr)]
           -> Page (Either Lang.TExpr [(Lang.TRule, Lang.TExpr)])
choosePage r e rs =
  Rewrites ((fmap . fmap) Right (rewrites r id e))
           (fmap (\(r', e') -> (Lang.ru_name r', pretty r', Left e')) rs)
  where pretty rule = ": "
                      ++ Lang.renderSexp (Lang.ppr (Lang.ru_lhs rule))
                      ++ " &rarr; "
                      ++ Lang.renderSexp (Lang.ppr (Lang.ru_rhs rule))

rewritesPages :: Rules.RuleBase -> Lang.TExpr -> Free Page a
rewritesPages r e = do
    x <- liftF (rewritesPage r e)
    choosePages r e x

choosePages :: Rules.RuleBase
            -> Lang.TExpr
            -> [(Lang.TRule, Lang.TExpr)]
            -> Free Page a
choosePages r e rs = do
    x <- liftF (choosePage r e rs)
    case x of
      Left e' -> rewritesPages r e'
      Right rs' -> choosePages r e rs'

newLink :: a -> State (Data.Map.Map Int a) Int
newLink a = do
  mm <- Control.Monad.Trans.State.get
  let i = case Data.Map.lookupMax mm of
        Just (theMax, _) -> theMax + 1
        Nothing -> 0
  put (Data.Map.insert i a mm)
  pure i

render :: (container_int -> string)
       -> ((a -> State (Data.Map.Map Int a) Int)
          -> container_a -> State map_int_a container_int)
       -> map_int_a
       -> container_a
       -> (map_int_a, string)
render renderString traverse' m d = (m', renderString d')
  where (d', m') = flip runState m $ flip traverse' d newLink

renderDocument :: Data.Map.Map Int a
               -> Document a
               -> (Data.Map.Map Int a, String)
renderDocument = render renderDocumentString traverseDocument

traverseDocument :: Applicative f
                 => (a -> f b)
                 -> Document a
                 -> f (Document b)
traverseDocument f = \case
  Left' s       -> pure (Left' s)
  Right' (s, a) -> (\a' -> Right' (s, a')) <$> f a
  Branch ds     -> Branch <$> (traverse . traverseDocument) f ds

spanColor :: String -> String
spanColor s = "<span onMouseOver=\"window.event.stopPropagation(); this.style.backgroundColor='#ffdddd'\" "
              ++ "onMouseOut=\"window.event.stopPropagation(); this.style.backgroundColor='transparent'\">"
              ++ s
              ++ "</span>"

renderDocumentString :: Document Int -> String
renderDocumentString = \case
  Left' s       -> s
  Right' (s, b) -> renderLink b s
  Branch ds     -> spanColor (foldr f "" ds)
    where f d rest = renderDocumentString d ++ rest

renderLink :: Show a => a -> String -> String
renderLink i s = "<a href=\"/rewrite/" ++ show i ++ "\">" ++ s ++ "</a>"

renderPage :: Data.Map.Map Int a
           -> Page a
           -> (Data.Map.Map Int a, String)
renderPage = render renderPageString traversePage

traversePage :: Applicative f
             => (a -> f b) -> Page a -> f (Page b)
traversePage f = \case
  Document d   -> Document <$> (traverse . traverseDocument) f d
  Rewrites d r -> Rewrites <$> (traverse . traverseDocument) f d
                           <*> (traverse . traverse3of3) f r

traverse3of3 :: Functor f => (c -> f c') -> (a, b, c) -> f (a, b, c')
traverse3of3 f (a, b, c) = (\c' -> (a, b, c')) <$> f c

renderPageString :: Page Int -> String
renderPageString = \case
  Document d -> concatMap renderDocumentString d
  Rewrites d r -> concatMap renderDocumentString d
                  ++ "<ul>"
                  ++ renderRewrites (NEL.nonEmpty r)
                  ++ "</ul>"
    where renderRewrites = \case
            Nothing -> "<p>No rewrites available for selected expression</p>"
            Just l -> foldr f "" l
              where f (s, s1, b) rrs = "<li>" ++ renderLink b s ++ s1 ++ "</li>" ++ rrs

renderPages :: Data.Map.Map Int (Free Page Void)
            -> Free Page Void
            -> (Data.Map.Map Int (Free Page Void), String)
renderPages m = \case
  Pure void -> absurd void
  Free page -> renderPage m page
