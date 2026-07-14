{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module SenaVN.DB
  ( -- * 连接
    withDB,
    getDBPath,

    -- * 初始化
    initDB,

    -- * Game
    getGame,
    getGameWithLocal,
    getAllGames,
    getAllGamesWithLocal,
    insertGame,
    updateGame,
    deleteGame,

    -- * LocalPath
    getLocalPath,
    upsertLocalPath,
    deleteLocalPath,

    -- * PlaySession
    upsertPlaySession,
    getPlaySessions,

    -- * 辅助
    updateLastPlay,
  )
where

-- updateLastPlay,

import Control.Exception (bracket)
import Control.Monad (forM, forM_)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import SenaVN.Types
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.FilePath ((</>))

-- ────────────────────────────────────────────
-- 路径
-- ────────────────────────────────────────────

getAppDir :: IO FilePath
getAppDir = do
  home <- getHomeDirectory
  let dir = home </> ".sena"
  createDirectoryIfMissing True dir
  pure dir

getDBPath :: IO FilePath
getDBPath = (</> "sena.db") <$> getAppDir

-- ────────────────────────────────────────────
-- 连接
-- ────────────────────────────────────────────

withDB :: (Connection -> IO a) -> IO a
withDB action = do
  path <- getDBPath
  bracket (open path) close $ \conn -> do
    execute_ conn "PRAGMA journal_mode=WAL"
    execute_ conn "PRAGMA foreign_keys=ON"
    initDB conn
    action conn

-- ────────────────────────────────────────────
-- Schema
-- ────────────────────────────────────────────

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
      \  developer        TEXT    NOT NULL DEFAULT ''\
      \)",
      "CREATE TABLE IF NOT EXISTS game_aliases (\
      \  game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,\
      \  alias   TEXT NOT NULL,\
      \  PRIMARY KEY (game_id, alias)\
      \)",
      "CREATE TABLE IF NOT EXISTS game_tags (\
      \  game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,\
      \  tag     TEXT NOT NULL,\
      \  PRIMARY KEY (game_id, tag)\
      \)",
      "CREATE TABLE IF NOT EXISTS game_images (\
      \  game_id    TEXT    NOT NULL REFERENCES games(id) ON DELETE CASCADE,\
      \  url        TEXT    NOT NULL,\
      \  sort_order INTEGER NOT NULL DEFAULT 0\
      \)",
      "CREATE TABLE IF NOT EXISTS game_links (\
      \  game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,\
      \  name    TEXT NOT NULL,\
      \  url     TEXT NOT NULL\
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
      \)"
    ]

-- ────────────────────────────────────────────
-- 内部行类型
-- ────────────────────────────────────────────

