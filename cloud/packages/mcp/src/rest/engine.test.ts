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
import { createGoogleDriveHandler, createS3Handler } from "./descriptors/data.js";
import type { McpCallContext } from "../transports/native.js";
import type { GuardedFetch } from "../ssrf.js";

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
  return { uid, secrets, workspace: {}, fetchImpl };
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

  it("injects bearer auth with prefix and posts the json body map (linear)", async () => {
    const { calls, impl } = fakeFetch();
    const body = { query: "query { issues(first: 20) { nodes { id title } } }", variables: { x: 1 } };
    const r = await createRestHandler(byId("linear")).callTool(
      "list_issues",
      { body },
      makeCtx({ api_key: "lin_1" }, impl),
    );
    expect(r.isError).toBe(false);
    expect(calls[0].url).toBe("https://api.linear.app/graphql");
    expect(calls[0].init?.method).toBe("POST");
    expect(headersOf(calls[0]).Authorization).toBe("Bearer lin_1");
    expect(calls[0].init?.body).toBe(JSON.stringify(body));
    expect(headersOf(calls[0])["content-type"]).toBe("application/json");
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

  it("appends the queryKey secret param (firebase) and keeps multi-segment document paths", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("firebase")).callTool(
      "get_document",
      { path: "users/u1" },
      makeCtx({ api_key: "K", project_id: "P" }, impl),
    );
    expect(calls[0].url).toBe(
      "https://firestore.googleapis.com/v1/projects/P/databases/(default)/documents/users/u1?key=K",
    );
    expect(headersOf(calls[0]).Authorization).toBeUndefined();
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

  it("form-encodes formBodyArg bodies (stripe-style)", async () => {
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
    await createRestHandler(stripeLike).callTool(
      "create_invoice",
      { body: { customer_id: "cus_1", amount: 100, metadata: { order: "o-9" }, items: ["a", "b"] } },
      makeCtx({ secret_key: "sk_1" }, impl),
    );
    expect(headersOf(calls[0])["content-type"]).toBe("application/x-www-form-urlencoded");
    expect(calls[0].init?.body).toBe(
      "customer_id=cus_1&amount=100&metadata%5Border%5D=o-9&items%5B0%5D=a&items%5B1%5D=b",
    );
  });

  it("missing credential returns the exact configure-first text without fetching", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("linear")).callTool("list_issues", { body: {} }, makeCtx({}, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Configure Linear API key first: open the MCP settings for Linear Sync.");
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

  it("invalid timeout_seconds surfaces as an isError result", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("slack")).callTool(
      "list_channels",
      { timeout_seconds: "abc" },
      makeCtx({ bot_token: "xoxb-1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toContain('Invalid timeout_seconds "abc": expected a number.');
    expect(calls).toHaveLength(0);
  });

  it("an oversized timeout clamps to 300 s and still sends with an abort signal", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("slack")).callTool(
      "list_channels",
      { timeout_seconds: "999" },
      makeCtx({ bot_token: "xoxb-1" }, impl),
    );
    expect(r.isError).toBe(false);
    expect(calls).toHaveLength(1);
    expect(calls[0].init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("non-2xx responses come back verbatim with the status line", async () => {
    const { calls, impl } = fakeFetch(404, '{"ok":false,"error":"channel_not_found"}');
    const r = await createRestHandler(byId("slack")).callTool(
      "history",
      { channel: "C1" },
      makeCtx({ bot_token: "xoxb-1" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe('HTTP 404\n{"ok":false,"error":"channel_not_found"}');
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

  it("unknown tools error with the dart wording", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("gitlab")).callTool("nope", {}, makeCtx({ token: "t" }, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe('Unknown tool: nope for plugin "GitLab MCP".');
    expect(calls).toHaveLength(0);
  });

  it("substitutes path placeholders from stored config (telegram bot token)", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("telegram")).callTool(
      "get_me",
      {},
      makeCtx({ bot_token: "123:ABC" }, impl),
    );
    expect(calls[0].url).toBe("https://api.telegram.org/bot123%3AABC/getMe");
    expect(headersOf(calls[0]).Authorization).toBeUndefined();
  });

  it("expands query-map args and adds static headers (supabase select)", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("supabase")).callTool(
      "select",
      { table: "tasks", query: { select: "*", status: "eq.done" } },
      makeCtx({ service_key: "sk", base_url: "https://xyz.supabase.co" }, impl),
    );
    expect(calls[0].url).toBe("https://xyz.supabase.co/rest/v1/tasks?select=*&status=eq.done");
    expect(headersOf(calls[0]).Authorization).toBe("Bearer sk");
    expect(headersOf(calls[0]).apikey).toBe("sk");
  });

  it("refuses unfiltered supabase writes", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createRestHandler(byId("supabase")).callTool(
      "update",
      { table: "tasks", query: {}, patch_json: { done: true } },
      makeCtx({ service_key: "sk", base_url: "https://xyz.supabase.co" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe(
      'Tool "update" requires a non-empty "query" filter map (unfiltered writes are refused).',
    );
    expect(calls).toHaveLength(0);
  });

  it("synthesizes data-api envelopes (mongodb find)", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("mongodb")).callTool(
      "find",
      { db: "mydb", coll: "things", filter_json: '{"status":"open"}', limit: "7" },
      makeCtx(
        {
          api_key: "K",
          data_api_base: "https://data.mongodb-api.com/app/x/endpoint/data/v1",
          data_source: "Cluster0",
        },
        impl,
      ),
    );
    expect(calls[0].url).toBe("https://data.mongodb-api.com/app/x/endpoint/data/v1/action/find");
    expect(headersOf(calls[0])["api-key"]).toBe("K");
    expect(headersOf(calls[0])["content-type"]).toBe("application/json");
    expect(calls[0].init?.body).toBe(
      JSON.stringify({
        dataSource: "Cluster0",
        database: "mydb",
        collection: "things",
        filter: { status: "open" },
        limit: 7,
      }),
    );
  });

  it("builds nested notion create_page bodies and omits absent children", async () => {
    const { calls, impl } = fakeFetch();
    await createRestHandler(byId("notion")).callTool(
      "create_page",
      { parent_id: "db1", title: "T", text: "hello" },
      makeCtx({ api_key: "nt_1" }, impl),
    );
    expect(JSON.parse(calls[0].init?.body as string)).toEqual({
      parent: { database_id: "db1" },
      properties: { title: { title: [{ text: { content: "T" } }] } },
      children: [
        {
          object: "block",
          type: "paragraph",
          paragraph: { rich_text: [{ type: "text", text: { content: "hello" } }] },
        },
      ],
    });
    expect(headersOf(calls[0])["Notion-Version"]).toBe("2022-06-28");
    expect(headersOf(calls[0]).Authorization).toBe("Bearer nt_1");

    const second = fakeFetch();
    await createRestHandler(byId("notion")).callTool(
      "create_page",
      { parent_id: "db1", title: "T2" },
      makeCtx({ api_key: "nt_1" }, second.impl),
    );
    expect(JSON.parse(second.calls[0].init?.body as string)).toEqual({
      parent: { database_id: "db1" },
      properties: { title: { title: [{ text: { content: "T2" } }] } },
    });
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

  it("gets google drive metadata with fields=* and raw content with alt=media", async () => {
    const meta = fakeFetch();
    await createGoogleDriveHandler().callTool("get_file", { id: "f1" }, makeCtx({ access_token: "t" }, meta.impl));
    expect(new URL(meta.calls[0].url).searchParams.get("fields")).toBe("*");

    const raw = fakeFetch(200, "plain text body");
    await createGoogleDriveHandler().callTool(
      "download_text",
      { id: "f2" },
      makeCtx({ access_token: "t" }, raw.impl),
    );
    expect(new URL(raw.calls[0].url).searchParams.get("alt")).toBe("media");
  });

  it("uploads google drive text as a multipart/related body", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createGoogleDriveHandler().callTool(
      "upload_text",
      { name: "n.txt", text: "hi", folder_id: "fold1" },
      makeCtx({ access_token: "t" }, impl),
    );
    expect(r.isError).toBe(false);
    expect(calls[0].url).toBe(
      "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
    );
    expect(headersOf(calls[0])["content-type"]).toContain("multipart/related; boundary=");
    const body = calls[0].init?.body as string;
    expect(body).toContain("Content-Type: application/json; charset=UTF-8");
    expect(body).toContain('"name":"n.txt"');
    expect(body).toContain('"parents":["fold1"]');
    expect(body).toContain("Content-Type: text/plain");
    expect(body.endsWith("--\r\n") || body.includes("--")).toBe(true);
  });

  it("surfaces missing google drive metadata-name arguments as errors", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createGoogleDriveHandler().callTool(
      "upload_text",
      { text: "hi" },
      makeCtx({ access_token: "t" }, impl),
    );
    expect(r.isError).toBe(true);
    expect(r.text).toBe("Missing required argument: name");
    expect(calls).toHaveLength(0);
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
  };

  /** Recomputes the expected SigV4 header from the captured request and
   * asserts the handler signed exactly that (URL ↔ signer consistency). */
  function expectValidSignature(call: Call, opts: { rawPath: string; body: Uint8Array | string }): void {
    const url = new URL(call.url);
    const amzDate = headersOf(call)["x-amz-date"];
    const expected = s3Authorization({
      accessKeyId: "AKIDEXAMPLE",
      secretAccessKey: "aws-secret",
      region: "us-east-1",
      method: call.init?.method ?? "GET",
      canonicalUri: opts.rawPath,
      queryParameters: Object.fromEntries(url.searchParams),
      headers: { host: url.host, "x-amz-date": amzDate },
      payloadHash: sha256Hex(typeof opts.body === "string" ? Buffer.from(opts.body, "utf8") : opts.body),
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
    expect(r.text).toContain("presign_get");
    expect(r.text).toContain("mybucket/bin");
  });

  it("put_object PUTs text with a payload-signed header", async () => {
    const { calls, impl } = fakeFetch(200, "");
    const r = await createS3Handler().callTool(
      "put_object",
      { key: "notes/hi.txt", text: "hello" },
      makeCtx(s3secrets, impl),
    );
    expect(r.isError).toBe(false);
    expect(r.text).toBe('Put 5 bytes to "notes/hi.txt" in bucket "mybucket".');
    expect(calls[0].init?.method).toBe("PUT");
    expect(new URL(calls[0].url).pathname).toBe("/notes/hi.txt");
    expect(Buffer.from(calls[0].init?.body as unknown as Uint8Array).toString("utf8")).toBe("hello");
    expect(headersOf(calls[0])["content-type"]).toBe("text/plain; charset=utf-8");
    expectValidSignature(calls[0], { rawPath: "/notes/hi.txt", body: Buffer.from("hello", "utf8") });
  });

  it("delete_object DELETEs the key", async () => {
    const { calls, impl } = fakeFetch(204, "");
    const r = await createS3Handler().callTool("delete_object", { key: "old.txt" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(false);
    expect(r.text).toBe('Deleted "old.txt" from bucket "mybucket".');
    expect(calls[0].init?.method).toBe("DELETE");
    expectValidSignature(calls[0], { rawPath: "/old.txt", body: "" });
  });

  it("presign_get signs purely without any network", async () => {
    const { calls, impl } = fakeFetch();
    const r = await createS3Handler().callTool("presign_get", { key: "a/b.txt" }, makeCtx(s3secrets, impl));
    expect(calls).toHaveLength(0);
    const uri = new URL(r.text.trim());
    expect(uri.host).toBe("mybucket.s3.us-east-1.amazonaws.com");
    expect(uri.pathname).toBe("/a/b.txt");
    expect(uri.searchParams.get("X-Amz-Algorithm")).toBe("AWS4-HMAC-SHA256");
    expect(uri.searchParams.get("X-Amz-Expires")).toBe("3600");
    expect(uri.searchParams.get("X-Amz-Credential")).toMatch(/^AKIDEXAMPLE\//);
    expect(uri.searchParams.get("X-Amz-Signature")).toMatch(/^[0-9a-f]{64}$/);
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

  it("non-2xx comes back verbatim with the status line", async () => {
    const { impl } = fakeFetch(403, "<Error><Code>AccessDenied</Code></Error>");
    const r = await createS3Handler().callTool("get_object", { key: "x" }, makeCtx(s3secrets, impl));
    expect(r.isError).toBe(true);
    expect(r.text).toBe("HTTP 403\n<Error><Code>AccessDenied</Code></Error>");
  });
});

describe("curated descriptor data", () => {
  it("is the 16 original REST ids, then the 80-service expansion", () => {
    // The first 16 are pinned forever (users already have them configured).
    expect(CURATED_DESCRIPTORS.slice(0, 16).map((d) => d.curatedId)).toEqual([
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
    // 96 declarative + 4 native = the 100-connector catalogue.
    expect(CURATED_DESCRIPTORS.length).toBe(96);
    expect(new Set(CURATED_DESCRIPTORS.map((d) => d.curatedId)).size).toBe(96);
    // Every expansion descriptor is fully declarative and self-consistent.
    for (const d of CURATED_DESCRIPTORS.slice(16)) {
      expect(d.tools.length, `${d.curatedId} needs at least one tool`).toBeGreaterThan(0);
      for (const t of d.tools) {
        expect(t.name, `${d.curatedId} tool name`).toMatch(/^[a-z][a-z0-9_]*$/);
        // "" is legitimate: it means "the base URL itself" (a GraphQL or
        // account-level POST/GET). Anything else must be root-relative, so a
        // descriptor can never smuggle in a scheme or a host.
        expect(
          t.path === "" || t.path.startsWith("/"),
          `${d.curatedId}.${t.name} path`,
        ).toBe(true);
        expect(t.path).not.toContain("://");
        expect(t.inputSchema).toBeTypeOf("object");
      }
    }
  });

  it("has unique ids and object-shaped tool schemas across all descriptors", () => {
    const ids = ALL_DESCRIPTORS.map((d) => d.curatedId);
    expect(new Set(ids).size).toBe(ids.length);
    for (const d of ALL_DESCRIPTORS) {
      expect(d.displayName).toBeTruthy();
      expect(d.description).toBeTruthy();
      expect(d.tools.length).toBeGreaterThan(0);
      for (const t of d.tools) {
        expect(t.name).toBeTruthy();
        expect(t.description).toBeTruthy();
        expect((t.inputSchema as { type?: string }).type).toBe("object");
      }
    }
  });
});
