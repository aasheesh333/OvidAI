import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type {
  ApprovalDecision,
  ApprovalGate,
  ApprovalRequest,
  Tool,
  ToolContext,
} from "@ovid/agent-core";
import type { StudioRepoBinding, StudioRepoUpsert } from "@ovid/db";

import {
  createStudioAgentTools,
  type StudioAgentGitService,
} from "./studioAgentTools.js";
import {
  StudioGitError,
  type StudioCloneResult,
  type StudioGit,
  type StudioGitTokenRequest,
  type StudioSwitchResult,
  type StudioSyncResult,
} from "./studioGit.js";
import {
  StudioRunBindingError,
  type StudioRunBindingIdentity,
  type StudioRunBindingPort,
} from "./studioRunBinding.js";

const UID = "user-owner";
const SESSION_ID = "11111111-1111-4111-8111-111111111111";
const FOREIGN_SESSION_ID = "22222222-2222-4222-8222-222222222222";
const TOKEN = "synthetic-studio-agent-token";
const NOW = new Date("2026-10-24T12:00:00.000Z");

function context(patch: Partial<ToolContext> = {}): ToolContext {
  return {
    sessionId: SESSION_ID,
    runId: "run-studio",
    userId: UID,
    mode: "studio",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "call-studio",
    signal: new AbortController().signal,
    ...patch,
  };
}

function row(patch: Partial<StudioRepoBinding> = {}): StudioRepoBinding {
  return {
    sessionId: SESSION_ID,
    userId: UID,
    repo: "acme/app",
    repoDir: "app",
    branch: "main",
    createdAt: NOW,
    updatedAt: NOW,
    ...patch,
  };
}

class MemoryBinding implements StudioRunBindingPort {
  current: StudioRepoBinding | null;
  failNextUpsert = false;
  staleNextCas = false;
  readonly reads: StudioRunBindingIdentity[] = [];
  readonly upserts: StudioRepoUpsert[] = [];
  readonly cas: Array<{ expected: StudioRepoBinding; branch: string }> = [];

  constructor(
    private readonly order: string[],
    initial: StudioRepoBinding | null = row(),
  ) {
    this.current = initial;
  }

  private verify(identity: StudioRunBindingIdentity): void {
    if (identity.userId !== UID || identity.sessionId !== SESSION_ID) {
      throw new StudioRunBindingError();
    }
  }

  async get(identity: StudioRunBindingIdentity): Promise<StudioRepoBinding | null> {
    this.verify(identity);
    this.reads.push(identity);
    return this.current;
  }

  async upsert(identity: StudioRunBindingIdentity, input: StudioRepoUpsert): Promise<StudioRepoBinding | null> {
    this.verify(identity);
    this.order.push("binding:upsert");
    this.upserts.push(input);
    if (this.failNextUpsert) {
      this.failNextUpsert = false;
      return null;
    }
    this.current = row(input);
    return this.current;
  }

  async compareAndSetBranch(
    identity: StudioRunBindingIdentity,
    expected: StudioRepoBinding,
    branch: string,
  ): Promise<StudioRepoBinding | null> {
    this.verify(identity);
    this.order.push("binding:cas");
    this.cas.push({ expected, branch });
    if (this.staleNextCas) {
      this.staleNextCas = false;
      this.current = row({ branch: "concurrent-branch" });
      return null;
    }
    if (
      this.current === null ||
      this.current.repo !== expected.repo ||
      this.current.repoDir !== expected.repoDir ||
      this.current.branch !== expected.branch
    ) return null;
    this.current = row({ ...this.current, branch });
    return this.current;
  }
}

