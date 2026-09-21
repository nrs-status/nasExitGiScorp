{ pkgs, pkgsLib, ... }:
let
	script = pkgs.writeText "reload-flakes.py" (builtins.readFile ./reload-flakes.py);
in
pkgs.writeShellApplication {
		name = "reload-flakes";
		runtimeInputs = [
			pkgs.python3 # tomllib (stdlib since 3.11) for the TOML config
			pkgs.nix # nix flake update / nix flake metadata
			pkgs.git # dirty-tree detection and `git push -u origin main`
		];
		text = "${pkgsLib.getExe pkgs.python3} ${script} \"$@\"";
	}
