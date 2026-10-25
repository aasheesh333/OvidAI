/**
 * Tests for the REST descriptor engine (port of native_plugins/rest_engine.dart
 * part A + the S3 SigV4 special engine) and the curated descriptor data.
 *
 * Every egress goes through a fake ctx.fetchImpl that records the URL/init it
 * was handed — the engine must never touch the network by any other path.
 */

import { describe, expect, it } from "vitest";
import {
  REST_DEFAULT_TIMEOUT_S,
  REST_MAX_TIMEOUT_S,
  REST_MIN_TIMEOUT_S,
  RestFormatException,
  createRestHandler,
  resolveTimeoutSeconds,
  s3Authorization,
  s3PresignedGetUrl,
  sha256Hex,
  type RestServiceDescriptor,
} from "./engine.js";
import {
  COMMS_DESCRIPTORS,
  CURATED_DESCRIPTORS,
  DATA_DESCRIPTORS,
  DEV_DESCRIPTORS,
} from "./descriptors/index.js";
import { createGoogleDriveHandler, createS3Handler, createSupabaseHandler } from "./descriptors/data.js";
import type { McpCallContext } from "../transports/native.js";
import type { GuardedFetch } from "../ssrf.js";
import type { ProviderEgress } from "../egress/responseLimits.js";
import type { ProviderApproval } from "../providers/types.js";

interface Call {
  url: string;
  init?: RequestInit;
}

function fakeFetch(status = 200, body: string | Uint8Array<ArrayBuffer> = "ok"): { calls: Call[]; impl: GuardedFetch } {
  const calls: Call[] = [];
  const nullBodyStatus = status === 204 || status === 205 || status === 304;
  const impl: GuardedFetch = async (url, init) => {
    calls.push({ url, init });
    return new Response(nullBodyStatus ? null : body, { status });
  };
  return { calls, impl };
}

function makeCtx(
  secrets: Record<string, string>,
  fetchImpl: GuardedFetch,
  uid = "u1",
): McpCallContext {
  return { uid, secrets, workspace: {}, fetchImpl, mode: "auto", planMode: false, unattended: false } as McpCallContext;
}

function approvalCtx(
  secrets: Record<string, string>,
  fetchImpl: GuardedFetch,
  approve: (approval: ProviderApproval) => Promise<{
    decision: "allow" | "deny" | "always";
    approval?: ProviderApproval;
  }>,
): McpCallContext {
  return {
    ...makeCtx(secrets, fetchImpl),
    sessionId: "session-1",
    runId: "run-1",
    userId: "u1",
    connectionId: "connection-1",
    providerId: "slack",
    isSubagent: false,
    depth: 0,
    callKey: "call-1",
    signal: new AbortController().signal,
    approveProvider: approve,
  } as McpCallContext;
}

const ALL_DESCRIPTORS = [...DEV_DESCRIPTORS, ...DATA_DESCRIPTORS, ...COMMS_DESCRIPTORS];

function byId(id: string): RestServiceDescriptor {
  const d = ALL_DESCRIPTORS.find((x) => x.curatedId === id);
  if (d === undefined) throw new Error(`missing descriptor fixture: ${id}`);
  return d;
}

function headersOf(c: Call): Record<string, string> {
  return (c.init?.headers ?? {}) as Record<string, string>;
}

/** Engine-only high-risk fixture; production Slack exports read-first operations. */
function externalCommunicationDescriptor(): RestServiceDescriptor {
  return {
    ...byId("slack"),
    credentialKey: "user_token",
    credentialLabel: "Slack user token",
    tools: [{
      name: "send_message",
      description: "Engine approval fixture for one external message.",
      method: "POST",
      path: "/chat.postMessage",
      effect: "external_communication",
      approval: "per_action",
      inputSchema: {
        type: "object",
        properties: {
          channel: { type: "string", minLength: 1, maxLength: 128 },
          text: { type: "string", minLength: 1, maxLength: 4_000 },
        },
        required: ["channel", "text"],
      },
      required: ["channel", "text"],
      bodyTemplate: { channel: "arg:channel", text: "arg:text" },
    }],
  };
}

