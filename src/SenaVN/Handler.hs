module SenaVN.Handler (handle) where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Except (throwE)
import Data.Foldable (find)
import Data.List (sortOn)
import Data.Maybe (isJust)
import qualified Data.Text as T
import SenaVN.Api (fetchFromVndb)
import SenaVN.Command
import SenaVN.Core
import SenaVN.Pretty (printFetchResults)
import SenaVN.Types
import SenaVN.Utils

handle :: Command -> Romi ()
handle (Add title' coreId' maybePath' noFetch' order' keepName') = do
  rootState <- loadRootStates
  let gameId = GameId coreId'
  saveRootStates $
    rootState
      { gameCore = gameCore rootState ++ [GameCore {coreId = gameId, vndbId = Nothing, updateDate = 0, title = title', alias = [], description = "", tags = [], playTimelines = [], expectedPlayTime = 0, lastPlay = 0, createDate = 0, releaseDate = 0, rating = 0, developer = "", images = [], links = []}],
        localPaths =
          rootState.localPaths ++ case maybePath' of
            Just path' -> [LocalPath {localId = gameId, programFile = path', savePath = Nothing, guideFile = Nothing}]
            Nothing -> []
      }
  romiPutStrLn $ "Adding game " <> title' <> " with id " <> coreId'
