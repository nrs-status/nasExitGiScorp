# voice-input console adaptation — SUMMARY

Goal: make `./gengBowsArrow/voice-input/` work on a bare Linux console with no
window manager. It previously depended on `notify-send` (needs a D-Bus
notification daemon) and `wtype` (needs a Wayland compositor), neither of which
exists on the console. The fix is a `--console` flag that switches the script's
reporting and text-insertion behaviour; the tmux key binding (the console's
push-to-talk entry point) was updated to use it.

## Changes

### 1. `gengBowsArrow/voice-input/default.nix` (this flake)

Added a `--console` flag (before the subcommand) plus two configuration-level
ways to enable the same mode:

- config file key `console = yes` (searched via `$VOICE_INPUT_CONFIG` or
  `${XDG_CONFIG_HOME:-~/.config}/voice-input/config`; commented lines are
  ignored; `yes/true/on/1` enable)
- environment variable `VOICE_INPUT_CONSOLE=1`

Precedence: `--console` > `VOICE_INPUT_CONSOLE=1` > config file `console` key >
default (no = previous graphical behaviour, byte-for-byte unchanged code paths).

With the flag on:

- **Notifications**: instead of `notify-send`, messages are printed to stderr
  (colourised when stderr is a terminal) and additionally flashed on the tmux
  status line via `tmux display-message` when a tmux server is reachable. tmux
  is optional — without it the stderr line is all the user gets. Because tmux
  `run-shell` jobs surface their output, the F13 key binding still shows every
  message.
- **Insertion**: instead of `wtype`, the transcription is typed into the active
  tmux pane with `tmux send-keys -l` (literal text). `TMUX_PANE` is honoured so
  the text lands in the pane the key binding was pressed in. Without a
  reachable tmux server the script fails loudly instead of silently dropping
  the transcription.
- Recording (`pw-record` via pipewire) and all transcription logic are
  unchanged.

Hermeticity: all tmux calls use the store-path tmux (`${pkgs.tmux}`), so
behaviour does not depend on PATH. `usage()` was factored out and now mentions
`--console`.

### 2. `gengBowsArrow/voice-input/config.example`

Documented the new `console` key (commented-out example included).

### 3. `gengBowsArrow/voice-transcribe/transcribe.py` + `default.nix`

The transcriber parses the same configuration file and aborts on unknown keys,
so `console` was added to `DEFAULTS` (accepted, documented, ignored by the
transcriber itself). This keeps one shared config file working for both
programs; unknown keys are still rejected.

### 4. `~/baghdadPlane/flakes/newFrontArmToPlane.update-voice-input-for-console/templeArtemisEphesus/tmux/default.nix`

This modification *was* necessary: the User0/F13 toggle binding only exists
when no graphical session is running, so it must invoke voice-input in console
mode — otherwise it would call `notify-send`/`wtype` and fail on the console.
The binding now runs `voice-input --console start|finish` and additionally
pins `TMUX_PANE=#{pane_id}` (run-shell expands formats, cf. the scrollback
binding in `basic.conf`) so the transcription is typed into the pane F13 was
pressed in even if tmux does not export `TMUX_PANE` to the run-shell job.
Comments updated accordingly.

## Testing (all on separate tmux sockets; the user's real session was untouched)

1. `nix build .#voice-input .#voice-transcribe` — both build; generated script
   passes `bash -n`.
2. Usage output shows the new `--console` option.
3. Mock OpenRouter server (local HTTP returning a canned completion) used for
   deterministic end-to-end tests:
   - `--console transcribe-file <wav>` → text typed into a pane on a test
     socket (`tmux send-keys -l`), verified via `capture-pane`.
   - Full `--console start` / `--console finish` cycle: real `pw-record`
     recording, pid file created/consumed, transcription inserted.
   - No reachable tmux server → loud error "no tmux server running", exit 1.
   - `TMUX_PANE` unset → falls back to the server's most recently active pane.
   - Config file `console = yes` enables console mode without any flag;
     commented `# console = yes` lines are ignored.
   - `VOICE_INPUT_CONSOLE=1` beats config `console = no`; `--console` beats
     config `console = no`.
   - Graphical branch still selected when nothing enables console mode
     (observed it attempting `notify-send`).
4. `voice-transcribe` accepts a config containing `console` and still rejects
   genuinely unknown keys.
5. One real end-to-end transcription against the actual OpenRouter API
   succeeded (insertion into the test pane).
6. Built the modified tmux package from
   `newFrontArmToPlane.update-voice-input-for-console` with
   `--override-input nasExitGiScorp <this worktree>`; the generated
   `main.conf` contains the expected binding (`--console` + `TMUX_PANE=#{pane_id}`),
   the config loads on a separate socket, `user-keys[0]` is set and the User0
   binding is installed (no graphical session in the test shell).
7. Full integration: attached a real client to a fresh test server via a pty,
   ran the exact run-shell command from the binding twice (toggle) with the
   job environment tmux provides (`TMUX` points at the server's own socket —
   verified by dumping a run-shell job's env); recording started, finished,
   and the transcription appeared in the pane.

## Cleanup

Test tmux servers killed, stale sockets removed, mock server stopped, no
`pw-record` left running, pid file removed. Nothing was committed.
