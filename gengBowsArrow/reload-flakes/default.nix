{
  pkgs,
  ...
}:
# reload-flakes: batch-update selected flake inputs of several local git
# repositories containing Nix flakes; see ./SPEC.md for the behavioural
# specification and ./SPEC2.md for the completed/fixed version that this
# implementation follows.
#
# A pure Python program (./reload-flakes.py, stdlib only -- TOML parsing
# uses the stdlib `tomllib') packaged as a single executable `reload-flakes'
# with `nix' and `git' on its PATH, since it shells out to both:
#
# usage:
#   reload-flakes CONFIG_FILE
#   reload-flakes -h | --help
#
# If CONFIG_FILE is omitted, the path is taken from the environment
# variable DEFAULT_RELOAD_FLAKES_CONFIG_PATH (the command line argument
# has the higher precedence).
let
  script = pkgs.writers.writePython3Bin "reload-flakes"
    {
      #the module docstring deliberately contains long documentation lines,
      #and the code deliberately uses this repo's compact comment style
      flakeIgnore = [
        "E501" # line too long (docstring/comments)
        "E265" # block comment should start with '# '
      ];
    }
    (builtins.readFile ./reload-flakes.py);
in
pkgs.symlinkJoin {
  name = "reload-flakes";
  paths = [ script ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/reload-flakes \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix pkgs.git ]}
  '';
}
