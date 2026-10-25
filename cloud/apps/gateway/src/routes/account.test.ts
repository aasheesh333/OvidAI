import { beforeEach, describe, expect, it } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import {
  AccountError,
  type Claims,
  type DataAdapter,
  type DeletionSession,
  type Lifecycle,
  type PublicState,
} from "@ovid/account";
import {
  registerAccountRoutes,
  withCollabDeletionFence,
  type AccountRouteDeps,
} from "./account.js";

// ---------------------------------------------------------------------------
// Port of server/account/tests/test_api.py — the legacy /account/* contract:
// snake_case bodies, HTTPException-parity {"detail": code}, explicit consent,
// and no public finalize endpoint.
// ---------------------------------------------------------------------------

class FakeLifecycle implements Lifecycle {
  calls: Array<{ op: string; uid: string; requestId?: string }> = [];
  state: PublicState = { state: "active", delete_after: null, request_id: null };

  private uid(claims: Claims): string {
    return String(claims.uid);
  }
  async request(claims: Claims, requestId: string): Promise<PublicState> {
    this.calls.push({ op: "request", uid: this.uid(claims), requestId });
    if (requestId === "bad") throw new AccountError("invalid_request_id", 400);
    this.state = { state: "pending", delete_after: 87_400, request_id: requestId };
    return this.state;
  }
  async status(claims: Claims): Promise<PublicState> {
    this.calls.push({ op: "status", uid: this.uid(claims) });
    return this.state;
  }
  async login(claims: Claims): Promise<PublicState> {
    this.calls.push({ op: "login", uid: this.uid(claims) });
    return this.state;
  }
  async cancel(claims: Claims): Promise<PublicState> {
    this.calls.push({ op: "cancel", uid: this.uid(claims) });
    this.state = { ...this.state, state: "cancelled" };
    return this.state;
  }
  async access<T>(claims: Claims, fn: (uid: string) => Promise<T>): Promise<T> {
    return fn(this.uid(claims));
  }
  async finalize(uid: string): Promise<PublicState> {
    this.calls.push({ op: "finalize", uid });
    return this.state;
  }
}

