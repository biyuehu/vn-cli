{-# LANGUAGE NamedFieldPuns #-}

module SenaVN.Handler (handle) where

import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command
  ( Command (..),
    MetaOptions (..),
    ShellType (..),
    SortField (..),
    hasMeta,
  )
import SenaVN.Core (Romi, SenaError (..), askConn, throwR)
import qualified SenaVN.DB as DB
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (Connection)
import SenaVN.Pretty
import qualified SenaVN.Session as Session
import SenaVN.Types
import SenaVN.Utils (maskSensitive, now, openDirectory, pickResult, randomOne)
import System.Console.Haskeline (defaultSettings, getInputLine, runInputT)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (normalise, takeDirectory, (</>))
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Process (CreateProcess (..), StdStream (..), callProcess, createProcess, proc)

requireGame :: GameId -> Romi GameCore
requireGame gid = do
  conn <- askConn
  mg <- liftIO $ DB.getGame conn gid
  case mg of
    Nothing -> throwR (GameNotFound gid)
    Just g -> pure g

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

findEditor :: Connection -> IO (Maybe FilePath)
findEditor conn = do
  mCfgEditor <- DB.getTypedConfig conn DB.CoreEditor
  case mCfgEditor of
    Just ed | not (T.null (T.strip ed)) -> pure (Just (T.unpack (T.strip ed)))
    _ -> do
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
  conn <- askConn
  mEditor <- liftIO $ findEditor conn
  editor <- case mEditor of
    Nothing -> throwR EditorNotFound
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
    Left err -> throwR (JsonParseError (T.pack err))
    Right g' ->
      pure
        g'
          { coreId = g.coreId,
            createDate = g.createDate,
            playTimelines = g.playTimelines
          }

spawnDaemon :: GameId -> Text -> Text -> IO ()
spawnDaemon (GameId gid) gameName exePath = do
  sessDir <- Session.getSessionsDir
  daemonExe <- Session.getDaemonPath
  let sessionFile = sessDir </> T.unpack gid <> ".session.json"
  _ <-
    createProcess
      ( proc
          daemonExe
          [ "--run",
            "--game-id",
            T.unpack gid,
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

printLn :: Doc AnsiStyle -> IO ()
printLn d = render (d <> line)

ok :: Doc AnsiStyle -> IO ()
ok msg = printLn $ annotate (color Green <> bold) "✔" <+> msg

askConfirmation :: Doc AnsiStyle -> IO Bool
askConfirmation promptDoc = do
  renderInline $
    annotate (color Yellow <> bold) "?"
      <+> promptDoc
      <+> dim_ "[y/N]"
      <+> annotate (color Cyan <> bold) "› "
  ans <- runInputT defaultSettings (getInputLine "")
  case ans of
    Just s ->
      let trimmed = T.toLower (T.strip (T.pack s))
       in pure (trimmed == "y" || trimmed == "yes")
    Nothing -> pure False

selectFetchInteractive :: Text -> [FetchGameData] -> IO FetchGameData
selectFetchInteractive _ [] = fail "Empty results"
selectFetchInteractive query (firstResult : rest) = do
  let results = firstResult : rest
  printLn $
    annotate (color Cyan <> bold) "◆"
      <+> bold_ "Multiple VNDB results found for"
      <+> cyan_ (pretty ("'" <> query <> "'")) <> dim_ ":"
  let displayResults = take 6 results
  forM_ (zip [1 :: Int ..] displayResults) $ \(idx, fd) -> do
    let vid = fd.vndbId
        titleDoc = bold_ (white_ (pretty fd.title))
        devDoc =
          if T.null fd.developer
            then mempty
            else dim_ " · " <> dim_ (pretty fd.developer)
        ratingDoc' =
          if fd.rating > 0
            then space <> yellow_ ("★" <> pretty (show (round (fd.rating * 10) :: Int)))
            else mempty
    printLn $
      indent 2 $
        annotate (color Cyan <> bold) ("[" <> pretty idx <> "]")
          <+> titleDoc
          <+> dim_ ("(" <> pretty vid <> ")")
          <> devDoc
          <> ratingDoc'
  askLoop (length displayResults)
  where
    askLoop maxIdx = do
      renderInline $
        annotate (color Yellow <> bold) "?"
          <+> bold_ "Select result"
          <+> dim_ ("[1-" <> pretty maxIdx <> ", default 1, q to cancel]")
          <+> annotate (color Cyan <> bold) "› "
      input <- getLine
      let trimmed = filter (/= ' ') input
      case trimmed of
        "" -> pure firstResult
        "1" -> pure firstResult
        "q" -> exitFailure
        "Q" -> exitFailure
        s -> case reads s of
          [(idx, "")] | idx >= 1 && idx <= maxIdx ->
            pure ((firstResult : rest) !! (idx - 1))
          _ -> do
            printLn $
              annotate (color Red <> bold) "✗"
                <+> annotate (color Red) "Invalid selection."
                <+> dim_ ("Please enter 1-" <> pretty maxIdx <> " or 'q' to cancel.")
            askLoop maxIdx

selectGameInteractive :: Text -> [GameWithLocal] -> IO GameCore
selectGameInteractive query matches = do
  printLn $
    annotate (color Cyan <> bold) "◆"
      <+> bold_ "Multiple configured games matched"
      <+> cyan_ (pretty ("'" <> query <> "'")) <> dim_ ":"
  let displayMatches = take 8 matches
  forM_ (zip [1 :: Int ..] displayMatches) $ \(idx, gwl) -> do
    let titleDoc = bold_ (white_ (pretty gwl.game.title))
        idDoc = annotate (color Magenta) (pretty ("(#" <> gwl.game.coreId.unGameId <> ")"))
        exeDoc = maybe mempty (\lp -> dim_ " → " <> dim_ (pretty lp.programFile)) gwl.local
    printLn $
      indent 2 $
        annotate (color Cyan <> bold) ("[" <> pretty idx <> "]")
          <+> titleDoc
          <+> idDoc
          <> exeDoc
  askLoop (length displayMatches)
  where
    askLoop maxIdx = do
      renderInline $
        annotate (color Yellow <> bold) "?"
          <+> bold_ "Select game to run"
          <+> dim_ ("[1-" <> pretty maxIdx <> ", q to cancel]")
          <+> annotate (color Cyan <> bold) "› "
      input <- getLine
      let trimmed = filter (/= ' ') input
      case trimmed of
        "q" -> exitFailure
        "Q" -> exitFailure
        s -> case reads s of
          [(idx, "")] | idx >= 1 && idx <= maxIdx ->
            pure (matches !! (idx - 1)).game
          _ -> do
            printLn $
              annotate (color Red <> bold) "✗"
                <+> annotate (color Red) "Invalid selection."
                <+> dim_ ("Please enter 1-" <> pretty maxIdx <> " or 'q' to cancel.")
            askLoop maxIdx

attachRunningSessions :: [GameWithLocal] -> IO [GameWithLocal]
attachRunningSessions games = do
  sessions <- Session.listSessions
  liveSessions <- fmap catMaybes $ forM sessions $ \s -> do
    alive <- Session.isPidAlive s.guardPid
    pure $ if alive then Just (s.gameId, s.activeSeconds) else Nothing
  pure $
    map
      ( \gwl ->
          case lookup gwl.game.coreId liveSessions of
            Just activeSec -> gwl {running = Just activeSec}
            Nothing -> gwl
      )
      games

handle :: Command -> Romi ()
handle Add {addName, addCoreId, addPath, addNoFetch, addSkip, addOrder, addKeepName, addMeta} = do
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

handle Remove {removeCoreId, removeHard} = do
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

handle Move {moveOldId, moveNewId} = do
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

handle Run {runTarget, runSkip, runRandom, runRecent, runLast, runFilter} = do
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

handle Fetch {fetchName, fetchOrder} = do
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

handle List {listSort, listReverse, listFilter = _, listDetail} = do
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

handle Stats {statsCoreIds, statsFilter = _} = do
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

handle Timeline {tlCoreIds, tlFilter = _} = do
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

handle Use {useCoreId, useExePath, useSavePath, useGuide} = do
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

handle Info {infoCoreId, infoGuide, infoSave} = do
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

handle Status = do
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

handle Sync =
  throwR (NotImplemented "cloud sync")

handle Config {configKey, configValue, configUnset, configEdit} = do
  conn <- askConn
  let doUnset k = do
        deleted <- liftIO $ DB.deleteConfig conn k
        if deleted
          then liftIO . ok $ dim_ "unset" <+> cyan_ (pretty k)
          else throwR (ConfigKeyNotFound k)

  if configEdit || (configKey == Just "edit" && configValue == Nothing)
    then editConfigInteractive conn
    else case configUnset of
      Just k -> doUnset k
      Nothing -> case (configKey, configValue) of
        (Just "rm", Just k) -> doUnset k
        (Just "unset", Just k) -> doUnset k
        (Just "rm", Nothing) -> throwR ConfigMissingKey
        (Just "unset", Nothing) -> throwR ConfigMissingKey
        (Nothing, Nothing) -> do
          cfgs <- liftIO $ DB.getAllConfigs conn
          if null cfgs
            then liftIO $ putStrLn "no configuration set."
            else liftIO $ forM_ cfgs $ \(k, v) ->
              printLn $ cyan_ (pretty k) <+> dim_ "=" <+> pretty (maskSensitive k v)
        (Just k, Nothing) -> do
          mv <- liftIO $ DB.getConfig conn k
          case mv of
            Just v -> liftIO $ putStrLn (T.unpack v)
            Nothing -> throwR (ConfigKeyNotFound k)
        (Just k, Just v) -> do
          case validateConfigKey k of
            Left err -> throwR (ConfigKeyInvalid k err)
            Right () -> do
              liftIO $ DB.setConfig conn k v
              liftIO . ok $ cyan_ (pretty k) <+> dim_ "=" <+> pretty v
        (Nothing, Just _) ->
          throwR ConfigMissingValue

handle Completion {completionShell} = liftIO $ do
  case completionShell of
    ShellBash -> putStrLn "eval \"$(sena --bash-completion-script sena)\""
    ShellZsh -> putStrLn "eval \"$(sena --zsh-completion-script sena)\""
    ShellFish -> putStrLn "sena --fish-completion-script sena | source"

validateConfigKey :: Text -> Either Text ()
validateConfigKey k
  | T.null (T.strip k) = Left "config key cannot be empty"
  | T.any (\c -> c == ' ' || c == '\t' || c == '=' || c == '#' || c == ';') k =
      Left "config key cannot contain whitespace, '=', '#', or ';'"
  | otherwise = Right ()

editConfigInteractive :: Connection -> Romi ()
editConfigInteractive conn = do
  mEditor <- liftIO $ findEditor conn
  editor <- case mEditor of
    Nothing -> throwR EditorNotFound
    Just ed -> pure ed
  cfgs <- liftIO $ DB.getAllConfigs conn
  let initialContent =
        T.unlines $
          [ "# SenaVN Configuration",
            "# Format: key = value",
            "# Lines starting with '#' or ';' are ignored.",
            ""
          ]
            ++ map (\(k, v) -> k <> " = " <> v) cfgs
  content <- liftIO $
    withSystemTempFile "sena-config-.ini" $ \path h -> do
      TIO.hPutStr h initialContent
      hClose h
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      callProcess prog (args ++ [path])
      TIO.readFile path
  parsed <- parseConfigContent content
  liftIO $ DB.setAllConfigs conn parsed
  liftIO . ok $ pretty ("Configuration updated (" <> show (length parsed) <> " entries).")
  where
    parseConfigContent :: Text -> Romi [(Text, Text)]
    parseConfigContent txt = mapM parseLine (filter (not . isIgnored) (T.lines txt))

    isIgnored l =
      let s = T.strip l
       in T.null s || "#" `T.isPrefixOf` s || ";" `T.isPrefixOf` s

    parseLine l =
      let (kRaw, rest) = T.breakOn "=" l
       in if T.null rest
            then throwR (ConfigFileLineInvalid l "missing '=' delimiter")
            else
              let k = T.strip kRaw
                  v = T.strip (T.drop 1 rest)
               in case validateConfigKey k of
                    Left err -> throwR (ConfigFileLineInvalid l err)
                    Right () -> pure (k, v)

openGameGuide :: Connection -> GameWithLocal -> Romi ()
openGameGuide conn gwl = do
  case gwl.local >>= (.guideFile) of
    Nothing -> throwR (GuideNotConfigured gwl.game.coreId)
    Just gFile -> do
      let rawPath = normalise (T.unpack gFile)
      mEditor <- liftIO $ findEditor conn
      editor <- case mEditor of
        Nothing -> throwR EditorNotFound
        Just ed -> pure ed
      let parentDir = takeDirectory rawPath
      liftIO $ unless (null parentDir || parentDir == ".") $
        createDirectoryIfMissing True parentDir
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      liftIO $ callProcess prog (args ++ [rawPath])

openGameSave :: GameWithLocal -> Romi ()
openGameSave gwl = do
  case gwl.local >>= (.savePath) of
    Nothing -> throwR (SaveNotConfigured gwl.game.coreId)
    Just sPath -> do
      let rawDir = normalise (T.unpack sPath)
      isDir <- liftIO $ doesDirectoryExist rawDir
      targetPath <-
        if isDir
          then pure rawDir
          else do
            isFile <- liftIO $ doesFileExist rawDir
            if isFile
              then let p = takeDirectory rawDir in pure (if null p then "." else p)
              else throwR (SavePathNotFound rawDir)
      liftIO $ openDirectory targetPath
      liftIO . ok $ dim_ "opened save directory →" <+> cyan_ (pretty (T.pack targetPath))