function makeHarness(workspaceDir = "/tmp/opencode/studio-agent-unused") {
  const order: string[] = [];
  const binding = new MemoryBinding(order);
  const cloneCalls: Array<Parameters<StudioGit["clone"]>[0]> = [];
  const switchCalls: Array<Parameters<StudioGit["switchBranch"]>[0]> = [];
  const syncCalls: Array<Parameters<StudioGit["syncLatest"]>[0]> = [];
  const tokenCalls: StudioGitTokenRequest[] = [];
  const approvalCalls: Array<{
    ctx: Parameters<ApprovalGate["approve"]>[0];
    req: ApprovalRequest;
  }> = [];
  const attachCalls: string[] = [];
  let decision: ApprovalDecision = "allow";
  let resolvedToken: string | null = TOKEN;
  let cloneFailure: unknown;
  let switchFailure: unknown;
  let syncFailure: unknown;

  const cloneResult: StudioCloneResult = {
    status: "cloned",
    repoDir: "actual-clone-dir",
    branch: "actual-clone-branch",
  };
  const switchResult: StudioSwitchResult = {
    status: "switched",
    branch: "topic",
    stashed: false,
    message: "Switched to topic.",
  };
  const syncResult: StudioSyncResult = {
    status: "synced",
    dirty: false,
    behind: 1,
    ahead: 0,
    branch: "main",
    message: "Updated to the latest 1 change.",
  };

  const git: StudioAgentGitService["git"] = {
    async clone(req) {
      order.push("git:clone");
      cloneCalls.push(req);
      if (cloneFailure !== undefined) throw cloneFailure;
      return cloneResult;
    },
    async switchBranch(req) {
      order.push("git:switch");
      switchCalls.push(req);
      if (switchFailure !== undefined) throw switchFailure;
      return switchResult;
    },
    async syncLatest(req) {
      order.push("git:sync");
      syncCalls.push(req);
      if (syncFailure !== undefined) throw syncFailure;
      return syncResult;
    },
  };
  const service: StudioAgentGitService = {
    git,
    async resolveToken(req) {
      order.push("token");
      tokenCalls.push(req);
      return resolvedToken;
    },
    manager: {
      async attach(userId) {
        order.push("attach");
        attachCalls.push(userId);
        return { workspaceDir };
      },
    },
  };
  const approvals: ApprovalGate = {
    async approve(ctx, req) {
      order.push("approval");
      approvalCalls.push({ ctx, req });
      return decision;
    },
  };
  const tools = createStudioAgentTools({ git: service, binding, approvals });
  const byName = new Map(tools.map((tool) => [tool.spec.name, tool]));
  const tool = (name: string): Tool => {
    const found = byName.get(name);
    if (found === undefined) throw new Error(`missing tool ${name}`);
    return found;
  };
  const execute = (name: string, args: Record<string, unknown>, ctx = context()) =>
    tool(name).execute(args, ctx);

  return {
    order,
    binding,
    cloneCalls,
    switchCalls,
    syncCalls,
    tokenCalls,
    approvalCalls,
    attachCalls,
    cloneResult,
    switchResult,
    syncResult,
    tools,
    tool,
    execute,
    setDecision(value: ApprovalDecision) { decision = value; },
    setToken(value: string | null) { resolvedToken = value; },
    failClone(error: unknown) { cloneFailure = error; },
    failSwitch(error: unknown) { switchFailure = error; },
    failSync(error: unknown) { syncFailure = error; },
  };
}

function json(result: { content: string }): any {
  return JSON.parse(result.content);
}

