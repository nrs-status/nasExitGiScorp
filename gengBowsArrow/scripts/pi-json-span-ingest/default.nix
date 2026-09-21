{ pkgs, ... }:
# pi-json-span-ingest: Python stream ingester that feeds the JSON-lines
# output of `pi-json-span-processor' into PostgreSQL via the target
# database's `pi_stream_ingest(jsonb)' function (span lines ->
# pi_stream_spans, session passthrough -> pi_stream_sessions; anything
# else is echoed to stderr).  Never creates the target database: it
# errors out if the database or the ingest function/tables are missing.
pkgs.runCommand "pi-json-span-ingest-1.0.0"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
    meta = with pkgs.lib; {
      description =
        "Stream pi-json-span-processor JSON lines into a PostgreSQL `pi' database";
      mainProgram = "pi-json-span-ingest";
      license = licenses.mit;
      platforms = platforms.linux;
    };
    pythonEnv = pkgs.python3.withPackages (ps: [
      ps.psycopg2 # PostgreSQL client library
    ]);
  }
  ''
    install -Dm555 ${./pi-json-span-ingest.py} $out/share/pi-json-span-ingest.py

    mkdir -p $out/bin
    makeWrapper $pythonEnv/bin/python3 $out/bin/pi-json-span-ingest \
      --add-flags "$out/share/pi-json-span-ingest.py"
  ''
