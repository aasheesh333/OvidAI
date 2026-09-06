# Design: Control Mode, Service Reliability, Real File Handling & Play Safety

**Date:** 2026-09-06
**Status:** Approved sections spec (post-brainstorm)
**Branch base:** `hoplite/gortyn-77773150` @ `3f631f4`
**Gate files:** `lib/core/agent_service.dart`, `lib/core/state.dart`, `lib/core/agent_notification_service.dart`, `lib/core/mcp_service.dart`, `lib/main.dart`, `lib/ui/plugins_screen.dart`, `lib/ui/browser_screen.dart`, `android/app/src/main/AndroidManifest.xml`

This spec bundles six approved workstreams into one integrated scope. Each section is independently implementable and independently testable; the tracking table in §1 is the single source of truth for status.

---

## 1. Integrated Scope Tracking

| # | Workstream | Section | Depends on | Acceptance signal |
|---|-----------|---------|-----------|-------------------|
| W1 | Control mode (Phase A: in-app surface) | §2 | W6 | `AgentMode.control` exists, gated like `drive`+, tools denied in safe/plan |
| W2 | MCP/plugin re-init + tri-state health | §3 | — | Resume re-inits MCP **and** plugins; UI shows gray/amber/green/red, never stale binary |
| W3 | Real browser file handling | §4 | — | Downloads stream to disk (no in-memory cap wall); uploads chunk; user page uploads work via file selector |
| W4 | Queue / Stop / Keep-alive semantics | §5 | — | Stop semantics per spec; keep-alive keeps foreground service with "Ready & Listening" |
| W5 | Play-safety guardrails | §6 | W1 | No new sensitive permissions; MANAGE_EXTERNAL_STORAGE de-risked; disclosure flows documented |
| W6 | Accessibility disclosure flow (designed, gated off) | §2.4 | W1, W5 | Sheet exists, wired behind a `const kEnableDeviceControl = false` flag |

Constraints carried from prior plans (still binding):

- Downloads land in the session workspace (agent-readable, containment-checked), never public Downloads.
- Read-Only + plan-mode gates stay: every new interactive tool MUST be denied in both gates.
- Zero reference-web mentions in `lib/` + `test/`.
- Do not break the green test suite; TDD RED→GREEN per task in the implementation plan.

---

## 2. Control Mode Architecture

### 2.1 Mode enum

Extend `AgentMode` (`lib/core/agent_service.dart:75`) with `control`:

```
enum AgentMode { safe, auto, drive, studio, control }
```

