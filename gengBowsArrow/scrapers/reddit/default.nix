{ pkgs, pkgsLib, ... }:

let
  python = pkgs.python3.withPackages (ps: [ ps.psycopg2 ]);
  share = "share/reddit-scraper";
in
pkgs.stdenv.mkDerivation {
  pname = "reddit-scraper";
  version = "1.0.0";
  src = ./.;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/${share} $out/bin
    install -Dm444 reddit_scraper.py $out/${share}/reddit_scraper.py
    install -Dm444 config.example.toml $out/${share}/config.example.toml
    install -Dm444 compose.yaml Dockerfile requirements.txt README.md .env.example $out/${share}/
    cat > $out/bin/reddit-scraper <<EOF
#!${pkgs.runtimeShell}
exec ${python}/bin/python $out/${share}/reddit_scraper.py "\$@"
EOF
    chmod 0555 $out/bin/reddit-scraper

    runHook postInstall
  '';

  meta = with pkgsLib; {
    description = "Configurable Reddit OAuth scraper with PostgreSQL storage and IPv4-only networking";
    mainProgram = "reddit-scraper";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
