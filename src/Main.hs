-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.List.Extra (intercalate, splitOn, unzip4)
import qualified Data.HashMap.Strict as HM
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import System.Directory (canonicalizePath, doesFileExist, getHomeDirectory)
import System.FilePath ((</>), takeFileName)
import System.Posix.Process (getProcessID)
import System.Posix.Env (getEnvDefault)
import System.Posix.User (getEffectiveUserName)

import SimpleCmd (cmd_, cmdBool, cmdFull, cmdSilent, error')
import SimpleCmdArgs

import Text.Toml (parseTomlDoc)
import Text.Toml.Types (Node(..), Table)

import Paths_constrained_toolbox (version)

main :: IO ()
main =
  simpleCmdArgs (Just version)
  "constrained-toolbox"
  "Run a toolbox image in an isolated podman container" $
  run
  <$> argumentWith str "TOOLBOX"
  <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "bind mount (repeatable)")
  <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "set or pass through an environment variable (repeatable)")
  <*> many (strOptionWith 'P' "path" "DIR" "prepend a directory to PATH inside the container (repeatable)")
  <*> many (strOptionWith 'i' "init" "CMD" "run a bash snippet before entering the container (repeatable)")
  <*> many (strOptionLongWith "cap" "NAME" "enable a capability from the config file (repeatable)")
  <*> optional (strOptionWith 'p' "project" "DIR" "mount a project directory (default: cwd) and set as workdir")
  <*> switchLongWith "readonly" "make the container filesystem read-only"
  <*> switchLongWith "dryrun" "print the podman command instead of running it"
  <*> switchLongWith "refresh" "force re-commit of the toolbox image"
  <*> switchLongWith "delete" "remove the committed image after running"
  <*> many (argumentWith str "CMD")

run :: String -> [String] -> [String] -> [String] -> [String] -> [String]
    -> Maybe String -> Bool -> Bool -> Bool -> Bool -> [String] -> IO ()
run toolbox vols envs paths inits caps mproject readonly dryrun refresh delete command = do
  mprojectDir <-
    case mproject of
      Just dir -> Just <$> (expandPath dir >>= canonicalizePath)
      Nothing -> return Nothing
  image <- commitToolbox toolbox refresh delete
  config <- loadConfig
  let capabilities = getCapabilities config

  (extraVols, extraEnvs, extraPaths, extraInits) <-
    resolveCapabilities capabilities caps

  let projectVol =
        case mprojectDir of
          Just d -> [d ++ ":" ++ '/' : takeFileName d]
          Nothing -> []
      volumes = vols ++ extraVols ++ projectVol
      envVars = envs ++ extraEnvs
      allpaths = paths ++ extraPaths
      allinits = inits ++ extraInits

  home <- getHomeDirectory
  username <- getEffectiveUserName

  let envParts = ("HOME=" ++ shellQuote home) : pathEnvPart allpaths
      initSetup = mkInitSetup allinits
      userCmdParts = mkUserCmd command allinits
      runuserCmd = "env " ++ unwords (envParts ++ map shellQuote userCmdParts)
      setup = "echo " ++ shellQuote (username ++ " ALL=(ALL) NOPASSWD:ALL")
              ++ " > /etc/sudoers.d/toolbox-constrained"
              ++ " && chmod 440 /etc/sudoers.d/toolbox-constrained"
              ++ initSetup
              ++ " && exec runuser -u " ++ username ++ " -- " ++ runuserCmd

  mounts <- mapM addSelinuxLabel volumes

  let workdirPart =
        case mprojectDir of
          Just d -> ["--workdir", '/' : takeFileName d]
          Nothing -> []
      cmd = ["podman", "run", "--rm", "-it", "--userns=keep-id",
             "--user", "root", "-e", "HOME=" ++ home]
            ++ workdirPart
            ++ (if readonly
                then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                else [])
            ++ concatMap (\m -> ["-v", m]) mounts
            ++ concatMap (\e -> ["-e", e]) envVars
            ++ [image, "sh", "-c", setup]

  if dryrun
    then putStrLn $ unwords (map shellQuote cmd)
    else do
      let cleanup = when delete $ removeImage image
      flip finally cleanup $
        cmd_ "podman" (drop 1 cmd)

-- image management

commitToolbox :: String -> Bool -> Bool -> IO String
commitToolbox toolbox refresh delete = do
  let baseImage = "toolbox-constrained-" ++ toolbox
  image <-
    if delete
    then do
      pid <- getProcessID
      return $ baseImage ++ "-" ++ show pid
    else return baseImage
  exists <- cmdBool "podman" ["image", "exists", image]
  if exists && not refresh
    then return image
    else do
      (ok, _, err) <- cmdFull "buildah"
                      ["commit", "--disable-compression", toolbox, image] ""
      if ok
        then return image
        else error' $ "could not commit toolbox container '"
             ++ toolbox ++ "': " ++ err

removeImage :: String -> IO ()
removeImage image = cmdSilent "podman" ["rmi", image]

-- config

configPath :: IO FilePath
configPath = do
  home <- getHomeDirectory
  return $ home </> ".config/toolbox-constrained/config.toml"

