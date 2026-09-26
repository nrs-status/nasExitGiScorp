{ pkgs, ... }:
# jev: a command-line front end to OpenRouter's Jev model.
#
# The program (./jev.py) reads one JSON object from stdin, sets its `model`
# field to the configured Jev model, POSTs it to OpenRouter's decisions
# endpoint and writes the JSON response body to stdout. See ./SPEC.md for the
# behavioural specification.
#
# usage:
#   jev [--api-key-file PATH] [--model MODEL] [--api-url URL]
#
# The API key file path comes from --api-key-file, else $OPENROUTER_API_KEY,
# else /run/secrets/keys/openrouter (the command line option has the higher
# precedence). The model comes from --model, else $DEFAULT_JEV_MODEL, else
# ~typesafe/jev-latest (again the command line option wins).
pkgs.writers.writePython3Bin "jev"
  {
    #the module docstring deliberately contains long documentation lines,
    #and the code deliberately uses this repo's compact comment style
    flakeIgnore = [
      "E501" # line too long (docstring/comments)
      "E265" # block comment should start with '# '
    ];
  }
  (builtins.readFile ./jev.py)
