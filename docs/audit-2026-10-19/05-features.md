# 05: Secondary feature screens audit

Scope: Browser, Schedules, Artifacts, Sharing (read-only links + deep links), Collab, Trajectory, Subagent, Content reports, Image studio/receipts, session history/search.
Repo: /root/OvidAI @ feat/ovid-cloud fdf2c5f. This audit was read-only. Each finding was checked against the client code, the gateway/worker code, `/opt/ovid-gateway/caddy/Caddyfile` and `docker ps`. Two harmless unauthenticated `curl` probes were also run against prod. Findings marked "suspected" were inferred from the code and not run end to end.

## Cross-cutting root cause (read first)

Many of the findings below come from one gap. **The cloud transcript only carries plain text.**

- `lib/core/cloud/event_projection.dart:29-35, 436-450`: `tool_started`, `tool_completed`, `artifact_created`, `subagent_started/completed`, `todo_updated` and the other non-text events are folded as **no-ops**.
- `lib/core/cloud/cloud_session_store.dart:595-603`: `_messageFromDto` maps every history row to `MsgKind.text` with no attachments, tool, image or html data.
- `lib/core/cloud/cloud_agent_facade.dart:1032-1037`: the optimistic user row has no `attachments`.
- Cloud sessions keep `ChatSession.messages` **empty**. The transcript lives only in `CloudAgentFacade.transcriptFor()` (chat_screen.dart:1264-1269), and that is null until the session's projection has been created in this process.

Any screen that derives data from `ChatSession.messages`, from tool rows or from `toolSessionId` is therefore empty or unreachable for cloud chats. This covers Artifacts, Subagent, Jobs, search and native transcript share. The fix is to fold the structured events into the projection (and into the persisted cache), or to read the server routes directly. Details are in each finding.

---

## P0

### FE-001 [P0] In-app content reporting cannot work in the release build (Play AI/UGC policy blocker)
- **Files:** `lib/core/content_report_service.dart:105-108, 128-140`; `/opt/ovid-gateway/caddy/Caddyfile:39-52`; `cloud/apps/gateway/src/routes/reports.ts:226`
- **Problem:** The "Report" actions (on an AI message and on a shared conversation) always fail.
  - `baseUrl` defaults to `String.fromEnvironment('OVID_SHARE_BASE_URL')`, which has **no default**. `.github/workflows/build.yml:197-208` defines neither `OVID_REPORT_BASE_URL` nor `OVID_SHARE_BASE_URL`. So `_endpoint == null` and the user sees "Reporting is not configured in this build."
  - Even with the define set to `https://api.ovidsi.com`, the request goes to `/v1/reports`. Caddy's `@api path /v1/*` sends that to LiteLLM on :4000, not to the TS gateway's `POST /v1/reports`.
- **Evidence:** `curl -X POST https://api.ovidsi.com/v1/reports` returns `{"detail":"Not Found"}` (HTTP 404).
- **Fix:**
  - Give the service a real default (`https://api.ovidsi.com`) or pass `--dart-define=OVID_REPORT_BASE_URL` in CI.
  - Add a Caddy matcher `@reports path /v1/reports` placed before `@api`, proxying to the gateway (127.0.0.1:8082). Or mount reports under `/cloud/v1/reports` and use `CloudRestClient`.
  - Add a release smoke test that POSTs a dry-run report.
- **Emulator verification:** Release APK, long-press an assistant message, choose Report, pick a reason and Send. Expect "Thanks. Your report was sent…" and a row in the `reports` table. Repeat from a `/s/<token>` viewer's flag icon.

---

## P1: broken, incomplete or misleading

### FE-002 [P1] Collab live sessions: every message fails, leaves orphan prompts for other members, and writes into an unrelated chat
- **Files:**
  - `lib/core/state.dart:1384-1412`: `_collaborationTurnRunner` always throws `kCollaborationReadOnlyNotice` and appends a `turnTail` row to the **active chat** (`activeSession.messages.add`, then persisted).
  - `lib/core/collaboration/production.dart:465-522`: the user prompt and `modelStatus: running` are appended to the live session **before** the runner is called. On throw it appends `modelStatus: failed`.
  - `lib/ui/collab_session_screen.dart:38-43, 106-127`: the model picker lists local providers with their own keys (`p.hasKey`). On the cloud build this is usually empty, giving the "Add a provider with your own key…" snack.
  - `lib/ui/conversation_share_sheet.dart:160-166`: the "Collab" mode card still advertises live chat with each person's model.
