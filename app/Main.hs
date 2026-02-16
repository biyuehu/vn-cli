{-# LANGUAGE OverloadedStrings #-}

module Main where

-- import Brick
-- import Brick.Widgets.Core
-- import Brick.Widgets.List
-- import qualified Graphics.Vty as V

import qualified Api
import Common
import Control.Monad (when)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.List (find, sortOn)
import Data.Maybe (isJust)
import Data.Text (Text, pack, unpack)
import Models (GameId (unGameId))
import qualified Models as M
import Options.Applicative as O
import Utils (loadRootStates, randomOne, romiPutStrLn, saveRootStates)

-- fetchSource :: [Text]
-- fetchSource = ["VNDB"]

data Command
  = Add {name :: Text, coreId :: Text, maybePath :: Maybe Text, fetch :: Bool, order :: Int, keepName :: Bool}
  | Remove {coreId :: Text, hard :: Bool}
  | Run {runAlias :: Maybe Text {- find :: Text, -}, random :: Bool, last :: Bool, recent :: Bool}
  | Fetch {name :: Text, order :: Int}
  | List {sort :: Text, reverse :: Bool, filterDsl :: Text, detailed :: Bool}
  | Stats {coreIds :: [Text], filterDsl :: Text}
  | Timeline {coreIds :: [Text], filterDsl :: Text}
  | Config {key :: Text, newValue :: Text}
  | Use {coreId :: Text, path :: Text}
  | Update {coreId :: Text, keepName :: Bool, fetch :: Bool}
  | Info {coreId :: Text}
  | Sync

commandParser :: Parser Command
commandParser =
  subparser $
    command "add" (info addParser (progDesc "Add game"))
      <> command "stat" (info statsParser (progDesc "Show stats"))
      <> command "timeline" (info timelineParser (progDesc "Show timeline"))
      <> command "fetch" (info fetchParser (progDesc "Fetch game"))
      <> command "list" (info listParser (progDesc "List games"))
      <> command "remove" (info removeParser (progDesc "Remove game"))
      <> command "run" (info runParser (progDesc "Run game"))
      <> command "config" (info configParser (progDesc "Config"))
      <> command "use" (info useParser (progDesc "Use game"))
      <> command "update" (info updateParser (progDesc "Update game"))
      <> command "info" (info infoParser' (progDesc "Info"))
      <> command "sync" (info syncParser (progDesc "Sync"))
  where
    addParser =
      Add
        <$> argument str (metavar "TITLE")
        <*> argument str (metavar "ALIAS")
        <*> optional (argument str (metavar "PATH"))
        <*> switch (short 'f' <> long "fetch" <> help "Auto fetching")
        <*> option auto (short 'o' <> long "order" <> help "Order" <> metavar "ORDER" <> value 1)
        <*> switch (short 'k' <> long "keep-name" <> help "Keep input name")

    removeParser = Remove <$> argument str (metavar "ALIAS") <*> switch (short 'h' <> long "hard" <> help "Remove from cloud")

    runParser =
      Run
        <$> optional (argument str (metavar "ALIAS"))
        <*> switch (short 'r' <> long "random" <> help "Random game")
        <*> switch (short 'l' <> long "last" <> help "Last played game")
        <*> switch (short 'c' <> long "recent" <> help "Recently played game")

    fetchParser =
      Fetch
        <$> argument str (metavar "TITLE")
        <*> option auto (short 'o' <> long "order" <> help "Order" <> metavar "ORDER" <> value 1)

    listParser =
      List
        <$> option auto (short 's' <> long "sort" <> help "Sort" <> metavar "SORT" <> value "title")
        <*> switch (short 'r' <> long "reverse" <> help "Reverse")
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")
        <*> switch (short 'd' <> long "detailed" <> help "Detailed")

    statsParser =
      Stats
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")

    timelineParser =
      Timeline
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")

    configParser =
      Config
        <$> argument str (metavar "KEY")
        <*> argument str (metavar "VALUE")

    useParser = Use <$> argument str (metavar "ALIAS") <*> argument str (metavar "PATH")

    updateParser =
      Update
        <$> argument str (metavar "ALIAS")
        <*> switch (short 'k' <> long "keep-name" <> help "Keep original name")
        <*> switch (short 'f' <> long "fetch" <> help "Auto fetching")

    infoParser' = Info <$> argument str (metavar "ALIAS")

    syncParser = pure Sync

main :: IO ()
main = do
  -- TODO: automatically create data.json if not exists
  command' <- execParser opts
  result <- runExceptT $ handle command'
  case result of
    Left err -> Prelude.putStrLn err
    Right _ -> pure ()
  where
    opts = info (commandParser <**> helper) (fullDesc <> progDesc "Gal Manager")

    handle :: Command -> Romi ()
    handle (Add title' coreId' maybePath' fetch' order' keepName') = do
      rootState <- loadRootStates
      let gameId = M.GameId coreId'
      saveRootStates $
        rootState
          { M.gameCore = M.gameCore rootState ++ [M.GameCore {M.coreId = gameId, M.vndbId = Nothing, M.updateDate = 0, M.title = title', M.alias = [], M.description = "", M.tags = [], M.playTimelines = [], M.expectedPlayTime = 0, M.lastPlay = 0, M.createDate = 0, M.releaseDate = 0, M.rating = 0, M.developer = "", M.images = [], M.links = []}],
            M.localPaths =
              M.localPaths rootState ++ case maybePath' of
                Just path' -> [M.LocalPath {M.localId = gameId, M.programFile = path', M.savePath = Nothing, M.guideFile = Nothing}]
                Nothing -> []
          }
      romiPutStrLn $ "Adding game " <> title' <> " with id " <> coreId'
    handle (Remove coreId' hard') = do
      rootState <- loadRootStates
      let newGameCores = filter (\g -> unGameId (M.coreId g) /= coreId') $ M.gameCore rootState
      when (length newGameCores == length (M.gameCore rootState)) $ throwE "No game found"
      let newLocalPaths = filter (\p -> unGameId (M.localId p) /= coreId') $ M.localPaths rootState
      -- TODO: add confirmation for hard remove
      saveRootStates $ rootState {M.gameCore = if hard' then newGameCores else M.gameCore rootState, M.localPaths = newLocalPaths}
    handle (Run coreId' random' last' recent') = do
      when (length (filter id [isJust coreId', random', last', recent']) >= 2) $ throwE "Only one of id, random, last, or recent can be specified"

      rootState <- loadRootStates
      let games = M.gameCore rootState
      targetGame <- case coreId' of
        Just a -> pure $ find (\g -> unGameId (M.coreId g) == a) games
        Nothing ->
          if recent'
            then
              pure $ foldl (\acc g -> case acc of Just acc' | M.lastPlay acc' > M.lastPlay g -> Just acc'; _ -> Just g) Nothing games
            else
              if last'
                then pure $ foldl (\acc g -> case acc of Just acc' | M.createDate acc' < M.createDate g -> Just acc'; _ -> Just g) Nothing games
                else randomOne games
      case targetGame of
        Just g -> do
          romiPutStrLn $ "Running game " <> M.title g
        Nothing -> throwE "No game found"
    handle (Fetch title' order') = do
      rootState <- loadRootStates
      -- romiPutStrLn $ "Fetching from " <> pack (show fetch') <> ": " <> title'
      romiPutStrLn $ "Order: " <> pack (show order')

      res <- Api.fetchFromVndb $ Api.VndbName title'

      romiPutStrLn $ "Result: " <> pack (show res)

    -- let payload =
    --       object
    --         [ "filters" .= [["title", "=", title']],
    --           "fields" .= "title coreId description tags rating released developer links",
    --           "sort" .= "title",
    --           "results" .= (10 :: Int),
    --           "page" .= (1 :: Int)
    --         ]

    -- r <- liftIO $ runReq defaultHttpConfig $ do
    --   req
    --     POST
    --     (https "api.vndb.org" /: "v2" /: "vn")
    --     (ReqBodyJson payload)
    --     jsonResponse
    --     mempty

    -- case responseBody r of
    --   Right (json) -> do
    --     case json ^? key "results" . _Array of
    --       Just results | not (V.null results) -> do
    --         let first = V.head results
    --         case parseEither parseGameCore first of
    --           Right newGame -> do
    --             saveRootStates $ rootState {M.gameCore = M.gameCore rootState ++ [newGame]}
    --             romiPutStrLn $ "Fetched and added: " <> M.title newGame
    --           Left err -> throwE $ pack err
    --       _ -> throwE "VNDB returned empty or no match"
    --   Left err -> throwE $ pack $ "VNDB request failed: " ++ show err
    handle (List sort' reverse' filterDsl' detailed') = do
      rootState <- loadRootStates
      let games = M.gameCore rootState
      sorted <- case sort' of
        "title" -> pure $ sortOn M.title games
        "lastPlay" -> pure $ sortOn M.lastPlay games
        "createDate" -> pure $ sortOn M.createDate games
        "releaseDate" -> pure $ sortOn M.releaseDate games
        "rating" -> pure $ sortOn M.rating games
        _ -> throwE "Invalid sort option, must be one of: title, lastPlay, createDate, releaseDate, rating"
      let reversed = if reverse' then Prelude.reverse sorted else sorted
      let filtered = {- if filterDsl' == "" then reversed else filter (\g -> T.isInfixOf filterDsl' (M.title g)) -} reversed
      romiPutStrLn "Listing games:"
      mapM_
        ( \g -> do
            romiPutStrLn $ M.title g <> " (" <> unGameId (M.coreId g) <> ")"
            when detailed' $ do
              romiPutStrLn $ "  Description: " <> M.description g
              romiPutStrLn $ "  Sessions: " <> pack (show $ length $ M.playTimelines g)
              romiPutStrLn $ "  Total time: " <> pack (show $ sum $ map M.duration $ M.playTimelines g) <> "s"
        )
        filtered
    handle (Stats coreIds' filterDsl') = do
      rootState <- loadRootStates
      let games = M.gameCore rootState
      let targets = if null coreIds' then games else filter (\g -> unGameId (M.coreId g) `elem` coreIds') games
      let filtered = {- if filterDsl' == "" then targets else filter (\g -> T.isInfixOf filterDsl' (M.title g)) -} targets
      romiPutStrLn "Stats:"
      mapM_
        ( \g -> do
            let total = sum $ map M.duration $ M.playTimelines g
            romiPutStrLn $ M.title g <> ":"
            romiPutStrLn $ "  Total play time: " <> pack (show total) <> " seconds"
            romiPutStrLn $ "  Sessions: " <> pack (show $ length $ M.playTimelines g)
            romiPutStrLn $ "  Last play: " <> pack (show $ M.lastPlay g)
        )
        filtered
    handle (Timeline coreIds' filterDsl') = do
      rootState <- loadRootStates
      let games = M.gameCore rootState
      let targets = if null coreIds' then games else filter (\g -> unGameId (M.coreId g) `elem` coreIds') games
      let filtered = {- if filterDsl' == "" then targets else filter (\g -> T.isInfixOf filterDsl' (M.title g)) -} targets
      romiPutStrLn "Timeline:"
      mapM_
        ( \g -> do
            romiPutStrLn $ M.title g <> " timelines:"
            mapM_ (\s -> romiPutStrLn $ "  " <> pack (show $ M.start s) <> " -> " <> pack (show $ M.end s) <> " (" <> pack (show $ M.duration s) <> "s)") $ M.playTimelines g
        )
        filtered
    handle (Config key' value') = do
      romiPutStrLn $ "Set config " <> key' <> " = " <> value'
      pure ()
    handle (Use coreId' path') = do
      rootState <- loadRootStates
      let targetId = M.GameId coreId'
      let newLocals = map (\p -> if M.localId p == targetId then p {M.programFile = path'} else p) $ M.localPaths rootState
      when (newLocals == M.localPaths rootState) $ throwE $ "No local path found for id " <> unpack coreId'
      saveRootStates $ rootState {M.localPaths = newLocals}
      romiPutStrLn $ "Updated path for " <> coreId' <> " to " <> path'
    handle (Update coreId' keepName' fetch') = do
      rootState <- loadRootStates
      let targetId = M.GameId coreId'
      case find (\g -> M.coreId g == targetId) $ M.gameCore rootState of
        Just oldG -> do
          romiPutStrLn $ "Updating " <> coreId' <> " (keep name: " <> pack (show keepName') <> ", fetch: " <> pack (show fetch') <> ")"
          let newTitle = if keepName' then M.title oldG else "Updated Title"
          let newGame = oldG {M.title = newTitle, M.updateDate = 1729000000}
          let newCores = map (\g -> if M.coreId g == targetId then newGame else g) $ M.gameCore rootState
          saveRootStates $ rootState {M.gameCore = newCores}
          romiPutStrLn "Update completed"
        Nothing -> throwE $ "No game found for id " <> unpack coreId'
    handle (Info coreId') = do
      rootState <- loadRootStates
      let targetId = M.GameId coreId'
      case find (\g -> M.coreId g == targetId) $ M.gameCore rootState of
        Just g -> do
          romiPutStrLn $ "Info for " <> coreId'
          romiPutStrLn $ "Title: " <> M.title g
          romiPutStrLn $ "Description: " <> M.description g
          romiPutStrLn $ "Tags: " <> pack (show $ M.tags g)
          romiPutStrLn $ "Total play time: " <> pack (show $ sum $ map M.duration $ M.playTimelines g) <> " seconds"
          romiPutStrLn $ "Last play: " <> pack (show $ M.lastPlay g)
          romiPutStrLn $ "Links: " <> pack (show $ map M.name $ M.links g)
        Nothing -> throwE $ "No game found for id " <> unpack coreId'
    handle Sync = do
      romiPutStrLn "Syncing games"
