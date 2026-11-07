{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module SenaVN.DB
  ( withDB,
    getDBPath,
    initDB,
    getGame,
    getGameWithLocal,
    getAllGames,
    getAllGamesWithLocal,
    insertGame,
    updateGame,
    deleteGame,
    getLocalPath,
    upsertLocalPath,
    upsertPlaySession,
    getPlaySessions,
    updateLastPlay,
    renameGame,
    getAllConfigs,
    getConfig,
    setConfig,
    deleteConfig,
    setAllConfigs,
    ConfigKey (..),
    configKeyName,
    ConfigValue (..),
    getTypedConfig,
    setTypedConfig,
  )
where

import Control.Exception (bracket)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (forM_)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple
import SenaVN.Types
import SenaVN.Utils (getAppDir)
import System.FilePath ((</>))
import Text.Read (readMaybe)

getDBPath :: IO FilePath
getDBPath = (</> "sena.db") <$> getAppDir

withDB :: (Connection -> IO a) -> IO a
withDB action = do
  path <- getDBPath
  bracket (open path) close $ \conn -> do
    execute_ conn "PRAGMA journal_mode=WAL"
    execute_ conn "PRAGMA foreign_keys=ON"
    execute_ conn "PRAGMA busy_timeout = 5000"
    initDB conn
    action conn

initDB :: Connection -> IO ()
initDB conn =
  mapM_
    (execute_ conn)
    [ "CREATE TABLE IF NOT EXISTS games (\
      \  id               TEXT    PRIMARY KEY,\
      \  vndb_id          TEXT,\
      \  title            TEXT    NOT NULL,\
      \  description      TEXT    NOT NULL DEFAULT '',\
      \  expected_minutes INTEGER NOT NULL DEFAULT 0,\
      \  last_play        INTEGER NOT NULL DEFAULT 0,\
      \  create_date      INTEGER NOT NULL DEFAULT 0,\
      \  update_date      INTEGER NOT NULL DEFAULT 0,\
      \  release_date     INTEGER NOT NULL DEFAULT 0,\
      \  rating           REAL    NOT NULL DEFAULT 0.0,\
      \  developer        TEXT    NOT NULL DEFAULT '',\
      \  alias            TEXT    NOT NULL DEFAULT '[]',\
      \  tags             TEXT    NOT NULL DEFAULT '[]',\
      \  images           TEXT    NOT NULL DEFAULT '[]',\
      \  links            TEXT    NOT NULL DEFAULT '[]'\
      \)",
      "CREATE TABLE IF NOT EXISTS local_paths (\
      \  game_id      TEXT PRIMARY KEY REFERENCES games(id) ON DELETE CASCADE,\
      \  program_file TEXT NOT NULL,\
      \  save_path    TEXT,\
      \  guide_file   TEXT\
      \)",
      "CREATE TABLE IF NOT EXISTS play_sessions (\
      \  id         TEXT    PRIMARY KEY,\
      \  game_id    TEXT    NOT NULL REFERENCES games(id) ON DELETE CASCADE,\
      \  start_time INTEGER NOT NULL,\
      \  end_time   INTEGER NOT NULL DEFAULT 0,\
      \  duration   INTEGER NOT NULL DEFAULT 0\
      \)",
      "CREATE TABLE IF NOT EXISTS configs (\
      \  key   TEXT PRIMARY KEY,\
      \  value TEXT NOT NULL\
      \)"
    ]

decodeJson :: (FromJSON a) => Text -> a -> a
decodeJson t defVal = fromMaybe defVal (decode (BL.fromStrict (TE.encodeUtf8 t)))

encodeJson :: (ToJSON a) => a -> Text
encodeJson val = TE.decodeUtf8 (BL.toStrict (encode val))

data GameRow = GameRow
  { grId :: !GameId,
    grVndbId :: !(Maybe Text),
    grTitle :: !Text,
    grDesc :: !Text,
    grExpected :: !Minutes,
    grLastPlay :: !Int,
    grCreate :: !Int,
    grUpdate :: !Int,
    grRelease :: !Int,
    grRating :: !Double,
    grDev :: !Text,
    grAlias :: !Text,
    grTags :: !Text,
    grImages :: !Text,
    grLinks :: !Text
  }

instance FromRow GameRow where
  fromRow =
    GameRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data LocalRow = LocalRow
  { lrGameId :: !GameId,
    lrProgram :: !Text,
    lrSave :: !(Maybe Text),
    lrGuide :: !(Maybe Text)
  }

instance FromRow LocalRow where
  fromRow = LocalRow <$> field <*> field <*> field <*> field

gameSelectCols :: Query
gameSelectCols =
  "SELECT id,vndb_id,title,description,expected_minutes,\
  \last_play,create_date,update_date,release_date,rating,developer,\
  \alias,tags,images,links FROM games"

buildGameCoreFromRow :: Map.Map GameId [PlayTimeline] -> GameRow -> GameCore
buildGameCoreFromRow sessMap r =
  GameCore
    { coreId = r.grId,
      vndbId = r.grVndbId,
      title = r.grTitle,
      description = r.grDesc,
      alias = decodeJson r.grAlias [],
      tags = decodeJson r.grTags [],
      images = decodeJson r.grImages [],
      links = decodeJson r.grLinks [],
      playTimelines = Map.findWithDefault [] r.grId sessMap,
      expectedPlayTime = r.grExpected,
      lastPlay = r.grLastPlay,
      createDate = r.grCreate,
      updateDate = r.grUpdate,
      releaseDate = r.grRelease,
      rating = r.grRating,
      developer = r.grDev
    }

buildGameCore :: Connection -> GameRow -> IO GameCore
buildGameCore conn r = do
  playSessions <- getPlaySessions conn r.grId
  pure $ buildGameCoreFromRow (Map.singleton r.grId playSessions) r

fromLocalRow :: LocalRow -> LocalPath
fromLocalRow lr =
  LocalPath
    { localId = lr.lrGameId,
      programFile = lr.lrProgram,
      savePath = lr.lrSave,
      guideFile = lr.lrGuide
    }

getGame :: Connection -> GameId -> IO (Maybe GameCore)
getGame conn gid = do
  rows <- query conn (gameSelectCols <> " WHERE id=?") (Only gid) :: IO [GameRow]
  case rows of
    [] -> pure Nothing
    (r : _) -> Just <$> buildGameCore conn r

getGameWithLocal :: Connection -> GameId -> IO (Maybe GameWithLocal)
getGameWithLocal conn gid = do
  mg <- getGame conn gid
  case mg of
    Nothing -> pure Nothing
    Just g -> do
      ml <- getLocalPath conn gid
      pure $ Just GameWithLocal {game = g, local = ml, running = Nothing}

getAllGames :: Connection -> IO [GameCore]
getAllGames conn = do
  rows <- query_ conn (gameSelectCols <> " ORDER BY title") :: IO [GameRow]
  sessRows <-
    query_
      conn
      "SELECT game_id,start_time,end_time,duration FROM play_sessions ORDER BY start_time" ::
      IO [(GameId, Int, Int, Seconds)]
  let sessMap =
        Map.fromListWith
          (flip (++))
          [(gid, [PlayTimeline s e d]) | (gid, s, e, d) <- sessRows]
  pure $ map (buildGameCoreFromRow sessMap) rows

getAllGamesWithLocal :: Connection -> IO [GameWithLocal]
getAllGamesWithLocal conn = do
  rows <- query_ conn (gameSelectCols <> " ORDER BY title") :: IO [GameRow]
  sessRows <-
    query_
      conn
      "SELECT game_id,start_time,end_time,duration FROM play_sessions ORDER BY start_time" ::
      IO [(GameId, Int, Int, Seconds)]
  localRows <-
    query_
      conn
      "SELECT game_id,program_file,save_path,guide_file FROM local_paths" ::
      IO [LocalRow]
  let sessMap =
        Map.fromListWith
          (flip (++))
          [(gid, [PlayTimeline s e d]) | (gid, s, e, d) <- sessRows]
      localMap =
        Map.fromList
          [(lr.lrGameId, fromLocalRow lr) | lr <- localRows]
  pure
    [ GameWithLocal
        { game = buildGameCoreFromRow sessMap r,
          local = Map.lookup r.grId localMap,
          running = Nothing
        }
    | r <- rows
    ]

insertGame :: Connection -> GameCore -> IO ()
insertGame conn g = withTransaction conn $ do
  let gid = g.coreId.unGameId
  execute
    conn
    "INSERT INTO games\
    \ (id,vndb_id,title,description,expected_minutes,\
    \  last_play,create_date,update_date,release_date,rating,developer,\
    \  alias,tags,images,links)\
    \ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    ( ( gid,
        g.vndbId,
        g.title,
        g.description,
        g.expectedPlayTime,
        g.lastPlay,
        g.createDate,
        g.updateDate
      )
        :. ( g.releaseDate,
             g.rating,
             g.developer,
             encodeJson g.alias,
             encodeJson g.tags,
             encodeJson g.images,
             encodeJson g.links
           )
    )

