-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import Control.Monad (unless, when, (>=>))
import Data.List.Extra (intercalate, splitOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, doesPathExist, getHomeDirectory)
import System.Environment.XDG.BaseDir (getUserConfigFile)
import System.Exit (exitWith)
import System.FilePath ((</>), takeFileName)
import System.IO (BufferMode(NoBuffering), hSetBuffering, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (getFileStatus, isSocket)
import System.Posix.User (getEffectiveUserName)
import System.Process (rawSystem)
import SimpleCmd (cmd_, cmdBool, cmdFull, cmdLines, error', warning, (+-+))
import SimpleCmdArgs
import TOML (Value(..), Table, renderTOMLError, decodeFile)

import Paths_encapsule (version)
import Script

progname :: String
progname = "encapsule"

-- FIXME maybe rename to Workdir?
data ProjectName = Project FilePath | Name String

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  simpleCmdArgs (Just version)
    progname
    "Run a toolbox image in an isolated podman container" $
    subcommands
    -- FIXME add/separate: create/enter/run
    [ Subcommand "list" "List encapsule images and containers" $
      pure listCmd
    , Subcommand "list-caps" "List encapsule images and containers" $
      pure listCapsCmd
    , Subcommand "rm" "Remove an encapsule container" $
      removeCmd
      <$> toolboxArg
      <*> optional projectNameOpt
    , Subcommand "rmi" "Remove an encapsule image" $
      removeImageCmd
      <$> dryrunOpt
      <*> toolboxArg
    , Subcommand "stop" "Stop an encapsule container" $
      stopCmd
      <$> toolboxArg
      <*> optional projectNameOpt
    , Subcommand "enter" "Connect to a (running) encapsule container" $
      enterCmd
      <$> optional toolboxArg
      <*> optional projectNameOpt
    , Subcommand "run" "Run an encapsule container" $
    runCmd <$>
    (RunOpts
    <$> toolboxArg
    <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "Bind mounts (default to selinux :z)")
    <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "Set or pass through an environment variable")
    <*> many (strOptionWith 'P' "path" "DIR" "Prepend a directory to PATH inside the container")
    <*> many (strOptionWith 'i' "init" "CMD" "A bash snippet run when creating the encapsule container")
    <*> many (strOptionLongWith "cap" "NAME" "Enable a capability from the config file")
    <*> optional (strOptionLongWith "home" "DIR" "Mount a directory as a writable home (created if missing)")
    <*> optional (projectOpt "Mount a (project) directory as a workdir")
    <*> optional nameOpt
    <*> switchLongWith "keep" "Keep the encapsule container after exiting"
    <*> switchLongWith "readonly" "Make the encapsule container filesystem read-only"
    <*> switchLongWith "no-network" "Disable network access"
    <*> switchLongWith "no-sudo" "Skip passwordless sudo setup"
    <*> switchLongWith "unique" "Run a new encapsule container even if one is already running"
    <*> many (strOptionLongWith "podman-opt" "OPTION" "Pass an option directly to podman")
    <*> switchLongWith "debug" "Show debug output"
    <*> dryrunOpt
    <*> switchLongWith "refresh" "Force re-commit of the toolbox image"
    <*> many (argumentWith str "CMD")
    )
    ]
  where
    dryrunOpt = switchLongWith "dryrun" "Print the podman command instead of running it"

    projectOpt desc = strOptionWith 'w' "workdir" "DIR" desc

    nameOpt = strOptionWith 'n' "name" "NAME" "Optional container name (prefix with '^' prefix to skip 'encapsule-' prefix)"

    projectNameOpt = Project <$> projectOpt "Project name or path" <|>
                     Name <$> nameOpt

    toolboxArg = argumentWith str "TOOLBOX"

listCmd :: IO ()
listCmd = do
  cmd_ "podman" ["images",
                 "--filter", "reference=" ++ progname ++ "-*",
                 "--format", "{{.Repository}}  {{.Size}}  {{.Created}}"]
  cmd_ "podman" ["ps", "-a",
                 "--filter", "name=^" ++ progname ++ "-",
                 "--format", "{{.Names}}  {{.Status}}"]

listCapsCmd :: IO ()
listCapsCmd = do
  config <- loadConfig
  let capabilities = getCapabilities config
  if Map.null capabilities
    then putStrLn "No capabilities defined"
    else do
      putStrLn "Available capabilities:"
      mapM_ (putStrLn . ("  " ++) . T.unpack) $ Map.keys capabilities

removeCmd :: String -> Maybe ProjectName -> IO ()
removeCmd toolbox mprojectname = do
  containerName <- mkContainerName toolbox mprojectname
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

