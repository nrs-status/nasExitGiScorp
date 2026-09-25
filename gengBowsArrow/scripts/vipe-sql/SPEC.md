# vipe-sql — specification

## 1. Overview

`vipe-sql` is a command line tool (a Bash script) that lets the user compose
an SQL script interactively in their editor and apply it to a PostgreSQL
database in a single step. It opens the user's editor on an empty temporary
file with a `.sql` suffix (via moreutils' `vipe --suffix .sql`, so the editor
can enable SQL syntax highlighting), captures the edited content, and feeds it
to the given database with `psql --file`.

The tool consists of two files in `gengBowsArrow/scripts/vipe-sql/`:

* `vipe-sql.sh` — the script itself (see sections 3–8),
* `default.nix` — the Nix packaging (see section 9).

## 2. Invocation

    vipe-sql <database>

* The command takes exactly one positional argument, `<database>`.
* There are no options, flags, or subcommands.
* `<database>` is passed verbatim to `psql --dbname=`. Because `psql`
  interprets `--dbname` liberally, the argument may be:
  * a plain database name (e.g. `mydb`), or
  * a full connection string (`postgresql://user@host:port/db` URI or
    `key=value` keyword string), which then overrides the environment-derived
    connection parameters of section 4.

## 3. Shell environment and error mode

The script runs under `#!/usr/bin/env bash` with `set -euo pipefail`:

* any command failing (outside of an explicit conditional) aborts the script
  with that command's exit status,
* use of an unset variable is a fatal error,
* a failure in any member of a pipeline fails the pipeline.

When packaged with `default.nix` (section 9), `writeShellApplication`
prepends its own equivalent strict-mode prologue; the script's own shebang
line and `set -euo pipefail` line are then redundant but harmless.

## 4. Configuration

`vipe-sql` has no configuration of its own. It inherits behaviour from its
two delegated tools:

* **Editor selection** — `vipe` opens `$VISUAL` if set, otherwise `$EDITOR`,
  otherwise its compiled-in default (`vi`).
* **PostgreSQL connection** — apart from `--dbname=<database>`, all
  connection parameters (host, port, user, password, …) come from the
  standard libpq environment variables (`PGHOST`, `PGPORT`, `PGUSER`,
  `PGPASSWORD`, `PGSERVICE`, …), `~/.pgpass`, and libpq defaults (Unix
  socket, current OS username).
* **psqlrc** — the connectivity check of section 6.1 is run with
  `--no-psqlrc`, but the *apply* step of section 6.4 is **not**: the user's
  `~/.psqlrc` (and `PSQLRC`) is read there and may affect behaviour, notably
  `\set ON_ERROR_STOP on` (see section 7).

## 5. Temporary file

* Created with `mktemp /tmp/vipe-sql.XXXXXX.sql`:
  * located in `/tmp` (hard-coded; `$TMPDIR` is **not** consulted),
  * named `vipe-sql.<6 random chars>.sql`,
  * mode `0600`, owned by the invoking user,
  * created empty.
* Immediately after creation, a `trap 'rm -f "$tmp"' EXIT` is installed, so
  the file is removed on every exit path of the script (success, failure due
  to `set -e`, or termination by a signal for which Bash runs the EXIT trap,
  e.g. SIGINT/SIGTERM).
* Independently, `vipe` creates and cleans up its **own** temporary `.sql`
  file (that is the file the editor actually opens); the `mktemp` file above
  only stores `vipe`'s stdout so it can be handed to `psql --file`.

## 6. Runtime behaviour

The script performs the following steps, in order. Any step failing aborts
the run (section 3) and triggers the cleanup of section 5.

### 6.1 Argument validation

If the number of arguments is not exactly 1, the script prints

    usage: vipe-sql <database>

to **stderr** and exits with status `1`.

### 6.2 Database reachability check (fail early)

Before opening any editor, the script verifies the database exists and is
reachable by running:

    psql --dbname="$db" --tuples-only --no-psqlrc --command='SELECT 1'

with both stdout and stderr discarded. If this command fails (unknown
database, unreachable server, authentication failure, …), the script prints

    vipe-sql: database '<database>' not found or not accessible

to **stderr** and exits with status `1`. This guarantees the user never
composes SQL that cannot be delivered.

### 6.3 Interactive editing

The script runs:

    vipe --suffix .sql < /dev/null > "$tmp"

* `vipe` is deliberately run **bare** (not wrapping another command),
  because `vipe` parses every `-flag`-looking argument for itself and would
  swallow options intended for a wrapped command.