- **Problem:**
  - The feature is advertised but cannot produce a single AI reply.
  - Other members see the user's prompt followed by "model failed".
  - The user gets the snack "Collaboration is moving to the cloud — read-only for now".
  - A stray notice row is written into whatever chat happens to be active (data pollution). For cloud chats that row is invisible but is persisted.
- **Fix (short term):** hide or disable the Collab mode card and the composer behind a server capability flag, with explicit "Coming soon" copy. Never append to the live session before the runner succeeds. Remove `_appendCollabReadOnlyNotice`.
- **Fix (real):** run collab turns server-side. Add a gateway route that runs the turn on the sender's cloud account and posts the assistant event.
- **Emulator verification:**
  1. Open a chat, open Share, choose Collab, Start, then Open.
  2. Send "hi".
  3. Today the snack appears and the second device's member view shows an orphan prompt. After the fix, either the composer is disabled with an explanation, or a reply arrives.
  4. Confirm the active chat gains no new rows (`adb shell run-as … sqlite3 history.db`).

### FE-003 [P1] "Continue this chat in Ovid" from a shared link loses the context: the model never sees it and the UI hides it after the first send
- **Files:** `lib/ui/shared_conversation_screen.dart:80-97`; `lib/core/state.dart:4243-4273` (`importSharedMessages`); `lib/core/cloud/cloud_session_store.dart:337-349` (`_createServerSession` creates an empty session, no history seed); `lib/ui/chat_screen.dart:1268-1269`
- **Problem:**
  - Fork returns a random 22-char id (`moneyRepos.ts` fork) that is **not** a cloud session.
  - The messages are imported only into local `ChatSession.messages`.
  - On the first send, `ensureServerSession` creates an empty server session, so the agent answers with no context.
  - `_stateFor()` creates the projection, so `transcriptFor()` becomes non-null and the chat now renders only the projection. The imported history disappears from view.
- **Fix:** after `fork`, create the server session and seed it via `POST /cloud/v1/import/sessions` (already used by `history_import.dart`), or add a gateway fork route that materialises a cloud session with the snapshot. Then select that server session id.
- **Emulator verification:**
  1. Open `https://ovidsi.com/s/<token>` (adb `am start -d`) and tap Continue.
  2. Ask "What did we discuss above?".
  3. The reply should reference the shared content.
  4. Scroll up: the shared messages are still visible after the reply.

### FE-004 [P1] Artifacts screen is always empty for cloud chats
- **Files:** `lib/core/session_artifacts.dart:210-215, 266-338`; `lib/ui/artifacts_screen.dart:52-57`; root cause above
- **Problem:** `collectSessionArtifacts` scans `ChatSession.messages`, which is empty for cloud chats:
  - Uploaded attachments are never recorded on cloud user rows.
  - `imageGen` and `htmlArtifact` rows are never produced.
  - Tool rows are never produced, and `fileWritingTools` still lists the on-device tool names (`file_write`, `fs_edit`, `multi_edit`, `notebook_edit`). The cloud worker uses `write_file` / `edit_file` (`cloud/apps/worker/src/tools/fileTools.ts:212,245`).
  - The gateway already exposes `GET /cloud/v1/sessions/:id/artifacts` (routes/artifacts.ts), but nothing in `lib/` calls it.
- The empty state promises "Files you attach and files, images and pages Ovid creates will appear here."
- **Fix:**
  - Source the list from `GET /sessions/:id/artifacts` (paged), with the server id resolved per session. "All chats" should iterate the known server sessions, or use an account-wide route.
  - Fold `artifact_created` and the attachment ids into the projection.
  - Update `fileWritingTools` to the cloud names.
- **Emulator verification:** In a cloud chat, attach a PDF and ask the agent to "write hello.txt". Open Artifacts. Expect both entries; tap each and confirm the preview or download works.

