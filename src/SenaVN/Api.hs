module SenaVN.Api (transformVNData, fetchFromVndb) where

import Control.Applicative ((<|>))
import Control.Exception (throwIO, try)
import Data.Aeson (FromJSON, object, (.=))
import Data.List (isInfixOf, sortBy)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (Down), comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import GHC.Generics (Generic)
import Network.HTTP.Req
import SenaVN.Types
import System.Environment (setEnv)

newtype VNTitle = VNTitle {title :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

newtype VNImage = VNImage {url :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

newtype VNScreenshot = VNScreenshot {url :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

data VNTag = VNTag {name :: !Text, rating :: !Double, spoiler :: !(Maybe Int)}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

newtype VNDeveloper = VNDeveloper {name :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

data VNExtLink = VNExtLink {url :: !Text, name :: !Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

data VNRawItem = VNRawItem
  { id :: !Text,
    title :: !Text,
    titles :: ![VNTitle],
    image :: !(Maybe VNImage),
    screenshots :: ![VNScreenshot],
    description :: !(Maybe Text),
    tags :: ![VNTag],
    length_minutes :: !(Maybe Int),
    released :: !(Maybe Text),
    rating :: !(Maybe Double),
    developers :: ![VNDeveloper],
    extlinks :: ![VNExtLink]
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

newtype VNResponse = VNResponse {results :: [VNRawItem]}
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON)

transformVNData :: VNRawItem -> FetchGameData
transformVNData raw =
  FetchGameData
    { vndbId = itemId,
      title = itemTitle,
      alias = titlesList,
      description = fromMaybe "" itemDesc,
      tags = tagsList,
      expectedPlayHours = maybe 0 (\m -> fromIntegral m / 60) mins,
      releaseDate = maybe 0 parseDateToTimestamp rel,
      rating = maybe 0 (/ 10) rat,
      developer = devName,
      images = imgList,
      links = map (\l -> Link {name = l.name, url = l.url}) links'
    }
  where
    VNRawItem
      { id = itemId,
        title = itemTitle,
        titles = itemTitles,
        image = itemImage,
        screenshots = screens,
        description = itemDesc,
        tags = itemTags,
        length_minutes = mins,
        released = rel,
        rating = rat,
        developers = devs,
        extlinks = links'
      } = raw

    titlesList = map (\(VNTitle t) -> t) itemTitles
    tagsList =
      take 30 $
        map (\t -> t.name) $
          sortBy (comparing (\t -> Down t.rating)) $
            filter (\t -> fromMaybe 0 t.spoiler == 0 && t.rating >= 2.0) itemTags
    devName = T.intercalate ", " [n | VNDeveloper n <- devs]
    screensUrls = map (\(VNScreenshot u) -> u) screens
    imgList = maybe screensUrls (\(VNImage u) -> u : screensUrls) itemImage

    parseDateToTimestamp dateStr =
      let str = T.unpack (T.strip dateStr)
          mDay :: Maybe Day
          mDay =
            parseTimeM True defaultTimeLocale "%Y-%m-%d" str
              <|> parseTimeM True defaultTimeLocale "%Y-%m" str
              <|> parseTimeM True defaultTimeLocale "%Y" str
       in case mDay of
            Just day ->
              let utc = UTCTime day (secondsToDiffTime 0)
               in round (utcTimeToPOSIXSeconds utc)
            Nothing -> 0

formatHttpError :: HttpException -> String
formatHttpError (JsonHttpException err) = "VNDB JSON parsing error: " ++ err
formatHttpError (VanillaHttpException err) =
  let errStr = show err
   in if "429" `isInfixOf` errStr
        then "VNDB API rate limit reached (HTTP 429), please try again later."
        else if "ResponseTimeout" `isInfixOf` errStr || "timeout" `isInfixOf` errStr
          then "Connection to VNDB timed out (exceeded 10s limit)."
          else if "ConnectionFailure" `isInfixOf` errStr || "getAddrInfo" `isInfixOf` errStr
            then "Cannot connect to VNDB (network offline or DNS resolution failed)."
            else "VNDB network request failed: " ++ errStr

fetchFromVndb :: Maybe Text -> VndbBy -> IO [FetchGameData]
fetchFromVndb mProxy vndbBy = do
  case mProxy of
    Just p | not (T.null (T.strip p)) -> do
      let proxyStr = normalizeProxyUrl (T.strip p)
      setEnv "HTTPS_PROXY" proxyStr
      setEnv "HTTP_PROXY" proxyStr
    _ -> pure ()
  res <- try (runReq defaultHttpConfig queryVndb)
  case res of
    Right val -> pure val
    Left err -> throwIO $ userError (formatHttpError err)
  where
    normalizeProxyUrl p
      | "http://" `T.isPrefixOf` p || "https://" `T.isPrefixOf` p = T.unpack p
      | otherwise = "http://" ++ T.unpack p

    queryVndb = do
      response <-
        req
          POST
          (https "api.vndb.org" /: "kana" /: "vn")
          ( ReqBodyJson $
              object
                [ "filters"
                    .= case vndbBy of
                      VndbName name' -> ["search", "=", name']
                      VndbId vId -> ["id", "=", vId],
                  "fields"
                    .= ("id, title, image.url, released, titles.title, length_minutes, rating, screenshots.url, tags.name, tags.rating, tags.spoiler, developers.name, extlinks.name, extlinks.url, description" :: Text)
                ]
          )
          jsonResponse
          (responseTimeout (10 * 1000000))
      let vnResponse = responseBody response :: VNResponse
      pure $ map transformVNData vnResponse.results
