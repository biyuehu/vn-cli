module Test.UtilsSpec (utilsTests) where

import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import SenaVN.Utils
import Test.Framework

utilsTests :: Test
utilsTests =
  testGroup
    "SenaVN.Utils"
    [ base64Tests,
      maskSensitiveTests,
      formattingTests,
      textManipulationTests
    ]

base64Tests :: Test
base64Tests =
  testGroup
    "Base64 (RFC 4648)"
    [ testCase "encodes empty ByteString" $
        assertEqual "empty" "" (encodeBase64 ""),
      testCase "encodes standard RFC 4648 vectors" $ do
        assertEqual "f" "Zg==" (encodeBase64 "f")
        assertEqual "fo" "Zm8=" (encodeBase64 "fo")
        assertEqual "foo" "Zm9v" (encodeBase64 "foo")
        assertEqual "foob" "Zm9vYg==" (encodeBase64 "foob")
        assertEqual "fooba" "Zm9vYmE=" (encodeBase64 "fooba")
        assertEqual "foobar" "Zm9vYmFy" (encodeBase64 "foobar"),
      testCase "decodes standard RFC 4648 vectors" $ do
        assertEqual "empty" (Just "") (decodeBase64 "")
        assertEqual "f" (Just "f") (decodeBase64 "Zg==")
        assertEqual "fo" (Just "fo") (decodeBase64 "Zm8=")
        assertEqual "foo" (Just "foo") (decodeBase64 "Zm9v")
        assertEqual "foob" (Just "foob") (decodeBase64 "Zm9vYg==")
        assertEqual "fooba" (Just "fooba") (decodeBase64 "Zm9vYmE=")
        assertEqual "foobar" (Just "foobar") (decodeBase64 "Zm9vYmFy"),
      testCase "rejects malformed inputs" $ do
        assertEqual "length not mod 4" Nothing (decodeBase64 "Zg")
        assertEqual "length not mod 4" Nothing (decodeBase64 "Zg=")
        assertEqual "length not mod 4" Nothing (decodeBase64 "Zm9vY"),
      testCase "roundtrips arbitrary binary and UTF-8 payloads" $ do
        let utf8Sample = TE.encodeUtf8 "Hello World - Visual Novel Engine 2.0"
        let binSample = BS.pack [0 .. 255]
        assertEqual "utf8 roundtrip" (Just utf8Sample) (decodeBase64 (encodeBase64 utf8Sample))
        assertEqual "binary roundtrip" (Just binSample) (decodeBase64 (encodeBase64 binSample))
    ]

maskSensitiveTests :: Test
maskSensitiveTests =
  testGroup
    "maskSensitive"
    [ testCase "leaves non-sensitive keys unmasked" $ do
        assertEqual "editor" "nvim" (maskSensitive "core.editor" "nvim")
        assertEqual "theme" "nord" (maskSensitive "theme" "nord")
        assertEqual "username" "sena" (maskSensitive "username" "sena"),
      testCase "handles empty sensitive values" $ do
        assertEqual "empty token" "" (maskSensitive "sync.token" "")
        assertEqual "empty secret" "" (maskSensitive "api.secret" "")
        assertEqual "empty password" "" (maskSensitive "password" ""),
      testCase "masks short sensitive values completely" $ do
        assertEqual "8 chars" "********" (maskSensitive "sync.token" "12345678")
        assertEqual "4 chars" "********" (maskSensitive "token" "abcd"),
      testCase "partially masks long sensitive tokens" $ do
        let tok = "ghp_1234567890abcdef"
        assertEqual "long token" "ghp_****ef" (maskSensitive "sync.token" tok)
    ]

formattingTests :: Test
formattingTests =
  testGroup
    "Time & Date Formatting"
    [ testCase "fmtSecStr formats seconds to human-readable strings" $ do
        assertEqual "0s" "0m" (fmtSecStr 0)
        assertEqual "59s" "0m" (fmtSecStr 59)
        assertEqual "60s" "1m" (fmtSecStr 60)
        assertEqual "3599s" "59m" (fmtSecStr 3599)
        assertEqual "3600s" "1h 0m" (fmtSecStr 3600)
        assertEqual "3665s" "1h 1m" (fmtSecStr 3665)
        assertEqual "7320s" "2h 2m" (fmtSecStr 7320),
      testCase "formatDate converts POSIX timestamp to YYYY-MM-DD" $ do
        assertEqual "zero date" "—" (formatDate 0)
        assertEqual "valid date" "2023-11-14" (formatDate 1700000000),
      testCase "formatRelativeTime produces accurate human intervals" $ do
        let baseTs = 1700000000
        assertEqual "zero ts" "unknown" (formatRelativeTime baseTs 0)
        assertEqual "future ts" "in the future" (formatRelativeTime baseTs (baseTs + 50))
        assertEqual "just now" "just now" (formatRelativeTime baseTs (baseTs - 30))
        assertEqual "1 minute ago" "1 minute ago" (formatRelativeTime baseTs (baseTs - 90))
        assertEqual "15 minutes ago" "15 minutes ago" (formatRelativeTime baseTs (baseTs - 900))
        assertEqual "1 hour ago" "1 hour ago" (formatRelativeTime baseTs (baseTs - 3600))
        assertEqual "2 hours ago" "2 hours ago" (formatRelativeTime baseTs (baseTs - 7200))
        assertEqual "yesterday" "yesterday" (formatRelativeTime baseTs (baseTs - 90000))
        assertEqual "3 days ago" "3 days ago" (formatRelativeTime baseTs (baseTs - 259200))
        assertEqual "1 week ago" "1 week ago" (formatRelativeTime baseTs (baseTs - 604800))
        assertEqual "2 weeks ago" "2 weeks ago" (formatRelativeTime baseTs (baseTs - 1209600))
        assertEqual "1 month ago" "1 month ago" (formatRelativeTime baseTs (baseTs - 2592000))
        assertEqual "2 months ago" "2 months ago" (formatRelativeTime baseTs (baseTs - 5184000))
        assertEqual "1 year ago" "1 years ago" (formatRelativeTime baseTs (baseTs - 31536000))
    ]

textManipulationTests :: Test
textManipulationTests =
  testGroup
    "Text Manipulation"
    [ testCase "truncateText clamps length with ellipsis" $ do
        assertEqual "within limit" "hello" (truncateText 10 "hello")
        assertEqual "exact limit" "hello" (truncateText 5 "hello")
        assertEqual "exceeds limit" "hell…" (truncateText 5 "helloworld"),
      testCase "wrapLine splits lines correctly" $ do
        assertEqual "empty text" [""] (wrapLine 10 "")
        assertEqual "single line" ["hello"] (wrapLine 10 "hello")
        assertEqual "multi chunk" ["12345", "67890", "a"] (wrapLine 5 "1234567890a")
    ]
