{-# LANGUAGE NamedFieldPuns #-}

module SenaVN.Handler (handle) where

import Control.Applicative ((<|>))
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum)
import Data.List (sortOn, uncons)
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe)
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
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hClose)
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

spawnDaemon :: Text -> Text -> Text -> IO ()
spawnDaemon gameId gameName exePath = do
  sessDir <- Session.getSessionsDir
  daemonExe <- Session.getDaemonPath
  let sessionFile = sessDir </> T.unpack gameId <> ".session.json"
  _ <-
    createProcess
      ( proc
          daemonExe
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
          case lookup gwl.game.coreId.unGameId liveSessions of
            Just activeSec -> gwl {running = Just activeSec}
            Nothing -> gwl
      )
      games

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
            when (null results) $ throwR "no VNDB results found"
            selected <-
              if addOrder /= 1 || addSkip
                then case pickResult addOrder results of
                  Nothing -> throwR "no VNDB results found"
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
            results <- liftIO $ fetchFromVndb (VndbName g.title)
            when (null results) $ throwR "no VNDB results found"
            selected <-
              if editOrder /= 1 || editApply
                then case pickResult editOrder results of
                  Nothing -> throwR "no VNDB results found"
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
      ok $
        bold_ (white_ (pretty g.title))
          <+> dim_ "removed."
          <> if removeHard then dim_ " (TODO: cloud remove)" else mempty

handle Move {moveOldId, moveNewId} = do
  conn <- askConn
  when (moveOldId == moveNewId) $
    throwR "new ID must be different from old ID"
  when (T.null (T.strip moveNewId)) $
    throwR "new ID cannot be empty"
  unless (T.all (\c -> isAlphaNum c || c == '-' || c == '_') moveNewId) $
    throwR "new ID must contain only letters, numbers, hyphens, or underscores"
  g <- requireGame moveOldId
  existingNew <- liftIO $ DB.getGame conn moveNewId
  when (isJust existingNew) $
    throwR ("game already exists with ID: " <> moveNewId)
  mRunning <- liftIO $ Session.readSession moveOldId
  case mRunning of
    Just sess -> do
      alive <- liftIO $ Session.isPidAlive sess.guardPid
      when alive $
        throwR ("cannot rename game while it is running (PID: " <> T.pack (show sess.guardPid) <> ")")
    Nothing -> pure ()
  liftIO $ Session.reconcileSessions conn
  ts <- liftIO now
  liftIO $ DB.renameGame conn moveOldId moveNewId ts
  liftIO $ Session.renameSession moveOldId moveNewId
  liftIO $
    ok $
      bold_ (white_ (pretty g.title))
        <+> dim_ "renamed:"
        <+> annotate (color Magenta) (pretty ("#" <> moveOldId))
        <+> dim_ "→"
        <+> annotate (color Cyan <> bold) (pretty ("#" <> moveNewId))

