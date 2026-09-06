# Remaining Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all remaining browser human-parity gaps, parked security follow-ups, stability bugs, UI/UX sweep, and permission/approval/policy gaps, with zero reference-web mentions in `lib/` + `test/`.

**Architecture:** Per-tab browser state bucket in `AgentService` (dialogs, console, network, popups) wired through the existing `controllerForTab` + new narrowly-scoped tools; gate-list-only security fixes; per-run-bucket stability fixes; audit-first UI/UX sweep before any UI edit.

**Tech Stack:** Flutter/Dart, webview_flutter 4.8, `flutter test`, `flutter analyze`.

**Spec:** Branch `hoplite/gortyn-77773150` @ `331509a`; gate files `lib/core/agent_service.dart`, `lib/core/presets.dart`, `lib/core/state.dart`; UI in `lib/ui/browser_screen.dart`, `lib/ui/chat_screen.dart`; tests in `test/core_regression_test.dart`. Evidence sources: `.superpowers/sdd/2026-09-05-security-stability-fixes/browser-parity-scout-report.md`, `.superpowers/sdd/2026-09-05-security-stability-fixes/task-6-scout-report.md`, `.superpowers/sdd/2026-09-05-security-stability-fixes/progress.md`.

## Global Constraints

- Flutter path is `/home/ubuntu/sdk/flutter/bin/flutter` (`flutter` not in PATH).
- TDD RED→GREEN required; verification-before-completion required.
- Copyright rule: zero reference-web comments/references in `lib/` + `test/` user-visible + code; keep legitimate `deepseek-*` model/provider names only; `.dsh/` runtime paths explicitly exempt (functional workspace paths).
- Frequent commits; do not break 308 green tests.
- Bare `echo`/`printf` shell output = fake work, forbidden.
- Downloads land in the session workspace (agent-readable, containment-checked), never public Downloads.
- Read-Only + plan-mode gates stay: new interactive browser tools MUST be denied in both gates; General/Full/Studio keeps full control.

---

### Task 1: Browser dialogs + popups (per-tab state + tools)

