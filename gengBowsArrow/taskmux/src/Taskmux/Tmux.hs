{-# LANGUAGE OverloadedStrings #-}

-- | Thin wrapper around the tmux command line, plus the task-state model
-- of SPEC.md §1: the per-session user options @\@task-status@ and
-- @\@task-description@.
module Taskmux.Tmux
  ( TaskRow (..)
  , runTmux
  , tmuxOrDie
  , currentSession
  , getSessionOption
  , setSessionOption
  , unsetSessionOption
  , serverRunning
  , fetchTaskRows
  , rowDisplay
  , listWindowIndices
  , listPanePids
  , switchToSession
  ) where

import Control.Exception (SomeException, try)
import Data.List (dropWhileEnd)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import System.Process (proc, readCreateProcessWithExitCode)

-- | One tasked tmux session as reported by the fetch of @list@.
data TaskRow = TaskRow
  { rowName :: String -- ^ bare session name (needed for switch-client)
  , rowStatus :: String -- ^ @\@task-status@ value (non-empty)
  , rowDescription :: String -- ^ @\@task-description@ value (may be empty)
  }
  deriving (Eq, Show)

-- | Run tmux with the given arguments and return its exit code and
-- captured stdout/stderr.
runTmux :: [String] -> IO (ExitCode, String, String)
runTmux args = readCreateProcessWithExitCode (proc "tmux" args) ""

-- | Run tmux; if it fails, forward its stderr and exit with its status.
-- Used by the state-mutating commands (start\/done\/clear), where an
-- error (e.g. a non-existent session) must not be swallowed.
tmuxOrDie :: [String] -> IO String
tmuxOrDie args = do
  (code, out, err) <- runTmux args
  case code of
    ExitSuccess -> return out
    ExitFailure n -> do
      hPutStrLn stderr (dropWhileEnd (== '\n') err)
      exitWith (ExitFailure n)

-- | The current session's name via @display-message -p '#S'@, or Nothing
-- when tmux cannot be asked (no server, not inside tmux and no current
-- session).
currentSession :: IO (Maybe String)
currentSession = do
  r <- try (tmuxQuiet ["display-message", "-p", "#S"])
  case (r :: Either SomeException (ExitCode, String, String)) of
    Right (ExitSuccess, out, _) -> return (Just (trimLine out))
    _ -> return Nothing
  where
    tmuxQuiet = runTmux

-- | Trim a single trailing newline (and surrounding whitespace) from
-- captured command output.
trimLine :: String -> String
trimLine = unwords . words

-- | Read a per-session option with @show-options -v@.  Returns Nothing
-- when the option is not set (tmux then exits non-zero) or tmux fails.
getSessionOption :: String -> String -> IO (Maybe String)
getSessionOption session opt = do
  (code, out, _) <- runTmux ["show-options", "-v", "-q", "-t", session, opt]
  case code of
    ExitSuccess ->
      let v = trimLine out
       in return (if null v then Nothing else Just v)
    ExitFailure _ -> return Nothing

-- | Set a per-session option (@tmux set-option -t <session> <opt> <val>@).
setSessionOption :: String -> String -> String -> IO ()
setSessionOption session opt val =
  () <$ tmuxOrDie ["set-option", "-t", session, opt, val]

-- | Unset a per-session option (@tmux set-option -u -t <session> <opt>@).
unsetSessionOption :: String -> String -> IO ()
unsetSessionOption session opt =
  () <$ tmuxOrDie ["set-option", "-u", "-t", session, opt]

-- | Pre-check used by @list@: True when @tmux list-sessions@ succeeds,
-- i.e. a tmux server with at least one session is reachable.
serverRunning :: IO Bool
serverRunning = do
  (code, _, _) <- runTmux ["list-sessions"]
  return (code == ExitSuccess)

-- | Fetch every session's task state via
-- @tmux list-sessions -F '#{session_name}\\t#\\@task-status\\t#\\@task-description'@.
--
-- Only sessions with a non-empty @\@task-status@ are kept.  If the tmux
-- server is not running (or goes away mid-refresh) the fetch yields an
-- empty result: tmux errors are suppressed and the caller must not
-- abort.  The format string uses a literal tab character; tmux does not
-- interpret @\\t@ escape sequences in @-F@ strings.
fetchTaskRows :: IO [TaskRow]
fetchTaskRows = do
  (code, out, _) <- runTmux ["list-sessions", "-F", fmt]
  return $ case code of
    ExitSuccess -> mapMaybe rowOf (lines out)
    ExitFailure _ -> []
  where
    fmt = "#{session_name}\t#{@task-status}\t#{@task-description}"
    rowOf l = case splitTab l of
      (name, Just (status, descr))
        | not (null name) && not (null status) ->
            Just (TaskRow name status descr)
      _ -> Nothing
    -- Split on the first two tabs; anything after the second tab (i.e.
    -- the description, which may itself contain tabs) is kept verbatim.
    splitTab s = case break (== '\t') s of
      (a, '\t' : rest) -> case break (== '\t') rest of
        (b, '\t' : c) -> (a, Just (b, c))
        _ -> (a, Nothing)
      _ -> (s, Nothing)

-- | The display line of a tasked session:
-- @<session>: <status> - <description>@.
rowDisplay :: TaskRow -> String
rowDisplay (TaskRow n st d) = n ++ ": " ++ st ++ " - " ++ d

-- | The window indices of a session (@list-windows -F '#\{window_index\}'@).
listWindowIndices :: String -> IO [Int]
listWindowIndices session = do
  (code, out, _) <- runTmux ["list-windows", "-t", session, "-F", "#{window_index}"]
  return $ case code of
    ExitSuccess -> mapMaybe readInt (lines out)
    ExitFailure _ -> []

-- | The pids of the root shell processes of a window's panes.
listPanePids :: String -> Int -> IO [Int]
listPanePids session idx = do
  (code, out, _) <-
    runTmux ["list-panes", "-t", session ++ ":" ++ show idx, "-F", "#{pane_pid}"]
  return $ case code of
    ExitSuccess -> mapMaybe readInt (lines out)
    ExitFailure _ -> []

-- | Switch the current tmux client to the session when running inside
-- tmux, otherwise attach to it (SPEC.md §3.3).
switchToSession :: String -> IO ()
switchToSession name = do
  inside <- lookupEnv "TMUX"
  _ <-
    if maybe False (not . null) inside
      then tmuxOrDie ["switch-client", "-t", name]
      else tmuxOrDie ["attach-session", "-t", name]
  return ()

mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe _ [] = []
mapMaybe f (x : xs) = case f x of
  Just y -> y : mapMaybe f xs
  Nothing -> mapMaybe f xs

readInt :: String -> Maybe Int
readInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing
