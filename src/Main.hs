{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}

module Main
  ( main
  )
where



import Language.Haskell.ExferenceCore ( ExferenceHeuristicsConfig(..)
                                      , findExpressionsWithStats )
import Language.Haskell.Exference
import Language.Haskell.Exference.ExpressionToHaskellSrc
import Language.Haskell.Exference.BindingsFromHaskellSrc
import Language.Haskell.Exference.ClassEnvFromHaskellSrc
import Language.Haskell.Exference.TypeFromHaskellSrc
import Language.Haskell.Exference.FunctionBinding
import Language.Haskell.Exference.EnvironmentParser

import Language.Haskell.Exference.SimpleDict
import Language.Haskell.Exference.TypeClasses
import Language.Haskell.Exference.Expression
import Language.Haskell.Exference.ExferenceStats
import Language.Haskell.Exference.SearchTree

import Control.DeepSeq

import System.Process hiding ( env )

import Control.Applicative ( (<$>), (<*>) )
import Control.Arrow ( first, second, (***) )
import Control.Monad ( when, forM_, guard, forM, mplus, mzero )
import Data.List ( sortBy, find, intersect )
import Data.Ord ( comparing )
import Text.Printf
import Data.Maybe ( listToMaybe, fromMaybe, maybeToList )
import Data.Either ( lefts, rights )
import Control.Monad.Writer.Strict
import qualified Data.Map as M

import Language.Haskell.Exts.Syntax ( Module(..), Decl(..), ModuleName(..) )
import Language.Haskell.Exts.Parser ( parseModuleWithMode
                                    , parseModule
                                    , ParseResult (..)
                                    , ParseMode (..)
                                    , defaultParseMode )
import Language.Haskell.Exts.Extension ( Language (..)
                                       , Extension (..)
                                       , KnownExtension (..) )
import Language.Haskell.Exts.Pretty

import Data.PPrint
import Data.Tree ( drawTree )


import MainConfig
import MainTest

import Paths_exference
import qualified Paths_exference_core
import qualified Flags_exference_core

import System.Environment ( getArgs )
import System.Console.GetOpt
import Data.Version ( showVersion )

import Debug.Hood.Observe



data Flag = Verbose
          | Version
          | Help
          | Tests
          | Examples
          | Env
          | Input String
          | PrintAll
          | PrintTree -- TODO: more options to control core
          | EnvUsage -- TODO: option to specify dictionary to use
          | Serial
          | Parallel
          | Unused
  deriving (Show, Eq)

options :: [OptDescr Flag]
options =
  [ Option []    ["version"]     (NoArg Version)              ""
  , Option []    ["help"]        (NoArg Help)                 "prints basic program info"
  , Option ['t'] ["tests"]       (NoArg Tests)                "run the standard validity/performance tests"
  , Option ['x'] ["examples"]    (NoArg Examples)             "prints the first few results for the examples; useful for debugging"
  , Option ['e'] ["environment"] (NoArg Env)                  "print the environment to be used for queries"
  , Option ['v'] ["verbose"]     (NoArg Verbose)              ""
  , Option ['i'] ["input"]       (ReqArg Input "type")        "the type for which to generate an expression"
  , Option ['a'] ["all"]         (NoArg PrintAll)             "print all solutions (up to search step limit)"
  , Option []    ["envUsage"]    (NoArg EnvUsage)             "print a list of functions that got inserted at some point (regardless if successful or not), and how often"
  , Option []    ["tree"]        (NoArg PrintTree)            "print tree of search space"
  , Option []    ["serial"]      (NoArg Serial)               "use the non-parallelized version of the algorithm (default)"
  , Option ['j'] ["parallel"]    (NoArg Parallel)             "use the parallelized version of the algorithm"
  , Option ['u'] ["allowUnused"] (NoArg Unused)               "allow unused input variables"
  ]

mainOpts :: [String] -> IO ([Flag], [String])
mainOpts argv =
  case getOpt Permute options argv of
    (o, n, []  ) | not $ null $ intersect o [Version, Help, Tests, Examples, Env]
                                ++ [x|x@(Input _) <- o]
                 -> return (o, n)
    ([], _, [])   -> return ([Tests],[])
    (_,  _, errs) -> ioError (userError (concat errs ++ fullUsageInfo))

fullUsageInfo :: String
fullUsageInfo = usageInfo header options
  where
    header = "Usage: exference [OPTION...]"

