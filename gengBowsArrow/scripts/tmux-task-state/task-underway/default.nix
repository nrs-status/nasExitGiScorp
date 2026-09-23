# task-underway <task-description> [tmux-session]: marks a tmux session as
# having a task underway, via the `@task-status' / `@task-description'
# session options (see the sibling tmux-task-state scripts).
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "task-underway";
  runtimeInputs = [
    pkgs.tmux
  ];
  text = builtins.readFile ./task-underway.sh;
}