updateGame :: Connection -> GameCore -> IO ()
updateGame conn g = withTransaction conn $ do
  let gid = g.coreId.unGameId
  execute
    conn
    "UPDATE games SET\
    \ vndb_id=?,title=?,description=?,expected_minutes=?,\
    \ last_play=?,update_date=?,release_date=?,rating=?,developer=?,\
    \ alias=?,tags=?,images=?,links=?\
    \ WHERE id=?"
    ( ( g.vndbId,
        g.title,
        g.description,
        g.expectedPlayTime,
        g.lastPlay,
        g.updateDate,
        g.releaseDate,
        g.rating
      )
        :. ( g.developer,
             encodeJson g.alias,
             encodeJson g.tags,
             encodeJson g.images,
             encodeJson g.links,
             gid
           )
    )

deleteGame :: Connection -> GameId -> IO ()
deleteGame conn gid =
  execute conn "DELETE FROM games WHERE id=?" (Only gid)

getLocalPath :: Connection -> GameId -> IO (Maybe LocalPath)
getLocalPath conn gid = do
  rows <- query conn "SELECT game_id,program_file,save_path,guide_file FROM local_paths WHERE game_id=?" (Only gid) :: IO [LocalRow]
  pure $ fromLocalRow <$> listToMaybe rows

