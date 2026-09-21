#!/usr/bin/env python3
"""
Transcribe an audio file or stream via OpenRouter.

Usage:
  python3 transcribe.py out.wav
  python3 transcribe.py audio.mp3
  some-command | python3 transcribe.py -          # read raw audio from stdin

Command line options:
  --config <file>       use <file> as the configuration file instead of the
                        default search path (a missing --config file is an error)
  --api-url <url>       override the 'api_url' config parameter
  --model <id>          override the 'model' config parameter
  --api-key-file <path> override the 'api_key_file' config parameter
  --prompt <text>       override the 'prompt' config parameter
  --pipe-command <cmd>  override the 'pipe_command' config parameter
                        (an empty value disables the pipe entirely)
  --save-directory <dir>  override the 'save_directory' config parameter
  --save-limit <n>      override the 'save_limit' config parameter

The API call to OpenRouter is configurable via command line options,
environment variables and the optional configuration file.
Precedence (highest wins):
  1. command line options (--config, --api-url, --model, --api-key-file,
     --prompt, --pipe-command, --save-directory, --save-limit)
  2. environment variables ($OPENROUTER_API_KEY, $OPENROUTER_API_KEY_FILE,
     $OPENROUTER_MODEL, $OPENROUTER_API_URL, $VOICE_INPUT_SAVE_DIRECTORY,
     $VOICE_INPUT_SAVE_LIMIT)
  3. the configuration file (keys below)
  4. built-in defaults
Without any override the API key is read from /run/secrets/keys/openrouter.

Optional configuration file (--config <file>, else searched in this order):
  $VOICE_INPUT_CONFIG
  ${XDG_CONFIG_HOME:-~/.config}/voice-input/config

Config format ('key = value' lines; '#' comments and blank lines ignored):
  api_url = <url>
      OpenRouter endpoint to POST the chat-completions request to.
      Default: https://openrouter.ai/api/v1/chat/completions
      Example: api_url = https://openrouter.ai/api/v1/chat/completions
  model = <model id>
      OpenRouter model used for the transcription (must accept audio input).
      Default: google/gemini-2.5-flash
      Example: model = openai/gpt-4o-audio-preview
  api_key_file = <path>
      File the OpenRouter API key is read from (single line).
      Default: /run/secrets/keys/openrouter
      Example: api_key_file = /home/me/secrets/openrouter.key
  prompt = <text>
      Instruction sent to the model together with the audio.
      Default: "Transcribe this audio to plain text. Output only the transcription."
      Example: prompt = Transcribe this audio. Keep filler words.
  pipe_command = <shell command>
      If set, the transcription text is piped through this shell command
      (text on stdin, transformed text read from stdout) before it is
      printed and ultimately inputted (typed) at the cursor. Example:
        pipe_command = sed -e 's/um //g' -e 's/uh //g'
  save_directory = <path>
      Directory transcriptions are automatically archived to: the raw audio
      is saved as <name>.wav and the transcription as <name>.txt, where
      <name> corresponds to the moment the recording began (for file input
      the file's mtime is used as the best available approximation; for
      stdin input the current time). The directory is created if it does
      not exist. Errors in this stage are fatal and abort the program.
      Default: unset (no archiving)
      Example: save_directory = /home/me/voice-logs
  save_limit = <n>
      Maximum number of voice recordings kept in 'save_directory'. When the
      limit is reached the most recent recordings are kept (including the
      newest one). 0 disables the archive entirely ('save_directory' is
      ignored). Must be a non-negative integer.
      Default: 0
      Example: save_limit = 50
"""

import argparse
import base64
import errno
import json
import os
import selectors
import socket
import subprocess
import sys
import time

import requests
import urllib3.util.connection as urllib3_connection
from urllib3.exceptions import LocationParseError

# How long to wait for the TCP connection to be established (as an overall
# budget for one address family race, not per address) and how long to wait
# for the model's response once connected.
CONNECT_TIMEOUT = 10
READ_TIMEOUT = 120

# Happy Eyeballs (RFC 8305): connect to the resolved IPv6 and IPv4 candidates
# in parallel, starting each next candidate this many seconds after the
# previous one, and keep whichever connects first.
#
# urllib3's stock create_connection tries every address strictly one after
# another with the full connect timeout. On a host whose IPv6 is blackholed
# -- a router that keeps advertising a global prefix it no longer routes
# upstream, so TCP SYNs are silently dropped instead of answered with an
# ICMPv6 error -- the IPv6 addresses come first and each one stalled the whole
# connect timeout before IPv4 was even attempted, so a transcription took
# minutes instead of seconds. Racing the candidates fixes that without
# preferring one family over the other: on a healthy dual-stack network IPv6
# still wins, on a blackholed one IPv4 wins almost immediately, and on an
# IPv6-only host the IPv6 attempt wins.
HAPPY_EYEBALLS_DELAY = 0.25


