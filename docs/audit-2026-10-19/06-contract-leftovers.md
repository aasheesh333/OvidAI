# 06: Client↔Cloud contract and architectural leftovers

Scope: Flutter client `lib/` (HEAD fdf2c5f, branch feat/ovid-cloud) against `cloud/apps/gateway`, `cloud/packages/shared`, the live Caddy config (`/opt/ovid-gateway/caddy/Caddyfile`) and the live containers (`docker ps`). Audit was read-only.

Production probes:
- Unauthenticated GETs: `/cloud/v1/health` 200 `{"status":"ok","checks":{"db":true,"redisQ":true}}`; `/cloud/v1/nope` 404 gateway envelope; `/billing/verify` 404 Caddy "Not found"; `/v1/reports` 404 `{"detail":"Not Found"}` (LiteLLM); `/plans` 404 Caddy; `/healthz` 200; `/v1/images/capabilities` 401 `{"error":{"code":"sign_in_required"}}`.
- One bodiless, credential-less POST to `/billing/verify` was also sent. It was refused at Caddy with a 404 and never reached a backend.

Production topology, verified with `docker ps`:
- `api.ovidsi.com/cloud/*` → ovid-cloud gateway (:8082).
- `/mint /healthz /upgrade /usage /v1/images/* /v1/models` → **Python** verifier `/opt/ovid-gateway/verifier/mint.py` (:8090). The TS `cloud/apps/mint` port is *not* what serves these public paths.
- `/account/* /shares* /s/* /chat* /sync/v1/*` → account-dev (:8080).
- Every other `/v1/*` → LiteLLM (:4000).
- Anything else → Caddy 404.

## 1. Endpoint table: HTTP

| # | Client call (file:line) | Method + path (full) | Server route (file:line) | Auth | Contract check |
|---|---|---|---|---|---|
| 1 | cloud_rest.dart:336 `health()` | GET /cloud/v1/health | routes/health.ts:48 (public scope app.ts:298) | none | OK. Shape `{status, checks{db,redisQ}}` matches models.dart:235-256. 503 body is the same shape. |
| 2 | cloud_rest.dart:349 `mintTicket` | POST /cloud/v1/auth/ticket | app.ts:313 | Bearer + AppCheck | OK `{ticket}` |
| 3 | cloud_rest.dart:359 `createSession` | POST /cloud/v1/sessions `{title?}` | sessions.ts:24 (strict `{title?}`) | yes | OK, 201 SessionDto. **No model / preset / plan field exists** (see CT-001). |
| 4 | cloud_rest.dart:365 `listSessions` | GET /cloud/v1/sessions?limit&cursor | sessions.ts:38 | yes | OK `{items,nextCursor}`; the store pages until nextCursor is null (cloud_session_store.dart:427-447). |
| 5 | cloud_rest.dart:374 | GET /cloud/v1/sessions/:id | sessions.ts:51 | yes | OK |
| 6 | cloud_rest.dart:379 | DELETE /cloud/v1/sessions/:id | sessions.ts:81 (204) | yes | OK |
| 7 | cloud_rest.dart:384 | PATCH /cloud/v1/sessions/:id `{title?,mode?}` | sessions.ts:64 + shared rest.ts `sessionPatchSchema` | yes | OK. AgentMode enum `safe/auto/drive/studio` (models.dart:407) equals the server enum. |
| 8 | cloud_rest.dart:405 `sendMessage` | POST /cloud/v1/sessions/:id/messages `{content, attachmentIds?, clientMsgId?, maxOutputTokens?}` | messages.ts:160 (strict) | yes | Fields OK. Server returns 202 `{runId,userMessageId,status:"queued"}`. 402 `daily_limit_reached` + `x-ovid-resets-at` is parsed (cloud_rest.dart:290). **No model / preset / plan / system-prompt / temperature fields** (CT-001, CT-004). |
| 9 | cloud_rest.dart:423 `pageMessages` | GET /cloud/v1/sessions/:id/messages?limit&before | messages.ts:366 | yes | Pagination OK (newest-first, `before`=uuid). DTO is **text only** (CT-003). |
| 10 | cloud_rest.dart:433 | POST /cloud/v1/runs/:id/cancel | runs.ts:99 | yes | OK `{runId,status:cancelling\|cancelled}` |
| 11 | cloud_rest.dart:436 | POST /cloud/v1/sessions/:id/attachments `{name,size}` | attachments.ts:53 | yes | Shape OK. **Size cap mismatch** (CT-010). |
| 12 | cloud_rest.dart:463 | PUT `<presigned R2 url>` | R2 | URL is the credential | OK; the XML error body collapses to `internal`. |
| 13 | cloud_rest.dart:450 `mintArtifactUrl` | GET /cloud/v1/sessions/:id/artifacts/:artifactId/url | artifacts.ts:61 | yes | OK `{url,expiresAt}`. Only reachable when an artifact URL already sits in message text (CT-002). |
| 14 | cloud_rest.dart:476 `importMessages` | POST /cloud/v1/import/sessions | import.ts:43 (strict, ≤500 msgs, datetime) | yes | OK (client batches 500, history_import.dart:99; UTC ISO). |
| 15 | cloud_rest.dart:497 `registerDevice` | POST /cloud/v1/devices `{token,platform:"android"}` | devices.ts:18 | yes | OK. **DELETE /devices never called** (CT-006). |
| 16 | cloud_ws.dart:995, trajectory_screen.dart:60 | GET /cloud/v1/sessions/:id/events?after\|before\|tail\|limit | events.ts:54 | yes | OK. `{events:[SessionEvent]}`; client pages at 200 (= DEFAULT_EVENT_LIMIT). |
| 17 | studio_files.dart:217 | GET /cloud/v1/sessions/:id/workspace/tree | workspace.ts:146 | yes | OK. **Screen is unreachable** (CT-008). |
| 18 | studio_files.dart:269 | GET /cloud/v1/sessions/:id/workspace/file?path | workspace.ts:206 | yes | OK (`downloadUrl`/`sizeBytes` redirect branch handled) |
| 19 | studio_files.dart:384 | PUT /cloud/v1/sessions/:id/workspace/file `{path,contentUtf8}` | workspace.ts:276 | yes | OK (202 `{status:"hydrating"}` handled) |
| 20 | schedule_client.dart:291/314/337/350/359 | GET/POST/PATCH/DELETE /cloud/v1/schedules[/:id][/runs] | schedules.ts:95-194 | yes | OK. Fields and enums match shared schedules.ts; `cursor`, `includeCancelled`, `before` match; tz comes from native `timeZoneId` (IANA). |
| 21 | byok_client.dart:95/114/127/132 | GET/POST/DELETE /cloud/v1/byok, POST /byok/:id/test | byok.ts:107-195 | yes | OK. GET answers `{items}`. |
| 22 | ovid_cloud_service.dart:498/640 | POST https://api.ovidsi.com/mint | Python mint.py:1059 via Caddy @mint | Firebase + AppCheck | live (not part of the cloud gateway) |
| 23 | ovid_cloud_service.dart:503/955 | POST /usage | Python mint.py:1530 | yes | live |
| 24 | ovid_cloud_service.dart:507/1020 | POST /upgrade | Python mint.py:1027 (ALLOW_TEST_UPGRADE gate) | yes | test-only |
| 25 | ovid_cloud_service.dart:512/1101 | POST /billing/verify | **None in prod.** The TS route exists only in cloud/apps/mint/src/billing/routes.ts:83, which does not serve public traffic. Caddy has no matcher. | n/a | **404** (CT-005) |
| 26 | ovid_cloud_service.dart:864 | GET {mintedBase}models (= /v1/models) | Python mint (Caddy @images) | minted key | live |
| 27 | image_studio.dart:270/315/561/614/649 | /v1/images/{capabilities,generations,edits,requests/:id[/result]} | Python verifier images module via Caddy @images | yes | live (401 envelope confirmed) |
| 28 | account_service.dart:67 | /account/login, /account/deletion[/cancel] | account-dev :8080 via Caddy @account | yes | live. The duplicate gateway root routes (app.ts:296, routes/account.ts:98-127) are unreachable in prod (CT-016). |
| 29 | conversation_share_service.dart:215-294 | /shares, /shares/:id, /shares/:id/fork, /s/:id.json | account-dev (Caddy @account); the gateway shares/routes.ts:285-406 duplicates them but is not routed | yes / public | live on account-dev |
| 30 | collaboration/client.dart:309/352 | /chat/:token/events … | account-dev | yes | live (not in cloud scope) |
| 31 | content_report_service.dart:139 | POST {OVID_REPORT_BASE_URL}/v1/reports | gateway reports.ts:226 registers it at ROOT, but Caddy sends `/v1/*` to LiteLLM | yes | **Broken twice over** (CT-007) |