upsertLocalPath :: Connection -> LocalPath -> IO ()
upsertLocalPath conn lp =
  execute
    conn
    "INSERT INTO local_paths (game_id,program_file,save_path,guide_file)\
    \ VALUES (?,?,?,?)\
    \ ON CONFLICT(game_id) DO UPDATE SET\
    \   program_file=excluded.program_file,\
    \   save_path=excluded.save_path,\
    \   guide_file=excluded.guide_file"
    (lp.localId, lp.programFile, lp.savePath, lp.guideFile)

sessionId :: GameId -> Int -> Text
sessionId (GameId gid) s = gid <> "-" <> T.pack (show s)

upsertPlaySession :: Connection -> GameId -> PlayTimeline -> IO ()
upsertPlaySession conn gid tl =
  execute
    conn
    "INSERT INTO play_sessions (id,game_id,start_time,end_time,duration)\
    \ VALUES (?,?,?,?,?)\
    \ ON CONFLICT(id) DO UPDATE SET\
    \   end_time=excluded.end_time,\
    \   duration=excluded.duration"
    (sessionId gid tl.start, gid, tl.start, tl.end, tl.duration)

getPlaySessions :: Connection -> GameId -> IO [PlayTimeline]
getPlaySessions conn gid = do
  rows <-
    query
      conn
      "SELECT start_time,end_time,duration FROM play_sessions\
      \ WHERE game_id=? ORDER BY start_time"
      (Only gid) ::
      IO [(Int, Int, Seconds)]
  pure $ map (\(s, e, d) -> PlayTimeline {start = s, end = e, duration = d}) rows

updateLastPlay :: Connection -> GameId -> Int -> IO ()
updateLastPlay conn gid ts =
  execute
    conn
    "UPDATE games SET last_play=? WHERE id=? AND last_play<?"
    (ts, gid, ts)

renameGame :: Connection -> GameId -> GameId -> Int -> IO ()
renameGame conn oldId newId ts = withTransaction conn $ do
  execute_ conn "PRAGMA defer_foreign_keys = ON"
  execute conn "UPDATE games SET id=?, update_date=? WHERE id=?" (newId, ts, oldId)
  execute conn "UPDATE local_paths SET game_id=? WHERE game_id=?" (newId, oldId)
  execute
    conn
    "UPDATE play_sessions SET id=? || '-' || start_time, game_id=? WHERE game_id=?"
    (newId, newId, oldId)

getAllConfigs :: Connection -> IO [(Text, Text)]
getAllConfigs conn =
  query_ conn "SELECT key,value FROM configs ORDER BY key"

getConfig :: Connection -> Text -> IO (Maybe Text)
getConfig conn k = do
  rows <- query conn "SELECT value FROM configs WHERE key=?" (Only k) :: IO [Only Text]
  pure $ case rows of
    (Only v : _) -> Just v
    [] -> Nothing

setConfig :: Connection -> Text -> Text -> IO ()
setConfig conn k v =
  execute
    conn
    "INSERT INTO configs (key,value) VALUES (?,?)\
    \ ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    (k, v)

deleteConfig :: Connection -> Text -> IO Bool
deleteConfig conn k = do
  execute conn "DELETE FROM configs WHERE key=?" (Only k)
  n <- changes conn
  pure (n > 0)

setAllConfigs :: Connection -> [(Text, Text)] -> IO ()
setAllConfigs conn kvs = withTransaction conn $ do
  execute_ conn "DELETE FROM configs"
  forM_ kvs $ \(k, v) ->
    execute conn "INSERT OR REPLACE INTO configs (key, value) VALUES (?, ?)" (k, v)

data ConfigKey a where
  CoreEditor :: ConfigKey Text
  FetchProxy :: ConfigKey Text

configKeyName :: ConfigKey a -> Text
configKeyName CoreEditor = "core.editor"
configKeyName FetchProxy = "fetch.proxy"

class ConfigValue a where
  serializeValue :: a -> Text
  deserializeValue :: Text -> Maybe a

instance ConfigValue Text where
  serializeValue = id
  deserializeValue = Just

instance ConfigValue Int where
  serializeValue = T.pack . show
  deserializeValue = readMaybe . T.unpack

instance ConfigValue Bool where
  serializeValue True = "true"
  serializeValue False = "false"
  deserializeValue s
    | lower `elem` ["true", "1", "yes", "on"] = Just True
    | lower `elem` ["false", "0", "no", "off"] = Just False
    | otherwise = Nothing
    where
      lower = T.toLower (T.strip s)

getTypedConfig :: (ConfigValue a) => Connection -> ConfigKey a -> IO (Maybe a)
getTypedConfig conn key = do
  mRaw <- getConfig conn (configKeyName key)
  pure (mRaw >>= deserializeValue)

setTypedConfig :: (ConfigValue a) => Connection -> ConfigKey a -> a -> IO ()
setTypedConfig conn key val =
  setConfig conn (configKeyName key) (serializeValue val)