### FE-005 [P1] Artifact URL re-mint always 404s for chats created on the device, so expired links get shared and opened
- **Files:** `lib/ui/artifact_preview.dart:97-112` (`freshArtifactUrl` passes `a.sessionId`, which is the LOCAL chat id); `lib/core/cloud/cloud_rest.dart:449-456` (no server-id resolution); `cloud/apps/gateway/src/routes/artifacts.ts:68` (`isUuid` returns 404)
- **Problem:** The 404 is swallowed and the stale presigned URL (about a 1 h TTL) is shared or opened. Recipients get an S3/R2 403.
- **Fix:** `mintArtifactUrl` should call `CloudSessionStore.I.resolveServerSessionIdAsync(sessionId)` first. Show an error instead of silently falling back to a URL that is known to be expired.
- **Emulator verification:** Attach a file, then wait more than 1 h (or shorten the TTL on staging). In Artifacts, long-press the file and Share. The shared URL's `X-Amz-Date` should be fresh and the download should succeed.

### FE-006 [P1] Image generation is gone end to end; only the legacy receipt screen remains
- **Files:**
  - `lib/core/image_studio.dart:443` (`inferResult`) and the `refresh`/`ensureFresh` capability-card fetch: **no callers** in `lib/`.
  - No code creates a `MsgKind.imageGen` message.
  - The `lib/core/image_task.dart` tool is unused.
  - The cloud worker registers no `generate_image` / `edit_image` tool, even though `cloud/packages/agent-core/src/presets.ts:68,112` and `loop.ts:257` list them.
  - `lib/ui/usage_screen.dart:235-260` still shows "Image receipts", backed by legacy mint headers.
- **Problem:**
  - Users cannot generate or edit images.
  - Capability cards are never loaded.
  - Agent presets advertise image tools that do not exist, so the model may try to call them.
  - The receipt screen is a confusing leftover that is always empty for new users.
- **Fix:**
  - Add worker tools `generate_image` / `edit_image` that call the image gateway (`/v1/images/*` on :8090 via LiteLLM keys) and emit `artifact_created`, folded client-side into an image row.
  - Or, if images stay a direct client feature, add a composer "Image" mode that uses `ImageStudio.ensureFresh` cards and `inferResult`.
  - Remove the tool names from presets until the tools exist.
  - Hide Image receipts while it has no data.
- **Emulator verification:** Ask "generate an image of a red bicycle". Expect an inline image card, an entry in Artifacts, and a receipt. Then "make it blue" should edit it.

### FE-007 [P1] Subagent view is unreachable and could not show a transcript anyway; Jobs is always empty
- **Files:**
  - `lib/ui/subagent_screen.dart:24-82`: only lists `CloudAgentFacade.jobsFor`.
  - `lib/core/cloud/cloud_agent_facade.dart:1409-1416`: `jobsFor` returns `const []`.
  - `lib/ui/chat_screen.dart:3771, 4131`: entry points need `m.toolSessionId`, which nothing sets (`grep toolSessionId` shows only the JSON decode at state.dart:516).
  - `cloud/packages/agent-core/src/subagents.ts:584-591` emits `subagent_started{childSessionId, childRunId, prompt}`; the client ignores it.
- **Problem:**
  - Subagent work is invisible.
  - The screen's "Background jobs" header is the wrong concept.
  - The Jobs popover from the chat menu is always empty.
- **Fix:**
  - Fold `subagent_started/completed` into a subagent card carrying `childSessionId`.
  - Make SubagentScreen load `/sessions/:childId/messages` and `/events` read-only.
  - Hide Jobs until `job_*` events exist.
- **Emulator verification:** Prompt "use a subagent to research X". A subagent card should appear; tapping it opens the child transcript, which updates live.

### FE-008 [P1] Browser takeover has no keyboard, so the main takeover use case (logins, 2FA, captchas, forms) is impossible
- **Files:** `lib/core/cloud/browser_stream.dart:418-423` (`sendKey`, never called); `lib/ui/browser_screen.dart` (no text field or IME hookup); server support exists in `cloud/packages/browser/src/input.ts:156-172` (`key` / `insertText`)
- **Fix:** while takeover is active, add a "Keyboard" button that focuses a hidden `TextField`. Send `sendKey('Insert', text: delta)` for text and `sendKey('Backspace'|'Enter'|'Tab')` for special keys. Also expose double-tap and long-press, which the server supports but the client does not.
- **Emulator verification:**
  1. Ask the agent to open a login page, open Browser, and take over.
  2. Tap the email field, open the keyboard and type.
  3. The characters should appear in the next frames; Enter submits.

