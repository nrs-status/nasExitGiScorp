#!/usr/bin/env python3
"""End-to-end test for the OpenRouter provider pi extension.

Drives pi in RPC mode (`pi --mode rpc -e <extension>`) and checks:

  1. detection: after a prompt, the extension resolves the upstream provider
     and publishes it as an `openrouter-provider` setStatus UI request;
  2. routing pin: `/openrouter pin <slug>` injects `provider.only` into the
     next request payload (and the upstream generation confirms it);
  3. interactive picker: `/openrouter` opens a select dialog whose options
     come from the model's endpoints, and choosing one pins it;
  4. blacklist toggle: blacklisted providers are excluded from automatic
     selection via `provider.ignore` (exercised through the `block`/
     `unblock` subcommands, which the picker's shift+enter toggle funnels
     into), and are marked with `✗` in the picker.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.normpath(os.path.join(HERE, "..", "openrouter-provider.ts"))
KEY_FILE = "/run/secrets/keys/openrouter"


class PiRpc:
    def __init__(self, log_path: str):
        self.log_path = log_path
        self.proc = subprocess.Popen(
            ["pi", "--mode", "rpc", "--no-extensions", "-e", EXTENSION, "--no-session"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            # Hermetic: a globally exported routing config must not leak into
            # the test scenarios (it would change what is injected and what
            # the footer status shows).
            env={
                **{
                    k: v
                    for k, v in os.environ.items()
                    if k != "PI_OPENROUTER_EXTENSION_CONFIG_FILE"
                },
                "PI_OPENROUTER_PROVIDER_LOG": log_path,
            },
        )
        self.events: list[dict] = []
        self._lock = threading.Lock()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                event = {"type": "raw", "line": line}
            with self._lock:
                self.events.append(event)

    def send(self, payload: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout: float, description: str):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for event in self.events:
                    if predicate(event):
                        return event
            time.sleep(0.1)
        raise TimeoutError(f"timed out waiting for {description}; events={self.describe()}")

    def describe(self) -> str:
        with self._lock:
            return json.dumps(self.events[-20:], indent=1)

    def close(self) -> None:
        try:
            self.send({"type": "abort"})
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def read_log(path: str) -> str:
    try:
        with open(path) as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def status_events(pi_rpc: PiRpc) -> list[str]:
    with pi_rpc._lock:
        return [
            e.get("statusText", "")
            for e in pi_rpc.events
            if e.get("method") == "setStatus" and e.get("statusKey") == "openrouter-provider"
        ]


def wait_for_provider_status(pi_rpc: PiRpc, timeout: float) -> str:
    """Wait for a status that names the *upstream provider*, not just the pin."""

    def is_provider_status(event: dict) -> bool:
        if event.get("method") != "setStatus" or event.get("statusKey") != "openrouter-provider":
            return False
        text = event.get("statusText") or ""
        if not text.startswith("⇢ ") or "loading" in text:
            return False
        first = text[len("⇢ ") :].split(" · ")[0]
        return bool(first) and not first.startswith("pin:")

    event = pi_rpc.wait_for(is_provider_status, timeout, "provider status")
    return event["statusText"]


def wait_for_agent_end(pi_rpc: PiRpc, timeout: float) -> None:
    pi_rpc.wait_for(lambda e: e.get("type") in ("agent_end", "agent_settled"), timeout, "agent end")


def query_generation(generation_id: str) -> str | None:
    key = open(KEY_FILE).read().strip()
    url = f"https://openrouter.ai/api/v1/generation?id={generation_id}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    # The record is written asynchronously; retry briefly.
    for _ in range(10):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = json.load(response)
            name = data.get("data", {}).get("provider_name")
            if name:
                return name
        except Exception:
            pass
        time.sleep(1)
    return None


def extract_generation_id(log_text: str) -> str | None:
    for line in reversed(log_text.splitlines()):
        if "generationId=" in line:
            tail = line.split("generationId=", 1)[1].split()[0]
            if tail:
                return tail
    return None


def fetch_model_endpoints(model_id: str) -> list[dict]:
    """Providers serving `model_id`, deduped by slug, best uptime first.

    Mirrors the extension's dedup: per slug the cheapest endpoint wins
    (ties broken on uptime), so the returned price/quantization are those of
    the endpoint the extension would display.
    """
    url = f"https://openrouter.ai/api/v1/models/{model_id}/endpoints"
    with urllib.request.urlopen(url, timeout=30) as response:
        data = json.load(response)

    def prompt_price(endpoint: dict) -> float:
        try:
            return float(endpoint.get("pricing", {}).get("prompt"))
        except (TypeError, ValueError):
            return float("inf")

    best: dict[str, dict] = {}
    for endpoint in data.get("data", {}).get("endpoints", []):
        if endpoint.get("status", 0) < 0:
            continue
        tag = endpoint.get("tag") or ""
        slug = (tag.split("/")[0] or endpoint.get("provider_name") or "").lower()
        if not slug:
            continue
        entry = {
            "slug": slug,
            "name": endpoint.get("provider_name") or slug,
            "uptime": endpoint.get("uptime_last_30m") or 0.0,
            "prompt_price": prompt_price(endpoint),
            "quantization": (endpoint.get("quantization") or "").strip().lower(),
        }
        previous = best.get(slug)
        if previous is None or (entry["prompt_price"], -entry["uptime"]) < (
            previous["prompt_price"],
            -previous["uptime"],
        ):
            best[slug] = entry
    return sorted(best.values(), key=lambda entry: -entry["uptime"])


def pin_and_prompt(candidate: dict, log_path: str) -> tuple[bool, str]:
    """Try to pin `candidate` and run a prompt. Returns (ok, status/diagnostic)."""
    try:
        os.unlink(log_path)
    except FileNotFoundError:
        pass
    rpc = PiRpc(log_path)
    slug = candidate["slug"]
    try:
        rpc.send({"type": "prompt", "message": f"/openrouter pin {slug}"})
        rpc.wait_for(
            lambda e: e.get("method") == "notify" and slug in (e.get("message") or ""),
            30,
            "pin notification",
        )
        rpc.send({"type": "prompt", "message": "Reply with exactly: ok"})
        wait_for_agent_end(rpc, 150)
        status = wait_for_provider_status(rpc, 25)
        if f"pin:{slug}" not in status:
            return False, f"status missing pin: {status!r}"
        return True, status
    finally:
        rpc.close()


def flattened_log(text: str) -> str:
    return text.replace(" ", "")


def main() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        print(("PASS " if condition else "FAIL ") + message)
        if not condition:
            failures.append(message)

    model_id = "z-ai/glm-5.3-flash"
    candidates = fetch_model_endpoints(model_id)[:4]
    check(len(candidates) > 1, f"discovered {len(candidates)} candidate providers for {model_id}")

    # ---- Test 1 + 2: detection and pinning via command -------------------
    # Providers can be transiently rate-limited upstream, so try candidates in
    # order of uptime until one serves the request.
    log_path = "/tmp/pi-openrouter-provider-test.log"
    pinned = None
    status = None
    for candidate in candidates:
        print(f"... trying provider {candidate['slug']!r} ({candidate['name']})")
        try:
            ok, detail = pin_and_prompt(candidate, log_path)
        except TimeoutError as error:
            ok, detail = False, f"timed out: {error}"
        if ok:
            pinned, status = candidate, detail
            break
        print(f"    unusable ({detail.splitlines()[0][:120]})")

    check(pinned is not None, f"pinned provider served a request: {pinned and pinned['name']!r}")
    if pinned is not None and status is not None:
        slug = pinned["slug"]
        detected = status[len("⇢ ") :].split(" · ")[0]
        check(bool(detected) and not detected.startswith("pin:"), f"detection status shows upstream provider: {status!r}")
        check(f"pin:{slug}" in status, f"detection status shows the pin: {status!r}")

        log_text = read_log(log_path)
        flattened = log_text.replace(" ", "")
        check(f'"only":["{slug}"]' in flattened, f"request payload pins {slug}")
        check('"allow_fallbacks":false' in flattened, "request payload disables fallbacks")

        generation_id = extract_generation_id(log_text)
        check(generation_id is not None, f"captured generation id: {generation_id}")
        if generation_id:
            provider = query_generation(generation_id)
            # Pinned generations are not always queryable; only assert on a hit.
            if provider is None:
                print("SKIP generation lookup returned no record for a pinned request")
            else:
                check(
                    provider.lower() == pinned["name"].lower(),
                    f"OpenRouter generation confirms upstream provider: {provider!r}",
                )

    # ---- Test 3: interactive picker -------------------------------------
    log_path2 = "/tmp/pi-openrouter-provider-picker.log"
    try:
        os.unlink(log_path2)
    except FileNotFoundError:
        pass
    rpc2 = PiRpc(log_path2)
    try:
        rpc2.send({"type": "prompt", "message": "/openrouter"})
        select = rpc2.wait_for(
            lambda e: e.get("method") == "select" and e.get("title") == "OpenRouter upstream provider",
            60,
            "provider select dialog",
        )
        options = select.get("options", [])
        target_slug = candidates[0]["slug"] if candidates else None
        choice = next((o for o in options if target_slug and f"({target_slug})" in o), None)
        check(choice is not None, f"picker lists a {target_slug!r} option among {len(options)} entries")
        check(len(options) > 1, f"picker lists multiple providers ({len(options)})")
        # Every picker option whose slug has a known quantization must show it.
        quantized = 0
        for candidate in candidates:
            quant = candidate.get("quantization") or ""
            if not quant or quant == "unknown":
                continue
            option = next((o for o in options if f"({candidate['slug']})" in o), None)
            if option is None:
                continue
            quantized += 1
            check(f"[{quant}]" in option, f"picker option for {candidate['slug']} shows precision {quant!r}: {option!r}")
        if quantized == 0:
            print("SKIP no candidate endpoint reports a known quantization")
        if choice is not None:
            rpc2.send({"type": "extension_ui_response", "id": select["id"], "value": choice})
            notify = rpc2.wait_for(
                lambda e: e.get("method") == "notify" and target_slug in (e.get("message") or ""),
                30,
                "picker selection notification",
            )
            check(True, f"picker selection applied: {notify.get('message')!r}")
    finally:
        rpc2.close()

    # ---- Test 4: blacklist toggle (shift+enter) behaviour ----------------
    # The shift+enter toggle lives in the TUI picker; through RPC we exercise
    # the same blacklist machinery via the `block`/`unblock` subcommands
    # (which the picker's toggle path funnels into) and verify that automatic
    # selection mode excludes blacklisted providers via `provider.ignore`.
    if candidates:
        blocked_slug = candidates[1]["slug"] if len(candidates) > 1 else candidates[0]["slug"]
        log_path3 = "/tmp/pi-openrouter-provider-blacklist.log"
        try:
            os.unlink(log_path3)
        except FileNotFoundError:
            pass
        rpc3 = PiRpc(log_path3)
        try:
            rpc3.send({"type": "prompt", "message": f"/openrouter block {blocked_slug}"})
            rpc3.wait_for(
                lambda e: e.get("method") == "notify" and "blacklisted" in (e.get("message") or ""),
                30,
                "block notification",
            )
            rpc3.send({"type": "prompt", "message": "Reply with exactly: ok"})
            wait_for_agent_end(rpc3, 150)
            flat = read_log(log_path3).replace(" ", "")
            check(
                f'"ignore":["{blocked_slug}"]' in flat,
                f"auto-mode request excludes blacklisted provider {blocked_slug!r}",
            )
            check(
                '"allow_fallbacks":true' in flat,
                "auto-mode request keeps fallbacks allowed while blacklisting",
            )
            # The picker (RPC fallback select) must mark the blacklisted item.
            rpc3.send({"type": "prompt", "message": "/openrouter"})
            select = rpc3.wait_for(
                lambda e: e.get("method") == "select" and e.get("title") == "OpenRouter upstream provider",
                60,
                "picker after block",
            )
            marked = next((o for o in select.get("options", []) if f"({blocked_slug})" in o and "✗" in o), None)
            check(marked is not None, f"picker marks blacklisted provider with ✗: {select.get('options')}")
            rpc3.send({"type": "extension_ui_response", "id": select["id"], "cancelled": True})
            # Un-blacklist again; the next auto request must not ignore anyone.
            rpc3.send({"type": "prompt", "message": f"/openrouter unblock {blocked_slug}"})
            rpc3.wait_for(
                lambda e: e.get("method") == "notify" and "un-blacklisted" in (e.get("message") or ""),
                30,
                "unblock notification",
            )
            rpc3.send({"type": "prompt", "message": "Reply with exactly: ok"})
            wait_for_agent_end(rpc3, 150)
            flat2 = read_log(log_path3).replace(" ", "")
            check(flat2.count('"ignore":[') == 1, "after unblocking, requests no longer exclude the provider")
        finally:
            rpc3.close()

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())