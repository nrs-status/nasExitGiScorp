# taskmux — Specification

**Program:** `taskmux` — unified task-state management for tmux sessions

---

## 1. Task state model

A task state is stored entirely in two tmux session options:

| Option               | Meaning                                        | Set by     |
|----------------------|------------------------------------------------|------------|
| `@task-status`       | Task status string: `underway` or `done`       | `start`, `done` |
| `@task-description`  | Free-form task description text                | `start`    |

`@task-status`: Task status string: "underway" or "done" . 
- A session is *tasked* if and only if its `@task-status` option is set
  (non-empty). `@task-description` alone does not make a session tasked.
- Unsetting both options (`clear`) removes the task state.
- Options are per-session user options (`@`-prefixed), so they require a
  running tmux server and do not persist beyond the session's lifetime.

## 3. Command-line interface

```
taskmux start [task-description] [tmux-session]
taskmux done [tmux-session]
taskmux list
taskmux clear [tmux-session]
```

**General rules**

- With no arguments at all (`taskmux` bare), print `usage` to stderr and exit
  with status 1.
- An unknown subcommand prints `taskmux: unknown subcommand: <cmd>` to stderr,
  then `usage`, and exits 1.
- Any subcommand receiving more arguments than its maximum prints `usage` and
  exits 1 (via `set -e` — the usage function exits 1).
- `<tmux-session>` omitted defaults to the current session
  (`tmux display-message -p '#S'`).

### 3.1 `start`

```
taskmux start [task-description] [tmux-session]
```

- Accepts at most 2 arguments.
- Sets on the target session:
  - `@task-status` = `underway`
  - `@task-description` = `<task-description>`

**Description resolution**

- If a description argument is given, it is used verbatim.
- If omitted, the name of the current git branch is used
  (`git symbolic-ref --short HEAD`).
- If the branch lookup fails (not in a git repository, or detached HEAD),
  `start` prints to stderr:

  ```
  taskmux start: not in a git repository (or no current branch); a task description is required
  ```

  and exits with status 1 **without modifying any session state**.

### 3.2 `done`

```
taskmux done [tmux-session]
```

- Accepts at most 1 argument.
- Sets `@task-status` = `done` on the target session.
- Leaves `@task-description` unchanged.

### 3.3 `list`

```
taskmux list
```

- Accepts no arguments.

**Data fetch**

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

**Refresh behavior (both modes)**

- The listing is re-fetched every 3 seconds (`refresh_secs`).
- Output is redrawn only when the fetched state has actually changed since the
  last render (string comparison of the full fetched listing).

**Non-interactive mode** (entered when stdin is not a tty *or* stderr is not
a tty):

- Prints the current listing immediately, then loops forever:
  sleep 3s → re-fetch → if changed, reprint.
- When stdout is a tty, the previous listing is erased first (cursor-up N
  lines + clear-to-end, `\033[NA\033[J`); when stdout is redirected, each
  changed listing is printed in full, one after another.
- If the new listing is empty, nothing is printed after the erase.

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

- **Terminal setup:** saves the current `stty` settings from `/dev/tty`,
  installs an EXIT trap restoring them, then sets `-echo -icanon -isig`
  (explicitly *not* `raw`, to preserve output post-processing; `-isig` makes
  Ctrl-C arrive as byte `\003` instead of a signal).
- **Input handling** (reads one byte at a time from `/dev/tty`, with a
  `refresh_secs` timeout so the menu refreshes while idle):
  - `j` — move cursor down (wraps around).
  - `k` — move cursor up (wraps around).
  - Return (`\r` or `\n`) — select the highlighted session and stop the menu.
  - `Escape` — may begin an arrow-key sequence: if `[A` / `[B` follow within
    ~0.05 s, treat as up / down; otherwise quit without switching.
  - `q` or Ctrl-C (`\003`) — quit without switching.
  - Any timeout (no key within 3 s) — re-fetch state; redraw only if changed.
- Redraw erases the previously drawn lines (menu occupies `count + 1` lines
  with entries, or 2 lines in the empty state).
- If the session list shrinks so that the cursor index is out of range, the
  cursor resets to 0.
- **On selection:** if `$TMUX` is set (inside tmux), run
  `tmux switch-client -t <session>`; otherwise run
  `tmux attach-session -t <session>`.
- Restores the saved terminal settings before switching/attaching and on exit.

### 3.4 `clear`

```
taskmux clear [tmux-session]
```

- Accepts at most 1 argument.
- Unsets both `@task-status` and `@task-description` on the target session
  (`tmux set-option -u`).

## 4. Exit status

| Situation                                        | Status |
|--------------------------------------------------|--------|
| Bare invocation, usage error, unknown subcommand | 1      |
| `start` with no description outside git repo     | 1      |
| No tmux server / no tasked sessions (`list`)     | 0      |
| Normal completion of any subcommand              | 0      |

The script runs under `set -euo pipefail`, so any unexpected command failure
(e.g. tmux rejecting an unknown session name in `start`/`done`/`clear`)
terminates it with the failing command's non-zero status.

## 5. Packaging (`default.nix`)

- Built with `pkgs.writeShellApplication`, name `taskmux`, body taken from
  `./taskmux.sh`.
- `runtimeInputs`: `tmux`, `gawk`, `coreutils` (for `stty`), `git`.
