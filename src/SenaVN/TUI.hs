{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SenaVN.TUI (runTUI) where

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
    emptyWidget,
    hBox,
    hLimit,
    halt,
    neverShowCursor,
    padLeft,
    padRight,
    padTop,
    suspendAndResume,
    txt,
    vBox,
    withAttr,
    withBorderStyle,
    (<+>),
    (<=>),
  )
import Brick.Util (fg)
import Brick.Widgets.Border (borderWithLabel, hBorder)
import Brick.Widgets.Border.Style (unicodeRounded)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (get, modify, put)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection)
import qualified Graphics.Vty as V
import qualified Graphics.Vty.CrossPlatform as VCP
import SenaVN.Core (Env (..), renderSenaError, runRomi)
import qualified SenaVN.DB as DB
import SenaVN.Handler.Common (attachRunningSessions)
import qualified SenaVN.Session as Session
import SenaVN.Stats (LibraryStats (..), computeStats, effectivePlayed)
import SenaVN.System (openEditor, openGameGuide, openGameSave, spawnDaemon)
import SenaVN.Types
  ( GameCore (..),
    GameId (..),
    GameWithLocal (..),
    LocalPath (..),
    Minutes,
    PlayTimeline (..),
    Seconds,
    minutesToSeconds,
  )
import SenaVN.Utils
  ( fmtSecStr,
    formatDate,
    formatRelativeTime,
    maskSensitive,
    now,
    truncateText,
  )

-- | Top-level subcommand categories in the navigation tree
data SubCategory
  = CatList
  | CatStats
  | CatTimeline
  | CatConfig
  deriving (Show, Eq, Ord, Enum, Bounded)

categoryIcon :: SubCategory -> Text
categoryIcon CatList = "◆ "
categoryIcon CatStats = "▲ "
categoryIcon CatTimeline = "◈ "
categoryIcon CatConfig = "⚙ "

categoryTitle :: SubCategory -> Text
categoryTitle CatList = "Library (List)"
categoryTitle CatStats = "Statistics (Stats)"
categoryTitle CatTimeline = "Timeline (Timeline)"
categoryTitle CatConfig = "Configuration (Config)"

-- | Items appearing in the flattened visible tree list
data TreeItem
  = ItemCategory !SubCategory !Bool !Int
  | ItemGame !SubCategory !GameWithLocal
  | ItemConfig !Text !Text
  deriving (Show, Eq)

-- | Application State
data AppState = AppState
  { conn :: !Connection,
    games :: ![GameWithLocal],
    configs :: ![(Text, Text)],
    expandedList :: !Bool,
    expandedStats :: !Bool,
    expandedTimeline :: !Bool,
    expandedConfig :: !Bool,
    selectedIndex :: !Int,
    filterQuery :: !Text,
    isFiltering :: !Bool,
    statusMessage :: !(Maybe (Text, Bool)),
    currentTime :: !Int
  }

type ResourceName = ()

-- | Attribute names for Brick styling
attrCategory, attrSelected, attrTitle, attrDim, attrGreen, attrCyan, attrYellow, attrMagenta, attrStatus :: AttrName
attrHeaderLogo, attrHeaderAccent, attrHeaderBrand :: AttrName
attrBadgeKey, attrBadgeVal, attrBadgeGreen, attrBadgeCyan, attrBadgeYellow, attrBadgeMagenta, attrBadgeDim, attrBadgeTag :: AttrName
attrStar, attrBranch :: AttrName
attrCategory = attrName "category"
attrSelected = attrName "selected"
attrTitle = attrName "title"
attrDim = attrName "dim"
attrGreen = attrName "green"
attrCyan = attrName "cyan"
attrYellow = attrName "yellow"
attrMagenta = attrName "magenta"
attrStatus = attrName "status"
attrHeaderLogo = attrName "headerLogo"
attrHeaderAccent = attrName "headerAccent"
attrHeaderBrand = attrName "headerBrand"
attrBadgeKey = attrName "badgeKey"
attrBadgeVal = attrName "badgeVal"
attrBadgeGreen = attrName "badgeGreen"
attrBadgeCyan = attrName "badgeCyan"
attrBadgeYellow = attrName "badgeYellow"
attrBadgeMagenta = attrName "badgeMagenta"
attrBadgeDim = attrName "badgeDim"
attrBadgeTag = attrName "badgeTag"
attrStar = attrName "star"
attrBranch = attrName "branch"

