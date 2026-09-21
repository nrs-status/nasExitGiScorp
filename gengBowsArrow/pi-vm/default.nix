inputs: rec {
  bare = import ./bare.nix inputs;

  # new vm derived from `bare` via `extendModules`, adding one single new
  # service that calls `pi --mode json` with a string found in the vm's
  # /sys/firmware/qemu_fw_cfg and streams the output to a unix socket the
  # host can read
  wservice = import ./basic/wservice.nix inputs;

  # micro-VM variant of `wservice', built with the modules of the
  # github.com/microvm-nix/microvm.nix repository (see ./microvm/): same
  # purpose, same shared pi-json guest service (../wservicePiJson.py), same
  # fw_cfg/9p/virtio-serial protocol
  microvm-wservice = import ./microvm/wservice-microvm.nix inputs;

  # executable that runs the `wservice' VM and streams its `pi --mode json'
  # JSON event output to stdout (or to a file with -o/-o FILE); shares host
  # directories with the VM over 9p (--workdir/-w, --read-write/-rw,
  # --read-only/-ro), sizes the VM's root disk with the optional option
  # --disk-size/-d (fallback: the PI_VM_DISK_SIZE environment variable, then
  # a 10G default), sets the VM's RAM with the optional option --ram/-r
  # (fallback: the PI_VM_RAM environment variable, then the build-time
  # memorySize) and takes pi's prompt from stdin
  run-pi-vm =
    let
      vmScript = "${(wservice { mountHostNixStore = false; }).config.system.build.vm}/bin/run-pi-vm-vm";
    in
    inputs.pkgs.runCommand "run-pi-vm"
      {
        nativeBuildInputs = [ inputs.pkgs.python3 ];
        meta.mainProgram = "run-pi-vm";
      }
      ''
        mkdir -p $out/bin
        substitute ${./basic/runWserviceVm.py} $out/bin/run-pi-vm \
          --subst-var-by vmScript ${vmScript}
        chmod +x $out/bin/run-pi-vm
        patchShebangs $out/bin/run-pi-vm
      '';

  # executable twin of `run-pi-vm' with the exact same capabilities and
  # behavior (JSON stream to stdout/-o, 9p shares, fw_cfg prompt and api
  # key, disk space set with the optional --disk-size/-d option (fallback:
  # the PI_VM_DISK_SIZE environment variable, then a 10G default), RAM set
  # with the optional --ram/-r option (fallback: the PI_VM_RAM environment
  # variable, then the build-time mem), non-interactive serial console on
  # stderr), except it runs the
  # micro-VM built by `microvm-wservice' via the microvm.nix runner
  # `microvm-run' (which picks up extra qemu options through the QEMU_OPTS
  # environment variable, see `microvm.extraArgsScript' in
  # ./microvm/wservice-microvm.nix). The microvm's /nix/store is a writable
  # overlay (see ./microvm/wservice-microvm.nix): packages can be installed
  # at run time, in an ephemeral overlay recreated on every run.
  run-pi-microvm =
    let
      microvmConfig = microvm-wservice { mountHostNixStore = false; };
      declaredRunner = microvmConfig.config.microvm.declaredRunner;
      # The microvm.nix runner bakes the build-time `microvm.mem' (1536M)
      # into its qemu command line twice: as `-m 1536M' and as the size of
      # the `-object memory-backend-memfd,id=mem' backend that its 9p-share
      # NUMA options require. Appending a second `-m' through QEMU_OPTS
      # would therefore be rejected by qemu ("total memory for NUMA nodes
      # should equal RAM size"). The RAM override (run-pi-microvm's
      # --ram/-r option or PI_VM_RAM environment variable, resolved by the
      # Python host runner) instead rewrites the runner script's baked-in
      # memory size (both occurrences, so -m and the memfd backend stay
      # consistent) to the requested value at start time.
      vmScript = inputs.pkgs.writeShellScript "run-pi-microvm-vm" ''
        memOverride="''${RUN_PI_MICROVM_MEM:-}"
        if [ -n "$memOverride" ]; then
          case "$memOverride" in
            *[[:space:]]*)
              echo "run-pi-microvm-vm: RAM size must not contain " \
                   "whitespace: '$memOverride'" >&2
              exit 1
              ;;
          esac
          sedScript=$(mktemp)
          sed -e "s/${toString microvmConfig.config.microvm.mem}M/$memOverride/g" \
            "${declaredRunner}/bin/microvm-run" > "$sedScript"
          exec bash "$sedScript"
        fi
        exec "${declaredRunner}/bin/microvm-run"
      '';
    in
      inputs.pkgs.runCommand "run-pi-microvm"
        {
          nativeBuildInputs =
            [ inputs.pkgs.python3 inputs.pkgs.makeWrapper ];
          meta.mainProgram = "run-pi-microvm";
        }
        ''
          mkdir -p $out/bin
          substitute ${./microvm/runWserviceMicrovm.py} $out/bin/run-pi-microvm \
            --subst-var-by vmScript ${vmScript}
          chmod +x $out/bin/run-pi-microvm
          patchShebangs $out/bin/run-pi-microvm
          # The script creates the VM's disk image at run time with
          # truncate and mkfs.ext4: make sure both are in PATH even when
          # the caller's environment does not provide them.
          wrapProgram $out/bin/run-pi-microvm \
            --prefix PATH : ${inputs.pkgs.lib.makeBinPath [
              inputs.pkgs.e2fsprogs
              inputs.pkgs.util-linux
            ]}
        '';
}
