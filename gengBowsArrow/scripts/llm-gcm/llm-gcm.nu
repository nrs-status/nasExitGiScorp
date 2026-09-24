#!/usr/bin/env nu
# git-commit-llm-completion — generate a suggested commit message for the
# currently staged changes with `pi`, open it in a neovim buffer, and commit
# the staged changes with the resulting message once the buffer is saved and
# neovim is exited. Quitting neovim without saving aborts the commit.

const MAX_DIFF_CHARS = 60000

def main [
  --dry-run # Print the generated message and exit (no neovim, no commit)
  --model: string # Optional model pattern or ID passed through to `pi` (e.g. "anthropic/claude-sonnet-4-5")
] {
  # Sanity checks
  let repo = (git rev-parse --show-toplevel | complete)
  if $repo.exit_code != 0 {
    error make {msg: "not inside a git repository"}
  }

  # `git diff --staged --quiet` exits 0 iff there are no staged changes
  let nothing_staged = ((git diff --staged --quiet | complete).exit_code == 0)
  if $nothing_staged {
    error make {msg: "no staged changes: stage something with `git add` first"}
  }

  let branch = ((git branch --show-current | complete).stdout | str trim)
  let diff = ((git diff --staged | complete).stdout)
  let diff_stat = ((git diff --staged --stat | complete).stdout)
  let recent_commits = ((git log --oneline -10 | complete).stdout)

  # Guard against overflowing the model's context window with huge diffs
  let diff = (
    if ($diff | str length) > $MAX_DIFF_CHARS {
      ($diff | str substring 0..$MAX_DIFF_CHARS) + "\n...[diff truncated for the LLM]"
    } else {
      $diff
    }
  )

  let context = (
    [
      $"Repository: ($env.PWD)"
      $"Branch: ($branch)"
      ""
      "### Recently committed subjects (match this repo's style):"
      $recent_commits
      ""
      "### Staged changes summary:"
      $diff_stat
      ""
      "### Full staged diff:"
      $diff
    ]
    | str join "\n"
  )

  let instructions = (
    "You are a commit message writer for a git repository.\n"
    + "Write a suggested git commit message for the staged changes below.\n"
    + "Match the style of the recently committed subjects in this repo.\n"
    + "Start with a concise subject line (imperative mood, ~72 chars or less), followed by a blank line, then a short body explaining the most important details of the change.\n"
    + "Respond with ONLY the commit message itself: no commentary, no markdown code fences, no quotes around the message."
  )

  print "Asking pi for a suggested commit message..."

  # `--mode json` makes pi emit its session events (including per-message
  # usage/cost statistics) as JSON lines on stdout, which we parse below.
  let pi_args = (
    [--no-session -nt -nc --mode json -p $instructions]
    | append (if $model != null { [--model $model] } else { [] })
  )
  let llm_result = ($context | pi ...$pi_args | complete)

  if $llm_result.exit_code != 0 {
    error make {
      msg: $"pi failed with exit code ($llm_result.exit_code): ($llm_result.stderr | str trim)"
    }
  }

  # Parse the JSON event stream. Keep only well-formed JSON lines.
  let events = (
    $llm_result.stdout
    | lines
    | each {|line| try { $line | from json } catch { null } }
    | compact
  )
  # Completed assistant messages (one per turn) carry the authoritative usage
  let assistant_messages = (
    $events
    | where {|e| ($e.type? == "message_end") and ($e.message?.role? == "assistant")}
    | get message
  )

  if ($assistant_messages | is-empty) {
    error make {msg: "pi returned no assistant message, aborting"}
  }

  # The suggested message is the text of the last assistant message
  let message = (
    $assistant_messages
    | last
    | get --optional content
    | default []
    | where {|c| $c.type? == "text"}
    | get --optional text
    | default []
    | str join "\n"
    # Clean up: drop markdown code fences if any, then trim
    | split row "\n"
    | where {|line| not (($line | str trim) | str starts-with "```")}
    | str join "\n"
    | str trim
  )

  if ($message | is-empty) {
    error make {msg: "pi returned an empty message, aborting"}
  }

  # Aggregate tokens and cost over all assistant messages, as recorded by pi
  let total_tokens = (
    $assistant_messages
    | get --optional usage.totalTokens
    | default []
    | math sum
  )
  let total_cost = (
    $assistant_messages
    | get --optional usage.cost.total
    | default []
    | math sum
    | math round --precision 6
  )

  let stats_line = (
    $"llm-gcm: spent ($total_tokens) tokens, cost according to pi session: \$($total_cost)"
  )

  if $dry_run {
    print $message
    print $stats_line
    return
  }

  # Write the message plus a git-style comment footer into a temp file
  let msg_file = (mktemp -t git-commit-msg-XXXXXX --suffix .md)
  (
    [
      $message
      ""
      "# --- git-commit-llm-completion ---"
      "# Edit the commit message above."
      "# Lines starting with '#' are ignored."
      "# Save and exit (:wq) to commit the staged changes with this message,"
      "# or quit without saving (:q!) to abort."
    ]
    | str join "\n"
  ) + "\n"
  | save -f $msg_file

  let mtime_before = (ls $msg_file | get modified | first)

  # Open the message in the user's editor (defaults to neovim)
  let editor_raw = (
    $env.GIT_EDITOR?
    | default ($env.VISUAL? | default ($env.EDITOR? | default "nvim"))
  )
  # treat an empty editor variable as unset
  let editor = (
    if ($editor_raw | str trim | is-empty) {
      "nvim"
    } else {
      $editor_raw | str trim
    }
  )
  print $"Opening ($editor) — save and exit to commit, or quit without saving to abort."
  let editor_parts = ($editor | split row " ")
  run-external ($editor_parts | first) ...($editor_parts | skip 1 | append $msg_file)

  # The commit only happens when the buffer was actually saved
  # (nanosecond-precision mtimes; a save is a strictly newer mtime)
  let mtime_after = (ls $msg_file | get modified | first)
  if not ($mtime_after > $mtime_before) {
    print -e "Buffer was not saved; aborting without committing."
    rm $msg_file
    return
  }

  # Strip comment lines; commit only if something remains
  let final_msg = (
    open --raw $msg_file
    | lines
    | where {|line| not (($line | str trim) | str starts-with "#")}
    | str join "\n"
    | str trim
  )

  if ($final_msg | is-empty) {
    print -e "Commit message is empty; aborting without committing."
    rm $msg_file
    return
  }

  git commit --cleanup=strip -F $msg_file
  rm $msg_file
  print $stats_line
}
