# SPEC_EXTENSION — taskmux implementation details

This document fills in the details of `SPEC.md` that the implementation
had to decide, interpret or add.  Together with `SPEC.md` it forms the
full technical specification of the `taskmux` program as implemented
here.

The program is written in Haskell (as SPEC.md §0 requires), split into
modules (see §7 below), and packaged in this directory via
`default.nix` (cabal project built with the repository's
`haskellPackages`, wrapped so that `tmux` and `git` are on `PATH`).

## 1. Task state model (SPEC.md §1)

* The state is stored exactly as specified: per-session user options
  `@task-status` (non-empty ⇔ tasked; values written by taskmux are
  `underway`/`done`) and `@task-description` (free-form text).
* No option values are validated or normalised: `list` prints whatever
  non-empty `@task-status` string it finds, so a status written by an
  older tool still shows up.

## 2. CLI parsing (SPEC.md §3)

* `parseCommand` (module `Taskmux.Options`) implements the rules:
  * no arguments → usage error (usage to stderr, exit 1);
  * unknown subcommand → `taskmux: unknown subcommand: <cmd>` on
    stderr, then usage, exit 1;
  * more than the maximum number of positional arguments → usage,
    exit 1;
  * `list` accepts exactly zero or one of `--one-shot` / `-1`; any
    other argument (including a second flag) is a usage error.
* `start` positional order is description-then-session, per §3.1;
  with a single argument it is the description (the session defaults
  to the current one).  The old bash implementation had the same
  convention.
* If the current session cannot be determined (`tmux display-message
  -p '#S'` fails) for a command that defaults to it, the command
  prints `taskmux: cannot determine the current tmux session` and
  exits 1.
* tmux failures for the state-mutating commands (`start`, `done`,
  `clear`, and the `switch-client`/`attach-session` of `list`) are
  propagated: the tmux stderr is forwarded and taskmux exits with
  tmux's exit status.

## 3. `list` (SPEC.md §3.3)

* The fetch runs
  `tmux list-sessions -F '#{session_name}\t#{@task-status}\t#{@task-description}'`
  with a **literal tab** in the format string.  (tmux does not
  interpret `\t` escapes in `-F`; the old bash script passed the
  two-character sequence `\t` and therefore never matched anything —
  the Haskell implementation fixes this.)
* Field splitting splits on the first two tabs only; anything after
  the second tab is the description verbatim.  A description
  containing a tab therefore survives (but shifts columns when
  re-parsed by nushell's `detect columns` — unavoidable given the
  format).
* Rows whose status field is empty are dropped (that is the "tasked"
  filter).  Rows with an empty description are kept and rendered with
  an empty description after ` - `.
* Mode selection:
  * `--one-shot`/`-1` → one-shot;
  * otherwise interactive iff stdin **and** stderr are ttys
    (`isatty(0) && isatty(2)`);
  * else non-interactive.
* Pre-check: a plain `tmux list-sessions` is run first; on failure
  (no server) `list` exits 0 in every mode.
* **One-shot**: prints the display lines (if any) and exits 0.
* **Non-interactive**:
  * if the initial listing is empty, nothing is printed and `list`
    exits 0 (matching the "no tasked sessions ⇒ exit 0" rule);
  * otherwise the listing is printed immediately and the loop
    `sleep 3s → fetch → redraw if the fetched listing changed` runs
    forever; comparison is a plain string comparison of the rendered
    listing (so a change is detected even if it only reorders rows);
  * when stdout is a tty the previous listing is erased with
    `\e[<N>A\e[J` (N = number of lines printed last time) before a
    changed listing is drawn; when stdout is redirected each changed
    listing is printed in full; if the new listing is empty, nothing
    is printed after the erase (the next non-empty listing erases the
    residue).
