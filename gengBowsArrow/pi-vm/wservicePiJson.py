#!/usr/bin/env @pythonInterpreter@
"""The `pi-json' guest service shared by the wservice VM
(basic/wservice.nix) and the wservice microvm (microvm/wservice-microvm.nix):
both configurations have the exact same behavior, so they use this exact same
program.

It reads the prompt the host passed through the qemu fw_cfg string
`opt/pi/json-prompt' (e.g. -fw_cfg name=opt/pi/json-prompt,string=<contents>),
provisions the openrouter key from the fw_cfg file `opt/pi/api-key' if the
host passed one, mounts the 9p host shares listed in the fw_cfg file
`opt/pi/mounts', runs `pi --mode json' from the workdir share with that
prompt, and streams pi's JSON event output into the `pi-json' virtserialport,
which the host's qemu command line bridges to a host unix socket. When pi is
done (or the service fails to start), the VM powers itself off so the host's
runner sees the stream end cleanly.

The store paths of the few host binaries used below are substituted at build
time (see basic/wservice.nix and microvm/wservice-microvm.nix).
"""

import os
import subprocess
import sys

# fw_cfg entries (contents decided by the host's later qemu command line):
# - name=opt/pi/json-prompt,string=<contents>: prompt fed to `pi --mode json`.
#   (fw_cfg "string" entries are NUL-terminated; the trailing NUL and any
#   trailing newlines are stripped below, like bash command substitution
#   would.)
# - name=opt/pi/api-key,file=<path-to-key-file>: (optional) provisions the
#   guest's /run/secrets/keys/openrouter. A `file=` entry stores the file's
#   exact bytes (no NUL terminator); passing the key as a file also keeps it
#   off the qemu command line, where it would be visible in `ps` output.
FW_CFG_PROMPT_RAW = "/sys/firmware/qemu_fw_cfg/by_name/opt/pi/json-prompt/raw"
FW_CFG_KEY_RAW = "/sys/firmware/qemu_fw_cfg/by_name/opt/pi/api-key/raw"
# (optional) model name for `pi --model'; provisioned by the host runner's
# -m/--model option through the fw_cfg file `opt/pi/model'
FW_CFG_MODEL_RAW = "/sys/firmware/qemu_fw_cfg/by_name/opt/pi/model/raw"

# The virtserialport the service streams pi's JSON output into. The host's
# later qemu command line must bridge it to a host unix socket:
#   -chardev socket,id=pi-json,path=<host-socket>,server=on,wait=off
#   -device virtio-serial-pci
#   -device virtserialport,chardev=pi-json,name=pi-json
VPORT_NAME = "pi-json"
VPORT_DEV = "/dev/virtio-ports/pi-json"

# The opt/pi/mounts fw_cfg file the host passes with e.g.
#   -fw_cfg name=opt/pi/mounts,file=<manifest>
# with one line per share: <workdir|rw|ro> <TAB> <mount tag> <TAB> <guest
# mountpoint>, and the host's qemu command line exposing each tag, e.g.
#   -fsdev local,id=pi-fs0,path=<host path>,security_model=none,readonly=off
#   -device virtio-9p-pci,fsdev=pi-fs0,mount_tag=pi-workdir
MOUNTS_MANIFEST = "/sys/firmware/qemu_fw_cfg/by_name/opt/pi/mounts/raw"

# The guest path localPkgs.pi provisions the openrouter key through
# `! cat /run/secrets/keys/openrouter'.
API_KEY_PATH = "/run/secrets/keys/openrouter"

# Binaries substituted at build time (see basic/wservice.nix and
# microvm/wservice-microvm.nix).
PI = "@pi@"
MOUNT = "@mount@"
MODPROBE = "@modprobe@"
SYSTEMCTL = "@systemctl@"

# 9p mount options shared by every share; read-only ones add ,ro.
BASE_9P_OPTS = "trans=virtio,version=9p2000.L,msize=131072"


def log(message):
    """Log to stderr: it stays visible in the guest's journal."""
    print(f"pi-json: {message}", file=sys.stderr)


def fail(message):
    log(message)
    sys.exit(1)


def read_prompt():
    """Read the prompt from the qemu fw_cfg string the host passed later.
    Like bash command substitution, strip the fw_cfg string entry's trailing
    NUL terminator and any trailing newlines."""
    try:
        with open(FW_CFG_PROMPT_RAW, "rb") as f:
            raw = f.read()
    except OSError:
        fail(f"could not read the fw_cfg string at {FW_CFG_PROMPT_RAW}; does "
             "the host qemu command line pass "
             "-fw_cfg name=opt/pi/json-prompt,string=<contents>?")
    return raw.rstrip(b"\0").rstrip(b"\n").decode("utf-8", "replace")


