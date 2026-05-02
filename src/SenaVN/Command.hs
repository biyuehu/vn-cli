module SenaVN.Command where

import Data.Text (Text)
import Options.Applicative as O

-- fetchSource :: [Text]
-- fetchSource = ["VNDB"]

data Command
  = Add {name :: Text, coreId :: Text, maybePath :: Maybe Text, noFetch :: Bool, order :: Int, keepName :: Bool}
  | Remove {coreId :: Text, hard :: Bool}
  | Run {runAlias :: Maybe Text {- find :: Text, -}, random :: Bool, last :: Bool, recent :: Bool}
  | Fetch {name :: Text, order :: Int}
  | List {sort :: Text, reverse :: Bool, filterDsl :: Text, detailed :: Bool}
  | Stats {coreIds :: [Text], filterDsl :: Text}
  | Timeline {coreIds :: [Text], filterDsl :: Text}
  | Config {key :: Text, newValue :: Text}
  | Use {coreId :: Text, path :: Text}
  | Update {coreId :: Text, keepName :: Bool, fetch :: Bool}
  | Info {coreId :: Text}
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
      <> command "info" (info infoParser' (progDesc "Info"))
      <> command "sync" (info syncParser (progDesc "Sync"))
  where
    addParser =
      Add
        <$> argument str (metavar "TITLE")
        <*> argument str (metavar "ALIAS")
        <*> optional (argument str (metavar "PATH"))
        <*> switch (short 'n' <> long "no-fetch" <> help "No fetching")
        <*> option auto (short 'o' <> long "order" <> help "Order fetching result" <> metavar "ORDER" <> value 0)
        <*> switch (short 'k' <> long "keep-name" <> help "Keep input name")

    removeParser = Remove <$> argument str (metavar "ALIAS") <*> switch (short 'h' <> long "hard" <> help "Remove from cloud")

    runParser =
      Run
        <$> optional (argument str (metavar "ALIAS"))
        <*> switch (short 'r' <> long "random" <> help "Random game")
        <*> switch (short 'l' <> long "last" <> help "Last played game")
        <*> switch (short 'c' <> long "recent" <> help "Recently played game")

    fetchParser =
      Fetch
        <$> argument str (metavar "TITLE")
        <*> option auto (short 'o' <> long "order" <> help "Order" <> metavar "ORDER" <> value 0)

    listParser =
      List
        <$> option auto (short 's' <> long "sort" <> help "Sort" <> metavar "SORT" <> value "title")
        <*> switch (short 'r' <> long "reverse" <> help "Reverse")
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")
        <*> switch (short 'd' <> long "detailed" <> help "Detailed")

    statsParser =
      Stats
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")

    timelineParser =
      Timeline
        <$> some (argument str (metavar "ALIAS"))
        <*> option auto (short 'f' <> long "filter" <> help "Filter" <> metavar "FILTER" <> value "")

    configParser =
      Config
        <$> argument str (metavar "KEY")
        <*> argument str (metavar "VALUE")

    useParser = Use <$> argument str (metavar "ALIAS") <*> argument str (metavar "PATH")

    updateParser =
      Update
        <$> argument str (metavar "ALIAS")
        <*> switch (short 'k' <> long "keep-name" <> help "Keep original name")
        <*> switch (short 'f' <> long "fetch" <> help "Auto fetching")

    infoParser' = Info <$> argument str (metavar "ALIAS")

    syncParser = pure Sync
