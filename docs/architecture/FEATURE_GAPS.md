# Ovid Si — feature gaps versus the v2 product spec

**Status:** audit of the code on 2026-10-21.
**Spec:** `docs/superpowers/specs/2026-10-21-ovid-si-product-spec.md`.
**Method:** static reading of the app, gateway, worker, sandbox, storage, mint
and collaboration code. Tests were **not** re-run for this document. The repo's
living TODO claims `flutter analyze` clean and 3,057 app tests passing; treat
that as a claim to re-verify, not as evidence in this file.

**Legend**

| Mark | Meaning |
|---|---|
| ✅ | Implemented and wired on the live path; usable now |
| 🟡 | Implemented in part, or implemented but not wired into the v2 shell |
| ❌ | Not implemented, or the UI claims something the code does not do |
| ⚠️ | Cannot be established from the repo (deployment/console state) |

> The most dangerous gaps are not the missing screens. They are the places
> where the UI says the work happened and the code only signed out, showed an
> empty state, or wrote a local file. Those are called out in
> **§17 False-confidence traps**.

---

## 1. Summary

| # | Spec area | Status | One-line verdict |
|---|---|---|---|
| 4.1 | Chat top bar, model chip order | ✅ | v2 chat/live pages carry the spec order; model picker is wired |
| 4.2 | Composer attach / voice / drafts | 🟡 | Attach + voice + drafts exist; upload quotas and some limits are not enforced |
| 4.3 | Message stream, tools, artifacts, errors | ✅ | Live transcript maps tools, thinking, artifacts and errors |
| 4.4 | Queue and Stop | 🟡 | Facade queue exists; the v2 live screen is fed `queuedCount: 0` |
| 4.5 | Empty state | ✅ | Suggestion cards + voice CTA + allowance copy |
| 5 | 100% session isolation | ❌ | Agent file tools use a per-**user** workspace, not per-session |
| 5 | `@` session/project mentions | ✅ | Live mention source + gateway owner checks + worker injection |
| 5 | Per-session memory at `/workspace/.ovid/memory/{sid}.md` | ❌ | Memory is DB rows, not workspace files; no auto-write after each turn |
| 5 | Project memory | 🟡 | Read/injected for main runs; no write path or auto-learning in the app |
| 5 | Global memory | ❌ | Settings says “Global memory”; no store/API/UI source |
| 5 | Share-session-memory toggle | 🟡 | DB shared scope exists; UI labels it “Global” and maps it loosely |
| 5 | Share chat / fork | ✅ | Snapshot allowlist, read-only viewer, idempotent fork |
| 5 | Pin/rename/move/duplicate/export/delete | 🟡 | UI + local duplicate/export; server delete is soft and leaves files/memory |
| 6 | Sidebar order, rail at ≥900 dp | 🟡 | Order is right; it is always a drawer, never a rail |
| 6 | Search local then server | 🟡 | Search filters the local session list only; FTS endpoint is not called |
| 7 | Studio GitHub OAuth/PAT | 🟡 | Repo picker + device flow/PAT UI; cloud clone token is deployment-wide |
| 7 | Folder gate before Studio send | 🟡 | Gate widget exists; binding port is never installed in production |
| 7 | Cloud clone / branch / fetch / status / sync | 🟡 | Worker git service exists; gateway/queue wiring is incomplete |
| 7 | Ephemeral git credential helper | ✅ | `GIT_ASKPASS`, 0700, deleted, token redacted, not in `.git/config` |
| 7 | File tree / editor / changes / commit / push | 🟡 | v2 page can render a tree/code, but the route feeds no tree/code/diff |
| 7 | Live Preview via gateway proxy | ❌ | No proxy route; v2 page says “no preview URL source exists yet” |
| 8 | Agent-only tabs, 3–5 fps, 45 s headless | ✅ | Backend policy, screencast clamp, headless timer all implemented |
| 8 | Take control for 5 minutes | 🟡 | Takeover exists; no 5-minute auto-release timer in the backend |
| 8 | Browser uploads/downloads to Artifacts | 🟡 | Backend vault bridge exists; v2 browser is not wired |
| 8 | Per-host consent / cookies names-only | ❌ | No consent prompt or cookie-name filter found |
| 9 | 50 subagents, no nesting, 8 h, 300-token JSON, log | ✅ | All enforced in `cloud/packages/agent-core/src/subagents.ts` |
| 9 | Subagent cards and detail from a dispatch row | 🟡 | Detail screen exists; the chat row does not open it |
| 10 | Settings order and pages | 🟡 | Shell matches the spec closely; several rows are `notReady`/inert |
| 10 | Appearance (theme, text, motion, contrast) | 🟡 | Theme + text scale wired; reduce-motion/high-contrast not passed/persisted |
| 10 | Memory / Shared memory / Memory files | 🟡 | Session memory files load; global and project views are empty/inert |
| 10 | Export/import caps | ✅ | 64 MB / 1,000 sessions / 20,000 messages enforced client-side |
| 10 | Crash reports opt-out | 🟡 | Crashlytics opt-in exists; Data control shows a hard-coded `false` |
| 10 | Storage screen | 🟡 | Renders a donut from injected data; live route passes only the plan limit |
| 10 | Delete data / Reset memory | ❌ | Delete is local-only; reset only clears the active chat, despite the copy |
| 10 | Account deletion, 24 h grace | 🟡 | Server lifecycle + `deletion.py` exist; the v2 action still only signs out |
| 10 | Account health / devices / revoke | 🟡 | Page + device routes exist; “System status” is `notReady` |
| 11 | Free/Go/Plus/Pro catalog + prices | 🟡 | UI catalog is new; server mint seeds and Play IDs are still Starter/Pro/Max |
| 11 | 50M/24 h + 1.5B/30 d Free caps | ✅ | Python mint + LiteLLM hook enforce; TS mint port does not |
| 11 | Go 1.5× / Plus 5× / Pro 20× auto | ❌ | Multipliers are seed data; paid plans are explicitly not token-capped |
| 11 | Manual models greyed out and server-rejected | 🟡 | Client greys them; `planGate.ts` helper landed but **no route imports it** |
| 11 | Storage quotas 3/5/15/75 GB | 🟡 | `cloud/packages/storage/src/quota.ts` + `cloud/apps/gateway/src/planGate.ts` exist; upload paths do not reserve |
| 11 | Upload caps 50/day Free, 80/3 h paid | ❌ | No per-day/per-window upload counter; only a 25 MB per-file cap |
| 11 | Custom connectors 0/5/20/20 | 🟡 | Limits exist in `planGate.ts`; `mcpServers.ts` still Pro-only/uncapped |
| 11 | RevenueCat + Play + restore | 🟡 | Both layers exist; entitlement→tier mapping uses legacy 3x/7x/15x; Go product missing |
| 12 | Cloudflare, R2, FCM, App Check | ✅ | Code/config present; live edge state is owner-configured |
| 12 | Postgres RLS | ❌ | No `ROW LEVEL SECURITY`/`CREATE POLICY` anywhere |
| 12 | Per-uid / per-IP rate limits | 🟡 | `server/security/rate_limits.py` + tests landed; **not wired** to account/gateway routes |
| 12 | Sandbox bwrap + uid + cgroups + nft + seccomp | 🟡 | First four exist; **no seccomp profile** |
| 12 | IP-hop block + email + admin unblock | ✅ | `server/security/ip_hop.py` + account runtime + admin routes |
| 12 | TLS pinning when configured | ✅ | Off by default with an empty pin set; documented rollback |
| 12 | App lock (biometric/PIN) | ✅ | Hashed PIN, timeout, cooldown, biometric hook |
| 13 | 50-member collab, one sender, creator storage | 🟡 | Python backend has all three; the app’s collab runtime is a separate device-local projection |
| 13 | Read-only fork | ✅ | Same share/fork service as read-only links |
| 13 | Roles Owner / Can chat / View only; transfer | ❌ | Backend roles are `owner`/`participant`; no transfer-ownership path |
| 14 | Artifacts grid/filter/search/download/share | 🟡 | Grid + filters + detail; download/share/open-in-Studio callbacks are absent on the v2 route |
| 14 | Schedules once/daily/weekly/custom, tz, retry, history | 🟡 | Backend trigger engine is strong; v2 create/toggle/run-now are `notReady` |
| 14 | Run trajectory with tokens/sources/preview | 🟡 | Built from the local transcript; token/duration show “Not reported” |
| 14 | Subagent monitor | 🟡 | Screens exist; not opened from the dispatch row |
| 15 | FCM run/schedule/security pushes | ✅ | Worker notifier + device registration + channels |
| 15 | Deep links to chat/run/schedule | ✅ | Notification routes + `app_router` + pending cold-start route |
| 15 | Offline queue + cached transcripts | ✅ | Cloud outbox + local history |
| 16 | Motion tokens and adoption | 🟡 | Tokens exist; not every v2 surface uses `OFadeSlide`/`OStagger` |
| 17 | Crash reporting, perf traces | 🟡 | Crashlytics opt-in; no cold-start/first-token trace code found |
| — | English + Hindi | ❌ | Only `app_en.arb`; 94 `TODO(l10n)` in v2 (audit-time count); no `app_hi.arb` |

