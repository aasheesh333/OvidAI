import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

const FIXTURE_NAMES = [
  "account-health.json",
  "billing.json",
  "notifications.json",
  "quota.json",
] as const;
const canonicalUrl = new URL("../contracts/fixtures/operations/", import.meta.url);
const webMirrorUrl = new URL(
  "../../../../../OvidWeb/web/test/fixtures/operations/",
  import.meta.url,
);
const flutterMirrorUrl = new URL(
  "../../../../../OvidFlutter/test/fixtures/operations/",
  import.meta.url,
);
const ledgerUrl = new URL(
  "../../../../../OvidWeb/docs/OPERATIONS-RELEASE-GATES.md",
  import.meta.url,
);
const exporter = fileURLToPath(new URL("../contracts/exportOperationsFixtures.mjs", import.meta.url));

const operationGapFields = [
  "requirement",
  "currentEvidence",
  "target",
  "owner",
  "contractFixture",
  "automatedProof",
  "liveProof",
  "externalState",
  "disposition",
] as const;

type OperationGapRow = Record<(typeof operationGapFields)[number], string>;

function readJson(base: URL, name: string): any {
  return JSON.parse(readFileSync(new URL(name, base), "utf8"));
}

function parseLedger(markdown: string): OperationGapRow[] {
  const lines = markdown.split(/\r?\n/);
  const header = `| ${operationGapFields.join(" | ")} |`;
  const rows: OperationGapRow[] = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (lines[index] !== header) continue;
    index += 2;
    while (index < lines.length && lines[index]!.startsWith("| WS")) {
      const cells = lines[index]!.slice(1, -1).split("|").map((cell) => cell.trim());
      expect(cells).toHaveLength(operationGapFields.length);
      rows.push(Object.fromEntries(operationGapFields.map((field, cell) => [field, cells[cell]])) as OperationGapRow);
      index += 1;
    }
  }
  return rows;
}

function notificationDto(value: any) {
  return {
    kind: value.data.kind as string,
    channel: value.data.channel as string,
    sessionId: value.data.sessionId as string,
    route: value.data.route as string,
    sound: value.sound as string,
    androidChannelId: value.androidChannelId as string,
  };
}

function billingEntitlementDto(value: any) {
  return {
    tier: value.tier as string,
    productId: value.productId as string,
    period: value.period as "monthly" | "yearly" | null,
    expiresAt: value.expiresAt as number | null,
    autoRenewing: value.autoRenewing as boolean,
    purchaseState: value.purchaseState as string,
  };
}

function quotaReservationDto(value: any) {
  return {
    reservationId: value.reservationId as string,
    userId: value.userId as string,
    runId: value.runId as string,
    quotaCallId: value.quotaCallId as string,
    source: value.source as string,
    reservedTokens: value.reservedTokens as number,
    status: value.status as string,
  };
}

function accountHealthDto(value: any) {
  return {
    remainingUsd: value.usage.today.remainingUsd as number | null,
    monthlyRemainingUsd: value.usage.month.remainingUsd as number | null,
    multiIpFlags: value.standing.multiIpFlags as boolean | null,
    appCheck: value.security.appCheck as string | null,
    mailOutcome: value.security.mailOutcome as string | null,
  };
}

