module Main where

import Control.Monad.Trans.Except (runExceptT)
import Options.Applicative
import SenaVN.Command (commandParser)
import SenaVN.Handler (handle)

main :: IO ()
main = do
  -- TODO: automatically create data.json if not exists
  command' <- execParser opts
  result <- runExceptT $ handle command'
  case result of
    Left err -> Prelude.putStrLn err
    Right _ -> pure ()
  where
    opts = info (commandParser <**> helper) (fullDesc <> progDesc "Gal Manager")