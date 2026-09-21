# pp-psql-table: print the contents of a PostgreSQL table as a nushell table.
#
# NOTE: this directory is auto-imported by ../default.nix
# (baseLib.importPairsOfDirPath), which passes `localPkgsArgs` (plus
# `localPkgs`) as the single argument, so we destructure `pkgs` from it
# instead of expecting the original flake-shaped `inputs` record.
{ pkgs, ... }:
let
  ppPsqlTable =
    let
      script = pkgs.writers.writeNu "pp-psql-table" (
        builtins.replaceStrings [ "@postgresql@" ] [ "${pkgs.postgresql}" ]
          (builtins.readFile ./pp-psql-table.nu)
      );
    in
    # writeNu's output is a bare symlink to the script file, so repackage it
    # into a proper bin/ directory so that "${ppPsqlTable}/bin/pp-psql-table"
    # (and thus `nix run .#pp-psql-table`) works.
    pkgs.runCommand "pp-psql-table-bin"
      {
        preferLocalBuild = true;
        # so that `nix run .#scripts.pp-psql-table` executes
        # bin/pp-psql-table rather than the derivation name
        meta.mainProgram = "pp-psql-table";
      }
      ''
      mkdir -p $out/bin
      ln -s ${script} $out/bin/pp-psql-table
    '';
in
ppPsqlTable