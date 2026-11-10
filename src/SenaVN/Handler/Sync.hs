module SenaVN.Handler.Sync (handleSync) where

import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Prettyprinter
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Interactive (ok, printLn)
import SenaVN.Pretty (cyan_, dim_, green_, yellow_)
import SenaVN.Sync
  ( SyncAction (..),
    SyncConfig (..),
    SyncSummary (..),
    runSync,
  )

handleSync :: Bool -> Romi ()
handleSync isDryRun = do
  conn <- askConn
  mToken <- liftIO $ DB.getConfig conn "sync.token"
  token <- case mToken of
    Just t | not (T.null (T.strip t)) -> pure (T.strip t)
    _ -> throwR (SyncMissingConfig "sync.token")

  mRepo <- liftIO $ DB.getConfig conn "sync.repo"
  (owner, repo) <- case mRepo of
    Just r | not (T.null (T.strip r)) ->
      let parts = T.splitOn "/" (T.strip r)
       in case parts of
            [o, rp] | not (T.null o) && not (T.null rp) -> pure (o, rp)
            _ -> throwR (SyncMissingConfig "sync.repo (expected format: owner/repo)")
    _ -> throwR (SyncMissingConfig "sync.repo")

  mBranch <- liftIO $ DB.getConfig conn "sync.branch"
  let branch = fromMaybe "main" (mBranch >>= nonEmpty)

  mPath <- liftIO $ DB.getConfig conn "sync.path"
  let path = fromMaybe "data.json" (mPath >>= nonEmpty)

  mProxy <- liftIO $ DB.getConfig conn "fetch.proxy"

  let cfg =
        SyncConfig
          { token = token,
            repoOwner = owner,
            repoName = repo,
            branch = branch,
            filePath = path,
            proxy = mProxy >>= nonEmpty
          }

  if isDryRun
    then liftIO . printLn $ yellow_ "▶" <+> "Dry-run mode (simulation only, no changes will be saved):"
    else liftIO . printLn $ cyan_ "▶" <+> pretty ("Syncing with GitHub (" <> owner <> "/" <> repo <> ")...")

  (summary, mCommit) <- runSync cfg isDryRun logStep

  liftIO $ renderSummary isDryRun summary mCommit
  where
    nonEmpty t =
      let s = T.strip t
       in if T.null s then Nothing else Just s

    logStep msg =
      printLn $ indent 2 (dim_ "✓" <+> pretty msg)

    renderSummary dryRun summary _mCommit = do
      let added = [g | ActionAdded _ g <- summary.actions]
          updated = [g | ActionUpdated _ g <- summary.actions]
          deleted = [g | ActionDeleted _ g <- summary.actions]
          resurrected = [g | ActionResurrected _ g <- summary.actions]

      if null summary.actions && summary.mergedSessionsCount == 0
        then ok "Library is already up to date, no changes needed."
        else do
          printLn $
            indent 2 $
              dim_ "Summary:"
                <+> ( if not (null added)
                        then green_ ("+" <> pretty (length added) <> " added") <> " "
                        else mempty
                    )
                <+> ( if not (null updated)
                        then cyan_ ("~" <> pretty (length updated) <> " updated") <> " "
                        else mempty
                    )
                <+> ( if not (null deleted)
                        then yellow_ ("-" <> pretty (length deleted) <> " deleted") <> " "
                        else mempty
                    )
                <+> ( if not (null resurrected)
                        then green_ ("+" <> pretty (length resurrected) <> " resurrected") <> " "
                        else mempty
                    )
                <+> ( if summary.mergedSessionsCount > 0
                        then dim_ ("(" <> pretty summary.mergedSessionsCount <> " sessions merged)")
                        else mempty
                    )
          if dryRun
            then printLn $ yellow_ "✓" <+> "Simulation complete. Run 'sena sync' to apply changes."
            else ok "Sync completed successfully."
