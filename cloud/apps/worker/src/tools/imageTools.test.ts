import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { verifyInternalRequest } from "@ovid/shared";
import type { SandboxHandle } from "@ovid/sandbox";
import type { ToolContext } from "./types.js";
import { createToolRegistry } from "./registry.js";
import {
  EDITS_PATH,
  GENERATIONS_PATH,
  createImageTools,
  createInternalImageClient,
  modelsFor,
  parseImageCapabilities,
  type ImageArtifactInput,
  type ImageCall,
  type ImageCallResult,
  type ImageCapabilities,
} from "./imageTools.js";

/**
 * W8 — generate_image / edit_image.
 *
 * The provider is stubbed (no paid calls): a fake `ImageCall` returns the
 * exact public response shape. Tests cover capability routing, artifact
 * creation, quota blocking and the vision guard. The internal HTTP client is
 * covered separately (HMAC + body shape).
 */

const PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const PNG_BYTES = Buffer.from(PNG_B64, "base64");
const SECRET = "test-internal-secret-0123456789abcdef";
const TS = 1_700_000_000;

function capsBody() {
  return {
    model: "ovid-image",
    catalog_hash: "a".repeat(32),
    operations: { generate: ["1024x1024"], edit: ["1024x1024"] },
    models: [
      {
        slug: "ovid-image:img-one",
        operations: { generate: {}, edit: {} },
        sizes: ["1024x1024"],
        aspect_ratios: ["1:1"],
        input: { max_images: 1 },
        output_formats: ["png"],
        text_rendering: "good",
        quality: "high",
        speed: "fast",
        latency_p50_s: 4,
        cost_tier: "low",
        verified: true,
      },
      {
        slug: "ovid-image:img-two",
        operations: { edit: {} },
        sizes: ["1536x1024"],
        aspect_ratios: ["3:2"],
        input: { max_images: 2 },
      },
      // Unpriced: parsed, but never selectable.
      {
        slug: "ovid-image:img-free",
        operations: { generate: {} },
        sizes: ["1024x1024"],
        priced: false,
      },
      // Malformed entries are dropped.
      { slug: "not-a-slug", operations: { generate: {} } },
      { slug: "ovid-image:no-ops", operations: {} },
    ],
  };
}

function caps(): ImageCapabilities {
  return parseImageCapabilities(capsBody());
}

function successBody(): Record<string, unknown> {
  return {
    model: "ovid-image",
    model_slug: "ovid-image:img-one",
    data: [{ b64_json: PNG_B64, mime_type: "image/png" }],
    receipt: {
      account_id: "u1",
      request_id: "request-1",
      fingerprint: "f".repeat(64),
      state: "confirmed",
      charged: "0.0123",
    },
  };
}

function context(root: string, events: Array<{ type: string; payload: Record<string, unknown> }> = []): ToolContext {
  return {
    sandbox: { workspaceDir: root } as SandboxHandle,
    userId: "u1",
    sessionId: "s1",
    runId: "r1",
    emitEvent: async (type, payload) => {
      events.push({ type, payload });
    },
    signal: new AbortController().signal,
  };
}

interface Harness {
  call: ImageCall & ReturnType<typeof vi.fn>;
  calls: Array<{ path: string; userId: string; body: Record<string, unknown> }>;
  published: ImageArtifactInput[];
  publishArtifact: (input: ImageArtifactInput) => Promise<{
    id: string;
    url: string;
    expiresAt: string;
    sizeBytes: number;
    contentType: string;
  }>;
}

function harness(result: ImageCallResult | (() => ImageCallResult)): Harness {
  const calls: Harness["calls"] = [];
  const published: ImageArtifactInput[] = [];
  const call = vi.fn(async (path: string, userId: string, body: Record<string, unknown>) => {
    calls.push({ path, userId, body });
    return typeof result === "function" ? result() : result;
  }) as unknown as Harness["call"];
  const publishArtifact = async (input: ImageArtifactInput) => {
    published.push(input);
    return {
      id: "art-1",
      url: "https://r2.example/art-1",
      expiresAt: "2026-10-20T16:00:00.000Z",
      sizeBytes: input.content.length,
      contentType: input.contentType,
    };
  };
  return { call, calls, published, publishArtifact };
}

