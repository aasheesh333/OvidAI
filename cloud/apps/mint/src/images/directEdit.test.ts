import { describe, expect, it } from "vitest";
import { money, type Money } from "@ovid/money";
import type { MintEnv } from "../env.js";
import { createDirectEdit, providerModelId } from "./directEdit.js";

/**
 * Port of server/images/tests/test_direct_edit.py (SSRF + settlement half).
 * Fakes only: no provider or LiteLLM request ever leaves the process.
 */

const KEY = "sk-inferhub-SECRET-0123456789";
const BASE = "https://api.inferhub.dev/v1";
const MODEL = "cb/gpt-image-2";

function envWith(images: Partial<MintEnv["images"]> = {}): MintEnv {
  return {
    images: {
      maxUpstreamCostUsd: null,
      inferhubApiKey: KEY,
      directEditHosts: "api.inferhub.dev",
      editCostUsd: null,
      probeKey: null,
      probeMaxUsd: 0.5,
      probeDailyUsd: 5,
      probeTtlS: 604800,
      probeStaggerS: 30,
      probeMaxSizes: 4,
      ...images,
    },
  } as unknown as MintEnv;
}

interface Seen {
  url: string;
  init: RequestInit;
}

function response(status: number, body: unknown): {
  status: number;
  headers: Record<string, string>;
  json(): Promise<unknown>;
} {
  return {
    status,
    headers: {},
    json: async () => body,
  };
}

