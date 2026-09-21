# SPEC — `tiles.py` (tiled terminal command launcher)

**Version:** 1.0 (branch `1.0`)
**Language:** Python 3.11+ (uses `tomllib` from the standard library)
**Dependencies:** none beyond the Python standard library (requires a
curses-capable terminal and a UTF-8 locale for box-drawing characters).

---

## 1. Overview

`tiles.py` reads a TOML configuration file that associates **key bindings**
with `{name, command}` pairs ("tiles"), fills the **entire terminal** with a
grid of tiles (one per key binding, plus filler tiles that pad the screen),
and displays the tiled screen until the user presses a key.

- Pressing a tile's key binding **runs the corresponding command in the raw
  terminal** (curses is temporarily suspended) and, once the command
  finishes, **the program exits** (*run-and-exit* behavior).
- Pressing `ESC` or `Ctrl-D` on the tiled screen quits the program without
  running anything.
- If stdin is a pipe (not a TTY), its contents are buffered at startup and
  fed to the stdin of whichever command is launched.

## 2. Command-line interface

```
usage: tiles.py -c CONFIG.toml
       tiles.py --config CONFIG.toml
```

| Argument | Meaning |
|---|---|
| `-c CONFIG` / `--config CONFIG` | Path to the TOML configuration file. **Required.** |

- Any other argument combination prints the usage line to stderr and exits
  with a non-zero status.
- `ESCDELAY` is set to `50` ms (if not already set) for snappy ESC handling.
- The program must be run with a controlling terminal; curses is used for
  drawing and single-key input.

## 3. Configuration file format

The configuration is TOML. Two top-level fields are understood:

```toml
title = "My Launcher"        # optional; default: "command tiles"

[tiles.foo]                  # one entry per tile, any number of tiles
key = "f"                    # optional; auto-assigned if omitted
name = "Fetch mail"          # optional; defaults to the tile id
command = "neomutt"          # required; run through the shell
```

### 3.1 Tile entry forms

All of the following are equivalent ways to declare a tile:

```toml
# Full form:
[tiles.foo]
name = "Fetch mail"
command = "neomutt"

# Inline-table form:
[tiles]
foo = { name = "Fetch mail", command = "neomutt" }

# Shorthand form (value is the command; name defaults to the tile id):
[tiles]
foo = "neomutt"
```

### 3.2 Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `key` | string | no | Single character binding for the tile. Compared case-insensitively (stored lowercase). If omitted, a key is **auto-assigned** (see §3.3). If the tile id itself is a single printable character and no `key` is given, the tile id is used as the key. |
| `name` | string | no | Human-readable label shown inside the tile. Defaults to the tile id. |
| `command` | string | **yes** | Shell command executed with `sh -c` semantics (`subprocess.run(..., shell=True)`). A missing `command` is a fatal error (`KeyError` in the current implementation). |

### 3.3 Key assignment

- Keys declared explicitly must be **unique**; duplicates are fatal.
- Tiles without a key get one auto-assigned from the pool

  ```
  1234567890qwertyuiopasdfghjklzxcvbnm
  ```

  in **reading order of the configuration**, skipping keys already in use.
- If the pool is exhausted (more keyless tiles than free keys), the program
  exits with an error naming the tile that could not be bound.

### 3.4 Validation errors (all fatal, exit non-zero)

| Condition | Error message |
|---|---|
| No `[tiles]` entries, or `tiles` is not a table | `error: config '<path>' has no [tiles] entries` |
| A `key` is more than one character | `error: tile '<id>': key must be a single character` |
| Duplicate key | `error: tile '<id>': duplicate key '<key>'` |
| No free key left for an auto-assigned tile | `error: no free key left for tile '<id>'` |
| Missing `command` field | fatal (`KeyError`) |

### 3.5 Upper limit on tiles

There is no explicit limit on the number of tiles, but the terminal grid can
only display a finite number of cells (see §5). Tiles are always kept in the
tile list (and always key-bound), even if the grid is too small to draw them
all. The auto-assign pool (36 keys) bounds keyless tiles.

## 4. Startup behavior

1. Parse arguments; load and validate the TOML config (§3).
2. **Piped stdin:** if stdin is not a TTY, its full contents are buffered
   into memory (`piped_stdin`), and file descriptor 0 is replaced by
   `/dev/tty` so that curses still works. `piped_stdin is not None` is shown
   in the header as `⏳ piped stdin buffered`.
