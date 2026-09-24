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

This section specifies the types and the runtime behavior of the `run` subcommand.

### 3.0 Types

This section contains various types that will be referred to throughout later sections about the `run` subcommand. The types in this section will be referred to by their section number.

### 3.0.1 Subcommand syntax and validation

`runmanager [global options] run [--pure] <flakeref>#<runConfig>`

* The left-hand side of the hash sign is a flake ref of the same sort seen in the usual nix commands. It must be a proper flakeref.
* The right-hand side designates an output of the flake accessible at the
attribute `runConfigs`.
* If the `--pure` flag is not set, the flakeref must designate a path outside the nix store, on the local machine.
* The flake specified by the flakeref must have the `runConfigs` attribute in its outputs.

### 3.0.2 runpath

A runpath consists of a string containing two substrings separated by a forward slash. The second substring must be either the word "latest" or a non negative integer.

### 3.0.3 Pure path of a run

A pure path of a run must satisfy the following constraints:
- It must have the form: `<flakedir>/runs/<runConfigs subattribute>/<"latest" or an integer>`.
- `<flakedir>` must contain a `flake.nix` file
- `<flakedir>` must refer to a flake directory *inside* the nix store


### 3.0.4 `runConfigs` schema

This is the type of `runConfigs` subattributes.

A subattribute of `runConfigs` must have a value of the form:

    roDirs: list of paths to directories
    follows: list of paths of type 3.0.3
    disk:   string
    ram:    string
    model:  string
    prompt: string

The `roDirs` and `follows` attributes are optional

The directories whose paths are in `follows` must be empty

The `disk` and `ram` strings must contain an integer followed by "MB" or "GB"

The `model` string must contain three substrings separated by two forward slashes, e.g. "openrouter/z-ai/glm-5.3-flash"

### 3.0.5 `workdir` path


A `workdir` path is the path of a temporary directory, created for a single specific run, in `$TMPDIR`, using a runpath `<runConfigs subattribute>/<run number>`as a reference and timestamped with the `startTime` column value, as follows: `$TMPDIR/<runConfigs subattribute>-<run number>-<timestamp>`

### 3.0.6 `run` table schema

The Postgresql schema for the `run` table is as follows:

    id:                    primary key, integer
    host: <user@host>, i.e., name of the user and name of the host in which the run happens
    runpath: string of type 3.0.2
    type: one of: pure, impure
    origin: nix store flakeref
    target: null or nix store path
    workdir: null or a path of type 3.0.5
    status:                one of: ongoing, done, initializing, terminated
    startTime:           datetime
    endTime:             null or datetime


### 3.1 Runtime behaviour

This section specifies the run-time behavior of the `run` subcommand.

### 3.1.0 Initial validation

The command call is first validated according to 3.0.1

It then valides the `runConfigs` subattribute that was passed as an argument, according to type 3.0.4

### 3.1.1. Database entry

The command then validates whether there is a table called `run` in the postgreSQL server given through the URL passed in `databaseUrl`, and validates that it satisfies the schema specified as type 3.0.6.

The command then inserts a new entry as follows:

* `id` = a unique ID,
* `host` = name of the user and name of the host where the command was called
* `runpath` = see section 3.1.1.0
* `type` = "impure" unless `--pure` flag is passed, in which case "pure"
* `origin` = see section 3.1.1.1
* `output` = empty for the moment
* `startTime` = the time right now,
* `workdir` = A temporary directory whose path atisfies type 3.0.5, using the values of `runpath` and `startTime`
* `status` = `initializing` 
* `endTime` is empty for the moment.

### 3.1.1.0 The `runpath` value

### 3.1.1.0.0  `type` = "impure"

if `type` = "impure", then

If `flakeref`, which is a local path due to `type` = "impure", does not contain `runs/<runConfigs subattribute for current run>/0`, it is created, and runpath is `<runConfigs subattribute for current run>/0`. If that directory does exists, we create instead `runs/<runConfigs subattribute for current run>/<increment highest number at this path by 1>`, and runpath is `<runConfigs subattribute for current run>/<increment highest number at this path by 1>`

At this point, an unrelated side-effect is triggered: a symlink is created or updated at `<flakeref>/runs/<runConfigs subattribute for current run>/latest` so that it links to the latest created empty directory

### 3.1.1.0.1 `type` = "pure"


if `type` = "pure", then

The `run` table is searched for any run whose runpath begins with the same `runConfigs` subattribute as the current run. Runs with status `terminated` are ignored.

If no such entry exists, runpath is `<runConfigs subattribute for current run>/0`. Otherwise, it is `<runConfigs subattribute for current run>/<increment highest number at this path in search results by 1>`


### 3.1.1.1 The `origin` value

if `type` = "impure", then `origin` is the path of a nix store copy of `flakeref` that includes the new directories
if `type` = "pure", then `origin` is `flakeref`


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

The `run-pi-microvm` script is resolved from the `runPiMicroVMPath` config value

### 3.4 Monitoring

While the script is running, `runmanager run` monitors the run's state and updates the database entry as follows: 
* The status changes from `initializing` to `ongoing` once the VM is booted and `pi` is confirmed running. 
* The status is set to `terminated` only in case the script did not exit correctly (i.e. the virtual machine it ran did not exit correctly or the `pi` process running within it did not exit correctly), in which case `endTime` is set as well. Also, the `workdir` column in the database is set to a null value. 
* The status is set to `done` if the run finishes without any issues

### 3.4.1 Hook on the `runs` directory when setting the status to `terminated`

If a run's status is set to `terminated` and `type` = "impure", then the corresponding directory in `runs` is deleted.

### 3.4.2 Hook on the `runs` directory when setting the status to `done`

If a run completes successfully, the contents of the `workdir` temporary directory created specifically for this run is moved to the nix store, the value of `outputPath` in the database is updated with its nix store path and also printed to stdout

furthermore, if `type` = "impure", then the contents of `workdir` is also copied to `<impure flakeref>/runs/<runpath>`

## 4. The `list` subcommand

This command lists the entries of the postgresql's URL's  `run` table according to the config value `listedStatuses`. Here are some examples

     odit   # list everything
     o      # only ongoing
     d      # only done
     t      # only terminated
     i      # only initializing
     it     # only initializing and terminated

The output is a nushell-friendly table: whitespace-aligned columns whose
first line holds single-word headers (same as the columns in type 3.0.6), with space-free ISO-8601 timestamps and no decoration rows, so that piping it into nushell's `detect columns` yields a proper
structured table (e.g. `runmanager list -c <config> | detect columns | where
STATUS == done`).