- Display name: `'Control'`; icon `Icons.accessibility_new_outlined`; color `Aether.danger` (distinct from drive's warn amber).
- `_modeRank` (`agent_service.dart:10107`) becomes: safe 0, auto 1, studio 2, drive 3, **control 4**. Child sessions inherit capped ranks exactly as today; control is never inherited by subagents — children of a control session run at `drive` (a subagent touching the device surface is not allowed).
- Tool schema `mode` enum (`agent_service.dart:3571`) gains `'control'`.
- `/permission` in `lib/core/commands.dart:268-279`: switching to `control` requires the same explicit `confirm` flag as `drive`, PLUS a one-time in-chat disclosure card (see §6.4). Session modes stay per-session independent (`state.dart:528-529`).

### 2.2 Phase A — in-app control surface (ships now)

Control mode in Phase A means **the agent drives the app's own WebView and in-app UI** with real input events, not only synthesized JS. No Android system permission is needed.

New tools (all denied in Read-Only + plan gates, all ` _mutatingTools`):

| Tool | Args | Mechanism |
|------|------|-----------|
| `device_tap` | `selector?`, `x?`, `y?` | CSS selector → `getBoundingClientRect` center, then Android `Input`-less fallback: `runJavaScript` dispatch of `pointerdown/pointerup` with `isTrusted`-ish coordinates on the tab controller; coords-only taps hit the active tab viewport |
| `device_type` | `selector?`, `text`, `submit?` | Focus element, then `controller.runJavaScript` `dispatchEvent(new InputEvent(...))` per char fallback to existing `browser_type` path; `submit` presses Enter via existing keycode map |
| `device_swipe` | `from_x,from_y,to_x,to_y`, `steps?` | JS pointer-event interpolation (same pattern as `browser_drag` steps, §fidelity prior work) |
| `device_snapshot` | — | Thin alias of `browser_snapshot` accessibility-tree text; kept separate so gates/policies can evolve independently. Phase A adds no new capture API |

Final Phase A tool set (four): `device_tap`, `device_type`, `device_swipe`, `device_snapshot`.

Behavior rules:

- All four resolve against `_activeTab` of the run's session (run-Zone resolution, same as A11 fix).
- When no browser tab is open in that session, tools return `'Control surface not available — open a page first (browser_open).'`.
- `device_*` tools imply nothing about the OS; they are namespaced for Phase B continuity.

### 2.3 Phase B — device-wide control (deferred, pre-designed)

Phase B adds an `AccessibilityService` (Kotlin) exposing `performGlobalAction` + node queries over a MethodChannel, guarded by:

- `const kEnableDeviceControl = false;` in `lib/core/state.dart` — compile-time gate; every Phase B call site checks it.
- Play policy: accessibility use must be for the user's own agent-assistance purpose; disclosure copy in §6.4 is written for that framing.
- Phase B is NOT implemented in this scope; only the flag, the disclosure sheet, and the tool-name reservation ship.

### 2.4 Accessibility permission flow (Phase B only, gated off)

When (and only when) `kEnableDeviceControl` is true and the user switches to control mode:

1. Disclosure sheet: what device control can do, what it cannot (no passwords typed on behalf of the user, no financial apps — denylist in §6.5), local-only, revocable anytime.
2. Accept → `Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)` with our service highlighted via `EXTRA_FRAGMENT_ARG_KEY`.
3. On resume, check `AccessibilityManager.getEnabledAccessibilityServiceList`; if absent, mode falls back to Phase A surface with a persistent inline notice.

---

## 3. MCP / Plugin Re-initialization + Tri-state Health

### 3.1 Current state

- Startup: `AppState.I.reconnectMcpServers()` (`main.dart` initState).
- Resume: same call in `didChangeAppLifecycleState` resumed branch; `paused` intentionally does nothing (tearing down mid-run kills in-flight `mcp__` calls).
- Plugin runtimes are **not** re-initialized on resume — after backgrounding, plugin-provided tools can 404 while the Plugins screen still shows the last known `server.connected` boolean (`plugins_screen.dart:620-621`).

### 3.2 Tri-state health model

Add to `state.dart`:

```dart
enum ServiceHealth { connecting, working, failed }

class ServiceStatus {
  ServiceHealth health;
  String detail;      // '' | 'dead: exit 1' | '3 tools' | 'retry in 9s'
  DateTime updatedAt;
}
```

`AppState.serviceStatus` = `Map<String, ServiceStatus>` keyed by `mcp:<name>` and `plugin:<id>`. Transitions:

- connect call issued → `connecting` immediately (UI: amber/gray pulse).
- handshake ok (MCP `initialize` ack / plugin runtime ready) → `working` (green).
- handshake fail, process death (`_lastDeath` diagnostics from `mcp_service.dart`), or retry-budget exhausted → `failed` (red) + `detail` carries the reason.
- Retry loop keeps status `connecting` with `detail: 'retry in Ns'` while budget remains.

### 3.3 Re-init wiring

- `reconnectMcpServers()` (`state.dart:2787`) additionally calls `PluginRuntime.reinitAll()` (new): restarts runtimes whose persisted state is "user wants connected", re-registers their tools into the dispatch table.
- Both startup and resume paths call the same function; resume first marks every expected service `connecting` so the UI never shows stale green.
- `plugins_screen.dart` connect button + status rows render from `serviceStatus` instead of `server.connected` (keep the field as the source of truth for connection intent, not health).
- Health screen gains the same tri-state row per service.

---

## 4. Real Browser File Handling

### 4.1 Download path (replace in-memory cap)

Current: `HttpShim.get(..., maxResponseBytes: 20MB)` fully buffered (`agent_service.dart` `_handleBrowserDownload`). Design:

- Add streaming variant: Dart `HttpClient` GET with the tab's cookies NOT injected (agent downloads stay server-side plain, matching today's behavior) writing straight to `containedPath(work, name)` in 64KB chunks.
- New cap: **200MB** per file, checked against `FileSystemEntity` free space first (abort with clear message under 1.2× headroom).
- Progress: `_emit('nav', 'downloading: name (x.y MB / total)')` every ~2s max.
- Result message unchanged shape: `'downloaded ✓ · name · N bytes (workspace — read with read_attachment)'`.
- Session-workspace containment rule unchanged; never public Downloads (binding constraint).

