module SenaVN.Handler.Config
  ( handleConfig,
    handleCompletion,
    validateConfigKey,
    editConfigInteractive,
  )
where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Database.SQLite.Simple (Connection)
import Prettyprinter
import SenaVN.Command (Command (..), ShellType (..))
import SenaVN.Core (Romi, askConn, throwR)
import SenaVN.DB qualified as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Interactive (ok, printLn)
import SenaVN.Pretty (cyan_, dim_)
import SenaVN.System (findEditor)
import SenaVN.Utils (maskSensitive)
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)
import System.Process (callProcess)

validateConfigKey :: Text -> Either Text ()
validateConfigKey k
  | T.null (T.strip k) = Left "config key cannot be empty"
  | T.any (\c -> c == ' ' || c == '\t' || c == '=' || c == '#' || c == ';') k =
      Left "config key cannot contain whitespace, '=', '#', or ';'"
  | otherwise = Right ()

editConfigInteractive :: Connection -> Romi ()
editConfigInteractive conn = do
  mEditor <- liftIO $ findEditor conn
  editor <- case mEditor of
    Nothing -> throwR EditorNotFound
    Just ed -> pure ed
  cfgs <- liftIO $ DB.getAllConfigs conn
  let initialContent =
        T.unlines $
          [ "# SenaVN Configuration",
            "# Format: key = value",
            "# Lines starting with '#' or ';' are ignored."
          ]
            ++ concatMap renderConfigEntry cfgs
  content <- liftIO $
    withSystemTempFile "sena-config-.ini" $ \path h -> do
      TIO.hPutStr h initialContent
      hClose h
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      callProcess prog (args ++ [path])
      TIO.readFile path
  parsed <- parseConfigContent content
  liftIO $ DB.setAllConfigs conn parsed
  liftIO . ok $ pretty ("Configuration updated (" <> show (length parsed) <> " entries).")
  where
    renderConfigEntry (k, v) =
      case fieldDoc k of
        Just doc -> ["", doc, k <> " = " <> v]
        Nothing -> [k <> " = " <> v]

    fieldDoc "core.editor" =
      Just "# Preferred text editor for metadata and config (e.g. code --wait, nvim, notepad)"
    fieldDoc "fetch.proxy" =
      Just "# Proxy URL for VNDB and cloud synchronization (e.g. http://127.0.0.1:7890)"
    fieldDoc "sync.branch" =
      Just "# Cloud sync branch name (default: main)"
    fieldDoc "sync.path" =
      Just "# Cloud sync file path in repository (default: data.json)"
    fieldDoc "sync.repo" =
      Just "# Target GitHub repository in 'owner/repo' format"
    fieldDoc "sync.token" =
      Just "# GitHub Personal Access Token (with repo scope)"
    fieldDoc _ = Nothing

    parseConfigContent :: Text -> Romi [(Text, Text)]
    parseConfigContent txt = mapM parseLine (filter (not . isIgnored) (T.lines txt))

    isIgnored l =
      let s = T.strip l
       in T.null s || "#" `T.isPrefixOf` s || ";" `T.isPrefixOf` s

    parseLine l =
      let (kRaw, rest) = T.breakOn "=" l
       in if T.null rest
            then throwR (ConfigFileLineInvalid l "missing '=' delimiter")
            else
              let k = T.strip kRaw
                  v = T.strip (T.drop 1 rest)
               in case validateConfigKey k of
                    Left err -> throwR (ConfigFileLineInvalid l err)
                    Right () -> pure (k, v)

handleConfig :: Command -> Romi ()
handleConfig Config {configKey, configValue, configUnset, configEdit} = do
  conn <- askConn
  let doUnset k = do
        deleted <- liftIO $ DB.deleteConfig conn k
        if deleted
          then liftIO . ok $ dim_ "unset" <+> cyan_ (pretty k)
          else throwR (ConfigKeyNotFound k)

  if configEdit || (configKey == Just "edit" && isNothing configValue)
    then editConfigInteractive conn
    else case configUnset of
      Just k -> doUnset k
      Nothing -> case (configKey, configValue) of
        (Just "rm", Just k) -> doUnset k
        (Just "unset", Just k) -> doUnset k
        (Just "rm", Nothing) -> throwR ConfigMissingKey
        (Just "unset", Nothing) -> throwR ConfigMissingKey
        (Nothing, Nothing) -> do
          cfgs <- liftIO $ DB.getAllConfigs conn
          if null cfgs
            then liftIO $ putStrLn "no configuration set."
            else liftIO $ forM_ cfgs $ \(k, v) ->
              printLn $ cyan_ (pretty k) <+> dim_ "=" <+> pretty (maskSensitive k v)
        (Just k, Nothing) -> do
          mv <- liftIO $ DB.getConfig conn k
          case mv of
            Just v -> liftIO $ putStrLn (T.unpack v)
            Nothing -> throwR (ConfigKeyNotFound k)
        (Just k, Just v) -> do
          case validateConfigKey k of
            Left err -> throwR (ConfigKeyInvalid k err)
            Right () -> do
              liftIO $ DB.setConfig conn k v
              liftIO . ok $ cyan_ (pretty k) <+> dim_ "=" <+> pretty v
        (Nothing, Just _) ->
          throwR ConfigMissingValue
handleConfig _ = pure ()

handleCompletion :: Command -> Romi ()
handleCompletion Completion {completionShell} = liftIO $ do
  case completionShell of
    ShellBash -> putStrLn "eval \"$(sena --bash-completion-script sena)\""
    ShellZsh -> putStrLn "eval \"$(sena --zsh-completion-script sena)\""
    ShellFish -> putStrLn "sena --fish-completion-script sena | source"
handleCompletion _ = pure ()
