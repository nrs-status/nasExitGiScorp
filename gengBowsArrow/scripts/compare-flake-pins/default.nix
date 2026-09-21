{ pkgs, pkgsLib, ... }:
	let 
	script = pkgs.writeText "compare-flake-pins.nu" (builtins.readFile ./compare-flake-pins.nu);
in pkgs.writeShellApplication {
		name = "compare-flake-pins";
		text = "${pkgsLib.getExe pkgs.nushell} --config ~/.config/nushell/config.nu ${script}";
	}

