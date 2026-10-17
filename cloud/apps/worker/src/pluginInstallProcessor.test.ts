/**
 * P5 Task 14 — plugin-install processor unit tests (pure: fake repo +
 * fake installer, no Postgres/Redis). The real BullMQ round-trip lives in
 * packages/queue/src/pluginQueue.test.ts.
 */

import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { PluginInstallJob } from "@ovid/queue";
import type { PluginInstallOutcome } from "@ovid/mcp";
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
});
