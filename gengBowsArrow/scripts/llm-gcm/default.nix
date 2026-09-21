{ pkgs, pkgsLib, ... }:
let
	script = pkgs.writeText "llm-gcm.nu" (builtins.readFile ./llm-gcm.nu);
in pkgs.writeShellApplication {
		name = "llm-gcm";
		runtimeInputs = [
			pkgs.pi-coding-agent
			pkgs.neovim #nixvim
			pkgs.git
		];
		text = "${pkgsLib.getExe pkgs.nushell} --config ~/.config/nushell/config.nu ${script} \"$@\"";
	}