### 4.2 Upload path (chunked, no base64 wall)

Current: whole-file base64 in one JS string, 10MB cap. Design:

- Stage file to JS in **256KB base64 chunks** via `runJavaScript` appending to `window.__ovidUploadBuf` (array of strings), then finalize: assemble `Uint8Array` → `File` → `DataTransfer` → assign `el.files` + dispatch `input`/`change`. Buffer cleared on success/failure.
- New cap: **50MB** (chunking removes the string-length wall; memory is chunk-sized on both sides).
- Keeps the existing selector contract (`selector` must be `input[type=file]`).

### 4.3 User-initiated page uploads (file selector)

`AndroidWebViewController.setOnShowFileSelector` (available in the locked webview_flutter 4.8 line) is currently unhooked — `<input type=file>` taps from the page silently do nothing. Design:

- In `controllerForTab`, register the callback; forward to platform file picker (`file_picker` is already in the tree via attach sheet — confirm dep; else `image_picker`+SAF intent through the existing channel) and return the selected URIs to the WebView via the controller's `onShowFileSelector` result path.
- Multi-select honored when `mode` is `multiple`.
- This is a USER action path — it bypasses agent gates entirely (no tool involved), but logs a `('shell', 'file chooser: n files')` event for the transcript.

### 4.4 User-visible downloads (SAF export)

Agent downloads stay in the session workspace. A separate user action — "Save to device" on a produced-file chip (chat attachment preview, `chat_screen.dart:1866` pill region) and in browser omnibar menu (`browser_screen.dart:74-75`) — uses Storage Access Framework:

- First use: `ACTION_OPEN_DOCUMENT_TREE` picker; persist granted URI permission + path string in `SharedPreferences` (`ovid_saf_export_dir`).
- Subsequent exports copy the file into that tree via a small platform-channel helper (`safCopy` in the existing Kotlin method channel; create the file with `DocumentsContract.createDocument`, stream bytes).
- No `MANAGE_EXTERNAL_STORAGE` involvement anywhere in this flow (§6).

---

## 5. Pre-compaction Items: Queue / Stop / Keep-alive / Modes

These were captured before context compaction and are now specified in full.

### 5.1 Message queue semantics (existing, formalized)

- Per-session outgoing queue exists; `_drainQueueIntoMsgs` (`agent_service.dart:4219`) is invoked after the final response of a run (call sites `:5388`, `:5517`).
- Formal rule: while a run is active, new user messages are queued (composer shows queue depth badge); on run completion they are appended to `msgs` in order and ONE continuation run starts. No implicit parallel runs per session (matches activeRunId re-entry refusal from STAB1).

### 5.2 Stop semantics (changed)

Current: Stop button → `AgentService.I.cancelAllRuns()` (`chat_screen.dart:4181`) — kills everything, queued work included implicitly (queue drains only after a *completed* run; a cancelled run leaves the queue orphaned).

New rule, decided pre-compaction:

- **Queue non-empty:** Stop aborts the CURRENT turn only, then immediately dispatches the next queued message as a fresh run. Rationale: user queued a correction; they want the correction to run, not silence.
- **Queue empty:** panic stop — cancel run, kill run-scoped processes (`killRunProcesses` from STAB1), clear pending approval.
- Notification Stop buttons (`agent_notification_service.dart:79-81`) get the same two-branch logic via a shared `stopRequested()` on AgentService.
- Composer Stop label surfaces the branch: `Stop (2 queued → next runs)` vs `Stop`.