### Server routes the client never calls

| Server route | file:line | Status in app |
|---|---|---|
| GET /sessions/:id/artifacts (list) | artifacts.ts:35 | Not wired. The artifacts screen scans message text instead (CT-002). |
| POST /sessions/:id/workspace/hydrate, /hibernate | workspace.ts:395/446 | Not wired (Studio unreachable anyway). |
| GET /schedules/:id | schedules.ts:136 | Not wired (list is used instead). Harmless. |
| DELETE /devices | devices.ts:35 | **Not wired → CT-006** |
| /mcp/servers CRUD, /mcp/catalog, /mcp/oauth/start, /mcp/oauth/disconnect | mcpServers.ts:252-402, mcpCatalog.ts:13, mcpOauth.ts:54/79 | Not wired. `Distribution.cloudPlugins=false` (distribution.dart:51), so this is intentionally dark. The memory note says Android MCP is client-side by design, yet no MCP client exists in lib/ either (CT-013). |
| /plugins, /plugins/:id, /plugins/install, /plugins/:id/config | plugins.ts:121-230 | Not wired (dark) |
| POST /system/responses | systemResponses.ts:15 | Not wired |
| account routes at gateway root, shares at gateway root, /v1/reports | app.ts:296, 353-372 | Unreachable through Caddy |

## 2. WebSocket table (`wss://api.ovidsi.com/cloud/ws?ticket=`; shared/src/ws.ts)

| op | Direction | Client | Server | Notes |
|---|---|---|---|---|
| subscribe {sessionId,lastEventId} | C→S | cloud_ws.dart:722 | ws.ts | OK |
| unsubscribe | C→S | cloud_ws.dart | ws.ts | OK |
| ping / pong | both | cloud_ws.dart:684 / :837 | ws.ts | OK |
| subscribed {trimmed?} | S→C | cloud_ws.dart:812 | ws.ts | OK; trimmed → REST mirror catch-up |
| event {SessionEvent} | S→C | cloud_ws.dart:798 | ws.ts | Transport OK. **11 of 21 event types are dropped by the chat projection** (CT-002). |
| error {code,message,sessionId?,ptyId?} | S→C | cloud_ws.dart:842/880 | ws.ts | OK |
| browser_attach/detach/input/takeover | C→S | browser_stream.dart:270-453 | ws.ts | Input shapes (`tap{x,y}`, `scroll{dx,dy}`, `key{key,text?}`) match shared browser.ts |
| browser_state + binary frames | S→C | browser_stream.dart (raw lane) | ws.ts / browserChannel.ts | OK |
| approval_response {decision: allow\|deny\|always} | C→S | cloud_agent_facade.dart:1199-1259 | ws.ts:877 | OK |
| approval_ack | S→C | ignored (raw lane, no consumer) | ws.ts:902 | Fine: the durable `approval_resolved` event covers it |
| pty_open/attach/input/resize/close; pty_opened/attached/output/exit | both | **never sent / no consumer** | ws.ts + wsPty.ts | Cloud terminal built server-side, no client (CT-008) |
| subscribe_system / unsubscribe_system / system_subscribed / system_event / system_response | both | **never sent** | ws.ts, systemChannel.ts | MCP OAuth/plugin prompts cannot reach the user (CT-013) |
| system {schedule_* event} | S→C | **never subscribed** | ws.ts (deps.system) | The schedule screen gets no live updates (CT-014) |

Event types vs the client fold (event_projection.dart:407-450; the facade switch at cloud_agent_facade.dart:438):
- Folded: run_started, message_delta, message_completed, run_started_retry, run_failed, run_cancelled, run_completed, system_note, approval_requested, approval_resolved.
- Ignored in chat: **tool_started, tool_completed, artifact_created, todo_updated, goal_updated, plan_mode_changed, subagent_started, subagent_completed, compaction_completed, workspace_hibernated, workspace_hydrated.** These are rendered only in the opt-in Trajectory screen.

---

## 3. Findings

