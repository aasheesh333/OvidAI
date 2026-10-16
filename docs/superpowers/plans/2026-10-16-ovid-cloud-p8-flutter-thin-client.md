# P8 — Flutter Thin-Client Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Ovid Flutter app into a zero-setup thin client of the Ovid Cloud stack: all agent execution, files, terminal, browser, and schedules live server-side; the app renders the cloud event stream, keeps a read cache + prompt outbox offline, and sheds ~107k LOC of on-device execution machinery — while sideload builds keep working through the transition via feature flags.

**Architecture:** Three server-gap tasks extend the P1 gateway additively (run cancel, session PATCH, attachment upload, clientMsgId idempotency + history import). A new `lib/core/cloud/` client library (REST wrapper, WS multiplexer, event→transcript projector, AgentService-shaped facade, session store) is built and unit-tested FIRST, fully dark. Screens then rebind to the facade/store behind `Distribution.cloudExecution`, and removal waves delete the local execution stack one compile-clean slice at a time; `agent_service.dart` (26,735 LOC, 25 importers) dies IN PIECES — each deletion wave (Tasks 12–18) mechanically strips the imports/members that wave's deletions make dead — and the file itself dies last (Task 19's final rewrite). Binding research: `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/p8-flutter-strip-worklist.md` (file-level worklist; all LOC/importer/call-site counts below are its measurements).

**Tech Stack:** Flutter/Dart (existing app, `flutter analyze` + `flutter test`), `package:http` (+ `MockClient` for tests), `dart:io` WebSocket (cert-pinned via existing `OvidPinningHttpOverrides`), `firebase_messaging` (new dep), SharedPreferences + sqlite3 (`session_history_store.dart`) for cache/outbox; TypeScript strict + Fastify 5 + Drizzle + Vitest for the gateway/worker additions under `cloud/`.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` — §12 (removed/kept/offline), §13.2–13.3 (strangler, history import), §6.2 (client protocol), §8 (schedules), §10 (data layer), §14 (phase table), §15 (verbatim error contracts), D3 (BYOK escrow), D5 (control removed / voice stays / WebView browser removed), D6 (private_sync deleted), NG3 (no permanent local fallback), AG4 (Dart suite is the behavioral contract), R6 (Data Safety owner task).

## Global Constraints

- `flutter analyze` reports **No issues found** AND `flutter test` is green after EVERY task; each removal wave is compile-clean before the next wave starts.
- `agent_service.dart` dies in pieces (the worklist §1C model): every deletion wave (Tasks 12–18) lists it in Modify for the MECHANICAL removal of the imports/members that wave's deletions make dead — dead-code removal ONLY, no behavior redesign; the file's final rewrite/deletion is Task 19. This is what makes the analyze-green-per-task constraint achievable.
- Wire contracts EXACTLY as built in `cloud/` — read the code, do not guess: REST under `/cloud/v1`, WS at `GET /cloud/ws?ticket=` (single-use ticket, 60 s TTL, minted via `POST /cloud/v1/auth/ticket` → `{ticket}`), event envelope `{sessionId, seq, type, payload, ts}`, event types `run_started{runId}`, `message_delta{runId,text}`, `message_completed{messageId,content}`, `run_started_retry{attempt,nextBackoffMs}`, `run_failed{code,message?}`, `run_completed{runId}`, `system_note`; WS client ops `subscribe{sessionId,lastEventId?}` / `unsubscribe{sessionId}` / `ping`, server ops `subscribed` / `event` / `pong` / `error{code,message,sessionId?}`; auth failure = error frame + close code **4401**.
- All JSON is camelCase on the wire (matches `cloud/packages/shared/src/rest.ts`).
- Client-side seq-dedupe is mandatory: `seq` is a Redis Stream ID `"ms-idx"`; compare by splitting on `-` and numeric compare; per-session `lastEventId` persisted in SharedPreferences.
- Server additions (Tasks 1–4) are STRICTLY additive: no change to any P1-built route, event type, or schema field semantics; existing cloud Vitest suites stay green (`cd cloud && pnpm -r test`).
- NG3: feature flags (`OVID_THIN_CLIENT` / `Distribution.cloudExecution` & per-subsystem getters) are transition scaffolding only — no local-execution fallback survives Task 20.
- The app talks ONLY to `https://api.ovidsi.com/cloud/*` + Firebase endpoints + presigned R2 upload URLs. Staging overrides exist solely via `--dart-define=OVID_CLOUD_REST_BASE` / `OVID_CLOUD_WS_URL`.
- Secrets: BYOK keys leave the device only via the escrow endpoint over TLS, are never logged, and are never displayed again after upload (spec D3). ID tokens, App Check tokens, WS tickets, and FCM tokens never appear in logs or crash reports.
- D5: control mode + accessibility service removed entirely; `voice_input_service.dart` stays on-device (STT → text into composer); on-device WebView browser removed — `webview_flutter` retained ONLY for HTML artifact rendering (`html_artifact_view.dart` + `HtmlArtifactViewFactory.kt`).
- Play policy: store listing must not mention on-device terminal/Linux (§12 context); `android/app/src/play/AndroidManifest.xml` overlay pattern preserved; Data Safety / privacy policy update is an owner-gated step in Task 20 (R6).
- Activation/staging on the shared VPS is owner-gated (ledger rule): no compose-up on production ports, no Caddy/DNS changes without explicit owner approval; local staging smoke runs on scratch ports only.
- Dart conventions: `analysis_options.yaml` (flutter_lints), tests in the existing flat `test/` layout — new client tests are `test/cloud_*_test.dart`; new client code lives in `lib/core/cloud/`.
- AG4 coordination: behavior-contract tests of removed Dart modules were/are ported server-side (Vitest, per phase — P1 done, P3 parity). The client keeps ONLY UI/projection tests. Never port agent-loop behavior tests back into Dart; delete them with their module.
- Commit style: conventional commits matching `git log` (`feat(cloud): …` for TS, `feat(app)/refactor(chat)/refactor(studio)/…` for Flutter).

## Review Focus

Five failure modes the spec implies that a reasonable user would hit, with the pinning test added to the owning task:

1. **Stale/reused WS ticket on reconnect** (single-use, 60 s TTL): after idle > 60 s the client must silently re-mint and resubscribe with the persisted `lastEventId`; a 4401 close must never surface as a user-visible error. → Task 6 test `reconnect after 4401 re-mints ticket and resubscribes with persisted lastEventId`.
2. **Duplicate events across the replay boundary**: the gateway replays from `lastEventId` then goes live; the same `seq` may arrive twice. The transcript must fold each seq exactly once (no double bubbles, no double-appended deltas). → Task 6 test `duplicate seq is delivered once` + Task 7 test `applying the same event twice mutates the transcript once`.
3. **Prompt composed offline, app killed, reopened**: the outbox must survive process death, flush FIFO on reconnect, and never create a second run for the same prompt (clientMsgId dedupe). → Task 9 test `outbox survives re-instantiation and flushes FIFO once` + Task 4 test `duplicate clientMsgId replays the original runId without a second run row`.
4. **402 `daily_limit_reached` with `x-ovid-resets-at`**: the composer must show the server's verbatim error envelope plus a reset countdown, and must NOT lose the typed draft. → Task 10 widget test `402 daily limit shows verbatim message, resets-at countdown, keeps draft`.
5. **History import interrupted mid-chunk** (network drop at chunk 3/10): re-running the import must skip already-imported messages server-side and never duplicate; nothing uploads before explicit consent. → Task 4 test `re-import with same clientMsgIds skips all` + Task 20 test `interrupted import resumes and reports skipped counts; no upload before consent`.

## Upstream dependencies (plans pending at writing time)

Per the ledger's wave order (2026-10-16 owner directive: P2→P3, then P4/P5/P6/P7 in parallel, then P8), the server surfaces below are BUILT before P8 executes. Their plan files (`docs/superpowers/plans/2026-10-16-ovid-cloud-p{2,4,6,7}-*.md`) did not exist when this plan was written, so each consuming task pins the spec §14 row + spec shape it needs and says **reconcile against the built code before consuming** (the built code is the contract, per Global Constraints):

| Need | Owner phase (spec §14) | Consumed by |
|---|---|---|
| WS `pty` channel ops (raw bytes + resize + 256 KB scrollback repaint), `job_*` events | P2 (SandboxManager) | Task 15 (pty), Task 8 (`jobsFor` stays empty until job events exist) |
| Approval / tool / subagent / memory / context-token events + endpoints | P3 (agent-core parity) | Tasks 8, 18 (stubs until then) |
| Schedules REST (`/cloud/v1/schedules` CRUD + runs feed, spec §8 model), `devices` table + `POST /cloud/v1/devices`, FCM send | P4 (scheduler + notifications) | Tasks 12, 14 |
| Cloud plugins screen data | P5 (McpRouter) | Task 17 (screens stay dark; `Distribution.cloudPlugins = false`) |
| WS `browser` channel (binary WebP frames, JSON input, takeover), tab list | P6 (browser engine) | Task 16 |
| Workspace tree manifest + per-file GET/PUT endpoints, R2 presigner, server-proxied GitHub device flow (§11) | P7 (StateHydrator + R2) | Tasks 3 (presigner), 15 |
| BYOK escrow endpoints, collab v2, TS mint | P9 | Task 18 (escrow UI flag-gated off), Task 11 (collab execution flag-gated off) |

---

## File Structure (new code)

| File | Responsibility |
|---|---|
| `lib/core/cloud/cloud_config.dart` | Base URLs (`https://api.ovidsi.com/cloud/v1`, `wss://api.ovidsi.com/cloud/ws`) + staging dart-define overrides |
| `lib/core/cloud/cloud_rest.dart` | `CloudRestClient`: typed REST wrapper, Firebase auth headers, `CloudApiException` error-envelope mapping |
| `lib/core/cloud/cloud_ws.dart` | `CloudSessionEvent` model, `CloudSocket` test seam, `WsMultiplexer`: one socket, ticket lifecycle, per-session subscribe, seq dedupe, lastEventId persistence, backoff, heartbeat |
| `lib/core/cloud/models.dart` | Cloud DTOs (`SessionDto`, `MessageDto`, `CloudPage<T>`, `SendMessageResponse`, `RunCancelResponse`, `AttachmentUpload`, `ImportReport`, …), `CloudRunState`, `OutboxEntry`; from Task 19 also the re-homed `AgentMode` (−control), `ApprovalRequest`, `UserQuestion`, `BgJob`, `SubagentInfo` |
| `lib/core/cloud/event_projection.dart` | `TranscriptProjection` + `EventTranscriptProjector`: cloud events → existing `Message`/`MsgKind` transcript model |
| `lib/core/cloud/agent_surface.dart` | `AgentSurface`: the abstract seam both `AgentService` and `CloudAgentFacade` implement (dual-path flag) |
| `lib/core/cloud/cloud_agent_facade.dart` | `CloudAgentFacade`: AgentService-shaped facade over REST + projection |
| `lib/core/cloud/cloud_session_store.dart` | `CloudSessionStore`: session-list reconciliation, create-on-first-send, transcript pages → cache, offline read-only + prompt outbox |
| `lib/core/cloud/push_service.dart` | FCM: token registration, foreground presenter, tap routing |
| `lib/core/cloud/schedule_client.dart` | P4 schedules REST client |
| `lib/core/cloud/studio_files.dart`, `studio_pty.dart`, `studio_remote_client.dart` | Remote Studio: tree/file REST, pty WS channel, `_SessionStudio`-shaped notifier |
| `lib/core/cloud/browser_stream.dart` | P6 browser WS channel: WebP frames, input, takeover |
| `lib/core/cloud/history_import.dart` | §13.3 one-time consented import: scan local stores → chunked resumable upload |
| `cloud/apps/gateway/src/routes/runs.ts`, `attachments.ts`, `import.ts` (+ tests) | Server gap routes (Tasks 1, 3, 4) |

---

### Task 1: Server — run cancel endpoint + worker abort

**Files:**
- Modify: `cloud/packages/shared/src/rest.ts` (add `RunCancelResponse`), `cloud/packages/shared/src/rest.test.ts`
- Modify: `cloud/packages/db/src/schema.ts` (`runs.cancelRequested`), `cloud/packages/db/src/repos.ts` (`runs.requestCancel`, `runs.isCancelRequested`), `cloud/packages/db/drizzle/` (new generated migration, follows `0000_volatile_sersi.sql` convention)
- Create: `cloud/apps/gateway/src/routes/runs.ts`, `cloud/apps/gateway/src/routes/runs.test.ts`
- Modify: `cloud/apps/gateway/src/app.ts` (register inside the authenticated scope, next to `registerMessageRoutes`)
- Modify: `cloud/apps/worker/src/runProcessor.ts` + its existing test file (cancel check between streamed delta batches)

**Interfaces:**
- Consumes: P1-built `GatewayDeps` (`db`, `queues`, `events`, `mint`), `runs` repo (`create/claimNext/touch/finish`, `ACTIVE_RUN_STATUSES`), `EventLog.append`, `eventMirror` repo — all as built in `cloud/`.
- Produces (Task 5/8 consume): `POST /cloud/v1/runs/:id/cancel` → `202 {"runId": string, "status": "cancelling" | "cancelled"}`; `404 {"error":{"code":"not_found",…}}` for malformed/unknown/not-owned (same envelope rule as every `:id` route); `409 {"error":{"code":"run_not_cancellable",…}}` when the run is terminal (`completed|failed|cancelled`). Cancellation emits the EXISTING event type `run_failed` with `payload {code:"cancelled", message:"Stopped by user."}` — no new event type. `RunCancelResponse = { runId: string; status: "cancelling" | "cancelled" }` exported from `@ovid/shared`.