### 5.3 Keep-alive (changed)

Current: `agentIdle()` (`agent_notification_service.dart:140-148`) stops the foreground service whenever no run is active. That kills the process on OEM-aggressive devices → scheduled runs (`schedule_create`) and queued follow-ups never fire while the app is backgrounded.

New rule:

- Persist setting `ovid_keep_alive` (default ON after first explicit notification-permission grant, else OFF; toggle in Settings).
- With keep-alive ON: `agentIdle()` does NOT call `agentServiceStop`; it updates the notification to `'Ready & Listening'` (`agentServiceUpdate`), keeps `FOREGROUND_SERVICE_DATA_SYNC` type, and `_active` stays true. A real run switches text back to working form via existing `agentWorking`.
- With keep-alive OFF: behavior unchanged (service stops on idle).
- Toggling keep-alive off while idle stops the service immediately.

### 5.4 Mode persistence

- Session `mode` already persists per session; control mode (§2) persists too, but on cold start a session saved as `control` reloads as `drive` with a one-tap "Re-enable Control" chip (never silently re-arm the strongest mode).

---

## 6. Play-Safety Guardrails

### 6.1 Permission posture

Manifest today (`AndroidManifest.xml`) declares a wide set incl. `MANAGE_EXTERNAL_STORAGE` (:29), `CAMERA`, `RECORD_AUDIO`, contacts, location, phone. Guardrails:

1. No NEW permission in this scope. Phase A adds none; Phase B's accessibility service would add none (user-granted in Settings, not manifest-requestable).
2. `MANAGE_EXTERNAL_STORAGE` is de-risked: §4.4 SAF export replaces the only flows that leaned on it; if no code path still requires all-files access after this scope lands, a follow-up removes the declaration (tracked in W5, not executed here — removal may break Studio's pinned-folder flows and needs its own audit).
3. Every runtime permission request happens point-of-use with a purpose string; never at launch (existing pattern; regression-tested via audit note in this spec).

### 6.2 Foreground service justification

`dataSync` type is correct for agent-run processing. Keep-alive (§5.3) extends lifetime; the notification always reflects true state (working / ready) — never a silent persistent notification (Play spam policy). Keep-alive is user-toggleable and OFF by default for users who never granted notifications.

### 6.3 Telemetry / data safety

Telemetry consent dialog (`main.dart` `_maybeAskConsent`) unchanged; any new event types added by §3 (`serviceStatus` churn) stay local — nothing leaves the device in this scope.

### 6.4 Control-mode disclosure copy (final)

> **Control mode lets Ovid operate the app on your behalf** — tapping and typing inside pages you opened. It never sees other apps in this version, never autofills passwords, and every action is logged in this chat. You can switch modes any time; switching down takes effect immediately.

(Phase B copy will extend this with device-wide wording + accessibility-policy paragraph; written when `kEnableDeviceControl` turns on.)

### 6.5 Hard limits enforced in code

- Control-mode tool dispatch refuses when `_activeTab` URL matches a denylist: banking/payments keywords configurable via `presets` (`deniedControlDomains`, default `['paypal.com', 'wise.com']` + bank TLDs list) — refusal message explains and suggests Read-Only.
- `device_*` tools are double-gated: mode gate (control only) AND safe/plan gate (denied), so a control session entering plan mode loses them.

---

## Out of scope

- Phase B AccessibilityService implementation.
- MANAGE_EXTERNAL_STORAGE removal (needs separate Studio-folder audit).
- iOS equivalents (project ships Android).
- BrowserTab cookie-per-session isolation (tracked as B9, separate).

## Verification summary (plan-level)

Every workstream gets RED→GREEN tests in `test/core_regression_test.dart`: mode gate denials (W1), status transitions via `serviceStatusForTest` (W2), streaming download chunk-writes + upload chunk assembly via pure helpers (W3), stop-branch + keep-alive idle via `agentIdleForTest` (W4), denylist refusal (W5). `flutter analyze` clean; full suite green before each commit.
