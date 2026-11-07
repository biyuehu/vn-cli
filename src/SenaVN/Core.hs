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
import Data.Text (Text)
import Database.SQLite.Simple (Connection)
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Types (GameId (..))

data SenaError
  -- Game lookup & lifecycle
  = GameNotFound !GameId
  | GameAlreadyExists !GameId
  | GameTargetNotFound !Text
  | GameAlreadyRunning !GameId !Text !Int
  | EmptyLibrary
  | NoGamesMatchingFilter !(Maybe Text)
  | NoGamesPlayedYet
  | NoMatchingGamesFound ![GameId]

  -- Game local path configuration
  | ExeNotConfigured !GameId !Text
  | GuideNotConfigured !GameId
  | SaveNotConfigured !GameId
  | SavePathNotFound !FilePath

  -- External tools & parsing
  | EditorNotFound
  | JsonParseError !Text

  -- VNDB API
  | VndbNoResults !Text
  | VndbInvalidOrder !Int !Int

  -- App configuration
  | ConfigKeyNotFound !Text
  | ConfigKeyInvalid !Text !Text
  | ConfigFileLineInvalid !Text !Text
  | ConfigMissingKey
  | ConfigMissingValue

  -- Command input & operations
  | InvalidNewGameId !GameId !Text
  | ConflictingRunFlags
  | MissingRunTarget
  | NotImplemented !Text
  | UserCancelled
  deriving (Show, Eq)

