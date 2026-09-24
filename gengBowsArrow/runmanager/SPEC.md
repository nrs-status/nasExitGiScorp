# runmanager — specification

## 1. Overview

`runmanager` is a command line tool (written in Haskell) that manages runs of the
pi microvm runner `run-pi-microvm` (from the `nasExitGiScorp` flake) whose
configuration lives in the `runConfigs` attribute set of a nix flake. Every
run is tracked in a postgresql `run` table, from creation to completion.

The tool has two subcommands: `run` and `list`.

## 2. Common option

Both subcommands take an option `--config` (`-c`) giving the path of a
TOML configuration file. The config contains:

* `databaseUrl` — a URL to a Postgres SQL server (postgresql-simple
  connection syntax; URIs and keyword strings both work), holding the `run`
  table,
* `openrouterApiKeyFile` — the path of a file containing the OpenRouter API
  key handed to the VM. The key itself is never read into runmanager's memory
  or copied anywhere: only the path is passed on. The file must exist and
  be non-empty (and ideally have mode 0600).
* `runPiMicroVMPath` - path to the `run-pi-microvm` script
* `listedStatuses` - a string of unordered characters (see section 4 for usage)

It is necessary that *all* of these configurations be set before any subcommand runs.

These configurations can also be set individually as environment variables or command line options . The path to the config file can also be given as an environment variable. 


## 3. The `run` subcommand

    runmanager run <flakeref>#<runConfig>

The argument has the form `<flakeref>#<config>`, where the left-hand side of
the hash sign is a flake ref of the same sort seen in the usual nix commands,
and the right-hand side designates an output of the flake accessible at the
attribute `runConfigs`.

### 3.0 Initial validation

The command exits with an error if the argument is not a proper flakeref, or if the `outputs.runConfigs.<runConfig>` attribute does not exist.

### 3.1 `runConfigs` schema

An element of the attribute `runConfigs` is an attribute set of the form:

    roDirs: list of paths to directories
    follows: list of paths to directories
    disk:   string
    ram:    string
    model:  string
    prompt: string

### 3.1.0 Validation

The `roDirs` and `follows` attributes are optional, and can only contain paths in the nix store

The directories whose paths are in `follows` must be empty

The `disk` and `ram` strings must contain an integer followed by "MB" or "GB"

The `model` string must contain three substrings separated by a forward slash, e.g. "openrouter/z-ai/glm-5.3-flash"



### 3.2 Database entry

If the run `subcommand ` successfully validates the `runConfigs` attribute, it inserts an entry in the postgresql server located at the URL passed in the `runmanager` config file argument. The table has the following schema:

    'run' table
    id:                    primary key, integer
    host: <user@host>, i.e., name of the user and name of the host in which the run happens
    origin: path in the nix store to an empty directory
    target: null or path in the nix store to a directory 
    workdir: path of the working directory for the run
    status:                one of: ongoing, done, initializing, terminated
    startTime:           datetime
    endTime:             null or datetime

The new entry itself consists of:

* `id` = a unique ID,
* `host` = name of the user and name of the host where the command was called
* `origin-impure` = see section 3.2.0
* `origin` = see section 3.2.0
* `target` = empty for the moment
* `workdir` = a new temporary directory created for this specific run
* `status` = `initializing`, 
* `startTime` = the time right now,
* `endTime` is empty for the moment.

### 3.2.0 The `origin-impure` and `origin` values

The value of the `origin-impure` column is determined in the following way:
* if the `<flakedir>/runs/<runConfigs subattribute for current run>` directory does not exist, it is created.
* if the directory `<flakedir>/runs/<runConfigs subattribute for current run>/0` does not exist, it is created. otherwise, the directory `<flakedir>/runs/<runConfigs subattribute for current run>/<increment highest number at this path by 1>` is created
* `origin-impure` is set to the path of this last created directory

At this point, an unrelated side-effect is triggered: a symlink is created or updated at `<flakedir>/runs/runConfigs subattribute for current run>/latest` so that it links to the latest created empty directory

The value of the `origin` column is determined in the following way
* the flake's path in the nix store is changed to a new path in the nix store with a flake containing the new directory and the updated symlink
* the `origin` value is set to what `origin-impure` is under the new flake in the nix store created at the previous step. That means it necessarily is a path to an empty directory.

### 3.3 Running the job

Once the database entry is made, `run` executes the `run-pi-microvm` script using the following options:

* `--workdir` copied from the `run` table's `workdir` column
* `--disk-size`, `--ram`, `--read-only`, come from the
  `runConfig`'s `disk`, `ram`, `roDirs`, but `disk` and `ram` are translated adequately
* `--model` comes from the `model` column
* `--api-key-file` receives the path of the openrouter API key file from
  the TOML config (the key itself is never copied, logged, or printed; only
  the path is handed to the script),
* the prompt from `prompt` is passed on stdin.

The `run-pi-microvm` script is resolved from the `runmanager` config file.

### 3.4 Monitoring

While the script is running, `runmanager run` monitors the run's state and updates the database entry as follows: 
* The status changes from `initializing` to `ongoing` once the VM is booted and `pi` is confirmed running. 
* The status is set to `terminated` only in case the script did not exit correctly (i.e. the virtual machine it ran did not exit correctly or the `pi` process running within it did not exit correctly), in which case `endTime` is set as well. Also, the `workdir` column in the database is set to a null value. 
* The status is set to `done` if the run finishes without any issues

### 3.4.1 Hook on the `runs` directory when setting the status to `terminated`

If a run's status is set to `terminated`, then the corresponding directory in `runs` is moved to `$TMPDIR`, timestamped with the `endTime` column value, as follows: `<flakedir>/runs/<run config name>/<run number>` gets moved to `/tmp/<run config name>-<run number>-<timestamp>`

### 3.4.2 Hook on the `runs` directory when setting the status to `done`

If a run completes successfully then the contents of the `workdir` temporary directory created specifically for this run is moved to the path stated at `origin-impure`. Then, the path of the flake is modified to a new path in the nix store, this time contining a flake with the updated contents of `origin-impure`. The path of `origin-impure` in this new nix store flake path is the value to which `target` is set in the `run` table.


## 4. The `list` subcommand

This command lists the entries of the postgresql's URL's  `run` table according to the config value `listedStatuses`. Here are some examples

     odit   # list everything
     o      # only ongoing
     d      # only done
     t      # only terminated
     i      # only initializing
     it     # only initializing and terminated

The output is a nushell-friendly table: whitespace-aligned columns whose
first line holds single-word headers (ID, STATUS, START, END, CONFIG,
OUTPUT, WORKDIR), with space-free ISO-8601 timestamps and no decoration
rows, so that piping it into nushell's `detect columns` yields a proper
structured table (e.g. `runmanager list -c <config> | detect columns | where
STATUS == done`).