theMap :: AttrMap
theMap =
  attrMap
    V.defAttr
    [ (attrCategory, V.withStyle (fg V.cyan) V.bold),
      (attrSelected, V.withStyle (fg V.black `V.withBackColor` V.cyan) V.bold),
      (attrTitle, V.withStyle (fg V.white) V.bold),
      (attrDim, fg (V.rgbColor (130 :: Int) (130 :: Int) (130 :: Int))),
      (attrGreen, V.withStyle (fg V.green) V.bold),
      (attrCyan, fg V.cyan),
      (attrYellow, fg V.yellow),
      (attrMagenta, fg V.magenta),
      (attrStatus, V.withStyle (fg V.yellow) V.bold),
      (attrHeaderLogo, V.withStyle (fg V.magenta) V.bold),
      (attrHeaderAccent, V.withStyle (fg V.cyan) V.bold),
      (attrHeaderBrand, V.withStyle (fg V.cyan) V.bold),
      (attrBadgeKey, V.withStyle (fg V.black `V.withBackColor` V.cyan) V.bold),
      (attrBadgeVal, V.withStyle (fg (V.rgbColor (220 :: Int) (220 :: Int) (220 :: Int)) `V.withBackColor` (V.rgbColor (45 :: Int) (45 :: Int) (45 :: Int))) V.bold),
      (attrBadgeGreen, V.withStyle (fg V.black `V.withBackColor` V.green) V.bold),
      (attrBadgeCyan, V.withStyle (fg V.black `V.withBackColor` V.cyan) V.bold),
      (attrBadgeYellow, V.withStyle (fg V.black `V.withBackColor` V.yellow) V.bold),
      (attrBadgeMagenta, V.withStyle (fg V.black `V.withBackColor` V.magenta) V.bold),
      (attrBadgeDim, V.withStyle (fg (V.rgbColor (180 :: Int) (180 :: Int) (180 :: Int)) `V.withBackColor` (V.rgbColor (45 :: Int) (45 :: Int) (45 :: Int))) V.bold),
      (attrBadgeTag, V.withStyle (fg V.cyan `V.withBackColor` (V.rgbColor (35 :: Int) (45 :: Int) (55 :: Int))) V.bold),
      (attrStar, V.withStyle (fg V.yellow) V.bold),
      (attrBranch, fg (V.rgbColor (100 :: Int) (100 :: Int) (100 :: Int)))
    ]

-- | Compute all visible items based on expansion state and filter query
getVisibleItems :: AppState -> [TreeItem]
getVisibleItems s =
  let q = T.toLower (T.strip s.filterQuery)
      matchesQuery :: GameWithLocal -> Bool
      matchesQuery gwl =
        if T.null q
          then True
          else
            q `T.isInfixOf` T.toLower gwl.game.title
              || any (\a -> q `T.isInfixOf` T.toLower a) gwl.game.alias
              || q `T.isInfixOf` T.toLower gwl.game.coreId.unGameId
              || any (\t -> q `T.isInfixOf` T.toLower t) gwl.game.tags

      filteredGames = filter matchesQuery s.games
      playedGamesList = sortOn (Down . effectivePlayed) (filter (\g -> effectivePlayed g > 0) filteredGames)
      timelineGames = filter (\g -> not (null g.game.playTimelines)) filteredGames
      sortedTimeline = sortOn (Down . (\g -> g.game.lastPlay)) timelineGames

      listItems =
        ItemCategory CatList s.expandedList (length filteredGames)
          : (if s.expandedList then map (ItemGame CatList) filteredGames else [])

      statsItems =
        ItemCategory CatStats s.expandedStats (length playedGamesList)
          : (if s.expandedStats then map (ItemGame CatStats) (if null playedGamesList then filteredGames else playedGamesList) else [])

      timelineItems =
        ItemCategory CatTimeline s.expandedTimeline (length sortedTimeline)
          : (if s.expandedTimeline then map (ItemGame CatTimeline) sortedTimeline else [])

      configItems =
        ItemCategory CatConfig s.expandedConfig (length s.configs)
          : (if s.expandedConfig then map (uncurry ItemConfig) s.configs else [])
   in listItems ++ statsItems ++ timelineItems ++ configItems

-- | Main UI drawing function
drawUI :: AppState -> [Widget ResourceName]
drawUI s =
  let visible = getVisibleItems s
      clampedIdx = if null visible then 0 else max 0 (min (length visible - 1) s.selectedIndex)
      selectedItem = if null visible then Nothing else Just (visible !! clampedIdx)
      headerPane = drawHeader s
      leftPane = hLimit 42 (drawNavTree s visible clampedIdx)
      rightPane = drawDetailPane s selectedItem
      bottomPane = drawBottomBar s
      body = leftPane <+> rightPane
   in [withBorderStyle unicodeRounded $ headerPane <=> body <=> bottomPane]

-- | Render the top application header banner
drawHeader :: AppState -> Widget ResourceName
drawHeader s =
  let totGames = length s.games
      runningCount = length (filter (isJust . (.running)) s.games)
      playedCount = length (filter (\g -> effectivePlayed g > 0) s.games)
      totPlaytime = sum (map effectivePlayed s.games)

      brand =
        withAttr attrHeaderLogo (txt " ❖ SENA")
          <+> withAttr attrHeaderAccent (txt "VN ")
          <+> withAttr attrDim (txt "·  v2.0.0")

      tagline =
        withAttr attrDim (txt "Terminal Visual Novel Library & Playtime Tracker")

      brandBlock =
        brand <=> padLeft (Pad 1) tagline

      pill key val valAttr =
        withAttr attrBadgeKey (txt (" " <> key <> " "))
          <+> withAttr valAttr (txt (" " <> val <> " "))

      pills =
        hBox
          [ pill "GAMES" (T.pack (show totGames) <> " (" <> T.pack (show playedCount) <> " played)") attrBadgeVal,
            txt "  ",
            pill "RUNNING" (T.pack (show runningCount) <> " active") (if runningCount > 0 then attrBadgeGreen else attrBadgeVal),
            txt "  ",
            pill "PLAYTIME" (T.pack (fmtSecStr totPlaytime)) attrBadgeYellow,
            txt "  ",
            pill "DB" "SQLite WAL" attrBadgeDim
          ]

      headerContent =
        hBox
          [ padLeft (Pad 1) brandBlock,
            padLeft Max (padRight (Pad 1) (vBox [padTop (Pad 1) pills]))
          ]
   in borderWithLabel (withAttr attrHeaderBrand (txt " ❖ SENAVN ")) headerContent

