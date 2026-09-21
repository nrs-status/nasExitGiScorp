#!/usr/bin/env python3
"""gsa-proxy.py — local plain-HTTP -> HTTPS reverse proxy for Apple's servers.

AltServer is shipped as a static musl binary whose TLS stack cannot complete a
handshake with Apple's servers from a NixOS host, and Apple's edge returns HTTP
429 when the SRP `o=complete` request reuses the TLS connection of `o=init`.
This proxy therefore:

  * accepts plain HTTP from AltServer (whose base URLs are patched to
    http://127.0.0.1:<port>), and
  * opens a *fresh* upstream TLS connection to the real Apple host for every
    single request.

With `--refresh-2fa` it additionally refreshes the anisette one-time-password
and modernises the client-info / Xcode headers for the 2FA endpoints, because
AltServer reuses the login OTP and Apple rejects that on 2FA.

Usage:
    gsa-proxy.py <port> <upstream-host> [--refresh-2fa]

Environment:
    IPHONE_DEV_LOG_DIR         directory for access logs (default /tmp)
    IPHONE_DEV_ANISETTE_PROXY  anisette proxy URL used for 2FA refresh
                               (default http://127.0.0.1:6969)
    IPHONE_DEV_XCODE_CLIENT_INFO  client-info to use for 2FA requests
"""

import gzip
import json
import os
import socket
import ssl
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if len(sys.argv) < 3:
    sys.exit(__doc__)

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2]
REFRESH = "--refresh-2fa" in sys.argv

LOG_DIR = os.environ.get("IPHONE_DEV_LOG_DIR", "/tmp")
ANISETTE_PROXY = os.environ.get("IPHONE_DEV_ANISETTE_PROXY", "http://127.0.0.1:6969")
XCODE_CLIENT_INFO = os.environ.get(
    "IPHONE_DEV_XCODE_CLIENT_INFO",
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>",
)
XCODE_VERSION = os.environ.get("IPHONE_DEV_XCODE_VERSION", "27.0 (27A5218g)")

LOG = os.path.join(LOG_DIR, f"gsa-{PORT}.log")
HDRLOG = os.path.join(LOG_DIR, f"gsa-{PORT}-headers.log")

_lock = threading.Lock()


def log(msg: bytes) -> None:
    with _lock:
        with open(LOG, "ab") as f:
            f.write(msg + b"\n")


def dechunk(data: bytes) -> bytes:
    out = b""
    while data:
        pos = data.find(b"\r\n")
        if pos < 0:
            break
        try:
            size = int(data[:pos].split(b";")[0], 16)
        except ValueError:
            return data
        if size == 0:
            break
        out += data[pos + 2:pos + 2 + size]
        data = data[pos + 2 + size + 2:]
    return out


def refresh_headers() -> dict:
    """Fetch fresh anisette headers from the anisette proxy, for 2FA."""
    try:
        fresh = json.loads(urllib.request.urlopen(ANISETTE_PROXY, timeout=20).read())
    except Exception as exc:  # pragma: no cover - best effort
        log(b"    anisette refresh failed: " + str(exc).encode())
        return {}
    return {
        "x-apple-i-md": fresh.get("X-Apple-I-MD"),
        "x-apple-i-md-lu": fresh.get("X-Apple-I-MD-LU"),
        "x-apple-i-md-m": fresh.get("X-Apple-I-MD-M"),
        "x-apple-i-md-rinfo": fresh.get("X-Apple-I-MD-RINFO"),
        "x-mme-device-id": fresh.get("X-Mme-Device-Id"),
        "x-mme-client-info": XCODE_CLIENT_INFO,
        "x-apple-i-client-time": fresh.get("X-Apple-I-Client-Time"),
        "x-apple-locale": fresh.get("X-Apple-Locale"),
        "x-apple-i-timezone": fresh.get("X-Apple-I-TimeZone"),
        "x-xcode-version": XCODE_VERSION,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self) -> None:
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""

        override = {}
        if REFRESH and (
            "trusteddevice" in self.path
            or self.path.startswith("/grandslam/GsService2/validate")
        ):
            override = refresh_headers()
            if override:
                log(b"    refreshed anisette for 2FA request")

        hdrs = []
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in (
                "host",
                "content-length",
                "connection",
                "accept-encoding",
                "proxy-connection",
                "te",
                "transfer-encoding",
            ):
                continue
            if lower in override and override[lower]:
                value = override[lower]
            hdrs.append((key, value))
        hdrs.append(("Host", UPSTREAM))
        hdrs.append(("Accept-Encoding", "identity"))
        if body or self.command.upper() in ("POST", "PUT", "PATCH"):
            hdrs.append(("Content-Length", str(len(body))))
        hdrs.append(("Connection", "close"))

        try:
            with open(HDRLOG, "a") as f:
                f.write(f"{self.command} {self.path} {hdrs!r}\n")
        except OSError:
            pass

        try:
            ctx = ssl._create_unverified_context()
            infos = socket.getaddrinfo(UPSTREAM, 443, socket.AF_INET, socket.SOCK_STREAM)
            ip = infos[0][4][0]
            raw = socket.create_connection((ip, 443), timeout=30)
            upstream = ctx.wrap_socket(raw, server_hostname=UPSTREAM)
            request = f"{self.command} {self.path} HTTP/1.1\r\n"
            request += "".join(f"{k}: {v}\r\n" for k, v in hdrs)
            request += "\r\n"
            upstream.sendall(request.encode("latin-1") + body)
            chunks = []
            while True:
                chunk = upstream.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            upstream.close()
            response = b"".join(chunks)
        except Exception as exc:
            log(b"=== UPSTREAM ERROR: " + str(exc).encode())
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        head, _, rbody = response.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        status_line = lines[0] if lines else b"HTTP/1.1 502 Bad Gateway"
        try:
            code = int(status_line.split()[1])
        except Exception:
            code = 502
        if any(
            line.lower().startswith(b"transfer-encoding") and b"chunked" in line.lower()
            for line in lines[1:]
        ):
            rbody = dechunk(rbody)
        if rbody[:2] == b"\x1f\x8b":
            try:
                rbody = gzip.decompress(rbody)
            except Exception:
                pass

        ctype = b"text/x-xml-plist"
        for line in lines[1:]:
            if line.lower().startswith(b"content-type:"):
                ctype = line.split(b":", 1)[1].strip()

        log(
            b"=== "
            + f"{self.command} {self.path}".encode()
            + b" -> "
            + status_line
            + b" bodylen="
            + str(len(rbody)).encode()
        )

        self.send_response(code)
        self.send_header("Content-Type", ctype.decode("latin-1"))
        self.send_header("Content-Length", str(len(rbody)))
        self.end_headers()
        self.wfile.write(rbody)

    do_POST = _proxy
    do_GET = _proxy
    do_PUT = _proxy
    do_PATCH = _proxy
    do_DELETE = _proxy

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"gsa-proxy :{PORT} -> https://{UPSTREAM} (refresh2fa={REFRESH})", flush=True)
    server.serve_forever()