### FE-009 [P1] Browser scroll is inverted and only applied when the finger lifts
- **Files:** `lib/ui/browser_screen.dart:318-331`
- **Problem:** The client sends `sendScroll(_drag.dx/scale, _drag.dy/scale)`. The worker applies `page.mouse.wheel(dx, dy)` (`input.ts:122-135`), where positive dy scrolls **down**. Dragging a finger down (dy > 0) therefore scrolls the page down, which is the opposite of touch convention. The single wheel on pan end also gives jumpy, laggy scrolling.
- **Fix:** send `-dx, -dy`. Emit throttled scroll events during `onPanUpdate` (for example every 50 ms). Include `x, y` so the wheel targets the element under the finger. Optionally use the server's `swipe` event.
- **Emulator verification:** Take over on a long page and swipe up. The page should move up (reveal content below) and track the finger.

### FE-010 [P1] Browser "Take over" gives no feedback, is shown when there is nothing to control, and has no ack timeout
- **Files:** `lib/ui/browser_screen.dart:333-363`; `browser_stream.dart:436-445`
- **Problem:**
  - The chip shows "Agent is driving — Take over" even when no page exists, on error, or while waiting.
  - Tapping it sends `browser_takeover` and nothing visibly happens until a `browser_state` ack, which never comes if no browser is live.
  - There is no spinner, disabled state or timeout message.
- **Fix:**
  - Show the chip only when `state?.live == true`.
  - Add a pending state with a spinner and a 5 s timeout ("Couldn't take control — try again").
  - When `state.live` is false, show "No live browser".
- **Emulator verification:** Open Browser in a chat that has no browser. The chip should be hidden. With a live page, tap Take over: a spinner shows, then the chip flips to "Release control".

### FE-011 [P1] Schedule notification taps open "Chat not found" for chats created on the device
- **Files:**
  - `cloud/apps/worker/src/notify.ts:327,352` (`scheduleRoute(a.sessionId)` carries the **server** UUID)
  - `lib/ui/app_router.dart:156-168` (`ScheduleRoute` calls `AppState.I.sessionById(serverId)`)
  - `lib/core/cloud/cloud_session_store.dart:420-438` (a mapped server row is kept under the LOCAL id, so lookup by server id fails)
  - The doc at `lib/core/cloud/push_service.dart:71` even claims the route is `/schedule/<scheduleId>`.
- **Problem:** Unlike `ChatRoute`, `ScheduleRoute` also has no reconcile wait, so a schedule's dedicated server session that has not synced yet also fails. The same server-to-local mismatch affects `ChatRoute` for mapped chats; the reconcile there still looks up by server id.
- **Fix:**
  - Add `CloudSessionStore.localIdFor(serverId)` (reverse map) and resolve it in both `ChatRoute` and `ScheduleRoute`.
  - Reuse `_openCloudChatWhenReconciled` for `ScheduleRoute`.
  - Fix the push doc.
  - Use "Schedule not found" copy for this route.
- **Emulator verification:**
  1. In a new chat, send "remind me in 6 minutes to stretch" and background the app.
  2. Tap the notification when it arrives.
  3. The Schedule screen for that chat should open, with the run shown.

### FE-012 [P1] Schedules: no create, no run-now, no run history, and the list only shows the active chat
- **Files:**
  - `lib/ui/schedule_screen.dart:58-79`: filters the account list to the active chat's server id.
  - `:117-126`: the empty state says "Ask the agent…" and there is no create button.
  - `lib/core/cloud/schedule_client.dart:315-334`: `runs()` is unused.
  - `create()` is unused by the UI.
  - Gateway: no run-now route (`routes/schedules.ts` has only CRUD and `/runs`).
  - `lib/ui/sidebar.dart:520-534`: Schedule is disabled with no active chat.
- **Problem:**
  - Schedules created in other chats, or in server-materialised dedicated sessions, can only be found by guessing the chat.
  - An unsent chat (unmapped local id) always shows empty.
  - The l10n message promises "Results appear here", but run history is never shown.
- **Fix:**
  - Add an account-wide "All schedules" view grouped by chat, with the per-chat filter as a toggle.
  - Add a "New schedule" sheet that reuses `_EditScheduleSheet` with `ScheduleClient.create`.
  - Add a "Run history" section that uses `runs()` and links each `runId` to its chat.
  - Add `POST /schedules/:id/run` on the gateway with a "Run now" menu item.