### CT-001 [P0] The model picker, `/model`, `/preset` and `/plan` never reach the cloud. Every run uses the fleet default model.
- **Client:**
  - The chat AppBar "Change model" opens `_modelPicker` (lib/ui/chat_screen.dart:1555-1559, 2523).
  - `/model` calls only `app.setModel` locally (lib/core/commands.dart:258-293).
  - `/preset` sets only `s.presetId` locally (commands.dart:206-253).
  - `/plan` flips the local `session.planMode` (cloud_agent_facade.dart:1272-1277) and sends the plan text *without* the `/plan` prefix (commands.dart:174-204).
  - The send path posts only `content/attachmentIds/clientMsgId/maxOutputTokens` (cloud_rest.dart:405-421, cloud_agent_facade.dart:1022-1028).
  - cloud_session_store.dart:460-462 even says "Cloud runs choose their model server-side … the provider picker is hidden on the thin client". It is **not** hidden.
- **Server:**
  - The model comes from `SessionAgentState.modelPin`, set only by the *server* `/model` slash command (packages/agent-core/src/commands.ts:280-295); otherwise `deps.defaultModel` is used (apps/worker/src/keyResolver.ts:199-210, runProcessor.ts:1008-1013).
  - `presetId` has no writer anywhere server-side (only the defaults in db/src/repos.ts:1900 and agent-core ports.ts:115). There is no `preset` command case in commands.ts (cases: plan, permission, model, compact, todo).
  - The server's own `/plan` (commands.ts:236) is shadowed because the client intercepts `/plan` locally.
- **Impact:** Users see the model they picked in the header, but every reply comes from the default model. Presets and plan mode are UI-only.
- **Fix:**
  - Add `model` (and `presetId`, `planMode`) to `sessionPatchSchema` (and/or the send body), persist them into SessionAgentState, and PATCH from `AppState.setModel` / the preset and plan setters.
  - Short-term alternative: forward `/model <id>`, `/plan` and `/preset` verbatim as message content so the server pre-pass handles them.
  - Either way, stop showing an editable picker that does nothing.

### CT-002 [P1] The chat drops tool, artifact, todo, subagent and compaction events. Cloud agent work is invisible in the transcript.
- **Client:**
  - event_projection.dart:407-450 handles 10 types; the default branch is a no-op (doc at :30-35 lists the ignored ones).
  - `subagentsOf` → `const []` (cloud_agent_facade.dart:1666), `jobsFor` → `[]` (:1409).
  - The context counters `sessionSystemTokens…measuredContextTokens` → 0 (:1420, :1650-1659).
  - `browserBusy/browserReady` → false (:1674-1677).
- **Server:** shared/src/events.ts emits `tool_started`, `tool_completed`, `artifact_created`, `todo_updated`, `goal_updated`, `plan_mode_changed`, `subagent_*`, `compaction_completed`. `GET /sessions/:id/artifacts` (artifacts.ts:35) is unused.
- **Impact:**
  - No tool cards and no generated-file chips in the chat.
  - The Artifacts screen only finds artifacts whose URL happens to appear in assistant text (session_artifacts.dart:86).
  - The subagent screen is always empty, the context ring is always 0%, and the Jobs menu is empty.
- **Fix:** Fold these types into `TranscriptProjection` (tool rows, artifact attachments via `mintArtifactUrl`, a todo panel, subagent list), and populate the Artifacts screen from `GET /sessions/:id/artifacts`.

### CT-003 [P1] Reopening a chat replaces the rich transcript with plain text from `GET /messages`.
- **Client:**
  - `loadTranscript` overwrites the cache with `_messageFromDto` rows (`kind: MsgKind.text`, content only; cloud_session_store.dart:538-562, 595-603).
  - `seedFromHistory` clears the projection and installs them (event_projection.dart:160-166).
  - `role:"tool"` rows render as plain text.
- **Server:** `MessageDto` is `{id,sessionId,role,content,createdAt}` only (shared/src/rest.ts). There are no attachments, artifacts, tool calls or reasoning.
- **Impact:** Images, attachments, tool rows and approval history vanish whenever a session is reopened online, on reinstall, or on a second device.
- **Fix:** Rebuild the transcript from the event mirror (`GET /events?tail=1` + `before` paging) rather than from messages, or extend MessageDto with attachments/artifacts/toolCalls.