describe("image capability parsing", () => {
  it("keeps valid cards, drops malformed ones, and never offers unpriced models", () => {
    const parsed = caps();
    expect(parsed.catalog_hash).toBe("a".repeat(32));
    expect(parsed.models.map((m) => m.slug)).toEqual([
      "ovid-image:img-one",
      "ovid-image:img-two",
      "ovid-image:img-free",
    ]);
    expect(modelsFor(parsed, "generate").map((m) => m.slug)).toEqual(["ovid-image:img-one"]);
    expect(modelsFor(parsed, "edit").map((m) => m.slug)).toEqual([
      "ovid-image:img-one",
      "ovid-image:img-two",
    ]);
    const one = parsed.models[0]!;
    expect(one.sizes).toEqual(["1024x1024"]);
    expect(one.aspect_ratios).toEqual(["1:1"]);
    expect(one.text_rendering).toBe("good");
    expect(one.verified).toBe(true);
  });

  it("accepts the legacy operations map as one coarse card", () => {
    const parsed = parseImageCapabilities({
      operations: { generate: ["1024x1024"], edit: ["1024x1024", "1536x1024"] },
    });
    expect(parsed.models).toHaveLength(1);
    expect(parsed.models[0]!.slug).toBe("ovid-image");
    expect(modelsFor(parsed, "edit")[0]!.sizes).toEqual(["1024x1024", "1536x1024"]);
  });

  it("returns empty (never throws) for a malformed body", () => {
    expect(parseImageCapabilities(null).models).toEqual([]);
    expect(parseImageCapabilities({ models: "nope" }).models).toEqual([]);
  });
});

