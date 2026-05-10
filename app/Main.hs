{-# LANGUAGE CPP #-}

module Main where

import Data.Word (Word32)
import Options.Applicative
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Command (commandParser)
import SenaVN.Core (Env (Env), runRomi)
import SenaVN.DB (withDB)
import SenaVN.Handler (handle)
import System.IO (hSetEncoding, stderr, stdout, utf8)

#ifdef mingw32_HOST_OS
import Data.Int  (Int32)

foreign import ccall "SetConsoleOutputCP" setConsoleOutputCP :: Word32 -> IO Int32
foreign import ccall "SetConsoleCP"       setConsoleCP       :: Word32 -> IO Int32
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
  result <- withDB $ \conn ->
    runRomi (Env conn) $ handle cmd
  case result of
    Left err ->
      renderIO stdout . layoutPretty defaultLayoutOptions $
        annotate (color Red) "error" <+> pretty err <> line
    Right () -> pure ()
  where
    opts =
      info
        (commandParser <**> helper)
        (fullDesc <> progDesc "sena — gal library manager")