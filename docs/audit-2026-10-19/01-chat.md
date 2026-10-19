# 01 — Chat (Ovid SI Android, branch feat/ovid-cloud @ fdf2c5f)

Scope: lib/ui/chat_screen.dart and companions, lib/core/cloud/* client, traced against
cloud/apps/gateway, cloud/apps/worker, cloud/packages/{shared,agent-core,storage}.
All findings are from reading the code. "Suspected" means a code-path inference I did not
reproduce on a device. The severity scale and emulator steps follow the brief.

Severity: P0 = crash, data loss, security, or blocks a core flow. P1 = feature broken or
misleading. P2 = polish.

---

## A. Wire contract: send → stream → render → tools → approvals → cancel → retry → reload

### CH-001 — P0 (security/trust) — The mode chip ("Read-Only / General / Full Access / Studio") has no effect on the server
- **Where:** lib/core/cloud/cloud_agent_facade.dart:757 (`_rest.patchSession(serverId, mode: next.name)`); cloud/packages/db/src/repos.ts:262-285 (`sessions.update` writes only the `sessions.mode` column); cloud/apps/worker/src/runProcessor.ts:1736 (`const mode = job.data.mode ?? sessionState.mode ?? "auto"`); repos.ts:1911-1924 (zero state `mode: "auto"`).
- **Problem:** The client PATCHes `sessions.mode`. The worker reads `session_agent_state.state.mode`, and only the server `/permission` slash command writes that (agent-core/src/commands.ts). The gateway's job payload never carries `mode` (gateway/src/routes/messages.ts:300-320). Every cloud run therefore executes in "auto" (General). A user who picks **Read-Only**, whose hint promises "Asks for permission before every shell, browser, or write action" (models.dart:417), gets no approvals.
- **Evidence:** `sessions.update(...) set.mode = fields.mode` touches no agent state. The worker never reads `sessions.mode`. The messages route enqueues `{runId, sessionId, userId, prompt, tier, attachmentIds?, maxOutputTokens?}` with no mode.
- **Fix:** Server: make PATCH /sessions/:id `mode` also `sessionState.patch(sessionId, {mode})` in the same transaction, or put `mode: session.mode` on the job payload so `job.data.mode` wins. Add a gateway test asserting that a PATCHed mode reaches `runProcessor`'s `mode`. Client: no change needed once the server honours it. Until then, hide or disable the chip.
- **Verify:** On the emulator, set the chip to Read-Only and send "create a file test.txt with hello". Today the file is written with no approval card. After the fix an approval card appears.

### CH-002 — P0 (core flow) — Reopening a chat while a run is still in flight never shows the answer
- **Where:** lib/core/cloud/event_projection.dart:484 (delta epoch gate) and :501 (`if (target._activeRunId == null) return;` in `_onMessageCompleted`); lib/core/cloud/cloud_session_store.dart:531 (cursor read from the WS prefs cursor); cloud_ws.dart:857 (cursor persisted on every event, including mid-run deltas).
- **Problem:** The WS replay cursor is persisted per event. After process death mid-run (common on Android: the user starts a long agent task and leaves), the next `loadTranscript` seeds the REST page (user message only) and resumes the replay strictly after the persisted cursor. `run_started` is below the cursor, so it is never replayed and `activeRunId` stays null. Every later `message_delta` is dropped by the epoch gate, and `message_completed` is dropped by the null-run guard. The answer never renders, `busy` stays false (no Stop button; a new send queues server-side behind the invisible run), and `_cloudTranscriptsLoaded` (chat_screen.dart:1089) stops a re-fetch for the rest of the screen's life. Only a full app restart after the run finishes shows the answer.
- **Fix:** (a) In `_onMessageCompleted`, when no run is active, append or replace by `messageId` instead of returning (the messageId dedupe already exists). (b) In `_onMessageDelta` with no live bubble but a runId, lazily arm a bubble and set `activeRunId`/busy (an implicit `run_started`). (c) Better: have `GET /sessions/:id/messages` also return the active run (`runs.activeForSession`) and its `run_started` seq, so the client seeds `busy` and resumes the replay from that run's start.
- **Verify:** Send "count slowly to 200, one number per line" (or a multi-tool task). After the first tokens, `adb shell am kill com.ovid...` (or swipe away and force-stop), then reopen the chat while the run is live. Today there is no streaming, no final answer, and no Stop button.

### CH-003 — P0 (history integrity) — First open of a chat on a new device or after reinstall replays the whole event log on top of the REST page, piling stale rows at the bottom
- **Where:** cloud_session_store.dart:531 (`cursor = await _ws.cursorFor(...)` is null for a never-seen session) then `seedTranscript(..., cursor=null)`; cloud_ws.dart:448-452 (`subscribe` sends `lastEventId: null`); gateway/src/ws.ts:543 (`readSince(sessionId, null, 500)` replays from the beginning); event_projection.dart:541-560 (`_replaceLiveBubble` appends at the tail when the messageId is not in the seeded page), :583-602 and :604-611 (every replayed `run_failed`, `run_cancelled` and `system_note` appends a turn-tail row at the end); cloud_agent_facade.dart:538-588 (replayed terminals call `_recordError` and drain the queue).
- **Problem:** Every server session that `refreshSessions` pulls in (all history after login on a new phone, or after clear-data) has no cursor. Subscribing replays up to 500 events, then mirror catch-up of up to 5,000. Effects:
  - Assistant answers older than the 50-row REST page are re-appended at the bottom, out of order. Later `prependTranscript` skips them as known, so they stay at the bottom.
  - Every historical "Stopped by user." or error row piles up under the latest turn.
  - If the last historical run failed, the red error banner shows for it.
  - Thousands of delta events are folded on open, which is costly.
- **Fix:** Make the REST snapshot carry a watermark. Either return `lastEventSeq` with `GET /sessions/:id/messages` (the `session_event_mirror` max seq at read time), or call `GET /sessions/:id/events?tail=1&limit=1` before subscribing and seed the cursor with that seq. Never subscribe with `lastEventId: null` for a session that has a REST snapshot. Also gate side effects (`_recordError`, `_drainQueue`, stall watchdog) on live, not replayed, events: tag events that arrive before the `subscribed` ack's replay ends.
- **Verify:** Create a chat with more than 30 turns, including one stopped run and one failed run, on emulator A (or before clearing data). Clear app data, sign in, and open the chat. Today old answers and "Stopped by user." rows appear below the newest turn.

### CH-004 — P1 — Tool calls, artifacts, todos, plan-mode, subagent and compaction events are dropped by the projection (the chat shows no agent activity)
- **Where:** event_projection.dart:396-452 (the `apply` switch handles only run_*, message_*, system_note and approval_*; `default:` at :438 drops everything else); the library doc at :29-35 says so explicitly. Server emitters: agent-core/src/loop.ts:1088 (`tool_started {runId, callId, name, args, input}`) and :1345 (`tool_completed {runId, callId, name, ok, isError, content, truncated}`); storage/src/artifacts.ts:200 (`artifact_created {artifactId, name, sizeBytes, contentType, url, expiresAt}`); tools/goalsTodos.ts:112/146 (`todo_updated`, `goal_updated`); loop.ts:751 (`plan_mode_changed`); subagents.ts:584/680; compaction/compactor.ts:514.
- **Problem:** The UI has full renderers (`_ToolCard` chat_screen.dart:3577, `_SubagentCard` :3844, `_CompactionRow` :5019, `_TodoDock` :7757, `_GoalBar` :7580, `_ProducedFilesCard` :5105, `HtmlArtifactView`), but nothing feeds them on the cloud path. During a 3-minute multi-tool run the user sees one bubble with no indication of what is happening, files the agent created never appear, the todo dock never updates, and the plan chip goes stale after `exit_plan_mode`. Only the separate trajectory screen (lib/ui/trajectory_screen.dart:181-281) knows these events.
- **Fix:** Add fold rows:
  - `tool_started` → insert a `MsgKind.tool` row keyed by `callId`, positioned before the live bubble, with the bubble re-armed after it.
  - `tool_completed` → set `toolDetail`, `toolSummary` and an error flag on that row.
  - `artifact_created` → a produced-file or artifact row holding `artifactId`; mint fresh URLs through `CloudRestClient.mintArtifactUrl`.
  - `todo_updated` and `goal_updated` → `ChatSession.todos` / `goal`.
  - `plan_mode_changed` → `session.planMode`.
  - `subagent_*` → `SubagentInfo`.
  - `compaction_completed` → `MsgKind.compact`.
  Persist these rows or rebuild them from `/sessions/:id/events` on reload (see CH-006).
- **Verify:** Ask "create hello.py that prints hi, run it, then show me the output". Today there is no tool card, no file card, and only the final text.

### CH-005 — P1 — Multi-turn runs concatenate intermediate assistant text into one bubble, then the text vanishes when the run completes
- **Where:** event_projection.dart:491 (`live.content = live.content + text` across all turns of a run); :501-525 (`message_completed` replaces the bubble with `payload.content`); agent-core/src/loop.ts:779 (deltas for every turn), :1063 (`message_completed` carries only the FINAL turn's `content`), :1078 (intermediate turn text is pushed only into in-memory `msgs`).
- **Problem:** Turn 1 streams "Let me look at the repo.", tools run (invisible, CH-004), then turn 2 streams "Here is the summary..." directly after it with no separator ("repo.Here is"). On `message_completed`, the bubble is replaced with the turn-2 text only, so the turn-1 text the user just read disappears. Reloading shows only the final text (CH-006).
- **Fix:** On `tool_started`, close the current bubble as a settled text row (if non-empty), insert the tool row, and arm a fresh streaming bubble. `message_completed` then replaces only the last bubble. Server side, persist intermediate assistant text (with `toolCalls` metadata) as messages, or rely on the event mirror for reload.
- **Verify:** Same prompt as CH-004. Watch the bubble: text joins without a separator, then the first part disappears at completion.

### CH-006 — P1 — History reload shows only user prompts and final answers; tool activity, intermediate text, errors and attachment chips are lost
- **Where:** cloud_session_store.dart:600-610 (`_messageFromDto`: kind text only); agent-core/src/loop.ts:1058 (the only `messages.append` for the assistant); shared/src/rest.ts `MessageDto` (no attachments, no tool calls); cloud_agent_facade.dart:1032-1037 (the optimistic user row has no `attachments`).
- **Problem:** Live rows differ from reloaded rows. Turn-tail errors and "Stopped by user." appear live and vanish after reopening. User attachment chips never render, even live. A cloud chat cannot show what the agent did.
- **Fix:** Build reload from `GET /sessions/:id/events` (the mirror already stores every event; trajectory_screen.dart uses it), or persist tool and system rows server-side. Include attachments in `MessageDto` (join `attachments` by prompt message) and in the optimistic row (`MessageAttachment(name, size)`).
- **Verify:** Run a tool task with an image attachment, then reopen the chat after an app restart. The image chip, tool rows and error rows are gone.

### CH-007 — P1 — The model picker and the "/model" command never reach the server: every run uses the fleet default model
- **Where:** chat_screen.dart:2523 (`_modelPicker` → `AppState.setModel`, state.dart:4623, local only); cloud_rest.dart `sendMessage` (body is `content, attachmentIds, clientMsgId, maxOutputTokens`); shared/src/rest.ts `sendMessageBodySchema` (strict, no model); worker runProcessor.ts:1670-1680 and agent-core/src/loop.ts:629 (route from `sessionState.modelPin`, set only by the server-side `/model <id>` command, agent-core/src/commands.ts:294); lib/core/commands.dart:260-291 intercepts `/model` client-side and never forwards it.
- **Problem:** The header shows the chosen model, while billing, quality and vision support follow `cfg.defaultModel`. The model-compare view, effort variants, context ring (model_limits.dart) and the vision warning are all computed for a model that is not used. This is misleading and a billing-trust issue.
- **Fix:** Add `model` to the send body (server: validate against the catalog, set `modelPin` or put it on the job), or add `modelPin` to `PATCH /sessions/:id`. Echo the effective model back (e.g. on `run_started` as `{runId, model}`) and render it on the answer's stats line.
- **Verify:** Pick a non-default model and send "which model are you?". Check the LiteLLM or worker log on the VPS (`docker logs` for the worker): the routed model is the default.

### CH-008 — P1 — Plan mode and presets are client-only bits
- **Where:** cloud_agent_facade.dart:1269-1277 (`planMode` setter only sets `session.planMode`); lib/core/commands.dart:175-257 (`/plan` strips the prefix and sends the bare text; `/preset` writes `s.presetId` locally); server: commands.ts `case "plan"`, runProcessor.ts:1669 `presetById(sessionState.presetId)`.
- **Problem:** The Plan chip and `/plan` never put the server into plan mode, so the agent writes files while the UI says "Plan". Presets ("code", custom presets) never change the roster, persona or temperature, yet the UI says "Applies from your next message".
- **Fix:** Forward `/plan …` verbatim (drop the client handler) and drive `session.planMode` from `plan_mode_changed` (CH-004). Add `presetId` to the session PATCH schema and its server state write, or hide presets.
- **Verify:** Toggle Plan, ask "create a.txt". The file is created. `/preset code`, then ask the agent to browse: it still can.

### CH-009 — P0 (data loss) — The offline outbox permanently drops prompts on a timeout, 429 or 401
- **Where:** lib/core/cloud/cloud_session_store.dart:852-873.
- **Problem:** The keep-and-retry branch is `e.status >= 500 || e.status == 402`. Everything else is "Other 4xx: this prompt can never succeed — drop it". That includes:
  - `CloudApiException(status: 0, code: 'timeout')`, which cloud_rest.dart:236-247 throws when the gateway does not answer within 30 s (a flaky mobile link);
  - 429 `rate_limited`, which the gateway relays from mint (messages.ts:146);
  - 401 `unauthenticated`, when the force-refreshed token also fails, e.g. an expired session mid-flush.

  The user's composed prompt is deleted from the persisted outbox, and the only trace is the error chip.
- **Fix:** Retain on `status == 0`, `408`, `425`, `429`, `401/403` (with re-auth) and any 5xx. Drop only on 400, 404 and 413. The `clientMsgId` already makes retries idempotent. For 429 honour `x-ovid-resets-at` or `retry-after`.
- **Verify:** With airplane mode on, queue a prompt. Turn the network on but throttle it to 1 kbps (emulator: `adb emu network speed gsm` plus `network delay umts`) so the POST exceeds 30 s. The outbox entry disappears and "did not answer within 30s" shows.

### CH-010 — P1 — `clientMsgId` is regenerated on every attempt, so idempotency never protects a user retry (double runs, double charge)
- **Where:** cloud_agent_facade.dart:1026 (`clientMsgId: _newClientMsgId()` inside `runTask`); chat_screen.dart:2381-2387 (`_retryFailedCloudPrompt` → `runTask` again).
- **Problem:** If the POST times out (status 0) after the gateway enqueued the run, the composer keeps the text and the user taps Send or Retry again. A new key creates a second message and a second run, and both are billed. The server's whole replay machinery (messages.ts:30-80) is unused for live sends.
- **Fix:** Mint the key when the user presses Send and keep it with the draft (and with the queued or failed prompt) until the send is acknowledged. Retries reuse it.
- **Verify:** Throttle the network as in CH-009, send, wait for the timeout error, then tap Send again. Two user rows and two answers appear on reload.

### CH-011 — P1 — The optimistic user row is appended only after uploads and the POST, and can land below the assistant's first output
- **Where:** cloud_agent_facade.dart:1011-1037.
- **Problem:** (1) With attachments, the prompt text stays in the composer and nothing appears in the transcript until every file is uploaded sequentially (up to 120 s per file) and the POST returns, with no progress indicator. (2) The WS `run_started` (and for slash commands, `message_completed`) can arrive before the HTTP 202 is processed. The live bubble is then appended first and the user row lands under it, so the conversation reads answer-then-question. Suspected race; it is most likely for server slash commands (worker prePass at runProcessor.ts:1941 emits without a model call).
- **Fix:** Insert a pending user row (with attachment chips and a "sending/uploading x%" state) before the uploads, keyed by `clientMsgId`. Swap in `userMessageId` on the 202, mark it failed with Retry on error, and on `run_started` always keep the bubble after the pending user row.
- **Verify:** Attach a 20 MB file and send on a throttled network: nothing appears for a long time. For the race, send `/todo` repeatedly on a slow link and look for an assistant row above its prompt.

### CH-012 — P1 — `ensureServerSession` failures other than `CloudApiException` escape `runTask` (new chat plus network error = silent failure)
- **Where:** cloud_agent_facade.dart:966-981 (only `on CloudApiException`); cloud_session_store.dart:337-349 (`_rest.createSession` can throw `ClientException`/`SocketException`, since `_raw` converts only `TimeoutException`).
- **Problem:** On a brand-new chat with DNS failure or a connection refused (the `ConnectionService` probe has not yet flipped to offline), `runTask` throws. `_sendPrompt` calls it with `unawaited`, so the error is unhandled: no error row, no outbox entry, and the prompt is neither sent nor queued. A `CloudApiException(timeout)` at create is also recorded and not enqueued, so new chats are never offline-capable.
- **Fix:** Catch all exceptions around `ensureServerSession`. On a network-class failure, enqueue to the outbox under the local id (the outbox flush already creates the server session) and treat the send as accepted-and-queued.
- **Verify:** Turn off Wi-Fi and data quickly (before the probe notices), create a new chat, and send. Nothing happens and no error appears. `adb logcat | grep -i unhandled` shows the exception.

### CH-013 — P1 — Server title is fixed at "New chat" and later overwrites the local auto-title
- **Where:** state.dart:4176-4179 (new session `title: 'New chat'`); cloud_session_store.dart:339-343 (create sends `session?.title`, which is "New chat"); chat_screen.dart:2363-2367 (auto-title set locally after the send, never PATCHed); cloud_session_store.dart:473 (`_applyDto` overwrites with any non-empty server title); cloud_agent_facade.dart:1684 (`regenerateSessionTitle` is a no-op).
- **Problem:** After the next `refreshSessions` (app start, resume), every chat in the sidebar reverts to "New chat", and other devices only ever see "New chat". This makes the history list unusable.
- **Fix:** Create the session with `title: null` (or the auto-title of the first prompt) and PATCH the auto-title through `renameSessionIfInstalled` after the first accepted send. Better: generate titles server-side after the first run.
- **Verify:** Send a first prompt in a new chat (the sidebar shows the auto-title). Kill and relaunch the app: the title is "New chat".

### CH-014 — P1 — Sessions are never unsubscribed; past 64 visited chats new subscriptions fail with `too_many_subscriptions`, and every reconnect replays all of them
- **Where:** cloud_agent_facade.dart:381-462 (`_stateFor` subscribes; only `dropSession` and `resetAccountState` unsubscribe); cloud_ws.dart:626-630 (re-subscribes every registered session on each connect); gateway/src/ws.ts:249 (`MAX_SUBSCRIPTIONS_PER_CONNECTION = 64`).
- **Problem:** Browsing history grows the set without bound. Once past 64, opening a chat gives a session-scoped `error{too_many_subscriptions}`, which shows in the red error row, with no live updates. Each reconnect (every heartbeat timeout or network flip) sends N subscribes and N replays.
- **Fix:** Keep the active session, sessions with a live run, and sessions with a pending approval subscribed, with an LRU cap of about 16. Unsubscribe the rest when the user switches away (the server keeps the events, and the cursor makes re-subscribe cheap).
- **Verify:** Script 70 chats (import or create), open each in turn, then open a new one and send. The error row shows `too_many_subscriptions`.

### CH-015 — P1 — The terminal-time cache write saves a stale cursor; offline seeding rewinds the replay and duplicates turn-tail rows and errors
- **Where:** cloud_agent_facade.dart:593-604 (`persistTranscript(..., store.cachedCursorFor(serverId))` is the cursor from the last REST load, not the live WS cursor); cloud_session_store.dart:583-592 (`_seedFromCache` → `seedTranscript(messages, staleCursor)`); cloud_agent_facade.dart:1754-1764 and cloud_ws.dart:398-402 (`seedCursor` overwrites the persisted WS cursor with the stale one).
- **Problem:** The cache holds messages up to turn N but a cursor from turn 1. On a cold start that is offline (or where the REST page fails), the projection is seeded and the cursor rewinds. On reconnect every event since turn 1 is replayed. `message_completed` is deduped, but every `run_failed`, `run_cancelled` and `system_note` is appended again, and replayed terminals re-record errors.
- **Fix:** Persist the WS cursor (`await _ws.cursorFor(serverId)`) together with the projection at terminal time. Never let `seedCursor` move a cursor backwards (compare with `compareSeq`).
- **Verify:** Run two turns, one of them stopped. Kill the app, start it offline, open the chat, then go online. A duplicate "Stopped by user." row appears.

### CH-016 — P1 — A merged queued run (`system_note{code:"run_merged"}`) leaves the client stuck busy
- **Where:** agent-core/src/steering.ts:70-80 (a queued run is finished as `completed` and only `system_note{code:'run_merged', mergedRunId, runId}` is emitted, with no run_started or terminal for it); cloud_agent_facade.dart:1039-1044 (`runState = CloudRunState(runId: response.runId, busy: true)`, `queuedBehindActiveRun = true`), :488-520 (`_busyForRun` stays true until that run's own terminal); cloud_session_store.dart:817-873 (the outbox flush POSTs entries back-to-back while run 1 is active).
- **Problem:** When two prompts reach the server while a run is active (outbox flush of more than one entry, a second device, or a send racing the busy flip), the server steers the second into the active run. The client tracks the second runId, which never emits a terminal. The composer shows Stop forever, the local queue never drains, and the `run_merged` note renders as an empty row (CH-018). Suspected; the flush path makes it likely.
- **Fix:** Fold `system_note` with `code == 'run_merged'`: if `mergedRunId` equals the tracked run, settle it (busy false, set `terminalSettledRunId`). Have the outbox flush send one entry per terminal, as the facade's in-memory queue does.
- **Verify:** Go offline, queue three prompts, then go online. After the first run completes, the Stop button stays.

### CH-017 — P1 — Approval card loses the `kind`, the plan body, the expiry and any refusal note; an optimistic dismiss can strand the run
- **Where:** cloud_agent_facade.dart:1214-1227 (`ApprovalRequest(...)` drops `kind` and `expiresAt`, and sets no `planBody`), :1195-1199 (`note` dropped), :1243-1264 (card removed before `sendRaw`, which is fire-and-forget); cloud_ws.dart:897-920 (`approval_ack` goes to the raw lane, nobody listens).
- **Problem:**
  - A `kind: "plan"` request (`exit_plan_mode`, roster.ts:236) renders as a generic tool Allow/Deny, not the plan-review card.
  - There is no countdown, although the bridge auto-denies at `expiresAt`. The user can answer after the deny and get no feedback.
  - If the frame is dropped (the outbound queue is capped at 32 frames, cloud_ws.dart:54) or the gateway answers `error{unavailable}`, the card is already gone and the run sits blocked until the timeout-deny.
- **Fix:** Carry `kind`, `expiresAt` and `planBody` (parse the detail after the first blank line) into `ApprovalRequest`, and render a countdown. Keep the card in a "sending…" state until `approval_ack` or `approval_resolved`; restore it on `error` for that approvalId or after a 5 s timeout. Remove the note UI or extend the wire.
- **Verify:** In plan mode, let the agent call `exit_plan_mode`: a generic card appears. Approve with airplane mode on, then go online. The run stays blocked until the timeout.

### CH-018 — P2 — `system_note` payloads mostly render as blank turn-tail rows
- **Where:** event_projection.dart:604-611 (reads only `text` or `message`, else `''`); chat_screen.dart:5313-5333 (renders a clock icon plus empty text, and the action row still renders).
- **Problem:** Several emitters send neither field:
  - `hook_block_ignored {reason}` (loop.ts:901)
  - `run_merged` (steering.ts:76)
  - schedule boundary notes `{scheduleId, status}` (schedulerSettle.ts:246, 357)
  - hibernate `{code}` (storage/hibernate.ts:723)
  - warmLru notes
- **Fix:** Map known codes to copy (`run_merged` → "Merged your follow-up into the running task", schedule → "Scheduled run finished", hibernate → "Workspace paused"). Drop notes with no displayable text instead of rendering empty rows.
- **Verify:** Trigger a scheduled run into a chat, or merge two prompts as in CH-016. An empty row with a clock icon appears.

### CH-019 — P1 — `run_failed` codes surface as raw identifiers or provider stack text, twice
- **Where:** event_projection.dart:651-660 (`humanText` maps only `cancelled` and `key_not_minted`); chat_screen.dart:8045-8052 (the error row shows the server message verbatim, else the code); cloud_agent_facade.dart:568-575 (also records the same failure as the banner error).
- **Problem:**
  - `run_lost`, `run_queue_wait_timeout` and `tool_rounds_exhausted` render as bare snake_case.
  - `model_terminal` and `model_transient_exhausted` (full processor) render raw LiteLLM or provider prose, e.g. "litellm.BadRequestError: …".
  - Each failure appears twice: an inline turn-tail row and the red banner.
  - Generic network errors render `'$e'` (e.g. "ClientException with SocketException: Failed host lookup…", cloud_agent_facade.dart:1067).
  - Retry exists only for `unavailable`/`internal` send errors, not for failed runs. The user must retype, because Regenerate is dead (CH-024).
- **Fix:** Build a `code → {title, body, action}` table: `run_lost` → "The task was interrupted. Retry?"; `model_*` → "The model provider failed. Try again or pick another model"; `rate_limited` → retry-after; `timeout`/network → "Connection problem" plus Retry. Keep raw text behind a "Details" expander. Show one surface per failure (inline row with a Retry action; drop the duplicate banner for run-level failures). Wire Retry to re-send the last user prompt (same session).
- **Verify:** Force a provider error (point LiteLLM at an invalid model, or kill the worker mid-run to get `run_lost` after the stale sweep). Read the inline and banner text.

### CH-020 — P2 — Stopping before the worker claims the run shows a red error banner "Stopped by user."
- **Where:** gateway/src/routes/runs.ts:73-79 and worker runProcessor.ts:764 (queued cancel emits `run_failed{code:'cancelled'}`, not `run_cancelled`); cloud_agent_facade.dart:570-576 (`run_failed` with a code → `_recordError`).
- **Problem:** The facade treats `run_cancelled` as a non-error, but the queued-cancel spelling `run_failed{cancelled}` is recorded as an error. A quick Stop leaves a red banner with Dismiss for a user-initiated action.
- **Fix:** In `_onTerminalEvent`, treat `run_failed` with `code == 'cancelled'` exactly like `run_cancelled` (call `_clearError`).
- **Verify:** Send and tap Stop within about 300 ms. The red "Stopped by user." banner appears.

### CH-021 — P2 — The replay cursor is written to SharedPreferences on every streamed token
- **Where:** cloud_ws.dart:857 (`_persistCursor` per accepted event; `message_delta` is one event per token chunk).
- **Problem:** On Android, each `setString` rewrites the whole prefs XML. At 30–80 deltas per second this causes I/O churn, battery drain, and jank on low-end devices during long answers.
- **Fix:** Debounce cursor persistence (e.g. every 2 s and on terminal events, pause and detach), and keep the in-memory cursor authoritative.
- **Verify:** Stream a long answer with `adb shell dumpsys gfxinfo <pkg>` and the Studio CPU and I/O profiler. Look for many prefs writes per second.

### CH-022 — P2 — Attachment limits disagree with the server, and failures happen only at send time
- **Where:** cloud_agent_facade.dart:1326 (`25 * 1024 * 1024` = 26,214,400 bytes, and 0-byte files allowed); gateway/src/routes/attachments.ts:23 and :38 (`ATTACHMENT_MAX_BYTES = 25_000_000`, `size: positive()`); cloud_agent_facade.dart:1011-1020 (sequential uploads, the whole file read into memory, every file re-uploaded on each retry, orphan uploads when the POST fails).
- **Problem:** Files between 25.0 and 26.2 MB, or empty files, stage fine, then fail the send with "Attachments are limited to 25000000 bytes.". During a long upload the Stop button does nothing (`stopRequested` returns false because there is no runId yet).
- **Fix:** Use `25000000` and `size > 0` at staging time. Upload at staging time, in parallel with progress, and keep `attachmentId`s so a retry does not re-upload. Make Stop cancel in-flight uploads.
- **Verify:** Attach a 25.5 MB file. It stages OK, then the send shows the 400.

### CH-023 — P1 — The in-memory composer queue is lost on process death
- **Where:** cloud_agent_facade.dart:220-227, :1460-1480 (`_queues` is a plain map; only the offline outbox is persisted).
- **Problem:** Messages typed while a run is busy show in the queue dock. If Android kills the app (or the user swipes it away) before the run ends, they are gone. Attachments ride with them.
- **Fix:** Persist the online queue in the same store as the outbox (same account stamping), or POST immediately and let the server's FIFO/steering own ordering, tracking `queuedBehindActiveRun` per run.
- **Verify:** Start a long run, queue two messages, force-stop the app, and reopen. The queue is empty.

## B. Message actions and leftovers of the on-device architecture

### CH-024 — P1 — Edit & resend, Delete message, Regenerate and Branch show on cloud chats but silently do nothing
- **Where:** chat_screen.dart:5464-5481, 5539-5610, 5669-5676 (`_canChangeHistory` requires `session.messages[msgIndex]`, but cloud sessions keep `ChatSession.messages` empty, :1263-1269); state.dart:4215-4240 (`branchSessionFrom` over empty `src.messages` → null).
- **Problem:** Every handler returns early with no snackbar. Regenerate also checks for a local provider ("Set up a provider for this chat before regenerating", :5578) and `provider.models.contains(session.model)`, both leftovers. There is no server truncate API.
- **Fix:** Hide these actions for cloud sessions now. Then add a server `POST /sessions/:id/messages/:messageId/regenerate` (or truncate plus re-send) and a fork via `/import/sessions`, and implement Regenerate as a cloud re-send without the local-provider checks.
- **Verify:** On the last turn of a cloud chat, tap Regenerate, Edit & resend, or "…" → Branch. Nothing happens.

### CH-025 — P1 — Client slash commands intercept server commands or lie
- **Where:** lib/core/commands.dart: `/compact` at 141-170 (claims "managed by Ovid Cloud" and sends nothing; the server implements it at runProcessor.ts:1913); `/clear` at 120-138 (truncates the empty local list and says "Session cleared."); `/export` at 340-352 and 412-445 (exports empty `s.messages` to an app-private temp path); `/feedback` at 355-372 (writes a local `feedback.log` nothing uploads); `/model`, `/plan` and `/preset` (CH-007, CH-008).
- **Fix:** Forward `/compact`, `/plan`, `/model`, `/permission` and `/todo` verbatim to the server. Make `/clear` start a new chat. Build `/export` from the projection or server pages and share it via the share sheet. POST `/feedback` to gateway `/reports` or remove it.
- **Verify:** `/clear`, then "what did I just ask?": the model remembers. `/compact` in a long chat produces no compaction event.

### CH-026 — P0 (data loss) — "Reset all data" recursively deletes the user's pinned Studio folder on shared storage
- **Where:** lib/core/settings_state_integration.dart:44-61 (`_workspaceDeleter(sandboxId)` for each session, before `sessions.clear()`); state.dart:1146-1165 (`localWorkspaceDirFor` returns the pinned `workspaceFolder`) and :1166-1173 (`dir.delete(recursive: true)`); state.dart:1310-1324 (`workspaceDirProvider`); the folder is pinned via the Studio folder chip (chat_screen.dart:9042-9310), and new chats inherit it (state.dart:4192).
- **Problem:** A user who picked e.g. `/sdcard/Documents/project` loses the whole folder when resetting app data. The cloud agent never even used that folder (CH-027).
- **Fix:** Delete only app-owned scratch dirs (`${systemTemp}/ovid_workspaces/<id>`) and never follow `workspaceFolder`. Remove the folder-pinning feature on the thin client.
- **Verify:** Studio mode → folder chip → pick `/sdcard/Documents/t` with files → Settings → Reset all data → `adb shell ls /sdcard/Documents/t`. The folder is gone.

### CH-027 — P1 — Studio "Sandbox folder" chip, the header Studio button and @file mentions are leftovers that mislead
- **Where:** chat_screen.dart:9042-9310 (`_StudioFolderChip` picks a local Android dir, with copy "Sandbox folder (Studio)" and "Working in the session sandbox."); :1590-1601 and :9223-9228 (header `</>` and "Open Studio" show only a snackbar, "Studio moves to the cloud in this build.", although lib/ui/studio_screen.dart exists unreferenced); :6524-6560 (`_loadMentionFiles` always empty: "no files yet"); :6729-6745 (`@session:<localId>` inserted, which the server cannot resolve).
- **Fix:** Remove the folder chip. Push the existing cloud `StudioScreen` (or hide the button). Populate `@file` from `studio_files.dart` (the cloud workspace listing). Expand `@session:` client-side into an excerpt, or hide it.
- **Verify:** Tap the header `</>`: only a snackbar appears. Type `@` after the agent created files: "no files yet".

### CH-028 — P2 — Inert AgentSurface members feed dead UI (jobs, context ring, token meter, subagents, browser header)
- **Where:** cloud_agent_facade.dart:1407-1421 (`jobsFor` → `[]`, `killJobFor` no-op, `measuredContextTokens` → 0), :1650-1689 (session token counters 0, `subagentsOf` → `[]`, `browserBusy`/`browserReady` false, `regenerateSessionTitle` no-op); chat_screen.dart:2391-2520 (jobs popover unreachable), :420-440 and :619-700 (context ring and meter never show or show zeros); chat_overflow_menu.dart:21-120.
- **Fix:** Delete the dead UI and surface members, or feed them from events (`subagent_*`, `compaction_completed`, a usage event on `run_completed {inputTokens, outputTokens}`).
- **Verify:** Run several turns: no context ring. "…" menu: no jobs entry ever.

### CH-029 — P2 — Thumbs up/down feedback is neither persisted nor sent for cloud rows
- **Where:** chat_screen.dart:5490-5530 (mutates the projection `Message` and calls `persistSessions()`, but cloud rows are not in `session.messages`).
- **Fix:** POST to a gateway feedback endpoint keyed by `privateSyncId` (reports.ts exists), and cache it locally by that id.
- **Verify:** Like an answer, relaunch: the like is gone.

### CH-030 — P2 — The delete dialog always claims a "sandbox workspace" is deleted
- **Where:** session_actions.dart:106-113 and state.dart:921 (`sandboxId ??= id`, so the count is at least 1).
- **Fix:** Use copy that matches server delete semantics ("This deletes the chat and its cloud workspace files"), and drop `sandboxId`.
- **Verify:** Delete any chat and read the dialog.

### CH-031 — P2 — Error-row CTAs are wrong or missing for quota, auth and network
- **Where:** chat_screen.dart:8020-8095.
- **Problem:**
  - 402 `daily_limit_reached` has no "Upgrade" CTA to `BillingScreen`. "Resets in N min" is computed once per rebuild with no ticking timer, and shows raw minutes (e.g. "Resets in 842 min").
  - 429 has no retry-after.
  - `key_not_minted` sends the user to *Settings* ("Provider settings"), but the key is minted server-side and the user can do nothing there.
  - `unauthenticated` has no "Sign in" action.
  - `timeout` (status 0) and network errors are not `retryable`, so they get no Retry button even though they are the most retryable.
- **Fix:** 402 → "Daily limit reached · resets at 14:00 (in 3 h 12 m)" plus "Upgrade" (push BillingScreen), with a 30 s ticker. 429 → auto-retry with countdown. `key_not_minted` → "Retry" plus "Contact support". `unauthenticated` → "Sign in". `timeout` and network → Retry (with the CH-010 stable key).
- **Verify:** Exhaust a free-tier allowance on staging (or set the cap to 0 in /admin) and send: a raw countdown appears with no upgrade path.

### CH-032 — P2 (suspected) — Workspace hibernation and hydration are invisible; a cold first token can take many seconds with only "Thinking…"
- **Where:** event_projection.dart:438 (ignores `workspace_hibernated`/`workspace_hydrated`); worker runProcessor.ts:883 (hydrate happens before the model call).
- **Fix:** Show the status line "Waking your workspace…" between `run_started` and the first delta when `workspace_hydrated` is pending. Fold `workspace_hydrated` to clear it.
- **Verify:** Leave a session idle past the hibernation window, then send. The thinking shimmer runs for a long time with no explanation.

## C. Composer, attachments, media, rendering, UX

### CH-033 — P0 (data loss / core flow) — Attachments staged in a brand-new chat are silently dropped on the first send
- **Where:** cloud_agent_facade.dart:1294-1340 (`attachFile` keys `_attachments` by `_serverId(sessionId)`, which before the first send is the LOCAL id); :962-997 (`runTask` resolves `id = await store.ensureServerSession(sessionId)` to the new SERVER id, then reads `staged = attachments ?? _attachments[id]` under the server key and finds nothing); cloud_session_store.dart:337-349 (the mapping step re-keys nothing).
- **Problem:** The first message of a new chat with an image or file is sent without it. The chip disappears, because `pendingAttachments` now resolves to the server id. The toast had already said the file "will be sent with your next message". The orphan list under the local id is never cleared. The same re-key gap affects `_queues` and `_modes` set before the first send.
- **Fix:** Snapshot `_attachments[originalKey]` before `ensureServerSession`, or migrate every per-session map (`_attachments`, `_queues`, `_modes`, `_errors`, `_busyNotifiers`) from local to server id inside the store's mapping callback.
- **Verify:** New chat → attach an image → "describe this image" → Send. The gateway log shows no `POST /sessions/:id/attachments`, and the model says it sees no image.

### CH-034 — P1 — "Generate image" in the attach sheet sends plain text to an agent that has no image tool
- **Where:** chat_screen.dart:6874-6880 (attach sheet entry), :6990-7060 (`_imagePromptDialog` / `_sendImagePrompt` sends "Generate an image: …" as a normal prompt). No `generate_image` tool is registered in cloud/apps/worker or agent-core (the name appears only in presets.ts:68/112 and loop.ts:257 lists). `_imageGen`/`_imageGenCard` (:6052-6160) render only local `m.imagePath` files, and nothing creates `MsgKind.imageGen`. `ImageStudio`, `image_task.dart` and `ImageReceiptPanel` are reachable only from the Usage screen.
- **Problem:** A headline feature replies with text or a refusal, and the user is still charged for the run.
- **Fix:** Register a server `generate_image` tool backed by the mint image gateway. It writes the artifact and emits `artifact_created`, which folds into an image row (CH-004). Until then, hide the entry or route it to the working Image Studio flow.
- **Verify:** Attach → Generate image → "a red cube". No image appears.

### CH-035 — P1 — Offline behaviour contradicts itself, and a failed first history load is never retried
- **Where:**
  - chat_screen.dart:7377-7391: Send is disabled whenever `ConnectionService.I.offline`, so the outbox ("sends automatically when you are back online", the `_CloudOutboxChip` at :7920) is reachable only when the network is up but the WS is down.
  - chat_screen.dart:1088-1099: `_loadCloudTranscript` adds the id to `_cloudTranscriptsLoaded` BEFORE the fetch and swallows the failure.
  - cloud_agent_facade.dart:981-990: the offline enqueue carries no attachments, and they stay staged.
- **Problem:** A chat opened offline (or on a transient 5xx) with no cache shows the "How can I help?" empty state for the rest of the screen's life, which looks like lost history. There is no loading skeleton while the first page loads. Offline-staged files ride along with a later, unrelated message.
- **Fix:** Pick one model: allow offline send into the outbox (upload attachments at flush, keyed to the entry's `clientMsgId`), or remove the outbox chip. Mark the transcript loaded only on success, and retry on reconnect and resume. Show a skeleton, and a "Couldn't load history · Retry" state instead of `_EmptyState`.
- **Verify:** Airplane mode → cold start → open an old chat: you get the empty state. Turning the network back on does not reload it.

### CH-036 — P1 (suspected; profile) — Streaming cost grows with message length, and wide rebuilds happen on every facade notify
- **Where:**
  - event_projection.dart:491 (`live.content = live.content + text`, O(n²)).
  - chat_screen.dart:1866-1893 (the live tail rebuilds per tick), :9617 (`_OvidMarkdown.build` re-splits fences with regexes and re-parses every chunk each tick), :9910 (`highlightCode` re-highlights every code block each tick).
  - chat_screen.dart:1521 and :1716 (nested `AnimatedBuilder`s on `Listenable.merge([app, _agent])` rebuild the whole Scaffold on every AppState or facade notify).
  - chat_screen.dart:1700-1707 (pinch zoom calls `setChatFontScale` → `notifyListeners` plus a prefs write on every scale update).
- **Fix:**
  - Use a `StringBuffer` for the live content.
  - Coalesce ticks to about 30 fps.
  - Memoize parsed markdown and highlighted spans per (messageId, settled-prefix length), and re-parse only the open tail block.
  - Narrow listeners (`ValueListenableBuilder` per surface: busy, approvals, errors, queue).
  - Apply the pinch scale locally and persist it in `onScaleEnd`.
- **Verify:** Profile-mode build. Ask for "a 2000-line answer with 10 code blocks". The DevTools performance overlay shows UI-thread frames over 16 ms, growing as the answer grows.

### CH-037 — P2 — Thinking display is misleading and duplicated
- **Where:** chat_screen.dart:3438 (`_ReasoningCard` "Thinking for Ns" on the live bubble until the first delta), :7523 (`_TypingBubble` "Working…" at the same time); event_projection.dart:296-339 (the cloud emits no reasoning stream).
- **Problem:** "Thinking" covers queue wait, workspace hydrate and tool rounds. Two indicators show at once. The Settings "Show reasoning" toggle does nothing on cloud.
- **Fix:** Use one phase-driven status row (Queued → Starting workspace → Running `tool` → Writing), fed by run, tool and workspace events. Hide the reasoning toggle until reasoning events exist.
- **Verify:** Send any prompt and watch both indicators during the wait.

### CH-038 — P2 — Code fence and diff rendering bugs
- **Where:** chat_screen.dart:9595-9940.
- **Problem:**
  - The `_fenceRe` (```` ```(\w*)\n…``` ````) misses `c++`, `objective-c`, `shell-session`, `~~~` fences, indented fences inside lists, and CRLF.
  - An unclosed fence while streaming renders through the default `pre`, then jumps to `_OvidCodeBox` when it closes (layout jump).
  - Splitting prose into several `MarkdownBody`s restarts numbered lists across code blocks and breaks cross-chunk selection.
  - `_isDiff` (:9869) treats any of the first 8 lines starting with `+` or `-` as a diff, so YAML, bullet lists and SQL `--` comments render red and green.
  - `_OvidInlineCodeBuilder` (:9980) returns a widget for inline code, so paragraphs break into Wrap children with odd line breaks (suspected).
- **Fix:** Use a CommonMark-correct fence parse (info string up to whitespace; `~~~` too), or a single markdown parse with a custom `pre` builder. Treat as diff only when `lang == diff/patch` or there are `@@` hunk headers. Style inline code through `styleSheet.code`.
- **Verify:** Prompt: "show a c++ snippet, a YAML list, and a numbered list with code between items 2 and 3".

### CH-039 — P2 — Voice input defects
- **Where:** chat_screen.dart:6334-6415 (`_MicButton`); lib/core/voice_input_service.dart.
- **Problem:**
  - Partial results overwrite the field with `base + transcript`, discarding anything typed during dictation.
  - Dictation continues into another chat's draft after a session switch.
  - `initialize` is called without `onError`/`onStatus`, so after an error the mic stays "listening".
  - A permanently denied permission reads "Speech recognition is not available on this device" (`ensureMicrophonePermission` is unused).
  - A 2 s `pauseFor` cuts off natural pauses.
- **Fix:** Insert at the caret, cancel on session change, wire status and error, add a denied → open-Settings path, and raise `pauseFor` to about 4 s.
- **Verify:** Deny the mic permission permanently in system settings and tap the mic. Dictate, switch chats mid-dictation.

### CH-040 — P2 — Model picker extras and context-window display
- **Where:** chat_screen.dart:2523-2560 (sheet sizes computed once from the keyboard inset); model_limits.dart (`defaultContextWindow = 1000000`, so unknown models show a near-0% ring); the picker lists on-device BYOK providers (`p.hasKey && p.models.isNotEmpty`) whose keys never leave the phone (see CH-007).
- **Fix:** List only the cloud catalog plus server-side BYOK targets (byok_client.dart). Size the sheet reactively. Use a conservative default window (e.g. 128k) or hide the ring for unknown models.
- **Verify:** Open the picker, then focus search: the sheet does not re-snap. Pick an unknown model: the ring shows about 0%.

### CH-041 — P2 — Artifact thumbnails cause a URL-mint storm and a stale-URL flash
- **Where:** lib/ui/artifact_preview.dart:180-250 (`ArtifactThumb` re-mints a presigned URL in every `initState` with no shared cache, and first loads the stale persisted URL, which 403s).
- **Note:** The HTML artifact WebView (html_artifact_view.dart) is properly locked down: JS off, opaque origin, requests and permissions denied. It is just never fed on cloud (CH-004).
- **Fix:** Keep an LRU of minted URLs per `artifactId` until `expiresAt`, and skip loading a URL known to be expired.
- **Verify:** Scroll a list of 30 artifacts and watch the gateway log for `/artifacts/:id/url` bursts.

### CH-042 — P2 — Accessibility gaps
- **Where:** chat_screen.dart:1922-1960 (jump-to-latest pill about 28 dp tall); the live answer and the "Working…"/"Still working…" rows are not `Semantics(liveRegion: true)`; 10.5–11 px `Aether.textFaint` text (stats line, timestamps, paging affordance, turn tails) is likely below AA contrast (suspected); many hard-coded English strings bypass l10n (error row, attach sheet, toasts).
- **Fix:** Use 48 dp targets. Announce run completion and errors through a live region or `SemanticsService.announce`. Set a minimum 12 sp and AA contrast for meta text. Move the strings to ARB files.
- **Verify:** With TalkBack on, send a prompt: there is no completion announcement. Run the Accessibility Scanner on the chat.

### CH-043 — P2 (suspected) — Small screens, keyboard and gestures
- **Where:** chat_screen.dart:7300-7450 (docks plus composer heights in % of the pane), :1693 (a `GestureDetector(onScale…)` wraps the ListView, so the scale recognizer competes with the list drag and can delay scroll starts or lose flings).
- **Problem:** On a 360x640 screen with the keyboard open and font scale 1.3, the queue, todo and approval docks plus a 2-line hint leave the transcript a sliver.
- **Fix:** Collapse docks while the composer has focus, cap dock heights in dp, shorten the hint, and use a `RawGestureDetector` that claims only on 2 pointers.
- **Verify:** Emulator at 360x640, font scale 1.3, keyboard open, with a queued message and a pending approval.

### CH-044 — P2 — Stop has no "Stopping…" state, and "Interrupt and send" actually queues
- **Where:** cloud_agent_facade.dart:1088-1130 (`stopRequested` is tracked, but the button stays an active Stop and each tap POSTs cancel again); chat_screen.dart:2264-2268 ("Interrupt and send" calls stop, then `_sendCloudPrompt` still sees `busyFor` and enqueues).
- **Fix:** Show a disabled "Stopping…" state while `runState.stopRequested`. Either relabel "Interrupt and send" as "Stop and queue", or await the terminal and then send.
- **Verify:** Tap Stop twice quickly and watch the gateway log for two `/runs/:id/cancel` calls.

### CH-045 — P2 — Composer drafts are not account-scoped
- **Where:** lib/core/composer_drafts.dart (keyed by session id only); state.dart:1535-1561 (cleared only by Delete All Data, not on sign-out or account switch).
- **Fix:** Namespace keys by `sessionAccountId` and purge on account transition.
- **Verify:** Account A types a draft, signs out, and B signs in. Inspect `shared_prefs` (run-as): A's draft is still there.

### CH-046 — P2 — Long user messages and retry state
- **Where:** chat_screen.dart:5966 (a pasted 100k-char prompt renders fully as one `SelectableText`); :2334 (`_lastFailedCloudPrompt` is one field for the whole screen, so a failure in chat B overwrites A's, and Retry in A sends B's text into A); the attach sheet says "max 20 MB each" (:6862) while the client enforces 25 MiB and the server 25 MB (CH-022).
- **Fix:** Collapse user bubbles past about 30 lines with "Show more". Key the failed prompt (and its `clientMsgId`, CH-010) per session. Use one limit with the same copy everywhere.
- **Verify:** Paste a 100k-char prompt and scroll. Fail a send in chat B, switch to A, tap Retry.

### CH-047 — P2 — Leftover copy and dead UI
- **Where:**
  - chat_screen.dart:3299: the empty state says "the agent runs tools right here".
  - :1750-1767: `_ProducedFilesCard` is hard-wired to `const []`.
  - :102-219: `ChatTranscript` (the subagent viewer) renders `session.messages`, which is always empty for cloud.
  - :10009-10016: an orphan "runtime-install banner … Node.js/Python" doc comment.
  - artifact_preview.dart:19: `kStudioMovesToCloudMessage` is unused (the literal is duplicated at :1598 and :9226).
  - lib/core/commands.dart: `/help` dumps raw markdown into a SnackBar; the slash menu (:6640-6660) never suggests server `/todo` or user-invocable skills.
- **Fix:** Delete or rewrite. Fetch the server skill list for slash suggestions.
- **Verify:** Read the empty state. Type `/`: no skills are suggested.
