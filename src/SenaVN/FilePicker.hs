module SenaVN.FilePicker
  ( pickFilePath,
    pickDirPath,
  )
where

import Brick
  ( App (..),
    AttrMap,
    AttrName,
    BrickEvent (..),
    EventM,
    Padding (..),
    Widget,
    attrMap,
    attrName,
    customMain,
    hBox,
    halt,
    neverShowCursor,
    padLeft,
    padRight,
    str,
    txt,
    vBox,
    withAttr,
    withBorderStyle,
    (<+>),
  )
import Brick.Util (fg, on)
import Brick.Widgets.Border (borderWithLabel, hBorder)
import Brick.Widgets.Border.Style (unicodeRounded)
import Control.Exception (SomeException, catch)
import Control.Monad (filterM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (get, modify, put)
import Data.Char (toLower)
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Graphics.Vty qualified as V
import Graphics.Vty.CrossPlatform qualified as VCP
import System.Directory
  ( doesDirectoryExist,
    listDirectory,
  )
import System.FilePath (takeDirectory, (</>))

-- ---------------------------------------------------------------------------
-- Types & State
-- ---------------------------------------------------------------------------

data PickMode = PickFile | PickDir deriving (Eq)

data FsEntry
  = FsParent
  | FsDrive !FilePath
  | FsDir !FilePath
  | FsFile !FilePath
  deriving (Eq)

fsEntryDisplayName :: FsEntry -> String
fsEntryDisplayName FsParent = ".."
fsEntryDisplayName (FsDrive d) = d
fsEntryDisplayName (FsDir d) = d
fsEntryDisplayName (FsFile f) = f

fsEntryMatchName :: FsEntry -> String
fsEntryMatchName FsParent = ""
fsEntryMatchName (FsDrive d) = d
fsEntryMatchName (FsDir d) = d
fsEntryMatchName (FsFile f) = f

data PickerLocation
  = LocPath !FilePath
  | LocDrives
  deriving (Eq)

pageSize :: Int
pageSize = 16

data PickerState = PickerState
  { mode :: !PickMode,
    location :: !PickerLocation,
    entries :: ![FsEntry],
    selectedIdx :: !Int,
    scrollOffset :: !Int,
    filterBuf :: !String,
    result :: !(Maybe Text)
  }

type ResourceName = ()

-- ---------------------------------------------------------------------------
-- Entry loading
-- ---------------------------------------------------------------------------

getAvailableDrives :: IO [FilePath]
getAvailableDrives = do
  let candidates = [[c, ':', '\\'] | c <- ['A' .. 'Z']]
  filterM doesDirectoryExist candidates

loadEntries :: PickMode -> PickerLocation -> IO [FsEntry]
loadEntries _ LocDrives = do
  drives <- getAvailableDrives
  if null drives
    then pure [FsDir "/"]
    else pure (map FsDrive drives)
loadEntries m (LocPath dir) = do
  names <- (sort <$> listDirectory dir) `catch` \(_ :: SomeException) -> pure []
  classified <- mapM classify names
  let dirs = [e | e@(FsDir _) <- classified]
      files = [e | e@(FsFile _) <- classified]
      body = case m of
        PickDir -> dirs
        PickFile -> dirs ++ files
  pure (FsParent : body)
  where
    classify name = do
      let full = dir </> name
      isD <- doesDirectoryExist full `catch` \(_ :: SomeException) -> pure False
      pure $ if isD then FsDir name else FsFile name

-- | Base directory is ROOT (LocDrives on Windows, "/" on Unix)
initialPickerState :: PickMode -> IO PickerState
initialPickerState m = do
  let loc = LocDrives
  es <- loadEntries m loc
  pure $
    PickerState
      { mode = m,
        location = loc,
        entries = es,
        selectedIdx = 0,
        scrollOffset = 0,
        filterBuf = "",
        result = Nothing
      }

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

attrSelected :: AttrName
attrSelected = attrName "selected"

attrDir :: AttrName
attrDir = attrName "dir"

attrFile :: AttrName
attrFile = attrName "file"

attrDrive :: AttrName
attrDrive = attrName "drive"

attrParent :: AttrName
attrParent = attrName "parent"

attrFilter :: AttrName
attrFilter = attrName "filter"

attrDim :: AttrName
attrDim = attrName "dim"

locationText :: PickerLocation -> Text
locationText LocDrives = "This PC (Root / Drives)"
locationText (LocPath p) = T.pack p

adjustScroll :: Int -> Int -> Int
adjustScroll sel off
  | sel < off = sel
  | sel >= off + pageSize = sel - pageSize + 1
  | otherwise = off

drawPicker :: PickerState -> [Widget ResourceName]
drawPicker ps =
  let visible = filteredEntries ps
      tot = length visible
      cur = if tot == 0 then 0 else ps.selectedIdx + 1
      modeLabel = if ps.mode == PickFile then "Select File" else "Select Directory"
      titleW = str (" " ++ modeLabel ++ " [" ++ show cur ++ "/" ++ show tot ++ "] ")
   in [ withBorderStyle unicodeRounded $
          borderWithLabel titleW $
            vBox
              [ padLeft (Pad 1) $ padRight (Pad 1) $ txt (locationText ps.location),
                hBorder,
                drawList ps visible,
                hBorder,
                drawFilter ps,
                hBorder,
                drawHelp ps
              ]
      ]

drawList :: PickerState -> [FsEntry] -> Widget ResourceName
drawList ps visible
  | null visible = padLeft (Pad 2) $ withAttr attrDim $ str "No matching files or directories."
  | otherwise =
      let tot = length visible
          window = take pageSize (drop ps.scrollOffset visible)
          indexedWindow = zip [ps.scrollOffset ..] window
          rendered = map (\(idx, entry) -> drawEntry ps.selectedIdx idx entry) indexedWindow
          topMore =
            if ps.scrollOffset > 0
              then [padLeft (Pad 2) $ withAttr attrDim $ str ("▲ (" ++ show ps.scrollOffset ++ " more above)")]
              else []
          botMore =
            let remaining = tot - (ps.scrollOffset + pageSize)
             in if remaining > 0
                  then [padLeft (Pad 2) $ withAttr attrDim $ str ("▼ (" ++ show remaining ++ " more below)")]
                  else []
       in vBox (topMore ++ rendered ++ botMore)

drawEntry :: Int -> Int -> FsEntry -> Widget ResourceName
drawEntry selIdx idx entry =
  let name = fsEntryDisplayName entry
      (icon, baseAttr) = case entry of
        FsParent -> ("⤴ ", attrParent)
        FsDrive _ -> ("💽 ", attrDrive)
        FsDir _ -> ("📁 ", attrDir)
        FsFile _ -> ("📄 ", attrFile)
      prefix = if idx == selIdx then " > " else "   "
      lineW = txt (T.pack (prefix ++ icon)) <+> txt (T.pack name)
      styled =
        if idx == selIdx
          then withAttr attrSelected lineW
          else withAttr baseAttr lineW
   in styled

drawFilter :: PickerState -> Widget ResourceName
drawFilter ps
  | null ps.filterBuf = padLeft (Pad 1) $ withAttr attrFilter $ str " / to search…"
  | otherwise = padLeft (Pad 1) $ withAttr attrFilter $ str ("/" ++ ps.filterBuf ++ "▌")

drawHelp :: PickerState -> Widget ResourceName
drawHelp ps =
  padLeft (Pad 1) $
    hBox $
      case ps.mode of
        PickFile ->
          [ str "↑↓/jk navigate  ",
            str "Enter select/open  ",
            str "Bksp/Left parent  ",
            str "/ search  ",
            str "Esc/q cancel"
          ]
        PickDir ->
          [ str "↑↓/jk navigate  ",
            str "Enter open  ",
            str "Space select dir  ",
            str "Bksp/Left parent  ",
            str "/ search  ",
            str "Esc/q cancel"
          ]

-- ---------------------------------------------------------------------------
-- Filtering & Clamping
-- ---------------------------------------------------------------------------

filteredEntries :: PickerState -> [FsEntry]
filteredEntries ps
  | null ps.filterBuf = ps.entries
  | otherwise =
      let q = map toLower ps.filterBuf
       in filter
            ( \e -> case e of
                FsParent -> True
                other -> isPrefixOf q (map toLower (fsEntryMatchName other))
            )
            ps.entries

clampIdx :: PickerState -> PickerState
clampIdx ps =
  let tot = length (filteredEntries ps)
      maxIdx = max 0 (tot - 1)
      sel = max 0 (min maxIdx ps.selectedIdx)
      off = adjustScroll sel ps.scrollOffset
   in ps {selectedIdx = sel, scrollOffset = off}

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

handlePickerEvent :: BrickEvent ResourceName () -> EventM ResourceName PickerState ()
handlePickerEvent (VtyEvent ev) = do
  ps <- get
  if null ps.filterBuf
    then handleNormal ev
    else handleFilterMode ev
handlePickerEvent _ = pure ()

handleFilterMode :: V.Event -> EventM ResourceName PickerState ()
handleFilterMode ev = do
  ps <- get
  case ev of
    V.EvKey V.KEsc _ -> modify (\s -> clampIdx s {filterBuf = "", selectedIdx = 0, scrollOffset = 0})
    V.EvKey V.KEnter _ -> modify (\s -> clampIdx s {filterBuf = ""})
    V.EvKey V.KBS _ ->
      let buf' = if null ps.filterBuf then "" else init ps.filterBuf
       in modify (\s -> clampIdx s {filterBuf = buf', selectedIdx = 0, scrollOffset = 0})
    V.EvKey (V.KChar c) _ ->
      let buf' = ps.filterBuf ++ [c]
       in modify (\s -> clampIdx s {filterBuf = buf', selectedIdx = 0, scrollOffset = 0})
    _ -> pure ()

handleNormal :: V.Event -> EventM ResourceName PickerState ()
handleNormal ev = do
  ps <- get
  let visible = filteredEntries ps
      selEntry = safeIdx visible ps.selectedIdx
  case ev of
    -- Cancel / Exit
    V.EvKey V.KEsc _ -> halt
    V.EvKey (V.KChar 'q') _ -> halt
    -- Navigation
    V.EvKey V.KUp _ -> moveBy (-1)
    V.EvKey (V.KChar 'k') _ -> moveBy (-1)
    V.EvKey V.KDown _ -> moveBy 1
    V.EvKey (V.KChar 'j') _ -> moveBy 1
    V.EvKey V.KPageUp _ -> moveBy (-10)
    V.EvKey V.KPageDown _ -> moveBy 10
    -- Enter
    V.EvKey V.KEnter _ -> case selEntry of
      Just FsParent -> navigateUp
      Just (FsDrive d) -> navigateTo (LocPath d)
      Just (FsDir d) -> navigateInto d
      Just (FsFile f) -> case ps.location of
        LocPath dir -> selectFile (dir </> f)
        LocDrives -> pure ()
      Nothing -> pure ()
    -- Space (select directory in PickDir mode)
    V.EvKey (V.KChar ' ') _ -> case ps.mode of
      PickDir -> case ps.location of
        LocPath dir -> selectDir dir
        LocDrives -> pure ()
      PickFile -> case selEntry of
        Just FsParent -> navigateUp
        Just (FsDrive d) -> navigateTo (LocPath d)
        Just (FsDir d) -> navigateInto d
        Just (FsFile f) -> case ps.location of
          LocPath dir -> selectFile (dir </> f)
          LocDrives -> pure ()
        Nothing -> pure ()
    -- Backspace / Left / h: go up
    V.EvKey V.KBS _ -> navigateUp
    V.EvKey V.KLeft _ -> navigateUp
    V.EvKey (V.KChar 'h') _ -> navigateUp
    -- Search
    V.EvKey (V.KChar '/') _ -> modify (\s -> s {filterBuf = ""})
    _ -> pure ()

safeIdx :: [a] -> Int -> Maybe a
safeIdx xs i
  | i >= 0 && i < length xs = Just (xs !! i)
  | otherwise = Nothing

moveBy :: Int -> EventM ResourceName PickerState ()
moveBy delta = modify $ \ps ->
  let tot = length (filteredEntries ps)
      maxIdx = max 0 (tot - 1)
      sel = max 0 (min maxIdx (ps.selectedIdx + delta))
      off = adjustScroll sel ps.scrollOffset
   in ps {selectedIdx = sel, scrollOffset = off}

navigateTo :: PickerLocation -> EventM ResourceName PickerState ()
navigateTo loc = do
  ps <- get
  es <- liftIO $ loadEntries ps.mode loc
  put $
    ps
      { location = loc,
        entries = es,
        selectedIdx = 0,
        scrollOffset = 0,
        filterBuf = ""
      }

navigateInto :: FilePath -> EventM ResourceName PickerState ()
navigateInto name = do
  ps <- get
  case ps.location of
    LocPath dir -> navigateTo (LocPath (dir </> name))
    LocDrives -> navigateTo (LocPath name)

navigateUp :: EventM ResourceName PickerState ()
navigateUp = do
  ps <- get
  case ps.location of
    LocDrives -> pure ()
    LocPath dir -> do
      let parent = takeDirectory dir
      if parent == dir
        then navigateTo LocDrives
        else navigateTo (LocPath parent)

selectFile :: FilePath -> EventM ResourceName PickerState ()
selectFile full = do
  modify $ \s -> s {result = Just (T.pack full)}
  halt

selectDir :: FilePath -> EventM ResourceName PickerState ()
selectDir full = do
  modify $ \s -> s {result = Just (T.pack full)}
  halt

-- ---------------------------------------------------------------------------
-- Attribute map
-- ---------------------------------------------------------------------------

theMap :: AttrMap
theMap =
  attrMap
    V.defAttr
    [ (attrSelected, V.black `on` V.cyan),
      (attrDir, fg V.brightBlue),
      (attrFile, fg V.white),
      (attrDrive, fg V.magenta),
      (attrParent, fg V.yellow),
      (attrFilter, fg V.brightYellow),
      (attrDim, fg V.brightBlack)
    ]

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

runPicker :: PickMode -> IO (Maybe Text)
runPicker m = do
  initial <- initialPickerState m
  let theApp =
        App
          { appDraw = drawPicker,
            appChooseCursor = neverShowCursor,
            appHandleEvent = handlePickerEvent,
            appStartEvent = pure (),
            appAttrMap = const theMap
          }
  let buildVty = VCP.mkVty V.defaultConfig
  initialVty <- buildVty
  finalState <- customMain initialVty buildVty Nothing theApp initial
  pure finalState.result

-- | Launch a TUI file picker; returns the selected file path, or Nothing if cancelled.
pickFilePath :: IO (Maybe Text)
pickFilePath = runPicker PickFile

-- | Launch a TUI directory picker; returns the selected directory path, or Nothing if cancelled.
pickDirPath :: IO (Maybe Text)
pickDirPath = runPicker PickDir
