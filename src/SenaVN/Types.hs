module SenaVN.Types where

import Control.Applicative ((<|>))
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    object,
    withArray,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.Foldable (toList)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import GHC.Generics (Generic)

newtype GameId = GameId {unGameId :: Text}
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON)

instance IsString GameId where
  fromString = GameId . fromString

instance FromField GameId where
  fromField f = GameId <$> fromField f

instance ToField GameId where
  toField (GameId gid) = toField gid

type Seconds = Int

type Minutes = Int

minutesToSeconds :: Minutes -> Seconds
minutesToSeconds m = m * 60

secondsToMinutes :: Seconds -> Minutes
secondsToMinutes s = s `div` 60

data PlayTimeline = PlayTimeline
  { start :: !Int,
    end :: !Int,
    duration :: !Seconds
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON PlayTimeline where
  parseJSON v = parseArray v <|> parseObj v
    where
      parseArray = withArray "PlayTimeline array" $ \arr ->
        case toList arr of
          [s, e, d] -> PlayTimeline <$> parseJSON s <*> parseJSON e <*> parseJSON d
          _ -> fail "Expected [start, end, duration] for PlayTimeline"
      parseObj = withObject "PlayTimeline object" $ \o ->
        PlayTimeline <$> o .: "start" <*> o .: "end" <*> o .: "duration"

instance ToJSON PlayTimeline where
  toJSON pt = toJSON [pt.start, pt.end, pt.duration]

data Link = Link
  { name :: !Text,
    url :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

parseTimestamp :: Maybe Value -> Int -> Parser Int
parseTimestamp Nothing defVal = pure defVal
parseTimestamp (Just (Number n)) _ =
  let d = (fromRational (toRational n) :: Double)
      s = if d > 1e11 then d / 1000.0 else d
   in pure (round s)
parseTimestamp (Just other) _ = parseJSON other

data GameCore = GameCore
  { coreId :: !GameId,
    vndbId :: !(Maybe Text),
    updateDate :: !Int,
    title :: !Text,
    alias :: ![Text],
    description :: !Text,
    tags :: ![Text],
    playTimelines :: ![PlayTimeline],
    expectedPlayTime :: !Minutes,
    lastPlay :: !Int,
    createDate :: !Int,
    releaseDate :: !Int,
    rating :: !Double,
    developer :: !Text,
    images :: ![Text],
    links :: ![Link]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GameCore where
  parseJSON = withObject "GameCore" $ \o -> do
    cId <- o .:? "id" >>= maybe (o .: "coreId") pure
    vId <- o .:? "vndbId"
    t <- o .: "title"
    al <- o .:? "alias" .!= []
    desc <- o .:? "description" .!= ""
    tg <- o .:? "tags" .!= []
    pts <- o .:? "playTimelines" .!= []
    mHours <- o .:? "expectedPlayHours"
    expTime <- case mHours of
      Just (h :: Double) -> pure (round (h * 60))
      Nothing -> o .:? "expectedPlayTime" .!= 0
    lpVal <- o .:? "lastPlay"
    lp <- parseTimestamp lpVal 0
    cdVal <- o .:? "createDate"
    cd <- parseTimestamp cdVal 0
    udVal <- o .:? "updateDate"
    ud <- parseTimestamp udVal cd
    rdVal <- o .:? "releaseDate"
    rd <- parseTimestamp rdVal 0
    rat <- o .:? "rating" .!= 0.0
    dev <- o .:? "developer" .!= ""
    rawImgs <- o .:? "images" .!= []
    mCover <- o .:? "cover"
    let imgs = case mCover of
          Just c | c `notElem` rawImgs && not ("data:" `T.isPrefixOf` c) -> c : rawImgs
          _ -> filter (\u -> not ("data:" `T.isPrefixOf` u)) rawImgs
    lks <- o .:? "links" .!= []
    pure
      GameCore
        { coreId = cId,
          vndbId = vId,
          updateDate = ud,
          title = t,
          alias = al,
          description = desc,
          tags = tg,
          playTimelines = pts,
          expectedPlayTime = expTime,
          lastPlay = lp,
          createDate = cd,
          releaseDate = rd,
          rating = rat,
          developer = dev,
          images = imgs,
          links = lks
        }

instance ToJSON GameCore where
  toJSON g =
    object
      [ "id" .= g.coreId,
        "vndbId" .= g.vndbId,
        "updateDate" .= g.updateDate,
        "title" .= g.title,
        "alias" .= g.alias,
        "description" .= g.description,
        "tags" .= g.tags,
        "playTimelines" .= g.playTimelines,
        "expectedPlayTime" .= g.expectedPlayTime,
        "expectedPlayHours" .= (fromIntegral g.expectedPlayTime / 60.0 :: Double),
        "lastPlay" .= g.lastPlay,
        "createDate" .= g.createDate,
        "releaseDate" .= g.releaseDate,
        "rating" .= g.rating,
        "developer" .= g.developer,
        "images" .= g.images,
        "links" .= g.links
      ]

data LocalPath = LocalPath
  { localId :: !GameId,
    programFile :: !Text,
    savePath :: !(Maybe Text),
    guideFile :: !(Maybe Text)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GameWithLocal = GameWithLocal
  { game :: !GameCore,
    local :: !(Maybe LocalPath),
    running :: !(Maybe Seconds)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CloudData = CloudData
  { deleteIds :: ![GameId],
    datas :: ![GameCore]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON CloudData where
  parseJSON v = parseObj v <|> parseArr v
    where
      parseObj = withObject "CloudData" $ \o -> do
        delIds <- o .:? "deleteIds" .!= []
        games <- o .:? "data" >>= maybe (o .:? "datas" .!= []) pure
        pure CloudData {deleteIds = delIds, datas = games}
      parseArr = withArray "CloudData list" $ \arr -> do
        games <- mapM parseJSON (toList arr)
        pure CloudData {deleteIds = [], datas = games}

instance ToJSON CloudData where
  toJSON cd =
    object
      [ "deleteIds" .= cd.deleteIds,
        "data" .= cd.datas
      ]

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
    links :: ![Link]
  }
  deriving (Show, Generic)

data VndbBy = VndbName Text | VndbId Text