- **Emulator verification:**
  1. Create schedules in two chats and open Schedule from chat A: B's schedule appears under "All".
  2. Tap "+" to create a schedule without the agent.
  3. Run now: a new run row appears and the chat gets the output.

### FE-013 [P1] Failed schedules are a dead end
- **Files:** `lib/ui/schedule_screen.dart:944-951` ("Recovery needed"), `:1159` ("Failed · review before resuming"), `:991-1012` (Edit is disabled on terminal rows and Resume is only offered for `paused`); server `cloud/packages/db/src/scheduleService.ts:175-196` (failed is not editable and cannot be resumed)
- **Problem:** The UI tells the user to recover or resume, but offers no action that can do it.
- **Fix:** either allow `failed` to be resumed (`pending`) on the server, or offer "Duplicate as new schedule", which pre-fills the create sheet. Change the copy to match.
- **Emulator verification:** Force a failure (invalid prompt or a revoked key). The card should show a working recovery action.

### FE-014 [P1] (suspected) Sharing a chat from the sidebar shares nothing or a truncated history
- **Files:** `lib/ui/sidebar.dart:1173-1178` and `lib/ui/chat_overflow_menu.dart:192-197` pass `CloudAgentFacade.I.transcriptFor(s.id)`; `cloud_agent_facade.dart:1833-1834`; `conversation_share_service.dart:98-105`
- **Problem:**
  - For a chat whose projection has not been created in this process (not opened since launch), `transcriptFor` is null. The code falls back to the empty `session.messages`, so `withinLimits` is false and the user gets "Share 1–500 completed text messages…".
  - Even when the chat is open, only the paged-in window is shared. Older messages are silently omitted from the public link.
- **Fix:** before snapshotting, `await CloudSessionStore.I.loadTranscript(serverId)` (all pages, up to the 500-message limit), or snapshot server-side. Show "Sharing last N messages" when truncating.
- **Emulator verification:**
  1. Cold start, long-press a chat in the sidebar, then Share and Read only, then Create link. The link should be created.
  2. Open it in a browser; it should contain the full history (test with a chat of more than 60 messages).

### FE-015 [P1] Sidebar message search does not find anything in cloud chats; the FTS index is dead
- **Files:** `lib/core/state.dart:3859-3884` (searches the local `_kSessions` rows, which hold no messages for cloud chats); `lib/core/session_search.dart` (`SessionSearch.I` is only reset or deleted and never queried); server `cloud/packages/db/src/repos.ts:1963-2005` (`searchMessages` exists, but there is **no gateway route**)
- **Fix:** add `GET /cloud/v1/search?q=` backed by `searchMessages` and call it from the sidebar's debounced content search, with offline fallback to the cached transcripts. Delete the dead `SessionSearch` index.
- **Emulator verification:** Send a message containing "zebra42" in a chat. From the sidebar, search "zebra42": the hit shows that chat with a snippet, including after reinstall.

### FE-016 [P1] Prod shares and collab are served by the `ovid-gateway-account-dev` Python container, not the new gateway
- **Files:**
  - `/opt/ovid-gateway/caddy/Caddyfile:67-79` (`/chat* /shares* /s/*` go to 127.0.0.1:8080) and `:155-164` (ovidsi.com share links go to 8080).
  - `docker ps`: 8080 is `ovid-gateway-account-dev-1`.
  - The TS port in `cloud/apps/gateway/src/shares/routes.ts` is unreachable in prod.
  - Client defaults: `conversation_share_service.dart:126-130` and `collaboration/production.dart:144-151`.
- **Problem:**
  - There are two share implementations.
  - Account deletion in the TS gateway won't purge Python-held shares.
  - A dev service is on the production path.
- **Fix:** decide on one owner. Either point Caddy `/shares* /s/* /.well-known/assetlinks.json` to the TS gateway (8082) after migrating the share rows, or document the Python service as the prod owner and rename or harden it. Ensure the account purge covers whichever store is live.
- **Emulator verification:** Create a link, verify `GET https://ovidsi.com/s/<t>.json` is served by the gateway (check its logs), revoke it, and confirm a 404.

---

## P2: polish and robustness

