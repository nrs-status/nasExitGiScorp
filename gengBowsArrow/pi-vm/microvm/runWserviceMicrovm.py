#!/usr/bin/env python3
"""Run the pi `wservice' microvm (irc-phoneFan/pi-vm/microvm/
wservice-microvm.nix, built with the microvm.nix modules) and stream its
`pi --mode json' JSON event output to stdout or to a file.

This is the micro-VM twin of run-wservice-vm
(../basic/runWserviceVm.py): it has the exact same capabilities and behavior, with
the difference that the VM is a microvm.nix microvm (the qemu hypervisor
boots the kernel directly with the QEMU `microvm' machine type).

The prompt fed to `pi' is read from stdin: pipe it in, or type it in a
terminal and finish with Ctrl-D.

Host directories are shared with the VM through qemu 9p shares:

  --workdir/-w        mounted read-write, used as pi's working directory
                      (default: a fresh /tmp/run-pi-microvm-<timestamp>-XXXX
                      directory whose name records when the program ran)
  --read-write/-rw    mounted read-write (repeatable)
  --read-only/-ro     mounted read-only (repeatable)

  --disk-size/-d      disk space allocated to the virtual machine, i.e. the
                      size of the disk image attached to the VM as a
                      virtio-blk drive (e.g. 8G, 2048M, or a plain byte
                      count). Optional: falls back to the PI_VM_DISK_SIZE
                      environment variable and then to 10G.

  --ram/-r            RAM allocated to the virtual machine (e.g. 2G, 2048M,
                      or a plain byte count). Optional: falls back to the
                      PI_VM_RAM environment variable and then to the build-
                      time default (1536M, see wservice-microvm.nix).

The 9p shares and the mount manifest (fw_cfg file `opt/pi/mounts') that the
guest service reads to mount them are set up here; see wservice-microvm.nix.

The disk space allocated to the VM is set at run time with the obligatory
option --disk-size/-d: this program creates an ext4-formatted sparse raw disk
image of the requested size in its temporary directory (labeled
`pi-microvm-data') and attaches it to the qemu command line (passed through
QEMU_OPTS, like every other dynamic option) as a virtio-blk drive; the guest
sees it as /dev/vda. The image is ephemeral: it lives in this program's
temporary directory and is deleted when the VM is done.

The JSON event stream crosses the VM boundary through a virtio-serial port
that qemu bridges to a host unix socket (-chardev socket,server=on,wait=off);
this program connects to that socket as soon as qemu starts listening and
forwards everything it receives to stdout or to --output/-o. qemu discards
chardev writes made while no client is attached, so the connect must happen
promptly (the guest's pi-json service only starts writing after boot, so
connecting within a second or two is safe).

The VM's serial console (kernel messages, getty) is non-interactive here: it
cannot take over the terminal the program is run from (the subprocess's stdin
is /dev/null, so there is no way to type into the VM's console shell); all of
its output is sent to this program's stderr. When the program finishes, it
also reports on stderr the host locations of all the paths that were passed
to it (via --workdir/-w, --read-write/-rw and --read-only/-ro) and shared
with the VM.

The host's /run/secrets/keys/openrouter, if it exists and is readable, is
passed to the VM through the fw_cfg file `opt/pi/api-key' (see
wservice-microvm.nix).

The microvm.nix runner (`microvm-run') has no mechanism for extra qemu
options of its own, but the configuration (wservice-microvm.nix) sets
`microvm.extraArgsScript' to a script that echoes the QEMU_OPTS environment
variable; this program passes all of its dynamic qemu options (9p shares,
virtio-serial chardev, fw_cfg entries) through that variable, word-split like
the non-microvm `run-pi-vm-vm' script does.
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime

# Substituted at build time (see ../default.nix): the microvm.nix runner of
# the wservice-microvm configuration, e.g. .../bin/microvm-run. It runs qemu
# with extra options taken from the QEMU_OPTS environment variable (see
# `microvm.extraArgsScript' in wservice-microvm.nix).
VM_SCRIPT = "@vmScript@"

# fw_cfg names expected by the guest's pi-json service (see
# wservice-microvm.nix).
FW_CFG_PROMPT = "opt/pi/json-prompt"
FW_CFG_MOUNTS = "opt/pi/mounts"
FW_CFG_API_KEY = "opt/pi/api-key"
FW_CFG_MODEL = "opt/pi/model"
HOST_API_KEY_PATH = "/run/secrets/keys/openrouter"

# 9p mount tags and the guest mount points the pi-json service mounts them at.
TAG_WORKDIR = "pi-workdir"
GUEST_WORKDIR = "/mnt/workdir"
TAG_RW_FMT = "pi-rw-{0}"
GUEST_RW_FMT = "/mnt/rw-{0}"
TAG_RO_FMT = "pi-ro-{0}"
GUEST_RO_FMT = "/mnt/ro-{0}"

# How long to wait for qemu to start listening on the JSON stream socket.
SOCKET_CONNECT_TIMEOUT = 300

# Disk size resolution (CLI option --disk-size/-d > PI_VM_DISK_SIZE > this
# default): the size of the disk image attached to the VM.
DISK_SIZE_ENV = "PI_VM_DISK_SIZE"
DEFAULT_DISK_SIZE = "10G"

# RAM size resolution (CLI option --ram/-r > PI_VM_RAM > no override, i.e.
# the microvm's build-time mem from wservice-microvm.nix). The resolved
# size is passed to the wrapped VM start script through the
# RUN_PI_MICROVM_MEM environment variable (see ../default.nix): the
# microvm.nix runner bakes its build-time memory into its qemu command line
# (`-m' plus a matching memory-backend-memfd needed by its 9p-share NUMA
# options), so a second `-m' appended through QEMU_OPTS would be rejected
# by qemu; the wrapper script rewrites the baked-in memory size instead.
RAM_ENV = "PI_VM_RAM"
RUNNER_MEM_ENV = "RUN_PI_MICROVM_MEM"


def fail(message):
    print(f"run-pi-microvm: {message}", file=sys.stderr)
    sys.exit(1)


def share_path(path, flag):
    """Validate and normalize a host path to be shared with the VM."""
    real = os.path.realpath(path)
    if not os.path.isdir(real):
        fail(f"{flag}: not a directory: {path}")
    # QEMU_OPTS is word-split by the microvm's extraArgsScript, so paths with
    # whitespace would produce broken qemu command lines.
    if any(c.isspace() for c in real):
        fail(f"{flag}: path contains whitespace, which the VM start script "
             f"would split on: {path!r}")
    return real


def create_disk_image(path, size, label):
    """Create an ext4-formatted sparse raw disk image of the requested size
    (e.g. 8G, 2048M, or a plain byte count) at path, with the filesystem
    label `label'. The image is attached to the VM with --disk-size/-d
    semantics: it is the disk space allocated to the virtual machine.
    """
    for tool in ("truncate", "mkfs.ext4"):
        if shutil.which(tool) is None:
            fail(f"{tool} is needed to create the VM's disk image but is not "
                 "in PATH")
    result = subprocess.run(["truncate", "-s", size, path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"could not create the {size} disk image at {path}: "
             f"{result.stderr.strip()}")
    result = subprocess.run(["mkfs.ext4", "-L", label, path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"could not format the disk image at {path} as ext4: "
             f"{result.stderr.strip()}")


def parse_args():
    parser = argparse.ArgumentParser(
        prog="run-pi-microvm",
        description="Run the pi wservice microvm and stream its "
                    "`pi --mode json' JSON event output to stdout (or to a "
                    "file with -o). The prompt for pi is read from stdin.",
        epilog="The disk space allocated to the VM is set with "
               "--disk-size/-d (default: the PI_VM_DISK_SIZE environment "
               "variable, then 10G). RAM usage is set with --ram/-r "
               "(default: the PI_VM_RAM environment variable, then the "
               "microvm's build-time mem). Host directories are shared "
               "with the VM over 9p: --workdir read-write (pi's working "
               "directory), --read-write read-write, --read-only "
               "read-only.",
    )
    parser.add_argument(
        "-o", "--output", metavar="FILE",
        help="file the JSON stream is written to (default: stdout)",
    )
    parser.add_argument(
        "-d", "--disk-size", dest="disk_size", metavar="SIZE",
        default=None,
        help="disk space allocated to the VM, i.e. the size of the disk "
             "image attached to it as a virtio-blk drive, e.g. 8G, 2048M or "
             "a plain byte count (default: the PI_VM_DISK_SIZE environment "
             "variable, then 10G)",
    )
    parser.add_argument(
        "-r", "--ram", dest="ram", metavar="SIZE",
        default=None,
        help="RAM allocated to the VM, e.g. 2G, 2048M or a plain byte count "
             "(default: the PI_VM_RAM environment variable, then the "
             "microvm's build-time mem)",
    )
    parser.add_argument(
        "-w", "--workdir", metavar="DIR",
        default=None,
        help="host directory mounted read-write to the VM and used as pi's "
             "working directory (default: a fresh timestamped directory "
             "under /tmp, named after the time the program was run)",
    )
    parser.add_argument(
        "-rw", "--read-write", dest="read_write", metavar="PATH",
        action="append", default=[],
        help="host path mounted read-write to the VM (repeatable)",
    )
    parser.add_argument(
        "-ro", "--read-only", dest="read_only", metavar="PATH",
        action="append", default=[],
        help="host path mounted read-only to the VM (repeatable)",
    )
    parser.add_argument(
        "-m", "--model", dest="model", metavar="MODEL",
        default=None,
        help="model name passed to the guest's `pi --model' option "
             "(e.g. openrouter/z-ai/glm-5.3-flash). Optional: when it is "
             "not given, pi keeps the model baked into its wrapper script.",
    )
    parser.add_argument(
        "--api-key-file", dest="api_key_file", metavar="FILE",
        default=None,
        help="file whose contents are passed to the VM as the openrouter "
             "API key (fw_cfg opt/pi/api-key). Optional: when it is not "
             "given, the host key at " + HOST_API_KEY_PATH + " is used if "
             "it exists and is readable.",
    )
    return parser.parse_args()


