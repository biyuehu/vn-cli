{-# LANGUAGE NamedFieldPuns #-}

module SenaVN.Handler (handle) where

import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
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
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hClose, stdout)
import System.IO.Temp (withSystemTempFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc)

now :: IO Int
now = round <$> getPOSIXTime

-- 找不到游戏就直接 throwR
requireGame :: Text -> Romi GameCore
requireGame gid = do
  conn <- askConn
  mg <- liftIO $ DB.getGame conn gid
  case mg of
    Nothing -> throwR ("game not found: " <> gid)
    Just g -> pure g

-- 有 path 就写 LocalPath，没有就跳过
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

-- 从 VNDB 结果列表里取第 N 条（1-indexed）
pickResult :: Int -> [a] -> Maybe a
pickResult _ [] = Nothing
pickResult n xs
  | n >= 1 && n <= length xs = Just (xs !! (n - 1))
  | otherwise = Just (head xs) -- 超出范围退化到第一条

-- 将 FetchGameData 应用到 GameCore
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

-- 将 MetaOptions 定点覆盖到 GameCore
applyMeta :: GameCore -> MetaOptions -> GameCore
applyMeta g m =
  g
    { vndbId = m.metaVndbId <> g.vndbId, -- Maybe 的 <> 取第一个 Just
      developer = fromMaybe g.developer m.metaDeveloper,
      releaseDate = fromMaybe g.releaseDate m.metaReleaseDate,
      rating = fromMaybe g.rating m.metaRating,
      description = fromMaybe g.description m.metaDescription,
      tags = if null m.metaTags then g.tags else m.metaTags
    }

-- 空白 GameCore
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

-- 用 $EDITOR（fallback notepad.exe）编辑 GameCore JSON
-- 需要在 cabal 里加 aeson、temporary、process
openEditor :: GameCore -> Romi GameCore
openEditor g = do
  editor <- liftIO $ fromMaybe "notepad.exe" <$> lookupEnv "EDITOR"
  raw <- liftIO $
    withSystemTempFile "sena-edit-.json" $ \path h -> do
      BL.hPut h (encode g)
      hClose h
      -- TODO Windows：createProcess 改用 CREATE_NEW_CONSOLE 让编辑器有窗口
      _ <-
        createProcess
          (proc editor [path])
            { std_in = Inherit,
              std_out = Inherit,
              std_err = Inherit
            }
      BL.readFile path
  case eitherDecode raw of
    Left err -> throwR ("parse error after editor: " <> T.pack err)
    Right g' -> pure g'

