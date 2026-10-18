# Task 16 — Browser screen → P6 screencast + on-device browser removal

Status: IMPLEMENTED (full-suite verification in progress)

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
- `flutter analyze` → **No issues found!**
- `flutter test --no-pub test/cloud_browser_stream_test.dart` → **6/6 passed**
- `test/ui_redesign/browser_screen_test.dart` → **3/3 passed**
- `flutter build apk --debug` → **✓ Built app-debug.apk**
- Acceptance grep `WebviewPool|SessionBrowserProfiles|webview` in `lib/`
  excluding `html_artifact` → **empty**
- Full `flutter test --no-pub` → pending
