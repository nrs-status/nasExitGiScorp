# img-builder — a CLI that takes a WiFi network (ssid + password) and a root
# password, and builds a minimal non-graphical NixOS installer ISO that tries
# to connect to that WiFi network at boot, logs the `nixos` user into a shell
# that echoes the WiFi connection state until it successfully connects, and
# has root's password set to the given password.  Root's shell is left
# untouched so nixos-everywhere can use it to install NixOS.
#
# The CLI (bin/img-builder) hashes the passwords and calls `nix build` on
# ./iso.nix, a very simple extension of the official minimal installer
# (installation-cd-minimal.nix) pinned to this repository's nixpkgs.
{
  pkgs,
  pkgsLib,
  ...
}:
pkgs.runCommand "img-builder"
  {
    version = "1.0.0";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta = {
      description = "Build a minimal non-graphical NixOS installer ISO that auto-connects to a given WiFi network, logs the nixos user into a shell echoing the WiFi connection state until connected, and sets root's password";
      mainProgram = "img-builder";
      platforms = pkgsLib.platforms.linux;
    };
  }
  ''
    mkdir -p $out/bin $out/share/img-builder

    install -Dm444 ${./iso.nix} $out/share/img-builder/iso.nix

    substitute ${./img-builder.sh} $out/bin/img-builder \
      --subst-var-by nixpkgsPath ${pkgs.path} \
      --subst-var-by isoNix "$out/share/img-builder/iso.nix"
    chmod +x $out/bin/img-builder

    wrapProgram $out/bin/img-builder \
      --prefix PATH : ${pkgs.lib.makeBinPath [
        pkgs.mkpasswd   # hash the root password (yescrypt)
        pkgs.wpa_supplicant # wpa_passphrase: derive pskRaw from ssid+password
        pkgs.jq         # write the ssid/psk/hash JSON consumed by iso.nix
        pkgs.nix        # `nix build -f iso.nix ...`
      ]}
  ''