/**
 * P5 Task 14 — plugin-install processor unit tests (pure: fake repo +
 * fake installer, no Postgres/Redis). The real BullMQ round-trip lives in
 * packages/queue/src/pluginQueue.test.ts.
 */

import { describe, expect, it } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Db } from "@ovid/db";
import type { PluginInstallJob } from "@ovid/queue";
import type { PluginInstallOutcome, PluginSourceInput } from "@ovid/mcp";
import {
  createPluginInstallProcessor,
  PLUGIN_INSTALL_OUTCOME_STATUS,
  TERMINAL_PLUGIN_STATUSES,
  type PluginInstallRepoPort,
} from "./pluginInstallProcessor.js";

const DB = {} as Db;

function job(over: Partial<PluginInstallJob> = {}): PluginInstallJob {
  return {
    installId: "install-1",
    userId: "user-a",
    pluginId: "acme/demo",
    mode: "install",
    source: { kind: "paste", label: "fixture", config: "{}" },
    ...over,
  };
}

interface Row {
  id: string;
  userId: string;
  pluginId: string;
  status: string;
}

function fakeRepo(rows: Row[] = []): {
  repo: PluginInstallRepoPort;
  rows: Map<string, Row>;
  statuses: string[];
} {
  const byKey = new Map(rows.map((r) => [`${r.userId}/${r.pluginId}`, r]));
  const statuses: string[] = [];
  return {
    rows: byKey,
    statuses,
    repo: {
      async getByPluginId(_db, uid, pluginId) {
        const r = byKey.get(`${uid}/${pluginId}`);
        return r === undefined ? null : { id: r.id, status: r.status };
      },
      async setStatus(_db, id, uid, status) {
        for (const r of byKey.values()) {
          if (r.id === id && r.userId === uid) {
            r.status = status;
            statuses.push(status);
            return;
          }
        }
        throw new Error(`no row ${id} for ${uid}`);
      },
      async adopt(_db, input) {
        const provisional = [...byKey.values()].find(
          (r) => r.id === input.id && r.userId === input.userId,
        );
        if (provisional === undefined) return null;
        if (provisional.pluginId === input.pluginId) {
          return { id: provisional.id, status: provisional.status };
        }
        const existing = byKey.get(`${input.userId}/${input.pluginId}`);
        if (existing !== undefined && existing.id !== provisional.id) {
          // Reinstall: the canonical row (sealed-config AAD) stays.
          byKey.delete(`${input.userId}/${provisional.pluginId}`);
          return { id: existing.id, status: existing.status };
        }
        byKey.delete(`${provisional.userId}/${provisional.pluginId}`);
        provisional.pluginId = input.pluginId;
        byKey.set(`${provisional.userId}/${provisional.pluginId}`, provisional);
        return { id: provisional.id, status: provisional.status };
      },
    },
  };
}

function installerOf(impl: {
  install?: (j: PluginInstallJob) => Promise<PluginInstallOutcome>;
  uninstall?: (j: PluginInstallJob) => Promise<void>;
}) {
  return {
    install:
      impl.install ??
      (async () => ({ status: "active" as const, pluginId: "acme/demo", probeFailures: [] })),
    uninstall: impl.uninstall ?? (async () => {}),
  };
}

