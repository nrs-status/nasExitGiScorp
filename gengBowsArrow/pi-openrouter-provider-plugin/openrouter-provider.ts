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
 *      footer status area (e.g. `⇢ DeepInfra`). The name is read from the
 *      streamed response itself: the OpenRouter chat-completions SSE chunks
 *      carry a `provider` field, which is captured by tapping the provider
 *      HTTP fetch. As a fallback (and for non-`openrouter` providers whose
 *      base URL points at OpenRouter) the `X-Provider-Name` header or the
 *      generation endpoint (`GET /api/v1/generation?id=<x-generation-id>`)
 *      is used.
 *   3. Lets the user interactively pin / prefer an upstream provider via the
 *      `/openrouter` command. The selection is injected into the outgoing
 *      request as the OpenRouter `provider` routing field, and persisted in
 *      the session so it survives resumption.
 *
 * Usage:
 *   pi -e ./openrouter-provider.ts
 *
 * Commands:
 *   /openrouter                      interactive provider picker
 *   /openrouter auto                 release the pin (OpenRouter decides)
 *   /openrouter status               show current routing + last seen provider
 *   /openrouter list                 list providers serving the active model
 *   /openrouter pin <slug>           force <slug>, disallow fallbacks
 *   /openrouter prefer <slug>        try <slug> first, allow fallbacks
 *   /openrouter <slug>               shorthand for `pin <slug>`
 *
 * Debugging: set PI_OPENROUTER_PROVIDER_LOG=/path/to/log to append a trace.
 */

import { appendFileSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import type { Provider } from "@earendil-works/pi-ai";

const STATUS_KEY = "openrouter-provider";
const ROUTING_ENTRY = "openrouter-routing";
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
let lastDetected: string | undefined;
let statusDirty = false;
let cachedKey: string | undefined;
let keyResolved = false;
let tapInstalled = false;
let api: ExtensionAPI | undefined;
let endpointsCache: { modelId: string; fetchedAt: number; endpoints: EndpointInfo[] } | undefined;

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
	if (lastDetected) parts.push(lastDetected);
	if (routing.mode === "pin" && routing.provider) parts.push(`pin:${routing.provider}`);
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

/**
 * Read an OpenRouter SSE body in parallel with the provider, pulling the
 * `provider` field out of the chat-completion chunks (every chunk carries it).
 * The tap stream is consumed and discarded; the forward stream is handed back
 * to the SDK untouched.
 */
function tapSseStream(stream: ReadableStream<Uint8Array>, onProvider: (name: string) => void): void {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let buffer = "";
	void (async () => {
		try {
			for (;;) {
				const { done, value } = await reader.read();
				if (done) break;
				buffer += decoder.decode(value, { stream: true });
				let newline: number;
				while ((newline = buffer.indexOf("\n")) >= 0) {
					const line = buffer.slice(0, newline).trim();
					buffer = buffer.slice(newline + 1);
					if (!line.startsWith("data:")) continue;
					const data = line.slice(5).trim();
					if (!data || data === "[DONE]") continue;
					try {
						const chunk = JSON.parse(data) as { provider?: unknown };
						if (typeof chunk.provider === "string" && chunk.provider) onProvider(chunk.provider);
					} catch {
						/* not JSON; ignore */
					}
				}
				// Guard against a pathological body producing an unbounded buffer.
				if (buffer.length > 1_000_000) buffer = buffer.slice(-10_000);
			}
		} catch (error) {
			log(`stream tap ended early: ${String(error)}`);
		} finally {
			try {
				reader.releaseLock();
			} catch {
				/* ignore */
			}
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
	endpointsCache = { modelId: model.id, fetchedAt: now, endpoints };
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

function priceTag(endpoint: EndpointInfo): string {
	if (endpoint.promptPrice === undefined && endpoint.completionPrice === undefined) return "";
	const uptime = endpoint.uptime !== undefined ? `, up ${endpoint.uptime.toFixed(1)}%` : "";
	return ` — $${fmtPrice(endpoint.promptPrice)}/M in, $${fmtPrice(endpoint.completionPrice)}/M out${uptime}`;
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
	const labels: string[] = ["Auto — let OpenRouter decide"];
	const slugs: (string | undefined)[] = [undefined];
	endpoints.forEach((endpoint, index) => {
		labels.push(`${index + 1}. ${endpoint.name} (${endpoint.slug})${priceTag(endpoint)}`);
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
		.map((endpoint, index) => `${index + 1}. ${endpoint.name} (${endpoint.slug})${priceTag(endpoint)}`);
	ctx.ui.notify(`Providers for ${ctx.model?.id}:\n${lines.join("\n")}`, "info");
}

function describeRouting(): string {
	if (routing.mode === "pin" && routing.provider) {
		return `pinned to "${routing.provider}"${routing.allowFallbacks ? " (fallbacks allowed)" : " (no fallbacks)"}`;
	}
	return "automatic (OpenRouter decides)";
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
		case "info":
			ctx.ui.notify(
				`OpenRouter routing: ${describeRouting()}.\nLast served by: ${lastDetected ?? "(unknown)"}`,
				"info",
			);
			return;
		case "list":
			await listProviders(ctx);
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
		const entries = ctx.sessionManager.getEntries();
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
		}
		renderStatus(ctx);
		log(`session start: model=${ctx.model?.id} routing=${JSON.stringify(routing)}`);
	});

	pi.on("model_select", async (_event, ctx) => {
		lastDetected = undefined;
		keyResolved = false;
		endpointsCache = undefined;
		if (isOpenRouterModel(ctx.model)) {
			await ensureKey(ctx);
			installStreamTap(pi, ctx);
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

	pi.on("before_provider_request", (event, ctx) => {
		if (!isOpenRouterModel(ctx.model)) return;
		log(`request: model=${ctx.model?.id} routing=${JSON.stringify(routing)}`);
		if (routing.mode !== "pin" || !routing.provider) return;
		const payload =
			event.payload && typeof event.payload === "object" ? (event.payload as Record<string, unknown>) : {};
		const existing =
			payload.provider && typeof payload.provider === "object"
				? (payload.provider as Record<string, unknown>)
				: {};
		const provider: Record<string, unknown> = {
			...existing,
			only: [routing.provider],
			allow_fallbacks: routing.allowFallbacks ?? false,
		};
		delete provider.order;
		log(`injecting provider routing: ${JSON.stringify(provider)}`);
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
		description: "Show or change which upstream provider OpenRouter routes to",
		handler: handleOpenRouter,
	};
	pi.registerCommand("openrouter", command);
	pi.registerCommand("or", command);
}