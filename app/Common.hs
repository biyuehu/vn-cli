module Common (Romi) where

import Control.Monad.Trans.Except (ExceptT)

type Romi = ExceptT String {- (StateT M.RootState IO) -} IO