describe("createPluginInstallProcessor", () => {
  it("claims a queued row (installing) and maps a pro_required outcome to failed", async () => {
    const { repo, rows, statuses } = fakeRepo([
      { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "queued" },
    ]);
    const seen: string[] = [];
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      logError: () => {},
      installer: installerOf({
        install: async (j) => {
          seen.push(rows.get(`${j.userId}/${j.pluginId}`)!.status);
          // pro_required writes no row of its own (report ruling).
          return { status: "failed", pluginId: j.pluginId, probeFailures: [], reason: "pro_required" };
        },
      }),
    });

    await process({ data: job() });

    expect(seen).toEqual(["installing"]); // claimed before the installer ran
    expect(statuses).toEqual(["installing", "failed"]);
    expect(rows.get("user-a/acme/demo")!.status).toBe("failed");
  });

  it("no-ops a replayed INSTALL job whose row is already terminal", async () => {
    // Uninstall is deliberately NOT gated on terminal status: `active`/
    // `degraded` are exactly the states a legitimate uninstall starts from,
    // and every removal step is idempotent (see the uninstall test below).
    for (const status of TERMINAL_PLUGIN_STATUSES) {
      const { repo } = fakeRepo([
        { id: "row-1", userId: "user-a", pluginId: "acme/demo", status },
      ]);
      let called = false;
      const process = createPluginInstallProcessor({
        db: DB,
        plugins: repo,
        logError: () => {},
        installer: installerOf({
          install: async () => {
            called = true;
            return { status: "active", pluginId: "acme/demo", probeFailures: [] };
          },
        }),
      });
      await process({ data: job() });
      expect(called).toBe(false);
    }
  });

  it("does not clobber a terminal row the installer wrote (active/degraded) or restored", async () => {
    const { repo, rows } = fakeRepo([
      { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "queued" },
    ]);
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      logError: () => {},
      installer: installerOf({
        install: async (j) => {
          // Simulate the installer committing (it writes the row itself).
          rows.get(`${j.userId}/${j.pluginId}`)!.status = "active";
          return { status: "active", pluginId: j.pluginId, probeFailures: [] };
        },
      }),
    });
    await process({ data: job() });
    expect(rows.get("user-a/acme/demo")!.status).toBe("active");
  });

  it("maps grant_denied to rolled_back when the installer left the row live", async () => {
    const { repo, rows } = fakeRepo([
      { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "installing" },
    ]);
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      logError: () => {},
      installer: installerOf({
        install: async () => ({
          status: "failed",
          pluginId: "acme/demo",
          probeFailures: [],
          reason: "grant_denied",
        }),
      }),
    });
    await process({ data: job() });
    expect(rows.get("user-a/acme/demo")!.status).toBe("rolled_back");
    expect(PLUGIN_INSTALL_OUTCOME_STATUS.grant_denied).toBe("rolled_back");
  });

  it("logs a thrown installer error, terminalizes the row, and completes (no rethrow)", async () => {
    const { repo, rows } = fakeRepo([
      { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "installing" },
    ]);
    const logged: string[] = [];
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      logError: (message) => logged.push(message),
      installer: installerOf({
        install: async () => {
          throw new Error("infra boom");
        },
      }),
    });

    await expect(process({ data: job() })).resolves.toBeUndefined();
    expect(logged.some((m) => m.includes("install-1"))).toBe(true);
    expect(rows.get("user-a/acme/demo")!.status).toBe("failed");
  });

  it("uninstall: no row is a no-op; an owned row is claimed uninstalling", async () => {
    // No row for this user — a foreign/replayed uninstall must not run.
    {
      const { repo, statuses } = fakeRepo();
      let called = false;
      const process = createPluginInstallProcessor({
        db: DB,
        plugins: repo,
        logError: () => {},
        installer: installerOf({ uninstall: async () => { called = true; } }),
      });
      await process({ data: job({ mode: "uninstall" }) });
      expect(called).toBe(false);
      expect(statuses).toEqual([]);
    }

    // Owned row → uninstalling, then the installer removes it.
    {
      const { repo, rows, statuses } = fakeRepo([
        { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "active" },
      ]);
      const process = createPluginInstallProcessor({
        db: DB,
        plugins: repo,
        logError: () => {},
        installer: installerOf({
          uninstall: async (j) => {
            expect(rows.get(`${j.userId}/${j.pluginId}`)!.status).toBe("uninstalling");
          },
        }),
      });
      await process({ data: job({ mode: "uninstall" }) });
      expect(statuses).toEqual(["uninstalling"]);
    }
  });

  it("uninstall throw is logged and the row is terminalized failed", async () => {
    const { repo, rows } = fakeRepo([
      { id: "row-1", userId: "user-a", pluginId: "acme/demo", status: "active" },
    ]);
    const logged: string[] = [];
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      logError: (message) => logged.push(message),
      installer: installerOf({
        uninstall: async () => {
          throw new Error("rm boom");
        },
      }),
    });
    await expect(process({ data: job({ mode: "uninstall" }) })).resolves.toBeUndefined();
    expect(logged.some((m) => m.includes("uninstall"))).toBe(true);
    expect(rows.get("user-a/acme/demo")!.status).toBe("failed");
  });

  // -------------------------------------------------------------------------
  // HIGH-3: worker-side identity resolution + row adoption
  // -------------------------------------------------------------------------

  async function pasteFixture(): Promise<string> {
    const dir = await mkdtemp(join(tmpdir(), "processor-identity-"));
    await writeFile(
      join(dir, "plugin.json"),
      JSON.stringify({ name: "Demo Tools", author: "mcp", version: "1.2.3" }),
      "utf8",
    );
    return dir;
  }

  function resolverOf(dir: string) {
    const discarded: string[] = [];
    return {
      discarded,
      resolver: {
        async resolve(_input: PluginSourceInput) {
          return {
            stagingDir: dir,
            async discard() {
              discarded.push(dir);
            },
          };
        },
      },
    };
  }

  it("HIGH-3: needsIdentity resolves the source, adopts the provisional row, and installs the canonical id", async () => {
    const dir = await pasteFixture();
    try {
      const { repo, rows, statuses } = fakeRepo([
        {
          id: "install-1",
          userId: "user-a",
          pluginId: "pending/install-1",
          status: "queued",
        },
      ]);
      const seen: PluginInstallJob[] = [];
      const { resolver, discarded } = resolverOf(dir);
      const process = createPluginInstallProcessor({
        db: DB,
        plugins: repo,
        resolver,
        logError: () => {},
        installer: installerOf({
          install: async (j) => {
            seen.push(j);
            return { status: "active", pluginId: j.pluginId, probeFailures: [] };
          },
        }),
      });

      await process({
        data: job({ pluginId: "pending/install-1", needsIdentity: true }),
      });

      expect(seen).toHaveLength(1);
      expect(seen[0]!.pluginId).toBe("mcp/demo-tools");
      expect(rows.get("user-a/mcp/demo-tools")!.status).toBe("active");
      expect(rows.has("user-a/pending/install-1")).toBe(false);
      expect(statuses).toEqual(["installing", "active"]);
      expect(discarded).toEqual([dir]); // staging discarded after identity read
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("HIGH-3: a resolution failure terminalizes the provisional row and never calls the installer", async () => {
    const { repo, rows } = fakeRepo([
      {
        id: "install-1",
        userId: "user-a",
        pluginId: "pending/install-1",
        status: "queued",
      },
    ]);
    let called = false;
    const process = createPluginInstallProcessor({
      db: DB,
      plugins: repo,
      resolver: {
        async resolve() {
          throw new Error("zip download failed (500)");
        },
      },
      logError: () => {},
      installer: installerOf({
        install: async () => {
          called = true;
          return { status: "active", pluginId: "acme/demo", probeFailures: [] };
        },
      }),
    });

    await process({
      data: job({ pluginId: "pending/install-1", needsIdentity: true }),
    });

    expect(called).toBe(false);
    expect(rows.get("user-a/pending/install-1")!.status).toBe("failed");
  });

  it("HIGH-1: an unsafe/empty resolved version terminalizes the row as failed (never installs)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "processor-badversion-"));
    try {
      // No version → adaptNative defaults to "" (the HIGH-1 regression shape).
      await writeFile(
        join(dir, "plugin.json"),
        JSON.stringify({ name: "No Version", author: "mcp" }),
        "utf8",
      );
      const { repo, rows } = fakeRepo([
        {
          id: "install-1",
          userId: "user-a",
          pluginId: "pending/install-1",
          status: "queued",
        },
      ]);
      let called = false;
      const { resolver } = resolverOf(dir);
      const process = createPluginInstallProcessor({
        db: DB,
        plugins: repo,
        resolver,
        logError: () => {},
        installer: installerOf({
          install: async () => {
            called = true;
            return { status: "active", pluginId: "mcp/no-version", probeFailures: [] };
          },
        }),
      });

      await process({
        data: job({ pluginId: "pending/install-1", needsIdentity: true }),
      });

      expect(called).toBe(false);
      expect(rows.get("user-a/pending/install-1")!.status).toBe("failed");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
