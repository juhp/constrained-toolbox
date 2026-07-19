-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import Control.Monad (unless, when)
import Data.List.Extra (intercalate, splitOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing, mapMaybe)
import qualified Data.Text as T
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, doesPathExist, getHomeDirectory)
import System.Exit (exitWith)
import System.FilePath ((</>), takeFileName)
import System.IO (BufferMode(NoBuffering), hSetBuffering, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (getFileStatus, isSocket)
import System.Posix.User (getEffectiveUserName)
import System.Process (rawSystem)

import SimpleCmd (cmd_, cmdBool, cmdFull, error', warning, (+-+))
import SimpleCmdArgs

import TOML (Value(..), Table, renderTOMLError, decodeFile)

import Paths_envclave (version)

progname :: String
progname = "envclave"

data Mode = Caps | DeleteImage | List | Remove | Run | Stop
  deriving Eq

data Opts = Opts
  { mtoolbox :: Maybe String
  , vols :: [String]
  , envs :: [String]
  , paths :: [String]
  , inits :: [String]
  , caps :: [String]
  , mhome :: Maybe FilePath
  , mproject :: Maybe FilePath
  , mname :: Maybe String
  , mode :: Mode
  , keep :: Bool
  , readonly :: Bool
  , nonetwork :: Bool
  , nosudo :: Bool
  , unique :: Bool
  , podmanopts :: [String]
  , debugging :: Bool
  , dryrun :: Bool
  , refresh :: Bool
  , command :: [String]
  }

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  simpleCmdArgs (Just version)
    "envclave"
    "Run a toolbox image in an isolated podman container" $
    run <$>
    (Opts
    <$> optional (argumentWith str "TOOLBOX")
    <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "Bind mounts (default to selinux :z)")
    <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "Set or pass through an environment variables")
    <*> many (strOptionWith 'P' "path" "DIR" "Prepend a directory to PATH inside the container")
    <*> many (strOptionWith 'i' "init" "CMD" "Run a bash snippet before entering the container")
    <*> many (strOptionLongWith "cap" "NAME" "Enable a capability from the config file")
    <*> optional (strOptionLongWith "home" "DIR" "Mount a directory as a writable home (created if missing)")
    <*> optional (strOptionWith 'p' "project" "DIR" "Mount a project directory and set as workdir")
    <*> optional (strOptionWith 'n' "name" "NAME" "Container name (for creating or joining)")
    <*> (flagLongWith' Caps "caps" "List available capabilities from the config file" <|>
         flagLongWith' List "list" "List envclave images and containers" <|>
         flagLongWith' Remove "remove" "Remove the container" <|>
         flagLongWith' DeleteImage "delete-image" "Remove the image" <|>
         flagLongWith Run Stop "stop" "Stop the container")
    <*> switchLongWith "keep" "Keep the container after exiting"
    <*> switchLongWith "readonly" "Make the container filesystem read-only"
    <*> switchLongWith "no-network" "Disable network access"
    <*> switchLongWith "no-sudo" "Skip passwordless sudo setup"
    <*> switchLongWith "unique" "Run a new container even if one is already running"
    <*> many (strOptionLongWith "podman-opt" "OPTION" "Pass an option directly to podman")
    <*> switchLongWith "debug" "Show debug output"
    <*> switchLongWith "dryrun" "Print the podman command instead of running it"
    <*> switchLongWith "refresh" "Force re-commit of the toolbox image"
    <*> many (argumentWith str "CMD"))

