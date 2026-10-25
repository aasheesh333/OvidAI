import { mkdtemp, mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import { StudioPreviewCapacityError } from "../../../packages/db/src/studioPreviewStore.js";

import {
  StudioPreviewError,
  type StudioPreviewManager,
  type StudioPreviewRecord,
} from "./studioPreview.js";
import { registerStudioPreviewRoutes } from "./studioPreviewRoutes.js";

const TOKEN = "studio-preview-internal-token";
const UID = "route-user";
const OTHER_UID = "other-user";
const SID = "00000000-0000-4000-8000-000000000018";
const OTHER_SID = "00000000-0000-4000-8000-000000000019";
const PID = "0199aaaa-0000-7000-8000-000000000018";
const BASE = `/internal/sessions/${SID}/previews`;
const T0 = Date.parse("2026-10-24T12:00:00.000Z");
const cleanup: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) await fn();
});

function record(overrides: Partial<StudioPreviewRecord> = {}): StudioPreviewRecord {
  return {
    id: PID,
    sessionId: SID,
    userId: UID,
    generation: 4,
    kind: "dev_server",
    workspacePath: "/private/workspace",
    projectDir: "/private/workspace/app",
    startScript: "dev",
    processId: 4123,
    processGroupId: "/sys/fs/cgroup/private/preview",
    workerEpoch: "worker-private",
    bindHost: "127.0.0.1",
    port: 20123,
    status: "running",
    createdAt: "2026-10-24T12:00:00.000Z",
    lastAccessAt: null,
    expiresAt: "2026-10-24T12:15:00.000Z",
    endedAt: null,
    exitCode: null,
    failureCode: null,
    logBytes: 12,
    ...overrides,
  };
}

interface Harness {
  app: FastifyInstance;
  previews: StudioPreviewManager;
  root: string;
  start: ReturnType<typeof vi.fn>;
  stopSession: ReturnType<typeof vi.fn>;
  touch: ReturnType<typeof vi.fn>;
  touchWrites: () => number;
  afterNextTouch: (patch: Partial<StudioPreviewRecord>) => void;
}

async function harness(current: StudioPreviewRecord = record()): Promise<Harness> {
  const root = await mkdtemp(join("/tmp/opencode/", "studio-preview-routes-"));
  const app = Fastify({ logger: false });
  const start = vi.fn(async () => current);
  const stopSession = vi.fn(async () => 0);
  let touchWrites = 0;
  let afterTouch: (() => void) | null = null;
  // The DB primitive is boolean. The manager-facing fake below never treats
  // false as a record and always revalidates before returning Record | null.
  const storeTouch = async (input: { id: string; generation: number; now: string }): Promise<boolean> => {
    const at = Date.parse(input.now);
    if (
      current.id !== input.id || current.generation !== input.generation ||
      current.status !== "running" || Date.parse(current.expiresAt) <= at
    ) return false;
    const last = Date.parse(current.lastAccessAt ?? "");
    if (Number.isFinite(last) && at - last < 1_000) return false;
    current = { ...current, lastAccessAt: input.now };
    touchWrites += 1;
    return true;
  };
  const touch = vi.fn(async (req: {
    userId: string;
    sessionId: string;
    id: string;
    generation: number;
    kind?: "static" | "dev_server";
    now?: Date;
  }) => {
    if (
      req.userId !== current.userId || req.sessionId !== current.sessionId ||
      req.id !== current.id || req.generation !== current.generation ||
      (req.kind !== undefined && req.kind !== current.kind) || current.status !== "running"
    ) return null;
    await storeTouch({
      id: req.id,
      generation: req.generation,
      now: (req.now ?? new Date(T0)).toISOString(),
    });
    if (afterTouch !== null) {
      const callback = afterTouch;
      afterTouch = null;
      callback();
    }
    if (
      current.generation !== req.generation || current.status !== "running" ||
      (req.kind !== undefined && current.kind !== req.kind) ||
      Date.parse(current.expiresAt) <= (req.now?.getTime() ?? T0)
    ) return null;
    return current;
  });
  const previews = {
    start,
    touch,
    stop: vi.fn(async (req: { userId: string; sessionId: string; id: string }) =>
      req.userId === current.userId && req.sessionId === current.sessionId && req.id === current.id
        ? { ...current, status: "stopped", endedAt: "2026-10-24T12:01:00.000Z" }
        : null),
    get: vi.fn(async (req: { userId: string; sessionId: string; id?: string }) => {
      if (req.userId !== current.userId || req.sessionId !== current.sessionId) {
        return req.id === undefined ? [] : null;
      }
      if (req.id !== undefined) return req.id === current.id ? current : null;
      return [current];
    }),
    logs: vi.fn(async (req: { userId: string; sessionId: string; id: string }) =>
      req.userId === current.userId && req.sessionId === current.sessionId && req.id === current.id
        ? { text: "redacted log\n", truncated: false }
        : null),
    sweep: vi.fn(async () => 0),
    stopSession,
    close: vi.fn(async () => undefined),
  } as unknown as StudioPreviewManager;
  await registerStudioPreviewRoutes(app, { internalToken: TOKEN, previews });
  cleanup.push(() => app.close(), () => rm(root, { recursive: true, force: true }));
  return {
    app,
    previews,
    root,
    start,
    stopSession,
    touch,
    touchWrites: () => touchWrites,
    afterNextTouch: (patch) => { afterTouch = () => { current = { ...current, ...patch }; }; },
  };
}

