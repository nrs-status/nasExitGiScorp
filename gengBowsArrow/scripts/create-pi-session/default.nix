{ pkgs, pkgsLib, ... }:
# create-pi-session <GIT BRANCH NAME> <MODEL NAME>: creates a git worktree
# (via worktrunk's `wt switch --create`), lets you write instructions.txt for
# it with `vipe`, then opens a tmux session (via `sesh connect`) containing
# two windows: one running `pi "Read and execute ./instructions.txt"` with the
# given model, and one plain shell at the new worktree.
let
	script = pkgs.writeText "create-pi-session.nu" (builtins.readFile ./create-pi-session.nu);
in pkgs.writeShellApplication {
		name = "create-pi-session";
		runtimeInputs = [
			pkgs.nushell
			pkgs.git
			pkgs.worktrunk # provides `wt' (worktree management)
			pkgs.sesh # `sesh connect' attaches the prepared tmux session
			pkgs.tmux
			pkgs.moreutils # provides `vipe'
			pkgs.pi-coding-agent # `pi' runs in the session's first tmux window
		];
		# `wt' is called with `^' so nushell invokes the worktrunk binary directly
		# instead of parsing it as the user's shell-integrated `def wt' wrapper
		# (which would reject unknown flags like `--create' at parse time).
		text = "${pkgsLib.getExe pkgs.nushell} ${script} \"$@\"";
	}