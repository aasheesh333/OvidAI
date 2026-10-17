import { mkdtempSync, rmSync } from "node:fs";
import { statfs } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it, vi } from "vitest";
import {
  cacheProjectId,
  createNoopQuotaBackend,
  selectQuotaBackend,
  workspaceProjectId,
} from "./quota.js";

/**
 * Portable quota tests (Task 8 Step 1): project-id math, the noop backend,
 * and selectQuotaBackend's probe agreement. The XFS backend itself cannot be
 * exercised without an XFS prjquota volume (Task 16 activation) — its real
 * proofs are the host/isolation suites; here we pin only that the selection
 * matches the statfs probe of the actual filesystem.
 */

const XFS_MAGIC = 0x58465342;

const roots: string[] = [];
afterAll(() => {
  for (const r of roots) rmSync(r, { recursive: true, force: true });
});

describe("project ids", () => {
  it("workspaceProjectId(uid) === uid", () => {
    expect(workspaceProjectId(200001)).toBe(200001);
  });

  it("cacheProjectId(uid) === uid + 100_000", () => {
    expect(cacheProjectId(200001)).toBe(300001);
  });
});

describe("noop backend", () => {
  it("resolves applyQuota and records nothing", async () => {
    const backend = createNoopQuotaBackend();
    expect(backend.kind).toBe("noop");
    await expect(backend.applyQuota("/nonexistent/anywhere", 1, 2)).resolves.toBeUndefined();
  });
});

describe("selectQuotaBackend", () => {
  it("matches the statfs probe: noop (with a single log-once warning) unless the fs is XFS with the tools", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ovid-quota-"));
    roots.push(dir);
    const probe = await statfs(dir);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const first = await selectQuotaBackend(dir);
      await selectQuotaBackend(dir); // second selection must not re-warn
      if (probe.type !== XFS_MAGIC) {
        // Portable assertion per the brief: not "xfs" unless the CI fs is
        // XFS — the backend must agree with the statfs probe result.
        expect(first.kind).toBe("noop");
        expect(warn).toHaveBeenCalledTimes(1);
      } else {
        // XFS filesystem: xfs only when the xfs_quota/xfs_io tools are also
        // present (the probe checks both); never anything else.
        expect(["xfs", "noop"]).toContain(first.kind);
        expect(warn).toHaveBeenCalledTimes(first.kind === "noop" ? 1 : 0);
      }
    } finally {
      warn.mockRestore();
    }
  });
});
