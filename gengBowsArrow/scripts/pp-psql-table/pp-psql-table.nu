# pp-psql-table: print the contents of a PostgreSQL table as a nushell table.

# Make psql available to nushell's external command resolution.
$env.PATH = ($env.PATH | prepend "@postgresql@/bin")

let pg_host = ($env.PGHOST? | default "/run/postgresql")

# Escape a string for use inside a single-quoted SQL literal.
def sql-lit [s: string] {
  $s | str replace --all "'" "''"
}

# Quote a PostgreSQL identifier (e.g. a schema or table name).
def quote-ident [s: string] {
  '"' + ($s | str replace --all '"' '""') + '"'
}

def usage [] {
  print "usage: pp-psql-table [--help] <database> <table>"
  print ""
  print "Prints the full contents of <table> in <database> as a nushell table."
  print "<table> may be schema-qualified (e.g. public.nodes); without a schema"
  print "qualifier the table is looked up in the current search path."
  print ""
  print "Options:"
  print "  --help     Show this usage information and exit."
  print ""
  print "Environment:"
  print "  PGHOST     PostgreSQL host or socket directory (default: /run/postgresql)"
}

def list-tables [db: string, pg_host: string] {
  let result = (
    psql
      --host $pg_host
      --dbname $db
      --csv
      --pset pager=off
      --command "SELECT schemaname || '.' || tablename AS \"table\" FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;"
      | complete
  )
  if $result.exit_code != 0 {
    []
  } else if ($result.stdout | str trim) == "" {
    []
  } else {
    $result.stdout | from csv | get table
  }
}

# Print the full contents of <table> in <database> as a nushell table.
#
# <table> may be schema-qualified (e.g. public.nodes); without a schema
# qualifier the table is looked up in the current search path.
#
# Environment:
#   PGHOST  PostgreSQL host or socket directory (default: /run/postgresql)
def main [
  database?: string
  table_name?: string
  --help  # Show usage information
] {
  if $help {
    # Nushell normally intercepts --help before this runs; fall back to our
    # custom usage text in case it ever reaches here.
    usage
    exit 0
  }
  if ($database == null) or ($table_name == null) {
    print -e "error: expected two arguments: a database name and a table name"
    usage
    exit 1
  }

  # Split an optional schema qualifier off the table name.
  let parts = ($table_name | split row ".")
  let schema = if ($parts | length) == 2 { $parts | first } else { null }
  let name = if ($parts | length) == 2 { $parts | get 1 } else { $table_name }

  # Check that the table exists before running the query, so that we can
  # produce a helpful error message (and avoid SQL injection through the
  # identifier).
  let cond = if ($schema == null) {
    $"tablename = '(sql-lit $name)'"
  } else {
    $"schemaname = '(sql-lit $schema)' AND tablename = '(sql-lit $name)'"
  }
  let check = (
    psql
      --host $pg_host
      --dbname $database
      --csv
      --pset pager=off
      --tuples-only
      --no-align
      --command $"SELECT count\(*) FROM pg_catalog.pg_tables WHERE ($cond)"
      | complete
  )
  if $check.exit_code != 0 {
    print -e $check.stderr
    exit 1
  }
  if ($check.stdout | str trim) == "0" {
    print -e $"pp-psql-table: table '($table_name)' does not exist in database '($database)'"
    let tables = (list-tables $database $pg_host)
    if not ($tables | is-empty) {
      print -e $"available tables: ($tables | str join ', ')"
    }
    exit 1
  }

  let qualified = if ($schema == null) {
    quote-ident $name
  } else {
    (quote-ident $schema) + "." + (quote-ident $name)
  }

  let result = (
    psql
      --host $pg_host
      --dbname $database
      --csv
      --pset pager=off
      --command $"SELECT * FROM ($qualified)"
      | complete
  )
  if $result.exit_code != 0 {
    print -e $result.stderr
    exit 1
  }

  let rows = (
    $result.stdout
    | from csv
    # PostgreSQL CSV output renders SQL NULL as an empty string; turn those
    # back into nushell nulls.
    | update cells {|cell| if ($cell | is-empty) { null } else { $cell } }
  )

  print $rows
}
