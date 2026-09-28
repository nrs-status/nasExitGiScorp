-- | Git helpers: the current branch name, used by @taskmux start@ as the
-- default task description (SPEC.md §3.1).
module Taskmux.Git (currentBranch) where

import Control.Exception (SomeException, try)
import System.Process (proc, readCreateProcessWithExitCode)
import System.Exit (ExitCode (..))

-- | @git symbolic-ref --short HEAD@ trimmed of its trailing newline.
-- Returns Nothing when the lookup fails: not inside a git repository, a
-- detached HEAD, git missing, or any other error.
currentBranch :: IO (Maybe String)
currentBranch = do
  r <- try (readCreateProcessWithExitCode (proc "git" ["symbolic-ref", "--short", "HEAD"]) "")
  case (r :: Either SomeException (ExitCode, String, String)) of
    Right (ExitSuccess, out, _) -> do
      let b = unwords (words out)
      return (if null b then Nothing else Just b)
    _ -> return Nothing
