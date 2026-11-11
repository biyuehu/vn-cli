module SenaVN.Command
  ( Command (..),
    MetaOptions (..),
    SortField (..),
    ShellType (..),
    emptyMeta,
    hasMeta,
    commandParser,
  )
where

import Control.Exception (SomeException, catch)
import Data.Char (toLower)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), close, open, query_)
import Options.Applicative
import qualified SenaVN.DB as DB
import SenaVN.Types (GameId (..))
import System.Directory (doesFileExist)

gameIdCompleter :: Completer
gameIdCompleter = listIOCompleter fetchGameIds

fetchGameIds :: IO [String]
fetchGameIds =
  ( do
      dbPath <- DB.getDBPath
      exists <- doesFileExist dbPath
      if not exists
        then pure []
        else do
          conn <- open dbPath
          ids <- query_ conn "SELECT id FROM games ORDER BY id" :: IO [Only Text]
          close conn
          pure (map (T.unpack . fromOnly) ids)
  )
    `catch` \(_ :: SomeException) -> pure []

data SortField
  = SortTitle
  | SortLastPlay
  | SortCreateDate
  | SortReleaseDate
  | SortRating
  | SortPlayed
  deriving (Show, Eq, Enum, Bounded)

sortFieldReader :: ReadM SortField
sortFieldReader = eitherReader $ \s -> case map toLower s of
  "title" -> Right SortTitle
  "lastplay" -> Right SortLastPlay
  "createdate" -> Right SortCreateDate
  "releasedate" -> Right SortReleaseDate
  "rating" -> Right SortRating
  "played" -> Right SortPlayed
  other -> Left $ "unknown sort field '" ++ other ++ "', valid: title|lastPlay|createDate|releaseDate|rating|played"

data ShellType
  = ShellBash
  | ShellZsh
  | ShellFish
  deriving (Show, Eq, Enum, Bounded)

