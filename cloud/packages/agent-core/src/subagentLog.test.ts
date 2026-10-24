import { constants } from "node:fs";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { afterEach, beforeEach, describe, expect, it } from "vitest";

import {
  SUBAGENT_LOG_LINE_MAX_CHARS,
  SUBAGENT_LOG_MAX_BYTES,
  SUBAGENT_LOG_READ_MAX_BYTES,
  SUBAGENT_LOG_TAIL_DEFAULT,
  SUBAGENT_LOG_TAIL_MAX,
  SUBAGENT_LOG_TRUNCATION_MARKER,
  SubagentLogAuthorizationError,
  clampSubagentLogTailLines,
  createSubagentLog,
  readAuthorizedSubagentLog,
  readSubagentLogTail,
  redactSubagentLogText,
  redactSubagentLogValue,
  subagentLogPath,
  tailSubagentLogText,
} from "./subagentLog.js";

const CANARY = "test-only-secret-canary-7f39b2";
let root: string;
let dir: string;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "ovid-task7-log-"));
  dir = join(root, ".ovid", "logs");
});

afterEach(async () => {
  await rm(root, { recursive: true, force: true });
});

describe("real bounded subagent logs", () => {
  it("creates 0700/0600 append-only logs and redacts on write", async () => {
    const log = await createSubagentLog({
      sessionId: "child-1",
      dir,
      now: () => 123,
      secrets: [CANARY],
      header: { agentType: "research" },
    });
    await log.append({
      type: "tool_result",
      input: { api_key: CANARY, command: `printf '${CANARY}'` },
      authorization: `Bearer ${CANARY}`,
    });
    await log.close();

    expect(log.lastError()).toBeNull();
    expect((await stat(dir)).mode & 0o777).toBe(0o700);
    expect((await stat(log.path)).mode & 0o777).toBe(0o600);
    const raw = await readFile(log.path, "utf8");
    expect(raw).not.toContain(CANARY);
    expect(raw).toContain("[REDACTED]");
    expect(raw).toContain("subagent_log_started");

    const reopened = await createSubagentLog({ sessionId: "child-1", dir });
    await reopened.append({ type: "second_process" });
    await reopened.close();
    const appended = await readFile(log.path, "utf8");
    expect(appended).toBe(raw + appended.slice(raw.length));
    expect(appended).toContain("second_process");
    expect(appended.split("subagent_log_started")).toHaveLength(3);
  });

  it("refuses symlink log files for both writing and reading without following the target", async () => {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const target = join(root, "must-not-be-read-or-written.log");
    await writeFile(target, "original", { mode: 0o600 });
    const path = subagentLogPath("child-link", dir);
    await symlink(target, path);

    await expect(createSubagentLog({ sessionId: "child-link", dir })).rejects.toThrow();
    await expect(readSubagentLogTail({ sessionId: "child-link", dir })).rejects.toThrow();
    expect(await readFile(target, "utf8")).toBe("original");
  });

  it("rejects a parent-directory symlink without creating or exposing its target", async () => {
    await mkdir(join(root, ".ovid"), { recursive: true, mode: 0o700 });
    const outside = join(root, "outside-parent");
    await mkdir(outside, { mode: 0o700 });
    await writeFile(join(outside, "do-not-read"), "parent-canary", { mode: 0o600 });
    await symlink(outside, dir);

    await expect(createSubagentLog({ sessionId: "child-parent-link", dir })).rejects.toThrow();
    await expect(readSubagentLogTail({ sessionId: "child-parent-link", dir })).rejects.toThrow();
    expect(await readdir(outside)).toEqual(["do-not-read"]);
    expect(await readFile(join(outside, "do-not-read"), "utf8")).toBe("parent-canary");
  });

  it("keeps an opened directory descriptor confined across a parent substitution race", async () => {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const originalDirectory = join(root, "descriptor-held-logs");
    const outside = join(root, "race-outside");
    await mkdir(outside, { mode: 0o700 });
    const log = await createSubagentLog({
      sessionId: "child-parent-race",
      dir,
      onDirectoryOpen: async () => {
        await rename(dir, originalDirectory);
        await symlink(outside, dir);
      },
    });
    await log.append({ type: "race_safe" });
    await log.close();

    const originalFile = join(originalDirectory, basename(log.path));
    expect(await readFile(originalFile, "utf8")).toContain("race_safe");
    expect(await readdir(outside)).toEqual([]);
    const tail = await readSubagentLogTail({
      sessionId: "child-parent-race",
      dir: originalDirectory,
    });
    expect(tail.text).toContain("race_safe");
  });

  it("anchors reads to the opened parent during a substitution race", async () => {
    const created = await createSubagentLog({ sessionId: "child-read-race", dir });
    await created.append({ type: "original_real_log" });
    await created.close();
    const heldDirectory = join(root, "read-descriptor-held");
    const outside = join(root, "read-race-outside");
    await mkdir(outside, { mode: 0o700 });
    await writeFile(join(outside, basename(created.path)), "outside-canary", { mode: 0o600 });

    const tail = await readSubagentLogTail({
      sessionId: "child-read-race",
      dir,
      onDirectoryOpen: async () => {
        await rename(dir, heldDirectory);
        await symlink(outside, dir);
      },
    });
    expect(tail.text).toContain("original_real_log");
    expect(tail.text).not.toContain("outside-canary");
    expect(await readFile(join(outside, basename(created.path)), "utf8")).toBe("outside-canary");
    expect(await readFile(join(heldDirectory, basename(created.path)), "utf8"))
      .toContain("original_real_log");
  });

  it("redacts legacy plaintext and signed credentials again on read", async () => {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const path = subagentLogPath("child-legacy", dir);
    await writeFile(path, [
      `Authorization: Bearer ${CANARY}`,
      `{"refresh_token":"${CANARY}","visible":"yes"}`,
      `https://files.invalid/download?x-amz-signature=${CANARY}&name=a`,
      `command=${CANARY}`,
      "",
    ].join("\n"), { mode: 0o600 });
    await chmod(path, 0o600);

    const result = await readSubagentLogTail({
      sessionId: "child-legacy",
      dir,
      secrets: [CANARY],
    });
    expect(result.text).not.toContain(CANARY);
    expect(result.text).toContain("Authorization: [REDACTED]");
    expect(result.text).toContain('"visible":"yes"');
    expect(result.text).toContain("files.invalid/download?x-amz-signature=[REDACTED]");
    expect(result.text).toContain("command=[REDACTED]");
  });

  it("redacts standalone PATs and URL userinfo even without a supplied secret list", () => {
    const pat = "github_pat_TESTONLYSECRET123456";
    const classic = "ghp_TESTONLYSECRET123456";
    const projected = redactSubagentLogText(
      `https://x-access-token:${pat}@github.invalid/org/repo.git ${classic}`,
    );
    expect(projected).not.toContain(pat);
    expect(projected).not.toContain(classic);
    expect(projected).toContain("[REDACTED]");
    expect(projected).toContain("github.invalid/org/repo.git");
  });

  it("redacts x-figma-token and secret-bearing object keys without damaging ordinary hosts", () => {
    const explicit = "nested-key-secret-92c4";
    const projected = redactSubagentLogValue({
      nested: {
        "x-figma-token": "figma-test-only-token",
        "x-figma-token: header-secret": "visible",
        [`note-${explicit}`]: "kept-value",
        "Authorization: Bearer default-header-secret": "kept-too",
        "https://worker.invalid/path": "ordinary-host-value",
      },
    }, [explicit]);
    const serialized = JSON.stringify(projected);
    expect(serialized).not.toContain("figma-test-only-token");
    expect(serialized).not.toContain("header-secret");
    expect(serialized).not.toContain("default-header-secret");
    expect(serialized).not.toContain(explicit);
    expect(serialized).toContain("note-[REDACTED]");
    expect(serialized).toContain("https://worker.invalid/path");
    expect(serialized).toContain("ordinary-host-value");
    expect(redactSubagentLogText("x-figma-token: another-secret"))
      .toBe("x-figma-token: [REDACTED]");
  });

  it("bounds append bytes and reports cap truncation instead of pretending all writes fit", async () => {
    expect(SUBAGENT_LOG_MAX_BYTES).toBe(16_777_216);
    const log = await createSubagentLog({
      sessionId: "child-bounded-write",
      dir,
      maxBytes: 768,
    });
    for (let index = 0; index < 20; index += 1) {
      await log.append({ type: "large", index, payload: "x".repeat(180) });
    }
    await log.close();
    expect(log.truncated()).toBe(true);
    expect(log.lastError()).toBeNull();
    expect((await stat(log.path)).size).toBeLessThanOrEqual(768);
  });

  it("flushes an overflowing write and its real truncation marker on immediate close", async () => {
    const log = await createSubagentLog({
      sessionId: "child-immediate-close",
      dir,
      maxBytes: 640,
    });
    await log.append({ type: "fill", payload: "x".repeat(300) });
    const pending = log.append({ type: "overflow", payload: "y".repeat(500) });
    const closing = log.close();
    await Promise.all([pending, closing]);
    expect(log.lastError()).toBeNull();
    expect(log.truncated()).toBe(true);
    const raw = await readFile(log.path, "utf8");
    expect((await stat(log.path)).size).toBeLessThanOrEqual(640);
    expect(raw).toContain("subagent_log_truncated");
  });

  it("keeps the 200/2,000 tail shape with honest line and byte bounds", async () => {
    expect(SUBAGENT_LOG_TAIL_DEFAULT).toBe(200);
    expect(SUBAGENT_LOG_TAIL_MAX).toBe(2_000);
    expect(clampSubagentLogTailLines(undefined)).toBe(200);
    expect(clampSubagentLogTailLines(0)).toBe(1);
    expect(clampSubagentLogTailLines(2_001)).toBe(2_000);

    const defaultTail = tailSubagentLogText(
      Array.from({ length: 250 }, (_, index) => `line-${index}`).join("\n"),
    );
    expect(defaultTail.lines).toHaveLength(200);
    expect(defaultTail.lines[0]).toBe("line-50");
    expect(defaultTail.truncated).toBe(true);
    expect(defaultTail.text.endsWith(SUBAGENT_LOG_TRUNCATION_MARKER)).toBe(true);

    const aggregate = tailSubagentLogText(
      Array.from({ length: 2_100 }, (_, index) => `${index}:${"x".repeat(2_100)}`).join("\n"),
      2_000,
    );
    expect(aggregate.lines.length).toBeLessThanOrEqual(2_000);
    expect(aggregate.truncated).toBe(true);
    expect(Buffer.byteLength(aggregate.text, "utf8")).toBeLessThanOrEqual(
      SUBAGENT_LOG_READ_MAX_BYTES,
    );
    expect(aggregate.lines.every((line) => line.length <= SUBAGENT_LOG_LINE_MAX_CHARS)).toBe(true);
  });

  it("scans only a bounded suffix of a large real file and marks omitted bytes", async () => {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const path = subagentLogPath("child-large-read", dir);
    const oldMarker = "OLD-LINE-MUST-NOT-BE-RETURNED";
    const content = `${oldMarker}\n${"z".repeat(SUBAGENT_LOG_READ_MAX_BYTES + 100_000)}\nnew-line\n`;
    await writeFile(path, content, { mode: 0o600 });

    const result = await readSubagentLogTail({
      sessionId: "child-large-read",
      dir,
      tailLines: 10,
    });
    expect(result.truncated).toBe(true);
    expect(result.text).not.toContain(oldMarker);
    expect(result.text).toContain("new-line");
    expect(Buffer.byteLength(result.text, "utf8")).toBeLessThanOrEqual(
      SUBAGENT_LOG_READ_MAX_BYTES,
    );
  });

  it("resolves only an authorized @subagent_id through the actual supervisor child list", async () => {
    const log = await createSubagentLog({ sessionId: "child-authorized", dir });
    await log.append({ type: "real_entry", value: 1 });
    await log.close();
    const children = [{ sessionId: "child-authorized" }];

    const result = await readAuthorizedSubagentLog({
      reference: "@child-authorized",
      children,
      dir,
    });
    expect(result.available).toBe(true);
    if (result.available) expect(result.text).toContain("real_entry");

    for (const reference of [
      "child-authorized",
      subagentLogPath("child-authorized", dir),
      "@other-child",
      "@../child-authorized",
    ]) {
      await expect(readAuthorizedSubagentLog({ reference, children, dir }))
        .rejects.toBeInstanceOf(SubagentLogAuthorizationError);
    }
  });

  it("says log unavailable for an authorized child with no real log", async () => {
    const result = await readAuthorizedSubagentLog({
      reference: "@child-without-log",
      children: [{ sessionId: "child-without-log" }],
      dir,
    });
    expect(result).toMatchObject({
      available: false,
      text: "log unavailable",
      lines: [],
      truncated: false,
    });
  });

  it("validates supervisor-owned ids instead of accepting model-controlled paths", () => {
    for (const unsafe of ["../child", "/workspace/log", "child/name", "@child", ""]) {
      expect(() => subagentLogPath(unsafe, dir)).toThrow();
    }
    expect(subagentLogPath("child_SAFE-123", dir)).toBe(
      join(dir, "subagent_child_SAFE-123.log"),
    );
  });
});
