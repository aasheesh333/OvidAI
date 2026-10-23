# Two agents, one repo — file ownership

This repo is being edited by **two OpenCode sessions at the same time**. This
file is the contract that keeps them out of each other's way. Read it before
touching anything under `cloud/`, and update your row when your area changes.

Last updated: 2026-10-23 (web/cloud session)

---

## The two sessions

| Session | Working directory | Branch | Owns |
|---|---|---|---|
| **Flutter / Android** | `~/.local/share/opencode/worktree/d5f2a3/ovid-si-rebuild` | `feat/ovid-si-rebuild` | `lib/`, `test/`, `android/`, `pubspec.yaml`, and `cloud/packages/{agent-core,browser,sandbox}/` |
| **Web / cloud** | `/root/OvidWeb` (client) and `/root/OvidAI` (backend, deployed) | `feat/ovid-cloud` | `cloud/apps/gateway/`, `cloud/packages/{shared,db}/`, and the whole `OvidWeb` repo |

Both branches share the merge base `e7a4dd79`.

---

## The rule

1. **Never edit a file outside your row.** If you need a change in someone
   else's area, write it in the "Handoffs" section below instead of making it.
2. **Never `git add -A` / `git add .`.** Stage the exact paths you changed.
   The other session has uncommitted work in the same working tree; a blanket
   add would swallow it into your commit.
3. **Commit small and often**, on your own branch. A long-lived uncommitted
   tree is what makes merges expensive.
4. **Do not rebuild or restart a shared service** (`ovid-worker`,
   `ovid-cloud-gateway-1`, `ovid-cloud-mint-1`) without noting it here first —
   the other session may be mid-verification against it.

---

## Current state (2026-10-23)

### What is deployed right now

| Thing | Runs from | Branch |
|---|---|---|
| `ovid-worker` (agent runs) | `/opt/ovid-cloud/repo/cloud` → `/root/OvidAI/cloud` | `feat/ovid-cloud` |
| `ovid-cloud-gateway-1` (docker) | same tree, image rebuilt from it | `feat/ovid-cloud` |
| `beta.ovidsi.com` (web) | `/root/OvidWeb/web` via `npm run cf:deploy` | `main` (OvidWeb) |

**The deployed backend is `feat/ovid-cloud`, which is 56 commits behind
`feat/ovid-si-rebuild`.** Everything the Flutter session has built in
`cloud/packages/{agent-core,browser,sandbox}` is on disk in its worktree but is
**not** in the running worker.

### Divergence

```
e7a4dd79  ← merge base
   ├── feat/ovid-cloud        +2 commits   (deployed)
   └── feat/ovid-si-rebuild   +56 commits  (not deployed)
```

Eight files conflict on a merge, and two of them are the same feature built
twice:

| Concern | `feat/ovid-cloud` (web/cloud session) | `feat/ovid-si-rebuild` (Flutter session) |
|---|---|---|
| Parallel subagents | `dispatch` itself is non-blocking; the outcome arrives as a queued report + a parent wake | `dispatch` still blocks; a second tool, `dispatch_agents`, fans out a batch with `Promise.all` |
| Child summary | 300 tokens on success / 1,000 on failure or stop, led by `runs.last_error` | strict five-key JSON, always within budget |
| Sandbox cleanup | not addressed | settled children release their jobs/resources |
| Per-subagent timeout | not addressed | one 8 h deadline for the whole child |

Conflicting files: `apps/gateway/src/app.ts`,
`apps/worker/src/main.ts`, `apps/worker/src/runProcessor.ts`,
`packages/agent-core/src/{loop,subagents,subagents.test,tools/subagentTools,tools/subagentTools.test}.ts`.

### What only `feat/ovid-cloud` has

- `GET /cloud/v1/models` — the model catalog + the account tier
- `PATCH /sessions/:id { pinned }` + migration `0023_session_pin`
- `DELETE /artifacts/:id` (frees quota, deletes the bytes)
- `packages/shared/src/plans.ts` — one plan table (1.5× / 5× / 20×, $5 / $18 / $99)
- server-side refusal of a named model on an auto-only tier (402)

### What only `feat/ovid-si-rebuild` has

- `dispatch_agents` batch tool, sandbox resource cleanup, per-child 8 h timeout
- per-user browser isolation changes
- Studio repo reachability fixes
- settings card order + agent app-awareness
- 50+ further commits

---

## Handoffs

Add a line here when you need something in the other session's area.

| From | To | What |
|---|---|---|
| web/cloud | Flutter | Decide the subagent contract (see below) before either side merges. |
| web/cloud | Flutter | **Studio git execution.** The gateway route layer is done (`cloud/apps/gateway/src/routes/studio.ts`): repo list, branch list, clone, switch-branch and sync-latest. Clone/switch/sync call the `StudioGitTransport` seam (`cloud/apps/gateway/src/studioGit.ts`) and are refused with `503 studio_git_unavailable` until a transport is wired — no fake success. The deployed worker has no git surface: `studioGit.ts` exists only on `feat/ovid-si-rebuild`, and only as a queue consumer (`studio_git`), which this branch has no producer for. Least-work handoff: expose three routes on the worker's internal file service (same `x-ovid-internal-token` + `x-ovid-user-id` auth, port 8091) wrapping the existing transport-free `createStudioGit` service — `POST /internal/sessions/:sid/studio-git/clone {repo,branch?,dest?}` → `{repoDir,branch}`, `POST .../studio-git/sync {}` → the sync result, `POST .../studio-git/switch-branch {branch}` → the switch result — then wire `deps.studioGit` in the gateway composition root. The service already resolves the token per user from the curated `github` MCP row; the gateway never sends one, and nothing is written to `.git/config`. The session→repo binding is gateway-owned (`studio_repos`, migration `0024`), so this works with either transport (HTTP or your existing queue). |

---

## Open decision: one subagent architecture

Both branches answer "run up to 50 subagents at once" differently, and they
cannot both ship. The choice matters because it changes what the model is told
`dispatch_agent` does:

- **Batch tool (Flutter branch).** `dispatch_agent` still waits and returns the
  answer; `dispatch_agents` runs a batch in parallel. Familiar to prompts, no
  change to the single-dispatch contract, but the parent still cannot do other
  work while a batch runs, and cannot start a second batch from the first
  batch's results.
- **Non-blocking (web/cloud branch).** `dispatch_agent` returns immediately and
  the outcome arrives as a system note; a parent whose turn ended is woken.
  Maximum parallelism, but every prompt that assumes "dispatch and wait" has to
  be re-read, and the main agent must be told not to summarise work that has
  not happened.

Until it is decided, **neither session should edit `subagents.ts` again.**
