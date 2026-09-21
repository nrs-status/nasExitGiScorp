#!/usr/bin/env python3
"""reload-flakes: batch-update flake inputs of several git repositories.

Takes a single argument: the path to a TOML configuration file of the shape:

    [[repositories]]
    path = "/home/me/flakes/my-flake"
    flakeInputNames = ["nixpkgs", "microvm"]
    push = true
    onUncommitted = "warn"   # or "error"

For every declared repository the program first validates:

  * `path` points at a directory containing a flake.nix and a flake.lock,
  * it is the root of a proper git repository (a git work tree whose
    top level is exactly `path`, not merely a subdirectory of one),
  * every name in `flakeInputNames` is an actual input of that flake
    (direct inputs, or nested ones addressed with dotted names such as
    "someInput.someSubInput", which is exactly what `nix flake update`
    accepts),
  * if the work tree is dirty, `onUncommitted` decides whether a warning
    is printed ("warn") or the whole program aborts ("error").

Only after *all* repositories validated does the update phase start.  The
repositories are visited sequentially, in the order they were declared in
the TOML file; for each one `nix flake update` is run for *only* the
declared inputs.  If the update changed `flake.lock`, the change is
committed with `git add flake.lock` followed by `git commit` whose message
names the updated inputs (e.g. "flake.lock: update nixpkgs, microvm").
When `push` is true, `git push -u origin main` is executed afterwards.

An optional top-level `[all]` header may set `afterPushDelay`, a number of
seconds to wait after each `git push` before continuing with the next
repository (useful to give a remote hook time to pick up the push):

    [all]
    afterPushDelay = 10

If the `[all]` header is absent the delay defaults to 0 (no waiting).

The delay is only applied when the push actually transferred something
to the remote; a `git push` that reports "Everything up-to-date"
(nothing was pushed) is never followed by a wait.
"""

import json
import os
import subprocess
import sys
import time
import tomllib

REQUIRED_FIELDS = ("path", "flakeInputNames", "push", "onUncommitted")


def die(msg: str, code: int = 1) -> None:
    print(f"reload-flakes: error: {msg}", file=sys.stderr)
    sys.exit(code)


def warn(msg: str) -> None:
    print(f"reload-flakes: warning: {msg}", file=sys.stderr)


def run(cmd, cwd=None, check=True):
    print(f"reload-flakes: running: {' '.join(cmd)}"
          + (f"  (in {cwd})" if cwd else ""))
    return subprocess.run(cmd, cwd=cwd, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=None)


def load_config(config_path: str) -> list[dict]:
    try:
        with open(config_path, "rb") as f:
            data = tomllib.load(f)
    except FileNotFoundError:
        die(f"configuration file not found: {config_path}")
    except tomllib.TOMLDecodeError as e:
        die(f"invalid TOML in {config_path}: {e}")

    repos = data.get("repositories")
    if not isinstance(repos, list) or not repos:
        die("configuration must contain a non-empty [[repositories]] array of tables")

    for i, repo in enumerate(repos):
        label = f"repository #{i + 1}"
        if not isinstance(repo, dict):
            die(f"{label} is not a table")
        for field in REQUIRED_FIELDS:
            if field not in repo:
                die(f"{label} is missing required field '{field}'")
        if not isinstance(repo["path"], str) or not repo["path"]:
            die(f"{label}: 'path' must be a non-empty string")
        names = repo["flakeInputNames"]
        if not isinstance(names, list) or not all(
            isinstance(n, str) and n for n in names
        ):
            die(f"{label}: 'flakeInputNames' must be a non-empty list of strings")
        if not isinstance(repo["push"], bool):
            die(f"{label}: 'push' must be a boolean")
        if repo["onUncommitted"] not in ("warn", "error"):
            die(f"{label}: 'onUncommitted' must be \"warn\" or \"error\"")
        seen = set()
        for n in names:
            if n in seen:
                die(f"{label}: duplicate flake input name '{n}'")
            seen.add(n)

    if "all" in data:
        all_cfg = data["all"]
        if not isinstance(all_cfg, dict):
            die("the top-level 'all' entry must be a table ([all])")
        if "afterPushDelay" not in all_cfg:
            die("the [all] header is missing the required field 'afterPushDelay' "
                "(a non-negative number of seconds to wait after each push)")
        delay = all_cfg["afterPushDelay"]
        if isinstance(delay, bool) or not isinstance(delay, (int, float)) or delay < 0:
            die("'all.afterPushDelay' must be a non-negative number of seconds")
        delay = float(delay)
    else:
        delay = 0.0
    return repos, delay


