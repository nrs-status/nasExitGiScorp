{
  pkgs,
  pkgsLib,
  localPkgs,
  ...
}:
# honstarehand: a CLI tool (Haskell) that runs pi microvm jobs configured in a
# nix flake's `runConfigs' attribute set and tracks every run in a
# postgresql `run' table (see ./SPEC.md). Internalized from the
# `run-manager.2' worktree; built with the repository's nixpkgs and wrapped
# so that it uses this flake's own `pi-vm.run-pi-microvm' runner and always
# has `nix' on PATH.
let
  honstarehandHaskell = pkgs.haskellPackages.callCabal2nix "honstarehand" ./. { };
in
pkgs.runCommand "honstarehand"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta.mainProgram = "honstarehand";
  }
  ''
    mkdir -p $out/bin
    makeWrapper ${honstarehandHaskell}/bin/honstarehand $out/bin/honstarehand \
      --set HONSTAREHAND_RUN_PI_MICROVM ${localPkgs.pi-vm.run-pi-microvm}/bin/run-pi-microvm \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix ]}
  ''
