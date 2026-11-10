module Test.ConfigSpec (configTests) where

import SenaVN.Handler.Config (validateConfigKey)
import Test.Framework

configTests :: Test
configTests =
  testGroup
    "SenaVN.Handler.Config"
    [ testCase "accepts valid configuration keys" $ do
        assertRight_ "sync.token" (validateConfigKey "sync.token")
        assertRight_ "core.editor" (validateConfigKey "core.editor")
        assertRight_ "fetch.proxy" (validateConfigKey "fetch.proxy")
        assertRight_ "sync.branch" (validateConfigKey "sync.branch")
        assertRight_ "alphanumeric-key_1" (validateConfigKey "alphanumeric-key_1"),
      testCase "rejects empty keys and whitespace-only keys" $ do
        assertLeft_ "empty" (validateConfigKey "")
        assertLeft_ "spaces" (validateConfigKey "   ")
        assertLeft_ "tabs" (validateConfigKey "\t\t"),
      testCase "rejects keys containing forbidden delimiter characters" $ do
        assertLeft_ "space in key" (validateConfigKey "foo bar")
        assertLeft_ "tab in key" (validateConfigKey "foo\tbar")
        assertLeft_ "equals in key" (validateConfigKey "foo=bar")
        assertLeft_ "hash in key" (validateConfigKey "foo#bar")
        assertLeft_ "semicolon in key" (validateConfigKey "foo;bar")
    ]
