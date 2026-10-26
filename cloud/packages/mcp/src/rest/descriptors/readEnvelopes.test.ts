import { describe, expect, it } from "vitest";

import { createCuratedCatalog, type CuratedCatalogDeps } from "../../catalog.js";
import { createCuratedProviderSupport } from "../../activation.js";
import type { EgressRequest, EgressResponse, ProviderEgress } from "../../egress/providerEgress.js";
import { ORIGINAL_PROVIDER_DEFINITIONS, ORIGINAL_READINESS_ROWS } from "../../providerEvidence.js";
import { createProviderRegistry, type ProviderRegistry } from "../../providers/registry.js";
import type { GuardedFetch } from "../../ssrf.js";
import type { McpCallContext } from "../../transports/native.js";
import type { WorkspaceFiles } from "../../workspace.js";
import {
  READ_ENVELOPE_PROVIDER_IDS,
  readShapeError,
  withReadEnvelope,
} from "./readEnvelopes.js";

// ---------------------------------------------------------------------------
// These fixtures are synthetic, hand-written copies of the *documented* shape
// of each official read (no credentials, no captured traffic). They prove the
// parser, not the provider: a passing case here is source-level evidence only.
// ---------------------------------------------------------------------------

interface ShapeCase {
  providerId: string;
  operationId: string;
  valid: unknown;
  /** A 2xx body that the old generic engine reported as a successful read. */
  softFailure: unknown;
}

const CASES: readonly ShapeCase[] = [
  {
    providerId: "gitlab",
    operationId: "list_projects",
    valid: [{ id: 1, name: "ovid" }],
    softFailure: { message: "401 Unauthorized" },
  },
  {
    providerId: "gitlab",
    operationId: "list_merge_requests",
    valid: [],
    softFailure: { error: "404 Not found" },
  },
  {
    providerId: "jira",
    operationId: "search",
    valid: { issues: [], isLast: true },
    softFailure: { errorMessages: ["The value 'x' does not exist"], errors: {} },
  },
  {
    providerId: "jira",
    operationId: "get_issue",
    valid: { id: "10001", key: "PROJ-1" },
    softFailure: { errorMessages: ["Issue does not exist"] },
  },
  {
    providerId: "figma",
    operationId: "get_file",
    valid: { name: "Design", document: { id: "0:0" } },
    softFailure: { status: 403, err: "Invalid token" },
  },
  {
    providerId: "figma",
    operationId: "get_comments",
    valid: { comments: [] },
    softFailure: {},
  },
  {
    providerId: "sentry",
    operationId: "list_issues",
    valid: [{ id: "1", title: "Boom" }],
    softFailure: { detail: "Invalid token" },
  },
  {
    providerId: "sentry",
    operationId: "get_issue",
    valid: { id: "1" },
    softFailure: { detail: "Unauthorized" },
  },
  {
    providerId: "sentry",
    operationId: "latest_event",
    valid: { eventID: "abc", id: "2" },
    softFailure: { detail: "Not found" },
  },
  {
    providerId: "exa",
    operationId: "search",
    valid: { results: [{ url: "https://example.invalid" }] },
    softFailure: { requestId: "x", error: "invalid api key" },
  },
  {
    providerId: "exa",
    operationId: "contents",
    valid: { results: [] },
    softFailure: { error: "unprocessable" },
  },
  {
    providerId: "notion",
    operationId: "search",
    valid: { object: "list", results: [] },
    softFailure: { object: "error", status: 401, message: "API token is invalid." },
  },
  {
    providerId: "notion",
    operationId: "query_data_source",
    valid: { object: "list", results: [], has_more: false },
    softFailure: { object: "error", code: "validation_error" },
  },
  {
    providerId: "notion",
    operationId: "get_page",
    valid: { object: "page", id: "page-id" },
    softFailure: { object: "error", message: "Could not find page." },
  },
  {
    providerId: "airtable",
    operationId: "list_records",
    valid: { records: [{ id: "rec1", fields: {} }] },
    softFailure: { error: { type: "AUTHENTICATION_REQUIRED" } },
  },
  {
    providerId: "firebase",
    operationId: "get_document",
    valid: { name: "projects/p/databases/(default)/documents/c/d" },
    softFailure: { error: { code: 403, message: "Missing or insufficient permissions." } },
  },
  {
    providerId: "firebase",
    operationId: "list_documents",
    // Firestore omits `documents` for an empty collection.
    valid: {},
    softFailure: { error: { code: 401 } },
  },
  {
    providerId: "discord",
    operationId: "get_current_user",
    valid: { id: "123", username: "ovid" },
    softFailure: { message: "401: Unauthorized", code: 0 },
  },
  {
    providerId: "discord",
    operationId: "list_guilds",
    valid: [{ id: "1", name: "guild" }],
    softFailure: { message: "Missing Access", code: 50001 },
  },
];

