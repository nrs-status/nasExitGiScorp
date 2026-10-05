/**
 * OpenRouter Provider — a pi extension.
 *
 * When the active model is served through OpenRouter (https://openrouter.ai),
 * OpenRouter picks an upstream inference provider for every request. This
 * extension:
 *
 *   1. Detects OpenRouter usage (provider id `openrouter`, or a model whose
 *      base URL points at an `openrouter.ai` host).
 *   2. Reports which upstream provider actually served the request, in the
 *      footer status area (e.g. `⇢ DeepInfra`), together with that provider's
 *      costs (per million tokens, when the model's endpoints data is
 *      available) and its precision (quantization) — e.g.
 *      `⇢ DeepInfra (fp8, $0.07/M in, $0.15/M out)`. The name is read from the
 *      streamed response itself: the OpenRouter chat-completions SSE chunks
 *      carry a `provider` field, which is captured by tapping the provider
 *      HTTP fetch. As a fallback (and for non-`openrouter` providers whose
 *      base URL points at OpenRouter) the `X-Provider-Name` header or the
 *      generation endpoint (`GET /api/v1/generation?id=<x-generation-id>`)
 *      is used.
 *   3. Lets the user interactively pin / prefer an upstream provider via the
 *      `/openrouter` command. The selection is injected into the outgoing
 *      request as the OpenRouter `provider` routing field, and persisted in
 *      the session so it survives resumption. The picker and `list` also
 *      show the model's precision (quantization) at each endpoint when
 *      OpenRouter reports it.
 *   4. Lets the user blacklist upstream providers from the automated
 *      selection mode: in the `/openrouter` picker, pressing shift+enter on
 *      a menu item toggles (blacklists) it instead of pinning it. A
 *      blacklisted provider is excluded from OpenRouter's automatic
 *      provider choice via the `provider.ignore` routing field. OpenRouter
 *      silently ignores unknown routing slugs, so configured and pinned
 *      provider references are validated against the exact slugs reported
 *      by the endpoints API: an entry that looks like a typo for a known
 *      slug is loudly reported (warning notification with a "did you mean"
 *      suggestion), while entries matching nothing at all are only
 *      debug-logged — endpoint lists are per model, so a provider absent
 *      from the active model's list may well serve other models.
 *   5. Reads an optional TOML configuration file (path taken from the
 *      PI_OPENROUTER_EXTENSION_CONFIG_FILE environment variable) that
 *      declaratively prefers and/or blacklists providers, globally and/or
 *      per model. A per-model table overrides the keys it sets; keys it
 *      omits are inherited from the [global] table. See SPEC.md 5.1. TOML parsing and SSE framing are
 *      provided by runtime dependencies (smol-toml, eventsource-parser).
 *
 * Usage:
 *   PI_OPENROUTER_EXTENSION_CONFIG_FILE=/etc/openrouter-routing.toml \
 *     pi -e ./openrouter-provider.ts
 *
 * Runtime dependencies (declared in ./package.json, resolved from
 * ./node_modules next to this file): smol-toml, eventsource-parser.
 *
 * Commands:
 *   /openrouter                      interactive provider picker
 *   /openrouter auto                 release the pin (OpenRouter decides)
 *   /openrouter status               show current routing + last seen provider
 *   /openrouter list                 list providers serving the active model
 *   /openrouter pin <slug>           force <slug>, disallow fallbacks
 *   /openrouter prefer <slug>        try <slug> first, allow fallbacks
 *   /openrouter <slug>               shorthand for `pin <slug>`
 *   /openrouter block <slug>         blacklist <slug> from automatic selection
 *   /openrouter unblock <slug>       remove <slug> from the blacklist
 *   /openrouter blocked              show the blacklist
 *   /openrouter config               show the config-file routing for the
 *                                    current model (preferred + blacklisted)
 *
 * Debugging: set PI_OPENROUTER_PROVIDER_LOG=/path/to/log to append a trace.
 */

