# pi-openrouter-provider-plugin — Specification

## 0. About this document

This document contains a high-level overview of the `pi-openrouter-provider-plugin` extension for the [pi](https://pi.dev) coding agent harness. This document's main purpose is to serve as a reference for AI agents to use in order to implement the extension. It is not meant to give excessively detailed technical information; an agent is expected to fill out the missing details or to make architectural and design decisions about elements that are left underspecified in this document.

Any agent using this document as a starting point for implementing the extension is expected to write a second document, SPEC_EXTENSION.md, containing the details missing from this document necessary for the implementation. SPEC_EXTENSION.md should include the interpretation of ambiguities in this document, and design decisions left open or underspecified by this document. The combination of SPEC.md and SPEC_EXTENSION.md should suffice to give a full technical specification of the extension.

This document intends to specify a pi extension written in TypeScript, delivered as a single extension file loaded with `pi -e <path>` (or placed in a pi extension discovery directory). Although the deliverable is a single file, an agent implementing this specification is expected to avoid writing an undifferentiated monolith, and instead factor the program into self-contained pieces implementing a singular logically distinct part of the total extension (detection, state, status rendering, stream tapping, API lookups, command handling).

## 1. Purpose

OpenRouter is an aggregator: a single model id (e.g. `z-ai/glm-5.3-flash`) can be served by many upstream inference providers (DeepInfra, Together, Fireworks, …), and OpenRouter chooses one per request according to load, price, and the request's `provider` routing preferences.

The extension has three responsibilities:

1. **Detect** when the active model is served through OpenRouter.
2. **Display** the upstream provider that actually served each request.
3. **Change** the upstream provider interactively (pin or prefer), by injecting the OpenRouter `provider` routing field into outgoing requests, and **exclude** providers from OpenRouter's automatic choice by blacklisting them.

The extension is inert whenever the active model is not OpenRouter-backed: it never touches the request payload, never queries the API, and never writes status (see section 2).

## 2. Detection

The active model is considered to be served through OpenRouter when either:

- `ctx.model.provider === "openrouter"`, or
- the host of `ctx.model.baseUrl` is `openrouter.ai` or a subdomain of it.

The OpenRouter API base URL is derived from `ctx.model.baseUrl` (trailing slashes removed); all API queries in sections 4 and 6 are issued against it. A model whose provider is `openrouter` but whose base URL host is not an `openrouter.ai` host is still detected as OpenRouter (for payload rewriting), but API queries that need a base URL are skipped.

## 3. State model

The extension's mutable state is a single in-memory object plus a provider blacklist:

```
type Routing = { mode: "auto" } | { mode: "pin"; provider: string; allowFallbacks: boolean };
```

| State                | Type           | Meaning                                                        |
|----------------------|----------------|----------------------------------------------------------------|
| `routing`            | `Routing`      | Current routing preference; initialised to `{ mode: "auto" }`  |
| `blacklist`          | `string[]`     | Provider slugs excluded from automatic selection               |
| `lastDetected`       | `string?`      | Name of the last upstream provider seen serving a request      |
| `endpointsCache`     | cached object  | Endpoints of the active model, keyed by model id               |

**Persistence.** `routing` is persisted in the session as a custom entry of type `openrouter-routing` (via `pi.appendEntry`) and `blacklist` as a custom entry of type `openrouter-blacklist` (as `{ providers: string[] }`). Both are restored on `session_start`. Restored values are sanitized: malformed entries fall back to the default (`auto` routing, empty blacklist); blacklist slugs are trimmed, lowercased, and deduplicated.

## 4. Displaying the upstream provider

The upstream provider name is shown in the footer status area under the status key `openrouter-provider`, rendered as:

```
⇢ <Provider> · pin:<slug> · blacklisted:<n>
```

`pin:<slug>` appears only while a provider is pinned; `blacklisted:<n>` (with the count of blacklisted providers) appears only when the blacklist is non-empty. While the endpoints list is being fetched for the picker, the status briefly shows `⇢ loading providers…`. When nothing has been detected and no pin or blacklist exists, the status is cleared.

Name resolution, in order:

1. The `X-Provider-Name` response header, when OpenRouter sends it (read from the `after_provider_response` event, with header names matched case-insensitively).
2. The `provider` field of the chat-completion SSE chunks, read by a **stream tap**: the extension wraps the effective OpenRouter provider's fetch so that `text/event-stream` response bodies are tee'd; the tap stream is parsed line-by-line for `data:` chunks (ignoring non-JSON lines and `[DONE]`) and the authoritative upstream `provider` string is extracted from each chunk. The forward stream is handed back to pi untouched. The tap is installed once, lazily, and only when the OpenRouter provider is registered.
3. Otherwise, the `X-Generation-Id` response header is used to query `GET {baseUrl}/generation?id=<id>`, whose `data.provider_name` is the upstream provider. The generation record is written just after the response arrives, so the lookup retries with a linear backoff (up to 6 attempts). The generation lookup is skipped when the stream tap is installed, since the tap already yields the authoritative name (and pinned generations are not queryable).

The API key is resolved once through `ctx.modelRegistry.getApiKeyForProvider` and reused; the lookup runs in the background so it never delays streaming.

Because the stream tap resolves the name mid-stream, the rendered status is flushed lazily: the extension marks the status dirty and re-renders on the next `message_update` or `turn_end` event with a live context.

All status writes are wrapped so that a failing UI can never crash the extension (the failure is logged, see section 7).

## 5. Payload rewriting

The `before_provider_request` hook rewrites the outgoing payload, but only when the active model is OpenRouter (section 2). It never rewrites anything otherwise.

When `routing.mode === "pin"`, the payload's `provider` field becomes:

```jsonc
{
  "provider": {
    "only": ["<provider>"],
    "allow_fallbacks": false   // true when the pin was set with `prefer`
  }
}
```

Any pre-existing `order` key is removed so `only` takes effect. Other pre-existing keys of the `provider` object are preserved.

When `routing.mode === "auto"` the payload is left untouched — unless the blacklist is non-empty, in which case the payload is rewritten to:

```jsonc
{
  "provider": {
    "ignore": ["<blacklisted-slug>", ...],
    "allow_fallbacks": true
  }
}
```

with the same `order` removal. When the blacklist is empty and mode is `auto`, the hook returns without modifying the payload.

## 6. Commands

The extension registers a single command `/openrouter` (alias `/or`) which takes an optional subcommand. All commands require an OpenRouter model to be active; otherwise a warning (`The active model is not routed through OpenRouter.`) is shown and nothing else happens.

| Command | Behaviour |
|---------|-----------|
| `/openrouter` (aliases: bare, `pick`, `choose`) | Interactive picker of providers serving the active model. |
| `/openrouter auto` (aliases: `off`, `reset`) | Release the pin; OpenRouter decides. |
| `/openrouter status` (alias: `info`) | Report current routing and last seen provider. |
| `/openrouter list` | List the first 15 providers serving the active model, with prices. |
| `/openrouter pin <slug>` | Force `<slug>`, disallow fallbacks. |
| `/openrouter prefer <slug>` | Try `<slug>` first, allow fallbacks. |
| `/openrouter <slug>` | Shorthand for `pin <slug>` (any unknown subcommand is treated as a slug). |
| `/openrouter block <slug>…` (alias: `blacklist`) | Blacklist `<slug>`s from automatic selection. |
| `/openrouter unblock <slug>…` (alias: `unblacklist`) | Remove `<slug>`s from the blacklist. |
| `/openrouter blocked` (alias: `blacklisted`) | Show the blacklist. |

Missing arguments to `pin`/`prefer`/`block`/`unblock` produce a usage warning. `unblock` of a slug that is not blacklisted produces a warning and changes nothing. Blacklisting or un-blacklisting reports the change via a notification. `status` reports, e.g., `pinned to "<slug>" (no fallbacks)` or `automatic (OpenRouter decides), blacklisted: a, b`, followed by the last provider seen (`(unknown)` if none).

### 6.0 Endpoint listing

Providers serving the active model are fetched from `GET {baseUrl}/models/<modelId>/endpoints` and deduplicated per provider slug (the endpoint tag with any `/quantization` suffix removed). Each endpoint record carries the human-readable provider name, prompt/completion prices per token, the advertised context length, the advertised quantization, and 30-minute uptime. The result is cached per model id. The deduplicated list is sorted by prompt price.

### 6.1 `/openrouter list` and picker entries

`/openrouter list` shows the first 15 endpoints as a numbered notification. Both `list` and the picker render each entry as:

```
<index>. <name> (<slug>)<precision tag><price tag>
```

where the precision tag shows the model's quantization at that endpoint (e.g. `[fp8]`) when OpenRouter reports a known one, and the price tag shows price per million tokens (and 30-minute uptime).

### 6.2 Interactive picker

In TUI mode the picker is a toggle-aware menu with a hint footer (`enter pin · shift+enter blacklist-toggle · esc cancel`):

- **enter** on a menu item pins the highlighted provider (no fallbacks) and closes the menu.
- **shift+enter** toggles (blacklists) the highlighted provider instead of closing the menu: an un-blacklisted provider becomes blacklisted, an already-blacklisted one is un-blacklisted. The list is re-rendered with blacklisted providers marked `✗`.
- **escape** cancels without changing anything.

Blacklisted providers are marked with `✗`, persisted in the session (section 3), and excluded from OpenRouter's automatic selection mode (section 5). In non-TUI modes (e.g. RPC) the picker falls back to a plain select menu with an `Auto — let OpenRouter decide` entry; blacklisted items are marked `✗` but cannot be toggled interactively — use `block`/`unblock` instead.

## 7. Diagnostics

| Environment variable | Effect |
|----------------------|--------|
| `PI_OPENROUTER_PROVIDER_LOG` | Append a timestamped trace of detection, routing, stream-tap, and lookup events to this file. |

Logging must never break the extension: write failures are silently ignored.

## 8. Non-goals

- Changing the *model* (use pi's `/model`).
- Managing OpenRouter accounts, credits, or API keys.