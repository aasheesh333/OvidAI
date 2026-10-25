import { describe, expect, it, vi } from "vitest";

import { buildFileService, type FileServiceDeps } from "./fileService.js";
import type { StudioPreviewManager } from "./studioPreview.js";

const TOKEN = "preview-composition-token";

function makeDeps(overrides: Partial<FileServiceDeps> = {}): FileServiceDeps {
  return {
    db: {} as FileServiceDeps["db"],
    events: {} as FileServiceDeps["events"],
    storage: {} as FileServiceDeps["storage"],
    workspacesRoot: "/unused-preview-composition",
    sandboxUid: async () => 1,
    activity: {} as FileServiceDeps["activity"],
    internalToken: TOKEN,
    inlineMaxBytes: 1024,
    port: 0,
    fileManifests: {} as FileServiceDeps["fileManifests"],
    runs: {} as FileServiceDeps["runs"],
    eventMirror: {} as FileServiceDeps["eventMirror"],
    workspaceObjects: {} as FileServiceDeps["workspaceObjects"],
    quota: {} as FileServiceDeps["quota"],
    assertProjectFileCapacity: async () => undefined,
    ...overrides,
  };
}

function managerWith(get: unknown): StudioPreviewManager {
  return { get } as unknown as StudioPreviewManager;
}

const headers = {
  "x-ovid-internal-token": TOKEN,
  "x-ovid-user-id": "user-preview",
};

describe("UNEXECUTED file service Studio preview composition", () => {
  it("leaves preview routes absent when no manager was composed", async () => {
    const app = buildFileService(makeDeps());
    try {
      const response = await app.inject({
        method: "GET",
        url: "/internal/sessions/session-preview/previews",
        headers,
      });
      expect(response.statusCode).toBe(404);
    } finally {
      await app.close();
    }
  });

  it("registers the existing preview manager below the internal preHandler", async () => {
    const get = vi.fn(async () => []);
    const app = buildFileService(makeDeps({ studioPreviews: managerWith(get) }));
    try {
      const response = await app.inject({
        method: "GET",
        url: "/internal/sessions/session-preview/previews",
        headers,
      });
      expect(response.statusCode).toBe(200);
      expect(response.headers["cache-control"]).toBe("private, no-store");
      expect(response.json()).toEqual({ items: [] });
      expect(get).toHaveBeenCalledWith({
        userId: "user-preview",
        sessionId: "session-preview",
      });
    } finally {
      await app.close();
    }
  });

  it("keeps the internal-token gate in front of preview manager calls", async () => {
    const get = vi.fn(async () => []);
    const app = buildFileService(makeDeps({ studioPreviews: managerWith(get) }));
    try {
      const response = await app.inject({
        method: "GET",
        url: "/internal/sessions/session-preview/previews",
        headers: { "x-ovid-user-id": "user-preview" },
      });
      expect(response.statusCode).toBe(401);
      expect(response.json()).toMatchObject({ error: { code: "unauthenticated" } });
      expect(get).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }
  });
});