-- 启动 foo.exe（detached）
spawnFoo :: Text -> Text -> Text -> IO ()
spawnFoo gameId gameName exePath = do
  sessDir <- Session.getSessionsDir
  let sessionFile = sessDir </> T.unpack gameId <> ".session.json"
  -- TODO：Windows 下用 DETACHED_PROCESS flag，让 foo.exe 与 sena 完全脱钩
  _ <-
    createProcess
      ( proc
          "foo.exe"
          [ "--game-id",
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
          std_err = NoStream
        }
  pure ()

-- ────────────────────────────────────────────
-- Pretty 输出辅助（不引入 Pretty 内部细节）
-- ────────────────────────────────────────────

render :: Doc AnsiStyle -> IO ()
render = renderIO stdout . layoutPretty defaultLayoutOptions

printLn :: Doc AnsiStyle -> IO ()
printLn d = render (d <> line)

ok :: Doc AnsiStyle -> IO ()
ok msg = printLn $ annotate (color Green) "✓" <+> msg

err_ :: Doc AnsiStyle -> IO ()
err_ msg = printLn $ annotate (color Red) "✗" <+> msg

-- ────────────────────────────────────────────
-- handle
-- ────────────────────────────────────────────

handle :: Command -> Romi ()
-- ── add ──────────────────────────────────────────────────

handle Add {addName, addCoreId, addPath, addNoFetch, addSkip, addOrder, addKeepName, addMeta} = do
  conn <- askConn
  existing <- liftIO $ DB.getGame conn addCoreId
  when (isJust existing) $ throwR ("id already exists: " <> addCoreId)
  ts <- liftIO now
  let base = emptyGameCore addCoreId addName ts

  finalGame <-
    if hasMeta addMeta
      then do
        -- 提供了 meta option → 直接保存，不 fetch 不 editor
        pure (applyMeta base addMeta)
      else
        if addNoFetch
          then
            -- --no-fetch → 跳过 fetch，进 editor（除非 --skip）
            if addSkip
              then pure base
              else openEditor base
          else do
            -- 默认：fetch + editor（--skip 跳过 editor）
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

-- ── edit ─────────────────────────────────────────────────

handle Edit {editCoreId, editFetch, editApply, editOrder, editKeepName, editMeta} = do
  conn <- askConn
  g <- requireGame editCoreId
  ts <- liftIO now

  finalGame <-
    if hasMeta editMeta
      then do
        -- 提供了 meta option → 定点保存，不 editor
        pure (applyMeta g editMeta)
      else
        if editFetch
          then do
            -- --fetch → 拉取后进 editor（--apply 跳过 editor）
            results <- liftIO $ fetchFromVndb (VndbName g.title)
            case pickResult editOrder results of
              Nothing -> throwR "no VNDB results found"
              Just fd -> do
                let fetched = applyFetch editKeepName g fd
                if editApply
                  then pure fetched
                  else openEditor fetched
          else
            -- 默认：editor 预填当前数据
            openEditor g

  liftIO $ do
    DB.updateGame conn (finalGame {updateDate = ts})
    ok $ bold_ (pretty finalGame.title) <+> dim_ "updated."

-- ── rm ───────────────────────────────────────────────────

handle Remove {removeCoreId, removeHard} = do
  conn <- askConn
  g <- requireGame removeCoreId
  -- TODO：加 confirmation prompt（haskeline readline）
  liftIO $ do
    DB.deleteGame conn removeCoreId
    ok $
      bold_ (pretty g.title)
        <+> dim_ "removed."
        <> if removeHard then dim_ " (TODO: cloud remove)" else mempty

-- ── run ──────────────────────────────────────────────────

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
    Just lp -> liftIO $ do
      spawnFoo g.coreId.unGameId g.title lp.programFile
      printLn $
        annotate (color Green) "▶"
          <+> bold_ (pretty g.title)
          <> line
          <> dim_ (pretty lp.programFile)

-- ── fetch ─────────────────────────────────────────────────

handle Fetch {fetchName, fetchOrder} = do
  results <- liftIO $ fetchFromVndb (VndbName fetchName)
  when (null results) $ throwR "no results found"
  liftIO $ case fetchOrder of
    0 -> printFetchResults results
    n ->
      if n >= 1 && n <= length results
        then printFetchResult n (results !! (n - 1))
        else
          err_
            ( "invalid --order "
                <> pretty n
                <> ", got "
                <> pretty (length results)
                <> " results"
            )

-- ── list ──────────────────────────────────────────────────

handle List {listSort, listReverse, listFilter, listDetail} = do
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
  -- TODO: apply listFilter DSL
  liftIO $
    if listDetail
      then forM_ ordered printGame
      else printGames ordered

-- ── stat ──────────────────────────────────────────────────

handle Stats {statsCoreIds, statsFilter} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  all' <- liftIO $ DB.getAllGamesWithLocal conn
  let targets =
        if null statsCoreIds
          then all'
          else filter (\g -> g.game.coreId.unGameId `elem` statsCoreIds) all'
  -- TODO: apply statsFilter DSL
  when (null targets) $ throwR "no matching games"
  liftIO $ forM_ targets printGame

-- ── timeline ─────────────────────────────────────────────

handle Timeline {tlCoreIds, tlFilter} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  all' <- liftIO $ DB.getAllGames conn
  let targets =
        if null tlCoreIds
          then all'
          else filter (\g -> g.coreId.unGameId `elem` tlCoreIds) all'
  -- TODO: apply tlFilter DSL
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

-- ── use ───────────────────────────────────────────────────

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

-- ── info ──────────────────────────────────────────────────

handle Info {infoCoreId} = do
  conn <- askConn
  liftIO $ Session.reconcileSessions conn
  mgwl <- liftIO $ DB.getGameWithLocal conn infoCoreId
  case mgwl of
    Nothing -> throwR ("game not found: " <> infoCoreId)
    Just gwl -> liftIO $ printGame gwl

-- ── status ────────────────────────────────────────────────

handle Status = do
  sessions <- liftIO Session.listSessions
  if null sessions
    then liftIO $ printLn (dim_ "no games running.")
    else liftIO $ forM_ sessions $ \s -> do
      alive <- Session.isPidAlive s.fooPid
      printLn $
        (if alive then annotate (color Green) "●" else annotate (color Yellow) "?")
          <+> bold_ (pretty s.gameId)
          <+> dim_ "|"
          <+> fmtSeconds s.activeTime
          <+> dim_ ("pid " <> pretty s.fooPid)

-- ── sync ──────────────────────────────────────────────────

handle Sync =
  -- TODO：读 config 取 gh token，序列化 DB 数据，push 到 gh repo
  throwR "sync not yet implemented"
-- ── config ────────────────────────────────────────────────

handle Config {} =
  -- TODO：定义 AppConfig 类型，load/save config 文件，按 key 更新
  throwR "config not yet implemented"
