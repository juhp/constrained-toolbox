{-# LANGUAGE OverloadedStrings, ExtendedDefaultRules #-}

module Script (
  installScript
  )
where

import Control.Monad.Shell
import qualified Data.Text.Lazy as T
import System.Posix.IO

default (T.Text)

installScript :: Bool -> T.Text
installScript dbg =
  T.replace "\t" " " . linearScript $ do
  unlessCmd (haveCmd "runuser") $ do
    ifCmd (haveCmd "dnf")
      (runHide "dnf" ["install", "-y", "util-linux", "sudo"]
       -||-
       run "true" [])
      (whenCmd (haveCmd "apt-get") $
        runHide "apt-get" ["update"]
        -&&-
        runHide "apt-get" ["install", "-y", "util-linux", "sudo"]
        -||-
        run "true" [])
  where
    redir s dest =
      if dbg then s else s |> (dest :: String) &stdError>&stdOutput

    runHide c args = run c args `redir` "/dev/null"

    haveCmd c = runHide "command" ["-v",c]
