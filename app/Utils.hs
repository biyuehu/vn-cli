module Utils where

import Common
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (eitherDecodeStrictText)
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text, pack)
import qualified Data.Text.IO as TIO
import qualified Models as M
import System.Random (randomRIO)

romiPutStrLn :: Text -> Romi ()
romiPutStrLn = liftIO . TIO.putStrLn

romiPutStrLn' :: String -> Romi ()
romiPutStrLn' = romiPutStrLn . pack

rootStateFile :: FilePath
rootStateFile = "data.json"

loadRootStates :: Romi M.RootState
loadRootStates = do
  text <- liftIO $ TIO.readFile rootStateFile
  case eitherDecodeStrictText text of
    Left err -> throwE err
    Right states -> pure states

saveRootStates :: M.RootState -> Romi ()
saveRootStates states = liftIO $ TIO.writeFile rootStateFile $ pack $ show $ encodeToLazyText states

randomOne :: [a] -> Romi (Maybe a)
randomOne [] = pure Nothing
randomOne xs = do
  idx <- randomRIO (0, length xs - 1)
  pure $ Just (xs !! idx)