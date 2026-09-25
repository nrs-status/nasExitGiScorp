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

The plugin is a single extension file. Load it directly:

```bash
pi -e ./gengBowsArrow/pi-openrouter-provider-plugin/openrouter-provider.ts
```

Or copy it into a pi extension discovery directory (`~/.pi/agent/extensions/`
for all projects, `.pi/extensions/` for this one).

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

The status area shows `⇢ <Provider>` (and ` · pin:<slug>` when pinned) while an
OpenRouter model is active.

## Options

| Environment variable | Effect |
|----------------------|--------|
| `PI_OPENROUTER_PROVIDER_LOG` | Append a trace of detection/routing to this file. |

## Nix

`default.nix` installs the extension file, and nothing else (no wrapper, no
package manifest):

```bash
nix build .#packages.x86_64-linux.pi-openrouter-provider-plugin
pi -e result/share/pi/extensions/openrouter-provider.ts
```

## Testing

`test/rpc_test.py` drives pi in RPC mode and checks detection, pinning, and
the interactive picker end to end:

```bash
python3 test/rpc_test.py
```