---

## 2. Chat

### 4.1 Top bar and model chip — ✅ / 🟡

- Order `☰ · model chip · Ovid Si · Studio · Browser · ⋮` is implemented in
  `lib/ui/v2/chat/chat_page.dart` and `live_chat_page.dart`; the chip opens
  `model_chip_menu.dart` / `model_picker_sheet.dart`.
- **Gap:** the “manual models allowed” decision is client-side only:
  `lib/ui/v2/app/v2_app_shell.dart` computes
  `autoOnly = tier == 'free' || tier == '3x'` and refuses the tap. The gateway
  does the opposite — `cloud/apps/gateway/src/keys.ts` says “Every plan may use
  every catalog model … there is no per-plan filter”, and
  `cloud/apps/gateway/src/routes/messages.ts` only checks that the model exists
  in the catalog. A modified client can select a manual model on Free/Go.
- The server-side gate the spec requires does not exist. See §11.

### 4.2 Composer — 🟡

- Attach, camera/gallery/file, voice, drafts, permission chip, Studio chip and
  send/stop are present (`chat_page.dart`, `composer_attachments.dart`,
  `composer_voice.dart`, `composer_mentions.dart`).
- Voice languages `en`, `hi`, `hinglish`, `pa`, `ta` are persisted
  (`lib/core/state.dart`, `voiceLanguageIds`).
- **Gaps:**
  - Attachment limits are client-side max 5 files / 8 MB each
    (`composer_attachments.dart`), while the gateway accepts up to 25 MB
    (`cloud/apps/gateway/src/routes/attachments.ts`). The two limits disagree.
  - The spec’s **50 files/day Free, 80 files/3 h paid** caps are not
    implemented anywhere. There is no upload counter; `attachments.ts` only
    checks per-file size and project file capacity.
  - “Send disabled when the plan window is exhausted” is only partly true: the
    surface shows a plan-limited state, but the authoritative stop is a 402
    from mint on send (`messages.ts` → `daily_limit_reached`).

### 4.3 Message stream — ✅

- Live transcript maps user/assistant/tool/thinking/artifact/error rows
  (`lib/ui/v2/chat/live_chat_page.dart`, `lib/ui/v2/app/v2_app_shell.dart`
  `_items`).
- Code fences, copy, artifact cards and retry are present in the screen; tool
  cards carry human labels via `tool_labels.dart` / `_toolIcon`.

### 4.4 Queue and Stop — 🟡

- The facade truly queues while busy and drains on settle
  (`lib/core/cloud/cloud_agent_facade.dart`: `_queues`, `_drainQueue`,
  `queuedMessagesFor`, `queuedMessageCountFor`, `sendQueuedNow`). Queue
  persistence uses `queuePrefKey` (CH-023).
- **Gap:** the v2 live screen never receives the queue. `V2LiveChatData` has
  `queuedCount`/`queuedPreview`, but `_liveData()` in
  `lib/ui/v2/app/v2_app_shell.dart` does not pass them; only the empty-chat
  `_chatData()` passes `queuedCount: 0`. The dock therefore never appears on a
  real running chat.
- **Gap:** queue state is per client, not per account. A second device does not
  see the first device’s queued rows; the server runs one turn per session but
  has no user-visible queue object. The spec says “shown above the composer”,
  which is satisfied only on the device that typed it.

### 4.5 Empty state — ✅

- Headline, subtitle, suggestion cards, voice CTA and allowance line are in
  `lib/ui/v2/chat/chat_page.dart` (empty state builder). Copy is hard-coded
  with `TODO(l10n)`.

---

## 3. Sessions, projects, memory

### 5.1 “100% isolation” — ❌ (filesystem)

This is the most serious product gap.

- Ownership checks on sessions, messages, events, memory and runs are real and
  consistently owner-scoped (`cloud/packages/db/src/repos.ts`,
  `cloud/apps/gateway/src/routes/*`).
- **But the agent’s file tools operate in `{workspacesRoot}/{uid}/workspace`,
  shared by every session of the same user**:
  - `cloud/packages/sandbox/src/manager.ts` builds `workspaceDir` as
    `{uid}/workspace`; `attach(userId)` has no `sessionId`.
  - `cloud/apps/worker/src/main.ts` comments that “the agent itself runs in
    `{root}/{uid}/workspace`”.
  - `cloud/apps/worker/src/sandboxAdapter.ts` resolves every file read/write
    against `handle.workspaceDir`.
  - `cloud/apps/worker/src/runProcessor.ts` attaches with `userId` only.
- Per-session directories exist (`{uid}/sessions/{sessionId}`) and are used by
  the browser, Studio file API and P7 hydration
  (`manager.ts` `workspaceDirFor`, `main.ts` `workspaceDir`), but **not by the
  agent’s shell/file tools**.
- Consequence: a prompt in session B can read `../A/secret.txt` (or simply a
  file left by session A) through the agent. Acceptance test #4 in the spec
  (“a second session cannot read the first session’s files”) **fails**.
- Studio is per-session, so the inconsistency is visible: Studio shows one
  directory, while the agent sees another.

**Fix sketch:** make `/workspace` in the jail a bind mount of
`{uid}/sessions/{sessionId}` for the whole run (and for all tool calls), or
switch to per-session overlay mounts. Keep a separate user-global area only if
a product feature needs it. This is a P0 before any isolation claim.

### 5.2 `@` mentions — ✅

- Composer mention UI + ranking: `lib/ui/v2/chat/composer_mentions.dart`,
  `lib/ui/v2/app/mention_source_live.dart`.
- Gateway validates refs against owned sessions/projects
  (`cloud/apps/gateway/src/routes/messages.ts`, `sessionRefs`/`projectRefs`).
- Worker re-checks ownership and injects context for the run only
  (`runProcessor.ts` `buildReferencedSessionContext`,
  `referencedProjectMemoryContextFor`).
- This one is genuinely end-to-end.

### 5.3 Per-session memory — ❌ (path and lifecycle)

The spec says: `/workspace/.ovid/memory/{sessionId}.md`, written automatically
after each turn, capped at 32 KB, viewable/editable.

What exists:

- A DB-backed private memory store, `private_memory_files`
  (`cloud/packages/db/src/schema.ts`), with per-session scope, 32 files max,
  32 KiB **per file**, revision checks, and a `MEMORY.md` entrypoint
  (`cloud/packages/db/src/privateMemory.ts`).
- Memory tools (`memory_read`, `memory_save`, `memory_search`) use that store
  and explicitly **do not create workspace files**
  (`cloud/packages/agent-core/src/tools/memory.ts`).
- Gateway routes `/memory` are explicitly “the private_memory_files store ONLY…
  no `.ovid/memory` or `.ovid/session-memory` paths”
  (`cloud/apps/gateway/src/routes/memory.ts`).

What is missing:

1. **No automatic write after each turn.** The model may call `memory_save`,
   but the runtime does not synthesize or append a memory summary when a run
   ends. Nothing in `runProcessor.ts` or `agent-core` does this.
2. **No 32 KB session cap**; the cap is 32 KiB per file × up to 32 files
   (~1 MiB per session), plus 80–250 files for projects.
3. **No `.md` file in the workspace**, so the spec’s path is wrong. This may be
   a deliberate improvement (DB isolation is stronger than a file), but the
   product copy and the acceptance criteria still describe files. Pick one and
   make the spec/code agree.
4. **Session memory is not injected into the main prompt**; only project
   memory is (`runProcessor.ts` `projectMemoryContext`). The model must call
   `memory_read` to see the current session’s memory.

### 5.4 Project memory — 🟡

- Read path: `projectMemoryContextForProject` reads project-scope rows and
  injects them into main-agent runs; `@project` refs are also injected for one
  turn (`runProcessor.ts`).
- Write path: **none in the app.** `createMemoryTools` has no project
  namespace; the memory UI only reads the active chat’s session scope
  (`v2_settings_routes.dart` `_MemoryFilesLoader`). The model cannot
  `memory_save` into a project; the store supports it, but no tool calls it.
- Auto-learning: none.

### 5.5 Global memory — ❌

- `V2MemoryPageData` has `globalMemory` and `globalVersionLabel`, but
  `_memory()` passes `globalVersionLabel: ''` and never fills `globalMemory`
  (`lib/ui/v2/app/v2_settings_routes.dart`). The section renders “No global
  memories yet.”
- No store scope for a user-global memory (scopes are a session id, `shared`,
  or `project:<uuid>`; `shared` is the share-session-memory scope, not a
  global facts store).
- The settings copy “Global and project memory” is therefore aspirational.

### 5.6 Share-session-memory — 🟡

- The preference exists (`userPreferences.shareSessionMemory`), and the store
  uses scope `shared` when it is on (`privateMemory.ts`).
- **Gap:** the UI maps the `shared` listing to `V2MemoryFileGroup.global`
  (`v2_settings_routes.dart`), which conflates “shared across this user’s
  chats” with “global memory”. The label should say “Shared memory”, and the
  separate global scope does not exist.

### 5.7 Share chat / fork — ✅

- Snapshot allowlist rejects reasoning/credentials/paths; 500 messages,
  200 KB, 20k chars per message (`cloud/apps/gateway/src/shares/snapshot.ts`).
- Read-only viewer, revoke, expiry and fork are implemented
  (`cloud/apps/gateway/src/shares/routes.ts`).
- The fork path is idempotent and re-checks account identity
  (`lib/ui/shared_conversation_screen.dart`).

### 5.8 Pin / rename / move / duplicate / export / delete — 🟡

- The actions sheet exposes all of them (`session_actions_sheet.dart`), and
  local duplicate/export exist (`lib/core/state.dart`
  `duplicateSession`, `SettingsBackupService`).
- **Delete is not the spec’s delete.** `DELETE /sessions/:id` only soft-deletes
  the row and cancels active runs
  (`cloud/apps/gateway/src/routes/sessions.ts`). It does **not** delete the
  session workspace, memory, attachments or artifacts. The UI copy says
  “Deletes messages, workspace files, memory and artifacts”; the code leaves
  all of them in place. This is a retention/data-rights bug, not just a copy
  bug.

---

## 4. Sidebar

- Order and content are right: profile/plan, New chat, Search, Pinned,
  Projects, Today/Yesterday/Earlier, footer Schedule/Artifacts/Settings
  (`lib/ui/v2/app/v2_app_shell.dart` and `lib/ui/v2/sidebar/*`).
- **Gap: no rail at ≥900 dp.** The shell always uses `Drawer`; there is no
  width breakpoint for a permanent rail. The spec says “drawer below 900 dp
  and a rail at or above it”.
- **Gap: search is local only.** `_openSearch()` builds `V2SearchData` from
  `AppState.I.rootSessionsByRecency`; it never calls the server FTS
  (`messages.searchVector` / `searchMessages`). The spec says local first, then
  server-side. Filter chips and result rows exist; the server half is missing.

---

## 5. Studio

### 7.1 GitHub connect — 🟡

- There is a real GitHub device flow (`lib/core/github_service.dart`) and a PAT
  entry in the repo picker (`lib/ui/v2/studio/repo_picker_page.dart`).
- The v2 route’s “Connect GitHub” and “Personal token” actions are
  **`notReady`** (`lib/ui/v2/app/v2_work_routes.dart`). The device flow is
  reachable from the legacy surface, not from the v2 picker.
- The app token is memory-only; a process restart signs the user out
  (`github_service.dart`). There is no per-user server-side OAuth/PAT store.

### 7.2 Folder gate — 🟡

- `lib/ui/v2/studio/studio_gate.dart` is a correct blocked-composer state.
- The gate is inert in v2 because `StudioBindingPort.instance` is **never
  installed in production**. The only assignments are
  `installForTest` (`lib/core/chat_integration_ports.dart`). The v2 shell calls
  `StudioBindingPort.instance` and gets `null`, so the repo list is always
  empty and the workspace always opens in the empty state.

### 7.3 Cloud clone / branch / fetch / status / sync — 🟡

- The worker has a real git service: clone, fetch, behind count, stash,
  branch switch, credential helper, token redaction
  (`cloud/apps/worker/src/studioGit.ts`, `studioGitQueue.ts`).
- **Gaps:**
  - The worker resolves `tokenFor: async () => cfg.githubToken` — **one
    deployment-wide GitHub token for every user** (`main.ts`). Per-user
    OAuth/PAT is explicitly a future seam in the comments. A shared token
    cannot clone private repos correctly or safely at scale.
  - The gateway does not expose a Studio git route that the app calls; the
    TODO lists “register the Studio git job in BullMQ/gateway” as still open.
  - The v2 workspace’s “Sync latest changes” calls
    `StudioBindingPort.syncLatest(sessionId)` (`v2_studio_routes.dart`), which
    is null in production.
- The credential helper itself is good: ephemeral `GIT_ASKPASS`, mode 0600,
  deleted after the operation, token never in argv or `.git/config`
  (`cloud/packages/sandbox/src/gitCredential.ts`).

### 7.4 File tree / editor / changes / commit / push — 🟡 (empty data)

