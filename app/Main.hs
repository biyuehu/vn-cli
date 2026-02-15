{-# LANGUAGE OverloadedStrings #-}

module Main where

-- import Brick
-- import Brick.Widgets.Core
-- import Brick.Widgets.List
-- import qualified Graphics.Vty as V

import Data.Maybe (fromMaybe)
import Data.Text (Text, pack)
import Data.Text.IO as TIO
import qualified Models ()
import Options.Applicative as O

data FetchSource = VAB | VNDB | BGM deriving (Show, Read)

data FetchSourceOrNone = VAB' | VNDB' | BGM' | None deriving (Show, Read)

data Command
  = Add {name :: Text, alias :: Text, maybePath :: Maybe Text, fetch :: FetchSourceOrNone, order :: Int, keepName :: Bool}
  | Remove {alias :: Text, hard :: Bool}
  | Run {runAlias :: Maybe Text {- find :: Text, -}, random :: Bool, last :: Bool, recent :: Bool}
  | Fetch {name :: Text, order :: Int, source :: FetchSource}
  | List {sort :: Text, reverse :: Bool, filter :: Text, detailed :: Bool}
  | Stats {aliases :: [Text], filter :: Text}
  | Timeline {aliases :: [Text], filter :: Text}
  | Config {key :: Text, value :: Text}
  | Use {alias :: Text, path :: Text}
  | Update {alias :: Text, keepName :: Bool, fetch :: FetchSourceOrNone}
  | Info {alias :: Text}
  | Sync

commandParser :: Parser Command
commandParser =
  subparser $
    command "add" (info addParser (progDesc "Add game"))
      <> command "stat" (info statsParser (progDesc "Show stats"))
      <> command "timeline" (info timelineParser (progDesc "Show timeline"))
      <> command "fetch" (info fetchParser (progDesc "Fetch game"))
      <> command "list" (info listParser (progDesc "List games"))
      <> command "remove" (info removeParser (progDesc "Remove game"))
      <> command "run" (info runParser (progDesc "Run game"))
      <> command "config" (info configParser (progDesc "Config"))
      <> command "use" (info useParser (progDesc "Use game"))
      <> command "update" (info updateParser (progDesc "Update game"))
      <> command "info" (info infoParser (progDesc "Info"))
      <> command "sync" (info syncParser (progDesc "Sync"))
  where
    addParser =
      Add
        <$> argument str (metavar "NAME")
        <*> argument str (metavar "ALIAS")
        <*> optional (argument str (metavar "PATH"))
        <*> option auto (short 'f' <> long "fetch" <> help "Fetch source" <> metavar "SOURCE")
        <*> option auto (short 'o' <> long "order" <> help "Order" <> metavar "ORDER")
        <*> switch (short 'k' <> long "keep-name" <> help "Keep original name")

    removeParser = Remove <$> argument str (metavar "ALIAS") <*> switch (short 'h' <> long "hard" <> help "Remove from hard drive")

    runParser =
      Run
        <$> optional (argument str (metavar "ALIAS"))
        <*> switch (short 'r' <> long "random" <> help "Random game")
        <*> switch (short 'l' <> long "last" <> help "Last played game")
        <*> switch (short 'c' <> long "recent" <> help "Recently played game")

    fetchParser =
      Fetch
        <$> argument str (metavar "NAME")
        <*> option auto (short 'o' <> long "order" <> help "Order" <> metavar "ORDER")
        <*> option auto (short 's' <> long "source" <> help "Source" <> metavar "SOURCE")

    listParser =
      List
        <$> option auto (short 's' <> long "sort" <> help "Sort" <> metavar "SORT")
        <*> switch (short 'r' <> long "reverse" <> help "Reverse")
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER")
        <*> switch (short 'd' <> long "detailed" <> help "Detailed")

    statsParser =
      Stats
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER")

    timelineParser =
      Timeline
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER")

    configParser =
      Config
        <$> argument str (metavar "KEY")
        <*> argument str (metavar "VALUE")

    useParser = Use <$> argument str (metavar "ALIAS") <*> argument str (metavar "PATH")

    updateParser =
      Update
        <$> argument str (metavar "ALIAS")
        <*> switch (short 'k' <> long "keep-name" <> help "Keep original name")
        <*> option auto (short 'f' <> long "fetch" <> help "Fetch source" <> metavar "SOURCE")

    infoParser = Info <$> argument str (metavar "ALIAS")

    syncParser = pure Sync

main :: IO ()
main = execParser opts >>= handle
  where
    opts = info (commandParser <**> helper) (fullDesc <> progDesc "Gal Manager")

    handle :: Command -> IO ()
    handle (Add name alias maybePath fetch order keepName) = do
      TIO.putStrLn $ "Adding game " <> name <> " with alias " <> alias
      TIO.putStrLn $ "Path: " <> fromMaybe "None" maybePath
      TIO.putStrLn $ "Fetch source: " <> pack (show fetch)
      TIO.putStrLn $ "Keep original name: " <> pack (show keepName)
    handle (Remove alias hard) = do
      TIO.putStrLn $ "Removing game with alias " <> alias
      TIO.putStrLn $ "Hard: " <> pack (show hard)
    handle (Run alias random last recent) = do
      TIO.putStrLn $ "Running game with alias " <> fromMaybe "None" alias
      TIO.putStrLn $ "Random: " <> pack (show random)
      TIO.putStrLn $ "Last: " <> pack (show last)
      TIO.putStrLn $ "Recent: " <> pack (show recent)
    handle (Fetch name order source) = do
      TIO.putStrLn $ "Fetching game " <> name
      TIO.putStrLn $ "Order: " <> pack (show order)
      TIO.putStrLn $ "Source: " <> pack (show source)
    handle (List sort reverse filter detailed) = do
      TIO.putStrLn $ "Listing games"
      TIO.putStrLn $ "Sort: " <> pack (show sort)
      TIO.putStrLn $ "Reverse: " <> pack (show reverse)
      TIO.putStrLn $ "Filter: " <> filter
      TIO.putStrLn $ "Detailed: " <> pack (show detailed)
    handle (Stats aliases filter) = do
      TIO.putStrLn $ "Showing stats for aliases " <> pack (show aliases)
      TIO.putStrLn $ "Filter: " <> filter
    handle (Timeline aliases filter) = do
      TIO.putStrLn $ "Showing timeline for aliases " <> pack (show aliases)
      TIO.putStrLn $ "Filter: " <> filter
    handle (Config key value) = do
      TIO.putStrLn $ "Configuring " <> key <> " to " <> value
    handle (Use alias path) = do
      TIO.putStrLn $ "Using game with alias " <> alias
      TIO.putStrLn $ "Path: " <> path
    handle (Update alias keepName fetch) = do
      TIO.putStrLn $ "Updating game with alias " <> alias
      TIO.putStrLn $ "Keep original name: " <> pack (show keepName)
      TIO.putStrLn $ "Fetch source: " <> pack (show fetch)
    handle (Info alias) = do
      TIO.putStrLn $ "Showing info for game with alias " <> alias
    handle Sync = do
      TIO.putStrLn "Syncing games"
