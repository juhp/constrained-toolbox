{-# LANGUAGE OverloadedStrings, ExtendedDefaultRules #-}

module Script (
  installScript
  )
where

import Control.Monad.Shell
import qualified Data.Text.Lazy as T
import System.Posix.IO

default (T.Text)

installScript :: Bool -> Bool -> T.Text
installScript dbg sudo =
  T.replace "\t" " " . linearScript $ do
  unlessCmd (haveCmd "runuser") $ do
    let pkgs = "util-linux" : ["sudo" | sudo]
        installargs = ["install", "-y"] ++ pkgs
    run "echo" $ T.pack "installing:" : pkgs
    ifCmd (haveCmd "dnf")
      (runHide "dnf" installargs
       -||-
       run "true" [])
      (whenCmd (haveCmd "apt-get") $
        runHide "apt-get" ["update"]
        -&&-
        runHide "apt-get" installargs
        -||-
        run "true" [])
  where
    redir s dest =
      if dbg then s else s |> (dest :: String) &stdError>&stdOutput

    runHide c args = run c args `redir` "/dev/null"

    haveCmd c = runHide "command" ["-v",c]
