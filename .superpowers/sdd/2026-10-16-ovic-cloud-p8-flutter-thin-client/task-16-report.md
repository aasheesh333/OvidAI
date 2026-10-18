# Task 16 — Browser screen → P6 screencast + on-device browser removal

Status: IMPLEMENTED — commits `662050fc6fd15c4d2bc925eb28df5b4bb841e53f`
(feature) and `b6f1714732d9f8a5bd3b6cfccf0730f2bff67d94` (multiplexer
binary-frame pin).

## Files
### New
- `lib/core/cloud/browser_stream.dart` — `BrowserFrame`, `BrowserState`,
  `BrowserStreamClient` over `WsMultiplexer`.
- `test/cloud_browser_stream_test.dart` — 6 tests (real 1×1 WebP decode,
  takeover-before/after-ack input gate, input union, detach, state filtering,
  widget render).
- `lib/core/cloud/cloud_ws.dart` — added `binaryServerFrames` (the binary
  half of the P6 channel; text frames still ride `rawServerFrames`).

### Rewritten
- `lib/ui/browser_screen.dart` — tab strip + read-only address chrome +
  screencast canvas + gesture forwarding + server-acked takeover chip.

### Deleted
- `lib/core/webview_pool.dart`, `lib/core/session_browser_profiles.dart`,
  `lib/core/session_data_sharing.dart`.
- `android/.../OvidWebViewHandler.kt`, `android/.../OvidBrowserProfiles.kt`
  and the two JVM capture tests.
- 25 on-device-browser Dart test files (desktop mode, geolocation, popups,
  screenshots, profiles, etc.).
- The on-device browser block in `agent_service.dart` (BrowserTab,
  tab persistence, WebView controller plumbing, `browser_*` tool definitions
  and dispatch cases, preview tool), plus its prompt copy.
- state/settings wiring: `clearWebCookies`, restart sharing, desktop-mode
  preference, `onSessionSwitched`, browser-cookie storage row.

### Modified
- `chat_screen.dart` — header button now gated on `Distribution.cloudBrowser`
  and opens `BrowserScreen(sessionId:)`; link taps pass the active session.
- `state.dart`, `settings_state_integration.dart`, `settings_screen.dart`.
- Affected tests (gate polarity, cookie row, plan-mode browser group, SSRF
  browser helper, token-budget roster).
- `MainActivity.kt` no longer constructs the removed handler; the
  `HtmlArtifactViewFactory` stays (D5).

## Server shape (built P6, reconciled — server wins)
- WS client → server: `browser_attach{sessionId}`, `browser_detach{sessionId}`,
  `browser_input{sessionId,input}`, `browser_takeover{sessionId,enabled}`.
