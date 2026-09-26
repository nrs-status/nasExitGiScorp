#!/usr/bin/env python3
"""
jev -- send a JSON request to OpenRouter's Jev model and print its JSON reply.

The program reads exactly one JSON object from stdin, sets its `model` field
to the configured Jev model, POSTs it to OpenRouter's decisions endpoint and
writes the JSON response body to stdout.

usage:
  jev [--api-key-file PATH] [--model MODEL] [--api-url URL]
  jev -h | --help

Configuration (highest precedence first):

  API key file -- the file the OpenRouter API key is read from (as a single
  line of text):
    1. --api-key-file PATH
    2. $OPENROUTER_API_KEY
    3. /run/secrets/keys/openrouter

  Jev model -- the model id put into the request's `model` field:
    1. --model MODEL
    2. $DEFAULT_JEV_MODEL
    3. ~typesafe/jev-latest

  Endpoint -- the OpenRouter endpoint the request is sent to:
    1. --api-url URL
    2. $JEV_API_URL
    3. https://openrouter.ai/api/alpha/decisions

Exit status is 0 when the endpoint answered with a 2xx status, 1 otherwise.
See ./SPEC.md for the behavioural specification.
"""

import argparse
import json
import os
import socket
import sys
import urllib.error
import urllib.request

# Some hosts blackhole IPv6.  Python's default address ordering can try an
# IPv6 address first and hang until the timeout; put IPv4 candidates ahead of
# IPv6 ones so a working IPv4 route is used immediately (IPv6 is still tried
# if no IPv4 address connects).
_getaddrinfo = socket.getaddrinfo


def _prefer_ipv4_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    results = _getaddrinfo(host, port, family, type, proto, flags)
    return sorted(results, key=lambda result: result[0] != socket.AF_INET)


socket.getaddrinfo = _prefer_ipv4_getaddrinfo

PROG = "jev"

API_KEY_ENV = "OPENROUTER_API_KEY"
MODEL_ENV = "DEFAULT_JEV_MODEL"
API_URL_ENV = "JEV_API_URL"

DEFAULT_API_KEY_FILE = "/run/secrets/keys/openrouter"
DEFAULT_MODEL = "~typesafe/jev-latest"
DEFAULT_API_URL = "https://openrouter.ai/api/alpha/decisions"

READ_TIMEOUT = 300  # seconds to wait for the Jev model to answer


def fail(message):
    """Print an error to stderr and exit with status 1."""
    print(f"{PROG}: error: {message}", file=sys.stderr)
    sys.exit(1)


def resolve(explicit, env_name, default):
    """Apply the CLI > environment variable > built-in default precedence."""
    if explicit:
        return explicit
    value = os.environ.get(env_name, "")
    if value:
        return value
    return default


def read_api_key(path):
    """Read the OpenRouter API key from `path` (single line, trailing space cut)."""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError as error:
        fail(f"cannot read API key file {path!r}: {error}")


def read_request():
    """Parse the single JSON object on stdin."""
    try:
        request = json.load(sys.stdin)
    except json.JSONDecodeError as error:
        fail(f"invalid JSON on stdin: {error}")
    if not isinstance(request, dict):
        fail("the JSON on stdin must be an object")
    return request


def send(api_url, api_key, request):
    """POST `request` to `api_url` and return (status, raw response body)."""
    body = json.dumps(request).encode("utf-8")
    http_request = urllib.request.Request(
        api_url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(http_request, timeout=READ_TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        fail(f"request to {api_url} failed: {error.reason}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Send the JSON object on stdin to OpenRouter's Jev model "
        "and print the JSON response to stdout.",
    )
    parser.add_argument(
        "--api-key-file",
        metavar="PATH",
        help="file containing the OpenRouter API key "
        f"(default: ${API_KEY_ENV} or {DEFAULT_API_KEY_FILE})",
    )
    parser.add_argument(
        "--model",
        metavar="MODEL",
        help="Jev model id to request "
        f"(default: ${MODEL_ENV} or {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--api-url",
        metavar="URL",
        help=f"OpenRouter endpoint to POST to (default: {DEFAULT_API_URL})",
    )
    args = parser.parse_args(argv)

    request = read_request()
    api_key_file = resolve(args.api_key_file, API_KEY_ENV, DEFAULT_API_KEY_FILE)
    model = resolve(args.model, MODEL_ENV, DEFAULT_MODEL)
    api_url = resolve(args.api_url, API_URL_ENV, DEFAULT_API_URL)
    api_key = read_api_key(api_key_file)

    # The model is owned by this program, never by the request body: the
    # resolved model always wins over whatever the input object contained.
    request["model"] = model

    status, payload = send(api_url, api_key, request)

    text = payload.decode("utf-8", "replace")
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")

    if not 200 <= status < 300:
        print(f"{PROG}: error: OpenRouter answered with HTTP {status}", file=sys.stderr)
        sys.exit(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
