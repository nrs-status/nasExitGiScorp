{
  inputs = {
    mcEatBurg.url = "github:nrs-status/mcEatBurg";
    peachRampSkateboard.url = "github:nrs-status/newPeachRampSkateboard";
    # microvm.nix: modules to run NixOS configurations as micro-VMs
    # (needed by gengBowsArrow/pi-vm). Pinned to the same rev as the
    # parent repository (newFrontArmToPlane) used.
    microvm = {
      url = "github:microvm-nix/microvm.nix/1b99da49e9d1c8f15fd4911f7b8d2c4375758dcd";
    };
  };

  outputs =
    inputs:
    let
      pkgs = inputs.mcEatBurg.pkgs;
      nixpkgs = inputs.mcEatBurg.nixpkgs;
      pkgsLib = inputs.peachRampSkateboard.pkgsLib; # pkgsLib is distinguished from pkgs because logically they are independent: pkgsLib is used to provide glue code to make the repository work, pkgs provides actual build components
      baseLib = inputs.peachRampSkateboard.baseLib;
      modulesPath = "${nixpkgs}/nixos/modules";
      nixosSystem = nixpkgs.lib.nixosSystem;
      microvmFlake = inputs.microvm;
      localPkgsArgs = {
        # abstracting this out is useful for debugging sessions
        inherit
          baseLib
          pkgs
          pkgsLib
          modulesPath
          nixosSystem
          microvmFlake
          ;
      };
      # Packages reference each other (e.g. voice-input -> voice-transcribe,
      # honstarehand -> pi-vm.run-pi-microvm, scripts.bwrap-pi ->
      # scripts.bwrap-wpath), so expose the package set to itself via `fix'.
      localPkgs = pkgs.lib.fix (
        self: import ./gengBowsArrow (localPkgsArgs // { localPkgs = self; })
      );
    in
    {
      packages."x86_64-linux" = localPkgs;
    };
}