-- | Render the left navigation tree pane
drawNavTree :: AppState -> [TreeItem] -> Int -> Widget ResourceName
drawNavTree s visible curIdx =
  let renderedItems = zipWith (renderTreeRow curIdx) [0 ..] visible
      lbl =
        if T.null s.filterQuery
          then " Navigation Tree "
          else " Filter: " <> s.filterQuery <> " "
      content =
        if null visible
          then padLeft (Pad 2) $ padTop (Pad 1) $ withAttr attrDim (txt "No matching items found.")
          else vBox renderedItems
   in borderWithLabel (withAttr attrTitle (txt lbl)) content

renderTreeRow :: Int -> Int -> TreeItem -> Widget ResourceName
renderTreeRow curIdx idx item =
  let isSel = curIdx == idx
      decorator = if isSel then withAttr attrSelected else id
   in decorator $ case item of
        ItemCategory cat isExp cnt ->
          let arrow = if isExp then "▼ " else "▶ "
              icon = categoryIcon cat
              countBadge = withAttr attrDim (txt (" (" <> T.pack (show cnt) <> ")"))
              catText = withAttr attrCategory (txt (arrow <> icon <> categoryTitle cat))
           in padLeft (Pad 1) (catText <+> countBadge)
        ItemGame _ gwl ->
          let dot = case gwl.running of
                Just _ -> withAttr attrGreen (txt "▶ ")
                Nothing
                  | null gwl.game.playTimelines -> withAttr attrDim (txt "○ ")
                  | effectivePlayed gwl >= minutesToSeconds gwl.game.expectedPlayTime && gwl.game.expectedPlayTime > 0 -> withAttr attrCyan (txt "✔ ")
                  | otherwise -> withAttr attrGreen (txt "● ")
              branch = withAttr attrBranch (txt "├─ ")
              cursor = if isSel then withAttr attrHeaderLogo (txt "➜ ") else txt "  "
              titleTxt = truncateText 20 gwl.game.title
              playDur = effectivePlayed gwl
              playText =
                if playDur > 0
                  then withAttr attrDim (txt (T.pack (fmtSecStr playDur)))
                  else withAttr attrDim (txt "—")
           in cursor <+> branch <+> dot <+> txt titleTxt <+> padLeft Max playText
        ItemConfig k _ ->
          let branch = withAttr attrBranch (txt "├─ ")
              cursor = if isSel then withAttr attrHeaderLogo (txt "➜ ") else txt "  "
              label = truncateText 26 k
           in cursor <+> branch <+> withAttr attrDim (txt "· ") <+> txt label

-- | Visual progress bar with filled and empty blocks
renderProgressBar :: Int -> Seconds -> Minutes -> Widget ResourceName
renderProgressBar barWidth playedSec expectedMin
  | expectedMin <= 0 = withAttr attrDim (txt "[ No expected playtime set ]")
  | otherwise =
      let expectedSec = minutesToSeconds expectedMin
          pct = if expectedSec > 0 then (playedSec * 100) `div` expectedSec else 0
          clampedPct = min 100 (max 0 pct)
          filled = min barWidth (round ((fromIntegral (clampedPct * barWidth) / 100.0) :: Double) :: Int)
          empty = max 0 (barWidth - filled)
          barFilled = T.replicate filled "█"
          barEmpty = T.replicate empty "░"
          pctStr = T.pack (show pct) <> "%"
          barColor = if pct >= 100 then attrGreen else attrCyan
       in hBox
            [ withAttr barColor (txt ("[ " <> barFilled)),
              withAttr attrDim (txt (barEmpty <> " ]  ")),
              withAttr (if pct >= 100 then attrGreen else attrTitle) (txt pctStr)
            ]

-- | Star rating widget
renderStars :: Double -> Widget ResourceName
renderStars 0 = withAttr attrDim (txt "Not rated")
renderStars r =
  let norm = if r > 10 then r / 10 else r
      filled = min 10 (max 0 (round norm :: Int))
      empty = max 0 (10 - filled)
      starsFilled = T.replicate filled "★"
      starsEmpty = T.replicate empty "☆"
      scoreStr = if r > 10 then T.pack (show (round r :: Int) <> "/100") else T.pack (show (round r :: Int) <> "/10")
   in hBox
        [ withAttr attrStar (txt (starsFilled <> starsEmpty)),
          withAttr attrDim (txt ("  " <> scoreStr))
        ]

-- | Render the right detail and preview pane
drawDetailPane :: AppState -> Maybe TreeItem -> Widget ResourceName
drawDetailPane s mItem =
  let content = case mItem of
        Nothing -> padLeft (Pad 2) $ withAttr attrDim (txt "Select an item from the navigation tree.")
        Just (ItemCategory CatList _ _) -> drawCategoryListOverview s
        Just (ItemCategory CatStats _ _) -> drawCategoryStatsOverview s
        Just (ItemCategory CatTimeline _ _) -> drawCategoryTimelineOverview s
        Just (ItemCategory CatConfig _ _) -> drawCategoryConfigOverview s
        Just (ItemGame CatList gwl) -> drawGameInfoCard s gwl
        Just (ItemGame CatStats gwl) -> drawGameStatCard s gwl
        Just (ItemGame CatTimeline gwl) -> drawGameTimelineCard s gwl
        Just (ItemGame CatConfig gwl) -> drawGameInfoCard s gwl
        Just (ItemConfig k v) -> drawConfigCard k v
   in borderWithLabel (withAttr attrTitle (txt " Preview & Details ")) content

