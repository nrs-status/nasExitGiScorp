{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "update-twc-fatp-input";
  text = ''
    #!/usr/bin/env bash

    set -euo pipefail

    initial_path="$PWD"

    cd "''${THATWATERCHARMANDER_PATH:-}"

    sudo nix flake update frontArmToPlane
    sudo git add ./flake.lock
    # Only commit when the lockfile actually changed: `git commit` exits non-zero
    # when there is nothing to commit, and with `set -e` that aborted the script
    # before the "--rebuild" block could ever be reached.
    if ! sudo git diff --cached --quiet; then
      sudo git commit -m "updating lockfile's frontArmToPlane input" ./flake.lock
    fi

    if [[ "''${1:-}" == "--rebuild" ]]; then
      sudo nixos-rebuild switch --flake .#wranHearst
    fi



    cd "$initial_path"
  '';
}
