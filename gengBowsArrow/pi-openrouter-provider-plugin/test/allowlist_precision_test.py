#!/usr/bin/env python3
"""End-to-end test for the allowlist and precision-filtering features of the
OpenRouter provider pi extension (SPEC.md section 5.1).

Drives pi in RPC mode with PI_OPENROUTER_EXTENSION_CONFIG_FILE pointing at a
TOML file and checks, via the extension's debug log, what is injected into
the outgoing request payload:

  1. allowlist → `provider.only` (only the listed providers may serve);
  2. precision_allowlist → `provider.quantizations` verbatim;
  3. precision_blacklist → `provider.quantizations` as the complement within
     the known quantization set;
  4. precision_preferred → quantization-qualified endpoint tags (resolved
     from the model's endpoints data) prepended to `provider.order`;
  5. precision_allowlist wins when both precision filters are configured;
  6. model-scope tables override the new keys per key and inherit the ones
     they omit from [global];
  7. a precision_preferred entry no endpoint serves is skipped (and with no
     other routing configured, nothing is injected at all);
  8. the footer status and `/openrouter config` report the new settings.

The slugs/precisions used in `only`/`quantizations` are real values for the
test model (fetched from the endpoints API) so the requests still succeed;
unreachable ones would make OpenRouter reject the routing.
"""

from __future__ import annotations

import os
import subprocess
import sys
import threading
import urllib.request
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rpc_test import read_log, wait_for_agent_end  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.normpath(os.path.join(HERE, "..", "openrouter-provider.ts"))
MODEL_ID = "z-ai/glm-5.3-flash"
CONFIG_PATH = "/tmp/pi-openrouter-allowlist-test.toml"
# Must mirror KNOWN_QUANTIZATIONS in openrouter-provider.ts.
KNOWN_QUANTIZATIONS = ["int4", "int8", "fp4", "fp6", "fp8", "fp16", "bf16", "fp32", "unknown"]


def fetch_raw_endpoints(model_id: str) -> list[dict]:
    """Raw endpoint records of `model_id` from the OpenRouter API."""
    url = f"https://openrouter.ai/api/v1/models/{model_id}/endpoints"
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.load(response).get("data", {}).get("endpoints", [])


def cheapest_endpoint_per_quant(raw_endpoints: list[dict]) -> list[dict]:
    """Mirror of the extension's endpoint view: per provider slug the cheapest
    endpoint wins (ties on uptime), sorted by prompt price ascending."""
    def price(endpoint: dict) -> float:
        try:
            return float(endpoint.get("pricing", {}).get("prompt"))
        except (TypeError, ValueError):
            return float("inf")

    best: dict[str, dict] = {}
    for endpoint in raw_endpoints:
        if endpoint.get("status", 0) < 0:
            continue
        tag = endpoint.get("tag") or ""
        slug = (tag.split("/")[0] or endpoint.get("provider_name") or "").lower()
        if not slug:
            continue
        entry = {
            "slug": slug,
            "tag": tag,
            "prompt_price": price(endpoint),
            "uptime": endpoint.get("uptime_last_30m") or 0.0,
            "quantization": (endpoint.get("quantization") or "unknown").strip().lower(),
        }
        previous = best.get(slug)
        if previous is None or (entry["prompt_price"], -entry["uptime"]) < (
            previous["prompt_price"],
            -previous["uptime"],
        ):
            best[slug] = entry
    return sorted(best.values(), key=lambda entry: entry["prompt_price"])