-- | Overview for Library (List)
drawCategoryListOverview :: AppState -> Widget ResourceName
drawCategoryListOverview s =
  let totGames = length s.games
      runningCount = length (filter (isJust . (.running)) s.games)
      playedCount = length (filter (\g -> effectivePlayed g > 0) s.games)
      totPlaytime = sum (map effectivePlayed s.games)

      hdr =
        withAttr attrTitle (txt "Library Overview")
          <=> withAttr attrDim (txt ("Total: " <> T.pack (show totGames) <> " (" <> T.pack (show playedCount) <> " played)  ·  " <> T.pack (show runningCount) <> " running  ·  " <> T.pack (fmtSecStr totPlaytime) <> " played"))
          <=> hBorder

      row gwl =
        let dot = case gwl.running of
              Just _ -> withAttr attrGreen (txt "▶ ")
              Nothing
                | null gwl.game.playTimelines -> withAttr attrDim (txt "○ ")
                | effectivePlayed gwl >= minutesToSeconds gwl.game.expectedPlayTime && gwl.game.expectedPlayTime > 0 -> withAttr attrCyan (txt "✔ ")
                | otherwise -> withAttr attrGreen (txt "● ")
            idTxt = withAttr attrBadgeMagenta (txt (" #" <> truncateText 6 gwl.game.coreId.unGameId <> " "))
            tTxt = withAttr attrTitle (txt (truncateText 28 gwl.game.title))
            playTxt = withAttr attrGreen (txt (T.pack (fmtSecStr (effectivePlayed gwl))))
            devTxt = withAttr attrDim (txt (truncateText 16 (if T.null gwl.game.developer then "Unknown" else gwl.game.developer)))
         in hBox
              [ hLimit 3 dot,
                hLimit 12 idTxt,
                hLimit 30 tTxt,
                hLimit 18 devTxt,
                playTxt
              ]

      gameList = vBox (take 18 (map row s.games))
      hint = withAttr attrDim (txt "Hint: Press [Space] to toggle categories. Press [Enter/r] to launch game.")
   in padLeft (Pad 2) $ padRight (Pad 2) $ hdr <=> gameList <=> padTop (Pad 1) hint

-- | Overview for Statistics
drawCategoryStatsOverview :: AppState -> Widget ResourceName
drawCategoryStatsOverview s =
  let st = computeStats s.games
      topGames = take 6 st.topPlayed
      maxPlay = if null topGames then 1 else maximum (map snd topGames)

      hdr = withAttr attrTitle (txt "Library Aggregate Statistics") <=> hBorder

      card cardTitle lines_ =
        hLimit 26 $
          borderWithLabel (withAttr attrTitle (txt (" " <> cardTitle <> " "))) $
            padLeft (Pad 1) $ padRight (Pad 1) $ vBox lines_

      metricRow lbl val =
        hBox [withAttr attrDim (txt lbl), padLeft Max (withAttr attrCyan (txt val))]

      card1 =
        card
          "Games"
          [ metricRow "Total:" (T.pack (show st.totalGames)),
            metricRow "Configured:" (T.pack (show st.configuredGames)),
            metricRow "Played:" (T.pack (show st.playedGames)),
            metricRow "Unplayed:" (T.pack (show st.unplayedGames))
          ]

      card2 =
        card
          "Playtime"
          [ metricRow "Total:" (T.pack (fmtSecStr st.totalPlaytime)),
            metricRow "Average:" (T.pack (fmtSecStr st.avgSessionSec)),
            metricRow "Sessions:" (T.pack (show st.totalSessions))
          ]

      cardsBox = hBox [card1, txt "  ", card2]

      renderTopRow :: (Int, (GameWithLocal, Seconds)) -> Widget ResourceName
      renderTopRow (idx, (gwl, sec)) =
        let barW = 20 :: Int
            filled = if maxPlay > 0 then (sec * barW) `div` maxPlay else 0
            clampedFilled = min barW (max 0 filled)
            empty = max 0 (barW - clampedFilled)
            barFilled = T.replicate clampedFilled "█"
            barEmpty = T.replicate empty "░"
            titleTxt = truncateText 22 gwl.game.title
            durTxt = T.pack (fmtSecStr sec)
         in hBox
              [ hLimit 3 (withAttr attrDim (txt (T.pack (show (idx :: Int) <> ".")))),
                hLimit 24 (withAttr attrTitle (txt titleTxt)),
                withAttr attrGreen (txt ("[ " <> barFilled)),
                withAttr attrDim (txt (barEmpty <> " ] ")),
                withAttr attrYellow (txt durTxt)
              ]

      topHeader = padTop (Pad 1) $ withAttr attrTitle (txt "Top Played Titles (Relative Activity):") <=> hBorder
      topBox = vBox (map renderTopRow (zip [1 ..] topGames))
   in padLeft (Pad 2) $ padRight (Pad 2) $ hdr <=> cardsBox <=> topHeader <=> topBox

