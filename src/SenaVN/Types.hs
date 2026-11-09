module SenaVN.Types where

import Data.Aeson (FromJSON, ToJSON)
import Data.String (IsString (..))
import Data.Text (Text)
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
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data Link = Link
  { name :: !Text,
    url :: !Text
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

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
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data LocalPath = LocalPath
  { localId :: !GameId,
    programFile :: !Text,
    savePath :: !(Maybe Text),
    guideFile :: !(Maybe Text)
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data GameWithLocal = GameWithLocal
  { game :: !GameCore,
    local :: !(Maybe LocalPath),
    running :: !(Maybe Seconds)
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- data CloudData = CloudData
--   { deleteIds :: ![GameId],
--     datas :: ![GameCore]
--   }
--   deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- data AppConfig = AppConfig
--   { syncUsername :: !Text,
--     syncToken :: !Text,
--     syncFile :: !Text,
--     syncVisibility :: Bool
--   }
--   deriving (Show, Eq, Generic, FromJSON, ToJSON)

-- data RootState = RootState
--   { gameCore :: ![GameCore],
--     localPaths :: ![LocalPath],
--     config :: !AppConfig
--   }
--   deriving (Show, Eq, Generic, FromJSON, ToJSON)

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