shellTypeReader :: ReadM ShellType
shellTypeReader = eitherReader $ \s -> case map toLower s of
  "bash" -> Right ShellBash
  "zsh" -> Right ShellZsh
  "fish" -> Right ShellFish
  other -> Left $ "unsupported shell '" ++ other ++ "', valid: bash|zsh|fish"

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
        addCoreId :: !GameId,
        addPath :: !(Maybe Text),
        addNoFetch :: !Bool,
        addSkip :: !Bool,
        addOrder :: !Int,
        addKeepName :: !Bool,
        addMeta :: !MetaOptions
      }
  | Edit
      { editCoreId :: !GameId,
        editFetch :: !Bool,
        editApply :: !Bool,
        editOrder :: !Int,
        editKeepName :: !Bool,
        editMeta :: !MetaOptions
      }
  | Remove
      { removeCoreId :: !GameId,
        removeHard :: !Bool
      }
  | Move
      { moveOldId :: !GameId,
        moveNewId :: !GameId
      }
  | Run
      { runTarget :: !(Maybe Text),
        runSkip :: !Bool,
        runRandom :: !Bool,
        runRecent :: !Bool,
        runLast :: !Bool,
        runFilter :: !(Maybe Text)
      }
  | Fetch
      { fetchName :: !Text,
        fetchOrder :: !Int
      }
  | List
      { listSort :: !SortField,
        listReverse :: !Bool,
        listFilter :: !Text,
        listDetail :: !Bool
      }
  | Stats
      { statsCoreIds :: ![GameId],
        statsFilter :: !Text
      }
  | Timeline
      { tlCoreIds :: ![GameId],
        tlFilter :: !Text,
        tlMaxCount :: !(Maybe Int),
        tlOneline :: !Bool,
        tlToday :: !Bool,
        tlReverse :: !Bool,
        tlNoPager :: !Bool
      }
  | Use
      { useCoreId :: !GameId,
        useExePath :: !Text,
        useSavePath :: !(Maybe Text),
        useGuide :: !(Maybe Text)
      }
  | Info
      { infoCoreId :: !GameId,
        infoGuide :: !Bool,
        infoSave :: !Bool
      }
  | Status
  | Sync
      { syncDryRun :: !Bool
      }
  | Config
      { configKey :: !(Maybe Text),
        configValue :: !(Maybe Text),
        configUnset :: !(Maybe Text),
        configEdit :: !Bool
      }
  | Completion {completionShell :: !ShellType}
  | Tui
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
    sub "add" addParser "Add a game to library"
      <> sub "edit" editParser "Edit game metadata"
      <> sub "rm" rmParser "Remove a game"
      <> sub "mv" mvParser "Rename a game ID"
      <> sub "run" runParser "Launch a game"
      <> sub "fetch" fetchParser "Search VNDB"
      <> sub "list" listParser "List library"
      <> sub "stat" statParser "Play statistics"
      <> sub "tl" tlParser "Play timeline"
      <> sub "use" useParser "Set game executable"
      <> sub "info" infoParser' "Show game details"
      <> sub "status" statusParser "Show running games"
      <> sub "sync" syncParser "Sync to GitHub"
      <> sub "config" cfgParser "Manage configuration"
      <> sub "completion" completionParser "Generate shell completion script"
      <> sub "tui" (pure Tui) "Open interactive TUI browser"
  where
    sub cmd p desc = command cmd (info (p <**> helper) (progDesc desc))
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
        <$> argument str (metavar "ID" <> help "Game ID to edit" <> completer gameIdCompleter)
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
        <$> argument str (metavar "ID" <> help "Game ID to remove" <> completer gameIdCompleter)
        <*> switch (long "hard" <> short 'H' <> help "Permanently remove and mark for cloud deletion (record tombstone)")

    mvParser =
      Move
        <$> argument str (metavar "OLD_ID" <> help "Current game ID to rename" <> completer gameIdCompleter)
        <*> argument str (metavar "NEW_ID" <> help "New game ID")

    runParser =
      Run
        <$> optional (argument str (metavar "ID_OR_NAME" <> help "Game ID or title query" <> completer gameIdCompleter))
        <*> switch (long "skip" <> short 's' <> help "Exact ID match only, skip fuzzy search")
        <*> switch (long "random" <> help "Random game")
        <*> switch (long "recent" <> short 'R' <> help "Most recently played")
        <*> switch (long "last" <> short 'L' <> help "Most recently added")
        <*> optional (strOption (long "filter" <> short 'f' <> metavar "FILTER" <> help "Filter games by tag, developer, or title (useful with --random)"))

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
          sortFieldReader
          ( long "sort"
              <> short 's'
              <> metavar "FIELD"
              <> value SortTitle
              <> help "title|lastPlay|createDate|releaseDate|rating|played"
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
        <$> many (argument str (metavar "ID..." <> help "Game IDs (empty = all)" <> completer gameIdCompleter))
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
        <$> many (argument str (metavar "ID..." <> help "Game IDs (empty = all)" <> completer gameIdCompleter))
        <*> option
          str
          ( long "filter"
              <> short 'f'
              <> metavar "EXPR"
              <> value ""
              <> help "Filter DSL (TODO)"
          )
        <*> optional
          ( option
              auto
              ( long "max-count"
                  <> short 'n'
                  <> metavar "NUM"
                  <> help "Limit the number of sessions output"
              )
          )
        <*> switch
          ( long "oneline"
              <> help "Display each session on a single line"
          )
        <*> switch
          ( long "today"
              <> help "Only show sessions recorded today"
          )
        <*> switch
          ( long "reverse"
              <> help "Output sessions in reverse order (chronological)"
          )
        <*> switch
          ( long "no-pager"
              <> help "Do not pipe output into a pager"
          )

    useParser =
      Use
        <$> argument str (metavar "ID" <> help "Game ID" <> completer gameIdCompleter)
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

    infoParser' =
      Info
        <$> argument str (metavar "ID" <> help "Game ID" <> completer gameIdCompleter)
        <*> switch (long "guide" <> short 'g' <> help "Open guide file in editor")
        <*> switch (long "save" <> short 's' <> help "Open save directory in file manager")
    statusParser = pure Status
    syncParser =
      Sync
        <$> switch (long "dry-run" <> short 'n' <> help "Simulate sync without applying local or remote changes")
    cfgParser =
      Config
        <$> optional (argument str (metavar "KEY" <> help "Config key"))
        <*> optional (argument str (metavar "VALUE" <> help "Config value"))
        <*> optional (strOption (long "unset" <> short 'u' <> metavar "KEY" <> help "Remove config key"))
        <*> switch (long "edit" <> short 'e' <> help "Edit configuration in $EDITOR")
    completionParser =
      Completion
        <$> argument shellTypeReader (metavar "SHELL" <> help "bash|zsh|fish")