-- | Overview for Timeline
drawCategoryTimelineOverview :: AppState -> Widget ResourceName
drawCategoryTimelineOverview s =
  let allTimelines = concatMap (\gwl -> map (\tl -> (gwl, tl)) gwl.game.playTimelines) s.games
      sortedRecent = take 14 (sortOn (Down . (\(_, tl) -> tl.start)) allTimelines)
      totalDur = sum (map (\(_, tl) -> tl.duration) sortedRecent)
      hdr =
        withAttr attrTitle (txt "Global Play Timeline")
          <=> withAttr attrDim (txt ("Showing " <> T.pack (show (length sortedRecent)) <> " recent sessions  ·  Total duration: " <> T.pack (fmtSecStr totalDur)))
          <=> hBorder

      renderTL :: (GameWithLocal, PlayTimeline) -> Widget ResourceName
      renderTL (gwl, tl) =
        let relTime = formatRelativeTime s.currentTime tl.start
            titleTxt = truncateText 24 gwl.game.title
            durTxt = fmtSecStr tl.duration
            dateTxt = formatDate tl.start
         in hBox
              [ withAttr attrBranch (txt "├─ "),
                withAttr attrGreen (txt "● "),
                hLimit 12 (withAttr attrDim (txt dateTxt)),
                hLimit 18 (withAttr attrDim (txt ("(" <> relTime <> ")"))),
                hLimit 26 (withAttr attrTitle (txt titleTxt)),
                withAttr attrBadgeGreen (txt (" " <> T.pack durTxt <> " "))
              ]
      tlList = if null sortedRecent then withAttr attrDim (txt "No recorded play sessions.") else vBox (map renderTL sortedRecent)
   in padLeft (Pad 2) $ padRight (Pad 2) $ hdr <=> tlList

-- | Overview for Config
drawCategoryConfigOverview :: AppState -> Widget ResourceName
drawCategoryConfigOverview s =
  let hdr = withAttr attrTitle (txt "Configuration Settings") <=> hBorder
      renderCfg (k, v) =
        hBox
          [ withAttr attrBranch (txt "├─ "),
            hLimit 24 (withAttr attrCyan (txt k)),
            withAttr attrDim (txt "= "),
            txt (maskSensitive k v)
          ]
      cfgList = if null s.configs then withAttr attrDim (txt "No configuration settings found.") else vBox (map renderCfg s.configs)
   in padLeft (Pad 2) $ hdr <=> cfgList

-- | Game Details Card (like sena info)
drawGameInfoCard :: AppState -> GameWithLocal -> Widget ResourceName
drawGameInfoCard _ gwl =
  let g = gwl.game
      badgeId = withAttr attrBadgeMagenta (txt (" #" <> g.coreId.unGameId <> " "))
      devStr = if T.null g.developer then "Unknown Developer" else g.developer
      dateStr = formatDate g.releaseDate
      metaSub = withAttr attrDim (txt ("by " <> devStr <> "  ·  Released: " <> dateStr))

      hdr =
        (withAttr attrTitle (txt g.title) <+> txt "  " <+> badgeId)
          <=> metaSub
          <=> hBorder

      statusBadge = case gwl.running of
        Just sec ->
          withAttr attrBadgeGreen (txt " ▶ RUNNING ")
            <+> txt " "
            <+> withAttr attrGreen (txt ("Active session: " <> T.pack (fmtSecStr sec)))
        Nothing
          | null g.playTimelines -> withAttr attrBadgeDim (txt " ○ UNPLAYED ")
          | effectivePlayed gwl >= minutesToSeconds g.expectedPlayTime && g.expectedPlayTime > 0 ->
              withAttr attrBadgeCyan (txt " ✔ FINISHED ")
          | otherwise -> withAttr attrBadgeGreen (txt " ● IN PROGRESS ")

      played = effectivePlayed gwl
      progressDetail =
        T.pack (fmtSecStr played) <> (if g.expectedPlayTime > 0 then " / " <> T.pack (show (g.expectedPlayTime `div` 60) <> "h " <> show (g.expectedPlayTime `mod` 60) <> "m expected") else "")

      progressRow =
        vBox
          [ renderProgressBar 24 played g.expectedPlayTime,
            padTop (Pad 1) $ withAttr attrDim (txt ("  Playtime: " <> progressDetail))
          ]

      infoLine lbl val =
        hBox
          [ hLimit 14 (withAttr attrDim (txt lbl)),
            val
          ]

      localBlock =
        borderWithLabel (withAttr attrTitle (txt " Target & Configuration ")) $
          padLeft (Pad 1) $
            padRight (Pad 1) $
              case gwl.local of
                Nothing -> withAttr attrDim (txt "No executable configured. Run 'sena use <id> <path>'")
                Just lp ->
                  vBox
                    [ hBox [withAttr attrDim (txt "Program : "), withAttr attrCyan (txt lp.programFile)],
                      hBox [withAttr attrDim (txt "Save Dir: "), txt (fromMaybe "Not configured" lp.savePath)],
                      hBox [withAttr attrDim (txt "Guide   : "), txt (fromMaybe "Not configured" lp.guideFile)]
                    ]

      tagBadges =
        if null g.tags
          then emptyWidget
          else
            padTop (Pad 1) $
              hBox (withAttr attrDim (txt "Tags: ") : map (\t -> padRight (Pad 1) $ withAttr attrBadgeTag (txt (" " <> t <> " "))) (take 8 g.tags))

      descText =
        if T.null g.description
          then emptyWidget
          else
            padTop (Pad 1) $
              withAttr attrDim (txt "Description:")
                <=> padLeft (Pad 2) (withAttr attrDim (txt "│ ") <+> txt (truncateText 350 g.description))
   in padLeft (Pad 2) $
        padRight (Pad 2) $
          hdr
            <=> infoLine "Status:" statusBadge
            <=> padTop (Pad 1) (infoLine "Progress:" progressRow)
            <=> padTop (Pad 1) (infoLine "Rating:" (renderStars g.rating))
            <=> padTop (Pad 1) localBlock
            <=> tagBadges
            <=> descText

