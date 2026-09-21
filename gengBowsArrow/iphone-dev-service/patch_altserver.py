#!/usr/bin/env python3
"""patch_altserver.py — redirect AltServer's Apple base URLs to local proxies.

The static AltServer binary cannot speak TLS to Apple from this host, so its
two hard-coded Apple base URLs are rewritten (in place, same length or shorter
and NUL-terminated) to point at the local `gsa-proxy` instances.

Usage:
    patch_altserver.py INPUT OUTPUT
Environment:
    IPHONE_DEV_GSA_PORT          default 4443
    IPHONE_DEV_DEVSERVICES_PORT  default 4444
"""

import os
import sys

GSA_PORT = os.environ.get("IPHONE_DEV_GSA_PORT", "4443")
DEV_PORT = os.environ.get("IPHONE_DEV_DEVSERVICES_PORT", "4444")

REPLACEMENTS = [
    (b"https://gsa.apple.com",
     f"http://127.0.0.1:{GSA_PORT}".encode()),
    (b"https://developerservices2.apple.com/services/v1",
     f"http://127.0.0.1:{DEV_PORT}/services/v1".encode()),
    (b"https://developerservices2.apple.com/services/QH65B2",
     f"http://127.0.0.1:{DEV_PORT}/services/QH65B2".encode()),
]


def patch_all(data: bytes, needle: bytes, replacement: bytes) -> tuple[bytes, int]:
    if len(replacement) < len(needle):
        replacement = replacement + b"\x00"
    if len(replacement) > len(needle):
        raise ValueError(
            f"replacement too long for {needle!r}: {replacement!r}"
        )
    offsets = []
    start = 0
    while True:
        idx = data.find(needle, start)
        if idx < 0:
            break
        offsets.append(idx)
        start = idx + 1
    for idx in offsets:
        data = data[:idx] + replacement + data[idx + len(replacement):]
    return data, len(offsets)


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    for needle, replacement in REPLACEMENTS:
        data, count = patch_all(data, needle, replacement)
        print(f"patched {count}x {needle.decode()}", file=sys.stderr)
    with open(dst, "wb") as f:
        f.write(data)
    os.chmod(dst, 0o755)
    return 0


if __name__ == "__main__":
    sys.exit(main())