describe("generate_image / edit_image", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-image-tools-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  it("registers both tools and the worker v1 roster stays unchanged", () => {
    const h = harness({ ok: true, body: successBody() });
    const tools = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
    });
    expect(tools.map((t) => t.name)).toEqual(["generate_image", "edit_image"]);
    for (const tool of tools) {
      expect(tool.parameters).toMatchObject({ type: "object" });
      expect(tool.description.length).toBeGreaterThan(0);
    }
    // The description carries ONLY priced, capable cards.
    expect(tools[0]!.description).toContain("ovid-image:img-one");
    expect(tools[0]!.description).not.toContain("img-free");
    expect(tools[1]!.description).toContain("ovid-image:img-two");
    // The P2 six-tool registry is the compat seam; image tools enter the FULL
    // roster (runProcessor), not this registry.
    expect(createToolRegistry().tools.map((t) => t.name)).not.toContain("generate_image");
  });

  it("says so when the plan's allowance is already exhausted", () => {
    const parsed = parseImageCapabilities({
      ...capsBody(),
      quota: { tier: "free", free_cap_remaining: 0 },
    });
    const h = harness({ ok: true, body: successBody() });
    const [generate] = createImageTools({
      call: h.call,
      capabilities: parsed,
      publishArtifact: h.publishArtifact,
    });
    expect(generate!.description).toContain("allowance is exhausted");
  });

  it("generate: saves the image, publishes the artifact and records measured usage", async () => {
    const h = harness({ ok: true, body: successBody() });
    const usage: Array<Record<string, unknown>> = [];
    const [generate] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      recordUsage: async (fact) => {
        usage.push(fact);
      },
    });

    const result = await generate!.execute(
      {
        prompt: "a red cube",
        size: "1024x1024",
        aspect_ratio: "1:1",
        request_id: "request-1",
      },
      context(root),
    );
    expect(result.isError).toBe(false);
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]!.path).toBe(GENERATIONS_PATH);
    expect(h.calls[0]!.userId).toBe("u1");
    expect(h.calls[0]!.body).toMatchObject({
      request_id: "request-1",
      prompt: "a red cube",
      size: "1024x1024",
      requirements: { aspect_ratio: "1:1" },
    });

    const files = await readdir(join(root, "generated"));
    expect(files).toEqual(["generate_request-1.png"]);
    expect(await readFile(join(root, "generated", files[0]!))).toEqual(PNG_BYTES);
    expect(h.published).toHaveLength(1);
    expect(h.published[0]).toMatchObject({
      userId: "u1",
      sessionId: "s1",
      name: "generated/generate_request-1.png",
      contentType: "image/png",
    });
    expect(result.content).toContain("generated/generate_request-1.png");
    expect(result.content).toContain('"model":"ovid-image:img-one"');
    expect(result.content).toContain('"charged":"0.0123"');
    expect(result.content).toContain('"id":"art-1"');
    expect(usage).toEqual([
      {
        account: "u1",
        request: "request-1",
        sessionId: "s1",
        runId: "r1",
        op: "generate",
        costUsd: "0.0123",
      },
    ]);
  });

  it("generate: rejects a size/model the cards do not advertise, without a call", async () => {
    const h = harness({ ok: true, body: successBody() });
    const [generate] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
    });

    const size = await generate!.execute(
      { prompt: "a cube", size: "2048x2048" },
      context(root),
    );
    expect(size.isError).toBe(true);
    expect(size.content).toContain("unsupported_size");

    const model = await generate!.execute(
      { prompt: "a cube", model: "ovid-image:nope" },
      context(root),
    );
    expect(model.isError).toBe(true);
    expect(model.content).toContain("unsupported_model");
    expect(h.calls).toHaveLength(0);
  });

  it("edit: reads the workspace image and records its real run/session", async () => {
    await writeFile(join(root, "input.png"), PNG_BYTES);
    const h = harness({ ok: true, body: successBody() });
    const usage: Array<Record<string, unknown>> = [];
    const [, edit] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      recordUsage: async (fact) => {
        usage.push(fact);
      },
    });

    const result = await edit!.execute(
      { prompt: "make it blue", path: "input.png", request_id: "request-2" },
      context(root),
    );
    expect(result.isError).toBe(false);
    expect(h.calls[0]!.path).toBe(EDITS_PATH);
    expect(h.calls[0]!.body).toMatchObject({
      request_id: "request-2",
      prompt: "make it blue",
      image: `data:image/png;base64,${PNG_B64}`,
    });
    expect(result.content).toContain("generated/edit_request-2.png");
    expect(usage).toEqual([
      {
        account: "u1",
        request: "request-2",
        sessionId: "s1",
        runId: "r1",
        op: "edit",
        costUsd: "0.0123",
      },
    ]);
  });

  it("keeps an absent receipt charge null instead of estimating image cost", async () => {
    const body = successBody();
    (body.receipt as { charged: string | null }).charged = null;
    const h = harness({ ok: true, body });
    const usage: Array<Record<string, unknown>> = [];
    const [generate] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      recordUsage: async (fact) => {
        usage.push(fact);
      },
    });

    const result = await generate!.execute(
      { prompt: "a cube", request_id: "request-null" },
      context(root),
    );
    expect(result.isError).toBe(false);
    expect(usage).toEqual([
      {
        account: "u1",
        request: "request-null",
        sessionId: "s1",
        runId: "r1",
        op: "generate",
        costUsd: null,
      },
    ]);
  });

  it("edit: refuses a path outside the workspace", async () => {
    const h = harness({ ok: true, body: successBody() });
    const [, edit] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
    });
    const result = await edit!.execute(
      { prompt: "make it blue", path: "/etc/passwd" },
      context(root),
    );
    expect(result.isError).toBe(true);
    expect(result.content.startsWith("confined:")).toBe(true);
    expect(h.calls).toHaveLength(0);
  });

  it("quota exhausted: returns a graceful error, publishes nothing", async () => {
    const h = harness({
      ok: false,
      status: 402,
      code: "image_limit_reached",
      detail: null,
      receipt: null,
      retryAfterSeconds: null,
    });
    const [generate] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
    });
    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const result = await generate!.execute({ prompt: "a cube" }, context(root, events));
    expect(result.isError).toBe(true);
    expect(result.content).toContain("allowance");
    expect(result.content).toContain("image_limit_reached");
    expect(events).toEqual([
      {
        type: "system_note",
        payload: { code: "image_limit_reached", message: expect.stringContaining("allowance") },
      },
    ]);
    expect(h.published).toHaveLength(0);
    await expect(readdir(join(root, "generated"))).rejects.toThrow();
  });

  it("vision guard: a text-only chat model gets an in-chat error and a push", async () => {
    await writeFile(join(root, "input.png"), PNG_BYTES);
    const h = harness({ ok: true, body: successBody() });
    const notifyAgentFailed = vi.fn(async () => {});
    const [, edit] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      notifier: { notifyAgentFailed },
      visionGuard: async () => ({
        supports: false,
        model: "deepseek-v4",
        message: "Custom Model Error: Selected model 'deepseek-v4' does not support vision.",
      }),
    });

    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const result = await edit!.execute(
      { prompt: "make it blue", path: "input.png" },
      context(root, events),
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("does not support vision");
    expect(h.calls).toHaveLength(0);
    expect(events).toEqual([
      {
        type: "system_note",
        payload: { code: "model_no_vision", message: expect.stringContaining("vision") },
      },
    ]);
    expect(notifyAgentFailed).toHaveBeenCalledWith(
      expect.objectContaining({
        userId: "u1",
        sessionId: "s1",
        code: "model_no_vision",
      }),
    );
  });

  it("vision guard: a capability-read failure fails closed", async () => {
    await writeFile(join(root, "input.png"), PNG_BYTES);
    const h = harness({ ok: true, body: successBody() });
    const [, edit] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      visionGuard: async () => {
        throw new Error("catalog unavailable");
      },
    });
    const result = await edit!.execute(
      { prompt: "make it blue", path: "input.png" },
      context(root),
    );
    expect(result.isError).toBe(true);
    expect(result.content).toContain("could not verify model vision support");
    expect(h.calls).toHaveLength(0);
  });

  it("vision guard: a vision-capable model edits normally", async () => {
    await writeFile(join(root, "input.png"), PNG_BYTES);
    const h = harness({ ok: true, body: successBody() });
    const [, edit] = createImageTools({
      call: h.call,
      capabilities: caps(),
      publishArtifact: h.publishArtifact,
      visionGuard: async () => ({ supports: true, model: "gemini-2", message: "" }),
    });
    const result = await edit!.execute(
      { prompt: "make it blue", path: "input.png", request_id: "request-3" },
      context(root),
    );
    expect(result.isError).toBe(false);
    expect(h.calls).toHaveLength(1);
  });
});

