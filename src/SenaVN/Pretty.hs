{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module SenaVN.Pretty
  ( prettyGameDetail,
    prettyGameRow,
    prettyGames,
    prettyFetchResult,
    prettyFetchResults,
    printGame,
    printGames,
    printFetchResult,
    printFetchResults,
  )
where

import Data.List (intercalate)
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

-- magenta_ :: Doc AnsiStyle -> Doc AnsiStyle
-- magenta_ = annotate (color Magenta)

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

fmtSeconds :: Seconds -> Doc AnsiStyle
fmtSeconds 0 = dim_ "—"
fmtSeconds s =
  let h = s `div` 3600
      m = (s `mod` 3600) `div` 60
   in green_ . pretty $
        if h > 0 then show h <> "h " <> show m <> "m" else show m <> "m"

-- Double 小时 -> "12h 30m"
fmtHours :: Double -> Doc AnsiStyle
fmtHours 0 = dim_ "—"
fmtHours d =
  let h = floor d :: Int
      mn = round ((d - fromIntegral h) * 60) :: Int
   in pretty $ if h > 0 then show h <> "h " <> show mn <> "m" else show mn <> "m"

totalPlayed :: [PlayTimeline] -> Seconds
totalPlayed = sum . map (.duration)

ratingDoc :: Double -> Doc AnsiStyle
ratingDoc 0 = dim_ "not rated"
ratingDoc r =
  let filled = round (r / 10) :: Int
      stars = replicate filled '★' <> replicate (10 - filled) '☆'
   in yellow_ (pretty stars) <+> dim_ (pretty (show (round r :: Int) <> "/100"))

truncated :: Int -> Text -> Doc AnsiStyle
truncated n t
  | T.length t <= n = pretty t
  | otherwise = pretty (T.take (n - 1) t <> "…")

rule :: Doc AnsiStyle
rule = dim_ (pretty (replicate 58 '─'))

-- key-value 行，key 固定宽度右对齐
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

prettyGameDetail :: GameWithLocal -> Doc AnsiStyle
prettyGameDetail gwl =
  vsep $
    [ rule,
      bold_ (white_ (pretty gwl.game.title))
        <+> dim_ (pretty ("#" <> gwl.game.coreId.unGameId)),
      aliasLine,
      rule,
      kv w "vndb" vndbLine,
      kv w "developer" (pretty gwl.game.developer),
      kv w "release" (fmtDate gwl.game.releaseDate),
      kv w "added" (fmtDate gwl.game.createDate),
      kv w "updated" (fmtDate gwl.game.updateDate),
      emptyDoc,
      kv w "rating" (ratingDoc gwl.game.rating),
      kv w "expected" (fmtMinutes gwl.game.expectedPlayTime),
      kv w "played" (fmtSeconds played),
      kv w "last play" (fmtDate gwl.game.lastPlay),
      kv w "sessions" (pretty (length gwl.game.playTimelines)),
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
    played = totalPlayed gwl.game.playTimelines

    aliasLine
      | null gwl.game.alias = emptyDoc
      | otherwise =
          dim_ . pretty $
            intercalate " / " (map T.unpack gwl.game.alias)

    vndbLine = case gwl.game.vndbId of
      Nothing -> dim_ "—"
      Just vid -> cyan_ (pretty vid)

    descSection
      | T.null gwl.game.description = []
      | otherwise =
          [ emptyDoc,
            dim_ "  description",
            indent 4 (truncated 240 gwl.game.description)
          ]

    -- 明确类型签名，避免 FlexibleContexts 推断问题
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

-- ────────────────────────────────────────────
-- GameWithLocal 列表视图
-- ────────────────────────────────────────────

statusDot :: GameWithLocal -> Doc AnsiStyle
statusDot gwl
  | null gwl.game.playTimelines = dim_ "○"
  | gwl.game.lastPlay > 0 = green_ "●"
  | otherwise = yellow_ "◐"

prettyGameRow :: GameWithLocal -> Doc AnsiStyle
prettyGameRow gwl =
  statusDot gwl
    <+> fill 30 (bold_ (truncated 28 gwl.game.title))
    <+> fill 14 (dim_ (truncated 12 gwl.game.developer))
    <+> fill 10 (fmtSeconds (totalPlayed gwl.game.playTimelines))
    <+> fill 12 (fmtDate gwl.game.lastPlay)
    <+> ratingCol
  where
    ratingCol
      | gwl.game.rating == 0 = dim_ "—"
      | otherwise = yellow_ . pretty $ show (round gwl.game.rating :: Int)

listHeader :: Doc AnsiStyle
listHeader =
  dim_ $
    pretty ("  " :: Text)
      <> fill 30 "title"
      <> fill 14 "developer"
      <> fill 10 "played"
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

-- 多条搜索结果，带序号，用于 sena fetch 展示
prettyFetchResults :: [FetchGameData] -> Doc AnsiStyle
prettyFetchResults [] = dim_ "  no results."
prettyFetchResults fs =
  vsep (zipWith prettyFetchResult [1 ..] fs)
    <> line
    <> dim_ (pretty ("  " <> show (length fs) <> " result(s)  ·  use --order N for details"))

-- ────────────────────────────────────────────
-- IO 输出
-- ────────────────────────────────────────────

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