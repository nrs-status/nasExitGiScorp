#!/usr/bin/env python3
"""
reload-flakes -- batch-update selected flake inputs of several local git
repositories containing Nix flakes.

For each configured repository `reload-flakes` runs `nix flake update`
restricted to a declared set of input names, commits the resulting
`flake.lock` change (if any) and optionally pushes the commit to the
`origin` remote.

The program operates in two strictly separated phases:

1. validation phase -- every configured repository is checked; any failure
   aborts the whole program before any repository is modified;
2. update phase -- only entered if validation of *all* repositories
   succeeded; repositories are processed sequentially, in configuration
   declaration order.

Because flakes declared later in the configuration file may depend on
flakes declared earlier, remotes that were actually pushed to earlier in
the run are polled (every two seconds, up to the configured
`pollingTimeout`) until they visibly contain the pushed changes, before
dependents are updated.  See ./SPEC.md and ./SPEC2.md.

usage:
  reload-flakes CONFIG_FILE
  reload-flakes -h | --help

If CONFIG_FILE is not given on the command line, it is read from the
environment variable DEFAULT_RELOAD_FLAKES_CONFIG_PATH.  The command line
argument has the higher precedence.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import tomllib
from urllib.parse import unquote

PROG = "reload-flakes"
ENV_CONFIG = "DEFAULT_RELOAD_FLAKES_CONFIG_PATH"
POLL_INTERVAL = 2.0  # seconds between remote polls (fixed by the spec)
SPINNER_FRAMES = ["|", "/", "-", "\\"]

GREEN = "\033[1;32m"
RESET = "\033[0m"


class Fatal(Exception):
    """A configuration or validation error; the program exits with status 1."""


class CommandFailure(Exception):
    """An external command exited with a non-zero status."""

    def __init__(self, cmd, returncode):
        self.cmd = cmd
        self.returncode = returncode
        super().__init__(
            f"command failed with exit code {returncode}: {shlex.join(cmd)}"
        )


class PollTimeout(Exception):
    """The remote-state polling loop exceeded its `pollingTimeout`."""

    def __init__(self, timeout, remotes):
        self.timeout = timeout
        self.remotes = remotes
        super().__init__(
            f"timed out after {timeout}s waiting for the remote(s) to receive "
            f"the pushed changes: {remotes}"
        )


# ---------------------------------------------------------------------------
# logging


class Log:
    """All output of git/nix commands run by the program is piped here."""

    def __init__(self):
        tmpdir = tempfile.gettempdir()  # honours $TMPDIR, falls back to /tmp
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = os.path.join(tmpdir, f"{PROG}-{stamp}.log")
        suffix = 1
        while os.path.exists(path):
            suffix += 1
            path = os.path.join(tmpdir, f"{PROG}-{stamp}-{suffix}.log")
        self.path = path
        self.fh = open(path, "w", encoding="utf-8")

    def line(self, text=""):
        self.fh.write(text + "\n")
        self.fh.flush()

    def command(self, cmd, cwd, proc):
        self.line("$ " + shlex.join(cmd) + (f"  # cwd: {cwd}" if cwd else ""))
        if proc.stdout:
            self.fh.write(proc.stdout)
            if not proc.stdout.endswith("\n"):
                self.fh.write("\n")
        if proc.stderr:
            self.fh.write(proc.stderr)
            if not proc.stderr.endswith("\n"):
                self.fh.write("\n")
        self.line(f"# exit code: {proc.returncode}")


def run(log, cmd, cwd=None):
    """Run an external command, piping its output into the log file.

    Raises CommandFailure if the command exits non-zero.
    """
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    log.command(cmd, cwd, proc)
    if proc.returncode != 0:
        raise CommandFailure(cmd, proc.returncode)
    return proc


# ---------------------------------------------------------------------------
# configuration


def usage(out=sys.stdout):
    out.write(
        f"""usage: {PROG} CONFIG_FILE
       {PROG} -h | --help

Batch-update selected flake inputs of several local git repositories
containing Nix flakes: for each configured repository, run `nix flake
update` restricted to the declared inputs, commit the resulting
flake.lock change (if any) and optionally push it to the `origin` remote.

arguments:
  CONFIG_FILE  path to a TOML configuration file; if omitted, the path is
               taken from the environment variable
               {ENV_CONFIG} (the command line
               argument has the higher precedence)

