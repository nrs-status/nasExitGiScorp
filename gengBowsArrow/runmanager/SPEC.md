# runmanager — specification

## 0. About this document

This document contains a high-level overview of the `runmanager` command line tool along with its server-side component. Its main purpose is to serve as a reference for AI agents to use in order to implement the program. It is not meant to give excessively detailed technical information; an agent is expected to fill out the missing details or to make architectural and design decisions about elements that are left underspecified in this document.

Any agent using this document as a starting point for implementing the `runmanager` program is expected to write a second document, SPEC_EXTENSION.md, containing the details missing from this document necessary for the implementation. SPEC_EXTENSION.md should include the interpretation of ambiguities in this document, and design decisions left open or underspecified by this document. The combination of SPEC.md and SPEC_EXTENSION.md should suffice to give a full technical specification of the `runmanager` program.

This document intends to specify a Haskell program. It is expected that any agent implementing this specification will avoid writing the entire program in a single file, and instead will make extensive use of the module system to separate program logic into self-contained pieces implementing a singular logically distinct part of the total program.

## 1. Overview

`runmanager` is a command line tool that manages runs of the pi microvm runner `run-pi-microvm` (from the `nasExitGiScorp` flake) whose configuration lives in the `runConfigs` attribute set of a nix flake. Every run is tracked from creation to completion in a postgresql server containing a database that has a `run` table. 

The server is included as a deliverable, packaged as a container.

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
* `streamSocketFile` - path to a file that will be used as the socket to stream `run-pi-microvm`'s JSON output. The file may or may not exist yet.

It is necessary that *all* of these configurations be set before any subcommand runs.

These configurations can also be set individually as environment variables or command line options . The path to the config file can also be given as an environment variable. Command line options take precedence, then come environment variables.


## 3. The `run` subcommand

This section specifies the types and the runtime behavior of the `run` subcommand.

### 3.0 Types

This section contains various types that will be referred to throughout later sections about the `run` subcommand. The types in this section will be referred to by their section number.

### 3.0.1 Subcommand syntax and validation

`runmanager [<global options>] run <--pure>? <flakeref>#<runConfig>`

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
- `<flakedir>` must be a proper flake directory, containing a `flake.nix` file
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
    host: <user>@<host>, i.e., name of the user and name of the host in which the run happens
    runpath: string of type 3.0.2
    type: one of: pure, impure, synthetic-latest
    origin: nix store flakeref
    outputPath: null or nix store path
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
* `outputPath` = empty for the moment
* `startTime` = the time right now,
* `workdir` = A temporary directory whose path atisfies type 3.0.5, using the values of `runpath` and `startTime`
* `status` = `initializing` 
* `endTime` is empty for the moment.

### 3.1.1.0 The `runpath` value

### 3.1.1.0.0 When `type` = "impure"

if `type` = "impure", then

If `flakeref`, which is a local path due to `type` = "impure", does not contain `runs/<runConfigs subattribute for current run>/0`, it is created, and runpath is `<runConfigs subattribute for current run>/0`. If that directory does exists, we create instead `runs/<runConfigs subattribute for current run>/<increment highest number at this path by 1>`, and runpath is `<runConfigs subattribute for current run>/<increment highest number at this path by 1>`

At this point, an unrelated side-effect is triggered: a symlink is created or updated at `<flakeref>/runs/<runConfigs subattribute for current run>/latest` so that it links to the latest created empty directory

### 3.1.1.0.1 When `type` = "pure"

if `type` = "pure", then

The `run` table is searched for any run whose runpath begins with the same `runConfigs` subattribute as the current run. Runs with status `terminated` are ignored.

If no such entry exists, runpath is `<runConfigs subattribute for current run>/0`. Otherwise, it is `<runConfigs subattribute for current run>/<increment highest number at this path in search results by 1>`

### 3.1.1.0.2 For both `type` = "pure" and `type` = "impure"

