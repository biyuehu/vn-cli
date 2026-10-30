module SenaVN.Command
  ( Command (..),
    MetaOptions (..),
    emptyMeta,
    hasMeta,
    commandParser,
  )
where

import Data.Maybe (isJust)
import Data.Text (Text)
import Options.Applicative

data MetaOptions = MetaOptions
  { metaVndbId :: !(Maybe Text),
    metaDeveloper :: !(Maybe Text),
    metaReleaseDate :: !(Maybe Int),
    metaRating :: !(Maybe Double),
    metaDescription :: !(Maybe Text),
    metaTags :: ![Text]
  }
  deriving (Show)

emptyMeta :: MetaOptions
emptyMeta = MetaOptions Nothing Nothing Nothing Nothing Nothing []

hasMeta :: MetaOptions -> Bool
hasMeta m =
  isJust m.metaVndbId
    || isJust m.metaDeveloper
    || isJust m.metaReleaseDate
    || isJust m.metaRating
    || isJust m.metaDescription
    || not (null m.metaTags)

data Command
  = Add
      { addName :: !Text,
        addCoreId :: !Text,
        addPath :: !(Maybe Text),
        addNoFetch :: !Bool,
        addSkip :: !Bool,
        addOrder :: !Int,
        addKeepName :: !Bool,
        addMeta :: !MetaOptions
      }
  | Edit
      { editCoreId :: !Text,
        editFetch :: !Bool,
        editApply :: !Bool,
        editOrder :: !Int,
        editKeepName :: !Bool,
        editMeta :: !MetaOptions
      }
  | Remove
      { removeCoreId :: !Text,
        removeHard :: !Bool
      }
  | Run
      { runTarget :: !(Maybe Text),
        runRandom :: !Bool,
        runRecent :: !Bool,
        runLast :: !Bool
      }
  | Fetch
      { fetchName :: !Text,
        fetchOrder :: !Int
      }
  | List
      { listSort :: !Text,
        listReverse :: !Bool,
        listFilter :: !Text,
        listDetail :: !Bool
      }
  | Stats
      { statsCoreIds :: ![Text],
        statsFilter :: !Text
      }
  | Timeline
      { tlCoreIds :: ![Text],
        tlFilter :: !Text
      }
  | Use
      { useCoreId :: !Text,
        useExePath :: !Text,
        useSavePath :: !(Maybe Text),
        useGuide :: !(Maybe Text)
      }
  | Info {infoCoreId :: !Text}
  | Status
  | Sync
  | Config {configKey :: !Text, configValue :: !Text}
  deriving (Show)

metaParser :: Parser MetaOptions
metaParser =
  MetaOptions
    <$> optional
      ( option
          str
          ( long "vndb-id"
              <> metavar "ID"
              <> help "VNDB ID (e.g. v12345)"
          )
      )
    <*> optional
      ( option
          str
          ( long "developer"
              <> short 'd'
              <> metavar "DEV"
              <> help "Developer / circle name"
          )
      )
    <*> optional
      ( option
          auto
          ( long "release-date"
              <> metavar "TS"
              <> help "Release date (unix timestamp)"
          )
      )
    <*> optional
      ( option
          auto
          ( long "rating"
              <> metavar "N"
              <> help "Rating 0–100"
          )
      )
    <*> optional
      ( option
          str
          ( long "description"
              <> metavar "DESC"
              <> help "Description text"
          )
      )
    <*> many
      ( option
          str
          ( long "tag"
              <> short 't'
              <> metavar "TAG"
              <> help "Tag (repeatable)"
          )
      )

