{ pkgs, ... }:
# voice-transcribe: standalone, configurable audio transcription via OpenRouter.
#
# This is the transcription half split out of the former `voice-input'
# package: a pure Python program (./transcribe.py) packaged as a single
# self-contained executable `voice-transcribe' so it can be run standalone,
# purely for the purpose of doing configurable voice transcription
# (audio file or raw audio stream on stdin -> transcription text on stdout).
#
# The `voice-input' package (the push-to-talk script proper, now in its own
# directory) imports this package and calls `${voice-transcribe}' for all of
# its transcription work; see ../voice-input/default.nix.
#
# usage:
#   voice-transcribe <audio-file>
#   voice-transcribe -            # read raw audio from stdin
#
# options (all forwarded to the OpenRouter call, see `voice-transcribe --help'):
#   --config <file>       use <file> as the configuration file (instead of
#                         $VOICE_INPUT_CONFIG / the default search path)
#   --api-url <url>       override the 'api_url' config parameter
#   --model <id>          override the 'model' config parameter
#   --api-key-file <path> override the 'api_key_file' config parameter
#   --prompt <text>       override the 'prompt' config parameter
#   --pipe-command <cmd>  override the 'pipe_command' config parameter
#   --save-directory <dir>  override the 'save_directory' config parameter
#   --save-limit <n>      override the 'save_limit' config parameter
#   (the config file may additionally contain a 'console' key, which is
#   consumed by the voice-input push-to-talk script and ignored here)
#
# precedence (highest wins): CLI options > environment variables > config file
# > built-in defaults; without any override the API key is read from
# /run/secrets/keys/openrouter (see the module docstring in ./transcribe.py
# for the full configuration matrix).
pkgs.writers.writePython3Bin "voice-transcribe"
  {
    libraries = [ pkgs.python3Packages.requests ];
    #the module docstring deliberately contains long documentation lines,
    #and the code deliberately uses this repo's compact comment style
    flakeIgnore = [
      "E501" # line too long (docstring)
      "E265" # block comment should start with '# '
      "W503" # line break before binary operator
    ];
  }
  (builtins.readFile ./transcribe.py)