describe("DirectEdit (port of directedit.py)", () => {
  it("maps provider model ids (only a leading openai/)", () => {
    expect(providerModelId("openai/cb/gpt-image-2")).toBe("cb/gpt-image-2");
    expect(providerModelId("cb/gemini-2.5-flash-image")).toBe("cb/gemini-2.5-flash-image");
    expect(providerModelId(undefined)).toBeNull();
    expect(providerModelId("openai/")).toBeNull();
  });

  it("only allows allowlisted plain https hosts and never follows redirects", async () => {
    const seen: Seen[] = [];
    const direct = createDirectEdit(envWith(), {
      maxUpstreamCost: money("1.00"),
      fetchImpl: (async (url: string | URL | Request, init?: RequestInit) => {
        seen.push({ url: String(url), init: init ?? {} });
        return response(302, {});
      }) as unknown as typeof fetch,
    });

    expect(direct.target({ model: `openai/${MODEL}`, api_base: BASE })).toEqual({
      url: "https://api.inferhub.dev/v1/images/edits",
      model: MODEL,
    });

    for (const base of [
      "http://api.inferhub.dev/v1",
      "https://evil.example/v1",
      "https://api.inferhub.dev.evil.io/v1",
      "https://user:pw@api.inferhub.dev/v1",
      "https://api.inferhub.dev:8443/v1",
      "https://api.inferhub.dev/v1?x=1",
      "https://api.inferhub.dev/v1#frag",
      "https://169.254.169.254/v1",
      "ftp://api.inferhub.dev",
      "",
      null,
      "https://",
    ]) {
      expect(direct.target({ model: `openai/${MODEL}`, api_base: base }), String(base)).toBeNull();
    }
    expect(direct.target({ api_base: BASE })).toBeNull();
    expect(direct.enabled_for({})).toBe(false);

    await direct.post({ model: `openai/${MODEL}`, api_base: BASE }, "p", "1024x1024", "data:image/png;base64,AA==");
    expect(seen).toHaveLength(1);
    expect(seen[0]!.url).toBe("https://api.inferhub.dev/v1/images/edits");
    expect(seen[0]!.init.redirect).toBe("manual");
  });

  it("honours a custom allowlist and refuses without a key", () => {
    const other = createDirectEdit(envWith({ directEditHosts: "edge.example.com , api.inferhub.dev" }), {
      maxUpstreamCost: money("1.00"),
    });
    expect(other.enabled_for({ model: "openai/m", api_base: "https://edge.example.com/v1" })).toBe(true);
    const missing = createDirectEdit(envWith({ inferhubApiKey: "  " }), { maxUpstreamCost: money("1.00") });
    expect(missing.hasKey).toBe(false);
    expect(missing.enabled_for({ model: "openai/m", api_base: BASE })).toBe(false);
  });

  it("posts the documented JSON shape with the key only in Authorization", async () => {
    const seen: Seen[] = [];
    const direct = createDirectEdit(envWith(), {
      maxUpstreamCost: money("1.00"),
      fetchImpl: (async (url: string | URL | Request, init?: RequestInit) => {
        seen.push({ url: String(url), init: init ?? {} });
        return response(200, { data: [] });
      }) as unknown as typeof fetch,
    });

    await direct.post(
      { model: `openai/${MODEL}`, api_base: BASE },
      "make it blue",
      "1024x1024",
      "data:image/png;base64,AA==",
    );

    expect(seen).toHaveLength(1);
    expect(seen[0]!.url).toBe("https://api.inferhub.dev/v1/images/edits");
    const headers = seen[0]!.init.headers as Record<string, string>;
    expect(headers.Authorization).toBe(`Bearer ${KEY}`);
    // The provider contract is JSON-only. Without this explicit header undici
    // sends text/plain and every edit is rejected (Python asserts the same).
    expect(headers["content-type"]).toBe("application/json");
    expect(seen[0]!.init.signal).toBeInstanceOf(AbortSignal);
    expect(JSON.stringify(headers)).not.toContain("sk-LITELLM");
    expect(JSON.parse(String(seen[0]!.init.body))).toEqual({
      model: MODEL,
      prompt: "make it blue",
      size: "1024x1024",
      n: 1,
      response_format: "b64_json",
      image: "data:image/png;base64,AA==",
    });
  });

  it("aborts a silent provider after the configured timeout", async () => {
    const direct = createDirectEdit(envWith(), {
      maxUpstreamCost: money("1.00"),
      timeoutMs: 20,
      fetchImpl: ((_url: string | URL | Request, init?: RequestInit) =>
        new Promise((_resolve, reject) => {
          const signal = init?.signal;
          if (signal === null || signal === undefined) {
            reject(new Error("missing abort signal"));
            return;
          }
          signal.addEventListener("abort", () => reject(signal.reason));
        })) as typeof fetch,
    });

    await expect(
      direct.post(
        { model: `openai/${MODEL}`, api_base: BASE },
        "make it blue",
        "1024x1024",
        "data:image/png;base64,AA==",
      ),
    ).rejects.toMatchObject({ name: "TimeoutError" });
  });

  it("settles provider usage.cost when usable, capped by the bound", () => {
    const direct = createDirectEdit(envWith({ editCostUsd: "0.04" }), {
      maxUpstreamCost: money("1.00"),
    });
    expect(direct.settlementCost({ usage: { cost: 0.02 } }, money("1.00")).equals(money("0.02"))).toBe(true);
    expect(direct.settlementCost({ usage: { cost: "0.5" } }, money("1.00")).equals(money("0.5"))).toBe(true);
    expect(direct.settlementCost({ usage: { cost: 99 } }, money("1.00")).equals(money("1"))).toBe(true);
    // Missing / invalid usage falls back to the flat configured price.
    expect(direct.settlementCost({ data: [] }, money("1.00")).equals(money("0.04"))).toBe(true);
    expect(direct.settlementCost({ usage: { cost: "nan" } }, money("1.00")).equals(money("0.04"))).toBe(true);
    expect(direct.settlementCost({ usage: { cost: -1 } }, money("1.00")).equals(money("0.04"))).toBe(true);
    expect(direct.settlementCost({ usage: { cost: true } }, money("1.00")).equals(money("0.04"))).toBe(true);
  });

  it("defaults the flat price to the bound, caps an oversized edit cost, and ignores garbage", () => {
    const unbounded = createDirectEdit(envWith(), { maxUpstreamCost: money("1.00") });
    expect(unbounded.settlementCost({}, money("1.00")).equals(money("1"))).toBe(true);

    const capped = createDirectEdit(envWith({ editCostUsd: "5" }), { maxUpstreamCost: money("1.00") });
    expect(capped.settlementCost({}, money("1.00")).equals(money("1"))).toBe(true);

    const bad = createDirectEdit(envWith({ editCostUsd: "abc" }), { maxUpstreamCost: money("1.00") });
    expect(bad.settlementCost({}, money("1.00")).equals(money("1"))).toBe(true);

    const zero = createDirectEdit(envWith({ editCostUsd: "0" }), { maxUpstreamCost: money("1.00") });
    expect(zero.settlementCost({}, money("1.00")).equals(money("1"))).toBe(true);
  });

  it("never settles above the owner bound", () => {
    const direct = createDirectEdit(envWith({ editCostUsd: "0.04" }), {
      maxUpstreamCost: money("0.03"),
    });
    const value: Money = direct.settlementCost({ usage: { cost: "0.5" } }, money("0.03"));
    expect(value.equals(money("0.03"))).toBe(true);
  });
});
