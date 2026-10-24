import { describe, expect, it } from "vitest";

import {
  createStudioGitHttpTransport,
  type StudioGitHttpTransport,
} from "./studioGitHttp.js";
import { StudioGitRefusal } from "./studioGit.js";
import { WorkerUnavailableError } from "./workerClient.js";

const INTERNAL_TOKEN = "internal-http-adapter-test";
const PAT = "ghp_http_adapter_secret_1234567890";
const UID = "verified-user";
const SID = "00000000-0000-4000-8000-000000000003";
const BASE_URL = "http://worker.internal:8091/";
const HEAD_SHA = "0123456789012345678901234567890123456789";
const STATUS = {
  branch: "main",
  headSha: HEAD_SHA,
  upstream: "origin/main",
  dirty: false,
  ahead: 0,
  behind: 0,
  reason: "clean",
  fetchedAt: null,
};

interface CapturedCall {
  url: string;
  init?: RequestInit;
  body: Record<string, unknown>;
}

function transportWith(answer: unknown, status = 200) {
  const calls: CapturedCall[] = [];
  const fetchImpl = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    calls.push({
      url: String(input),
      init,
      body: JSON.parse(String(init?.body)) as Record<string, unknown>,
    });
    return new Response(typeof answer === "string" ? answer : JSON.stringify(answer), {
      status,
      headers: { "content-type": "application/json" },
    });
  };
  const transport = createStudioGitHttpTransport({
    baseUrl: BASE_URL,
    token: INTERNAL_TOKEN,
    fetch: fetchImpl as typeof fetch,
  });
  return { transport, calls };
}

const cloneRequest = { userId: UID, sessionId: SID, repo: "acme/app", branch: "main", dest: "app" };
const repoRequest = { userId: UID, sessionId: SID, repoDir: "app" };
const syncResponse = {
  status: "up_to_date",
  dirty: false,
  behind: 0,
  ahead: 0,
  branch: "main",
  message: "Up to date.",
};
const switchResponse = {
  status: "switched",
  branch: "next",
  stashed: true,
  stashRef: "0123456789012345678901234567890123456789",
  stashNote: "Saved before switching.",
  message: "Switched to next.",
};

const cases: Array<{
  operation: string;
  body: Record<string, unknown>;
  response: Record<string, unknown>;
  invoke: (transport: StudioGitHttpTransport) => Promise<unknown>;
}> = [
  {
    operation: "clone",
    body: { repo: "acme/app", branch: "main", dest: "app" },
    response: { repoDir: "app", branch: "main" },
    invoke: (transport) => transport.clone(cloneRequest),
  },
  {
    operation: "sync",
    body: { repoDir: "app" },
    response: syncResponse,
    invoke: (transport) => transport.sync(repoRequest),
  },
  {
    operation: "switch-branch",
    body: { repoDir: "app", branch: "next" },
    response: switchResponse,
    invoke: (transport) => transport.switchBranch({ ...repoRequest, branch: "next" }),
  },
  {
    operation: "inspect",
    body: { repoDir: "app" },
    response: { ...STATUS, fetchedAt: "2026-10-24T00:00:00.000Z" },
    invoke: (transport) => transport.inspect(repoRequest),
  },
  {
    operation: "status",
    body: { repoDir: "app" },
    response: STATUS,
    invoke: (transport) => transport.status(repoRequest),
  },
  {
    operation: "diff",
    body: { repoDir: "app", staged: true, path: "README.md", maxBytes: 4096 },
    response: { patch: "diff --git a/README.md b/README.md\n", truncated: false },
    invoke: (transport) =>
      transport.diff({ ...repoRequest, staged: true, path: "README.md", maxBytes: 4096 }),
  },
  {
    operation: "logs",
    body: { repoDir: "app", limit: 10 },
    response: { items: [{ sha: HEAD_SHA, subject: "initial", authoredAt: "2026-10-24T00:00:00.000Z" }] },
    invoke: (transport) => transport.logs({ ...repoRequest, limit: 10 }),
  },
  {
    operation: "search",
    body: { repoDir: "app", query: "readme", limit: 10 },
    response: { items: [{ path: "app/README.md", name: "README.md" }], truncated: false },
    invoke: (transport) => transport.search({ ...repoRequest, query: "readme", limit: 10 }),
  },
];