- The v2 workspace page can render a file tree (`V2FileNode`), an open file’s
  code lines (`V2CodeLine`), changed-file counts and an editor-shaped body
  (`lib/ui/v2/studio/studio_workspace_page.dart`). `file_tree.dart`,
  `code_viewer.dart` and `commit_sheet.dart` also exist.
- **But the route never supplies any of it.**
  `V2StudioRoutes.workspaceDataFor` returns only `repoName` and `branch`; it
  passes no `fileTree`, no `codeLines`, no `onSelectFile`, no saved/dirty state.
  The page therefore shows its empty content state even with a bound repo.
- `onCommit` opens `V2ChangesPage` with `changesDataFor`, which always returns
  `V2ChangesStatus.empty` (“No diff source exists yet”). The commit sheet is
  not reachable. There is no push action in the v2 route.
- So the spec’s core Studio loop (tree → edit → diff → commit → push) is not
  usable in v2, even though the visual pieces and the worker git service exist.

### 7.5 Live Preview — ❌

- `lib/ui/v2/studio/live_preview_page.dart` is a complete presentational page:
  status, expiry, metrics, refresh/stop/share.
- `v2_studio_routes.livePreviewDataFor` returns `V2PreviewStatus.empty` and the
  file comment says “No preview URL source exists yet”.
- There is **no gateway proxy route** to a sandbox port (grep `/preview` under
  `cloud/apps/gateway/src` returns only an unrelated image comment), no
  short-lived preview token, and no tunnel (correctly, tunnels stay blocked).
- This is a product gap and a scale-plan dependency (see `SCALE_PLAN.md`).

---

## 6. Browser

### 8.1 Backend — ✅

The browser engine is one of the strongest parts of the codebase:

- Agent-only tabs enforced server-side (`cloud/packages/browser/src/tabPolicy.ts`),
  with the exact “Ovid opens tabs” refusal.
- Screencast 3–5 fps, default 4, clamped
  (`cloud/packages/browser/src/screencast.ts`).
- 45 s no-human-input → headless, context stays alive
  (`engine.ts`, `watchHeadless.ts`, `OVID_WATCH_IDLE_HEADLESS_MS=45000`).
- Takeover/input exclusivity, human-like input queue, one input queue per
  session (`engine.ts`, `humanInput.ts`, `input.ts`).
- Gateway ops `browser_attach`, `browser_input`, `browser_takeover` with
  ownership checks (`cloud/apps/gateway/src/ws.ts`).
- Uploads/downloads bridge to the Artifact Vault (`engine.ts` `artifactVault`,
  `browserToolAdapter.ts`), with a hardened transfer policy: 50 MB caps, a
  MIME allowlist, and a realpath-checked workspace jail
  (`cloud/packages/browser/src/tools/transfers.ts`,
  `cloud/packages/browser/src/tools/transferPolicy.ts`).

### 8.2 v2 wiring — ❌

- `V2WorkRoutes.openBrowser` pushes `const BrowserPage(data: V2BrowserData())`
  — empty tabs, empty address, `status: content`, no stream, no callbacks
  (`lib/ui/v2/app/v2_work_routes.dart`).
- The real browser UI/stream lives in the legacy `lib/ui/browser_screen.dart`
  / `lib/core/cloud/browser_stream.dart` path, which the v2 shell does not use.
- So a v2 user sees a designed browser screen that is not connected to the
  agent’s browser.

### 8.3 Take control — 🟡

- The backend supports takeover (`browser_takeover`), server-side input gating,
  and releases control when the viewer leaves (`engine.ts`).
- **Gap:** no 5-minute auto-release timer. The spec says “Take control pauses
  the agent for 5 minutes” with a countdown. The UI shows a countdown
  (`take_control_sheet.dart` `countdownLabel = 'Ovid paused · 4:59'`), but the
  backend has no 300 s expiry; control persists until the viewer releases or
  disconnects. The countdown is presentational.

### 8.4 Per-host consent / cookies — ❌

- No consent prompt or per-host approval gate was found in
  `cloud/packages/browser/src` or the v2 browser UI.
- Cookie handling is names-only? The state/persistence code stores
  `storageState`; there is no cookie-name allowlist shown to the user. The
  spec’s “cookies are names-only unless approved” is not implemented as a
  user-facing flow.

---

## 7. Subagents

### 9.1 Runtime — ✅

All of the spec’s hard numbers are enforced in
`cloud/packages/agent-core/src/subagents.ts`:

- `MAX_SUBAGENTS_PER_ROOT = 50`, slot acquired before any await, released on
  every terminal path.
- No nesting: `MAX_SUBAGENT_DEPTH` + `parent.isSubagent` + lineage depth. A
  child cannot dispatch.
- `DEFAULT_SUBAGENT_MAX_RUNTIME_MS = 8 * 60 * 60 * 1000`; timeout reports
  `status: "timeout"`.
- Strict ≤300-token JSON summary (`subagentSummary.ts`, tests in
  `subagentContract.test.ts`).
- Append-only log at `/workspace/.ovid/logs/subagent_{id}.log`, written from
  inside the sandbox (`subagentLogSink.ts`, `runProcessor.ts` wires
  `SANDBOX_SUBAGENT_LOG_DIR`).
- `read_subagent_log` exists so the main agent can read the full log.

### 9.2 UI — 🟡

- `lib/ui/v2/runs/subagent_page.dart` and `run_trajectory_page.dart` exist.
- The dispatch row in the transcript is a generic tool card; there is no
  `onTap` that opens `V2RunRoutes.openSubagent` from the row. The route exists
  but is not reachable from the place the spec names (“the parent sees a card
  per subagent … detail”).
- Subagent cards show name/task/progress/files/elapsed/log preview/stop in the
  screen data model; the live transcript mapping (`_items`) does not populate
  those fields from the server’s subagent events, so the cards are generic
  tool rows in practice.

---

## 8. Settings

### 10.1 Order — ✅ mostly

The five sections match the spec: Account, Chat, Models, Data control,
Advanced (`lib/ui/v2/app/v2_app_shell.dart` settings builder). Rows include
Account, Plan & billing, Usage, Credentials; Appearance, Memory, Shared
memory, Memory files; Connectors, Agent presets, Response wait; Export/import,
Permissions, Crash reports, Storage, Delete data, Reset memory; Notifications,
App lock, Account health, About.

Two deviations:

- Spec puts **App lock** under Account; the shell puts it under Advanced.
- Spec puts **Show reasoning** under Chat; the shell passes it as a toggle on
  the settings data rather than a Chat row. (Functional, but the order differs.)

### 10.2 Actions that are actually inert — ❌

`V2SettingsActions.notReady` prints “<Feature> is not available yet.” It is
wired to:

- GitHub sign-in and Personal token (`v2_work_routes.dart`)
- New schedule, schedule toggle, Run now
- Add custom connector, connector catalog
- New preset
- System status
- Two-factor

That is seven visible settings/work actions that do nothing beyond a snackbar.
Several have real backends (schedules, presets, connectors), so this is wiring,
not missing infrastructure.

### 10.3 Appearance — 🟡

- Theme mode and text scale are wired to `AppState` and persisted
  (`v2_settings_routes._appearance`, `state.dart` `themeMode`).
- **Reduce motion and high contrast are not passed** from the route. The page
  model has `reduceMotion`, `reduceMotionFollowsSystem`, `highContrast`
  (`appearance_page.dart`), but `_appearance()` supplies none and there are no
  callbacks. They therefore render defaults and cannot be changed.
- The spec requires reduced motion, high contrast and accent selection. Only
  theme and text size are real today.

### 10.4 Memory settings — 🟡 / ❌

- `Memory` and `Shared memory` toggles persist through
  `AppState.setMemoryEnabled` / `setShareSessionMemory`.
- `Memory files` loads the active chat’s session-scope files through
  `AccountSettingsClient.memoryFiles` (`v2_settings_routes.dart`), with
  read/delete.
- **Global memory** is empty (`globalVersionLabel: ''`, no list).
- **Project memory** rows are absent (`projects: []` in `_memory()`), and the
  project tap opens the same session file loader.
- **Reset memory** deletes only the active chat’s files, although the dialog
  says “Ovid forgets global, project and session memory”
  (`v2_settings_actions.resetMemory`). Global/project memory is untouched.
- **Memory on/off** does remove the `memory_*` tools from the roster
  (`runProcessor.ts`, `cloud/packages/agent-core/src/roster.ts`), so that part is real.

### 10.5 Data control — 🟡 / ❌

- **Export/import** is real: 64 MB archive cap, 1,000 sessions, 20,000
  messages, pre-flight plan, staging and restore
  (`SettingsBackupService`, `lib/ui/v2/app/v2_settings_actions.dart`
  `exportData`/`importData`).
- **Crash reports**: `_dataControl()` hard-codes `crashReports: false` and
  passes no change callback. The Crashlytics consent itself is real
  (`lib/core/firebase_service.dart` `_consentKey`), but the v2 Data control
  toggle is not connected to it.
- **Storage**: `_storage()` passes only `totalGb` from the plan; `usedGb`
  defaults to 0 and there are no slices/items. The page is a designed empty
  donut, not usage data. Separately, the sidebar footer hard-codes
  `'${_planLabel(tier)} · 3 GB storage'`
  (`lib/ui/v2/app/v2_app_shell.dart`), so paid users see “Plus plan · 3 GB
  storage”.
- **Delete data**: `deleteAllData` clears local prefs, local history, drafts,
  local workspace handles and secure storage, then re-seeds
  (`lib/core/state.dart`). It does **not** call a server delete endpoint. The
  confirmation says “removed from this device and the cloud”. That is false.
- **Reset memory**: active chat only (see 10.4).

### 10.6 Account and deletion — 🟡 / ❌

- Account page shows profile, email, region (hard-coded “Asia Pacific”),
  connected accounts, sign out, delete account (`v2_settings_routes._account`).
- **Delete account in v2 is a stub.** `deleteAccount()` confirms, calls
  `FirebaseService.I.signOut()`, and shows “Deletion request started. Check
  your email.” (`v2_settings_actions.dart`). It does not call
  `requestAccountDeletion`, `AccountService`, or the gateway
  `/account/deletion` route.
- The real client + server exist: `lib/core/account_service.dart` (24 h grace,
  status/cancel), `cloud/apps/gateway/src/routes/account.ts`, the Python
  account runtime, and the newer product-facing
  `server/account/deletion.py` + `deletion_worker.py` (24 h pending/cancel/
  restore semantics, Play management URL). The v2 action bypasses all of it.
  A user can believe their account is being deleted when only the local
  session was signed out.
- This is the highest-severity false claim in the app.

### 10.7 Account health — 🟡

