-- | Discovery and state inspection of pi coding agent harness processes
-- running inside tmux panes; used by @taskmux monitor-pi@ (SPEC.md §3.5).
--
-- A pi process is identified by its command line: a process whose first
-- @\/proc\/<pid>\/cmdline@ token has base name @pi@.  Its turn state is
-- derived from the pi session file it appends to
-- (@~\/.pi\/agent\/sessions\/--<cwd>--\/&lt;ts&gt;_&lt;uuid&gt;.jsonl@,
-- most recently modified): entries are appended in real time as messages
-- complete, so the role and stop reason of the last message entry tell
-- whether the agent is mid-turn or waiting for user input.
module Taskmux.Pi
  ( TurnState (..)
  , piDescendants
  , piProcessesInWindow
  , piProcessesInSession
  , piTurnState
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..), decodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.List (isSuffixOf, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import System.Directory
  ( doesDirectoryExist
  , getDirectoryContents
  , getHomeDirectory
  , getModificationTime
  )
import System.FilePath (takeFileName, (</>))
import System.Posix.Files (readSymbolicLink)

import Taskmux.Tmux (listPanePids, listWindowIndices)

-- | Whether the monitored pi agent is still busy with its turn
-- ('TurnUnderway') or has finished and is waiting for user input
-- ('TurnDone').
data TurnState = TurnUnderway | TurnDone
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- /proc helpers
-- ---------------------------------------------------------------------------

-- | @\/proc@ numeric process ids currently visible.
allPids :: IO [Int]
allPids = do
  r <- try (getDirectoryContents "/proc")
  case (r :: Either SomeException [FilePath]) of
    Right entries -> return (mapMaybe readInt (filter allDigits entries))
    Left _ -> return []
  where
    allDigits = all (\c -> c >= '0' && c <= '9')

-- | The parent pid from @\/proc\/<pid>\/stat@ (field 4, after the
-- parenthesised command which may itself contain spaces and parentheses).
procPpid :: Int -> IO (Maybe Int)
procPpid pid = do
  r <- try (readFile ("/proc/" ++ show pid ++ "/stat"))
  case (r :: Either SomeException String) of
    Right stat -> return (parsePpid stat)
    Left _ -> return Nothing

-- | Parse the ppid out of a stat line: the ppid is the second field
-- after the closing parenthesis of the comm field.
parsePpid :: String -> Maybe Int
parsePpid stat = case break (== ')') stat of
  (_, ')' : rest) -> case words rest of
    (_state : ppid : _) -> readInt ppid
    _ -> Nothing
  _ -> Nothing

-- | The command name (@\/proc\/<pid>\/comm@), i.e. what @ps@ shows.
-- For the real pi launcher this is @pi@ even though the executable is
-- the node binary.
procComm :: Int -> IO (Maybe String)
procComm pid = do
  r <- try (readFile ("/proc/" ++ show pid ++ "/comm"))
  case (r :: Either SomeException String) of
    Right s -> return (Just (takeWhile (\c -> c /= '\n' && c /= '\r') s))
    Left _ -> return Nothing

-- | The full command line of @\/proc\/<pid>\/cmdline@ as separate tokens.
procCmdArgs :: Int -> IO (Maybe [String])
procCmdArgs pid = do
  r <- try (BS.readFile ("/proc/" ++ show pid ++ "/cmdline"))
  case (r :: Either SomeException ByteString) of
    Right bs | not (BS.null bs) ->
      return (Just (map BS.unpack (BS.split '\0' (BS.takeWhile (/= '\0') bs))))
    _ -> return Nothing

-- | Whether a process is a pi coding agent harness.  Detected via
-- @comm@ (@pi@, even though the executable is the node binary) or via
-- the command line: the launcher may appear directly
-- (@argv0 = ...\/pi@) or via its shebang interpreter (@bash ...\/pi@).
procIsPi :: Int -> IO Bool
procIsPi pid = do
  comm <- procComm pid
  args <- procCmdArgs pid
  return (comm == Just "pi" || maybe False isPiArgs args)
  where
    isPiArgs args0 =
      case args0 of
        (a0 : rest) ->
          base a0 == "pi"
            || (base a0 `elem` ["bash", "sh", "env"] && any (\a -> base a == "pi") (take 2 rest))
        [] -> False
    base = takeFileName

-- | The working directory of a process (@readlink \/proc\/<pid>\/cwd@),
-- or Nothing when it cannot be read (process gone, permissions).
procCwd :: Int -> IO (Maybe FilePath)
procCwd pid = do
  r <- try (readSymbolicLink ("/proc/" ++ show pid ++ "/cwd"))
  case (r :: Either SomeException FilePath) of
    Right dir -> return (Just dir)
    Left _ -> return Nothing

readInt :: String -> Maybe Int
readInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- pi process discovery
-- ---------------------------------------------------------------------------

-- | All processes rooted at (and including, since a pane's root shell
-- may itself have exec'd into pi) @root@ whose command name is @pi@.
piDescendants :: Int -> IO [Int]
piDescendants root = do
  pids <- allPids
  tree <- childrenMap pids
  bfs tree [root] []
  where
    bfs _ [] acc = return (reverse acc)
    bfs tree (p : queue) acc = do
      let kids = Map.findWithDefault [] p tree
      isPiP <- procIsPi p
      flags <- mapM procIsPi kids
      let piKids = [k | (k, True) <- zip kids flags]
      bfs tree (queue ++ kids) (if isPiP then p : reverse piKids ++ acc else reverse piKids ++ acc)

-- | Parent-children relation over the given pids.
childrenMap :: [Int] -> IO (Map Int [Int])
childrenMap pids = do
  edges <- mapMaybeM (\p -> fmap (fmap ((,) p)) (procPpid p)) pids
  return (Map.fromListWith (++) [(ppid, [pid]) | (pid, ppid) <- edges])
  where
    mapMaybeM _ [] = return []
    mapMaybeM f (x : xs) = do
      y <- f x
      ys <- mapMaybeM f xs
      return (maybe ys (: ys) y)

-- | The pi processes running in the given window (identified by window
-- index) of @session@: the pi descendants of every pane's root shell.
piProcessesInWindow :: String -> Int -> IO [Int]
piProcessesInWindow session idx = do
  panePids <- listPanePids session idx
  concat <$> mapM piDescendants panePids

-- | The pi processes running anywhere in @session@, paired with their
-- window index.
piProcessesInSession :: String -> IO [(Int, Int)]
piProcessesInSession session = do
  idxs <- listWindowIndices session
  pairs <- mapM one idxs
  return (concat pairs)
  where
    one idx = do
      ps <- piProcessesInWindow session idx
      return [(idx, p) | p <- ps]

-- ---------------------------------------------------------------------------
-- turn state
-- ---------------------------------------------------------------------------

-- | The turn state of the pi process with the given pid, or Nothing when
-- it cannot be determined (no session directory, no session file, or a
-- read\/parse error).
piTurnState :: Int -> IO (Maybe TurnState)
piTurnState pid = do
  mcwd <- procCwd pid
  case mcwd of
    Nothing -> return Nothing
    Just cwd -> do
      mfile <- newestSessionFile cwd
      case mfile of
        Nothing -> return Nothing
        Just file -> sessionFileState file

-- | The pi session directory for a working directory: the cwd with its
-- leading @\/@ dropped and every remaining @\/@ replaced by @-@, wrapped
-- in @--...--@ under @~\/.pi\/agent\/sessions@.
sessionDirFor :: FilePath -> FilePath -> FilePath
sessionDirFor home cwd =
  home </> ".pi/agent/sessions"
    </> ("--" ++ map (\c -> if c == '/' then '-' else c) (dropLeadSlash cwd) ++ "--")
  where
    dropLeadSlash ('/' : rest) = rest
    dropLeadSlash p = p

-- | The most recently modified @.jsonl@ file in the pi session directory
-- for @cwd@, if any.
newestSessionFile :: FilePath -> IO (Maybe FilePath)
newestSessionFile cwd = do
  home <- getHomeDirectory'
  let dir = sessionDirFor home cwd
  exists <- doesDirectoryExist dir
  if not exists
    then return Nothing
    else do
      r <- try (getDirectoryContents dir)
      case (r :: Either SomeException [FilePath]) of
        Left _ -> return Nothing
        Right entries -> do
          let files = filter (".jsonl" `isSuffixOf`) entries
          times <- mapMaybeM (\f -> fmap (fmap ((,) f)) (mtime (dir </> f))) files
          case sortOn (\(_, t) -> t) times of
            [] -> return Nothing
            timed -> return (Just (dir </> fst (last timed)))
  where
    mtime f = do
      r <- try (getModificationTime f)
      case (r :: Either SomeException UTCTime) of
        Right t -> return (Just t)
        Left _ -> return Nothing
    mapMaybeM _ [] = return []
    mapMaybeM f (x : xs) = do
      y <- f x
      ys <- mapMaybeM f xs
      return (maybe ys (: ys) y)

getHomeDirectory' :: IO FilePath
getHomeDirectory' = do
  r <- try getHomeDirectory
  case (r :: Either SomeException FilePath) of
    Right h -> return h
    Left _ -> return "/"

-- | The turn state recorded in a pi session file: the role and stop
-- reason of the last message entry decide.
--
-- pi appends entries in real time as messages complete, so:
--
--   * the last entry being an assistant message with a terminal stop
--     reason (@stop@, @length@, @aborted@ or @error@) means the agent's
--     turn ended and it is waiting for user input — 'TurnDone';
--   * anything else (a user message, a tool result, an assistant message
--     still awaiting its tool results, an unrecognised entry) means the
--     agent is mid-turn — 'TurnUnderway'.
sessionFileState :: FilePath -> IO (Maybe TurnState)
sessionFileState file = do
  r <- try (BS.readFile file)
  case (r :: Either SomeException ByteString) of
    Left _ -> return Nothing
    Right bs -> return (lastLineState bs)

-- | State implied by the last line of a session file.
lastLineState :: ByteString -> Maybe TurnState
lastLineState bs
  | BS.null trimmed = Nothing
  | otherwise = fmap decide (decodeStrict' trimmed)
  where
    trimmed = lastNonEmpty (BS.lines bs)
    lastNonEmpty = foldl (\acc l -> if BS.null (BS.strip l) then acc else l) BS.empty
    decide v = case memberString "role" (entryMessage v) of
      Just "assistant" | stopReasonIsTerminal v -> TurnDone
      _ -> TurnUnderway
    entryMessage v = case v of
      Object o -> KM.lookup (Key.fromString "message") o
      _ -> Nothing
    stopReasonIsTerminal v = case memberString "stopReason" (entryMessage v) of
      Just r -> r `elem` ["stop", "length", "aborted", "error"]
      Nothing -> False
    memberString k v = case v of
      Just (Object o) -> case KM.lookup (Key.fromText (T.pack k)) o of
        Just (String s) -> Just (T.unpack s)
        _ -> Nothing
      _ -> Nothing
