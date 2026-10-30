{-# LANGUAGE NamedFieldPuns #-}

module SenaVN.Handler (handle) where

import Control.Applicative ((<|>))
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.List (sortOn, uncons)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Pretty
import qualified SenaVN.Session as Session
import SenaVN.Types
import SenaVN.Utils (randomOne)
import System.Console.Haskeline (defaultSettings, getInputLine, runInputT)
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hClose, stdout)
import System.IO.Temp (withSystemTempFile)
import System.Process (CreateProcess (..), StdStream (..), callProcess, createProcess, proc)

now :: IO Int
now = round <$> getPOSIXTime

requireGame :: Text -> Romi GameCore
requireGame gid = do
  conn <- askConn
  mg <- liftIO $ DB.getGame conn gid
  case mg of
    Nothing -> throwR ("game not found: " <> gid)
    Just g -> pure g

setupLocal :: Text -> Maybe Text -> Romi ()
setupLocal _ Nothing = pure ()
setupLocal gid (Just path) = do
  conn <- askConn
  liftIO $
    DB.upsertLocalPath
      conn
      LocalPath
        { localId = GameId gid,
          programFile = path,
          savePath = Nothing,
          guideFile = Nothing
        }

pickResult :: Int -> [a] -> Maybe a
pickResult _ [] = Nothing
pickResult n xs
  | n >= 1 && n <= length xs = Just (xs !! (n - 1))
  | otherwise = fst <$> uncons xs

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
      links = map (\l -> Link {name = l.name, url = l.url}) f.links
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

