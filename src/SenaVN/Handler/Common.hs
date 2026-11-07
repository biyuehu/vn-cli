module SenaVN.Handler.Common
  ( requireGame,
    attachRunningSessions,
  )
where

import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (catMaybes)
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import qualified SenaVN.Session as Session
import SenaVN.Types (GameCore (..), GameId, GameWithLocal (..))

requireGame :: GameId -> Romi GameCore
requireGame gid = do
  conn <- askConn
  mg <- liftIO $ DB.getGame conn gid
  case mg of
    Nothing -> throwR (GameNotFound gid)
    Just g -> pure g

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
