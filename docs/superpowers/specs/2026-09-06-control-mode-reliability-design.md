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
| W1 | Control mode (device-wide, accessibility-backed) | §2 | W5 | `AgentMode.control` exists, confirm-gated; `device_*` tools drive any app; denied in safe/plan |
| W2 | MCP/plugin re-init + tri-state health | §3 | — | Resume re-inits MCP **and** plugins; UI shows amber/green/red, never stale binary |
| W3 | Real file handling, no caps | §4 | — | Downloads stream to disk and uploads chunk with no size ceiling; page file inputs work |
| W4 | Queue / Stop / Keep-alive semantics | §5 | — | Stop semantics per spec; keep-alive keeps foreground service as "Ready & Listening" |
| W5 | Play-safety guardrails | §6 | W1 | Accessibility disclosure + denylist + password refusal enforced; no silent screen reading |
| W6 | Screen reading without per-action screenshots | §2.3 | W1 | Node tree primary, dirty-flag cache, delta reads, node-handle taps; screenshot only on the three fallback cases |


Constraints carried from prior plans (still binding):

- Downloads land in the session workspace (agent-readable, containment-checked), never public Downloads.
- Read-Only + plan-mode gates stay: every new interactive tool MUST be denied in both gates.
- Zero reference-web mentions in `lib/` + `test/`.
- Do not break the green test suite; TDD RED→GREEN per task in the implementation plan.
- Ovid is the user's personal agent: within Control mode it may do anything the user can do on their own device, subject only to the §6.5 hard limits.


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

### 2.2 Device-wide control surface (ships now)

Control mode means **Ovid can do anything the user can do on their own device**. It is the user's personal agent: every tap, swipe, keystroke, and system navigation the user can perform, Ovid can perform, in any app.

Implemented via `OvidAccessibilityService` (Kotlin, `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt`), bridged to Dart over the existing `ovid/native` MethodChannel.

New tools (all denied in Read-Only + plan gates, all in `_mutatingTools`, all require `AgentMode.control`):

| Tool | Args | Mechanism |
|------|------|-----------|
| `device_read` | `mode?` (`delta` default, `full`) | Reads the a11y node tree of the foreground window. This is the agent's PRIMARY eye — see §2.3 |
| `device_tap` | `node?`, `x?`, `y?` | `node` → `AccessibilityNodeInfo.performAction(ACTION_CLICK)` on the handle (preferred, scroll-safe); coords → `dispatchGesture` a tap at `(x, y)` |
| `device_type` | `node?`, `text`, `submit?` | `ACTION_SET_TEXT` on the node; falls back to focused editable. `submit` fires `ACTION_IME_ENTER`/Enter keycode |
| `device_swipe` | `from_x, from_y, to_x, to_y`, `duration_ms?` | `dispatchGesture` with an interpolated `Path` stroke |
| `device_system_nav` | `action` (`back`\|`home`\|`recents`\|`notifications`\|`quick_settings`) | `performGlobalAction(GLOBAL_ACTION_*)` |
| `device_screenshot` | — | `AccessibilityService.takeScreenshot()` (API 30+). FALLBACK ONLY — see §2.3 |

Behavior rules:

- Every tool first checks the service is bound. If not: `'Control mode needs the Ovid accessibility service. Enable it in Settings → Accessibility → Ovid AI.'` plus a one-tap deep link.
- WebView tabs are covered by this same surface — no separate in-app path. The browser is just another window in the tree.
- `device_screenshot` on API < 30 returns an honest unsupported message; the node tree still works.

### 2.3 Seeing the screen without screenshotting every action

Screenshots are slow, expensive, and vision-model-only. The node tree is text, works on every model, and is ~50× cheaper. So the tree is primary and the screenshot is the exception.

**Node tree as the primary reader.** `device_read` renders `rootInActiveWindow` as flat indexed rows:

```
[12] Button   "Send"       id=send_btn  bounds=(880,1520,1010,1600) clickable
[13] EditText "Message…"   id=composer  bounds=(60,1500,860,1620) editable focused
[14] TextView "Ravi: hi"                bounds=(60,900,700,960)
```

