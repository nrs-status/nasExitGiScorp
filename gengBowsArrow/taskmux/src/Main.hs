-- | taskmux: task-state management for tmux sessions.
--
-- A task state lives entirely in the @\@task-status@ and
-- @\@task-description@ user options of a tmux session (SPEC.md §1); a
-- session is /tasked/ iff its @\@task-status@ option is set.  The
-- subcommands set (@start@), complete (@done@), remove (@clear@),
-- inspect (@list@) and derive (@monitor-pi@) that state.
module Main (main) where

import System.Environment (getArgs)
import System.Exit
  ( ExitCode (..)
  , exitWith
  )
import System.IO (hPutStrLn, stderr)

import Taskmux.Git (currentBranch)
import Taskmux.List (runList)
import Taskmux.Monitor (runMonitorPi)
import Taskmux.Options (Command (..), ParseError (..), parseCommand)
import Taskmux.Tmux
  ( currentSession
  , setSessionOption
  , unsetSessionOption
  )

-- | The usage text, printed to stderr on bad invocations.
usage :: IO ()
usage = do
  hPutStrLn stderr "usage: taskmux start [task-description] [tmux-session]"
  hPutStrLn stderr "       taskmux done [tmux-session]"
  hPutStrLn stderr "       taskmux list [--one-shot|-1]"
  hPutStrLn stderr "       taskmux clear [tmux-session]"
  hPutStrLn stderr "       taskmux monitor-pi [tmux-window]"

main :: IO ()
main = do
  args <- getArgs
  case parseCommand args of
    Left (UnknownSub cmd) -> do
      hPutStrLn stderr ("taskmux: unknown subcommand: " ++ cmd)
      usage
      exitWith (ExitFailure 1)
    Left UsageError -> do
      usage
      exitWith (ExitFailure 1)
    Right cmd -> run cmd

-- | The session a command targets: the explicit argument, else the
-- current session.
targetSession :: Maybe String -> IO String
targetSession msession = case msession of
  Just s -> return s
  Nothing -> do
    ms <- currentSession
    case ms of
      Just s -> return s
      Nothing -> do
        hPutStrLn stderr "taskmux: cannot determine the current tmux session"
        exitWith (ExitFailure 1)

run :: Command -> IO ()
run cmd = case cmd of
  Start mdesc msession -> cmdStart mdesc msession
  Done msession -> cmdDone msession
  ListCmd oneShot -> runList oneShot
  Clear msession -> cmdClear msession
  MonitorPi mwin -> runMonitorPi mwin

-- | @start@: set @\@task-status@ to @underway@ and @\@task-description@
-- to the given description (or, without one, the current git branch
-- name).  The git-branch fallback must not modify any session state when
-- it fails (SPEC.md §3.1).
cmdStart :: Maybe String -> Maybe String -> IO ()
cmdStart mdesc msession = do
  description <- case mdesc of
    Just d -> return d
    Nothing -> do
      mb <- currentBranch
      case mb of
        Just b -> return b
        Nothing -> do
          hPutStrLn
            stderr
            "taskmux start: not in a git repository (or no current branch); a task description is required"
          exitWith (ExitFailure 1)
  session <- targetSession msession
  setSessionOption session "@task-status" "underway"
  setSessionOption session "@task-description" description

-- | @done@: set @\@task-status@ to @done@, leaving the description
-- untouched (SPEC.md §3.2).
cmdDone :: Maybe String -> IO ()
cmdDone msession = do
  session <- targetSession msession
  setSessionOption session "@task-status" "done"

-- | @clear@: unset both task-state options (SPEC.md §3.4).
cmdClear :: Maybe String -> IO ()
cmdClear msession = do
  session <- targetSession msession
  unsetSessionOption session "@task-status"
  unsetSessionOption session "@task-description"
