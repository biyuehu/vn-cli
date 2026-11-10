module Test.SyncSpec (syncTests) where

import qualified Data.Text as T
import SenaVN.Sync
import SenaVN.Types
import Test.Framework

syncTests :: Test
syncTests =
  testGroup
    "SenaVN.Sync (3-Way Merge)"
    [ disjointMergeTests,
      conflictResolutionTests,
      sessionUnionTests,
      tombstoneDeletionTests,
      resurrectionTests
    ]

makeDummyGame :: GameId -> T.Text -> Int -> [PlayTimeline] -> GameCore
makeDummyGame gid title ud pts =
  GameCore
    { coreId = gid,
      vndbId = Nothing,
      updateDate = ud,
      title = title,
      alias = [],
      description = "",
      tags = [],
      playTimelines = pts,
      expectedPlayTime = 60,
      lastPlay = if null pts then ud else maximum (map (.end) pts),
      createDate = ud,
      releaseDate = 0,
      rating = 8.0,
      developer = "Dev",
      images = [],
      links = []
    }

disjointMergeTests :: Test
disjointMergeTests =
  testGroup
    "Disjoint Library Sets"
    [ testCase "merges independent local and remote games" $ do
        let gLocal = makeDummyGame (GameId "g_loc") "Local Game" 100 []
        let gRemote = makeDummyGame (GameId "g_rem") "Remote Game" 100 []
        let remoteCloud = CloudData {deleteIds = [], datas = [gRemote]}
        let (newCloud, upserts, deletes, _, summary) = mergeData [gLocal] [] remoteCloud

        assertEqual "cloud games count" 2 (length newCloud.datas)
        assertEqual "local upserts count" 1 (length upserts)
        case upserts of
          [u] -> assertEqual "local upserted game id" (GameId "g_rem") u.coreId
          _ -> fail "Expected exactly 1 upsert"
        assertEqual "deletes empty" [] deletes
        assertEqual "actions count" 2 (length summary.actions)
    ]

conflictResolutionTests :: Test
conflictResolutionTests =
  testGroup
    "Metadata Conflict Resolution (LWW)"
    [ testCase "local wins when local updateDate is newer" $ do
        let gLoc = makeDummyGame (GameId "g1") "Local Newer Title" 2000 []
        let gRem = makeDummyGame (GameId "g1") "Remote Older Title" 1000 []
        let remoteCloud = CloudData {deleteIds = [], datas = [gRem]}
        let (newCloud, upserts, _, _, _) = mergeData [gLoc] [] remoteCloud

        case newCloud.datas of
          [winner] -> assertEqual "cloud game title" "Local Newer Title" winner.title
          _ -> fail "Expected exactly 1 game in cloud data"
        assertEqual "no local upserts needed" 0 (length upserts),
      testCase "remote wins when remote updateDate is newer" $ do
        let gLoc = makeDummyGame (GameId "g1") "Local Older Title" 1000 []
        let gRem = makeDummyGame (GameId "g1") "Remote Newer Title" 2000 []
        let remoteCloud = CloudData {deleteIds = [], datas = [gRem]}
        let (newCloud, upserts, _, _, _) = mergeData [gLoc] [] remoteCloud

        case newCloud.datas of
          [winner] -> assertEqual "cloud game title" "Remote Newer Title" winner.title
          _ -> fail "Expected exactly 1 game in cloud data"
        assertEqual "local upsert required" 1 (length upserts)
        case upserts of
          [u] -> assertEqual "local upsert has remote title" "Remote Newer Title" u.title
          _ -> fail "Expected exactly 1 upsert"
    ]