run :: Opts -> IO ()
run (Opts {..})
  | mode == Caps = do
      config <- loadConfig
      let capabilities = getCapabilities config
      if Map.null capabilities
        then putStrLn "No capabilities defined"
        else do
          putStrLn "Available capabilities:"
          mapM_ (putStrLn . ("  " ++) . T.unpack) $ Map.keys capabilities
  | mode == List = do
      cmd_ "podman" ["images",
                     "--filter", "reference=" ++ progname ++ "-*",
                     "--format", "{{.Repository}}  {{.Size}}  {{.Created}}"]
      cmd_ "podman" ["ps", "-a",
                     "--filter", "name=^" ++ progname ++ "-",
                     "--format", "{{.Names}}  {{.Status}}"]
  | mode == DeleteImage =
      removeImage (progname ++ "-" ++ containerBase)
  | mode == Remove = do
      exists <- cmdBool "podman" ["container", "exists", containerName]
      if exists
        then do
          (_, out, _) <- cmdFull "podman"
            ["container", "inspect", "-f", "{{.State.Running}}", containerName] ""
          when (take 4 out == "true") $ do
            putStr "stopping "
            cmd_ "podman" ["stop", containerName]
          putStr "rm "
          cmd_ "podman" ["rm", containerName]
        else warning $ "container" +-+ containerName +-+ "not found"
  | mode == Stop = do
      exists <- cmdBool "podman" ["container", "exists", containerName]
      if exists
        then do
          putStr "stop "
          cmd_ "podman" ["stop", containerName]
        else warning $ "container" +-+ containerName +-+ "not found"
  | otherwise = do
      container <-
        if unique
        then do
          pid <- getProcessID
          return $ containerName ++ "-" ++ show pid
        else return containerName
      debug $ "container:" +-+ container
      running <-
        if unique
        then return False
        else do
          exists <- cmdBool "podman" ["container", "exists", container]
          debug $ container +-+ "exists"
          if exists
            then do
              (_, out, _) <- cmdFull "podman"
                ["container", "inspect", "-f", "{{.State.Running}}", container] ""
              if take 4 out == "true"
                then return True
                else do
                putStr "start "
                cmd_ "podman" ["start", container]
                return True
            else return False
      if running
        then do
          let noopts = and
                [ null vols
                , null envs
                , null paths
                , null inits
                , null caps
                , isNothing mproject
                , isNothing mhome
                , not keep
                , not readonly
                , not nonetwork
                , not nosudo
                , null podmanopts
                , not refresh
                ]
          unless noopts $
            error' "cannot give options for an existing container!"
          warning "Joining existing container"
          home <- getHomeDirectory
          username <- getEffectiveUserName
          let userCmd = if null command then ["bash"] else command
              execCmd = ["podman", "exec", "-it", container,
                         "runuser", "-u", username, "--",
                         "env", "HOME=" ++ home] ++ userCmd
          if dryrun
            then putStrLn $ unwords (map shellQuote execCmd)
            else do
              ret <- rawSystem "podman" (drop 1 execCmd)
              exitWith ret
        else do
          case mtoolbox of
            Nothing ->
              when (isNothing mtoolbox) $
              error' $ "TOOLBOX argument needed to create a container" +-+
              if isJust mname then "(use '--name ^...' to reference a full container name)" else ""
            Just toolbox -> createContainer toolbox container
  where
    createContainer toolbox container = do
      mprojectDir <-
        case mproject of
          Just dir -> Just <$> (expandPath dir >>= canonicalizePath)
          Nothing -> return Nothing
      mhomeDir <-
        case mhome of
          Just dir -> Just <$> (expandPath dir >>= canonicalizePath)
          Nothing -> return Nothing
      let isImage = ':' `elem` toolbox
      debug $ if isImage then "image:" +-+ toolbox
              else "toolbox:" +-+ toolbox
      image <- if isImage
               then return toolbox
               else commitToolbox toolbox refresh
      config <- loadConfig
      let capabilities = getCapabilities config

      (extraVols, extraEnvs, extraPaths, extraInits, extraSecurityOpts) <-
        resolveCapabilities capabilities caps

      home <- getHomeDirectory
      username <- getEffectiveUserName

      homeVol <-
        case mhomeDir of
          Just d -> do
            createDirectoryIfMissing True d
            return [d ++ ":" ++ home]
          Nothing -> return []

      let projectVol =
            case mprojectDir of
              Just d -> [d ++ ":" ++ rootDest d]
              Nothing -> []
          volumes = homeVol ++ vols ++ extraVols ++ projectVol
          envVars = envs ++ extraEnvs
          allpaths = paths ++ extraPaths
          allinits = inits ++ extraInits

      let envParts = ("HOME=" ++ shellQuote home) : pathEnvPart allpaths
          initSetup = mkInitSetup allinits
          userCmdParts = mkUserCmd command allinits
          runuserCmd = "env" +-+ unwords (envParts ++ map shellQuote userCmdParts)
          sudoers = "/etc/sudoers.d" </> progname
          installSetup =
            ["(command -v runuser >/dev/null 2>&1 || dnf install -y util-linux sudo >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 && apt-get install -y util-linux sudo >/dev/null 2>&1 || true)" | isImage]
          sudoSetup =
            if nosudo
            then ["rm -f /usr/bin/sudo"]
            else ["echo" +-+ shellQuote (username +-+ "ALL=(ALL) NOPASSWD:ALL")
                  +-+ ">" +-+ sudoers,
                  "chmod 440" +-+ sudoers]
          homeSetup =
            if isNothing mhome
            then ["mkdir -p" +-+ shellQuote home,
                  "chown" +-+ username +-+ shellQuote home]
            else []
          fallback =
            if isImage
            then " || exec" +-+ runuserCmd
            else ""
          trace = ["set -x" | debugging]
          setup = intercalate " && "
                  (trace ++ installSetup ++ sudoSetup ++ homeSetup ++
                  [initSetup | not (null allinits)] ++
                  ["exec runuser -u" +-+ username +-+ "--" +-+ runuserCmd])
                  ++ fallback

      debug $ "setup:" +-+ setup
      mounts <- mapM addSelinuxLabel volumes

      let workdirPart =
            case mprojectDir of
              Just d -> ["--workdir", rootDest d]
              Nothing | not isImage -> ["--workdir", home]
                      | otherwise -> []
          args = "run" :
                 [ "--rm" | not keep] ++
                 [ "-it", "--userns=keep-id",
                 "--name", container, "--hostname", container,
                 "--user", "root", "-e", "HOME=" ++ home,
                 "-e", "TERM", "-e", "COLORTERM"]
                ++ workdirPart
                ++ (if readonly
                    then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                         ++ case mhomeDir of
                              Nothing -> ["--tmpfs", home]
                              Just _ -> []
                    else [])
                ++ (if nonetwork then ["--net", "none"] else [])
                ++ concatMap (\s -> ["--security-opt", s]) extraSecurityOpts
                ++ concatMap (\m -> ["-v", m]) mounts
                ++ concatMap (\e -> ["-e", e]) envVars
                ++ podmanopts
                ++ [image, "sh", "-c", setup]

      if dryrun
        then putStrLn $ unwords $ "podman" : map shellQuote args
        else do
          ret <- rawSystem "podman" args
          exitWith ret

    containerBase =
      case mtoolbox of
        Just toolbox ->
          map (\c -> if c == ':' then '-' else c) toolbox
        Nothing -> error' "no TOOLBOX arg given"

    containerName =
      case mname of
        Just ('^':n) -> n
        Just n -> progname ++ "-" ++ n
        Nothing -> progname ++ "-" ++ containerBase

    debug msg = when debugging $ warning $ "debug:" +-+ msg

