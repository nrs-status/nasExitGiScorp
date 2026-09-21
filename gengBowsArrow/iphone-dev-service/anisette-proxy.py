#!/usr/bin/env python3
"""anisette-proxy.py — rewrite the anisette server's client-info.

Apple's edge returns HTTP 503 for any request whose `X-Mme-Client-Info`
contains `com.apple.dt.Xcode/...`.  Anisette servers (public and Dadoum's)
return exactly such a value, so AltServer's authentication is 503'd before it
can even reach the SRP endpoint.

This proxy sits in front of the anisette server and rewrites the JSON
`X-MMe-Client-Info` field to a value without the Xcode parenthetical.  It
forwards every method/path unchanged, so it is compatible with both the v2
(`GET /`) and v3 (`POST /v3/get_headers`) anisette protocols.

Environment:
    IPHONE_DEV_ANISETTE_PROXY_PORT  listen port        (default 6969)
    IPHONE_DEV_ANISETTE_UPSTREAM    upstream base URL  (default http://127.0.0.1:6970)
    IPHONE_DEV_CLIENT_INFO          replacement client-info
    IPHONE_DEV_LOG_DIR              log directory      (default /tmp)
"""

import json
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("IPHONE_DEV_ANISETTE_PROXY_PORT", "6969"))
UPSTREAM = os.environ.get("IPHONE_DEV_ANISETTE_UPSTREAM", "http://127.0.0.1:6970")
CLIENT_INFO = os.environ.get(
    "IPHONE_DEV_CLIENT_INFO",
    "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1>",
)
LOG_DIR = os.environ.get("IPHONE_DEV_LOG_DIR", "/tmp")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _serve(self) -> None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None

        url = UPSTREAM.rstrip("/") + self.path
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, value in self.headers.items():
            if key.lower() in ("host", "content-length", "connection"):
                continue
            req.add_header(key, value)

        try:
            with urllib.request.urlopen(req, timeout=25) as resp:
                raw = resp.read()
                status = resp.status
                ctype = resp.headers.get("Content-Type", "application/json")
        except Exception as exc:
            raw = json.dumps({"error": str(exc)}).encode()
            status = 502
            ctype = "application/json"

        # Rewrite the client-info in JSON payloads (best effort).
        try:
            payload = json.loads(raw)
            if isinstance(payload, dict) and "X-MMe-Client-Info" in payload:
                payload["X-MMe-Client-Info"] = CLIENT_INFO
                raw = json.dumps(payload).encode()
        except Exception:
            pass

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    do_GET = _serve
    do_POST = _serve
    do_PUT = _serve

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"anisette-proxy :{PORT} -> {UPSTREAM}", flush=True)
    server.serve_forever()
