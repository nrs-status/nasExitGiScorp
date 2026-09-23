# list-tasked-sessions: lists every tmux session carrying a task state
# (set by `task-underway' / `task-done', cleared by `remove-task-state').
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "list-tasked-sessions";
  runtimeInputs = [
    pkgs.tmux
    pkgs.gawk
  ];
  text = builtins.readFile ./list-tasked-sessions.sh;
}