describe("createStudioAgentTools", () => {
  let workspaceDir: string;

  beforeEach(async () => {
    workspaceDir = await mkdtemp("/tmp/opencode/ovid-studio-agent-tools-");
    await mkdir(join(workspaceDir, "app", "src"), { recursive: true });
    await writeFile(join(workspaceDir, "app", "src", "needle.ts"), "export const ok = true;\n");
    await writeFile(join(workspaceDir, "app", "README.md"), "needle in prose is not a path match\n");
    await mkdir(join(workspaceDir, "outside"), { recursive: true });
    await writeFile(join(workspaceDir, "outside", "needle-secret.ts"), "not visible\n");
  });

  afterEach(async () => {
    await rm(workspaceDir, { recursive: true, force: true });
  });

  it("exposes only the four bound Studio tools and no workspace/credential selectors", () => {
    const h = makeHarness(workspaceDir);
    expect(h.tools.map((tool) => tool.spec.name)).toEqual([
      "studio_repo_clone",
      "studio_repo_switch",
      "studio_repo_sync",
      "studio_file_search",
    ]);
    expect(Object.keys(h.tool("studio_repo_clone").spec.parameters.properties ?? {}))
      .toEqual(["repo", "branch", "dest"]);
    expect(Object.keys(h.tool("studio_repo_switch").spec.parameters.properties ?? {}))
      .toEqual(["branch"]);
    expect(Object.keys(h.tool("studio_repo_sync").spec.parameters.properties ?? {}))
      .toEqual([]);
    expect(Object.keys(h.tool("studio_file_search").spec.parameters.properties ?? {}))
      .toEqual(["query", "path", "limit"]);
    for (const tool of h.tools) {
      expect(tool.spec.parameters.additionalProperties).toBe(false);
      expect(tool.spec.parameters).not.toHaveProperty("properties.repoDir");
      expect(tool.spec.parameters).not.toHaveProperty("properties.command");
      expect(tool.spec.parameters).not.toHaveProperty("properties.token");
      expect(tool.spec.parameters).not.toHaveProperty("properties.userId");
      expect(tool.spec.parameters).not.toHaveProperty("properties.sessionId");
    }
  });

  it("rejects undeclared selectors before any binding, approval, token, or Git side effect", async () => {
    const h = makeHarness(workspaceDir);
    const cases = [
      ["studio_repo_clone", { repo: "acme/app", repoDir: "escape" }],
      ["studio_repo_switch", { branch: "topic", repoDir: "escape" }],
      ["studio_repo_sync", { command: "git reset --hard" }],
      ["studio_file_search", { query: "needle", token: TOKEN }],
    ] as const;

    for (const [name, args] of cases) {
      const result = await h.execute(name, args);
      expect(result.isError).toBe(true);
      expect(json(result)).toEqual({
        error: { code: "bad_request", message: "Invalid Studio tool arguments." },
      });
    }
    expect(h.binding.reads).toHaveLength(0);
    expect(h.approvalCalls).toHaveLength(0);
    expect(h.tokenCalls).toHaveLength(0);
    expect(h.cloneCalls).toHaveLength(0);
    expect(h.switchCalls).toHaveLength(0);
    expect(h.syncCalls).toHaveLength(0);
    expect(h.attachCalls).toHaveLength(0);
  });

  it("clones through the approved resolver and stores only actual success results", async () => {
    const h = makeHarness(workspaceDir);
    const ctx = context({ unattended: true });
    const result = await h.execute("studio_repo_clone", {
      repo: "https://github.com/acme/app.git",
      branch: "requested-branch",
      dest: "requested-dir",
    }, ctx);

    expect(result.isError).toBeUndefined();
    expect(json(result)).toEqual({
      status: "cloned",
      repo: "acme/app",
      repoDir: "actual-clone-dir",
      branch: "actual-clone-branch",
      bindingStored: true,
    });
    expect(h.cloneCalls).toEqual([{
      userId: UID,
      sessionId: SESSION_ID,
      repo: "https://github.com/acme/app.git",
      branch: "requested-branch",
      dest: "requested-dir",
      token: TOKEN,
    }]);
    expect(h.tokenCalls).toEqual([{ userId: UID, repo: "acme/app" }]);
    expect(h.binding.upserts).toEqual([{
      sessionId: SESSION_ID,
      userId: UID,
      repo: "acme/app",
      repoDir: "actual-clone-dir",
      branch: "actual-clone-branch",
    }]);
    expect(h.order).toEqual(["approval", "token", "git:clone", "binding:upsert"]);
    expect(h.approvalCalls[0]?.ctx).toBe(ctx);
    expect(h.approvalCalls[0]?.req).toMatchObject({
      kind: "tool",
      tool: "studio_repo_clone",
      hostTargets: ["github.com"],
      pathTargets: [],
    });
    expect(result.content).not.toContain(TOKEN);
  });

  it("reports a real clone with bindingStored:false when its row cannot be saved", async () => {
    const h = makeHarness(workspaceDir);
    h.binding.current = null;
    h.binding.failNextUpsert = true;

    const result = await h.execute("studio_repo_clone", { repo: "acme/app" });
    expect(json(result)).toMatchObject({
      status: "cloned",
      repoDir: "actual-clone-dir",
      branch: "actual-clone-branch",
      bindingStored: false,
    });
    expect(h.binding.current).toBeNull();
  });

  it.each(["studio_repo_clone", "studio_repo_switch", "studio_repo_sync"] as const)(
    "%s denial does not resolve a token, run Git, or write the binding",
    async (name) => {
      const h = makeHarness(workspaceDir);
      h.setDecision("deny");
      const before = h.binding.current;
      const args = name === "studio_repo_clone"
        ? { repo: "acme/app" }
        : name === "studio_repo_switch" ? { branch: "topic" } : {};

      const result = await h.execute(name, args, context({ unattended: true }));
      expect(result).toEqual({ content: "DENIED by user" });
      expect(h.approvalCalls).toHaveLength(1);
      expect(h.approvalCalls[0]?.ctx.unattended).toBe(true);
      expect(h.tokenCalls).toHaveLength(0);
      expect(h.cloneCalls).toHaveLength(0);
      expect(h.switchCalls).toHaveLength(0);
      expect(h.syncCalls).toHaveLength(0);
      expect(h.binding.upserts).toHaveLength(0);
      expect(h.binding.cas).toHaveLength(0);
      expect(h.binding.current).toBe(before);
    },
  );

  it("switches the bound repo and compare-and-sets the actual branch after success", async () => {
    const h = makeHarness(workspaceDir);
    const result = await h.execute("studio_repo_switch", { branch: "topic" });

    expect(h.switchCalls).toEqual([{
      userId: UID,
      sessionId: SESSION_ID,
      repoDir: "app",
      branch: "topic",
      token: TOKEN,
    }]);
    expect(h.binding.cas).toEqual([{ expected: row(), branch: "topic" }]);
    expect(h.binding.current?.branch).toBe("topic");
    expect(h.order).toEqual(["approval", "token", "git:switch", "binding:cas"]);
    expect(json(result)).toMatchObject({
      status: "switched",
      branch: "topic",
      bindingStored: true,
    });
  });

  it("maps service-level switch failure to the public refusal and does not write the binding", async () => {
    const h = makeHarness(workspaceDir);
    Object.assign(h.switchResult, {
      status: "failed",
      branch: "topic",
      message: "Could not switch to topic. Nothing was lost.",
    });

    const result = await h.execute("studio_repo_switch", { branch: "topic" });
    expect(result.isError).toBe(true);
    expect(json(result)).toEqual({
      error: {
        code: "switch_failed",
        message: "Could not switch to topic. Nothing was lost.",
      },
    });
    expect(h.binding.cas).toHaveLength(0);
    expect(h.binding.current?.branch).toBe("main");
  });

  it("does not overwrite a newer binding after a stale branch CAS", async () => {
    const h = makeHarness(workspaceDir);
    h.binding.staleNextCas = true;

    const result = await h.execute("studio_repo_switch", { branch: "topic" });
    expect(json(result)).toMatchObject({
      status: "switched",
      branch: "topic",
      bindingStored: false,
    });
    expect(h.binding.current?.branch).toBe("concurrent-branch");
    expect(h.binding.upserts).toHaveLength(0);
  });

  it("syncs only the bound repo and CAS-updates a changed actual branch", async () => {
    const h = makeHarness(workspaceDir);
    Object.assign(h.syncResult, { branch: "actual-sync-branch" });

    const result = await h.execute("studio_repo_sync", {});
    expect(h.syncCalls).toEqual([{
      userId: UID,
      sessionId: SESSION_ID,
      repoDir: "app",
      token: TOKEN,
    }]);
    expect(h.binding.cas).toEqual([{ expected: row(), branch: "actual-sync-branch" }]);
    expect(json(result)).toMatchObject({
      status: "synced",
      branch: "actual-sync-branch",
      bindingStored: true,
    });
  });

  it("returns needs_merge without claiming a mutation or changing an unchanged binding", async () => {
    const h = makeHarness(workspaceDir);
    Object.assign(h.syncResult, {
      status: "needs_merge",
      dirty: true,
      behind: 1,
      branch: "main",
      reason: "dirty_worktree",
      message: "You have uncommitted changes. Commit or stash them before syncing.",
    });

    const result = await h.execute("studio_repo_sync", {});
    expect(result.isError).toBeUndefined();
    expect(json(result)).toEqual({
      status: "needs_merge",
      dirty: true,
      behind: 1,
      ahead: 0,
      branch: "main",
      message: "You have uncommitted changes. Commit or stash them before syncing.",
      reason: "dirty_worktree",
      bindingStored: true,
    });
    expect(result.content).not.toContain('"status":"synced"');
    expect(h.binding.cas).toHaveLength(0);
    expect(h.binding.current?.branch).toBe("main");
  });

  it("searches below the bound repo through Task 2 without approvals or a PAT", async () => {
    const h = makeHarness(workspaceDir);
    const result = await h.execute("studio_file_search", {
      query: "needle",
      path: "src",
      limit: 10,
    });

    expect(json(result)).toEqual({
      items: [{ path: "app/src/needle.ts", name: "needle.ts" }],
      truncated: false,
    });
    expect(h.attachCalls).toEqual([UID]);
    expect(h.approvalCalls).toHaveLength(0);
    expect(h.tokenCalls).toHaveLength(0);
    expect(h.order).toEqual(["attach"]);
  });

  it("keeps search escapes confined and uses the public bad_request vocabulary", async () => {
    const h = makeHarness(workspaceDir);
    const result = await h.execute("studio_file_search", {
      query: "needle",
      path: "../outside",
    });

    expect(result.isError).toBe(true);
    expect(json(result)).toMatchObject({ error: { code: "bad_request" } });
    expect(result.content).not.toContain("needle-secret.ts");
    expect(h.approvalCalls).toHaveLength(0);
    expect(h.tokenCalls).toHaveLength(0);
  });

  it.each([
    ["studio_repo_clone", { repo: "acme/app" }],
    ["studio_repo_switch", { branch: "topic" }],
    ["studio_repo_sync", {}],
    ["studio_file_search", { query: "needle" }],
  ] as const)("%s refuses a wrong session before any external side effect", async (name, args) => {
    const h = makeHarness(workspaceDir);

    const result = await h.execute(name, args, context({ sessionId: FOREIGN_SESSION_ID }));
    expect(result.isError).toBe(true);
    expect(json(result)).toEqual({
      error: { code: "not_found", message: "Session not found." },
    });
    expect(h.approvalCalls).toHaveLength(0);
    expect(h.tokenCalls).toHaveLength(0);
    expect(h.cloneCalls).toHaveLength(0);
    expect(h.switchCalls).toHaveLength(0);
    expect(h.syncCalls).toHaveLength(0);
    expect(h.attachCalls).toHaveLength(0);
    expect(h.binding.upserts).toHaveLength(0);
    expect(h.binding.cas).toHaveLength(0);
  });

  it.each([
    ["studio_repo_switch", { branch: "topic" }],
    ["studio_repo_sync", {}],
    ["studio_file_search", { query: "needle" }],
  ] as const)("%s returns no_repo without an existing binding", async (name, args) => {
    const h = makeHarness(workspaceDir);
    h.binding.current = null;

    const result = await h.execute(name, args);
    expect(result.isError).toBe(true);
    expect(json(result).error.code).toBe("no_repo");
    expect(h.approvalCalls).toHaveLength(0);
    expect(h.tokenCalls).toHaveLength(0);
    expect(h.switchCalls).toHaveLength(0);
    expect(h.syncCalls).toHaveLength(0);
    expect(h.attachCalls).toHaveLength(0);
  });

  it("shares public token and typed Git refusal vocabulary", async () => {
    const missing = makeHarness(workspaceDir);
    missing.setToken(null);
    const tokenResult = await missing.execute("studio_repo_sync", {});
    expect(tokenResult.isError).toBe(true);
    expect(json(tokenResult)).toEqual({
      error: {
        code: "github_not_connected",
        message: "Connect GitHub in Settings to use Studio git.",
      },
    });
    expect(missing.syncCalls).toHaveLength(0);

    const failed = makeHarness(workspaceDir);
    failed.failSync(new StudioGitError("fetch_failed", "Could not reach the remote. Check your connection and try again."));
    const fetchResult = await failed.execute("studio_repo_sync", {});
    expect(fetchResult.isError).toBe(true);
    expect(json(fetchResult)).toEqual({
      error: {
        code: "fetch_failed",
        message: "Could not reach the remote. Check your connection and try again.",
      },
    });
    expect(failed.binding.cas).toHaveLength(0);
  });
});
