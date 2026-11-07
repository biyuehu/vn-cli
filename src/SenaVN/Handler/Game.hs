{-# LANGUAGE NamedFieldPuns #-}

module SenaVN.Handler.Game
  ( handleAdd,
    handleEdit,
    handleRemove,
    handleMove,
    handleUse,
    handleInfo,
    setupLocal,
    applyFetch,
    applyMeta,
    emptyGameCore,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isAlphaNum)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command (Command (..), MetaOptions (..), hasMeta)
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Handler.Common (attachRunningSessions, requireGame)
import SenaVN.Interactive (askConfirmation, ok, printLn, selectFetchInteractive)
import SenaVN.Pretty (bold_, cyan_, dim_, printGame, white_)
import qualified SenaVN.Session as Session
import SenaVN.System (openEditor, openGameGuide, openGameSave)
import SenaVN.Types
  ( FetchGameData (..),
    GameCore (..),
    GameId (..),
    LocalPath (..),
    VndbBy (..),
  )
import SenaVN.Utils (now, pickResult)

setupLocal :: GameId -> Maybe Text -> Romi ()
setupLocal _ Nothing = pure ()
setupLocal gid (Just path) = do
  conn <- askConn
  liftIO $
    DB.upsertLocalPath
      conn
      LocalPath
        { localId = gid,
          programFile = path,
          savePath = Nothing,
          guideFile = Nothing
        }

applyFetch :: Bool -> GameCore -> FetchGameData -> GameCore
applyFetch keepName g f =
  g
    { vndbId = Just f.vndbId,
      title = if keepName then g.title else f.title,
      alias = f.alias,
      description = f.description,
      tags = f.tags,
      expectedPlayTime = round (f.expectedPlayHours * 60),
      releaseDate = f.releaseDate,
      rating = f.rating,
      developer = f.developer,
      images = f.images,
      links = f.links
    }

applyMeta :: GameCore -> MetaOptions -> GameCore
applyMeta g m =
  g
    { coreId = g.coreId,
      vndbId = m.metaVndbId <|> g.vndbId,
      developer = fromMaybe g.developer m.metaDeveloper,
      releaseDate = fromMaybe g.releaseDate m.metaReleaseDate,
      rating = fromMaybe g.rating m.metaRating,
      description = fromMaybe g.description m.metaDescription,
      tags = if null m.metaTags then g.tags else m.metaTags
    }

emptyGameCore :: GameId -> Text -> Int -> GameCore
emptyGameCore gid name ts =
  GameCore
    { coreId = gid,
      vndbId = Nothing,
      title = name,
      alias = [],
      description = "",
      tags = [],
      images = [],
      links = [],
      playTimelines = [],
      expectedPlayTime = 0,
      lastPlay = 0,
      createDate = ts,
      updateDate = ts,
      releaseDate = 0,
      rating = 0.0,
      developer = ""
    }

handleAdd :: Command -> Romi ()
handleAdd Add {addName, addCoreId, addPath, addNoFetch, addSkip, addOrder, addKeepName, addMeta} = do
  conn <- askConn
  existing <- liftIO $ DB.getGame conn addCoreId
  when (isJust existing) $ throwR (GameAlreadyExists addCoreId)
  ts <- liftIO now
  let base = emptyGameCore addCoreId addName ts

  finalGame <-
    if hasMeta addMeta
      then pure (applyMeta base addMeta)
      else
        if addNoFetch
          then
            if addSkip
              then pure base
              else openEditor base
          else do
            mProxy <- liftIO $ DB.getTypedConfig conn DB.FetchProxy
            results <- liftIO $ fetchFromVndb mProxy (VndbName addName)
            when (null results) $ throwR (VndbNoResults addName)
            selected <-
              if addOrder /= 1 || addSkip
                then case pickResult addOrder results of
                  Nothing -> throwR (VndbNoResults addName)
                  Just fd -> pure fd
                else case results of
                  [single] -> pure single
                  _ -> liftIO $ selectFetchInteractive addName results
            let fetched = applyFetch addKeepName base selected
            if addSkip
              then pure fetched
              else openEditor fetched

  liftIO $ DB.insertGame conn finalGame
  setupLocal addCoreId addPath
  liftIO $ ok $ bold_ (white_ (pretty finalGame.title)) <+> dim_ "added."
handleAdd _ = pure ()

handleEdit :: Command -> Romi ()
handleEdit Edit {editCoreId, editFetch, editApply, editOrder, editKeepName, editMeta} = do
  conn <- askConn
  g <- requireGame editCoreId
  ts <- liftIO now

  finalGame <-
    if hasMeta editMeta
      then pure (applyMeta g editMeta)
      else
        if editFetch
          then do
            mProxy <- liftIO $ DB.getTypedConfig conn DB.FetchProxy
            results <- liftIO $ fetchFromVndb mProxy (VndbName g.title)
            when (null results) $ throwR (VndbNoResults g.title)
            selected <-
              if editOrder /= 1 || editApply
                then case pickResult editOrder results of
                  Nothing -> throwR (VndbNoResults g.title)
                  Just fd -> pure fd
                else case results of
                  [single] -> pure single
                  _ -> liftIO $ selectFetchInteractive g.title results
            let fetched = applyFetch editKeepName g selected
            if editApply
              then pure fetched
              else openEditor fetched
          else openEditor g

  liftIO $ do
    DB.updateGame conn (finalGame {updateDate = ts})
    ok $ bold_ (white_ (pretty finalGame.title)) <+> dim_ "updated."
handleEdit _ = pure ()

handleRemove :: Command -> Romi ()
handleRemove Remove {removeCoreId, removeHard} = do
  conn <- askConn
  g <- requireGame removeCoreId
  confirmed <-
    liftIO $
      askConfirmation
        ( "Are you sure you want to delete"
            <+> bold_ (white_ (pretty ("'" <> g.title <> "'")))
            <> "?"
        )
  if not confirmed
    then liftIO $ printLn (annotate (color Yellow) "!" <+> dim_ "operation cancelled.")
    else liftIO $ do
      DB.deleteGame conn removeCoreId
      Session.deleteSession removeCoreId
      ok $
        bold_ (white_ (pretty g.title))
          <+> dim_ "removed."
          <> if removeHard then dim_ " (TODO: cloud remove)" else mempty
handleRemove _ = pure ()

handleMove :: Command -> Romi ()
handleMove Move {moveOldId, moveNewId} = do
  conn <- askConn
  when (moveOldId == moveNewId) $
    throwR (InvalidNewGameId moveNewId "new ID must be different from old ID")
  when (T.null (T.strip moveNewId.unGameId)) $
    throwR (InvalidNewGameId moveNewId "new ID cannot be empty")
  unless (T.all (\c -> isAlphaNum c || c == '-' || c == '_') moveNewId.unGameId) $
    throwR (InvalidNewGameId moveNewId "new ID must contain only letters, numbers, hyphens, or underscores")
  g <- requireGame moveOldId
  existingNew <- liftIO $ DB.getGame conn moveNewId
  when (isJust existingNew) $
    throwR (GameAlreadyExists moveNewId)
  mRunning <- liftIO $ Session.readSession moveOldId
  case mRunning of
    Just sess -> do
      alive <- liftIO $ Session.isPidAlive sess.guardPid
      when alive $
        throwR (GameAlreadyRunning moveOldId g.title sess.guardPid)
    Nothing -> pure ()
  liftIO $ Session.reconcileSessions conn
  ts <- liftIO now
  liftIO $ DB.renameGame conn moveOldId moveNewId ts
  liftIO $ Session.renameSession moveOldId moveNewId
  liftIO $
    ok $
      bold_ (white_ (pretty g.title))
        <+> dim_ "renamed:"
        <+> annotate (color Magenta) (pretty ("#" <> moveOldId.unGameId))
        <+> dim_ "→"
        <+> annotate (color Cyan <> bold) (pretty ("#" <> moveNewId.unGameId))
handleMove _ = pure ()

handleUse :: Command -> Romi ()
handleUse Use {useCoreId, useExePath, useSavePath, useGuide} = do
  conn <- askConn
  g <- requireGame useCoreId
  liftIO $ do
    DB.upsertLocalPath
      conn
      LocalPath
        { localId = useCoreId,
          programFile = useExePath,
          savePath = useSavePath,
          guideFile = useGuide
        }
    ok $
      bold_ (white_ (pretty g.title))
        <+> annotate (color Magenta) (pretty ("(#" <> useCoreId.unGameId <> ")"))
        <+> dim_ "linked →"
        <+> cyan_ (pretty useExePath)
handleUse _ = pure ()

handleInfo :: Command -> Romi ()
handleInfo Info {infoCoreId, infoGuide, infoSave} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  mgwl <- liftIO $ DB.getGameWithLocal conn infoCoreId
  case mgwl of
    Nothing -> throwR (GameNotFound infoCoreId)
    Just gwl -> do
      if infoGuide || infoSave
        then do
          when infoGuide $ openGameGuide conn gwl
          when infoSave $ openGameSave gwl
        else do
          liveGwls <- liftIO $ attachRunningSessions [gwl]
          case listToMaybe liveGwls of
            Just live -> liftIO $ printGame live
            Nothing -> liftIO $ printGame gwl
handleInfo _ = pure ()
