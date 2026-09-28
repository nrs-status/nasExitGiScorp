{ pkgs, ... }:
# taskmux: task-state management for tmux sessions, implemented in
# Haskell (see ./SPEC.md and ./SPEC_EXTENSION.md).
#
# The task state of a tmux session is stored in its @task-status /
# @task-description session options; taskmux provides the subcommands
# start, done, list, clear and monitor-pi (the last one derives the
# state from the pi coding agent harness running in a tmux window).
#
# The compiled binary invokes tmux and git through PATH, so the wrapper
# adds both to it.
let
  taskmuxUnwrapped = pkgs.haskellPackages.callCabal2nix "taskmux" ./. { };
in
pkgs.runCommand "taskmux"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "taskmux";
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${taskmuxUnwrapped}/bin/taskmux $out/bin/taskmux \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.tmux
        pkgs.git
      ]}
  ''