* stdin is redirected from `/dev/null`, so the editor opens on an **empty**
  buffer.
* `vipe` copies the (empty) stdin into its own temp file named `<tmp>.sql`,
  runs the editor on it, and writes the resulting content to stdout, which
  the script captures into the temporary file of section 5.
* The `.sql` suffix exists solely so the editor detects the filetype.
* If the editor exits non-zero (e.g. `:cq` in Vim), `vipe` exits non-zero
  and the script aborts with that status; **nothing is sent to the
  database**. This is the supported way to cancel a `vipe-sql` invocation.
* Saving an **empty** buffer is *not* an error: the empty file proceeds to
  section 6.4, where `psql` executes no statements and succeeds.

### 6.4 Applying the SQL

The script runs:

    psql --dbname="$db" --file="$tmp"

* `psql`'s stdout/stderr are inherited: per-statement results, notices and
  errors appear directly on the user's terminal.
* Note that `--no-psqlrc` is **not** passed here (section 4).

### 6.5 Success message

If (and only if) the `psql` invocation of section 6.4 exits `0`, the script
prints to **stdout**:

    vipe-sql: SQL applied to database '<database>'

and exits with status `0`.

## 7. Exit status

| status | condition |
|--------|-----------|
| `0` | full success (including the empty-buffer case of section 6.3) |
| `1` | wrong argument count (6.1) or unreachable database (6.2) |
| exit status of `vipe` | editor/`vipe` failure (6.3); no SQL is applied |
| exit status of `psql` | failure of the apply step (6.4): `1` fatal error (e.g. file unreadable), `2` connection lost, `3` script error **only if** `ON_ERROR_STOP` is set |

**Caveat (inherited from `psql`):** with default settings, SQL errors inside
the file do **not** make `psql --file` exit non-zero; failed statements are
reported on stderr, the remaining statements still run, `psql` exits `0`,
and the success message of section 6.5 is printed. Users wanting
all-or-nothing semantics must set `ON_ERROR_STOP` (e.g. in `~/.psqlrc`,
which the apply step honours) and/or begin their script with `BEGIN;`.

## 8. Output summary

* **stdout:** output of `psql --file` (query results, `INSERT 0 1`
  tags, …), followed by the success line of section 6.5.
* **stderr:** usage/validation errors (6.1, 6.2), editor UI (via the
  terminal), `psql` notices and error messages.
* No secrets are printed; the SQL itself is only ever stored in the two
  mode-`0600` temporary files (section 5), both removed on exit.

## 9. Packaging (`default.nix`)

`default.nix` is a function `{ pkgs, ... }:` returning

    pkgs.writeShellApplication {
      name = "vipe-sql";
      runtimeInputs = [ pkgs.moreutils pkgs.postgresql ];
      text = builtins.readFile ./vipe-sql.sh;
    }

* `runtimeInputs` guarantees `vipe` (from `moreutils`) and `psql` (from
  `postgresql`) are on `PATH` at run time, regardless of the caller's
  environment.
* `writeShellApplication` additionally:
  * substitutes its own `bash` shebang and strict-mode prologue (section 3),
  * runs **shellcheck** over the script at build time, so the package fails
    to build if the script has shellcheck findings.
* The package is exposed through `gengBowsArrow/scripts/default.nix` into the
  flake's `packages."x86_64-linux"` set (via the `localPkgs` fixpoint in the
  top-level `flake.nix`).

## 10. Dependencies

| tool | provided by | used for |
|------|-------------|----------|
| `bash` | shebang / `writeShellApplication` | interpreter |
| `vipe` | `pkgs.moreutils` | editor round-trip with `.sql` suffix |
| `psql` | `pkgs.postgresql` | connectivity check and SQL execution |
| `mktemp`, `rm`, `echo` | coreutils / bash builtins | temp-file lifecycle, messages |

## 11. Known limitations

1. The temporary file is always placed in `/tmp`, ignoring `$TMPDIR`.
2. SQL errors do not fail the run unless the user configures
   `ON_ERROR_STOP` (section 7).
3. The reachability check (6.2) and the apply step (6.4) are not atomic: the
   database may disappear while the user is editing; the apply step then
   fails with `psql`'s own error.
4. There is no way to re-open the editor after a failed apply; the composed
   SQL is deleted with the temp files on exit and must be rewritten.
5. Asymmetric psqlrc handling: the check uses `--no-psqlrc`, the apply step
   does not (section 4).
