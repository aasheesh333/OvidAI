import { describe, expect, it } from "vitest";
import { CURATED_IDS, CURATED_MANIFEST, createCuratedCatalog, type CuratedCatalogDeps } from "./catalog.js";
import { createFetchHandler } from "./native/fetch.js";
import { createMemoryHandler } from "./native/memory.js";
import type { McpCallContext } from "./transports/native.js";
import type { McpToolDef } from "./client.js";
import type { GuardedFetch } from "./ssrf.js";
import type { WorkspaceFiles } from "./workspace.js";
import { createProviderRegistry, type ProviderRegistry } from "./providers/registry.js";
import { ORIGINAL_PROVIDER_DEFINITIONS, ORIGINAL_READINESS_ROWS } from "./providerEvidence.js";

function fakeFetch(): { calls: string[]; impl: GuardedFetch } {
  const calls: string[] = [];
  return {
    calls,
    impl: async (url) => {
      calls.push(url);
      return new Response("ok", { status: 200 });
    },
  };
}

function fakeWorkspace(): { uids: string[]; impl: WorkspaceFiles } {
  const uids: string[] = [];
  const files = new Map<string, string>();
  return {
    uids,
    impl: {
      async read(uid, path) {
        uids.push(uid);
        const content = files.get(`${uid}:${path}`);
        return content === undefined ? null : { content, bytes: content.length };
      },
      async write(uid, path, content) { uids.push(uid); files.set(`${uid}:${path}`, content); },
      async list(uid) { uids.push(uid); return []; },
      async stat(uid) { uids.push(uid); return null; },
      async remove(uid) { uids.push(uid); },
    },
  };
}

function makeCtx(uid: string, opts: { fetchImpl?: GuardedFetch; workspace?: unknown }): McpCallContext {
  return {
    uid,
    secrets: {},
    workspace: (opts.workspace ?? {}) as never,
    fetchImpl: opts.fetchImpl ?? (async () => new Response("ok", { status: 200 })),
    mode: "auto",
    planMode: false,
    unattended: false,
  } as McpCallContext;
}

// The Filesystem ProviderOperation adds registry-only operation metadata and
// the closed-schema narrowing documented in providerEvidence.ts. Remove only
// those additions: every remaining MCP publication field must equal the real
// handler's listTools() exactly.
function filesystemHandlerView(tools: readonly McpToolDef[]): McpToolDef[] {
  return tools.map((tool) => {
    const inputSchema = { ...(tool.inputSchema ?? {}) };
    delete inputSchema.additionalProperties;
    delete inputSchema.maxProperties;
    const properties = Object.fromEntries(Object.entries(inputSchema.properties ?? {}).map(([name, value]) => {
      const property = { ...(value as Record<string, unknown>) };
      delete property.minLength;
      delete property.maxLength;
      return [name, property];
    }));
    return {
      name: tool.name,
      description: tool.description,
      inputSchema: { ...inputSchema, properties },
    };
  });
}

/** Test-only evidence proves catalog filtering mechanics; it is not original live evidence. */
function supportedRegistry(ids: readonly string[]): ProviderRegistry {
  const registry = createProviderRegistry({ now: () => new Date("2026-10-24T23:00:00.000Z") });
  for (const id of ids) {
    const definition = ORIGINAL_PROVIDER_DEFINITIONS.find((candidate) => candidate.providerId === id);
    const original = ORIGINAL_READINESS_ROWS.find((candidate) => candidate.providerId === id);
    if (definition === undefined || original === undefined) throw new Error(`missing test definition ${id}`);
    const read = definition.operations.find((operation) => operation.effect === "read");
    if (read === undefined) throw new Error(`missing test read ${id}`);
    registry.registerProvider(definition, {
      ...original,
      operations: definition.operations.map((operation) => ({ ...operation })),
      effects: Object.fromEntries(definition.operations.map((operation) => [operation.name, {
        effect: operation.effect,
        approval: operation.approval,
      }])),
      automatedEvidence: { test: "src/catalog.test.ts", result: "passed", runAt: "2026-10-24T20:00:00.000Z" },
      liveReadEvidence: {
        command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_${id.toUpperCase().replaceAll("-", "_")}=1 test-only-catalog-fixture`,
        operationId: read.name,
        runAt: "2026-10-24T20:01:00.000Z",
        evidence: "sanitized-result: isolated catalog fixture only",
      },
      liveWriteEvidence: definition.operations.filter((operation) => operation.effect !== "read").map((operation) => ({
        command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_WRITE_TESTS=1 OVID_LIVE_PROVIDER_${id.toUpperCase().replaceAll("-", "_")}=1 OVID_LIVE_PROVIDER_${id.toUpperCase().replaceAll("-", "_")}_DISPOSABLE_RESOURCE=declared test-only-catalog-fixture`,
        operationId: operation.name,
        runAt: "2026-10-24T20:02:00.000Z",
        evidence: "sanitized-result: disposable isolated catalog fixture; cleanup verified",
      })),
      credentials: "passed",
      releaseState: "supported",
    });
  }
  return registry;
}