- The page reads four real facts: plan (`/usage` tier), today's counters
  (`/usage` `today`), storage (artifact inventory + this device's transcripts)
  and the deletion receipt (`lastDeletionReceipt`); the status line is derived
  from them, never hardcoded. There is no device/session-list endpoint (only
  `POST`/`DELETE /devices` for the push token) and no 2FA endpoint, so the page
  renders no devices, sign-ins or revoke section and never mentions them
  (`docs/audit/FEATURE_GAPS.md` A6).

---

## 9. Plans, billing and limits

### 11.1 Plan catalog — 🟡

- The UI catalog is the new one: Free $0/3 GB, Go $5/5 GB, Plus $18/15 GB,
  Pro $99/75 GB (`lib/ui/v2/settings/plan_billing_page.dart`,
  `lib/ui/v2/onboarding/paywall_page.dart`).
- **The server seed catalog is still the old one.** `cloud/apps/mint/src/planMath.ts`
  `seedPlans()` returns `free`/`starter`($5)/`pro`($25)/`max`($60) with
  multipliers 3/23/43; the Python authority
  `server/mint/ovid_plans.py` `seed_plans()` does the same. The UI’s Go/Plus/Pro
  names and prices exist only as seeds in the app and as RevenueCat/Play
  mappings (`go→3x`, `plus→7x`, `pro→15x` in
  `lib/core/revenuecat_billing.dart`, `play_billing.dart`,
  `server/billing/products.py`).
- Unless production’s mint settings have been manually overwritten via the
  admin console, the plan rows and prices the app shows do not match the
  server’s defaults. This needs one source of truth.
- The Play product IDs are `ovid_plus_monthly`, `ovid_pro_monthly`,
  `ovid_max_monthly`; there is no Go product. The paywall shows Go. Either Go
  is not purchasable, or the mapping is wrong.

### 11.2 Free token caps — ✅

- Python mint and the LiteLLM hook enforce 50M/24 h and 1.5B/30 d for the
  **free** plan only, with bucketed rolling windows and a typed 429
  (`server/mint/ovid_plans.py` `FREE_DAILY_TOKENS`,
  `server/mint/litellm_hook/*`; `server/mint/mint.py` `token_decision`).
- The TS mint port does **not** have these constants (grep
  `FREE_DAILY_TOKENS` under `cloud/apps/mint/src` returns nothing). If the TS
  mint becomes the live mint, the caps disappear. Treat the Python mint as the
  authority until the port catches up.
- Paid plans are explicitly “never token-capped”
  (`decide_tokens` returns allow for non-free). That is consistent with a USD
  allowance, but it means Go’s “1.5× auto allowance” is not a token cap.

### 11.3 Plan multipliers — ❌

- Go 1.5×, Plus 5×, Pro 20× are UI copy
  (`plan_billing_page.dart` comments and labels). The server’s paid allowance
  is `free_daily_usd × plan.mult × window_hours / 24`
  (`userPools` in `planMath.ts` / `ovid_plans.py`), with old multipliers
  3/23/43. There is no 1.5/5/20 enforcement anywhere.
- If the new plans are meant to be real, the plan data, Play products,
  RevenueCat entitlements and mint settings all need one migration.

### 11.4 Manual model gating — 🟡 (helper landed, not wired)

- Client: `autoOnly` greys rows and refuses selection
  (`v2_app_shell.dart`, `model_picker_sheet.dart`, `model_chip_menu.dart`).
- Server: the P3 helper now exists —
  `cloud/apps/gateway/src/planGate.ts` has `PLAN_ENTITLEMENTS`,
  `normalizePlanTier`, `isAutoModel` and `assertModelAllowed` with tests in
  `planGate.test.ts`. It maps Free/Go to `manualModels: false` and throws a
  typed 403.
- **It is not wired.** A grep for `planGate` in `cloud/apps/gateway/src`
  finds only the helper and its test; `messages.ts` still only checks
  `model_unavailable`, and `keys.ts` still says “Every plan may use every
  catalog model … there is no per-plan filter”. The helper is a good
  foundation, not an enforcement path.
- A modified client, or a direct API call, can still request a manual model on
  Free/Go. This fails spec acceptance #3 (“client or server”).

### 11.5 Storage quotas — 🟡 (package landed, uploads not reserving)

- The UI shows 3/5/15/75 GB and a storage donut.
- The P3 foundation now exists:
  - `cloud/packages/storage/src/quota.ts` defines `PLAN_STORAGE_BYTES`,
    `resolveStoragePlan`, creator-pays `storageAttribution`, a
    `StorageQuotaLedger` seam and `withStorageQuota` reservation wrapper.
  - `cloud/apps/gateway/src/planGate.ts` re-exports the entitlement and
    `assertStorageAvailable`.
  - Both have tests (`quota.test.ts`, `planGate.test.ts`).
- **No upload path calls them.** `attachments.ts` still checks only the 25 MB
  per-file cap and project file count; artifacts/workspace writes do not
  reserve. The only enforced quota is the per-user XFS workspace quota:
  `OVID_WORKSPACE_QUOTA_MB=500` free / `2048` pro
  (`cloud/deploy/worker.env.example`, `cloud/packages/sandbox/src/config.ts`). There is no
  account-wide 3/5/15/75 GB ledger wired to storage.
- At 100M users this is both a product gap and a cost risk (see
  `SCALE_PLAN.md` §9).

### 11.6 Upload quotas — ❌

- Spec: 50 files/day Free, 80 files/3 h paid.
- Code: `attachments.ts` enforces a 25 MB per-file cap and project file
  capacity; no per-day or 3-hour counter exists. The client’s 5-file/8 MB
  limits are separate and inconsistent.

### 11.7 Custom connectors — 🟡 (limit helper landed, route not using it)

- Spec: Free 0, Go 5, Plus 20, Pro 20.
- `planGate.ts` now defines exactly those limits
  (`customConnectorLimit: 0/5/20/20`) and
  `assertConnectorSlotAvailable`, with tests.
- **The route does not call it.** `cloud/apps/gateway/src/routes/mcpServers.ts`
  still rejects any `tier === "free"` and the comment says “Custom servers are
  a Pro feature”. Curated connectors are available to all tiers. There is no
  count check for Go/Plus/Pro, so Go/Plus cannot add custom connectors at all
  and Pro is uncapped.
- Wiring is small: replace the `tier === "free"` checks with
  `assertConnectorSlotAvailable(tier, currentCustomCount)` on both the pasted
  and custom branches.

### 11.8 Billing / restore — 🟡

- RevenueCat + Play Billing + restore are implemented
  (`lib/core/revenuecat_billing.dart`, `play_billing.dart`,
  `lib/ui/v2/app/v2_settings_actions.dart` `buyPlan`/`restorePurchases`).
- The entitlement→tier mapping is the legacy `go/plus/pro → 3x/7x/15x`
  (`revenuecat_billing.dart`). This matches the old server tiers, not the new
  plan names. Restore works, but “which plan am I on” will read as a legacy
  tier in server data.
- The TODO’s “RevenueCat credentials validation / Play subscriptions locked
  until review” is a console/deployment state (⚠️), not a code gap.

---

## 10. Security and trust

### 12.1 Cloudflare / R2 / FCM / App Check — ✅

- Cloudflare is the documented edge (`HARDENING.md`), R2 is the production
  storage backend (`storageEnv.ts` refuses `fs` in production), FCM is wired
  (`notify.ts`, `devices` routes), App Check defaults to `required`
  (`cloud/apps/gateway/src/env.ts`).
- Live edge configuration (WAF rules, Cloudflare account settings) is owner
  state; the repo cannot prove it. ⚠️

### 12.2 Postgres RLS — ❌

- The spec says “session isolation, Postgres RLS”.
- There is **no** `ROW LEVEL SECURITY`, `CREATE POLICY` or
  `current_setting('ovid.uid')` in `cloud/packages/db` or `server/*.sql`.
- Ownership is enforced in repository queries (good), but there is no
  database-level backstop. A single missed `WHERE user_id = ...` becomes a
  cross-tenant read. Add RLS with `SET LOCAL ovid.uid` per transaction.

### 12.3 Per-uid / per-IP rate limits — 🟡 (helper landed, not wired)

- A real P3 helper now exists: `server/security/rate_limits.py` implements
  per-`(uid, route)` token buckets with burst/refill, `Retry-After` headers,
  Redis-backed atomic Lua checks, admin overrides and tests
  (`server/security/tests/test_rate_limits.py`).
- **It is not wired.** A grep for `rate_limits` under `server/` outside the
  helper/tests finds only mint's unrelated `rate_limits(uid)` display fields.
  The account routes, collab routes and the gateway do not call it.
- The gateway has no rate-limit module at all; `/messages` relies on mint for
  quota/rate (per-send internal call), and `server/mint/mint.py` has a per-IP
  `/mint` limit. That is not a gateway-wide per-uid/per-route limit, and it
  does not cover WS frames, workspace/file routes, shares, reports or MCP.
- Spec §12 requires per-uid/per-IP rate limits. Wire the helper into the
  account/shares/collab routes and add a gateway equivalent (or proxy the
  account service) before launch.

### 12.4 Sandbox hardening — 🟡

- bwrap, numeric uid, cgroups v2, nftables egress, read-only rootfs,
  `no-new-privileges` are present (`cloud/packages/sandbox/src/*`,
  `cloud/deploy/net/*`).
- **No seccomp profile** (grep `seccomp` under `cloud/packages/sandbox/src` is
  empty). The spec names seccomp. Add a deny-by-default profile.
- The per-user uid pool is also a scale blocker (see `SCALE_PLAN.md` §6.1).

### 12.5 IP-hop — ✅

- `server/security/ip_hop.py` implements impossible-travel/country-burst,
  session blocks, email notification and admin unblock; the account runtime
  wires it (`server/account/runtime.py`, `domain.py`).
- Deployment needs a real GeoIP database and Cloudflare headers
  (`IP_HOP_DATABASE_PATH`); the code path is present but the TODO says the live
  run is pending. ⚠️ for production.

### 12.6 TLS pinning — ✅ (off by design)

- `lib/core/cert_pinning.dart` ships disabled with an empty pin set and a
  detailed rotation warning. The spec says “TLS pinning when configured”, so
  this is compliant, not a gap. Do not enable leaf pinning behind Cloudflare.

### 12.7 App lock — ✅

- Hashed PIN (salted SHA-256), 2-minute timeout, 5-attempt cooldown, biometric
  hook, settings page and gate (`lib/core/app_lock.dart`,
  `lib/ui/v2/app/app_lock_gate.dart`). Default off, as specified.

### 12.8 Logs and secrets — 🟡

- Studio git redacts tokens; notify redacts device tokens; the client scrubs
  MCP secrets (`lib/core/secret_scrub.dart`).
- There is no single gateway/worker log scrubber for prompts or file contents.
  Event payloads are stored in Redis/PG by design (they are the transcript);
  “logs never contain prompts” is a policy that needs a logging adapter, not
  just ad-hoc redaction. ⚠️

---

## 11. Collaboration

### 13.1 Backend — ✅

`server/collaboration/` has the real invariants:

- 50-member cap including owner (`MAX_ACTIVE_MEMBERS = 50`,
  `schema_extensions.sql` `CHECK (max_uses BETWEEN 1 AND 50)`).
- Single-sender turn lease (`collab_turns`, `_claim_turn`, `turn_taken` 409).
- Creator-paid storage attribution (`collab_storage_files`,
  `collab_storage_usage`, `owner_uid`).
- Account-deletion cleanup and invite lifecycle.

### 13.2 App integration — 🟡

- The v2 collab pages render from `AppState.I.collaboration`, a projection
  maintained by `lib/core/collaboration/production.dart`. That runtime is
  **device-local**: it uses a local atomic file for metadata and a
  `CollaborationTurnRunner` that “runs one AI turn on THIS device's own
  provider/model/key”.
- It is not the cloud chat/session runtime. A shared collab session does not
  use the cloud agent, the user’s cloud plan, or the server’s 50-member turn
  lock in the path the v2 UI exercises.
- `v2_collab_routes.liveDataFor` explicitly sets `creatorPaysStorage: false`
  because “the projection records no storage-payer flag”. So the UI does not
  show the creator-paid storage the server implements.
- If the intent is “collaboration on a cloud session”, this is a missing
  integration, not a small wiring gap.

### 13.3 Roles and transfer — ❌

- Backend roles are `owner` and `participant` only
  (`server/collaboration/repository.py` schema). The spec wants Owner, Can chat,
  View only.
- No transfer-ownership operation was found. The owner cannot leave without
  transferring (the schema enforces exactly one owner, and
  `owner_not_removable` exists), but there is no transfer endpoint, so the
  owner is stuck.

### 13.4 Read-only fork — ✅

- Read-only share links and fork-into-own-account are implemented
  (`cloud/apps/gateway/src/shares/routes.ts`, `shared_conversation_screen.dart`). This is separate
  from the collab roles above.

---

## 12. Library, schedules, runs

### 14.1 Artifacts — 🟡

- `V2WorkRoutes.openArtifacts` constructs a real `ArtifactVaultController` and
  loads items (`lib/ui/v2/app/v2_work_routes.dart`). Grid, filters and detail
  exist (`lib/ui/v2/library/*`).
- **Gaps:** the detail page receives name/type/size/source rows only; the v2
  route does not pass download, share, delete or “open in Studio” callbacks.
  The spec lists all of them. Missing files show a recoverable error only if
  the caller supplies the error state; the live route does not.

### 14.2 Schedules — 🟡

- Backend is strong:
  - trigger kinds `at`, `every`, `daily_at`, `cron` with IANA timezones and
    DST handling (`cloud/packages/shared/src/triggers.ts`);
  - missed-run policy, retries, run history, pause/resume, claim ledger,
    BullMQ mirror, FCM (`cloud/apps/gateway/src/routes/schedules.ts`,
    `cloud/packages/db/src/scheduleService.ts`,
    `cloud/apps/worker/src/scheduler*.ts`).
- v2 list is real (`ScheduleClient.I.list()` in
  `v2_work_routes.openSchedules`).
- **Gaps:** “New schedule”, toggle, “Run now” and retry are `notReady`
  (snackbar). The runs page is pushed with `const V2ScheduleRunsData()` (empty).
  The schedule editor page exists but is not reachable from the list. So the
  user can see schedules but cannot create or control them in v2.

### 14.3 Run trajectory — 🟡

- `V2RunRoutes.trajectoryDataFor` builds steps from the local `ChatSession`
  transcript. It shows prompt, model, steps and status; tokens/duration show
  “Not reported” when the session has no analytics
  (`lib/ui/v2/app/v2_run_routes.dart`).
- There is no gateway trajectory endpoint; `cloud/apps/gateway/src/routes/runs.ts`
  only has `POST /runs/:id/cancel`. The spec wants sources, files, previews,
  durations and model tokens per step. That data exists in events/run_usage but
  is not assembled into a DTO the app consumes.

### 14.4 Subagent monitor — 🟡

See §7.2: backend is complete; the v2 route exists; the dispatch row does not
open it.

---

## 13. Notifications, deep links, offline

### 15.1 FCM — ✅

- Worker push for run finished/failed, schedule results, security/approval
  (`cloud/apps/worker/src/notify.ts`, `cloud/apps/worker/src/main.ts`), device
  registration (`cloud/apps/gateway/src/routes/devices.ts`), channels and
  quiet hours in the app (`lib/core/background_notifications.dart`,
  `lib/ui/v2/settings_extra/notifications_page.dart`).

### 15.2 Deep links — ✅

- Notification routes `/c/:sessionId`, `/schedule/:sessionId`
  (`background_notifications.dart`), `app_router.dart`, pending cold-start
  route in `lib/main.dart` (`NativeRouteChannel.takePendingRoute`).
- Share links route through `ShareLinkResolver` and the viewer.

### 15.3 Offline — ✅

- Cloud outbox + `ConnectionService` offline gate + queued frames
  (`lib/core/cloud/cloud_ws.dart`, `cloud_agent_facade.dart`), local cached
  transcripts (`SessionHistoryRepository`).
- “Messages will send when you reconnect” copy is present.
- **Gap:** notification permission banner state is still a TODO in the living
  TODO (P1); the v2 banner is not wired to Android’s actual permission state.

---

## 14. Motion, accessibility, localization

### 16 Motion — 🟡

- Tokens and `OFadeSlide`/`OStagger` exist (`lib/ui/design/o_motion.dart`,
  `o_components.dart`), and many v2 pages use them.
- Reduced motion is a page-model field but not wired/persisted (see 10.3).
  “Every entrance uses the motion system” is not auditable from the code
  without a per-screen sweep; treat it as partial.

### 17 Telemetry — 🟡

- Crashlytics/Analytics are consent-gated (`lib/core/firebase_service.dart`);
  `FirstRunSteps.telemetry` and the settings copy are real.
- No cold-start/first-token/frame-build trace code was found. The spec’s
  performance traces are missing; crash-free/ANR dashboards are console state
  (⚠️).

### Localization — ❌

- Only `lib/l10n/app_en.arb` exists; there is no `app_hi.arb`.
- 94 `TODO(l10n)` comments under `lib/ui/v2` (audit-time count); nearly every v2 screen has
  inline English.
- The plan’s D5 says English + Hindi. This is not started in the v2 surface.

### Accessibility — 🟡

- The v2 design system has 48 dp targets, semantic labels and 320 dp/200 %
  ratchets; the living TODO claims 102 ratchet tests pass (51 screens ×
  light/dark) and 3,057 app tests pass.
- Those tests were not re-run here. The screens are designed for it; a real
  TalkBack pass per screen is still listed as P2.

---

## 15. Acceptance checklist (§19 of the spec)

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | All screens light/dark, 320 dp, 200 % | ✅ per repo TODO | 102 ratchet tests claimed; not re-run here |
| 2 | Every destructive action names its consequence | 🟡 | Copy is good, but Delete data/account do less than the copy says (§17) |
| 3 | Free/Go cannot select manual models, client or server | ❌ | Client only; server catalog explicitly allows all models |
| 4 | Second session cannot read first session’s files | ❌ | Per-user workspace shared by all sessions |
| 5 | Studio cannot send before folder; moved remote surfaces Sync | 🟡 | Gate widget + sync chip exist; binding port is null; cloud git not wired |
| 6 | 50-member collab, exactly one sender | 🟡 | Server enforces; app collab runtime is separate/device-local |
| 7 | Reduced motion removes entrance animation | 🟡 | Motion tokens exist; setting is not wired |
| 8 | `flutter analyze` clean, full suite green | ✅ per repo TODO | Claimed; not re-run here |

---

## 16. P0 launch blockers (ordered)

1. **Per-session filesystem isolation.** Bind the agent’s `/workspace` to the
   session directory. Without it, acceptance #4 is false.
   Files: `cloud/packages/sandbox/src/manager.ts`,
   `cloud/apps/worker/src/main.ts`, `cloud/apps/worker/src/sandboxAdapter.ts`,
   `cloud/apps/worker/src/runProcessor.ts`.
2. **Account deletion in v2 is a stub.** Wire `V2SettingsActions.deleteAccount`
   to `AccountService.requestDeletion` / the gateway `/account/deletion` route,
   or change the copy to “Sign out”. The server side is ready:
   `server/account/deletion.py`, `deletion_worker.py`,
   `cloud/apps/gateway/src/routes/account.ts`. Files:
   `lib/ui/v2/app/v2_settings_actions.dart`, `lib/core/account_service.dart`.
3. **“Delete all data” is local-only.** Call a server delete (sessions,
   workspace, artifacts, memory) or stop claiming cloud deletion. Files:
   `lib/core/state.dart` `deleteAllData`, `cloud/apps/gateway/src/routes/sessions.ts`.
4. **Server-side manual-model gate.** Import and call `assertModelAllowed`
   from `cloud/apps/gateway/src/planGate.ts` in `messages.ts` (and, for defense
   in depth, the worker’s model pin). The helper and tests already exist.
5. **Rate limits + RLS.** Wire `server/security/rate_limits.py` into the
   account/shares/collab routes and add a gateway limiter; add Postgres RLS.
   Files: `cloud/apps/gateway/src/*`, `cloud/packages/db/src/schema.ts`.
6. **Plan storage, upload and connector quotas.** Wire
   `cloud/packages/storage/src/quota.ts` into `attachments.ts`/artifacts and
   `assertConnectorSlotAvailable` into `mcpServers.ts`; add the 50/day and
   80/3 h upload counters. The helpers exist; the routes do not call them.
7. **Studio end-to-end.** Install a real `StudioBindingPort`, wire per-user
   GitHub auth and the git job through the gateway, and feed the v2 workspace
   tree/editor/changes/commit from `StudioRemoteClient`. Files:
   `lib/ui/v2/app/v2_*`, `cloud/apps/gateway/src`,
   `cloud/apps/worker/src/studioGit*.ts`.
8. **Live Preview.** Add the gateway proxy + short-lived token; the v2 page is
   currently an empty state by design.
9. **Browser v2 wiring.** The v2 route pushes empty `V2BrowserData`; connect
   the real stream/attach/takeover. Add the 5-minute takeover expiry.
10. **Queue dock wiring.** Pass `queuedCount`/`queuedPreview` into
    `V2LiveChatData` and wire `onSendQueuedNow`/`onDismissQueued`.
11. **Global/session memory.** Decide DB or workspace files, then implement
    auto-write, global scope, project write path, and the 32 KB cap.
12. **l10n.** Add `app_hi.arb` and remove the `TODO(l10n)` markers (94 at audit time).
13. **Delete-session semantics.** Remove workspace/memory/artifacts, or change
    the copy and the spec.

---

## 17. False-confidence traps

These are the places where a demo looks finished but the underlying product is
not:

| Surface | What it says | What the code does |
|---|---|---|
| Delete account card | “Deletion starts a 24-hour grace period… signing in cancels it” | `deleteAccount()` signs out and shows a snackbar. The server lifecycle (`deletion.py`) is ready but is not called. |
| Delete data card | “removed from this device and the cloud” | `AppState.deleteAllData()` clears local state only. |
| Reset memory dialog | “forgets global, project and session memory” | Deletes only the active session’s memory files. |
| Storage screen | Donut + “3 GB” quota | `_storage()` passes only `totalGb`; `usedGb` is 0; no slices. |
| Crash reports toggle | Opt-out | `_dataControl()` hard-codes `crashReports: false`, no callback. |
| Studio | Repo picker, branch, sync chip, Preview button | `StudioBindingPort.instance` is never installed; repo list is empty; changes/preview are empty states. |
| Browser | Tab strip, live view, Take control | v2 pushes `const V2BrowserData()`; no attach/stream; countdown is a label. |
| Queue | “N messages waiting” dock | `_liveData()` does not pass `queuedCount`; only the empty chat passes 0. |
| Collaboration | Members, one sender, creator pays storage | App runtime is device-local and sets `creatorPaysStorage: false`; server collab is separate. |
| Plans | Free/Go/Plus/Pro with new limits | `planGate.ts`/`quota.ts` exist but no route calls them; server seeds are Starter/Pro/Max; manual/storage/upload/connector gates are not enforced. |
| “100% isolation” | Session isolation | Filesystem is per-user; logical DB checks are real. |
| Appearance | Reduce motion, high contrast | Page model has them; route passes neither. |
| Global memory | “Global and project memory” | `globalMemory` is always empty; no global scope exists. |

---

## 18. What is genuinely good

To keep the audit honest, these are substantial and should not be rewritten:

- **Subagent runtime**: 50 cap, no nesting, 8 h, strict 300-token JSON,
  sandbox-local log, `read_subagent_log`.
- **Queue/stop semantics in the facade**: durable composer queue, outbox,
  offline gate, stop-and-send-queued.
- **Share/fork**: allowlisted snapshot, read-only viewer, idempotent fork.
- **Studio credential helper**: ephemeral `GIT_ASKPASS`, redaction, no token in
  `.git/config`.
- **Browser backend**: agent-only tabs, 3–5 fps clamp, 45 s headless, human
  input queue, takeover gating.
- **Scheduler**: timezone-aware triggers, DST handling, retries, claim ledger,
  BullMQ mirror, FCM.
- **Sandbox primitives**: bwrap, cgroups v2, per-uid quotas, nftables egress.
- **Storage**: R2 adapter, presigning, range reads, CDN signed URLs, content-
  addressed artifacts.
- **Account/Python services**: 24 h deletion grace, IP-hop, billing, image
  ledger, collaboration 50/turn/storage. The newer P3 helpers —
  `cloud/apps/gateway/src/planGate.ts`, `cloud/packages/storage/src/quota.ts`, `server/security/rate_limits.py`,
  `server/account/deletion.py`, `cloud/packages/browser/src/tools/transferPolicy.ts` — are
  well-tested foundations; they need wiring, not redesign.
- **Design system**: light/dark tokens, 48 dp, 200 % ratchet, motion tokens.

The rebuild is real. The remaining work is mostly **wiring the v2 shell to the
real services**, **making the server enforce the promises the UI makes**, and
**fixing the two architectural isolation/scale blockers**.

---

## 19. Suggested order of work

1. Truth pass (1–2 days): delete-account/delete-data/reset-memory copy and
   wiring; crash-report toggle; storage usage; remove or implement `notReady`
   rows. Never ship a destructive action that lies.
2. Isolation pass (P0): per-session `/workspace` + a regression test that
   session A cannot read session B's file through a tool.
3. Enforcement pass: manual models, storage, uploads, connector caps, rate
   limits, RLS.
4. Studio/Browser wiring pass: install the binding port, per-user GitHub,
   git job route, tree/editor/changes, preview proxy, browser stream/takeover.
5. Memory decision: DB vs workspace files; implement auto-write + global +
   project write; fix the 32 KB cap semantics.
6. Queue/plan polish: queue dock, schedule editor/actions, trajectory DTO,
   subagent row tap.
7. l10n + TalkBack + perf traces.

Each item has a file pointer above; none requires a rewrite of the good
backend pieces.
