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
import System.Exit (ExitCode, exitFailure)
import System.IO (hSetEncoding, stderr, stdout, utf8)

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
  cmd <- execParser opts
  handleApp cmd `catch` \(e :: SomeException) ->
    case fromException e of
      Just (exitCode :: ExitCode) -> throwIO exitCode
      Nothing -> do
        renderIO stderr . layoutPretty defaultLayoutOptions $
          annotate (color Red) "error" <+> pretty (show e) <> line
        exitFailure
  where
    handleApp cmd = do
      result <- withDB $ \conn ->
        runRomi (Env conn) $ handle cmd
      case result of
        Left err -> do
          renderIO stderr . layoutPretty defaultLayoutOptions $
            annotate (color Red) "error" <+> pretty err <> line
          exitFailure
        Right () -> pure ()

    opts =
      info
        (commandParser <**> helper)
        (fullDesc <> progDesc "sena — gal library manager")
