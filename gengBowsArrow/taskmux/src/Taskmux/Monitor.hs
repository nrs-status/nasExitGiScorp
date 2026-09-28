-- | The @taskmux monitor-pi@ subcommand (SPEC.md §3.5).
--
-- Watches the pi coding agent harness process running in a tmux window
-- of the current session and records whether that agent's turn is
-- finished in the current session's task state: the session's
-- @\@task-status@ is set to @underway@ while the agent is mid-turn and
-- to @done@ when it is waiting for user input.
module Taskmux.Monitor (runMonitorPi) where

import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Taskmux.Pi
  ( TurnState (..)
  , piProcessesInSession
  , piProcessesInWindow
  , piTurnState
  )
import Taskmux.Tmux
  ( currentSession
  , getSessionOption
  , listWindowIndices
  , setSessionOption
  )

-- | Print an error and exit 1.
die :: String -> IO a
die msg = do
  hPutStrLn stderr msg
  exitWith (ExitFailure 1)

-- | Run @monitor-pi [tmux-window]@.
--
-- The optional argument is an integer window index of the current
-- session.  When it is omitted, exactly one pi process must be running
-- in the current session; when it is given, exactly one pi process must
-- be running in that window.  The current session must be tasked
-- (@\@task-status@ set to @underway@ or @done@).  The monitored agent's
-- turn state is then written to the current session's @\@task-status@.
runMonitorPi :: Maybe String -> IO ()
runMonitorPi mwin = do
  session <- requireCurrentSession
  requireTasked session
  piPid <- case mwin of
    Nothing -> findSolo session
    Just w -> findInWindow session w
  state <- piTurnState piPid
  let status = case state of
        Just TurnDone -> "done"
        _ -> "underway"
  setSessionOption session "@task-status" status

-- | The current session must be resolvable; monitor-pi cannot work
-- without one.
requireCurrentSession :: IO String
requireCurrentSession = do
  ms <- currentSession
  case ms of
    Just s -> return s
    Nothing -> die "taskmux monitor-pi: cannot determine the current tmux session"

-- | The current session must already be tasked with status @underway@ or
-- @done@ (SPEC.md §3.5).
requireTasked :: String -> IO ()
requireTasked session = do
  mstatus <- getSessionOption session "@task-status"
  case mstatus of
    Just s | s == "underway" || s == "done" -> return ()
    _ ->
      die
        ( "taskmux monitor-pi: current session '"
            ++ session
            ++ "' is not tasked (no @task-status); run `taskmux start' first"
        )

-- | Exactly one pi process must run somewhere in the session.
findSolo :: String -> IO Int
findSolo session = do
  found <- piProcessesInSession session
  case found of
    [(_, pid)] -> return pid
    [] ->
      die
        ( "taskmux monitor-pi: no pi coding agent harness is running in the current session '"
            ++ session
            ++ "'"
        )
    _ ->
      die
        ( "taskmux monitor-pi: more than one pi coding agent harness is running in the current session '"
            ++ session
            ++ "'; pass a tmux window index to select one"
        )

-- | The named window must exist in the session and contain exactly one
-- pi process.
findInWindow :: String -> String -> IO Int
findInWindow session w = case readInt w of
  Nothing ->
    die ("taskmux monitor-pi: not a tmux window index: " ++ w)
  Just idx -> do
    idxs <- listWindowIndices session
    if idx `notElem` idxs
      then
        die
          ( "taskmux monitor-pi: session '"
              ++ session
              ++ "' has no window with index "
              ++ show idx
          )
      else do
        found <- piProcessesInWindow session idx
        case found of
          [pid] -> return pid
          [] ->
            die
              ( "taskmux monitor-pi: no pi coding agent harness is running in window "
                  ++ show idx
                  ++ " of session '"
                  ++ session
                  ++ "'"
              )
          _ ->
            die
              ( "taskmux monitor-pi: more than one pi coding agent harness is running in window "
                  ++ show idx
                  ++ " of session '"
                  ++ session
                  ++ "'"
              )

readInt :: String -> Maybe Int
readInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing
