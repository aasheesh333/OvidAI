# Two agents, one repo — file ownership

This repo is being edited by **two OpenCode sessions at the same time**. This
file is the contract that keeps them out of each other's way. Read it before
touching anything under `cloud/`, and update your row when your area changes.

Last updated: 2026-10-23 (web/cloud session)

---

## The two sessions

| Session | Working directory | Branch | Owns |
|---|---|---|---|
| **Flutter / Android** | `/root/OvidFlutter` | `feat/ovid-si-rebuild` | `lib/`, `test/`, `android/`, `pubspec.yaml`, and `cloud/packages/{agent-core,browser,sandbox}/` |
| **Web / cloud** | `/root/OvidWeb` (client) and `/root/OvidBackend` (backend, deployed) | `feat/ovid-cloud` | `cloud/apps/gateway/`, `cloud/packages/{shared,db}/`, and the whole `OvidWeb` repo |

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
| `ovid-worker` (agent runs) | `/opt/ovid-cloud/repo/cloud` → `/root/OvidBackend/cloud` | `feat/ovid-cloud` |
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
| web/cloud | Flutter | **Studio git execution — BLOCKED on a worker transport.** The gateway routes are committed at `10de6b8e`; clone/switch/sync answer `503 studio_git_unavailable` because `deps.studioGit` is unwired, and `GET .../git` reports `available:false` (no fake success). `cloud/apps/worker/` is outside the web/cloud row and `apps/worker/src/main.ts` is a known cross-branch conflict file, so this half must land on `feat/ovid-si-rebuild`. Exact contract the gateway expects (`cloud/apps/gateway/src/studioGit.ts`): `clone({userId,sessionId,repo,branch?,dest?})` → `{repoDir,branch}`; `sync({userId,sessionId,repoDir})` → `{status:"up_to_date" / "synced" / "needs_merge", dirty, behind, ahead, branch, message, reason?}`; `switchBranch({userId,sessionId,repoDir,branch})` → `{status:"switched" / "unchanged" / "failed", branch, stashed, stashRef?, stashNote?, message}`. A typed failure must arrive as `StudioGitRefusal(code,message,stashRef?)` so the route can map it (`token_unavailable` → 409 `github_not_connected`, `destination_exists` → 409, `clone_failed`/`fetch_failed`/`sync_failed` → 502, `credential_leak` → 500 `internal`); a transport failure is the only thing that may become the generic 503. Suggested endpoints on the existing internal file service (port 8091, same `preHandler` gate): `POST /internal/sessions/:sid/studio-git/clone` body `{repo,branch?,dest?}`; `POST /internal/sessions/:sid/studio-git/sync` body `{repoDir}` (the gateway knows the binding, the worker needs the folder); `POST /internal/sessions/:sid/studio-git/switch-branch` body `{repoDir,branch}`. Every request carries `x-ovid-internal-token` (`OVID_INTERNAL_TOKEN`) and `x-ovid-user-id` (the verified uid); the gateway sends NO token in any header or body. The worker resolves the PAT per request via `createPerUserGithubTokenResolver` (curated `github` MCP row, sealed `GITHUB_TOKEN`, `createEnvelopeCrypto(masterKey)`) and throws `token_unavailable` when absent — never a deployment-wide fallback. `createStudioGit` and the resolver live only on `feat/ovid-si-rebuild`; wire them in `main.ts` (`manager`, `mcpServersRepo`, `cfg.gitAllowedHosts`) and pass the built service into `buildFileService` deps, because `buildFileService` currently has no `manager`. Error body: non-2xx `{error:{code,message,stashRef?}}` using the worker's `StudioGitErrorCode` vocabulary. Nothing may be written to `.git/config` or `.git-credentials`; the existing askpass/env-dispose/leak-scan path already guarantees that. After the endpoints exist, web/cloud wires `deps.studioGit` in `apps/gateway/src/index.ts` beside `createWorkerClient` (a thin HTTP client that throws `StudioGitRefusal` on the envelope and `WorkerUnavailableError` on transport failure) — no gateway change before then. Session→repo binding stays gateway-owned (`studio_repos`, migration `0024`), so the queue consumer and the HTTP route can share the same service. |
| web/cloud | Flutter | **Reasoning transport — worker/agent-core half needed.** The DB/API half is committed (`b290b734`: `messages.reasoning` nullable column + migration `0026_messages_reasoning`, `MessageDto.reasoning`, `UserPreferences.showReasoning` default `true`, `messages.append({reasoning})`). Nothing under `cloud/packages/agent-core/` or `cloud/apps/worker/` persists it yet. The transport already accumulates it (`AgentResponse.thinking`; `transport/openai.ts` maps `delta.reasoning_content`), so only the two append sites change: `cloud/packages/agent-core/src/loop.ts` finalize (`messages.append(deps.db, { sessionId, role: "assistant", content })`, ~line 1190) must pass `reasoning: response.thinking` when non-empty (omit when empty so the column stays `NULL`); the legacy v0 path at `cloud/apps/worker/src/runProcessor.ts` ~line 1384 has `result.thinking` from `transport.stream` and must do the same. Never fold thinking into `content` — the answer, search and compaction must not see it. The pre-pass feedback append (~line 2189) and `schedulerSettle.ts` system rows have no thinking and stay unchanged. |
| web/cloud | — | **Reasoning transport — gateway half complete.** `b290b734` lands the DB/API half; `85fc9a52` lands the two hunks that were held back while `messages.ts`/`messages.test.ts` also carried the token-cap work: `toMessageDto` emits `reasoning` when the row has one (and omits it, not null, otherwise), and the history-route test asserts both. Nothing remains on the gateway side; only the worker/agent-core append sites in the row above are outstanding. |
| web/cloud | — | **Web push — source complete, production rollout pending.** Working-tree changes on `feat/ovid-cloud` add migration `0028_web_push_subscriptions`, owner-scoped subscription POST/DELETE and public-key-only `/push/config`, worker VAPID configuration, and Web Push fan-out inside the existing `createNotifier` (including 404/410 pruning and zero-device+zero-subscription handling). `0027_notification_delivery_claims` adds persistent run-level completion dedupe; the existing root-run terminal event calls `notifyAgentFinished`, while scheduled/subagent completions stay on their existing paths. Web routes map to `/chat/...`; VAPID private key/subject remain worker-only. Verified in this session: gateway 565 tests, worker 354 tests, package builds, and both migrations on a fresh isolated database. Production DB migration, gateway/worker restart and real VAPID configuration are NOT done; live `/cloud/v1/push/config` is still 404. |
| release subagent | main agent | **Ovid Si release authorized.** The user authorized this release; gateway/worker restarts will be coordinated by the main agent after this commit. |

| web/cloud | Flutter | **Browser credential autofill — security handoff required before re-enabling.** Static audit confirmed that after `browser_login_with_credential` fills a password, arbitrary `browser_evaluate` can read it back. A model-safe brokered login or an equivalent read-back boundary is required; also bind to full HTTPS origin (scheme/host/effective port), and reject site userinfo/query/fragment. The web/cloud session's direct edits under `cloud/packages/browser/` were reverted because that package belongs to Flutter. Current source still exposes legacy autofill; do not describe it as model-safe until Flutter lands adversarial autofill→evaluate exfiltration tests and the boundary. |
| web/cloud | — | **Credential write metadata hardened.** `cloud/apps/gateway/src/routes/credentials.ts` now accepts only HTTPS site metadata and rejects userinfo/query/fragment before sealing/storing; real-Postgres route tests are green. This does not remove the browser-side autofill read-back issue above. |

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