data GameRow = GameRow
  { grId :: !Text,
    grVndbId :: !(Maybe Text),
    grTitle :: !Text,
    grDesc :: !Text,
    grExpected :: !Int,
    grLastPlay :: !Int,
    grCreate :: !Int,
    grUpdate :: !Int,
    grRelease :: !Int,
    grRating :: !Double,
    grDev :: !Text
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

data LocalRow = LocalRow
  { lrGameId :: !Text,
    lrProgram :: !Text,
    lrSave :: !(Maybe Text),
    lrGuide :: !(Maybe Text)
  }

instance FromRow LocalRow where
  fromRow = LocalRow <$> field <*> field <*> field <*> field

-- ────────────────────────────────────────────
-- 组装 GameCore（多表 JOIN 手动拼）
-- ────────────────────────────────────────────

buildGameCore :: Connection -> GameRow -> IO GameCore
buildGameCore conn r = do
  aliases <-
    map fromOnly
      <$> query conn "SELECT alias FROM game_aliases WHERE game_id=?" (Only r.grId)
  tags' <-
    map fromOnly
      <$> query conn "SELECT tag FROM game_tags WHERE game_id=?" (Only r.grId)
  images' <-
    map fromOnly
      <$> query conn "SELECT url FROM game_images WHERE game_id=? ORDER BY sort_order" (Only r.grId)
  linkRows <-
    query
      conn
      "SELECT name,url FROM game_links WHERE game_id=?"
      (Only r.grId) ::
      IO [(Text, Text)]
  sessRows <-
    query
      conn
      "SELECT start_time,end_time,duration FROM play_sessions WHERE game_id=? ORDER BY start_time"
      (Only r.grId) ::
      IO [(Int, Int, Int)]
  pure
    GameCore
      { coreId = GameId r.grId,
        vndbId = r.grVndbId,
        title = r.grTitle,
        description = r.grDesc,
        alias = aliases,
        tags = tags',
        images = images',
        links = map (\(n, u) -> Link {name = n, url = u}) linkRows,
        playTimelines = map (\(s, e, d) -> PlayTimeline {start = s, end = e, duration = d}) sessRows,
        expectedPlayTime = r.grExpected,
        lastPlay = r.grLastPlay,
        createDate = r.grCreate,
        updateDate = r.grUpdate,
        releaseDate = r.grRelease,
        rating = r.grRating,
        developer = r.grDev
      }

fromLocalRow :: LocalRow -> LocalPath
fromLocalRow lr =
  LocalPath
    { localId = GameId lr.lrGameId,
      programFile = lr.lrProgram,
      savePath = lr.lrSave,
      guideFile = lr.lrGuide
    }

-- ────────────────────────────────────────────
-- Game CRUD
-- ────────────────────────────────────────────

getGame :: Connection -> Text -> IO (Maybe GameCore)
getGame conn gid = do
  rows <- query conn "SELECT * FROM games WHERE id=?" (Only gid) :: IO [GameRow]
  case rows of
    [] -> pure Nothing
    (r : _) -> Just <$> buildGameCore conn r

getGameWithLocal :: Connection -> Text -> IO (Maybe GameWithLocal)
getGameWithLocal conn gid = do
  mg <- getGame conn gid
  case mg of
    Nothing -> pure Nothing
    Just g -> do
      ml <- getLocalPath conn gid
      pure $ Just GameWithLocal {game = g, local = ml}

getAllGames :: Connection -> IO [GameCore]
getAllGames conn = do
  rows <- query_ conn "SELECT * FROM games ORDER BY title" :: IO [GameRow]
  forM rows (buildGameCore conn)

getAllGamesWithLocal :: Connection -> IO [GameWithLocal]
getAllGamesWithLocal conn = do
  games <- getAllGames conn
  forM games $ \g -> do
    ml <- getLocalPath conn g.coreId.unGameId
    pure GameWithLocal {game = g, local = ml}

insertGame :: Connection -> GameCore -> IO ()
insertGame conn g = withTransaction conn $ do
  let gid = g.coreId.unGameId
  execute
    conn
    "INSERT INTO games\
    \ (id,vndb_id,title,description,expected_minutes,\
    \  last_play,create_date,update_date,release_date,rating,developer)\
    \ VALUES (?,?,?,?,?,?,?,?,?,?,?)"
    ( ( gid,
        g.vndbId,
        g.title,
        g.description,
        g.expectedPlayTime,
        g.lastPlay,
        g.createDate
      )
        :. (g.updateDate, g.releaseDate, g.rating, g.developer)
    )
  insertLists conn gid g

updateGame :: Connection -> GameCore -> IO ()
updateGame conn g = withTransaction conn $ do
  let gid = g.coreId.unGameId
  execute
    conn
    "UPDATE games SET\
    \ vndb_id=?,title=?,description=?,expected_minutes=?,\
    \ last_play=?,update_date=?,release_date=?,rating=?,developer=?\
    \ WHERE id=?"
    ( g.vndbId,
      g.title,
      g.description,
      g.expectedPlayTime,
      g.lastPlay,
      g.updateDate,
      g.releaseDate,
      g.rating,
      g.developer,
      gid
    )
  execute conn "DELETE FROM game_aliases WHERE game_id=?" (Only gid)
  execute conn "DELETE FROM game_tags    WHERE game_id=?" (Only gid)
  execute conn "DELETE FROM game_images  WHERE game_id=?" (Only gid)
  execute conn "DELETE FROM game_links   WHERE game_id=?" (Only gid)
  insertLists conn gid g

deleteGame :: Connection -> Text -> IO ()
deleteGame conn gid =
  execute conn "DELETE FROM games WHERE id=?" (Only gid)

-- ON DELETE CASCADE 自动清理关联表

insertLists :: Connection -> Text -> GameCore -> IO ()
insertLists conn gid g = do
  forM_ g.alias $ \a ->
    execute conn "INSERT INTO game_aliases (game_id,alias) VALUES (?,?)" (gid, a)
  forM_ g.tags $ \t ->
    execute conn "INSERT INTO game_tags (game_id,tag) VALUES (?,?)" (gid, t)
  forM_ (zip [0 ..] g.images) $ \(i, u) ->
    execute
      conn
      "INSERT INTO game_images (game_id,url,sort_order) VALUES (?,?,?)"
      (gid, u, i :: Int)
  forM_ g.links $ \l ->
    execute
      conn
      "INSERT INTO game_links (game_id,name,url) VALUES (?,?,?)"
      (gid, l.name, l.url)

-- ────────────────────────────────────────────
-- LocalPath CRUD
-- ────────────────────────────────────────────

getLocalPath :: Connection -> Text -> IO (Maybe LocalPath)
getLocalPath conn gid = do
  rows <- query conn "SELECT * FROM local_paths WHERE game_id=?" (Only gid) :: IO [LocalRow]
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
    (lp.localId.unGameId, lp.programFile, lp.savePath, lp.guideFile)

deleteLocalPath :: Connection -> Text -> IO ()
deleteLocalPath conn gid =
  execute conn "DELETE FROM local_paths WHERE game_id=?" (Only gid)

-- ────────────────────────────────────────────
-- PlaySession CRUD
-- ────────────────────────────────────────────

-- sessionId：用 gameId + startTime 构成自然主键，幂等安全
sessionId :: Text -> Int -> Text
sessionId gid s = gid <> "-" <> T.pack (show s)

-- 既是 insert 也是 update（session 文件补录用）
upsertPlaySession :: Connection -> Text -> PlayTimeline -> IO ()
upsertPlaySession conn gid tl =
  execute
    conn
    "INSERT INTO play_sessions (id,game_id,start_time,end_time,duration)\
    \ VALUES (?,?,?,?,?)\
    \ ON CONFLICT(id) DO UPDATE SET\
    \   end_time=excluded.end_time,\
    \   duration=excluded.duration"
    (sessionId gid tl.start, gid, tl.start, tl.end, tl.duration)

getPlaySessions :: Connection -> Text -> IO [PlayTimeline]
getPlaySessions conn gid = do
  rows <-
    query
      conn
      "SELECT start_time,end_time,duration FROM play_sessions\
      \ WHERE game_id=? ORDER BY start_time"
      (Only gid) ::
      IO [(Int, Int, Int)]
  pure $ map (\(s, e, d) -> PlayTimeline {start = s, end = e, duration = d}) rows

-- 只在新值更大时更新（幂等）
updateLastPlay :: Connection -> Text -> Int -> IO ()
updateLastPlay conn gid ts =
  execute
    conn
    "UPDATE games SET last_play=? WHERE id=? AND last_play<?"
    (ts, gid, ts)