describe("Studio git HTTP adapter", () => {
  it.each(cases)("$operation sends only auth headers and its exact DTO, then validates the answer", async (testCase) => {
    const { transport, calls } = transportWith(testCase.response);
    await expect(testCase.invoke(transport)).resolves.toEqual(testCase.response);
    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.url).toBe(
      `http://worker.internal:8091/internal/sessions/${SID}/studio-git/${testCase.operation}`,
    );
    expect(call.init?.method).toBe("POST");
    expect(Object.fromEntries(new Headers(call.init?.headers).entries())).toEqual({
      "content-type": "application/json",
      "x-ovid-internal-token": INTERNAL_TOKEN,
      "x-ovid-user-id": UID,
    });
    expect(call.body).toEqual(testCase.body);
    expect(call.body).not.toHaveProperty("token");
    expect(JSON.stringify(call)).not.toContain(PAT);
  });

  it("refuses a user/workspace mismatch before any network call on a verified-UID transport", async () => {
    const { transport, calls } = transportWith(STATUS);
    const bound = transport.forUser(UID);

    await expect(bound.status({ ...repoRequest, userId: "different-user" })).rejects.toMatchObject({
      name: "StudioGitRefusal",
      code: "invalid_path",
    });
    expect(calls).toEqual([]);

    await expect(bound.status(repoRequest)).resolves.toEqual(STATUS);
    expect(calls).toHaveLength(1);
    expect(new Headers(calls[0]?.init?.headers).get("x-ovid-user-id")).toBe(UID);
  });

  it("cannot forward extra credential fields even from an untyped caller", async () => {
    const { transport, calls } = transportWith({ repoDir: "app", branch: "main" });
    await transport.clone({ ...cloneRequest, token: PAT, authorization: PAT } as typeof cloneRequest);
    expect(calls[0]?.body).toEqual({ repo: "acme/app", branch: "main", dest: "app" });
    expect(calls[0]?.body).not.toHaveProperty("token");
    expect(JSON.stringify(calls)).not.toContain(PAT);
  });

  it.each([
    "invalid_repo",
    "invalid_path",
    "invalid_branch",
    "destination_exists",
    "not_a_repo",
    "clone_failed",
    "fetch_failed",
    "sync_failed",
    "stash_failed",
    "switch_failed",
    "search_failed",
    "token_unavailable",
    "credential_leak",
  ])("maps a non-2xx %s envelope to StudioGitRefusal without losing stash metadata", async (code) => {
    const { transport } = transportWith(
      { error: { code, message: "Safe worker refusal.", stashRef: "refs/stash@{0}" } },
      409,
    );
    const promise = transport.status(repoRequest);
    await expect(promise).rejects.toBeInstanceOf(StudioGitRefusal);
    await expect(promise).rejects.toMatchObject({
      code,
      message: "Safe worker refusal.",
      stashRef: "refs/stash@{0}",
    });
  });

  it("turns a deadline into WorkerUnavailableError even when fetch ignores abort", async () => {
    let signal: AbortSignal | null | undefined;
    const fetchImpl = ((_input: string | URL | Request, init?: RequestInit) => {
      signal = init?.signal;
      return new Promise<Response>(() => {});
    }) as typeof fetch;
    const transport = createStudioGitHttpTransport({
      baseUrl: BASE_URL,
      token: INTERNAL_TOKEN,
      timeoutMs: 5,
      fetch: fetchImpl,
    });
    await expect(transport.status(repoRequest)).rejects.toBeInstanceOf(WorkerUnavailableError);
    expect(signal?.aborted).toBe(true);
  });

  it.each([
    ["invalid JSON", "{not-json"],
    ["null JSON", null],
    ["wrong success shape", { repoDir: 7 }],
    ["an unexpected response credential", { repoDir: "app", branch: "main", token: PAT }],
  ])("turns malformed transport into WorkerUnavailableError: %s", async (_label, answer) => {
    const { transport } = transportWith(answer);
    const promise = transport.clone(cloneRequest);
    await expect(promise).rejects.toBeInstanceOf(WorkerUnavailableError);
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining(PAT) });
  });

  it("turns a malformed non-2xx envelope into WorkerUnavailableError", async () => {
    const { transport } = transportWith({ error: { code: "upstream", message: PAT } }, 502);
    const promise = transport.status(repoRequest);
    await expect(promise).rejects.toBeInstanceOf(WorkerUnavailableError);
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining(PAT) });
  });

  it("does not forward raw network/provider failure text", async () => {
    const fetchImpl = (async () => {
      throw new Error(`provider failed with ${PAT}`);
    }) as typeof fetch;
    const transport = createStudioGitHttpTransport({
      baseUrl: BASE_URL,
      token: INTERNAL_TOKEN,
      fetch: fetchImpl,
    });
    const promise = transport.status(repoRequest);
    await expect(promise).rejects.toBeInstanceOf(WorkerUnavailableError);
    await expect(promise).rejects.not.toMatchObject({ message: expect.stringContaining(PAT) });
  });
});
