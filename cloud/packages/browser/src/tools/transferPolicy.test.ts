import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  isAllowedTransferMime,
  mimeTypeForFilename,
  normalizeMimeType,
  resolveWorkspaceDir,
  resolveWorkspaceEntry,
  sanitizeFilename,
} from "./transferPolicy.js";

describe("transfer policy", () => {
  let root: string;
  let outside: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-transfer-root-"));
    outside = await mkdtemp(join(tmpdir(), "ovid-transfer-outside-"));
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  });

  describe("MIME allowlist", () => {
    it("normalizes parameters and casing", () => {
      expect(normalizeMimeType("Text/Plain; charset=UTF-8")).toBe("text/plain");
      expect(normalizeMimeType(" application/pdf ")).toBe("application/pdf");
    });

    it("falls back to octet-stream for missing or malformed declarations", () => {
      expect(normalizeMimeType(null)).toBe("application/octet-stream");
      expect(normalizeMimeType("")).toBe("application/octet-stream");
      expect(normalizeMimeType("not a mime")).toBe("application/octet-stream");
    });

    it("allows attachments and refuses active content", () => {
      expect(isAllowedTransferMime("image/png")).toBe(true);
      expect(isAllowedTransferMime("text/csv; charset=utf-8")).toBe(true);
      expect(isAllowedTransferMime("application/octet-stream")).toBe(true);
      expect(isAllowedTransferMime("text/html")).toBe(false);
      expect(isAllowedTransferMime("image/svg+xml")).toBe(false);
      expect(isAllowedTransferMime("application/javascript")).toBe(false);
      expect(isAllowedTransferMime("application/x-msdownload")).toBe(false);
    });

    it("types uploads by extension only", () => {
      expect(mimeTypeForFilename("photo.PNG")).toBe("image/png");
      expect(mimeTypeForFilename("report.final.pdf")).toBe("application/pdf");
      expect(mimeTypeForFilename("run.sh")).toBeNull();
      expect(mimeTypeForFilename("page.html")).toBeNull();
      expect(mimeTypeForFilename("icon.svg")).toBeNull();
      expect(mimeTypeForFilename("README")).toBeNull();
      expect(mimeTypeForFilename(".env")).toBeNull();
    });

    it("sanitizes to a single plain filename", () => {
      expect(sanitizeFilename("report.txt")).toBe("report.txt");
      expect(sanitizeFilename("../report.txt")).toBeNull();
      expect(sanitizeFilename("/etc/passwd")).toBeNull();
      expect(sanitizeFilename("a/b.txt")).toBeNull();
      expect(sanitizeFilename("a\\b.txt")).toBeNull();
      expect(sanitizeFilename("..")).toBeNull();
    });
  });

  describe("workspace jail", () => {
    it("resolves a file inside the workspace and reports its relative path", async () => {
      await mkdir(join(root, "uploads"));
      await writeFile(join(root, "uploads", "hello.txt"), "hi");

      const result = await resolveWorkspaceEntry(root, "uploads/hello.txt");
      expect(result).toEqual({
        ok: true,
        abs: join(root, "uploads", "hello.txt"),
        rel: "uploads/hello.txt",
      });
    });

    it("rejects traversal and absolute paths lexically", async () => {
      expect(await resolveWorkspaceEntry(root, "../secret.txt")).toEqual({
        ok: false,
        reason: "escape",
      });
      expect(await resolveWorkspaceEntry(root, "/etc/passwd")).toEqual({
        ok: false,
        reason: "escape",
      });
      expect(await resolveWorkspaceEntry(root, "")).toEqual({ ok: false, reason: "invalid" });
    });

    it("rejects a symlink that points outside the workspace", async () => {
      await writeFile(join(outside, "secret.txt"), "not yours");
      await symlink(outside, join(root, "linked"), "dir");

      expect(await resolveWorkspaceEntry(root, "linked/secret.txt")).toEqual({
        ok: false,
        reason: "escape",
      });
    });

    it("creates nested directories inside the workspace", async () => {
      const dir = await resolveWorkspaceDir(root, "browser/downloads");
      expect(dir).toBe(join(root, "browser", "downloads"));
      expect(existsSync(dir as string)).toBe(true);
    });

    it("refuses to create directories through a symlink that leaves the workspace", async () => {
      await symlink(outside, join(root, "browser"), "dir");

      expect(await resolveWorkspaceDir(root, "browser/downloads")).toBeNull();
      expect(existsSync(join(outside, "downloads"))).toBe(false);
    });
  });
});