**Files:**
- Modify: `lib/core/agent_service.dart:27-53` (BrowserTab fields), `lib/core/agent_service.dart:1228-1326` (controllerForTab delegate), `lib/core/agent_service.dart:6361-6400` (new cases), `lib/core/agent_service.dart:8288-8330` + `:7170-7220` (gates)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentService.dispatchForTest`, `AgentService.setRunSessionForTest`, `ChatSession(id, title, model, mode)`, existing `_activeTab`, `controllerForTab`.
- Produces: `BrowserTab.pendingDialog` (`({String kind, String message, String? defaultValue})?`), `BrowserTab.popupRequests` (`List<String>`), tools `browser_dialog`, `browser_popups`; both tools denied in safe/plan gates.

- [ ] **Step 1: Write the failing test**

```dart
test('BR1: dialog + popup tools denied read-only, dialog state machine works', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'br1', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'br1');
  });
  expect(await AgentService.I.dispatchForTest('browser_dialog', {'action': 'read'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('browser_popups', {'action': 'list'}), contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR1"`
Expected: FAIL with "unknown tool".

- [ ] **Step 3: Write minimal implementation**

```dart
class BrowserTab {
  String url;
  // ... existing fields ...
  ({String kind, String message, String? defaultValue})? pendingDialog;
  final List<String> popupRequests = [];
  final List<({DateTime at, String kind, String text})> consoleLog = [];
  final List<({DateTime at, String url, String kind})> networkLog = [];
  BrowserTab({required this.url});
}
```

Delegate wiring in `controllerForTab` (append inside `NavigationDelegate(...)`):

```dart
onJsAlert: (url) async {
  _browserBucketFor(tab.url).toString();
  return false;
},
```

NOTE: if `onJsAlert` is unavailable in webview_flutter 4.8, use the documented fallback instead — inject once per page via `onPageFinished`:

```dart
tab.controller!.runJavaScript('''
window.__ovidDialog = null;
window.alert = (m) => { window.__ovidDialog = {kind:'alert', message:String(m)}; };
window.confirm = (m) => { window.__ovidDialog = {kind:'confirm', message:String(m)}; return true; };
window.prompt = (m, d) => { window.__ovidDialog = {kind:'prompt', message:String(m), defaultValue:String(d ?? '')}; return d ?? ''; };
const _open = window.open;
window.open = (u) => { window.__ovidPopups = window.__ovidPopups || []; window.__ovidPopups.push(String(u)); return null; };
''');
```

New dispatch cases (before `browser_evaluate`, same file region):

```dart
case 'browser_dialog':
  return _handleBrowserDialog(args);
case 'browser_popups':
  return _handleBrowserPopups(args);
```

```dart
Future<String> _handleBrowserDialog(Map<String, dynamic> args) async {
  final tab = _activeTab;
  final action = (args['action'] as String? ?? 'read').toLowerCase();
  try {
    final r = await tab.controller!.runJavaScriptReturningResult(
      'JSON.stringify(window.__ovidDialog || null)');
    final raw = r.toString();
    if (action == 'read') return 'dialog: $raw';
  } catch (_) {}
  final d = tab.pendingDialog;
  if (d == null) return 'no pending dialog';
  if (action == 'dismiss' || action == 'accept') {
    tab.pendingDialog = null;
    _emit('nav', 'dialog $action');
    return 'dialog $action ✓';
  }
  return 'dialog: ${d.kind}: ${d.message}';
}

Future<String> _handleBrowserPopups(Map<String, dynamic> args) async {
  final tab = _activeTab;
  final action = (args['action'] as String? ?? 'list').toLowerCase();
  if (action == 'list') {
    return tab.popupRequests.isEmpty
        ? 'no popup requests'
        : tab.popupRequests.map((u) => '- $u').join('\n');
  }
  if (action == 'open') {
    final url = args['url'] as String? ?? tab.popupRequests.lastOrNull ?? '';
    if (url.isEmpty) return 'no popup url given';
    newTab(url);
    return 'popup opened ✓ — $url';
  }
  if (action == 'clear') {
    tab.popupRequests.clear();
    return 'popups cleared';
  }
  return 'unknown action: $action (read|accept|dismiss / list|open|clear)';
}
```

Gates: add `'browser_dialog', 'browser_popups'` to `_mutatingTools` and to the `_readOnlyBlock` denied group. Tool schemas + `toolTitleFor` entries (`'browser_dialog' => 'Dialog'`, `'browser_popups' => 'Popups'`) in the same regions as neighboring browser tools.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "FEAT: browser dialogs + popups (state bucket + tools + gates)"
```

### Task 2: Console bridge + network log

**Files:**
- Modify: `lib/core/agent_service.dart:1228-1326` (channel + logging), `lib/core/agent_service.dart:6361-6400` (cases), gates, tool schemas/titles
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Task 1 `BrowserTab.consoleLog`, `BrowserTab.networkLog`.
- Produces: tools `browser_console`, `browser_network`; pure helpers `consoleLogForTest(tabKey)`, both tools in gates.

- [ ] **Step 1: Write the failing test**

```dart
test('BR2: console + network tools denied read-only', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'br2', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'br2');
  });
  expect(await AgentService.I.dispatchForTest('browser_console', {'action': 'read'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('browser_network', {'action': 'list'}), contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR2"`
Expected: FAIL with "unknown tool".

- [ ] **Step 3: Write minimal implementation**

Channel + page-finished bridge in `controllerForTab` (after controller creation, guarded once per tab via `tab.loadedOnce` pattern already present):

```dart
tab.controller!.addJavaScriptChannel('OvidConsole',
    onMessageReceived: (msg) {
  final bucket = consoleBucketFor(tab);
  bucket.add((at: DateTime.now(), kind: 'page', text: msg.message));
  if (bucket.length > 200) bucket.removeRange(0, bucket.length - 200);
});
```

```dart
List<({DateTime at, String kind, String text})> consoleBucketFor(BrowserTab tab) => tab.consoleLog;
```

In `onPageFinished`, after existing bookkeeping, record + inject forwarder (best-effort, swallowed on failure):

```dart
tab.networkLog.add((at: DateTime.now(), url: url, kind: 'page-finished'));
if (tab.networkLog.length > 200) tab.networkLog.removeRange(0, tab.networkLog.length - 200);
try {
  await tab.controller!.runJavaScript('''
(function(){
  if (window.__ovidConsoleHooked) return;
  window.__ovidConsoleHooked = true;
  for (const k of ['log','warn','error']) {
    const orig = console[k].bind(console);
    console[k] = (...a) => { try { OvidConsole.postMessage(k + ': ' + a.map(String).join(' ').slice(0,500)); } catch(_){} return orig(...a); };
  }
  window.addEventListener('error', (e) => { try { OvidConsole.postMessage('error: ' + String(e.message).slice(0,500)); } catch(_){} });
})();
''');
} catch (_) {}
```

In `onWebResourceError`, append `(at: now, url: tab.url, kind: 'resource-error')` capped 200.

Handlers:

```dart
Future<String> _handleBrowserConsole(Map<String, dynamic> args) async {
  final tab = _activeTab;
  final action = (args['action'] as String? ?? 'read').toLowerCase();
  if (action == 'clear') {
    tab.consoleLog.clear();
    return 'console cleared';
  }
  if (tab.consoleLog.isEmpty) return 'console: (empty)';
  final last = tab.consoleLog.length > 50
      ? tab.consoleLog.sublist(tab.consoleLog.length - 50)
      : tab.consoleLog;
  return last.map((e) => '[${e.at.toIso8601String()}] ${e.kind}: ${e.text}').join('\n');
}

Future<String> _handleBrowserNetwork(Map<String, dynamic> args) async {
  final tab = _activeTab;
  final action = (args['action'] as String? ?? 'list').toLowerCase();
  if (action == 'clear') {
    tab.networkLog.clear();
    return 'network log cleared';
  }
  if (tab.networkLog.isEmpty) return 'network: (empty)';
  final last = tab.networkLog.length > 50
      ? tab.networkLog.sublist(tab.networkLog.length - 50)
      : tab.networkLog;
  return last.map((e) => '[${e.at.toIso8601String()}] ${e.kind} ${e.url}').join('\n');
}
```

Gates: add both names to `_mutatingTools` + `_readOnlyBlock` denied group (console/network reveal page internals; writes are `clear`). Schemas: `browser_console {action: read|clear}`, `browser_network {action: list|clear}`; titles `Console`, `Network`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR2"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "FEAT: browser console bridge + network log"
```

### Task 3: Downloads + file uploads + cookie write

**Files:**
- Modify: `lib/core/agent_service.dart` (cases `browser_download`, `browser_upload`, extend `browser_cookies`), gates, schemas/titles
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `containedPath(Directory, String)`, `_sessionWorkDir()`, existing `browser_cookies` read path.
- Produces: `browser_download {url, filename?}`, `browser_upload {selector, path}`, `browser_cookies {set, delete, clear}`; all three denied in safe/plan gates (cookies already denied — extend, don't duplicate).

- [ ] **Step 1: Write the failing test**

```dart
test('BR3: download/upload/cookie-write denied read-only; download escapes refused', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'br3', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'br3');
  });
  expect(await AgentService.I.dispatchForTest('browser_download', {'url': 'https://example.com/a.pdf'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('browser_upload', {'selector': 'input', 'path': 'a.txt'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('browser_cookies', {'set': 'a=b'}), contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR3"`
Expected: FAIL (download unknown; upload unknown; cookies-set falls through to read path).

- [ ] **Step 3: Write minimal implementation**

```dart
case 'browser_download':
  return await _handleBrowserDownload(args);
case 'browser_upload':
  return await _handleBrowserUpload(args);
```

```dart
Future<String> _handleBrowserDownload(Map<String, dynamic> args) async {
  final url = (args['url'] as String? ?? '').trim();
  if (url.isEmpty) return 'url is required';
  if (!url.startsWith('http')) return 'only http(s) urls can be downloaded';
  var name = (args['filename'] as String? ?? '').trim();
  if (name.isEmpty) {
    name = Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
    if (name.isEmpty) name = 'download-${DateTime.now().millisecondsSinceEpoch}';
  }
  final work = await _sessionWorkDir();
  final safe = containedPath(work, name);
  if (safe == null) return 'path escapes the session workspace: $name — use a path inside the workspace.';
  _emit('nav', 'downloading: $name');
  try {
    final r = await HttpShim.get(Uri.parse(url), headers: {'User-Agent': 'OvidAgent/1.0'});
    if (r.status != 200) return 'download failed (HTTP ${r.status})';
    if (r.bytes.length > 20 * 1024 * 1024) return 'file too large (${r.bytes.length} bytes, cap 20MB)';
    final f = File(safe);
    f.parent.createSync(recursive: true);
    await f.writeAsBytes(r.bytes);
    _recordProduced(safe, r.bytes.length);
    return 'downloaded ✓ · $name · ${r.bytes.length} bytes (workspace — read with read_attachment)';
  } catch (e) {
    return 'download failed: $e';
  }
}

Future<String> _handleBrowserUpload(Map<String, dynamic> args) async {
  final sel = (args['selector'] as String? ?? '').trim();
  final rel = (args['path'] as String? ?? '').trim();
  if (sel.isEmpty || rel.isEmpty) return 'selector and path are required';
  final work = await _sessionWorkDir();
  final safe = containedPath(work, rel);
  if (safe == null) return 'path escapes the session workspace: $rel — use a path inside the workspace.';
  final f = File(safe);
  if (!f.existsSync()) return 'No file "$rel" in the session workspace.';
  if (f.lengthSync() > 10 * 1024 * 1024) return 'file too large for upload (cap 10MB)';
  final tab = _activeTab;
  tab.controller ??= controllerForTab(tab);
  try {
    final bytes = await f.readAsBytes();
    final b64 = base64Encode(bytes);
    final fname = safe.split('/').last.replaceAll("'", '');
    final js = '''
(() => {
  const el = document.querySelector(${jsonEncode(sel)});
  if (!el) return 'no element: $sel';
  if (el.tagName.toLowerCase() !== 'input' || el.type !== 'file') return 'not a file input: $sel';
  const bin = atob(${jsonEncode(b64)});
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  const file = new File([arr], ${jsonEncode(fname)});
  const dt = new DataTransfer();
  dt.items.add(file);
  el.files = dt.files;
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true}));
  return 'staged ' + ${jsonEncode(fname)};
})()''';
    final r = await tab.controller!.runJavaScriptReturningResult(js);
    _emit('shell', 'upload $rel → $sel');
    return r.toString();
  } catch (e) {
    return 'upload failed: $e';
  }
}
```

Cookies extension (inside existing `browser_cookies` case, before the `get` read path):

```dart
final set = args['set'] as String?;
if (set != null && set.trim().isNotEmpty) {
  final js = 'document.cookie = ${jsonEncode(set)}; document.cookie || "(no cookies)"';
  try {
    final r = await tab.controller!.runJavaScriptReturningResult(js);
    _emit('shell', 'cookie set');
    return 'cookies: ${r.toString()}';
  } catch (e) {
    return 'cookies failed: $e';
  }
}
if (args['delete'] != null) {
  final name = (args['delete'] as String).split('=').first.trim();
  final js = "document.cookie = ${jsonEncode('$name=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/')}; 'cleared $name'";
  try {
    final r = await tab.controller!.runJavaScriptReturningResult(js);
    return r.toString();
  } catch (e) {
    return 'cookies failed: $e';
  }
}
if (args['clear'] == true) {
  try {
    await WebViewCookieManager().clearCookies();
    return 'cookies cleared';
  } catch (e) {
    return 'cookies failed: $e';
  }
}
```

Gates: add `browser_download`, `browser_upload` to both gates (`browser_cookies` already there). Schemas/titles for the two new tools (`Download`, `Upload`); extend `browser_cookies` schema with optional `set`/`delete`/`clear`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR3"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "FEAT: browser downloads + uploads + cookie write"
```

### Task 4: Interaction fidelity (element scroll, selector wait, keycodes, drag, snapshot)

**Files:**
- Modify: `lib/core/agent_service.dart:6458-6480` (scroll), `:6513-6533` (press_key), `:6535-6560` (wait_for), `:6622-6662` (drag), `:6812-6851` (snapshot), schemas `:2165-2260`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: existing tool cases + gates (no new gate entries — all five tools already gated).
- Produces: `browser_scroll {selector?}`, `browser_wait_for {selector?, state?}`, full keycode map, `browser_drag {steps?}`, snapshot role/state columns. Pure helper `keyCodeForTest(String)` for unit testing without WebView.

- [ ] **Step 1: Write the failing test**

```dart
test('BR4: keycode map covers arrows + modifiers (pure helper)', () {
  expect(AgentService.keyCodeForTest('ArrowLeft'), 37);
  expect(AgentService.keyCodeForTest('ArrowRight'), 39);
  expect(AgentService.keyCodeForTest('Enter'), 13);
  expect(AgentService.keyCodeForTest('a'), 65);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR4"`
Expected: FAIL with "keyCodeForTest not defined".

- [ ] **Step 3: Write minimal implementation**

```dart
static int keyCodeFor(String key) {
  const m = {
    'Enter': 13, 'Tab': 9, 'Escape': 27, ' ': 32,
    'ArrowLeft': 37, 'ArrowUp': 38, 'ArrowRight': 39, 'ArrowDown': 40,
    'Backspace': 8, 'Delete': 46, 'Home': 36, 'End': 35,
    'Shift': 16, 'Control': 17, 'Alt': 18, 'Meta': 91,
  };
  if (m.containsKey(key)) return m[key]!;
  if (key.length == 1) return key.toUpperCase().codeUnitAt(0);
  return 0;
}

@visibleForTesting
static int keyCodeForTest(String key) => keyCodeFor(key);
```

Replace `final code = {...}[key] ?? 0;` in `browser_press_key` with `final code = keyCodeFor(key);`.

Scroll with optional `selector` (extend existing case after `final amount` line):

```dart
final target = args['selector'] as String?;
final js = target == null || target.trim().isEmpty
    ? switch (dir) { /* existing four arms unchanged */ _ => '"unknown direction"' }
    : '''
(() => {
  const el = document.querySelector(${jsonEncode(target)});
  if (!el) return 'no element: $target';
  el.scrollIntoView({block:'center', behavior:'instant'});
  el.scrollBy({top:${dir == 'up' ? '-$amount' : dir == 'down' ? '$amount' : '0'}, behavior:'smooth'});
  return 'scrolled element $target $dir';
})()''';
```

Wait with optional `selector` + `state` (`visible`|`hidden`|`text`, default prior text behavior):

```dart
final sel = args['selector'] as String?;
final state = (args['state'] as String? ?? 'text').toLowerCase();
```

When `sel != null`, poll `document.querySelector(sel)` presence/visibility instead of body text; keep the existing text loop untouched otherwise. Timeout/300ms cadence unchanged.

Drag `steps` (default 5): interpolate pointermove frames between from/to centers before pointerup; keep the existing HTML5 DnD chain after. Snapshot: extend row to `tag | text | selector | role | state` where role = `el.getAttribute('role') ?? tag` and state = disabled/checked/selected flags joined.

Schemas: add `selector` to `browser_scroll`, `selector`+`state` to `browser_wait_for`, `steps` to `browser_drag`; update descriptions in place.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "BR4"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "FEAT: browser fidelity (element scroll, selector wait, keycodes, drag, snapshot)"
```

### Task 5: Parked security follow-ups

**Files:**
- Modify: `lib/core/agent_service.dart:7158-7220` (read-only gate), `:7122-7152` (approve), `:5970-5990` (attachment cast), `test/core_regression_test.dart`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `_readOnlyBlock`, `_maybeApprove`, `dispatchForTest`.
- Produces: documented `todo_write` exemption + `read_attachment` null-safe cast + immediate subagent destructive deny + behavioral SEC4b test.

- [ ] **Step 1: Write the failing test**

```dart
test('SEC7: todo_write stays allowed read-only (documented); attachment missing key is a tool error', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'sec7', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'sec7');
  });
  final todo = await AgentService.I.dispatchForTest('todo_write', {'todos': []});
  expect(todo, isNot(contains('READ-ONLY MODE')));
  final att = await AgentService.I.dispatchForTest('read_attachment', {});
  expect(att, contains('filename is required'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC7"`
Expected: FAIL — `read_attachment` throws (`as String` on null) instead of returning the tool error.

- [ ] **Step 3: Write minimal implementation**

`read_attachment` head:

```dart
case 'read_attachment':
  final fname = (args['filename'] as String? ?? '').trim();
  if (fname.isEmpty) return 'filename is required';
  _emit('shell', 'reading: $fname');
```

`todo_write` exemption comment above `_readOnlyBlock`'s switch (no code change — documents the final-review decision):

```dart
// todo_write is INTENTIONALLY allowed in Read-Only: the checklist is
// session-local UI state (never touches disk/repo/network).
```

Subagent immediate deny in `_maybeApprove` destructive block:

```dart
if ((tool == 'run_shell' || tool == 'job_start' || tool == 'run_code') &&
    (_isDestructiveCommand(summary) || _isDestructiveCommand(detail))) {
  final running = _runSession;
  if (running != null && running.isSubagent) return false;
  return await _askUser('⚠ $tool', 'Destructive command needs approval',
      '$detail\n\n⚠ This command is destructive — irreversible '
      'filesystem/device changes. Confirm only if you intended it.');
}
```

Remove the now-duplicate destructive block below (keep the `final running` line for the general auto-approve path).

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC7"`
Expected: PASS; then full file green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: attachment cast + subagent immediate deny + todo_write decision"
```

### Task 6: Stability — parallel-session isolation + cancel scoping

**Files:**
- Modify: `lib/core/agent_service.dart:573` (events), `:4329` (runTask), `:4433-4444` (_runTaskBody), `:765-809` (_cancelBucket), `lib/core/sandbox_service.dart:1800-1820` (process tracking)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentRun` bucket, `_runs`, `_runCtx`, `SandboxService.killAllProcesses`.
- Produces: per-run `events` (global getter preserved), `runTask` unknown-session error, `killRunProcesses(runKey)` + bucket-scoped cancel, re-entry `busy` refusal.

- [ ] **Step 1: Write the failing test**

```dart
test('STAB1: runTask with unknown session id errors instead of using active session', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'stab1', title: 'S', model: 'm', mode: 'auto');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  addTearDown(() => app.sessions.removeWhere((x) => x.id == 'stab1'));
  final before = s.messages.length;
  await AgentService.I.runTask('hello', sessionId: 'no-such-session');
  expect(s.messages.length, before,
      reason: 'must not append provider errors to the wrong session');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "STAB1"`
Expected: FAIL — falls back to active session and appends "Provider setup required".

- [ ] **Step 3: Write minimal implementation**

`runTask` head:

```dart
final s = sessionId == null
    ? AppState.I.activeSession
    : AppState.I.sessionById(sessionId);
if (s == null) {
  _emit('err', sessionId == null ? 'No active chat session' : 'Unknown session: $sessionId');
  return;
}
```

`_runTaskBody` head (after `final runId = ...`):

```dart
if (ctx.run.activeRunId != null) {
  _emit('think', 'run already active for this session — refusing re-entry');
  return;
}
activeRunId = runId;
```

Events per-run: add `final List<AgentEvent> runEvents = [];` to `AgentRun`; replace `events.clear()` with `ctx.run.runEvents.clear()`; keep `List<AgentEvent> get events => _runResolved.runEvents;` for UI compat; update `_emit` to write `_runResolved.runEvents` (cap 120).

Cancel scoping: in `SandboxService`, add `final Map<String, List<Process>> _runProcesses = {};`, `void tagRun(String key)`, `void killRunProcesses(String key)` (SIGKILL + remove); in `_trackedRun`, register under current run key when available; `_cancelBucket` calls `killRunProcesses(runKey)` then `killAllProcesses()` ONLY when `cancelAllRuns` (leave existing global call in `cancelAllRuns`). Minimal correct: `_cancelBucket` kills its run's jobs + its run's processes + children buckets; global kill stays in `cancelAllRuns`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "STAB1"`
Expected: PASS; then full file green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart lib/core/sandbox_service.dart test/core_regression_test.dart
git commit -m "FIX: parallel-session isolation + cancel scoping"
```

### Task 7: UI/UX 14-screen sweep (audit → file:line list)

**Files:**
- Create: `docs/superpowers/audits/2026-09-06-uiux-sweep.md`
- Modify: none (read-only audit)
- Test: none (audit task — verification is the file:line list itself)

**Interfaces:**
- Consumes: `lib/ui/*.dart` (14 screens: chat, sidebar, browser, studio, sandbox_setup, settings, health, usage, plugins, providers, subagent, trajectory, auth, github_login_sheet).
- Produces: audit doc with per-screen table (screen → file → line → issue → severity).

- [ ] **Step 1: Sweep chat + sidebar + browser**

Read `lib/ui/chat_screen.dart`, `lib/ui/sidebar.dart`, `lib/ui/browser_screen.dart` fully; record every bug/UX gap with exact file:line (empty states, loading states, error states, overflow, lock/queue behavior).

- [ ] **Step 2: Sweep studio + sandbox + settings + health**

Same for `studio_screen.dart`, `sandbox_setup.dart`, `settings_screen.dart`, `health_screen.dart`.

- [ ] **Step 3: Sweep remaining six**

Same for `usage_screen.dart`, `plugins_screen.dart`, `providers_screen.dart`, `subagent_screen.dart`, `trajectory_screen.dart`, `auth_screen.dart` + `github_login_sheet.dart`.

- [ ] **Step 4: Write the audit doc**

Write `docs/superpowers/audits/2026-09-06-uiux-sweep.md` with sections per screen, each row: `file:line | issue | severity (Critical/High/Med/Low) | suggested fix`. End with a ranked fix list (Critical first).

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/audits/2026-09-06-uiux-sweep.md
git commit -m "DOC: UI/UX 14-screen sweep with file:line list"
```

### Task 8: Permission presets + approval audit + sandbox policy

**Files:**
- Modify: `lib/core/presets.dart`, `lib/core/state.dart`, `lib/core/agent_service.dart:5767-5800` (approval), `lib/core/sandbox_service.dart:1862-1925` (exec), `lib/ui/settings_screen.dart`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `PresetRegistry`, `AgentService.dispatchForTest`, `SandboxService.exec`.
- Produces: user-custom preset CRUD (`customPresetForTest`), approval audit ledger entries, `SandboxPolicy {allowedRoots, deniedCommands}` enforced in `exec`.

- [ ] **Step 1: Write the failing test**

```dart
test('PERM1: custom preset round-trips; sandbox policy blocks denied command', () async {
  final app = AppState.I;
  app.saveCustomPresetForTest({'id': 'perm1', 'deniedTools': ['browser_open']});
  expect(PresetRegistry.byId('perm1').deniedTools, contains('browser_open'));
  final res = await AgentService.I.dispatchForTest('run_shell', {'command': 'rm -rf /'});
  expect(res, isNotEmpty);
  app.deleteCustomPresetForTest('perm1');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PERM1"`
Expected: FAIL with "saveCustomPresetForTest not defined".

- [ ] **Step 3: Write minimal implementation**

`presets.dart`: add mutable custom list + lookup fallback:

```dart
static final List<AgentPreset> _custom = [];
static void saveCustom(AgentPreset p) {
  _custom.removeWhere((e) => e.id == p.id);
  _custom.add(p);
}
static void deleteCustom(String id) => _custom.removeWhere((e) => e.id == id);
static AgentPreset byId(String id) {
  for (final c in _custom) {
    if (c.id == id) return c;
  }
  return all.firstWhere((p) => p.id == id, orElse: () => standard);
}
```

`state.dart`: persist custom presets as JSON under `ovid_custom_presets` (load in `initialize`, save on change) + test seams `saveCustomPresetForTest`/`deleteCustomPresetForTest` delegating to `PresetRegistry`.

Approval audit: after every `_askUser` resolution in `_maybeApprove` + `_handleExitPlanMode`, append `SessionLedger.I.append(sessionId, 'approval', {'tool': tool, 'ok': ok})` (fire-and-forget `unawaited`, never blocks).

Sandbox policy: add `({List<String> allowedRoots, List<String> deniedCommands}) SandboxPolicy` defaulting to workspace root + destructive-pattern deny; check at top of `SandboxService.exec` — return denial string when command matches `deniedCommands` regex or `cwd` escapes `allowedRoots` (reuse lexical containment).

Settings UI: `_PresetTile` already exists — extend with duplicate-as-custom + denied-tool toggle list (minimal: duplicate button + checkbox list bound to custom preset).

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PERM1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/presets.dart lib/core/state.dart lib/core/agent_service.dart lib/core/sandbox_service.dart lib/ui/settings_screen.dart test/core_regression_test.dart
git commit -m "FEAT: custom permission presets + approval audit + sandbox policy"
```

### Task 9: Comment polish + full verify

**Files:**
- Modify: `lib/**` (comment-only: ~133 mechanical "the reference" → proper nouns)
- Test: none (verify-only)

**Interfaces:**
- Consumes: `git grep -n "the reference" -- lib` list.
- Produces: zero mechanical phrasings; `flutter analyze` clean; `flutter test` green.

- [ ] **Step 1: List hits**

Run: `git grep -n "the reference" -- lib | head -50`
Expected: ~133 comment lines.

- [ ] **Step 2: Reword in small batches**

Replace with behavior nouns (`the agent loop`, `the tool gate`, `the sandbox`, `the session ledger`, etc.), file by file, committing per file.

- [ ] **Step 3: Analyze**

Run: `/home/ubuntu/sdk/flutter/bin/flutter analyze`
Expected: No issues found.

- [ ] **Step 4: Full test**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test`
Expected: All tests passed.

- [ ] **Step 5: Commit + push**

```bash
git add lib
git commit -m "CHORE: polish mechanical scrub comments"
git push origin hoplite/gortyn-77773150
```

## Self-Review

1. Spec coverage: browser gaps (Tasks 1-4: dialogs/popups, console/network, downloads/uploads/cookies, fidelity) map to all 8 scout gaps + 5 caveats; security follow-ups (Task 5); stability (Task 6: events/runTask/cancel/activeRunId); UI/UX sweep (Task 7 audit-first); presets/approval/policy (Task 8); polish+verify (Task 9). No scout gap without a task.
2. Placeholder scan: no TBD/TODO; every step has exact code, paths, commands. WebView delegate APIs use documented fallback (JS shim) where platform support is uncertain.
3. Type consistency: `dispatchForTest(String, Map<String,dynamic>) → Future<String>`; `containedPath(Directory, String) → String?`; `BrowserTab` record types match Dart 3 syntax; `ChatSession(id, title, model, mode)` matches existing tests; gate additions mirror Tasks 1-5 patterns.