### CT-004 [P1] **GATED, not released** — cloud history mutations return an ownership-first 409 `history_actions_unavailable` and preserve state.
- **Current state (gate, 2026-10-19):**
  - **Server:** `DELETE /sessions/:id/messages/:messageId`, `POST .../regenerate` and `POST /sessions/:id/branch` (cloud/apps/gateway/src/routes/messages.ts) validate ownership and target first (wrong owner and unknown id are the same 404), then return 409 `history_actions_unavailable` before any key mint, queue add, truncate or copy. Durable rows, event-mirror events, attachments, compaction state and run rows are provably untouched (messagesWave1b.test.ts snapshots all of them around each refused call). No bypass flag exists.
  - **Client:** cloud chats no longer offer Edit & resend, Delete from here, Regenerate, Branch, or a run-failure Retry; `CloudAgentFacade.canEditHistory` is a constant `false` and the run-failed row explains in plain language that the chat is kept unchanged. Ordinary send, outbox Retry/Discard (stable clientMsgId), copy, report, rich history, Stop, approvals and drafts are all retained. The facade's wire methods remain behind the facade wire tests, but no UI control can reach them.
  - Why a gate and not a fix: an idle check (`runs.activeForSession`) followed by a destructive mutation is not a cross-worker serialization protocol — a second device's send, a queued run start and the truncate race freely, and edit-then-send is not atomic (a crash between truncate and re-send loses the turn permanently). Branch as a capped text-row copy is not a rich fork (no attachments, events, tool state, compaction, approvals).
- **Historical finding (pre-gate):** the actions showed on cloud chats but silently did nothing (local-only `AppState.deleteMessagesFrom`, regenerate gated on a local BYO provider, no server truncate route; the worker reads history from `messages.page`, runProcessor.ts:1915), so the model saw old answers plus duplicate turns and deleted rows returned on reload.
- **Fix (future, not a small patch):** real enablement needs an atomic design — a shared PostgreSQL lock (e.g. advisory lock or transactional lock row) serializing history mutation against send across workers; a single transaction that truncates rows/events/compaction, creates the replacement run and writes a durable queue-outbox entry with crash recovery; and, for branch, a rich clone of attachments, events and session state rather than a text copy. Until that contract ships, the gate stays.

### CT-005 [P0 for Play builds] Google Play purchases cannot be verified: `/billing/verify` is 404 in production.
- **Client:** ovid_cloud_service.dart:512 (`https://api.ovidsi.com/billing/verify`), :1101-1125. A 404 maps to `UpgradeResult.notAvailable`.
- **Server:**
  - The route exists only in the TS mint (cloud/apps/mint/src/billing/routes.ts:83), which is not the public mint (it runs as `ovid-cloud-mint-1` on :8091-8092 behind the `mint` profile; see deploy/docker-compose.yml:355-373).
  - The live Python mint (`/opt/ovid-gateway/verifier/mint.py`) has no billing route.
  - The Caddy `@mint` matcher is `/mint /healthz /upgrade` only.
  - Probe: `POST /billing/verify` → Caddy `404 Not found`.
- **Impact:** In an `OVID_PLAY_BUILD=true` release, a user can pay but the tier is never granted. The purchase is never acknowledged, so Play refunds it after 3 days. The UI says "not available".
- **Fix:** Route `/billing/verify` (and `/billing/rtdn`) in Caddy to the service that implements it (finish the TS-mint cut-over, or port the route to mint.py). Gate the buy button on a successful capability probe.

### CT-006 [P1, privacy] The FCM device token is never unbound on sign-out, and is never re-registered on account switch.
- **Client:**
  - `PushService.init()` is one-shot (`_initialized` latch, push_service.dart:106-108) and runs only from `_maybeStartCloud` at the first sign-in (main.dart:207-217).
  - There is no `DELETE /devices` call and no `FirebaseMessaging.deleteToken` anywhere in lib/.
- **Server:** `POST /devices` upserts by token (db/src/deviceRepos.ts:30-36). `DELETE /devices` (devices.ts:35) exists but is unused.
- **Impact:**
  - After user A signs out, A's schedule and agent pushes (with titles and bodies) keep arriving on the device.
  - If B signs in within the same process, B is never registered until a token refresh or restart, while the token stays bound to A, so B's notifications go nowhere and A's are shown to B.
