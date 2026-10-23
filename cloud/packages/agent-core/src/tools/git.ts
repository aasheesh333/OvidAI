/**
 * Git/repo tools — P3 Task 11. Ports the git_status/git_log/git_diff/
 * git_pull/git_clone/git_push/commit dispatch cases and the repo_tree /
 * repo_sync surface from lib/core/agent_service.dart.
 *
 * Cloud shape (per the revised P3 plan):
 *   - Every git_* command runs INSIDE the session workspace jail via
 *     SandboxPort.exec (cwd = workspace root, ctx.callKey threaded so the
 *     dispatcher can kill it, output spilled through spillToolOutput).
 *     There is no on-device RepoCache / GlobalRepoRegistry here — the
 *     workspace git repo is the one authority.
 *   - A non-zero exit returns stdout+stderr verbatim prefixed `exit <code>`
 *     (the model adapts) and flags isError.
 *   - Approval parity: git_push is ALWAYS individually confirmed
 *     (allowAlways:false — no grant can pre-approve a push), commit shows
 *     the staged-file list on the card first (`git diff --cached
 *     --name-only`) and is likewise individually confirmed, git_clone
 *     prompts with the remote's host in hostTargets (fusing Dart's
 *     _checkHostGrant + _maybeApprove into the one cloud ApprovalGate),
 *     git_pull prompts with Dart's summary/detail copy.
 *   - repo_tree renders the Dart line-17827 'TREE (N files, showing 120)'
 *     header from GitHubApiPort.getTree(recursive) — and is OMITTED from
 *     the roster when no GitHub API is wired (the roster never advertises
 *     what cannot run). repo_sync is the pinned P3-Q4 cloud refusal: the
 *     device repo-cache sync does not exist server-side, so the tool stays
 *     on the roster answering with the documented deviation instead of
 *     silently disappearing on the model.
 */

import { randomUUID } from "node:crypto";

import type {
  ApprovalDecision,
  ApprovalGate,
  GitHubApiPort,
  SandboxPort,
} from "../ports.js";
import type { Tool, ToolContext, ToolResult } from "../types.js";
import { spillToolOutput, toolOutputCapFor } from "./spill.js";

/** The pinned repo_sync refusal copy (P3-Q4 documented scope cut). */
export const REPO_SYNC_CLOUD_REFUSAL =
  "repo_sync is not available in cloud workspaces — use git_pull/git_push in the workspace";

/** Dart _toolTimeoutFor parity for the git family. */
const TOOL_TIMEOUTS: Record<string, number> = {
  commit: 180_000, // 3 min
  git_push: 300_000, // 5 min
  git_pull: 300_000, // 5 min
  git_clone: 300_000, // 5 min
  git_switch: 120_000, // 2 min — checkout is local, but a big tree can be slow
};
const DEFAULT_TIMEOUT_MS = 120_000;
const REPO_TREE_TIMEOUT_MS = 60_000; // REST call, no sandbox exec
const TREE_CAP = 120; // Dart repo_tree parity

// -- shared plumbing (same conventions as sandboxTools.ts) --------------------

function reqStr(args: Record<string, unknown>, key: string): string {
  const v = args[key];
  if (typeof v !== "string" || v === "") {
    throw new Error(`invalid_input: ${key} must be a non-empty string`);
  }
  return v;
}

function optStr(args: Record<string, unknown>, key: string): string | undefined {
  const v = args[key];
  return typeof v === "string" ? v : undefined;
}

function optInt(args: Record<string, unknown>, key: string): number | undefined {
  const v = args[key];
  return typeof v === "number" && Number.isInteger(v) ? v : undefined;
}

/** POSIX single-quotes a string for interpolation into a bash -c command. */
function shq(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}

function compose(res: { stdout: string; stderr: string }): string {
  return res.stdout + (res.stderr !== "" ? `\n[stderr]\n${res.stderr}` : "");
}

async function finish(
  sandbox: SandboxPort,
  name: string,
  ctx: ToolContext,
  content: string,
  isError = false,
): Promise<ToolResult> {
  const text = await spillToolOutput(
    { sandbox, userId: ctx.userId, workspaceRelDir: "" },
    name,
    content,
    toolOutputCapFor(name),
  );
  return { content: text, isError };
}

/** Runs a tool body; user-level failures become isError results, never throws. */
async function run(body: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await body();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const content = /outside the workspace/.test(msg) ? `confined: ${msg}` : msg;
    return { content, isError: true };
  }
}

