{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  pname = "tiles";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm444 tiles.py $out/share/tiles/tiles.py
    install -Dm444 exampleConfig.toml $out/share/tiles/exampleConfig.toml
    install -Dm555 launcher.sh $out/bin/tiles

    wrapProgram $out/bin/tiles \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.python3 ]} \
      --set TILES_PY $out/share/tiles/tiles.py \
      --set TILES_EXAMPLE_CONFIG $out/share/tiles/exampleConfig.toml

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Tiled terminal launcher: press a key to run a command in a full-screen tile grid";
    mainProgram = "tiles";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
