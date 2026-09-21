{ pkgs, pkgsLib, ... }:
let
	script = pkgs.writeText "scan-lan.nu" (builtins.readFile ./scan-lan.nu);
in pkgs.writeShellApplication {
		name = "scan-lan";
		runtimeInputs = [
			pkgs.nushell
			pkgs.iproute2 # `ip addr` (find our subnet) + `ip neigh` (read ARP cache)
			pkgs.dnsutils # dig (reverse DNS via the router)
		];
		# NOTE: no root involved at all. The ARP sweep is triggered by
		# unprivileged pings: `ping` is deliberately NOT put in
		# runtimeInputs, because the store iputils ping has no raw-socket
		# capability and would shadow the working one. It resolves to the
		# host's setuid wrapper (/run/wrappers/bin/ping on NixOS) via the
		# inherited PATH, just like the old `sudo arp-scan` did.
		text = "${pkgsLib.getExe pkgs.nushell} ${script} \"$@\"";
	}
