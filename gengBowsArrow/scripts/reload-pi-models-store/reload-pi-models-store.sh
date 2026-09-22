#!/usr/bin/env bash
# reload-pi-models-store: refresh the pinned pi model catalog.
#
# The `pi' wrapper package in the frontArmToPlane (a.k.a. newFrontArmToPlane)
# repository installs a checked-in copy of pi's dynamically refreshed model
# catalog (templeArtemisEphesus/pi/models-store.json) into
# ~/.pi/agent/models-store.json.  That copy goes stale over time, so this
# script:
#
#   1. builds/downloads the raw `pkgs.pi-coding-agent' (provided on PATH by
#      the surrounding Nix wrapper, no frontArmToPlane files involved),
#   2. runs `pi update --models' once to force pi to re-fetch the current
#      provider catalogs into ~/.pi/agent/models-store.json,
#   3. copies that freshly generated file over
#      "$FRONTARMTOPLANE_PATH/templeArtemisEphesus/pi/models-store.json",
#   4. commits the change in the frontArmToPlane repository with a message
#      describing what happened.
#
# FRONTARMTOPLANE_PATH must point at the frontArmToPlane check-out holding
# templeArtemisEphesus/pi/models-store.json.
set -euo pipefail

readonly commit_path="templeArtemisEphesus/pi/models-store.json"

log() { printf 'reload-pi-models-store: %s\n' "$*"; }
die() { printf 'reload-pi-models-store: error: %s\n' "$*" >&2; exit 1; }

if [[ -z "${FRONTARMTOPLANE_PATH:-}" ]]; then
  die "FRONTARMTOPLANE_PATH is not set; point it at the frontArmToPlane repository"
fi

# Allow the conventional "~/..." spelling in the environment variable.
target="${FRONTARMTOPLANE_PATH/#\~/$HOME}"
[[ -d "$target" ]] || die "FRONTARMTOPLANE_PATH is not a directory: $target"
[[ -f "$target/$commit_path" ]] || die "missing catalog file: $target/$commit_path"

git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "$target is not inside a git work tree"
git_top="$(git -C "$target" rev-parse --show-toplevel)"
[[ "$(realpath "$git_top")" == "$(realpath "$target")" ]] \
  || die "$target is not the root of its git repository (top level: $git_top)"

# @pi@ is substituted at build time with the raw pkgs.pi-coding-agent binary,
# so the frontArmToPlane `pi' wrapper cannot shadow it.
readonly pi_bin="@pi@"

log "building/refreshing model catalogs with $pi_bin"
"$pi_bin" update --models

readonly home_store="$HOME/.pi/agent/models-store.json"
[[ -f "$home_store" ]] || die "pi did not produce $home_store"

log "installing $home_store -> $target/$commit_path"
install -m 644 "$home_store" "$target/$commit_path"

git -C "$target" add -- "$commit_path"

if git -C "$target" diff --cached --quiet -- "$commit_path"; then
  log "models-store.json is already up to date; nothing to commit"
  exit 0
fi

version="$("$pi_bin" --version 2>/dev/null | head -n1 || true)"
[[ -n "$version" ]] || version="unknown"

msg="pi: refresh models-store.json from pi-coding-agent ${version}

Regenerated ~/.pi/agent/models-store.json by running
'pi update --models' with the raw pkgs.pi-coding-agent (${version}) and
copied the resulting provider catalog over
templeArtemisEphesus/pi/models-store.json, so the wrapped pi sees the
current model list.

Automated by gengBowsArrow/scripts/reload-pi-models-store."

log "committing $commit_path"
git -C "$target" commit -m "$msg" -- "$commit_path"
log "done"