main :: IO ()
main = runO $ do
  argv <- getArgs
  (flags, params) <- mainOpts argv
  let verbose = Verbose `elem` flags
  let
    printVersion = do
      putStrLn $ "exference version " ++ showVersion version
      putStrLn $ "exference-core version " ++ showVersion Paths_exference_core.version
  if | [Version] == flags   -> printVersion
     | Help    `elem` flags -> putStrLn fullUsageInfo >> putStrLn "TODO"
     | otherwise -> do
        par <- case (Parallel `elem` flags, Serial `elem` flags) of
          (False,False) -> return False
          (True, False) -> return True
          (False,True ) -> return False
          (True, True ) -> do
            error "--serial and --parallel are in conflict! aborting" 
        when (Version `elem` flags || verbose) printVersion
        --((eSignatures, StaticClassEnv clss insts), messages) <- runWriter <$> parseExternal testBaseInput'
        when verbose $ do
          putStrLn "[Environment]"
          putStrLn "reading environment from ExferenceDict.hs and ExferenceRatings.txt"
        (env@(eSignatures, sEnv@(StaticClassEnv clss insts)), messages)
          <- runWriter
          <$> environmentFromModuleAndRatings "ExferenceDict.hs" "ExferenceRatings.txt"
        when (verbose && not (null messages)) $ do
          forM_ messages $ \m -> putStrLn $ "environment warning: " ++ m
        when (Env `elem` flags) $ do
          when verbose $ putStrLn "[Environment]"
          mapM_ print $ clss
          mapM_ print $ [(i,x)| (i,xs) <- M.toList insts, x <- xs]
          mapM_ print $ eSignatures
        when (Examples `elem` flags) $ do
          when verbose $ putStrLn "[Examples]"
          printAndStuff testHeuristicsConfig env
        when (Tests `elem` flags) $ do
          when verbose $ putStrLn "[Tests]"
          printCheckExpectedResults par
                                    testHeuristicsConfig
                                    env
        case [x|(Input x)<-flags] of
          []    -> return ()
          (x:_) -> do
            when verbose $ putStrLn "[Custom Input]"
            let mParsedType = parseConstrainedType sEnv x
            case mParsedType of
              Left err -> do
                putStrLn $ "could not parse input type: " ++ err
              Right parsedType -> do
                let input = ExferenceInput
                      parsedType
                      eSignatures
                      sEnv
                      (Unused `elem` flags)
                      32768
                      (Just 32768)
                      testHeuristicsConfig
                if
                  | PrintAll `elem` flags -> do
                      when verbose $ putStrLn "[running findExpressions ..]"
                      let rs = findExpressions input
                      if null rs
                        then putStrLn "[no results]"
                        else forM_ rs
                          $ \(e, ExferenceStats n d) ->
                            putStrLn $ prettyPrint (convert e)
                                        ++ " (depth " ++ show d
                                        ++ ", " ++ show n ++ " steps)"
                  | PrintTree `elem` flags ->
                      if not Flags_exference_core.buildSearchTree
                        then putStrLn "exference-core was not compiled with flag \"buildSearchTree\""
                        else do
                          when verbose $ putStrLn "[running findExpressionsWithStats ..]"
                          let (_, tree, _) = last $ findExpressionsWithStats input
                          let showf (total,processed,expression,_)
                                = printf "%d (+%d): %s" processed
                                                        (total-processed)
                                                        (show expression)
                          putStrLn $ drawTree
                                   $ fmap showf
                                   -- $ filterSearchTreeProcessedN 2
                                   $ tree
                  | EnvUsage `elem` flags -> do
                      when verbose $ putStrLn "[running findExpressionsWithStats ..]"
                      let (stats, _, _) = last $ findExpressionsWithStats input
                          highest = take 8 $ sortBy (flip $ comparing snd) $ M.toList stats
                      putStrLn $ show highest
                  | otherwise -> do
                      r <- if par
                        then do
                          when verbose $ putStrLn "[running findOneExpressionPar ..]"
                          findOneExpressionPar input
                        else do
                          when verbose $ putStrLn "[running findOneExpression ..]"
                          return $ findOneExpression input
                      case r of
                        Nothing -> putStrLn "[no result]"
                        Just (e, ExferenceStats n d) ->
                            putStrLn $ prettyPrint (convert e)
                                        ++ " (depth " ++ show d
                                        ++ ", " ++ show n ++ " steps)"

        -- printChecks     testHeuristicsConfig env
        -- printStatistics testHeuristicsConfig env
        
        -- print $ compileDict testDictRatings $ eSignatures
        -- print $ parseConstrainedType defaultClassEnv $ "(Show a) => [a] -> String"
        -- print $ inflateHsConstraints a b
        {-
        let t :: HsType
            t = read "m a->( ( a->m b)->( m b))"
        print $ t
        -}

_pointfree :: String -> IO String
_pointfree s = (!!1) <$> lines <$> readProcess "pointfree" ["--verbose", s] ""

_pointful :: String -> IO String
_pointful s = (!!0) <$> lines <$> readProcess "pointful" [s] ""

_tryParse :: Bool -> String -> IO ()
_tryParse shouldBangPattern s = do
  content <- readFile $ "/home/lsp/asd/prog/haskell/exference/BaseContext/preprocessed/"++s++".hs"
  let exts1 = (if shouldBangPattern then (BangPatterns:) else id)
              [ UnboxedTuples
              , TypeOperators
              , MagicHash
              , NPlusKPatterns
              , ExplicitForAll
              , ExistentialQuantification
              , TypeFamilies
              , PolyKinds
              , DataKinds ]
      exts2 = map EnableExtension exts1
  case parseModuleWithMode (ParseMode (s++".hs")
                                      Haskell2010
                                      exts2
                                      False
                                      False
                                      Nothing
                           )
                           content of
    f@(ParseFailed _ _) -> do
      print f
    ParseOk _modul -> do
      putStrLn s
      --mapM_ putStrLn $ map (either id show)
      --               $ getBindings defaultClassEnv mod
      --mapM_ putStrLn $ map (either id show)
      --               $ getDataConss mod
      --mapM_ putStrLn $ map (either id show)
      --               $ getClassMethods defaultClassEnv mod