describe("WS9–WS11 current-gap ledger", () => {
  it("requires all nine fields, bounded external states, and current evidence", () => {
    const rows = parseLedger(readFileSync(ledgerUrl, "utf8"));
    expect(rows.length).toBeGreaterThanOrEqual(3);
    expect(new Set(rows.map((row) => row.requirement.slice(0, 4)))).toEqual(
      new Set(["WS9.", "WS10", "WS11"]),
    );
    for (const row of rows) {
      expect(Object.keys(row)).toHaveLength(9);
      expect(Object.keys(row).sort()).toEqual([...operationGapFields].sort());
      for (const field of operationGapFields) expect(row[field].length).toBeGreaterThan(0);
      expect(row.externalState).toMatch(/^(?:not provided|configured|passed|failed)$/);
      expect(row.currentEvidence).toMatch(/`[^`]+`/);
      expect(row.currentEvidence).not.toMatch(/^\s*(?:PARTIAL|ABSENT|MATCH)\b/i);
      expect(row.disposition).toMatch(/^Open\b/);
    }
  });

  it("records the root-only token-cap baseline without claiming scheduled or child coverage", () => {
    const rows = parseLedger(readFileSync(ledgerUrl, "utf8"));
    const baseline = rows.find(
      (row) => row.requirement.startsWith("WS10.") && /universal token/i.test(row.requirement),
    );
    expect(baseline).toBeDefined();
    expect(baseline!.currentEvidence).toContain("Token caps exist");
    expect(baseline!.currentEvidence).toContain("root-only");
    expect(baseline!.currentEvidence).toContain("scheduled/child paths are not covered");
  });
});

describe("shared operations fixtures", () => {
  it("has byte-identical canonical, Web, and Flutter copies", () => {
    for (const name of FIXTURE_NAMES) {
      const canonical = readFileSync(new URL(name, canonicalUrl));
      expect(readFileSync(new URL(name, webMirrorUrl)), `Web ${name}`).toEqual(canonical);
      expect(readFileSync(new URL(name, flutterMirrorUrl)), `Flutter ${name}`).toEqual(canonical);
    }
  });

  it("covers per-channel metadata and tolerates additive notification fields", () => {
    const fixture = readJson(canonicalUrl, "notifications.json");
    expect(fixture.contractVersion).toBe(1);
    expect(fixture.messages.map((message: any) => message.data.channel)).toEqual([
      "agent_updates",
      "scheduler_results",
      "background_status",
    ]);
    const [agent, scheduler, background] = fixture.messages.map(notificationDto);
    expect(agent).toEqual({
      kind: "agentFinished",
      channel: "agent_updates",
      sessionId: "session-fixture-agent",
      route: "/c/session-fixture-agent",
      sound: "chime",
      androidChannelId: "ovid_agent_updates.chime.v1",
    });
    expect(scheduler.kind).toBe("scheduleSucceeded");
    expect(scheduler.route).toBe("/schedule/session-fixture-scheduler");
    expect(background.sound).toBe("silent");
    expect(background.androidChannelId).toBe("ovid_background_status.silent.v1");
    expect(fixture.messages[0].data.futureMetadata).toEqual({ additive: true });
    expect(fixture.quietHours.utcOffsetMinutes).toBe(330);
  });

  it("preserves a verified yearly entitlement and ignores additive fields", () => {
    const fixture = readJson(canonicalUrl, "billing.json");
    expect(fixture.entitlement.futureEntitlementField).toBe("additive-v2");
    expect(billingEntitlementDto(fixture.entitlement)).toEqual({
      tier: "plus",
      productId: "ovid_pro_yearly",
      period: "yearly",
      expiresAt: 1_800_000_000_000,
      autoRenewing: true,
      purchaseState: "active",
    });
    expect(fixture.unavailableYearly.selectedPackage).toBeNull();
    expect(fixture.unavailableYearly.reason).toBe("not_configured");
  });

  it("covers model and upload reservations without inventing unknown actuals", () => {
    const fixture = readJson(canonicalUrl, "quota.json");
    expect(fixture.modelReservation.futureReservationField).toEqual({ additive: true });
    expect(quotaReservationDto(fixture.modelReservation)).toEqual({
      reservationId: "quota-reservation-fixture-1",
      userId: "user-fixture",
      runId: "run-fixture-schedule-tick",
      quotaCallId: "run-fixture-schedule-tick:attempt-1:call-0",
      source: "schedule_tick",
      reservedTokens: 2000,
      status: "reserved",
    });
    expect(fixture.settlement.costUsd).toBe("0.0000000001");
    expect(fixture.unknownUsage).toEqual({ providerModel: null, costUsd: null });
    expect(fixture.uploadReservation.actorUserId).toBe("actor-fixture");
    expect(fixture.uploadReservation.ownerUserId).toBe("owner-fixture");
    expect(fixture.uploadReservation.declaredBytes).toBe(99);
    expect(fixture.uploadReservation.actualBytes).toBeNull();
    expect(fixture.uploadReservation.actualContentType).toBeNull();
  });

  it("keeps unknown account-health facts null while allowing additive fields", () => {
    const fixture = readJson(canonicalUrl, "account-health.json");
    expect(fixture.accountHealth.futureHealthField).toEqual({ additive: true });
    expect(accountHealthDto(fixture.accountHealth)).toEqual({
      remainingUsd: null,
      monthlyRemainingUsd: null,
      multiIpFlags: null,
      appCheck: null,
      mailOutcome: null,
    });
    expect(fixture.accountHealth.security.anomaly).toBeNull();
    expect(fixture.accountHealth.uploadWindow.used).toBeNull();
    expect(fixture.accountHealth.uploadWindow.remaining).toBeNull();
  });
});

describe("operations fixture exporter", () => {
  let root: string;
  let canaryRoot: string;

  function directoryFor(kind: "source" | "web" | "flutter"): string {
    const directories = {
      source: ["contracts", "fixtures", "operations"],
      web: ["web", "test", "fixtures", "operations"],
      flutter: ["flutter", "test", "fixtures", "operations"],
    };
    return join(root, ...directories[kind]);
  }

  function run(...args: string[]) {
    return spawnSync(process.execPath, [exporter, ...args], {
      encoding: "utf8",
      env: { ...process.env, OVID_OPERATIONS_FIXTURE_ROOT: root },
    });
  }

  function names(kind: "source" | "web" | "flutter"): string[] {
    const directory = directoryFor(kind);
    if (!existsSync(directory)) return [];
    return readdirSync(directory).filter((name) => name.endsWith(".json")).sort();
  }

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "ovid-operations-fixtures-"));
    canaryRoot = mkdtempSync(join(tmpdir(), "ovid-operations-external-canary-"));
    mkdirSync(directoryFor("source"), { recursive: true });
    for (const name of FIXTURE_NAMES) {
      writeFileSync(
        join(directoryFor("source"), name),
        `{\n  "contractVersion": 1,\n  "fixture": "${name}"\n}\n`,
      );
    }
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(canaryRoot, { recursive: true, force: true });
  });

  it("writes deterministic byte-identical mirrors and passes the real --check mode", () => {
    const first = run();
    expect(first.status, first.stderr || first.stdout).toBe(0);
    for (const kind of ["web", "flutter"] as const) {
      expect(names(kind)).toEqual([...FIXTURE_NAMES]);
      for (const name of FIXTURE_NAMES) {
        expect(readFileSync(join(directoryFor(kind), name))).toEqual(
          readFileSync(join(directoryFor("source"), name)),
        );
      }
    }
    const before = names("web").map((name) => readFileSync(join(directoryFor("web"), name)));
    expect(run().status).toBe(0);
    expect(names("web").map((name) => readFileSync(join(directoryFor("web"), name)))).toEqual(before);
    const checked = run("--check");
    expect(checked.status, checked.stderr || checked.stdout).toBe(0);
  });

  it("fails --check on drift without repairing the mirror", () => {
    expect(run().status).toBe(0);
    const drifted = join(directoryFor("web"), "billing.json");
    writeFileSync(drifted, '{"drifted":true}\n');
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("billing.json");
    expect(readFileSync(drifted, "utf8")).toBe('{"drifted":true}\n');
  });

  it("fails --check when a required mirror is missing", () => {
    expect(run().status).toBe(0);
    rmSync(join(directoryFor("flutter"), "quota.json"));
    const checked = run("--check");
    expect(checked.status).not.toBe(0);
    expect(`${checked.stdout}${checked.stderr}`).toContain("quota.json");
  });

  it("cleans stale regular JSON only inside a real mirror directory", () => {
    expect(run().status).toBe(0);
    const stale = join(directoryFor("web"), "stale.json");
    const keep = join(directoryFor("web"), "keep.txt");
    writeFileSync(stale, '{"stale":true}\n');
    writeFileSync(keep, "leave non-JSON files alone\n");
    expect(run().status).toBe(0);
    expect(existsSync(stale)).toBe(false);
    expect(readFileSync(keep, "utf8")).toBe("leave non-JSON files alone\n");
    expect(run("--check").status).toBe(0);
  });

  it("rejects a canonical-named file symlink without overwriting its external target", () => {
    expect(run().status).toBe(0);
    const canary = join(canaryRoot, "file-target.json");
    const canaryBytes = "EXTERNAL FILE CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    const destination = join(directoryFor("web"), "billing.json");
    rmSync(destination);
    symlinkSync(canary, destination);

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(canary, "utf8"), "external file target was overwritten").toBe(canaryBytes);
    expect.soft(lstatSync(destination).isSymbolicLink()).toBe(true);
  });

  it("rejects a symlinked mirror directory without overwriting or deleting external files", () => {
    const outside = join(canaryRoot, "directory-target");
    mkdirSync(outside, { recursive: true });
    const overwritten = join(outside, "billing.json");
    const deleted = join(outside, "stale.json");
    const overwriteCanary = "EXTERNAL DIRECTORY CANARY — MUST NOT CHANGE\n";
    const deleteCanary = "EXTERNAL STALE CANARY — MUST NOT BE DELETED\n";
    writeFileSync(overwritten, overwriteCanary);
    writeFileSync(deleted, deleteCanary);
    mkdirSync(join(directoryFor("web"), ".."), { recursive: true });
    symlinkSync(outside, directoryFor("web"), "dir");

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(overwritten, "utf8"), "external directory file was overwritten").toBe(overwriteCanary);
    expect.soft(readFileSync(deleted, "utf8"), "external stale file was deleted").toBe(deleteCanary);
    expect.soft(lstatSync(directoryFor("web")).isSymbolicLink()).toBe(true);
  });

  it("rejects a symlinked mirror ancestor without touching its external target", () => {
    const outside = join(canaryRoot, "ancestor-target");
    mkdirSync(join(outside, "operations"), { recursive: true });
    const canary = join(outside, "operations", "notifications.json");
    const canaryBytes = "EXTERNAL ANCESTOR CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    const ancestor = join(directoryFor("web"), "..");
    mkdirSync(join(ancestor, ".."), { recursive: true });
    symlinkSync(outside, ancestor, "dir");

    const exported = run();
    expect.soft(exported.status, exported.stderr || exported.stdout).not.toBe(0);
    expect.soft(readFileSync(canary, "utf8"), "external ancestor target was overwritten").toBe(canaryBytes);
    expect.soft(lstatSync(ancestor).isSymbolicLink()).toBe(true);
  });

  it("keeps --check non-mutating and rejects a matching file-symlink target", () => {
    expect(run().status).toBe(0);
    const name = "billing.json";
    const source = join(directoryFor("source"), name);
    const destination = join(directoryFor("web"), name);
    const canary = join(canaryRoot, "matching-check-target.json");
    writeFileSync(canary, readFileSync(source));
    rmSync(destination);
    symlinkSync(canary, destination);
    const before = readFileSync(canary);

    const checked = run("--check");
    expect.soft(checked.status, checked.stderr || checked.stdout).not.toBe(0);
    expect.soft(readFileSync(canary)).toEqual(before);
    expect.soft(lstatSync(destination).isSymbolicLink()).toBe(true);
  });

  it("keeps --check non-mutating and rejects a matching directory-symlink target", () => {
    expect(run().status).toBe(0);
    const outside = join(canaryRoot, "matching-directory-target");
    mkdirSync(outside, { recursive: true });
    for (const name of FIXTURE_NAMES) {
      writeFileSync(join(outside, name), readFileSync(join(directoryFor("source"), name)));
    }
    rmSync(directoryFor("web"), { recursive: true });
    symlinkSync(outside, directoryFor("web"), "dir");
    const before = readdirSync(outside).sort().map((name) => readFileSync(join(outside, name)));

    const checked = run("--check");
    expect.soft(checked.status, checked.stderr || checked.stdout).not.toBe(0);
    expect.soft(readdirSync(outside).sort().map((name) => readFileSync(join(outside, name)))).toEqual(before);
    expect.soft(lstatSync(directoryFor("web")).isSymbolicLink()).toBe(true);
  });

  it("contains a concurrent mirror-directory replacement and rejects the run", async () => {
    const outside = join(canaryRoot, "concurrent-target");
    mkdirSync(outside, { recursive: true });
    const canary = join(outside, "quota.json");
    const canaryBytes = "EXTERNAL CONCURRENT CANARY — MUST NOT CHANGE\n";
    writeFileSync(canary, canaryBytes);
    for (let index = 0; index < 80; index += 1) {
      const name = `race-${String(index).padStart(3, "0")}.json`;
      writeFileSync(join(directoryFor("source"), name), `${JSON.stringify({ padding: "x".repeat(32768) })}\n`);
    }
    mkdirSync(directoryFor("web"), { recursive: true });

    const child = spawn(process.execPath, [exporter], {
      env: { ...process.env, OVID_OPERATIONS_FIXTURE_ROOT: root },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    const completed = new Promise<{ status: number | null }>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (status) => resolve({ status }));
    });

    try {
      const deadline = Date.now() + 4_000;
      while (!existsSync(join(directoryFor("web"), "account-health.json"))) {
        if (Date.now() > deadline) throw new Error(`first mirror write not observed: ${stdout}${stderr}`);
        await new Promise((resolve) => setTimeout(resolve, 1));
      }
      renameSync(directoryFor("web"), `${directoryFor("web")}-held`);
      symlinkSync(outside, directoryFor("web"), "dir");

      const result = await completed;
      expect.soft(result.status, stderr || stdout).not.toBe(0);
      expect.soft(readFileSync(canary, "utf8"), "concurrent replacement overwrote the external target").toBe(canaryBytes);
      expect.soft(readdirSync(outside), "concurrent replacement wrote extra external files").toEqual(["quota.json"]);
    } finally {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      await completed;
    }
  }, 15_000);
});