commandParser :: Parser Command
commandParser =
  subparser $
    command "add" (info addParser (progDesc "Add a game to library"))
      <> command "edit" (info editParser (progDesc "Edit game metadata"))
      <> command "rm" (info rmParser (progDesc "Remove a game"))
      <> command "run" (info runParser (progDesc "Launch a game"))
      <> command "fetch" (info fetchParser (progDesc "Search VNDB"))
      <> command "list" (info listParser (progDesc "List library"))
      <> command "stat" (info statParser (progDesc "Play statistics"))
      <> command "tl" (info tlParser (progDesc "Play timeline"))
      <> command "use" (info useParser (progDesc "Set game executable"))
      <> command "info" (info infoParser' (progDesc "Show game details"))
      <> command "status" (info statusParser (progDesc "Show running games"))
      <> command "sync" (info syncParser (progDesc "Sync to GitHub"))
      <> command "config" (info cfgParser (progDesc "Set config value"))
  where
    addParser =
      Add
        <$> argument
          str
          ( metavar "NAME"
              <> help "Game name or VNDB search term"
          )
        <*> argument
          str
          ( metavar "ID"
              <> help "Unique short ID (e.g. ever17)"
          )
        <*> optional
          ( argument
              str
              ( metavar "PATH"
                  <> help "Executable path"
              )
          )
        <*> switch
          ( long "no-fetch"
              <> short 'n'
              <> help "Skip VNDB fetch"
          )
        <*> switch
          ( long "skip"
              <> short 's'
              <> help "Skip editor, save immediately"
          )
        <*> option
          auto
          ( long "order"
              <> short 'o'
              <> metavar "N"
              <> value 1
              <> help "Use Nth VNDB result (default: 1)"
          )
        <*> switch
          ( long "keep-name"
              <> short 'k'
              <> help "Retain input name after fetch"
          )
        <*> metaParser

    editParser =
      Edit
        <$> argument str (metavar "ID" <> help "Game ID to edit")
        <*> switch
          ( long "fetch"
              <> short 'f'
              <> help "Fetch from VNDB before editing"
          )
        <*> switch
          ( long "apply"
              <> short 'a'
              <> help "With --fetch: save without opening editor"
          )
        <*> option
          auto
          ( long "order"
              <> short 'o'
              <> metavar "N"
              <> value 1
              <> help "VNDB result index"
          )
        <*> switch
          ( long "keep-name"
              <> short 'k'
              <> help "Retain current name after fetch"
          )
        <*> metaParser

    rmParser =
      Remove
        <$> argument str (metavar "ID" <> help "Game ID to remove")
        <*> switch (long "hard" <> short 'H' <> help "Also remove from cloud")

    runParser =
      Run
        <$> optional (argument str (metavar "ID" <> help "Game ID to run"))
        <*> switch (long "random" <> short 'r' <> help "Random game")
        <*> switch (long "recent" <> short 'c' <> help "Most recently played")
        <*> switch (long "last" <> short 'l' <> help "Most recently added")

    fetchParser =
      Fetch
        <$> argument str (metavar "QUERY" <> help "Search query")
        <*> option
          auto
          ( long "order"
              <> short 'o'
              <> metavar "N"
              <> value 0
              <> help "0=all results  N=show Nth in detail"
          )

    listParser =
      List
        <$> option
          str
          ( long "sort"
              <> short 's'
              <> metavar "FIELD"
              <> value "title"
              <> help "title|lastPlay|createDate|releaseDate|rating"
          )
        <*> switch (long "reverse" <> short 'r' <> help "Reverse sort order")
        <*> option
          str
          ( long "filter"
              <> short 'f'
              <> metavar "EXPR"
              <> value ""
              <> help "Filter DSL (TODO)"
          )
        <*> switch (long "detail" <> short 'd' <> help "Detailed per-game view")

    statParser =
      Stats
        <$> many (argument str (metavar "ID..." <> help "Game IDs (empty = all)"))
        <*> option
          str
          ( long "filter"
              <> short 'f'
              <> metavar "EXPR"
              <> value ""
              <> help "Filter DSL (TODO)"
          )

    tlParser =
      Timeline
        <$> many (argument str (metavar "ID..." <> help "Game IDs (empty = all)"))
        <*> option
          str
          ( long "filter"
              <> short 'f'
              <> metavar "EXPR"
              <> value ""
              <> help "Filter DSL (TODO)"
          )

    useParser =
      Use
        <$> argument str (metavar "ID" <> help "Game ID")
        <*> argument str (metavar "PATH" <> help "Executable path")
        <*> optional
          ( option
              str
              ( long "save"
                  <> metavar "PATH"
                  <> help "Save directory"
              )
          )
        <*> optional
          ( option
              str
              ( long "guide"
                  <> metavar "PATH"
                  <> help "Guide / walkthrough file"
              )
          )

    infoParser' = Info <$> argument str (metavar "ID" <> help "Game ID")
    statusParser = pure Status
    syncParser = pure Sync
    cfgParser =
      Config
        <$> argument str (metavar "KEY")
        <*> argument str (metavar "VALUE")
