module SenaVN.Core (Romi, Env (..), throwR, askConn, runRomi) where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), asks)
import Data.Text (Text)
import Database.SQLite.Simple (Connection)

newtype Env = Env {envConn :: Connection}

type Romi = ReaderT Env (ExceptT Text IO)

throwR :: Text -> Romi a
throwR = lift . throwE

askConn :: Romi Connection
askConn = asks (.envConn)

runRomi :: Env -> Romi a -> IO (Either Text a)
runRomi env m = runExceptT (runReaderT m env)