{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module SenaVN.Pretty
  ( prettyGameDetail,
    prettyGameRow,
    prettyGames,
    prettyFetchResult,
    prettyFetchResults,
    prettyLibraryStats,
    prettyGameStat,
    printGame,
    printGames,
    printFetchResult,
    printFetchResults,
    printLibraryStats,
    printGameStat,
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
    totalPlayed,
    ratingDoc,
    truncated,
    rule,
    kv,
    tagsList,
    linksList,
    statusDot,
    progressBar,
  )
where

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
import System.IO (stdout)

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

rule :: Doc AnsiStyle
rule = dim_ (pretty (replicate 75 '─'))

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
  | expectedMin <= 0 = dim_ "       —        "
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
  | isJust gwl.running = annotate (color Green <> bold) "●"
  | null gwl.game.playTimelines = dim_ "○"
  | otherwise = green_ "●"

prettyGameDetail :: GameWithLocal -> Doc AnsiStyle
prettyGameDetail gwl =
  vsep $
    [ rule,
      bold_ (white_ (pretty gwl.game.title))
        <+> dim_ (pretty ("#" <> gwl.game.coreId.unGameId)),
      aliasLine,
      rule,
      kv w "status" statusLine,
      kv w "vndb" vndbLine,
      kv w "developer" (pretty gwl.game.developer),
      kv w "release" (fmtDate gwl.game.releaseDate),
      kv w "added" (fmtDate gwl.game.createDate),
      kv w "updated" (fmtDate gwl.game.updateDate),
      emptyDoc,
      kv w "rating" (ratingDoc gwl.game.rating),
      kv w "expected" (fmtMinutes gwl.game.expectedPlayTime),
      kv w "played" playedLine,
      kv w "progress" (progressBar 16 played gwl.game.expectedPlayTime),
      kv w "last play" lastPlayLine,
      kv w "sessions" (pretty (length gwl.game.playTimelines + maybe 0 (const 1) gwl.running)),
      emptyDoc,
      kv w "tags" (tagsList gwl.game.tags)
    ]
      <> descSection
      <> sessionSection
      <> localSection
      <> linksSection
      <> [rule]
  where
    w = 10
    played = effectivePlayed gwl

    statusLine = case gwl.running of
      Just liveSec -> annotate (color Green <> bold) "● running" <+> dim_ ("(session: " <> pretty (fmtSecStr liveSec) <> ")")
      Nothing
        | null gwl.game.playTimelines -> dim_ "○ unplayed"
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
            dim_ "  description",
            indent 4 (truncated 240 gwl.game.description)
          ]

    sessionSection :: [Doc AnsiStyle]
    sessionSection
      | null gwl.game.playTimelines = []
      | otherwise =
          [ emptyDoc,
            dim_ "  recent sessions"
          ]
            <> map timelineRow (take 5 . reverse $ gwl.game.playTimelines)

    timelineRow :: PlayTimeline -> Doc AnsiStyle
    timelineRow tl =
      indent 4 $
        dim_ "·"
          <+> fmtDate tl.start
          <+> dim_ "→"
          <+> fmtDate tl.end
          <+> dim_ "|"
          <+> fmtSeconds tl.duration

    localSection :: [Doc AnsiStyle]
    localSection = case gwl.local of
      Nothing -> []
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

prettyGameRow :: GameWithLocal -> Doc AnsiStyle
prettyGameRow gwl =
  statusDot gwl
    <+> fill 26 (bold_ (truncated 24 gwl.game.title))
    <+> fill 14 (dim_ (truncated 12 gwl.game.developer))
    <+> fill 10 playedDoc
    <+> fill 16 (progressBar 8 played gwl.game.expectedPlayTime)
    <+> fill 12 lastPlayDoc
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
      | gwl.game.rating == 0 = dim_ "—"
      | otherwise = yellow_ . pretty $ show (round gwl.game.rating :: Int)

listHeader :: Doc AnsiStyle
listHeader =
  dim_ $
    pretty ("  " :: Text)
      <> fill 26 "title"
      <> fill 14 "developer"
      <> fill 10 "played"
      <> fill 16 "progress"
      <> fill 12 "last play"
      <> "rating"

prettyGames :: [GameWithLocal] -> Doc AnsiStyle
prettyGames [] = dim_ "  no games."
prettyGames gs =
  vsep $
    [ listHeader,
      rule
    ]
      <> map prettyGameRow gs
      <> [ rule,
           dim_ (pretty ("  " <> show (length gs) <> " game(s)"))
         ]

