/** Pure temporary-filesystem HTTP regressions; no DB, Redis, sockets or jail. */
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { buildFileService, type FileServiceDeps } from "./fileService.js";

const hash = (content: string) => createHash("sha256").update(content).digest("hex");
const headers = { "x-ovid-internal-token": "test-token", "x-ovid-user-id": "test-user" };

describe("file service concurrent conditional saves (pure FS)", () => {
  let root: string;
  let dir: string;
  let app: ReturnType<typeof buildFileService>;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-file-cas-"));
    dir = join(root, "uid-123", "workspace");
    await mkdir(dir, { recursive: true });
    app = buildFileService({
      workspacesRoot: root,
      sandboxUid: async () => "uid-123",
      internalToken: "test-token",
      inlineMaxBytes: 1024,
      port: 0,
      activity: { bump: async () => {} },
      fileManifests: { get: async () => null },
    } as unknown as FileServiceDeps);
  });

  afterEach(async () => {
    await app.close();
    await rm(root, { recursive: true, force: true });
  });

  it.each([false, true])("one save succeeds and eleven return409 baseline_mismatch (distinct sessions: %s)", async (distinctSessions) => {
    await writeFile(join(dir, "a.txt"), "old");
    const responses = await Promise.all(Array.from({ length: 12 }, (_, i) => app.inject({
      method: "PUT",
      url: `/internal/sessions/${distinctSessions ? `session-${i}` : "session"}/file?path=a.txt`,
      headers,
      payload: { contentBase64: Buffer.from(`writer-${i}`).toString("base64"), ifMatchSha256: hash("old") },
    })));
    const accepted = responses.filter((response) => response.statusCode === 200);
    const conflicts = responses.filter((response) => response.statusCode === 409);
    expect(accepted).toHaveLength(1);
    expect(conflicts).toHaveLength(11);
    for (const conflict of conflicts) expect(conflict.json()).toMatchObject({ error: { code: "baseline_mismatch" } });
    expect(hash(await readFile(join(dir, "a.txt"), "utf8"))).toBe(accepted[0]!.json().sha256);
    expect(await readdir(dir)).toEqual(["a.txt"]);
  });

  it("a refused conditional save leaves bytes unchanged and a fresh baseline can save afterward", async () => {
    await writeFile(join(dir, "a.txt"), "current");
    const request = (baseline: string) => app.inject({
      method: "PUT",
      url: "/internal/sessions/session/file?path=a.txt",
      headers,
      payload: { contentBase64: Buffer.from("next").toString("base64"), ifMatchSha256: hash(baseline) },
    });
    const stale = await request("old");
    expect(stale.statusCode).toBe(409);
    expect(stale.json()).toMatchObject({ error: { code: "baseline_mismatch" } });
    expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("current");
    expect((await request("current")).statusCode).toBe(200);
    expect(await readFile(join(dir, "a.txt"), "utf8")).toBe("next");
  });
});
