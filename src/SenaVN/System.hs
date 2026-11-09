module SenaVN.System
  ( findEditor,
    openEditor,
    spawnDaemon,
    openGameGuide,
    openGameSave,
    runWithPager,
  )
where

import Control.Exception (SomeException, catch, try)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (eitherDecode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as BL
import Data.List (isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection)
import Prettyprinter
  ( Doc,
    LayoutOptions (..),
    PageWidth (..),
    layoutPretty,
    pretty,
    (<+>),
  )
import Prettyprinter.Render.Terminal (AnsiStyle, renderIO)
import SenaVN.Core (Romi, askConn, throwR)
import qualified SenaVN.DB as DB
import SenaVN.Error (SenaError (..))
import SenaVN.Interactive (ok)
import SenaVN.Pretty (cyan_, dim_, renderDoc)
import qualified SenaVN.Session as Session
import SenaVN.Types (GameCore (..), GameId (..), GameWithLocal (..), LocalPath (..))
import SenaVN.Utils (getTermWidth, openDirectory)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    findExecutable,
  )
import System.Environment (lookupEnv)
import System.FilePath (normalise, takeDirectory, (</>))
import System.IO (hClose, hIsTerminalDevice, hSetEncoding, stdout, utf8)
import System.IO.Temp (withSystemTempFile)
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    callProcess,
    createProcess,
    proc,
    waitForProcess,
  )

findEditor :: Connection -> IO (Maybe FilePath)
findEditor conn = do
  mCfgEditor <- DB.getTypedConfig conn DB.CoreEditor
  case mCfgEditor of
    Just ed | not (T.null (T.strip ed)) -> pure (Just (T.unpack (T.strip ed)))
    _ -> do
      mVisual <- lookupEnv "VISUAL"
      mEditor <- lookupEnv "EDITOR"
      case filter (not . null) (maybe [] pure mVisual ++ maybe [] pure mEditor) of
        (ed : _) -> pure (Just ed)
        [] -> findInPath ["nvim", "vim", "nano", "vi"]
  where
    findInPath [] = pure Nothing
    findInPath (x : xs) = do
      mPath <- findExecutable x
      case mPath of
        Just _ -> pure (Just x)
        Nothing -> findInPath xs

openEditor :: GameCore -> Romi GameCore
openEditor g = do
  conn <- askConn
  mEditor <- liftIO $ findEditor conn
  editor <- case mEditor of
    Nothing -> throwR EditorNotFound
    Just ed -> pure ed
  raw <- liftIO $
    withSystemTempFile "sena-edit-.json" $ \path h -> do
      BL.hPut h (encodePretty g)
      hClose h
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      callProcess prog (args ++ [path])
      BL.readFile path
  case eitherDecode raw of
    Left err -> throwR (JsonParseError (T.pack err))
    Right g' ->
      pure
        g'
          { coreId = g.coreId,
            createDate = g.createDate,
            playTimelines = g.playTimelines
          }

spawnDaemon :: GameId -> Text -> Text -> IO ()
spawnDaemon (GameId gid) gameName exePath = do
  sessDir <- Session.getSessionsDir
  daemonExe <- Session.getDaemonPath
  let sessionFile = sessDir </> T.unpack gid <> ".session.json"
  _ <-
    createProcess
      ( proc
          daemonExe
          [ "--run",
            "--game-id",
            T.unpack gid,
            "--game-name",
            T.unpack gameName,
            "--exe-path",
            T.unpack exePath,
            "--session",
            sessionFile
          ]
      )
        { std_in = NoStream,
          std_out = NoStream,
          std_err = NoStream,
          create_group = True,
          detach_console = True
        }
  pure ()

openGameGuide :: Connection -> GameWithLocal -> Romi ()
openGameGuide conn gwl = do
  case gwl.local >>= (.guideFile) of
    Nothing -> throwR (GuideNotConfigured gwl.game.coreId)
    Just gFile -> do
      let rawPath = normalise (T.unpack gFile)
      mEditor <- liftIO $ findEditor conn
      editor <- case mEditor of
        Nothing -> throwR EditorNotFound
        Just ed -> pure ed
      let parentDir = takeDirectory rawPath
      liftIO $ unless (null parentDir || parentDir == ".") $
        createDirectoryIfMissing True parentDir
      let (prog, args) = case words editor of
            (p : rest) -> (p, rest)
            [] -> (editor, [])
      liftIO $ callProcess prog (args ++ [rawPath])

openGameSave :: GameWithLocal -> Romi ()
openGameSave gwl = do
  case gwl.local >>= (.savePath) of
    Nothing -> throwR (SaveNotConfigured gwl.game.coreId)
    Just sPath -> do
      let rawDir = normalise (T.unpack sPath)
      isDir <- liftIO $ doesDirectoryExist rawDir
      targetPath <-
        if isDir
          then pure rawDir
          else do
            isFile <- liftIO $ doesFileExist rawDir
            if isFile
              then let p = takeDirectory rawDir in pure (if null p then "." else p)
              else throwR (SavePathNotFound rawDir)
      liftIO $ openDirectory targetPath
      liftIO . ok $ dim_ "opened save directory →" <+> cyan_ (pretty (T.pack targetPath))

runWithPager :: Bool -> Doc AnsiStyle -> IO ()
runWithPager True doc = renderDoc doc
runWithPager False doc = do
  isTerm <- hIsTerminalDevice stdout `catch` \(_ :: SomeException) -> pure False
  if not isTerm
    then renderDoc doc
    else do
      mPager <- lookupEnv "PAGER"
      pagerCmd <- case mPager of
        Just p | not (null (words p)) -> pure (words p)
        _ -> do
          mLess <- findExecutable "less"
          case mLess of
            Just _ -> pure ["less", "-FRX"]
            Nothing -> pure []
      case pagerCmd of
        [] -> renderDoc doc
        (prog : args) -> do
          let finalArgs =
                if "less" `isSuffixOf` prog && not (any (\a -> 'R' `elem` a) args)
                  then args ++ ["-FRX"]
                  else args
          spawnRes <- try $
            createProcess
              (proc prog finalArgs)
                { std_in = CreatePipe,
                  std_out = Inherit,
                  std_err = Inherit
                }
          case spawnRes of
            Left (_ :: SomeException) -> renderDoc doc
            Right (Just hIn, _, _, ph) -> do
              hSetEncoding hIn utf8
              w <- getTermWidth
              let opts = LayoutOptions (AvailablePerLine (max 40 w) 1.0)
              _ <- try (renderIO hIn (layoutPretty opts doc)) :: IO (Either SomeException ())
              _ <- try (hClose hIn) :: IO (Either SomeException ())
              _ <- waitForProcess ph
              pure ()
            Right _ -> renderDoc doc
