{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Exception (SomeException, catch, fromException, throwIO)
import Data.Word (Word32)
import Options.Applicative
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Command (commandParser)
import SenaVN.Core (Env (Env), runRomi)
import SenaVN.DB (withDB)
import SenaVN.Handler (handle)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitSuccess, exitWith)
import System.IO (hPutStr, hSetEncoding, stderr, stdout, utf8)

#ifdef mingw32_HOST_OS
import Data.Int (Int32)

foreign import ccall "SetConsoleOutputCP" setConsoleOutputCP :: Word32 -> IO Int32
foreign import ccall "SetConsoleCP" setConsoleCP :: Word32 -> IO Int32
#endif

main :: IO ()
main = do
#ifdef mingw32_HOST_OS
  _ <- setConsoleOutputCP 65001
  _ <- setConsoleCP 65001
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
#endif
  args <- getArgs
  cmd <- case execParserPure parserPrefs opts args of
    Success c -> pure c
    Failure failure -> do
      let (msg, code) = renderFailure failure "sena"
      case code of
        ExitSuccess -> putStr msg
        _ -> hPutStr stderr msg
      exitWith code
    CompletionInvoked compl -> do
      msg <- execCompletion compl "sena"
      putStr msg
      exitSuccess
  handleApp cmd `catch` \(e :: SomeException) ->
    case fromException e of
      Just (exitCode :: ExitCode) -> throwIO exitCode
      Nothing -> do
        renderIO stderr . layoutPretty defaultLayoutOptions $
          annotate (color Red <> bold) "✗ error:" <+> pretty (show e) <> line
        exitFailure
  where
    handleApp cmd = do
      result <- withDB $ \conn ->
        runRomi (Env conn) $ handle cmd
      case result of
        Left err -> do
          renderIO stderr . layoutPretty defaultLayoutOptions $
            annotate (color Red <> bold) "✗ error:" <+> pretty err <> line
          exitFailure
        Right () -> pure ()

    opts =
      info
        (commandParser <**> helper)
        (fullDesc <> progDesc "sena — gal library manager")

    parserPrefs =
      prefs
        ( showHelpOnEmpty
            <> showHelpOnError
            <> subparserInline
        )
