module SenaVN.Handler (handle) where

import Control.Monad.IO.Class (liftIO)
import SenaVN.Command (Command (..))
import SenaVN.Core (Romi, askConn)
import qualified SenaVN.Handler.Config as Config
import qualified SenaVN.Handler.Game as Game
import qualified SenaVN.Handler.Query as Query
import qualified SenaVN.Handler.Run as Run
import qualified SenaVN.TUI as TUI

handle :: Command -> Romi ()
handle cmd = case cmd of
  Add {} -> Game.handleAdd cmd
  Edit {} -> Game.handleEdit cmd
  Remove {} -> Game.handleRemove cmd
  Move {} -> Game.handleMove cmd
  Use {} -> Game.handleUse cmd
  Info {} -> Game.handleInfo cmd
  Run {} -> Run.handleRun cmd
  Status -> Run.handleStatus
  List {} -> Query.handleList cmd
  Stats {} -> Query.handleStats cmd
  Timeline {} -> Query.handleTimeline cmd
  Fetch {} -> Query.handleFetch cmd
  Sync -> Query.handleSync
  Config {} -> Config.handleConfig cmd
  Completion {} -> Config.handleCompletion cmd
  Tui -> do
    conn <- askConn
    liftIO $ TUI.runTUI conn
