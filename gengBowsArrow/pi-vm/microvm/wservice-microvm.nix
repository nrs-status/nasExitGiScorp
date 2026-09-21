#
# Like wservice.nix, this creates a NixOS configuration from a minimal base
# (here: the microvm.nix modules, github.com/microvm-nix/microvm.nix, instead
# of the qemu-vm.nix-based ../bare.nix) and adds exactly one single new
# service: `pi-json`, which reads the contents of a string located in the
# vm's /sys/firmware/qemu_fw_cfg tree and calls `pi --mode json` with it,
# streaming pi's JSON event output to a unix socket the host can read.
#
# The fw_cfg string's contents are left undetermined here; they become
# available due to options passed to the qemu command line later, e.g.
#   -fw_cfg name=opt/pi/json-prompt,string=<contents>
#
# Because AF_UNIX sockets are kernel-local, the output stream crosses the VM
# boundary through a virtio-serial port, which the host's later qemu command
# line bridges to a host unix socket:
#   -chardev socket,id=pi-json,path=<host-socket>,server=on,wait=off
#   -device virtio-serial-pci
#   -device virtserialport,chardev=pi-json,name=pi-json
# The host then reads the stream by connecting a client to <host-socket>, e.g.
#   socat - UNIX-CONNECT:<host-socket>
# Note: qemu discards chardev writes made while no client is attached, so the
# host must connect promptly.
#
# The shared ~/.pi/agent/auth.json resolves the openrouter key through
# `! cat /run/secrets/keys/openrouter`; the service provisions it (mode
# 0600) from the optional fw_cfg file `opt/pi/api-key` if the host passed
# e.g. -fw_cfg name=opt/pi/api-key,file=<path-to-key-file>
#
# Host directories can be shared with the VM over 9p (the packaged runner
# `run-pi-microvm' in ../default.nix, from ./runWserviceMicrovm.py, wires all
# of this up): the host's qemu command line passes a tab-separated mounts
# manifest as the fw_cfg file opt/pi/mounts,
#
#   -fw_cfg name=opt/pi/mounts,file=<manifest>
#
# with one line per share: <workdir|rw|ro> <TAB> <mount tag> <TAB> <guest
# mountpoint>, and exposes each tag as a 9p share, e.g.
#
#   -fsdev local,id=pi-fs0,path=<host path>,security_model=none,readonly=off
#   -device virtio-9p-pci,fsdev=pi-fs0,mount_tag=pi-workdir
#
# The service below mounts each share (read-only ones with ro) and runs pi
# from the workdir share's guest mountpoint. When the pi-json service ends
# (pi finished, or it failed to start), the vm powers itself off, so a host
# runner reading the stream socket sees the stream end cleanly.
#
# The microvm.nix differences from the qemu-vm.nix-based wservice VM:
# - the microvm.nix guest module (`microvmFlake.nixosModules.microvm') builds
#   the VM: the qemu hypervisor boots the kernel directly (`-M microvm`), so
#   there is no bootloader and no virtual display;
# - the runner script (config.microvm.declaredRunner) has no mechanism for
#   extra qemu options like the `run-pi-vm-vm' script's QEMU_OPTS variable,
#   but `microvm.extraArgsScript' provides the same thing: a script run by
#   `microvm-run' at start time whose stdout is word-split into extra qemu
#   command line options. This module sets it to echo the QEMU_OPTS
#   environment variable, so host runners can pass dynamic options exactly
#   like for the non-microvm wservice VM;
# - the host's /nix/store is shared as a static 9p share (tag `ro-store')
#   when `mountHostNixStore' is true, instead of the qemu-vm.nix
#   `virtualisation.mountHostNixStore' option;
# - /nix/store is a writable overlayfs (see the `writableStoreOverlay'
#   volume below): its read-only layers are the store disk (when
#   `mountHostNixStore' is false) or the `ro-store' 9p share (when true),
#   and its writable layer lives on the ext4 volume mounted at
#   /nix/.rw-store. 9p/virtiofs shares do not work as the overlay's upper
#   layer, so the docs resort to a volume for it (microvm.nix docs,
#   "Writable /nix/store overlay" in doc/src/shares.md).
{
  nixosSystem,
  pkgs,
  localPkgs,
  microvmFlake,
  ...
}:
{ mountHostNixStore }:
let
  # fw_cfg entries (contents decided by the host's later qemu command line):
  # - name=opt/pi/json-prompt,string=<contents>: prompt fed to `pi --mode json`
  # - name=opt/pi/api-key,file=<path-to-key-file>: (optional) provisions the
  #   guest's /run/secrets/keys/openrouter from a host file. A `file=`
  #   entry stores the file's exact bytes (no NUL terminator), unlike a
  #   `string=` entry; passing the key as a file also keeps it off the
  #   qemu command line, where it would be visible in `ps` output.
  # The service logic itself lives in the shared ../wservicePiJson.py, a
  # Python program (the basic variant in ../basic/ uses the exact same
  # program): only the store paths of the few host binaries it needs are
  # substituted in here at build time, keeping this module readable.
  pi-json = pkgs.runCommand "pi-json-microvm"
    {
      nativeBuildInputs = [ pkgs.python3 ];
      pi = "${pkgs.pi-coding-agent}/bin/pi";
      mount = "${pkgs.util-linux}/bin/mount";
      modprobe = "${pkgs.kmod}/bin/modprobe";
      systemctl = "${pkgs.systemd}/bin/systemctl";
      pythonInterpreter = "${pkgs.python3.interpreter}";
    }
    ''
      mkdir -p $out/bin
      substituteAll ${../wservicePiJson.py} $out/bin/pi-json
      chmod +x $out/bin/pi-json
    '';

  # The one single new service of this microvm.
  wserviceMicrovmModule =
    { lib, ... }:
    {
      networking.hostName = "pi-microvm";
      system.stateVersion = "26.11";

      microvm = {
        hypervisor = "qemu";
        # QEMU hangs if memory is exactly 2GB (microvm.nix issue #171), and
        # pi needs some room: 1536M, like the microvm.nix examples.
        mem = 1536;
        vcpu = 4;
        # qemu user networking (slirp), like the qemu-vm.nix-based wservice VM
        interfaces = [
          {
            type = "user";
            id = "eth0";
            mac = "52:54:00:00:04:21";
          }
        ];
        # `microvm-run' has no mechanism for extra qemu options of its own,
        # but extraArgsScript is run at start time and its stdout is word-
        # split into extra qemu command line options: echo the QEMU_OPTS
        # environment variable, so host runners (run-pi-microvm, from
        # ./runWserviceMicrovm.py) can pass 9p shares, the virtio-serial
        # chardev and the fw_cfg entries dynamically, exactly like the
        # non-microvm `run-pi-vm-vm' script supports.
        extraArgsScript = ''
          echo ''${QEMU_OPTS:-}
        '';
      };

      # Share the host's /nix/store read-only over 9p (microvm.nix example
      # style: mounted at /nix/.ro-store and bind-mounted to /nix/store by
      # the guest module). Without it, the microvm boots from a read-only
      # store disk instead (microvm.storeOnDisk defaults to that when no
      # /nix/store share is declared).
      #
      # With the writable store overlay below, /nix/store is an overlayfs
      # whose lower (read-only) layer is exactly this share (mountPoint
      # /nix/.ro-store) when `mountHostNixStore' is true, and the store disk
      # (mounted read-only at /nix/.ro-store by the microvm.nix guest
      # module) when it is false: the guest module sets the overlay's
      # lowerdir to the host store share's mount point in the former case
      # and to /nix/.ro-store (the ro store disk) in the latter.
      microvm.shares = lib.mkIf mountHostNixStore [
        {
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }
      ];

      # Writable /nix/store overlay (microvm.nix docs, doc/src/shares.md,
      # "Writable /nix/store overlay"): setting `writableStoreOverlay' makes
      # the guest module mount /nix/store as an overlayfs with lowerdir
      # /nix/.ro-store (see above) and upperdir/workdir inside this path, so
      # packages can be installed (nix build, nix-shell, nix profile, ...)
      # at run time even though the lower layers are read-only.
      #
      # The overlay's upper layer must be on a writable filesystem: 9p and
      # virtiofs shares do not work there, so the docs resort to a volume.
      # The volume image path is relative: it is created (labeled and
      # formatted, `autoCreate' is the default) by the microvm.nix runner's
      # start script in its working directory, which run-pi-microvm's host
      # runner sets to its own ephemeral temporary directory (deleted when
      # the VM is done). The overlay is therefore recreated on every run,
      # exactly as the microvm.nix docs recommend: the Nix database keeps
      # only what the VM's NixOS system closure needs, so it forgets
      # packages built in the overlay after every reboot anyway.
      microvm.writableStoreOverlay = "/nix/.rw-store";
      microvm.volumes = [
        {
          image = "nix-store-overlay.img";
          # ext4 labels are limited to 16 bytes: keep this one short.
          label = "rw-store";
          mountPoint = "/nix/.rw-store";
          size = 10240;
        }
      ];

      # The runtime-added devices (virtio-serial-pci, virtio-9p-pci) are PCI
      # devices. requirePci in microvm.nix's qemu runner is computed from the
      # *static* shares/interfaces, so force pcie on for the microvm machine
      # to make sure the runtime-added PCI devices can always be attached.
      microvm.qemu.machineOpts = {
        accel = "kvm:tcg";
        mem-merge = "on";
        acpi = "on";
        pit = "off";
        pic = "off";
        pcie = "on";
        rtc = "on";
        usb = "off";
      };

      # /sys/firmware/qemu_fw_cfg is exported by CONFIG_FW_CFG_SYSFS
      # (drivers/firmware/qemu_fw_cfg.c). Upstream Kconfig defaults it to `n`
      # and none of the NixOS kernel configs enable it either, so extend the
      # kernel packages with it.
      boot.kernelPackages = pkgs.linuxPackages.extend (
        _: super: {
          kernel = super.kernel.override {
            structuredExtraConfig = with lib.kernel; {
              FW_CFG_SYSFS = module;
              FW_CFG_SYSFS_CMDLINE = yes;
            };
          };
        }
      );

      boot.kernelModules = [ "qemu_fw_cfg" "virtio_console" ];

      # qemu user networking (slirp) is IPv4-only, so AAAA answers are
      # unusable in the guest and pi's API calls fail with connection errors
      # when DNS prefers them; disable IPv6 in the guest.
      boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = true;
      boot.kernel.sysctl."net.ipv6.conf.default.disable_ipv6" = true;

      systemd.services.pi-json = {
        description = "pi-json: stream `pi --mode json` output to a unix socket the host can read";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        # pi's wrapper script runs through `#!/usr/bin/env bash`, so bash must
        # be on the service's PATH.
        path = with pkgs; [
          bash
          coreutils
        ];
        environment.HOME = "/root";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pi-json}/bin/pi-json";
          # pi stderr (prompt size, key provisioning, pi errors) stays visible
          # in the journal; pi stdout is streamed to the host unix socket.
          Restart = "no";
          # Whatever way this service ends (pi finished, fw_cfg missing, ...),
          # the vm has no reason to keep running: power it off so the host's
          # runner sees the end of the JSON stream (qemu closing the socket).
          ExecStopPost = "${pkgs.systemd}/bin/systemctl poweroff --no-block";
        };
      };
    };
in
nixosSystem {
  system = "x86_64-linux";
  modules = [
    microvmFlake.nixosModules.microvm
    wserviceMicrovmModule
  ];
}
