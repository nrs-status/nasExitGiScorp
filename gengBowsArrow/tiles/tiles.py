#!/usr/bin/env python3
"""
tiles.py — a tiled terminal launcher.

Reads a TOML config associating key bindings to {name, command} pairs,
fills the entire terminal with tiles (one per key binding, extra filler
tiles pad the screen), and runs the corresponding command when the user
presses a tile's key.

Piping: if stdin is a pipe (not a TTY), its contents are buffered and
fed to the stdin of whichever command is launched.
"""

import curses
import os
import signal
import subprocess
import sys
import tomllib

# Keys auto-assigned to tiles that did not declare one (home-row first).
AUTO_KEYS = "1234567890qwertyuiopasdfghjklzxcvbnm"

# Placeholder key for empty/filler tiles (unreachable).
FILLER_KEY = "\x00"

# ────────────────────────────────────────────────────────────────
#  Configuration
# ────────────────────────────────────────────────────────────────


def load_config(path):
    """Parse the TOML config and return (title, tiles).

    Expected format (either style works):

        title = "My Launcher"

        [tiles.foo]
        key = "f"           # optional; auto-assigned if omitted
        name = "Fetch mail" # optional; defaults to the tile id
        command = "neomutt"

        # or, compactly:
        [tiles]
        bar = { command = "df -h" }
    """
    with open(path, "rb") as fh:
        data = tomllib.load(fh)

    title = data.get("title", "command tiles")
    raw = data.get("tiles", {})
    if not isinstance(raw, dict) or not raw:
        sys.exit(f"error: config '{path}' has no [tiles] entries")

    tiles, used = [], set()
    for tile_id, spec in raw.items():
        if isinstance(spec, str):  # shorthand: id = "command"
            spec = {"command": spec}
        # Key: explicit "key" field, else the tile id if it is a single char.
        key = str(spec.get("key", "")).strip().lower() or None
        if key is None and len(tile_id) == 1 and tile_id.isprintable():
            key = tile_id.lower()
        if key:
            if len(key) != 1:
                sys.exit(f"error: tile '{tile_id}': key must be a single character")
            if key in used:
                sys.exit(f"error: tile '{tile_id}': duplicate key '{key}'")
            used.add(key)
        tiles.append(
            {
                "id": tile_id,
                "key": key,
                "name": str(spec.get("name", tile_id)),
                "command": str(spec["command"]),
            }
        )

    # Auto-assign keys to tiles that lack one.
    it = iter(AUTO_KEYS)
    for t in tiles:
        if t["key"] is None:
            for k in it:
                if k not in used:
                    t["key"] = k
                    used.add(k)
                    break
            else:
                sys.exit(f"error: no free key left for tile '{t['id']}'")
    return title, tiles


# ────────────────────────────────────────────────────────────────
#  Command execution
# ────────────────────────────────────────────────────────────────


def run_command(command, piped_stdin):
    """Run command in the raw terminal; the caller exits afterwards."""
    # curses session has already ended (wrapper closed it); run in raw terminal
    try:
        proc = subprocess.run(
            command,
            shell=True,
            input=piped_stdin,  # None -> inherit the terminal
        )
        rc = proc.returncode
    except KeyboardInterrupt:
        rc = 130

    print(f"\n[exit {rc}]")


# ────────────────────────────────────────────────────────────────
#  TUI
# ────────────────────────────────────────────────────────────────


def draw(screen, title, tiles, piped_stdin):
    """Draw the full tiled layout."""
    curses.curs_set(0)
    screen.clear()  # full repaint (screen state is invalid after endwin)

    max_y, max_x = screen.getmaxyx()
    keymap = {t["key"]: t for t in tiles}

    # Layout: header row, then a grid of tiles filling the rest.
    header_h = 2
    grid_top, grid_h = header_h, max_y - header_h
    rows, cols = _grid_dims(len(tiles), grid_h, max_x)
    tile_h, tile_w = grid_h // rows, max_x // cols
    # stretch the last row/column so tiles cover the terminal edge-to-edge
    last_h = grid_h - (rows - 1) * tile_h
    last_w = max_x - (cols - 1) * tile_w

    # Header
    flag = "⏳ piped stdin buffered" if piped_stdin is not None else ""
    head = f" {title} — {len(tiles)} commands  {flag}"
    try:
        screen.addnstr(0, 0, head, max_x - 1, curses.A_REVERSE | curses.A_BOLD)
        screen.addnstr(1, 0, " " * max_x, max_x, curses.A_REVERSE)
    except curses.error:
        pass

    # Tiles — enough cells that every tile fits, remainder are fillers
    for i in range(rows * cols):
        r, c = divmod(i, cols)
        y, x = grid_top + r * tile_h, c * tile_w
        h = last_h if r == rows - 1 else tile_h
        w = last_w if c == cols - 1 else tile_w
        if h < 3 or w < 4:
            continue  # pathologically tiny terminal
        _draw_tile(screen, y, x, h, w, tiles[i] if i < len(tiles) else None)
    screen.refresh()


