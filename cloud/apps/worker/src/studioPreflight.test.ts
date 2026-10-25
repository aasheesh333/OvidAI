import { describe, expect, it } from "vitest";
import type { SessionMode } from "@ovid/agent-core";
import type { StudioRepoBinding } from "@ovid/db";
import { GitCredentialLeakError } from "@ovid/sandbox/gitCredential";

import {
  createStudioPreflight,
  runStudioPreflightAfterWarm,
  type StudioPreflightDeps,
  type StudioPreflightInput,
  type StudioPreflightResult,
} from "./studioPreflight.js";
import {
  StudioGitError,
  type StudioGit,
  type StudioGitStatus,
  type StudioGitTokenRequest,
} from "./studioGit.js";
import {
  StudioRunBindingError,
  type StudioRunBindingIdentity,
  type StudioRunBindingPort,
} from "./studioRunBinding.js";

const UID = "verified-studio-user";
const SESSION_ID = "11111111-1111-4111-8111-111111111111";
const TOKEN = "synthetic-studio-preflight-token";
const NOW = new Date("2026-10-24T12:00:00.000Z");

const BINDING: StudioRepoBinding = {
  sessionId: SESSION_ID,
  userId: UID,
  repo: "acme/app",
  repoDir: "actual-bound-dir",
  branch: "main",
  createdAt: NOW,
  updatedAt: NOW,
};

const STATUS: StudioGitStatus = {
  branch: "main",
  headSha: "0123456789012345678901234567890123456789",
  upstream: "origin/main",
  dirty: false,
  ahead: 2,
  behind: 3,
  reason: "diverged",
  fetchedAt: "2026-10-24T12:01:00.000Z",
};

function input(mode: SessionMode = "studio"): StudioPreflightInput {
  return { userId: UID, sessionId: SESSION_ID, mode };
}

interface HarnessOptions {
  bound?: StudioRepoBinding | null;
  bindingError?: unknown;
  token?: string | null;
  inspectError?: unknown;
}

function harness(options: HarnessOptions = {}) {
  const calls: string[] = [];
  const forbidden: string[] = [];
  const bindingReads: StudioRunBindingIdentity[] = [];
  const tokenRequests: StudioGitTokenRequest[] = [];
  const inspectRequests: Array<Parameters<StudioGit["inspect"]>[0]> = [];
  const bound = options.bound === undefined ? BINDING : options.bound;

  const mustNotCall = (operation: string): never => {
    forbidden.push(operation);
    throw new Error(`${operation} is not a preflight operation`);
  };
  const binding: StudioRunBindingPort = {
    async get(identity) {
      calls.push("binding");
      bindingReads.push(identity);
      if (options.bindingError !== undefined) throw options.bindingError;
      return bound;
    },
    async upsert() {
      return mustNotCall("binding.upsert");
    },
    async compareAndSetBranch() {
      return mustNotCall("binding.compareAndSetBranch");
    },
  };
  const git: StudioGit = {
    async inspect(req) {
      calls.push("inspect");
      inspectRequests.push(req);
      if (options.inspectError !== undefined) throw options.inspectError;
      return STATUS;
    },
    async clone() {
      return mustNotCall("git.clone");
    },
    async syncLatest() {
      return mustNotCall("git.syncLatest");
    },
    async switchBranch() {
      return mustNotCall("git.switchBranch");
    },
    async status() {
      return mustNotCall("git.status");
    },
    async diff() {
      return mustNotCall("git.diff");
    },
    async logs() {
      return mustNotCall("git.logs");
    },
  };
  const deps: StudioPreflightDeps = {
    binding,
    git: {
      git,
      resolveToken: async (req) => {
        calls.push("token");
        tokenRequests.push(req);
        return options.token === undefined ? TOKEN : options.token;
      },
    },
  };

  return {
    calls,
    forbidden,
    bindingReads,
    tokenRequests,
    inspectRequests,
    preflight: createStudioPreflight(deps),
  };
}