-- | Game Stats Card (under Statistics)
drawGameStatCard :: AppState -> GameWithLocal -> Widget ResourceName
drawGameStatCard _ gwl =
  let g = gwl.game
      hdr = withAttr attrTitle (txt (g.title <> " (#" <> g.coreId.unGameId <> ") - Statistics")) <=> hBorder
      played = effectivePlayed gwl
      timelines = g.playTimelines
      totalSess = length timelines + maybe 0 (const 1) gwl.running
      avgSess = if totalSess > 0 then played `div` totalSess else 0
      longestSess = if null timelines then 0 else maximum (map (.duration) timelines)
      firstPlay = if null timelines then 0 else minimum (map (.start) timelines)

      statLine lbl val =
        hBox
          [ hLimit 20 (withAttr attrDim (txt lbl)),
            withAttr attrTitle (txt val)
          ]
   in padLeft (Pad 2) $
        hdr
          <=> statLine "Total Playtime:" (T.pack (fmtSecStr played))
          <=> statLine "Expected Playtime:" (T.pack (show (g.expectedPlayTime `div` 60) <> "h " <> show (g.expectedPlayTime `mod` 60) <> "m"))
          <=> statLine "Sessions Count:" (T.pack (show totalSess))
          <=> statLine "Average Session:" (T.pack (fmtSecStr avgSess))
          <=> statLine "Longest Session:" (T.pack (fmtSecStr longestSess))
          <=> statLine "First Played:" (formatDate firstPlay)
          <=> statLine "Last Played:" (formatDate g.lastPlay)

-- | Game Timeline Card (under Timeline)
drawGameTimelineCard :: AppState -> GameWithLocal -> Widget ResourceName
drawGameTimelineCard s gwl =
  let g = gwl.game
      timelines = sortOn (Down . (.start)) g.playTimelines
      totalPlay = effectivePlayed gwl
      totalSess = length timelines
      avgSess = if totalSess > 0 then totalPlay `div` totalSess else 0
      hdr =
        withAttr attrTitle (txt (g.title <> " - Session Timeline"))
          <=> withAttr attrDim (txt (T.pack (show totalSess) <> " recorded sessions  ·  " <> T.pack (fmtSecStr totalPlay) <> " total  ·  avg " <> T.pack (fmtSecStr avgSess)))
          <=> hBorder

      renderSession :: PlayTimeline -> Widget ResourceName
      renderSession tl =
        let rel = formatRelativeTime s.currentTime tl.start
            dateStr = formatDate tl.start
            durStr = fmtSecStr tl.duration
         in hBox
              [ withAttr attrBranch (txt "├─ "),
                withAttr attrGreen (txt "● "),
                hLimit 14 (withAttr attrDim (txt dateStr)),
                hLimit 18 (withAttr attrDim (txt ("(" <> rel <> ")"))),
                withAttr attrBadgeGreen (txt (" " <> T.pack durStr <> " "))
              ]
      body = if null timelines then withAttr attrDim (txt "No recorded sessions for this game.") else vBox (map renderSession (take 16 timelines))
   in padLeft (Pad 2) $ padRight (Pad 2) $ hdr <=> body

-- | Config Card
drawConfigCard :: Text -> Text -> Widget ResourceName
drawConfigCard k v =
  let hdr = withAttr attrTitle (txt ("Configuration: " <> k)) <=> hBorder
      valDisplay =
        hBox
          [ withAttr attrDim (txt "Value: "),
            withAttr attrCyan (txt (maskSensitive k v))
          ]
      helpTxt =
        padTop (Pad 1) $
          withAttr attrDim (txt ("To change this setting in CLI:\n  sena config " <> k <> " <new_value>\nTo remove:\n  sena config rm " <> k))
   in padLeft (Pad 2) $ hdr <=> valDisplay <=> helpTxt

-- | Render the bottom bar and status messages
drawBottomBar :: AppState -> Widget ResourceName
drawBottomBar s =
  let statusLine = case s.statusMessage of
        Just (msg, isErr) ->
          let colorAttr = if isErr then attrBadgeMagenta else attrBadgeGreen
              icon = if isErr then " ✗ " else " ✓ "
           in withAttr colorAttr (txt (icon <> msg <> " "))
        Nothing ->
          if s.isFiltering
            then withAttr attrCyan (txt " 🔍 Search: ") <+> withAttr attrTitle (txt (s.filterQuery <> "█")) <+> withAttr attrDim (txt "  [Enter] confirm  [Esc] cancel")
            else withAttr attrDim (txt " ❖ Browse Mode  ·  Press [/] to filter library")

      keyCap k action =
        withAttr attrBadgeKey (txt (" " <> k <> " ")) <+> withAttr attrDim (txt (" " <> action <> "  "))

      helpLine =
        hBox
          [ keyCap "Enter" "Launch",
            keyCap "r" "Run",
            keyCap "g" "Guide",
            keyCap "s" "Save",
            keyCap "e" "Edit",
            keyCap "/" "Filter",
            keyCap "Space" "Toggle",
            keyCap "q" "Quit"
          ]
   in statusLine <=> hBorder <=> helpLine

-- | Handle keyboard events
handleEvent :: BrickEvent ResourceName () -> EventM ResourceName AppState ()
handleEvent (VtyEvent ev) = do
  s <- get
  if s.isFiltering
    then handleFilterKey ev
    else handleNormalKey ev
handleEvent _ = pure ()

-- | Handle keystrokes in filter/search mode
handleFilterKey :: V.Event -> EventM ResourceName AppState ()
handleFilterKey (V.EvKey V.KEsc []) =
  modify $ \st -> st {isFiltering = False, filterQuery = ""}
handleFilterKey (V.EvKey V.KEnter []) =
  modify $ \st -> st {isFiltering = False}
