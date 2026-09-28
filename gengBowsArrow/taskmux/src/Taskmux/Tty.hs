{-# LANGUAGE ScopedTypeVariables #-}

-- | Terminal handling for the interactive @taskmux list@ menu.
--
-- The menu reads one byte at a time from @\/dev\/tty@ with a
-- @refresh_secs@ timeout (SPEC.md §3.3): the terminal is put in a
-- non-canonical, non-echoing, non-signalling mode with @VMIN = 0@ and
-- @VTIME = 30@ (3 s), so a read returns either one keypress or nothing
-- after the refresh interval has elapsed.
module Taskmux.Tty
  ( RawTty
  , withRawTty
  , readKey
  ) where

import Control.Exception (bracket)
import Data.Word (Word8)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Posix.IO
  ( OpenMode (ReadOnly)
  , defaultFileFlags
  , closeFd
  , fdReadBuf
  , openFd
  )
import System.Posix.Terminal
  ( TerminalAttributes
  , TerminalMode (..)
  , TerminalState (Immediately)
  , getTerminalAttributes
  , setTerminalAttributes
  , withMinInput
  , withTime
  , withoutMode
  )
import System.Posix.Types (Fd)

-- | An open @\/dev\/tty@ in the raw-ish input mode described above.
data RawTty = RawTty
  { ttyFd :: Fd
  , ttySaved :: TerminalAttributes
  }

-- | Open @\/dev\/tty@, put it in the menu input mode, run the action,
-- and always restore the saved terminal settings and close the fd
-- afterwards (SPEC.md §3.3: the saved settings are restored on exit).
withRawTty :: (RawTty -> IO a) -> IO a
withRawTty = bracket openRawTty closeRawTty
  where
    openRawTty = do
      fd <- openFd "/dev/tty" ReadOnly defaultFileFlags
      saved <- getTerminalAttributes fd
      setTerminalAttributes fd (rawInput saved) Immediately
      return (RawTty fd saved)
    closeRawTty tty = do
      setTerminalAttributes (ttyFd tty) (ttySaved tty) Immediately
      closeFd (ttyFd tty)

-- | Disable canonical input (@ICANON@, i.e. @ProcessInput@), echo and
-- signal generation (so Ctrl-C arrives as the @\\ETX@ byte instead of a
-- signal) while keeping output post-processing (ONLCR) and input
-- translation (ICRNL, so Return is readable as @\\n@), and set @VMIN =
-- 0@ / @VTIME = 30@ so reads time out after three seconds (the
-- @refresh_secs@ of SPEC.md §3.3).
--
-- Note the unix package's naming traps: @LocalMode@ is @CLOCAL@ (a modem
-- flag), not canonical mode; canonical mode is @ProcessInput@.
rawInput :: TerminalAttributes -> TerminalAttributes
rawInput a =
  withTime (withMinInput cleaned 0) 30
  where
    cleaned =
      foldl withoutMode a [ProcessInput, EnableEcho, KeyboardInterrupts]

-- | Read one key from the tty.  Returns Nothing when the refresh timeout
-- elapsed without a keypress.  Reads one byte at a time, as specified.
readKey :: RawTty -> IO (Maybe Char)
readKey tty = alloca $ \(buf :: Ptr Word8) -> do
  n <- fdReadBuf (ttyFd tty) buf 1
  if n == 0
    then return Nothing
    else do
      w <- peek buf
      return (Just (toEnum (fromIntegral w)))
