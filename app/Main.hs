{-# LANGUAGE CPP #-}

module Main where

import Control.Exception (SomeException, catch, fromException, throwIO)
import Data.Text qualified as T
import Data.Word (Word32)
import Options.Applicative
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Command (Command (Tui), commandParser)
import SenaVN.Core (Env (Env), renderSenaErrorDoc, runRomi)
import SenaVN.DB (withDB)
import SenaVN.Handler (handle)
import SenaVN.Version (appAuthor, appHomepage, appLicense, appVersionStr)
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
  cmd <-
    if null args
      then pure Tui
      else case execParserPure parserPrefs opts args of
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
            renderSenaErrorDoc err <> line
          exitFailure
        Right () -> pure ()

    versionOpt =
      infoOption
        ( "sena "
            <> appVersionStr
            <> "\nAuthor: "
            <> T.unpack appAuthor
            <> "\nHomepage: "
            <> T.unpack appHomepage
            <> "\nLicense: "
            <> T.unpack appLicense
        )
        ( long "version"
            <> short 'v'
            <> help "Show version and author information"
        )

    opts =
      info
        (commandParser <**> helper <**> versionOpt)
        ( fullDesc
            <> header ("sena " <> appVersionStr <> " — Terminal Visual Novel Library & Playtime Tracker")
            <> progDesc "A modern CLI & TUI galgame/visual novel management tool."
            <> footer ("Author: " <> T.unpack appAuthor <> " · " <> T.unpack appHomepage)
        )

    parserPrefs =
      prefs
        ( showHelpOnEmpty
            <> showHelpOnError
            <> subparserInline
        )