configuration file format (TOML):

  [all]
  pollingTimeout = 10          # seconds; timeout of the remote-state
                               # polling performed during sequencing

  [[repositories]]             # at least one; processed in order
  path = "/home/me/flakes/my-flake"  # repository root
  flakeInputNames = ["nixpkgs"]      # inputs to update; may be empty;
                                     # names may be dotted ("foo.bar") to
                                     # address nested inputs
  branch = "main"                    # branch to push
  push = true                        # whether to `git push` after updating

For the full specification see the SPEC.md / SPEC2.md shipped alongside
this program.
"""
    )


def die(message):
    print(f"{PROG}: {message}", file=sys.stderr)
    sys.exit(1)


def require(cond, message):
    if not cond:
        raise Fatal(message)


def load_config(config_path):
    require(os.path.exists(config_path), f"configuration file does not exist: {config_path}")
    try:
        with open(config_path, "rb") as fh:
            doc = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        raise Fatal(f"configuration file is not valid TOML: {config_path}: {exc}") from exc

    require(isinstance(doc, dict), "configuration must be a TOML table")
    require("all" in doc, "configuration is missing the [all] table")
    all_table = doc["all"]
    require(isinstance(all_table, dict), "[all] must be a table")
    require(
        "pollingTimeout" in all_table,
        "[all] is missing the required field 'pollingTimeout'",
    )
    polling_timeout = all_table["pollingTimeout"]
    require(
        isinstance(polling_timeout, int) and not isinstance(polling_timeout, bool),
        "[all] 'pollingTimeout' must be an integer (seconds)",
    )
    require(
        polling_timeout > 0,
        "[all] 'pollingTimeout' must be a positive integer (seconds)",
    )

    require(
        "repositories" in doc,
        "configuration is missing the [[repositories]] array",
    )
    repositories = doc["repositories"]
    require(
        isinstance(repositories, list) and len(repositories) > 0,
        "[[repositories]] must be a non-empty array of tables",
    )

    required = ("path", "flakeInputNames", "branch", "push")
    for index, repo in enumerate(repositories):
        label = f"repository #{index}"
        require(isinstance(repo, dict), f"{label}: must be a table")
        for field in required:
            require(field in repo, f"{label}: missing required field '{field}'")
        path = repo["path"]
        require(
            isinstance(path, str) and path != "",
            f"{label}: 'path' must be a non-empty string",
        )
        names = repo["flakeInputNames"]
        require(
            isinstance(names, list),
            f"{label}: 'flakeInputNames' must be a list of strings",
        )
        for name in names:
            require(
                isinstance(name, str) and name != "",
                f"{label}: every element of 'flakeInputNames' must be a non-empty string",
            )
        require(
            len(set(names)) == len(names),
            f"{label}: 'flakeInputNames' contains duplicates",
        )
        branch = repo["branch"]
        require(
            isinstance(branch, str) and branch != "",
            f"{label}: 'branch' must be a non-empty string",
        )
        push = repo["push"]
        require(
            isinstance(push, bool),
            f"{label}: 'push' must be a boolean",
        )

    return {
        "pollingTimeout": polling_timeout,
        "repositories": [
            {
                "path": repo["path"],
                "flakeInputNames": list(repo["flakeInputNames"]),
                "branch": repo["branch"],
                "push": repo["push"],
            }
            for repo in repositories
        ],
    }


# ---------------------------------------------------------------------------
# flake.lock helpers


def load_lock(path):
    """Parse <path>/flake.lock into a dict (or None if unparseable)."""
    try:
        with open(os.path.join(path, "flake.lock"), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def resolve_input_node(nodes, root, name):
    """Resolve an (possibly dotted) input name to a flake.lock node id.

    Returns None if the name does not denote an existing input.
    """
    current = root
    for part in name.split("."):
        node = nodes.get(current)
        if node is None:
            return None
        inputs = node.get("inputs", {})
        if part not in inputs:
            return None
        target = inputs[part]
        if isinstance(target, list):
            target = target[0] if target else None
        if not isinstance(target, str):
            return None
        current = target
    return current


def input_original_url(lock, name):
    """Return the `original` URL of an input of the flake described by lock."""
    if lock is None:
        return None
    nodes = lock.get("nodes", {})
    root = lock.get("root")
    node_id = resolve_input_node(nodes, root, name)
    if node_id is None:
        return None
    original = nodes.get(node_id, {}).get("original", {})
    return original_to_url(original)


def original_to_url(original):
    """Extract a URL string from a flake.lock `original` object."""
    if not isinstance(original, dict):
        return None
    kind = original.get("type")
    if kind == "github":
        host = original.get("host", "github.com")
        return f"https://{host}/{original.get('owner')}/{original.get('repo')}"
    if kind == "gitlab":
        host = original.get("host", "gitlab.com")
        return f"https://{host}/{original.get('owner')}/{original.get('repo')}"
    if kind == "sourcehut":
        host = original.get("host", "git.sr.ht")
        return f"https://{host}/~{original.get('owner')}/{original.get('repo')}"
    if isinstance(original.get("url"), str):
        return original["url"]
    if isinstance(original.get("path"), str):
        return original["path"]
    return None


def normalize_url(url):
    """Normalize a git/flake URL for equality comparison.

    The normalization rule (an interpretation of the spec's "sane
    normalization rule", made explicit in SPEC2.md section 6.2):

    * a leading "git+" transport indicator is stripped;
    * scp-like syntax ("[user@]host:path") is rewritten to "ssh://host/path";
    * the scheme (https/ssh/git/file/...) is ignored;
    * userinfo ("user@") and the port are dropped from the authority;
    * the host is lower-cased;
    * percent-escapes in the path are decoded;
    * a trailing "/" and a trailing ".git" are stripped.
    """
    if not isinstance(url, str):
        return None
    u = url.strip()
    if u == "":
        return None
    if u.startswith("git+"):
        u = u[len("git+"):]
    if "://" not in u:
        # scp-like syntax: [user@]host:path (a single colon, path not
        # starting with a slash); plain absolute paths have no colon.
        match = re.match(r"^(?:[^@/:]+@)?([^/:]+):([^/].*)$", u)
        if match:
            u = f"ssh://{match.group(1)}/{match.group(2)}"
    if "://" in u:
        _, rest = u.split("://", 1)
        authority, _, path = rest.partition("/")
    else:
        # plain (relative or absolute) filesystem path
        authority, path = "", u
    authority = authority.rsplit("@", 1)[-1]
    host = authority.split(":", 1)[0].strip().lower()
    path = unquote(path)
    path = path.rstrip("/")
    while path.lower().endswith(".git"):
        path = path[: -len(".git")]
    path = path.lstrip("/")
    if authority != "":
        # host-based URLs are compared case-insensitively; plain filesystem
        # paths are kept verbatim (filesystems may be case-sensitive)
        path = path.lower()
    return f"{host}/{path}"


# ---------------------------------------------------------------------------
# validation phase


def validate_repository(log, repo, index):
    """Validate one repository; raises Fatal or CommandFailure."""
    path = repo["path"]
    label = f"repository #{index} ({path})"

    if not os.path.isdir(path):
        raise Fatal(f"{label}: path is not an existing directory")

    if not os.path.isfile(os.path.join(path, "flake.nix")):
        raise Fatal(f"{label}: missing regular file flake.nix")
    if not os.path.isfile(os.path.join(path, "flake.lock")):
        raise Fatal(
            f"{label}: missing regular file flake.lock "
            "(run 'nix flake lock' first)"
        )

    proc = run(log, ["git", "rev-parse", "--is-inside-work-tree"], cwd=path)
    if proc.stdout.strip() != "true":
        raise Fatal(f"{label}: not inside a git work tree")

    toplevel = run(log, ["git", "rev-parse", "--show-toplevel"], cwd=path)
    reported = toplevel.stdout.strip()
    if os.path.realpath(reported) != os.path.realpath(path):
        raise Fatal(
            f"{label}: is inside the git work tree {reported}, "
            "but is not itself a work tree root"
        )

    metadata = run(log, ["nix", "flake", "metadata", "--json"], cwd=path)
    try:
        meta = json.loads(metadata.stdout)
        locks = meta.get("locks", {})
        nodes = locks.get("nodes", {})
        root = locks.get("root")
    except json.JSONDecodeError as exc:
        raise Fatal(f"{label}: could not parse `nix flake metadata --json` output: {exc}") from exc
    for name in repo["flakeInputNames"]:
        if resolve_input_node(nodes, root, name) is None:
            raise Fatal(f"{label}: flake has no input named '{name}'")

    status = run(log, ["git", "status", "--porcelain"], cwd=path)
    if status.stdout.strip() != "":
        raise Fatal(f"{label}: work tree is dirty:\n{status.stdout.rstrip()}")


# ---------------------------------------------------------------------------
# remote-state sequencing machinery


def record_initial_remote_state(log, repo, label):
    """Record the initial state of a repository's `origin` remote (6.1).

    Returns (raw_url, branch, initial_sha) or None if there is no initial
    state (the branch does not exist on the remote yet).
    """
    path = repo["path"]
    branch = repo["branch"]
    url = run(log, ["git", "remote", "get-url", "origin"], cwd=path).stdout.strip()
    proc = run(
        log, ["git", "ls-remote", "origin", f"refs/heads/{branch}"], cwd=path
    )
    initial = ""
    for line in proc.stdout.splitlines():
        if line.strip():
            initial = line.split()[0]
            break
    log.line(
        f"# recorded initial remote state for {label}: "
        f"origin={url} branch={branch} sha={initial or '(branch absent)'}"
    )
    return {"raw_url": url, "branch": branch, "initial": initial, "label": label}


def remote_head_sha(log, raw_url, branch):
    proc = run(log, ["git", "ls-remote", raw_url, f"refs/heads/{branch}"])
    for line in proc.stdout.splitlines():
        if line.strip():
            return line.split()[0]
    return ""


def pending_remote_entries(log, repo, names, pushed_remotes):
    """Compute the remote entries a repository must wait for before updating.

    An entry matches when the input's `original` URL in flake.lock is equal
    (after normalization) to the origin remote of an earlier-processed
    repository that (a) had its initial remote state recorded in 6.1 and
    (b) was successfully pushed to in 6.3 with something actually pushed.
    """
    lock = load_lock(repo["path"])
    entries = {}
    for name in names:
        url = normalize_url(input_original_url(lock, name))
        if url is None:
            continue
        for entry in pushed_remotes.get(url, []):
            key = (url, entry["branch"], entry["initial"])
            entries[key] = entry
    return list(entries.values())


def wait_for_remote_updates(log, entries, timeout):
    """Poll matching remotes until they contain the pushed changes (6.2 step 2).

    Polls every POLL_INTERVAL seconds with a transient spinner message on
    stdout; raises PollTimeout if the timeout is reached first.
    """
    if not entries:
        return
    deadline = time.monotonic() + timeout
    start = time.monotonic()
    frame_index = 0
    last_len = 0
    wrote_spinner = False

    def clear_spinner():
        nonlocal wrote_spinner, last_len
        if wrote_spinner:
            sys.stdout.write("\r" + " " * last_len + "\r")
            sys.stdout.flush()
        wrote_spinner = False
        last_len = 0

    try:
        while True:
            pending = []
            for entry in entries:
                sha = remote_head_sha(log, entry["raw_url"], entry["branch"])
                # satisfied when the remote branch exists and differs from
                # the initially recorded state, i.e. it received the push
                if not sha or sha == entry["initial"]:
                    pending.append(entry)
            if not pending:
                return
            remaining = ", ".join(
                f"{entry['raw_url']} (branch {entry['branch']})"
                for entry in pending
            )
            if time.monotonic() >= deadline:
                raise PollTimeout(timeout, remaining)
            next_poll = time.monotonic() + POLL_INTERVAL
            while time.monotonic() < min(next_poll, deadline):
                frame = SPINNER_FRAMES[frame_index % len(SPINNER_FRAMES)]
                frame_index += 1
                elapsed = int(time.monotonic() - start)
                text = (
                    f"waiting for the pushed changes to reach remote(s): "
                    f"{remaining} ... {frame} ({elapsed}s elapsed, "
                    f"timeout {timeout}s)"
                )
                sys.stdout.write("\r" + text)
                sys.stdout.flush()
                wrote_spinner = True
                last_len = max(last_len, len(text))
                time.sleep(min(0.25, max(0.0, min(next_poll, deadline) - time.monotonic())))
    finally:
        clear_spinner()


# ---------------------------------------------------------------------------
# update phase


def repo_report(name, updated_str, push_str):
    print(f"[{name}]")
    print(f"updated inputs: {updated_str}")
    print(f"push: {push_str}")


def updated_input_names(names, before, after):
    """Determine which of the configured inputs actually changed.

    Compares the `locked` field of each input's flake.lock node before and
    after the update.  Falls back to the full configured list when the
    comparison is impossible.
    """
    if before is None or after is None:
        return list(names) if before != after else []
    before_nodes = before.get("nodes", {})
    after_nodes = after.get("nodes", {})
    before_root = before.get("root")
    after_root = after.get("root")
    changed = []
    for name in names:
        before_id = resolve_input_node(before_nodes, before_root, name)
        after_id = resolve_input_node(after_nodes, after_root, name)
        if before_id is None or after_id is None:
            changed.append(name)
            continue
        if before_nodes.get(before_id, {}).get("locked") != after_nodes.get(
            after_id, {}
        ).get("locked"):
            changed.append(name)
    return changed


def process_repository(log, repo, index, pushed_remotes, polling_timeout):
    """Run 6.1-6.4 for one repository."""
    path = repo["path"]
    names = repo["flakeInputNames"]
    branch = repo["branch"]
    push = repo["push"]
    label = f"repository #{index} ({path})"
    name = os.path.basename(os.path.normpath(path))

    updated_str = None
    push_str = "not configured" if not push else None
    try:
        # 6.1: record the initial state of the remote (if pushing)
        initial_state = None
        if push:
            initial_state = record_initial_remote_state(log, repo, label)

        updated_str = None
        changed = []
        if names:
            # 6.2 step 2: wait for earlier pushes to reach the remotes our
            # inputs point at
            entries = pending_remote_entries(log, repo, names, pushed_remotes)
            wait_for_remote_updates(log, entries, polling_timeout)

            # 6.2 step 3: update only the declared inputs; nested input
            # names are configured (and reported) dotted ("foo.bar") but
            # `nix flake update' addresses nested inputs with slashes
            # ("foo/bar"), so translate for the command line
            update_args = [name.replace(".", "/") for name in names]
            before = load_lock(path)
            run(log, ["nix", "flake", "update", *update_args], cwd=path)
            after = load_lock(path)

            # 6.2 steps 4-6: stage flake.lock, find out whether it changed
            run(log, ["git", "add", "flake.lock"], cwd=path)
            staged = run(
                log, ["git", "diff", "--cached", "--name-only"], cwd=path
            )
            staged_names = staged.stdout.split()
            if "flake.lock" in staged_names:
                # 6.2 step 7: commit
                message = "flake.lock: update " + ", ".join(names)
                run(log, ["git", "commit", "-m", message], cwd=path)
                changed = updated_input_names(names, before, after)
                if not changed:
                    changed = list(names)  # comparison was inconclusive
            updated_str = (
                "none" if not changed else "[" + ", ".join(changed) + "]"
            )
        else:
            updated_str = "no inputs specified"

        # 6.3: push
        if push:
            run(log, ["git", "push", "-u", "origin", branch], cwd=path)
            new_state = record_initial_remote_state(log, repo, label)
            if new_state["initial"] and new_state["initial"] != initial_state["initial"]:
                # something was actually pushed: register the remote so that
                # later repositories wait for it during sequencing
                url = normalize_url(initial_state["raw_url"])
                pushed_remotes.setdefault(url, []).append(
                    {
                        "raw_url": initial_state["raw_url"],
                        "branch": branch,
                        "initial": initial_state["initial"],
                        "label": label,
                    }
                )
                push_str = "success"
            else:
                push_str = "nothing to push"
    except CommandFailure as exc:
        if updated_str is None:
            updated_str = str(exc)
        if push_str is None:
            push_str = str(exc)
        repo_report(name, updated_str, push_str)
        raise
    repo_report(name, updated_str, push_str)


# ---------------------------------------------------------------------------
# main


def parse_args(argv):
    args = argv[1:]
    if args == ["-h"] or args == ["--help"]:
        usage()
        sys.exit(0)
    if len(args) > 1:
        die(f"too many arguments; usage: {PROG} CONFIG_FILE")
    if args:
        return args[0]
    config_path = os.environ.get(ENV_CONFIG)
    if not config_path:
        die(
            "no configuration file specified; pass CONFIG_FILE or set "
            f"the environment variable {ENV_CONFIG}"
        )
    return config_path


def main(argv):
    config_path = parse_args(argv)
    log = Log()

    try:
        config = load_config(config_path)
        repositories = config["repositories"]
        polling_timeout = config["pollingTimeout"]

        # validation phase
        for index, repo in enumerate(repositories):
            validate_repository(log, repo, index)
        count = len(repositories)
        print(
            f"{GREEN}validation successful: all {count} "
            f"{'repository' if count == 1 else 'repositories'} "
            f"are ready to be updated{RESET}"
        )

        # update phase
        pushed_remotes = {}
        for index, repo in enumerate(repositories):
            process_repository(
                log, repo, index, pushed_remotes, polling_timeout
            )

        print(
            f"done: all {count} "
            f"{'repository' if count == 1 else 'repositories'} processed "
            "successfully"
        )
        print(f"log file: {log.path}")
        return 0
    except Fatal as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    except PollTimeout as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        print(f"log file: {log.path}", file=sys.stderr)
        return 1
    except CommandFailure as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        print(f"log file: {log.path}", file=sys.stderr)
        return exc.returncode
    except KeyboardInterrupt:
        print(f"{PROG}: interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv))
