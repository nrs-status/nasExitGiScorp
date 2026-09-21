#!/usr/bin/env nu

# Nushell translation of the `flakify` bash function:
#   - bootstrap a flake via nix-direnv's template if flake.nix is missing,
#   - otherwise create .envrc ("use flake") and allow it if .envrc is missing,
#   - finally open flake.nix in $EDITOR (default: vim).

if not ('flake.nix' | path exists) {
    nix flake new -t github:nix-community/nix-direnv .
} else if not ('.envrc' | path exists) {
    $"use flake\n" | save .envrc
    direnv allow
}

let editor = ($env | get --optional EDITOR | default 'vim')
^$editor flake.nix
