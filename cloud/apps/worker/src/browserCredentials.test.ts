// UNEXECUTED round-2 browser artifact-publication regressions.
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Db } from "@ovid/db";
import type { SessionEvent } from "@ovid/shared";
import { createFsStorage, type StorageAdapter } from "@ovid/storage";
import { createBrowserArtifactVaultPort } from "./browserCredentials.js";

describe("browser artifact publication failures", () => {
  let root: string;
  let storage: StorageAdapter;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-browser-artifact-"));
    storage = createFsStorage(root);
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  // UNEXECUTED R3-2: real browser registration consumes cdn + grantFactory.
  it("forwards configured CDN into real registration and signs the frozen grant", async () => {
    await writeFile(join(root, "source.txt"), "source");
    const append = vi.fn(async (
      sessionId: string,
      type: SessionEvent["type"],
      payload: Record<string, unknown>,
    ): Promise<SessionEvent> => ({
      sessionId,
      seq: "1",
      type,
      payload,
      ts: "2026-10-25T00:00:00.000Z",
    }));
    const grantFactory = vi.fn(async () => ({
      grantId: "grant-browser-1",
      key: `users/user-1/artifact-shares/browser/sha256-${"a".repeat(64)}/object`,
    }));
    const port = createBrowserArtifactVaultPort({
      db: {} as Db,
      storage,
      events: { append, readSince: vi.fn(), subscribe: vi.fn() },
      workspaceObjects: { registerArtifact: vi.fn() },
      eventMirror: { put: vi.fn() },
      workspaceDir: async () => root,
      quota: {
        reserveArtifact: async (input) => ({ ok: true as const, reservationId: input.artifactId }),
        finalizeUpload: async (input) => ({ ok: true as const, reservationId: input.reservationId }),
        releaseUpload: vi.fn(),
        removeObject: vi.fn(),
      },
      grantFactory,
      cdn: { baseUrl: "https://cdn.test", secret: "s".repeat(32), ttlSeconds: 900 },
      assertProjectFileCapacity: async () => null,
    });

    const rec = await port.registerFromWorkspace!({
      userId: "user-1",
      sessionId: "session-1",
      path: "source.txt",
      mimeType: "text/plain",
    });
    expect(rec?.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(grantFactory).toHaveBeenCalledTimes(1);
    const event = append.mock.calls[0]!;
    expect(event[1]).toBe("artifact_created");
    const url = new URL(String(event[2].url));
    expect(url.searchParams.get("g")).toBe("grant-browser-1");
    expect(url.searchParams.get("v")).toMatch(/^[a-f0-9]{64}$/);
  });

  it("propagates project_file_limit instead of returning null or storing bytes", async () => {
    await writeFile(join(root, "source.txt"), "source");
    const reserveArtifact = vi.fn();
    const port = createBrowserArtifactVaultPort({
      db: {} as Db,
      storage,
      events: { append: vi.fn(), readSince: vi.fn(), subscribe: vi.fn() },
      workspaceObjects: { registerArtifact: vi.fn() },
      eventMirror: { put: vi.fn() },
      workspaceDir: async () => root,
      quota: {
        reserveArtifact,
        finalizeUpload: vi.fn(),
        releaseUpload: vi.fn(),
        removeObject: vi.fn(),
      },
      assertProjectFileCapacity: async () => {
        throw Object.assign(new Error("project full"), { code: "project_file_limit" });
      },
    });

    await expect(port.registerFromWorkspace!({
      userId: "user-1",
      sessionId: "session-1",
      path: "source.txt",
      mimeType: "text/plain",
    })).rejects.toMatchObject({ code: "project_file_limit" });
    expect(reserveArtifact).not.toHaveBeenCalled();
    expect(await storage.getBuffer("source.txt")).not.toBeNull();
  });
});