import { appendFileSync, readFileSync } from "node:fs";
import { parse as parseToml } from "smol-toml";
import { EventSourceParserStream } from "eventsource-parser/stream";
import type { ExtensionAPI, ExtensionContext, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { Provider } from "@earendil-works/pi-ai";
import { matchesKey, truncateToWidth } from "@earendil-works/pi-tui";

const STATUS_KEY = "openrouter-provider";
const ROUTING_ENTRY = "openrouter-routing";
const BLACKLIST_ENTRY = "openrouter-blacklist";
const DEBUG_LOG = process.env.PI_OPENROUTER_PROVIDER_LOG;

type RoutingMode = "auto" | "pin";

interface Routing {
	mode: RoutingMode;
	/** Provider slug to pin/prefer (only meaningful when mode === "pin"). */
	provider?: string;
	/** Whether OpenRouter may fall back to another provider. */
	allowFallbacks?: boolean;
}

interface EndpointInfo {
	/** Routing slug (provider tag with any quantization suffix removed). */
	slug: string;
	/** Raw endpoint tag (may include `/quantization`). */
	tag: string;
	/** Human-readable provider name. */
	name: string;
	/** USD per token, prompt side. */
	promptPrice?: number;
	/** USD per token, completion side. */
	completionPrice?: number;
	/** Provider-advertised context length for this endpoint. */
	contextLength?: number;
	/** Quantization advertised by the endpoint. */
	quantization?: string;
	/** 30 minute uptime percentage. */
	uptime?: number;
}

let routing: Routing = { mode: "auto" };
/** Provider slugs excluded from OpenRouter's automatic selection. */
let blacklist: string[] = [];
let lastDetected: string | undefined;
let statusDirty = false;
let cachedKey: string | undefined;
let keyResolved = false;
let tapInstalled = false;
let api: ExtensionAPI | undefined;
let endpointsCache: { modelId: string; fetchedAt: number; endpoints: EndpointInfo[] } | undefined;
/**
 * Alias index for provider-slug *validation* and suggestions: for every
 * endpoint seen on the endpoints API it records the exact routing slug in
 * `knownSlugs`, and indexes naming variants (normalized slug, display name,
 * tag prefix) in `slugSuggestions` so a mistyped reference can be reported
 * with a "did you mean" hint. OpenRouter's `provider.order` /
 * `provider.ignore` routing only understands the exact routing slugs (e.g.
 * `open-inference`) and **silently ignores unknown ones** — so configured
 * slugs are never rewritten; instead, entries that match no known slug are
 * loudly reported (notification + log) rather than silently ineffective.
 */
const knownSlugs = new Set<string>();
const slugSuggestions = new Map<string, string>();
/** Probable typos already reported, to avoid notification spam. */
const warnedSlugs = new Set<string>();
/** Id of the model the known slugs were (last) learned from, for log lines. */
let knownSlugsModelId: string | undefined;

function log(message: string): void {
	if (!DEBUG_LOG) return;
	try {
		appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${message}\n`);
	} catch {
		/* logging must never break the extension */
	}
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function hostOf(url: string | undefined): string {
	if (!url) return "";
	try {
		return new URL(url).hostname.toLowerCase();
	} catch {
		return "";
	}
}

/** Normalize a provider-slug-ish string: lowercase, only [a-z0-9]. */
function normalizeSlug(value: string): string {
	return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** Record the endpoints' exact routing slugs and naming variants. */
function learnKnownSlugs(modelId: string | undefined, endpoints: EndpointInfo[]): void {
	if (modelId) knownSlugsModelId = modelId;
	for (const endpoint of endpoints) {
		if (endpoint.slug) knownSlugs.add(endpoint.slug);
		for (const candidate of [endpoint.slug, endpoint.name, endpoint.tag.split("/")[0]]) {
			if (!candidate) continue;
			const key = normalizeSlug(candidate);
			if (key && !slugSuggestions.has(key)) slugSuggestions.set(key, endpoint.slug);
		}
	}
}

/**
 * Report configured provider references that look like *typos*: an entry that
 * matches no known routing slug exactly, but does match one under
 * normalization (e.g. "openinference" vs "open-inference") is reported as a
 * warning notification with a "did you mean" hint, because OpenRouter would
 * silently ignore it and the intended block/order would not happen.
 *
 * Entries that match nothing at all are only debug-logged: endpoint lists are
 * **per model**, while configuration (especially the global blacklist) can
 * name providers that serve other models — absence from the active model's
 * endpoint list is therefore not evidence of a mistake, and OpenRouter
 * harmlessly ignores such entries there. Skipped entirely while nothing is
 * known (the endpoints lookup has not succeeded yet). Probable typos are
 * reported once per slug.
 */
function warnUnknownSlugs(ctx: ExtensionContext, entries: string[], what: string): void {
	if (knownSlugs.size === 0) return;
	for (const entry of entries) {
		if (knownSlugs.has(entry)) continue;
		const suggestion = slugSuggestions.get(normalizeSlug(entry));
		if (!suggestion) {
			log(
				`provider slug "${entry}" (${what}) is not among the ${knownSlugs.size} slugs known so far ` +
					`(endpoint lists are per model; last learned from ${knownSlugsModelId ?? "?"})`,
			);
			continue;
		}
		if (warnedSlugs.has(entry)) continue;
		warnedSlugs.add(entry);
		log(`unknown provider slug in ${what}: "${entry}" — did you mean "${suggestion}"?`);
		safeUi(ctx, (ui) =>
			ui.notify(
				`OpenRouter: "${entry}" (${what}) looks like a typo for "${suggestion}" and will be ignored by routing`,
				"warning",
			),
		);
	}
}

/** Warn about every unknown slug in the effective routing configuration. */
function warnConfiguredSlugs(ctx: ExtensionContext): void {
	const resolved = resolveConfig(ctx.model?.id);
	if (resolved.config) {
		warnUnknownSlugs(ctx, resolved.config.preferred ?? [], `${resolved.scope} config preferred`);
		warnUnknownSlugs(ctx, resolved.config.blacklist ?? [], `${resolved.scope} config blacklist`);
	}
	warnUnknownSlugs(ctx, blacklist, "session blacklist");
}

function isOpenRouterModel(model: ExtensionContext["model"]): boolean {
	if (!model) return false;
	if (model.provider === "openrouter") return true;
	const host = hostOf(model.baseUrl);
	return host === "openrouter.ai" || host.endsWith(".openrouter.ai");
}

/** The OpenRouter API base URL for the active model, if it is OpenRouter. */
function openRouterBase(model: ExtensionContext["model"]): string | undefined {
	if (!model) return undefined;
	const host = hostOf(model.baseUrl);
	if (host !== "openrouter.ai" && !host.endsWith(".openrouter.ai")) return undefined;
	return model.baseUrl.replace(/\/+$/, "");
}

function lowerHeaders(headers: Record<string, string>): Record<string, string> {
	const out: Record<string, string> = {};
	for (const [k, v] of Object.entries(headers ?? {})) out[k.toLowerCase()] = v;
	return out;
}

function safeUi(ctx: ExtensionContext, fn: (ui: ExtensionContext["ui"]) => void): void {
	try {
		fn(ctx.ui);
	} catch (error) {
		log(`ui update failed: ${String(error)}`);
	}
}

function renderStatus(ctx: ExtensionContext): void {
	const parts: string[] = [];
	if (lastDetected) parts.push(detectedStatusPart());
	if (routing.mode === "pin" && routing.provider) {
		parts.push(`pin:${routing.provider}`);
	} else {
		// Automatic mode: report the effective (config ∪ session) exclusions and
		// a declarative preferred order from the configuration file, if any.
		const ignore = effectiveIgnore(ctx.model?.id);
		if (ignore.length > 0) parts.push(`blacklisted:${ignore.length}`);
		const order = resolveConfig(ctx.model?.id).config?.preferred ?? [];
		if (order.length > 0) parts.push(`order:${order.length}`);
	}
	const text = parts.length > 0 ? `⇢ ${parts.join(" · ")}` : undefined;
	safeUi(ctx, (ui) => ui.setStatus(STATUS_KEY, text));
}

function sanitizeRouting(data: unknown): Routing {
	if (!data || typeof data !== "object") return { mode: "auto" };
	const raw = data as Partial<Routing>;
	if (raw.mode === "pin" && typeof raw.provider === "string" && raw.provider.trim()) {
		return { mode: "pin", provider: raw.provider.trim(), allowFallbacks: raw.allowFallbacks === true };
	}
	return { mode: "auto" };
}

function sanitizeBlacklist(data: unknown): string[] {
	if (!data || typeof data !== "object") return [];
	const raw = (data as { providers?: unknown }).providers;
	if (!Array.isArray(raw)) return [];
	const slugs = raw
		.filter((item): item is string => typeof item === "string" && !!item.trim())
		.map((item) => item.trim().toLowerCase());
	return [...new Set(slugs)];
}

async function ensureKey(ctx: ExtensionContext): Promise<string | undefined> {
	if (keyResolved) return cachedKey;
	try {
		cachedKey = await ctx.modelRegistry.getApiKeyForProvider(ctx.model?.provider ?? "openrouter");
	} catch (error) {
		log(`could not resolve OpenRouter API key: ${String(error)}`);
		cachedKey = undefined;
	}
	keyResolved = true;
	return cachedKey;
}

// ---------------------------------------------------------------------------
// Configuration file (PI_OPENROUTER_EXTENSION_CONFIG_FILE)
//
// A TOML file that declaratively routes requests: a `[global]` table whose
// settings apply to every OpenRouter model, and per-model tables under
// `[models."<model-id>"]`. Both kinds of table may set two keys:
//
//   preferred = ["slug-a", "slug-b"]   → provider.order (tried in list order)
//   blacklist = ["slug-c"]             → provider.ignore
//
// A model-specific table overrides the global one per key: each key it sets
// replaces the global value for that model, while keys it omits are
// inherited from the `[global]` table (an explicit `blacklist = []` or
// `preferred = []` disables the global list for that key). See SPEC.md
// section 5.1.
// ---------------------------------------------------------------------------

interface ProviderRoutingConfig {
	/** Providers tried sequentially, in list order (provider.order). */
	preferred?: string[];
	/** Providers excluded from automatic selection (provider.ignore). */
	blacklist?: string[];
}

interface FileConfig {
	/** Absolute or relative path the configuration was loaded from. */
	path: string;
	/** Routing that applies to every OpenRouter model. */
	global?: ProviderRoutingConfig;
	/** Per-model routing, keyed by exact model id. */
	models: Map<string, ProviderRoutingConfig>;
}

let fileConfig: FileConfig | undefined;
let fileConfigError: string | undefined;

// TOML parsing is provided by the smol-toml runtime dependency (see package.json).

/** Trim, lowercase and deduplicate a configured provider-slug list. */
function sanitizeConfigSlugs(value: unknown, what: string): string[] {
	if (!Array.isArray(value)) throw new Error(`${what} must be an array of provider slugs`);
	const slugs: string[] = [];
	for (const item of value) {
		if (typeof item !== "string" || !item.trim()) throw new Error(`${what} must contain only non-empty strings`);
		slugs.push(item.trim().toLowerCase());
	}
	return [...new Set(slugs)];
}

function extractRoutingTable(raw: unknown, what: string): ProviderRoutingConfig {
	if (raw === undefined) return {};
	if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error(`${what} must be a table`);
	const table = raw as Record<string, unknown>;
	const config: ProviderRoutingConfig = {};
	if (table.preferred !== undefined) config.preferred = sanitizeConfigSlugs(table.preferred, `${what}.preferred`);
	if (table.blacklist !== undefined) config.blacklist = sanitizeConfigSlugs(table.blacklist, `${what}.blacklist`);
	return config;
}

/**
 * (Re-)load the configuration file named by PI_OPENROUTER_EXTENSION_CONFIG_FILE.
 * Any problem (missing file, parse error, wrong value types) is logged and the
 * configuration is treated as absent; it can never break the extension.
 */
function loadConfigFile(): void {
	fileConfig = undefined;
	fileConfigError = undefined;
	const path = process.env.PI_OPENROUTER_EXTENSION_CONFIG_FILE?.trim();
	if (!path) return;
	try {
		const text = readFileSync(path, "utf8");
		const root = parseToml(text) as Record<string, unknown>;
		const models = new Map<string, ProviderRoutingConfig>();
		if (root.models !== undefined) {
			if (!root.models || typeof root.models !== "object" || Array.isArray(root.models)) {
				throw new Error("[models] must be a table of per-model tables");
			}
			for (const [modelId, table] of Object.entries(root.models as Record<string, unknown>)) {
				models.set(modelId, extractRoutingTable(table, `[models."${modelId}"]`));
			}
		}
		const globalConfig = root.global !== undefined ? extractRoutingTable(root.global, "[global]") : undefined;
		fileConfig = { path, global: globalConfig, models };
		log(
			`config file loaded: ${path} global=${JSON.stringify(globalConfig)} ` +
				`models=${JSON.stringify([...models.entries()])}`,
		);
	} catch (error) {
		fileConfigError = `${path}: ${error instanceof Error ? error.message : String(error)}`;
		log(`config file ignored (${fileConfigError})`);
	}
}

type ConfigScope = "model" | "global" | "none";

/**
 * The routing configuration that applies to `modelId`: the model-specific
 * table when one exists, with each key it omits inherited from the global
 * table; otherwise the global table; otherwise nothing.
 */
function resolveConfig(modelId: string | undefined): { scope: ConfigScope; config?: ProviderRoutingConfig } {
	if (!fileConfig || !modelId) return { scope: "none" };
	const modelSpecific = fileConfig.models.get(modelId);
	if (modelSpecific) {
		return {
			scope: "model",
			config: {
				preferred: modelSpecific.preferred ?? fileConfig.global?.preferred ?? [],
				blacklist: modelSpecific.blacklist ?? fileConfig.global?.blacklist ?? [],
			},
		};
	}
	if (fileConfig.global) {
		return {
			scope: "global",
			config: { preferred: fileConfig.global.preferred ?? [], blacklist: fileConfig.global.blacklist ?? [] },
		};
	}
	return { scope: "none" };
}

/**
 * The effective ignore list for automatic mode: config ∪ session blacklist.
 * Entries are injected exactly as configured — unknown slugs are reported
 * (see warnUnknownSlugs) instead of rewritten.
 */
function effectiveIgnore(modelId: string | undefined): string[] {
	const configured = resolveConfig(modelId).config?.blacklist ?? [];
	return [...new Set([...configured, ...blacklist])];
}

let slugAliasPrefetch: Promise<void> | undefined;

/**
 * (Re-)fetch the endpoints of the active model to (re-)learn the known
 * routing slugs. Concurrent calls share one request; the endpoints cache
 * keeps repeats cheap. Never throws.
 */
function prefetchSlugAliases(ctx: ExtensionContext): Promise<void> {
	if (!slugAliasPrefetch) {
		slugAliasPrefetch = getEndpoints(ctx)
			.then((endpoints) => {
				learnKnownSlugs(ctx.model?.id, endpoints);
				// Now that the routing slugs are known, configured entries that
				// match none of them can be flagged (they would be silently
				// ignored by OpenRouter otherwise).
				warnConfiguredSlugs(ctx);
				// The validated ignore list (and therefore its reported count)
				// may be final only now.
				renderStatus(ctx);
			})
			.catch((error) => log(`slug prefetch failed: ${String(error)}`))
			.finally(() => {
				slugAliasPrefetch = undefined;
			});
	}
	return slugAliasPrefetch;
}

/**
 * Make sure slug validation has the endpoints API's slugs available: wait for
 * an in-flight (or freshly started) prefetch, at most briefly, so a request
 * can never be delayed significantly.
 */
async function ensureSlugAliases(ctx: ExtensionContext): Promise<void> {
	if (knownSlugs.size > 0) return;
	await Promise.race([prefetchSlugAliases(ctx), sleep(4000)]);
}

/**
 * Ask the OpenRouter generation endpoint which upstream provider served a
 * completed generation. The record is written slightly after the response
 * arrives, so retry a few times with a backoff.
 */
async function lookupProviderName(base: string, apiKey: string | undefined, generationId: string): Promise<string | undefined> {
	const url = `${base}/generation?id=${encodeURIComponent(generationId)}`;
	for (let attempt = 0; attempt < 6; attempt++) {
		try {
			const response = await fetch(url, {
				headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : {},
			});
			if (response.ok) {
				const json = (await response.json()) as { data?: { provider_name?: string } };
				const name = json?.data?.provider_name;
				if (typeof name === "string" && name.length > 0) return name;
			}
		} catch (error) {
			log(`generation lookup attempt ${attempt} failed: ${String(error)}`);
		}
		await sleep(500 * (attempt + 1));
	}
	return undefined;
}

function setDetected(ctx: ExtensionContext, name: string): void {
	if (lastDetected !== name) log(`detected upstream provider: ${name}`);
	lastDetected = name;
	renderStatus(ctx);
}

/** Called from the background stream tap, which has no live context. */
function onProviderDetected(name: string): void {
	if (lastDetected === name) return;
	lastDetected = name;
	statusDirty = true;
	log(`stream tap detected upstream provider: ${name}`);
}

/** Re-render the footer once the endpoints (costs/precision) have loaded. */
function onEndpointsLoaded(ctx: ExtensionContext): void {
	if (lastDetected) renderStatus(ctx);
}

/**
 * Read an OpenRouter SSE body in parallel with the provider, pulling the
 * `provider` field out of the chat-completion events (every event carries it).
 * SSE framing (line buffering, BOM/CR handling, multi-line data) is delegated
 * to the eventsource-parser runtime dependency. The tap stream is consumed and
 * discarded; the forward stream is handed back to the SDK untouched.
 */
function tapSseStream(stream: ReadableStream<Uint8Array>, onProvider: (name: string) => void): void {
	void (async () => {
		try {
			const events = stream
				.pipeThrough(new TextDecoderStream())
				.pipeThrough(new EventSourceParserStream())
				.getReader();
			for (;;) {
				const { done, value } = await events.read();
				if (done) break;
				const data: string = value.data;
				if (!data || data === "[DONE]") continue;
				try {
					const chunk = JSON.parse(data) as { provider?: unknown };
					if (typeof chunk.provider === "string" && chunk.provider) onProvider(chunk.provider);
				} catch {
					/* not JSON; ignore */
				}
			}
		} catch (error) {
			log(`stream tap ended early: ${String(error)}`);
		}
	})();
}

function makeTapFetch(
	baseFetch: typeof globalThis.fetch,
	onProvider: (name: string) => void,
): typeof globalThis.fetch {
	return async (input, init) => {
		const response = await baseFetch(input, init);
		try {
			const contentType = response.headers.get("content-type") ?? "";
			if (response.body && contentType.includes("text/event-stream")) {
				const [forward, tap] = response.body.tee();
				tapSseStream(tap, onProvider);
				return new Response(forward, {
					status: response.status,
					statusText: response.statusText,
					headers: response.headers,
				});
			}
		} catch (error) {
			log(`could not tap response stream: ${String(error)}`);
		}
		return response;
	};
}

/**
 * Wrap the effective OpenRouter provider so that its HTTP fetch is tapped for
 * the upstream `provider` field. Everything else (auth, model list, payload
 * and response hooks) is delegated to the original provider.
 */
function installStreamTap(pi: ExtensionAPI, ctx: ExtensionContext): void {
	if (tapInstalled) return;
	const original = ctx.modelRegistry.getProvider("openrouter") as Provider | undefined;
	if (!original) {
		log("stream tap: openrouter provider not found");
		return;
	}
	const withTap = <T>(options: T | undefined): T => {
		const base = (options ?? {}) as { fetch?: typeof globalThis.fetch };
		return {
			...base,
			fetch: makeTapFetch(base.fetch ?? globalThis.fetch, onProviderDetected),
		} as T;
	};
	const wrapped: Provider = {
		...original,
		stream: (model, context, options) => original.stream(model, context, withTap(options)),
		streamSimple: (model, context, options) => original.streamSimple(model, context, withTap(options)),
	};
	pi.registerProvider(wrapped);
	tapInstalled = true;
	log("stream tap installed for provider openrouter");
}

async function getEndpoints(ctx: ExtensionContext): Promise<EndpointInfo[]> {
	const model = ctx.model;
	const base = openRouterBase(model);
	if (!model || !base) return [];
	const now = Date.now();
	if (endpointsCache && endpointsCache.modelId === model.id && now - endpointsCache.fetchedAt < 5 * 60_000) {
		return endpointsCache.endpoints;
	}
	const url = `${base}/models/${model.id}/endpoints`;
	const response = await fetch(url, { signal: ctx.signal });
	if (!response.ok) throw new Error(`OpenRouter endpoints request failed: HTTP ${response.status}`);
	const json = (await response.json()) as { data?: { endpoints?: unknown[] } };
	const endpoints = parseEndpoints(json);
	learnKnownSlugs(model.id, endpoints);
	endpointsCache = { modelId: model.id, fetchedAt: now, endpoints };
	// Costs and precision for the serving provider may now be known; refresh
	// the footer status if it is already showing a detected provider.
	onEndpointsLoaded(ctx);
	return endpoints;
}

function numberOf(value: unknown): number | undefined {
	const n = typeof value === "string" ? Number(value) : typeof value === "number" ? value : Number.NaN;
	return Number.isFinite(n) ? n : undefined;
}

function parseEndpoints(json: { data?: { endpoints?: unknown[] } }): EndpointInfo[] {
	const raw = json?.data?.endpoints;
	if (!Array.isArray(raw)) return [];
	const bySlug = new Map<string, EndpointInfo>();
	for (const item of raw) {
		const e = item as Record<string, any>;
		const tag = typeof e.tag === "string" ? e.tag : "";
		const name = typeof e.provider_name === "string" ? e.provider_name : tag;
		const slug = (tag.split("/")[0] || name || "").trim().toLowerCase();
		if (!slug) continue;
		const info: EndpointInfo = {
			slug,
			tag,
			name,
			promptPrice: numberOf(e?.pricing?.prompt),
			completionPrice: numberOf(e?.pricing?.completion),
			contextLength: numberOf(e?.context_length),
			quantization: typeof e.quantization === "string" ? e.quantization : undefined,
			uptime: numberOf(e?.uptime_last_30m),
		};
		const previous = bySlug.get(slug);
		// Prefer the cheapest endpoint for a provider; break ties on uptime.
		if (!previous || cheaper(info, previous)) bySlug.set(slug, info);
	}
	return [...bySlug.values()].sort((a, b) => (a.promptPrice ?? Number.POSITIVE_INFINITY) - (b.promptPrice ?? Number.POSITIVE_INFINITY));
}

function cheaper(a: EndpointInfo, b: EndpointInfo): boolean {
	const ap = a.promptPrice ?? Number.POSITIVE_INFINITY;
	const bp = b.promptPrice ?? Number.POSITIVE_INFINITY;
	if (ap !== bp) return ap < bp;
	return (a.uptime ?? 0) > (b.uptime ?? 0);
}

function fmtPrice(value: number | undefined): string {
	if (value === undefined) return "?";
	const perMillion = value * 1_000_000;
	if (perMillion >= 100) return perMillion.toFixed(0);
	if (perMillion >= 10) return perMillion.toFixed(1);
	return perMillion.toFixed(2);
}

/**
 * The precision (quantization) the model is served with at this endpoint,
 * rendered as a label suffix. Empty when OpenRouter does not report a known
 * quantization for the endpoint.
 */
function precisionTag(endpoint: EndpointInfo): string {
	if (!endpoint.quantization || endpoint.quantization === "unknown") return "";
	return ` [${endpoint.quantization}]`;
}

function priceTag(endpoint: EndpointInfo): string {
	if (endpoint.promptPrice === undefined && endpoint.completionPrice === undefined) return "";
	const uptime = endpoint.uptime !== undefined ? `, up ${endpoint.uptime.toFixed(1)}%` : "";
	return ` — $${fmtPrice(endpoint.promptPrice)}/M in, $${fmtPrice(endpoint.completionPrice)}/M out${uptime}`;
}

/**
 * The endpoints record of the currently serving upstream provider
 * (lastDetected), matched case-insensitively against the display name,
 * routing slug, and raw endpoint tag of the active model's endpoints.
 * Undefined when the endpoints data has not been fetched (yet) or the
 * detected name matches none of the model's endpoints.
 */
function detectedEndpoint(): EndpointInfo | undefined {
	if (!lastDetected || !endpointsCache) return undefined;
	const key = lastDetected.trim().toLowerCase();
	return endpointsCache.endpoints.find(
		(endpoint) =>
			endpoint.name.toLowerCase() === key || endpoint.slug === key || endpoint.tag.toLowerCase() === key,
	);
}

/**
 * Footer status part for the serving upstream provider: the name, enriched —
 * when the model's endpoints data is available and matches the detected name —
 * with the provider's precision (quantization) and per-million-token costs,
 * e.g. `DeepInfra (fp8, $0.07/M in, $0.15/M out)`. The parentheses-free name
 * is shown when the endpoint (and thus costs/precision) is unknown. The part
 * deliberately contains no " · " separator, which the status line uses to
 * delimit its top-level parts.
 */
function detectedStatusPart(): string {
	if (!lastDetected) return "";
	const endpoint = detectedEndpoint();
	if (!endpoint) return lastDetected;
	const precision = precisionTag(endpoint).trim().replace(/^\[|\]$/g, "");
	const costs =
		endpoint.promptPrice !== undefined || endpoint.completionPrice !== undefined
			? `$${fmtPrice(endpoint.promptPrice)}/M in, $${fmtPrice(endpoint.completionPrice)}/M out`
			: "";
	const suffix = [precision, costs].filter(Boolean).join(", ");
	return suffix ? `${lastDetected} (${suffix})` : lastDetected;
}

function setBlacklist(next: string[], ctx: ExtensionContext, changed?: string, added?: boolean): void {
	blacklist = next;
	try {
		api?.appendEntry(BLACKLIST_ENTRY, { providers: blacklist });
	} catch (error) {
		log(`could not persist blacklist: ${String(error)}`);
	}
	renderStatus(ctx);
	if (changed) {
		ctx.ui.notify(
			added
				? `OpenRouter: blacklisted "${changed}" (excluded from automatic selection)`
				: `OpenRouter: un-blacklisted "${changed}" (automatic selection may use it again)`,
			"info",
		);
	}
	log(`blacklist set: ${JSON.stringify(blacklist)}`);
}

function setRouting(next: Routing, ctx: ExtensionContext): void {
	routing = next;
	try {
		api?.appendEntry(ROUTING_ENTRY, routing);
	} catch (error) {
		log(`could not persist routing: ${String(error)}`);
	}
	lastDetected = undefined;
	renderStatus(ctx);
	if (routing.mode === "pin" && routing.provider) {
		const fallbacks = routing.allowFallbacks ? "fallbacks allowed" : "no fallbacks";
		ctx.ui.notify(`OpenRouter: ${routing.provider} (${fallbacks})`, "info");
	} else {
		ctx.ui.notify("OpenRouter: automatic provider selection", "info");
	}
	log(`routing set: ${JSON.stringify(routing)}`);
}

/**
 * The interactive picker action: either pin an item (plain enter), or toggle
 * its blacklist state (shift+enter), or cancel (escape).
 */
type PickerAction = { kind: "pin"; slug?: string } | { kind: "toggle"; slug: string } | { kind: "cancel" };

/**
 * Interactive picker with toggle support (TUI mode only). Plain enter pins
 * the highlighted provider (or selects Auto); shift+enter toggles the
 * highlighted provider's blacklist state instead of selecting it.
 */
async function pickWithToggle(ctx: ExtensionCommandContext, endpoints: EndpointInfo[]): Promise<PickerAction> {
	return ctx.ui.custom<PickerAction>((tui, theme, _kb, done) => {
		const rows: { slug?: string; base: string }[] = [
			{ slug: undefined, base: "Auto — let OpenRouter decide" },
			...endpoints.map((endpoint) => ({
				slug: endpoint.slug,
				base: `${endpoint.name} (${endpoint.slug})${precisionTag(endpoint)}${priceTag(endpoint)}`,
			})),
		];
		const blocked = new Set(blacklist);
		let index = 0;
		return {
			render(width: number): string[] {
				const lines: string[] = [];
				lines.push(theme.fg("accent", theme.bold("OpenRouter upstream provider")));
				lines.push(theme.fg("dim", "enter pin · shift+enter blacklist-toggle · esc cancel"));
				rows.forEach((row, i) => {
					const cursor = i === index ? "→ " : "  ";
					const marker = row.slug && blocked.has(row.slug) ? "✗ " : "  ";
					let text = truncateToWidth(`${cursor}${marker}${row.base}`, width, "");
					if (row.slug && blocked.has(row.slug)) text = theme.fg("error", text);
					else if (i === index) text = theme.fg("accent", text);
					lines.push(text);
				});
				return lines;
			},
			invalidate(): void {},
			handleInput(data: string): void {
				if (matchesKey(data, "up")) {
					index = index === 0 ? rows.length - 1 : index - 1;
				} else if (matchesKey(data, "down")) {
					index = index === rows.length - 1 ? 0 : index + 1;
				} else if (matchesKey(data, "shift+enter")) {
					const row = rows[index];
					if (row?.slug) {
						if (blocked.has(row.slug)) blocked.delete(row.slug);
						else blocked.add(row.slug);
						done({ kind: "toggle", slug: row.slug });
						return;
					}
				} else if (matchesKey(data, "enter")) {
					done({ kind: "pin", slug: rows[index]?.slug });
					return;
				} else if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
					done({ kind: "cancel" });
					return;
				}
				tui.requestRender();
			},
		};
	});
}

async function pickProvider(ctx: ExtensionCommandContext): Promise<void> {
	const model = ctx.model;
	safeUi(ctx, (ui) => ui.setStatus(STATUS_KEY, "⇢ loading providers…"));
	let endpoints: EndpointInfo[] = [];
	try {
		endpoints = await getEndpoints(ctx);
	} catch (error) {
		ctx.ui.notify(`Could not list OpenRouter providers: ${String(error)}`, "error");
		renderStatus(ctx);
		return;
	}
	renderStatus(ctx);
	if (ctx.mode === "tui") {
		// Full picker with shift+enter blacklist toggling.
		const action = await pickWithToggle(ctx, endpoints);
		if (!action || action.kind === "cancel") return;
		if (action.kind === "pin") {
			if (action.slug) setRouting({ mode: "pin", provider: action.slug, allowFallbacks: false }, ctx);
			else setRouting({ mode: "auto" }, ctx);
			return;
		}
		// Toggle the highlighted provider's blacklist state.
		const slug = action.slug;
		if (blacklist.includes(slug)) {
			setBlacklist(
				blacklist.filter((s) => s !== slug),
				ctx,
				slug,
				false,
			);
		} else {
			setBlacklist([...blacklist, slug], ctx, slug, true);
		}
		return;
	}
	// Fallback (RPC / non-TUI): plain select menu, no toggling.
	const labels: string[] = ["Auto — let OpenRouter decide"];
	const slugs: (string | undefined)[] = [undefined];
	endpoints.forEach((endpoint, index) => {
		labels.push(
			`${index + 1}. ${blacklist.includes(endpoint.slug) ? "✗ " : ""}${endpoint.name} (${endpoint.slug})${precisionTag(endpoint)}${priceTag(endpoint)}`,
		);
		slugs.push(endpoint.slug);
	});
	const choice = await ctx.ui.select("OpenRouter upstream provider", labels);
	if (choice === undefined) return;
	const slug = slugs[labels.indexOf(choice)];
	if (slug) setRouting({ mode: "pin", provider: slug, allowFallbacks: false }, ctx);
	else setRouting({ mode: "auto" }, ctx);
}

async function listProviders(ctx: ExtensionCommandContext): Promise<void> {
	let endpoints: EndpointInfo[] = [];
	try {
		endpoints = await getEndpoints(ctx);
	} catch (error) {
		ctx.ui.notify(`Could not list OpenRouter providers: ${String(error)}`, "error");
		return;
	}
	if (endpoints.length === 0) {
		ctx.ui.notify("No OpenRouter endpoints found for the active model.", "warning");
		return;
	}
	const lines = endpoints
		.slice(0, 15)
		.map((endpoint, index) => `${index + 1}. ${endpoint.name} (${endpoint.slug})${precisionTag(endpoint)}${priceTag(endpoint)}`);
	ctx.ui.notify(`Providers for ${ctx.model?.id}:\n${lines.join("\n")}`, "info");
}

function describeRouting(modelId: string | undefined): string {
	if (routing.mode === "pin" && routing.provider) {
		return `pinned to "${routing.provider}"${routing.allowFallbacks ? " (fallbacks allowed)" : " (no fallbacks)"}`;
	}
	const bits: string[] = ["automatic (OpenRouter decides)"];
	const resolved = resolveConfig(modelId);
	if (resolved.config && (resolved.config.preferred.length > 0 || resolved.config.blacklist.length > 0)) {
		bits.push(`config ${resolved.scope} scope`);
		if (resolved.config.preferred.length > 0) bits.push(`preferred: ${resolved.config.preferred.join(", ")}`);
	}
	const ignore = effectiveIgnore(modelId);
	if (ignore.length > 0) bits.push(`blacklisted: ${ignore.join(", ")}`);
	if (fileConfigError) bits.push(`config file invalid (${fileConfigError})`);
	return bits.join(", ");
}

/**
 * The `/openrouter config` status view: the routing the configuration file
 * declares for the *current* model — the applicable scope, the preferred
 * provider order, and the blacklisted providers. Session state (the pin and
 * the interactive blacklist) is deliberately out of scope here; it is
 * reported by `/openrouter status` and `/openrouter blocked`.
 */
function showConfigStatus(ctx: ExtensionCommandContext): void {
	if (fileConfigError) {
		ctx.ui.notify(`Config file invalid, routing ignored:\n${fileConfigError}`, "warning");
		return;
	}
	if (!fileConfig) {
		ctx.ui.notify(
			"No configuration file: PI_OPENROUTER_EXTENSION_CONFIG_FILE is unset.",
			"info",
		);
		return;
	}
	const resolved = resolveConfig(ctx.model?.id);
	const header = `Config: ${fileConfig.path}`;
	if (resolved.scope === "none" || !resolved.config) {
		ctx.ui.notify(`${header}\nNo routing table applies to ${ctx.model?.id ?? "(no model)"}.`, "info");
		return;
	}
	const preferred =
		resolved.config.preferred.length > 0 ? resolved.config.preferred.join(", ") : "(none)";
	const blacklisted =
		resolved.config.blacklist.length > 0 ? resolved.config.blacklist.join(", ") : "(none)";
	ctx.ui.notify(
		`${header} (${resolved.scope} scope for ${ctx.model?.id})\n` +
			`Preferred providers: ${preferred}\n` +
			`Blacklisted providers: ${blacklisted}`,
		"info",
	);
}

async function handleOpenRouter(args: string, ctx: ExtensionCommandContext): Promise<void> {
	if (!isOpenRouterModel(ctx.model)) {
		ctx.ui.notify("The active model is not routed through OpenRouter.", "warning");
		return;
	}
	const trimmed = args.trim();
	if (trimmed === "" || trimmed === "pick" || trimmed === "choose") {
		await pickProvider(ctx);
		return;
	}
	const [subcommand, ...rest] = trimmed.split(/\s+/);
	switch (subcommand.toLowerCase()) {
		case "auto":
		case "off":
		case "reset":
			setRouting({ mode: "auto" }, ctx);
			return;
		case "status":
		case "info": {
			let configLine: string;
			if (fileConfigError) configLine = `Config: file invalid (${fileConfigError})`;
			else if (!fileConfig) configLine = "Config: no configuration file (PI_OPENROUTER_EXTENSION_CONFIG_FILE unset)";
			else {
				const resolved = resolveConfig(ctx.model?.id);
				configLine =
					resolved.scope === "none"
						? `Config: ${fileConfig.path} (no applicable routing)`
						: `Config: ${fileConfig.path} (${resolved.scope} scope)`;
			}
			ctx.ui.notify(
				`OpenRouter routing: ${describeRouting(ctx.model?.id)}.\n${configLine}\nLast served by: ${lastDetected ?? "(unknown)"}`,
				"info",
			);
			return;
		}
		case "list":
			await listProviders(ctx);
			return;
		case "block":
		case "blacklist": {
			const slugs = rest.map((s) => s.toLowerCase()).filter(Boolean);
			if (slugs.length === 0) {
				ctx.ui.notify("Usage: /openrouter block <provider-slug>…", "warning");
				return;
			}
			const next = [...new Set([...blacklist, ...slugs])];
			setBlacklist(next, ctx, slugs[0], true);
			return;
		}
		case "unblock":
		case "unblacklist": {
			const slugs = rest.map((s) => s.toLowerCase()).filter(Boolean);
			if (slugs.length === 0) {
				ctx.ui.notify("Usage: /openrouter unblock <provider-slug>…", "warning");
				return;
			}
			const next = blacklist.filter((s) => !slugs.includes(s));
			if (next.length === blacklist.length) {
				ctx.ui.notify(`OpenRouter: "${slugs[0]}" is not blacklisted`, "warning");
				return;
			}
			setBlacklist(next, ctx, slugs[0], false);
			return;
		}
		case "blocked":
		case "blacklisted":
			ctx.ui.notify(
				blacklist.length > 0
					? `Blacklisted providers (excluded from automatic selection):\n${blacklist.join("\n")}`
					: "No blacklisted providers.",
				"info",
			);
			return;
		case "config":
		case "routing":
			showConfigStatus(ctx);
			return;
		case "pin":
			if (!rest[0]) {
				ctx.ui.notify("Usage: /openrouter pin <provider-slug>", "warning");
				return;
			}
			setRouting({ mode: "pin", provider: rest[0].toLowerCase(), allowFallbacks: false }, ctx);
			return;
		case "prefer":
			if (!rest[0]) {
				ctx.ui.notify("Usage: /openrouter prefer <provider-slug>", "warning");
				return;
			}
			setRouting({ mode: "pin", provider: rest[0].toLowerCase(), allowFallbacks: true }, ctx);
			return;
		default:
			setRouting({ mode: "pin", provider: subcommand.toLowerCase(), allowFallbacks: false }, ctx);
			return;
	}
}

export default function (pi: ExtensionAPI): void {
	api = pi;
	pi.on("session_start", async (_event, ctx) => {
	loadConfigFile();
	const entries = ctx.sessionManager.getEntries();
		for (let i = entries.length - 1; i >= 0; i--) {
			const entry = entries[i] as { type?: string; customType?: string; data?: unknown };
			if (entry.type === "custom" && entry.customType === BLACKLIST_ENTRY) {
				blacklist = sanitizeBlacklist(entry.data);
				break;
			}
		}
		for (let i = entries.length - 1; i >= 0; i--) {
			const entry = entries[i] as { type?: string; customType?: string; data?: unknown };
			if (entry.type === "custom" && entry.customType === ROUTING_ENTRY) {
				routing = sanitizeRouting(entry.data);
				break;
			}
		}
		if (isOpenRouterModel(ctx.model)) {
			await ensureKey(ctx);
			installStreamTap(pi, ctx);
			prefetchSlugAliases(ctx);
		}
		renderStatus(ctx);
		log(`session start: model=${ctx.model?.id} routing=${JSON.stringify(routing)} blacklist=${JSON.stringify(blacklist)}`);
	});

	pi.on("model_select", async (_event, ctx) => {
		loadConfigFile();
		lastDetected = undefined;
		keyResolved = false;
		endpointsCache = undefined;
		if (isOpenRouterModel(ctx.model)) {
			await ensureKey(ctx);
			installStreamTap(pi, ctx);
			prefetchSlugAliases(ctx);
		}
		renderStatus(ctx);
	});

	// The stream tap fills in the provider name mid-stream; flush it to the
	// footer as soon as the agent loop yields an event with a live context.
	pi.on("message_update", (_event, ctx) => {
		if (!statusDirty) return;
		statusDirty = false;
		renderStatus(ctx);
	});
	pi.on("turn_end", (_event, ctx) => {
		if (!statusDirty) return;
		statusDirty = false;
		renderStatus(ctx);
	});

	pi.on("before_provider_request", async (event, ctx) => {
		if (!isOpenRouterModel(ctx.model)) return;
		log(
			`request: model=${ctx.model?.id} routing=${JSON.stringify(routing)} blacklist=${JSON.stringify(blacklist)} ` +
				`config=${fileConfig ? "loaded" : fileConfigError ? `invalid (${fileConfigError})` : "unset"}`,
		);
		const payload =
			event.payload && typeof event.payload === "object" ? (event.payload as Record<string, unknown>) : {};
		const existing =
			payload.provider && typeof payload.provider === "object"
				? (payload.provider as Record<string, unknown>)
				: {};
		if (routing.mode === "pin" && routing.provider) {
			await ensureSlugAliases(ctx);
			warnUnknownSlugs(ctx, [routing.provider], "pin");
			const provider: Record<string, unknown> = {
				...existing,
				only: [routing.provider],
				allow_fallbacks: routing.allowFallbacks ?? false,
			};
			delete provider.order;
			log(`injecting provider routing: ${JSON.stringify(provider)}`);
			return { ...payload, provider };
		}
		// Automatic (auto) selection mode: apply the declarative routing from the
		// configuration file (model-specific scope wins over the global one) and
		// keep both configured and interactively blacklisted providers away from
		// OpenRouter's choice via `provider.ignore`.
		const resolved = resolveConfig(ctx.model?.id);
		const order = resolved.config?.preferred ?? [];
		const ignore = effectiveIgnore(ctx.model?.id);
		if (order.length === 0 && ignore.length === 0) return;
		// Slug validation needs the routing slugs from the endpoints API; a
		// request that races the prefetch waits for it briefly (see above).
		await ensureSlugAliases(ctx);
		if (order.length > 0) warnUnknownSlugs(ctx, order, `${resolved.scope} config preferred`);
		warnUnknownSlugs(ctx, ignore, "effective blacklist");
		const provider: Record<string, unknown> = {
			...existing,
			allow_fallbacks: true,
		};
		delete provider.order;
		if (ignore.length > 0) provider.ignore = ignore;
		if (order.length > 0) provider.order = order;
		log(`injecting auto routing (config scope=${resolved.scope}): ${JSON.stringify(provider)}`);
		return { ...payload, provider };
	});

	pi.on("after_provider_response", (event, ctx) => {
		if (!isOpenRouterModel(ctx.model)) return;
		const headers = lowerHeaders(event.headers);
		const generationId = headers["x-generation-id"];
		const headerName = headers["x-provider-name"];
		const base = openRouterBase(ctx.model);
		log(`response: status=${event.status} generationId=${generationId} headerProvider=${headerName ?? ""}`);
		if (headerName) {
			setDetected(ctx, headerName);
			return;
		}
		// The fetch tap already reads the authoritative provider from the SSE
		// body for the built-in openrouter provider, so don't pay for a
		// generation lookup there (pinned generations are not queryable
		// anyway). Other OpenRouter-based providers still use the endpoint.
		if (tapInstalled && ctx.model?.provider === "openrouter") return;
		if (!base || !generationId) return;
		void (async () => {
			try {
				const apiKey = (await ensureKey(ctx)) ?? cachedKey;
				const name = await lookupProviderName(base, apiKey, generationId);
				if (name) setDetected(ctx, name);
			} catch (error) {
				log(`provider lookup failed: ${String(error)}`);
			}
		})();
	});

	const command = {
		description:
			"Show or change which upstream provider OpenRouter routes to (shift+enter in the picker toggles/blacklists a provider)",
		handler: handleOpenRouter,
	};
	pi.registerCommand("openrouter", command);
	pi.registerCommand("or", command);
}