describe("documented read envelopes", () => {
  it.each(CASES)("$providerId/$operationId accepts its documented shape", ({ providerId, operationId, valid }) => {
    expect(readShapeError(providerId, operationId, valid)).toBeNull();
  });

  it.each(CASES)("$providerId/$operationId rejects an HTTP-200 soft failure", ({ providerId, operationId, softFailure }) => {
    expect(readShapeError(providerId, operationId, softFailure)).not.toBeNull();
  });

  it("rejects an unknown operation instead of silently accepting it", () => {
    expect(readShapeError("figma", "create_file", { document: {} })).toBe("unknown operation");
    expect(readShapeError("slack", "list_channels", { ok: true })).toBe("provider has no documented read envelope");
  });

  it("documents every published operation of every wrapped original", () => {
    const published = new Set<string>();
    for (const definition of ORIGINAL_PROVIDER_DEFINITIONS) {
      if (!READ_ENVELOPE_PROVIDER_IDS.includes(definition.providerId)) continue;
      for (const operation of definition.operations) published.add(`${definition.providerId}/${operation.name}`);
    }
    const documented = new Set(CASES.map((entry) => `${entry.providerId}/${entry.operationId}`));
    // No descriptor operation may be published without a shape contract, and
    // no shape contract may survive an operation that is no longer published.
    expect([...documented].sort()).toEqual([...published].sort());
  });
});

// ---------------------------------------------------------------------------
// End-to-end through the two real construction paths (catalog and activation)
// so the wrapper cannot silently fall out of production wiring.
// ---------------------------------------------------------------------------

class JsonEgress implements ProviderEgress {
  readonly requests: EgressRequest[] = [];
  constructor(private readonly body: unknown) {}
  async request(request: EgressRequest): Promise<EgressResponse> {
    this.requests.push(request);
    return {
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      body: new Response(JSON.stringify(this.body)).body as ReadableStream<Uint8Array>,
      origin: new URL(request.url.origin),
      remoteAddress: "192.0.2.20",
    };
  }
  async close(): Promise<void> {}
}

function testRegistry(ids: readonly string[]): ProviderRegistry {
  const registry = createProviderRegistry({ now: () => new Date("2026-10-24T23:00:00.000Z") });
  for (const id of ids) {
    const definition = ORIGINAL_PROVIDER_DEFINITIONS.find((candidate) => candidate.providerId === id);
    const original = ORIGINAL_READINESS_ROWS.find((candidate) => candidate.providerId === id);
    if (definition === undefined || original === undefined) throw new Error(`missing test definition ${id}`);
    const read = definition.operations.find((operation) => operation.effect === "read");
    if (read === undefined) throw new Error(`missing test read ${id}`);
    const suffix = id.toUpperCase().replaceAll("-", "_");
    registry.registerProvider(definition, {
      ...original,
      operations: definition.operations.map((operation) => ({ ...operation })),
      effects: Object.fromEntries(definition.operations.map((operation) => [operation.name, {
        effect: operation.effect,
        approval: operation.approval,
      }])),
      automatedEvidence: { test: "src/rest/descriptors/readEnvelopes.test.ts", result: "passed", runAt: "2026-10-24T20:00:00.000Z" },
      liveReadEvidence: {
        command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_${suffix}=1 test-only-envelope-fixture`,
        operationId: read.name,
        runAt: "2026-10-24T20:01:00.000Z",
        evidence: "sanitized-result: isolated envelope fixture only",
      },
      liveWriteEvidence: definition.operations.filter((operation) => operation.effect !== "read").map((operation) => ({
        command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_WRITE_TESTS=1 OVID_LIVE_PROVIDER_${suffix}=1 OVID_LIVE_PROVIDER_${suffix}_DISPOSABLE_RESOURCE=declared test-only-envelope-fixture`,
        operationId: operation.name,
        runAt: "2026-10-24T20:02:00.000Z",
        evidence: "sanitized-result: disposable isolated envelope fixture; cleanup verified",
      })),
      credentials: "passed",
      releaseState: "supported",
    });
  }
  return registry;
}

