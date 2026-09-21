#used as an environment to make it easier to write and test bash scripts for setting up the `pi` vm
{
  nixosSystem,
  modulesPath,
  pkgs,
  ...
}:
{ mountHostNixStore }:
nixosSystem {
  system = "x86_64-linux";
  modules = [
    "${modulesPath}/virtualisation/qemu-vm.nix"
    (
      if mountHostNixStore then
        {
          virtualisation.mountHostNixStore = true;
        }
      else
        {
          # Explicitly disable the 9p mount of the host's /nix/store (its
          # qemu-vm.nix default is true, so an empty module would not do).
          virtualisation.mountHostNixStore = false;
          # Without the host store the guest would boot with an empty
          # /nix/store (the root disk image is empty too), so bake the
          # system's closure into a read-only store image instead.
          virtualisation.useNixStoreImage = true;
          # Layer a tmpfs overlay on the store image (the behavior the host
          # store mount had, too): without a writable store the guest's
          # shutdown hangs after unmounting the store image.
          virtualisation.writableStore = true;
        }
    )
    {
      networking.hostName = "pi-vm";
      system.stateVersion = "26.11";

      services.getty.autologinUser = "root";

      virtualisation.graphics = false;

      virtualisation = {
        memorySize = 2048;
        cores = 4;
        diskSize = 8192;
      };

      environment.systemPackages =
        with pkgs;
        [
          git
          vim
          xxd
        ]
        ++ [ pkgs.pi-coding-agent ];

    }
  ];
}
