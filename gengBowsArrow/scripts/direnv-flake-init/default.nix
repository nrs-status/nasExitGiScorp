{ pkgs, pkgsLib, ... }:
let
	script = pkgs.writeText "direnv-flake-init.nu" (builtins.readFile ./direnv-flake-init.nu);
in pkgs.writeShellApplication {
		name = "direnv-flake-init";
		runtimeInputs = [
			# NOTE: the wrapper `nushell' package lives in the parent
			# repository; use the plain nixpkgs nushell here.
			pkgs.nushell
			pkgs.nix # `nix flake new`
			pkgs.direnv # `direnv allow`
		];
		text = "${pkgsLib.getExe pkgs.nushell} ${script} \"$@\"";
	}
