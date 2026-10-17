import { beforeEach, describe, expect, it } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import {
  AccountError,
  type Claims,
  type Lifecycle,
  type PublicState,
} from "@ovid/account";
import { registerAccountRoutes, type AccountRouteDeps } from "./account.js";

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

  beforeEach(async () => {
    lifecycle = new FakeLifecycle();
    verifyCalls = [];
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

  it("exposes no public finalize route", async () => {
    const res = await app.inject({ method: "POST", url: "/account/finalize", headers });
    expect(res.statusCode).toBe(404);
  });
});
