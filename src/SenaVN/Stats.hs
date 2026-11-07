module SenaVN.Stats
  ( LibraryStats (..),
    computeStats,
    totalPlayed,
    effectivePlayed,
  )
where

import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import SenaVN.Types

data LibraryStats = LibraryStats
  { totalGames :: !Int,
    configuredGames :: !Int,
    playedGames :: !Int,
    unplayedGames :: !Int,
    totalPlaytime :: !Seconds,
    totalSessions :: !Int,
    avgSessionSec :: !Seconds,
    topPlayed :: ![(GameWithLocal, Seconds)]
  }
  deriving (Show, Eq)

totalPlayed :: [PlayTimeline] -> Seconds
totalPlayed = sum . map (.duration)

effectivePlayed :: GameWithLocal -> Seconds
effectivePlayed gwl =
  totalPlayed gwl.game.playTimelines + fromMaybe 0 gwl.running

computeStats :: [GameWithLocal] -> LibraryStats
computeStats games =
  let tot = length games
      configured = length $ filter (isJust . (.local)) games
      withPlay = filter (\g -> effectivePlayed g > 0) games
      playedCount = length withPlay
      unplayedCount = tot - playedCount
      totalSec = sum (map effectivePlayed games)
      allSessions = concatMap (\g -> g.game.playTimelines) games
      totSessions = length allSessions + length (filter (isJust . (.running)) games)
      avgSec = if totSessions > 0 then totalSec `div` totSessions else 0
      top5 = take 5 . sortOn (Down . snd) $ map (\g -> (g, effectivePlayed g)) withPlay
   in LibraryStats
        { totalGames = tot,
          configuredGames = configured,
          playedGames = playedCount,
          unplayedGames = unplayedCount,
          totalPlaytime = totalSec,
          totalSessions = totSessions,
          avgSessionSec = avgSec,
          topPlayed = top5
        }
