/**
 * Tests for the curated MCP catalog: the 100 pinned ids, the pure-data
 * manifest, and THE shared-singleton proof — one handler instance per
 * curated server per process, per-user data injected per call.
 */

import { describe, expect, it } from "vitest";
import { CURATED_IDS, CURATED_MANIFEST, createCuratedCatalog } from "./catalog.js";
import { EXPANDED_IDS } from "./rest/descriptors/index.js";
import { createFetchHandler } from "./native/fetch.js";
import { createMemoryHandler } from "./native/memory.js";
import type { McpCallContext } from "./transports/native.js";
import type { GuardedFetch } from "./ssrf.js";
import type { WorkspaceFiles } from "./workspace.js";

interface FetchCall {
  url: string;
}

function fakeFetch(): { calls: FetchCall[]; impl: GuardedFetch } {
  const calls: FetchCall[] = [];
  const impl: GuardedFetch = async (url) => {
    calls.push({ url });
    return new Response("ok", { status: 200 });
  };
  return { calls, impl };
}

function fakeWorkspace(): { uids: string[]; impl: WorkspaceFiles } {
  const uids: string[] = [];
  const files = new Map<string, string>();
  const impl: WorkspaceFiles = {
    async read(uid, path) {
      uids.push(uid);
      return files.has(`${uid}:${path}`) ? { content: files.get(`${uid}:${path}`)!, bytes: 0 } : null;
    },
    async write(uid, path, content) {
      uids.push(uid);
      files.set(`${uid}:${path}`, content);
    },
    async list(uid) {
      uids.push(uid);
      return [];
    },
    async stat(uid) {
      uids.push(uid);
      return null;
    },
    async remove(uid) {
      uids.push(uid);
    },
  };
  return { uids, impl };
}

function makeCtx(uid: string, opts: { fetchImpl?: GuardedFetch; workspace?: unknown }): McpCallContext {
  return {
    uid,
    secrets: {},
    workspace: (opts.workspace ?? {}) as never,
    fetchImpl: opts.fetchImpl ?? (async () => new Response("ok", { status: 200 })),
  };
}

describe("curated catalog", () => {
  it("CURATED_IDS is the 20 original ids followed by the 80 expansion", () => {
    // The first 20 are pinned forever: they are the ids users already have
    // configured, so a reorder would silently re-map their credentials.
    expect(CURATED_IDS.slice(0, 20)).toEqual([
      "github",
      "filesystem",
      "fetch",
      "memory",
      "gitlab",
      "jira",
      "linear",
      "figma",
      "sentry",
      "exa",
      "notion",
      "google-drive",
      "airtable",
      "supabase",
      "firebase",
      "mongodb",
      "s3",
      "slack",
      "discord",
      "telegram",
    ]);
    // Owner directive: the catalogue is 100 connectors.
    expect(CURATED_IDS.length).toBe(100);
    expect(new Set(CURATED_IDS).size).toBe(100);
    expect(CURATED_IDS.slice(20)).toEqual([...EXPANDED_IDS]);
  });

  it("CURATED_MANIFEST is pure data with a credential field on every gated entry", () => {
    expect(CURATED_MANIFEST.map((e) => e.curatedId)).toEqual([...CURATED_IDS]);
    const credentialless = new Set(["fetch", "filesystem", "memory"]);
    for (const entry of CURATED_MANIFEST) {
      expect(Object.keys(entry).sort()).toEqual([
        "credentialFields",
        "curatedId",
        "description",
        "displayName",
        "tools",
      ]); // no handler — the gateway serves this without instantiating anything
      expect(entry.tools.length).toBeGreaterThan(0);
      if (credentialless.has(entry.curatedId)) {
        expect(entry.credentialFields).toEqual([]);
        continue;
      }
      const secret = entry.credentialFields.find((f) => f.secret);
      expect(secret, `credential field for ${entry.curatedId}`).toBeDefined();
    }
    const github = CURATED_MANIFEST.find((e) => e.curatedId === "github");
    expect(github?.credentialFields).toEqual([
      { key: "GITHUB_TOKEN", label: "GitHub token", secret: true },
    ]);
  });

  it("createCuratedCatalog instantiates each handler exactly once and serves both users with one instance", async () => {
    const fetchFake = fakeFetch();
    const ws = fakeWorkspace();
    let fetchConstructions = 0;
    let memoryConstructions = 0;

    const catalog = createCuratedCatalog({
      fetchImpl: fetchFake.impl,
      workspace: ws.impl,
      handlerOverrides: {
        fetch: () => {
          fetchConstructions += 1;
          return createFetchHandler();
        },
        memory: () => {
          memoryConstructions += 1;
          return createMemoryHandler();
        },
      },
    });

    // (a) same CatalogEntry object → same handler identity on every get
    const a = catalog.get("fetch");
    const b = catalog.get("fetch");
    expect(a).toBeDefined();
    expect(b).toBe(a);
    expect(b?.handler).toBe(a?.handler);

    // two users, two contexts, ONE handler
    const userA = makeCtx("userA", { fetchImpl: fetchFake.impl });
    const userB = makeCtx("userB", { fetchImpl: fetchFake.impl });
    const ra = await a!.handler.callTool("fetch", { url: "https://example.com/a" }, userA);
    const rb = await b!.handler.callTool("fetch", { url: "https://example.com/b" }, userB);
    expect(ra.isError).toBe(false);
    expect(rb.isError).toBe(false);
    expect(fetchFake.calls.map((c) => c.url)).toEqual([
      "https://example.com/a",
      "https://example.com/b",
    ]);

    // (b) the counting wrapper recorded exactly one handler construction
    expect(fetchConstructions).toBe(1);

    // memory singleton: the workspace fake saw two DISTINCT uids through one instance
    const mA = catalog.get("memory");
    const mB = catalog.get("memory");
    expect(mB).toBe(mA);
    const rA = await mA!.handler.callTool("read_graph", {}, makeCtx("userA", { workspace: ws.impl }));
    const rB = await mB!.handler.callTool("read_graph", {}, makeCtx("userB", { workspace: ws.impl }));
    expect(rA.isError).toBe(false);
    expect(rB.isError).toBe(false);
    expect(memoryConstructions).toBe(1);
    expect(new Set(ws.uids)).toEqual(new Set(["userA", "userB"]));

    // unknown ids resolve to nothing
    expect(catalog.get("not-a-real-service")).toBeUndefined();
    expect(catalog.get("")).toBeUndefined();
  });

  it("every manifest entry's tools match its live handler's listTools (no drift)", async () => {
    const fetchFake = fakeFetch();
    const catalog = createCuratedCatalog({ fetchImpl: fetchFake.impl, workspace: fakeWorkspace().impl });
    const entries = catalog.entries();
    expect(entries.length).toBe(100);
    expect(entries.map((e) => e.curatedId)).toEqual([...CURATED_IDS]);
    for (const entry of entries) {
      const live = await entry.handler.listTools();
      expect(entry.tools).toEqual(live);
    }
  });

  it("handlers initialize with their curated server identity", async () => {
    const catalog = createCuratedCatalog({
      fetchImpl: fakeFetch().impl,
      workspace: fakeWorkspace().impl,
    });
    const init = await catalog.get("gitlab")!.handler.initialize({});
    expect(init).toMatchObject({
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "gitlab", version: "1.0.0" },
    });
  });
});
