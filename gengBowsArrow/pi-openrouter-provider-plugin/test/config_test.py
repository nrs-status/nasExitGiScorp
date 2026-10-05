#!/usr/bin/env python3
"""End-to-end test for the configuration-file feature of the OpenRouter
provider pi extension (SPEC.md section 5.1).

Drives pi in RPC mode with PI_OPENROUTER_EXTENSION_CONFIG_FILE pointing at a
TOML file and checks, via the extension's debug log, what is injected into
the outgoing request payload:

  1. model-specific scope: a `[models."<id>"]` table applies, and the
     `[global]` table is ignored entirely (not merged per key);
  2. global scope: with no model-specific table for the active model, the
     `[global]` preferred/blacklist lists apply;
  3. invalid TOML: the file is rejected as a whole, the extension stays
     functional, and nothing is injected;
  4. an interactive pin overrides configuration-file routing;
  5. the session blacklist unions with the configuration blacklist;
  6. with no (or a missing) configuration file, payloads are untouched;
  7. `/openrouter status` reports the configuration file and its scope.

The injected `preferred` slugs are real provider slugs for the test model so
that the order request still succeeds; blacklist slugs are synthetic
(OpenRouter tolerates unknown slugs in `ignore`).
"""

from __future__ import annotations

import os
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rpc_test import PiRpc, fetch_model_endpoints, read_log, wait_for_agent_end  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.normpath(os.path.join(HERE, "..", "openrouter-provider.ts"))
MODEL_ID = "z-ai/glm-5.3-flash"
CONFIG_PATH = "/tmp/pi-openrouter-config-test.toml"


