{ pkgs, pkgsLib, ... }:
	let 
	script = pkgs.writeText "update-twc-fatp-input.nu" (builtins.readFile ./update-twc-fatp-input.nu);
in pkgs.writeShellApplication {
		name = "update-twc-fatp-input";
		text = "${pkgsLib.getExe pkgs.nushell} --config ~/.config/nushell/config.nu ${script} \"$@\"";
	}

