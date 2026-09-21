{ pkgs, localPkgs, ... }:
# voice-input: push-to-talk audio recording + transcription + insertion at cursor.
#
# This is the voice input script proper; all transcription work is delegated
# to the `voice-transcribe' package (../voice-transcribe), the standalone
# OpenRouter transcription program this package was split off from.
#
# notifications: transient notifications (-t 5000, max 5 s) are sent on recording
# start and on transcription end (inserted / empty); error notifications are
# critical and persist.
#
# subcommands:
#   start                 : start recording the default audio source with pw-record
#   finish                : stop recording, transcribe the wav using the
#                           `voice-transcribe' program (OpenRouter, key read from
#                           /run/secrets/keys/openrouter by that program), and type the
#                           transcription wherever the cursor is with wtype
#   transcribe-file <path>: like finish but transcribes a given file instead of a recording
#                           (useful for testing, e.g. with ~/baghdad_plane/rectest/out.wav)
#
# options (before the subcommand, forwarded to the transcriber):
#   --config <file>       use <file> as the configuration file (instead of
#                         $VOICE_INPUT_CONFIG / the default search path)
#   --api-url <url>       override the 'api_url' config parameter
#   --model <id>          override the 'model' config parameter
#   --api-key-file <path> override the 'api_key_file' config parameter
#   --prompt <text>       override the 'prompt' config parameter
#   --pipe-command <cmd>  override the 'pipe_command' config parameter
#
# precedence (highest wins): CLI options > environment variables > config file
# > built-in defaults
#
# configuration file (searched in this order):
#   $VOICE_INPUT_CONFIG
#   ${XDG_CONFIG_HOME:-~/.config}/voice-input/config
#
#   api_url = <url>
#       OpenRouter endpoint the transcription request is POSTed to.
#       Default: https://openrouter.ai/api/v1/chat/completions
#   model = <model id>
#       OpenRouter model used for transcription (must accept audio input).
#       Default: google/gemini-2.5-flash
#   api_key_file = <path>
#       File the OpenRouter API key is read from.
#       Default: /run/secrets/keys/openrouter
#   prompt = <text>
#       Instruction sent to the model together with the audio.
#   pipe_command = <shell command>
#       If set, the transcription text is piped through this command (on stdin,
#       transformed text from stdout) before it is inputted/typed at the cursor.
#       Example: pipe_command = sed -e 's/um //g'
#
# environment variables (override the config file):
#   OPENROUTER_API_KEY / OPENROUTER_API_KEY_FILE : API key / key file
#   OPENROUTER_MODEL                             : model override
#   OPENROUTER_API_URL                           : API endpoint override (testing)

let
  #standalone, configurable transcription program (see ../voice-transcribe)
  voiceTranscribe = localPkgs.voice-transcribe;
in
pkgs.writeShellScriptBin "voice-input" ''
  set -euo pipefail

  recordFile=/tmp/voice-input-recording.wav
  pidFile=/tmp/voice-input-recording.pid
  logFile=/tmp/voice-input-transcribe.log

  notify() {
    ${pkgs.libnotify}/bin/notify-send -a voice-input "$@"
  }

  #transcribeAndInsert <wav-file> [transcriber options...]
  transcribeAndInsert() {
    wavFile="$1"; shift
    if [ ! -f "$wavFile" ]; then
      notify -u critical "voice-input" "no audio file to transcribe: $wavFile"
      return 1
    fi
    if ! text="$(${voiceTranscribe}/bin/voice-transcribe "$wavFile" "$@" 2>"$logFile")"; then
      notify -u critical "voice-input" "transcription failed, see $logFile"
      return 1
    fi
    #flatten newlines and trim whitespace so wtype never hits Enter and inserts nothing superfluous
    text="$(printf '%s' "$text" | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ *//;s/ *$//')"
    if [ ''${#text} -eq 0 ]; then
      notify -t 5000 "voice-input" "transcription was empty, nothing inserted"
      return 0
    fi
    if ${pkgs.wtype}/bin/wtype -s 5 -- "$text"; then
      notify -t 5000 "voice-input" "inserted transcription: ''${text:0:60}..."
    else
      notify -u critical "voice-input" "wtype failed: no wayland cursor to insert at?"
      return 1
    fi
  }

  start() {
    if [ -f "$pidFile" ]; then
      notify -u critical "voice-input" "recording already in progress"
      return 1
    fi
    rm -f "$recordFile"
    ${pkgs.pipewire}/bin/pw-record --target @DEFAULT_AUDIO_SOURCE@ --rate 16000 --channels 1 "$recordFile" >/dev/null 2>&1 &
    echo "$!" > "$pidFile"
    notify -t 5000 "voice-input" "recording started... (release rightcontrol to transcribe)"
  }

  finish() {
    if [ ! -f "$pidFile" ]; then
      notify -u critical "voice-input" "no recording in progress"
      return 1
    fi
    #$1.. = optional transcriber options (e.g. --config, --model)
    pid="$(cat "$pidFile")"
    rm -f "$pidFile"
    kill -INT "$pid" 2>/dev/null || true
    #wait for pw-record to finalize the wav file (up to 5s)
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i+1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      notify -u critical "voice-input" "recorder did not stop, wav may be incomplete"
      return 1
    fi
    transcribeAndInsert "$recordFile" "$@"
  }

  #collect leading --options (each takes one value argument) to forward to the
  #transcriber; the first non-option argument starts the subcommand
  opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --config|--api-url|--model|--api-key-file|--prompt|--pipe-command)
        if [ $# -lt 2 ]; then
          echo "voice-input: missing value for $1" >&2
          exit 1
        fi
        opts+=("$1" "$2")
        shift 2
        ;;
      *) break ;;
    esac
  done

  case "''${1:-}" in
    start) start ;;
    finish) finish "''${opts[@]+"''${opts[@]}"}" ;;
    transcribe-file)
      file="''${2:-}"
      if [ -z "$file" ]; then
        echo "usage: voice-input [--config FILE] [--api-url URL] [--model ID]" \
             "[--api-key-file FILE] [--prompt TEXT] [--pipe-command CMD]" \
             "[--save-directory DIR] [--save-limit N]" \
             "start|finish|transcribe-file <path>" >&2
        exit 1
      fi
      transcribeAndInsert "$file" ''${opts[@]+"''${opts[@]}"}
      ;;
    *)
      echo "usage: voice-input [--config FILE] [--api-url URL] [--model ID]" \
           "[--api-key-file FILE] [--prompt TEXT] [--pipe-command CMD]" \
           "[--save-directory DIR] [--save-limit N]" \
           "start|finish|transcribe-file <path>" >&2
      exit 1
      ;;
  esac
''
