module SenaVN.Utils
  ( randomOne,
    pickResult,
    now,
    formatDate,
    formatTimestamp,
    fmtSecStr,
    wrapLine,
    truncateText,
    maskSensitive,
    getAppDir,
    safeRemoveFile,
    openDirectory,
    getTermWidth,
  )
where

import Control.Exception (IOException, try)
import Data.List (uncons)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import SenaVN.Types (Seconds)
import System.Directory (createDirectoryIfMissing, getHomeDirectory, removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Info (os)
import System.Process (createProcess, proc)
import System.Random (randomRIO)
import Text.Read (readMaybe)

randomOne :: [a] -> IO (Maybe a)
randomOne [] = pure Nothing
randomOne xs = do
  idx <- randomRIO (0, length xs - 1)
  pure $ Just (xs !! idx)

pickResult :: Int -> [a] -> Maybe a
pickResult _ [] = Nothing
pickResult n xs
  | n >= 1 && n <= length xs = Just (xs !! (n - 1))
  | otherwise = fst <$> uncons xs

now :: IO Int
now = round <$> getPOSIXTime

formatTimestamp :: String -> Int -> Text
formatTimestamp fmt ts =
  T.pack $
    formatTime defaultTimeLocale fmt (posixSecondsToUTCTime (fromIntegral ts))

formatDate :: Int -> Text
formatDate 0 = "—"
formatDate ts = formatTimestamp "%Y-%m-%d" ts

fmtSecStr :: Seconds -> String
fmtSecStr 0 = "0m"
fmtSecStr totalS =
  let h = totalS `div` 3600
      m = (totalS `mod` 3600) `div` 60
   in if h > 0 then show h <> "h " <> show m <> "m" else show m <> "m"

wrapLine :: Int -> Text -> [Text]
wrapLine maxW t
  | T.null t = [""]
  | T.length t <= maxW = [t]
  | otherwise =
      let (chunk, rest) = T.splitAt maxW t
       in chunk : wrapLine maxW rest

truncateText :: Int -> Text -> Text
truncateText n t
  | T.length t <= n = t
  | otherwise = T.take (n - 1) t <> "…"

maskSensitive :: Text -> Text -> Text
maskSensitive k v
  | isSensitive k =
      let len = T.length v
       in if len <= 8
            then "********"
            else T.take 4 v <> "****" <> T.takeEnd 2 v
  | otherwise = v
  where
    isSensitive s =
      let lower = T.toLower s
       in any (`T.isInfixOf` lower) ["token", "secret", "password"]

getAppDir :: IO FilePath
getAppDir = do
  home <- getHomeDirectory
  let dir = home </> ".senavn"
  createDirectoryIfMissing True dir
  pure dir

safeRemoveFile :: FilePath -> IO ()
safeRemoveFile p = do
  res <- try (removeFile p) :: IO (Either IOException ())
  case res of
    Left _ -> pure ()
    Right () -> pure ()

openDirectory :: FilePath -> IO ()
openDirectory dir = do
  let (cmd, args) = case os of
        "mingw32" -> ("explorer", [dir])
        "darwin"  -> ("open", [dir])
        _         -> ("xdg-open", [dir])
  _ <- createProcess (proc cmd args)
  pure ()

getTermWidth :: IO Int
getTermWidth = do
  mEnvCols <- lookupEnv "COLUMNS"
  let parsedEnv = mEnvCols >>= readMaybe
  pure $ case parsedEnv of
    Just cols | cols > 0 -> clamp cols
    _ -> 88
  where
    clamp c = max 60 (min 160 (c - 1))
