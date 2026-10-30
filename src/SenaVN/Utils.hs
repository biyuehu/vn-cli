module SenaVN.Utils (randomOne) where

import System.Random (randomRIO)

randomOne :: [a] -> IO (Maybe a)
randomOne [] = pure Nothing
randomOne xs = do
  idx <- randomRIO (0, length xs - 1)
  pure $ Just (xs !! idx)