describe("rest engine", () => {
  it("substitutes path and query args (gitlab list_projects)", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("gitlab")).callTool(
      "list_projects",
      { search: "x" },
      makeCtx({ token: "tok" }, impl),
    );
    expect(r.isError).toBe(false);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://gitlab.com/api/v4/projects?search=x");
    expect(calls[0].init?.method).toBe("GET");
    expect(headersOf(calls[0])["PRIVATE-TOKEN"]).toBe("tok");
  });

  it("routes gitlab to a self-hosted host from config", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("gitlab")).callTool(
      "list_projects",
      {},
      makeCtx({ token: "tok", host: "https://git.example.com/" }, impl),
    );
    expect(calls[0].url).toBe("https://git.example.com/api/v4/projects");
  });

  it("rejects model-supplied GraphQL before reading credentials or fetching (linear)", async () => {
    const { calls, impl } = fakeFetch();
    const body = { query: "query { issues(first: 20) { nodes { id title } } }", variables: { x: 1 } };
    const r = await createRestHandler(byId("linear")).callTool(
      "list_issues",
      { body },
      makeCtx({ personal_api_key: "lin_1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toMatch(/unavailable|invalid/i);
    expect(calls).toHaveLength(0);
  });

  it("injects apiKeyHeader by name (figma X-Figma-Token)", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("figma")).callTool(
      "get_file",
      { file_key: "kf1" },
      makeCtx({ token: "fig_1" }, impl),
    );
    expect(calls[0].url).toBe("https://api.figma.com/v1/files/kf1");
    expect(headersOf(calls[0])["X-Figma-Token"]).toBe("fig_1");
  });

  it("injects basic auth from the username config (jira) and fills {host} from config", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("jira")).callTool(
      "get_issue",
      { key: "PROJ-1" },
      makeCtx({ host: "acme.atlassian.net", email: "a@b.co", api_token: "tok" }, impl),
    );
    expect(calls[0].url).toBe("https://acme.atlassian.net/rest/api/3/issue/PROJ-1");
    expect(headersOf(calls[0]).Authorization).toBe(
      `Basic ${Buffer.from("a@b.co:tok").toString("base64")}`,
    );
  });

  it("uses Firestore Bearer authorization and keeps multi-segment document paths", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("firebase")).callTool(
      "get_document",
      { path: "users/u1" },
      makeCtx({ access_token: "oauth-token", project_id: "P" }, impl),
    );
    expect(calls[0].url).toBe(
      "https://firestore.googleapis.com/v1/projects/P/databases/(default)/documents/users/u1",
    );
    expect(headersOf(calls[0]).Authorization).toBe("Bearer oauth-token");
  });

  it("returns the configure-first message for a missing jira host without fetching", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("jira")).callTool(
      "get_issue",
      { key: "PROJ-1" },
      makeCtx({ email: "a@b.co", api_token: "tok" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Configure Jira host first: open the MCP settings for Jira MCP.");
    expect(calls).toHaveLength(0);
  });

  it("rejects arbitrary formBodyArg bodies instead of forwarding them", async () => {
    const stripeLike: RestServiceDescriptor = {
      curatedId: "stripe-like",
      displayName: "Stripe Test",
      description: "engine capability test fixture",
      baseUrl: "https://api.stripe.example/v1",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "secret_key",
      credentialLabel: "Stripe secret key",
      tools: [
        {
          name: "create_invoice",
          description: "Create an invoice.",
          method: "POST",
          path: "/invoices",
          inputSchema: { type: "object" },
          formBodyArg: "body",
        },
      ],
    };
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(stripeLike).callTool(
      "create_invoice",
      { body: { customer_id: "cus_1", amount: 100, metadata: { order: "o-9" }, items: ["a", "b"] } },
      makeCtx({ secret_key: "sk_1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toMatch(/unavailable|invalid/i);
    expect(calls).toHaveLength(0);
  });

  it("missing credential returns the exact configure-first text without fetching", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("gitlab")).callTool("list_projects", {}, makeCtx({}, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Configure GitLab personal access token first: open the MCP settings for GitLab MCP.");
    expect(calls).toHaveLength(0);
  });

  it("timeout_seconds is tolerant-parsed, clamped 5..300, default 30", () => {
    expect(resolveTimeoutSeconds({})).toBe(REST_DEFAULT_TIMEOUT_S);
    expect(REST_DEFAULT_TIMEOUT_S).toBe(30);
    expect(REST_MIN_TIMEOUT_S).toBe(5);
    expect(REST_MAX_TIMEOUT_S).toBe(300);
    expect(resolveTimeoutSeconds({ timeout_seconds: "999" })).toBe(REST_MAX_TIMEOUT_S);
    expect(resolveTimeoutSeconds({ timeout_seconds: 2 })).toBe(REST_MIN_TIMEOUT_S);
    expect(resolveTimeoutSeconds({ timeout_seconds: "10" })).toBe(10);
    expect(() => resolveTimeoutSeconds({ timeout_seconds: "abc" })).toThrow(RestFormatException);
    expect(() => resolveTimeoutSeconds({ timeout_seconds: "abc" })).toThrow(
      'Invalid timeout_seconds "abc": expected a number.',
    );
    expect(() => resolveTimeoutSeconds({ timeout_seconds: "" })).toThrow(
      'Invalid timeout_seconds "": expected a number.',
    );
  });

  it("wrong-type timeout_seconds is rejected before fetching", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("slack")).callTool(
      "list_channels",
      { timeout_seconds: "abc" },
      makeCtx({ user_token: "xoxp-1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Invalid operation arguments.");
    expect(calls).toHaveLength(0);
  });

  it("an oversized timeout is rejected rather than clamped into a request", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("slack")).callTool(
      "list_channels",
      { timeout_seconds: 999 },
      makeCtx({ user_token: "xoxp-1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Invalid operation arguments.");
    expect(calls).toHaveLength(0);
  });

  it("non-2xx responses expose only a bounded status error", async () => {
    const { calls, impl } = fakeFetch(404, '{"ok":false,"error":"channel_not_found","echo":"xoxp-1"}');
    const r = await createRestHandler(byId("slack")).callTool(
      "history",
      { channel: "C1" },
      makeCtx({ user_token: "xoxp-1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Provider request failed (HTTP 404).");
    expect(r.text).not.toContain("channel_not_found");
    expect(r.text).not.toContain("xoxp-1");
    expect(calls).toHaveLength(1);
  });

  it("trims oversized results at 6000 chars", async () => {
    const big = "A".repeat(20000);
    const { impl } = fakeFetch(200, big);
    const r = await createRestHandler(byId("gitlab")).callTool(
      "list_projects",
      {},
      makeCtx({ token: "tok" }, impl),
    );
    expect(r.isError).toBe(false);
    expect(r.text).toContain("14000 characters omitted");
    expect(r.text.length).toBeLessThan(7000);
    expect(r.text.startsWith("AAAA")).toBe(true);
    expect(r.text.endsWith("AAAA")).toBe(true);
  });

  it("unknown tools fail closed without reflecting model-controlled text", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("gitlab")).callTool("nope-secret-canary", {}, makeCtx({ token: "t" }, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Unknown provider operation.");
    expect(r.text).not.toContain("secret-canary");
    expect(calls).toHaveLength(0);
  });

  it("substitutes and redacts Telegram path credentials", async () => {
    const { calls, impl } = fakeFetch(200, '{"ok":true,"result":{}}');
    await createRestHandler(byId("telegram")).callTool(
      "get_me",
      {},
      makeCtx({ bot_token: "123:ABC" }, impl),
    );
    expect(calls[0].url).toBe("https://api.telegram.org/bot123%3AABC/getMe");
    expect(headersOf(calls[0]).Authorization).toBeUndefined();
  });

  it("rejects Supabase open queries and every unfiltered mutation before fetching", async () => {
    for (const [name, args] of [
      ["select", { table: "tasks", query: { select: "*", status: "eq.done" } }],
      ["update", { table: "tasks", query: {}, patch_json: { done: true } }],
      ["delete", { table: "tasks", query: {} }],
    ] as const) {
      const { calls, impl } = fakeFetch();
      const r = await createSupabaseHandler().callTool(name, args, makeCtx({
        publishable_key: "sb_publishable_test",
        user_jwt: "header.eyJyb2xlIjoiYXV0aGVudGljYXRlZCJ9.signature",
        base_url: "https://xyz.supabase.co",
        allowed_tables: "tasks",
        allowed_columns: "id,title",
      }, impl));
      expect(r.isError).toBe(true);
      expect(calls).toHaveLength(0);
    }
  });

  it("keeps retired MongoDB legacy calls unexecutable", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("mongodb")).callTool("find", {}, makeCtx({}, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Unknown provider operation.");
    expect(calls).toHaveLength(0);
  });

  it("uses the current Notion data-source read and version", async () => {
    const { calls, impl } = fakeFetch(200, '{"results":[]}');
    await createRestHandler(byId("notion")).callTool(
      "query_data_source",
      { data_source_id: "ds1", page_size: 10 },
      makeCtx({ api_key: "nt_1" }, impl),
    );
    expect(JSON.parse(calls[0].init?.body as string)).toEqual({ page_size: 10 });
    expect(headersOf(calls[0])["Notion-Version"]).toBe("2026-03-11");
    expect(headersOf(calls[0]).Authorization).toBe("Bearer nt_1");
    expect(new URL(calls[0].url).pathname).toBe("/v1/data_sources/ds1/query");
  });

  it("maps google drive search args onto drive params (arg rename + default)", async () => {
    const { calls, impl } = fakeFetch();
    await createGoogleDriveHandler().callTool(
      "search",
      { query: "name = 'x'", limit: 5 },
      makeCtx({ access_token: "t" }, impl),
    );
    const url = new URL(calls[0].url);
    expect(url.origin + url.pathname).toBe("https://www.googleapis.com/drive/v3/files");
    expect(url.searchParams.get("q")).toBe("name = 'x'");
    expect(url.searchParams.get("pageSize")).toBe("5");
    expect(headersOf(calls[0]).Authorization).toBe("Bearer t");
  });

  it("separates Drive binary alt=media from native export", async () => {
    const meta = fakeFetch();
    await createGoogleDriveHandler().callTool("get_file", { id: "f1" }, makeCtx({ access_token: "t" }, meta.impl));
    expect(new URL(meta.calls[0].url).searchParams.get("fields")).toBe("id,name,mimeType,capabilities.canDownload");

    const raw = fakeFetch(200, "plain text body");
    await createGoogleDriveHandler().callTool("download_file", { id: "f2" }, makeCtx({ access_token: "t" }, raw.impl));
    expect(new URL(raw.calls[0].url).searchParams.get("alt")).toBe("media");

    const exported = fakeFetch(200, "exported");
    await createGoogleDriveHandler().callTool(
      "export_native",
      { id: "f3", mime_type: "text/plain" },
      makeCtx({ access_token: "t" }, exported.impl),
    );
    expect(new URL(exported.calls[0].url).pathname).toBe("/drive/v3/files/f3/export");
    expect(new URL(exported.calls[0].url).searchParams.get("mimeType")).toBe("text/plain");
  });
});

describe("typed provider execution boundaries", () => {
  it("rejects unknown, wrong, oversized, transport-overriding, body, and GraphQL args before connection resolution", async () => {
    const attempts: Record<string, unknown>[] = [
      { unknown: true },
      { search: 42 },
      { search: "x".repeat(20_000) },
      { baseUrl: "https://evil.example" },
      { base_url: "https://evil.example" },
      { host: "evil.example" },
      { data_api_base: "https://evil.example" },
      { proxy: "http://proxy.example" },
      { headers: { authorization: "attacker" } },
      { auth: "none" },
      { body: { arbitrary: true } },
      { query: "query { viewer { id } }" },
      { variables: { arbitrary: true } },
      { url: "https://evil.example" },
      { method: "POST" },
    ];
    for (const args of attempts) {
      let resolutions = 0;
      const { calls, impl } = fakeFetch();
      const result = await createRestHandler(byId("gitlab"), {
        resolveConnectionConfig: async () => {
          resolutions++;
          return { token: "tok" };
        },
      }).callTool("list_projects", args, makeCtx({ token: "tok" }, impl));
      expect(result.isError, JSON.stringify(args)).toBe(true);
      expect(calls, JSON.stringify(args)).toHaveLength(0);
      expect(resolutions, JSON.stringify(args)).toBe(0);
    }
  });

  it("rejects an unsupported descriptor method before connection resolution", async () => {
    const descriptor: RestServiceDescriptor = {
      ...byId("gitlab"),
      tools: [{ ...byId("gitlab").tools[0], method: "CONNECT" as "GET" }],
    };
    let resolutions = 0;
    const { calls, impl } = fakeFetch();
    const result = await createRestHandler(descriptor, {
      resolveConnectionConfig: async () => {
        resolutions++;
        return { token: "tok" };
      },
    }).callTool("list_projects", {}, makeCtx({ token: "tok" }, impl));
    expect(result.isError).toBe(true);
    expect(calls).toHaveLength(0);
    expect(resolutions).toBe(0);
  });

  it("requires an exactly bound per-action approval before an external communication", async () => {
    let prompts = 0;
    const { calls, impl } = fakeFetch(200, '{"ok":true}');
    const result = await createRestHandler(externalCommunicationDescriptor()).callTool(
      "send_message",
      { channel: "C1", text: "hello" },
      approvalCtx({ user_token: "xoxp-1" }, impl, async (approval) => {
        prompts++;
        expect(approval.operationId).toBe("send_message");
        expect(approval.connectionId).toBe("connection-1");
        expect(approval.userId).toBe("u1");
        return { decision: "allow", approval };
      }),
    );
    expect(result.isError).toBe(false);
    expect(prompts).toBe(1);
    expect(calls).toHaveLength(1);
  });

  it("does not send a high-risk operation when approval is missing or denied", async () => {
    for (const approve of [
      undefined,
      async () => ({ decision: "deny" as const }),
    ]) {
      const { calls, impl } = fakeFetch();
      const base = makeCtx({ user_token: "xoxp-1" }, impl);
      const ctx = {
        ...base,
        sessionId: "session-1",
        runId: "run-1",
        userId: "u1",
        connectionId: "connection-1",
        providerId: "slack",
        approveProvider: approve,
      } as McpCallContext;
      const result = await createRestHandler(externalCommunicationDescriptor()).callTool(
        "send_message",
        { channel: "C1", text: "hello" },
        ctx,
      );
      expect(result.isError).toBe(true);
      expect(calls).toHaveLength(0);
    }
  });

  it("redacts echoed credentials and secret-bearing URLs from successful output", async () => {
    const { impl } = fakeFetch(200, '{"echo":"xoxp-1","url":"https://slack.com/api?token=xoxp-1"}');
    const result = await createRestHandler(byId("slack")).callTool(
      "history",
      { channel: "C1" },
      makeCtx({ user_token: "xoxp-1" }, impl),
    );
    expect(result.isError).toBe(false);
    expect(result.text).not.toContain("xoxp-1");
    expect(result.text).toContain("[REDACTED]");
  });

  it("uses the narrow ProviderEgress consumer instead of the legacy fetch path", async () => {
    const requests: Parameters<ProviderEgress["request"]>[0][] = [];
    const providerEgress: ProviderEgress = {
      async request(req) {
        requests.push(req);
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new Response('{"ok":true}').body!,
          origin: new URL("https://gitlab.com"),
          remoteAddress: "192.0.2.10",
        };
      },
      async close() {},
    };
    const legacy = fakeFetch();
    const result = await createRestHandler(byId("gitlab"), { providerEgress }).callTool(
      "list_projects",
      { search: "typed" },
      makeCtx({ token: "tok" }, legacy.impl),
    );
    expect(result.isError).toBe(false);
    expect(requests).toHaveLength(1);
    expect(requests[0].originKey).toBe("gitlab");
    expect(requests[0].redirect).toBe("deny");
    expect(requests[0].secretValues).toContain("tok");
    expect(legacy.calls).toHaveLength(0);
  });

  it("uses a server-owned Linear GraphQL document with typed variables", async () => {
    const { calls, impl } = fakeFetch(200, '{"data":{"issues":{"nodes":[]}}}');
    const result = await createRestHandler(byId("linear")).callTool(
      "list_issues",
      { first: 2 },
      makeCtx({ personal_api_key: "lin_1" }, impl),
    );
    expect(result.isError).toBe(false);
    expect(calls).toHaveLength(1);
    const body = JSON.parse(calls[0].init?.body as string) as { query: string; variables: unknown };
    expect(body.query).toContain("issues(first: $first)");
    expect(body.variables).toEqual({ first: 2 });
    expect(body.query).not.toContain("viewer");
    const tools = await createRestHandler(byId("linear")).listTools();
    const list = tools.find((tool) => tool.name === "list_issues");
    expect(list?.inputSchema).toMatchObject({ additionalProperties: false });
    expect(JSON.stringify(list?.inputSchema)).not.toContain('"body"');
    expect((list as { effect?: string } | undefined)?.effect).toBe("read");
  });

  it("constructs Exa search from typed fields instead of an arbitrary body", async () => {
    const { calls, impl } = fakeFetch(200, '{"results":[]}');
    const result = await createRestHandler(byId("exa")).callTool(
      "search",
      { query: "typed search", numResults: 3 },
      makeCtx({ api_key: "exa_1" }, impl),
    );
    expect(result.isError).toBe(false);
    expect(JSON.parse(calls[0].init?.body as string)).toEqual({ query: "typed search", numResults: 3 });
    const tools = await createRestHandler(byId("exa")).listTools();
    const search = tools.find((tool) => tool.name === "search");
    expect(JSON.stringify(search?.inputSchema)).not.toContain('"body"');
    expect((search as { effect?: string } | undefined)?.effect).toBe("read");
  });

  it("rejects empty and whitespace-only required strings before writes", async () => {
    for (const text of ["", " \t "]) {
      const { calls, impl } = fakeFetch();
      const result = await createRestHandler(externalCommunicationDescriptor()).callTool(
        "send_message",
        { channel: "C1", text },
        makeCtx({ user_token: "tok" }, impl),
      );
      expect(result.isError, JSON.stringify(text)).toBe(true);
      expect(calls, JSON.stringify(text)).toHaveLength(0);
    }
  });

  it("executes the approval snapshot when caller args mutate after the approval await", async () => {
    const { calls, impl } = fakeFetch(200, '{"ok":true}');
    const args = { channel: "C-original", text: "before-approval" };
    const pending = createRestHandler(externalCommunicationDescriptor()).callTool(
      "send_message",
      args,
      approvalCtx({ user_token: "xoxp-1" }, impl, async (approval) => ({ decision: "allow", approval })),
    );
    args.channel = "C-attacker";
    args.text = "after-approval";
    const result = await pending;
    expect(result.isError).toBe(false);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(String(calls[0].init?.body))).toEqual({ channel: "C-original", text: "before-approval" });
  });

  it("uses the same deep args snapshot after connection resolution awaits", async () => {
    let entered!: () => void;
    const enteredResolver = new Promise<void>((resolve) => { entered = resolve; });
    let release!: () => void;
    const resolverGate = new Promise<void>((resolve) => { release = resolve; });
    const args = {
      db: "mydb",
      coll: "things",
      filter_json: { status: "open", nested: { rank: 1 } },
      limit: 7,
    };
    const descriptor: RestServiceDescriptor = {
      curatedId: "snapshot-fixture",
      displayName: "Snapshot fixture",
      description: "Generic typed snapshot fixture.",
      baseUrl: "https://api.acme.test",
      auth: "bearer",
      authPrefix: "Bearer ",
      credentialKey: "token",
      credentialLabel: "Fixture token",
      extraConfig: [{ key: "data_source", label: "Fixture data source", secret: false }],
      tools: [{
        name: "find",
        description: "Typed snapshot read.",
        method: "POST",
        path: "/action/find",
        effect: "read",
        bodyTemplate: {
          dataSource: "config:data_source",
          database: "arg:db",
          collection: "arg:coll",
          filter: "json:filter_json",
          limit: "int:limit:20",
        },
        inputSchema: {
          type: "object",
          properties: {
            db: { type: "string" },
            coll: { type: "string" },
            filter_json: {
              type: "object",
              properties: {
                status: { type: "string" },
                nested: { type: "object", properties: { rank: { type: "number" } } },
              },
            },
            limit: { type: "integer", minimum: 1, maximum: 100 },
          },
          required: ["db", "coll"],
        },
      }],
    };
    const { calls, impl } = fakeFetch(200, '{"documents":[]}');
    const pending = createRestHandler(descriptor, {
      resolveConnectionConfig: async () => {
        entered();
        await resolverGate;
        return { token: "K", data_source: "Cluster0" };
      },
    }).callTool("find", args, makeCtx({}, impl));
    await enteredResolver;
    args.filter_json.status = "closed";
    args.filter_json.nested.rank = 99;
    args.limit = 99;
    release();
    const result = await pending;
    expect(result.isError).toBe(false);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(calls[0].init?.body as string)).toEqual({
      dataSource: "Cluster0",
      database: "mydb",
      collection: "things",
      filter: { status: "open", nested: { rank: 1 } },
      limit: 7,
    });
  });

  it("cancels the response body when REST header validation fails", async () => {
    let cancelled = 0;
    const body = new ReadableStream<Uint8Array>({
      pull() {},
      cancel() { cancelled++; },
    });
    const impl: GuardedFetch = async () => new Response(body, {
      status: 200,
      headers: { "x-overflow": "x".repeat(9_000) },
    });
    const result = await createRestHandler(byId("gitlab")).callTool(
      "list_projects",
      {},
      makeCtx({ token: "tok" }, impl),
    );
    expect(result.isError).toBe(true);
    expect(cancelled).toBe(1);
  });

  it("publishes closed schemas plus effect, approval, request, limits, and output metadata", async () => {
    const tools = await createRestHandler(externalCommunicationDescriptor()).listTools();
    const send = tools.find((tool) => tool.name === "send_message") as typeof tools[number] & {
      effect: string;
      approval: string;
      request: { originKey: string };
      limits: { responseBytes: number };
      outputPolicy: { kind: string };
    };
    expect(send.effect).toBe("external_communication");
    expect(send.approval).toBe("per_action");
    expect(send.request.originKey).toBe("slack");
    expect(send.limits.responseBytes).toBeGreaterThan(0);
    expect(send.outputPolicy.kind).toBe("redacted_text");
    expect(send.inputSchema).toMatchObject({ additionalProperties: false });
    expect(JSON.stringify(send.inputSchema)).toContain("maxLength");
  });
});

describe("sigv4", () => {
  it("matches the AWS IAM documentation vector", () => {
    const auth = s3Authorization({
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
      region: "us-east-1",
      service: "iam",
      method: "GET",
      canonicalUri: "/",
      queryParameters: { Action: "ListUsers", Version: "2010-05-08" },
      headers: {
        "content-type": "application/x-www-form-urlencoded; charset=utf-8",
        host: "iam.amazonaws.com",
        "x-amz-date": "20150830T123600Z",
      },
      payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      amzDate: new Date(Date.UTC(2015, 7, 30, 12, 36)),
    });
    expect(auth).toBe(
      "AWS4-HMAC-SHA256 " +
        "Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, " +
        "SignedHeaders=content-type;host;x-amz-date, " +
        "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
    );
  });

  it("signing is deterministic and keyed", () => {
    const sign = (secret: string): string =>
      s3Authorization({
        accessKeyId: "AKID",
        secretAccessKey: secret,
        region: "eu-west-1",
        method: "GET",
        canonicalUri: "/",
        headers: { host: "s3.eu-west-1.amazonaws.com", "x-amz-date": "20260101T000000Z" },
        payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        amzDate: new Date(Date.UTC(2026, 0, 1)),
      });
    expect(sign("aaa")).toBe(sign("aaa"));
    expect(sign("aaa")).not.toBe(sign("bbb"));
    expect(sign("aaa")).toMatch(/^AWS4-HMAC-SHA256 Credential=AKID\//);
  });

  it("presign is deterministic for a fixed date", () => {
    const first = s3PresignedGetUrl({
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "aws-secret",
      region: "us-east-1",
      bucket: "mybucket",
      key: "a/b.txt",
      amzDate: new Date(Date.UTC(2026, 0, 2, 3, 4, 5)),
    });
    const second = s3PresignedGetUrl({
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "aws-secret",
      region: "us-east-1",
      bucket: "mybucket",
      key: "a/b.txt",
      amzDate: new Date(Date.UTC(2026, 0, 2, 3, 4, 5)),
    });
    expect(first).toBe(second);
    expect(first).toContain("X-Amz-Date=20260102T030405Z");
    expect(first).toContain("X-Amz-Expires=3600");
  });

  it("presign matches the frozen SigV4 presign vector", () => {
    expect(
      s3PresignedGetUrl({
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        region: "us-east-1",
        bucket: "examplebucket",
        key: "test.txt",
        expiresSeconds: 86400,
        amzDate: new Date(Date.UTC(2013, 4, 24)),
      }),
    ).toBe(
      "https://examplebucket.s3.us-east-1.amazonaws.com/test.txt" +
        "?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
        "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
        "&X-Amz-Date=20130524T000000Z" +
        "&X-Amz-Expires=86400" +
        "&X-Amz-SignedHeaders=host" +
        "&X-Amz-Signature=e88bfc86a6838bda6e6b842bfd69edd8741f6aedb0459e1275be0713ad3e2633",
    );
  });
});

function parseAmzDate(s: string): Date {
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  if (m === null) throw new Error(`bad amz date: ${s}`);
  return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
}

describe("s3 handler", () => {
  const s3secrets: Record<string, string> = {
    secret_access_key: "aws-secret",
    access_key_id: "AKIDEXAMPLE",
    region: "us-east-1",
    bucket: "mybucket",
    session_token: "sts-session-token",
  };

  /** Recomputes the expected SigV4 header from the captured request and
   * asserts the handler signed exactly that (URL ↔ signer consistency). */
  function expectValidSignature(call: Call, opts: { rawPath: string; body: Uint8Array | string }): void {
    const url = new URL(call.url);
    const amzDate = headersOf(call)["x-amz-date"];
    const payloadHash = sha256Hex(typeof opts.body === "string" ? Buffer.from(opts.body, "utf8") : opts.body);
    const expected = s3Authorization({
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "aws-secret",
      region: "us-east-1",
      method: call.init?.method ?? "GET",
      canonicalUri: opts.rawPath,
      queryParameters: Object.fromEntries(url.searchParams),
      headers: {
        host: url.host,
        "x-amz-date": amzDate,
        "x-amz-content-sha256": payloadHash,
        "x-amz-security-token": "sts-session-token",
      },
      payloadHash,
      amzDate: parseAmzDate(amzDate),
    });
    expect(headersOf(call).Authorization).toBe(expected);
  }

  it("list_objects signs a GET with list-type + prefix", async () => {
    const { calls, impl } = fakeFetch(200, "<ListBucketResult/>");
    const r = await createS3Handler().callTool("list_objects", { prefix: "photos/" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(false);
    expect(r.text).toContain("ListBucketResult");
    const url = new URL(calls[0].url);
    expect(calls[0].init?.method).toBe("GET");
    expect(url.host).toBe("mybucket.s3.us-east-1.amazonaws.com");
    expect(url.pathname).toBe("/");
    expect(url.searchParams.get("list-type")).toBe("2");
    expect(url.searchParams.get("prefix")).toBe("photos/");
    expect(headersOf(calls[0]).Authorization).toMatch(/^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\//);
    expect(headersOf(calls[0]).Authorization).toContain("SignedHeaders=host;");
    expectValidSignature(calls[0], { rawPath: "/", body: "" });
  });

  it("get_object GETs the key with literal slashes and inlines small utf-8 text", async () => {
    const { calls, impl } = fakeFetch(200, "hello world");
    const r = await createS3Handler().callTool("get_object", { key: "a/b.txt" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(false);
    expect(r.text).toBe("hello world");
    expect(new URL(calls[0].url).pathname).toBe("/a/b.txt");
    expectValidSignature(calls[0], { rawPath: "/a/b.txt", body: "" });
  });

  it("get_object reports metadata for binary content instead of inlining it", async () => {
    const { impl } = fakeFetch(200, new Uint8Array([0xff, 0xfe, 0x01]));
    const r = await createS3Handler().callTool("get_object", { key: "bin" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(false);
    expect(r.text).toContain("3 bytes");
    expect(r.text).toContain("mybucket/bin");
    expect(r.text).not.toContain("presign_get");
  });

  it("keeps unproven S3 writes and credential minting absent", async () => {
    const tools = await createS3Handler().listTools();
    expect(tools.map((tool) => tool.name)).toEqual(["list_objects", "get_object"]);
    for (const name of ["put_object", "delete_object", "presign_get"]) {
      const { calls, impl } = fakeFetch();
      const result = await createS3Handler().callTool(name, { key: "x", text: "x" }, makeCtx(s3secrets, impl));
      expect(result.isError).toBe(true);
      expect(calls).toHaveLength(0);
    }
  });

  it("requires an STS session token before any S3 egress", async () => {
    const { calls, impl } = fakeFetch();
    const result = await createS3Handler().callTool("list_objects", {}, makeCtx({ ...s3secrets, session_token: "" }, impl));
    expect(result.isError).toBe(true);
    expect(result.text).toContain("session token");
    expect(calls).toHaveLength(0);
  });

  it("missing config gates with configure-first and never fetches", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createS3Handler().callTool(
      "list_objects",
      {},
      makeCtx({ ...s3secrets, bucket: "" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Configure S3 bucket first: open the MCP settings for S3 MCP.");
    expect(calls).toHaveLength(0);
  });

  it("non-2xx returns a bounded status-only error", async () => {
    const { impl } = fakeFetch(403, "<Error><Code>AccessDenied</Code></Error>");
    const r = await createS3Handler().callTool("get_object", { key: "x" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Provider request failed (HTTP 403).");
    expect(r.text).not.toContain("AccessDenied");
  });
});

describe("curated descriptor data", () => {
  it("covers exactly the 16 REST curated ids in pinned order", () => {
    expect(CURATED_DESCRIPTORS.map((d) => d.curatedId)).toEqual([
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
  });

  it("has unique ids and object-shaped tool schemas across all descriptors", () => {
    const ids = ALL_DESCRIPTORS.map((d) => d.curatedId);
    expect(new Set(ids).size).toBe(ids.length);
    for (const d of ALL_DESCRIPTORS) {
      expect(d.displayName).toBeTruthy();
      expect(d.description).toBeTruthy();
      if (d.curatedId === "mongodb") expect(d.tools).toEqual([]);
      else expect(d.tools.length).toBeGreaterThan(0);
      for (const t of d.tools) {
        expect(t.name).toBeTruthy();
        expect(t.description).toBeTruthy();
        expect((t.inputSchema as { type?: string }).type).toBe("object");
      }
    }
  });
});