- **Fix:** On sign-out, call `DELETE /devices {token}` and `deleteToken()`. Reset `_initialized` and re-run `_register` on every auth-state change to a new uid.

### CT-007 [P1, Play policy] In-app content reporting is broken in every CI release, at two layers.
- **Client:**
  - content_report_service.dart:105-108: the default is `String.fromEnvironment('OVID_SHARE_BASE_URL')` with no default value, so it is `''`.
  - CI never sets either define (.github/workflows/build.yml:208-209).
  - `available == false`, so `submit()` throws "Reporting is not configured". content_report_sheet.dart does not pre-check `available`, so users fill in the form and then fail.
- **Server:** Even with a base of `https://api.ovidsi.com`, `/v1/reports` is matched by Caddy `@api path /v1/*` → LiteLLM. The probe returns `404 {"detail":"Not Found"}`. The gateway registers `/v1/reports` at its root (reports.ts:226), but only `/cloud/*` is proxied to the gateway.
- **Fix:** Pick one home. Either move the route to `/cloud/v1/reports` (authenticated scope) and point the client at `CloudConfig.restBase`, or add a Caddy matcher for `/v1/reports` before `@api`. Set a non-empty default.

### CT-008 [P1] Studio and the cloud terminal are fully built on both sides but unreachable from the UI.
- **Client:**
  - `StudioScreen` (studio_screen.dart:46) is never constructed.
  - The chat header Studio button and the "Open Studio" row only show a snackbar, "Studio moves to the cloud in this build." (chat_screen.dart:1590-1601, :9220-9224).
  - No `pty_*` op is ever sent.
- **Server:** workspace.ts:146-446 (tree, file, put, hydrate, hibernate) and the pty bridge (ws.ts pty ops, wsPty.ts) are live.
- **Impact:** The "Studio" access mode can be selected, but the user cannot browse or edit the workspace or open a terminal. The Studio folder picker selects a *phone* folder that nothing in lib/core/cloud reads (`session.workspaceFolder`, chat_screen.dart:9196-9300).
- **Fix:** Route the header button to `StudioScreen`. Remove the local folder picker for cloud sessions. Wire a terminal pane over `pty_open/attach/input/resize`.

### CT-009 [P1] Taps on local notifications don't navigate: Kotlin calls `ovid/native` methods that Dart never handles.
- **Client:** MainActivity.kt:452-460 invokes `onSelectSession` and `onOpenRoute` on `ovid/native` after *removing* the extras (:39-52). No Dart code registers a handler on `ovid/native`; the only `setMethodCallHandler` is html_artifact_view.dart:183.
- **Impact:** Foreground FCM pushes re-posted through `BackgroundNotifier.post` (push_service.dart:137-147), and all local notifications, open the app on whatever screen was last shown. Only background FCM taps (`onMessageOpenedApp`) route correctly.
- **Fix:** Register a `MethodChannel('ovid/native').setMethodCallHandler` in main.dart for `onOpenRoute` / `onSelectSession` → `AppRouter`. For cold start, have Dart pull a pending route instead of Kotlin pushing one before the engine is ready.

### CT-010 [P2] Attachment size cap mismatch: client 25 MiB, server 25 MB.
- **Client:** cloud_agent_facade.dart:1327 `25 * 1024 * 1024` (26,214,400).
- **Server:** attachments.ts:28 `ATTACHMENT_MAX_BYTES = 25_000_000`.
- **Impact:** Files between 25,000,001 and 26,214,400 bytes are accepted at staging, then fail at send with 400 `attachment_too_large`. The whole send aborts after earlier attachments were already uploaded.
- **Fix:** Use `25000000` on the client (or share the constant).

### CT-011 [P2] An App Check failure surfaces as a non-`CloudApiException` from every REST call.
- **Client:** `CloudHeaders.authorize` awaits `CloudAppCheck.getToken`, which throws `AppCheckUnavailable` (cloud_app_check.dart). It is not a `CloudApiException`, so paths that only `on CloudApiException catch` let it escape. Example: the create-on-first-send at cloud_agent_facade.dart:966-980 falls through to a generic error or an unhandled future. Separately, the `?? ''` at cloud_rest.dart:110 is dead.
- **Server:** auth.ts always verifies App Check (`services.appCheck.verifyToken`); a missing token gives 401 with a generic message.
- **Fix:** Wrap the App Check failure as `CloudApiException(status:401, code:'app_check_unavailable')` so the chat error row and outbox logic handle it uniformly. (Suspected impact; not reproduced.)