removeImageCmd :: Bool -> String -> IO ()
removeImageCmd dryrun name =
  when dryrun $
  removeImage (progname ++ "-" ++ containerBase name)

-- FIXME dryrun
stopCmd :: String -> Maybe ProjectName -> IO ()
stopCmd name mprojectname = do
  containerName <- mkContainerName name mprojectname
  exists <- cmdBool "podman" ["container", "exists", containerName]
  if exists
    then do
      putStr "stop "
      cmd_ "podman" ["stop", containerName]
    else warning $ "container" +-+ containerName +-+ "not found"

-- FIXME dryrun
enterCmd :: Maybe String -> Maybe ProjectName -> IO ()
enterCmd mbase mprojectname = do
  regexp <-
    case mprojectname of
      Nothing -> return $ '^' : progname ++ "-"
      Just (Name n) -> return $ '^' : progname ++ '-' : n
      Just (Project p) -> do
        projectDir <- resolveProject p
        return $ progname ++ '-' : fromMaybe ".*" mbase ++ '-' : workProjectName projectDir
  ps <- cmdLines "podman" $ "ps" :
        ["--filter", "name=" ++ regexp,
         "--format", "{{.Names}}"]
  case ps of
    [] -> error' "no encapsule containers running"
    [c] -> enterContainer False c []
    _ -> error' $ "multiple running containers match:\n" ++ unlines ps

    -- FIXME lost starting up a stopped exact match
    -- Just base -> do
    --   containerName <- mkContainerName base mprojectname
    --   exists <- cmdBool "podman" ["container", "exists", containerName]
    --   if not exists
    --     then do
    --     ps <- cmdLines "podman" $ "ps" :
    --           ["--filter", "name=^" ++ containerName,
    --            "--format", "{{.Names}}"]
    --     case ps of
    --       [] -> error' $ "container" +-+ containerName +-+ "not found"
    --       [c] -> enterContainer False c []
    --       _ -> error' $ "multiple containers match:\n" ++ unlines ps
    --     else do
    --       (_, out, _) <- cmdFull "podman"
    --         ["container", "inspect", "-f", "{{.State.Running}}", containerName] ""
    --       unless (take 4 out == "true") $ do
    --         putStr "start "
    --         cmd_ "podman" ["start", containerName]
    --       enterContainer False containerName []

enterContainer :: Bool -> String -> [String] -> IO ()
enterContainer dryrun container command = do
  homedir <- getHomeDirectory >>= canonicalizePath
  username <- getEffectiveUserName
  let userCmd = if null command then ["bash"] else command
      execCmd = ["podman", "exec", "-it", container,
                 "runuser", "-u", username, "--",
                 "env", "HOME=" ++ homedir] ++ userCmd
  if dryrun
    then putStrLn $ unwords (map shellQuote execCmd)
    else do
      ret <- rawSystem "podman" (drop 1 execCmd)
      exitWith ret

