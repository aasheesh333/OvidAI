# 01 — Chat screen part 1 (chat core)

## Scope
- `lib/ui/chat_screen.dart` L1–4500 (ChatTranscript, ChatScreen state/build, app bar, model picker sheet, session stats / context meter sheets, background jobs sheet, mode/preset sheets, tool cards, diff viewer, produced files sheet)
- `lib/ui/transcript_model.dart`
- `lib/ui/chat_layout.dart`

## Goal
Read every line of the above in full, find functional bugs, missing states, UX/a11y/perf defects, UI-visible security issues, and gaps versus ChatGPT / Claude mobile and Claude Code MCP/plugin parity. Each finding cites file:line and gives a concrete fix.

Known context (not re-reported): per-token streaming rebuild storm and `_ChatTextScaler` equality (branch `perf/streaming-rebuilds`); model catalog 503 recovery (branch `fix/model-catalog-recovery`).

## Status
complete (all in-scope screens reviewed: sections 1–20 + group summary)


---

## 1. Transcript folding and windowing (`transcript_model.dart`)

**What it is / how reached:** Pure logic behind every chat transcript. `foldMessages` collapses runs of assistant tool/reasoning rows into a `FoldedGroup` (rendered as the "N tool calls · Thought for a while" strip). `windowForBounded` folds only the tail needed for the newest N items. Used by `ChatScreen` (page 40, grows by 40 on scroll-up) and `ChatTranscript` (subagent view, fixed 200).

**Findings**
- **P1 · functional / settings · transcript_model.dart:46-71** · The "Show reasoning" OFF filter runs only in the outer loop. The inner run collector (L63-67) takes `MsgKind.reasoning` rows no matter what `showReasoning` says. Any reasoning row that comes after a tool row in the same run is still kept: as a `SingleItem` in an unfolded run (rendered by `_MessageView` → `_reasoning()`, chat_screen.dart:4608), or inside a `FoldedGroup`. The folded case shows the "Thought for a while" label (chat_screen.dart:701/715) and puts a `_ReasoningCard` in the expanded strip (chat_screen.dart:755). · Users who turned reasoning off still see thinking text in most agentic turns, because tool → reasoning → tool is the normal pattern. The setting looks broken. · Filter inside the run loop as well. Either skip reasoning rows when collecting when `!showReasoning`, or pre-filter `messages` once (keeping absolute indices). Make `_isFoldable` and the boundary snap in `windowForBounded` (L228-238) use the same predicate so the bounded result still matches `windowFor`.
- **P2 · functional · transcript_model.dart:75-77** · A run counts as "complete" when the next row is any `MsgKind.text`, including a **user** message. If the user interrupts mid-run (Stop, then types), the unfinished run folds into a "Work done" strip as if it had produced an answer. · The interrupted or failed work is hidden behind a collapsed strip, so the user can't see what failed. · Also require `messages[i].role == 'assistant'`, or keep a run unfolded when it ends in an `error`/`stopped` tool state.
- **P2 · perf · transcript_model.dart:219-252** · When folding drops many rows (lots of hidden reasoning, or long runs that fold to 1 item), `span *= 2` loops can end up re-folding the whole history several times per cache miss. · Opening a very long agentic session costs O(n log n) folds once. That is acceptable, but nothing in a test measures it. · Cap the loop with an O(n) one-shot fallback (fold everything once) when `span > total / 2`.
- **P2 · maintainability · transcript_model.dart:27** · `transcriptFoldObserver` is a mutable global test hook in production code. · No user impact. · Move it behind `@visibleForTesting` or inject it.

**Missing features**
- No "Thought for Ns" duration and no per-run elapsed time in the folded group. ChatGPT and Claude both show reasoning time. `Message` would need `startedAt`/`endedAt` so the strip label can show it.

**Test to add**
- `foldMessages([user, tool, reasoning, tool, text], showReasoning:false)` contains no reasoning message, in either `SingleItem`s or `FoldedGroup.msgs`. Assert `windowForBounded(...).visible` equals the tail of `windowFor(...)` for the same input with `showReasoning:false`.
- `[tool, tool, userText]` must not produce a `FoldedGroup`.

## 2. ChatTranscript (subagent transcript widget)

**What it is / how reached:** chat_screen.dart:75-141. A read-only transcript for one child session. Opened from a `dispatch_agent` tool row's "Open" link → `SubagentScreen` (subagent_screen.dart:201).