def happy_eyeballs_create_connection(
    address,
    timeout=socket._GLOBAL_DEFAULT_TIMEOUT,
    source_address=None,
    socket_options=None,
):
    """Drop-in replacement for urllib3.util.connection.create_connection."""
    host, port = address
    if host.startswith("["):
        host = host.strip("[]")
    try:
        host.encode("idna")
    except UnicodeError:
        raise LocationParseError(f"'{host}', label empty or too long") from None

    candidates = []
    seen = set()
    for af, socktype, proto, _canonname, sa in socket.getaddrinfo(
        host, port, urllib3_connection.allowed_gai_family(), socket.SOCK_STREAM
    ):
        if sa not in seen:
            seen.add(sa)
            candidates.append((af, socktype, proto, sa))
    if not candidates:
        raise OSError("getaddrinfo returns an empty list")

    numeric_timeout = isinstance(timeout, (int, float))
    deadline = time.monotonic() + timeout if numeric_timeout else None

    selector = selectors.DefaultSelector()
    last_error = None
    next_candidate = 0
    start_next_at = time.monotonic()

    def start(candidate):
        """Start a non-blocking connect and register the socket, or save the failure."""
        nonlocal last_error
        af, socktype, proto, sa = candidate
        sock = socket.socket(af, socktype, proto)
        for option in socket_options or ():
            sock.setsockopt(*option)
        sock.setblocking(False)
        if source_address:
            sock.bind(source_address)
        code = sock.connect_ex(sa)
        if code not in (0, errno.EINPROGRESS, errno.EAGAIN, errno.EWOULDBLOCK):
            last_error = OSError(code, os.strerror(code))
            sock.close()
            return
        selector.register(sock, selectors.EVENT_WRITE, sa)

    def finish(sock, connected):
        """Unregister a socket; return it (blocking, with the caller's timeout) if connected."""
        selector.unregister(sock)
        if not connected:
            sock.close()
            return None
        sock.setblocking(True)
        if numeric_timeout:
            sock.settimeout(timeout)
        return sock

    def close_pending():
        for key in list(selector.get_map().values()):
            key.fileobj.close()
        selector.close()

    while True:
        if deadline is not None and time.monotonic() >= deadline:
            break
        # start every candidate whose staggered turn has arrived
        now = time.monotonic()
        while next_candidate < len(candidates) and now >= start_next_at:
            start(candidates[next_candidate])
            next_candidate += 1
            start_next_at = time.monotonic() + HAPPY_EYEBALLS_DELAY
            now = time.monotonic()

        waits = []
        if next_candidate < len(candidates):
            waits.append(max(0.0, start_next_at - time.monotonic()))
        if deadline is not None:
            waits.append(max(0.0, deadline - time.monotonic()))
        pending = selector.get_map()
        if not pending and not waits:
            break
        if not pending:
            time.sleep(min(waits))
            continue

        for key, _events in selector.select(min(waits) if waits else None):
            sock = key.fileobj
            error = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
            if error == 0:
                winner = finish(sock, True)
                close_pending()
                return winner
            last_error = OSError(error, os.strerror(error))
            finish(sock, False)

    close_pending()
    if deadline is not None and time.monotonic() >= deadline:
        raise socket.timeout(f"timed out connecting to {host}:{port}")
    if last_error is not None:
        raise last_error
    raise OSError(f"could not connect to {host}:{port}")


#race IPv4/IPv6 candidates for every connection requests/urllib3 makes
urllib3_connection.create_connection = happy_eyeballs_create_connection


DEFAULTS = {
    "api_url": "https://openrouter.ai/api/v1/chat/completions",
    "model": "google/gemini-2.5-flash",  # supports audio input
    "api_key_file": "/run/secrets/keys/openrouter",
    "prompt": "Transcribe this audio to plain text. Output only the transcription.",
    "pipe_command": None,
    "save_directory": None,
    "save_limit": "0",
}

#file name extensions of the archived recording (.wav) and its transcription (.txt)
AUDIO_EXT = ".wav"
TEXT_EXT = ".txt"

