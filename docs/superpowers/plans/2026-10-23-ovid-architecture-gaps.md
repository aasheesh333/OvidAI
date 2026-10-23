# Ovid Si — Architecture Gap Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the six P0 and four P1 gaps found in the architecture audit, in the order that makes each later fix safe.

**Architecture:** Server-first. Every task changes the authoritative enforcement point (gateway, worker, sandbox, mint) and only then the client that reflects it. No task relies on a client-side check for a limit the spec calls a guarantee.

**Tech Stack:** TypeScript (Fastify gateway, worker, `@ovid/sandbox`, `@ovid/agent-core`), Python (mint), Flutter (client), Postgres, Redis, R2.

**Spec:** The owner's architecture brief (verbatim requirements are quoted in each task's "Spec" line) plus the audit findings recorded in this session.

## Global Constraints

- Palette: Paper `#F4F1EA`, Ink `#1B1B1B`, Signal Red `#E5484D` (agent only), Stone `#8A867D`. No gradients, no glow.
- Every limit the spec states is enforced server-side. The client greys out; the server refuses.
- `flutter analyze` clean; full test suite green before each commit.
- Do not change UI layout or copy except where a task names it.
- No new dependency without a line here explaining why the existing stack cannot do it.
- Commits are per task, message `fix(<area>): <what>`.

## Review Focus

- **A second session reading the first session's files** — must return "no such file", not the content.
- **A refused upload** — must not leave an attachment row, a presigned URL, or a byte in R2.
- **A blocked key** — must refuse before any upstream call, and the owner must be told.
- **A connector enabled in the UI** — must be visible to the agent as tools, or not appear enabled at all.
- **A Studio session after app restart** — must not ask the user to sign in to GitHub again.
- **A settings row tapped on a stale build** — must open the screen the label promises.

---

## Task 1: Per-session sandbox workspace

**Spec:** "har session 100% isolated hota h jisse ek session dusare session se conflicts nahi kr sakta and naa hi padh sakta hai jab tak user @ karke session ko mention na kare"

**Why:** `manager.ts:347-348` builds `{workspacesRoot}/{uid}/workspace` and `runProcessor.ts:1092` calls `attach(userId)` with no session, so every chat shares one directory. The system prompt at `systemPrompt.ts:45-47` claims otherwise.

**Files:**
- Modify: `cloud/packages/sandbox/src/manager.ts` (add `attachSession`, keep `attach`)
- Modify: `cloud/packages/sandbox/src/exec.ts:96-116` (ctx factory already accepts `workspaceDir`; no change needed — confirm)
- Modify: `cloud/apps/worker/src/runProcessor.ts:1092` (attach per session)
- Modify: `cloud/apps/worker/src/sandboxAdapter.ts:164-216` (workspace resolver takes sessionId)
- Modify: `cloud/apps/worker/src/tools/fileTools.ts` (no change if the ctx value is already used — confirm)
- Test: `cloud/packages/sandbox/src/manager.session.test.ts` (new)
- Test: `cloud/apps/worker/src/sessionIsolation.test.ts` (new)

**Interfaces:**
- Produces: `SandboxManager.attachSession(userId: string, sessionId: string, opts?: { tier?: "free" | "pro" }): Promise<SandboxHandle>`
- Produces: `SandboxHandle.workspaceDir` — for a session handle this is `{workspacesRoot}/{uid}/sessions/{sessionId}/workspace`
- Produces: `SandboxManager.sessionWorkspaceDir(userId: string, sessionId: string): Promise<string>` (the host path, created + chowned + quota-applied)
- Consumes: existing `workspaceDirFor(userId, sessionId)` (returns `{uid}/sessions/{sessionId}`)

**Design:** the env (cgroup, `etc/`, `.home/`) stays per-user. Only the bwrap `/workspace` bind differs, so two sessions can exec concurrently without sharing data and without a second cgroup. A derived handle reuses the parent env's uid/rootfs/cgroups and gets its own `JailContext` and its own job registry.

- [ ] **Step 1: Write the failing isolation test**