loadConfig :: IO (Maybe Table)
loadConfig = do
  path <- configPath
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      content <- T.readFile path
      case parseTomlDoc path content of
        Left e -> error' $ "config parse error: " ++ show e
        Right table -> return (Just table)

getCapabilities :: Maybe Table -> Table
getCapabilities Nothing = HM.empty
getCapabilities (Just table) =
  case HM.lookup (T.pack "capabilities") table of
    Just (VTable t) -> t
    _ -> HM.empty

resolveCapabilities :: Table -> [String] -> IO ([String], [String], [String], [String])
resolveCapabilities caps capNames = do
  results <- mapM (resolveCap caps) capNames
  let (vs, es, ps, is) = unzip4 results
  return (concat vs, concat es, concat ps, concat is)

resolveCap :: Table -> String -> IO ([String], [String], [String], [String])
resolveCap caps name =
  case HM.lookup (T.pack name) caps of
    Just (VTable cap) ->
      return ( getStringList "volumes" cap
             , getStringList "env" cap
             , getStringList "path" cap
             , case getStringVal "init" cap of
                 Just s -> [s]
                 Nothing -> []
             )
    _ -> do
      let available = if HM.null caps
                      then "(none defined)"
                      else intercalate ", " $ map T.unpack $ HM.keys caps
      error' $ "unknown capability '" ++ name ++ "'. Available: " ++ available

getStringList :: String -> Table -> [String]
getStringList key table =
  case HM.lookup (T.pack key) table of
    Just (VArray arr) -> mapMaybe nodeToString (V.toList arr)
    _ -> []

getStringVal :: String -> Table -> Maybe String
getStringVal key table =
  case HM.lookup (T.pack key) table of
    Just (VString t) -> Just (T.unpack t)
    _ -> Nothing

nodeToString :: Node -> Maybe String
nodeToString (VString t) = Just (T.unpack t)
nodeToString _ = Nothing

-- SELinux labeling

addSelinuxLabel :: String -> IO String
addSelinuxLabel spec =
  case break (== ':') spec of
    (_, []) -> error' $ "invalid mount spec '" ++ spec ++ "', expected HOST:CONTAINER[:opts]"
    (hostPart, _:rest') -> do
      let (containerPart, optsPart) =
            case break (== ':') rest' of
              (c, []) -> (c, Nothing)
              (c, _:o) -> (c, Just o)
      hostExp <- expandPath hostPart
      containerExp <- expandPath containerPart
      let labeled = case optsPart of
            Nothing -> hostExp ++ ":" ++ containerExp ++ ":z"
            Just o ->
              let flags = splitOn "," o
              in if "z" `elem` flags || "Z" `elem` flags
                 then hostExp ++ ":" ++ containerExp ++ ":" ++ o
                 else hostExp ++ ":" ++ containerExp ++ ":" ++ o ++ ",z"
      return labeled

-- path and env expansion

expandPath :: String -> IO String
expandPath ('~':'/':rest) = do
  home <- getHomeDirectory
  rest' <- expandEnvVars rest
  return $ home </> rest'
expandPath "~" = getHomeDirectory
expandPath s = expandEnvVars s

expandEnvVars :: String -> IO String
expandEnvVars [] = return []
expandEnvVars ('$':'{':rest) =
  case break (== '}') rest of
    (var, '}':after) -> do
      val <- getEnvDefault var ""
      rest' <- expandEnvVars after
      return (val ++ rest')
    _ -> do
      rest' <- expandEnvVars rest
      return ("${" ++ rest')
expandEnvVars ('$':rest) =
  let (var, after) = span isVarChar rest
  in if null var
     then do
       rest' <- expandEnvVars rest
       return ('$' : rest')
     else do
       val <- getEnvDefault var ""
       rest' <- expandEnvVars after
       return (val ++ rest')
  where
    isVarChar c = c `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_")
expandEnvVars (c:rest) = do
  rest' <- expandEnvVars rest
  return (c : rest')

-- shell command construction

pathEnvPart :: [String] -> [String]
pathEnvPart [] = []
pathEnvPart ps =
  let prefix = intercalate ":" ps
  in ["PATH=\"" ++ prefix ++ ":$PATH\""]

mkInitSetup :: [String] -> String
mkInitSetup [] = ""
mkInitSetup snippets =
  let content = intercalate "\\n" snippets
  in " && printf " ++ shellQuote content ++ " > /tmp/toolbox-constrained-init.sh"

mkUserCmd :: [String] -> [String] -> [String]
mkUserCmd [] inits = mkUserCmd ["bash"] inits
mkUserCmd ["bash"] (_:_) =
  ["bash", "--rcfile", "/tmp/toolbox-constrained-init.sh"]
mkUserCmd cmd inits@(_:_) =
  let initChain = intercalate " && " inits
      cmdStr = initChain ++ " && exec " ++ unwords (map shellQuote cmd)
  in ["sh", "-c", cmdStr]
mkUserCmd cmd [] = cmd

-- utilities

shellQuote :: String -> String
shellQuote s
  | all isSafe s = s
  | otherwise = "'" ++ concatMap escSQ s ++ "'"
  where
    isSafe c = c `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "-_./=:@,+")
    escSQ '\'' = "'\\''"
    escSQ c = [c]
