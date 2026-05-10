module Main where

import Options.Applicative
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Command (commandParser)
import SenaVN.Core (Env (Env), runRomi)
import SenaVN.DB (withDB)
import SenaVN.Handler (handle)
import System.IO (BufferMode (NoBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stderr NoBuffering
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