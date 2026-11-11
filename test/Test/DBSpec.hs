module Test.DBSpec (dbTests) where

import Control.Exception (bracket)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, close, open)
import SenaVN.DB
import SenaVN.Types
import Test.Framework

dbTests :: Test
dbTests =
  testGroup
    "SenaVN.DB (In-Memory SQLite)"
    [ initDBTests,
      gameCrudTests,
      tombstoneTests,
      configTests
    ]

withMemDB :: (Connection -> IO a) -> IO a
withMemDB action =
  bracket (open ":memory:") close $ \conn -> do
    initDB conn
    action conn

initDBTests :: Test
initDBTests =
  testGroup
    "initDB"
    [ testCase "initializes default configuration keys on fresh database" $
        withMemDB $ \conn -> do
          cfgs <- getAllConfigs conn
          let cfgMap = Map.fromList cfgs
          assertEqual "core.editor set" (Just "") (Map.lookup "core.editor" cfgMap)
          assertEqual "sync.branch set" (Just "main") (Map.lookup "sync.branch" cfgMap)
          assertEqual "sync.path set" (Just "data.json") (Map.lookup "sync.path" cfgMap)
    ]

gameCrudTests :: Test
gameCrudTests =
  testGroup
    "Game CRUD & Sessions"
    [ testCase "inserts and retrieves a GameCore" $
        withMemDB $ \conn -> do
          let g = makeGame "g1" "Test Title"
          insertGame conn g
          mFetched <- getGame conn (GameId "g1")
          case mFetched of
            Nothing -> fail "Game not found in DB"
            Just fetched -> do
              assertEqual "title matches" "Test Title" fetched.title
              assertEqual "expectedPlayTime" 120 fetched.expectedPlayTime
              assertEqual "rating" 8.8 fetched.rating,
      testCase "records and retrieves play sessions" $
        withMemDB $ \conn -> do
          let g = makeGame "g2" "Session Title"
          insertGame conn g
          let s1 = PlayTimeline 1000 2000 1000
          let s2 = PlayTimeline 3000 5000 2000
          upsertPlaySession conn (GameId "g2") s1
          upsertPlaySession conn (GameId "g2") s2
          sessions <- getPlaySessions conn (GameId "g2")
          case sessions of
            [sess1, sess2] -> do
              assertEqual "first session start" 1000 sess1.start
              assertEqual "second session start" 3000 sess2.start
            _ -> fail "Expected exactly 2 sessions"
    ]

tombstoneTests :: Test
tombstoneTests =
  testGroup
    "Tombstone Lifecycle"
    [ testCase "deleteGame with hard flag records a tombstone in deleted_games" $
        withMemDB $ \conn -> do
          let g = makeGame "g_del" "To Delete"
          insertGame conn g
          deleteGame conn (GameId "g_del") True

          mGame <- getGame conn (GameId "g_del")
          assertEqual "game deleted" Nothing mGame

          tombs <- getDeletedGames conn
          case tombs of
            [(gid, _)] -> assertEqual "tombstone id" (GameId "g_del") gid
            _ -> fail "Expected exactly 1 tombstone",
      testCase "deleteGame without hard flag deletes locally without recording tombstone" $
        withMemDB $ \conn -> do
          let g = makeGame "g_soft" "To Soft Delete"
          insertGame conn g
          deleteGame conn (GameId "g_soft") False

          mGame <- getGame conn (GameId "g_soft")
          assertEqual "game deleted" Nothing mGame

          tombs <- getDeletedGames conn
          assertEqual "no tombstone recorded" 0 (length tombs),
      testCase "clearTombstone removes tombstone record" $
        withMemDB $ \conn -> do
          let g = makeGame "g_clear" "To Clear"
          insertGame conn g
          deleteGame conn (GameId "g_clear") True
          clearTombstone conn (GameId "g_clear")

          tombs <- getDeletedGames conn
          assertEqual "tombstones empty" 0 (length tombs),
      testCase "insertGame automatically clears existing tombstone" $
        withMemDB $ \conn -> do
          recordDeletedGame conn (GameId "g_reborn") 1000
          tombBefore <- isTombstoned conn (GameId "g_reborn")
          assertTrue "tombstone exists before insert" tombBefore

          let g = makeGame "g_reborn" "Reborn Game"
          insertGame conn g

          tombAfter <- isTombstoned conn (GameId "g_reborn")
          assertFalse "tombstone cleared after insert" tombAfter,
      testCase "renameGame clears tombstone for newId and records tombstone for oldId" $
        withMemDB $ \conn -> do
          recordDeletedGame conn (GameId "id1") 1000
          let g = makeGame "id2" "Game To Rename"
          insertGame conn g

          renameGame conn (GameId "id2") (GameId "id1") 2000

          -- id1 should exist and not be tombstoned
          mG1 <- getGame conn (GameId "id1")
          case mG1 of
            Nothing -> fail "id1 does not exist after rename"
            Just g1 -> assertEqual "id1 title" "Game To Rename" g1.title

          id1Tomb <- isTombstoned conn (GameId "id1")
          assertFalse "id1 tombstone cleared" id1Tomb

          -- id2 should not exist and be tombstoned
          mG2 <- getGame conn (GameId "id2")
          assertEqual "id2 deleted" Nothing mG2

          id2Tomb <- isTombstoned conn (GameId "id2")
          assertTrue "id2 tombstone recorded" id2Tomb
    ]

configTests :: Test
configTests =
  testGroup
    "Config Management"
    [ testCase "sets and gets configuration values" $
        withMemDB $ \conn -> do
          setConfig conn "custom.token" "secret123"
          val <- getConfig conn "custom.token"
          assertEqual "config value matches" (Just "secret123") val,
      testCase "overwrites existing config value" $
        withMemDB $ \conn -> do
          setConfig conn "sync.branch" "develop"
          val <- getConfig conn "sync.branch"
          assertEqual "updated value matches" (Just "develop") val
    ]

makeGame :: T.Text -> T.Text -> GameCore
makeGame gid title =
  GameCore
    { coreId = GameId gid,
      vndbId = Just "v123",
      updateDate = 1700000000,
      title = title,
      alias = ["Alt 1", "Alt 2"],
      description = "Game description",
      tags = ["Drama", "Romance"],
      playTimelines = [],
      expectedPlayTime = 120,
      lastPlay = 0,
      createDate = 1700000000,
      releaseDate = 1600000000,
      rating = 8.8,
      developer = "Key",
      images = ["https://example.com/cover.jpg"],
      links = [Link "VNDB" "https://vndb.org/v123"]
    }
