-- | Command-line parsing for taskmux.
--
-- Implements the argument-count and subcommand rules of SPEC.md §3:
--
--   * with no arguments at all the command is rejected (the caller prints
--     @usage@ to stderr and exits 1);
--   * an unknown subcommand is rejected with the offending name attached;
--   * subcommands that receive more arguments than their maximum are
--     rejected;
--   * @list@ accepts exactly one optional flag, @--one-shot@ or @-1@.
module Taskmux.Options (Command (..), ParseError (..), parseCommand) where

-- | A parsed taskmux invocation.
data Command
  = -- | @taskmux start [task-description] [tmux-session]@
    Start (Maybe String) (Maybe String)
  | -- | @taskmux done [tmux-session]@
    Done (Maybe String)
  | -- | @taskmux list [--one-shot|-1]@; the flag is one-shot mode.
    ListCmd Bool
  | -- | @taskmux clear [tmux-session]@
    Clear (Maybe String)
  | -- | @taskmux monitor-pi [tmux-window]@; the argument is kept as the
    -- raw string here and validated (integer window index) by the
    -- monitor-pi implementation itself, so it can produce a specific
    -- error message naming the offending argument.
    MonitorPi (Maybe String)
  deriving (Eq, Show)

-- | Why an argument vector could not be parsed.
data ParseError
  = -- | An unknown subcommand; carries the subcommand as typed.
    UnknownSub String
  | -- | No arguments at all, too many arguments for the subcommand, or
    -- an argument that @list@ cannot interpret.
    UsageError
  deriving (Eq, Show)

-- | Parse a full argument vector (without the program name).
parseCommand :: [String] -> Either ParseError Command
parseCommand [] = Left UsageError
parseCommand (sub : rest) = case sub of
  "start" -> case rest of
    -- One positional argument is the task description; two arguments are
    -- description then session (SPEC.md §3.1).
    [d] -> Right (Start (Just d) Nothing)
    [d, s] -> Right (Start (Just d) (Just s))
    [] -> Right (Start Nothing Nothing)
    _ -> Left UsageError
  "done" -> case rest of
    [s] -> Right (Done (Just s))
    [] -> Right (Done Nothing)
    _ -> Left UsageError
  "list" -> case rest of
    [] -> Right (ListCmd False)
    ["--one-shot"] -> Right (ListCmd True)
    ["-1"] -> Right (ListCmd True)
    _ -> Left UsageError
  "clear" -> case rest of
    [s] -> Right (Clear (Just s))
    [] -> Right (Clear Nothing)
    _ -> Left UsageError
  "monitor-pi" -> case rest of
    [w] -> Right (MonitorPi (Just w))
    [] -> Right (MonitorPi Nothing)
    _ -> Left UsageError
  _ -> Left (UnknownSub sub)
