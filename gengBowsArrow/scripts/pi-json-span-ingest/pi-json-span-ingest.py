#!/usr/bin/env python3
"""Stream the output of `pi-json-span-processor' into PostgreSQL.

Usage: span-ingest.py [CONNECTION]

CONNECTION is a libpq connection string / URL for the target database
(default: "dbname=pi host=/run/postgresql", i.e. the local `pi' database).

Input: JSON lines as emitted by `pi-json-span-processor'.  Each line is
routed through the database's `pi_stream_ingest(jsonb)' function:

  * span lines (`"span": "agent" | "turn" | "message" | "tool_execution"')
    land in `pi_stream_spans';
  * `session' passthrough lines land in `pi_stream_sessions';
  * anything else is reported on stderr (it was streamed through stdin
    but not successfully ingested).

Guarantees:
  * The program NEVER creates a database.  If the target database does
    not exist it errors out immediately.
  * Lines are ingested incrementally (streamed) as they arrive on stdin.
  * Any line that was not successfully ingested (unparseable, skipped by
    the ingest function, or a failed insert) is echoed verbatim to
    stderr, and ingestion continues with the next line.
  * On a fatal error (e.g. the connection dies) everything that streamed
    through stdin but was not ingested is flushed to stderr before exit.
"""

import json
import os
import sys

import psycopg2

DEFAULT_CONNINFO = "dbname=pi host=/run/postgresql"
PROG = "span-ingest"


def echo_stderr(line: str) -> None:
    sys.stderr.write(line if line.endswith("\n") else line + "\n")
    sys.stderr.flush()


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[valid-type]
    print(f"{PROG}: error: {msg}", file=sys.stderr)
    sys.exit(code)


def drain_stdin_to_stderr() -> None:
    """Flush the rest of stdin to stderr (fatal-error path)."""
    try:
        for raw in sys.stdin:
            line = raw.rstrip("\n")
            if line.strip():
                echo_stderr(line)
    except OSError:
        pass


def connect(conninfo: str):
    """Connect to the target database without ever creating it."""
    try:
        conn = psycopg2.connect(conninfo)
        conn.autocommit = True
        return conn
    except psycopg2.OperationalError as e:
        die(f"could not connect to database (not creating it): {e}")


def check_database_exists(base_conninfo: str, dbname: str) -> None:
    """Verify the target database exists (fail otherwise; never create)."""
    probe = " ".join(
        part for part in (base_conninfo, "dbname=postgres") if part
    )
    try:
        with psycopg2.connect(probe) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT 1 FROM pg_database WHERE datname = %s", (dbname,)
                )
                if cur.fetchone() is None:
                    die(
                        f"database '{dbname}' does not exist; "
                        f"refusing to create it"
                    )
    except psycopg2.OperationalError as e:
        die(f"could not probe server for database '{dbname}': {e}")


def check_schema(conn) -> None:
    """Ensure the ingest function and both stream tables exist."""
    required = ("pi_stream_spans", "pi_stream_sessions")
    with conn.cursor() as cur:
        cur.execute(
            "SELECT proname FROM pg_proc "
            "WHERE proname = 'pi_stream_ingest' "
            "AND pronamespace = 'public'::regnamespace"
        )
        if cur.fetchone() is None:
            die("function pi_stream_ingest(jsonb) is missing from the target database")
        for table in required:
            cur.execute(
                "SELECT 1 FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_name = %s",
                (table,),
            )
            if cur.fetchone() is None:
                die(f"table '{table}' does not exist in the target database")


def main() -> None:
    conninfo = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "PI_INGEST_CONNINFO", DEFAULT_CONNINFO
    )
    if len(sys.argv) > 2:
        die("usage: span-ingest.py [CONNECTION]")

    dbname = "pi"
    for token in conninfo.split():
        if token.startswith("dbname="):
            dbname = token[len("dbname=") :]
    if conninfo.startswith("postgres"):
        # URL form: extract the path component as the database name.
        from urllib.parse import urlparse

        path = urlparse(conninfo).path.lstrip("/")
        if path:
            dbname = path

    check_database_exists(conninfo, dbname)
    conn = connect(conninfo)
    check_schema(conn)

    ingest_sql = "SELECT pi_stream_ingest(%s::jsonb)"
    ingested = 0
    failed = 0
    cur = conn.cursor()
    try:
        for raw in sys.stdin:
            line = raw.rstrip("\n")
            if not line.strip():
                continue  # empty line: no data, nothing to report
            try:
                json.loads(line)  # validate; the server re-parses as jsonb
            except ValueError:
                failed += 1
                echo_stderr(line)
                continue
            try:
                cur.execute(ingest_sql, (line,))
                result = cur.fetchone()[0]
                if result in ("span", "session"):
                    ingested += 1
                else:  # 'skipped': streamed through but not ingested
                    failed += 1
                    echo_stderr(line)
            except (psycopg2.Error, TypeError, ValueError) as e:
                failed += 1
                echo_stderr(line)
                try:
                    conn.rollback()
                    conn.autocommit = True
                except psycopg2.Error:
                    # Connection unusable: flush the remaining input to
                    # stderr and abort.
                    drain_stdin_to_stderr()
                    die(
                        f"fatal database error after {ingested} ingested "
                        f"line(s); remaining input flushed to stderr: {e}",
                        code=3,
                    )
    except (BrokenPipeError, OSError):
        pass
    finally:
        cur.close()
        conn.close()

    print(
        f"{PROG}: ingested {ingested} line(s); "
        f"{failed} line(s) written to stderr",
        file=sys.stderr,
    )
    sys.exit(0 if failed == 0 else 2)


if __name__ == "__main__":
    main()
