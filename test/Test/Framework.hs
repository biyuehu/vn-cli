module Test.Framework
  ( Test (..),
    testCase,
    testGroup,
    assertEqual,
    assertTrue,
    assertFalse,
    assertRight,
    assertRight_,
    assertLeft,
    assertLeft_,
    assertJust,
    assertNothing,
    runTestTree,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Functor (void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, hSetEncoding, stderr, stdout)

data Test
  = TestCase !String !(IO ())
  | TestGroup !String ![Test]

testCase :: String -> IO () -> Test
testCase = TestCase

testGroup :: String -> [Test] -> Test
testGroup = TestGroup

assertEqual :: (Show a, Eq a) => String -> a -> a -> IO ()
assertEqual msg expected actual =
  if expected == actual
    then pure ()
    else
      fail $
        msg
          ++ "\n  expected: "
          ++ show expected
          ++ "\n  actual:   "
          ++ show actual

assertTrue :: String -> Bool -> IO ()
assertTrue msg cond =
  if cond
    then pure ()
    else fail (msg ++ " (expected True, got False)")

assertFalse :: String -> Bool -> IO ()
assertFalse msg cond =
  if not cond
    then pure ()
    else fail (msg ++ " (expected False, got True)")

assertRight :: (Show a, Show b) => String -> Either a b -> IO b
assertRight _ (Right b) = pure b
assertRight msg (Left a) =
  fail (msg ++ " (expected Right, got Left: " ++ show a ++ ")")

assertRight_ :: (Show a, Show b) => String -> Either a b -> IO ()
assertRight_ msg e = void (assertRight msg e)

assertLeft :: (Show a, Show b) => String -> Either a b -> IO a
assertLeft _ (Left a) = pure a
assertLeft msg (Right b) =
  fail (msg ++ " (expected Left, got Right: " ++ show b ++ ")")

assertLeft_ :: (Show a, Show b) => String -> Either a b -> IO ()
assertLeft_ msg e = void (assertLeft msg e)

assertJust :: (Show a) => String -> Maybe a -> IO a
assertJust _ (Just a) = pure a
assertJust msg Nothing =
  fail (msg ++ " (expected Just, got Nothing)")

assertNothing :: (Show a) => String -> Maybe a -> IO ()
assertNothing _ Nothing = pure ()
assertNothing msg (Just a) =
  fail (msg ++ " (expected Nothing, got Just: " ++ show a ++ ")")

data TestStats = TestStats
  { passed :: !Int,
    failed :: !Int
  }

runTestTree :: Test -> IO ()
runTestTree rootTest = do
  setLocaleEncoding utf8
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  statsRef <- newIORef (TestStats 0 0)
  putStrLn "\ESC[1mRunning SenaVN Test Suite...\ESC[0m\n"
  runNode statsRef 0 rootTest
  stats <- readIORef statsRef
  putStrLn ""
  putStrLn "=================================================="
  if stats.failed == 0
    then do
      putStrLn $ "\ESC[32;1mALL TESTS PASSED\ESC[0m: " ++ show stats.passed ++ " tests completed successfully."
      exitSuccess
    else do
      putStrLn $ "\ESC[31;1mTESTS FAILED\ESC[0m: " ++ show stats.failed ++ " failed, " ++ show stats.passed ++ " passed."
      exitFailure

runNode :: IORef TestStats -> Int -> Test -> IO ()
runNode statsRef depth (TestGroup name children) = do
  let indent = replicate (depth * 2) ' '
  putStrLn $ indent ++ "\ESC[36;1m" ++ name ++ "\ESC[0m"
  forM_ children (runNode statsRef (depth + 1))
runNode statsRef depth (TestCase name action) = do
  let indent = replicate (depth * 2) ' '
  putStr $ indent ++ "* " ++ name ++ " ... "
  hFlush stdout
  result <- try action :: IO (Either SomeException ())
  case result of
    Right () -> do
      putStrLn "\ESC[32m[PASS]\ESC[0m"
      modifyIORef' statsRef (\s -> s {passed = s.passed + 1})
    Left err -> do
      putStrLn "\ESC[31m[FAIL]\ESC[0m"
      putStrLn $ indent ++ "  \ESC[31m" ++ show err ++ "\ESC[0m"
      modifyIORef' statsRef (\s -> s {failed = s.failed + 1})
