# remove-task-state [tmux-session]: unsets the task-state session options
# of a tmux session so that `list-tasked-sessions' no longer lists it.
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "remove-task-state";
  runtimeInputs = [
    pkgs.tmux
  ];
  text = builtins.readFile ./remove-task-state.sh;
}
