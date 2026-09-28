# pi-openrouter-provider-plugin

A [pi](https://pi.dev) extension that shows **which upstream provider
OpenRouter is routing your requests to**, and lets you **change it
interactively**.

OpenRouter fans a model id out across many upstream inference providers and
picks one per request. This extension reads that choice back from the response
(and from OpenRouter's generation API), shows it in the footer, and injects
`provider` routing preferences into subsequent requests when you pin a
provider.

See [SPEC.md](./SPEC.md) for the full behaviour specification.

## Install

The plugin is a pi extension package: the entry file plus a package manifest
whose runtime dependencies must resolve from a `node_modules/` next to the
entry file (see `package.json` / `package-lock.json`). Install the
dependencies once, then load the entry file directly:

```bash
npm ci
cd . && pi -e ./gengBowsArrow/pi-openrouter-provider-plugin/openrouter-provider.ts
```

Or build it with nix (the output bundles the dependencies), and copy the
resulting package directory into a pi extension discovery directory
(`~/.pi/agent/extensions/` for all projects, `.pi/extensions/` for this
one).

## Commands

| Command | Behaviour |
|---------|-----------|
| `/openrouter` (or `/or`) | Interactive picker of the providers serving the active model. |
| `/openrouter auto` | Release the pin; OpenRouter decides. |
| `/openrouter status` | Show current routing and the last provider seen. |
| `/openrouter list` | List providers serving the active model, with prices. |
| `/openrouter pin <slug>` | Force `<slug>`, no fallbacks. |
| `/openrouter prefer <slug>` | Try `<slug>` first, allow fallbacks. |
| `/openrouter <slug>` | Shorthand for `pin <slug>`. |

The status area shows `⇢ <Provider>` (and ` · pin:<slug>` when pinned, plus
` · blacklisted:<n>` when providers are blacklisted) while an OpenRouter model
is active.

The interactive picker (and `/openrouter list`) shows, per provider: the
model's precision (quantization, e.g. `[fp8]`) at that endpoint when known,
the price per million tokens, and 30-minute uptime.

In the interactive picker, **shift+enter toggles (blacklists) the highlighted
provider** instead of selecting it: a blacklisted provider is marked with `✗`
and is excluded from OpenRouter's automatic provider selection (injected as
`provider.ignore` on outgoing requests). Pressing shift+enter again on a
blacklisted item un-blacklists it. Plain enter still pins the selected
provider. The same blacklist can be managed textually via `/openrouter
block|unblock|blocked`.

The same blacklist can be managed textually via `/openrouter
block|unblock|blocked`.

## Configuration file

Declarative routing can be set up in a TOML file whose path is taken from the
`PI_OPENROUTER_EXTENSION_CONFIG_FILE` environment variable:

```toml
[global]
preferred = ["deepinfra", "together"]   # tried sequentially, in this order
blacklist = ["chutes"]

[models."z-ai/glm-5.3-flash"]           # per-model override (exact model id)
preferred = ["moonshotai"]
blacklist = []
```

Both the global table and each per-model table accept the same two keys:
`preferred` (providers tried sequentially in list order, injected as
`provider.order`) and `blacklist` (providers excluded from automatic
selection, injected as `provider.ignore`). A model-specific table has higher
precedence than the global one: when one exists for the active model, the
global configuration is ignored entirely. An interactive pin
(`/openrouter pin`) overrides the file; in automatic mode the session
blacklist (picker toggles, `block`) is unioned with the file's blacklist.
A commented reference example ships with the package as `config.example.toml`
(it is never read by the extension — the path comes from the environment
variable).
See [SPEC.md](./SPEC.md) section 5.1 for the full semantics.

## Options

| Environment variable | Effect |
|----------------------|--------|
| `PI_OPENROUTER_PROVIDER_LOG` | Append a trace of detection/routing to this file. |
| `PI_OPENROUTER_EXTENSION_CONFIG_FILE` | Path of the TOML routing configuration file (see above). |

## Nix

`default.nix` builds the extension package with its declared runtime
dependencies installed offline from the lockfile, and nothing else:

```bash
nix build .#packages.x86_64-linux.pi-openrouter-provider-plugin
pi -e result/share/pi/extensions/pi-openrouter-provider-plugin/openrouter-provider.ts
```

## Testing

`test/rpc_test.py` drives pi in RPC mode and checks detection, pinning, and
the interactive picker end to end:

```bash
cd gengBowsArrow/pi-openrouter-provider-plugin && npm ci
python3 test/rpc_test.py
```

The configuration-file feature has its own end-to-end suite:

```bash
python3 test/config_test.py
```