function headers(uid = UID): Record<string, string> {
  return { "x-ovid-internal-token": TOKEN, "x-ovid-user-id": uid };
}

function expectPublicDto(body: Record<string, unknown>): void {
  expect(body).toEqual({
    id: PID,
    kind: "dev_server",
    status: expect.any(String),
    generation: 4,
    expiresAt: "2026-10-24T12:15:00.000Z",
    lastAccessAt: null,
    logAvailable: true,
  });
  for (const key of [
    "workspacePath", "projectDir", "startScript", "processId", "processGroupId",
    "workerEpoch", "bindHost", "port", "command", "url", "ticket", "cookie", "secret",
  ]) expect(body).not.toHaveProperty(key);
}

describe("Studio preview internal routes", () => {
  it("requires the internal token and verified uid on every management/static route", async () => {
    const h = await harness();
    const cases = [
      { headers: {}, status: 401 },
      { headers: { "x-ovid-internal-token": "wrong", "x-ovid-user-id": UID }, status: 401 },
      { headers: { "x-ovid-internal-token": TOKEN }, status: 401 },
    ];
    for (const test of cases) {
      for (const request of [
        { method: "GET" as const, url: BASE },
        { method: "POST" as const, url: BASE, payload: { kind: "static", workspacePath: "site" } },
        { method: "GET" as const, url: `${BASE}/${PID}/logs` },
        { method: "GET" as const, url: `${BASE}/${PID}/static/` },
      ]) {
        const response = await h.app.inject({ ...request, headers: test.headers });
        expect(response.statusCode).toBe(test.status);
        expect(response.json()).toEqual({
          error: { code: "unauthenticated", message: expect.any(String) },
        });
      }
    }
    expect(h.start).not.toHaveBeenCalled();
  });

  it("accepts only the two strict create definitions and never a raw command or endpoint", async () => {
    const h = await harness(record({ status: "starting" }));
    const dev = await h.app.inject({
      method: "POST",
      url: BASE,
      headers: headers(),
      payload: { kind: "dev_server", projectDir: "app", script: "dev" },
    });
    expect(dev.statusCode).toBe(201);
    expectPublicDto(dev.json());
    expect(dev.json().status).toBe("starting");
    expect(h.start).toHaveBeenLastCalledWith({
      userId: UID,
      sessionId: SID,
      kind: "dev_server",
      projectDir: "app",
      script: "dev",
    });

    const staticResult = await h.app.inject({
      method: "POST",
      url: BASE,
      headers: headers(),
      payload: { kind: "static", workspacePath: "dist" },
    });
    expect(staticResult.statusCode).toBe(201);
    expect(h.start).toHaveBeenLastCalledWith({
      userId: UID,
      sessionId: SID,
      kind: "static",
      workspacePath: "dist",
    });

    const invalid = [
      { kind: "dev_server", projectDir: "app", script: "build" },
      { kind: "dev_server", projectDir: "app", script: "dev", command: "id" },
      { kind: "dev_server", projectDir: "app", script: "dev", port: 20000 },
      { kind: "dev_server", projectDir: "app", script: "dev", host: "0.0.0.0" },
      { kind: "static", workspacePath: "dist", url: "http://127.0.0.1:20000" },
      { kind: "static", workspacePath: "dist", userId: OTHER_UID },
      { kind: "static", workspacePath: "dist", sessionId: OTHER_SID },
      { kind: "static", workspacePath: "dist", ticket: "secret" },
    ];
    for (const payload of invalid) {
      const response = await h.app.inject({ method: "POST", url: BASE, headers: headers(), payload });
      expect(response.statusCode).toBe(400);
      expect(response.json().error.code).toBe("bad_request");
    }
    expect(h.start).toHaveBeenCalledTimes(2);
  });

  it("lists, gets, stops, and reads logs using only header uid and route sid", async () => {
    const h = await harness();
    const listed = await h.app.inject({ method: "GET", url: BASE, headers: headers() });
    expect(listed.statusCode).toBe(200);
    expect(listed.json()).toEqual({ items: [{
      id: PID,
      kind: "dev_server",
      status: "running",
      generation: 4,
      expiresAt: "2026-10-24T12:15:00.000Z",
      lastAccessAt: null,
      logAvailable: true,
    }] });
    expect(h.previews.get).toHaveBeenCalledWith({ userId: UID, sessionId: SID });

    const got = await h.app.inject({ method: "GET", url: `${BASE}/${PID}`, headers: headers() });
    expect(got.statusCode).toBe(200);
    expectPublicDto(got.json());

    const logs = await h.app.inject({ method: "GET", url: `${BASE}/${PID}/logs`, headers: headers() });
    expect(logs.statusCode).toBe(200);
    expect(logs.json()).toEqual({ text: "redacted log\n", truncated: false });
    expect(h.previews.logs).toHaveBeenCalledWith({ userId: UID, sessionId: SID, id: PID });

    const stopped = await h.app.inject({ method: "POST", url: `${BASE}/${PID}/stop`, headers: headers() });
    expect(stopped.statusCode).toBe(200);
    expect(stopped.json().status).toBe("stopped");
    expect(h.previews.stop).toHaveBeenCalledWith({ userId: UID, sessionId: SID, id: PID });
    expect(h.stopSession).not.toHaveBeenCalled();
  });

  it("non-enumerates wrong-user, wrong-session, and unknown preview ids with no mutation", async () => {
    const h = await harness();
    for (const test of [
      { uid: OTHER_UID, sid: SID },
      { uid: UID, sid: OTHER_SID },
      { uid: OTHER_UID, sid: OTHER_SID },
    ]) {
      const base = `/internal/sessions/${test.sid}/previews/${PID}`;
      for (const request of [
        { method: "GET" as const, url: base },
        { method: "GET" as const, url: `${base}/logs` },
        { method: "GET" as const, url: `${base}/static/` },
        { method: "POST" as const, url: `${base}/stop` },
      ]) {
        const response = await h.app.inject({ ...request, headers: headers(test.uid) });
        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({
          error: { code: "not_found", message: "Preview not found." },
        });
      }
    }
    expect(h.previews.stop).not.toHaveBeenCalled();
    expect(h.stopSession).not.toHaveBeenCalled();

    vi.mocked(h.previews.logs).mockRejectedValueOnce(
      new StudioPreviewError("log_unavailable", "No preview log is available."),
    );
    const unavailable = await h.app.inject({
      method: "GET", url: `${BASE}/${PID}/logs`, headers: headers(OTHER_UID),
    });
    expect(unavailable.statusCode).toBe(404);
    expect(unavailable.json()).toEqual({
      error: { code: "not_found", message: "Preview not found." },
    });
  });

  it("maps capacity denial safely and hides unexpected internals", async () => {
    const h = await harness();
    h.start.mockRejectedValueOnce(new StudioPreviewError("per_user_capacity", "Two previews are already running."));
    const denied = await h.app.inject({
      method: "POST", url: BASE, headers: headers(),
      payload: { kind: "static", workspacePath: "dist" },
    });
    expect(denied.statusCode).toBe(429);
    expect(denied.json()).toEqual({
      error: { code: "per_user_capacity", message: "Two previews are already running." },
    });

    h.start.mockRejectedValueOnce(new StudioPreviewCapacityError("global_capacity"));
    const dbDenied = await h.app.inject({
      method: "POST", url: BASE, headers: headers(),
      payload: { kind: "static", workspacePath: "dist" },
    });
    expect(dbDenied.statusCode).toBe(429);
    expect(dbDenied.json()).toEqual({
      error: {
        code: "global_capacity",
        message: "Preview capacity is full. Retry shortly.",
      },
    });

    h.start.mockRejectedValueOnce(new Error("private workspace and token detail"));
    const failed = await h.app.inject({
      method: "POST", url: BASE, headers: headers(),
      payload: { kind: "static", workspacePath: "dist" },
    });
    expect(failed.statusCode).toBe(500);
    expect(failed.body).not.toContain("private workspace");
    expect(failed.body).not.toContain("token detail");
    expect(failed.json()).toEqual({
      error: { code: "internal", message: "Internal server error." },
    });
  });

  it("serves only real static bytes below the registered root with no-store", async () => {
    const root = await mkdtemp(join("/tmp/opencode/", "studio-preview-static-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    await mkdir(join(root, "assets"));
    await writeFile(join(root, "index.html"), "<h1>preview</h1>");
    await writeFile(join(root, "assets", "app.txt"), "static-text");
    await writeFile(join(root, ".secret"), "do-not-serve");
    await symlink("/etc/passwd", join(root, "escape"));
    const staticRecord = record({
      kind: "static",
      workspacePath: root,
      projectDir: null,
      startScript: null,
      processId: null,
      processGroupId: null,
      workerEpoch: null,
      bindHost: null,
      port: null,
      logBytes: null,
    });
    const h = await harness(staticRecord);

    const index = await h.app.inject({ method: "GET", url: `${BASE}/${PID}/static/`, headers: headers() });
    expect(index.statusCode).toBe(200);
    expect(index.body).toBe("<h1>preview</h1>");
    expect(index.headers["content-type"]).toContain("text/html");
    expect(index.headers["cache-control"]).toBe("private, no-store");
    expect(index.headers["x-content-type-options"]).toBe("nosniff");

    const asset = await h.app.inject({ method: "GET", url: `${BASE}/${PID}/static/assets/app.txt`, headers: headers() });
    expect(asset.statusCode).toBe(200);
    expect(asset.body).toBe("static-text");
    expect(h.touch).toHaveBeenCalledTimes(2);
    // First call wrote; the second was a throttled boolean false but still
    // revalidated the authoritative record and served normally.
    expect(h.touchWrites()).toBe(1);

    for (const path of ["escape", "assets", "../package.json", "%2e%2e/package.json", ".secret", "missing"]) {
      const response = await h.app.inject({ method: "GET", url: `${BASE}/${PID}/static/${path}`, headers: headers() });
      expect([400, 404]).toContain(response.statusCode);
      expect(response.body).not.toContain("root:");
      expect(response.body).not.toContain("do-not-serve");
    }
  });

  it("UNEXECUTED: post-touch status denial prevents static bytes from being served", async () => {
    const root = await mkdtemp(join("/tmp/opencode/", "studio-preview-static-denied-"));
    cleanup.push(() => rm(root, { recursive: true, force: true }));
    await writeFile(join(root, "index.html"), "must-not-be-served");
    const h = await harness(record({
      kind: "static",
      workspacePath: root,
      projectDir: null,
      startScript: null,
      processId: null,
      processGroupId: null,
      workerEpoch: null,
      bindHost: null,
      port: null,
      logBytes: null,
    }));
    h.afterNextTouch({ status: "stopped" });
    const response = await h.app.inject({
      method: "GET", url: `${BASE}/${PID}/static/`, headers: headers(),
    });
    expect(response.statusCode).toBe(404);
    expect(response.body).not.toContain("must-not-be-served");
    expect(h.touch).toHaveBeenCalledTimes(1);
    expect(h.touchWrites()).toBe(1);
  });
});