emptyGameCore :: Text -> Text -> Int -> GameCore
emptyGameCore gid name ts =
  GameCore
    { coreId = GameId gid,
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

findEditor :: IO (Maybe FilePath)
findEditor = do
  mVisual <- lookupEnv "VISUAL"
  mEditor <- lookupEnv "EDITOR"
  case filter (not . null) (maybe [] pure mVisual ++ maybe [] pure mEditor) of
    (ed : _) -> pure (Just ed)
    [] -> findInPath ["nvim", "vim", "nano", "vi"]
  where
    findInPath [] = pure Nothing
    findInPath (x : xs) = do
      mPath <- findExecutable x
      case mPath of
        Just _ -> pure (Just x)
        Nothing -> findInPath xs

openEditor :: GameCore -> Romi GameCore
openEditor g = do
  mEditor <- liftIO findEditor
  editor <- case mEditor of
    Nothing ->
      throwR "no editor found: please set $VISUAL or $EDITOR, or install nvim/vim/nano/vi"
    Just ed -> pure ed
  raw <- liftIO $
    withSystemTempFile "sena-edit-.json" $ \path h -> do
      BL.hPut h (encodePretty g)
      hClose h
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      callProcess prog (args ++ [path])
      BL.readFile path
  case eitherDecode raw of
    Left err -> throwR ("parse error after editor: " <> T.pack err)
    Right g' ->
      pure
        g'
          { coreId = g.coreId,
            createDate = g.createDate,
            playTimelines = g.playTimelines
          }

spawnFoo :: Text -> Text -> Text -> IO ()
spawnFoo gameId gameName exePath = do
  sessDir <- Session.getSessionsDir
  fooExe <- Session.getFooPath
  let sessionFile = sessDir </> T.unpack gameId <> ".session.json"
  _ <-
    createProcess
      ( proc
          fooExe
          [ "--run",
            "--game-id",
            T.unpack gameId,
            "--game-name",
            T.unpack gameName,
            "--exe-path",
            T.unpack exePath,
            "--session",
            sessionFile
          ]
      )
        { std_in = NoStream,
          std_out = NoStream,
          std_err = NoStream,
          create_group = True,
          detach_console = True
        }
  pure ()

render :: Doc AnsiStyle -> IO ()
render = renderIO stdout . layoutPretty defaultLayoutOptions

printLn :: Doc AnsiStyle -> IO ()
printLn d = render (d <> line)

ok :: Doc AnsiStyle -> IO ()
ok msg = printLn $ annotate (color Green) "✓" <+> msg

askConfirmation :: Text -> IO Bool
askConfirmation prompt = do
  ans <- runInputT defaultSettings (getInputLine (T.unpack prompt))
  case ans of
    Just s ->
      let trimmed = T.toLower (T.strip (T.pack s))
       in pure (trimmed == "y" || trimmed == "yes")
    Nothing -> pure False

handle :: Command -> Romi ()
handle Add {addName, addCoreId, addPath, addNoFetch, addSkip, addOrder, addKeepName, addMeta} = do
  conn <- askConn
  existing <- liftIO $ DB.getGame conn addCoreId
  when (isJust existing) $ throwR ("id already exists: " <> addCoreId)
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
            results <- liftIO $ fetchFromVndb (VndbName addName)
            case pickResult addOrder results of
              Nothing -> throwR "no VNDB results found"
              Just fd -> do
                let fetched = applyFetch addKeepName base fd
                if addSkip
                  then pure fetched
                  else openEditor fetched

  liftIO $ DB.insertGame conn finalGame
  setupLocal addCoreId addPath
  liftIO $ ok $ bold_ (pretty finalGame.title) <+> dim_ "added."

handle Edit {editCoreId, editFetch, editApply, editOrder, editKeepName, editMeta} = do
  conn <- askConn
  g <- requireGame editCoreId
  ts <- liftIO now

  finalGame <-
    if hasMeta editMeta
      then pure (applyMeta g editMeta)
      else
        if editFetch
          then do
            results <- liftIO $ fetchFromVndb (VndbName g.title)
            case pickResult editOrder results of
              Nothing -> throwR "no VNDB results found"
              Just fd -> do
                let fetched = applyFetch editKeepName g fd
                if editApply
                  then pure fetched
                  else openEditor fetched
          else openEditor g

  liftIO $ do
    DB.updateGame conn (finalGame {updateDate = ts})
    ok $ bold_ (pretty finalGame.title) <+> dim_ "updated."

handle Remove {removeCoreId, removeHard} = do
  conn <- askConn
  g <- requireGame removeCoreId
  confirmed <- liftIO $ askConfirmation ("Are you sure you want to delete '" <> g.title <> "'? [y/N] ")
  if not confirmed
    then liftIO $ printLn (dim_ "operation cancelled.")
    else liftIO $ do
      DB.deleteGame conn removeCoreId
      ok $
        bold_ (pretty g.title)
          <+> dim_ "removed."
          <> if removeHard then dim_ " (TODO: cloud remove)" else mempty

handle Run {runTarget, runRandom, runRecent, runLast} = do
  conn <- askConn
  let activeFlags = length $ filter Prelude.id [isJust runTarget, runRandom, runRecent, runLast]
  when (activeFlags > 1) $
    throwR "only one of <id> / --random / --recent / --last can be specified"

  liftIO $ Session.reconcileSessions conn

  games <- liftIO $ DB.getAllGames conn
  when (null games) $ throwR "library is empty"

  g <- case runTarget of
    Just gid -> requireGame gid
    Nothing
      | runRandom ->
          liftIO (randomOne games) >>= maybe (throwR "no games available") pure
      | runRecent ->
          case sortOn (Down . (.lastPlay)) (filter (\x -> x.lastPlay > 0) games) of
            [] -> throwR "no games played yet"
            (x : _) -> pure x
      | runLast ->
          case sortOn (Down . (.createDate)) games of
            [] -> throwR "library is empty"
            (x : _) -> pure x
      | otherwise ->
          throwR "specify a game ID or use --random / --recent / --last"

  mLocal <- liftIO $ DB.getLocalPath conn g.coreId.unGameId
  case mLocal of
    Nothing ->
      throwR $
        "no exe set for "
          <> g.title
          <> " — run: sena use "
          <> g.coreId.unGameId
          <> " <path>"
    Just lp -> do
      mSess <- liftIO $ Session.readSession g.coreId.unGameId
      case mSess of
        Just sess -> do
          alive <- liftIO $ Session.isPidAlive sess.fooPid
          when alive $
            throwR $
              "game is already running: "
                <> g.title
                <> " (PID: "
                <> T.pack (show sess.fooPid)
                <> ")"
        Nothing -> pure ()
      liftIO $ do
        spawnFoo g.coreId.unGameId g.title lp.programFile
        printLn $
          annotate (color Green) "▶"
            <+> bold_ (pretty g.title)
            <> line
            <> dim_ (pretty lp.programFile)

handle Fetch {fetchName, fetchOrder} = do
  results <- liftIO $ fetchFromVndb (VndbName fetchName)
  when (null results) $ throwR "no results found"
  case fetchOrder of
    0 -> liftIO $ printFetchResults results
    n
      | n >= 1 && n <= length results ->
          liftIO $ printFetchResult n (results !! (n - 1))
      | otherwise ->
          throwR $
            "invalid --order "
              <> T.pack (show n)
              <> ", got "
              <> T.pack (show (length results))
              <> " results"

handle List {listSort, listReverse, listFilter = _, listDetail} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  games <- liftIO $ DB.getAllGamesWithLocal conn
  sorted <- case listSort of
    "title" -> pure $ sortOn (\g -> g.game.title) games
    "lastPlay" -> pure $ sortOn (\g -> g.game.lastPlay) games
    "createDate" -> pure $ sortOn (\g -> g.game.createDate) games
    "releaseDate" -> pure $ sortOn (\g -> g.game.releaseDate) games
    "rating" -> pure $ sortOn (\g -> g.game.rating) games
    other ->
      throwR $
        "unknown sort field: "
          <> other
          <> "  valid: title|lastPlay|createDate|releaseDate|rating"
  let ordered = if listReverse then reverse sorted else sorted
  liftIO $
    if listDetail
      then forM_ ordered printGame
      else printGames ordered

handle Stats {statsCoreIds, statsFilter = _} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  all' <- liftIO $ DB.getAllGamesWithLocal conn
  let targets =
        if null statsCoreIds
          then all'
          else filter (\g -> g.game.coreId.unGameId `elem` statsCoreIds) all'
  when (null targets) $ throwR "no matching games"
  liftIO $ forM_ targets printGame

handle Timeline {tlCoreIds, tlFilter = _} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  all' <- liftIO $ DB.getAllGames conn
  let targets =
        if null tlCoreIds
          then all'
          else filter (\g -> g.coreId.unGameId `elem` tlCoreIds) all'
  when (null targets) $ throwR "no matching games"
  liftIO $ forM_ targets $ \g ->
    render $
      vsep
        [ bold_ (pretty g.title)
            <+> dim_ (pretty (T.pack (show (length g.playTimelines)) <> " sessions")),
          indent 2 $ vsep (map tlRow g.playTimelines),
          emptyDoc
        ]
  where
    tlRow :: PlayTimeline -> Doc AnsiStyle
    tlRow tl =
      dim_ "·"
        <+> fmtDate tl.start
        <+> dim_ "→"
        <+> fmtDate tl.end
        <+> dim_ "|"
        <+> fmtSeconds tl.duration

handle Use {useCoreId, useExePath, useSavePath, useGuide} = do
  conn <- askConn
  _ <- requireGame useCoreId
  liftIO $ do
    DB.upsertLocalPath
      conn
      LocalPath
        { localId = GameId useCoreId,
          programFile = useExePath,
          savePath = useSavePath,
          guideFile = useGuide
        }
    ok $ dim_ "exe →" <+> pretty useExePath

handle Info {infoCoreId} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  mgwl <- liftIO $ DB.getGameWithLocal conn infoCoreId
  case mgwl of
    Nothing -> throwR ("game not found: " <> infoCoreId)
    Just gwl -> liftIO $ printGame gwl

handle Status = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  sessions <- liftIO Session.listSessions
  if null sessions
    then liftIO $ printLn (dim_ "no games running.")
    else liftIO $ forM_ sessions $ \s -> do
      alive <- Session.isPidAlive s.fooPid
      printLn $
        (if alive then annotate (color Green) "●" else annotate (color Yellow) "?")
          <+> bold_ (pretty s.gameId)
          <+> dim_ "|"
          <+> fmtSeconds s.activeSeconds
          <+> dim_ ("pid " <> pretty s.fooPid)

handle Sync =
  throwR "sync not yet implemented"

handle Config {} =
  throwR "config not yet implemented"