/** One git command inside the session workspace jail (cwd = workspace root). */
function execGit(
  sandbox: SandboxPort,
  ctx: ToolContext,
  cmd: string,
  timeoutMs: number,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return sandbox.exec(ctx.userId, { cmd, cwd: ".", timeoutMs, callKey: ctx.callKey });
}

/** Non-zero exit: stdout+stderr verbatim, prefixed `exit <code>` (model adapts). */
async function exited(
  sandbox: SandboxPort,
  name: string,
  ctx: ToolContext,
  res: { exitCode: number; stdout: string; stderr: string },
): Promise<ToolResult> {
  const body = [res.stdout, res.stderr].filter((s) => s !== "").join("\n");
  return finish(sandbox, name, ctx, `exit ${res.exitCode}\n${body}`, true);
}

const allowed = (d: ApprovalDecision): boolean => d === "allow" || d === "always";

/** The network host a clone URL targets — scp-like form first, then URL host. */
function cloneHost(url: string): string {
  const scp = /^[\w.+-]+@([^:/]+):/.exec(url);
  if (scp?.[1]) return scp[1];
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

// -- git tools -----------------------------------------------------------------

export function createGitTools(deps: {
  sandbox: SandboxPort;
  approvals: ApprovalGate;
  github: GitHubApiPort | null; // accepted for wiring symmetry; the git_* tools run git in the sandbox and never call the REST API
}): Tool[] {
  const { sandbox, approvals } = deps;

  const tool = (
    name: string,
    description: string,
    parameters: Record<string, unknown>,
    execute: (args: Record<string, unknown>, ctx: ToolContext) => Promise<ToolResult>,
  ): Tool => ({
    spec: { name, description, parameters },
    timeoutMs: TOOL_TIMEOUTS[name] ?? DEFAULT_TIMEOUT_MS,
    execute: (args, ctx) => run(() => execute(args, ctx)),
  });

  return [
    // -- git_status ---------------------------------------------------------
    tool(
      "git_status",
      "Show working-tree status (short format) with branch tracking info. Read-only.",
      { type: "object", properties: {} },
      async (_args, ctx) => {
        const res = await execGit(sandbox, ctx, "git status --porcelain=v1 -b", DEFAULT_TIMEOUT_MS);
        if (res.exitCode !== 0) return exited(sandbox, "git_status", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_status", ctx, out === "" ? "no output" : out);
      },
    ),

    // -- git_log --------------------------------------------------------------
    tool(
      "git_log",
      "Show recent commit history, one line per commit. Read-only.",
      {
        type: "object",
        properties: {
          limit: { type: "integer", description: "Number of commits to show (1-50). Defaults to 20." },
        },
      },
      async (args, ctx) => {
        // Dart's arg name was `n`; accept it as an alias so ported prompts work.
        const raw = optInt(args, "limit") ?? optInt(args, "n") ?? 20;
        const n = Math.min(50, Math.max(1, raw));
        const res = await execGit(sandbox, ctx, `git log --oneline -${n}`, DEFAULT_TIMEOUT_MS);
        if (res.exitCode !== 0) return exited(sandbox, "git_log", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_log", ctx, out === "" ? "no commits" : out);
      },
    ),

    // -- git_diff --------------------------------------------------------------
    tool(
      "git_diff",
      "Show uncommitted changes in the working tree. Read-only.",
      {
        type: "object",
        properties: {
          staged: { type: "boolean", description: "Show staged changes (`git diff --cached`)." },
          stat: { type: "boolean", description: "Show only the per-file summary." },
          paths: { type: "array", items: { type: "string" }, description: "Limit the diff to these paths." },
        },
      },
      async (args, ctx) => {
        const paths = Array.isArray(args.paths)
          ? args.paths.filter((p): p is string => typeof p === "string" && p !== "")
          : [];
        let cmd = "git diff";
        if (args.staged === true) cmd += " --cached";
        if (args.stat === true) cmd += " --stat";
        if (paths.length > 0) cmd += ` -- ${paths.map(shq).join(" ")}`;
        const res = await execGit(sandbox, ctx, cmd, DEFAULT_TIMEOUT_MS);
        if (res.exitCode !== 0) return exited(sandbox, "git_diff", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_diff", ctx, out === "" ? "no changes" : out);
      },
    ),

    // -- git_pull ----------------------------------------------------------------
    tool(
      "git_pull",
      "Pull latest changes from the git remote into the current branch (fast-forward only; fails cleanly on divergence).",
      {
        type: "object",
        properties: {
          remote: { type: "string", description: "Remote name. Defaults to \"origin\"." },
          branch: { type: "string", description: "Branch to pull. Omit for the upstream branch." },
        },
      },
      async (args, ctx) => {
        const remote = (optStr(args, "remote") ?? "origin").trim();
        if (remote === "") return { content: "git_pull needs a remote name." };
        const branch = (optStr(args, "branch") ?? "").trim();
        const decision = await approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "git_pull",
          summary: `Pull${branch === "" ? "" : ` ${branch}`} from ${remote} (fast-forward only)`,
          detail:
            "PULL FROM GIT REMOTE\n" +
            remote +
            (branch === "" ? "" : `\nBranch: ${branch}`) +
            "\nFast-forward only — fails cleanly on divergence.",
          allowAlways: true,
          pathTargets: [],
          hostTargets: [],
        });
        if (!allowed(decision)) return { content: "DENIED by user" };
        let cmd = `git pull --ff-only ${shq(remote)}`;
        if (branch !== "") cmd += ` ${shq(branch)}`;
        const res = await execGit(sandbox, ctx, cmd, TOOL_TIMEOUTS.git_pull);
        if (res.exitCode !== 0) return exited(sandbox, "git_pull", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_pull", ctx, out === "" ? "already up to date ✓" : out);
      },
    ),

    // -- git_clone ------------------------------------------------------------------
    tool(
      "git_clone",
      "Clone a git repository into the session workspace. `branch` selects a branch/tag " +
        "(`git clone -b <branch>`); `path` names the destination directory (defaults to the repository name).",
      {
        type: "object",
        properties: {
          url: { type: "string", description: "Repository URL to clone." },
          path: { type: "string", description: "Destination directory name inside the session workspace." },
          branch: { type: "string", description: "Branch or tag to check out on clone. Omit for the default branch." },
        },
        required: ["url"],
      },
      async (args, ctx) => {
        const url = (optStr(args, "url") ?? "").trim();
        if (url === "") return { content: 'git_clone needs a repository "url".' };
        const dest = (optStr(args, "path") ?? "").trim();
        const branch = (optStr(args, "branch") ?? "").trim();
        // Refuse suspicious branch names early — a clean error beats a
        // confusing git failure (the quoting below already prevents injection).
        if (/\s/.test(branch) || branch.includes("..")) {
          return { content: `git_clone: refusing suspicious branch name "${branch}".` };
        }
        const host = cloneHost(url);
        // Dart parity: a URL with no host never passes the host gate.
        if (host === "") return { content: "DENIED by user" };
        const decision = await approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "git_clone",
          summary: url,
          detail:
            "Clone repository into the session workspace:\n" +
            url +
            (branch === "" ? "" : `\nBranch/tag: ${branch}`) +
            (dest === "" ? "" : `\nDestination: ${dest}`),
          allowAlways: true,
          pathTargets: [],
          hostTargets: [host],
        });
        if (!allowed(decision)) return { content: "DENIED by user" };
        let cmd = "git clone";
        if (branch !== "") cmd += ` -b ${shq(branch)}`;
        cmd += ` ${shq(url)}`;
        if (dest !== "") cmd += ` ${shq(dest)}`;
        const res = await execGit(sandbox, ctx, cmd, TOOL_TIMEOUTS.git_clone);
        if (res.exitCode !== 0) return exited(sandbox, "git_clone", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_clone", ctx, out === "" ? `cloned ${url} ✓` : out);
      },
    ),

    // -- git_switch ------------------------------------------------------------------
    //
    // Spec Screen 2: the AGENT can switch branches autonomously, not only the
    // user via the UI dropdown. Two guards keep that safe:
    //  · a dirty working tree is refused unless the caller forces it — a bare
    //    `git checkout` would silently carry uncommitted work to another
    //    branch (or fail in a way the model misreads);
    //  · the switch is individually confirmed (allowAlways false), like commit.
    tool(
      "git_switch",
      "Switch a cloned repository to another branch (or create one with `create`). " +
        "Refuses when the working tree has uncommitted changes unless `force` is set.",
      {
        type: "object",
        properties: {
          branch: { type: "string", description: "Branch to check out." },
          path: {
            type: "string",
            description: "Repository directory inside the workspace (default: the workspace root).",
          },
          create: {
            type: "boolean",
            description: "Create the branch if it does not exist (git checkout -b).",
          },
          force: {
            type: "boolean",
            description: "Switch even with uncommitted changes (they follow you).",
          },
        },
        required: ["branch"],
      },
      async (args, ctx) => {
        const branch = (optStr(args, "branch") ?? "").trim();
        if (branch === "") {
          return { content: 'git_switch needs a "branch".', isError: true };
        }
        // Same gate as git_clone: a ref reaches a shell, so anything that
        // could be read as an option or a second command is refused outright.
        if (
          /\s/.test(branch) ||
          branch.includes("..") ||
          branch.startsWith("-") ||
          /[;&|`$<>]/.test(branch)
        ) {
          return {
            content: `git_switch: refusing suspicious branch name "${branch}".`,
            isError: true,
          };
        }
        const rel = (optStr(args, "path") ?? "").trim();
        if (rel.startsWith("-") || rel.includes("..") || /[;&|`$<>]/.test(rel)) {
          return {
            content: `git_switch: refusing suspicious path "${rel}".`,
            isError: true,
          };
        }
        const create = args["create"] === true;
        const force = args["force"] === true;
        const at = rel === "" ? "git" : `git -C ${shq(rel)}`;

        if (!force) {
          const status = await sandbox.exec(ctx.userId, {
            cmd: `${at} status --porcelain`,
            cwd: ".",
            timeoutMs: DEFAULT_TIMEOUT_MS,
            callKey: ctx.callKey,
          });
          if (status.exitCode !== 0) return exited(sandbox, "git_switch", ctx, status);
          if (status.stdout.trim() !== "") {
            return {
              content:
                "git_switch refused: the working tree has uncommitted changes, and " +
                "switching now would carry them onto the other branch. Commit or stash " +
                "them first, or pass force: true to switch anyway.",
              isError: true,
            };
          }
        }

        const decision = await approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "git_switch",
          summary: `${create ? "Create and switch to" : "Switch to"} branch ${branch}`,
          detail:
            `SWITCH BRANCH\nTarget: ${branch}` +
            (create ? "\nCreates the branch." : "") +
            (rel === "" ? "" : `\nRepository: ${rel}`),
          allowAlways: false,
          pathTargets: [],
          hostTargets: [],
        });
        if (!allowed(decision)) return { content: "DENIED by user" };

        const cmd = `${at} checkout ${create ? "-b " : ""}${shq(branch)}`;
        const res = await sandbox.exec(ctx.userId, {
          cmd,
          cwd: ".",
          timeoutMs: TOOL_TIMEOUTS.git_switch ?? DEFAULT_TIMEOUT_MS,
          callKey: ctx.callKey,
        });
        if (res.exitCode !== 0) return exited(sandbox, "git_switch", ctx, res);
        const out = compose(res).trim();
        return finish(
          sandbox,
          "git_switch",
          ctx,
          out === "" ? `on branch ${branch} ✓` : out,
        );
      },
    ),

    // -- git_push ---------------------------------------------------------------------
    tool(
      "git_push",
      "Push the current branch to the git remote. Pass `branch` to push (and set upstream for) a specific branch.",
      {
        type: "object",
        properties: {
          remote: { type: "string", description: "Remote name. Defaults to \"origin\"." },
          branch: { type: "string", description: "Branch to push. Omit to push the current branch." },
        },
      },
      async (args, ctx) => {
        const remote = (optStr(args, "remote") ?? "origin").trim();
        if (remote === "") return { content: "git_push needs a remote name." };
        const branch = (optStr(args, "branch") ?? "").trim();
        // ALWAYS individually confirmed (Dart parity): allowAlways:false so no
        // session grant — host or path — can ever pre-approve a push.
        const decision = await approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "git_push",
          summary: `Push${branch === "" ? "" : ` branch ${branch}`} to ${remote}`,
          detail: "PUSH TO GIT REMOTE\n" + remote + (branch === "" ? "" : `\nBranch: ${branch}`),
          allowAlways: false,
          pathTargets: [],
          hostTargets: [],
        });
        if (!allowed(decision)) return { content: "DENIED by user" };
        let cmd = "git push";
        if (branch !== "") cmd += " --set-upstream";
        cmd += ` ${shq(remote)}`;
        if (branch !== "") cmd += ` ${shq(branch)}`;
        const res = await execGit(sandbox, ctx, cmd, TOOL_TIMEOUTS.git_push);
        if (res.exitCode !== 0) return exited(sandbox, "git_push", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "git_push", ctx, out === "" ? "pushed ✓" : out);
      },
    ),

    // -- commit -----------------------------------------------------------------------
    tool(
      "commit",
      "Commit the staged changes in the workspace git repo (one commit; use git_push to publish). " +
        "Shows the staged-file list for approval first.",
      {
        type: "object",
        properties: {
          message: { type: "string", description: "Commit message." },
        },
        required: ["message"],
      },
      async (args, ctx) => {
        const rawMessage = optStr(args, "message");
        const message = rawMessage !== undefined && rawMessage.trim() !== "" ? rawMessage : "Ovid agent update";
        // The staged-file list FIRST (read-only): the approval card shows
        // exactly what would be committed before any mutation is possible.
        const staged = await sandbox.exec(ctx.userId, {
          cmd: "git diff --cached --name-only",
          cwd: ".",
          timeoutMs: TOOL_TIMEOUTS.commit,
          callKey: ctx.callKey,
        });
        if (staged.exitCode !== 0) return exited(sandbox, "commit", ctx, staged);
        const files = staged.stdout.split("\n").map((l) => l.trim()).filter((l) => l !== "");
        if (files.length === 0) return { content: "no pending changes" };
        // Individually confirmed, like pushes: pathTargets stay empty and
        // allowAlways is false so no grant can pre-approve a commit.
        const decision = await approvals.approve(ctx, {
          approvalId: randomUUID(),
          kind: "tool",
          tool: "commit",
          summary: `Commit ${files.length} staged file${files.length === 1 ? "" : "s"}: ${files.join(", ")}`,
          detail: `COMMIT TO GIT\nFiles:\n${files.join("\n")}\nMessage: ${message}`,
          allowAlways: false,
          pathTargets: [],
          hostTargets: [],
        });
        if (!allowed(decision)) return { content: "DENIED by user" };
        const res = await execGit(sandbox, ctx, `git commit -m ${shq(message)}`, TOOL_TIMEOUTS.commit);
        if (res.exitCode !== 0) return exited(sandbox, "commit", ctx, res);
        const out = compose(res).trim();
        return finish(sandbox, "commit", ctx, out === "" ? "committed ✓" : out);
      },
    ),
  ];
}