describe("createStudioPreflight", () => {
  it("uses the verified uid/session binding and canonical remote inspect only", async () => {
    const h = harness();

    await expect(h.preflight(input())).resolves.toEqual({ status: STATUS, failure: null });

    expect(h.calls).toEqual(["binding", "token", "inspect"]);
    expect(h.forbidden).toEqual([]);
    expect(h.bindingReads).toEqual([{ userId: UID, sessionId: SESSION_ID }]);
    expect(h.tokenRequests).toEqual([{ userId: UID, repoDir: "actual-bound-dir" }]);
    expect(h.inspectRequests).toEqual([{
      userId: UID,
      sessionId: SESSION_ID,
      repoDir: "actual-bound-dir",
      token: TOKEN,
    }]);
  });

  it("returns empty context without a token or fetch when no repository is bound", async () => {
    const h = harness({ bound: null });

    await expect(h.preflight(input())).resolves.toEqual({ status: null, failure: null });

    expect(h.calls).toEqual(["binding"]);
    expect(h.tokenRequests).toEqual([]);
    expect(h.inspectRequests).toEqual([]);
    expect(h.forbidden).toEqual([]);
  });

  it.each(["safe", "auto", "drive"] as const)(
    "does not read a binding, resolve a credential, or fetch in %s mode",
    async (mode) => {
      const h = harness();

      await expect(h.preflight(input(mode))).resolves.toEqual({ status: null, failure: null });

      expect(h.calls).toEqual([]);
      expect(h.forbidden).toEqual([]);
    },
  );

  it("returns the existing GitHub-connection vocabulary without inspecting when no PAT exists", async () => {
    const h = harness({ token: null });

    await expect(h.preflight(input())).resolves.toEqual({
      status: null,
      failure: {
        code: "github_not_connected",
        message: "Connect GitHub in Settings to use Studio git.",
      },
    });
    expect(h.calls).toEqual(["binding", "token"]);
    expect(h.inspectRequests).toEqual([]);
  });

  it("returns a typed fetch refusal as context instead of rejecting the run", async () => {
    const h = harness({
      inspectError: new StudioGitError(
        "fetch_failed",
        "Could not reach the remote. Check your connection and try again.",
      ),
    });

    await expect(h.preflight(input())).resolves.toEqual({
      status: null,
      failure: {
        code: "fetch_failed",
        message: "Could not reach the remote. Check your connection and try again.",
      },
    });
    expect(h.forbidden).toEqual([]);
  });

  it("bounds typed failure messages before they become model context", async () => {
    const h = harness({
      inspectError: new StudioGitError("fetch_failed", "x".repeat(2_000)),
    });

    const result = await h.preflight(input());

    expect(result.status).toBeNull();
    expect(result.failure?.code).toBe("fetch_failed");
    expect(result.failure?.message).toHaveLength(512);
    expect(result.failure?.message).toBe("x".repeat(512));
  });

  it("never exposes an unknown provider/Git error or credential canary", async () => {
    const canary = "ghp_raw_provider_error_must_not_cross";
    const h = harness({ inspectError: new Error(`provider failed with ${canary}`) });

    const result = await h.preflight(input());

    expect(result).toEqual({
      status: null,
      failure: { code: "internal", message: "Internal server error." },
    });
    expect(JSON.stringify(result)).not.toContain(canary);
  });

  it("reduces credential-leak failures to fixed safe context", async () => {
    const h = harness({
      inspectError: new GitCredentialLeakError("synthetic credential canary"),
    });

    await expect(h.preflight(input())).resolves.toEqual({
      status: null,
      failure: { code: "internal", message: "Internal server error." },
    });
  });

  it("fails closed without a token or fetch when verified session ownership fails", async () => {
    const h = harness({ bindingError: new StudioRunBindingError() });

    await expect(h.preflight(input())).resolves.toEqual({
      status: null,
      failure: { code: "not_found", message: "Session not found." },
    });
    expect(h.calls).toEqual(["binding"]);
    expect(h.tokenRequests).toEqual([]);
    expect(h.inspectRequests).toEqual([]);
    expect(h.forbidden).toEqual([]);
  });
});

describe("runStudioPreflightAfterWarm", () => {
  it.each(["compat", "full"] as const)(
    "orders the %s path as workspace warm, preflight, then model/tools",
    async (path) => {
      const h = harness();
      const modelContexts: StudioPreflightResult[] = [];

      const sent = await runStudioPreflightAfterWarm({
        input: input(),
        ensureWarm: async (sessionId, userId) => {
          expect({ sessionId, userId }).toEqual({ sessionId: SESSION_ID, userId: UID });
          h.calls.push("warm");
        },
        studioPreflight: h.preflight,
        runModelTools: async (context) => {
          h.calls.push("model");
          modelContexts.push(context);
          return `${path}:sent`;
        },
      });

      expect(sent).toBe(`${path}:sent`);
      expect(h.calls).toEqual(["warm", "binding", "token", "inspect", "model"]);
      expect(modelContexts).toEqual([{ status: STATUS, failure: null }]);
    },
  );

  it("lets the model/send phase proceed with empty no-binding context", async () => {
    const h = harness({ bound: null });

    const sent = await runStudioPreflightAfterWarm({
      input: input(),
      ensureWarm: async () => {
        h.calls.push("warm");
      },
      studioPreflight: h.preflight,
      runModelTools: async (context) => {
        h.calls.push("model");
        return context;
      },
    });

    expect(sent).toEqual({ status: null, failure: null });
    expect(h.calls).toEqual(["warm", "binding", "model"]);
  });

  it("preserves legacy operation when the optional preflight dependency is absent", async () => {
    const order: string[] = [];

    const result = await runStudioPreflightAfterWarm({
      input: input(),
      ensureWarm: async () => {
        order.push("warm");
      },
      runModelTools: async (context) => {
        order.push("model");
        return context;
      },
    });

    expect(result).toEqual({ status: null, failure: null });
    expect(order).toEqual(["warm", "model"]);
  });

  it("does not preflight or enter model/tools when workspace warm rejects", async () => {
    const h = harness();
    const warmError = new Error("workspace did not hydrate");

    await expect(runStudioPreflightAfterWarm({
      input: input(),
      ensureWarm: async () => {
        h.calls.push("warm");
        throw warmError;
      },
      studioPreflight: h.preflight,
      runModelTools: async () => {
        h.calls.push("model");
      },
    })).rejects.toBe(warmError);

    expect(h.calls).toEqual(["warm"]);
  });
});