### CT-012 [P2] "Regenerate title" is inert.
- **Client:** `regenerateSessionTitle` is an empty body (cloud_agent_facade.dart:1683-1691).
- **Server:** There is no title-generation endpoint or event.
- **Fix:** Hide the action, or add a worker job that sets the title and emits it.

### CT-013 [P2, intended-but-incomplete] MCP and plugins have no client in either design.
- **Client:**
  - `Distribution.cloudPlugins=false` (distribution.dart:51).
  - There is no MCP client code in lib/.
  - The `OAuthCallbackActivity` manifest entry (`com.dhanuk.ovidai://oauth/callback`) has no Dart consumer (`_onLink`, main.dart:280, routes only chat/schedule/share).
  - `system_event` / `system_response` are never handled.
- **Server:** mcpServers.ts, mcpCatalog.ts, mcpOauth.ts, plugins.ts, systemResponses.ts and systemChannel.ts are live.
- **Note:** The owner memory says Android MCP is client-side by design. Currently neither side is reachable, while marketing copy says "plugins & MCP" (settings_screen.dart:1601).
- **Fix:** Decide the owner: wire the gateway MCP routes, or ship the device-side MCP client. Remove the claim until then.

### CT-014 [P2] The schedule screen gets no live updates.
- **Server** publishes `system{schedule_created…schedule_run_paused}` to subscribers (shared/src/schedules.ts; ws.ts deps.system). The **client** never sends `subscribe_system`.
- **Impact:** Run status and next run only update on manual refresh or re-entry.
- **Fix:** Subscribe while schedule_screen is visible and refetch on events.

### CT-015 [P2] Unused server routes are not wired: list artifacts, hydrate/hibernate, GET schedule by id.
These are covered by CT-002/CT-008 where they matter. GET /schedules/:id would let a deep-link `/schedule/<id>` open without paging the whole list.

### CT-016 [P2] Duplicate route ownership: account, shares and reports are registered on the gateway root but served by account-dev.
- **Server:** app.ts:291-297 and 353-372 register `/account/*`, `/shares*`, `/s/*`, `/.well-known/assetlinks.json` and `/v1/reports` on the gateway. Caddy routes those paths to account-dev :8080, except `/v1/reports`, which goes to LiteLLM.
- **Impact:** Two divergent implementations. Fixes to the gateway copies never ship (see CT-007).
- **Fix:** Delete or disable one side, and document the canonical owner in deploy/DEPLOY.md.

### CT-017 [P2] Sideload builds still target SDK 28 for the removed native sandbox.
- **Where:** android/app/build.gradle.kts:30 (`ovidSideloadTargetSdk = 28`), :119-136. CI push builds are sideload (`OVID_PLAY_BUILD` is set only on production_release, build.yml:207).
- **Impact:** The GitHub APK the owner tests runs under API-28 compatibility behaviour (background, notification, storage and intent semantics differ from the Play build). Bugs seen there may not reproduce in the Play build, and the reverse.
- **Fix:** Use 36 everywhere now that exec-from-app-files is gone.

### CT-018 [P2] On-device leftovers (dead code, class a)
- MainActivity.kt channel handlers with no Dart caller:
  - `getNativeLibraryDir` (:134-143, "exec-ALLOWED")
  - `deviceOpenSettings` (:148), `requestBatteryExemption` (:159-188), `openAutoStartSettings` (:189-266)
  - `safExportFile` (:349-378) + SafExportCoordinator.kt
  - `getSdkInt` (:380), `notifyOpenAppSettings` (:420)
  - unused imports `ZipFile` / `Executors` (:33-34)
- Dart:
  - `BgJob` with `dart:io Process` (cloud/models.dart:18, :526-549)
  - `shellSplitArgs` (state.dart:286-339)
  - `workspaceDirForSession` / `_warmWorkspace` (state.dart:4274-4303), which still creates `<appDocs>/workspaces/ws_<id>` for every session
  - an empty `_mountRuntimeSkills` startup gate (state.dart:1821/1861)
  - Control-mode prefs (state.dart:3485-3519)
  - `deleteAllData()` (state.dart:3305)
  - the `Distribution.cloudExecution/cloudStudio/cloudSchedules/cloudBrowser` constants (always true, test-only readers)
  - backup allowlist keys `ovid_sandbox_skipped`, `ovid_keep_alive`, `ovid_share_*_on_restart` (settings_backup_service.dart:118-133)
  - studio terminal-pane layout code (studio_layout.dart:62-65, 109-290)
