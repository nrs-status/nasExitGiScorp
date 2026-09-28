# taskmux — Specification

## 0. About this document

This document contains a high-level overview of the `taskmux` command line tool. This document's main purpose is to serve as a reference for AI agents to use in order to implement the program. It is not meant to give excessively detailed technical information; an agent is expected to fill out the missing details or to make architectural and design decisions about elements that are left underspecified in this document.

Any agent using this document as a starting point for implementing the `taskmux` program is expected to write a second document, SPEC_EXTENSION.md, containing the details missing from this document necessary for the implementation. SPEC_EXTENSION.md should include the interpretation of ambiguities in this document, and design decisions left open or underspecified by this document. The combination of SPEC.md and SPEC_EXTENSION.md should suffice to give a full technical specification of the `taskmux` program.

This document intends to specify a Haskell program. It is expected that any agent implementing this specification will avoid writing the entire program in a single file, and instead will make extensive use of the module system to separate program logic into self-contained pieces implementing a singular logically distinct part of the total program.


## 1. Task state model

A task state is stored entirely in two tmux session options:

| Option               | Meaning                                        | Set by     |
|----------------------|------------------------------------------------|------------|
| `@task-status`       | Task status string: `underway` or `done`       | `start`, `done`, `monitor-pi` |
| `@task-description`  | Free-form task description text                | `start`    |

`@task-status`: Task status string: "underway" or "done" . 
- A session is said to be *tasked* if and only if its `@task-status` option is set
  (non-empty). `@task-description` alone does not make a session tasked.
- Unsetting both options (using `taskmux clear`) removes the task state.
- Options are per-session user options (`@`-prefixed), so they require a
  running tmux server and do not persist beyond the session's lifetime.

## 3. Command-line interface

```
taskmux start <task description>? <tmux session>?
taskmux done <tmux session>?
taskmux list <--one-shot>?|<-1>?
taskmux clear <tmux session>?
taskmux monitor-pi <tmux pane>?
```

**General rules**
- With no arguments at all (`taskmux` bare), print `usage` to stderr and exit
  with status 1.
- An unknown subcommand prints `taskmux: unknown subcommand: <cmd>` to stderr,
  then `usage`, and exits 1.
- Any subcommand receiving more arguments than its maximum prints `usage` and
  exits 1.
- If `<tmux session>` is not passed to those commands that may take it, it is assumed to be the current session.

### 3.1 `start`

```
taskmux start <task description>? <tmux session>?
```

- Accepts at most 2 arguments.
- Sets on the target session:
  - `@task-status` = `underway`
  - `@task-description` = `<task description>`
- If a `<task description>` argument is given, it is used verbatim.
- If `<task description>` is omitted, the name of the current git branch is used
  (`git symbolic-ref --short HEAD`).
- If `<task description>` is omitted and the branch lookup fails (not in a git repository, or detached HEAD),
  `start` prints to stderr:
  ```
  taskmux start: not in a git repository (or no current branch); a task description is required
  ```
  and exits with status 1 **without modifying any session state**.

### 3.2 `done`

```
taskmux done <tmux session>?
```
- Accepts at most 1 argument.
- Sets `@task-status` = `done` on the target session.
- Leaves `@task-description` unchanged.

### 3.3 `list`

```
taskmux list <--one-shot>?|<-1>?
```

- Accepts no arguments.
- Queries every tmux session via
  `tmux list-sessions -F '#{session_name}\t#{@task-status}\t#{@task-description}'`.
- If the tmux server is not running (or goes away mid-refresh), the fetch
  yields an empty result; the script must not abort (errors from tmux are
  suppressed).
- Only sessions with a non-empty `@task-status` are listed. Each listed row is
  rendered as:
  ```
  <session>: <status> - <description>
  ```
  (The bare session name is kept alongside the display line because it is
  needed for `switch-client`; descriptions may contain `:` so the display line
  alone cannot recover the name.)
- If the pre-check `tmux list-sessions` fails (no server), `list` exits 0.
- If no session is tasked, `list` exits 0 (interactive mode still shows a
  "no tasked sessions" notice; non-interactive mode prints nothing).
- The listing is re-fetched every 3 seconds.
- Output is redrawn only when the fetched state has actually changed since the
  last render (string comparison of the full fetched listing).

**Non-interactive mode** (entered when stdin is not a tty, stderr is not a tty):
- Prints the current listing immediately, then loops forever:
  sleep 3s → re-fetch → if changed, reprint.
- When stdout is a tty, the previous listing is erased first (cursor-up N
  lines + clear-to-end, `\033[NA\033[J`); when stdout is redirected, each
  changed listing is printed in full, one after another.
- If the new listing is empty, nothing is printed after the erase.

**One-shot mode** (entered when the --one-shot or -1 flag is passed):
- Prints the current listing immediately, then exits.
- It is expected that the output of this mode can be parsed as a nushell table (through `detect columns`).

**Interactive mode** (stdin *and* stderr are ttys):
- Renders a selectable menu: one line per tasked session, plus a footer
  `j/k: move, Return: switch, q: quit`.
- The selected line is highlighted with reverse video and a `> ` marker;
  unselected lines are prefixed with two spaces.
- With zero tasked sessions it renders:
  ```
  no tasked sessions
  j/k: move, Return: switch, q: quit
  ```
- **Input handling** (reads one byte at a time from `/dev/tty`, with a
  `refresh_secs` timeout so the menu refreshes while idle):
  - `j` — move cursor down (wraps around).
  - `k` — move cursor up (wraps around).
  - Return (`\r` or `\n`) — select the highlighted session and stop the menu.
  - `Escape`, `q` or Ctrl-C (`\003`) — quit without switching.
  - Any timeout (no key within 3 s) — re-fetch state; redraw only if changed.
- If the session list shrinks so that the cursor index is out of range, the
  cursor resets to 0.
- **On selection:** if `$TMUX` is set (inside tmux), run
  `tmux switch-client -t <session>`; otherwise run
  `tmux attach-session -t <session>`.
- Restores the saved terminal settings before switching/attaching and on exit.

### 3.4 `clear`

```
taskmux clear <tmux session>?
```

- Accepts at most 1 argument.
- Unsets both `@task-status` and `@task-description` on the target session
  (`tmux set-option -u`).

### 3.5 `monitor-pi`

```
taskmux monitor-pi <tmux window>?
```

- `<tmux window>` must an integer designating a tmux window in the current session. If it is omitted, exactly a single a single pi coding agent harness must be running in the current session. If more than one pi coding agent harness is running in the current session and no argument was passed taskmux throws an error and exits. More than more than one pi coding agent harness may be running in the current session if a tmux window was explicitly passed.
- This subcommand requires that the current session be already tasked and be either `underway` or `done`. 
- This command monitors the pi process that in the window that was passed as an argument. If that agent's turn is not finished, the session's state is set to `underway`. If that agent's turn is finished and is awaiting user input or otherwise done, the session's state is set to `done`.