- [ ] **Step 1: Write the failing gateway tests** in `cloud/apps/gateway/src/routes/runs.test.ts` (follow the harness in `sessions.test.ts`): cancel a queued run → 202 `status:"cancelled"`, run row terminal, BullMQ job removed (`jobId=runId`), `run_failed{code:"cancelled"}` appended to the event log AND mirrored; cancel a running run → 202 `status:"cancelling"` + `cancelRequested=true` (no job remove success needed); cancel a terminal run → 409 `run_not_cancellable`; wrong owner and malformed `:id` → 404 `not_found` (identical envelope, no db hit on malformed).

- [ ] **Step 2: Run to verify failure** — `cd /root/OvidAI/cloud && pnpm --filter @ovid/gateway test` → FAIL (route not found / 404s everywhere).

- [ ] **Step 3: Implement** — schema column `cancelRequested: boolean("cancel_requested").notNull().default(false)` on `runs`; generate the drizzle migration; `runs.requestCancel(db, id, uid)` = ownership-scoped conditional `UPDATE … SET cancel_requested = true WHERE id=$1 AND user owns AND status IN ('queued','running') RETURNING row`; `runs.isCancelRequested(db, id)`; route logic: ownership+shape guard → terminal check (409) → set flag → best-effort `deps.queues.agentRuns.remove(runId)`; if remove succeeded AND row still `queued`: `runs.finish(cancelled)` + `deps.events.append(sessionId, "run_failed", {code:"cancelled", message:"Stopped by user."})` + `eventMirror` insert (same append+mirror pairing the worker uses), respond `status:"cancelled"`; else respond `status:"cancelling"`. Claim-race (job became active before remove) degrades to the `cancelling` path — the worker's flag check terminalizes it.

- [ ] **Step 4: Write the failing worker test** — runProcessor with a fake provider stream: `cancelRequested` flips true mid-stream → processor stops, appends+mirrors `run_failed{code:"cancelled", message:"Stopped by user."}`, finishes the run `cancelled`; flag false → unchanged behavior (existing tests stay green).

- [ ] **Step 5: Implement the worker check** — in the delta-arrival loop of `runProcessor.ts`, after each batch await `runs.isCancelRequested(deps.db, runId)` (throttle to at most 1 check/second with a monotonic timestamp guard); on true, terminalize as above and return.

- [ ] **Step 6: Run suites** — `cd /root/OvidAI/cloud && pnpm -r test && pnpm -r exec tsc --noEmit` → all green (existing P1 suites untouched).

- [ ] **Step 7: Commit**

```bash
git add cloud/
git commit -m "feat(cloud): run cancel endpoint + worker abort with cancelled run_failed event"
```

---

### Task 2: Server — session PATCH (title/mode) + `SessionDto.mode`

**Files:**
- Modify: `cloud/packages/shared/src/rest.ts` (`SessionDto.mode`, `sessionPatchSchema`), `rest.test.ts`
- Modify: `cloud/packages/db/src/repos.ts` (`sessions.update`), `cloud/packages/db/src/schema.ts` (no change — `mode` column exists, default `"auto"`)
- Modify: `cloud/apps/gateway/src/routes/sessions.ts`, `sessions.test.ts`

**Interfaces:**
- Consumes: P1-built `sessions` repo + route conventions (`isUuid`/`notFound`/`zodBadRequest` from `routes/http.ts`).
- Produces (Tasks 5, 8 consume): `SessionDto` gains `mode: string` (`"safe" | "auto" | "drive" | "studio"` — NO `"control"`, spec D5) on ALL session routes. `PATCH /cloud/v1/sessions/:id` body `{"title"?: string | null, "mode"?: "safe"|"auto"|"drive"|"studio"}` `.strict()`, at least one field required (else 400 `bad_request`), → 200 `SessionDto`. Ownership/malformed → 404, same envelope rule as GET.

- [ ] **Step 1: Write failing tests** — shared: `sessionDtoSchema` requires `mode`, rejects `"control"`; gateway (`sessions.test.ts` additions): PATCH title-only → 200 with new title, mode unchanged; PATCH mode `"studio"` → persisted + returned; PATCH `{}` → 400; PATCH `{mode:"control"}` → 400; PATCH unknown key → 400 (strict); wrong owner / malformed id → 404; existing GET/POST responses now include `mode:"auto"` for fresh sessions (update the P1 assertions additively).

- [ ] **Step 2: Run to verify failure** — `pnpm --filter @ovid/shared test && pnpm --filter @ovid/gateway test` → FAIL.

- [ ] **Step 3: Implement** — `sessions.update(db, id, uid, fields: {title?: string | null, mode?: string}): Promise<SessionRow | null>` (ownership-scoped UPDATE … RETURNING, bumps `updatedAt`); `toSessionDto` includes `row.mode`; PATCH route with the strict zod body.

- [ ] **Step 4: Run suites** — `cd /root/OvidAI/cloud && pnpm -r test && pnpm -r exec tsc --noEmit` → green.

- [ ] **Step 5: Commit**

```bash
git add cloud/
git commit -m "feat(cloud): session PATCH (title/mode) and SessionDto.mode"
```

---

### Task 3: Server — attachment upload (presigned R2 PUT) + message `attachmentIds`

**Files:**
- Create: `cloud/apps/gateway/src/routes/attachments.ts`, `attachments.test.ts`
- Modify: `cloud/packages/shared/src/rest.ts` (`AttachmentDto`, `sendMessageBody` extension lives in gateway), `rest.test.ts`
- Modify: `cloud/apps/gateway/src/app.ts` (register route), `cloud/apps/gateway/src/routes/messages.ts` (accept `attachmentIds`), `messages.test.ts`
- Modify: `cloud/apps/worker/src/runProcessor.ts` + test (job payload gains `attachmentIds`; materialize into the P2 sandbox workspace before the provider call)
- Modify: `cloud/packages/db/src/schema.ts` + `repos.ts` (new `attachments` table: `id`, `sessionId`, `userId`, `name`, `size`, `r2Key`, `createdAt`)

**Interfaces:**
- Consumes: P7's R2 presigner (`@ovid/storage` or equivalent — **reconcile against the built P7 package**; spec §10 R2 layout, §15 AWS SDK v3). Fallback if P7 exposes no reusable presigner: implement `presignPut(key, contentType, sizeBytes, ttlSeconds)` inside the gateway with `@aws-sdk/client-s3` + `@aws-sdk/s3-request-presigner` against `OVID_R2_*` env.
- Produces (Tasks 5, 8 consume): `POST /cloud/v1/sessions/:id/attachments` body `{"name": string, "size": integer > 0}` `.strict()` → 201 `{"attachmentId": string, "uploadUrl": string, "path": string, "expiresAt": string}` where `uploadUrl` is a presigned R2 PUT for key `users/{uid}/sessions/{sessionId}/uploads/{attachmentId}` and `path` is the workspace-relative `uploads/{sanitizedName}`. `size > 25_000_000` → 400 `{"code":"attachment_too_large"}`. `POST /cloud/v1/sessions/:id/messages` body gains optional `"attachmentIds": string[]` (unknown ids → 400 `bad_request`); the worker job payload carries `attachmentIds` and the processor downloads each R2 object into the session workspace `uploads/` path before the first provider call.

- [ ] **Step 1: Write failing tests** — gateway (fake presigner injected via deps): create attachment → 201 with all four fields, key layout pinned, db row written; oversize → 400 `attachment_too_large`; non-owner session → 404; sendMessage with `attachmentIds:["<known>"]` → 202 and the enqueued job payload contains the ids; unknown attachment id → 400. Worker: job with `attachmentIds` triggers one storage download per id into `uploads/<name>` before streaming (fake storage).

- [ ] **Step 2: Run to verify failure** — `pnpm --filter @ovid/gateway test && pnpm --filter @ovid/worker test` → FAIL.

- [ ] **Step 3: Implement** — table + repo (`attachments.create/getForSession`), route, presigner wiring, `sendMessageBody` = `z.object({content: z.string(), attachmentIds: z.array(z.string().uuid()).optional()}).strict()`, worker materialization step.

- [ ] **Step 4: Run suites** — `cd /root/OvidAI/cloud && pnpm -r test && pnpm -r exec tsc --noEmit` → green.

- [ ] **Step 5: Commit**

```bash
git add cloud/
git commit -m "feat(cloud): presigned attachment uploads and message attachmentIds"
```

---

### Task 4: Server — message `clientMsgId` idempotency + bulk history-import route

**Files:**
- Modify: `cloud/packages/db/src/schema.ts` (`messages.clientMsgId` text nullable + partial unique index on `(session_id, client_msg_id) WHERE client_msg_id IS NOT NULL`; generated migration), `repos.ts` (`messages.append` accepts `clientMsgId`, new `messages.findByClientMsgId`, `messages.importBulk`)
- Modify: `cloud/apps/gateway/src/routes/messages.ts` (accept optional `clientMsgId` ≤ 64 chars; conflict → replay), `messages.test.ts`
- Create: `cloud/apps/gateway/src/routes/import.ts`, `import.test.ts`; register in `app.ts`
- Modify: `cloud/packages/shared/src/rest.ts` (`ImportReport`), `rest.test.ts`

**Interfaces:**
- Consumes: P1 `messages`/`runs` repos, route conventions.
- Produces: (a) `POST /cloud/v1/sessions/:id/messages` body gains optional `"clientMsgId": string` (1–64 chars) — merged with Task 3's `attachmentIds` into ONE strict body `{content, attachmentIds?, clientMsgId?}`. On `(sessionId, clientMsgId)` conflict the route does NOT insert: if the existing message has a run (`runs.promptMessageId` lookup) → 202 with the ORIGINAL `{runId, userMessageId, status:"queued"}`; otherwise → 409 `{"code":"run_conflict"}`. (b) `POST /cloud/v1/import/sessions` body `{"title"?: string, "createdAt"?: ISO8601, "messages": [{"clientMsgId": string, "role": "user"|"assistant"|"system"|"tool", "content": string, "createdAt": ISO8601}]}` → 201 `{"sessionId": string, "imported": integer, "skipped": integer}`; empty messages or > 500 per call → 400 (`bad_request` / `import_too_large`); re-sent `clientMsgId`s are skipped, never duplicated; stored `createdAt` is the client's (timestamp fidelity, spec §13.3). Task 20 consumes both.

- [ ] **Step 1: Write failing tests** — messages: send with `clientMsgId` twice → second response 202 with identical `runId`/`userMessageId`, exactly ONE message row and ONE run row; conflicting clientMsgId without a run → 409 `run_conflict`; > 64 chars → 400. Import: 3-message import → 201 `{imported:3, skipped:0}`, rows carry client `createdAt` values; re-run the SAME body WITH the previously returned `sessionId` (the route's optional `sessionId` continuation — the binding pin) → 201 `{imported:0, skipped:3}` (duplicate `clientMsgId`s skip, never duplicate); a fresh call WITHOUT `sessionId` creates a fresh session (idempotency is per-session, so per-session duplicate-skip is only observable via the continuation path); 501 messages → 400 `import_too_large`; unknown session owner → 404.

- [ ] **Step 2: Run to verify failure** — `pnpm --filter @ovid/gateway test` → FAIL.

- [ ] **Step 3: Implement** — schema/migration, repo methods (`importBulk` = single INSERT … ON CONFLICT (session_id, client_msg_id) DO NOTHING RETURNING id, counts imported vs skipped), messages-route conflict replay branch, import route (`z.object({sessionId: z.string().uuid().optional(), title: z.string().optional(), createdAt: z.string().datetime().optional(), messages: z.array(...).min(1).max(500)}).strict()`; `messages[].clientMsgId` required — it is the idempotency key).

- [ ] **Step 4: Run suites** — `cd /root/OvidAI/cloud && pnpm -r test && pnpm -r exec tsc --noEmit` → green.

- [ ] **Step 5: Commit**

```bash
git add cloud/
git commit -m "feat(cloud): message clientMsgId idempotency and bulk history import route"
```

---

### Task 5: Client — `CloudConfig` + `CloudRestClient`

**Files:**
- Create: `lib/core/cloud/cloud_config.dart`, `lib/core/cloud/cloud_rest.dart`, `lib/core/cloud/models.dart` (DTOs only in this task)
- Test: `test/cloud_rest_client_test.dart`

**Interfaces:**
- Consumes: `FirebaseService.I.getIdToken({bool forceRefresh})` (`lib/core/firebase_service.dart:538`), `CloudAppCheck.getToken({bool forceRefresh})` (`lib/core/cloud_app_check.dart:24`), `package:http` (+ `MockClient` from `package:http/testing.dart`). Task 1–4 routes (built contract above).
- Produces (every later client task consumes):

```dart
// cloud_config.dart
class CloudConfig {
  const CloudConfig._();
  static const String prodRestBase = 'https://api.ovidsi.com/cloud/v1';
  static const String prodWsUrl = 'wss://api.ovidsi.com/cloud/ws';
  /// dart-define OVID_CLOUD_REST_BASE / OVID_CLOUD_WS_URL override (staging only).
  static String get restBase;
  static String get wsUrl;
}

// models.dart — mirrors cloud/packages/shared/src/rest.ts EXACTLY (camelCase JSON)
class SessionDto { final String id; final String? title; final String mode; final DateTime createdAt; final DateTime updatedAt; factory SessionDto.fromJson(Map<String, dynamic> j); }
class MessageDto { final String id; final String sessionId; final String role; final String content; final DateTime createdAt; factory MessageDto.fromJson(…); }
class CloudPage<T> { final List<T> items; final String? nextCursor; } // named CloudPage — Flutter already has Page
class SendMessageResponse { final String runId; final String userMessageId; final String status; /* 'queued' */ }
class RunCancelResponse { final String runId; final String status; /* 'cancelling' | 'cancelled' */ }
class AttachmentUpload { final String attachmentId; final String uploadUrl; final String path; final DateTime expiresAt; }
class ImportMessage { final String clientMsgId; final String role; final String content; final DateTime createdAt; }
class ImportReport { final String sessionId; final int imported; final int skipped; }
class CloudHealthChecks { final bool db; final bool redisQ; }
class CloudHealth { final String status; /* 'ok' | 'degraded' */ final CloudHealthChecks checks; } // mirrors the BUILT GET /health wire shape {status, checks:{db,redisQ}} (cloud/apps/gateway/src/routes/health.ts:39-42)
class CloudRunState { final String? runId; final bool busy; final bool stopRequested; final String? statusLine; final int? retryAttempt; final int? retryNextBackoffMs; final String? lastErrorCode; final String? lastErrorMessage; }

// cloud_rest.dart
class CloudApiException implements Exception {
  CloudApiException({required this.status, required this.code, required this.message, this.resetsAt});
  final int status; final String code; final String message;
  /// Parsed from the `x-ovid-resets-at` response header when present (spec §15 verbatim contract).
  final DateTime? resetsAt;
}
class CloudHeaders {
  CloudHeaders({Future<String?> Function()? idToken, Future<String> Function()? appCheck});
  static CloudHeaders I; // default binds FirebaseService + CloudAppCheck
  @visibleForTesting static CloudHeaders forTest({String idToken = 'test-id-token', String appCheck = 'test-app-check'});
  Future<Map<String, String>> authorize(); // {'Authorization': 'Bearer <id>', 'X-Firebase-AppCheck': <ac>} — throws CloudApiException(401,'unauthenticated') when signed out
}
class CloudRestClient {
  CloudRestClient({http.Client? httpClient, CloudHeaders? headers, String? restBase});
  static CloudRestClient get I;
  @visibleForTesting static void installForTest(CloudRestClient client);
  Future<Map<String, dynamic>> getJson(String path, {Map<String, String>? query});
  Future<Map<String, dynamic>> postJson(String path, {Object? body});
  Future<Map<String, dynamic>> patchJson(String path, {Object? body});
  Future<CloudHealth> health();                                     // GET /health (no auth headers — public route)
  Future<String> mintTicket();                                      // POST /auth/ticket → ticket
  Future<SessionDto> createSession({String? title});
  Future<CloudPage<SessionDto>> listSessions({int limit = 50, String? cursor});
  Future<SessionDto> getSession(String id);
  Future<SessionDto> patchSession(String id, {String? title, String? mode});
  Future<SendMessageResponse> sendMessage(String sessionId, String content, {List<String> attachmentIds = const [], String? clientMsgId});
  Future<CloudPage<MessageDto>> pageMessages(String sessionId, {int limit = 50, String? before});
  Future<RunCancelResponse> cancelRun(String runId);
  Future<AttachmentUpload> createAttachment(String sessionId, {required String name, required int size});
  Future<void> uploadAttachmentBytes(AttachmentUpload upload, List<int> bytes); // raw PUT to the presigned URL — NO Authorization/App Check headers on this call
  Future<ImportReport> importMessages({String? sessionId, String? title, DateTime? createdAt, required List<ImportMessage> messages});
  Future<void> registerDevice({required String fcmToken, String platform = 'android'}); // POST /devices — P4-owned route; reconcile shape against built P4 code
}
```

Error mapping (pin in `postJson`/`getJson`): non-2xx → parse `{"error":{"code","message"}}` → `CloudApiException(status, code, message, resetsAt: X-Ovid-Resets-At header parsed as epoch-ms-or-ISO)`; unparseable body → `code:'internal'`. A 401 from the server retries ONCE with `getIdToken(forceRefresh:true)` before throwing.

- [ ] **Step 1: Write the failing test** `test/cloud_rest_client_test.dart` with `MockClient`: `sendMessage` posts to `<restBase>/sessions/<id>/messages` with body `{"content":"hi","attachmentIds":["a1"],"clientMsgId":"cm1"}` and both auth headers, parses the 202 into `SendMessageResponse`; 409 body `{"error":{"code":"key_not_minted","message":"…"}}` → `CloudApiException(status:409, code:'key_not_minted')`; 402 with header `x-ovid-resets-at` → exception carries parsed `resetsAt`; `listSessions` parses `{items:[…],nextCursor:null}` into `CloudPage<SessionDto>` including `mode`; `patchSession(id, mode:'studio')` → PATCH with `{"mode":"studio"}`; `uploadAttachmentBytes` sends a PUT to the presigned URL with NO Authorization header; 401 → exactly one force-refresh retry then success.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_rest_client_test.dart` → FAIL (files don't exist).

- [ ] **Step 3: Implement** the three files per the signatures above.

- [ ] **Step 4: Run to verify pass** — `flutter test test/cloud_rest_client_test.dart` → PASS; `flutter analyze` → No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/core/cloud/ test/cloud_rest_client_test.dart
git commit -m "feat(app): cloud REST client with Firebase auth and App Check headers"
```

---

### Task 6: Client — `WsMultiplexer` (`cloud_ws.dart`)

**Files:**
- Create: `lib/core/cloud/cloud_ws.dart`
- Test: `test/cloud_ws_multiplexer_test.dart`

**Interfaces:**
- Consumes: `CloudRestClient.mintTicket()` (Task 5), `ConnectionService.I.status` (`lib/core/connection_service.dart` — `ConnectionStatus.online/offline`), `SharedPreferences`, `dart:io` `WebSocket.connect` (cert pinning comes free: `OvidPinningHttpOverrides` in `lib/core/cert_pinning.dart:129` hooks every `HttpClient`, which `WebSocket.connect` uses — verify with the pinning test seam, do not bypass), and the P1 DB event-mirror read seam for the replay fallback below (**reconcile the mirror read route/shape against the built gateway code — [MAP]**).
- Produces (Tasks 7–9, 15, 16 consume):

```dart
class CloudSessionEvent { // mirrors cloud/packages/shared/src/events.ts — NOT named SessionEvent (agent_service.dart owns that name until Task 19)
  final String sessionId; final String seq; final String type;
  final Map<String, dynamic> payload; final DateTime ts;
  factory CloudSessionEvent.fromJson(Map<String, dynamic> j);
}
enum WsLinkState { disconnected, connecting, online }
abstract class CloudSocket { // test seam over dart:io WebSocket
  Stream<Object> get frames;       // decoded String text frames
  void sendText(String frame);
  Future<void> close([int? code, String? reason]);
  Stream<void> get closed;         // fires once with the close code available via closeCode
  int? get closeCode;
}
typedef CloudSocketFactory = Future<CloudSocket> Function(Uri url);
class WsMultiplexer extends ChangeNotifier {
  WsMultiplexer({required Future<String> Function() mintTicket,
                 CloudSocketFactory? socketFactory,
                 SharedPreferences? prefs,
                 ConnectionService? connection,
                 Duration heartbeatInterval = const Duration(seconds: 25),
                 Duration pongTimeout = const Duration(seconds: 10)});
  static WsMultiplexer get I;      // production singleton (mintTicket: CloudRestClient.I.mintTicket)
  @visibleForTesting static void installForTest(WsMultiplexer ws);
  WsLinkState get linkState;
  /// Idempotent. Sends `{"op":"subscribe","sessionId":…,"lastEventId":<persisted or null>}`
  /// (connecting first if needed). Returned stream emits each event for the session EXACTLY
  /// once — duplicates by seq are dropped (Review Focus #2).
  Stream<CloudSessionEvent> subscribe(String sessionId);
  void unsubscribe(String sessionId);
  Future<void> connectIfNeeded();
  Future<void> disconnect();
  @visibleForTesting
  static int compareSeq(String a, String b); // 'ms-idx' numeric compare
}
```

Behavior pins: one socket for ALL sessions; EVERY (re)connect mints a FRESH ticket (single-use, 60 s TTL) — close code 4401 triggers re-mint + reconnect silently (Review Focus #1); on socket open, re-subscribe every active session with its persisted `lastEventId`; `lastEventId` = max-seq seen per session, persisted to SharedPreferences key `ovid_cloud_last_event_<sessionId>` on every accepted event; reconnect backoff `min(60s, 1s * 2^(attempt-1))` + 0–250 ms jitter, attempt counter resets after a `pong`/`subscribed`; no reconnect while `ConnectionService` reports offline (listen and retry on flip to online); heartbeat `{"op":"ping"}` every `heartbeatInterval`, missing pong within `pongTimeout` → close + reconnect; server `{op:"error"}` frame → forwarded on the session's stream as an error event only when `sessionId` present, otherwise logged via `debugPrint` (never rethrown). **Replay fallback** (owns the ledger's P1-review deferral "mirror replay-fallback (P8)"): when the Redis event-log replay is unavailable or degraded — the stream has trimmed past `lastEventId` (24 h/50 MB retention, spec §6.2; reconcile the exact server signal against the built `ws.ts`) — the multiplexer falls back to the DB event mirror for catch-up (the P1 `session_events` mirror seam — reconcile the read route/shape against the built gateway), applies mirror events through the SAME seq-dedupe, then continues live; `lastEventId` re-seeds from the mirror's last event.

- [ ] **Step 1: Write the failing test** `test/cloud_ws_multiplexer_test.dart` with a `FakeCloudSocket` (in-test `StreamController`-backed) + `SharedPreferences.setMockInitialValues({})`: (a) subscribe sends the subscribe op with null lastEventId first time; (b) two events `seq '5-0'` then `'4-9'` → only `'5-0'` emitted (dedupe); (c) same seq delivered twice → emitted once (Review Focus #2); (d) `lastEventId` persisted: after events, re-instantiate the multiplexer over a new fake socket → subscribe frame carries `'5-0'`; (e) socket closes with 4401 → `mintTicket` called again, new socket, resubscribe with persisted id, no error surfaced (Review Focus #1); (f) close without 4401 → backoff sequence observed with fake async (`1s, 2s, 4s` capped at 60 s); (g) offline `ConnectionService` → no reconnect attempts until online; (h) missing pong → reconnect; (i) `compareSeq('10-0','9-99') > 0`; (j) replay unavailable/degraded (fake socket delivers the server's trimmed-past-`lastEventId` signal — shape per built `ws.ts`) → the mirror catch-up path is invoked (fake mirror reader), its events are applied once through the same seq-dedupe, and the live subscription continues afterwards (mirror replay-fallback).

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_ws_multiplexer_test.dart` → FAIL.

- [ ] **Step 3: Implement** `cloud_ws.dart` per the pins above.

- [ ] **Step 4: Run to verify pass** — `flutter test test/cloud_ws_multiplexer_test.dart` → PASS; `flutter analyze` → clean; full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/cloud/cloud_ws.dart test/cloud_ws_multiplexer_test.dart
git commit -m "feat(app): WS multiplexer — ticket lifecycle, seq dedupe, lastEventId persistence, backoff"
```

---

### Task 7: Client — `EventTranscriptProjector` (`event_projection.dart`)

**Files:**
- Create: `lib/core/cloud/event_projection.dart`
- Test: `test/cloud_event_projection_test.dart`

**Interfaces:**
- Consumes: `CloudSessionEvent` (Task 6), `Message`/`MsgKind` from `lib/core/state.dart:1028-1226` (KEPT model — do not modify it here).
- Produces (Tasks 8–10 consume):

```dart
class TranscriptProjection extends ChangeNotifier {
  final List<Message> messages;          // transcript for one session
  bool get busy; String? get activeRunId;
  String? get statusLine;                // composer status row ("Retrying in 9s…")
  String? get lastErrorCode; String? get lastErrorMessage;
  final ValueNotifier<int> liveBubbleTicks; // replaces AgentService.liveBubbleTicksFor
  void seedFromHistory(List<Message> cached); // offline/paged cache first, events fold on top
}
class EventTranscriptProjector {
  EventTranscriptProjector(TranscriptProjection target);
  void apply(CloudSessionEvent event);   // fold table below; UNKNOWN types ignored (forward-compat for P2/P3 events)
}
```

Fold table (binding):

| Event | Projection |
|---|---|
| `run_started{runId}` | `busy=true`, record `activeRunId`; append live bubble `Message(role:'assistant', kind: MsgKind.streaming, thinking:true)`; clear `statusLine` |
| `message_delta{runId,text}` | if `payload.runId != activeRunId` DROP (epoch gate); else append `text` to live bubble `content`, bump `liveBubbleTicks.value++` |
| `message_completed{messageId,content}` | REPLACE live bubble with `Message(role:'assistant', kind: MsgKind.text, content: payload.content, privateSyncId: payload.messageId, thinking:false, elapsedMs: now - runStartedAt)` — server content/id authoritative; **clear `activeRunId`** (the double-apply guard below depends on it) |
| `run_started_retry{attempt,nextBackoffMs}` | `statusLine = 'Retrying in ${nextBackoffMs ~/ 1000}s… (attempt $attempt)'`; stays busy |
| `run_failed{code,message?}` | `busy=false`; `lastErrorCode/lastErrorMessage` set; append `Message(role:'assistant', kind: MsgKind.turnTail, content: message ?? humanText(code))` where `humanText('cancelled') = 'Stopped by user.'`, `humanText('key_not_minted') = 'No model API key is provisioned for this account.'` (verbatim server strings when present) |
| `run_completed{runId}` | `busy=false`, clear `statusLine` |
| `system_note` | append `Message(role:'assistant', kind: MsgKind.turnTail, content: payload['text'] ?? payload['message'] ?? '')` |

Seq-level idempotence: projector applies only events the multiplexer already deduped; applying the same event object twice must still mutate once (guard `message_completed` by `activeRunId == null → no-op`; Review Focus #2).

- [ ] **Step 1: Write the failing test** `test/cloud_event_projection_test.dart`: one test per fold-table row with exact payload shapes from `cloud/apps/worker/src/runProcessor.ts:25-31`; plus: delta with stale runId dropped; `message_completed` twice → single finalized bubble; unknown type `'job_started'` → no throw, no mutation; `seedFromHistory` then `run_started` appends after cached messages.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_event_projection_test.dart` → FAIL.

- [ ] **Step 3: Implement** `event_projection.dart`.

- [ ] **Step 4: Run to verify pass** — targeted PASS, `flutter analyze` clean, full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/cloud/event_projection.dart test/cloud_event_projection_test.dart
git commit -m "feat(app): cloud event to transcript projection"
```

---

### Task 8: Client — `AgentSurface` seam + `CloudAgentFacade`

**Files:**
- Create: `lib/core/cloud/agent_surface.dart`, `lib/core/cloud/cloud_agent_facade.dart`
- Modify: `lib/core/agent_service.dart` (additive only IN THIS TASK: `implements AgentSurface` on the class declaration + import; NO body changes — the mechanical dead-code strips of the deletion waves begin with Task 12, per the Global Constraints dies-in-pieces rule), `lib/core/distribution.dart` (flags)
- Test: `test/cloud_agent_facade_test.dart`, `test/agent_surface_conformance_test.dart`

**Interfaces:**
- Consumes: `CloudRestClient` (Task 5), `WsMultiplexer` (Task 6), `EventTranscriptProjector`/`TranscriptProjection` (Task 7); existing `AgentMode`, `ApprovalRequest`, `BgJob` types from `agent_service.dart:262-309,534-682` (they MOVE to `models.dart` in Task 19 — until then the facade imports them from `agent_service.dart`; do NOT duplicate the enums/classes).
- Produces:

```dart
// distribution.dart (extend)
static const bool _thinDefine = bool.fromEnvironment('OVID_THIN_CLIENT');
@visibleForTesting static bool? thinOverrideForTest;
static bool get thinClient => thinOverrideForTest ?? (_thinDefine || play);
static bool get cloudExecution => thinClient;   // chat/runs via cloud (Task 10 flips consumers)
static bool get cloudStudio => thinClient;      // live only after Task 15
static bool get cloudSchedules => thinClient;   // live only after Task 14
static bool get cloudBrowser => thinClient;     // live only after Task 16
static bool get cloudPlugins => false;          // dark until P5
static bool get cloudByok => false;             // dark until P9 escrow endpoints

// agent_surface.dart — the 21 surviving members = 20 of chat_screen's measured
// 26 (worklist §1C) + busyListenable (its measured consumer is
// sidebar.dart:1203, covered by Task 10). The 6 measured members NOT on the
// surface: requestBatteryExemption/workspaceRootFor/skillUnavailableReason/
// sessionRepoFull/hostDirOf (call sites die in Tasks 10/13) and approve
// (agent_service.dart:6836; its 2 call sites chat_screen.dart:8779/8806 are
// re-pointed onto approveRequest in Task 10 so the approval UI path is not
// orphaned). Signatures copied VERBATIM from
// agent_service.dart at the anchors shown:
abstract class AgentSurface extends ChangeNotifier {
  AgentMode get mode;                                        // foreground session's mode
  void setMode(AgentMode m, {String? sessionId});            // agent_service.dart:6687
  bool busyFor(String sessionId);                            // :6644
  ValueListenable<bool> busyListenable(String sessionId);    // :6650
  bool stopRequested({required String sessionId});           // :1771
  void hardStopAll();                                        // :1876
  Future<void> runTask(String originalPrompt, {String? sessionId, bool freshTurn = true, ChatSession? expandRefsFor, List<({String name, String path, int size})>? attachments, Map<String, dynamic>? scheduledTask}); // :11353
  String? statusFor(String sessionId);                       // :6673
  ValueListenable<int> liveBubbleTicksFor(String sessionId); // :14322
  ApprovalRequest? get pendingApproval;                      // :1429
  List<({String sessionId, String title, ApprovalRequest request})> get pendingApprovalsElsewhere; // :1459
  bool approveRequest(ApprovalRequest req, bool ok, {String? note}); // :6856
  bool approveAlwaysRequest(ApprovalRequest req);            // :6864
  bool get planMode; set planMode(bool v);                   // :1526-1533 (delegates to ChatSession, unchanged)
  List<({String name, String path, int size})> get pendingAttachments; // :6460
  int get stagingAttachmentCount;                            // :6464
  Future<String?> attachFile(String sourcePath, String fileName, {String? sessionId}); // :6473
  void removeAttachment(String path);                        // :6545
  void clearAttachment();                                    // :6551
  List<BgJob> jobsFor(String sessionId);
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''}); // :10704
}
```

`CloudAgentFacade extends ChangeNotifier implements AgentSurface` — singleton `CloudAgentFacade.I`, `@visibleForTesting static void installForTest(…)`, ctor `CloudAgentFacade({required CloudRestClient rest, required WsMultiplexer ws, required CloudSessionStore? store /* wired in Task 9; nullable until then */})`. Semantics:
- Per-session `TranscriptProjection` + projector, fed by `ws.subscribe(sessionId)`; `busyFor/statusFor/liveBubbleTicksFor/pendingApproval` read the projection; `notifyListeners` on every projection change.
- `runTask`: resolve session (via store when wired, else assume server id) → upload staged attachments (`createAttachment` + `uploadAttachmentBytes`) → `sendMessage(content, attachmentIds, clientMsgId: <new 32-hex id>)` → optimistically append `Message(role:'user', kind: MsgKind.text, content: prompt, privateSyncId: userMessageId)` + record `CloudRunState{runId, busy:true}`. Offline (or store reports outbox mode) → enqueue outbox entry instead (Task 9). `CloudApiException` → store into `CloudRunState.lastErrorCode/Message` and surface (never swallow).
- `hardStopAll`: for every session with `CloudRunState.runId != null && busy` → `rest.cancelRun(runId)`, set `stopRequested=true`; a 409 `run_not_cancellable` means the run just finished → refresh state, settle to NOT busy (Review Focus cancel-race). Terminal events clear `stopRequested`.
- `setMode`: optimistic local set + `rest.patchSession(serverId, mode: m.name)`; on failure revert + surface.
- Approvals: `pendingApproval` returns null and `approveRequest/approveAlwaysRequest` return false until P3 approval events land — leave a `// P3:` marker; NO local approval machinery.
- `jobsFor` → `const []` until P2 `job_*` events; `measuredContextTokens` → 0 until P3 (UI % display degrades gracefully — verify chat_screen guards division, else return the model-context default from `lib/core/model_limits.dart`).
- `attachFile`: no workspace copy — stage `({name, path, size})` in memory per session; size > 25 MB → return `'File is larger than the 25 MB cloud attachment limit.'`.

- [ ] **Step 1: Write the failing tests** — `test/cloud_agent_facade_test.dart` with a fake `CloudRestClient` subclass + `WsMultiplexer` fake-socket driver: runTask happy path issues sendMessage with clientMsgId + appends optimistic user message; busyFor flips on `run_started` and clears on `run_completed`; hardStopAll posts cancelRun and stopRequested reads true; cancelRun 409 → busy settles false; setMode PATCHes `mode:'studio'` and reverts on exception; 402 from sendMessage → lastErrorCode `'daily_limit_reached'`, no optimistic message left dangling; attachment over 25 MB → error string, nothing staged. `test/agent_surface_conformance_test.dart`: `AgentService.I is AgentSurface` and `CloudAgentFacade(…) is AgentSurface` (compile-time conformance via the `implements` clause + a runtime assert).

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_agent_facade_test.dart test/agent_surface_conformance_test.dart` → FAIL.

- [ ] **Step 3: Implement** `agent_surface.dart`, `cloud_agent_facade.dart`, the `distribution.dart` flag block, and the one-line `implements AgentSurface` on `AgentService`.

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green (the additive `implements` must not break any existing test — if a signature mismatch surfaces, the SURFACE conforms to AgentService, not vice versa).

- [ ] **Step 5: Commit**

```bash
git add lib/core/cloud/ lib/core/distribution.dart lib/core/agent_service.dart test/cloud_agent_facade_test.dart test/agent_surface_conformance_test.dart
git commit -m "feat(app): CloudAgentFacade — AgentService-shaped cloud seam behind flags"
```

---

### Task 9: Client — `CloudSessionStore` (reconciliation, offline cache, prompt outbox)

**Files:**
- Create: `lib/core/cloud/cloud_session_store.dart`
- Modify: `lib/core/cloud/cloud_agent_facade.dart` (wire `store` non-null; runTask offline path), `lib/core/cloud/models.dart` (`OutboxEntry`)
- Test: `test/cloud_session_store_test.dart`

**Interfaces:**
- Consumes: `CloudRestClient` (Task 5), `WsMultiplexer.linkState` (Task 6), `SessionHistoryRepository` (`lib/core/session_history_store.dart` — becomes the offline READ CACHE, spec §12), `ConnectionService.I`, `AppState.I.sessions` (`lib/core/state.dart`), SharedPreferences.
- Produces (Task 10 consumes):

```dart
class OutboxEntry { // models.dart
  final String clientMsgId; final String sessionId; final String content;
  final List<String> attachmentIds; final DateTime createdAt;
  Map<String, dynamic> toJson(); factory OutboxEntry.fromJson(Map<String, dynamic> j);
}
class CloudSessionStore extends ChangeNotifier {
  CloudSessionStore({required CloudRestClient rest, required SessionHistoryRepository cache, SharedPreferences? prefs, ConnectionService? connection});
  static CloudSessionStore get I;
  @visibleForTesting static void installForTest(CloudSessionStore store);
  String? serverIdFor(String localSessionId);           // prefs-persisted map `ovid_cloud_session_ids`
  Future<String> ensureServerSession(String localSessionId, {String? title}); // create-on-first-send; idempotent
  Future<void> refreshSessions();                        // GET /sessions pages → reconcile AppState.sessions (server UUIDv7 ids become ChatSession ids; unknown local sessions without a server id stay until first send)
  Future<void> loadTranscript(String serverSessionId, {String? before, int limit = 50}); // pageMessages (newest-first) → reversed → projection seed + cache write
  bool get offline;                                        // ConnectionService says offline OR ws linkState != online
  List<OutboxEntry> outboxFor(String sessionId);           // composer queue chip reads this
  Future<void> enqueue(String sessionId, String content, {List<String> attachmentIds}); // persisted to prefs `ovid_cloud_outbox` (JSON list, FIFO)
  Future<void> flushOutbox();                              // on reconnect: FIFO sendMessage(clientMsgId) per entry; success → remove; CloudApiException 4xx (except 402/409-conflict retryable semantics: 409 run_conflict = already sent → remove) → remove + surface; 5xx/network → stop, keep remainder, retry on next flip
}
```

- [ ] **Step 1: Write the failing test** `test/cloud_session_store_test.dart` (fake rest + `SharedPreferences.setMockInitialValues`): `ensureServerSession` posts once, second call returns the mapped id without a POST; `refreshSessions` creates ChatSession entries for server sessions and preserves the local→server map; `loadTranscript` reverses the newest-first page and writes the cache; offline `enqueue` persists — a NEW store instance over the same prefs still sees the entry (Review Focus #3); `flushOutbox` sends FIFO with the stored clientMsgIds, removes flushed entries, and on a 503 keeps the remainder; a replayed flush (server returns the original runId for a duplicate clientMsgId — fake rest simulates Task 4 semantics) removes the entry without a second optimistic message.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_session_store_test.dart` → FAIL.

- [ ] **Step 3: Implement** store + facade wiring (facade `runTask`: `store.offline → store.enqueue(...)`; facade listens to `ConnectionService` + `ws.linkState` and calls `flushOutbox()` on the offline→online flip).

- [ ] **Step 4: Run to verify pass** — targeted PASS, `flutter analyze` clean, full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/cloud/ test/cloud_session_store_test.dart
git commit -m "feat(app): cloud session store — reconciliation, offline cache, prompt outbox"
```

---

### Task 10: Chat rewire — `chat_screen.dart` + sidebar + search on the facade

**Files:**
- Modify: `lib/ui/chat_screen.dart` (10,363 LOC; 68 `AgentService.I` call sites / 26 distinct members / 88 referencing lines — worklist §1C), `lib/ui/sidebar.dart` (session list ← `CloudSessionStore`; search stays on `session_search.dart` FTS over the cache), `lib/ui/app_router.dart` (route `/c/<id>` accepts server ids), `lib/ui/session_actions.dart`, `lib/ui/chat_overflow_menu.dart`, `lib/ui/link_safety.dart` (import-level facade swaps only)
- Test: `test/chat_screen_cloud_rewire_test.dart` (new), plus fix existing chat widget tests that stub `AgentService.I` to install the facade under `Distribution.thinOverrideForTest = true`

**Interfaces:**
- Consumes: `AgentSurface`, `CloudAgentFacade.I`, `CloudSessionStore.I`, `Distribution.cloudExecution` (Tasks 8–9); `CloudApiException` (Task 5).
- Produces: the dual-path binding pattern every later screen task reuses — in `_ChatScreenState`: `AgentSurface get _agent => Distribution.cloudExecution ? CloudAgentFacade.I : AgentService.I;` and mechanical `AgentService.I.` → `_agent.` for the 21 surface members. Task 10 also OWNS removing chat_screen's dead-member call sites: `requestBatteryExemption` (2), `workspaceRootFor`, `skillUnavailableReason`, `sessionRepoFull`, `hostDirOf`, `approve` (2 sites: chat_screen.dart:8779/8806 — re-point onto the surface's `approveRequest` flow so the approval UI path is not orphaned; the member itself dies with Task 19), the sandbox-install entry (`onInstallSandbox`, chat_screen.dart:1527), startup-panel rendering (25 `startup` refs), sandbox banner (15 refs), control UI (~119 `control` refs), browser header button (chat_screen.dart:1410-1424 — hidden when `!Distribution.cloudBrowser`, re-pointed in Task 16), plugin/MCP composer entries (die fully in Task 17; hide behind `Distribution.cloudPlugins == false` here).

- [ ] **Step 1: Write the failing widget test** `test/chat_screen_cloud_rewire_test.dart`: with `Distribution.thinOverrideForTest = true` + `CloudAgentFacade.installForTest(fake)` + fake store: typing + Send calls `runTask` on the FACADE (never `AgentService.I`); a `run_started`/`message_delta`/`message_completed` sequence through the fake ws renders a live bubble then finalizes; queued outbox entries render the composer queue chip; **Review Focus #4 test**: fake rest throws `CloudApiException(402, 'daily_limit_reached', <server message>, resetsAt: now+30min)` → the error row shows the server message VERBATIM + a countdown derived from `resetsAt`, and the composer text is still present after dismiss.

- [ ] **Step 2: Run to verify failure** — `flutter test test/chat_screen_cloud_rewire_test.dart` → FAIL.

- [ ] **Step 3: Implement the rewire** — the `_agent` getter + mechanical call-site swaps (grep-driven: `grep -n 'AgentService\.I\.' lib/ui/chat_screen.dart` is the worklist); dead-member call-site removal per the Produces list; error-envelope UX for 402 (`x-ovid-resets-at` countdown), 409 `key_not_minted` (show server message + link to provider settings), 409 `run_conflict` (silent state refresh), 503 `unavailable` (retry affordance). Sidebar: session rows read `CloudSessionStore` reconciliation output (title/updatedAt from `SessionDto`); pull-to-refresh → `refreshSessions()`; when offline the list renders from cache read-only (spec §12).

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; FULL `flutter test` green (existing chat tests must pass under BOTH flag values — the default `false` path is untouched `AgentService.I` behavior).

- [ ] **Step 5: Commit**

```bash
git add lib/ui/ test/
git commit -m "refactor(chat): bind chat and sidebar to the cloud facade behind Distribution.cloudExecution"
```

---

### Task 11: `state.dart` strip 1/2 + private_sync removal

**Files:**
- Modify: `lib/core/state.dart` (12,007 LOC; imports 40 removed files — this task clears the private_sync + startup/runtime-install slices), `lib/ui/shell.dart:264-266` (remove the `maybeStartBackgroundRuntimeInstall` post-frame kick), `lib/core/reset_coordinator.dart` (drop private_sync/runtime-install stores from its enumeration), `lib/core/collaboration/production.dart` (remove `file_outbox`/`endpoint_policy` imports + call sites — collab SYNC dies; collab UI stays read-only)
- Delete: `lib/core/private_sync/` (14 files, 5,260 LOC — spec D6 "deleted, not ported"), the ~18 `test/` files referencing private_sync (worklist §4 task-17 triage counts)
- Modify (state.dart anchors, worklist §1A): remove `sandboxInstalled` (3464, 5669, 8079), `RuntimeInstallState` / `maybeStartBackgroundRuntimeInstall` / `retryBackgroundRuntimeInstall` / `showRuntimeInstallBanner` (8101–8210), `SandboxMaintenanceTask` wiring + startup-failure memo (3521, 3590–3610), `verifyRuntimesForStartupSelfHeal` (3911), the readiness-task builder block (≈3556–3950), private_sync imports (state.dart:59-60) + sync composition/outbox-flush/status members
- Gate: `completeCollaborationTurn` (state.dart:2311) — collab EXECUTION is flag-gated OFF (`Distribution.cloudExecution` → collab turns show "Collaboration is moving to the cloud — read-only for now" via `MsgKind.turnTail` row). **Owner question Q6 is pending; this default is reversible in Task 20.**

**Interfaces:**
- Consumes: nothing new — pure removal + flag gate.
- Produces: `AppState` without startup/private-sync surface; `session_history_store.dart` formally demoted to READ CACHE (its write path now fed only by Task 9's `loadTranscript`/projection persistence).

- [ ] **Step 1: Update the affected tests first** — delete private_sync test files; in state tests, remove startup/runtime-install expectations; add `test/state_collab_gate_test.dart`: with `thinOverrideForTest = true`, invoking the collab-turn path appends the turnTail notice and calls NO agent execution.

- [ ] **Step 2: Run to verify failure** — `flutter test test/state_collab_gate_test.dart` → FAIL (gate not implemented); `flutter analyze` currently green.

- [ ] **Step 3: Implement** — deletions + state.dart strip + collab gate + shell kick removal + reset_coordinator list update. Work top-down: delete private_sync dir → fix the 2 importers → strip state.dart blocks → fix compile errors in dependents (startup_coordinator/startup_tasks stay until Task 13 — only their state.dart wiring dies here; if a dangling reference forces an early delete, delete the file and note it in the commit body).

- [ ] **Step 4: Run to verify pass** — `flutter analyze` → No issues found; full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ test/
git commit -m "refactor(state): strip startup/runtime-install/private_sync wiring; delete private_sync client"
```

---

### Task 12: FCM push + background-reliability removal + lifecycle inversion

**Files:**
- Create: `lib/core/cloud/push_service.dart`; Test: `test/cloud_push_service_test.dart`
- Modify: `pubspec.yaml` (add `firebase_messaging` — run `flutter pub add firebase_messaging`; absent today, worklist §3e), `lib/core/firebase_service.dart` (expose `Future<String?> getFcmToken()`), `lib/main.dart` (remove headless-boot block 149–171: `AgentNotificationService.init`, `BackgroundNotifier.init`, `attachBackgroundJobWatchers`, `schedulesSettled→wakeSchedules→settleBackgroundService`, 3 s headless timer; KEEP tap-routing `_openChatFromNotification` 217–227 / `_openRouteFromNotification` 230–241 / `_showInAppNotification` 245–259 and the `BackgroundNotifier.inAppPresenter` wiring at 213 — re-fed from FCM), `lib/ui/shell.dart` (lifecycle inversion, see below; KEEP `McpService.disconnectAll` at :335 until Task 17), `lib/ui/settings_screen.dart` (remove background-reliability card + OEM-killer section, 12 refs), `lib/core/state.dart` (dead `agent_notification_service` import :15 + the members it forces — mechanical dead-code removal only), `lib/ui/schedule_screen.dart` (dead `agent_notification_service` :3 + `background_reliability_card` :10 imports and the members they force — the screen's full cloud rewrite is Task 14; only the dead references go here), `lib/core/agent_service.dart` (dead `agent_notification_service` import :23 + the members it forces — mechanical dead-code removal only, per the Global Constraints dies-in-pieces rule)
- Delete: `lib/core/agent_notification_service.dart` (548), `lib/core/background_health.dart` (185), `lib/core/background_jobs.dart` (70), `lib/ui/background_reliability_card.dart` (383), `android/app/src/main/kotlin/…/AgentForegroundService.kt` (247), `BackgroundChannel.kt` (228); manifest: remove FGS service + keep-alive permissions from `android/app/src/main/AndroidManifest.xml` (play overlay already clean); their tests
- KEEP + adapt: `lib/core/background_notifications.dart` (517) — channel/posting machinery becomes the FCM display path (`OvidNotifications.kt` 259 stays)

**Interfaces:**
- Consumes: `firebase_messaging` API, `CloudRestClient.registerDevice` (Task 5; **P4-owned route — reconcile**), existing `BackgroundNotifier` presenter + `_openRouteFromNotification` (main.dart), `WsMultiplexer.connectIfNeeded/disconnect` (Task 6), `CloudSessionStore.flushOutbox` (Task 9).
- Produces:

```dart
class PushService {
  static PushService get I;
  Future<void> init();  // request permission; FirebaseMessaging.instance.getToken() → rest.registerDevice; onTokenRefresh → re-register;
                        // onMessage → BackgroundNotifier in-app presenter (existing machinery);
                        // onMessageOpenedApp + getInitialMessage → _openRouteFromNotification(data)
  @visibleForTesting static void installForTest(PushService service);
}
```

Notification `data` routes (P4 server-side payload — reconcile against the P4 plan): `{'route': '/c/<sessionId>'}` and `{'route': '/schedule/<scheduleId>'}`.
Shell lifecycle inversion (`didChangeAppLifecycleState`): `resumed` → `WsMultiplexer.I.connectIfNeeded()` + `ConnectionService.I.probe()` + `CloudSessionStore.I.flushOutbox()`; `paused/inactive/hidden` → `AppState.I.flushSessionPersistence()` (kept); `detached` → `WsMultiplexer.I.disconnect()`. NOTHING keeps the process alive — runs are detached server-side (AG1 satisfied structurally; worklist §1F). Remove the `anyRunActive → agentWorking(…)` FGS calls (shell.dart:313-331), `setAppForegrounded`, `DeviceControlService.refreshServiceBinding` (dies fully Task 13), `onControlTaskCompleted` wiring (shell.dart:252, 272–281).

- [ ] **Step 1: Write the failing test** `test/cloud_push_service_test.dart` (fake `CloudRestClient` + fake messaging delegate seam injected via ctor): init registers the token via `registerDevice(fcmToken:…, platform:'android')`; token refresh re-registers; a message with `data {'route':'/c/abc'}` invokes the route callback with `/c/abc`; a foreground message reaches the in-app presenter.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_push_service_test.dart` → FAIL.

- [ ] **Step 3: Implement** — `push_service.dart` (ctor takes injectable token-source + message streams for testability), main.dart rewiring, shell lifecycle inversion, deletions + manifest cleanup, settings_screen section removal, and the mechanical dead-reference strips in `state.dart` / `schedule_screen.dart` / `agent_service.dart` (dead-code removal only).

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green; `cd android && ./gradlew :app assembleDebug` NOT run (native compile checked in Task 20's build step — but the Kotlin deletions must not break the build: run `flutter build apk --debug` once here if the toolchain is available on the box; otherwise note it and verify in Task 20).

- [ ] **Step 5: Commit**

```bash
git add -A pubspec.yaml lib/ android/ test/
git commit -m "feat(app): FCM push and notification rewire; remove background keep-alive apparatus"
```

---

### Task 13: Removal wave — sandbox/Termux + control mode (spec §12, D5)

**Files:**
- Delete (worklist §1A, 12 files): `lib/core/sandbox_service.dart` (5,378), `sandbox_pkg.dart`, `apt_trust.dart`, `dpkg_compat.dart`, `termux_proot.dart`, `studio_setup_coordinator.dart`, `startup_coordinator.dart`, `startup_tasks.dart`, `health_service.dart`, `workspace_files.dart`, `lib/ui/sandbox_setup.dart`, `lib/ui/startup_progress_panel.dart`
- Delete (worklist §1D): `lib/core/device_control_service.dart` (1,047), `android/…/OvidAccessibilityService.kt` (2,146), overlay channels in `MainActivity.kt` (partial — keep notification/share/artifact channels), accessibility-service manifest entries + XML in `android/app/src/main/` (play overlay already strips these)
- Rewrite: `lib/ui/settings_health_screen.dart` (1,027 → thin card over `CloudRestClient.I.health()` showing `{status, checks.db, checks.redisQ}` + app/version info); Test: `test/settings_health_cloud_test.dart`
- Modify: `lib/core/state.dart` (remaining sandbox refs), the measured live importers that OUTLIVE this wave (dead sandbox/control imports + the members they force — mechanical dead-code removal only; each is fully adapted or deleted in its own later task): `lib/core/github_service.dart` (fully adapted Task 15), `lib/core/hook_service.dart` (deleted Task 18), `lib/core/plugin_dependency_service.dart` (deleted Task 17), `lib/core/mcp_service.dart` (deleted Task 17), `lib/core/hook_execution_scope.dart` (deleted Task 18), and `lib/core/agent_service.dart` (imports `sandbox_service` :32, `device_control_service` :66, `workspace_files` :37 — remove the imports + the members they force, e.g. the control overlay handlers at 967–1250 and the sandbox helpers; dead-code removal only, per the Global Constraints dies-in-pieces rule — the `AgentMode.control` enum value itself survives until Task 19's type move), `lib/ui/shell.dart`, `lib/ui/studio_screen.dart` + `studio_terminal_tabs.dart` + `studio_editor.dart` (sandbox imports → compile-stubs behind `Distribution.cloudStudio == false` showing "Studio moves to the cloud in this build" until Task 15 — the studio screens are DOWN on the thin channel between Tasks 13 and 15, accepted by worklist §4 chain 2), `lib/ui/plugins_screen.dart` sandbox imports (screen deleted in Task 17 — if the import breaks analyze now, delete the file early and note it), `pubspec.yaml` (drop `assets/termux-keyring/*` block + delete `assets/termux-keyring/`), `android/app/build.gradle.kts` (drop bundled-userland/jniLibs packaging per worklist §5), `lib/core/native_plugins/sandbox_utilities.dart` + `misc_utilities.dart` (deleted in Task 17 — if they break analyze now via sandbox/control imports, delete early and note it), `lib/core/reset_coordinator.dart` (drop sandbox stores), ~47 sandbox + ~16 control test files deleted (worklist triage counts)
- KEEP: `lib/core/voice_input_service.dart` (D5 — composer STT stays; only its overlay-mic consumer dies).

**Interfaces:**
- Consumes: `CloudRestClient.health()` (Task 5), `CloudHealth` (Task 5 models).
- Produces: settings_health_screen bound to cloud health; no sandbox/control symbols anywhere in `lib/` (`grep -rn "SandboxService\|DeviceControlService\|TermuxProot" lib/` returns nothing) — Task 15 relies on the studio screens already being stub-gated.

- [ ] **Step 1: Write the failing health-screen test** `test/settings_health_cloud_test.dart`: fake rest returning `CloudHealth(status:'degraded', checks: CloudHealthChecks(db:true, redisQ:false))` (the BUILT nested wire shape — see Task 5's `CloudHealth`) renders the degraded banner + per-check rows; a thrown `CloudApiException(503,'unavailable',…)` renders the retry affordance.

- [ ] **Step 2: Run to verify failure** — `flutter test test/settings_health_cloud_test.dart` → FAIL.

- [ ] **Step 3: Implement** — health screen rewrite first (it is the only sandbox consumer needing a successor, worklist §1A), then deletions in dependency order: UI leaves (`sandbox_setup`, `startup_progress_panel`) → coordinators/tasks → `sandbox_service` + satellites → control mode (Dart, then Kotlin + manifest) → packaging (pubspec assets, gradle) → test deletions → fix every import error until analyze is clean.

- [ ] **Step 4: Run to verify pass** — `flutter analyze` → No issues found; full `flutter test` green; `grep -rn "SandboxService\|DeviceControlService" lib/` → empty.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ android/ assets/ pubspec.yaml test/
git commit -m "refactor(app): remove sandbox/Termux and control-mode local execution; health screen goes cloud"
```

---

### Task 14: Schedule screen → P4 REST

**Files:**
- Create: `lib/core/cloud/schedule_client.dart`; Test: `test/cloud_schedule_client_test.dart`
- Rewrite (data bindings; widget tree survives): `lib/ui/schedule_screen.dart` (1,271 LOC; 6 `AgentService.I` sites: `schedules`, `editSchedule`, `resumeScheduledBackground`)
- Delete: `lib/core/schedule_coordinator.dart` (543), `android/…/ScheduleAlarmReceiver.kt` (212), exact-alarm manifest entries (`SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM`), schedule-runtime state in `lib/core/state.dart` (`ChatSession.schedules` at state.dart:1525 becomes a server-data cache), their tests
- Modify: `lib/main.dart` (`wakeSchedules`/`schedulesSettled` refs — removed), `lib/core/agent_service.dart` (mechanical dead-code removal, per the Global Constraints dies-in-pieces rule: drop the dead `schedule_coordinator` import :25 and the schedule-runtime members it forces, 21,778–22,117 — dead-code removal only, no behavior redesign; Task 19 does the final rewrite)

**Interfaces:**
- Consumes: `CloudRestClient.getJson/postJson/patchJson` (Task 5). **P4-owned routes — spec §8 model, camelCase wire; reconcile against the built P4 code before implementing** (plan pending at writing time):
- Produces:

```dart
class ScheduleTrigger { final String kind; /* 'at'|'every'|'daily_at'|'cron' */ final DateTime? at; final int? everySeconds; final String? dailyAt; /* 'HH:MM' */ final String? tz; final String? cron; fromJson/toJson }
class ScheduleRunDto { final String id; final String status; final DateTime? scheduledFor; final DateTime? finishedAt; final String? summary; fromJson }
class ScheduleDto { final String id; final String? sessionId; final String title; final String description; final ScheduleTrigger trigger; final String autonomy; /* 'safe'|'auto' */ final String status; final DateTime? nextRunAt; final ScheduleRunDto? lastResult; final int maxRetries; fromJson }
class ScheduleClient {
  ScheduleClient(CloudRestClient rest);
  static ScheduleClient get I;
  Future<List<ScheduleDto>> list();                                  // GET /schedules
  Future<ScheduleDto> create({required String title, required String description, required ScheduleTrigger trigger, String autonomy = 'safe', String? sessionId, int maxRetries = 1});
  Future<ScheduleDto> update(String id, {String? title, String? description, ScheduleTrigger? trigger, String? autonomy, String? status, int? maxRetries});
  Future<void> delete(String id);
  Future<List<ScheduleRunDto>> runs(String id);                      // GET /schedules/:id/runs — results feed
  static DateTime? parseDate(String text);                           // moved from ScheduleCoordinator.parseDate (same regexes/semantics — port its Dart tests verbatim)
}
```

- [ ] **Step 1: Write the failing tests** — `test/cloud_schedule_client_test.dart` (fake rest): list parses the camelCase §8 model; create posts `{title, description, trigger:{kind:'daily_at', dailyAt:'09:00', tz:'UTC'}, autonomy:'safe', maxRetries:1}`; `parseDate` cases PORTED from the existing `schedule_coordinator` tests (AG4: UI-facing parsing stays client-side). Schedule-screen widget test: rows render from a fake client; pull-to-refresh reloads; results feed shows `lastResult.summary` + missed-run status (`ran_late` badge per spec §8).

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_schedule_client_test.dart` → FAIL.

- [ ] **Step 3: Implement** — client, screen rebind (behind `Distribution.cloudSchedules`; when false the screen shows the cloud-empty state — local runtime is already deleted), deletions, state.dart schedule-cache rewire, FCM result notifications already route `/schedule/<id>` (Task 12).

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ android/ test/
git commit -m "refactor(schedule): server-backed schedules via P4 REST; delete local scheduler runtime"
```

---

### Task 15: Remote Studio — P7 files + P2 pty

**Files:**
- Create: `lib/core/cloud/studio_files.dart`, `lib/core/cloud/studio_pty.dart`, `lib/core/cloud/studio_remote_client.dart`; Test: `test/cloud_studio_client_test.dart`
- Rewrite (bindings only; widget trees survive — worklist §3b): `lib/ui/studio_screen.dart` (2,929; 38 `RepoCache` refs, 11 `AgentService.I` sites), `lib/ui/studio_editor.dart` (1,556; 24 sites), `lib/ui/studio_file_tree.dart` (644; 13 sites), `lib/ui/studio_terminal_tabs.dart` (487; `StudioShellSession` → `CloudPtyChannel`), `lib/ui/studio_errors.dart`
- Delete: `lib/core/repo_cache.dart` (2,122), `lib/core/global_repo_registry.dart` (525), `lib/core/line_diff.dart` (237), `lib/core/pty_service.dart` (382), `lib/core/studio_terminal.dart` (347), ~29 repo_cache test files (worklist triage)
- Modify: `lib/core/agent_service.dart` (dead `repo_cache` :35 / `global_repo_registry` :30 / `pty_service` :60 imports + the members they force — mechanical dead-code removal only, per the Global Constraints dies-in-pieces rule), `lib/core/github_service.dart` (965, ADAPT: local device-flow + token storage → thin client of the server-proxied GitHub OAuth, spec §11 — **P7-owned endpoint; reconcile**), `lib/ui/github_login_sheet.dart` (568, ADAPT), `lib/core/studio_drafts.dart` (KEPT: local edit drafts survive offline against remote files), `lib/core/state.dart` (`_SessionStudio`-equivalent state moves to `StudioRemoteClient`), `lib/core/reset_coordinator.dart`

**Interfaces:**
- Consumes: `CloudRestClient` (Task 5), `WsMultiplexer` socket for the pty channel (Task 6). **P7 endpoints (tree/files) and P2 WS pty ops — reconcile against the built code; spec §6.2 (pty: raw bytes + resize + 256 KB scrollback repaint), §10 (manifest <5 KB, <100 ms; single-file extract <500 ms).** Expected shapes this plan pins client-side:
- Produces:

```dart
// studio_files.dart
class FileNode { final String path; final String kind; /* 'file'|'dir' */ final int? size; final DateTime? mtime; final List<FileNode> children; fromJson }
class StudioFilesClient {
  StudioFilesClient(CloudRestClient rest);
  Future<FileNode> tree(String sessionId);                              // GET  /sessions/:id/tree
  Future<String> readFile(String sessionId, String path);               // GET  /sessions/:id/files?path=…
  Future<void> writeFile(String sessionId, String path, String content, {String? baselineHash}); // PUT — 409 on baseline mismatch → conflict flow
}
// studio_pty.dart
class CloudPtyChannel extends ChangeNotifier {   // drop-in for StudioShellSession's surface
  CloudPtyChannel({required String sessionId, required String tabId, required WsMultiplexer ws});
  void write(List<int> bytes);
  void resize(int cols, int rows);
  Stream<List<int>> get output;   // starts with the server's ≤256 KB scrollback repaint
  Future<void> close();
}
// studio_remote_client.dart — exposes the EXACT _SessionStudio field set (agent_service.dart:996–1027)
class StudioRemoteClient extends ChangeNotifier {
  static StudioRemoteClient get I;
  Map<String, String> fileBuffer(String sessionId);      // path → content
  List<String> openFiles(String sessionId);
  String? activeFilePath(String sessionId);
  Map<String, String> baselines(String sessionId);       // path → server hash/mtime
  bool isStudioFileDirty(String sessionId, String path);
  Map<String, ({String kind, String message})> conflicts(String sessionId);
  Future<void> openStudioFile(String sessionId, String path);   // lazy fetch (<500 ms SLA)
  Future<void> saveStudioFile(String sessionId, String path);   // PUT + baseline update
  Future<void> syncStudioTabs(String sessionId);                // tree refresh
  // + StudioTabsState-shaped listenable so editor/tree widgets rebind with import-level edits
}
```

Local git UI (branch chips, sync progress, credential env) is REMOVED — server-side git tools are P2/P3 concerns; `sessionBranch`/`newStudioFile`/`focusStudioFile` call sites in `studio_screen.dart` either die or map onto tree/file equivalents.

- [ ] **Step 1: Write the failing test** `test/cloud_studio_client_test.dart` (fake rest + fake ws): `tree` parses nested `FileNode`s; `openStudioFile` lazily fetches once + populates `fileBuffer`/`baselines`; edit → `isStudioFileDirty` true; `saveStudioFile` PUTs and clears dirty; PUT 409 → `conflicts` entry + the editor's existing conflict resolution path fires (`resolveStudioConflict` equivalent); `CloudPtyChannel` replays the scrollback frame then live bytes, `resize` sends `{cols,rows}`.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_studio_client_test.dart` → FAIL.

- [ ] **Step 3: Implement** — the three client files, then rebind the four studio screens (replace the Task 13 stub gate), github_service adaptation, deletions, state.dart studio-state migration.

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green; `grep -rn "RepoCache\|PtyService\|StudioShellSession" lib/` → empty.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ test/
git commit -m "refactor(studio): remote tree/editor/terminal over P7 file APIs and P2 pty channel"
```

---

### Task 16: Browser screen → P6 screencast + on-device browser removal

**Files:**
- Create: `lib/core/cloud/browser_stream.dart`; Test: `test/cloud_browser_stream_test.dart`
- Rewrite: `lib/ui/browser_screen.dart` (1,028 — keeps tab chrome; content becomes the frame canvas + input forwarding + takeover UX)
- Delete: `lib/core/webview_pool.dart` (51), `lib/core/session_browser_profiles.dart` (599), `lib/core/session_data_sharing.dart` (137), `android/…/OvidWebViewHandler.kt` (1,052), `OvidBrowserProfiles.kt` (254), their state.dart/settings_screen wiring + tests
- Modify: `lib/ui/chat_screen.dart:1410-1424` header button → opens the cloud browser screen when `Distribution.cloudBrowser`, `lib/core/agent_service.dart` (dead `webview_pool` :33 / `session_browser_profiles` :42 imports + the members they force — mechanical dead-code removal only, per the Global Constraints dies-in-pieces rule), `lib/core/state.dart` (browser-restore state), `lib/ui/settings_screen.dart` (browser-profiles section)
- KEEP: `webview_flutter` in pubspec + `html_artifact_view.dart` + `HtmlArtifactViewFactory.kt` (artifact rendering only — Global Constraints, D5).

**Interfaces:**
- Consumes: `WsMultiplexer` socket (Task 6). **P6 WS browser channel — reconcile against the built P6 code; spec §6.2: binary WebP frames 3–5 fps, JSON input events, `takeover` handoff flag.** Client-side pins:
- Produces:

```dart
class BrowserFrame { final Uint8List webpBytes; final int width; final int height; }
class BrowserTabDto { final String tabId; final String url; final String title; final bool active; fromJson } // server tab list (P6 REST — reconcile)
class BrowserStreamClient extends ChangeNotifier {
  BrowserStreamClient({required WsMultiplexer ws});
  static BrowserStreamClient get I;
  Future<List<BrowserTabDto>> tabs(String sessionId);
  Future<void> attach(String sessionId, String tabId);   // binary frames → decodeImage → frames stream; JSON frames → tab/state updates
  Stream<BrowserFrame> get frames;
  void sendTap(double x, double y); void sendScroll(double dx, double dy); void sendKey(String key, {String? text});
  Future<void> requestTakeover(); Future<void> releaseTakeover();
  bool get takeoverActive;
  void detach();
}
```

Takeover UX (spec G6): while the agent drives, input gestures are IGNORED and a "Agent is driving — Take over" button shows; `requestTakeover()` flips `takeoverActive` (server acknowledges via the channel's takeover flag) and input forwarding starts; `releaseTakeover()` hands back.

- [ ] **Step 1: Write the failing test** `test/cloud_browser_stream_test.dart` (fake ws feeding binary + JSON frames): binary frame → `frames` emits a decodable `BrowserFrame` (1×1 WebP fixture bytes); taps ignored while `takeoverActive == false`; after `requestTakeover` ack → `sendTap` writes the JSON input op; `detach` unsubscribes. Widget test: browser_screen renders the canvas + takeover button from a fake client.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_browser_stream_test.dart` → FAIL.

- [ ] **Step 3: Implement** — client, screen rewrite, chat_screen button re-point, deletions + wiring cleanup.

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green; `grep -rn "WebviewPool\|SessionBrowserProfiles\|webview" lib/ | grep -v html_artifact` → empty.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ android/ test/
git commit -m "refactor(browser): P6 screencast canvas with takeover; remove on-device WebView browser"
```

---

### Task 17: MCP/plugin runtime + UI removal wave (largest strip, ≈38,982 LOC)

**Files:**
- Delete core (worklist §1H): `mcp_service.dart` (4,648), `native_mcp.dart`, `mcp_catalog_tools.dart`, `mcp_config_parse.dart`, `mcp_client_requests.dart`, `mcp_oauth_discovery.dart`, `plugin_runtime.dart`, `plugin_dependency_service.dart`, `plugin_registry.dart`, `plugin_manifest.dart`, `plugin_permissions.dart`, `plugin_source_resolver.dart`, `plugin_adapters.dart`, `plugin_user_config.dart`, `native_plugin.dart`, `lib/core/native_plugins/` (17 files, 15,344)
- Delete UI: `plugins_screen.dart` (5,988), `plugin_permission_sheet.dart`, `mcp_oauth_sheet.dart`, `mcp_server_add_form.dart`, `plugin_install_progress.dart`, `plugin_settings_panel.dart`, `mcp_elicitation_sheet.dart` (9,714 total) + their routes in `app_router.dart` / entries in `settings_screen.dart` + `sidebar.dart`
- Modify: `lib/main.dart:202` (elicitor wiring removed), `lib/ui/shell.dart:335` (`McpService.disconnectAll` removed — detached case now only closes the WS, Task 12), `lib/core/state.dart` (plugin/MCP management slice: `PluginItem`/`McpServer`, marketplace sync, plugin-safety startup — ≈2k of the state estimate), `lib/core/commands.dart` (435 → composer-side UI only; preset APPLICATION becomes a server session setting, P3), `lib/core/presets.dart` (337, same shrink), `lib/core/agent_service.dart` (mechanical dead-code removal, per the Global Constraints dies-in-pieces rule: the mcp/plugin imports :38–:59 + the members they force — dead-code removal only, no behavior redesign; Task 19 does the final rewrite)
- Delete tests: ~56 mcp/plugin test files (worklist triage)
- KEEP: `lib/ui/widgets/chat_tool_visuals.dart` (tool cards render from event `toolName`s — `mcp__*` names arrive via P3 events), `lib/core/secret_scrub.dart` (imported by `diag.dart`).
- Note: the cloud plugins screen is NOT rebuilt here — it stays dark until P5 (`Distribution.cloudPlugins == false`, worklist §1H decision: remove).

**Interfaces:**
- Consumes: nothing new — pure removal.
- Produces: `commands.dart`/`presets.dart` reduced surface (composer insert-only); state.dart free of plugin/MCP symbols; settings_screen without plugin/MCP sections. Task 18 relies on `grant_store`/`tool_usage_store` importers in `mcp_service`/`plugins_screen` already being gone.

- [ ] **Step 1: Pin the surviving behavior first** — add `test/chat_tool_visuals_cloud_test.dart`: a tool card renders from a plain `{toolName:'mcp__github__list', toolTitle, toolState}` Message with NO plugin runtime present (proves the kept visuals are runtime-free). Run → expect FAIL only if the widget imports a doomed module (fix the import as part of Step 3).

- [ ] **Step 2: Delete** — UI screens first (routes/entries), then core files bottom-up by importer order (native_plugins → registries/manifests → mcp_service/plugin_runtime), then state.dart/main.dart/shell.dart/commands/presets slices, then tests.

- [ ] **Step 3: Fix imports until clean** — `flutter analyze` drives the list; every fix is deletion or re-point, never re-implementation.

- [ ] **Step 4: Run to verify pass** — `flutter analyze` → No issues found; full `flutter test` green; `grep -rn "McpService\|PluginRegistry\|plugin_runtime" lib/` → empty.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ test/
git commit -m "refactor(app): remove local MCP/plugin runtimes and screens (cloud plugins return with P5)"
```

---

### Task 18: Agent-core satellites + secondary screens + BYOK escrow UI + `state.dart` strip 2/2

**Files:**
- Delete satellites (worklist §1C): `hook_service.dart` (3,786), `hook_context_store.dart`, `hook_execution_scope.dart`, `skills.dart` (1,086), `compaction/` (3 files, 1,283), `prompt_cache.dart`, `plan_mode.dart` (engine only — `ChatSession.planMode` + plan-review card STAY as UI state), `structured_edits.dart`, `subagent_tools.dart`, `claude_code_tools.dart`, `grant_store.dart`, `model_failure.dart`, `ssrf_guard.dart`, `tool_usage_store.dart`, `usage_attempt.dart` + `usage_attempt_recorder.dart` + `usage_attempt_store.dart` (1,128), `session_lifecycle_service.dart`, `recovered_images.dart`, `image_result_locator.dart`; their tests (~36 hooks files per worklist triage)
- Modify screens → server data sources: `lib/ui/trajectory_screen.dart` (443 → cloud `session_events` via a P3 endpoint — **reconcile; until live, render from the kept `session_ledger`** (import-window rule below; there is no projector event cache — the projector writes transcript `Message`s, not an event store)), `lib/ui/memory_screen.dart` (P3 memory endpoints — same rule), `lib/ui/subagent_screen.dart` (9 `AgentService.I` sites → facade `jobsFor`/P3 subagent events; empty-state until then), `lib/ui/permissions_screen.dart` (9 sites: `revoke*`, `rememberedDenialsFor`, `alwaysAllowedToolsFor` → server `grants` table read path, spec §10 — P3/P9 endpoint; until live: read-only empty state with "Permissions are managed server-side"), `lib/ui/image_receipt_panel.dart` (672: drop `recovered_images`/`image_result_locator` — results are R2 URLs, D7), `lib/ui/artifact_preview.dart` + `lib/core/session_artifacts.dart` (R2 URLs), `lib/ui/usage_screen.dart` (1,829 ADAPT: keep server `/usage` + `usage_today.dart` path only — device-local accounting dies)
- Create (flag-gated, P9 dependency): BYOK escrow UI in `lib/ui/settings_screen.dart` providers section + `lib/core/cloud/byok_client.dart` — `Distribution.cloudByok == false` keeps it hidden; contract pinned from spec D3: `POST /cloud/v1/byok/keys {provider, key}` → `{id, provider, fingerprint, createdAt}`; `GET /cloud/v1/byok/keys` → list WITHOUT key material; `DELETE /cloud/v1/byok/keys/:id`. Keys are write-once: the UI NEVER displays an uploaded key again (fingerprint + provider only), input field is `obscureText`, value never logged/persisted locally. Test: `test/cloud_byok_ui_test.dart`
- Modify: `lib/core/agent_service.dart` (imports of the deleted satellites — :21, :27–29, :43, :45–48, :57, :61, :63–65 — plus the members they force; mechanical dead-code removal only, per the Global Constraints dies-in-pieces rule)
- Modify: `lib/core/state.dart` strip 2/2 — plugin/MCP leftovers, grants, browser-restore, `ChatSession` field cleanup (fields whose services died in Tasks 11–17) + **persisted-JSON migration**: bump the `ovid_sessions` schema version, `ChatSession.fromJson` silently drops unknown/removed keys (existing lenient-parse pattern), old persisted sessions load without crash. `lib/core/settings_backup_service.dart` + `settings_state_integration.dart` (backup scope shrinks to settings — transcripts are server-owned), `lib/core/reset_coordinator.dart` (final store list)
- KEEP until Task 20: `session_ledger.dart` (652) + `memory_store.dart` (394) — readable for the §13.3 import; they die in Task 20 AFTER the import ships (worklist §1C import-window rule). `trajectory_screen` may read ledgers until then.

**Interfaces:**
- Consumes: facade (Task 8), projection cache (Tasks 7/9), `CloudRestClient` (Task 5).
- Produces: `byok_client.dart` (`class ByokClient { Future<List<ByokKeyDto>> list(); Future<ByokKeyDto> upload({required String provider, required String key}); Future<void> revoke(String id); }`, `ByokKeyDto{id, provider, fingerprint, createdAt}` — no key field exists on the DTO); state.dart at its final slim shape (only Task 19's agent_service import + Task 20's ledger/memory imports remain).

- [ ] **Step 1: Write the failing tests** — `test/cloud_byok_ui_test.dart`: with `cloudByok` forced true (test seam), upload flow POSTs `{provider:'anthropic', key:'sk-…'}`, the success row shows ONLY provider + fingerprint, the raw key string appears NOWHERE in the widget tree after upload (`find.textContaining('sk-')` → nothing), and nothing key-shaped lands in SharedPreferences (assert prefs dump). `test/state_persisted_migration_test.dart`: a pre-strip persisted `ovid_sessions` JSON blob (fixture with removed fields) loads without throwing and drops the dead fields.

- [ ] **Step 2: Run to verify failure** — both FAIL.

- [ ] **Step 3: Implement** — satellites deletion (analyze-driven import fixes), screen rewires, escrow UI + client, state.dart strip 2/2 + migration.

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; full `flutter test` green.

- [ ] **Step 5: Commit**

```bash
git add -A lib/ test/
git commit -m "refactor(app): agent-core satellite strip, server-backed secondary screens, BYOK escrow UI"
```

---

### Task 19: Delete `agent_service.dart` + test-suite triage

**Files:**
- Delete: `lib/core/agent_service.dart` (26,735 LOC)
- Modify: `lib/core/cloud/models.dart` — MOVE IN (verbatim, minus `.control`): `AgentMode` + `AgentModeX` extension (agent_service.dart:262–309, drop the `control` enum value, its label/hint/icon/color arms, and the `modeOptionsForPicker` control filter), `ApprovalRequest`, `UserQuestion`, `QuestionOption` (534–602), `BgJob`, `SubagentInfo` (606–682). Every importer (`agent_surface.dart`, `cloud_agent_facade.dart`, `state.dart`, chat/permissions/subagent screens, `chat_tool_visuals.dart`, `commands.dart`, …) switches imports to `models.dart` — mechanical grep-and-swap.
- Modify: `lib/core/connection_service.dart` — it imports `agent_service.dart` for `HttpShim` (agent_service.dart:26,513): inline a minimal reachability probe (plain `HttpClient` GET expecting 204 against the same public endpoint `HttpShim` used) so the class dies with its file.
- Modify: `lib/core/cloud/agent_surface.dart` (`AgentMode`/`ApprovalRequest`/`BgJob` imports ← models.dart), `lib/ui/shell.dart` (last `AgentService.I` refs: `anyRunActive` → `CloudAgentFacade.I` busy scan; `onControlTaskCompleted` already dead), `lib/core/state.dart` (final agent_service import removed), `lib/main.dart`, remaining UI importers per the worklist's 25-file list
- Delete/modify tests (worklist §4 task 17 triage; 561 files / 173k LOC total, 237 reference agent_service): DELETE tests of removed behavior (the module waves already took ~200; this task takes the remainder that stubbed `AgentService.I` for loop behavior). PORT to the facade: UI-facing tests that stubbed `AgentService.I` for rendering (install `CloudAgentFacade.installForTest` or a fake `AgentSurface` instead). AG4: do NOT port agent-loop behavior tests — the server Vitest suites carry that contract.

**Interfaces:**
- Consumes: everything from Tasks 5–18 (this task only compiles if every consumer was rewired).
- Produces: `models.dart` as the sole home of the surviving agent types; `AgentSurface` implemented ONLY by `CloudAgentFacade` (delete the `implements AgentSurface` line's counterpart — the class is gone); the dual-path in screens collapses to the facade in Task 20 (this task keeps `Distribution.cloudExecution` branches compiling with the facade as the only implementation).

- [ ] **Step 1: Pre-flight** — `grep -rln "agent_service" lib/ test/` and reduce the `lib/` list to zero importers BEFORE deleting (each fix is a re-point to models.dart/facade, never new behavior). Snapshot the count.

- [ ] **Step 2: Move the types** — relocate the KEEP shapes into `models.dart` (minus `.control`), update imports, run `flutter analyze` → still green WITH agent_service.dart present (it now imports its own types back from models.dart — delete its local copies). Green is achievable precisely because Tasks 12–18 already stripped the dead imports/members their deletions forced (dies-in-pieces rule) — including the `.control` references Task 13 removed; if analyze still flags a dead reference, remove it mechanically before proceeding.

- [ ] **Step 3: Delete `agent_service.dart`** + fix `connection_service.dart` probe inline + `flutter analyze` → No issues found.

- [ ] **Step 4: Test triage** — run full `flutter test`; for each failing file: deleted-module test → delete; UI-render test → re-point at the facade per the rule above; loop-behavior test → delete (AG4: server owns the contract). Record final counts (files deleted / ported) in the commit body.

- [ ] **Step 5: Run to verify pass** — `flutter analyze` clean; full `flutter test` green; `grep -rn "AgentService" lib/` → empty.

- [ ] **Step 6: Commit**

```bash
git add -A lib/ test/
git commit -m "refactor(app): delete agent_service.dart; type re-homing and test-suite triage"
```

---

### Task 20: History import client + flag collapse + zero-setup first run + staging smoke

**Files:**
- Create: `lib/core/cloud/history_import.dart`; Test: `test/cloud_history_import_test.dart`
- Create: consent + progress UI (first thin-client login flow): `lib/ui/history_import_sheet.dart`; hook in `lib/ui/login_gate.dart` (post-login, once per account — completion marker in prefs `ovid_cloud_import_done_<uid>`)
- Delete (AFTER the import can read them — worklist §1C import-window rule): `lib/core/session_ledger.dart` (652), `lib/core/memory_store.dart` (394), their tests; `trajectory_screen`/`memory_screen` already re-pointed in Task 18
- Modify: `lib/core/distribution.dart` — FLAG COLLAPSE: `cloudExecution/cloudStudio/cloudSchedules/cloudBrowser` become `true` constants, `thinOverrideForTest` retained for tests, `OVID_THIN_CLIENT` define plumbing deleted, `controlModeAvailable`/`onDeviceSandboxAvailable`/`idleKeepAliveAvailable` + their messages deleted (all capabilities are gone); remove every `Distribution.cloudExecution ? … : …` dual-path branch left in screens (the facade is the only implementation post-Task 19 — branches collapse to the facade arm)
- Modify: first-run flow — login → `CloudSessionStore.refreshSessions()` → session list (or empty state → new chat) → send prompt; NO setup steps anywhere (AG5); `lib/main.dart` boot sequence slims to Firebase + PushService + WsMultiplexer + store warm-up
- Modify: `android/app/src/main/AndroidManifest.xml` final sweep (no FGS/accessibility/exact-alarm remnants; POST_NOTIFICATIONS stays), `pubspec.yaml` final sweep (termux assets gone since Task 13; `speech_to_text` stays — D5; `webview_flutter` stays — artifacts)
- Docs/owner: Play store listing copy must not mention on-device terminal/Linux; Data Safety / privacy policy update — **owner-gated step (R6), pause for explicit owner approval like ledger Task 11 Step 6**; sideload forced-update gate mechanics — **owner questions Q1/Q2 pending: this task only prepares the min-version check hook (server-driven), it does not enable it**

**Interfaces:**
- Consumes: `CloudRestClient.importMessages` (Tasks 4/5), `SessionHistoryRepository` (`chat-history.db`: `history_messages` + `history_fts`, legacy prefs-StringList fallback authority — session_history_store.dart:16–57,111), prefs `ovid_sessions` account-scoped key (state.dart:4484 `_accountKey`), `<docs>/session-ledgers/*.jsonl` (session_ledger.dart:18,89,446), per-account memory markdown root (state.dart `_memoryRootForAccount`:4850).
- Produces:

```dart
class HistoryImportPlan { final int sessions; final int messages; final bool alreadyImported; }
class HistoryImportResult { final int imported; final int skipped; final List<String> failedSessionKeys; }
class HistoryImportService {
  HistoryImportService({required CloudRestClient rest, required SessionHistoryRepository history, required SharedPreferences prefs});
  Future<HistoryImportPlan> plan();     // scans the four stores read-only; alreadyImported = prefs marker for this account
  /// Chunked (≤500 messages/call = Task 4 cap), resumable (per-session completion marker in prefs
  /// `ovid_cloud_import_progress_<uid>`), consent REQUIRED before the first network call.
  /// Ledgers/memory files are imported only when their server endpoints are live (P3) — otherwise
  /// skipped with a stage notice (transcripts are the core, worklist §3f).
  Future<HistoryImportResult> run(void Function(String stage, double progress) onProgress);
}
```

- [ ] **Step 1: Write the failing tests** `test/cloud_history_import_test.dart` (fake rest + seeded sqlite/prefs fixtures): `plan()` counts sessions/messages from the db + legacy fallback; `run()` WITHOUT consent performs ZERO network calls (Review Focus #5); with consent, chunks at ≤500; a fake network failure at chunk 3/10 → progress marker persisted → a NEW service instance resumes at chunk 4 and reports `skipped` for server-deduped messages; `alreadyImported` short-circuits; ledger/memory stages report 'skipped (server endpoint not live)' when the fake rest 404s those routes.

- [ ] **Step 2: Run to verify failure** — `flutter test test/cloud_history_import_test.dart` → FAIL.

- [ ] **Step 3: Implement** — import service + consent sheet (`HistoryImportSheet`: what is uploaded, "Skip for now" is a first-class equal-weight button, spec §13.3 user-consented) + login_gate hook + deletions + flag collapse + first-run flow.

- [ ] **Step 4: Run to verify pass** — targeted PASS; `flutter analyze` clean; FULL `flutter test` green; `grep -rnE "cloudExecution\s*\?" lib/` → no dual-path branches remain; `grep -rni "termux\|proot\|accessibility" lib/ android/app/src/main/` → empty (except doc comments the sweep removes).

- [ ] **Step 5: Staging e2e smoke (owner-gated)** — with explicit owner approval, bring the cloud stack up on SCRATCH ports on the dev box (e.g. gateway :18080 via `docker compose -f cloud/… up` per P1 Task 11 artifacts, never touching production Caddy/DNS); then:

```bash
flutter build apk --debug --dart-define=OVID_CLOUD_REST_BASE=http://<host>:18080/cloud/v1 --dart-define=OVID_CLOUD_WS_URL=ws://<host>:18080/cloud/ws
```

Manual smoke checklist on a device/emulator (record results in the ledger): login → send prompt → watch streamed deltas live → kill network mid-run → reconnect → replay completes the transcript with no duplicates → Studio tree opens (manifest <100 ms per §10 SLA) → open a file, edit, save → terminal tab: bytes + resize + scrollback repaint → schedule CRUD + results feed → browser attach: frames render, takeover flips input → background the app: run continues server-side, FCM result notification arrives, tap routes to the session.

- [ ] **Step 6: Owner items (pause, do not self-approve)** — Play listing copy sweep (no terminal/Linux mention), Data Safety/privacy policy update (R6), forced-update gate decision (Q1/Q2).

- [ ] **Step 7: Commit**

```bash
git add -A lib/ android/ pubspec.yaml test/
git commit -m "feat(app): one-time history import, flag collapse, zero-setup first run"
```

---

## Self-Review

**1. Spec coverage.** §12 Removed: Termux/proot+sandbox_setup (T13), pty_service (T15), agent loop execution half (T8/T19), control+device_* (T13), WebView browser+pool (T16), background reliability (T12), local scheduler (T14), private_sync (T11), plugin/MCP runtimes (T17). §12 Kept: chat UI (T7/T10), voice input (T13 KEEP note), remote Studio/Schedule/Browser screens (T15/T14/T16), billing/usage/settings/shares/collab/reports (untouched except usage_screen adapt T18; collab read paths kept, execution flag-gated T11 pending Q6), FCM (T12). §12 Offline: read cache + prompt queue (T9). §13.3 import (T4+T20). §6.2 protocol: envelope/ticket/channels (T5/T6/T15/T16). D3 escrow (T18). D5 (T13/T16 + voice KEEP). NG3 no-fallback (T20 collapse). AG4 test coordination (Global Constraints + T19 triage rule). AG5 zero setup (T20). R6 owner task (T20 Step 6, owner-gated). §15 verbatim error contracts (T5 mapping + T10 402 test). Gaps found by the worklist: cancel (T1), attachment upload (T3), session-mode PATCH (T2) — all server-side and scheduled BEFORE their client consumers (T5/T8). The worklist's 18-task shape maps onto these 20 tasks (its task 1 split into T1–T4 server gaps per the phase brief; its task 16 split into T4 server / T20 client; its tasks 9+10 merged into T13). No spec requirement lacks a task.

**2. Step scan.** Each step names one action with a checkable result; test steps carry names + the load-bearing assertions; deletion waves use the analyze-driven loop instead of inventing tests for removed code (TDD applies to every new behavior: T1–T10, T12, T14–T16, T18, T20). Two deliberate latitude grants are explicit, not vague: P2/P4/P6/P7 wire shapes say "reconcile against built code" (those plans didn't exist at writing time — the Upstream Dependencies table pins who owns what), and T19's triage rule is a decision procedure (deleted-module → delete; UI-render → port; loop-behavior → delete per AG4), not a transcript.

**3. Type consistency.** `CloudSessionEvent` (not `SessionEvent` — agent_service.dart owns that name until T19) used in T6/T7/T8. `CloudPage<T>` (not `Page` — Flutter collision) used in T5/T9. `AgentSurface` member signatures copied from measured agent_service anchors in T8; T10 consumes `_agent` typed `AgentSurface`; T19 collapses implementations. `AgentMode/ApprovalRequest/BgJob/SubagentInfo` live in agent_service.dart through T18 and move to models.dart in T19 — T8 explicitly forbids duplicating them. `OutboxEntry.clientMsgId` (T9) ↔ server dedupe (T4) ↔ import idempotency (T20) use the same key concept. `RunCancelResponse.status` values `'cancelling'|'cancelled'` match T1's route and T8's facade handling. `Distribution` flag names (`thinOverrideForTest`, `cloudExecution`, `cloudStudio`, `cloudSchedules`, `cloudBrowser`, `cloudPlugins`, `cloudByok`) are consistent across T8/T10/T13–T18/T20.

**4. Review Focus.** All five lines carry their tests in the owning tasks: #1 → T6(e), #2 → T6(b,c)+T7 double-apply, #3 → T9 persistence/flush + T4 duplicate-clientMsgId, #4 → T10 widget test, #5 → T20 no-consent/resume tests + T4 skip-on-reimport. The cancel-race (409 `run_not_cancellable`) is additionally pinned in T1 and T8 though it didn't make the top-5 list.

**5. Proportion.** ~1,000 lines of plan for a phase that removes ~107k LOC and adds ~5–6k (worklist §0) — code blocks are signatures, fold tables, and test names, not bodies; the only verbatim strings are wire contracts (from the built cloud code) and the two spec-fixed error messages. Deletion waves enumerate files instead of describing edits.

**Known residual risks (for the controller/reviewers):** (a) T10 is the riskiest single diff in the repo's history (10.4k-LOC file, 68 call sites) — mitigated by the AgentSurface seam built and conformance-tested in T8 before any chat_screen edit; (b) P2/P4/P6/P7 wire-shape reconciliation points could shift T12/T14/T15/T16 client details — each task pins its client-side interface so drift is contained to the DTO layer; (c) Q6 (collab) default = execution flag-gated off — reversible in T20 if the owner rules otherwise; (d) native Kotlin deletions (T12/T13/T16) can only be fully compile-verified with an Android build on the box — each task notes the fallback verification in T20's build step.