- pubspec: `webview_flutter`, `webview_flutter_android`, `cryptography` are not imported anywhere.
- **Fix:** Delete them. Smaller APK, less R8 surface.

### CT-019 [P2, suspected data loss] A reset or session delete may recursively delete a user-picked folder.
- **Where:** `localWorkspaceDirFor` returns the pinned `workspaceFolder` (state.dart:1146-1164, 1314-1324). `_deleteLocalWorkspace` deletes it recursively (:1167-1174). The callers are the settings reset (settings_state_integration.dart:47-62), session delete (state.dart:2593) and deleteAllData.
- **Impact:** This contradicts the dialog text "Not deleted: folders you picked outside the app" (settings_action_widgets.dart:160). It only affects sessions that carry a legacy `sandboxId` (read from JSON, state.dart:929) plus a pinned folder.
- **Fix:** Never delete paths outside app storage. Drop the local workspace concept entirely.

### CT-020 [P2] UI copy still describes on-device execution
- studio_editor.dart:1193 "Terminal below runs inside the native Linux sandbox"
- settings_screen.dart:938 "Required by the app (sandbox, keys)"
- settings_screen.dart:1102 "background runs may stop"
- settings_action_widgets.dart:161 "installed sandbox runtime"
- chat_screen.dart:9162-9236 "Sandbox folder (Studio)", "Reset to session sandbox"
- settings_screen.dart:1601 "plugins & MCP"

### CT-021 [P2] Release-build hazards
- **Obfuscation:** No behaviour-affecting `runtimeType`/Type-name use. The only `runtimeType` (state.dart:2925) is an in-memory hash. Exception-text matching (providers_screen.dart:179-182, studio_errors.dart:112-133, user_error.dart:126-135) uses SDK literal strings, so it is safe but fragile; prefer `is SocketException`. Enum wire values use `.name` / `byName` (safe).
- **Defines:**
  - `OVID_BUILD` is set by CI (build.yml:208-209, 429) but never read, so the build SHA is not visible in the app or Diag.
  - `OVID_REPORT_BASE_URL` / `OVID_SHARE_BASE_URL` are not set → CT-007.
  - `OVID_ACCOUNT_ENABLED` defaults to `'false'` (build.yml:81), so in-app account deletion is off (web fallback).
  - `OVID_WEBSITE_URL` defaults to `https://dhanuk.page.gd/ovid` (legal_links.dart:15-18); confirm this is intended.
  - Cloud URLs default to prod; staging overrides are never shipped. OK.
- **R8:**
  - Minify and shrink are on (build.gradle.kts:160-168).
  - Mapping upload is disabled and the comment ":172 mapping is meaningless for Dart AOT" is wrong: plugin Java/Kotlin *is* obfuscated with `-repackageclasses ''`.
  - Dart symbols in `build/symbols` are not archived (build.yml:254-258), so release crashes cannot be symbolicated.
  - `-assumenosideeffects android.util.Log` strips w/e from all libraries.
  - No explicit Tink/protobuf keep for flutter_secure_storage 9.2.4 under R8 full mode with repackaging (suspected). Smoke-test write → restart → read on a signed release.
  - No local-notification Gson rules are needed (custom Kotlin notifications).

## 4. Verified OK (no finding)
- The error envelope `{error:{code,message}}` is uniform: setErrorHandler and setNotFoundHandler (app.ts:270-278) plus the http.ts helpers. The client parser handles it, falls back to `internal`, and reports timeouts as status 0.
- The 401 single retry with a force-refreshed ID token works. Close code 4401 triggers a re-mint and reconnect.
- Pagination: sessions use `cursor`, messages and schedule runs use `before` (uuid), events use `after/before/tail` (seq). Client and server agree everywhere; malformed cursors degrade to the first page.
- Enums match: session mode, message role, run-cancel status, schedule status/autonomy/trigger kinds, approval decision, device platform, browser input types.
- The import body: strict schema, UTC ISO timestamps, ≤500 messages per call.