def flake_input_exists(flake_path: str, dotted_name: str) -> bool:
    """True if `dotted_name` (e.g. "foo" or "foo.bar") names an input of the
    flake at `flake_path`, according to `nix flake metadata`."""
    proc = subprocess.run(
        ["nix", "flake", "metadata", "--json", flake_path],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        die(f"'{flake_path}' is not a usable flake:\n{proc.stderr.strip()}")
    meta = json.loads(proc.stdout)
    # Newer nix versions expose the input tree under locks.nodes[root].inputs
    # (node references are strings into `nodes`); older ones had a top-level
    # `inputs` dict.  Support both.
    if "inputs" in meta:
        root_inputs = meta["inputs"]
    else:
        locks = meta.get("locks", {})
        nodes = locks.get("nodes", {})
        root_inputs = nodes.get(locks.get("root"), {}).get("inputs", {})

    # Resolve a dotted name like "foo.bar" by walking the input tree.
    level = root_inputs
    for part in dotted_name.split("."):
        if not isinstance(level, dict) or part not in level:
            return False
        entry = level[part]
        if isinstance(entry, str):
            # reference into locks.nodes; its `inputs` (if any) is the next level
            level = meta.get("locks", {}).get("nodes", {}).get(entry, {}).get("inputs", {})
        else:
            level = entry.get("inputs", {})
    return True


def commit_lock(path: str, names: list[str]) -> None:
    """Stage and commit `flake.lock` if the update changed it."""
    run(["git", "add", "flake.lock"], cwd=path)
    staged = subprocess.run(
        ["git", "diff", "--cached", "--name-only"],
        cwd=path, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if staged.returncode != 0:
        die(f"in '{path}': git diff --cached failed:\n{staged.stderr.strip()}")
    if "flake.lock" not in staged.stdout.splitlines():
        print("reload-flakes: flake.lock unchanged, nothing to commit")
        return
    msg = "flake.lock: update " + ", ".join(names)
    run(["git", "commit", "-m", msg], cwd=path)


def push(path: str) -> bool:
    """Run `git push -u origin main` in `path` and print its output.

    Returns True if the push actually transferred something to the remote;
    returns False if the remote was already up to date (git printed
    "Everything up-to-date"), i.e. nothing was pushed.
    """
    cmd = ["git", "push", "-u", "origin", "main"]
    print(f"reload-flakes: running: {' '.join(cmd)}  (in {path})")
    proc = subprocess.run(cmd, cwd=path, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # git writes its push status ("Everything up-to-date", "Pushing to ...",
    # error messages, ...) on stderr; reproduce both streams verbatim.
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(
            proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr)
    return "Everything up-to-date" not in proc.stderr


def validate(repos: list[dict]) -> None:
    for i, repo in enumerate(repos):
        label = f"repository #{i + 1} ({repo['path']})"
        path = repo["path"]

        if not os.path.isdir(path):
            die(f"{label}: not a directory")
        if not os.path.isfile(os.path.join(path, "flake.nix")):
            die(f"{label}: no flake.nix found, '{path}' is not a nix flake")
        if not os.path.isfile(os.path.join(path, "flake.lock")):
            die(f"{label}: no flake.lock found in '{path}' "
                f"(run 'nix flake lock' there first)")

        proc = subprocess.run(
            ["git", "-C", path, "rev-parse", "--is-inside-work-tree"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if proc.returncode != 0 or proc.stdout.strip() != "true":
            die(f"{label}: not a git repository:\n{proc.stderr.strip()}")
        # A directory merely *inside* someone else's work tree must not
        # count: require that the work tree's top level is exactly `path`.
        proc = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        toplevel = proc.stdout.strip()
        if proc.returncode != 0 or not toplevel or \
                os.path.realpath(toplevel) != os.path.realpath(path):
            die(f"{label}: '{path}' is not the root of a git repository "
                f"(git top level is '{toplevel or 'unknown'}')")

        for name in repo["flakeInputNames"]:
            if not flake_input_exists(path, name):
                die(f"{label}: '{name}' is not an input of the flake at '{path}'")

        status = subprocess.run(
            ["git", "-C", path, "status", "--porcelain"],
            text=True, stdout=subprocess.PIPE,
        ).stdout
        if status.strip():
            if repo["onUncommitted"] == "error":
                die(f"{label}: has uncommitted changes "
                    f"(onUncommitted = \"error\"), aborting")
            else:
                warn(f"{label}: has uncommitted changes "
                     f"(onUncommitted = \"warn\"), continuing")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0 if len(sys.argv) == 2 else 1)
    repos, after_push_delay = load_config(sys.argv[1])

    print("reload-flakes: validation phase")
    validate(repos)

    print("reload-flakes: update phase")
    for i, repo in enumerate(repos):
        path, names = repo["path"], repo["flakeInputNames"]
        print(f"== [{i + 1}/{len(repos)}] {path} ==")
        if names:
            run(["nix", "flake", "update", *names], cwd=path)
            commit_lock(path, names)
        else:
            print(f"reload-flakes: no inputs declared for {path}, skipping update")
        if repo["push"]:
            pushed_something = push(path)
            if not pushed_something:
                print("reload-flakes: nothing was pushed (remote up to date), "
                      "skipping afterPushDelay")
            elif after_push_delay > 0:
                print(f"reload-flakes: waiting {after_push_delay:g} seconds "
                      f"after push (all.afterPushDelay)")
                time.sleep(after_push_delay)

    print("reload-flakes: done")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        die(f"command failed with exit code {e.returncode}: "
            f"{' '.join(e.cmd)}", code=e.returncode or 1)
    except KeyboardInterrupt:
        die("interrupted", code=130)
