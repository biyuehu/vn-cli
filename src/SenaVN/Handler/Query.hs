module SenaVN.Handler.Query
  ( handleList,
    handleStats,
    handleTimeline,
    handleFetch,
    handleSync,
  )
where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.List (mapAccumL, sortOn)
import Data.Ord (Down (..))
import Data.Time (getCurrentTimeZone, localDay, utcToLocalTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command (Command (..), SortField (..))
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Handler.Common (attachRunningSessions)
import SenaVN.Pretty
  ( TimelineItem (..),
    prettyTimelineGraphW,
    prettyTimelineOnelineW,
    printFetchResult,
    printFetchResults,
    printGame,
    printGameStat,
    printGames,
    printLibraryStats,
  )
import qualified SenaVN.Session as Session
import SenaVN.Stats (effectivePlayed)
import SenaVN.System (runWithPager)
import SenaVN.Types (GameCore (..), GameWithLocal (..), PlayTimeline (..), VndbBy (..))
import SenaVN.Utils (formatRelativeTime, getTermWidth, now)

handleFetch :: Command -> Romi ()
handleFetch Fetch {fetchName, fetchOrder} = do
  conn <- askConn
  mProxy <- liftIO $ DB.getTypedConfig conn DB.FetchProxy
  results <- liftIO $ fetchFromVndb mProxy (VndbName fetchName)
  when (null results) $ throwR (VndbNoResults fetchName)
  case fetchOrder of
    0 -> liftIO $ printFetchResults results
    n
      | n >= 1 && n <= length results ->
          liftIO $ printFetchResult n (results !! (n - 1))
      | otherwise ->
          throwR (VndbInvalidOrder n (length results))
handleFetch _ = pure ()

handleList :: Command -> Romi ()
handleList List {listSort, listReverse, listFilter = _, listDetail} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  rawGames <- liftIO $ DB.getAllGamesWithLocal conn
  games <- liftIO $ attachRunningSessions rawGames
  let sorted = case listSort of
        SortTitle -> sortOn (\g -> g.game.title) games
        SortLastPlay -> sortOn (\g -> g.game.lastPlay) games
        SortCreateDate -> sortOn (\g -> g.game.createDate) games
        SortReleaseDate -> sortOn (\g -> g.game.releaseDate) games
        SortRating -> sortOn (\g -> g.game.rating) games
        SortPlayed -> sortOn effectivePlayed games
  let ordered = if listReverse then reverse sorted else sorted
  liftIO $
    if listDetail
      then forM_ ordered printGame
      else printGames ordered
handleList _ = pure ()

handleStats :: Command -> Romi ()
handleStats Stats {statsCoreIds, statsFilter = _} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  rawGames <- liftIO $ DB.getAllGamesWithLocal conn
  allGames <- liftIO $ attachRunningSessions rawGames
  if null statsCoreIds
    then liftIO $ printLibraryStats allGames
    else do
      let targets = filter (\g -> g.game.coreId `elem` statsCoreIds) allGames
      when (null targets) $ throwR (NoMatchingGamesFound statsCoreIds)
      liftIO $ forM_ targets printGameStat
handleStats _ = pure ()

handleTimeline :: Command -> Romi ()
handleTimeline Timeline {tlCoreIds, tlFilter = _, tlMaxCount, tlOneline, tlToday, tlReverse, tlNoPager} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  allGames <- liftIO $ DB.getAllGames conn
  let targets =
        if null tlCoreIds
          then allGames
          else filter (\g -> g.coreId `elem` tlCoreIds) allGames
  when (null targets) $ throwR (NoMatchingGamesFound tlCoreIds)

  nowTs <- liftIO now
  tz <- liftIO getCurrentTimeZone
  let todayDay = localDay (utcToLocalTime tz (posixSecondsToUTCTime (fromIntegral nowTs)))

  let annotateGame :: GameCore -> [TimelineItem]
      annotateGame g =
        let sortedChronological = sortOn (.start) g.playTimelines
            scanStep acc tl =
              let newAcc = acc + tl.duration
               in ( newAcc,
                    TimelineItem
                      { itemGameId = g.coreId,
                        itemTitle = g.title,
                        itemTimeline = tl,
                        itemAccumSec = newAcc,
                        itemExpectedMin = g.expectedPlayTime,
                        itemRelative = formatRelativeTime nowTs tl.start
                      }
                  )
         in snd (mapAccumL scanStep 0 sortedChronological)

      allItems = concatMap annotateGame targets

      filteredToday =
        if tlToday
          then
            filter
              ( \it ->
                  let itemDay = localDay (utcToLocalTime tz (posixSecondsToUTCTime (fromIntegral it.itemTimeline.start)))
                   in itemDay == todayDay
              )
              allItems
          else allItems

      sortedItems =
        if tlReverse
          then sortOn (\it -> it.itemTimeline.start) filteredToday
          else sortOn (Down . (\it -> it.itemTimeline.start)) filteredToday

      finalItems = case tlMaxCount of
        Just n | n > 0 -> take n sortedItems
        _ -> sortedItems

  w <- liftIO getTermWidth
  let doc =
        if tlOneline
          then prettyTimelineOnelineW w finalItems
          else prettyTimelineGraphW w finalItems

  liftIO $ runWithPager tlNoPager doc
handleTimeline _ = pure ()

handleSync :: Romi ()
handleSync =
  throwR (NotImplemented "cloud sync")
