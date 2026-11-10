module Test.TypesSpec (typesTests) where

import Data.Aeson (decode, encode)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import SenaVN.Types
import Test.Framework

typesTests :: Test
typesTests =
  testGroup
    "SenaVN.Types"
    [ playTimelineTests,
      gameCoreTests,
      cloudDataTests
    ]

playTimelineTests :: Test
playTimelineTests =
  testGroup
    "PlayTimeline JSON"
    [ testCase "parses from 3-element array format" $ do
        let jsonStr = "[1700000000, 1700003600, 3600]"
        case (decode jsonStr :: Maybe PlayTimeline) of
          Nothing -> fail "Failed to parse array format"
          Just pt -> do
            assertEqual "start" 1700000000 (pt.start :: Int)
            assertEqual "end" 1700003600 (pt.end :: Int)
            assertEqual "duration" 3600 (pt.duration :: Seconds),
      testCase "parses from object format" $ do
        let jsonStr = "{\"start\": 100, \"end\": 200, \"duration\": 100}"
        case (decode jsonStr :: Maybe PlayTimeline) of
          Nothing -> fail "Failed to parse object format"
          Just pt -> do
            assertEqual "start" 100 (pt.start :: Int)
            assertEqual "end" 200 (pt.end :: Int)
            assertEqual "duration" 100 (pt.duration :: Seconds),
      testCase "rejects invalid array formats" $ do
        let tooFew = "[100, 200]"
        let tooMany = "[100, 200, 100, 50]"
        assertEqual "too few elements" (Nothing :: Maybe PlayTimeline) (decode tooFew)
        assertEqual "too many elements" (Nothing :: Maybe PlayTimeline) (decode tooMany),
      testCase "serializes to array format" $ do
        let pt = PlayTimeline {start = 10, end = 20, duration = 10}
        assertEqual "json encoding" "[10,20,10]" (BL.toStrict (encode pt))
    ]

gameCoreTests :: Test
gameCoreTests =
  testGroup
    "GameCore JSON"
    [ testCase "parses game with 'id' field" $ do
        let jsonStr = "{\"id\": \"g1\", \"title\": \"Game One\"}"
        case (decode jsonStr :: Maybe GameCore) of
          Nothing -> fail "Failed to parse GameCore with id"
          Just g -> do
            assertEqual "coreId" (GameId "g1") g.coreId
            assertEqual "title" "Game One" g.title,
      testCase "parses game with 'coreId' field fallback" $ do
        let jsonStr = "{\"coreId\": \"g2\", \"title\": \"Game Two\"}"
        case (decode jsonStr :: Maybe GameCore) of
          Nothing -> fail "Failed to parse GameCore with coreId"
          Just g -> do
            assertEqual "coreId" (GameId "g2") g.coreId
            assertEqual "title" "Game Two" g.title,
      testCase "converts expectedPlayHours into minutes" $ do
        let jsonStr = "{\"id\": \"g3\", \"title\": \"Game Three\", \"expectedPlayHours\": 2.5}"
        case (decode jsonStr :: Maybe GameCore) of
          Nothing -> fail "Failed to parse expectedPlayHours"
          Just g -> assertEqual "expectedPlayTime in minutes" 150 g.expectedPlayTime,
      testCase "converts millisecond timestamps into seconds" $ do
        let jsonStr = "{\"id\": \"g4\", \"title\": \"Game Four\", \"lastPlay\": 1700000000000}"
        case (decode jsonStr :: Maybe GameCore) of
          Nothing -> fail "Failed to parse ms timestamp"
          Just g -> assertEqual "lastPlay in seconds" 1700000000 g.lastPlay,
      testCase "filters out data: URI covers and images" $ do
        let jsonStr =
              "{\"id\": \"g5\", \"title\": \"Game Five\", \"cover\": \"data:image/png;base64,...\", \"images\": [\"https://example.com/valid.jpg\", \"data:image/jpeg;base64,...\"]}"
        case (decode jsonStr :: Maybe GameCore) of
          Nothing -> fail "Failed to parse images with data URIs"
          Just g -> assertEqual "images filtered" ["https://example.com/valid.jpg"] (g.images :: [T.Text])
    ]

cloudDataTests :: Test
cloudDataTests =
  testGroup
    "CloudData JSON"
    [ testCase "parses object format with deleteIds and data" $ do
        let jsonStr = "{\"deleteIds\": [\"del1\"], \"data\": [{\"id\": \"g1\", \"title\": \"T1\"}]}"
        case (decode jsonStr :: Maybe CloudData) of
          Nothing -> fail "Failed to parse CloudData object"
          Just cd -> do
            assertEqual "deleteIds" [GameId "del1"] cd.deleteIds
            assertEqual "data count" 1 (length cd.datas),
      testCase "parses legacy array format fallback" $ do
        let jsonStr = "[{\"id\": \"g1\", \"title\": \"Legacy Title\"}]"
        case (decode jsonStr :: Maybe CloudData) of
          Nothing -> fail "Failed to parse legacy array format"
          Just cd -> do
            assertEqual "deleteIds empty" [] cd.deleteIds
            assertEqual "data count" 1 (length cd.datas),
      testCase "roundtrips CloudData serialization" $ do
        let orig =
              CloudData
                { deleteIds = [GameId "d1"],
                  datas =
                    [ GameCore
                        { coreId = GameId "g1",
                          vndbId = Nothing,
                          updateDate = 100,
                          title = "Roundtrip Game",
                          alias = [],
                          description = "",
                          tags = [],
                          playTimelines = [PlayTimeline 10 20 10],
                          expectedPlayTime = 60,
                          lastPlay = 20,
                          createDate = 50,
                          releaseDate = 0,
                          rating = 8.5,
                          developer = "Dev",
                          images = [],
                          links = []
                        }
                    ]
                }
        let encoded = encode orig
        case (decode encoded :: Maybe CloudData) of
          Nothing -> fail "Failed to roundtrip CloudData"
          Just decoded -> assertEqual "roundtrip equals" orig decoded
    ]