prettyFetchResult :: Int -> FetchGameData -> Doc AnsiStyle
prettyFetchResult idx f =
  vsep $
    [ rule,
      dim_ (pretty ("[" <> show idx <> "]  "))
        <> bold_ (white_ (pretty f.title))
        <+> dim_ (pretty f.vndbId),
      aliasLine,
      rule,
      kv w "developer" (pretty f.developer),
      kv w "release" (fmtDate f.releaseDate),
      kv w "rating" (ratingDoc f.rating),
      kv w "expected" (fmtHours f.expectedPlayHours),
      emptyDoc,
      kv w "tags" (tagsList f.tags)
    ]
      <> descSection
      <> linksSection
      <> [rule]
  where
    w = 10

    aliasLine
      | null f.alias = emptyDoc
      | otherwise =
          dim_ . pretty $
            intercalate " / " (map T.unpack f.alias)

    descSection
      | T.null f.description = []
      | otherwise =
          [ emptyDoc,
            dim_ "  description",
            indent 4 (truncated 240 f.description)
          ]

    linksSection :: [Doc AnsiStyle]
    linksSection
      | null f.links = []
      | otherwise = [linksList f.links]

prettyFetchResults :: [FetchGameData] -> Doc AnsiStyle
prettyFetchResults [] = dim_ "  no results."
prettyFetchResults fs =
  vsep (zipWith prettyFetchResult [1 ..] fs)
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

prettyLibraryStats :: [GameWithLocal] -> Doc AnsiStyle
prettyLibraryStats games =
  let s = computeStats games
      w = 16
      showPct n tot' =
        if tot' > 0 then show ((n * 100) `div` tot') <> "%" else "0%"
      topSection
        | null s.topPlayed = emptyDoc
        | otherwise =
            let maxSec = maximum (map snd s.topPlayed)
                barLen sec = if maxSec > 0 then (sec * 20) `div` maxSec else 0
                row (idx, (gwl, sec)) =
                  dim_ ("  " <> pretty (show idx <> ". "))
                    <> fill 26 (bold_ (truncated 24 gwl.game.title))
                    <+> fill 10 (fmtSeconds sec)
                    <+> cyan_ (pretty (replicate (barLen sec) '█' <> replicate (20 - barLen sec) '░'))
             in vsep
                  ( [ emptyDoc,
                      dim_ "  Top Played Games"
                    ]
                      <> map row (zip [1 :: Int ..] s.topPlayed)
                  )
   in vsep
        [ rule,
          bold_ (white_ "SenaVN Library Statistics"),
          rule,
          kv w "total games" (pretty s.totalGames),
          kv w "configured" (pretty s.configuredGames <+> dim_ ("(" <> pretty (showPct s.configuredGames s.totalGames) <> ")")),
          kv w "played" (green_ (pretty s.playedGames) <+> dim_ ("(" <> pretty (showPct s.playedGames s.totalGames) <> ")")),
          kv w "unplayed" (dim_ (pretty s.unplayedGames) <+> dim_ ("(" <> pretty (showPct s.unplayedGames s.totalGames) <> ")")),
          emptyDoc,
          kv w "total playtime" (fmtSeconds s.totalPlaytime),
          kv w "sessions" (pretty s.totalSessions),
          kv w "avg session" (fmtSeconds s.avgSessionSec),
          topSection,
          rule
        ]

prettyGameStat :: GameWithLocal -> Doc AnsiStyle
prettyGameStat gwl =
  vsep
    [ rule,
      bold_ (white_ (pretty gwl.game.title)) <+> dim_ (pretty ("#" <> gwl.game.coreId.unGameId)),
      rule,
      kv w "developer" (pretty gwl.game.developer),
      kv w "rating" (ratingDoc gwl.game.rating),
      kv w "expected" (fmtMinutes gwl.game.expectedPlayTime),
      kv w "played" playedDoc,
      kv w "progress" (progressBar 16 played gwl.game.expectedPlayTime),
      emptyDoc,
      kv w "sessions" (pretty totalSessCount),
      kv w "avg session" (fmtSeconds avgSess),
      kv w "longest" (fmtSeconds longestSess),
      kv w "first play" (fmtDate firstPlay),
      kv w "last play" lastPlayDoc,
      rule
    ]
  where
    w = 14
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

render :: Doc AnsiStyle -> IO ()
render = renderIO stdout . layoutPretty defaultLayoutOptions

printGame :: GameWithLocal -> IO ()
printGame = render . prettyGameDetail

printGames :: [GameWithLocal] -> IO ()
printGames = render . prettyGames

printFetchResult :: Int -> FetchGameData -> IO ()
printFetchResult idx = render . prettyFetchResult idx

printFetchResults :: [FetchGameData] -> IO ()
printFetchResults = render . prettyFetchResults

printLibraryStats :: [GameWithLocal] -> IO ()
printLibraryStats = render . prettyLibraryStats

printGameStat :: GameWithLocal -> IO ()
printGameStat = render . prettyGameStat
