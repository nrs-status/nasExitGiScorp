{ pkgs, pkgsLib, ... }:
# create-pi-session <GIT BRANCH NAME> [<MODEL NAME>]: creates instructions.txt
# in the current directory with neovim (so editor completion is relative to the
# call site), creates a git worktree (via worktrunk's `wt switch --create`),
# moves instructions.txt into it, then opens a tmux session (via `sesh connect`)
# containing two windows: one running `pi "Read and execute ./instructions.txt"`
# with the model (optional second argument or DEFAULT_PI_MODEL environment
# variable), and one plain shell at the new worktree.
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
			pkgs.pi-coding-agent # `pi' runs in the session's first tmux window
		];
		# `wt' is called with `^' so nushell invokes the worktrunk binary directly
		# instead of parsing it as the user's shell-integrated `def wt' wrapper
		# (which would reject unknown flags like `--create' at parse time).
		text = "${pkgsLib.getExe pkgs.nushell} ${script} \"$@\"";
	}