The new runpath is populated by a file called `manifest.json`, a JSON representation of the value of the `runConfigs` subattribute for the current run.

### 3.1.1.1 The `origin` value

if `type` = "impure", then `origin` is the path of a nix store copy of `flakeref` that includes the new directories
if `type` = "pure", then `origin` is `flakeref`


### 3.1.1.2 The `synthetic-latest` entry

Once runpath and `origin` have been determined, an unrelated side-effect is triggered: if the database contains an entry with runpath `<runConigs subattribute for current run>/latest`, then it is modified to be an exact copy of the latest created entry for this specific run. It is otherwise created and filled with this information. This synthetic entry has type `synthetic-latest` and is expected to mirror exactly the columns of the latest created entry for the current run (with the exception of the `id`, `type`, `runpath` columns), during the entire lifetime of the current run.

### 3.3 Running the job

Once the database entry is made, `run` executes the `run-pi-microvm` script using the following options:

* `--workdir` copied from the `run` table's `workdir` column
* `--disk-size`, `--ram`, `--read-only`, come from the
  `runConfigs` subattribute's `disk`, `ram`, `roDirs`, but `disk` and `ram` are translated adequately
* `--model` comes from the `model` attribute in the `runConfigs` subattribute.
* `--api-key-file` receives the path of the openrouter API key file from
  the TOML config (the key itself is never copied, logged, or printed; only
  the path is handed to the script),
* the prompt from `prompt` is passed on stdin.
* `streamSocketFile` is passed as the output for the json stream

The `run-pi-microvm` script is resolved from the `runPiMicroVMPath` config value

### 3.4 Monitoring

While the script is running, `runmanager run` monitors the run's state and updates the database entry as follows: 
* The status changes from `initializing` to `ongoing` once the VM is booted and `pi` is confirmed running. 
* The status is set to `terminated` only in case the script did not exit correctly (i.e. the virtual machine it ran did not exit correctly or the `pi` process running within it did not exit correctly), in which case `endTime` is set as well. Also, the `workdir` column in the database is set to a null value. 
* The status is set to `done` if the run finishes without any issues

### 3.4.1 Hook when setting the status to `terminated`

If a run's status is set to `terminated` and `type` = "impure", then the corresponding directory in `runs` is deleted and the `latest` symlink is either linked back to the previous run, or deleted if this is run `0`.

If a run's status is set to `terminated`, for both `type` = "pure" and `type` = "impure", the `synthetic-latest` database entry for the current run is either modified to mirror the previous successful run, or is deleted if this is run `0`.

### 3.4.2 Hook when setting the status to `done`

If a run completes successfully, the contents of the `workdir` temporary directory created specifically for this run is moved to the nix store, the value of `outputPath` in the database is updated with its nix store path and also printed to stdout. 

Furthermore, if `type` = "impure", then the contents of `workdir` is also copied to `<impure flakeref>/runs/<runpath>`

Finally, `endTime` for the current run is set to the timestamp corresponding to these steps.

### 3.5. The `follows` attribute

If the `runConfigs` subattribute for the current runs as a `follows` attribute, the behaviour of the `run` subcommand is modified as follows:

If a path in the `follows` subattribute designates a run that is currently ongoing, then the `run` subcommand waits until its completion before beginning normal execution. 

This is the only case where behaviour changes. If not path in the `follows` subattribute designates a run that is currently ongoing, then the attribute is ignored.

## 4. The `list` subcommand

This command lists the entries of the postgresql's URL's  `run` table according to the config value `listedStatuses`. Here are some examples

     odit   # list everything
     o      # only ongoing
     d      # only done
     t      # only terminated
     i      # only initializing
     it     # only initializing and terminated

The output is a nushell-friendly table: whitespace-aligned columns whose first line holds single-word headers (same as the columns in type 3.0.6), with space-free ISO-8601 timestamps and no decoration rows, so that piping it into nushell's `detect columns` yields a proper structured table.