describe("internal image client", () => {
  it("signs the exact path/uid and sends the uid in the body", async () => {
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    const call = createInternalImageClient({
      baseUrl: "http://mint:8092/",
      secret: SECRET,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      now: () => TS * 1000,
    });

    const result = await call(GENERATIONS_PATH, "u1", {
      request_id: "request-1",
      prompt: "a cube",
    });
    expect(result.ok).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(`http://mint:8092${GENERATIONS_PATH}`);
    expect(JSON.parse(String(init.body))).toEqual({
      uid: "u1",
      request_id: "request-1",
      prompt: "a cube",
    });
    const headers = init.headers as Record<string, string>;
    expect(
      verifyInternalRequest(
        SECRET,
        "POST",
        GENERATIONS_PATH,
        "u1",
        headers["X-Ovid-Timestamp"]!,
        headers["X-Ovid-Signature"]!,
        TS,
      ),
    ).toBe(true);
  });

  it("maps the public error envelope to a typed failure", async () => {
    const fetchImpl = vi.fn(async () =>
      new Response(
        JSON.stringify({
          error: { code: "image_capacity_unavailable", retryAfterSeconds: 45 },
          receipt: { state: "pending" },
        }),
        { status: 503, headers: { "retry-after": "45" } },
      ),
    );
    const call = createInternalImageClient({
      baseUrl: "http://mint:8092",
      secret: SECRET,
      fetchImpl: fetchImpl as unknown as typeof fetch,
      now: () => TS * 1000,
    });
    const result = await call(GENERATIONS_PATH, "u1", { request_id: "request-1", prompt: "x" });
    expect(result).toMatchObject({
      ok: false,
      status: 503,
      code: "image_capacity_unavailable",
      retryAfterSeconds: 45,
      receipt: { state: "pending" },
    });
  });
});