function deps(registry: ProviderRegistry, extra: Partial<CuratedCatalogDeps> = {}): CuratedCatalogDeps {
  return { registry, fetchImpl: fakeFetch().impl, workspace: fakeWorkspace().impl, ...extra };
}

describe("readiness-gated curated catalog", () => {
  it("publishes no unsupported original descriptor, credential tile, or legacy handler", () => {
    expect(ORIGINAL_READINESS_ROWS).toHaveLength(20);
    expect(CURATED_IDS).toEqual([]);
    expect(CURATED_MANIFEST).toEqual([]);
    const catalog = createCuratedCatalog(deps(ORIGINAL_PROVIDER_DEFINITIONS.length === 20
      ? supportedRegistry([]) // explicit empty test registry
      : (() => { throw new Error("original inventory changed"); })()));
    for (const id of ["github", "fetch", "mongodb", "supabase", "slack"]) expect(catalog.get(id)).toBeUndefined();
    expect(catalog.entries()).toEqual([]);
  });

  it("instantiates each supported handler once and keeps per-user data on the call context", async () => {
    const fetchFake = fakeFetch();
    const ws = fakeWorkspace();
    const registry = supportedRegistry(["fetch", "memory"]);
    let fetchConstructions = 0;
    let memoryConstructions = 0;
    const catalog = createCuratedCatalog(deps(registry, {
      fetchImpl: fetchFake.impl,
      workspace: ws.impl,
      handlerOverrides: {
        fetch: () => { fetchConstructions++; return createFetchHandler(); },
        memory: () => { memoryConstructions++; return createMemoryHandler(); },
      },
    }));

    const a = catalog.get("fetch");
    expect(a).toBe(catalog.get("fetch"));
    expect(catalog.get("github")).toBeUndefined();
    await a!.handler.callTool("fetch", { url: "https://example.com/a" }, makeCtx("userA", { fetchImpl: fetchFake.impl }));
    await a!.handler.callTool("fetch", { url: "https://example.com/b" }, makeCtx("userB", { fetchImpl: fetchFake.impl }));
    expect(fetchFake.calls).toEqual(["https://example.com/a", "https://example.com/b"]);
    expect(fetchConstructions).toBe(1);

    const memory = catalog.get("memory");
    await memory!.handler.callTool("read_graph", {}, makeCtx("userA", { workspace: ws.impl }));
    await memory!.handler.callTool("read_graph", {}, makeCtx("userB", { workspace: ws.impl }));
    expect(memoryConstructions).toBe(1);
    expect(new Set(ws.uids)).toEqual(new Set(["userA", "userB"]));
  });

  it("derives supported tools from readiness definitions with no live-handler drift", async () => {
    const registry = supportedRegistry(["fetch", "memory", "github", "filesystem"]);
    const catalog = createCuratedCatalog(deps(registry));
    expect(catalog.entries().map((entry) => entry.curatedId)).toEqual(["fetch", "memory", "github", "filesystem"]);
    for (const entry of catalog.entries()) {
      const tools = entry.curatedId === "filesystem" ? filesystemHandlerView(entry.tools) : entry.tools;
      expect(tools).toEqual(await entry.handler.listTools());
    }
    expect(catalog.get("github")?.credentialFields).toEqual([
      { key: "GITHUB_TOKEN", label: "GitHub token", secret: true },
    ]);
    expect(Object.keys(catalog.get("github")!)).not.toContain("handlerSecret");
  });
});