Each row carries: index handle, class, text, content-description, view-id, bounds, and action flags (clickable / editable / scrollable / checked / focused). Invisible and zero-area nodes are dropped.

**Three mechanisms keep the agent from re-reading the screen constantly:**

1. **Event-driven dirty flag.** The service subscribes to `TYPE_WINDOW_STATE_CHANGED` and `TYPE_WINDOW_CONTENT_CHANGED` and only sets a `dirty` boolean plus a window signature. It never builds a tree on its own. A tree is built solely when `device_read` is called. If nothing changed since the last read, `device_read` returns `'screen unchanged'` — near-zero tokens.

2. **Delta reads.** Default `mode: delta` returns only rows added, removed, or changed since the last read of the same window, diffed on a stable node key (`viewId + class + text + bounds`):
   ```
   + [22] Toast "Message sent"
   ~ [13] EditText text:"" (was "hi ravi")
   ```
   A window signature change (new app / new screen) forces an automatic full read. `mode: full` forces it manually.

3. **Node handles instead of coordinates.** Handles from the last read stay valid until the tree is rebuilt. `device_tap(node: 12)` performs a real accessibility click on that node — correct even if the list scrolled, and immune to density/rotation math. Because the action targets a semantic node rather than a pixel, the agent does not need to re-read to confirm it hit the right thing; it re-reads only when it needs the *result*.

**Screenshot fallback fires in exactly three cases:**

1. `device_read` yields an empty or content-less tree (games, video, canvas, Flutter/Unity surfaces that expose no semantics) — the tool says so and suggests `device_screenshot`.
2. The agent needs actual pixels: reading a photo, a chart, a captcha, a rendered document.
3. The agent explicitly calls `device_screenshot`.

If the active model has no image support, case 1 and 3 return: `'This screen exposes no readable structure and the current model cannot read images. Switch to a vision model, or navigate using device_system_nav.'` — an honest limit, never a silent failure.

### 2.4 Accessibility permission flow

Requested only when the user switches to Control mode, never at launch:

1. Disclosure sheet (copy in §6.4): what Ovid can do with it, that it is local-only, that it is revocable, and the denylist in §6.5.
2. Accept → `Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)` with the service highlighted via `EXTRA_FRAGMENT_ARG_KEY`.
3. On resume, `AccessibilityManager.getEnabledAccessibilityServiceList` confirms binding. If the user declined, Control mode stays selectable but every `device_*` tool returns the not-bound message with the re-open link; the session is not silently downgraded.


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

### 4.1 Download path (no size cap)

Current: `HttpShim.get(..., maxResponseBytes: 20MB)` fully buffered (`agent_service.dart` `_handleBrowserDownload`). Design:

- Streaming variant: Dart `HttpClient` GET writing straight to `containedPath(work, name)` in 64KB chunks. Nothing is ever fully buffered in memory, so file size is bounded only by storage.
- **No artificial cap.** The only limit is real free disk space: before starting, if `Content-Length` is known and exceeds free space, abort with `'not enough space: needs X MB, Y MB free'`. If the length is unknown, stream until the device runs out and report the write failure honestly, deleting the partial file.
- Progress: `_emit('nav', 'downloading: name (x.y MB / total)')` every ~2s max.
- Result shape unchanged: `'downloaded ✓ · name · N bytes (workspace — read with read_attachment)'`.
- Session-workspace containment rule unchanged; never public Downloads (binding constraint).

### 4.2 Upload path (no size cap)

Current: whole-file base64 in one JS string, 10MB cap. Design:

- Stage the file to JS in **256KB base64 chunks** via `runJavaScript` appending to `window.__ovidUploadBuf`, then finalize: assemble `Uint8Array` → `File` → `DataTransfer` → assign `el.files` + dispatch `input`/`change`. Buffer cleared on success and on failure.
- **No artificial cap.** Chunking removes the string-length wall and keeps peak memory at one chunk on the Dart side. Very large files are read with a streaming `openRead()` so the whole file is never resident in Dart memory either.
- If the WebView rejects the staged buffer (renderer OOM on genuinely huge files), the tool reports the real error rather than pre-emptively refusing a size the device could have handled.
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

