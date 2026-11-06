module SenaVN.Session
  ( SessionData (..),
    getSessionsDir,
    readSession,
    writeSession,
    deleteSession,
    renameSession,
    listSessions,
    isPidAlive,
    reconcileSessions,
    getDaemonPath,
    daemonExeName,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
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
import qualified System.Info as Info
import System.Process (getCurrentPid, rawSystem)

data SessionData = SessionData
  { gameId :: !Text,
    startUnix :: !Int,
    lastHeartbeatUnix :: !Int,
    activeSeconds :: !Int,
    guardPid :: !Int
  }
  deriving (Show, Generic)

instance FromJSON SessionData

instance ToJSON SessionData

getSessionsDir :: IO FilePath
getSessionsDir = do
  home <- getHomeDirectory
  let dir = home </> ".senavn" </> "sessions"
  createDirectoryIfMissing True dir
  pure dir

sessionFile :: FilePath -> Text -> FilePath
sessionFile dir gid = dir </> T.unpack gid <> ".session.json"

readSafe :: FilePath -> Int -> IO (Maybe SessionData)
readSafe _ 0 = pure Nothing
readSafe p retries = do
  res <- try (eitherDecodeFileStrict p) :: IO (Either IOException (Either String SessionData))
  case res of
    Right (Right sd) -> pure (Just sd)
    _ -> do
      threadDelay 30000
      readSafe p (retries - 1)

readSession :: Text -> IO (Maybe SessionData)
readSession gid = do
  dir <- getSessionsDir
  let path = sessionFile dir gid
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else readSafe path 3

writeSession :: SessionData -> IO ()
writeSession sd = do
  dir <- getSessionsDir
  let path = sessionFile dir sd.gameId
      tmpPath = path <> ".tmp"
  encodeFile tmpPath sd
  renameFile tmpPath path

safeRemoveFile :: FilePath -> IO ()
safeRemoveFile p = do
  res <- try (removeFile p) :: IO (Either IOException ())
  case res of
    Left _ -> pure ()
    Right () -> pure ()

isSuffixOf :: String -> String -> Bool
isSuffixOf suf s = drop (length s - length suf) s == suf

deleteSession :: Text -> IO ()
deleteSession gid = do
  dir <- getSessionsDir
  let path = sessionFile dir gid
  safeRemoveFile path

renameSession :: Text -> Text -> IO ()
renameSession oldId newId = do
  dir <- getSessionsDir
  let oldPath = sessionFile dir oldId
      newPath = sessionFile dir newId
  exists <- doesFileExist oldPath
  when exists $ do
    mSess <- readSafe oldPath 3
    case mSess of
      Just sess -> do
        writeSession sess {gameId = newId}
        safeRemoveFile oldPath
      Nothing -> do
        res <- try (renameFile oldPath newPath) :: IO (Either IOException ())
        case res of
          Left _ -> pure ()
          Right () -> pure ()

listSessions :: IO [SessionData]
listSessions = do
  dir <- getSessionsDir
  files <- listDirectory dir
  let jsonFiles =
        filter
          ( \f ->
              takeExtension f == ".json"
                && not (".tmp" `isSuffixOf` f)
                && not (".reconcile" `isSuffixOf` f)
          )
          files
  fmap catMaybes $ forM jsonFiles $ \f ->
    readSafe (dir </> f) 3

daemonExeName :: FilePath
daemonExeName = "sena-guard" <> if Info.os == "mingw32" then ".exe" else ""

getDaemonPath :: IO FilePath
getDaemonPath = do
  selfExe <- getExecutablePath
  let siblingDaemon = takeDirectory selfExe </> daemonExeName
      devRelease = "target" </> "release" </> daemonExeName
      devDebug = "target" </> "debug" </> daemonExeName
  existsSibling <- doesFileExist siblingDaemon
  if existsSibling
    then pure siblingDaemon
    else do
      existsRel <- doesFileExist devRelease
      if existsRel
        then pure devRelease
        else do
          existsDbg <- doesFileExist devDebug
          if existsDbg
            then pure devDebug
            else pure daemonExeName

isPidAlive :: Int -> IO Bool
isPidAlive pid = do
  daemon <- getDaemonPath
  code <- rawSystem daemon ["--check-pid", show pid]
  pure (code == ExitSuccess)

reconcileSessions :: Connection -> IO ()
reconcileSessions conn = do
  dir <- getSessionsDir
  myPid <- getCurrentPid

  -- 1. Recover any orphaned .reconcile files from crashed terminals
  allFiles <- listDirectory dir
  let orphanFiles = filter (".reconcile" `isSuffixOf`) allFiles
  forM_ orphanFiles $ \of_ -> do
    let fullPath = dir </> of_
    mSess <- readSafe fullPath 2
    case mSess of
      Just s -> do
        let tl =
              PlayTimeline
                { start = s.startUnix,
                  end = s.lastHeartbeatUnix,
                  duration = s.activeSeconds
                }
        DB.upsertPlaySession conn s.gameId tl
        DB.updateLastPlay conn s.gameId s.lastHeartbeatUnix
        safeRemoveFile fullPath
      Nothing -> safeRemoveFile fullPath

  -- 2. Normal session reconciliation with atomic claim
  sessions <- listSessions
  forM_ sessions $ \s -> do
    alive <- isPidAlive s.guardPid
    unless alive $ do
      let originalPath = sessionFile dir s.gameId
          claimPath = originalPath <> "." <> show myPid <> ".reconcile"
      claimed <- try (renameFile originalPath claimPath) :: IO (Either IOException ())
      case claimed of
        Left _ -> pure () -- Another terminal already claimed it or it is gone
        Right () -> do
          let tl =
                PlayTimeline
                  { start = s.startUnix,
                    end = s.lastHeartbeatUnix,
                    duration = s.activeSeconds
                  }
          DB.upsertPlaySession conn s.gameId tl
          DB.updateLastPlay conn s.gameId s.lastHeartbeatUnix
          safeRemoveFile claimPath