-- image management

commitToolbox :: String -> Bool -> IO String
commitToolbox toolbox refresh = do
  let image = progname ++ '-' : toolbox
  imageExists <- cmdBool "podman" ["image", "exists", image]
  if imageExists && not refresh
    then return image
    else do
      containerExists <- cmdBool "podman" ["container", "exists", toolbox]
      if containerExists
        then do
        putStr "writing image "
        ok <- cmdBool "buildah"
              ["commit", "--disable-compression", toolbox, image]
        if ok
          then return image
          else error' $ "could not commit image of container" +-+ toolbox
        else error' $ "container '" ++ toolbox ++ "' not found"

removeImage :: String -> IO ()
removeImage image = do
  putStr "rmi "
  cmd_ "podman" ["rmi", image]

-- config

configPath :: IO FilePath
configPath = do
  home <- getHomeDirectory
  return $ home </> ".config" </> progname </> "config.toml"

loadConfig :: IO (Maybe Table)
loadConfig = do
  path <- configPath
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      result <- decodeFile path
      case result of
        Left e -> error' $ "config parse error:" +-+ T.unpack (renderTOMLError e)
        Right table -> return (Just table)

getCapabilities :: Maybe Table -> Table
getCapabilities Nothing = Map.empty
getCapabilities (Just table) =
  case Map.lookup (T.pack "capabilities") table of
    Just (Table t) -> t
    _ -> Map.empty

