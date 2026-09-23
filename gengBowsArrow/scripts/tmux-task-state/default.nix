# tmux-task-state: a grouping directory for the tmux task-state scripts
# (task-underway, task-done, list-tasked-sessions, remove-task-state).
# Imports its subdirectories the same way the parent `scripts' directory
# imports its entries, yielding a nested package set, e.g.
# <flakeref>.packages.x86_64-linux.scripts.tmux-task-state.task-done.
inputs:
inputs.baseLib.importPairsOfDirPath {
  dirPath = ./.;
  pred = x:
    (dirOf x == ./.) && baseNameOf x != "default.nix";
  inputsForImportPairs = inputs;
  excludeDirectories = false;
}