handle (Remove coreId' hard') = do
  rootState <- loadRootStates
  let newGameCores = filter (\g -> unGameId g.coreId /= coreId') $ gameCore rootState
  when (length newGameCores == length (gameCore rootState)) $ throwE "No game found"
  let newLocalPaths = filter (\p -> unGameId (localId p) /= coreId') $ localPaths rootState
  -- TODO: add confirmation for hard remove
  saveRootStates $ rootState {gameCore = if hard' then newGameCores else gameCore rootState, localPaths = newLocalPaths}
handle (Run coreId' random' last' recent') = do
  when (length (filter Prelude.id [isJust coreId', random', last', recent']) >= 2) $ throwE "Only one of id, random, last, or recent can be specified"

  rootState <- loadRootStates
  let games = gameCore rootState
  targetGame <- case coreId' of
    Just a -> pure $ find (\g -> unGameId g.coreId == a) games
    Nothing ->
      if recent'
        then
          pure $ foldl (\acc g -> case acc of Just acc' | lastPlay acc' > lastPlay g -> Just acc'; _ -> Just g) Nothing games
        else
          if last'
            then pure $ foldl (\acc g -> case acc of Just acc' | createDate acc' < createDate g -> Just acc'; _ -> Just g) Nothing games
            else randomOne games
  case targetGame of
    Just g -> do
      romiPutStrLn $ "Running game " <> g.title
    Nothing -> throwE "No game found"
handle (Fetch title' order') = do
  _rootState <- loadRootStates
  -- romiPutStrLn $ "Fetching from " <> T.pack (show fetch') <> ": " <> title'
  romiPutStrLn $ "Order: " <> T.pack (show order')

  res <- fetchFromVndb $ VndbName title'

  if order' == 0
    then do
      romiPutStrLn $ "Results count:" <> T.pack (show (length res))
      liftIO $ printFetchResults res
    else
      if order' >= 1 && order' <= length res
        then
          liftIO $ printFetchResults [res !! (order' - 1)]
        else
          romiPutStrLn "Invalid order"

-- romiPutStrLn $ "Result: " <> T.pack ()

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
--             saveRootStates $ rootState {gameCore = gameCore rootState ++ [newGame]}
--             romiPutStrLn $ "Fetched and added: " <> title newGame
--           Left err -> throwE $ T.pack err
--       _ -> throwE "VNDB returned empty or no match"
--   Left err -> throwE $ T.pack $ "VNDB request failed: " ++ show err
handle (List sort' reverse' filterDsl' detailed') = do
  rootState <- loadRootStates
  let games = gameCore rootState
  sorted <- case sort' of
    "title" -> pure $ sortOn (\g -> g.title) games
    "lastPlay" -> pure $ sortOn (\g -> g.lastPlay) games
    "createDate" -> pure $ sortOn (\g -> g.createDate) games
    "releaseDate" -> pure $ sortOn (\g -> g.releaseDate) games
    "rating" -> pure $ sortOn (\g -> g.rating) games
    _ -> throwE "Invalid sort option, must be one of: title, lastPlay, createDate, releaseDate, rating"
  let reversed = if reverse' then Prelude.reverse sorted else sorted
  let filtered = {- if filterDsl' == "" then reversed else filter (\g -> T.isInfixOf filterDsl' (g.title)) -} reversed
  romiPutStrLn "Listing games:"
  mapM_
    ( \g -> do
        romiPutStrLn $ g.title <> " (" <> unGameId g.coreId <> ")"
        when detailed' $ do
          romiPutStrLn $ "  Description: " <> g.description
          romiPutStrLn $ "  Sessions: " <> T.pack (show $ length $ playTimelines g)
          romiPutStrLn $ "  Total time: " <> T.pack (show $ sum $ map duration $ playTimelines g) <> "s"
    )
    filtered
handle (Stats coreIds' filterDsl') = do
  rootState <- loadRootStates
  let games = gameCore rootState
  let targets = if null coreIds' then games else filter (\g -> unGameId g.coreId `elem` coreIds') games
  let filtered = {- if filterDsl' == "" then targets else filter (\g -> T.isInfixOf filterDsl' (g.title)) -} targets
  romiPutStrLn "Stats:"
  mapM_
    ( \g -> do
        let total = sum $ map duration $ playTimelines g
        romiPutStrLn $ g.title <> ":"
        romiPutStrLn $ "  Total play time: " <> T.pack (show total) <> " seconds"
        romiPutStrLn $ "  Sessions: " <> T.pack (show $ length $ playTimelines g)
        romiPutStrLn $ "  Last play: " <> T.pack (show $ lastPlay g)
    )
    filtered
handle (Timeline coreIds' filterDsl') = do
  rootState <- loadRootStates
  let games = gameCore rootState
  let targets = if null coreIds' then games else filter (\g -> unGameId (g.coreId) `elem` coreIds') games
  let filtered = {- if filterDsl' == "" then targets else filter (\g -> T.isInfixOf filterDsl' (g.title)) -} targets
  romiPutStrLn "Timeline:"
  mapM_
    ( \g -> do
        romiPutStrLn $ g.title <> " timelines:"
        mapM_ (\s -> romiPutStrLn $ "  " <> T.pack (show $ start s) <> " -> " <> T.pack (show $ end s) <> " (" <> T.pack (show $ duration s) <> "s)") $ playTimelines g
    )
    filtered
handle (Config key' value') = do
  romiPutStrLn $ "Set config " <> key' <> " = " <> value'
  pure ()
handle (Use coreId' path') = do
  rootState <- loadRootStates
  let targetId = GameId coreId'
  let newLocals = map (\p -> if localId p == targetId then p {programFile = path'} else p) $ localPaths rootState
  when (newLocals == localPaths rootState) $ throwE $ "No local path found for id " <> T.unpack coreId'
  saveRootStates $ rootState {localPaths = newLocals}
  romiPutStrLn $ "Updated path for " <> coreId' <> " to " <> path'
handle (Update coreId' keepName' fetch') = do
  rootState <- loadRootStates
  let targetId = GameId coreId'
  case find (\g -> g.coreId == targetId) $ gameCore rootState of
    Just oldG -> do
      romiPutStrLn $ "Updating " <> coreId' <> " (keep name: " <> T.pack (show keepName') <> ", fetch: " <> T.pack (show fetch') <> ")"
      let newTitle = if keepName' then oldG.title else "Updated Title"
      let newGame = oldG {title = newTitle, updateDate = 1729000000}
      let newCores = map (\g -> if g.coreId == targetId then newGame else g) $ gameCore rootState
      saveRootStates $ rootState {gameCore = newCores}
      romiPutStrLn "Update completed"
    Nothing -> throwE $ "No game found for id " <> T.unpack coreId'
handle (Info coreId') = do
  rootState <- loadRootStates
  let targetId = GameId coreId'
  case find (\g -> g.coreId == targetId) $ gameCore rootState of
    Just g -> do
      romiPutStrLn $ "Info for " <> coreId'
      romiPutStrLn $ "Title: " <> g.title
      romiPutStrLn $ "Description: " <> g.description
      romiPutStrLn $ "Tags: " <> T.pack (show g.tags)
      romiPutStrLn $ "Total play time: " <> T.pack (show $ sum $ map duration $ playTimelines g) <> " seconds"
      romiPutStrLn $ "Last play: " <> T.pack (show $ lastPlay g)
      romiPutStrLn $ "Links: " <> T.pack (show $ map (\l -> l.name) g.links)
    Nothing -> throwE $ "No game found for id " <> T.unpack coreId'
handle Sync = do
  romiPutStrLn "Syncing games"
