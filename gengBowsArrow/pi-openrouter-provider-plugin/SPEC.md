# pi-openrouter-provider-plugin — specification

A [pi](https://pi.dev) extension for working with [OpenRouter](https://openrouter.ai)
provider routing.

## 1. Purpose

OpenRouter is an aggregator: a single model id (e.g. `z-ai/glm-5.3-flash`) can be
served by many upstream inference providers (DeepInfra, Together, Fireworks, …),
and OpenRouter chooses one per request according to load, price, and the
request's `provider` routing preferences.

This extension makes that choice visible and controllable from inside pi:

1. **Detect** when the active model is served through OpenRouter.
2. **Display** the upstream provider that actually served each request.
3. **Change** the upstream provider interactively (pin or prefer), by injecting
   the OpenRouter `provider` routing field into outgoing requests.

## 2. Detection

The active model is considered to be served through OpenRouter when either:

- `ctx.model.provider === "openrouter"`, or
- the host of `ctx.model.baseUrl` is `openrouter.ai` (or a subdomain).

When the model is not OpenRouter-backed the extension is inert: it never
touches the request payload and never writes status.

## 3. Displaying the upstream provider

For every provider response the extension resolves the upstream provider name
and shows it in the footer status area under the key `openrouter-provider` as
`⇢ <Provider>` (plus ` · pin:<slug>` when a provider is pinned).

Name resolution, in order:

1. The `X-Provider-Name` response header, when OpenRouter sends it.
2. Otherwise, the `X-Generation-Id` response header is used to query
   `GET {baseUrl}/generation?id=<id>`, whose `data.provider_name` is the
   upstream provider. The generation record is written just after the response
   arrives, so the lookup retries with a backoff (up to 6 attempts).

The API key is resolved once through `ctx.modelRegistry.getApiKeyForProvider`
and reused; the lookup runs in the background so it never delays streaming.

## 4. Changing the provider

State is a single object:

```ts
type Routing = { mode: "auto" } | { mode: "pin"; provider: string; allowFallbacks: boolean };
```

It is persisted in the session as a custom entry of type `openrouter-routing`
(via `pi.appendEntry`) and restored on `session_start`.

When `mode === "pin"`, the `before_provider_request` hook rewrites the payload:

```jsonc
{
  "provider": {
    "only": ["<provider>"],
    "allow_fallbacks": false   // true when set with `prefer`
  }
}
```

Any pre-existing `order` is removed so `only` takes effect. When
`mode === "auto"` the payload is left untouched.

## 5. Commands

| Command | Behaviour |
|---------|-----------|
| `/openrouter` (alias `/or`) | Interactive picker of providers serving the active model. |
| `/openrouter auto` | Release the pin; OpenRouter decides. |
| `/openrouter status` | Report current routing and last seen provider. |
| `/openrouter list` | List the first 15 providers serving the active model, with prices. |
| `/openrouter pin <slug>` | Force `<slug>`, disallow fallbacks. |
| `/openrouter prefer <slug>` | Try `<slug>` first, allow fallbacks. |
| `/openrouter <slug>` | Shorthand for `pin <slug>`. |

The interactive picker lists providers from
`GET {baseUrl}/models/<modelId>/endpoints`, deduplicated per provider slug
(the endpoint tag with any `/quantization` suffix removed), sorted by prompt
price. Each entry shows price per million tokens and 30-minute uptime.

## 6. Non-goals

- Changing the *model* (use pi's `/model`).
- Managing OpenRouter accounts, credits, or API keys.