### FE-017 [P2] Editing only the title of a schedule reschedules it
- **Files:** `lib/ui/schedule_screen.dart:404-426`; server `scheduleService.ts:217-218`
- **Problem:** `_save` always sends `trigger`. The server recomputes `nextRunAt` from "now" on any trigger patch, so renaming an hourly task pushes its next run out by an hour.
- **Fix:** send only the fields that changed (compare against `widget.schedule`).
- **Emulator verification:** Note "Next in 20m", rename the task, and check that it still says about 20m.

### FE-018 [P2] Schedule screen status, copy and live state
- **Files:** `lib/ui/schedule_screen.dart:166-191, 900-906, 1137-1153` and many hard-coded English strings (`'Edit schedule'`, `'One-off'`, `'Safe retries'`, `_fmtInstant` month table, and others)
- **Problem:**
  - The status strip is always a pulsing green "Cloud scheduling active", even when loading failed or the app is offline.
  - The pill shows the raw `status` (`pending`).
  - The `'running'` colour branch is unreachable.
  - There is no live refresh: the WS `schedule_*` system events are ignored (`grep schedule_ lib/core` finds nothing).
  - Dates are not localised.
- **Fix:**
  - Tie the strip to `_error` and the link state.
  - Map status to localised labels.
  - Subscribe to the system channel and reload on `schedule_*`.
  - Move the strings to ARB and use `MaterialLocalizations` / `intl` for dates.
- **Emulator verification:** Turn on airplane mode and open Schedule: no green "active". Then a run fires while the screen is open and the card updates without pull-to-refresh.

### FE-019 [P2] Schedule time zone cannot be changed
- **Files:** `lib/ui/schedule_screen.dart:247, 408-414, 478-481`
- **Problem:** The stored `tz` is always kept. After travel there is no way to switch a daily task to the device zone.
- **Fix:** add a "Time zone" row showing the stored zone and the device zone, with a "Use device zone" action.
- **Emulator verification:** `adb shell setprop persist.sys.timezone America/New_York`, then edit a daily task: the option is offered and the saved trigger carries the new tz.

### FE-020 [P2] Browser error, offline and new-chat states
- **Files:** `lib/ui/browser_screen.dart:113-127, 583-619`; `browser_stream.dart:301-321`
- **Problem:**
  - For an unsent chat, the local id goes on the wire and the gateway answers `forbidden "Session not found."`. The UI shows "Browser unavailable · Session not found · forbidden" (a raw code).
  - While the WS is offline, the last frame stays on screen as if live, with no "Reconnecting…" overlay.
  - All strings are hard-coded English.
- **Fix:**
  - When `knownServerIdFor` is null, show "Send a message first; the agent opens the browser."
  - Overlay a reconnect banner when `WsMultiplexer.linkState != online`.
  - Map error codes to friendly copy.
  - Localise the strings.
- **Emulator verification:** New chat, then the Browser icon: friendly message. With a live page, toggle airplane mode: a banner appears and the screen recovers after reconnect.

### FE-021 [P2] Trajectory labels and paging copy are wrong
- **Files:** `lib/ui/trajectory_screen.dart:110-121, 199-210, 266-267, 281-283`
- **Problem:**
  - `subagent_started` renders "Subagent started: ?" because the payload has `childSessionId` and `prompt`, not `agent`/`name`.
  - `subagent_completed` is always "succeeded" because the payload uses `status`, not `ok`.
  - An empty older page shows the error snack "Couldn't load earlier events." when there is simply nothing older.
  - An unsent chat shows "This session was not found on Ovid Cloud."
- **Fix:**
  - Read `prompt` and `status` from the payload.
  - Treat an empty page as the end (hide the button, no snack).
  - Use an empty state for unmapped chats.
- **Emulator verification:** Run a subagent and open Trajectory: correct labels. Tap "Load earlier" at the beginning: no error.

### FE-022 [P2] Artifacts screen: no loading state, and misleading "not on device" message for cloud files
- **Files:** `lib/ui/artifacts_screen.dart:39-50, 186-191`; `artifact_preview.dart:129-134`
- **Problem:**
  - The empty state renders while `_hydrate` is still running.
  - Workspace-relative generated files say "This file isn't on this device anymore" even though they live in the cloud workspace.
- **Fix:**
  - Track a `_loading` flag.
  - For relative paths, fetch the file via `GET /sessions/:id/workspace/file`.