handle Run {runTarget, runSkip, runRandom, runRecent, runLast, runFilter} = do
  conn <- askConn
  let activeFlags = length $ filter Prelude.id [isJust runTarget, runRandom, runRecent, runLast]
  when (activeFlags > 1) $
    throwR "only one of <id|name> / --random / --recent / --last can be specified"

  liftIO $ Session.reconcileSessions conn

  allGames <- liftIO $ DB.getAllGames conn
  when (null allGames) $ throwR "library is empty"

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
  when (null games) $ throwR "no games match the specified filter"

  g <- case runTarget of
    Nothing
      | runRandom ->
          liftIO (randomOne games) >>= maybe (throwR "no games available matching filter") pure
      | runRecent ->
          case sortOn (Down . (.lastPlay)) (filter (\x -> x.lastPlay > 0) games) of
            [] -> throwR "no games played yet (or none match filter)"
            (x : _) -> pure x
      | runLast ->
          case sortOn (Down . (.createDate)) games of
            [] -> throwR "no games found matching filter"
            (x : _) -> pure x
      | isJust runFilter ->
          liftIO (randomOne games) >>= maybe (throwR "no games available matching filter") pure
      | otherwise ->
          throwR "specify a game ID/name or use --random / --recent / --last / --filter"

    Just target -> do
      mExact <- liftIO $ DB.getGame conn target
      case mExact of
        Just exactGame -> pure exactGame
        Nothing ->
          if runSkip
            then throwR ("game not found with exact ID: " <> target)
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
                [] ->
                  throwR $
                    "no configured game found matching '"
                      <> target
                      <> "'. Check with 'sena list' or configure with 'sena use <id> <exe>'."
                [single] -> pure single.game
                multiple -> liftIO $ selectGameInteractive target multiple

  mLocal <- liftIO $ DB.getLocalPath conn g.coreId.unGameId
  case mLocal of
    Nothing ->
      throwR $
        "no exe configured for "
          <> g.title
          <> " — configure first with: sena use "
          <> g.coreId.unGameId
          <> " <path>"
    Just lp -> do
      mSess <- liftIO $ Session.readSession g.coreId.unGameId
      case mSess of
        Just sess -> do
          alive <- liftIO $ Session.isPidAlive sess.guardPid
          when alive $
            throwR $
              "game is already running: "
                <> g.title
                <> " (#"
                <> g.coreId.unGameId
                <> ", PID: "
                <> T.pack (show sess.guardPid)
                <> ")"
        Nothing -> pure ()
      liftIO $ do
        spawnDaemon g.coreId.unGameId g.title lp.programFile
        printLn $
          annotate (color Green <> bold) "▶"
            <+> bold_ (white_ (pretty g.title))
            <+> annotate (color Magenta) (pretty ("(#" <> g.coreId.unGameId <> ")"))
            <> line
            <> dim_ ("  ↳ " <> pretty lp.programFile)

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
  rawGames <- liftIO $ DB.getAllGamesWithLocal conn
  games <- liftIO $ attachRunningSessions rawGames
  sorted <- case listSort of
    "title" -> pure $ sortOn (\g -> g.game.title) games
    "lastPlay" -> pure $ sortOn (\g -> g.game.lastPlay) games
    "createDate" -> pure $ sortOn (\g -> g.game.createDate) games
    "releaseDate" -> pure $ sortOn (\g -> g.game.releaseDate) games
    "rating" -> pure $ sortOn (\g -> g.game.rating) games
    "played" -> pure $ sortOn effectivePlayed games
    other ->
      throwR $
        "unknown sort field: "
          <> other
          <> "  valid: title|lastPlay|createDate|releaseDate|rating|played"
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
      let targets = filter (\g -> g.game.coreId.unGameId `elem` statsCoreIds) allGames
      when (null targets) $ throwR "no matching games found"
      liftIO $ forM_ targets printGameStat

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
        { localId = GameId useCoreId,
          programFile = useExePath,
          savePath = useSavePath,
          guideFile = useGuide
        }
    ok $
      bold_ (white_ (pretty g.title))
        <+> annotate (color Magenta) (pretty ("(#" <> useCoreId <> ")"))
        <+> dim_ "linked →"
        <+> cyan_ (pretty useExePath)

handle Info {infoCoreId} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  mgwl <- liftIO $ do
    mg <- DB.getGameWithLocal conn infoCoreId
    case mg of
      Nothing -> pure Nothing
      Just gwl -> listToMaybe <$> attachRunningSessions [gwl]
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
      alive <- Session.isPidAlive s.guardPid
      mGame <- DB.getGame conn s.gameId
      let titleDoc = case mGame of
            Just g -> bold_ (white_ (pretty g.title)) <+> annotate (color Magenta) (pretty ("(#" <> s.gameId <> ")"))
            Nothing -> bold_ (white_ (pretty s.gameId))
      printLn $
        (if alive then annotate (color Green <> bold) "▶" else annotate (color Yellow) "?")
          <+> titleDoc
          <+> dim_ "·"
          <+> green_ (pretty (fmtSecStr s.activeSeconds))
          <+> dim_ ("(PID " <> pretty s.guardPid <> ")")

handle Sync =
  throwR "sync not yet implemented"

handle Config {} =
  throwR "config not yet implemented"

handle Completion {completionShell} = liftIO $ do
  case T.toLower completionShell of
    "bash" -> putStrLn "eval \"$(sena --bash-completion-script sena)\""
    "zsh" -> putStrLn "eval \"$(sena --zsh-completion-script sena)\""
    "fish" -> putStrLn "sena --fish-completion-script sena | source"
    _ -> putStrLn "Usage: eval \"$(sena --bash-completion-script sena)\" (supported: bash, zsh, fish)"