class AllowlistRpc:
    """A pi RPC process with a custom environment, mirroring config_test."""

    def __init__(self, log_path: str, config_path: str | None):
        env = {
            **{
                k: v
                for k, v in os.environ.items()
                if k != "PI_OPENROUTER_EXTENSION_CONFIG_FILE"
            },
            "PI_OPENROUTER_PROVIDER_LOG": log_path,
        }
        if config_path is not None:
            env["PI_OPENROUTER_EXTENSION_CONFIG_FILE"] = config_path
        self.log_path = log_path
        self.proc = subprocess.Popen(
            ["pi", "--mode", "rpc", "--no-extensions", "-e", EXTENSION, "--no-session",
             "--model", "openrouter/" + MODEL_ID],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
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
                continue
            with self._lock:
                self.events.append(event)

    def send(self, payload: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def wait_for(self, predicate, timeout: float, description: str):
        import time

        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for event in self.events:
                    if predicate(event):
                        return event
            time.sleep(0.1)
        raise TimeoutError(f"timed out waiting for {description}")

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


def run_scenario(name: str, config_text: str | None, prompts: list[str]) -> tuple[str, list[dict]]:
    """Start pi, run `prompts`, return (debug log, all RPC events)."""
    log_path = f"/tmp/pi-openrouter-allowlist-test-{name}.log"
    try:
        os.unlink(log_path)
    except FileNotFoundError:
        pass
    if config_text is not None:
        with open(CONFIG_PATH, "w") as handle:
            handle.write(config_text)
    rpc = AllowlistRpc(log_path, CONFIG_PATH if config_text is not None else None)
    try:
        for prompt in prompts:
            rpc.send({"type": "prompt", "message": prompt})
            if prompt.startswith("/"):
                rpc.wait_for(
                    lambda e: e.get("type") == "response" and e.get("command") == "prompt",
                    60,
                    f"command {prompt!r} handled",
                )
            else:
                wait_for_agent_end(rpc, 150)
        return read_log(log_path), rpc.events
    finally:
        rpc.close()


def injections(log_text: str) -> list[str]:
    return [line for line in log_text.splitlines() if "injecting" in line]


def flat(log_text: str) -> str:
    return "".join(injections(log_text)).replace(" ", "")


def main() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        print(("PASS " if condition else "FAIL ") + message)
        if not condition:
            failures.append(message)

    raw = fetch_raw_endpoints(MODEL_ID)
    endpoints = cheapest_endpoint_per_quant(raw)
    slugs = [e["slug"] for e in endpoints]
    quants_present = sorted({e["quantization"] for e in endpoints})
    check(len(slugs) >= 2, f"discovered {len(slugs)} candidate providers for {MODEL_ID}")
    check(len(quants_present) >= 1, f"endpoints report precisions {quants_present}")
    s0, s1 = slugs[0], slugs[1]
    prompt = "Reply with exactly: ok"

    # ---- Scenario 1: allowlist → provider.only ----------------------------
    log1, _ = run_scenario("allowlist", f'[global]\nallowlist = ["{s0}", "{s1}"]\n', [prompt])
    flat1 = flat(log1)
    check(f'"only":["{s0}","{s1}"]' in flat1, f"allowlist injected as provider.only: {injections(log1)[:1]}")
    check('"allow_fallbacks":true' in flat1, "allowlist routing keeps fallbacks allowed")
    check('"ignore"' not in flat1 and '"order"' not in flat1, "allowlist alone injects only the `only` field")

    # ---- Scenario 2: precision_allowlist → provider.quantizations ---------
    allow_quant = next(q for q in ["fp8", "fp16", "bf16", "unknown"] if q in quants_present)
    log2, _ = run_scenario("precision-allow", f'[global]\nprecision_allowlist = ["{allow_quant}"]\n', [prompt])
    flat2 = flat(log2)
    check(
        f'"quantizations":["{allow_quant}"]' in flat2,
        f"precision allowlist injected verbatim: {injections(log2)[:1]}",
    )

    # ---- Scenario 3: precision_blacklist → complement quantizations -------
    blocked = sorted(q for q in KNOWN_QUANTIZATIONS if q not in quants_present) or ["int4"]
    complement = [q for q in KNOWN_QUANTIZATIONS if q not in blocked]
    log3, _ = run_scenario(
        "precision-black",
        "[global]\nprecision_blacklist = [" + ", ".join(f'"{q}"' for q in blocked) + "]\n",
        [prompt],
    )
    flat3 = flat(log3)
    check(
        f'"quantizations":[{",".join(chr(34) + q + chr(34) for q in complement)}]' in flat3,
        f"precision blacklist injected as its complement: {injections(log3)[:1]}",
    )
    check(
        not any(f'"{q}"' in flat3 for q in blocked),
        "the complement never contains a blocked precision",
    )

    # ---- Scenario 4: precision_preferred → quantization-qualified order ---
    # Pick a precision the model is actually served with and compute the tag
    # of the cheapest endpoint at that precision, like the extension does.
    target_quant = allow_quant
    expected_tag = next(e["tag"] for e in endpoints if e["quantization"] == target_quant)
    log4, _ = run_scenario(
        "precision-preferred", f'[global]\nprecision_preferred = ["{target_quant}"]\n', [prompt]
    )
    flat4 = flat(log4)
    check(
        f'"order":["{expected_tag}"' in flat4,
        f"precision preferred tag {expected_tag!r} prepended to the order: {injections(log4)[:1]}",
    )

    # ---- Scenario 5: precision allowlist wins over a blacklist ------------
    log5, _ = run_scenario(
        "precision-both",
        f'[global]\nprecision_allowlist = ["{allow_quant}"]\nprecision_blacklist = ["{allow_quant}"]\n',
        [prompt],
    )
    flat5 = flat(log5)
    check(
        f'"quantizations":["{allow_quant}"]' in flat5,
        f"with both filters configured the allowlist wins: {injections(log5)[:1]}",
    )
    check("allowlist wins" in log5, "the allowlist-wins decision is logged")

    # ---- Scenario 6: model scope overrides / inherits the new keys --------
    config_6 = f"""\
[global]
allowlist = ["{s0}"]
precision_blacklist = ["int4"]

[models."{MODEL_ID}"]
allowlist = ["{s1}"]
"""
    log6, _ = run_scenario("model-scope", config_6, [prompt])
    flat6 = flat(log6)
    check(f'"only":["{s1}"]' in flat6, f"model allowlist overrides the global one: {injections(log6)[:1]}")
    check(s0 not in flat6, "the overridden global allowlist does not leak")
    check('"quantizations"' in flat6, "precision blacklist inherited from [global]")

    # ---- Scenario 7: unservable precision_preferred entry is skipped ------
    log7, _ = run_scenario("precision-unknown", '[global]\nprecision_preferred = ["no-such-precision"]\n', [prompt])
    check(not injections(log7), f"an unservable precision preference injects nothing: {injections(log7)}")
    check(
        "preference skipped" in log7 or "no endpoint serves" in log7,
        "the skipped precision is logged",
    )

    # ---- Scenario 8: status footer and /openrouter config report the keys -
    config_8 = f'[global]\nallowlist = ["{s0}"]\nprecision_blacklist = ["int4"]\nprecision_preferred = ["{target_quant}"]\n'
    log8, events8 = run_scenario("reporting", config_8, ["/openrouter config"])
    statuses = [
        e.get("statusText", "")
        for e in events8
        if e.get("method") == "setStatus" and e.get("statusKey") == "openrouter-provider"
    ]
    check(any("only:1" in s for s in statuses), f"footer status shows the allowlist: {statuses}")
    check(any("quants:" in s for s in statuses), f"footer status shows the precision filter: {statuses}")
    notify8 = next(
        (e for e in events8 if e.get("method") == "notify" and "Allowlisted providers" in (e.get("message") or "")),
        None,
    )
    check(notify8 is not None, "config command reports the allowlist")
    if notify8:
        message = notify8.get("message") or ""
        check(f"Allowlisted providers (only these may serve): {s0}" in message, f"config command allowlist line: {message!r}")
        check("Precisions blocked (inverted into a quantizations filter): int4" in message, f"config command precision line: {message!r}")
        check(f"Precisions preferred (ordered first): {target_quant}" in message, f"config command precision preference: {message!r}")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
