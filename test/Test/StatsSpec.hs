module Test.StatsSpec (statsTests) where

import qualified Data.Text as T
import SenaVN.Stats
import SenaVN.Types
import Test.Framework

statsTests :: Test
statsTests =
  testGroup
    "SenaVN.Stats"
    [ testCase "calculates total played time from timelines" $ do
        let pts =
              [ PlayTimeline 100 200 100,
                PlayTimeline 300 500 200,
                PlayTimeline 600 900 300
              ]
        assertEqual "total seconds" 600 (totalPlayed pts),
      testCase "calculates effective played time including live running session" $ do
        let g = makeGame "g1" [PlayTimeline 100 200 100]
        let gwlNotRunning = GameWithLocal {game = g, local = Nothing, running = Nothing}
        let gwlRunning = GameWithLocal {game = g, local = Nothing, running = Just 50}
        assertEqual "not running" 100 (effectivePlayed gwlNotRunning)
        assertEqual "with running" 150 (effectivePlayed gwlRunning),
      testCase "computes library stats for empty library" $ do
        let s = computeStats []
        assertEqual "totalGames" 0 s.totalGames
        assertEqual "configuredGames" 0 s.configuredGames
        assertEqual "playedGames" 0 s.playedGames
        assertEqual "unplayedGames" 0 s.unplayedGames
        assertEqual "totalPlaytime" 0 s.totalPlaytime
        assertEqual "totalSessions" 0 s.totalSessions
        assertEqual "avgSessionSec" 0 s.avgSessionSec
        assertEqual "topPlayed empty" 0 (length s.topPlayed),
      testCase "computes comprehensive library statistics" $ do
        let loc1 = LocalPath (GameId "g1") "game.exe" Nothing Nothing
        let loc2 = LocalPath (GameId "g2") "game2.exe" Nothing Nothing
        let g1 =
              GameWithLocal
                { game = makeGame "g1" [PlayTimeline 100 200 100, PlayTimeline 300 500 200],
                  local = Just loc1,
                  running = Nothing
                } -- 300s, 2 sess
        let g2 =
              GameWithLocal
                { game = makeGame "g2" [PlayTimeline 100 400 300],
                  local = Just loc2,
                  running = Just 300
                } -- 600s, 2 sess (1 pt + 1 running)
        let g3 =
              GameWithLocal
                { game = makeGame "g3" [],
                  local = Nothing,
                  running = Nothing
                } -- 0s, 0 sess
        let s = computeStats [g1, g2, g3]

        assertEqual "totalGames" 3 s.totalGames
        assertEqual "configuredGames" 2 s.configuredGames
        assertEqual "playedGames" 2 s.playedGames
        assertEqual "unplayedGames" 1 s.unplayedGames
        assertEqual "totalPlaytime" 900 s.totalPlaytime
        assertEqual "totalSessions" 4 s.totalSessions
        assertEqual "avgSessionSec" 225 s.avgSessionSec
        assertEqual "topPlayed count" 2 (length s.topPlayed)
        case s.topPlayed of
          [(firstGame, _), (secondGame, _)] -> do
            assertEqual "topPlayed #1 id" (GameId "g2") firstGame.game.coreId
            assertEqual "topPlayed #2 id" (GameId "g1") secondGame.game.coreId
          _ -> fail "Expected exactly 2 top played games"
    ]

makeGame :: T.Text -> [PlayTimeline] -> GameCore
makeGame gid pts =
  GameCore
    { coreId = GameId gid,
      vndbId = Nothing,
      updateDate = 1000,
      title = "Game " <> gid,
      alias = [],
      description = "",
      tags = [],
      playTimelines = pts,
      expectedPlayTime = 60,
      lastPlay = if null pts then 0 else maximum (map (.end) pts),
      createDate = 1000,
      releaseDate = 0,
      rating = 7.5,
      developer = "Dev",
      images = [],
      links = []
    }