* **Interactive**:
  * the terminal is put in a raw-ish mode via the `unix` package:
    ICANON, ECHO and ISIG off (Ctrl-C arrives as the `\ETX` byte),
    ONLCR/ICRNL left on; `VMIN=0`, `VTIME=30` so a read of one byte
    from `/dev/tty` times out after the 3 s refresh interval.  (Note:
    in the `unix` package `LocalMode` is `CLOCAL`, *not* canonical
    mode — canonical mode is `ProcessInput`.)
  * the frame is drawn only when something changed: the initial draw,
    after a cursor move, or when a re-fetch produced a different
    listing.  Redraws erase the previous frame (frame size = entries
    + footer, or 2 lines for the empty notice) with `\e[<N>A\e[J`.
  * the selected line is drawn reverse-video (`\e[7m … \e[0m`) with a
    `> ` marker; unselected lines get a two-space prefix.
  * keys: `j`/`k` move with wrap-around; Return (`\r` or `\n`)
    selects; Escape, `q` and Ctrl-C (`\ETX`) quit; any other key is
    ignored; a 3 s timeout re-fetches the state.  Arrow keys are
    *not* interpreted (bare Escape quits — this differs from the old
    bash prototype but follows the SPEC's key list literally).
  * when the listing shrinks and the cursor index falls off the end,
    the cursor resets to 0.
  * with zero tasked sessions the menu shows
    `no tasked sessions` + footer and keeps running (it picks up new
    sessions on refresh).
  * on selection the saved terminal settings are restored (and
    `/dev/tty` closed) *before* `tmux switch-client -t <session>` is
    run when `$TMUX` is set, or `tmux attach-session -t <session>`
    otherwise; the settings are likewise restored on quit.

## 4. `monitor-pi` (SPEC.md §3.5)

SPEC.md's synopsis calls the optional argument a *pane*, §3.5 calls
it a *window*; the implementation follows §3.5: the argument is an
integer **window index** of the current session.  Decisions:

* One-shot: the command inspects the pi process, writes the resulting
  status to the current session's `@task-status` and exits 0.  (It is
  meant to be invoked repeatedly, e.g. from a keybinding or a loop;
  making it a long-running daemon would duplicate `list`'s loop.)
* The current session must be tasked: `@task-status` must already be
  `underway` or `done`, otherwise
  `taskmux monitor-pi: current session '<s>' is not tasked (no @task-status); run 'taskmux start' first`
  and exit 1.
* Argument handling:
  * omitted → the pi processes of *all* windows of the current
    session are collected; there must be exactly one, else an error
    (`no pi coding agent harness is running…` / `more than one pi
    coding agent harness is running…; pass a tmux window index`) and
    exit 1;
  * given → it must parse as an integer (else
    `not a tmux window index: <arg>`) and name an existing window of
    the current session (else `session '<s>' has no window with index
    <n>`); that window must contain exactly one pi process (same
    error wording as above, per-window).
* **pi process discovery**: for every pane of the target window
  (pane root = `#{pane_pid}`), the process tree under that root —
  *including the root itself*, since a pane whose command exec'd
  straight into pi has pi as the pane pid — is scanned; a process
  counts as pi iff its `/proc/<pid>/comm` is `pi` (the real launcher
  is a node process whose comm is `pi`), or its command line is
  `…/pi …` directly, or it is a shebang wrapper (`bash`/`sh`/`env`)
  whose first argument is `…/pi`.
* **Turn state**: for the pi pid, read `/proc/<pid>/cwd` and derive
  the pi session directory
  `~/.pi/agent/sessions/--<cwd with '/'→'-', leading '/' dropped>--/`;
  the most recently modified `.jsonl` file in it is parsed.  pi
  appends entries in real time as messages complete, so the last
  message entry decides:
  * last entry has message role `assistant` **and** a terminal
    `stopReason` (`stop`, `length`, `aborted`, `error`) → the agent's
    turn ended and it is waiting for user input → set `done`;
  * anything else — a user message, a tool result, an assistant
    message with `stopReason: toolUse` (its tool calls are still
    running), an unparseable/unknown entry — → the agent is mid-turn
    → set `underway`.
* Undeterminable states (no session directory, no session file, read
  or parse errors, e.g. pi run with `--no-session`) map to
  `underway`: the session stays "busy" until the state can be proven
  finished, which is the conservative direction for a task monitor.
  A freshly started pi whose session file only has the header is
  also reported `underway` — indistinguishable from a first turn in
  progress.

## 5. Git fallback (`start` without description)

* `git symbolic-ref --short HEAD` is run in the *current working
  directory*; its trimmed output is the description.  On any failure
  (not a repository, detached HEAD, git missing) taskmux prints
  `taskmux start: not in a git repository (or no current branch); a task description is required`
  and exits 1 without touching tmux state.

## 6. Errors and exit codes (summary)

| situation | exit |
|---|---|
| usage error / unknown subcommand | 1 |
| `start` without description outside a git repo | 1 (no state change) |
| tmux command fails during `start`/`done`/`clear` | tmux's status |
| `list`: no tmux server, or no tasked sessions (one-shot/non-interactive) | 0 |
| `list` interactive quit | 0 |
| `monitor-pi`: not tasked / not a window index / window missing / pi count ≠ 1 | 1 |
| `monitor-pi` success | 0 |

## 7. Module map

| module | responsibility |
|---|---|
| `Main` | usage, dispatch, `start`/`done`/`clear` |
| `Taskmux.Options` | argument parsing rules |
| `Taskmux.Tmux` | tmux wrappers, task-state options, session/window/pane queries, `switch-client`/`attach`, the `list` fetch |
| `Taskmux.Git` | current git branch |
| `Taskmux.List` | the three `list` modes and the menu |
| `Taskmux.Tty` | `/dev/tty` raw mode (VMIN/VTIME) and single-byte reads |
| `Taskmux.Pi` | `/proc` scanning, pi discovery, pi session-file turn-state |
| `Taskmux.Monitor` | `monitor-pi` argument/window/session rules |

## 8. Packaging

`default.nix` builds the cabal project with the repository's
`haskellPackages` (`callCabal2nix`) and wraps the binary so `tmux`
and `git` are available on `PATH` at runtime.  It is picked up by
`gengBowsArrow/default.nix` as the flake package `.#taskmux`.

## 9. Known limitations

* Descriptions containing tabs break the `list` fetch format (tab is
  the field separator).
* Arrow keys are not handled in the interactive menu (Escape quits);
  use `j`/`k`.
* A pi process started with `--no-session` (or whose session file was
  deleted) is always reported `underway` by `monitor-pi`.
* `monitor-pi` assumes the pi launcher's `comm` is `pi`; a
  differently named node wrapper would not be detected.
