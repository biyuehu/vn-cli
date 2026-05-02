module SenaVN.Utils (romiPutStrLn, romiPutStrLn', rootStateFile, loadRootStates, saveRootStates, randomOne, fmtTs, fmtMins, truncateText, padL, padR) where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Except (throwE)
import Data.Aeson (eitherDecodeStrictText)
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import SenaVN.Core
import SenaVN.Types (RootState)
import System.Random (randomRIO)
import Text.Printf (printf)

romiPutStrLn :: Text -> Romi ()
romiPutStrLn = liftIO . TIO.putStrLn

romiPutStrLn' :: String -> Romi ()
romiPutStrLn' = romiPutStrLn . pack

rootStateFile :: FilePath
rootStateFile = "data.json"

loadRootStates :: Romi RootState
loadRootStates = do
  text <- liftIO $ TIO.readFile rootStateFile
  case eitherDecodeStrictText text of
    Left err -> throwE err
    Right states -> pure states

saveRootStates :: RootState -> Romi ()
saveRootStates states = liftIO $ TIO.writeFile rootStateFile $ pack $ show $ encodeToLazyText states

randomOne :: [a] -> Romi (Maybe a)
randomOne [] = pure Nothing
randomOne xs = do
  idx <- randomRIO (0, length xs - 1)
  pure $ Just (xs !! idx)

fmtTs :: Int -> String
fmtTs 0 = "N/A"
fmtTs ts = formatTime defaultTimeLocale "%Y-%m-%d %H:%M" (posixSecondsToUTCTime $ fromIntegral ts)

-- | 辅助：分钟转小时
fmtMins :: Int -> String
fmtMins m = printf "%dh %dm" (m `div` 60) (m `mod` 60)

-- | 辅助：截断长文本
truncateText :: Int -> Text -> String
truncateText n t =
  let s = unpack t
   in if length s > n then take (n - 3) s ++ "..." else s

padL :: Int -> T.Text -> T.Text
padL n = T.justifyLeft n ' '

padR :: Int -> T.Text -> T.Text
padR n = T.justifyRight n ' '
