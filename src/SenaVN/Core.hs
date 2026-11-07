module SenaVN.Core
  ( Romi,
    Env (..),
    SenaError (..),
    renderSenaError,
    renderSenaErrorDoc,
    throwR,
    askConn,
    runRomi,
  )
where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), asks)
import Database.SQLite.Simple (Connection)
import SenaVN.Error (SenaError (..), renderSenaError, renderSenaErrorDoc)

newtype Env = Env {envConn :: Connection}

type Romi = ReaderT Env (ExceptT SenaError IO)

throwR :: SenaError -> Romi a
throwR = lift . throwE

askConn :: Romi Connection
askConn = asks (.envConn)

runRomi :: Env -> Romi a -> IO (Either SenaError a)
runRomi env m = runExceptT (runReaderT m env)