function jsonFetch(body: unknown): GuardedFetch {
  return async () => new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

const WORKSPACE: WorkspaceFiles = {
  async read() { return null; },
  async write() {},
  async list() { return []; },
  async stat() { return null; },
  async remove() {},
};

function ctx(secrets: Record<string, string>, fetchImpl: GuardedFetch = jsonFetch({})): McpCallContext {
  return {
    uid: "envelope-user",
    secrets,
    workspace: WORKSPACE,
    fetchImpl,
    mode: "auto",
    planMode: false,
    unattended: false,
  } as McpCallContext;
}

function catalogDeps(body: unknown): CuratedCatalogDeps {
  return {
    registry: testRegistry(["figma", "sentry"]),
    fetchImpl: jsonFetch(body),
    workspace: WORKSPACE,
  };
}

describe("catalog wiring", () => {
  it("returns the provider document unchanged when the shape is documented", async () => {
    const catalog = createCuratedCatalog(catalogDeps({ comments: [{ id: "c1" }] }));
    const entry = catalog.get("figma");
    expect(entry).toBeDefined();
    const result = await entry!.handler.callTool("get_comments", { file_key: "abc" }, ctx({ token: "figma-personal-token-0001" }, jsonFetch({ comments: [{ id: "c1" }] })));
    expect(result.isError).toBe(false);
    expect(JSON.parse(result.text)).toEqual({ comments: [{ id: "c1" }] });
  });

  it("turns an HTTP-200 soft failure into a fixed error without echoing the payload", async () => {
    const catalog = createCuratedCatalog(catalogDeps({ status: 403, err: "Invalid token figma-personal-token-0001" }));
    const result = await catalog.get("figma")!.handler.callTool(
      "get_comments",
      { file_key: "abc" },
      ctx({ token: "figma-personal-token-0001" }, jsonFetch({ status: 403, err: "Invalid token figma-personal-token-0001" })),
    );
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Provider returned an unexpected read response.");
    expect(result.text).not.toContain("figma-personal-token-0001");
    expect(result.text).not.toContain("Invalid token");
  });

  it("keeps array-shaped reads working (Sentry issue list)", async () => {
    const catalog = createCuratedCatalog(catalogDeps([{ id: "1", title: "Boom" }]));
    const result = await catalog.get("sentry")!.handler.callTool(
      "list_issues",
      { org: "ovid" },
      ctx({ auth_token: "sentry-token" }, jsonFetch([{ id: "1", title: "Boom" }])),
    );
    expect(result.isError).toBe(false);
    expect(JSON.parse(result.text)).toHaveLength(1);
  });
});

describe("activation wiring", () => {
  it("installs the same envelope check on the worker activation path", async () => {
    const registry = testRegistry(["figma"]);
    const support = createCuratedProviderSupport(registry);
    const egress = new JsonEgress({ status: 401, err: "Invalid token" });
    const overrides = support.handlerOverrides(egress as never);
    const handler = overrides.figma;
    expect(handler).toBeDefined();
    const result = await handler!().callTool("get_comments", { file_key: "abc" }, ctx({ token: "figma-personal-token-0001" }));
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Provider returned an unexpected read response.");
    expect(egress.requests).toHaveLength(1);
  });

  it("passes a documented shape through the activation path", async () => {
    const registry = testRegistry(["figma"]);
    const support = createCuratedProviderSupport(registry);
    const egress = new JsonEgress({ comments: [] });
    const handler = support.handlerOverrides(egress as never).figma!();
    const result = await handler.callTool("get_comments", { file_key: "abc" }, ctx({ token: "figma-personal-token-0001" }));
    expect(result.isError).toBe(false);
    expect(JSON.parse(result.text)).toEqual({ comments: [] });
  });
});

describe("wrapper scope", () => {
  it("never wraps a provider it has no documented envelope for", () => {
    const marker = { called: 0 };
    const base = {
      initialize: async () => ({}),
      listTools: async () => [],
      async callTool() { marker.called += 1; return { text: "{}", isError: false, content: [] }; },
    };
    const wrapped = withReadEnvelope("slack", base as never);
    expect(wrapped).toBe(base as never);
  });
});