describe("legacy /account routes", () => {
  let app: FastifyInstance;
  let lifecycle: FakeLifecycle;
  let verifyCalls: Array<{ token: string; attestation: string; allowDisabled: boolean }>;
  let verifyResult: Claims | AccountError;
  let deletionFences: string[];

  beforeEach(async () => {
    lifecycle = new FakeLifecycle();
    verifyCalls = [];
    deletionFences = [];
    verifyResult = {
      uid: "alice",
      auth_time: 1000,
      firebase: { sign_in_provider: "google.com" },
    };
    const deps: AccountRouteDeps = {
      lifecycle,
      verify: async (token, attestation, opts) => {
        verifyCalls.push({ token, attestation, allowDisabled: opts.allowDisabled });
        if (verifyResult instanceof AccountError) throw verifyResult;
        return verifyResult;
      },
      collabLifecycle: {
        onDeletionPending: async (uid) => { deletionFences.push(uid); },
      },
    };
    app = Fastify({ logger: false });
    registerAccountRoutes(app, deps);
    await app.ready();
  });

  const headers = { authorization: "Bearer valid", "x-firebase-appcheck": "attested" };

  it("requires authentication (401 detail) before any lifecycle call", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/account/deletion",
      payload: { request_id: "request-0001" },
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ detail: "missing_authentication" });
    expect(lifecycle.calls).toEqual([]);
  });

  it("maps verifier failures to their AccountError status/detail", async () => {
    verifyResult = new AccountError("invalid_authentication", 401);
    const res = await app.inject({ method: "POST", url: "/account/login", headers });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ detail: "invalid_authentication" });
  });

  it("requests deletion with snake_case fields and rejects uid in the body", async () => {
    const ok = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "request-0001" },
    });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toEqual({ state: "pending", delete_after: 87_400, request_id: "request-0001" });
    expect(lifecycle.calls).toEqual([{ op: "request", uid: "alice", requestId: "request-0001" }]);

    const extra = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "request-0002", uid: "bob" },
    });
    expect(extra.statusCode).toBe(422);
    expect(lifecycle.calls).toHaveLength(1);
  });

  it("returns 400/409 detail codes from the lifecycle", async () => {
    const bad = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "bad" },
    });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toEqual({ detail: "invalid_request_id" });
  });

  it("status/login are observational GET/POST paths with the legacy body", async () => {
    const status = await app.inject({ method: "GET", url: "/account/deletion", headers });
    expect(status.statusCode).toBe(200);
    expect(status.json()).toEqual({ state: "active", delete_after: null, request_id: null });
    const login = await app.inject({ method: "POST", url: "/account/login", headers });
    expect(login.statusCode).toBe(200);
    expect(lifecycle.calls.map((c) => c.op)).toEqual(["status", "login"]);
  });

  it("cancel requires explicit consent and is the only disabled-token path", async () => {
    const refused = await app.inject({
      method: "POST",
      url: "/account/deletion/cancel",
      headers,
      payload: { consent: false },
    });
    expect(refused.statusCode).toBe(400);
    expect(refused.json()).toEqual({ detail: "explicit_consent_required" });
    expect(lifecycle.calls).toEqual([]);

    const extra = await app.inject({
      method: "POST",
      url: "/account/deletion/cancel",
      headers,
      payload: { consent: true, uid: "bob" },
    });
    expect(extra.statusCode).toBe(422);
    expect(lifecycle.calls).toEqual([]);

    const accepted = await app.inject({
      method: "POST",
      url: "/account/deletion/cancel",
      headers,
      payload: { consent: true },
    });
    expect(accepted.statusCode).toBe(200);
    expect(accepted.json()).toMatchObject({ state: "cancelled" });
    expect(verifyCalls.at(-1)!.allowDisabled).toBe(true);
  });

  it("allows a disabled token on status too, but never on login/request", async () => {
    await app.inject({ method: "GET", url: "/account/deletion", headers });
    await app.inject({ method: "POST", url: "/account/login", headers });
    await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "request-0001" },
    });
    expect(verifyCalls.map((c) => c.allowDisabled)).toEqual([true, false, false]);
  });

  it("fences collaboration with the verified UID immediately after deletion becomes pending", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "request-0001", uid: "bob" },
    });
    expect(res.statusCode).toBe(422);
    expect(deletionFences).toEqual([]);

    const ok = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers,
      payload: { request_id: "request-0001" },
    });
    expect(ok.statusCode).toBe(200);
    expect(deletionFences).toEqual(["alice"]);
  });

  it("repeats collaboration fencing at final cleanup while preserving every existing cleanup stage", async () => {
    const calls: string[] = [];
    const original: DataAdapter = {
      prepare: async () => ({}),
      revokeKeys: async () => { calls.push("keys"); },
      deletionSteps: () => [
        { name: "sessions", run: async (uid) => { calls.push(`sessions:${uid}`); } },
        { name: "sql", run: async (uid) => { calls.push(`sql:${uid}`); } },
      ],
      requiredDeletionSteps: [
        { name: "late-sql", run: async (uid) => { calls.push(`late-sql:${uid}`); } },
      ],
    };
    const fenced = withCollabDeletionFence(original, async (uid) => { calls.push(`collab:${uid}`); });
    const initial = fenced.deletionSteps();
    expect(initial.map((step) => step.name)).toEqual(["collab_fencing", "sessions", "sql"]);
    for (const step of initial) await step.run("alice", {});
    const required = fenced.requiredDeletionSteps ?? [];
    expect(required.map((step) => step.name)).toEqual(["collab_fencing_final", "late-sql"]);
    expect(new Set([...initial, ...required].map((step) => step.name)).size)
      .toBe(initial.length + required.length);
    for (const step of required) await step.run("alice", {});
    expect(calls).toEqual([
      "collab:alice", "sessions:alice", "sql:alice", "collab:alice", "late-sql:alice",
    ]);
  });

  // UNEXECUTED fix-round-1 regression: final cleanup reuses its reserved session.
  it("forwards the cleanup reserved session to final collaboration fencing", async () => {
    const original: DataAdapter = {
      prepare: async () => ({}),
      revokeKeys: async () => {},
      deletionSteps: () => [],
    };
    const calls: Array<{ uid: string; connection: unknown }> = [];
    const fenced = withCollabDeletionFence(original, async (uid, connection) => {
      calls.push({ uid, connection });
    });
    const reserved = { db: { reserved: true } } as unknown as DeletionSession;
    const final = fenced.requiredDeletionSteps![0]!;
    await final.run("alice", {}, reserved);
    expect(calls).toEqual([{ uid: "alice", connection: reserved.db }]);
  });

  it("exposes no public finalize route", async () => {
    const res = await app.inject({ method: "POST", url: "/account/finalize", headers });
    expect(res.statusCode).toBe(404);
  });

  // SH-004: the installed app's acknowledgeLogin sends
  // `content-type: application/json` with a null body. Fastify 5's default
  // parser would 400 (FST_ERR_CTP_EMPTY_JSON_BODY) and strand admission.
  it("accepts POST /account/login with a JSON content type and an empty body", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/account/login",
      headers: { ...headers, "content-type": "application/json" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual(lifecycle.state);
    expect(lifecycle.calls.map((c) => c.op)).toEqual(["login"]);
  });

  it("treats an empty JSON body on the other POSTs as a missing body (route validation, not a parser 400)", async () => {
    const del = await app.inject({
      method: "POST",
      url: "/account/deletion",
      headers: { ...headers, "content-type": "application/json" },
    });
    expect(del.statusCode).toBe(422);
    expect(del.json()).toEqual({ detail: "invalid_request" });
    const cancel = await app.inject({
      method: "POST",
      url: "/account/deletion/cancel",
      headers: { ...headers, "content-type": "application/json; charset=utf-8" },
      payload: "",
    });
    expect(cancel.statusCode).toBe(400);
    expect(cancel.json()).toEqual({ detail: "explicit_consent_required" });
  });

  it("still parses a non-empty JSON body and rejects malformed JSON with a 400", async () => {
    const ok = await app.inject({
      method: "POST",
      url: "/account/deletion/cancel",
      headers: { ...headers, "content-type": "application/json" },
      payload: '{"consent":true}',
    });
    expect(ok.statusCode).toBe(200);
    const bad = await app.inject({
      method: "POST",
      url: "/account/login",
      headers: { ...headers, "content-type": "application/json" },
      payload: "{nope",
    });
    expect(bad.statusCode).toBe(400);
    expect(lifecycle.calls.map((c) => c.op)).toEqual(["cancel"]);
  });
});