// -- repo tools ------------------------------------------------------------------

export function createRepoTools(deps: { github: GitHubApiPort | null }): Tool[] {
  const tools: Tool[] = [
    // repo_sync: pinned cloud refusal (P3-Q4) — the device repo-cache sync
    // does not exist server-side; keep the tool on the roster answering with
    // the documented deviation rather than silently dropping it.
    {
      spec: {
        name: "repo_sync",
        description:
          "Device-parity stub — repo cache sync does not exist in cloud workspaces; " +
          "use git_clone/git_pull in the session workspace instead.",
        parameters: { type: "object", properties: {} },
      },
      timeoutMs: DEFAULT_TIMEOUT_MS,
      execute: async () => ({ content: REPO_SYNC_CLOUD_REFUSAL }),
    },
  ];

  if (deps.github === null) return tools; // repo_tree absent: the roster never advertises what cannot run

  const github = deps.github;

  tools.push({
    spec: {
      name: "repo_tree",
      description:
        "List the file tree of a GitHub repository (owner/repo, optional ref) via the REST API — " +
        "no clone needed. Shows up to 120 paths; pass `path` to narrow to a prefix.",
      parameters: {
        type: "object",
        properties: {
          owner: { type: "string" },
          repo: { type: "string" },
          ref: { type: "string", description: "Branch/tag/commit SHA (default: the default branch)." },
          path: { type: "string", description: "Only show paths under this prefix." },
        },
        required: ["owner", "repo"],
      },
    },
    timeoutMs: REPO_TREE_TIMEOUT_MS,
    execute: (args, ctx) =>
      run(async () => {
        const owner = reqStr(args, "owner");
        const repo = reqStr(args, "repo");
        const ref = optStr(args, "ref");
        let entries: Array<{ path: string; type: "blob" | "tree" }>;
        try {
          entries = await github.getTree(ctx.userId, { owner, repo, ref, recursive: true });
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          return { content: `repo_tree failed: ${msg}` };
        }
        let paths = entries.filter((e) => e.type === "blob").map((e) => e.path);
        const rawPrefix = optStr(args, "path")?.trim();
        if (rawPrefix !== undefined && rawPrefix !== "") {
          const p = rawPrefix.replace(/\/+$/, "");
          paths = paths.filter((x) => x === p || x.startsWith(`${p}/`));
        }
        if (paths.length === 0) return { content: "no files found in this repository/ref" };
        // Dart line 17827 parity: the header always says "showing 120".
        const shown = paths.slice(0, TREE_CAP);
        return { content: `TREE (${paths.length} files, showing ${TREE_CAP}):\n${shown.join("\n")}` };
      }),
  });

  return tools;
}