handleFilterKey (V.EvKey V.KBS []) =
  modify $ \st -> st {filterQuery = if T.null st.filterQuery then "" else T.init st.filterQuery, selectedIndex = 0}
handleFilterKey (V.EvKey (V.KChar c) []) =
  modify $ \st -> st {filterQuery = st.filterQuery `T.snoc` c, selectedIndex = 0}
handleFilterKey _ = pure ()

-- | Handle keystrokes in normal navigation mode
handleNormalKey :: V.Event -> EventM ResourceName AppState ()
handleNormalKey (V.EvKey (V.KChar 'q') []) = halt
handleNormalKey (V.EvKey V.KEsc []) = halt
handleNormalKey (V.EvKey (V.KChar '/') []) =
  modify $ \st -> st {isFiltering = True, filterQuery = ""}
handleNormalKey (V.EvKey (V.KChar 'j') []) = moveDown
handleNormalKey (V.EvKey V.KDown []) = moveDown
handleNormalKey (V.EvKey (V.KChar 'k') []) = moveUp
handleNormalKey (V.EvKey V.KUp []) = moveUp
handleNormalKey (V.EvKey V.KPageDown []) = moveBy 8
handleNormalKey (V.EvKey V.KPageUp []) = moveBy (-8)
handleNormalKey (V.EvKey V.KHome []) = modify $ \st -> st {selectedIndex = 0}
handleNormalKey (V.EvKey V.KEnd []) = do
  st <- get
  let total = length (getVisibleItems st)
  modify $ \s -> s {selectedIndex = max 0 (total - 1)}
handleNormalKey (V.EvKey (V.KChar ' ') []) = toggleCurrentCategory
handleNormalKey (V.EvKey (V.KChar 'l') []) = expandCurrentCategory
handleNormalKey (V.EvKey V.KRight []) = expandCurrentCategory
handleNormalKey (V.EvKey (V.KChar 'h') []) = collapseCurrentCategory
handleNormalKey (V.EvKey V.KLeft []) = collapseCurrentCategory
handleNormalKey (V.EvKey (V.KChar 'r') []) = triggerRun
handleNormalKey (V.EvKey V.KEnter []) = triggerEnter
handleNormalKey (V.EvKey (V.KChar 'g') []) = triggerGuide
handleNormalKey (V.EvKey (V.KChar 's') []) = triggerSave
handleNormalKey (V.EvKey (V.KChar 'e') []) = triggerEdit
handleNormalKey _ = pure ()

moveDown :: EventM ResourceName AppState ()
moveDown = do
  st <- get
  let total = length (getVisibleItems st)
  when (total > 0) $
    modify $
      \s -> s {selectedIndex = min (total - 1) (s.selectedIndex + 1), statusMessage = Nothing}

moveUp :: EventM ResourceName AppState ()
moveUp =
  modify $ \s -> s {selectedIndex = max 0 (s.selectedIndex - 1), statusMessage = Nothing}

moveBy :: Int -> EventM ResourceName AppState ()
moveBy delta = do
  st <- get
  let total = length (getVisibleItems st)
  when (total > 0) $
    modify $
      \s -> s {selectedIndex = max 0 (min (total - 1) (s.selectedIndex + delta)), statusMessage = Nothing}

getCurrentItem :: AppState -> Maybe TreeItem
getCurrentItem s =
  let items = getVisibleItems s
   in if null items || s.selectedIndex >= length items || s.selectedIndex < 0
        then Nothing
        else Just (items !! s.selectedIndex)

toggleCategory :: SubCategory -> AppState -> AppState
toggleCategory CatList s = s {expandedList = not s.expandedList}
toggleCategory CatStats s = s {expandedStats = not s.expandedStats}
toggleCategory CatTimeline s = s {expandedTimeline = not s.expandedTimeline}
toggleCategory CatConfig s = s {expandedConfig = not s.expandedConfig}

setCategoryExpanded :: SubCategory -> Bool -> AppState -> AppState
setCategoryExpanded CatList b s = s {expandedList = b}
setCategoryExpanded CatStats b s = s {expandedStats = b}
setCategoryExpanded CatTimeline b s = s {expandedTimeline = b}
setCategoryExpanded CatConfig b s = s {expandedConfig = b}

toggleCurrentCategory :: EventM ResourceName AppState ()
toggleCurrentCategory = do
  st <- get
  case getCurrentItem st of
    Just (ItemCategory cat _ _) -> modify (toggleCategory cat)
    _ -> pure ()

expandCurrentCategory :: EventM ResourceName AppState ()
expandCurrentCategory = do
  st <- get
  case getCurrentItem st of
    Just (ItemCategory cat False _) -> modify (setCategoryExpanded cat True)
    Just (ItemCategory _ True _) -> moveDown
    _ -> pure ()

collapseCurrentCategory :: EventM ResourceName AppState ()
collapseCurrentCategory = do
  st <- get
  case getCurrentItem st of
    Just (ItemCategory cat True _) -> modify (setCategoryExpanded cat False)
    Just (ItemGame cat _) -> do
      -- Jump cursor to the parent category
      let items = getVisibleItems st
          mParentIdx = case [idx | (idx, ItemCategory c _ _) <- zip [0 ..] items, c == cat] of
            (pIdx : _) -> Just pIdx
            [] -> Nothing
      case mParentIdx of
        Just pIdx -> modify $ \s -> s {selectedIndex = pIdx}
        Nothing -> pure ()
    _ -> pure ()