- **Emulator verification:** Open Artifacts with many chats: a spinner shows, then the list. Share a generated `.md` file: it succeeds.

### FE-023 [P2] Leftovers from the on-device architecture
- `lib/ui/share_actions.dart:36-114`: `ChatShareButton` ("Share chat transcript", "Share local file…") is used only by tests.
- `lib/core/native_share.dart:46-71`: `transcript()` reads the empty `session.messages`.
- `native_share.dart:18-21`: the app share link is `https://dhanuk.page.gd/ovid` instead of ovidsi.com.
- `lib/core/session_search.dart`: the on-device FTS index.
- `lib/core/image_task.dart` and the `ImageStudio` inference/capability paths.
- The collab local-provider model picker (`collab_session_screen.dart:36-56`).
- `lib/core/state.dart:4279-4290`: "legacy agent loop" workspace resolution.
- `lib/ui/chat_screen.dart:1590-1601`: the chat header Studio button only shows the snack "Studio moves to the cloud in this build."
- `lib/core/session_artifacts.dart:210-215`: the old tool names.
- **Fix:** delete them, or rewire them to the cloud equivalents. Fix the share-app URL.
- **Emulator verification:** Settings, then Share Ovid: the link opens the ovidsi.com / Play listing.

### FE-024 [P2] Shared-conversation import drops repeated messages and uses a generic title
- **Files:** `lib/core/state.dart:4263-4267`
- **Problem:**
  - The duplicate check (same role and content anywhere in the session) silently drops legitimately repeated messages ("ok", "continue").
  - The title is always "Shared conversation".
- **Fix:** dedupe by index or fork id. Derive the title from the first user message.
- **Emulator verification:** Share a chat containing two "ok" messages, continue it, and count the rows.

### FE-025 [P2] (suspected) Collab panel: the sign-in card is unreachable in production
- **Files:** `lib/ui/conversation_share_sheet.dart:358-361`
- **Problem:** The condition is `!isSignedIn && widget.controller == null`. In production the controller is `AppState.I.collaboration`, which is non-null. A signed-out user therefore sees "Getting your account ready…" forever.
- **Fix:** drop the `controller == null` clause.
- **Emulator verification:** Sign out (if the gate allows), open Share and choose Collab: the sign-in card shows.

### FE-026 [P2] (suspected) Browser takeover is session-wide, not per viewer
- **Files:** `browser_stream.dart:390-395` (`_takeoverActive = state.takeover`); `cloud/packages/browser/src/engine.ts:443-470`
- **Problem:** If a second device or tab views the same session, both show "You are controlling the browser" and both can inject input.
- **Fix:** carry a `takeoverViewerId` in `BrowserStateDto`, compare it against this socket's viewer id, and show "Controlled on another device" otherwise.
- **Emulator verification:** Open the same chat's browser on two emulators, take over on A: B shows a read-only banner.

---

## Reachability summary

| Screen | Entry point | Opens | Works end to end on cloud |
|---|---|---|---|
| Browser | chat header globe, `/browser` route | yes | view: yes; input: partial (FE-008/009/010) |
| Schedule | sidebar footer, push `/schedule/<id>` | yes (sidebar); push broken (FE-011) | list/edit/pause/resume/cancel yes; create, run-now and history missing (FE-012/013) |
| Artifacts | sidebar, chat menu | yes | empty for cloud chats (FE-004) |
| Share (read-only) | chat menu, sidebar long-press | yes | create/list/revoke/update via legacy service (FE-016); sidebar path is suspected broken (FE-014) |
| Shared viewer `/s/<t>` | App Link, deferred referrer | yes | view yes; Continue loses context (FE-003); Report broken (FE-001) |
| Collab | share sheet, `/s/<t>/<invite>` | yes | join/leave/members via legacy `/chat`; sending is broken (FE-002) |
| Trajectory | sidebar, chat menu | yes | yes (label bugs, FE-021) |
| Subagent / Jobs | tool-card link (never rendered) | unreachable | no (FE-007) |
| Content report | message long-press, viewer flag | yes | never succeeds (FE-001) |
| Image studio | none | none | removed (FE-006) |
| Image receipts | Usage menu | yes | legacy only (FE-006) |
| Content search | sidebar search | yes | local rows only (FE-015) |
