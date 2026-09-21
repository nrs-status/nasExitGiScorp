#!/usr/bin/env bash
# launcher.sh — launch the tiles TUI.
#
# Usage:
#   ./run.sh              # launch the TUI with the packaged example config
#   ./run.sh my.toml      # launch the TUI with a custom config
#   ./run.sh -h|--help    # show the help message
set -euo pipefail


help() {
    cat <<EOF
usage: tiles [CONFIG.toml]

Launch the tiles TUI with a TOML configuration file.
Without an argument, the packaged example config is used.

  -h, --help    show this help and exit
EOF
}

if [[ $# -gt 1 ]]; then
    help >&2
    exit 1
fi

case "${1:-}" in
    -h|--help)
        help
        exit 0
        ;;
    "")
        CONFIG="$TILES_EXAMPLE_CONFIG"
        ;;
    -*)
        help >&2
        exit 1
        ;;
    *)
        CONFIG="$1"
        ;;
esac

if [[ ! -f "$CONFIG" ]]; then
    help >&2
    exit 1
fi

exec python3 "$TILES_PY" -c "$CONFIG"
