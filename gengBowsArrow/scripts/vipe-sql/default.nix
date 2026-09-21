{ pkgs, ... }:
# vipe-sql: takes the name of a PostgreSQL database, opens an editor on a
# temporary `.sql` file (via `vipe --suffix .sql`), and then pipes the
# resulting SQL file straight into that database with `psql -f`.
pkgs.writeShellApplication {
  name = "vipe-sql";
  runtimeInputs = [
    pkgs.moreutils # provides `vipe'
    pkgs.postgresql # provides `psql'
  ];
  text = builtins.readFile ./vipe-sql.sh;
}
