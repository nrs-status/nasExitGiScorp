# SPEC: reload-flakes

## 1. Overview

`reload-flakes` is a command-line program that batch-updates selected flake
inputs of several local git repositories containing Nix flakes. For each
configured repository it runs `nix flake update` restricted to a declared set
of input names, commits the resulting `flake.lock` change (if any), and
optionally pushes the commit to a remote.

The program operates in two strictly separated phases:

1. **Validation phase** — every configured repository is checked. Any
   validation failure aborts the whole program *before any repository is
   modified*.
2. **Update phase** — only entered if validation of *all* repositories
   succeeded. Repositories are processed sequentially, in the order they are
   declared in the configuration file.

## 2. Invocation

```
reload-flakes.py CONFIG_FILE
reload-flakes.py -h | --help
```

* With no environment variables, the program takes exactly one positional argument: the path to a TOML configuration file. The path that this file can otherwise be passed with the environment variable DEFAULT_RELOAD_FLAKES_CONFIG_PATH. The command line option has higher precedence than the environment variable.  
* If invoked with `-h` or `--help` as the sole argument, the program prints
  its usage documentation and exits with status `0`.

## 3. Log file

The output of all `git` and `nix` commands that are run during the execution of this program are piped to a log file whose name follows the following convention:

`$TMPDIR/reload-flakes-<timestamp>.log`

## 4. Configuration file format

The configuration file is TOML.

### 4.1 `[[repositories]]` (required)

A non-empty array of tables. Each table describes one repository and must
contain **all** of the following fields:

`path`: non-empty string consisting of a filesystem path to a flake repository's root
`flakeInputNames`: list of strings. Every element must be a non-empty string, there may be no duplicates. Names may be dotted (e.g. "foo.bar") to address nested inputs, matching the syntax of `nix flake update`
`branch`: the branch which will be pushed and/or updated
`push`: boolean which determines whether to `git push` after updating

### 4.2 `[all]` (requiered)

`[all]` has one required field:

`pollingTimeout`: an integer representing seconds. it will be used in section 6.2 to determine when to stop polling.


### 4.3 Configuration error handling

Each of the following conditions is a fatal error (message on stderr, exit
status `1`):

* Configuration file does not exist.
* Configuration file is not valid TOML.
* The contents of the TOML file does not follow the constraints specified in sections 4.1 and 4.2

Example configuration:

```toml
[all]
pollingTimeout = 10

[[repositories]]
path = "/home/me/flakes/my-flake"
flakeInputNames = ["nixpkgs", "microvm"]
branch = "main"
push = true
```

## 5. Validation phase

After the configuration loads successfully, the program validates every repository, in
declaration order. Any failure aborts the entire run with exit status `1`, unless the failure is due to a failure by the `nix` or `git` commands in which case the exit code is whatever exit code those commands returned.
On error, nothing is updated. Error messages identify the repository as
`repository #N (<path>)` (0-based index).

For each repository, in order:

1. **Directory check** — `path` must be an existing directory.
2. **Flake files check** — the directory must contain a regular file
   `flake.nix` and a regular file `flake.lock`. The error message for a
   missing `flake.lock` suggests running `nix flake lock` first.
3. **Git repository check** — `git -C <path> rev-parse --is-inside-work-tree`
   must succeed and print `true`.
4. **Git root check** — `git -C <path> rev-parse --show-toplevel` must
   succeed, and the reported top level must be *exactly* `path` (compared
   after resolving both through `os.path.realpath`, so symlinks are
   tolerated). A directory that is merely *inside* another repository's work
   tree is rejected.
5. **Flake input existence check** — every name in `flakeInputNames` must
   name an actual input of the flake (see §5).
6. **Dirty work tree check** — `git -C <path> status --porcelain` is run. If its output is non-blank (the work tree has uncommitted changes), the program aborts with an error.

## 5.1 Validation phase message

If the validation phase is successful, a bright green message is printed saying so. This is the only output of the validation phase, any other output goes into the log file.

## 6. Update phase

Only starts after all repositories validate. The program processes repositories sequentially in declaration order.

### 6.1 Machinery for adequately sequencing updates

We must specify a way for the updates made by the execution of `reload-flakes` because some flakes in the configuration file may depend on flakes declared earlier in the file. If no adequate mechanism is specified to adequately sequence the execution of the updates, some repositories may not update adequately because their update mechanism gets triggered before the remote records any changes. `reload-flakes` would therefore finish execution without having all of its flakes adequately synchronized both locally and with the remotes.

In order to prevent this state of affairs, for any flake repository in the configuration file that has `push` set to `true`, the initial state of the remote corresponding to it is recorded. This will later be used to control the rhythm of execution of the updates and pushes.

The initial recorded state is piped to the log file.



### 6.2 Update and commit

For each repository:

1. If `flakeInputNames` is empty, the program performs neither update nor commit (but may still push, see §6.3).
2. Otherwise: for each element of `flakeInputNames`, if their URL (specifically, the URL from the `original` field in `flake.lock`)  is the same (modulo a sane normalization rule, unspecified at this time) to the `origin` remote that 
 a. has been recorded at step (6.1), and 
 b. has been successfully pushed to during section (6.3) during earlier processing, meaning that, `reload-flakes` detected there was actually something to push, and something was pushed,
 Then `reload-flakes` enters a loop, polling every two seconds to see whether the remote contains the changes pushed during (6.3), using as a reference the state recorded by (6.1). During this polling, a small message appears on stdout as a transient message with a small loading animation, which keeps appearing until it is detected that the remote has successfully been updated with the actions of (6.3). At which point, the transient message completely disappears from the program's output and the next steps are executed. This polling has a timeout configured by the `pollingTimeout` field in the configuration file. If the time out time is reached, the program exits with an error. 
3. Run `nix flake update <name1> <name2> ...` in the repository directory (only the declared inputs are updated). A non-zero exit aborts the program.
4.  Run `git add flake.lock` in the repository.
5. Run `git diff --cached --name-only`; if it fails, abort with an error.
6. If `flake.lock` is **not** among the staged files, skip the commit.
7. Otherwise commit with:
   ```
   git commit -m "flake.lock: update <name1>, <name2>, ..."
   ```
   where the names appear in their configured order, comma-separated.

### 6.3 Push

If the configuration of a repository inside the configuration file sets `push` to `true`:

1. Run `git push -u origin <branch>` (where `<branch>` is read from the configuration's `branch` field) in the repository. The push happens regardless of whether a commit was made in §6.2.
2. Both stdout and stderr of `git push` are piped verbatim to the log file.
3. A non-zero exit status from `git push` aborts the program.

### 6.4 Output

For all steps in sections 6.2 and 6.3, the output of the `nix` and `git` commands are piped to the log file

During the sequencing, after processing has finished successfully for a given repository, a message following the following format is printed:

```
[<repository name>]
updated inputs: none|no inputs specified| [updated inputs] | <error message>
push: success|nothing to push|not configured| <error message>
```

### 6.5 Finalizing

After all repositories have been processed, the program prints a completion message, prints the path of the log file, and exits with status `0`.

## 7. Error handling and exit codes

When an external command run during the update phase fails, the program
reports `command failed with exit code <N>: <command>` on stderr, prints the path o the log file to stderr, and exits
with that command's exit code. Repositories later in the list are **not**
processed; earlier repositories that already committed/pushed are **not**
rolled back.
