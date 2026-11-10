module Main (main) where

import Test.ConfigSpec (configTests)
import Test.DBSpec (dbTests)
import Test.Framework (Test (..), runTestTree)
import Test.StatsSpec (statsTests)
import Test.SyncSpec (syncTests)
import Test.TypesSpec (typesTests)
import Test.UtilsSpec (utilsTests)

main :: IO ()
main =
  runTestTree $
    TestGroup
      "SenaVN Test Suite"
      [ utilsTests,
        typesTests,
        syncTests,
        configTests,
        statsTests,
        dbTests
      ]
