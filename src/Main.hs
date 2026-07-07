-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.List.Extra (intercalate, splitOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import System.Directory (canonicalizePath, doesFileExist, doesPathExist, getHomeDirectory)
import System.FilePath ((</>), takeFileName)
import System.Posix.Process (getProcessID)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (getFileStatus, isSocket)
import System.Posix.User (getEffectiveUserName)

import SimpleCmd (cmd_, cmdBool, cmdFull, cmdSilent, error')
import SimpleCmdArgs

import TOML (Value(..), Table, renderTOMLError, decodeFile)

import Paths_constrained_toolbox (version)

progname :: String
progname = "constrained-toolbox"

main :: IO ()
main =
  simpleCmdArgs (Just version)
  "constrained-toolbox"
  "Run a toolbox image in an isolated podman container" $
  run
  <$> optional (argumentWith str "TOOLBOX")
  <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "Bind mounts (default to selinux :z)")
  <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "Set or pass through an environment variables")
  <*> many (strOptionWith 'P' "path" "DIR" "Prepend a directory to PATH inside the container")
  <*> many (strOptionWith 'i' "init" "CMD" "Run a bash snippet before entering the container")
  <*> many (strOptionLongWith "cap" "NAME" "Enable a capability from the config file")
  <*> optional (strOptionWith 'p' "project" "DIR" "Mount a project directory and set as workdir")
  <*> switchLongWith "caps" "List available capabilities from the config file"
  <*> switchLongWith "readonly" "Make the container filesystem read-only"
  <*> switchLongWith "no-network" "Disable network access"
  <*> switchLongWith "dryrun" "Print the podman command instead of running it"
  <*> switchLongWith "refresh" "Force re-commit of the toolbox image"
  <*> switchLongWith "delete" "Remove the committed image after running"
  <*> many (argumentWith str "CMD")

run :: Maybe String -> [String] -> [String] -> [String] -> [String] -> [String]
    -> Maybe String -> Bool -> Bool -> Bool -> Bool -> Bool -> Bool -> [String] -> IO ()
run mtoolbox vols envs paths inits caps mproject listcaps readonly nonetwork dryrun refresh delete command =
  if listcaps
    then do
      config <- loadConfig
      let capabilities = getCapabilities config
      if Map.null capabilities
        then putStrLn "No capabilities defined"
        else do
          putStrLn "Available capabilities:"
          mapM_ (putStrLn . ("  " ++) . T.unpack) $ Map.keys capabilities
    else do
  let toolbox =
        case mtoolbox of
          Just t -> t
          Nothing -> error' "TOOLBOX argument required"
  mprojectDir <-
    case mproject of
      Just dir -> Just <$> (expandPath dir >>= canonicalizePath)
      Nothing -> return Nothing
  image <- commitToolbox toolbox refresh delete
  config <- loadConfig
  let capabilities = getCapabilities config

  (extraVols, extraEnvs, extraPaths, extraInits, extraSecurityOpts) <-
    resolveCapabilities capabilities caps

  let projectVol =
        case mprojectDir of
          Just d -> [d ++ ":" ++ rootDest d]
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
      sudoers = "/etc/sudoers.d" </> progname
      setup = "echo " ++ shellQuote (username ++ " ALL=(ALL) NOPASSWD:ALL")
              ++ " > " ++ sudoers
              ++ " && chmod 440 " ++ sudoers
              ++ initSetup
              ++ " && exec runuser -u " ++ username ++ " -- " ++ runuserCmd

  mounts <- mapM addSelinuxLabel volumes

  let workdirPart =
        case mprojectDir of
          Just d -> ["--workdir", rootDest d]
          Nothing -> []
      cmd = ["podman", "run", "--rm", "-it", "--userns=keep-id",
             "--user", "root", "-e", "HOME=" ++ home]
            ++ workdirPart
            ++ (if readonly
                then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                else [])
            ++ (if nonetwork then ["--net", "none"] else [])
            ++ concatMap (\s -> ["--security-opt", s]) extraSecurityOpts
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
  let baseImage = progname ++ '-' : toolbox
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
        Left e -> error' $ "config parse error: " ++ T.unpack (renderTOMLError e)
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
      error' $ "unknown capability '" ++ name ++ "'. Available: " ++ available

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
  in " && printf " ++ shellQuote content ++ " > /tmp" </> progname ++ "-init.sh"

mkUserCmd :: [String] -> [String] -> [String]
mkUserCmd [] inits = mkUserCmd ["bash"] inits
mkUserCmd ["bash"] (_:_) =
  ["bash", "--rcfile", "/tmp" </> progname ++ "-init.sh"]
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
