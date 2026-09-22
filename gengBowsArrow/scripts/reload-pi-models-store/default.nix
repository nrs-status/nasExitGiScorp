{ pkgs, pkgsLib, ... }:
# reload-pi-models-store: refresh the pinned pi model catalog
# (templeArtemisEphesus/pi/models-store.json) in the frontArmToPlane
# repository pointed at by $FRONTARMTOPLANE_PATH.
#
# pkgs.pi-coding-agent is a runtime input so that (a) Nix builds/downloads
# the raw package and (b) the script invokes that raw binary rather than the
# frontArmToPlane `pi' wrapper.  The exact store path is also baked into the
# script via the @pi@ placeholder for clarity.
let
  pi = pkgsLib.getExe pkgs.pi-coding-agent;
  script = builtins.replaceStrings [ "@pi@" ] [ pi ] (
    builtins.readFile ./reload-pi-models-store.sh
  );
in
pkgs.writeShellApplication {
  name = "reload-pi-models-store";
  runtimeInputs = [
    pkgs.pi-coding-agent # the raw pi CLI whose catalog we extract
    pkgs.git # stage + commit the refreshed models-store.json
  ];
  text = script;
}