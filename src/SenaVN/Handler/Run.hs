module SenaVN.Handler.Run
  ( handleRun,
    handleStatus,
  )
where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.List (sortOn)
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import qualified Data.Text as T
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Command (Command (..))
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Interactive (printLn, selectGameInteractive)
import SenaVN.Pretty (bold_, dim_, green_, white_)
import qualified SenaVN.Session as Session
import SenaVN.System (spawnDaemon)
import SenaVN.Types (GameCore (..), GameId (..), GameWithLocal (..), LocalPath (..))
import SenaVN.Utils (fmtSecStr, randomOne)

handleRun :: Command -> Romi ()
handleRun Run {runTarget, runSkip, runRandom, runRecent, runLast, runFilter} = do
  conn <- askConn
  let activeFlags = length $ filter Prelude.id [isJust runTarget, runRandom, runRecent, runLast]
  when (activeFlags > 1) $
    throwR ConflictingRunFlags

  liftIO $ Session.reconcileSessions conn

  allGames <- liftIO $ DB.getAllGames conn
  when (null allGames) $ throwR EmptyLibrary

  let matchesFilter :: GameCore -> Bool
      matchesFilter g = case runFilter of
        Nothing -> True
        Just flt ->
          let fltLower = T.toLower flt
           in fltLower `T.isInfixOf` T.toLower g.title
                || any (\a -> fltLower `T.isInfixOf` T.toLower a) g.alias
                || any (\t -> fltLower `T.isInfixOf` T.toLower t) g.tags
                || fltLower `T.isInfixOf` T.toLower g.developer
      games = filter matchesFilter allGames
  when (null games) $ throwR (NoGamesMatchingFilter runFilter)

  g <- case runTarget of
    Nothing
      | runRandom ->
          liftIO (randomOne games) >>= maybe (throwR (NoGamesMatchingFilter runFilter)) pure
      | runRecent ->
          case sortOn (Down . (.lastPlay)) (filter (\x -> x.lastPlay > 0) games) of
            [] -> throwR NoGamesPlayedYet
            (x : _) -> pure x
      | runLast ->
          case sortOn (Down . (.createDate)) games of
            [] -> throwR (NoGamesMatchingFilter runFilter)
            (x : _) -> pure x
      | isJust runFilter ->
          liftIO (randomOne games) >>= maybe (throwR (NoGamesMatchingFilter runFilter)) pure
      | otherwise ->
          throwR MissingRunTarget

    Just target -> do
      mExact <- liftIO $ DB.getGame conn (GameId target)
      case mExact of
        Just exactGame -> pure exactGame
        Nothing ->
          if runSkip
            then throwR (GameNotFound (GameId target))
            else do
              allWithLocal <- liftIO $ DB.getAllGamesWithLocal conn
              let configured = filter (isJust . (.local)) allWithLocal
                  targetLower = T.toLower target
                  matches =
                    filter
                      ( \gwl ->
                          targetLower `T.isInfixOf` T.toLower gwl.game.title
                            || any (\a -> targetLower `T.isInfixOf` T.toLower a) gwl.game.alias
                      )
                      configured
              case matches of
                [] -> throwR (GameTargetNotFound target)
                [single] -> pure single.game
                multiple -> liftIO $ selectGameInteractive target multiple

  mLocal <- liftIO $ DB.getLocalPath conn g.coreId
  case mLocal of
    Nothing -> throwR (ExeNotConfigured g.coreId g.title)
    Just lp -> do
      mSess <- liftIO $ Session.readSession g.coreId
      case mSess of
        Just sess -> do
          alive <- liftIO $ Session.isPidAlive sess.guardPid
          when alive $
            throwR (GameAlreadyRunning g.coreId g.title sess.guardPid)
        Nothing -> pure ()
      liftIO $ do
        spawnDaemon g.coreId g.title lp.programFile
        printLn $
          annotate (color Green <> bold) "▶"
            <+> bold_ (white_ (pretty g.title))
            <+> annotate (color Magenta) (pretty ("(#" <> g.coreId.unGameId <> ")"))
            <> line
            <> dim_ ("  ↳ " <> pretty lp.programFile)
handleRun _ = pure ()

handleStatus :: Romi ()
handleStatus = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  sessions <- liftIO Session.listSessions
  if null sessions
    then liftIO $ printLn (dim_ "no games running.")
    else liftIO $ forM_ sessions $ \s -> do
      alive <- Session.isPidAlive s.guardPid
      mGame <- DB.getGame conn s.gameId
      let titleDoc = case mGame of
            Just g -> bold_ (white_ (pretty g.title)) <+> annotate (color Magenta) (pretty ("(#" <> s.gameId.unGameId <> ")"))
            Nothing -> bold_ (white_ (pretty s.gameId.unGameId))
      printLn $
        (if alive then annotate (color Green <> bold) "▶" else annotate (color Yellow) "?")
          <+> titleDoc
          <+> dim_ "·"
          <+> green_ (pretty (fmtSecStr s.activeSeconds))
          <+> dim_ ("(PID " <> pretty s.guardPid <> ")")
