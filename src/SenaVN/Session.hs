module SenaVN.Session
  ( SessionData (..),
    getSessionsDir,
    readSession,
    writeSession,
    deleteSession,
    listSessions,
    isPidAlive,
    reconcileSessions,
    getFooPath,
  )
where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict, encodeFile)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection)
import GHC.Generics (Generic)
import qualified SenaVN.DB as DB
import SenaVN.Types
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getHomeDirectory,
    listDirectory,
    removeFile,
    renameFile,
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.Process (rawSystem)

-- ────────────────────────────────────────────
-- SessionData
--
-- foo.exe 每 N 分钟原子写一次到 <sessions>/<gameId>.session.json
-- lastHeartbeat 即 stop_time 的最佳近似
-- ────────────────────────────────────────────

data SessionData = SessionData
  { gameId :: !Text,

    startUnix :: !Int, -- unix ts，启动时确定，不变
    lastHeartbeatUnix :: !Int, -- 上次心跳，近似于当前/最终 stop_time
    activeSeconds :: !Int, -- 本次游玩有效秒数，foo 持续更新
    fooPid :: !Int
  }
  deriving (Show, Generic)

instance FromJSON SessionData

instance ToJSON SessionData

-- ────────────────────────────────────────────
-- 路径
-- ────────────────────────────────────────────

getSessionsDir :: IO FilePath
getSessionsDir = do
  home <- getHomeDirectory
  let dir = home </> ".senavn" </> "sessions"
  createDirectoryIfMissing True dir
  pure dir

sessionFile :: FilePath -> Text -> FilePath
sessionFile dir gid = dir </> T.unpack gid <> ".session.json"

-- ────────────────────────────────────────────
-- 读写删
-- ────────────────────────────────────────────

readSession :: Text -> IO (Maybe SessionData)
readSession gid = do
  dir <- getSessionsDir
  let path = sessionFile dir gid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      result <- eitherDecodeFileStrict path
      pure $ either (const Nothing) Just result

-- 原子写：先写临时文件再 rename，崩溃安全
writeSession :: SessionData -> IO ()
writeSession sd = do
  dir <- getSessionsDir
  let path = sessionFile dir sd.gameId
      tmpPath = path <> ".tmp"
  encodeFile tmpPath sd
  renameFile tmpPath path

deleteSession :: Text -> IO ()
deleteSession gid = do
  dir <- getSessionsDir
  let path = sessionFile dir gid
  exists <- doesFileExist path
  when exists $ removeFile path

listSessions :: IO [SessionData]
listSessions = do
  dir <- getSessionsDir
  files <- listDirectory dir
  let jsonFiles =
        filter
          ( \f ->
              takeExtension f == ".json"
                && not (".tmp" `isSuffixOf` f)
          )
          files
  fmap catMaybes $ forM jsonFiles $ \f -> do
    result <- eitherDecodeFileStrict (dir </> f)
    pure $ either (const Nothing) Just result
  where
    isSuffixOf suf s = drop (length s - length suf) s == suf

-- ────────────────────────────────────────────
-- PID 存活检查（委托 foo.exe）
-- ────────────────────────────────────────────

getFooPath :: IO FilePath
getFooPath = do
  selfExe <- getExecutablePath
  let siblingFoo = takeDirectory selfExe </> "foo.exe"
  exists <- doesFileExist siblingFoo
  if exists
    then pure siblingFoo
    else pure "foo.exe"

isPidAlive :: Int -> IO Bool
isPidAlive pid = do
  foo <- getFooPath
  code <- rawSystem foo ["--check-pid", show pid]
  pure (code == ExitSuccess)

-- ────────────────────────────────────────────
-- Reconcile
--
-- 每次 sena 启动相关命令前调用。
-- 扫描所有 session 文件：
--   foo 还活着 → 跳过
--   foo 已死   → 把 session 数据补录进 DB，删 session 文件
-- ────────────────────────────────────────────

reconcileSessions :: Connection -> IO ()
reconcileSessions conn = do
  sessions <- listSessions
  forM_ sessions $ \s -> do
    alive <- isPidAlive s.fooPid
    unless alive $ do
      let tl =
            PlayTimeline
              { start = s.startUnix,
                end = s.lastHeartbeatUnix,
                duration = s.activeSeconds
              }
      DB.upsertPlaySession conn s.gameId tl
      DB.updateLastPlay conn s.gameId s.lastHeartbeatUnix
      deleteSession s.gameId