{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

module SenaVN.Sync
  ( SyncAction (..),
    SyncSummary (..),
    SyncConfig (..),
    mergeData,
    fetchRemoteData,
    pushRemoteData,
    runSync,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (runExceptT)
import Control.Monad.Trans.Reader (runReaderT)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl', sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Network.HTTP.Req
  ( (/:),
    GET (..),
    HttpException (..),
    NoReqBody (..),
    Option,
    PUT (..),
    ReqBodyJson (..),
    Scheme (Https),
    defaultHttpConfig,
    header,
    https,
    ignoreResponse,
    jsonResponse,
    queryParam,
    req,
    responseBody,
    runReq,
  )
import SenaVN.Core (Env (..), Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Types (CloudData (..), GameCore (..), GameId (..), PlayTimeline (..))
import SenaVN.Utils (decodeBase64, encodeBase64)
import System.Environment (setEnv)

data SyncAction
  = ActionAdded !GameId !Text
  | ActionUpdated !GameId !Text
  | ActionDeleted !GameId !Text
  | ActionResurrected !GameId !Text
  deriving stock (Show, Eq)

data SyncSummary = SyncSummary
  { actions :: ![SyncAction],
    mergedSessionsCount :: !Int
  }
  deriving stock (Show, Eq)

data SyncConfig = SyncConfig
  { token :: !Text,
    repoOwner :: !Text,
    repoName :: !Text,
    branch :: !Text,
    filePath :: !Text,
    proxy :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

data GitHubContentResp = GitHubContentResp
  { content :: !(Maybe Text),
    sha :: !Text,
    git_url :: !(Maybe Text)
  }
  deriving stock (Show, Generic)

instance FromJSON GitHubContentResp where
  parseJSON = withObject "GitHubContentResp" $ \o ->
    GitHubContentResp
      <$> o .:? "content"
      <*> o .: "sha"
      <*> o .:? "git_url"

newtype GitHubBlobResp = GitHubBlobResp
  { blobContent :: Text
  }
  deriving stock (Show, Generic)

instance FromJSON GitHubBlobResp where
  parseJSON = withObject "GitHubBlobResp" $ \o ->
    GitHubBlobResp <$> o .: "content"

data GitHubPutReq = GitHubPutReq
  { message :: !Text,
    content :: !Text,
    sha :: !(Maybe Text),
    branch :: !Text
  }
  deriving stock (Show, Generic)

instance ToJSON GitHubPutReq where
  toJSON r =
    object $
      [ "message" .= r.message,
        "content" .= r.content,
        "branch" .= r.branch
      ]
        ++ maybe [] (\s -> ["sha" .= s]) r.sha

newtype GitHubPutResp = GitHubPutResp
  { commit :: GitHubCommitInfo
  }
  deriving stock (Show, Generic)

instance FromJSON GitHubPutResp where
  parseJSON = withObject "GitHubPutResp" $ \o ->
    GitHubPutResp <$> o .: "commit"

newtype GitHubCommitInfo = GitHubCommitInfo
  { sha :: Text
  }
  deriving stock (Show, Generic)

instance FromJSON GitHubCommitInfo where
  parseJSON = withObject "GitHubCommitInfo" $ \o ->
    GitHubCommitInfo <$> o .: "sha"

setupProxy :: Maybe Text -> IO ()
setupProxy (Just p) | not (T.null (T.strip p)) = do
  let pStr = normalize (T.strip p)
  setEnv "HTTPS_PROXY" pStr
  setEnv "HTTP_PROXY" pStr
  where
    normalize s
      | "http://" `T.isPrefixOf` s || "https://" `T.isPrefixOf` s = T.unpack s
      | otherwise = "http://" ++ T.unpack s
setupProxy _ = pure ()

extractHttpError :: HttpException -> (Int, Text)
extractHttpError (JsonHttpException err) = (-1, T.pack err)
extractHttpError (VanillaHttpException err) =
  let errStr = T.pack (show err)
      code
        | "statusCode = 404" `T.isInfixOf` errStr || "404 Not Found" `T.isInfixOf` errStr = 404
        | "statusCode = 401" `T.isInfixOf` errStr || "401 Unauthorized" `T.isInfixOf` errStr = 401
        | "statusCode = 403" `T.isInfixOf` errStr || "403 Forbidden" `T.isInfixOf` errStr = 403
        | "statusCode = 409" `T.isInfixOf` errStr || "409 Conflict" `T.isInfixOf` errStr = 409
        | otherwise = -1
      msg = extractJsonMessage errStr
   in (code, msg)
  where
    extractJsonMessage s =
      case T.breakOn "{\"message\":\"" s of
        (_, rest) | not (T.null rest) ->
          let content = T.drop (T.length "{\"message\":\"") rest
           in fst (T.breakOn "\"" content)
        _ ->
          if "ResponseTimeout" `T.isInfixOf` s || "timeout" `T.isInfixOf` s
            then "connection timed out"
            else
              if "ConnectionFailure" `T.isInfixOf` s || "getAddrInfo" `T.isInfixOf` s
                then "cannot connect to GitHub (network offline or DNS failed)"
                else s

githubHeaders :: Text -> Option 'Https
githubHeaders tok =
  header "User-Agent" "SenaVN"
    <> header "Authorization" (TE.encodeUtf8 ("Bearer " <> tok))
    <> header "Accept" "application/vnd.github.v3+json"

checkRepoExists :: SyncConfig -> Romi Bool
checkRepoExists cfg = do
  liftIO $ setupProxy cfg.proxy
  res <-
    liftIO $
      try $
        runReq defaultHttpConfig $ do
          let url = https "api.github.com" /: "repos" /: cfg.repoOwner /: cfg.repoName
          req GET url NoReqBody ignoreResponse (githubHeaders cfg.token)
  case res of
    Right _ -> pure True
    Left err -> do
      let (code, msg) = extractHttpError err
      if code == 404
        then throwR (SyncHttpError 404 ("Repository " <> cfg.repoOwner <> "/" <> cfg.repoName <> " not found"))
        else if code == 401 || code == 403
          then throwR (SyncHttpError code msg)
          else throwR (SyncNetworkError msg)

fetchRemoteData :: SyncConfig -> Romi (Maybe (CloudData, Text))
fetchRemoteData cfg = do
  liftIO $ setupProxy cfg.proxy
  res <-
    liftIO $
      try $
        runReq defaultHttpConfig $ do
          let url =
                https "api.github.com"
                  /: "repos"
                  /: cfg.repoOwner
                  /: cfg.repoName
                  /: "contents"
                  /: cfg.filePath
          req
            GET
            url
            NoReqBody
            jsonResponse
            (githubHeaders cfg.token <> queryParam "ref" (Just cfg.branch))
  case res of
    Right response -> do
      let respObj = responseBody response :: GitHubContentResp
      rawB64 <- case respObj.content of
        Just c -> pure c
        Nothing -> case respObj.git_url of
          Just blobUrl -> fetchBlob blobUrl
          Nothing -> throwR (SyncPayloadError "file content truncated and git_url missing")
      let cleanB64 = TE.encodeUtf8 (T.filter (\ch -> ch /= '\n' && ch /= '\r') rawB64)
      rawBytes <- case decodeBase64 cleanB64 of
        Just b -> pure b
        Nothing -> throwR (SyncPayloadError "failed to decode base64 file content")
      case eitherDecodeStrict' rawBytes of
        Right cd -> pure (Just (cd, respObj.sha))
        Left decodeErr -> throwR (SyncPayloadError (T.pack decodeErr))
    Left err -> do
      let (code, msg) = extractHttpError err
      case code of
        404 -> do
          -- Verify if repository actually exists
          _ <- checkRepoExists cfg
          pure Nothing
        401 -> throwR (SyncHttpError 401 msg)
        403 -> throwR (SyncHttpError 403 msg)
        _ -> throwR (SyncNetworkError msg)
  where
    fetchBlob :: Text -> Romi Text
    fetchBlob blobUrl = do
      bRes <-
        liftIO $
          try $
            runReq defaultHttpConfig $ do
              -- parse url components
              let segments = filter (not . T.null) (T.splitOn "/" (T.dropWhile (== '/') (snd (T.breakOn "//" blobUrl))))
              case segments of
                (_host : segs) -> do
                  let endpoint = foldl (/:) (https "api.github.com") (drop 1 segs)
                  req GET endpoint NoReqBody jsonResponse (githubHeaders cfg.token)
                _ -> liftIO $ fail "invalid blob url"
      case bRes of
        Right r -> pure (responseBody r :: GitHubBlobResp).blobContent
        Left err -> do
          let (code, msg) = extractHttpError err
          throwR (SyncHttpError code msg)

pushRemoteData :: SyncConfig -> CloudData -> Maybe Text -> Romi Text
pushRemoteData cfg cd mSha = do
  liftIO $ setupProxy cfg.proxy
  let jsonBytes = BL.toStrict (encode cd)
      b64Text = TE.decodeUtf8 (encodeBase64 jsonBytes)
      body =
        GitHubPutReq
          { message = "sync: update library data via sena",
            content = b64Text,
            sha = mSha,
            branch = cfg.branch
          }
  res <-
    liftIO $
      try $
        runReq defaultHttpConfig $ do
          let url =
                https "api.github.com"
                  /: "repos"
                  /: cfg.repoOwner
                  /: cfg.repoName
                  /: "contents"
                  /: cfg.filePath
          req
            PUT
            url
            (ReqBodyJson body)
            jsonResponse
            (githubHeaders cfg.token)
  case res of
    Right r -> pure (responseBody r :: GitHubPutResp).commit.sha
    Left err -> do
      let (code, msg) = extractHttpError err
      throwR (SyncHttpError code msg)

mergeData ::
  [GameCore] ->
  [(GameId, Int)] ->
  CloudData ->
  (CloudData, [GameCore], [GameId], [GameId], SyncSummary)
mergeData localGames localTombstonesList remoteCloudData =
  (newCloudData, toUpsertLocally, toDeleteLocally, toClearLocalTombstones, summary)
  where
    localGameMap = Map.fromList [(g.coreId, g) | g <- localGames]
    localTombMap = Map.fromList localTombstonesList
    remoteGameMap = Map.fromList [(g.coreId, g) | g <- remoteCloudData.datas]
    remoteTombSet = Set.fromList remoteCloudData.deleteIds

    allGameIds =
      Set.toList
        ( Set.unions
            [ Map.keysSet localGameMap,
              Map.keysSet remoteGameMap,
              Map.keysSet localTombMap,
              remoteTombSet
            ]
        )

    (resolvedGames, toUpsertLocally, toDeleteLocally, toClearLocalTombstones, resolvedTombstones, actionsList, sessCounts) =
      foldl' resolve ([], [], [], [], Set.empty, [], 0) allGameIds

    newCloudData =
      CloudData
        { deleteIds = Set.toList resolvedTombstones,
          datas = resolvedGames
        }

    summary =
      SyncSummary
        { actions = actionsList,
          mergedSessionsCount = sessCounts
        }

    resolve (rGames, upserts, deletes, clears, tombs, acts, sess) gid =
      case (Map.lookup gid localGameMap, Map.lookup gid localTombMap, Map.lookup gid remoteGameMap, Set.member gid remoteTombSet) of
        (Just loc, _, Just remG, _) ->
          let (mergedSess, addedSess) = mergeSessions loc.playTimelines remG.playTimelines
              newer = if loc.updateDate >= remG.updateDate then loc else remG
              newLastPlay =
                if null mergedSess
                  then max loc.lastPlay remG.lastPlay
                  else maximum (map (.end) mergedSess)
              mergedG = newer {playTimelines = mergedSess, lastPlay = newLastPlay}
              isDiff = loc.updateDate /= remG.updateDate || loc.playTimelines /= mergedSess
              act = [ActionUpdated gid mergedG.title | isDiff]
           in ( mergedG : rGames,
                if loc /= mergedG then mergedG : upserts else upserts,
                deletes,
                gid : clears,
                tombs,
                acts ++ act,
                sess + addedSess
              )
        (Just loc, _, Nothing, True) ->
          if loc.updateDate > 0 && any (\pt -> pt.start > 0) loc.playTimelines
            then (loc : rGames, upserts, deletes, gid : clears, tombs, acts ++ [ActionResurrected gid loc.title], sess)
            else (rGames, upserts, gid : deletes, clears, Set.insert gid tombs, acts ++ [ActionDeleted gid loc.title], sess)
        (Just loc, _, Nothing, False) ->
          (loc : rGames, upserts, deletes, clears, tombs, acts ++ [ActionAdded gid loc.title], sess)
        (Nothing, Just delTs, Just remG, _) ->
          if remG.updateDate > delTs || any (\pt -> pt.start > delTs) remG.playTimelines
            then (remG : rGames, remG : upserts, deletes, gid : clears, tombs, acts ++ [ActionResurrected gid remG.title], sess)
            else (rGames, upserts, deletes, clears, Set.insert gid tombs, acts ++ [ActionDeleted gid remG.title], sess)
        (Nothing, Nothing, Just remG, False) ->
          (remG : rGames, remG : upserts, deletes, clears, tombs, acts ++ [ActionAdded gid remG.title], sess)
        (Nothing, Just _, Nothing, _) ->
          (rGames, upserts, deletes, clears, Set.insert gid tombs, acts, sess)
        (Nothing, Nothing, Nothing, True) ->
          (rGames, upserts, deletes, clears, Set.insert gid tombs, acts, sess)
        _ -> (rGames, upserts, deletes, clears, tombs, acts, sess)

    mergeSessions locSess remSess =
      let mLoc = Map.fromList [(s.start, s) | s <- locSess]
          mRem = Map.fromList [(s.start, s) | s <- remSess]
          allStarts = Set.toList (Set.union (Map.keysSet mLoc) (Map.keysSet mRem))
          merged = flip map (sort allStarts) $ \st ->
            case (Map.lookup st mLoc, Map.lookup st mRem) of
              (Just s1, Just s2) ->
                PlayTimeline
                  { start = st,
                    end = max s1.end s2.end,
                    duration = max s1.duration s2.duration
                  }
              (Just s1, Nothing) -> s1
              (Nothing, Just s2) -> s2
              (Nothing, Nothing) -> error "unreachable"
          addedCount = length merged - length locSess
       in (merged, max 0 addedCount)

runSync ::
  SyncConfig ->
  Bool ->
  (Text -> IO ()) ->
  Romi (SyncSummary, Maybe Text)
runSync cfg isDryRun logStep = do
  conn <- askConn
  liftIO $ logStep ("Connecting to GitHub (" <> cfg.repoOwner <> "/" <> cfg.repoName <> ")...")
  mRemote <- fetchRemoteData cfg
  (remoteData, mSha) <- case mRemote of
    Just (cd, shaVal) -> do
      liftIO $ logStep ("Pulled remote library (sha: " <> T.take 7 shaVal <> ").")
      pure (cd, Just shaVal)
    Nothing -> do
      liftIO $ logStep "Remote file not found, initializing fresh cloud state."
      pure (CloudData {deleteIds = [], datas = []}, Nothing)

  localGames <- liftIO $ DB.getAllGames conn
  localTombstones <- liftIO $ DB.getDeletedGames conn

  let (newCloudData, toUpsert, toDelete, toClearTombstones, summary) =
        mergeData localGames localTombstones remoteData

  if isDryRun
    then pure (summary, Nothing)
    else do
      -- Push to remote with retry on 409
      commitSha <- pushWithRetry cfg newCloudData mSha 3
      liftIO $ logStep ("Pushed updated state to GitHub (commit: " <> T.take 7 commitSha <> ").")
      -- Apply atomic transaction to local database only after remote succeeds
      liftIO $ DB.applySyncMerge conn toUpsert toDelete toClearTombstones
      pure (summary, Just commitSha)
  where
    pushWithRetry :: SyncConfig -> CloudData -> Maybe Text -> Int -> Romi Text
    pushWithRetry c cd shaVal retriesLeft = do
      res <-
        (Right <$> pushRemoteData c cd shaVal)
          `catchSyncHttp` \code msg ->
            if code == 409 && retriesLeft > 0
              then pure (Left (code, msg))
              else throwR (SyncHttpError code msg)
      case res of
        Right commitSha -> pure commitSha
        Left _ -> do
          liftIO $ logStep "Conflict detected on remote (HTTP 409), pulling latest and retrying..."
          liftIO $ threadDelay 1000000 -- 1s backoff
          freshRemote <- fetchRemoteData c
          case freshRemote of
            Just (freshCd, freshSha) -> do
              conn <- askConn
              lGames <- liftIO $ DB.getAllGames conn
              lTombs <- liftIO $ DB.getDeletedGames conn
              let (freshMerged, _, _, _, _) = mergeData lGames lTombs freshCd
              pushWithRetry c freshMerged (Just freshSha) (retriesLeft - 1)
            Nothing ->
              pushWithRetry c cd Nothing (retriesLeft - 1)

    catchSyncHttp action handler =
      action `catchErrorRomi` \case
        SyncHttpError code msg -> handler code msg
        other -> throwR other

    catchErrorRomi m h = do
      env <- askConn
      res <- liftIO $ runExceptT (runReaderT m (Env env))
      case res of
        Left e -> h e
        Right a -> pure a