def _grid_dims(n, grid_h, max_x):
    """Pick rows/cols so the grid covers the terminal and fits n tiles,
    keeping tiles roughly 3-6 lines tall and 12-28 chars wide."""
    for tile_h in range(6, 2, -1):
        rows = grid_h // tile_h
        if rows < 1:
            continue
        for tile_w in range(28, 11, -2):
            cols = max_x // tile_w
            if cols >= 1 and rows * cols >= n:
                return rows, cols
    rows = max(1, grid_h // 4)
    cols = max(1, min(-(-n // rows), max_x // 6))  # keep tiles ≥6 chars wide
    return rows, cols


def _draw_tile(screen, y, x, h, w, tile):
    filled = tile is not None
    attr = curses.color_pair(2 if filled else 3) | curses.A_BOLD
    b_tl, b_tr, b_bl, b_br = "┌", "┐", "└", "┘"
    b_h, b_v = "─", "│"

    def put(cy, cx, ch):
        try:
            screen.addstr(cy, cx, ch, attr)
        except curses.error:
            pass  # e.g. the unwritable bottom-right screen corner

    try:
        # Corners + horizontal edges
        put(y, x, b_tl)
        put(y, x + w - 1, b_tr)
        put(y + h - 1, x, b_bl)
        put(y + h - 1, x + w - 1, b_br)
        for cx in range(x + 1, x + w - 1):
            put(y, cx, b_h)
            put(y + h - 1, cx, b_h)
        # Vertical edges + interior
        for cy in range(y + 1, y + h - 1):
            put(cy, x, b_v)
            put(cy, x + w - 1, b_v)
            for cx in range(x + 1, x + w - 1):
                put(cy, cx, " ")
        if filled and h >= 3:
            key = tile["key"]
            label = f"[{key}]"
            name = tile["name"]
            name = name[: w - 2 - len(label) - 2]
            put(y + h // 2, x + 2, label)
            put(y + h // 2, x + 3 + len(label), name)
        elif not filled and h >= 3:
            put(y + h // 2, x + 2, "·")
    except curses.error:
        pass


def main(screen, title, tiles, piped_stdin):
    """One curses session: draw the tiles, wait for one key, return it.

    Returns the pressed key char, 'resize', or None to quit.
    """
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(2, curses.COLOR_CYAN, -1)
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_BLACK)

    keymap = {t["key"]: t for t in tiles}
    screen.keypad(True)
    draw(screen, title, tiles, piped_stdin)

    ch = screen.getch()
    if ch == curses.KEY_RESIZE:
        return "resize"
    if ch in (4, 27):  # ctrl-d / esc quits
        return None
    key = chr(ch).lower() if 0 <= ch < 256 else None
    return key


def entry():
    os.environ.setdefault("ESCDELAY", "50")  # snappy ESC handling
    args = sys.argv[1:]
    if len(args) != 2 or args[0] not in ("-c", "--config"):
        sys.exit(f"usage: {sys.argv[0]} -c CONFIG.toml")
    title, tiles = load_config(args[1])
    keymap = {t["key"]: t for t in tiles}

    # Piped stdin: buffer it (so commands can consume it), then make the
    # terminal our stdin so curses still works.
    piped_stdin = None
    if not sys.stdin.isatty():
        piped_stdin = sys.stdin.buffer.read()
        tty = os.open("/dev/tty", os.O_RDONLY)
        os.dup2(tty, 0)
        os.close(tty)

    signal.signal(signal.SIGWINCH, signal.SIG_DFL)
    try:
        while True:
            key = curses.wrapper(main, title, tiles, piped_stdin)
            if key is None:
                return
            if key == "resize":
                continue  # fresh session picks up the new size
            if key in keymap:
                run_command(keymap[key]["command"], piped_stdin)
                return  # run-and-exit: leave the program after the command
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    entry()