renderSenaErrorDoc :: SenaError -> Doc AnsiStyle
renderSenaErrorDoc err = case err of
  GameNotFound gid ->
    vsep
      [ errHead ("game" <+> cyanId gid <+> "not found in library."),
        hintLine "run 'sena list' to see all registered games."
      ]

  GameAlreadyExists gid ->
    vsep
      [ errHead ("game" <+> cyanId gid <+> "already exists in library."),
        hintLine ("choose a different ID, or run 'sena info " <> pretty gid.unGameId <> "' to view it.")
      ]

  GameTargetNotFound target ->
    vsep
      [ errHead ("no configured game found matching" <+> whiteBold (pretty ("'" <> target <> "'")) <> "."),
        hintLine "check available games with 'sena list', or configure an executable with 'sena use <id> <path>'."
      ]

  GameAlreadyRunning gid title pid ->
    vsep
      [ errHead ("game" <+> whiteBold (pretty ("'" <> title <> "'")) <+> cyanId gid <+> "is already running" <+> dim_ ("(PID: " <> pretty pid <> ")") <> "."),
        hintLine "close the running game first, or inspect active sessions with 'sena status'."
      ]

  EmptyLibrary ->
    vsep
      [ errHead "your library is empty.",
        hintLine "add a game with: sena add <title>"
      ]

  NoGamesMatchingFilter _ ->
    vsep
      [ errHead "no games match the specified filter.",
        hintLine "run 'sena list' without filters to see all games in your library."
      ]

  NoGamesPlayedYet ->
    vsep
      [ errHead "no games have been played yet.",
        hintLine "launch a game with: sena run <id>"
      ]

  NoMatchingGamesFound _ ->
    vsep
      [ errHead "no matching games found in library.",
        hintLine "run 'sena list' to view registered game IDs."
      ]

  ExeNotConfigured gid title ->
    vsep
      [ errHead ("no executable configured for" <+> whiteBold (pretty ("'" <> title <> "'")) <+> cyanId gid <> "."),
        hintLine ("link an executable with: sena use " <> pretty gid.unGameId <> " <path-to-exe>")
      ]

  GuideNotConfigured gid ->
    vsep
      [ errHead ("no guide file configured for game" <+> cyanId gid <> "."),
        hintLine ("link a guide file with: sena use " <> pretty gid.unGameId <> " <path-to-exe> --guide <path>")
      ]

  SaveNotConfigured gid ->
    vsep
      [ errHead ("no save directory configured for game" <+> cyanId gid <> "."),
        hintLine ("link a save directory with: sena use " <> pretty gid.unGameId <> " <path-to-exe> --save <path>")
      ]

  SavePathNotFound path ->
    vsep
      [ errHead "save directory does not exist on disk:",
        indent 4 (cyan_ (pretty path)),
        hintLine "verify the path or update it with: sena use <id> <exe> --save <path>"
      ]

  EditorNotFound ->
    vsep
      [ errHead "no text editor found.",
        hintLine "configure 'core.editor' with: sena config core.editor <editor>",
        hintLine "or set your $VISUAL or $EDITOR environment variable."
      ]

  JsonParseError details ->
    vsep
      [ errHead "failed to parse edited JSON file:",
        indent 4 (dim_ (pretty details)),
        hintLine "ensure the temporary file contains valid JSON syntax."
      ]

  VndbNoResults query ->
    vsep
      [ errHead ("no results found on VNDB for query:" <+> whiteBold (pretty ("'" <> query <> "'")) <> "."),
        hintLine "check the spelling, search by VNDB ID directly (e.g. v123), or verify your proxy configuration."
      ]

  VndbInvalidOrder idx total ->
    vsep
      [ errHead ("invalid result index:" <+> pretty idx <+> dim_ ("(only " <> pretty total <> " result(s) returned)") <> "."),
        hintLine ("specify --order between 1 and " <> pretty total <> ".")
      ]

  ConfigKeyNotFound k ->
    vsep
      [ errHead ("configuration key" <+> cyanKey k <+> "is not set."),
        hintLine "run 'sena config' to view all current settings."
      ]

  ConfigKeyInvalid k reason ->
    vsep
      [ errHead ("invalid configuration key" <+> cyanKey k <> ":" <+> pretty reason <> "."),
        hintLine "keys must not contain spaces, '=', '#', or ';'."
      ]

  ConfigFileLineInvalid rawLine reason ->
    vsep
      [ errHead "invalid line in configuration file:",
        indent 4 (dim_ (pretty rawLine)),
        hintLine ("reason: " <> pretty reason)
      ]

  ConfigMissingKey ->
    vsep
      [ errHead "missing configuration key.",
        hintLine "usage: sena config <key> [value]  or  sena config rm <key>"
      ]

  ConfigMissingValue ->
    vsep
      [ errHead "cannot specify a configuration value without a key.",
        hintLine "usage: sena config <key> <value>"
      ]

  InvalidNewGameId gid reason ->
    vsep
      [ errHead ("invalid game ID" <+> cyanId gid <> ":" <+> pretty reason <> "."),
        hintLine "game IDs may only contain letters, numbers, hyphens, and underscores."
      ]

  ConflictingRunFlags ->
    vsep
      [ errHead "conflicting options: only one of <id|name>, --random, --recent, or --last can be specified.",
        hintLine "run 'sena run --help' for command usage details."
      ]

  MissingRunTarget ->
    vsep
      [ errHead "no game target specified.",
        hintLine "specify a game ID/name, or use --random / --recent / --last."
      ]

  NotImplemented feature ->
    vsep
      [ errHead ("feature not yet implemented:" <+> whiteBold (pretty feature) <> ".")
      ]

  UserCancelled ->
    annotate (color Yellow <> bold) "!" <+> dim_ "operation cancelled."
  where
    errHead msg = annotate (color Red <> bold) "✗ error:" <+> msg
    hintLine msg = indent 2 (dim_ "↳" <+> annotate (color Yellow) "hint:" <+> msg)
    cyanId (GameId gid) = annotate (color Magenta <> bold) (pretty ("(#" <> gid <> ")"))
    cyanKey k = annotate (color Cyan <> bold) (pretty ("'" <> k <> "'"))
    whiteBold doc = annotate (color White <> bold) doc
    cyan_ = annotate (color Cyan)
    dim_ = annotate (colorDull Black)

renderSenaError :: SenaError -> Text
renderSenaError = renderStrict . layoutCompact . renderSenaErrorDoc

newtype Env = Env {envConn :: Connection}

type Romi = ReaderT Env (ExceptT SenaError IO)

throwR :: SenaError -> Romi a
throwR = lift . throwE

askConn :: Romi Connection
askConn = asks (.envConn)

runRomi :: Env -> Romi a -> IO (Either SenaError a)
runRomi env m = runExceptT (runReaderT m env)