```ts
// cloud/apps/worker/src/sessionIsolation.test.ts
it("a file written in session A is not visible in session B", async () => {
  await writeFile(a, "/workspace/secret.txt", "A-only");
  const got = await readFile(b, "/workspace/secret.txt");
  await expect(got).rejects.toThrow(/no such file/);
});
```

- [ ] **Step 2: Run it and confirm it fails** — `npx vitest run cloud/apps/worker/src/sessionIsolation.test.ts` → the read succeeds today.

- [ ] **Step 3: Add `sessionWorkspaceDir` + `attachSession` in `manager.ts`**

`sessionWorkspaceDir` = `join(await workspaceDirFor(userId, sessionId), "workspace")`, then `mkdir -p`, `chown` to uid, and re-assert the same tier-aware quota `workspaceDirFor` applies.

`attachSession` = `const base = await attach(userId, opts)` then a derived handle whose `exec` and `jobs` use a `JailContext` cloned from the base with `workspaceDir: sessionWorkspace`. Keep the base ctx in a module-level `ctxByUser` map populated in `doAttach`.

- [ ] **Step 4: Pass the session through the worker**

`runProcessor.ts`: replace `attach(userId, {tier})` with `attachSession(userId, job.data.sessionId, {tier})`. Build the tool ctx with `workspaceDir: handle.workspaceDir`. `sandboxAdapter.ts`: change `attach(userId)` to `attachSession(userId, sessionId)` and thread `sessionId` from the run.

- [ ] **Step 5: Run the isolation test and the sandbox suite** — `npx vitest run cloud/packages/sandbox cloud/apps/worker/src/sessionIsolation.test.ts`. Expected: PASS, no regression.

- [ ] **Step 6: Commit** — `fix(sandbox): per-session workspace isolation`

---

## Task 2: Session workspace in the prompt and in Studio

**Spec:** Studio must clone into a workspace that outlives the chat and is not the chat's scratch dir.

**Files:**
- Modify: `cloud/apps/worker/src/runProcessor.ts` (pass the real workspace to `buildSystemPrompt`)
- Modify: `cloud/apps/worker/src/studioGit.ts` (clone root = `{uid}/studio/{repo}`)
- Test: `cloud/apps/worker/src/studioWorkspace.test.ts` (new)

**Interfaces:**
- Consumes: `SandboxManager.sessionWorkspaceDir` (Task 1)
- Produces: `studioWorkspaceDir(userId: string, repo: string): string`

- [ ] **Step 1: Failing test** — a Studio clone lands under `{uid}/studio/`, and the chat workspace does not contain `.git` after cloning.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — Studio root from the manager; `buildSystemPrompt({ workspaceFolder: sessionWorkspace })` so the prompt names the true path.
- [ ] **Step 4: Pass + commit** — `fix(studio): clone into a dedicated workspace root`

---

## Task 3: Connectors wired to the gateway

**Spec:** "connectors screen me inbuilt 50+ plugins and mcp rahengi jo main agent and subagent me proper kaam karengi ... user unko enable karke usko agent and subagent use kare"

**Why:** `v2_work_routes.dart:156-174` passes `connectors: []`; no Dart file calls `/mcp/servers` or `/mcp/catalog`. The 168 catalogue rows are display-only.

**Files:**
- Create: `lib/core/connectors/connector_api.dart`
- Modify: `lib/ui/v2/connectors/connector_store.dart` (add a remote-backed store)
- Modify: `lib/ui/v2/app/v2_work_routes.dart:156-174` (load from the API)
- Modify: `lib/ui/v2/connectors/catalog_data.dart` (drop entries with no backing, or mark `comingSoon`)
- Test: `test/connectors/connector_api_test.dart` (new)
- Test: `test/connectors/connector_store_remote_test.dart` (new)

**Interfaces:**
- Produces: `ConnectorApi.listCatalog() → Future<List<V2CatalogServer>>`, `ConnectorApi.listConfigured() → Future<List<V2ConnectorConnection>>`, `ConnectorApi.connect(curatedId, secrets)`, `ConnectorApi.disconnect(id)`
- Consumes: `GET /mcp/catalog`, `GET /mcp/servers`, `POST /mcp/servers`, `DELETE /mcp/servers/:id`