class ConfigRpc(PiRpc):
    """A PiRpc whose environment is customised per scenario."""

    def __init__(self, log_path: str, config_path: str | None):
        env = {
            **os.environ,
            "PI_OPENROUTER_PROVIDER_LOG": log_path,
        }
        if config_path is not None:
            env["PI_OPENROUTER_EXTENSION_CONFIG_FILE"] = config_path
        self.log_path = log_path
        self.proc = subprocess.Popen(
            ["pi", "--mode", "rpc", "--no-extensions", "-e", EXTENSION, "--no-session"],
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


def run_scenario(
    name: str,
    config_text: str | None,
    config_path: str | None,
    prompts: list[str],
) -> str:
    """Start pi, run `prompts` sequentially, return the extension debug log."""
    log_path = f"/tmp/pi-openrouter-config-test-{name}.log"
    try:
        os.unlink(log_path)
    except FileNotFoundError:
        pass
    if config_text is not None:
        with open(config_path, "w") as handle:
            handle.write(config_text)
    rpc = ConfigRpc(log_path, config_path)
    try:
        for prompt in prompts:
            rpc.send({"type": "prompt", "message": prompt})
            if prompt.startswith("/"):
                # A subcommand prompt does not run the agent loop; it merely
                # yields an RPC response once handled.
                rpc.wait_for(
                    lambda e: e.get("type") == "response" and e.get("command") == "prompt",
                    60,
                    f"command {prompt!r} handled",
                )
            else:
                wait_for_agent_end(rpc, 150)
        return read_log(log_path)
    finally:
        rpc.close()


def request_lines(log_text: str) -> list[str]:
    """Log lines that show what was injected into the outgoing payload."""
    return [line for line in log_text.splitlines() if "request:" in line or "injecting" in line]


def injections(log_text: str) -> list[str]:
    return [line for line in log_text.splitlines() if "injecting" in line]


def main() -> int:
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        print(("PASS " if condition else "FAIL ") + message)
        if not condition:
            failures.append(message)

    endpoints = fetch_model_endpoints(MODEL_ID)
    slugs = [entry["slug"] for entry in endpoints]
    check(len(slugs) >= 2, f"discovered {len(slugs)} candidate providers for {MODEL_ID}")
    s0, s1, s2 = (slugs + ["deepinfra", "together", "moonshotai"])[:3]
    prompt = "Reply with exactly: ok"

    # ---- Scenario 1: model-specific scope wins, global ignored entirely ----
    # The global list contains synthetic slugs; if the global table were
    # merged (or applied), they would leak into the injected payload. The
    # model table sets both keys, so this also exercises a full override.
    config_1 = f"""\
# comment handling
[global]
preferred = ["fake-global-a", "fake-global-b"]
blacklist = ["fake-global-blocked"]

[models."{MODEL_ID}"]
preferred = [
  "{s0}",   # trailing comment inside a multi-line array
  "{s1}",
]
blacklist = ["fake-model-blocked"]
"""
    log1 = run_scenario("model-scope", config_1, CONFIG_PATH, [prompt])
    flat1 = "".join(request_lines(log1)).replace(" ", "")
    check(
        f'"order":["{s0}","{s1}"]' in flat1,
        f"model-specific preferred order injected: {injections(log1)[:1]}",
    )
    check('"ignore":["fake-model-blocked"]' in flat1, "model-specific blacklist injected")
    check("fake-global-a" not in flat1, "global preferred list ignored when a model table exists")
    check("fake-global-blocked" not in flat1, "global blacklist ignored when a model table exists")
    check('"allow_fallbacks":true' in flat1, "config-driven routing keeps fallbacks allowed")
    check("config scope=model" in log1, "log reports model scope")

    # ---- Scenario 2: global scope applies when no model table matches ----
    config_2 = f"""\
[global]
preferred = ["{s1}", "{s2}"]
blacklist = ["fake-global-blocked"]

[models."some/other-model"]
preferred = ["fake-never-applied"]
"""
    log2 = run_scenario("global-scope", config_2, CONFIG_PATH, [prompt])
    flat2 = "".join(request_lines(log2)).replace(" ", "")
    check(f'"order":["{s1}","{s2}"]' in flat2, f"global preferred order injected: {injections(log2)[:1]}")
    check('"ignore":["fake-global-blocked"]' in flat2, "global blacklist injected")
    check("fake-never-applied" not in flat2, "another model's table not applied")
    check("config scope=global" in log2, "log reports global scope")

    # ---- Scenario 3: invalid TOML is rejected as a whole, extension inert --
    log3 = run_scenario("invalid-toml", "[global\npreferred = ???\n", CONFIG_PATH, [prompt])
    check(not injections(log3), f"invalid config injects nothing: {injections(log3)}")
    check("config file ignored" in log3, "parse error logged and the extension stayed functional")

    # ---- Scenario 4: interactive pin overrides the configuration file -----
    log4 = run_scenario("pin-overrides", config_1, CONFIG_PATH, [f"/openrouter pin {s0}", prompt])
    flat4 = "".join(request_lines(log4)).replace(" ", "")
    check(f'"only":["{s0}"]' in flat4, f"pin injected as provider.only: {injections(log4)[:1]}")
    check('"order":' not in flat4, "config order not injected while pinned")

    # ---- Scenario 5: session blacklist unions with the config blacklist ---
    log5 = run_scenario(
        "union",
        '[global]\nblacklist = ["fake-cfg-blocked"]\n',
        CONFIG_PATH,
        [f"/openrouter block {s1}", prompt],
    )
    flat5 = "".join(request_lines(log5)).replace(" ", "")
    check(
        '"ignore":["fake-cfg-blocked","%s"]' % s1 in flat5,
        f"config and session blacklists unioned: {injections(log5)[:1]}",
    )

    # ---- Scenario 6: no config file → payload untouched -------------------
    log6 = run_scenario("no-config", None, None, [prompt])
    check(not injections(log6), f"without a config file nothing is injected: {injections(log6)}")

    # ---- Scenario 7: missing config file → ignored, request still fine ----
    log7 = run_scenario("missing-file", None, "/tmp/pi-openrouter-config-does-not-exist.toml", [prompt])
    check(not injections(log7), "missing config file injects nothing")
    check("config file ignored" in log7, "missing config file logged and ignored")

    # ---- Scenario 8: /openrouter status reports the configuration file ----
    status_log = "/tmp/pi-openrouter-config-test-status.log"
    try:
        os.unlink(status_log)
    except FileNotFoundError:
        pass
    with open(CONFIG_PATH, "w") as handle:
        handle.write(config_1)
    rpc8 = ConfigRpc(status_log, CONFIG_PATH)
    try:
        rpc8.send({"type": "prompt", "message": "/openrouter status"})
        notify = rpc8.wait_for(
            lambda e: e.get("method") == "notify" and "OpenRouter routing:" in (e.get("message") or ""),
            30,
            "status notification",
        )
        message = notify.get("message") or ""
        check("(model scope)" in message, f"status reports the applicable scope: {message!r}")
        check(CONFIG_PATH in message, "status reports the config file path")
        check("preferred: " in message, "status reports the preferred order")
    finally:
        rpc8.close()

    # ---- Scenario 9: /openrouter config reports the config-file routing --
    # The command must show the preferred and blacklisted providers that the
    # configuration file applies to the *current* model, in all four cases:
    # model scope, global scope, no applicable table, and no/invalid file.
    # The file is only (re-)loaded on session_start/model_select, so each
    # variant runs in its own pi process.

    def run_config_command(config_text: str | None, config_path: str | None, command: str) -> tuple[str, str]:
        """Start pi, send `command`, return (notify message, '')."""
        if config_text is not None:
            with open(config_path, "w") as handle:
                handle.write(config_text)
        rpc = ConfigRpc(f"/tmp/pi-openrouter-config-test-cfg-{command.replace(' ', '-').replace('/', '')}.log", config_path)
        try:
            rpc.send({"type": "prompt", "message": command})
            notify = rpc.wait_for(
                lambda e: e.get("method") == "notify",
                30,
                f"config notification for {command!r}",
            )
            return notify.get("message") or "", notify.get("notifyType") or ""
        finally:
            rpc.close()

    message = run_config_command(config_1, CONFIG_PATH, "/openrouter config")[0]
    check(f"(model scope for {MODEL_ID})" in message, f"config command reports model scope: {message!r}")
    check(f"Preferred providers: {s0}, {s1}" in message, f"config command reports the preferred order: {message!r}")
    check("Blacklisted providers: fake-model-blocked" in message, f"config command reports the blacklist: {message!r}")
    check("fake-global" not in message, "config command ignores the global table when a model table exists")

    # Global scope: no model table for the active model (via the /or alias).
    message = run_config_command(config_2, CONFIG_PATH, "/or routing")[0]
    check("(global scope" in message, f"alias via /or routing reports global scope: {message!r}")
    check(f"Preferred providers: {s1}, {s2}" in message, f"global preferred order reported: {message!r}")
    check("Blacklisted providers: fake-global-blocked" in message, f"global blacklist reported: {message!r}")

    # No table applies to the active model.
    message = run_config_command(
        '[models."some/other-model"]\npreferred = ["fake-never"]\n', CONFIG_PATH, "/openrouter config"
    )[0]
    check("No routing table applies" in message, f"no applicable table reported: {message!r}")

    # No configuration file at all.
    message = run_config_command(None, None, "/openrouter config")[0]
    check("No configuration file" in message, f"unset file reported: {message!r}")

    # Invalid file: reported as a warning, with the path and the reason.
    msg, kind = run_config_command("[global\npreferred = ???\n", CONFIG_PATH, "/openrouter config")
    check("invalid" in msg and CONFIG_PATH in msg, f"invalid file reported with its path: {msg!r}")
    check(kind == "warning", f"invalid file reported as a warning: {kind!r}")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())