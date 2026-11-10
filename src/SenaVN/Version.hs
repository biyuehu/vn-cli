module SenaVN.Version
  ( appVersion,
    appVersionStr,
    appAuthor,
    appHomepage,
    appLicense,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (showVersion)
import Paths_SenaVN (version)

appVersionStr :: String
appVersionStr = showVersion version

appVersion :: Text
appVersion = T.pack appVersionStr

appAuthor :: Text
appAuthor = "ArimuraSena"

appHomepage :: Text
appHomepage = "https://github.com/biyuehu/vn-cli"

appLicense :: Text
appLicense = "GPL-3.0-only"
