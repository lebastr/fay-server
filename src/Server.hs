{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The server.

module Server where

import Server.API
import SharedTypes

import Control.Concurrent
import Control.Monad.IO
import Control.Monad
import Data.Char
import Data.Default
import Data.List
import Data.List.Split
import Data.Maybe
import Data.UUID (UUID)
import Data.UUID.V1
import Language.Fay.Compiler
import Language.Fay.Types
import Safe
import Snap.Core
import Snap.Http.Server
import System.Directory
import System.FilePath
import System.Process.Extra

-- | Main entry point.
server :: IO ()
server = do
  httpServe (setPort 10001 defaultConfig) (route [("/json",handle dispatcher)])

-- | Dispatch on the commands.
dispatcher :: Command -> Dispatcher
dispatcher cmd =
  case cmd of

    LibraryModules r -> r <~ do
      io $ getModulesIn "library"
    ProjectModules r -> r <~ do
      io $ getModulesIn "project"
    GlobalModules r -> r <~ do
      io $ getModulesIn "global"

    GetModule mname r -> r <~ do
      t <- io $ loadModule mname
      return $ case t of
        Nothing -> NoModule mname
        Just x -> LoadedModule x

    CheckModule contents r -> r <~ do
      (guid,fpath) <- io $ getTempFile ".hs"
      io $ deleteSoon fpath
      let (skiplines,out) = formatForGhc contents
      io $ writeFile fpath out
      dirs <- io getModuleDirs
      result <- io $ typecheck dirs [] fpath
      io $ removeFile fpath
      return $
        case result of
          Right _ -> CheckOk (show guid)
          Left orig@(parseMsgs skiplines -> msgs) -> CheckError msgs orig

    CompileModule contents r -> r <~ do
      (guid,fpath) <- io $ getTempFile ".hs"
      io $ writeFile fpath contents
      let fout = "static/gen" </> guid ++ ".js"
      result <- io $ compileFromToReturningStatus config fpath fout
      io $ deleteSoon fpath
      io $ deleteSoon fout
      case result of
        Right _ -> do
          io $ generateFile guid
          return (CompileOk guid)
        Left out -> return (CompileError (show out))

  where config = def { configTypecheck = False
                     , configDirectoryIncludes = ["include"]
                     , configPrettyPrint = False
                     }


getModulesIn :: FilePath -> IO ModuleList
getModulesIn dir = do
  fmap (ModuleList . sort . map fileToModule)
       (getDirectoryItemsRecursive ("modules" </> dir))

getModuleDirs = getDirectoryItems "modules"

getDirectoryItems dir =
  fmap (map (dir </>) . filter (not . all (=='.')))
       (getDirectoryContents dir)

getDirectoryItemsRecursive dir = do
  elems <- fmap (filter (not . all (=='.'))) (getDirectoryContents dir)
  dirs <- filterM doesDirectoryExist . map (dir </>) $ elems
  files <- return (filter (not . flip elem dirs . (dir </>)) elems)
  subdirs <- mapM getDirectoryItemsRecursive dirs
  return (map (dir </>) files ++ concat subdirs)

-- | Load a module from a module name.
loadModule :: String -> IO (Maybe String)
loadModule name = do
  dirs <- getModuleDirs
  tries <- mapM try (map (</> moduleToFile name) dirs)
  return (listToMaybe (catMaybes tries))

  where
        try fpath = do
          exists <- doesFileExist fpath
          if exists
             then fmap Just (readFile fpath)
             else return Nothing

fileToModule = go . dropWhile (not . isUpper) where
  go ('/':cs) = '.' : go cs
  go ".hs"    = ""
  go (c:cs)   = c   : go cs
  go x        = x

-- | Convert a module name to a file name.
moduleToFile = go where
  go ('.':cs) = '/' : go cs
  go (c:cs)   = c   : go cs
  go []       = ".hs"

-- | Format a Fay module for GHC.
formatForGhc :: String -> (Int,String)
formatForGhc contents =
  (length ls,unlines ls ++ contents)
  where ls = []
             -- ["{-# LANGUAGE NoImplicitPrelude #-}"
             -- ,"module " ++ name ++ " where"
             -- ,"import Language.Fay.Prelude"]

-- | Generate a HTML file for previewing the generated code.
generateFile :: String -> IO ()
generateFile guid = do
  writeFile fpath $ unlines [
      "<!doctype html>"
    , "<html>"
    , "  <head>"
    ,"    <meta http-equiv='Content-Type' content='text/html; charset=utf-8'>"
    ,"    <link href='/css/bootstrap.min.css' rel='stylesheet'>"
    ,"    <link href='/css/gen.css' rel='stylesheet'>"
    , intercalate "\n" . map ("    "++) $ map makeScriptTagSrc libs
    , intercalate "\n" . map ("    "++) $ map makeScriptTagSrc files
    , "  </head>"
    , "  <body><noscript>Please enable JavaScript.</noscript></body>"
    , "</html>"]
  deleteSoon fpath

  where fpath = "static/gen/" ++ guid ++ ".html"
        makeScriptTagSrc :: FilePath -> String
        makeScriptTagSrc s =
          "<script type=\"text/javascript\" src=\"" ++ s ++ "\"></script>"
        files = [guid ++ ".js"]
        libs = ["/js/jquery.js","/js/date.js","/js/gen.js"]

-- | Type-check a file.
typecheck :: [FilePath] -> [String] -> String -> IO (Either String (String,String))
typecheck includeDirs ghcFlags fp = do
  readAllFromProcess' "ghc" (
    ["-package","fay","-package-conf","cabal-dev/packages-7.4.2.conf"] ++
    ["-fno-code","-Wall","-Werror",fp] ++
    ["-iinclude"] ++
    map ("-i" ++) includeDirs ++ ghcFlags) ""

-- | Parse the GHC messages.
parseMsgs :: Int -> String -> [Msg]
parseMsgs skiplines = catMaybes . map (parseMsg skiplines) . splitOn "\n\n"

-- | Parse a GHC message.
parseMsg :: Int -> String -> Maybe Msg
parseMsg skiplines err = case Msg typ (line err) (dropWarning (message err)) of
  Msg _ n "" | n < 1 -> Nothing
  good -> Just good

  where
    line = subtract (fromIntegral skiplines) . fromMaybe 0 . readMay
         . takeWhile isDigit . drop 1 . dropWhile (/=':')
    message = intercalate "\n" . filter (not . null) . map dropIndent . lines
            . drop 1 . dropWhile (/=':') . drop 1 . dropWhile (/=':') . drop 1 . dropWhile (/=':')
    dropWarning x | isPrefixOf wprefix x = drop (length wprefix) x
                  | otherwise = x
    dropIndent x | isPrefixOf "    " x = drop 4 x
                 | otherwise = x
    typ = if isPrefixOf wprefix (message err)
             then MsgWarning
             else MsgError
    wprefix = "Warning: "

-- | Get a unique ID.
getUID :: IO UUID
getUID = do
  uid <- nextUUID
  case uid of
    Nothing -> do threadDelay (1000 * 10)
                  getUID
    Just u -> return u

-- | Get a unique temporary file path with the given extension.
getTempFile :: String -> IO (String,FilePath)
getTempFile ext = do
  dir <- getTemporaryDirectory
  uid <- getUID
  return (show uid,dir </> show uid ++ ext)

-- | Delete the given file soon.
deleteSoon :: FilePath -> IO ()
deleteSoon path = do purge; return () where
  purge = forkIO $ do
    threadDelay (1000 * 1000 * 5)
    exists <- doesFileExist path
    when exists (removeFile path)