- [ ] **Step 1: Failing test** — a configured connector returned by the gateway appears in the Installed tab; an unconfigured one appears in Available.
- [ ] **Step 2: Confirm it fails** (the page shows the empty injected list).
- [ ] **Step 3: Implement `ConnectorApi`** over the existing `OvidCloudService` auth/headers; no new HTTP client.
- [ ] **Step 4: Back the store with the API**, keeping `V2PrefsConnectorStore` as the offline cache.
- [ ] **Step 5: Trim the catalogue** to entries the gateway can serve; anything else renders `Coming soon` and cannot be enabled.
- [ ] **Step 6: Pass + commit** — `fix(connectors): load, enable and persist via the gateway`

---

## Task 4: GitHub token survives restart

**Spec:** "studio screen me user ko yaa to apne GitHub ki api key access token dalna hoga ya GitHub se approve dena hoga"

**Why:** `github_service.dart:69` — "NOT persisted; a process restart signs the user out." `credentials_page.dart:364-380` writes a PAT to SecureStore that nothing reads, and `onSaveGithubPat` is never wired (`v2_settings_routes.dart:889-941`).

**Files:**
- Modify: `lib/core/github_service.dart` (persist + restore)
- Modify: `lib/ui/v2/app/v2_settings_routes.dart:889-941` (wire the PAT saver)
- Modify: `lib/core/studio_binding.dart` (restore before `ready`)
- Test: `test/github_token_persistence_test.dart` (new)

**Interfaces:**
- Produces: `GitHubService.restore() → Future<bool>`; `GitHubService.savePat(String) → Future<void>`
- Consumes: `ovidSecureStorage()` from `lib/core/secure_store.dart`

- [ ] **Step 1: Failing test** — token saved, service reconstructed, `isLoggedIn` true and `token` equal.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — one SecureStore key `github.token`; write on successful device flow and on PAT save; read in `initialize()`; delete in `signOut()`. Never log the value.
- [ ] **Step 4: Wire the PAT row** so it calls `savePat` and refreshes the Studio badge.
- [ ] **Step 5: Pass + commit** — `fix(studio): persist the GitHub credential across restarts`

---

## Task 5: Upload window quotas

**Spec:** "Free 50 files / day ... Go/Plus/Pro 80 files / 3 hours"

**Why:** only the per-project cap and the storage quota are enforced (`attachments.ts:117`, `planGate.ts:116`). The window counter does not exist.

**Files:**
- Modify: `cloud/apps/gateway/src/planGate.ts` (add `filesPerWindow`, `fileWindowHours` to `PlanEntitlements`)
- Create: `cloud/apps/gateway/src/uploadWindow.ts`
- Modify: `cloud/apps/gateway/src/routes/attachments.ts:110-135` (check before presign)
- Test: `cloud/apps/gateway/src/uploadWindow.test.ts` (new)
- Test: `cloud/apps/gateway/src/routes/attachments.test.ts` (extend)

**Interfaces:**
- Produces: `assertUploadWindow(deps, uid, tier, now) → Promise<void>`; throws `UploadWindowExceededError` with code `upload_limit_reached`, `retryAt`
- Consumes: Redis sorted set `uploads:{uid}` scored by epoch ms

- [ ] **Step 1: Failing test** — the 51st Free upload in 24 h is refused with `upload_limit_reached` and no attachment row exists.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — `ZREMRANGEBYSCORE` past the window, `ZCARD`, then `ZADD` only after the check passes; refuse before presigning.
- [ ] **Step 4: Pass + commit** — `fix(uploads): enforce the plan's file window`

---

## Task 6: Connector count caps

**Spec:** "Free 0, Go 5, Plus/Pro 20"

**Why:** `assertConnectorSlotAvailable` (`planGate.ts:190`) is defined but never called; `mcpServers.ts:267,332` only blocks `free`.

**Files:**
- Modify: `cloud/apps/gateway/src/routes/mcpServers.ts` (call the assertion in both create paths)
- Test: `cloud/apps/gateway/src/routes/mcpServers.test.ts` (extend)

