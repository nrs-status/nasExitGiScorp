# taskmux <subcommand> ...: a single script for managing tmux task state,
# unifying the previous four scripts:
#   start -> task-underway: marks a tmux session as having a task
#     underway, via the `@task-status' / `@task-description' session
#     options.
#   done -> task-done: marks a tmux session's task as complete, via the
#     `@task-status' session option.
#   list -> list-tasked-sessions: lists every tmux session carrying a
#     task state.
#   clear -> remove-task-state: unsets the task-state session options of
#     a tmux session.
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "taskmux";
  runtimeInputs = [
    pkgs.tmux
    pkgs.gawk
    # coreutils (stty): needed by `taskmux list' to put the terminal in
    # raw mode for the interactive j/k selection.
    pkgs.coreutils
    # git: needed by `taskmux start' with no argument, which defaults
    # the task description to the current git branch's name.
    pkgs.git
  ];
  text = builtins.readFile ./taskmux.sh;
}