# all keys accepted in the config file
CONFIG_KEYS = set(DEFAULTS)

# env var -> config key it overrides
ENV_OVERRIDES = {
    "OPENROUTER_API_URL": "api_url",
    "OPENROUTER_MODEL": "model",
    "OPENROUTER_API_KEY_FILE": "api_key_file",
    "VOICE_INPUT_SAVE_DIRECTORY": "save_directory",
    "VOICE_INPUT_SAVE_LIMIT": "save_limit",
}

# command line option -> config key it overrides
CLI_OPTIONS = {
    "--api-url": "api_url",
    "--model": "model",
    "--api-key-file": "api_key_file",
    "--prompt": "prompt",
    "--pipe-command": "pipe_command",
    "--save-directory": "save_directory",
    "--save-limit": "save_limit",
}


def load_key(api_key_file: str) -> str:
    key = os.environ.get("OPENROUTER_API_KEY")
    if key:
        return key.strip()
    with open(api_key_file) as f:
        return f.read().strip()


def detect_format(data: bytes, path: str) -> str:
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if data[:3] == b"ID3" or (len(data) > 1 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0):
        return "mp3"
    ext = os.path.splitext(path)[1].lstrip(".").lower()
    if ext in {"wav", "mp3", "ogg", "flac", "aac", "opus", "webm", "m4a"}:
        return ext if ext != "m4a" else "aac"
    raise ValueError(f"Cannot determine audio format for {path!r}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="transcribe.py",
        description="Transcribe an audio file or stream via OpenRouter.",
    )
    parser.add_argument(
        "audio",
        nargs="?",
        help="path to the audio file, or '-' to read raw audio from stdin",
    )
    parser.add_argument(
        "--config",
        metavar="FILE",
        help="configuration file to use (overrides $VOICE_INPUT_CONFIG and the"
        " default search path)",
    )
    for option, key in CLI_OPTIONS.items():
        parser.add_argument(
            option,
            metavar="VALUE",
            help=f"override the '{key}' configuration parameter",
        )
    return parser.parse_args(argv)


def config_path(explicit: str | None = None) -> str | None:
    """Return the path of the config file to use, or None if there is none."""
    if explicit:
        if not os.path.isfile(explicit):
            sys.exit(f"voice-input: config file not found: {explicit}")
        return explicit
    explicit = os.environ.get("VOICE_INPUT_CONFIG")
    if explicit:
        if not os.path.isfile(explicit):
            sys.exit(f"voice-input: config file not found: {explicit}")
        return explicit
    xdg = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    path = os.path.join(xdg, "voice-input", "config")
    return path if os.path.isfile(path) else None


def load_config(path: str | None) -> dict:
    """Parse the config file and return the configuration (defaults merged in)."""
    config = dict(DEFAULTS)
    if path is None:
        return config
    seen: set[str] = set()
    with open(path) as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                sys.exit(f"voice-input: malformed line {lineno} in {path} (expected 'key = value'): {line!r}")
            key, _, value = line.partition("=")
            key, value = key.strip().lower(), value.strip()
            if key not in CONFIG_KEYS:
                sys.exit(f"voice-input: unknown config key {key!r} in {path} (line {lineno})")
            if key in seen:
                sys.exit(f"voice-input: duplicate {key!r} in {path} (line {lineno})")
            if not value:
                sys.exit(f"voice-input: {key!r} has an empty value in {path} (line {lineno})")
            seen.add(key)
            config[key] = value
    return config


