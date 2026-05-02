module SenaVN.Types where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype GameId = GameId {unGameId :: Text}
  deriving (Show, Eq, Ord, Generic, FromJSON, ToJSON)

type Seconds = Int

type Minutes = Int

data PlayTimeline = PlayTimeline
  { start :: !Int, -- Unix timestamp (秒)
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
    -- bgmId :: !(Maybe Text),
    updateDate :: !Int, -- Unix timestamp
    title :: !Text,
    alias :: ![Text],
    -- cover :: !Text, -- URL 或本地路径
    description :: !Text,
    tags :: ![Text],
    playTimelines :: ![PlayTimeline],
    expectedPlayTime :: !Minutes,
    lastPlay :: !Int, -- 上次游玩的 timestamp
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
    local :: !(Maybe LocalPath)
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data CloudData = CloudData
  { deleteIds :: ![GameId],
    datas :: ![GameCore]
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data AppConfig = AppConfig
  { syncUsername :: !Text,
    syncToken :: !Text,
    syncFile :: !Text,
    syncVisibility :: Bool
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)

data RootState = RootState
  { gameCore :: ![GameCore],
    localPaths :: ![LocalPath],
    config :: !AppConfig
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)


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

-- data ApplicationData = ApplicationData
--   { root :: !RootState,
--     cloud :: !CloudData
--   }

-- deriving anyclass ()

-- data SyncState = SyncState
--   { time           :: !Int
--   , deleteIds      :: ![GameId]
--   , size           :: !Int
--   , visibility     :: !Text
--   , username       :: !Text
--   , bgmUsername    :: !Text
--   , vndbUsername   :: !Text
--   , avatar         :: !Text
--   -- ... 其他 sync 相关字段
--   } deriving stock (Show, Eq, Generic)
--     deriving anyclass (FromJSON, ToJSON)

-- -- Settings 可以继续细分
-- data Settings = Settings
--   { -- language :: Text
--     -- theme :: Text
--     -- autoSyncMinutes :: Int
--     -- ...
--   } deriving stock (Show, Eq, Generic)
--     deriving anyclass (FromJSON, ToJSON)