- WS server → client: `browser_state{state: BrowserStateDto}` (JSON) and
  screencast frames as raw BINARY WS messages (image bytes only; the gateway
  strips redis's 1-byte format prefix).
- Takeover ack = a subsequent `browser_state` with `takeover: true`.
  `takeoverActive` is never set optimistically; `sendTap/Scroll/Key` are hard
  no-ops while it is false.
- **Deviations from the plan's pinned client interface (documented in the
  file header):**
  - There is NO P6 REST tab-list endpoint and no `tabId`. The gateway allows
    ONE attach per socket keyed by `sessionId`; `browser_state` describes the
    session's active page. `BrowserTabDto` / `tabs()` / `attach(sessionId,
    tabId)` are therefore not implemented; the tab chrome renders the single
    server tab from state.
  - The binary channel carries no dimensions or format. The client decodes
    the image for width/height and reads `frameFormat`/`viewport` from the
    latest `browser_state`.
  - There is no viewer navigation op (`BrowserInputEvent` has no navigate);
    the address row is read-only and the server/agent owns navigation.

## Gates
- `flutter analyze` → **No issues found!** (also re-run in a clean
  `git worktree` at the commit: **No issues found!**)
- `flutter test --no-pub test/cloud_browser_stream_test.dart` → **6/6 passed**
- `test/ui_redesign/browser_screen_test.dart` → **3/3 passed**
- `flutter build apk --debug` → **✓ Built app-debug.apk**
- Acceptance grep `WebviewPool|SessionBrowserProfiles|webview` in `lib/`
  excluding `html_artifact` → **empty**
- Full `flutter test --no-pub` → **3729 passed / 6 skipped / 0 failed**
  (exit 0), run in a CLEAN `git worktree` at `b6f1714` (not the shared
  working tree). Parent baseline (`662050f^`, same clean-worktree method):
  **3988 passed / 7 skipped / 0 failed**.
  Delta −259 passed / −1 skipped, fully attributed:
  - −251 passed / −1 skipped: the 25 deleted on-device-browser test files
    (measured by running exactly those files against the parent tree).
  - −14: removed browser-behaviour assertions in surviving suites
    (`browser_screen_test` 7→3, `settings_error_states` 6→3,
    `browser_subagent_trajectory` 5→4, `settings_screen_test` 5→4,
    `p4_studio_browser` 5→3, `plan_mode_allowlist` 13→11,
    `settings_actions_integration` 18→17, `security_ssrf_guard` 8→7)
    plus +1 new multiplexer binary-frame pin.
  - +6: new `test/cloud_browser_stream_test.dart`.
  - The −1 skipped is the one skipped test inside `ui_finish_12_browser_test`.
  No unexplained failures; no known-flake reruns were needed (both runs were
  green).
- 58 paths changed across the two commits (+3,162 / −15,548).

## Fix round 1 — browser wiring

Review: `task-16-review.md`, written against `662050f`. Every finding was
re-verified in the current working tree before changing anything; all were
still open. Fix commit: `02c0bbf` (7 paths, committed pathspec-only).
The LOW off-contract cast was fixed opportunistically as part of the error
handling. The LOW orphaned-settings/prefs items belong to another lane and
were left untouched.

### CRITICAL — the viewer attached with the LOCAL chat id

**Open.** The header passed `s?.id`, `_openLink` passed
`AppState.I.activeSessionId`, and the `/browser` route fell back to
`AppState.I.activeSession?.id`. Those are `ChatSession.id` values
(`DateTime.now().microsecondsSinceEpoch.toString()`), not UUIDs. The gateway
guards with `isUuid` + an ownership lookup (`ws.ts:757`) and answers
`forbidden`, so no attach was ever created.

**Fix.** `_BrowserScreenState._attachResolved` now resolves once at the
screen boundary: it awaits `CloudSessionStore.I.ready`, then calls
`attach(store.serverIdFor(localId) ?? localId)`. Every call site (header
button, `/browser` deep route, any future caller) goes through the screen,
and `BrowserScreen.open` still accepts the local id. A server id that has no
local mapping falls through unchanged.

**Pin.** `test/cloud_browser_stream_test.dart` — "attaches with the MAPPED
server id, not the local chat id": seeds `ovid_cloud_session_ids` with
`local → UUID`, opens the screen with the local id and asserts the
`browser_attach` frame names the UUID. Removing the resolver makes the test
fail on the local id.

### HIGH — attach failures and channel errors were invisible

**Open.** `BrowserStreamClient._onRawFrame` consumed only `browser_state`;
`WsMultiplexer._onErrorFrame` routed session-scoped errors to
`sub.events.addError` / `debugPrint` and copied only `ptyId`-scoped errors to
`rawServerFrames`. Browser errors carry `sessionId`, so the viewer could
never see `forbidden`, `unavailable`, `internal`, or `not_attached`, and the
screen spun forever.

**Fix.** `WsMultiplexer` gained `watchSessionErrors`/`unwatchSessionErrors`
(the browser attach registers its session). `_onErrorFrame` copies a
session-scoped error to `rawServerFrames` when that session is registered;
the existing session-event routing is unchanged (no duplicate event).
`BrowserStreamClient` now handles `op == "error"` (matching `sessionId`,
storing `code`/`message` in `BrowserStreamError? error`), clears the error on
the next `browser_state`, and resets it on attach. `browser_screen.dart`
renders a real "Browser unavailable" state with the server message, code,
and a Retry button, and an 8-second bounded "The agent hasn't opened a page
in this chat yet." state with a "Check again" button instead of the
indefinite spinner.

**Pin.** `cloud_browser_stream_test.dart`: "a session-scoped error frame
becomes a readable client error", "an error for another session is
ignored", "an attach error is shown and Retry re-attaches" (asserts a second
`browser_attach`), and "an attached session with no frame says so after a
bounded wait". `cloud_ws_multiplexer_test.dart`: "(s2) a registered browser
attach also sees session-scoped errors on the raw lane" (also asserts the
raw lane stops after unwatch).

### MEDIUM — reconnect silently killed the screencast

**Open.** The gateway detaches the browser attach on socket close
(`ws.ts:370-378`), raw ops are not replayed, and the client never observed
`WsLinkState`. `attach()` also early-returned while already attached.

**Fix.** `BrowserStreamClient` listens to the multiplexer's link state. On
the first offline→online transition the queued attach is simply flushed; on
every later transition to `online` while attached it bumps the attach
generation, clears state/error/takeover, and re-sends `browser_attach`. The
screen also discards its frame when the generation changes, so a
pre-reconnect frame is never shown as live.

**Pin.** `cloud_browser_stream_test.dart` — "a link reconnect re-sends
browser_attach and clears stale state", using a fake multiplexer whose link
state flips `online → disconnected → online`.

### MEDIUM — binary frames could leak across sessions

**Open.** Frames carry no session id; a decode queued for session A was
checked only against `_sessionId != null`, so after `attach(B)` it could
paint into B.

**Fix.** A monotonic attach generation is captured when each binary frame
arrives and checked both before and after the decode; a frame from a stale
generation is dropped and its decoded `ui.Image` is disposed.

**Pin.** `cloud_browser_stream_test.dart` — "a decode queued for session A
never paints into session B": a gated decoder is in flight for A when B
attaches; releasing it emits nothing to B, while B's own frame still flows.

### MEDIUM — a link tap dropped the target URL

**Open.** `_openLink` opened the viewer with `openUrl`, which the viewer
stored and never read; the wire contract has no navigate input event.

**Fix.** Chose the system browser for web links on every build (the non-cloud
arm already did this). The dead `openUrl` field and the `url` parameter of
`BrowserScreen.open` were removed; the header button still opens the
read-only cloud viewer. Reason: the cloud viewer cannot honor the target
URL, and showing the agent's unrelated page would be misleading.

### MEDIUM — every frame was decoded twice

**Open.** `decodeBrowserFrame` decoded to learn dimensions and disposed the
image; `_FrameCanvas` then decoded the same bytes again via
`Image.memory`.

**Fix.** `BrowserFrame.image` now carries the decoded `ui.Image`; the
production decoder returns it instead of disposing it. `_FrameImage` paints
it with `RawImage`; the screen disposes the replaced image in a post-frame
callback, and the client disposes a frame dropped by the generation guard.
A test decoder without an engine image still falls back to `Image.memory`.

**Pin.** `cloud_browser_stream_test.dart` — "the production decoder returns
the decoded image (no second decode)" (asserts the image and its
dimensions).

### LOW — off-contract cast

`_onRawFrame` no longer casts `sessionId` before the guarded decode; a
non-string value is simply not a mismatch signal.

### Gates

| Gate | Result |
|---|---|
| `flutter analyze --no-pub` (working tree) | **No issues found!** (22.8 s) |
| `flutter analyze --no-pub` (`git archive` of `02c0bbf`) | **No issues found!** (8.6 s) |
| `flutter test --no-pub test/cloud_browser_stream_test.dart test/cloud_ws_multiplexer_test.dart test/ui_redesign/browser_screen_test.dart` | **43/43 passed** |
| Surviving browser suites (`html_artifact_browser`, `ui_redesign/browser_subagent_trajectory`, `p4_studio_browser`) | **6/6 passed** |
| `flutter test --no-pub` (full suite, working tree) | **1,715 passed / 2 skipped / 0 failed, exit 0** (1:45) |
| `flutter build apk --debug` (`git archive` of `02c0bbf`) | **✓ Built build/app/outputs/flutter-apk/app-debug.apk**, exit 0 (54.5 s) |

The full-suite count includes the other lanes' current tests (+5 relative to
the 1,701/2 baseline) and this round's +9 browser/ws tests. A separate full
run in the archive of `02c0bbf` was **1,761 passed / 2 skipped / 1 failed**;
the sole failure was `schedule_session_id_test`, whose implementation fix
(`app_router.dart`) was still uncommitted in another lane at that moment —
it passes in the working tree and is unrelated to these paths.


