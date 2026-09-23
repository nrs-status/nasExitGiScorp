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
# console mode (--console flag, console = yes in the config file, or
# VOICE_INPUT_CONSOLE=1): for use on the Linux console (or any terminal) with
# no window manager, where neither notify-send (D-Bus notifications) nor wtype
# (wayland keyboard emulation) can work.  In this mode:
#   * notifications are printed to stderr (colourised when stderr is a
#     terminal) and additionally shown in the tmux status line via
#     display-message when a tmux server is reachable (tmux is *not* required)
#   * the transcription is typed into the active tmux pane with
#     `tmux send-keys -l' (literal text) instead of wtype; TMUX_PANE is
#     honoured so the text lands in the invoking pane even when started from
#     a run-shell key binding
# A window-manager session keeps the default behaviour unchanged.
#
# subcommands:
#   start                 : start recording the default audio source with pw-record
#   finish                : stop recording, transcribe the wav using the
#                           `voice-transcribe' program (OpenRouter, key read from
#                           /run/secrets/keys/openrouter by that program), and type the
#                           transcription wherever the cursor is with wtype
#                           (or tmux send-keys in console mode)
#   transcribe-file <path>: like finish but transcribes a given file instead of a recording
#                           (useful for testing, e.g. with ~/baghdad_plane/rectest/out.wav)
#
# options (before the subcommand, forwarded to the transcriber):
#   --console             run in console mode (no window manager: no
#                         notify-send, no wtype; see above)
#   --config <file>       use <file> as the configuration file (instead of
#                         $VOICE_INPUT_CONFIG / the default search path)
#   --api-url <url>       override the 'api_url' config parameter
#   --model <id>          override the 'model' config parameter
#   --api-key-file <path> override the 'api_key_file' config parameter
#   --prompt <text>       override the 'prompt' config parameter
#   --pipe-command <cmd>  override the 'pipe_command' config parameter
#
# precedence (highest wins): CLI options > environment variables > config file
# > built-in defaults; for the console flag specifically:
# --console > VOICE_INPUT_CONSOLE=1 > config file `console' key > no
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
#   console = yes|no
#       Console mode (see --console above): no notify-send, no wtype; stderr
#       feedback plus tmux display-message / tmux send-keys.  Any of
#       yes/true/on/1 enables it, anything else disables it.
#       Default: no
#
# environment variables (override the config file):
#   OPENROUTER_API_KEY / OPENROUTER_API_KEY_FILE : API key / key file
#   OPENROUTER_MODEL                             : model override
#   OPENROUTER_API_URL                           : API endpoint override (testing)
#   VOICE_INPUT_CONSOLE                          : enables console mode (=1)

let
  #standalone, configurable transcription program (see ../voice-transcribe)
  voiceTranscribe = localPkgs.voice-transcribe;