3. `SIGWINCH` handling is set to `SIG_DFL` (resizes are detected via
   curses' `KEY_RESIZE`).
4. Enter the curses event loop (§6).

## 5. TUI layout

The screen is divided into a **header** and a **tile grid**:

```
┌──────────────────────────────────────────────────────┐
│  <title> — <N> commands  [⏳ piped stdin buffered]    │   header rows 0–1
├──────────────────────────────────────────────────────┤
│ [1] Date & time   │ [2] Uptime    │ [3] Who am I  │  │
│ ... grid of tiles ...                                  │
└──────────────────────────────────────────────────────┘
```

- **Header:** 2 rows, drawn with `A_REVERSE | A_BOLD`. Row 0 shows
  ` <title> — <N> commands` (plus the piped-stdin flag when applicable);
  row 1 is a blank reverse-video separator.
- **Grid:** fills rows 2 … bottom, edge-to-edge.
- Every cell is drawn as a box (`┌ ┐ └ ┘ ─ │`) with the tile key and name
  centered vertically, e.g. `[f] Fetch mail`. The name is truncated to fit
  the tile width.
- **Filled tiles** (key-bound) are rendered in **cyan** on the default
  background, bold.
- **Filler tiles** (padding cells with no tile) are rendered dimly
  (black-on-black) with a single centered `·`.
- The **last row/column** is stretched so tiles cover the terminal edge
  exactly (no ragged border).
- On pathologically small terminals (tile height < 3 or width < 4) the cell
  is skipped rather than drawn incorrectly.
- Curses errors while writing (e.g. the unwritable bottom-right corner) are
  silently ignored.

### 5.1 Grid dimension algorithm

`_grid_dims(n, grid_h, max_x)` chooses rows/cols so the grid covers the
terminal and fits `n` tiles, targeting tiles roughly **3–6 lines tall** and
**12–28 chars wide**:

1. For tile height from 6 down to 3: compute candidate rows = `grid_h ÷ tile_h`.
2. For tile width from 28 down to 12 (step 2): compute cols = `max_x ÷ tile_w`.
3. First (tile_h, tile_w) pair with `rows × cols ≥ n` wins.
4. Fallback for tiny terminals: `rows = max(1, grid_h ÷ 4)`,
   `cols = max(1, min(⌈n ÷ rows⌉, max_x ÷ 6))`.

### 5.2 Key handling on the tiled screen

| Key | Action |
|---|---|
| Tile key binding (case-insensitive) | Run the tile's command (§6.2), then **exit the program**. |
| `ESC` | Quit without running anything. |
| `Ctrl-D` (ASCII 4) | Quit without running anything. |
| `Ctrl-C` | Interrupt; the program exits quietly (`KeyboardInterrupt` caught at top level). |
| Terminal resize (`KEY_RESIZE`) | Redraw the whole layout at the new size (a fresh curses session is started). |
| Any other key | Ignored (the program keeps waiting). |

## 6. Runtime behavior

### 6.1 Drawing and redraws

- Each event-loop iteration runs one full curses session
  (`curses.wrapper`), which repaints the screen completely (§5). A resize
  therefore simply starts a new session that repaints at the new size.

### 6.2 Command execution (*run-and-exit*)

When the user presses a tile's key binding:

1. The curses session ends (terminal restored to cooked mode).
2. The tile's `command` string is executed via `subprocess.run(command,
   shell=True)`:
   - If piped stdin was buffered at startup, it is fed to the command's
     stdin; otherwise the command inherits the terminal's stdin.
   - The command's stdout/stderr go directly to the terminal.
3. After the command finishes, the program prints a newline followed by
   `[exit <rc>]` — the command's return code — and **exits**.
   - `Ctrl-C` while the command runs yields rc `130`.
4. The program's own exit status is `0`.

> **Note (history):** earlier versions returned to the tiled screen after
> the command and waited for a keypress ("press any key to return to
> tiles…"). As of this version the program exits immediately after the
> command finishes.

### 6.3 Exit conditions summary

| Situation | Result |
|---|---|
| Tile key pressed → command ran | Exit 0 after printing `[exit <command rc>]` |
| `ESC` / `Ctrl-D` on the tiled screen | Exit 0 |
| `Ctrl-C` on the tiled screen | Exit (KeyboardInterrupt caught) |
| Fatal config error | Exit non-zero with error message |
| Wrong CLI usage | Exit non-zero with usage line |

## 7. Program structure

| Function | Responsibility |
|---|---|
| `load_config(path)` | Parse TOML, validate, assign keys. Returns `(title, tiles)` where each tile is `{id, key, name, command}`. |
| `run_command(command, piped_stdin)` | Run the command in the raw terminal; print `[exit <rc>]`. The caller exits afterwards. |
| `draw(screen, title, tiles, piped_stdin)` | Full repaint: header + tile grid. |
| `_grid_dims(n, grid_h, max_x)` | Compute rows/cols (§5.1). |
| `_draw_tile(screen, y, x, h, w, tile)` | Draw one tile box (filled or filler). |
| `main(screen, ...)` | One curses session: init colors, draw, wait for one key; returns the key char, `'resize'`, or `None` to quit. |
| `entry()` | CLI entry point: parse args, load config, handle piped stdin, run the event loop (§4, §6). |

**Colors initialized:**

| Pair | Meaning |
|---|---|
| 2 | Filled tile: cyan on default background |
| 3 | Filler tile: black on black |

## 8. Repository files

| File | Purpose |
|---|---|
| `tiles.py` | The program (this spec). |
| `example.toml` | Example configuration with **30 tiles** (title `example launcher`). |
| `test_tiles.py` | Headless pty-based test suite (see §9). |
| `run.sh` | Launcher: `./run.sh [CONFIG.toml]` launches the TUI (default config: `example.toml`). `-h`/`--help` prints help. Anything else — multiple arguments, unknown flags/words, or a nonexistent config file — prints the help message to stderr and exits `1`. |
| `flake.nix` | Nix dev shell (`nix develop`) providing python3/ncurses/git, plus a `packages` output exposing a `tiles` binary. |
| `SPEC.md` | This specification. |
| `SUMMARY.md` | Step-by-step summary of the run-and-exit modification task. |

## 9. Test suite (`test_tiles.py`)

Runs the program in a pty of 100×30 and asserts, without human interaction:

1. **Full tiling:** all checked key labels (`[1]`, `[0]`, `[q]`, `[p]`,
   `[a]`, `[l]`, `[z]`, `[x]`), the header title, and filler tiles (`·`)
   are drawn.
2. **Run-and-exit:** pressing `1` runs `date` (output visible), the
   `[exit <rc>]` feedback is printed, and the **process exits**.
3. **ESC quit:** a fresh instance exits on `ESC`.
4. **Piped stdin:** `printf 'hello pipe world\n' | tiles.py -c example.toml`
   shows the buffered-stdin indicator, forwards the data to tile `a`
   (`cat`), and the process exits afterwards with the `[exit <rc>]`
   feedback visible.

Run with `python3 test_tiles.py` (or `nix develop -c python3 test_tiles.py` inside the flake shell).

## 10. Example configuration (30 tiles)

`example.toml` declares exactly 30 tiles with keys `1-9`, `0`, `q…p`,
`a…l`, `z`, `x` — grouped as:

- **System info** (`1`–`9`, `0`): `date`, `uptime`, `whoami; id`,
  `hostnamectl || hostname`, `uname -a`, `df -h /`, `free -h`,
  `lscpu | head -12`, `ps aux --sort=-%cpu | head -15`.
- **Files / git / network** (`q`–`p`): `ls -lah`, `find . -maxdepth 2`,
  `du -ah . | sort -rh | head -15`, `git status`, `git diff --stat`,
  `env | sort`, `ip -brief addr`, `ss -tulnp`, `ping -c 3 <gateway>`,
  `curl ifconfig.me`.
- **Filters / stdin tools** (`a`–`l`, `z`, `x`): echo piped stdin, `wc`,
  `sort | uniq -c`, ROT13, `xxd`, `base64`, `cat -n`, uppercase, `sha256sum`,
  `last -n 5`, `cal`.

The filter tiles (`a`–`x` reading stdin) are the natural targets of the
piped-stdin feature (§4, §6.2).