- [ ] **Step 1: Failing test** — a Go user's 6th custom server is refused with `connector_limit_reached`; deleting one frees the slot.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — count before create, inside the same transaction as the insert.
- [ ] **Step 4: Pass + commit** — `fix(connectors): enforce the per-plan custom connector cap`

---

## Task 7: Collab turn lock regression test

**Spec:** "jab tak kisi ek user ka output khatam nahi ho jata tab tak dusra user msg nahi kr sakta uss Collab session me send icon greyed out rahe"

**Why:** the gate exists (`collab_live_page.dart:437-452` + `turnHolderId`), but no test pins the streaming case, and `turnHolderId` returns `null` when the last message is an assistant message — which is exactly the streaming case.

**Files:**
- Modify: `lib/ui/v2/app/v2_collab_routes.dart:171-184` (treat a streaming model state as a held turn)
- Test: `test/v2/collab_turn_lock_test.dart` (new)

- [ ] **Step 1: Failing test** — with participant A streaming and the last message an assistant message, `isMyTurn` is false for B.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — check `modelStates` for `streaming` before the message-author fallback.
- [ ] **Step 4: Pass + commit** — `fix(collab): keep the composer locked while a peer streams`

---

## Task 8: Security email transport

**Spec:** "user ko email jayega you account has found suspended because of suspicious activity"

**Why:** `mint.py:337` leaves `KEY_IP_EMAIL_SENDER = None`, so `:1238` prints instead of sending.

**Files:**
- Create: `server/mint/mail.py` (transport + template)
- Modify: `server/mint/mint.py:336-337` (default the sender from env)
- Test: `server/mint/tests/test_key_ip_email.py` (new)

**Interfaces:**
- Produces: `build_suspension_email(event) -> dict` and `send_via_resend(api_key, payload) -> bool`
- Consumes: `OVID_MAIL_API_KEY`, `OVID_MAIL_FROM`

- [ ] **Step 1: Failing test** — a fan-out event enqueues one email whose body names the reason and the support link.
- [ ] **Step 2: Confirm it fails.**
- [ ] **Step 3: Implement** — env-gated transport; unset key logs a warning and keeps the queue entry (never silently drops).
- [ ] **Step 4: Pass + commit** — `fix(security): deliver the key-suspension email`

---

## Task 9: Settings order, prompt feature map, subagent refusal event

**Spec:** "data control card k upar models card kr do"; "system prompt ... ovid si ka har feature ka context pata ho kaha kya hai"; "subagent limit ... user ko pata chale"

**Files:**
- Modify: `lib/ui/v2/app/v2_app_shell.dart:1771-1940` (card order: Account → Plan → Usage → Personalization → Connectors → Models → Data control → Advanced)
- Modify: `cloud/packages/agent-core/src/systemPrompt.ts:41-84` (feature map block)
- Modify: `cloud/packages/agent-core/src/subagents.ts:181` (emit a session event on refusal)
- Test: `test/v2/settings_order_test.dart` (new)
- Test: `cloud/packages/agent-core/src/systemPrompt.test.ts` (extend)

- [ ] **Step 1: Failing tests** — card order matches the spec; the prompt names Studio, Browser, Share, Artifacts and Schedules; a refusal emits `subagent_limit_exceeded`.
- [ ] **Step 2: Confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Pass + commit** — `fix(settings): match the spec's card order and agent self-knowledge`

---

## Self-Review

**Spec coverage:** every quoted spec line maps to a task. P0-1→T1, P0-2→T3, P0-3→T4, P0-4→T7, P0-5→T5, P0-6→T8, P1-1→T6, P1-2/3/5→T9. Studio workspace→T2.

**Deferred deliberately:** hibernation, regional gateways, prompt-injection delimiters, SSRF allowlist for MCP URLs, artifact CDN TTL — these are scale/security hardening that need their own design pass, not a gap fix.

**Ordering:** T1 before T2 (Studio root depends on the session workspace seam). T3 and T4 are independent of each other and of T1. T5 and T6 are independent server changes. T7 is client-only. T8 is Python-only. T9 is last because it touches copy that T3 changes.
