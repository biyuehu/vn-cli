{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Api (fetchFromVndb, FetchGameData (..), VndbBy (..)) where

import Common
import Data.Aeson (FromJSON, object, (.=))
import Data.List (sortBy)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (Down), comparing)
import Data.Text (Text, splitOn, unpack)
import GHC.Generics (Generic)
import Network.HTTP.Req

newtype VNTitle = VNTitle {title :: Text} deriving (Show, Generic, FromJSON)

newtype VNScreenshot = VNScreenshot {url :: Text} deriving (Show, Generic, FromJSON)

data VNTag = VNTag {name :: Text, rating :: Double} deriving (Show, Generic, FromJSON)

newtype VNDeveloper = VNDeveloper {name :: Text} deriving (Show, Generic, FromJSON)

data VNExtLink = VNExtLink {url :: !Text, name :: !Text} deriving (Show, Generic, FromJSON)

data VNRawItem = VNRawItem
  { id :: !Text,
    title :: !Text,
    titles :: ![VNTitle],
    screenshots :: ![VNScreenshot],
    description :: !(Maybe Text),
    tags :: ![VNTag],
    length_minutes :: !(Maybe Int),
    released :: !Text,
    rating :: !(Maybe Double),
    developers :: ![VNDeveloper],
    extlinks :: ![VNExtLink]
  }
  deriving (Show, Generic, FromJSON)

data VNResponse = VNResponse {results :: ![VNRawItem], more :: !Bool} deriving (Show, Generic, FromJSON)

data FetchGameData = FetchGameData
  { vndbId :: !Text,
    title :: !Text,
    alias :: ![Text],
    description :: !Text,
    tags :: ![Text],
    expectedPlayHours :: !Double,
    releaseDate :: !Int,
    rating :: !Double,
    developer :: !Text,
    images :: ![Text],
    links :: ![VNExtLink]
  }
  deriving (Show, Generic)

data VNRequest = VNRequest {filters :: [Text], fields :: Text} deriving (Eq, Show, Generic)

data VndbBy = VndbName Text | VndbId Text

transformVNData :: VNRawItem -> FetchGameData
transformVNData raw =
  FetchGameData
    { vndbId = itemId,
      title = itemTitle,
      alias = titlesList,
      description = fromMaybe "" itemDesc,
      tags = tagsList,
      expectedPlayHours = maybe 0 (\m -> fromIntegral m / 60) mins,
      releaseDate = parseDateToTimestamp rel,
      rating = maybe 0 (/ 10) rat,
      developer = devName,
      images = imgList,
      links = links'
    }
  where
    VNRawItem
      { id = itemId,
        title = itemTitle,
        titles = itemTitles,
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
        map (\(VNTag n _) -> n) $
          sortBy (comparing (\(VNTag _ r) -> Down r)) $
            filter (\(VNTag _ r) -> r >= 2.0) itemTags
    devName = case devs of
      (VNDeveloper n : _) -> n
      [] -> ""
    imgList = map (\(VNScreenshot u) -> u) screens

    parseDateToTimestamp dateStr = case splitOn "-" dateStr of
      [y, m, d] ->
        let year = read (unpack y) :: Int
            month = read (unpack m) :: Int
            day = read (unpack d) :: Int
            days = (year - 1970) * 365 + month * 30 + day
         in days * 86400
      _ -> 0

fetchFromVndb :: VndbBy -> Romi [FetchGameData]
fetchFromVndb vndbBy = runReq defaultHttpConfig $ do
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
                .= ("id, title, image.url, released, titles.title, length_minutes, rating, screenshots.url, tags.name, tags.rating, developers.name, extlinks.name, extlinks.url" :: Text)
            ]
      )
      jsonResponse
      mempty

  let vnResponse = responseBody response :: VNResponse
  pure $ map transformVNData (results vnResponse)
