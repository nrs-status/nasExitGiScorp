#!/usr/bin/env python3
"""sideload.py — run AltServer to sign + install an IPA, handling 2FA.

This is the generic driver behind `iphone-dev-service sideload`.  It starts the
patched AltServer with its stdin connected to a pipe, watches the output for
the "Enter two factor code" prompt, notifies the desktop (notify-send) and
feeds in the code written to --code-file.  When zero prompt appears (the
anisette machine is already trusted) it simply runs to completion.

Usage:
    sideload.py --altserver PATH --ipa PATH --udid UDID \
                --apple-id ID --password PW \
                [--code-file PATH] [--log PATH] [--timeout SECONDS] [--no-notify]

Exit status is AltServer's, so 0 means the install succeeded.
"""

import argparse
import os
import subprocess
import sys
import time

TWO_FACTOR_MARKERS = ("enter two factor code", "two factor code", "two-factor")


def notify(title: str, body: str) -> None:
    try:
        subprocess.run(["notify-send", "-u", "critical", "-t", "0", title, body])
    except Exception:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--altserver", required=True)
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--apple-id", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--code-file", default=os.path.join(os.getcwd(), "2fa.txt"))
    parser.add_argument("--log", default="/tmp/iphone-dev-service-sideload.log")
    parser.add_argument("--timeout", type=int, default=900,
                        help="give up waiting for a 2FA code after this many seconds")
    parser.add_argument("--no-notify", action="store_true")
    args = parser.parse_args()

    if os.path.exists(args.code_file):
        os.remove(args.code_file)

    logf = open(args.log, "w")
    proc = subprocess.Popen(
        [
            args.altserver,
            "-u", args.udid,
            "-a", args.apple_id,
            "-p", args.password,
            args.ipa,
        ],
        stdin=subprocess.PIPE,
        stdout=logf,
        stderr=subprocess.STDOUT,
    )

    notified = False
    sent = False
    keypresses = 0
    started = time.time()

    def read_log() -> str:
        try:
            return open(args.log, errors="replace").read()
        except Exception:
            return ""

    while proc.poll() is None:
        text = read_log()
        lower = text.lower()
        if not notified and any(m in lower for m in TWO_FACTOR_MARKERS):
            if not args.no_notify:
                notify(
                    "iPhone sideload: 2FA required",
                    f"Apple 2FA code needed to sign/install the app. Write it to "
                    f"{args.code_file}",
                )
            notified = True
        if not sent and os.path.exists(args.code_file):
            code = open(args.code_file, errors="replace").read().strip()
            if code:
                try:
                    proc.stdin.write((code + "\n").encode())
                    proc.stdin.flush()
                except Exception:
                    pass
                sent = True
        # AltServer blocks on "Press any key to continue..." after an alert;
        # send a newline for every such prompt so the process can exit.
        prompts = lower.count("press any key")
        while keypresses < prompts:
            try:
                proc.stdin.write(b"\n")
                proc.stdin.flush()
            except Exception:
                pass
            keypresses += 1
        if notified and not sent and time.time() - started > args.timeout:
            proc.terminate()
            break
        time.sleep(2)

    proc.wait()
    logf.close()
    with open(args.log, "a") as f:
        f.write(f"\n=== sideload.py: AltServer exited rc={proc.returncode} "
                f"sent_code={sent} ===\n")
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