def read_model():
    """Read the optional model name from the opt/pi/model fw_cfg file the
    host passed later (stripping the file's trailing newline/NUL, like
    read_prompt does for the prompt). Returns "" when the host passed no
    model, in which case pi keeps the model baked into its wrapper."""
    try:
        with open(FW_CFG_MODEL_RAW, "rb") as f:
            raw = f.read()
    except OSError:
        return ""
    return raw.replace(b"\0", b"").decode("utf-8", "replace").strip()


def provision_api_key():
    """Provision /run/secrets/keys/openrouter from the opt/pi/api-key
    fw_cfg file if the host provided the key (and it is not there already).
    A fw_cfg `file=` entry holds the file's exact bytes: strip any NULs for
    good measure and drop surrounding whitespace like the xargs pipeline it
    replaces."""
    if os.path.exists(API_KEY_PATH):
        return
    os.makedirs(os.path.dirname(API_KEY_PATH), exist_ok=True)
    try:
        with open(FW_CFG_KEY_RAW, "rb") as f:
            key = f.read()
        key = key.replace(b"\0", b"").decode("utf-8", "replace").strip()
    except OSError:
        key = ""
    if key:
        with open(API_KEY_PATH, "w") as f:
            f.write(key)
        os.chmod(API_KEY_PATH, 0o600)
        log(f"provisioned {API_KEY_PATH} from the opt/pi/api-key fw_cfg file")
    else:
        log(f"no openrouter key: {API_KEY_PATH} is missing and no "
            "-fw_cfg name=opt/pi/api-key,file=<path-to-key-file> was given")


def check_virtserialport():
    """The host's later qemu command line must bridge the `pi-json'
    virtserialport to a host unix socket (see the module header)."""
    if not os.path.exists(VPORT_DEV):
        fail(f"{VPORT_DEV} is missing; the host qemu command line must pass "
             f"-chardev socket,id={VPORT_NAME},path=<host-socket>,"
             f"server=on,wait=off -device virtio-serial-pci "
             f"-device virtserialport,chardev={VPORT_NAME},name={VPORT_NAME}")


def mount_9p_shares():
    """Mount the host 9p shares named in the opt/pi/mounts manifest, if the
    host provided one. Returns the guest mountpoint of the workdir share (or
    "" when there is none)."""
    workdir = ""
    try:
        with open(MOUNTS_MANIFEST) as f:
            lines = f.read().splitlines()
    except OSError:
        log("no opt/pi/mounts fw_cfg entry: no host shares mounted")
        return workdir
    subprocess.run([MODPROBE, "9pnet_virtio"], capture_output=True)
    subprocess.run([MODPROBE, "9p"], capture_output=True)
    for line in lines:
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        mode, tag, mnt = fields
        if not tag:
            continue
        os.makedirs(mnt, exist_ok=True)
        opts = BASE_9P_OPTS + (",ro" if mode == "ro" else "")
        result = subprocess.run(
            [MOUNT, "-t", "9p", "-o", opts, tag, mnt],
            capture_output=True, text=True)
        if result.returncode == 0:
            log(f"mounted 9p share {tag} (mode {mode}) at {mnt}")
        else:
            log(f"failed to mount 9p share {tag} at {mnt}: "
                f"{result.stderr.strip()}")
        if mode == "workdir":
            workdir = mnt
    return workdir


def main():
    prompt = read_prompt()
    log(f"read prompt ({len(prompt)} bytes) from {FW_CFG_PROMPT_RAW}")

    provision_api_key()
    check_virtserialport()

    # pi uses its current working directory as its working directory.
    workdir = mount_9p_shares()
    if workdir:
        log(f"running pi from the workdir {workdir}")
        os.chdir(workdir)

    # The host can override pi's model with its -m/--model option (fw_cfg
    # opt/pi/model); the wrapper's baked-in `--model' appears earlier on the
    # command line, so the last `--model' (ours) wins.
    model = read_model()
    if model:
        log(f"using model {model} from {FW_CFG_MODEL_RAW}")

    # Stream pi's JSON event output into the virtserialport; qemu forwards it
    # to the host unix socket. qemu discards chardev writes while no client is
    # attached to the host socket: the host must connect promptly.
    pi_command = [PI, "--mode", "json", "-p", "--no-session"]
    if model:
        pi_command += ["--model", model]
    pi_command.append(prompt)
    with open(VPORT_DEV, "wb") as vport:
        result = subprocess.run(pi_command, stdout=vport)
    log(f"pi exited with status {result.returncode}; powering the VM off")
    # This vm exists only to run pi on the fw_cfg prompt and stream its
    # output: once pi is done there is nothing left to do, so power off.
    # (qemu then closes the stream socket and the host's runner sees EOF.)
    subprocess.run([SYSTEMCTL, "poweroff", "--no-block"])
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
