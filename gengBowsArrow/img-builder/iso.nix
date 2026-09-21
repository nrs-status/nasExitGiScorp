# Builds a minimal, non-graphical NixOS installer ISO that:
#
#   - tries to connect to the given WiFi network at boot (wpa_supplicant
#     with the given ssid/psk),
#   - logs the `nixos` user in automatically on tty1 into a shell that
#     echoes the state of the WiFi connection attempt until it
#     successfully connects (after which an interactive shell is
#     started), and
#   - sets the root password on the installer to the given password
#     (already hashed by the caller).
#
# Root's shell is deliberately left untouched: it must remain the stock
# shell because it is used by nixos-everywhere to install NixOS.  Only
# the `nixos` user's shell is replaced with the WiFi-echo script.
#
# It is a very simple extension of the official minimal installer
# (modules/installer/cd-dvd/installation-cd-minimal.nix) with exactly those
# settings on top.
#
# Called by ./img-builder.sh as:
#
#   nix build -f iso.nix --argstr nixpkgsPath <path> --argstr wifiJson <path>
#
# where wifiJson is a JSON file of shape:
#
#   { "ssid": "...", "psk": "<hex pskRaw>", "hashedPassword": "..." }
#
{
  nixpkgsPath,
  wifiJson,
}: let
  wifi = builtins.fromJSON (builtins.readFile wifiJson);
  nixos = import (nixpkgsPath + "/nixos");
in
(nixos {
  configuration = {
    lib,
    modulesPath,
    pkgs,
    ...
  }: {
    imports = ["${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"];

    # The stock installer uses NetworkManager for interactive WiFi setup
    # (nmtui).  We replace it with wpa_supplicant, which reads
    # networking.wireless.networks and automatically tries to connect to the
    # configured network at boot.
    networking.networkmanager.enable = lib.mkImageMediaOverride false;

    networking.wireless.enable = true;
    networking.wireless.networks = {
      "${wifi.ssid}" = {
        pskRaw = wifi.psk;
      };
    };

    # Set root's password on the installer (takes precedence over the empty
    # initialHashedPassword set by the installation-device profile).
    users.users.root.hashedPassword = wifi.hashedPassword;

    # The `nixos` user is logged in automatically on tty1 and drops into
    # a shell that echoes the state of the WiFi connection attempt until
    # it succeeds.  Root's shell is left as-is: nixos-everywhere uses it
    # to install NixOS.
    services.getty.autologinUser = lib.mkForce "nixos";
    users.users.nixos.shell = let
      wifiEchoShellScript =
        pkgs.writeShellScript "wifi-echo-shell" ''
          export PATH="${pkgs.wpa_supplicant}/bin:${pkgs.iproute2}/bin:${pkgs.bashInteractive}/bin:/run/current-system/sw/bin:$PATH"

          SSID="${wifi.ssid}"

          echo "Attempting to connect to WiFi network '$SSID'..."
          echo "Echoing connection state until connected."

          while true; do
            if [ -n "$(ip -4 route show default 2>/dev/null)" ]; then
              echo "state: CONNECTED ($(ip -4 addr show scope global 2>/dev/null | sed -n 's/^ *inet \([^ ]*\).*/\1/p' | tr '\n' ' '))"
              echo "Successfully connected to WiFi network '$SSID'."
              break
            fi
            state="$(wpa_cli status 2>/dev/null | sed -n 's/^wpa_state=//p')"
            echo "state: ''${state:-starting wpa_supplicant...}"
            sleep 1
          done

          echo "Starting interactive shell."
          exec bash
        '';
    in
      # NixOS requires login shells to be shell packages (i.e. derivations
      # exposing a `shellPath`); wrap the script accordingly.
      pkgs.runCommand "wifi-echo-shell" {
        passthru.shellPath = "/bin/wifi-echo-shell";
        meta.mainProgram = "wifi-echo-shell";
      } ''
        mkdir -p $out/bin
        install -m555 ${wifiEchoShellScript} $out/bin/wifi-echo-shell
      '';
  };
  system = "x86_64-linux";
})
.config.system.build.isoImage