data RunOpts = RunOpts
  { toolbox :: String
  , vols :: [String]
  , envs :: [String]
  , paths :: [String]
  , inits :: [String]
  , caps :: [String]
  , mhome :: Maybe FilePath
  , mproject :: Maybe FilePath
  , mname :: Maybe String
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

runCmd :: RunOpts -> IO ()
runCmd (RunOpts {..}) = do
  mprojectDir <- traverse resolveProject mproject
  containerName <-
    mkContainerName toolbox $ maybe (Project <$> mproject) (Just . Name) mname
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
  homedir <- getHomeDirectory >>= canonicalizePath
  debug $ "HOME:" +-+ homedir
  if running
    then do
      let noopts = and
            [ null vols
            , null envs
            , null paths
            , null inits
            , null caps
            , isNothing mproject || isNothing mname
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
      warning "Entering existing container"
      enterContainer dryrun container command
    else createContainer homedir mprojectDir container
  where
    createContainer homedir mprojectDir container = do
      mtemphome <- traverse (expandPath homedir >=> canonicalizePath) mhome
      let isImage = ':' `elem` toolbox
      debug $ if isImage then "image:" +-+ toolbox
              else "toolbox:" +-+ toolbox
      image <- if isImage
               then return toolbox
               else commitToolbox dryrun toolbox refresh
      config <- loadConfig
      let capabilities = getCapabilities config

      (extraVols, extraEnvs, extraPaths, extraInits, extraSecurityOpts) <-
        resolveCapabilities capabilities caps

      homeVol <-
        case mtemphome of
          Just temphome -> do
            createDirectoryIfMissing True homedir
            return [temphome ++ ":" ++ homedir]
          Nothing -> return []

      username <- getEffectiveUserName

      let projectVol =
            case mprojectDir of
              Just d -> [d ++ ':' : d]
              Nothing -> []
          volumes = homeVol ++ vols ++ extraVols ++ projectVol
          envVars = envs ++ extraEnvs
          allpaths = paths ++ extraPaths
          allinits = inits ++ extraInits

          envParts = ("HOME=" ++ homedir) : pathEnvPart allpaths
          initSetup = mkInitSetup allinits
          userCmdParts = mkUserCmd command allinits
          runuserCmd = "env" +-+ unwords (envParts ++ map shellQuote userCmdParts)

          sudoers = "/etc/sudoers.d" </> progname
          installSetup =
            [TL.unpack $ installScript debugging (not nosudo) | isImage]
          sudoSetup =
            if nosudo
            then ["rm -f /usr/bin/sudo"]
            else ["echo" +-+ shellQuote (username +-+ "ALL=(ALL) NOPASSWD:ALL")
                  +-+ ">" +-+ sudoers,
                  "chmod 440" +-+ sudoers]
          homeSetup =
            if isNothing mhome
            then ["mkdir -p" +-+ homedir,
                  "chown" +-+ username +-+ homedir]
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
      mounts <- mapM (addSelinuxLabel homedir) volumes

      let workdirPart =
            case mprojectDir of
              Just d -> ["--workdir", d]
              Nothing | not isImage -> ["--workdir", homedir]
                      | otherwise -> []
          args = "run" :
                 [ "--rm" | not keep] ++
                 [ "-it", "--userns=keep-id",
                   "--name", container, "--hostname", container,
                   "--user", "root", "-e", "HOME=" ++ homedir,
                   "-e", "TERM", "-e", "COLORTERM"]
                ++ workdirPart
                ++ (if readonly
                    then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                         ++ case mtemphome of
                              Nothing -> ["--tmpfs", homedir]
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

    debug msg = when debugging $ warning $ "debug:" +-+ msg

-- image management

containerBase :: String -> String
containerBase = map (\c -> if c == ':' then '-' else c)

commitToolbox :: Bool -> String -> Bool -> IO String
commitToolbox dryrun toolbox refresh = do
  let image = progname ++ '-' : toolbox
  imageExists <- cmdBool "podman" ["image", "exists", image]
  if imageExists && not refresh
    then return image
    else do
      containerExists <- cmdBool "podman" ["container", "exists", toolbox]
      if containerExists
        then do
        ok <-
          if dryrun then return True
          else do
            putStr "writing image "
            cmdBool "buildah"
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
configPath = getUserConfigFile progname "config.toml"

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

-- FIXME rather return Mount type or triple?
addSelinuxLabel :: FilePath -> String -> IO String
addSelinuxLabel homedir spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      hostExp <- expandPath homedir hostPart
      sockFile <- isSocketFile hostExp
      return $ hostExp ++ ":" ++ hostExp ++ if sockFile then "" else ":z"
    (hostPart, _:rest') -> do
      hostExp <- expandPath homedir hostPart
      let (containerPart, optsPart)
            | isPathStart rest' =
                case break (== ':') rest' of
                  (c, [])  -> (c, Nothing)
                  (c, _:o) -> (c, Just o)
            | otherwise = (hostExp, if null rest' then Nothing else Just rest')
      containerExp <- expandPath homedir containerPart
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

expandPath :: FilePath -> String -> IO FilePath
expandPath homedir ('~':'/':rest) = do
  rest' <- expandEnvVars rest
  canonicalizePath $ homedir </> rest'
expandPath homedir "~" = return homedir
expandPath _ s = expandEnvVars s

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

resolveProject :: FilePath -> IO FilePath
resolveProject dir = do
  homedir <- getHomeDirectory >>= canonicalizePath
  finaldir <- expandPath homedir dir >>= canonicalizePath
  when (finaldir == homedir) $
    error' "mounting $HOME not supported!"
  return finaldir

-- container naming

sanitizeName :: String -> String
sanitizeName = map (\c -> if c `elem` nameChars then c else '-')
  where
    nameChars = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_.-"

workProjectName :: FilePath -> String
workProjectName = sanitizeName . takeFileName

mkContainerName :: String -> Maybe ProjectName -> IO String
mkContainerName base mprojectname = do
  case mprojectname of
    Nothing -> return $ progname ++ '-' : base
    Just mp ->
      case mp of
        Name ('^':n) -> return n
        Name n -> return $ progname ++ '-' : n
        Project p -> do
          projectDir <- resolveProject p
          return $ progname ++ '-' : base ++ '-' : workProjectName projectDir

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
