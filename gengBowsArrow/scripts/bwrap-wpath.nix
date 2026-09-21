{ pkgs, ... }:
pkgs.writeShellScript "bwrap-wpath" ''
  #!/usr/bin/env bash
  #
  # bwrap-wrapper.sh — bubblewrap wrapper that inherits the host PATH.
  #
  # Usage: bwrap-wrapper.sh [bubblewrap args and command...]
  #
  set -euo pipefail

  # Locate bubblewrap
  BWRAP="$(command -v bubblewrap || command -v bwrap)" || {
      echo "error: bubblewrap (bwrap) not found in PATH" >&2
      exit 127
  }

  ro_binds=()
  oldifs="$IFS"
  IFS=':'
  for dir in $PATH; do
      IFS="$oldifs"
      # Skip empty or non-existent entries and duplicates.
      if [[ -n "$dir" && -d "$dir" && ! " ''${ro_binds[*]:-} " == *" ''${dir} "* ]]; then
          ro_binds+=(--ro-bind "$dir" "$dir")
      fi
  done
  IFS="$oldifs"

  ro_binds+=(--ro-bind /nix/store /nix/store)

  # Forward every argument to bubblewrap unchanged (after our binds).
  exec "$BWRAP" "''${ro_binds[@]}" "$@"
''