def pipe_through(text: str, command: str) -> str:
    """Pipe text through a shell command (text on stdin, output from stdout)."""
    proc = subprocess.run(
        command,
        shell=True,
        input=text,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.strip()
        raise RuntimeError(
            f"pipe command {command!r} failed with exit code {proc.returncode}"
            + (f": {stderr[:500]}" if stderr else "")
        )
    return proc.stdout


def parse_save_limit(value: str) -> int:
    """Validate and convert the 'save_limit' value (non-negative integer)."""
    try:
        limit = int(value)
    except ValueError:
        sys.exit(f"voice-input: 'save_limit' must be a non-negative integer, got {value!r}")
    if limit < 0:
        sys.exit(f"voice-input: 'save_limit' must be a non-negative integer, got {value!r}")
    return limit


def prune_recordings(directory: str, limit: int) -> None:
    """Keep only the `limit' most recent recordings (and their transcriptions)."""
    try:
        stamps: dict[str, int] = {}
        for name in os.listdir(directory):
            stem, ext = os.path.splitext(name)
            if ext == AUDIO_EXT:
                stamps[stem] = os.stat(os.path.join(directory, name)).st_mtime_ns
        if len(stamps) <= limit:
            return
        keep = sorted(stamps, key=stamps.get, reverse=True)[:limit]
        for stem in sorted(set(stamps) - set(keep)):
            for ext in (AUDIO_EXT, TEXT_EXT):
                path = os.path.join(directory, stem + ext)
                if os.path.exists(path):
                    os.remove(path)
    except OSError as e:
        sys.exit(f"voice-input: cannot prune recordings in {directory!r}: {e}")


def save_recording(audio: bytes, text: str, directory: str, started: float, limit: int) -> None:
    """Archive the recording and its transcription in `directory'.

    The files are named after the moment the recording began (`started').
    The directory is created if needed; any error here is fatal.
    """
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError as e:
        sys.exit(f"voice-input: cannot create save directory {directory!r}: {e}")
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(started))
    base = os.path.join(directory, stamp)
    n = 1
    while os.path.exists(base + AUDIO_EXT) or os.path.exists(base + TEXT_EXT):
        base = os.path.join(directory, f"{stamp}-{n}")
        n += 1
    try:
        with open(base + AUDIO_EXT, "wb") as f:
            f.write(audio)
        with open(base + TEXT_EXT, "w") as f:
            f.write(text)
    except OSError as e:
        sys.exit(f"voice-input: cannot save recording in {directory!r}: {e}")
    prune_recordings(directory, limit)


def transcribe(audio: bytes, fmt: str, key: str, model: str, api_url: str, prompt: str) -> str:
    payload = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "input_audio",
                        "input_audio": {
                            "data": base64.b64encode(audio).decode(),
                            "format": fmt,
                        },
                    },
                ],
            }
        ],
    }
    resp = requests.post(
        api_url,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
    )
    if resp.status_code != 200:
        sys.exit(f"OpenRouter API error {resp.status_code}: {resp.text[:2000]}")
    result = resp.json()
    if "error" in result:
        sys.exit(f"OpenRouter error: {json.dumps(result['error'])[:2000]}")
    return result["choices"][0]["message"]["content"]


def main() -> None:
    args = parse_args(sys.argv[1:])
    if args.audio is None:
        sys.exit("transcribe.py: no audio file given (usage: transcribe.py <file> | -)"
                 " [--config FILE] [--api-url URL] [--model ID] [--api-key-file FILE]"
                 " [--prompt TEXT] [--pipe-command CMD] [--save-directory DIR] [--save-limit N]")
    path = args.audio

    #parse the config first so config errors fail fast, before reading/transcribing
    config = load_config(config_path(args.config))

    #environment variables override the config file (see docstring for precedence)
    for env_var, key in ENV_OVERRIDES.items():
        if os.environ.get(env_var):
            config[key] = os.environ[env_var]

    #command line options have the highest precedence (see docstring)
    for option, key in CLI_OPTIONS.items():
        value = getattr(args, option[2:].replace("-", "_"))
        if value is not None:
            config[key] = value

    if path == "-":
        audio = sys.stdin.buffer.read()
        fmt = detect_format(audio, "stream")
        #recording start time unknown for a stream: use the current moment
        started = time.time()
    else:
        with open(path, "rb") as f:
            audio = f.read()
        fmt = detect_format(audio, path)
        #best available approximation of when the recording began: the file's
        #modification time (when its recording was finalized)
        try:
            started = os.stat(path).st_mtime
        except OSError as e:
            sys.exit(f"voice-input: cannot stat {path!r}: {e}")

    #'save_limit' must be validated even when 'save_directory' is unset
    save_limit = parse_save_limit(config["save_limit"])

    key = load_key(config["api_key_file"])
    text = transcribe(
        audio,
        fmt,
        key,
        config["model"],
        config["api_url"],
        config["prompt"],
    )

    #optionally pipe the transcription through a command from the config file
    #before it is printed (and later inputted/typed at the cursor)
    command = config["pipe_command"]
    if command:
        try:
            text = pipe_through(text, command)
        except RuntimeError as e:
            sys.exit(f"voice-input: {e}")

    #optionally archive the recording and its transcription (save_limit == 0
    #disables the archive); errors here are fatal and abort the program
    save_directory = config["save_directory"]
    if save_directory and save_limit > 0:
        save_recording(audio, text, save_directory, started, save_limit)

    print(text)


if __name__ == "__main__":
    main()
