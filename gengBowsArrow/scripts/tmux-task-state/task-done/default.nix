# task-done [tmux-session]: marks a tmux session's task as complete, via
# the `@task-status' session option (see the sibling tmux-task-state
# scripts).
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "task-done";
  runtimeInputs = [
    pkgs.tmux
  ];
  text = builtins.readFile ./task-done.sh;
}