resolveCapabilities :: Table -> [String] -> IO ([String], [String], [String], [String], [String])
resolveCapabilities caps capNames = do
  results <- mapM (resolveCap caps) capNames
  let (vs, es, ps, is, ss) = unzip5 results
  return (concat vs, concat es, concat ps, concat is, concat ss)
  where
    unzip5 = foldr (\(a,b,c,d,e) (as,bs,cs,ds,es) -> (a:as,b:bs,c:cs,d:ds,e:es))
                   ([],[],[],[],[])

resolveCap :: Table -> String -> IO ([String], [String], [String], [String], [String])
resolveCap caps name =
  case Map.lookup (T.pack name) caps of
    Just (Table cap) ->
      return ( getStringList "volumes" cap
             , getStringList "env" cap
             , getStringList "path" cap
             , case getStringVal "init" cap of
                 Just s -> [s]
                 Nothing -> []
             , getStringList "security_opts" cap
             )
    _ -> do
      let available = if Map.null caps
                      then "(none defined)"
                      else intercalate ", " $ map T.unpack $ Map.keys caps
      error' $ "unknown capability '" ++ name ++ "'. Available:" +-+ available

getStringList :: String -> Table -> [String]
getStringList key table =
  case Map.lookup (T.pack key) table of
    Just (Array arr) -> mapMaybe valueToString arr
    _ -> []

getStringVal :: String -> Table -> Maybe String
getStringVal key table =
  case Map.lookup (T.pack key) table of
    Just (String t) -> Just (T.unpack t)
    _ -> Nothing

valueToString :: Value -> Maybe String
valueToString (String t) = Just (T.unpack t)
valueToString _ = Nothing

-- SELinux labeling

addSelinuxLabel :: String -> IO String
addSelinuxLabel spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      hostExp <- expandPath hostPart
      sockFile <- isSocketFile hostExp
      return $ hostExp ++ ":" ++ hostExp ++ if sockFile then "" else ":z"
    (hostPart, _:rest') -> do
      hostExp <- expandPath hostPart
      let (containerPart, optsPart)
            | isPathStart rest' =
                case break (== ':') rest' of
                  (c, [])  -> (c, Nothing)
                  (c, _:o) -> (c, Just o)
            | otherwise = (hostExp, if null rest' then Nothing else Just rest')
      containerExp <- expandPath containerPart
      sockFile <- isSocketFile hostExp
      let labeled = case optsPart of
            Nothing ->
              if sockFile
              then hostExp ++ ":" ++ containerExp
              else hostExp ++ ":" ++ containerExp ++ ":z"
            Just o ->
              let flags = splitOn "," o
              in if sockFile || "z" `elem` flags || "Z" `elem` flags
                 then hostExp ++ ":" ++ containerExp ++ ":" ++ o
                 else hostExp ++ ":" ++ containerExp ++ ":" ++ o ++ ",z"
      return labeled
  where
    isPathStart ('/':_) = True
    isPathStart ('~':_) = True
    isPathStart ('$':_) = True
    isPathStart _       = False

isSocketFile :: FilePath -> IO Bool
isSocketFile path = do
  exists <- doesPathExist path
  if exists
    then isSocket <$> getFileStatus path
    else return False

-- path and env expansion

rootDest :: FilePath -> FilePath
rootDest dir = '/' : takeFileName dir

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
  in "printf" +-+ shellQuote content +-+ "> /tmp" </> progname ++ "-init.sh"

mkUserCmd :: [String] -> [String] -> [String]
mkUserCmd [] inits = mkUserCmd ["bash"] inits
mkUserCmd ["bash"] (_:_) =
  ["bash", "--rcfile", "/tmp" </> progname ++ "-init.sh"]
mkUserCmd cmd inits@(_:_) =
  let initChain = intercalate " && " inits
      cmdStr = initChain +-+ "&& exec" +-+ unwords (map shellQuote cmd)
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