def add_9p_share(qemu_opts, index, host_path, tag, read_only):
    qemu_opts += [
        "-fsdev",
        "local,id=pi-fs{0},path={1},security_model=none,readonly={2}".format(
            index, host_path, "on" if read_only else "off"),
        "-device",
        "virtio-9p-pci,fsdev=pi-fs{0},mount_tag={1}".format(index, tag),
    ]


def write_mounts_manifest(path, workdir, read_write, read_only):
    """One line per share: <workdir|rw|ro> <TAB> <mount tag> <TAB> <guest
    mountpoint>; parsed by the guest's pi-json service (see
    wservice-microvm.nix)."""
    lines = ["workdir\t{0}\t{1}".format(TAG_WORKDIR, GUEST_WORKDIR)]
    for i, _ in enumerate(read_write):
        lines.append("rw\t{0}\t{1}".format(TAG_RW_FMT.format(i),
                                           GUEST_RW_FMT.format(i)))
    for i, _ in enumerate(read_only):
        lines.append("ro\t{0}\t{1}".format(TAG_RO_FMT.format(i),
                                           GUEST_RO_FMT.format(i)))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def connect_to_stream_socket(sock_path, vm_process, timeout):
    """Repeatedly try to connect to the chardev unix socket qemu listens on.
    Returns the connected socket, or None if qemu exited or the deadline
    passed."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(sock_path)
            return sock
        except OSError:
            sock.close()
            if vm_process.poll() is not None:
                return None
            time.sleep(0.2)
    return None


def resolve_sizes(args):
    """Resolve the disk and RAM sizes: a command line option wins over the
    matching environment variable, and the disk size finally falls back to
    DEFAULT_DISK_SIZE (10G); the RAM size has no further default, so the
    microvm keeps its build-time mem when neither option nor variable is
    set. Returns (disk_size, ram_size_or_None)."""
    disk_size = args.disk_size or os.environ.get(DISK_SIZE_ENV) or \
        DEFAULT_DISK_SIZE
    ram_size = args.ram or os.environ.get(RAM_ENV)
    if ram_size is not None:
        # The RAM size is passed to the wrapped VM start script through the
        # RUN_PI_MICROVM_MEM environment variable, which the start script
        # substitutes into its qemu command line: values with whitespace
        # would produce broken qemu command lines.
        if any(c.isspace() for c in ram_size):
            fail("RAM size must not contain whitespace: {0!r}".format(
                ram_size))
    return disk_size, ram_size


def main():
    args = parse_args()
    disk_size, ram_size = resolve_sizes(args)

    if args.workdir is None:
        # Create the default workdir: a fresh directory under /tmp whose name
        # records the time at which this program was run.
        args.workdir = tempfile.mkdtemp(
            prefix="run-pi-microvm-{0}-".format(
                datetime.now().strftime("%Y%m%dT%H%M%S")),
            dir="/tmp",
        )
        print("run-pi-microvm: no --workdir given, using {0}".format(
            args.workdir), file=sys.stderr)

    workdir = share_path(args.workdir, "--workdir")
    read_write = [share_path(p, "--read-write") for p in args.read_write]
    read_only = [share_path(p, "--read-only") for p in args.read_only]

    with tempfile.TemporaryDirectory(prefix="run-pi-microvm-") as tmp:
        # qemu runs with cwd=tmp so its QMP control socket and other VM temp
        # data stay out of the caller's directory.
        sock_path = os.path.join(tmp, "pi-json.sock")
        prompt_path = os.path.join(tmp, "prompt")
        manifest_path = os.path.join(tmp, "mounts-manifest")

        prompt = sys.stdin.buffer.read()
        if not prompt and sys.stdin.isatty():
            print("run-pi-microvm: type the prompt for pi and finish with "
                  "Ctrl-D", file=sys.stderr)
            prompt = sys.stdin.buffer.read()
        with open(prompt_path, "wb") as f:
            f.write(prompt)

        write_mounts_manifest(manifest_path, workdir, read_write, read_only)

        # The VM's disk, sized by --disk-size/-d (or PI_VM_DISK_SIZE, or
        # the 10G default).
        disk_image = os.path.join(tmp, "pi-microvm-disk.img")
        create_disk_image(disk_image, disk_size, "pi-microvm-data")
        print("run-pi-microvm: disk image ({0}) at {1}".format(
            disk_size, disk_image), file=sys.stderr)
        if ram_size is not None:
            print("run-pi-microvm: RAM size {0}".format(ram_size),
                  file=sys.stderr)
        else:
            print("run-pi-microvm: no RAM size given: using the microvm's "
                  "build-time mem", file=sys.stderr)

        qemu_opts = []

        add_9p_share(qemu_opts, 0, workdir, TAG_WORKDIR, read_only=False)
        for i, host_path in enumerate(read_write):
            add_9p_share(qemu_opts, 1 + i, host_path, TAG_RW_FMT.format(i),
                         read_only=False)
        base = 1 + len(read_write)
        for i, host_path in enumerate(read_only):
            add_9p_share(qemu_opts, base + i, host_path, TAG_RO_FMT.format(i),
                         read_only=True)

        # Attach the disk created above (sized with --disk-size/-d) as a
        # virtio-blk drive: the guest sees it as /dev/vda. (The statically
        # built microvm has no volumes and boots with the /nix/store 9p share
        # instead of a store disk, so /dev/vda is free.)
        qemu_opts += [
            "-drive", "file={0},format=raw,if=none,id=pi-disk".format(
                disk_image),
            "-device", "virtio-blk-pci,drive=pi-disk",
        ]

        # Bridge the guest's pi-json virtserialport to a host unix socket
        # this program reads the JSON stream from (see wservice-microvm.nix).
        qemu_opts += [
            "-chardev",
            "socket,id=pi-json,path={0},server=on,wait=off".format(sock_path),
            "-device", "virtio-serial-pci",
            "-device", "virtserialport,chardev=pi-json,name=pi-json",
        ]

        # The prompt and the mounts manifest, read by the guest's pi-json
        # service from /sys/firmware/qemu_fw_cfg/by_name/<name>/raw.
        qemu_opts += [
            "-fw_cfg", "name={0},file={1}".format(FW_CFG_PROMPT, prompt_path),
            "-fw_cfg", "name={0},file={1}".format(FW_CFG_MOUNTS, manifest_path),
        ]

        # The model for the guest's `pi --model' option, passed through the
        # opt/pi/model fw_cfg file (see wservicePiJson.py).
        if args.model:
            model_path = os.path.join(tmp, "model")
            with open(model_path, "w") as f:
                f.write(args.model)
            qemu_opts += [
                "-fw_cfg", "name={0},file={1}".format(FW_CFG_MODEL,
                                                      model_path),
            ]

        # Openrouter key for the guest's /run/secrets/keys/openrouter: an
        # explicitly given --api-key-file wins over the host key path.
        api_key_path = args.api_key_file or HOST_API_KEY_PATH
        if os.path.isfile(api_key_path) and os.access(api_key_path,
                                                      os.R_OK):
            qemu_opts += [
                "-fw_cfg", "name={0},file={1}".format(FW_CFG_API_KEY,
                                                      api_key_path),
            ]
        else:
            print("run-pi-microvm: {0} not found or not readable: the VM "
                  "will run without an openrouter key".format(
                      api_key_path), file=sys.stderr)

        # RUN_PI_MICROVM_MEM makes the wrapped VM start script rewrite the
        # microvm.nix runner's baked-in memory size (see ../default.nix);
        # without it, the microvm keeps its build-time mem.
        env = dict(os.environ,
                   QEMU_OPTS=" ".join(qemu_opts))
        if ram_size is not None:
            env[RUNNER_MEM_ENV] = ram_size
        # The VM's serial console (kernel messages, getty) is sent entirely to
        # our stderr, and the console is non-interactive: the subprocess's
        # stdin is /dev/null, so running this program never drops the shell it
        # is run from into a shell inside the VM.
        vm_process = subprocess.Popen([VM_SCRIPT], cwd=tmp, env=env,
                                      stdin=subprocess.DEVNULL,
                                      stdout=sys.stderr, stderr=sys.stderr)

        exit_code = 0
        try:
            sock = connect_to_stream_socket(sock_path, vm_process,
                                            SOCKET_CONNECT_TIMEOUT)
            if sock is None:
                fail("could not connect to the VM's JSON stream socket at "
                     "{0}".format(sock_path))
            output = open(args.output, "wb") if args.output else \
                sys.stdout.buffer
            try:
                with sock, output:
                    while True:
                        chunk = sock.recv(65536)
                        if not chunk:
                            break
                        output.write(chunk)
                        output.flush()
            except BrokenPipeError:
                # e.g. the JSON output file's writer closed early (| head)
                pass
            exit_code = vm_process.wait()
        except KeyboardInterrupt:
            exit_code = 130
        finally:
            if vm_process.poll() is None:
                vm_process.terminate()
                try:
                    vm_process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    vm_process.kill()
                    vm_process.wait()
            # The program has finished executing: report on stderr the host
            # locations of the paths it was given and shared with the VM.
            print_host_paths(workdir, read_write, read_only)


def print_host_paths(workdir, read_write, read_only):
    """Report on stderr the host locations of the paths this program was
    given (options --workdir/-w, --read-write/-rw, --read-only/-ro) and
    shared with the VM."""
    print("run-pi-microvm: host locations of the paths passed to this "
          "program:", file=sys.stderr)
    print("run-pi-microvm:   workdir (read-write): {0}".format(workdir),
          file=sys.stderr)
    for path in read_write:
        print("run-pi-microvm:   read-write: {0}".format(path),
              file=sys.stderr)
    for path in read_only:
        print("run-pi-microvm:   read-only: {0}".format(path),
              file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