in
pkgs.writeShellScriptBin "voice-input" ''
  set -euo pipefail

  recordFile=/tmp/voice-input-recording.wav
  pidFile=/tmp/voice-input-recording.pid
  logFile=/tmp/voice-input-transcribe.log

  #console mode flag: on when --console is given, when console = yes is set in
  #the config file or when VOICE_INPUT_CONSOLE=1 is exported
  console=no

  #notify-send needs a D-Bus session bus, i.e. a window manager session; in
  #console mode everything goes to stderr instead (colourised when stderr is a
  #terminal, which the plain console makes true)
  notify() {
    ${pkgs.libnotify}/bin/notify-send -a voice-input "$@"
  }

  #consoleNotify <severity: critical|info> <message>
  #print to stderr and, when a tmux server is reachable, also flash the
  #message in the tmux status line (critical messages in red); tmux is
  #optional: without it the stderr line is all the user gets
  consoleNotify() {
    severity="$1"; shift
    msg="voice-input: $*"
    if [ -t 2 ]; then
      if [ "$severity" = critical ]; then
        printf '\033[1;31m%s\033[0m\n' "$msg" >&2
      else
        printf '\033[1;36m%s\033[0m\n' "$msg" >&2
      fi
    else
      printf '%s\n' "$msg" >&2
    fi
    if ${pkgs.tmux}/bin/tmux has-session 2>/dev/null; then
      if [ "$severity" = critical ]; then
        ${pkgs.tmux}/bin/tmux display-message "#[bold]#[red]$msg#[default]"
      else
        ${pkgs.tmux}/bin/tmux display-message "$msg"
      fi
    fi
  }

  notifyInfo() {
    if [ "$console" = yes ]; then consoleNotify info "$@"; else notify -t 5000 "voice-input" "$@"; fi
  }

  notifyError() {
    if [ "$console" = yes ]; then consoleNotify critical "$@"; else notify -u critical "voice-input" "$@"; fi
  }

  #transcribeAndInsert <wav-file> [transcriber options...]
  transcribeAndInsert() {
    wavFile="$1"; shift
    if [ ! -f "$wavFile" ]; then
      notifyError "no audio file to transcribe: $wavFile"
      return 1
    fi
    if ! text="$(${voiceTranscribe}/bin/voice-transcribe "$wavFile" "$@" 2>"$logFile")"; then
      notifyError "transcription failed, see $logFile"
      return 1
    fi
    #flatten newlines and trim whitespace so wtype/send-keys never hits Enter and inserts nothing superfluous
    text="$(printf '%s' "$text" | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ *//;s/ *$//')"
    if [ ''${#text} -eq 0 ]; then
      notifyInfo "transcription was empty, nothing inserted"
      return 0
    fi
    if [ "$console" = yes ]; then
      #console: no wtype (it needs a wayland compositor); type into the active
      #tmux pane instead.  TMUX_PANE points at the pane the key binding was
      #pressed in, so the text lands there even when run from another pane or
      #from a run-shell context.  -l sends the text literally (no key names);
      #newlines have been flattened above, so nothing but text is sent.
      #Without a tmux server there is nothing to type into: fail loudly
      #instead of silently dropping the transcription.
      if ! ${pkgs.tmux}/bin/tmux has-session 2>/dev/null; then
        notifyError "no tmux server running: nowhere to type the transcription"
        return 1
      fi
      if [ -n "''${TMUX_PANE:-}" ]; then
        ${pkgs.tmux}/bin/tmux send-keys -l -t "''${TMUX_PANE}" -- "$text"
      else
        ${pkgs.tmux}/bin/tmux send-keys -l -- "$text"
      fi
      notifyInfo "inserted transcription into tmux: ''${text:0:60}..."
    elif ${pkgs.wtype}/bin/wtype -s 5 -- "$text"; then
      notifyInfo "inserted transcription: ''${text:0:60}..."
    else
      notifyError "wtype failed: no wayland cursor to insert at?"
      return 1
    fi
  }

  start() {
    if [ -f "$pidFile" ]; then
      notifyError "recording already in progress"
      return 1
    fi
    rm -f "$recordFile"
    ${pkgs.pipewire}/bin/pw-record --target @DEFAULT_AUDIO_SOURCE@ --rate 16000 --channels 1 "$recordFile" >/dev/null 2>&1 &
    echo "$!" > "$pidFile"
    notifyInfo "recording started... (toggle the voice key again to transcribe)"
  }

  finish() {
    if [ ! -f "$pidFile" ]; then
      notifyError "no recording in progress"
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
      notifyError "recorder did not stop, wav may be incomplete"
      return 1
    fi
    transcribeAndInsert "$recordFile" "$@"
  }

  usage() {
    echo "usage: voice-input [--console] [--config FILE] [--api-url URL] [--model ID]" \
         "[--api-key-file FILE] [--prompt TEXT] [--pipe-command CMD]" \
         "[--save-directory DIR] [--save-limit N]" \
         "start|finish|transcribe-file <path>" >&2
  }

  #collect leading --options: the value-taking ones are forwarded to the
  #transcriber, --console applies here; the first non-option argument starts
  #the subcommand
  opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --console)
        console=yes
        shift
        ;;
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

  #config file (the transcriber options are re-parsed by voice-transcribe, so
  #only the console flag needs to be extracted here; --console on the command
  #line already won above if it was given)
  config="''${VOICE_INPUT_CONFIG:-}"
  if [ -z "$config" ]; then
    config="''${XDG_CONFIG_HOME:-$HOME/.config}/voice-input/config"
  fi
  if [ "$console" = no ] && [ -f "$config" ]; then
    value="$(sed -n 's/^[[:space:]]*console[[:space:]]*=[[:space:]]*//p' "$config" | head -n 1 | tr -d '[:space:]')"
    case "$value" in
      yes|true|on|1) console=yes ;;
    esac
  fi
  if [ "$console" = no ] && [ "''${VOICE_INPUT_CONSOLE:-}" = 1 ]; then
    console=yes
  fi

  case "''${1:-}" in
    start) start ;;
    finish) finish "''${opts[@]+"''${opts[@]}"}" ;;
    transcribe-file)
      file="''${2:-}"
      if [ -z "$file" ]; then
        usage
        exit 1
      fi
      transcribeAndInsert "$file" ''${opts[@]+"''${opts[@]}"}
      ;;
    *)
      usage
      exit 1
      ;;
  esac
''
