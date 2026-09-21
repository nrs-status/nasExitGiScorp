# Creates a new VM from ../bare.nix (`import` + `extendModules`), adding exactly
# one single new service: `pi-json` (see the `wserviceModule` below).
#
# The service reads the contents of a string located in the vm's
# /sys/firmware/qemu_fw_cfg tree and calls `pi --mode json` with it, streaming
# pi's JSON event output to a unix socket the host can read.
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
# `run-pi-vm' in ../default.nix, from ./runWserviceVm.py, wires all of
# this up): the host's qemu command line
# passes a tab-separated mounts manifest as the fw_cfg file opt/pi/mounts,
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
{
  nixosSystem,
  modulesPath,
  pkgs,
  localPkgs,
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
  # Python program (the microvm variant in ../microvm/ uses the exact same
  # program):
  # only the store paths of the few host binaries it needs are substituted in
  # here at build time, keeping this module readable.
  pi-json = pkgs.runCommand "pi-json"
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

  # The one single new service of this vm.
  wserviceModule =
    { lib, ... }:
    {
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

      boot.kernelModules = [ "qemu_fw_cfg" ];

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
(import ../bare.nix {
  inherit nixosSystem modulesPath pkgs localPkgs;
} { inherit mountHostNixStore; }).extendModules {
  modules = [ wserviceModule ];
}
