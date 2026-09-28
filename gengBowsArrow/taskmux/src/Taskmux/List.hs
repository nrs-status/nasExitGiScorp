-- | The @taskmux list@ subcommand (SPEC.md §3.3).
--
-- Three modes:
--
--   * __one-shot__ (@--one-shot@ \/ @-1@): print the current listing once
--     and exit;
--   * __non-interactive__ (stdin or stderr is not a tty): print the
--     current listing, then loop forever — sleep 3 s, re-fetch, reprint
--     only when the fetched listing changed (erasing the previous
--     listing with @\\e[NA\\e[J@ when stdout is a tty);
--   * __interactive__ (stdin and stderr are ttys): a selectable menu
--     read from @\/dev\/tty@ with a 3 s input timeout so the menu keeps
--     refreshing while idle; @j@\/@k@ move the cursor, Return selects
--     (switch-client inside tmux, attach-session outside), @q@, Escape
--     and Ctrl-C quit.
module Taskmux.List (runList) where

import Control.Concurrent (threadDelay)
import System.Exit (exitSuccess)
import System.IO (hFlush, hPutStr, stdout)
import System.Posix.IO (stdError, stdInput, stdOutput)
import System.Posix.Terminal (queryTerminal)

import Taskmux.Tmux
  ( TaskRow (..)
  , fetchTaskRows
  , rowDisplay
  , serverRunning
  , switchToSession
  )
import Taskmux.Tty (RawTty, readKey, withRawTty)

-- | The refresh interval in seconds (SPEC.md: \"re-fetched every 3
-- seconds\").
refreshMicros :: Int
refreshMicros = 3 * 1000 * 1000

-- | Footer of the interactive menu.
footer :: String
footer = "j/k: move, Return: switch, q: quit"

-- | Run @list@ in one-shot or looping (non-interactive \/ interactive)
-- mode.
runList :: Bool -> IO ()
runList oneShot = do
  running <- serverRunning
  if not running
    then exitSuccess -- no tmux server: nothing to list
    else
      if oneShot
        then oneShotList
        else do
          inIsTty <- queryTerminal stdInput
          errIsTty <- queryTerminal stdError
          if inIsTty && errIsTty then interactiveLoop else nonInteractiveLoop

-- | The display lines of the currently tasked sessions.
currentEntries :: IO [String]
currentEntries = map rowDisplay <$> fetchTaskRows

-- | Print the listing once and exit.
oneShotList :: IO ()
oneShotList = do
  entries <- currentEntries
  putStr' (unlines entries)

putStr' :: String -> IO ()
putStr' s = do
  hPutStr stdout s
  hFlush stdout

-- ---------------------------------------------------------------------------
-- non-interactive mode
-- ---------------------------------------------------------------------------

-- | Print the listing immediately, then loop forever: sleep, re-fetch,
-- reprint only when the listing changed.  On a tty stdout the previous
-- listing is erased first (@\\e[NA\\e[J@); when stdout is redirected
-- each changed listing is printed in full.  If the new listing is empty,
-- nothing is printed after the erase.
nonInteractiveLoop :: IO ()
nonInteractiveLoop = do
  entries <- currentEntries
  if null entries
    then exitSuccess -- no tasked sessions: print nothing, exit 0
    else do
      putStr' (unlines entries)
      go (length entries) (unlines entries)
  where
    go :: Int -> String -> IO ()
    go linesDrawn prev = do
      threadDelay refreshMicros
      entries <- currentEntries
      let listing = unlines entries
      if listing == prev
        then go linesDrawn prev
        else do
          isTty <- queryTerminal stdOutput
          if isTty && linesDrawn > 0
            then putStr' (eraseLines linesDrawn)
            else return ()
          if null entries
            then go 0 listing
            else do
              putStr' listing
              go (length entries) listing

-- | Erase @n@ lines: cursor up @n@ lines, then clear to end of screen.
eraseLines :: Int -> String
eraseLines n = "\ESC[" ++ show n ++ "A\ESC[J"

-- ---------------------------------------------------------------------------
-- interactive mode
-- ---------------------------------------------------------------------------

-- | State of the interactive menu: the fetched rows (as last seen), the
-- cursor index, the number of screen lines the previous frame occupied
-- (needed for the erase) and whether the frame must be redrawn.
data MenuState = MenuState
  { msRows :: [TaskRow]
  , msSel :: Int
  , msDrawn :: Int
  , msDirty :: Bool
  }

-- | The interactive selection menu.  Runs the input loop and, on
-- selection, switches to (inside tmux) or attaches the chosen session —
-- after @withRawTty@ has restored the saved terminal settings.
interactiveLoop :: IO ()
interactiveLoop = do
  rows <- fetchTaskRows
  chosen <- withRawTty (\tty -> menu tty (MenuState rows 0 0 True))
  case chosen of
    Nothing -> return ()
    Just name -> switchToSession name

-- | Run the menu: draw when dirty, wait for a key (up to the refresh
-- interval), handle it, re-fetch and repeat.  Returns the selected
-- session name or Nothing on quit.
menu :: RawTty -> MenuState -> IO (Maybe String)
menu tty st
  | msDirty st = do
      eraseLines' (msDrawn st)
      draw (msRows st) (msSel st)
      next tty (st {msDirty = False})
  | otherwise = next tty st
  where
    eraseLines' n = putStr' (if n > 0 then "\ESC[" ++ show n ++ "A\ESC[J" else "")
    draw rows sel = do
      let count = length rows
          body
            | count == 0 = ["no tasked sessions"]
            | otherwise =
                [ if i == sel
                    then "\ESC[7m> " ++ rowDisplay r ++ "\ESC[0m"
                    else "  " ++ rowDisplay r
                | (i, r) <- zip [0 ..] rows
                ]
      putStr' (unlines (body ++ [footer]))
      -- The frame occupies one line per entry (or the notice) plus the
      -- footer; this is what the next erase must cover.
      return ()
    frameLines s = let count = length (msRows s) in if count == 0 then 2 else count + 1
    next tty' s = do
      key <- readKey tty'
      case key of
        -- quit without switching
        Just '\ESC' -> return Nothing
        Just 'q' -> return Nothing
        Just '\ETX' -> return Nothing
        -- select the highlighted session (no-op when nothing is listed)
        Just '\r' -> select s
        Just '\n' -> select s
        -- move the cursor down\/up with wrap-around
        Just 'j' -> move s 1
        Just 'k' -> move s (-1)
        -- any other key is ignored (but still triggers a re-fetch, as
        -- does the timeout: the loop below always re-fetches)
        _ -> refetch tty' s

    select s =
      case msRows s of
        [] -> refetch tty s
        rows -> return (Just (rowName (rows !! msSel s)))

    move s d =
      let count = length (msRows s)
       in if count == 0
            then refetch tty s
            else
              menu tty
                s
                  { msSel = (msSel s + d + count) `mod` count
                  , msDirty = True
                  , msDrawn = frameLines s
                  }

    refetch tty' s = do
      rows <- fetchTaskRows
      let sel
            | msSel s >= length rows = 0
            | otherwise = msSel s
          changed = rows /= msRows s
      menu
        tty'
        s
          { msRows = rows
          , msSel = sel
          , msDrawn =
              if changed
                then frameLines s
                else msDrawn s
          , msDirty = changed
          }
