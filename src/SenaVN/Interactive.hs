module SenaVN.Interactive
  ( printLn,
    ok,
    askConfirmation,
    selectFetchInteractive,
    selectGameInteractive,
  )
where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Prettyprinter
import Prettyprinter.Render.Terminal
import SenaVN.Pretty
  ( bold_,
    cyan_,
    dim_,
    render,
    renderInline,
    white_,
    yellow_,
  )
import SenaVN.Types
  ( FetchGameData (..),
    GameCore (..),
    GameId (..),
    GameWithLocal (..),
    LocalPath (..),
  )
import System.Console.Haskeline (defaultSettings, getInputLine, runInputT)
import System.Exit (exitFailure)

printLn :: Doc AnsiStyle -> IO ()
printLn d = render (d <> line)

ok :: Doc AnsiStyle -> IO ()
ok msg = printLn $ annotate (color Green <> bold) "✔" <+> msg

askConfirmation :: Doc AnsiStyle -> IO Bool
askConfirmation promptDoc = do
  renderInline $
    annotate (color Yellow <> bold) "?"
      <+> promptDoc
      <+> dim_ "[y/N]"
      <+> annotate (color Cyan <> bold) "› "
  ans <- runInputT defaultSettings (getInputLine "")
  case ans of
    Just s ->
      let trimmed = T.toLower (T.strip (T.pack s))
       in pure (trimmed == "y" || trimmed == "yes")
    Nothing -> pure False

selectFetchInteractive :: Text -> [FetchGameData] -> IO FetchGameData
selectFetchInteractive _ [] = fail "Empty results"
selectFetchInteractive query (firstResult : rest) = do
  let results = firstResult : rest
  printLn $
    annotate (color Cyan <> bold) "◆"
      <+> bold_ "Multiple VNDB results found for"
      <+> cyan_ (pretty ("'" <> query <> "'")) <> dim_ ":"
  let displayResults = take 6 results
  forM_ (zip [1 :: Int ..] displayResults) $ \(idx, fd) -> do
    let vid = fd.vndbId
        titleDoc = bold_ (white_ (pretty fd.title))
        devDoc =
          if T.null fd.developer
            then mempty
            else dim_ " · " <> dim_ (pretty fd.developer)
        ratingDoc' =
          if fd.rating > 0
            then space <> yellow_ ("★" <> pretty (show (round (fd.rating * 10) :: Int)))
            else mempty
    printLn $
      indent 2 $
        annotate (color Cyan <> bold) ("[" <> pretty idx <> "]")
          <+> titleDoc
          <+> dim_ ("(" <> pretty vid <> ")")
          <> devDoc
          <> ratingDoc'
  askLoop (length displayResults)
  where
    askLoop maxIdx = do
      renderInline $
        annotate (color Yellow <> bold) "?"
          <+> bold_ "Select result"
          <+> dim_ ("[1-" <> pretty maxIdx <> ", default 1, q to cancel]")
          <+> annotate (color Cyan <> bold) "› "
      input <- getLine
      let trimmed = filter (/= ' ') input
      case trimmed of
        "" -> pure firstResult
        "1" -> pure firstResult
        "q" -> exitFailure
        "Q" -> exitFailure
        s -> case reads s of
          [(idx, "")] | idx >= 1 && idx <= maxIdx ->
            pure ((firstResult : rest) !! (idx - 1))
          _ -> do
            printLn $
              annotate (color Red <> bold) "✗"
                <+> annotate (color Red) "Invalid selection."
                <+> dim_ ("Please enter 1-" <> pretty maxIdx <> " or 'q' to cancel.")
            askLoop maxIdx

selectGameInteractive :: Text -> [GameWithLocal] -> IO GameCore
selectGameInteractive query matches = do
  printLn $
    annotate (color Cyan <> bold) "◆"
      <+> bold_ "Multiple configured games matched"
      <+> cyan_ (pretty ("'" <> query <> "'")) <> dim_ ":"
  let displayMatches = take 8 matches
  forM_ (zip [1 :: Int ..] displayMatches) $ \(idx, gwl) -> do
    let titleDoc = bold_ (white_ (pretty gwl.game.title))
        idDoc = annotate (color Magenta) (pretty ("(#" <> gwl.game.coreId.unGameId <> ")"))
        exeDoc = maybe mempty (\lp -> dim_ " → " <> dim_ (pretty lp.programFile)) gwl.local
    printLn $
      indent 2 $
        annotate (color Cyan <> bold) ("[" <> pretty idx <> "]")
          <+> titleDoc
          <+> idDoc
          <> exeDoc
  askLoop (length displayMatches)
  where
    askLoop maxIdx = do
      renderInline $
        annotate (color Yellow <> bold) "?"
          <+> bold_ "Select game to run"
          <+> dim_ ("[1-" <> pretty maxIdx <> ", q to cancel]")
          <+> annotate (color Cyan <> bold) "› "
      input <- getLine
      let trimmed = filter (/= ' ') input
      case trimmed of
        "q" -> exitFailure
        "Q" -> exitFailure
        s -> case reads s of
          [(idx, "")] | idx >= 1 && idx <= maxIdx ->
            pure (matches !! (idx - 1)).game
          _ -> do
            printLn $
              annotate (color Red <> bold) "✗"
                <+> annotate (color Red) "Invalid selection."
                <+> dim_ ("Please enter 1-" <> pretty maxIdx <> " or 'q' to cancel.")
            askLoop maxIdx
