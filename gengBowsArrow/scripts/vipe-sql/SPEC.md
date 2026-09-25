# vipe-sql — specification

## 1. Overview

`vipe-sql` runs `vipe --sufix .sql`, starting an empty buffer, and then sends its contents to psql with `psql --file`.

The tool consists of two files in `gengBowsArrow/scripts/vipe-sql/`:

* `vipe-sql.sh` — the script itself (see sections 3–8),
* `default.nix` — the Nix packaging (see section 9).

## 2. Invocation syntax and validation

    vipe-sql <database>
    vipe-sql --help|-h

* `<database>` is passed verbatim to `psql --dbname=`. Because `psql`
  interprets `--dbname` liberally, the argument may be:
  * a plain database name (e.g. `mydb`), or
  * a full connection string (`postgresql://user@host:port/db` URI or
    `key=value` keyword string), which then overrides the environment-derived
    connection parameters of section 4.


## 3. --help

If the command is invoked with the --help flag, a help message explaining what the tool does and how to use it appears.

## 6. Normal invocation

If invoked normally (without the --help flag), the script performs the following steps, in order. Any step failing aborts
the run (section 3) and triggers the cleanup of section 5.


### 6.1 Database reachability check (fail early)

Before opening any editor, the script verifies the database exists and is
reachable. If it is not reachable, the script prints

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

## 8. Output summary

* **stdout:** output of `psql --file` (query results, `INSERT 0 1`
  tags, …), followed by the success line of section 6.5.
* **stderr:** usage/validation errors (6.1, 6.2), editor UI (via the
  terminal), `psql` notices and error messages.
* No secrets are printed; the SQL itself is only ever stored in the two
  mode-`0600` temporary files (section 5), both removed on exit.

