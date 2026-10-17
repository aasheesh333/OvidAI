import { money, type Money } from "@ovid/money";
import type { MintEnv } from "../env.js";

/**
 * Direct JSON image-edit transport for [OI]-compatible providers (InferHub) —
 * port of server/images/directedit.py.
 *
 * LiteLLM can only forward edits as multipart/form-data; the provider's
 * documented edit endpoint is application/json with a single `image` data URL.
 * The gateway therefore calls the provider directly, but ONLY for a discovered
 * `api_base` (never user input) that is a plain https URL on an allowlisted
 * host. The provider key lives exclusively in the Authorization header.
 */

export const DEFAULT_DIRECT_EDIT_HOSTS = "api.inferhub.dev";

export interface DirectEditTarget {
  url: string;
  model: string;
}

export interface DirectEditResponse {
  status: number;
  headers: Record<string, string>;
  json(): Promise<unknown>;
  /** Raw body, for error classification when the provider did not send JSON. */
  text(): Promise<string>;
}

export interface DirectEdit {
  readonly hasKey: boolean;
  target(params: Record<string, unknown> | null | undefined): DirectEditTarget | null;
  enabled_for(params: Record<string, unknown> | null | undefined): boolean;
  post(
    params: Record<string, unknown> | null | undefined,
    prompt: string,
    size: string,
    imageDataUrl: string,
  ): Promise<DirectEditResponse>;
  settlementCost(responseJson: unknown, bound: Money): Money;
}

export interface DirectEditOptions {
  fetchImpl?: typeof fetch;
  maxUpstreamCost?: Money;
  /** Per-request timeout; Python's httpx.Client uses 120 s. */
  timeoutMs?: number;
}

export const DEFAULT_DIRECT_EDIT_TIMEOUT_MS = 120_000;

/** `openai/cb/gpt-image-2` -> `cb/gpt-image-2` (only a leading openai/). */
export function providerModelId(litellmModel: unknown): string | null {
  if (typeof litellmModel !== "string") return null;
  const model = litellmModel.startsWith("openai/")
    ? litellmModel.slice("openai/".length)
    : litellmModel;
  return model === "" ? null : model;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function headersRecord(
  headers: Headers | Record<string, string> | undefined,
): Record<string, string> {
  const out: Record<string, string> = {};
  if (headers === undefined) return out;
  if (typeof (headers as Headers).forEach === "function") {
    (headers as Headers).forEach((value, key) => {
      out[key.toLowerCase()] = value;
    });
    return out;
  }
  for (const [key, value] of Object.entries(headers as Record<string, string>)) {
    out[key.toLowerCase()] = value;
  }
  return out;
}

function parseEditCost(raw: string | null | undefined): Money | null {
  const text = (raw ?? "").trim();
  if (text === "") return null;
  try {
    const value = money(text);
    return value.greaterThan(0) ? value : null;
  } catch {
    return null;
  }
}

class HttpDirectEdit implements DirectEdit {
  private readonly key: string;
  private readonly hosts: Set<string>;
  private readonly editCost: Money | null;
  private readonly bound: Money;
  private readonly fetchImpl: typeof fetch;
  private readonly timeoutMs: number;

  constructor(env: MintEnv, opts: DirectEditOptions = {}) {
    this.key = (env.images.inferhubApiKey ?? "").trim();
    this.hosts = new Set(
      (env.images.directEditHosts || DEFAULT_DIRECT_EDIT_HOSTS)
        .split(",")
        .map((host) => host.trim().toLowerCase())
        .filter((host) => host !== ""),
    );
    this.editCost = parseEditCost(env.images.editCostUsd);
    const fallback =
      env.images.maxUpstreamCostUsd !== null && env.images.maxUpstreamCostUsd !== undefined
        ? (() => {
            try {
              return money(env.images.maxUpstreamCostUsd);
            } catch {
              return money("1.00");
            }
          })()
        : money("1.00");
    this.bound = opts.maxUpstreamCost ?? fallback;
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_DIRECT_EDIT_TIMEOUT_MS;
  }

  get hasKey(): boolean {
    return this.key !== "";
  }

  target(params: Record<string, unknown> | null | undefined): DirectEditTarget | null {
    if (!this.hasKey) return null;
    const values = params ?? {};
    const base = values.api_base;
    const model = providerModelId(values.model);
    if (typeof base !== "string" || base === "" || model === null) return null;

    let parsed: URL;
    try {
      parsed = new URL(base.trim());
    } catch {
      return null;
    }
    const host = parsed.hostname.toLowerCase();
    const port = parsed.port;
    if (
      parsed.protocol !== "https:" ||
      parsed.username !== "" ||
      parsed.password !== "" ||
      parsed.search !== "" ||
      parsed.hash !== "" ||
      (port !== "" && port !== "443") ||
      host === ""
    ) {
      return null;
    }
    if (!this.hosts.has(host)) return null;
    const path = parsed.pathname.replace(/\/+$/, "");
    return { url: `https://${host}${path}/images/edits`, model };
  }

  enabled_for(params: Record<string, unknown> | null | undefined): boolean {
    return this.target(params) !== null;
  }

  async post(
    params: Record<string, unknown> | null | undefined,
    prompt: string,
    size: string,
    imageDataUrl: string,
  ): Promise<DirectEditResponse> {
    const target = this.target(params);
    if (target === null) throw new Error("direct edit not enabled");
    const body = {
      model: target.model,
      prompt,
      size,
      n: 1,
      response_format: "b64_json",
      image: imageDataUrl,
    };
    const response = await this.fetchImpl(target.url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.key}`,
        // The provider contract is JSON-only. A string body without an
        // explicit content-type makes undici send text/plain, which the
        // provider rejects (directedit.py sends httpx `json=`).
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify(body),
      redirect: "manual",
      // A silent provider must not pin the request (and its reservation)
      // forever; aborting surfaces as a transport failure -> unknown.
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    return {
      status: response.status,
      headers: headersRecord(response.headers),
      json: () => response.json(),
      text: () => response.text(),
    };
  }

  settlementCost(responseJson: unknown, bound: Money): Money {
    const cap = bound.lessThan(this.bound) ? bound : this.bound;
    const flat = this.editCost !== null && this.editCost.lessThan(cap) ? this.editCost : cap;
    try {
      const usage = isPlainObject(responseJson) ? responseJson.usage : undefined;
      const raw = isPlainObject(usage) ? usage.cost : undefined;
      if (typeof raw === "number" || typeof raw === "string") {
        const value = money(raw);
        if (value.greaterThan(0)) return value.greaterThan(cap) ? cap : value;
      }
    } catch {
      // invalid provider cost -> flat
    }
    return flat;
  }
}

export function createDirectEdit(env: MintEnv, opts: DirectEditOptions = {}): DirectEdit {
  return new HttpDirectEdit(env, opts);
}
