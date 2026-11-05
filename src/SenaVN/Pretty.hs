{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SenaVN.Pretty
  ( prettyGameDetailW,
    prettyGameRow,
    prettyGamesW,
    prettyFetchResultW,
    prettyFetchResultsW,
    prettyLibraryStatsW,
    prettyGameStatW,
    printGame,
    printGames,
    printFetchResult,
    printFetchResults,
    printLibraryStats,
    printGameStat,
    render,
    renderDoc,
    renderInline,
    getTermWidth,
    calcColumns,
    ListColumns (..),
    effectivePlayed,
    bold_,
    cyan_,
    green_,
    yellow_,
    white_,
    dim_,
    fmtDate,
    fmtMinutes,
    fmtSeconds,
    fmtSecStr,
    fmtHours,
    fmtTimeline,
    totalPlayed,
    ratingDoc,
    truncated,
    ruleW,
    kv,
    tagsList,
    linksList,
    statusDot,
    progressBar,
  )
where

import Control.Exception (SomeException, catch)
import Data.List (intercalate, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import GHC.Records (HasField)
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Types
import System.Environment (lookupEnv)
import System.IO (hFlush, hIsTerminalDevice, stdout)
import Text.Read (readMaybe)

bold_ :: Doc AnsiStyle -> Doc AnsiStyle
bold_ = annotate bold

cyan_ :: Doc AnsiStyle -> Doc AnsiStyle
cyan_ = annotate (color Cyan)

green_ :: Doc AnsiStyle -> Doc AnsiStyle
green_ = annotate (color Green)

yellow_ :: Doc AnsiStyle -> Doc AnsiStyle
yellow_ = annotate (color Yellow)

white_ :: Doc AnsiStyle -> Doc AnsiStyle
white_ = annotate (color White)

dim_ :: Doc AnsiStyle -> Doc AnsiStyle
dim_ = annotate (colorDull Black)

fmtDate :: Int -> Doc AnsiStyle
fmtDate 0 = dim_ "—"
fmtDate ts =
  pretty $
    formatTime defaultTimeLocale "%Y-%m-%d" $
      posixSecondsToUTCTime (fromIntegral ts)

fmtMinutes :: Minutes -> Doc AnsiStyle
fmtMinutes 0 = dim_ "—"
fmtMinutes m =
  let h = m `div` 60
      mn = m `mod` 60
   in pretty $ if h > 0 then show h <> "h " <> show mn <> "m" else show mn <> "m"

fmtSecStr :: Seconds -> String
fmtSecStr 0 = "0m"
fmtSecStr s =
  let h = s `div` 3600
      m = (s `mod` 3600) `div` 60
   in if h > 0 then show h <> "h " <> show m <> "m" else show m <> "m"

fmtSeconds :: Seconds -> Doc AnsiStyle
fmtSeconds 0 = dim_ "—"
fmtSeconds s = green_ . pretty $ fmtSecStr s

fmtHours :: Double -> Doc AnsiStyle
fmtHours 0 = dim_ "—"
fmtHours d =
  let h = floor d :: Int
      mn = round ((d - fromIntegral h) * 60) :: Int
   in pretty $ if h > 0 then show h <> "h " <> show mn <> "m" else show mn <> "m"

fmtTimeline :: PlayTimeline -> Doc AnsiStyle
fmtTimeline tl
  | tl.start == 0 = dim_ "·" <+> fmtSeconds tl.duration
  | otherwise =
      let startUtc = posixSecondsToUTCTime (fromIntegral tl.start)
          endTs = if tl.end > 0 then tl.end else tl.start + tl.duration
          endUtc = posixSecondsToUTCTime (fromIntegral endTs)
          startDate = formatTime defaultTimeLocale "%Y-%m-%d" startUtc
          endDate = formatTime defaultTimeLocale "%Y-%m-%d" endUtc
          startTime = formatTime defaultTimeLocale "%H:%M" startUtc
          endTime = formatTime defaultTimeLocale "%H:%M" endUtc
          timeRange =
            if startDate == endDate
              then pretty (startDate <> " " <> startTime <> " → " <> endTime)
              else pretty (startDate <> " " <> startTime <> " → " <> endDate <> " " <> endTime)
       in dim_ "·" <+> timeRange <+> dim_ "·" <+> fmtSeconds tl.duration

totalPlayed :: [PlayTimeline] -> Seconds
totalPlayed = sum . map (.duration)

effectivePlayed :: GameWithLocal -> Seconds
effectivePlayed gwl =
  totalPlayed gwl.game.playTimelines + fromMaybe 0 gwl.running

ratingDoc :: Double -> Doc AnsiStyle
ratingDoc 0 = dim_ "not rated"
ratingDoc r =
  let norm = if r > 10 then r / 10 else r
      filled = min 10 (max 0 (round norm :: Int))
      stars = replicate filled '★' <> replicate (10 - filled) '☆'
      scoreStr = if r > 10 then show (round r :: Int) <> "/100" else show (round r :: Int) <> "/10"
   in yellow_ (pretty stars) <+> dim_ (pretty scoreStr)

truncated :: Int -> Text -> Doc AnsiStyle
truncated n t
  | T.length t <= n = pretty t
  | otherwise = pretty (T.take (n - 1) t <> "…")

ruleW :: Int -> Doc AnsiStyle
ruleW w = dim_ (pretty (replicate (max 20 w) '─'))

wrapLine :: Int -> Text -> [Text]
wrapLine maxW t
  | T.null t = [""]
  | T.length t <= maxW = [t]
  | otherwise =
      let (chunk, rest) = T.splitAt maxW t
       in chunk : wrapLine maxW rest

kv :: Int -> Text -> Doc AnsiStyle -> Doc AnsiStyle
kv w k v =
  dim_ (pretty (T.replicate (w - T.length k) " " <> k <> "  ")) <> v

tagsList :: [Text] -> Doc AnsiStyle
tagsList [] = dim_ "—"
tagsList ts =
  hsep $ map (\t -> dim_ "[" <> cyan_ (pretty t) <> dim_ "]") ts

linksList :: (HasField "name" l Text, HasField "url" l Text) => [l] -> Doc AnsiStyle
linksList [] = emptyDoc
linksList ls =
  vsep
    [ emptyDoc,
      dim_ "  links",
      indent 4 . hsep $
        map (\l -> cyan_ (pretty l.name) <> dim_ (pretty (" " <> l.url))) ls
    ]

progressBar :: Int -> Seconds -> Minutes -> Doc AnsiStyle
progressBar barWidth playedSec expectedMin
  | expectedMin <= 0 || playedSec <= 0 = dim_ "—"
  | otherwise =
      let expectedSec = expectedMin * 60
          pct = (playedSec * 100) `div` expectedSec
          clampedPct = min 100 (max 0 pct)
          filled = min barWidth (round ((fromIntegral (clampedPct * barWidth) / 100.0) :: Double) :: Int)
          empty = barWidth - filled
          bar = replicate filled '█' <> replicate empty '░'
          pctStr = show pct <> "%"
          pctPadded = replicate (max 0 (4 - length pctStr)) ' ' <> pctStr
       in if pct >= 100
            then green_ (pretty bar) <+> green_ (pretty pctPadded)
            else cyan_ (pretty bar) <+> dim_ (pretty pctPadded)

statusDot :: GameWithLocal -> Doc AnsiStyle
statusDot gwl
  | isJust gwl.running = annotate (color Green <> bold) "▶"
  | null gwl.game.playTimelines = dim_ "○"
  | effectivePlayed gwl >= fromIntegral (gwl.game.expectedPlayTime * 60) && gwl.game.expectedPlayTime > 0 =
      annotate (color Cyan) "✔"
  | otherwise = green_ "●"

data ListColumns = ListColumns
  { colId :: !Int,
    colTitle :: !Int,
    colDev :: !Int,
    colPlayed :: !Int,
    colProgress :: !Int,
    colLastPlay :: !Int,
    colRating :: !Int
  }
  deriving (Show)

calcColumns :: Int -> ListColumns
calcColumns w =
  let idW = 8
      fixedW = idW + 48
      dynamicW = max 24 (w - fixedW)
      devW = max 10 (min 22 (dynamicW `div` 3))
      titleW = dynamicW - devW
   in ListColumns
        { colId = idW,
          colTitle = titleW,
          colDev = devW,
          colPlayed = 9,
          colProgress = 14,
          colLastPlay = 10,
          colRating = 6
        }

prettyGameRow :: ListColumns -> GameWithLocal -> Doc AnsiStyle
prettyGameRow cols gwl =
  statusDot gwl
    <+> fill cols.colId (annotate (color Magenta) (truncated cols.colId gwl.game.coreId.unGameId))
    <+> fill cols.colTitle (bold_ (truncated cols.colTitle gwl.game.title))
    <+> fill cols.colDev (dim_ (truncated cols.colDev gwl.game.developer))
    <+> fill cols.colPlayed playedDoc
    <+> fill cols.colProgress (progressBar 8 played gwl.game.expectedPlayTime)
    <+> fill cols.colLastPlay lastPlayDoc
    <+> ratingCol
  where
    played = effectivePlayed gwl
    playedDoc = case gwl.running of
      Just _ -> annotate (color Green <> bold) (pretty (fmtSecStr played))
      Nothing -> fmtSeconds played
    lastPlayDoc = case gwl.running of
      Just _ -> annotate (color Green <> bold) "now"
      Nothing -> fmtDate gwl.game.lastPlay
    ratingCol
      | gwl.game.rating <= 0 = dim_ "—"
      | otherwise =
          let score = if gwl.game.rating > 10 then gwl.game.rating / 10 else gwl.game.rating
              intPart = floor score :: Int
              decPart = round ((score - fromIntegral intPart) * 10) :: Int
              scoreStr = if decPart == 0 then show intPart else show intPart <> "." <> show decPart
           in yellow_ ("★ " <> pretty scoreStr)

listHeader :: ListColumns -> Doc AnsiStyle
listHeader cols =
  dim_ $
    pretty ("  " :: Text)
      <> fill cols.colId "id"
      <+> fill cols.colTitle "title"
      <+> fill cols.colDev "developer"
      <+> fill cols.colPlayed "played"
      <+> fill cols.colProgress "progress"
      <+> fill cols.colLastPlay "last play"
      <+> "rating"

prettyGamesW :: Int -> [GameWithLocal] -> Doc AnsiStyle
prettyGamesW _ [] = dim_ "  no games in library."
prettyGamesW w gs =
  vsep $
    [ listHeader cols,
      ruleW w
    ]
      <> map (prettyGameRow cols) gs
      <> [ ruleW w,
           footer
         ]
  where
    cols = calcColumns w
    tot = length gs
    totalSec = sum (map effectivePlayed gs)
    runningCount = length (filter (isJust . (.running)) gs)
    runDoc = if runningCount > 0 then dim_ "  ·  " <> green_ (pretty (show runningCount <> " running")) else emptyDoc
    playDoc = if totalSec > 0 then dim_ "  ·  " <> pretty (fmtSecStr totalSec) <+> dim_ "played" else emptyDoc
    footer = dim_ ("  " <> pretty (show tot <> " game(s)")) <> playDoc <> runDoc

prettyGameDetailW :: Int -> GameWithLocal -> Doc AnsiStyle
prettyGameDetailW w gwl =
  vsep $
    [ ruleW w,
      bold_ (white_ (pretty gwl.game.title))
        <+> dim_ (pretty ("#" <> gwl.game.coreId.unGameId)),
      aliasLine,
      ruleW w,
      kv kw "status" statusLine,
      kv kw "vndb" vndbLine,
      kv kw "developer" (pretty gwl.game.developer),
      kv kw "release" (fmtDate gwl.game.releaseDate),
      kv kw "added" (fmtDate gwl.game.createDate),
      kv kw "updated" (fmtDate gwl.game.updateDate),
      emptyDoc,
      kv kw "rating" (ratingDoc gwl.game.rating),
      kv kw "expected" (fmtMinutes gwl.game.expectedPlayTime),
      kv kw "played" playedLine,
      kv kw "progress" (progressBar 16 played gwl.game.expectedPlayTime),
      kv kw "last play" lastPlayLine,
      kv kw "sessions" (pretty (length gwl.game.playTimelines + maybe 0 (const 1) gwl.running)),
      emptyDoc,
      kv kw "tags" (tagsList gwl.game.tags)
    ]
      <> descSection
      <> sessionSection
      <> localSection
      <> linksSection
      <> imagesSection
      <> [ruleW w]
  where
    kw = 10
    played = effectivePlayed gwl

    statusLine = case gwl.running of
      Just liveSec -> annotate (color Green <> bold) "▶ running" <+> dim_ ("(session: " <> pretty (fmtSecStr liveSec) <> ")")
      Nothing
        | null gwl.game.playTimelines -> dim_ "○ unplayed"
        | played >= fromIntegral (gwl.game.expectedPlayTime * 60) && gwl.game.expectedPlayTime > 0 ->
            cyan_ "✔ finished"
        | otherwise -> green_ "● in library"

    aliasLine
      | null gwl.game.alias = emptyDoc
      | otherwise =
          dim_ . pretty $
            intercalate " / " (map T.unpack gwl.game.alias)

    vndbLine = case gwl.game.vndbId of
      Nothing -> dim_ "—"
      Just vid -> cyan_ (pretty vid)

    playedLine = case gwl.running of
      Just liveSec ->
        fmtSeconds played <+> annotate (color Green <> bold) (pretty ("(+" <> fmtSecStr liveSec <> " now)"))
      Nothing -> fmtSeconds played

    lastPlayLine = case gwl.running of
      Just _ -> annotate (color Green <> bold) "now"
      Nothing -> fmtDate gwl.game.lastPlay

    descSection
      | T.null gwl.game.description = []
      | otherwise =
          [ emptyDoc,
            dim_ "  description"
          ]
            <> map (indent 4 . pretty) (concatMap (wrapLine (max 40 (w - 8))) (T.lines gwl.game.description))

    sessionSection :: [Doc AnsiStyle]
    sessionSection
      | null gwl.game.playTimelines = []
      | otherwise =
          [ emptyDoc,
            dim_ "  recent sessions"
          ]
            <> map (indent 4 . fmtTimeline) (take 5 . reverse $ gwl.game.playTimelines)

    localSection :: [Doc AnsiStyle]
    localSection = case gwl.local of
      Nothing ->
        [ emptyDoc,
          dim_ "  local",
          indent 4 (dim_ "not configured  (set with: sena use " <> pretty gwl.game.coreId.unGameId <> " <path>)")
        ]
      Just lp ->
        [ emptyDoc,
          dim_ "  local",
          indent 4 (dim_ "exe   " <> pretty lp.programFile)
        ]
          <> maybe [] (\s -> [indent 4 (dim_ "save  " <> pretty s)]) lp.savePath
          <> maybe [] (\f -> [indent 4 (dim_ "guide " <> pretty f)]) lp.guideFile

    linksSection :: [Doc AnsiStyle]
    linksSection
      | null gwl.game.links = []
      | otherwise = [linksList gwl.game.links]

    imagesSection :: [Doc AnsiStyle]
    imagesSection
      | null gwl.game.images = []
      | otherwise =
          [ emptyDoc,
            dim_ "  images"
          ]
            <> map (\img -> indent 4 (dim_ "· " <> cyan_ (pretty img))) gwl.game.images

prettyFetchResultW :: Int -> Int -> FetchGameData -> Doc AnsiStyle
prettyFetchResultW w idx f =
  vsep $
    [ ruleW w,
      dim_ (pretty ("[" <> show idx <> "]  "))
        <> bold_ (white_ (pretty f.title))
        <+> dim_ (pretty f.vndbId),
      aliasLine,
      ruleW w,
      kv kw "developer" (pretty f.developer),
      kv kw "release" (fmtDate f.releaseDate),
      kv kw "rating" (ratingDoc f.rating),
      kv kw "expected" (fmtHours f.expectedPlayHours),
      kv kw "images" (pretty (show (length f.images) <> " image(s)")),
      emptyDoc,
      kv kw "tags" (tagsList f.tags)
    ]
      <> descSection
      <> linksSection
      <> [ruleW w]
  where
    kw = 10

    aliasLine
      | null f.alias = emptyDoc
      | otherwise =
          dim_ . pretty $
            intercalate " / " (map T.unpack f.alias)

    descSection
      | T.null f.description = []
      | otherwise =
          [ emptyDoc,
            dim_ "  description"
          ]
            <> map (indent 4 . pretty) (concatMap (wrapLine (max 40 (w - 8))) (T.lines f.description))

    linksSection :: [Doc AnsiStyle]
    linksSection
      | null f.links = []
      | otherwise = [linksList f.links]

prettyFetchResultsW :: Int -> [FetchGameData] -> Doc AnsiStyle
prettyFetchResultsW _ [] = dim_ "  no results."
prettyFetchResultsW w fs =
  vsep (zipWith (prettyFetchResultW w) [1 ..] fs)
    <> line
    <> dim_ (pretty ("  " <> show (length fs) <> " result(s)  ·  use --order N for details"))

data LibraryStats = LibraryStats
  { totalGames :: !Int,
    configuredGames :: !Int,
    playedGames :: !Int,
    unplayedGames :: !Int,
    totalPlaytime :: !Seconds,
    totalSessions :: !Int,
    avgSessionSec :: !Seconds,
    topPlayed :: ![(GameWithLocal, Seconds)]
  }

computeStats :: [GameWithLocal] -> LibraryStats
computeStats games =
  let tot = length games
      configured = length $ filter (isJust . (.local)) games
      withPlay = filter (\g -> effectivePlayed g > 0) games
      playedCount = length withPlay
      unplayedCount = tot - playedCount
      totalSec = sum (map effectivePlayed games)
      allSessions = concatMap (\g -> g.game.playTimelines) games
      totSessions = length allSessions + length (filter (isJust . (.running)) games)
      avgSec = if totSessions > 0 then totalSec `div` totSessions else 0
      top5 = take 5 . sortOn (Down . snd) $ map (\g -> (g, effectivePlayed g)) withPlay
   in LibraryStats
        { totalGames = tot,
          configuredGames = configured,
          playedGames = playedCount,
          unplayedGames = unplayedCount,
          totalPlaytime = totalSec,
          totalSessions = totSessions,
          avgSessionSec = avgSec,
          topPlayed = top5
        }

prettyLibraryStatsW :: Int -> [GameWithLocal] -> Doc AnsiStyle
prettyLibraryStatsW w games =
  let s = computeStats games
      kw = 16
      showPct n tot' =
        if tot' > 0 then show ((n * 100) `div` tot') <> "%" else "0%"
      topSection
        | null s.topPlayed = emptyDoc
        | otherwise =
            let maxSec = maximum (map snd s.topPlayed)
                barMax = max 15 (min 35 (w - 55))
                barLen sec = if maxSec > 0 then (sec * barMax) `div` maxSec else 0
                titleW = max 20 (min 45 (w - barMax - 25))
                row (idx, (gwl, sec)) =
                  dim_ ("  " <> pretty (show idx <> ". "))
                    <> fill titleW (bold_ (truncated titleW gwl.game.title))
                    <+> fill 10 (fmtSeconds sec)
                    <+> cyan_ (pretty (replicate (barLen sec) '█' <> replicate (barMax - barLen sec) '░'))
             in vsep
                  ( [ emptyDoc,
                      dim_ "  Top Played Games"
                    ]
                      <> zipWith (curry row) [1 :: Int ..] s.topPlayed
                  )
   in vsep
        [ ruleW w,
          bold_ (white_ "SenaVN Library Statistics"),
          ruleW w,
          kv kw "total games" (pretty s.totalGames),
          kv kw "configured" (pretty s.configuredGames <+> dim_ ("(" <> pretty (showPct s.configuredGames s.totalGames) <> ")")),
          kv kw "played" (green_ (pretty s.playedGames) <+> dim_ ("(" <> pretty (showPct s.playedGames s.totalGames) <> ")")),
          kv kw "unplayed" (dim_ (pretty s.unplayedGames) <+> dim_ ("(" <> pretty (showPct s.unplayedGames s.totalGames) <> ")")),
          emptyDoc,
          kv kw "total playtime" (fmtSeconds s.totalPlaytime),
          kv kw "sessions" (pretty s.totalSessions),
          kv kw "avg session" (fmtSeconds s.avgSessionSec),
          topSection,
          ruleW w
        ]

prettyGameStatW :: Int -> GameWithLocal -> Doc AnsiStyle
prettyGameStatW w gwl =
  vsep
    [ ruleW w,
      bold_ (white_ (pretty gwl.game.title)) <+> dim_ (pretty ("#" <> gwl.game.coreId.unGameId)),
      ruleW w,
      kv kw "developer" (pretty gwl.game.developer),
      kv kw "rating" (ratingDoc gwl.game.rating),
      kv kw "expected" (fmtMinutes gwl.game.expectedPlayTime),
      kv kw "played" playedDoc,
      kv kw "progress" (progressBar 16 played gwl.game.expectedPlayTime),
      emptyDoc,
      kv kw "sessions" (pretty totalSessCount),
      kv kw "avg session" (fmtSeconds avgSess),
      kv kw "longest" (fmtSeconds longestSess),
      kv kw "first play" (fmtDate firstPlay),
      kv kw "last play" lastPlayDoc,
      ruleW w
    ]
  where
    kw = 14
    played = effectivePlayed gwl
    playedDoc = case gwl.running of
      Just liveSec -> fmtSeconds played <+> green_ (pretty ("(+" <> fmtSecStr liveSec <> " now)"))
      Nothing -> fmtSeconds played
    lastPlayDoc = case gwl.running of
      Just _ -> green_ "now"
      Nothing -> fmtDate gwl.game.lastPlay
    timelines = gwl.game.playTimelines
    totalSessCount = length timelines + maybe 0 (const 1) gwl.running
    longestSess = if null timelines then 0 else maximum (map (.duration) timelines)
    avgSess = if totalSessCount > 0 then played `div` totalSessCount else 0
    firstPlay = if null timelines then 0 else minimum (map (.start) timelines)

getTermWidth :: IO Int
getTermWidth = do
  mEnvCols <- lookupEnv "COLUMNS"
  let parsedEnv = mEnvCols >>= readMaybe
  pure $ case parsedEnv of
    Just cols | cols > 0 -> clamp cols
    _ -> 88
  where
    clamp c = max 60 (min 160 (c - 1))

renderDoc :: Doc AnsiStyle -> IO ()
renderDoc doc = do
  w <- getTermWidth
  isTerm <- hIsTerminalDevice stdout `catch` \(_ :: SomeException) -> pure False
  let opts = LayoutOptions (AvailablePerLine (max 40 w) 1.0)
  if isTerm
    then renderIO stdout (layoutPretty opts doc)
    else renderIO stdout (layoutPretty opts (unAnnotate doc))

renderInline :: Doc AnsiStyle -> IO ()
renderInline doc = do
  w <- getTermWidth
  isTerm <- hIsTerminalDevice stdout `catch` \(_ :: SomeException) -> pure False
  let opts = LayoutOptions (AvailablePerLine (max 40 w) 1.0)
  if isTerm
    then renderIO stdout (layoutPretty opts doc)
    else renderIO stdout (layoutPretty opts (unAnnotate doc))
  hFlush stdout

render :: Doc AnsiStyle -> IO ()
render = renderDoc

printGame :: GameWithLocal -> IO ()
printGame gwl = do
  w <- getTermWidth
  renderDoc (prettyGameDetailW w gwl)

printGames :: [GameWithLocal] -> IO ()
printGames gs = do
  w <- getTermWidth
  renderDoc (prettyGamesW w gs)

printFetchResult :: Int -> FetchGameData -> IO ()
printFetchResult idx fd = do
  w <- getTermWidth
  renderDoc (prettyFetchResultW w idx fd)

printFetchResults :: [FetchGameData] -> IO ()
printFetchResults fs = do
  w <- getTermWidth
  renderDoc (prettyFetchResultsW w fs)

printLibraryStats :: [GameWithLocal] -> IO ()
printLibraryStats gs = do
  w <- getTermWidth
  renderDoc (prettyLibraryStatsW w gs)

printGameStat :: GameWithLocal -> IO ()
printGameStat gwl = do
  w <- getTermWidth
  renderDoc (prettyGameStatW w gwl)