**Findings**
- **P1 · functional · chat_screen.dart:96-112, 6564-6584** · The window is fixed at `pageSize: 200, visibleCount: 0` and there is no pager. When the child has more than 200 folded items, the top row is a static "Older messages not shown" label with no way to load them. The class docstring (L51-56) promises the subagent's work is "shown in full". · On long subagent runs (refactors, test loops) users cannot read the start of the child's work, which is usually where the plan is. · Reuse the `ChatScreen` pager: keep `visibleCount` in State and grow it on scroll-to-top, or at least make the indicator a "Load earlier" button that adds 200.
- **P2 · perf · chat_screen.dart:90-101** · The builder listens to `AppState.I` **and** `AgentService.I` and calls `windowForBounded` (a fresh fold of up to 200+ items) on every notification. There is no cache like `_ChatScreenState._transcriptWindow`. While the child streams, every token or status tick re-folds and rebuilds every row. · Jank on the subagent screen during live runs, worst on low-end Android. · Pull out the `_transcriptWindow` cache (session id, count, last identity, showReasoning) into a small helper used by both surfaces, and use the live-bubble tick pattern from `perf/streaming-rebuilds` for the tail.
- **P2 · UX · chat_screen.dart:93-95** · `ChatLayout(viewportWidth: MediaQuery.size.width)` uses the full window width, not the pane width. On a tablet where `SubagentScreen` sits beside the sidebar, the column is computed for the wrong width (ChatScreen fixed this with a `LayoutBuilder`, L1357-1362). · On tablets the column is too wide for its pane and gets clamped to the pane edge, with no gutters. · Wrap in a `LayoutBuilder` and use `constraints.maxWidth`.
- **P2 · functional · chat_screen.dart:118-119** · `onAction: () {}` and `input: null` are passed to every `_MessageView`. Row actions that rely on `onAction` to repaint (feedback thumbs, edit) silently do nothing visible here. · Taps on per-message actions in the subagent view look dead. · Hide the mutating actions in read-only mode (pass a `readOnly` flag) instead of wiring no-op callbacks.
- **P2 · UX · chat_screen.dart:107-123** · There is no tail-follow. When `typing` is true the list does not stick to the bottom as the child streams (unless the caller's controller does it). · Users watching a live subagent have to keep scrolling by hand. · Reuse `_maybeFollowTip` logic or `reverse: true`.

**Missing features**
- A header with the child's goal, status, elapsed time and tokens, plus a "Stop subagent" control. Claude Code shows per-agent progress and token usage.

**Test to add**
- Widget test: a child session with 450 messages shows a tappable "Load earlier" row, and tapping it renders message index 0 after enough taps.
- Count `transcriptFoldObserver` calls across 50 `AgentService.notifyListeners()` calls with an unchanged message list: expect ≤1.

## 3. ChatScreen state: drafts, tip-follow, paging, scroll anchoring

**What it is / how reached:** `_ChatScreenState` fields and helpers, chat_screen.dart:802-1185. Covers per-session drafts, the at-bottom follow, the lazy pager, and keyed anchor restore.

**Findings**
- **P1 · data loss · chat_screen.dart:830, 906-932** · Drafts live only in the in-memory `_drafts` map. They are lost when the app is killed, backgrounded and reclaimed (common on Android), or when the account switches. · Long prompts typed on mobile vanish after a phone call or app switch. ChatGPT and Claude keep drafts. · Persist drafts per session (debounced 500 ms to SharedPreferences or the session store), restore them in `_bindDraft`, and clear them on submit in `_clearSubmittedDraft`.
- **P2 · functional · chat_screen.dart:1196-1205** · Draft binding is deferred to a post-frame callback. For one frame after a session switch, the composer still shows the **previous** session's text, and a fast Send in that frame is blocked by the `_boundSessionId != s.id` guard (L1773-1777) with no feedback. · Occasional ignored Send right after switching chats. · Bind synchronously from a session-switch listener (`AppState.onSessionSwitched`) instead of from `build`, or give feedback when Send is ignored.
- **P2 · perf · chat_screen.dart:1174-1185** · `_maybeFollowTip` schedules a `jumpTo(maxScrollExtent)` after **every** rebuild while at bottom, including rebuilds unrelated to the transcript (approval dock, queue, startup panel ticks). On a lazily built `ListView`, `maxScrollExtent` is an estimate, so repeated jumps can visibly jitter while rows above settle. · Small stutter at the tail during streaming. · Only follow when the tail row's height or the row count changed (compare `_scroll.position.maxScrollExtent` with the last followed value), or use `reverse: true` with a bottom anchor, which needs no follow jumps at all.
- **P2 · state · chat_screen.dart:835, 1398** · `_queueEdits` entries are never removed when a session is deleted or the queue item finishes while the user is not in the composer. The composer stays in "editing queued message" mode for that session. · Stale "editing queue" banner. Send then shows "queued message changed" and nothing is sent. · Clear the entry in `_bindDraft` when the queued id no longer exists, and on session delete.
- **P2 · a11y · chat_screen.dart:976-997** · Older history loads only from a scroll position < 120 px. There is no tappable control. TalkBack and Switch Access users who navigate by focus, not by fling, may never trigger it. · Long chats are partly unreachable with assistive tech. · Make the affordance row at L1548-1606 a `Semantics(button:true)` `InkWell` that runs the same paging routine.

**Missing features**
- Search inside a conversation (ChatGPT has in-chat find). Jump to a message from search results would need to grow `_visibleCount` until the index is in the window, then use the anchor helpers.

**Test to add**
- Draft persistence: type into session A, recreate `ChatScreen` (simulated restart with the same `AppState`), and expect the draft restored.
- Paging affordance: with TalkBack semantics enabled, `tester.tap(find.bySemanticsLabel(RegExp('earlier message')))` grows the window.

## 4. Chat app bar (model title, jobs badge, Studio, Browser, New session)

**What it is / how reached:** chat_screen.dart:1207-1355. The main chat header. On widths below 840 it has a drawer with `SessionsSidebar`.

**Findings**
- **P2 · a11y · chat_screen.dart:1219-1237** · The model selector is a bare `GestureDetector` in the title. It has no `Semantics(button: true)`, no label such as "Model: X, change", no ink feedback, and a hit area only as tall as 14 sp text. · Screen-reader users don't know the most important control on the screen is tappable. Sighted users get no press feedback. · Use an `InkWell` or `TextButton` with `Semantics(button:true, label:'Model ${label}. Change model')` and a min height of 48.
- **P2 · UX · chat_screen.dart:1347-1352** · "New session" calls `app.newSession` with no dedupe (state.dart:6293). Each tap inserts another empty "New chat" at the top of the sidebar. · Sidebar fills with empty chats. ChatGPT and Claude reuse the existing empty chat. · If the active session has no messages and an empty draft, just focus the composer. Otherwise create the session.
- **P2 · a11y / contrast · chat_screen.dart:1273-1295** · The job-count badge is 8.5 sp white on `Aether.textFaint` when no job is running. That likely fails 4.5:1 contrast, and the count is not in the button's semantics ("Background jobs" only). · Low-vision and screen-reader users miss that jobs exist or how many. · Put the count in the tooltip and semantics label ("Background jobs, 2 running"). Use a ≥10 sp badge on a contrast-checked color.
- **P2 · a11y · chat_screen.dart:1308-1345** · The browser status dot (busy/ready/off) is color-only, and its meaning is not in the semantics label. · Color-blind and screen-reader users can't tell agent browser state. · Add the state to the tooltip and label: "Browser — agent active / ready / not started".
- **P2 · layout · chat_screen.dart:1238-1354** · On a 320–360 dp phone, the drawer button plus up to 4 compact icons leave the model title about 120 dp, so long model names truncate to a few characters. · Users can't see which model is active. · Move Studio and Browser into an overflow menu below 400 dp, or show only the jobs badge when it is active.

**Missing features**
- No conversation overflow menu in the header (rename, share, pin, delete, export, branch). ChatGPT and Claude both put these in the header.
- No visible usage or credit indicator for Ovid Cloud users in the header (Claude Code `/usage` parity). The only meter is the stats line (section 7).

**Test to add**
- Semantics test: `find.bySemanticsLabel(RegExp('Change model'))` exists and is a button.
- Tap "New session" twice on an empty chat: `AppState.I.sessions.length` grows by at most 1.

## 5. Chat body layout (startup panel, transcript list, jump pill, dock area, pinch zoom)

**What it is / how reached:** chat_screen.dart:1356-1754. Startup readiness panel, the windowed transcript `ListView`, the "jump to latest" pill, the bounded dock area (approval / goal / todo / stats / queue), then `_InputBar`.

**Findings**
- **P2 · a11y · chat_screen.dart:1682-1719** · The jump-to-latest pill is about 36×28 dp (padding 10×6 plus a 16 dp icon), below the 48 dp minimum. Tapping it also doesn't set `_atBottom = true`, so the next stream frame can race the listener. · Hard to hit while scrolling on a phone. · Wrap it in a `SizedBox(48×48)` / `FloatingActionButton.small`. Set `_atBottom = true; _showJumpFab = false` before `animateTo(max)`.
- **P2 · UX · chat_screen.dart:1682** · The pill shows whenever the user is not at the bottom, even on idle chats. It never shows a "new messages" count. · Low signal. Users scrolling an old chat always see a floating arrow. · Show it only when `typing` or when new rows arrived since the user scrolled away, and add a "N new" label.
- **P2 · gesture / perf · chat_screen.dart:1447-1460** · The pinch `GestureDetector` wraps the scrolling list. `setChatFontScale` (state.dart:5585) calls `notifyListeners()` and **writes SharedPreferences on every scale update** (about 60/s). That rebuilds the whole `ChatScreen` AnimatedBuilder, including the app bar and composer, every frame of a pinch. · Janky pinch. Disk writes during the gesture. · Keep the scale in local state during the pinch (apply it through a `ValueNotifier` that only the transcript `MediaQuery` listens to) and persist once in `onScaleEnd`.
- **P2 · a11y · chat_screen.dart:1446-1474** · Chat zoom is pinch-only from this screen. `_ChatTextScaler` multiplies the user's system scale by `chatFontScale` with no combined ceiling, so 200% system × max chat zoom can make the transcript unusable (single words per line). · Accessibility users can get stuck at extreme sizes. · Clamp the effective scale (for example `min(inherited.scale(f)*zoom, f*3.0)`) and show a "Reset zoom" chip when zoom ≠ 1.
- **P2 · layout · chat_screen.dart:1723-1734** · The dock area may take up to 30% (45% with an approval) of the chat height. With the keyboard open on a 640 dp phone, `chatConstraints.maxHeight` is about 300, so docks plus composer leave the transcript about 100 dp. · During a long queue or approval the user can barely see the conversation while typing. · When `viewInsets.bottom > 0`, collapse passive docks (stats, todo, goal) to a single summary line.
- **P2 · perf · chat_screen.dart:1475-1677** · The transcript `AnimatedBuilder` listens to `AgentService.I`. Every agent notification (job tick, status line, browser state) rebuilds the `ListView` and re-runs `_computeRowKeys`. The fold is cached but the row widgets are not. · Extra rebuild work on every tick during runs. Partly covered by `perf/streaming-rebuilds`. · Wrap static rows in `RepaintBoundary` and give non-tail rows `const`-stable widgets keyed by message identity, so element reuse skips rebuild.

**Missing features**
- No "Scroll to top / first message" and no message timestamps on long-press, both standard in ChatGPT.

**Test to add**
- Pinch gesture test: during a 2-finger scale, `SharedPreferences.setDouble` is called once (on end), not per update.
- Jump pill: `tester.getSize(find.bySemanticsLabel('Jump to latest'))` ≥ 48×48.

## 6. Send pipeline (onSend, slash commands, skills, queue edits, `_sendPrompt`, `_enqueuePrompt`)

**What it is / how reached:** chat_screen.dart:1772-1964 (composer `onSend`), 2087-2177. Pressing Send in the composer.

**Findings**
- **P1 · functional / silent failure · chat_screen.dart:1907-1914** · When `/skill-name` resolves to a user-invocable skill that is not available for this session (`isSkillAvailableForSession` false: disabled plugin, wrong mode, etc.), `onSend` just `return`s. No snackbar, and the draft stays. · The user presses Send and nothing happens, with no reason given. That looks like a frozen app. · Show "Skill X isn't available in this session (reason). Enable it in Plugins" with an action that opens `PluginsScreen(focusCanonicalId: ...)`.
- **P1 · functional · chat_screen.dart:1825-1829** · `await CommandService.I.execute(t)` runs with no busy state or re-entrancy guard. A double-tap on Send, or Enter pressed twice, runs a slash command twice. That matters for side-effecting commands (`/clear`, `/compact`, `/preset`, `/new`). · Duplicate compaction or clears, and confusing double snackbars. · Add an `_executingCommand` flag that disables Send (and shows a small spinner) until `execute` resolves.
- **P2 · UX · chat_screen.dart:2136-2150** · "Add an API key for X first." and "The selected model is no longer available." have no action. Only the provider-missing branch (L2128-2131) offers "Select". · Dead end. The user has to find Settings → Providers or the picker on their own. · Add `SnackBarAction`s: "Add key" (opens Settings → Providers focused on that provider) and "Choose model" (`_modelPicker`).
- **P2 · ordering · chat_screen.dart:1944-1950** · With "send while busy = interrupt", `stopRequested` promotes the existing queue (agent_service.dart:1609, `_scheduleQueuedContinuation`), and then the new prompt is sent immediately. The queued messages and the new one race. The new message usually starts first, and the queued ones run afterwards, in a different order from what the user typed. · Surprising order of turns, with possible duplicated context. · In interrupt mode, either put the new prompt at the head of the queue and let the continuation drain it, or stop without promoting the queue when an explicit new prompt follows.
- **P2 · robustness · chat_screen.dart:2124, 2439** · The magic string `session.model == 'Select a provider'` is used as a sentinel in several places (also state.dart:6298). · Fragile. Localizing or renaming that string breaks send validation. · Use a nullable `model` or a constant `kNoModelSelected` shared by state and UI.
- **P2 · UX · chat_screen.dart:2160-2165** · Snap-to-bottom uses `Future.delayed(80ms)` + `jumpTo` with no `mounted` check, and it is an instant jump, not an animation. · On slower devices 80 ms is too early: it jumps before the new row lays out and then lands one row short. · Use `_maybeFollowTip()` (already post-frame and `_atBottom`-gated) instead of a timer.
- **P2 · feedback · chat_screen.dart:2098-2104** · When `enqueueMessage` rejects admission (queue full, account not ready), `_enqueuePrompt` returns false and the draft is kept, but there is no message. · Send appears to do nothing while a run is active. · Return a reason from `enqueueMessage` and show it.

**Missing features**
- No retry on a failed send (network). The run error appears in the transcript. ChatGPT offers "Regenerate" in place. That may be covered in group 02 under per-message actions.
- No offline detection before send. With no network the run starts and fails later.

**Test to add**
- `/unavailable-skill` → Send shows a snackbar containing "isn't available", and the draft is kept.
- Double-tap Send with `/compact`: `CommandService.execute` is called once.
- Interrupt mode with 2 queued items, then send "C": the observed run order matches the documented intent.

## 7. Stats line and Session analytics sheet

**What it is / how reached:** `_StatsLine` (chat_screen.dart:329-436), docked above the composer once a session has usage. Tapping the text opens `_showSessionAnalytics` (L438-512).

**Findings**
- **P2 · a11y · chat_screen.dart:360-365, 388** · The whole line is a `GestureDetector` with 3 dp vertical padding and 10.5 sp `textFaint` text. The tap target is about 18 dp tall, with no semantics button role. Contrast of `textFaint` at 10.5 sp is likely below 4.5:1. · Hard to tap, hard to read, and invisible to TalkBack as a control. · Add a min height of 32–48 dp, `Semantics(button:true, label:'Session usage details')`, and use `textMuted`.
- **P2 · usage accuracy · chat_screen.dart:381-382, 503-505** · "≈ $0.0012" is computed from public list prices even for **Ovid Cloud managed** sessions, where the user is billed in plan credits or the gateway price. · Users compare it with their bill or credit balance and see different numbers, which leads to support tickets. · For the managed provider, show credits or the plan allowance reported by the gateway (`cloud_usage_status`). Hide the list-price estimate, or label it "list-price estimate".
- **P2 · consistency · chat_screen.dart:475-478 vs 348** · The sheet's "Context" uses `a.contextLimit`. The ring and context meter use `AgentService.contextWindowForSession(s)`. When `contextLimit` is 0 or stale, the sheet shows "12K / 0" while the ring shows 9%. · Contradictory numbers. · Use `contextWindowForSession` everywhere.
- **P2 · layout · chat_screen.dart:440-511** · The sheet is a fixed `Column` (no `isScrollControlled`, no scroll). At 200% text on a small phone, 8 metric tiles plus text overflow the sheet. · Bottom overflow stripes, and the footer note is cut off. · Wrap it in `SingleChildScrollView` and set `isScrollControlled: true`.
- **P2 · copy · chat_screen.dart:370-384** · The line mixes `  |  ` and ` · ` separators and abbreviations ("ttft", "tok/s", "LLM"). That reads as developer jargon to non-technical users. · Hurts the consumer-app feel. · Default to "3 turns · 9.6K tokens · 12%". Put TTFT, tok/s and cache in the sheet only, or behind a "Developer stats" setting.

**Missing features**
- Per-turn token and cost breakdown. Claude Code's `/cost` reports per-session totals by model, and the ChatGPT/Claude apps show plan limits ("X messages left until 3 PM"). Nothing here shows rate-limit or plan headroom.
- Export or copy analytics.

**Test to add**
- Golden at 2.0 text scale on a 360×640 viewport: the analytics sheet does not overflow.
- A managed-cloud session doesn't show a `$` estimate.

## 8. Context meter (ring + sheet)

**What it is / how reached:** The 12 dp ring and % at the end of the stats line (chat_screen.dart:394-429). Tapping it opens `_showContextMeter` (L541-627) with System / Tools / Messages bars and a cache-read note.

**Findings**
- **P2 · a11y · chat_screen.dart:394-428** · The tap target is a 12 dp ring plus a 10.5 sp label, nested inside the stats-line `GestureDetector`. The detail is in a `Tooltip`, which needs a long-press on mobile and is not exposed as a semantic value. · Almost impossible to tap reliably. TalkBack reads "9%" with no context. · Give it a 48 dp hit area, `Semantics(button:true, label:'Context 9% of 128K used. Details')`, and drop the Tooltip-only info.
- **P2 · stale data · chat_screen.dart:541-552** · The sheet takes `window`/`used` and the bucket values once, when it opens. It doesn't listen to `AgentService`, so while a run continues the numbers freeze. · Misleading while the agent works. · Wrap the body in `AnimatedBuilder(animation: Listenable.merge([AppState.I, AgentService.I]))` and recompute inside.
- **P2 · correctness · chat_screen.dart:548-551** · When `analytics` is null it falls back to `agent.session*Tokens`, which read `_run`: the *active* run bucket, not necessarily this session's. · Can show another session's numbers right after a switch. · Always read from `session.analytics`, and show "—" when absent.
- **P2 · UX · chat_screen.dart:614-621** · "Compaction triggers automatically near the window limit." gives no control. `/compact` exists (commands.dart:135) but there is no "Compact now" button, and no warning state when the meter is ≥80% apart from color. · Users near the limit can't act from the place where they see the problem. · Add a "Compact now" button (disabled while busy, matching the `/compact` idle-only rule). At ≥80%, add a one-line warning: "Long chats get slower and costlier. Compact or start a new chat."
- **P2 · a11y · chat_screen.dart:355-359, 583-587** · Danger, warning and OK are shown by color only (red/amber/green). · Color-blind users miss the threshold. · Add a text cue ("High", "Near limit") or an icon.

**Missing features (Claude Code parity)**
- Claude Code's `/context` breaks usage down **per MCP server / per tool schema**, memory files, and a free-space / autocompact buffer. Here "Tools" is one bucket. When several MCP servers are enabled, users can't see which one eats the context. Add per-server rows (from `McpService` schema token estimates) with a quick toggle to disable a server for this session.
- No "free space" segment, so the three bars don't add up to the total.

**Test to add**
- Open the sheet, bump `analytics.contextTokens`, pump: the header text updates.
- With the active session at ≥80%, the sheet shows a "Compact now" button that calls `CommandService.execute('/compact')`.

## 9. Turn-process strip (folded tool/reasoning group)

**What it is / how reached:** `_TurnProcessStrip`, chat_screen.dart:687-764. Rendered for each `FoldedGroup` before a final answer. Tapping it expands the folded tool and reasoning cards.

**Findings**
- **P2 · state loss · chat_screen.dart:694-695** · `_open` is plain `State`. When the row scrolls out of the `ListView` cache and back, or the window re-pages, the strip collapses again. · Users who expanded a strip to inspect tool calls lose their place on scroll. · Store expansion in a `Set<int>` keyed by the group's first message index on `_ChatScreenState` (or `PageStorage`), or use `AutomaticKeepAliveClientMixin` while open.
- **P2 · a11y · chat_screen.dart:725-750** · The row is about 30 dp tall (7 dp padding + 15 dp icon), and it has no `Semantics(expanded: _open, button: true)`. · Small target, and screen readers don't announce expanded/collapsed. · Add a min height of 44–48 and `Semantics(button:true, expanded:_open, label: label)`.
- **P2 · copy · chat_screen.dart:715, 740** · "Thought for a while" and the fallback "Work done" are vague. A failed tool in the group isn't shown in the collapsed label. · Users can't tell a group had errors without expanding it. · Show a duration ("Thought for 12s") when timestamps exist. Add "· 1 failed" in danger color when any `toolState == 'error'`.
- **P2 · perf · chat_screen.dart:752-759** · Expanding builds every folded card at once in a `Column`. A 60-tool group creates 60 cards inside one list row, so the row is not lazy. · A jank spike on expanding big groups. · Cap the visible cards at 20 with a "Show N more" button.

**Missing features**
- No "copy all tool output" or "view as log" for a group, which the Claude Code transcript view (Ctrl-R) provides.

**Test to add**
- Expand a strip, scroll it out of view (more than the cache extent), scroll back: it is still expanded.
- A group containing an error tool has a collapsed label containing "failed".

## 10. Agent access mode sheet (`/permission`) and Agent preset sheet (`/preset`)

**What it is / how reached:** `_showModeSheetFromCommand` (chat_screen.dart:1983-2025) and `_showPresetSheetFromCommand` (L2030-2082). Opened when `/permission` or `/preset` returns a `popup`.

**Findings**
- **P2 · layout · chat_screen.dart:1990-2022** · The mode sheet is a non-scrolling `Column` (the preset sheet scrolls). With large text or landscape, the last modes overflow. · The bottom options (often the most permissive mode, or "control") become unreachable. · Wrap it in `SingleChildScrollView` and set `isScrollControlled: true` like the preset sheet.
- **P2 · security UX · chat_screen.dart:2000-2018** · Every mode row looks the same. Permissive modes (auto-approve / control) get no warning color or icon, and only "control" goes through a consent dialog. · Users can switch to a full-auto mode with one tap and not realise tools will run without approval. · Add a danger accent and a "Tools run without asking" subtitle on auto-approve modes, and a confirm step mirroring `_enableControlMode`.
- **P2 · consistency · chat_screen.dart:1984-1998 vs 2031-2047** · The sheets have no drag handle, no close button, and a plain 14 sp title, unlike the model picker (`AetherSheet` style, L2501-2514). · Inconsistent sheet chrome. · Use a shared `AetherSheet` scaffold for all chat sheets.
- **P2 · feedback · chat_screen.dart:2016** · `AgentService.I.setMode(m)` gives no confirmation, and if a run is active it's unclear whether the new mode applies to the current run. · Ambiguity about safety state. · Show a snackbar: "Mode: Ask before edits (applies from the next tool call)".
- **P2 · feedback · chat_screen.dart:2061-2073** · Preset apply errors only show if `result.feedback` is non-empty. A null result (an unknown preset after a registry change) does nothing. · Silent failure. · Show a generic "Couldn't apply preset" when the result is null.

**Missing features**
- No per-tool allowlist editing from the mode sheet. Claude Code's `/permissions` lets you manage allow/deny rules per tool and MCP server. Link to `permissions_screen` from the sheet.

**Test to add**
- At 2.0 text scale on 360×640, every mode row is visible after scrolling (no overflow).

## 11. Background jobs sheet

**What it is / how reached:** The header badge appears when the session has jobs (chat_screen.dart:1246-1300). Tapping it opens `_showJobsPopover` (L2181-2311).

**Findings**
- **P2 · functional · chat_screen.dart:2253-2258** · The state color `switch` falls through to `successLight` for every state other than running, stopping and pending, so `failed`, `error` and `killed` jobs show a **green** dot. · Failed jobs look successful. · Map explicit states: failed/error → `dangerC`, killed/stopped → `warnLight`, done/exited 0 → success. Also add a text state, which is already present but low-contrast.
- **P2 · missing core action · chat_screen.dart:2243-2300** · Rows can't be tapped to view output. Only the size ("N chars") is shown. · Users can't see why a dev server or test run failed without asking the agent. · Tap a row to open a live log view (tail with auto-follow, copy). Claude Code `/bashes` lets you inspect output.
- **P2 · safety · chat_screen.dart:2287-2297** · "Kill job" fires immediately with no confirm or undo, from a 40 dp compact icon next to the row text. · Accidental kills of long builds. · Confirm on first kill, or show an undo snackbar where the platform allows it.
- **P2 · layout · chat_screen.dart:2192-2304** · `Flexible` + `shrinkWrap` `ListView` in a `Column` inside a non-scroll-controlled sheet. With many jobs it is capped at about 50% of the screen height, with no header pinning. · OK for a few jobs, cramped for 10+. · Set `isScrollControlled: true` with a `DraggableScrollableSheet`.
- **P2 · UX · chat_screen.dart:1260** · The badge disappears as soon as `jobsFor` is empty. Finished jobs vanish, so the user can't check the result of a job that just ended. · Lost results. · Keep finished jobs for the session (with a "Clear finished" action).

**Missing features**
- A global "all sessions" jobs view (jobs keep running when you switch chats).

**Test to add**
- A job with `state: 'failed'` renders a dot with the danger color.

## 12. Model picker sheet (`_ModelPickerSheet`, `_ModelTile`)

**What it is / how reached:** chat_screen.dart:2313-3010. Opened by tapping the app-bar title, by `/model`, or from the "Select" snackbar action. A `DraggableScrollableSheet` with search, an Ovid Cloud card (status + Retry), Recents, one card per keyed provider, and an "awaiting a key" notice.

**Findings**
- **P1 · functional · chat_screen.dart:2815-2831** · Effort support is guessed by substring: `'gpt'`, `'gemini-2.5'`, `'glm'`, `'kimi'`, `'r1'`, `'grok'`… That matches non-reasoning models (gpt-4o, gpt-4.1-mini, gpt-3.5, gemini-2.5-flash-lite, grok-2, any id containing "r1"). Those rows become `ExpansionTile`s whose Low/Medium/High chips send `reasoning_effort`. The gateway rejects it and the app falls back with an extra request (agent_service.dart:12552-12566). · Wasted latency on the first call. Users think they set a "High" effort that has no effect. Picking these models takes an extra tap (expand, then chip). · Drive effort support from catalogue metadata (the provider `/v1/models` capability flags, or a curated allowlist of exact model families: o1/o3/o4, gpt-5, claude opus/sonnet 4+, deepseek-reasoner, qwen3, gemini-2.5-pro/flash). Default to a plain `ListTile`.
- **P2 · UX · chat_screen.dart:2936-3006** · For effort-capable models, tapping the row only expands it. There is no direct select with a sensible default. · An extra tap on the most common action, and different behaviour from neighbouring rows. · Tap the row to select it with the default effort (Medium), and use a trailing "Effort ▸" affordance to expand.
- **P2 · perf · chat_screen.dart:2723-2753** · Each provider card builds **all** its model tiles eagerly in a `Column` inside one `SliverList.list` child. OpenRouter-type providers expose 300+ models, so opening the picker or typing a search letter builds hundreds of `ListTile`/`ExpansionTile`s. · Noticeable lag opening the picker and typing in search on mid-range phones. · Flatten into a `SliverList.builder` over (header, model) rows per provider, or cap each provider at 8 with "Show all N".
- **P2 · functional · chat_screen.dart:2452-2465** · Recents are filtered on "provider exists", not `hasKey`. A recent from a provider whose key was removed is still selectable, and then Send fails with "Add an API key". · A dead-end selection. · Filter recents by `p.hasKey || p.id == ovidCloudProviderId`, or render them disabled with "Key needed".
- **P2 · navigation · chat_screen.dart:2554-2561, 2786-2793** · "Open Settings" opens the Settings root, not the Providers section, even though the copy says "Settings → Providers". · An extra step and lost context. · Push the providers screen directly (`ProvidersScreen`), focused on the matching provider.
- **P2 · a11y · chat_screen.dart:2898-2925** · The selected state is a check icon only. No `Semantics(selected: true)` and no `ListTile.selected`. The "CURRENT" badge appears only in Recents. · Screen readers don't announce the active model. · Set `selected: selected` on `ListTile` (and on the ExpansionTile semantics).
- **P2 · error state · chat_screen.dart:2383-2393** · The cloud `failed` status prints `state.error` verbatim. It is said to be sanitized upstream, but there is no length cap, so long server messages wrap over many lines in the card. · A wall of text in the picker. · Cap it at 3 lines with a "Details" expander.
- **P2 · code smell · chat_screen.dart:2974-2984** · `v == 'Medium' ? '$baseModel · Medium' : '$baseModel · $v'`: both branches are identical. · No user impact. · Simplify, and build the variant id from a single helper used by state and UI.
- **P2 · UX · chat_screen.dart:2853-2855** · Every non-auto row shows a "Manual" pill, which adds noise to every row without telling the user anything. · Visual clutter. · Drop "Manual". Show capability pills instead (Vision, Tools, Reasoning, context size).

**Missing features (vs ChatGPT / Claude)**
- Model metadata in rows: context window, price tier or credit multiplier, vision/tools/reasoning support, "new" badge. Claude and ChatGPT show short model descriptions.
- Favorites or pinning, and a "Default model for new chats" setting from the picker.
- Per-session vs global choice: picking a model changes only the session. Make that explicit ("Apply to new chats too").

**Test to add**
- `_ModelTile(model:'gpt-4o-mini')` renders a `ListTile`, not an `ExpansionTile`. `'o3-mini'` renders effort chips.
- A recent whose provider has no key is not shown (or is disabled).
- Perf: a picker with one provider of 400 models builds fewer than 50 `_ModelTile`s on first frame.

## 13. Empty state (new chat home)

**What it is / how reached:** `_EmptyState`, chat_screen.dart:3016-3082. Shown when the active session has no messages.

**Findings**
- **P2 · onboarding · chat_screen.dart:3016-3082** · The same "How can I help?" shows even when **no provider or model is configured** (`session.model == 'Select a provider'`). The user only finds out after typing and pressing Send (snackbar, L2125-2133). · First-run users write a prompt, hit a dead end, and may churn. · When no usable model exists, show an inline card: "Connect Ovid Cloud (free) / Add an API key" with buttons, in place of the subtitle.
- **P2 · UX · chat_screen.dart:3012-3015** · No suggestion or starter prompts, by design. But the subtitle "the agent runs tools right here" gives no hint of what it can do (Studio, browser, plugins). · Lower activation than ChatGPT/Claude, which show capability chips. · Add 3–4 optional capability chips (configurable, can be turned off), or show the active preset and working folder.
- **P2 · a11y · chat_screen.dart:3034-3051** · The brand "O" tile is decorative but is read as the letter "O". · Screen-reader noise. · Wrap it in `ExcludeSemantics`. Mark the greeting as a header (`Semantics(header:true)`).
- **P2 · theme · chat_screen.dart:3045-3048** · The mark is hardcoded white text on `Aether.accent`, with no check in the light theme. · Possible low contrast on some palettes. · Use an `onAccent` token.

**Missing features**
- Recent chats or "continue where you left off" on the home screen. Also a visible model and mode summary so users know what they're about to talk to.

**Test to add**
- No configured provider: the empty state shows a "Connect" CTA, and tapping it opens the providers/cloud flow.

## 14. Reasoning card (`_ReasoningCard`)

**What it is / how reached:** chat_screen.dart:3088-3202. Collapsed "Thoughts" disclosure (live: chase dots + shimmering "Thinking…"). Shown for reasoning rows in the transcript and inside expanded turn strips.

**Findings**
- **P2 · UX bug · chat_screen.dart:3170-3179** · The chevron rotation is backwards. `Icons.chevron_right` with `turns: expanded ? 0.0 : -0.25` points **up** when collapsed and **right** when expanded. Every other disclosure in the file (strip, tool card, compaction row) points right/down. · Confusing affordance: collapsed looks like "collapse". · Use `Icons.chevron_right` with `turns: expanded ? 0.25 : 0.0`, or `expand_more` 0 → 0.5 like `_ToolCard`. Update the pinned test.
- **P2 · state loss · chat_screen.dart:3103** · `_override` is plain State, so it is lost when the row is recycled. A live card that the user collapsed re-expands after scrolling. · Annoying while reading long runs. · Persist it in a session-scoped expansion map (shared with section 9).
- **P2 · a11y · chat_screen.dart:3125-3183** · No `Semantics(expanded:…, button:true)`. Live state is only a shimmer animation, with no live-region announcement ("Thinking"). · TalkBack users don't know the model is thinking or that the row expands. · Add semantics with `liveRegion: isStreaming` and `label: 'Thinking'` / `'Thoughts, collapsed'`.
- **P2 · copy · chat_screen.dart:3158** · "Thoughts" has no duration. · Less informative than "Thought for 14s" (ChatGPT/Claude). · Store reasoning start/end on `Message` and show the duration.
- **P2 · perf · chat_screen.dart:3192-3196** · The expanded body re-renders full markdown for the whole reasoning text on every token while live (`expandedByDefault`). Very long thinking (10–50K chars) re-parses markdown each tick. · Jank during long thinking. · While streaming, render plain `Text` (or only the last ~4K chars), and switch to markdown once `thinking == false`.

**Test to add**
- Collapsed chevron: the `AnimatedRotation.turns` for the collapsed state yields a right-pointing glyph, and expanded points down.

## 15. Tool card, detail body and rich tool result (`_ToolCard`, `_DetailBody`, `_RichToolResult`, `_ModelCompareView`, `_ColorPaletteView`, `_DiffLine`)

**What it is / how reached:** chat_screen.dart:3214-4162. Every tool call row in the transcript. Tapping it expands a terminal/diff/plain body capped at 16 lines, with rich JSON/URL/colour rendering and special views for compare and palette tools. `dispatch_agent` rows have an "Open" link to the subagent transcript.

**Findings**
- **P1 · security · chat_screen.dart:3940-3946** · URLs found in **tool output** (web fetch, MCP results, shell output: all attacker-influenced via prompt injection) become underlined links that call `launchUrl(..., externalApplication)` on a single tap. There is no confirmation and no host display, and the regex (L3643) accepts look-alike domains and userinfo tricks (`https://bank.com@evil.tld`). · Phishing or drive-by downloads one tap away, styled as trusted app UI. · Before launching, show a confirm sheet with the punycode-decoded host prominent ("Open evil.tld?") and Copy / Open. Strip userinfo. Allow only http/https (already enforced).
- **P2 · resource leak · chat_screen.dart:3940** · A new `TapGestureRecognizer` is created per URL per build and never disposed. · Memory and arena churn in long sessions with link-heavy outputs. · Make `_enrichedLine` a StatefulWidget that owns and disposes its recognizers, or use `Text.rich` with `WidgetSpan(InkWell)`.
- **P2 · correctness · chat_screen.dart:3494-3506** · Diff detection marks any output whose first 8 lines include a line starting with `-` or `+` as a diff (markdown bullets, CLI flags, `-rw-r--r--` from `ls -l`, negative numbers). That output is then rendered red/green and loses URL/JSON enrichment. · Ordinary tool output looks like deletions, which is alarming and misleading. · Require a real diff signature (`diff `/`@@ `/`--- a/` + `+++ b/` header) or `kind == 'edit'`/`commit`.
- **P2 · correctness · chat_screen.dart:3491-3492, 3622-3625** · The 16-line cap keeps the **tail**, then JSON detection runs on the capped text. Multi-line JSON over 16 lines never parses (it only formats after "expand"). Read/search outputs show their last lines first, without saying the head is hidden. · Inconsistent rendering, and important leading content (file headers, first results) hidden. · Cap the head for non-terminal kinds, and keep the tail only for terminal. Detect JSON on the full `detail` (with a size guard), then cap the rendered lines.
- **P2 · perf · chat_screen.dart:3261-3271, 3283** · `_diffCountsOf` splits the entire `toolDetail` on every build of every tool card (including the live row, which rebuilds per tick). `_tryJsonFormat` does a full `jsonDecode` + pretty-print on every build. · CPU waste with big outputs (100 KB+ diffs or JSON). · Memoize per message (cache on `Message` or in State keyed by `detail.length`/hash).
- **P2 · lifecycle · chat_screen.dart:3227-3235, 3277** · The sweep animation starts only in `initState`. A card that becomes `running` after creation (row reuse, state flips from `unknown` to running on resume) never animates. There is no `didUpdateWidget`. · Missing live affordance in edge cases. · Start or stop in `didUpdateWidget` based on `toolState`.
- **P2 · a11y · chat_screen.dart:3298-3418** · The summary row is 30 dp tall. The nested "Open" link is about 20×16 dp (10.5 sp text + 12 dp icon, 4 dp padding) and sits inside the parent `InkWell`. Tool state (running/error/stopped) is only a coloured dot or animation, with no semantics. · Missed taps (it opens/closes the card instead of the subagent), and TalkBack doesn't announce failures. · Give "Open" a 48 dp target outside the row's ink. Add `Semantics(label: '$title, ${stateLabel}', button: hasDetail, expanded: _open)`.
- **P2 · UX · chat_screen.dart:3361-3371** · The `+N −M` chip uses one colour (success green) for both counts. · Deletions read as additions. · Colour `+N` success and `−M` danger, as in `_DiffLine`.
- **P2 · copy · chat_screen.dart:3771-3822** · "Mermaid diagram" only shows the source text. Nothing is rendered. · The label promises a diagram. · Rename it to "Mermaid source", or render it through the existing HTML artifact WebView.
- **P2 · UX · chat_screen.dart:3851-3859, 3956** · Lines with no URL or colour render as plain `Text` inside an enriched block, while other paths use `SelectableText`. So selectability depends on whether any line contains a URL. · Can't select or copy some tool output. · Use `SelectableText.rich` throughout, and add a Copy button in the detail header.
- **P2 · UX · chat_screen.dart:3592-3598** · The compare and palette views are chosen by `toolName.contains('compare')`/`'color_palette'` substring. Any MCP tool whose name contains "compare" with `## ` in its output (e.g. `git_compare`) gets the tabbed model-compare view. · Misrendered third-party tool output. · Match exact built-in tool ids.

**Missing features**
- A Copy button for the tool input and output. "Show raw input" (arguments JSON) for MCP tools, which Claude Code shows on expanding a tool call.
- An MCP server badge on tool rows (`server · tool`), so users can see which plugin acted.
- Per-tool duration on the row.

**Test to add**
- Tapping a URL in tool output opens a confirm sheet showing the host. `launchUrl` is not called until confirm.
- Output `"- item one\n- item two"` from a non-edit tool renders without `_DiffLine` widgets.
- 40-line pretty JSON in tool detail renders the "JSON" block when expanded and collapsed.

## 16. Full-screen diff viewer (`_DiffViewerScreen`)

**What it is / how reached:** chat_screen.dart:4167-4210. The "open full" link in an expanded edit/commit tool card's diff header (L3548-3558).

**Findings**
- **P2 · a11y · chat_screen.dart:3548-3558** · The "open full" entry point is a bare 11 sp text in an `InkWell`, about 16 dp tall. · Hard to hit. · Use a `TextButton` with a min size of 48.
- **P2 · UX · chat_screen.dart:4201-4206** · Each line is its own `SelectableText`, so a selection can't span lines. Only "Copy diff" (everything) works. There are no line numbers, no hunk navigation, and long lines wrap, which breaks indentation readability. · Reviewing code changes on a phone is painful. · Use one `SelectionArea` around the list, add old/new line-number gutters parsed from `@@` headers, and put long lines in a horizontal scroll (a "Wrap lines" toggle).
- **P2 · multi-file · chat_screen.dart:4173-4180** · The title takes only the first line. Multi-file diffs (`commit`) show only the first path, with no file list. · Hard to navigate commits. · Parse `diff ` headers into a file index (drawer or chips).

**Missing features**
- "Open in Studio" for the file, and "Revert this change" (Claude Code supports rewinding edits via checkpoints).

**Test to add**
- A diff with 2 `diff ` headers shows both paths in the file index.

## 17. Compaction row (`_CompactionRow`)

**What it is / how reached:** chat_screen.dart:4215-4296. The inline "Context compacted — N messages" event. Tapping it reveals the summary.

**Findings**
- **P2 · a11y · chat_screen.dart:4234-4270** · The row is about 26 dp tall. "View summary" is 10.5 sp accent text, and there are no expanded semantics. · Small target. · Min height 44, plus `Semantics(button:true, expanded:_open)`.
- **P2 · UX · chat_screen.dart:4282-4290** · The summary is an unbounded 11 sp mono `SelectableText`. A long summary becomes one giant list row, and there's no copy. · Hard to read and scroll. · Render the markdown (`_OvidMarkdown`), cap the height with internal scroll, and add Copy.

**Missing features**
- No "undo compaction" or "view messages before compaction". Claude Code keeps the full transcript reachable (Ctrl-R).

**Test to add**
- Tapping the row toggles the summary. Semantics show `expanded`.

## 18. Produced files card and "all files" sheet (`_ProducedFilesCard`)

**What it is / how reached:** chat_screen.dart:4300-4534. Shown at the transcript tail when the agent is idle and `AgentService.producedFiles` (the active session's latest run, agent_service.dart:1556) is non-empty. Tapping a chip opens the file in Studio. "+N files" opens a sheet with "Show in folder".

**Findings**
- **P2 · functional (Android) · chat_screen.dart:4381-4405** · "Show in folder" calls `launchUrl(Uri.file(dir))`. On Android, `file://` intents to other apps are blocked (`FileUriExposedException`), or `launchUrl` returns **false** without throwing. The `false` return value is ignored, so either nothing happens or the misleading "No file manager app" message appears. · A dead button on the main target platform. · On Android, use a `content://` URI through FileProvider / SAF `ACTION_VIEW` on the document tree, or hide the button and offer "Share file" / "Open in Studio". Check the bool result.
- **P2 · persistence · chat_screen.dart:1494-1499** · The card comes from in-memory run state. It disappears after app restart or when the next run starts, and it isn't attached to the turn that produced the files. · Users lose the quick link to outputs from earlier turns. · Store produced files on the final assistant message of the turn (`Message.produced`) and render the card under that message.
- **P2 · a11y · chat_screen.dart:4427-4461** · Chips are about 26 dp tall. The full path is only in a long-press `Tooltip`. · Small targets, and the path is hidden from screen readers. · Min height 40–48, and set the `Semantics` label to the full path.
- **P2 · layout · chat_screen.dart:4476** · A hardcoded `right: 40` margin wastes 40 dp on a 360 dp phone. · A cramped chip lane. · Make the margin proportional, or drop it below 600 dp.

**Missing features**
- Share or export the produced files (Android share sheet), and preview images or HTML inline. ChatGPT shows downloadable file cards in place.

**Test to add**
- Android platform override: "Show in folder" doesn't call `launchUrl` with a `file://` URI, and shows a working alternative.

## 19. `chat_layout.dart` (ChatLayout width axis + Aether transcript primitives)

**What it is / how reached:** `ChatLayout` (chat_layout.dart:11-30) sets the readable column, composer and user-bubble widths for ChatScreen, ChatTranscript and the composer. `AetherSurface`, `ChatMessageRow` and `ChatToolCallCard` (L49-285) are the "additive" Aether rows.

**Findings**
- **P2 · layout (latent) · chat_layout.dart:25** · `composerWidth` clamps to `viewportWidth`, not to the pane (`viewportWidth - sidebarWidth`). With `sidebarWidth > 0` and a pane under 712, `contentWidth == pane`, so the composer is pane + 32 and overflows the pane by 32 dp. Current callers pass no sidebar (chat_screen.dart:1362), so this is latent. · A future tablet caller would get a clipped composer. · Clamp to `pane`.
- **P2 · layout · chat_layout.dart:21** · Between 680 and about 1062 dp of pane, the column is pinned at the 680 minimum. On a 700 dp foldable or small-tablet pane, that leaves 10 dp gutters each side (before the 16 dp list padding), so the content runs almost edge to edge, while a 1100 dp pane gets generous margins. · Uneven reading width on foldables. · Use one smooth rule, for example `min(920, max(pane - 48, pane * 0.64))` for panes ≥ 600.
- **P2 · dead code · chat_layout.dart:88-285** · `ChatMessageRow`, `ChatToolCallCard` and `AetherSurface` are referenced by no file in `lib/` (only tests). `chat_screen.dart` keeps its own `_ToolCard` with different behaviour (cap, diff, rich output). · Two diverging tool-card implementations. Fixes land in one and not the other. · Either migrate `_ToolCard` onto `ChatToolCallCard` (moving the rich body into it), or delete the unused primitives and their tests.
- **P2 · a11y · chat_layout.dart:242-265** · (If kept) the `ChatToolCallCard` "Details" toggle is about 24 dp tall with no expanded semantics. The detail `Text` is unbounded, not selectable, and has no line cap. · The same issues as section 15. · Use a min height of 48, `Semantics(expanded:)`, `SelectableText`, and a height cap.
- **P2 · contrast · chat_layout.dart:136, 184-190** · The user bubble is `accentSoft` with body text, and the state pills use `warnLight`/`textFaint` on surface. These pairs have no contrast assertions. · Possible WCAG failures in the light theme. · Add contrast unit tests for these token pairs (group 08 covers theme maths).

**Test to add**
- `ChatLayout(viewportWidth: 1000, sidebarWidth: 320).composerWidth <= 680`.

## 20. Cross-cutting: motion, animation controllers, theming (`_RowIn`, `_ChaseDot`, `_ShimmerText`, tool sweep)

**What it is / how reached:** chat_screen.dart:146-301 and 3221-3446. Entrance animation for every row, and looping indicators for live rows.

**Findings**
- **P2 · a11y · chat_screen.dart:153-185, 197-243, 256-301, 3230-3234** · None of the animations check `MediaQuery.disableAnimationsOf(context)`. Shimmer, chase dots and glare sweep loop forever, and every row slides in. · Users with "Remove animations" on (vestibular disorders) still get constant motion. · Read `disableAnimations`. Render static states (`_c.value = 1`, no `repeat()`) when it is true.
- **P2 · UX · chat_screen.dart:143-145, 311, 323** · `_RowIn` claims to play once, but `ListView.builder` disposes off-screen rows. Every row re-animates when it scrolls back in, and all prepended rows fade in on paging. · Flicker while scrolling history. · Animate only rows whose message index is ≥ the count at first build (new rows). Pass `animate: isNew` from the list.
- **P2 · theming · chat_screen.dart:281-288** · The shimmer gradient hardcodes `0xFF4176E6`/`0xFFD3E2FF` instead of `Aether.accent` tokens. · Wrong accent in themes or the light/dark switch. · Derive the colours from `Aether.accent` and `Aether.accentSoft`.

**Test to add**
- With `MediaQueryData(disableAnimations: true)`, a running tool card has no animating `AnimationController` (`tester.hasRunningAnimations == false`).

---

## Group summary

**Totals:** 20 sections, P0 0, P1 7, P2 95. None of these are crash or data-corruption P0s. The streaming rebuild storm and model-catalog 503 are known and tracked on their own branches.

**Top 10 fixes, in order**
| # | Fix | Sections | Sev | Effort |
|---|---|---|---|---|
| 1 | Apply `showReasoning` inside the fold run collector (and the bounded snap predicate) so "Show reasoning: off" really hides thinking | 1 | P1 | S |
| 2 | Confirm-before-open for URLs in tool output (show decoded host, strip userinfo). Dispose the `TapGestureRecognizer`s | 15 | P1 | S |
| 3 | Send-path feedback and a guard: snackbar + Plugins link when a skill is unavailable; re-entrancy flag around `CommandService.execute`; reason on queue rejection; actions on the "add key" / "model unavailable" snackbars | 6 | P1 | S |
| 4 | Persist composer drafts per session (debounced), restore on bind, clear on submit | 3 | P1 | M |
| 5 | Model picker: effort support from catalogue metadata/allowlist instead of substrings; tap-to-select with default effort; lazy per-model slivers; recents filtered by `hasKey`; "Open Settings" goes straight to Providers | 12 | P1/P2 | M |
| 6 | Subagent `ChatTranscript`: add the pager ("Load earlier"), reuse the cached window helper, use pane width (`LayoutBuilder`), read-only actions | 2 | P1 | M |
| 7 | Tool-card rendering correctness: a real diff signature check, head-cap for non-terminal output, JSON detection on the full detail, memoized diff/JSON parsing, two-colour `+N −M`, exact tool-id matching for compare/palette | 15 | P2 | S–M |
| 8 | Accessibility pass on chat chrome: 48 dp targets and `Semantics` (model title, jump pill, stats line, context ring, tool rows + "Open", strips, reasoning, compaction, produced chips), fixed reasoning chevron direction, `disableAnimations` honoured by all loops, `_RowIn` only for new rows | 4, 5, 7–9, 14–18, 20 | P2 | M |
| 9 | Context and usage: live-updating context sheet, "Compact now" button, per-session source (not `_run`), contradictory context limit fixed; credits instead of list-price `$` for Ovid Cloud; per-MCP-server context breakdown (Claude Code `/context` parity) | 7, 8 | P2 | M–L |
| 10 | Pinch zoom: keep the scale local during the gesture and persist on end, clamp the combined system×chat scale, "Reset zoom" chip | 5 | P2 | S |

**Also quick (S):** failed-job dot colour + tap-to-view-log entry (11); "New session" reuses an empty chat (4); empty-state "connect a model" CTA when nothing is configured (13); Android-safe "Show in folder" (18); scrollable mode sheet + warning for auto-approve modes (10); `composerWidth` clamp to the pane (19).

**Suggested PR grouping:** (A) items 1+2+3 in one small correctness/safety PR. (B) item 4 + section 3 stale `_queueEdits`. (C) item 5 picker. (D) item 6 + section 9/14 expansion-state map. (E) item 7. (F) items 8+10 a11y and motion. (G) item 9 usage and context, which coordinates with group 05 `usage_screen`/`cloud_usage_status`. Decide early on the dead `ChatToolCallCard`/`ChatMessageRow` primitives (migrate or delete) so that E and F don't fix two implementations.
