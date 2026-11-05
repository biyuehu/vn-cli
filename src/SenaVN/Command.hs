{-# LANGUAGE ScopedTypeVariables #-}

module SenaVN.Command
  ( Command (..),
    MetaOptions (..),
    emptyMeta,
    hasMeta,
    commandParser,
  )
where

import Control.Exception (SomeException, catch)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), close, open, query_)
import Options.Applicative
import System.Directory (doesFileExist, getHomeDirectory)
import System.FilePath ((</>))

gameIdCompleter :: Completer
gameIdCompleter = listIOCompleter fetchGameIds

fetchGameIds :: IO [String]
fetchGameIds =
  ( do
      home <- getHomeDirectory
      let dbPath = home </> ".senavn" </> "sena.db"
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
  | Move
      { moveOldId :: !Text,
        moveNewId :: !Text
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
  | Completion {completionShell :: !Text}
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
      <> sub "config" cfgParser "Set config value"
      <> sub "completion" completionParser "Generate shell completion script"
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
        <*> switch (long "hard" <> short 'H' <> help "Also remove from cloud")

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

    infoParser' = Info <$> argument str (metavar "ID" <> help "Game ID" <> completer gameIdCompleter)
    statusParser = pure Status
    syncParser = pure Sync
    cfgParser =
      Config
        <$> argument str (metavar "KEY")
        <*> argument str (metavar "VALUE")
    completionParser =
      Completion
        <$> argument str (metavar "SHELL" <> help "bash|zsh|fish")
