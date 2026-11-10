module SenaVN.Utils
  ( randomOne,
    pickResult,
    now,
    formatDate,
    formatTimestamp,
    formatRelativeTime,
    fmtSecStr,
    wrapLine,
    truncateText,
    maskSensitive,
    getAppDir,
    safeRemoveFile,
    openDirectory,
    getTermWidth,
    encodeBase64,
    decodeBase64,
  )
where

import Control.Exception (IOException, try)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (ord)
import Data.List (uncons)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Word (Word8)
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

formatRelativeTime :: Int -> Int -> Text
formatRelativeTime nowTs targetTs
  | targetTs <= 0 = "unknown"
  | diff < 0 = "in the future"
  | diff < 60 = "just now"
  | diff < 120 = "1 minute ago"
  | diff < 3600 = T.pack (show (diff `div` 60)) <> " minutes ago"
  | diff < 7200 = "1 hour ago"
  | diff < 86400 = T.pack (show (diff `div` 3600)) <> " hours ago"
  | diff < 172800 = "yesterday"
  | diff < 86400 * 7 = T.pack (show (diff `div` 86400)) <> " days ago"
  | diff < 86400 * 14 = "1 week ago"
  | diff < 86400 * 30 = T.pack (show (diff `div` (86400 * 7))) <> " weeks ago"
  | diff < 86400 * 60 = "1 month ago"
  | diff < 86400 * 365 = T.pack (show (diff `div` (86400 * 30))) <> " months ago"
  | otherwise = T.pack (show (diff `div` (86400 * 365))) <> " years ago"
  where
    diff = nowTs - targetTs

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
      if T.null v
        then ""
        else
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

base64Table :: BS.ByteString
base64Table = BC.pack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

encodeBase64 :: BS.ByteString -> BS.ByteString
encodeBase64 bs = BS.pack (go (BS.unpack bs))
  where
    go [] = []
    go [a] =
      let n = shiftL (fromIntegral a :: Int) 16
          c1 = BS.index base64Table (shiftR n 18 .&. 0x3F)
          c2 = BS.index base64Table (shiftR n 12 .&. 0x3F)
       in [c1, c2, fromIntegral (ord '='), fromIntegral (ord '=')]
    go [a, b] =
      let n = shiftL (fromIntegral a :: Int) 16 .|. shiftL (fromIntegral b :: Int) 8
          c1 = BS.index base64Table (shiftR n 18 .&. 0x3F)
          c2 = BS.index base64Table (shiftR n 12 .&. 0x3F)
          c3 = BS.index base64Table (shiftR n 6 .&. 0x3F)
       in [c1, c2, c3, fromIntegral (ord '=')]
    go (a : b : c : rest) =
      let n = shiftL (fromIntegral a :: Int) 16 .|. shiftL (fromIntegral b :: Int) 8 .|. fromIntegral c
          c1 = BS.index base64Table (shiftR n 18 .&. 0x3F)
          c2 = BS.index base64Table (shiftR n 12 .&. 0x3F)
          c3 = BS.index base64Table (shiftR n 6 .&. 0x3F)
          c4 = BS.index base64Table (n .&. 0x3F)
       in c1 : c2 : c3 : c4 : go rest

decodeBase64 :: BS.ByteString -> Maybe BS.ByteString
decodeBase64 bs =
  let cleaned = filter isB64 (BS.unpack bs)
   in if length cleaned `mod` 4 /= 0
        then Nothing
        else BS.pack <$> go cleaned
  where
    isB64 w =
      (w >= 65 && w <= 90)
        || (w >= 97 && w <= 122)
        || (w >= 48 && w <= 57)
        || w == 43
        || w == 47
        || w == 61

    val :: Word8 -> Maybe Int
    val w
      | w >= 65 && w <= 90 = Just (fromIntegral w - 65)
      | w >= 97 && w <= 122 = Just (fromIntegral w - 97 + 26)
      | w >= 48 && w <= 57 = Just (fromIntegral w - 48 + 52)
      | w == 43 = Just 62
      | w == 47 = Just 63
      | otherwise = Nothing

    go [] = Just []
    go [a, b, 61, 61] = do
      va <- val a
      vb <- val b
      let n = shiftL va 18 .|. shiftL vb 12
      pure [fromIntegral (shiftR n 16 .&. 0xFF)]
    go [a, b, c, 61] = do
      va <- val a
      vb <- val b
      vc <- val c
      let n = shiftL va 18 .|. shiftL vb 12 .|. shiftL vc 6
      pure [fromIntegral (shiftR n 16 .&. 0xFF), fromIntegral (shiftR n 8 .&. 0xFF)]
    go (a : b : c : d : rest) = do
      va <- val a
      vb <- val b
      vc <- val c
      vd <- val d
      let n = shiftL va 18 .|. shiftL vb 12 .|. shiftL vc 6 .|. vd
      let b1 = fromIntegral (shiftR n 16 .&. 0xFF)
      let b2 = fromIntegral (shiftR n 8 .&. 0xFF)
      let b3 = fromIntegral (n .&. 0xFF)
      ([b1, b2, b3] ++) <$> go rest
    go _ = Nothing