1. **One new declaration:** `BIND_ACCESSIBILITY_SERVICE` on the `OvidAccessibilityService` component (§2.2). This is a signature-level bind permission — the user grants it manually in system Settings; the app cannot request it at runtime and cannot enable itself. It is declared, never auto-granted.
2. Play policy for accessibility: the service exists to let the user's own assistant operate their device for them — an explicitly permitted use when disclosed. Ship requirements: prominent in-app disclosure before the settings deep link (§6.4), an accessibility-use declaration in the Play Console submission, and `android:accessibilityFlags` limited to what the tools need (`flagDefault|flagRetrieveInteractiveWindows|flagRequestFilterKeyEvents` omitted — no key filtering).
3. `MANAGE_EXTERNAL_STORAGE` is de-risked: §4.4 SAF export replaces the only flows that leaned on it; if no code path still requires all-files access after this scope lands, a follow-up removes the declaration (tracked in W5, not executed here — removal may break Studio's pinned-folder flows and needs its own audit).
4. Every runtime permission request happens point-of-use with a purpose string; never at launch.

### 6.2 Foreground service justification

`dataSync` type is correct for agent-run processing. Keep-alive (§5.3) extends lifetime; the notification always reflects true state (working / ready) — never a silent persistent notification (Play spam policy). Keep-alive is user-toggleable and OFF by default for users who never granted notifications.

### 6.3 Telemetry / data safety

Telemetry consent dialog (`main.dart` `_maybeAskConsent`) unchanged; any new event types added by §3 (`serviceStatus` churn) stay local — nothing leaves the device in this scope. **Screen content never leaves the device except as part of the user's own model request**: node-tree text and screenshots are sent only to the provider the user already chose for that session, exactly like any other tool result, and are never logged to disk or telemetry.

### 6.4 Control-mode disclosure copy (final)

> **Control mode lets Ovid use your device the way you would.** With your permission it can read what is on screen and tap, type, swipe, and use Back / Home / Recents — in this app and in others, so it can finish tasks for you end to end.
>
> Ovid reads the screen only while Control mode is on, and only to do what you asked. Screen content is sent to the AI model you chose for this chat and to nowhere else — it is never stored or shared. It will not act on banking or payment screens. Every action appears in this chat.
>
> You turn this on yourself in Settings → Accessibility, and you can turn it off there at any time.


### 6.5 Hard limits enforced in code

- **Sensitive-app denylist.** Before every `device_*` action the service reads the foreground package name (`AccessibilityEvent.getPackageName` / `rootInActiveWindow.packageName`) and the WebView URL when the foreground app is Ovid. If either matches the denylist — banking, payments, and wallet packages/domains in `kDeniedControlPackages` / `kDeniedControlDomains` — the tool refuses with an explanation and suggests the user do it themselves. The check is on the *live* foreground app, so it holds even if the agent navigates there mid-run.
- **No credential entry.** `device_type` refuses when the target node reports `isPassword`, in any app.
- **Double gating.** `device_*` tools require `AgentMode.control` AND are denied in the Read-Only and plan gates, so a control session entering plan mode loses them.
- **Not inheritable.** Subagents never run in control mode (§2.1) — a child dispatched from a control session runs at `drive`.
- **Bounded blast radius per action.** Every `device_*` call returns what it did in the transcript (`_emit`), so the user has a complete, reviewable log of everything Ovid touched.

---

## Out of scope

- MANAGE_EXTERNAL_STORAGE removal (needs separate Studio-folder audit).
- iOS equivalents (project ships Android).
- BrowserTab cookie-per-session isolation (tracked as B9, separate).
- Cross-device / remote control.

## Verification summary (plan-level)

Every workstream gets RED→GREEN tests in `test/core_regression_test.dart`: mode gate denials + node-tree render/diff pure helpers + denylist refusal (W1/W5), status transitions via `serviceStatusForTest` (W2), streaming download and chunked upload via pure helpers with no cap assertions (W3), stop-branch + keep-alive idle via `agentIdleForTest` (W4). Kotlin service surface is asserted by source-level tests in the existing `readForegroundServiceSourceForTest` style (manifest declaration, flags, global actions present). `flutter analyze` clean; full suite green before each commit.

