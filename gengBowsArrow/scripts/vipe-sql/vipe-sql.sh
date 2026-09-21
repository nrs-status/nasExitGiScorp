#!/usr/bin/env bash
set -euo pipefail

# vipe-sql <database>
#
# Opens your $EDITOR on a temporary file with a `.sql' suffix (courtesy of
# `vipe --suffix .sql`), then applies the resulting SQL file to the given
# PostgreSQL database with `psql -f`.

if [ "$#" -ne 1 ]; then
	echo "usage: vipe-sql <database>" >&2
	exit 1
fi

db=$1

# Fail early if the database does not exist / is not reachable.
if ! psql --dbname="$db" --tuples-only --no-psqlrc --command='SELECT 1' >/dev/null 2>&1; then
	echo "vipe-sql: database '$db' not found or not accessible" >&2
	exit 1
fi

# vipe would swallow any options of a wrapped command (it parses every
# `-flag' for itself), so run it bare: it copies its stdin (empty) into a
# temp file named <tmp>.sql, runs $EDITOR on it, and dumps the result on
# stdout, which we capture and feed to psql.
tmp=$(mktemp /tmp/vipe-sql.XXXXXX.sql)
trap 'rm -f "$tmp"' EXIT
vipe --suffix .sql < /dev/null > "$tmp"
psql --dbname="$db" --file="$tmp"
echo "vipe-sql: SQL applied to database '$db'"
