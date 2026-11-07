{-# LANGUAGE NamedFieldPuns #-}

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
import Data.List (sortOn)
import Prettyprinter
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command (Command (..), SortField (..))
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Handler.Common (attachRunningSessions)
import SenaVN.Pretty
  ( bold_,
    dim_,
    fmtTimeline,
    printFetchResult,
    printFetchResults,
    printGame,
    printGameStat,
    printGames,
    printLibraryStats,
    render,
    white_,
  )
import qualified SenaVN.Session as Session
import SenaVN.Stats (effectivePlayed)
import SenaVN.Types (GameCore (..), GameId (..), GameWithLocal (..), VndbBy (..))

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
handleTimeline Timeline {tlCoreIds, tlFilter = _} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  all' <- liftIO $ DB.getAllGames conn
  let targets =
        if null tlCoreIds
          then all'
          else filter (\g -> g.coreId `elem` tlCoreIds) all'
  when (null targets) $ throwR (NoMatchingGamesFound tlCoreIds)
  liftIO $ forM_ targets $ \g ->
    render $
      vsep
        [ bold_ (white_ (pretty g.title))
            <+> dim_ (pretty ("(#" <> g.coreId.unGameId <> ")"))
            <+> dim_ ("· " <> pretty (show (length g.playTimelines) <> " session(s)")),
          if null g.playTimelines
            then indent 2 (dim_ "no recorded play sessions.")
            else indent 2 $ vsep (map fmtTimeline (reverse g.playTimelines)),
          emptyDoc
        ]
handleTimeline _ = pure ()

handleSync :: Romi ()
handleSync =
  throwR (NotImplemented "cloud sync")