triggerEnter :: EventM ResourceName AppState ()
triggerEnter = do
  st <- get
  case getCurrentItem st of
    Just (ItemCategory cat _ _) -> modify (toggleCategory cat)
    Just (ItemGame _ gwl) -> do
      newState <- liftIO (launchGame gwl st)
      put newState
    _ -> pure ()

triggerRun :: EventM ResourceName AppState ()
triggerRun = do
  st <- get
  case getCurrentItem st of
    Just (ItemGame _ gwl) -> do
      newState <- liftIO (launchGame gwl st)
      put newState
    _ -> modify $ \s -> s {statusMessage = Just ("Select a game first to launch", True)}

triggerGuide :: EventM ResourceName AppState ()
triggerGuide = do
  st <- get
  case getCurrentItem st of
    Just (ItemGame _ gwl) -> do
      newState <- liftIO (openGuideAction gwl st)
      put newState
    _ -> modify $ \s -> s {statusMessage = Just ("Select a game first to open guide", True)}

triggerSave :: EventM ResourceName AppState ()
triggerSave = do
  st <- get
  case getCurrentItem st of
    Just (ItemGame _ gwl) -> do
      newState <- liftIO (openSaveAction gwl st)
      put newState
    _ -> modify $ \s -> s {statusMessage = Just ("Select a game first to open save directory", True)}

triggerEdit :: EventM ResourceName AppState ()
triggerEdit = do
  st <- get
  case getCurrentItem st of
    Just (ItemGame _ gwl) ->
      suspendAndResume (editGameAction gwl st)
    _ -> modify $ \s -> s {statusMessage = Just ("Select a game first to edit metadata", True)}

-- | Action to launch game via daemon
launchGame :: GameWithLocal -> AppState -> IO AppState
launchGame gwl s = case gwl.local of
  Nothing ->
    pure s {statusMessage = Just ("Error: No executable configured for " <> gwl.game.title, True)}
  Just lp -> do
    mSess <- Session.readSession gwl.game.coreId
    alive <- case mSess of
      Nothing -> pure False
      Just sess -> Session.isPidAlive sess.guardPid
    if alive
      then pure s {statusMessage = Just ("Game is already running (#" <> gwl.game.coreId.unGameId <> ")", True)}
      else do
        spawnDaemon gwl.game.coreId gwl.game.title lp.programFile
        Session.reconcileSessions s.conn
        rawGames <- DB.getAllGamesWithLocal s.conn
        games' <- attachRunningSessions rawGames
        pure
          s
            { games = games',
              statusMessage = Just ("Launched " <> gwl.game.title <> " (#" <> gwl.game.coreId.unGameId <> ") in background", False)
            }

-- | Action to open guide file
openGuideAction :: GameWithLocal -> AppState -> IO AppState
openGuideAction gwl s = case gwl.local >>= (.guideFile) of
  Nothing ->
    pure s {statusMessage = Just ("No guide file configured for " <> gwl.game.title, True)}
  Just _ -> do
    res <- runRomi (Env s.conn) (openGameGuide s.conn gwl)
    case res of
      Left err ->
        pure s {statusMessage = Just ("Failed to open guide: " <> renderSenaError err, True)}
      Right () ->
        pure s {statusMessage = Just ("Opened guide for " <> gwl.game.title, False)}

-- | Action to open save directory
openSaveAction :: GameWithLocal -> AppState -> IO AppState
openSaveAction gwl s = case gwl.local >>= (.savePath) of
  Nothing ->
    pure s {statusMessage = Just ("No save directory configured for " <> gwl.game.title, True)}
  Just _ -> do
    res <- runRomi (Env s.conn) (openGameSave gwl)
    case res of
      Left err ->
        pure s {statusMessage = Just ("Failed to open save: " <> renderSenaError err, True)}
      Right () ->
        pure s {statusMessage = Just ("Opened save directory for " <> gwl.game.title, False)}

-- | Action to edit game in external editor
editGameAction :: GameWithLocal -> AppState -> IO AppState
editGameAction gwl s = do
  res <- runRomi (Env s.conn) (openEditor gwl.game >>= liftIO . DB.updateGame s.conn)
  case res of
    Left err ->
      pure s {statusMessage = Just ("Edit cancelled or error: " <> renderSenaError err, True)}
    Right () -> do
      rawGames <- DB.getAllGamesWithLocal s.conn
      games' <- attachRunningSessions rawGames
      pure
        s
          { games = games',
            statusMessage = Just ("Updated metadata for " <> gwl.game.title, False)
          }

-- | Brick application specification
theApp :: App AppState () ResourceName
theApp =
  App
    { appDraw = drawUI,
      appChooseCursor = neverShowCursor,
      appHandleEvent = handleEvent,
      appStartEvent = pure (),
      appAttrMap = const theMap
    }

-- | Entry point for running the TUI browser
runTUI :: Connection -> IO ()
runTUI dbConn = do
  Session.reconcileSessions dbConn
  rawGames <- DB.getAllGamesWithLocal dbConn
  games' <- attachRunningSessions rawGames
  cfgs <- DB.getAllConfigs dbConn
  nowTs <- now

  let initialState =
        AppState
          { conn = dbConn,
            games = games',
            configs = cfgs,
            expandedList = True, -- Default expanded to show library games right away
            expandedStats = False,
            expandedTimeline = False,
            expandedConfig = False,
            selectedIndex = 0,
            filterQuery = "",
            isFiltering = False,
            statusMessage = Nothing,
            currentTime = nowTs
          }

  let buildVty = VCP.mkVty V.defaultConfig
  initialVty <- buildVty
  _ <- customMain initialVty buildVty Nothing theApp initialState
  pure ()