sessionUnionTests :: Test
sessionUnionTests =
  testGroup
    "Play Sessions Union & Deduplication"
    [ testCase "unions disjoint sessions and deduplicates shared sessions" $ do
        let s1 = PlayTimeline {start = 100, end = 200, duration = 100}
        let s2 = PlayTimeline {start = 300, end = 400, duration = 100}
        let s3 = PlayTimeline {start = 500, end = 600, duration = 100}
        let gLoc = makeDummyGame (GameId "g1") "Game" 1000 [s1, s2]
        let gRem = makeDummyGame (GameId "g1") "Game" 1000 [s1, s3]
        let remoteCloud = CloudData {deleteIds = [], datas = [gRem]}
        let (newCloud, _, _, _, summary) = mergeData [gLoc] [] remoteCloud

        case newCloud.datas of
          [winner] -> do
            let mergedSess = winner.playTimelines
            assertEqual "merged sessions count" 3 (length mergedSess)
            assertEqual "sessions starts" [100, 300, 500] (map (.start) mergedSess)
            assertEqual "new sessions reported in summary" 1 summary.mergedSessionsCount
          _ -> fail "Expected exactly 1 game in cloud data"
    ]

tombstoneDeletionTests :: Test
tombstoneDeletionTests =
  testGroup
    "Tombstone Deletion Propagation"
    [ testCase "propagates remote deletion to unplayed local game" $ do
        let gLoc = makeDummyGame (GameId "g_del") "Deleted on Remote" 0 []
        let remoteCloud = CloudData {deleteIds = [GameId "g_del"], datas = []}
        let (newCloud, _, deletes, _, summary) = mergeData [gLoc] [] remoteCloud

        assertEqual "marked for local delete" [GameId "g_del"] deletes
        assertEqual "cloud tombstone preserved" [GameId "g_del"] newCloud.deleteIds
        assertEqual "cloud data empty" 0 (length newCloud.datas)
        assertEqual "action is deleted" [ActionDeleted (GameId "g_del") "Deleted on Remote"] summary.actions,
      testCase "propagates local deletion to remote game" $ do
        let gRem = makeDummyGame (GameId "g_del") "Deleted Locally" 1000 []
        let localTombs = [(GameId "g_del", 2000)] -- deleted at 2000, remote was 1000
        let remoteCloud = CloudData {deleteIds = [], datas = [gRem]}
        let (newCloud, upserts, _, _, summary) = mergeData [] localTombs remoteCloud

        assertEqual "not upserted locally" 0 (length upserts)
        assertEqual "cloud tombstone recorded" [GameId "g_del"] newCloud.deleteIds
        assertEqual "cloud data empty" 0 (length newCloud.datas)
        assertEqual "action is deleted" [ActionDeleted (GameId "g_del") "Deleted Locally"] summary.actions
    ]

resurrectionTests :: Test
resurrectionTests =
  testGroup
    "Tombstone Resurrection"
    [ testCase "resurrects game when modified after local deletion timestamp" $ do
        let pt = PlayTimeline {start = 2500, end = 2600, duration = 100}
        let gRem = makeDummyGame (GameId "g_res") "Resurrected by Remote" 2500 [pt]
        let localTombs = [(GameId "g_res", 2000)] -- deleted locally at 2000, but played on remote at 2500
        let remoteCloud = CloudData {deleteIds = [], datas = [gRem]}
        let (newCloud, upserts, deletes, clears, summary) = mergeData [] localTombs remoteCloud

        assertEqual "upserted to restore locally" 1 (length upserts)
        assertEqual "local tombstone cleared" [GameId "g_res"] clears
        assertEqual "not in deletes" [] deletes
        assertEqual "in cloud datas" 1 (length newCloud.datas)
        assertEqual "action is resurrected" [ActionResurrected (GameId "g_res") "Resurrected by Remote"] summary.actions,
      testCase "resurrects game when played locally despite remote deletion" $ do
        let pt = PlayTimeline {start = 2500, end = 2600, duration = 100}
        let gLoc = makeDummyGame (GameId "g_res2") "Played Locally" 2500 [pt]
        let remoteCloud = CloudData {deleteIds = [GameId "g_res2"], datas = []}
        let (newCloud, _, deletes, clears, summary) = mergeData [gLoc] [] remoteCloud

        assertEqual "not deleted locally" [] deletes
        assertEqual "local tombstone cleared" [GameId "g_res2"] clears
        assertEqual "in cloud datas" 1 (length newCloud.datas)
        assertEqual "action is resurrected" [ActionResurrected (GameId "g_res2") "Played Locally"] summary.actions
    ]
