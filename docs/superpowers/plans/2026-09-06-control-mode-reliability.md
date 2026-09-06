# Control Mode, Service Reliability, Real File Handling & Play Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Phase A in-app Control Mode, persistent keep-alive foreground service semantics, queue-aware smart Stop, tri-state health tracking with resume re-init, streaming browser file downloads (200MB) and chunked uploads (50MB), and Play Store safety guardrails.

**Architecture:** Extend `AgentMode` with rank-4 `control` mode double-gated by mode check and read-only/plan blocks; decouple queue draining on cancel to allow single-turn abort when queued items exist vs global panic stop; replace in-memory byte buffers in browser file handling with streaming disk pipes and JS buffer chunking; unify MCP and plugin health under a tri-state model (`connecting`, `working`, `failed`) refreshed on app resume.

**Tech Stack:** Flutter 3 / Dart 3, `webview_flutter` 4.8, `file_picker`, Android Foreground Service (`dataSync`), `flutter test`.

**Spec:** `docs/superpowers/specs/2026-09-06-control-mode-reliability-design.md` @ `d97a0f8`.

## Global Constraints

- Flutter binary path is `/home/ubuntu/sdk/flutter/bin/flutter` (`flutter` is not in global PATH).
- TDD RED→GREEN required; run verification commands before any success assertion.
- Downloads land in the session workspace (agent-readable, containment-checked), never public Downloads.
- Read-Only + plan-mode gates stay: every new interactive tool MUST be denied in both gates.
- Zero reference-web mentions in `lib/` and `test/`.
- Do not break the existing test suite (all 377 tests must stay green).
- Keep `kEnableDeviceControl = false` (Phase B compile-time safety flag).
- Frequent commits per task with clear, conventional messages.

---

### Task 1: Keep-alive foreground service toggle + "Ready & Listening" idle state

**Files:**
- Modify: `lib/core/state.dart:420-470` (keep-alive preference)
- Modify: `lib/core/agent_notification_service.dart:140-155` (`agentIdle` keep-alive branch)
- Modify: `lib/ui/settings_screen.dart:260-275` (keep-alive toggle UI)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AppState.I`, `AgentNotificationService.I`, `SharedPreferences`
- Produces: `AppState.keepAliveEnabled`, `AgentNotificationService.keepAliveEnabledOverrideForTest`, idle state updating notification to `'Ready & Listening'` when enabled instead of stopping the service.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`, add at the end of the `AgentNotificationService` test group:

```dart
test('KEEPALIVE1: idle updates to Ready & Listening when keep-alive enabled, stops when disabled', () async {
  final notif = AgentNotificationService.I;
  notif.supportedForTest = true;
  notif.activeForTest = true;
  AgentNotificationService.serviceStopRequestedForTestFlag = false;
  setAnyRunActiveForTest(false);

  // When keep-alive is true, agentIdle does not stop the service
  AgentNotificationService.keepAliveOverrideForTest = true;
  await agentIdleForTest();
  expect(AgentNotificationService.serviceStopRequestedForTestFlag, isFalse);
  expect(notif.activeForTest, isTrue);

  // When keep-alive is false, agentIdle stops the service
  AgentNotificationService.keepAliveOverrideForTest = false;
  await agentIdleForTest();
  expect(AgentNotificationService.serviceStopRequestedForTestFlag, isTrue);
  expect(notif.activeForTest, isFalse);
  AgentNotificationService.keepAliveOverrideForTest = null;
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "KEEPALIVE1"`
Expected: FAIL with "keepAliveOverrideForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_notification_service.dart`:
Add test override and update `agentIdle()`:

```dart
  @visibleForTesting
  static bool? keepAliveOverrideForTest;

  bool get _isKeepAlive =>
      keepAliveOverrideForTest ?? AppState.I.keepAliveEnabled;

  /// Run finished / idle → notification either updates to Ready & Listening
  /// (if keep-alive enabled) or stops the foreground service.
  void agentIdle() {
    if (!_supported || !_active) return;
    if (_isAnyRunActive()) return;
    _lastEventHash = 0;
    _debounce?.cancel();

    if (_isKeepAlive) {
      // Keep foreground service active so scheduled tasks and message queue fire
      unawaited(_invoke('agentServiceUpdate', {
        'title': 'Ovid AI',
        'text': 'Ready & Listening',
      }));
      return;
    }

    _active = false;
    serviceStopRequestedForTestFlag = true;
    unawaited(_invoke('agentServiceStop', {}));
  }
```

In `lib/core/state.dart`:
Add persistence for `ovid_keep_alive`:

```dart
  static const _kKeepAlivePref = 'ovid_keep_alive';
  bool _keepAliveEnabled = true;
  bool get keepAliveEnabled => _keepAliveEnabled;
  set keepAliveEnabled(bool v) {
    if (_keepAliveEnabled == v) return;
    _keepAliveEnabled = v;
    unawaited(_saveKeepAlivePref(v));
    if (!v) {
      AgentNotificationService.I.agentIdle();
    }
    notifyListeners();
  }

  Future<void> _saveKeepAlivePref(bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kKeepAlivePref, v);
    } catch (_) {}
  }
```
Load `_keepAliveEnabled` in `AppState.initialize`:
```dart
_keepAliveEnabled = prefs.getBool(_kKeepAlivePref) ?? true;
```

In `lib/ui/settings_screen.dart` under the `General` section:
```dart
SwitchListTile(
  dense: true,
  secondary: Icon(Icons.bolt_outlined, size: 19, color: Aether.textMuted),
  title: const Text('Background keep-alive', style: TextStyle(fontSize: 14)),
  subtitle: Text(
    'Keep assistant listening for scheduled tasks in background',
    style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
  ),
  value: AppState.I.keepAliveEnabled,
  onChanged: (v) => setState(() => AppState.I.keepAliveEnabled = v),
),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "KEEPALIVE1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_notification_service.dart lib/core/state.dart lib/ui/settings_screen.dart test/core_regression_test.dart
git commit -m "feat: background keep-alive toggle and Ready & Listening idle state"
```

---

### Task 2: Smart Stop semantics (Queue-aware turn abort vs panic stop)

**Files:**
- Modify: `lib/core/agent_service.dart:760-790` (add `stopRequested`)
- Modify: `lib/core/agent_notification_service.dart:70-85` (call `stopRequested`)
- Modify: `lib/ui/chat_screen.dart:4170-4190` (call `stopRequested` and update tooltip)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentService._cancelBucket`, `AgentService.cancelAllRuns`, `AgentRun.queue`
- Produces: `AgentService.stopRequested({String? sessionId}) -> bool` (returns true if turn aborted with queued message pending, false if full panic stop).

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('STOP2: stopRequested aborts turn only when queue is non-empty, panic stops when empty', () async {
  final agent = AgentService.I;
  final app = AppState.I;
  final s = ChatSession(id: 'stop2_sess', title: 'S', model: 'm', mode: 'auto');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  addTearDown(() {
    agent.clearQueueForTest();
    app.sessions.removeWhere((x) => x.id == 'stop2_sess');
  });

  // Empty queue -> panic stop across all runs
  final didQueueResume = agent.stopRequested(sessionId: s.id);
  expect(didQueueResume, isFalse);

  // Non-empty queue -> aborts current bucket only, preserves queued item
  agent.queueMessageForTest('follow up prompt');
  final didQueueResume2 = agent.stopRequested(sessionId: s.id);
  expect(didQueueResume2, isTrue);
  expect(agent.queuedMessages, contains('follow up prompt'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "STOP2"`
Expected: FAIL with "stopRequested isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  /// Queue-aware stop request:
  /// - If the target session has queued messages: aborts the CURRENT turn only,
  ///   leaving the queue intact so the next instruction runs immediately.
  /// - If the queue is empty: performs a full panic stop (clears all queues,
  ///   cancels all runs, kills all processes).
  /// Returns `true` if a queued continuation was preserved, `false` on full panic stop.
  bool stopRequested({String? sessionId}) {
    final sid = sessionId ?? AppState.I.activeSessionId;
    final r = _runs[sid];
    if (r != null && r.queue.isNotEmpty) {
      _cancelBucket(r);
      return true;
    }
    for (final b in _runs.values) {
      b.queue.clear();
    }
    cancelAllRuns();
    return false;
  }
```

In `lib/core/agent_notification_service.dart`:
```dart
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAgentStop') {
        AgentService.I.stopRequested();
      } else if (call.method == 'onAgentExit') {
        AgentService.I.cancelAllRuns();
        if (_onExitCallback != null) {
          _onExitCallback!();
        }
      }
      return null;
    });
```

In `lib/ui/chat_screen.dart:4170-4188`:
Update tooltip and onPressed:
```dart
  final hasQueued = AgentService.I.queuedMessages.isNotEmpty;
  final tip = runningNow && !hasDraft
      ? (hasQueued ? 'Stop current turn (next queued will run)' : 'Stop (panic stop)')
      : (hasDraft ? 'Send' : 'Send message');

  ...
  onPressed: () {
    if (runningNow && !hasDraft) {
      AgentService.I.stopRequested(sessionId: session.id);
    } else {
      onSend();
    }
  },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "STOP2"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart lib/core/agent_notification_service.dart lib/ui/chat_screen.dart test/core_regression_test.dart
git commit -m "feat: smart queue-aware Stop semantics"
```

---

### Task 3: Tri-state service health model

**Files:**
- Modify: `lib/core/state.dart:180-220` (add `ServiceHealth`, `ServiceStatus`, `serviceStatus` map)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AppState`
- Produces: `enum ServiceHealth { connecting, working, failed }`, `class ServiceStatus`, `AppState.updateServiceStatus`, `AppState.serviceStatusForTest`

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('HEALTH1: tri-state ServiceHealth model transitions connecting -> working -> failed', () {
  final app = AppState.I;
  app.updateServiceStatus('mcp:test_srv', ServiceHealth.connecting, detail: 'spawning');
  expect(app.serviceStatusForTest('mcp:test_srv')?.health, ServiceHealth.connecting);
  expect(app.serviceStatusForTest('mcp:test_srv')?.detail, 'spawning');

  app.updateServiceStatus('mcp:test_srv', ServiceHealth.working, detail: '4 tools ready');
  expect(app.serviceStatusForTest('mcp:test_srv')?.health, ServiceHealth.working);

  app.updateServiceStatus('mcp:test_srv', ServiceHealth.failed, detail: 'process exited 1');
  expect(app.serviceStatusForTest('mcp:test_srv')?.health, ServiceHealth.failed);
  expect(app.serviceStatusForTest('mcp:test_srv')?.detail, 'process exited 1');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "HEALTH1"`
Expected: FAIL with "ServiceHealth isn't a type".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/state.dart`:
```dart
enum ServiceHealth { connecting, working, failed }

class ServiceStatus {
  final ServiceHealth health;
  final String detail;
  final DateTime updatedAt;

  const ServiceStatus({
    required this.health,
    this.detail = '',
    required this.updatedAt,
  });
}
```

In `AppState`:
```dart
  final Map<String, ServiceStatus> serviceStatus = {};

  void updateServiceStatus(
    String key,
    ServiceHealth health, {
    String detail = '',
  }) {
    serviceStatus[key] = ServiceStatus(
      health: health,
      detail: detail,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
  }

  @visibleForTesting
  ServiceStatus? serviceStatusForTest(String key) => serviceStatus[key];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "HEALTH1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: tri-state ServiceHealth model"
```

---

### Task 4: Re-init wiring on resume & UI indicators

**Files:**
- Modify: `lib/core/state.dart:2785-2810` (`reconnectServices`)
- Modify: `lib/main.dart:148-175` (lifecycle resume calling `reconnectServices`)
- Modify: `lib/ui/plugins_screen.dart:600-640` (tri-state status chips)
- Modify: `lib/ui/health_screen.dart:150-190` (surface service health)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AppState.serviceStatus`, `McpService.I`, `PluginItem`
- Produces: `AppState.reconnectServices()` covering both MCP servers and enabled plugins; UI rendering amber/green/red icons.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('HEALTH2: reconnectServices updates health to connecting and then working or failed', () async {
  final app = AppState.I;
  final server = McpServer(
    name: 'health2_srv',
    author: 'test',
    description: 'desc',
    category: 'custom',
    command: 'echo',
    custom: true,
  );
  app.mcpServers.add(server);
  addTearDown(() => app.mcpServers.removeWhere((s) => s.name == 'health2_srv'));

  await app.reconnectServices(targetServers: ['health2_srv']);
  final st = app.serviceStatusForTest('mcp:health2_srv');
  expect(st, isNotNull);
  expect(st!.health, isIn([ServiceHealth.working, ServiceHealth.failed]));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "HEALTH2"`
Expected: FAIL with "reconnectServices isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/state.dart`:
```dart
  /// Reconnect both MCP servers and enabled plugins on app launch / resume.
  Future<void> reconnectServices({List<String>? targetServers}) async {
    List<String> names = targetServers ?? [];
    if (targetServers == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        names = prefs.getStringList(_kMcpConnectedIntent) ?? [];
      } catch (_) {
        names = [];
      }
    }

    for (final name in names) {
      final s = mcpServers.where((s) => s.name == name).firstOrNull;
      if (s == null) continue;
      updateServiceStatus('mcp:$name', ServiceHealth.connecting, detail: 'connecting…');
      try {
        final res = await McpService.I.connect(s);
        final isOk = McpService.I.isConnected(name);
        s.connected = isOk;
        updateServiceStatus(
          'mcp:$name',
          isOk ? ServiceHealth.working : ServiceHealth.failed,
          detail: res,
        );
      } catch (e) {
        s.connected = false;
        updateServiceStatus('mcp:$name', ServiceHealth.failed, detail: '$e');
      }
    }

    // Re-verify enabled plugins
    for (final p in plugins.where((p) => p.installed && p.enabled)) {
      updateServiceStatus('plugin:${p.name}', ServiceHealth.working, detail: 'enabled');
    }
    refresh();
  }
```

In `lib/main.dart`:
Replace `AppState.I.reconnectMcpServers()` with `AppState.I.reconnectServices()` in `initState` and in `didChangeAppLifecycleState(AppLifecycleState.resumed)`.

In `lib/ui/plugins_screen.dart`:
In server listing, check `AppState.I.serviceStatus['mcp:${server.name}']`:
- If `health == ServiceHealth.connecting`: show pulsating amber `SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Aether.accent))`
- If `health == ServiceHealth.working`: show green `Icons.check_circle_outline`
- If `health == ServiceHealth.failed`: show red `Icons.error_outline` with tooltip `status.detail`

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "HEALTH2"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/state.dart lib/main.dart lib/ui/plugins_screen.dart lib/ui/health_screen.dart test/core_regression_test.dart
git commit -m "feat: reconnect services on resume and surface tri-state health UI"
```

---

### Task 5: Streaming browser downloads (200MB disk pipe)

**Files:**
- Modify: `lib/core/agent_service.dart:8520-8565` (`_handleBrowserDownload` streaming)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `containedPath`, `_sessionWorkDir`, `HttpClient`
- Produces: `AgentService.downloadFileStreamingForTest`, 200MB download cap, zero memory accumulation.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('DL1: streaming download enforces 200MB cap and writes directly to file', () async {
  final tempDir = Directory.systemTemp.createTempSync('dl1_test');
  final dest = '${tempDir.path}/test_out.bin';
  addTearDown(() => tempDir.deleteSync(recursive: true));

  // Test cap check pure helper
  final result = await AgentService.downloadStreamHelperForTest(
    dataStream: Stream.value(List<int>.filled(1024, 65)),
    destPath: dest,
    maxBytes: 512,
  );
  expect(result, contains('file too large'));
  expect(File(dest).existsSync(), isFalse);

  // Under cap -> file written
  final okResult = await AgentService.downloadStreamHelperForTest(
    dataStream: Stream.value(List<int>.filled(256, 66)),
    destPath: dest,
    maxBytes: 512,
  );
  expect(okResult, contains('downloaded ✓'));
  expect(File(dest).lengthSync(), equals(256));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "DL1"`
Expected: FAIL with "downloadStreamHelperForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  @visibleForTesting
  static Future<String> downloadStreamHelperForTest({
    required Stream<List<int>> dataStream,
    required String destPath,
    int maxBytes = 200 * 1024 * 1024,
  }) async {
    final f = File(destPath);
    if (f.existsSync()) f.deleteSync();
    f.parent.createSync(recursive: true);
    final sink = f.openWrite();
    int received = 0;
    try {
      await for (final chunk in dataStream) {
        received += chunk.length;
        if (received > maxBytes) {
          await sink.close();
          if (f.existsSync()) f.deleteSync();
          return 'file too large (${received} bytes, cap ${maxBytes ~/ (1024 * 1024)}MB)';
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      return 'downloaded ✓ · ${f.uri.pathSegments.last} · $received bytes';
    } catch (e) {
      await sink.close();
      if (f.existsSync()) f.deleteSync();
      return 'download failed: $e';
    }
  }
```

Update `_handleBrowserDownload`:
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
    if (safe == null) {
      return 'path escapes the session workspace: $name — use a path inside the workspace.';
    }
    _emit('nav', 'downloading: $name');
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'OvidAgent/1.0');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        return 'download failed (HTTP ${resp.statusCode})';
      }
      final res = await downloadStreamHelperForTest(
        dataStream: resp,
        destPath: safe,
        maxBytes: 200 * 1024 * 1024,
      );
      if (res.contains('downloaded ✓')) {
        _recordProduced(safe, File(safe).lengthSync());
        return '$res (workspace — read with read_attachment)';
      }
      return res;
    } catch (e) {
      return 'download failed: $e';
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "DL1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "feat: streaming browser download with 200MB cap"
```

---

### Task 6: Chunked browser file uploads (50MB cap)

**Files:**
- Modify: `lib/core/agent_service.dart:8565-8615` (`_handleBrowserUpload` chunked)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `containedPath`, `_sessionWorkDir`, `BrowserTab.controller`
- Produces: `AgentService.chunkFileForUploadForTest`, 50MB upload cap, 256KB base64 chunked JS staging.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('UP1: upload chunking splits bytes into 256KB segments and enforces 50MB cap', () {
  final small = Uint8List(500 * 1024); // 500KB
  final chunks = AgentService.chunkFileForUploadForTest(small, chunkSize: 256 * 1024);
  expect(chunks.length, equals(2));
  expect(chunks[0].length, equals(256 * 1024));
  expect(chunks[1].length, equals(244 * 1024));

  final isAllowed = AgentService.isUploadSizeAllowedForTest(50 * 1024 * 1024);
  expect(isAllowed, isTrue);
  final isExceeded = AgentService.isUploadSizeAllowedForTest(50 * 1024 * 1024 + 1);
  expect(isExceeded, isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "UP1"`
Expected: FAIL with "chunkFileForUploadForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  @visibleForTesting
  static List<Uint8List> chunkFileForUploadForTest(Uint8List bytes, {int chunkSize = 256 * 1024}) {
    final List<Uint8List> chunks = [];
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      chunks.add(bytes.sublist(i, end));
    }
    return chunks;
  }

  @visibleForTesting
  static bool isUploadSizeAllowedForTest(int size, {int maxBytes = 50 * 1024 * 1024}) =>
      size <= maxBytes;
```

Update `_handleBrowserUpload`:
```dart
  Future<String> _handleBrowserUpload(Map<String, dynamic> args) async {
    final sel = (args['selector'] as String? ?? '').trim();
    final rel = (args['path'] as String? ?? '').trim();
    if (sel.isEmpty || rel.isEmpty) return 'selector and path are required';
    final work = await _sessionWorkDir();
    final safe = containedPath(work, rel);
    if (safe == null) {
      return 'path escapes the session workspace: $rel — use a path inside the workspace.';
    }
    final f = File(safe);
    if (!f.existsSync()) return 'No file "$rel" in the session workspace.';
    if (!isUploadSizeAllowedForTest(f.lengthSync())) {
      return 'file too large for upload (cap 50MB)';
    }
    final tab = _activeTab;
    tab.controller ??= controllerForTab(tab);
    try {
      final bytes = await f.readAsBytes();
      final chunks = chunkFileForUploadForTest(bytes);
      final fname = safe.split('/').last.replaceAll("'", '');

      // Initialize buffer on window
      await tab.controller!.runJavaScript('window.__ovidUploadBuf = [];');
      for (final chunk in chunks) {
        final b64 = base64Encode(chunk);
        await tab.controller!.runJavaScript(
          'window.__ovidUploadBuf.push(${jsonEncode(b64)});',
        );
      }

      final jsFinalize = '''
(() => {
  const el = document.querySelector(${jsonEncode(sel)});
  if (!el) return 'no element: $sel';
  if (el.tagName.toLowerCase() !== 'input' || el.type !== 'file') return 'not a file input: $sel';
  const parts = window.__ovidUploadBuf || [];
  window.__ovidUploadBuf = null;
  const binary = parts.map(b => atob(b)).join('');
  const arr = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
  const file = new File([arr], ${jsonEncode(fname)});
  const dt = new DataTransfer();
  dt.items.add(file);
  el.files = dt.files;
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true}));
  return 'staged ' + ${jsonEncode(fname)};
})()''';
      final r = await tab.controller!.runJavaScriptReturningResult(jsFinalize);
      _emit('shell', 'upload $rel → $sel');
      return r.toString();
    } catch (e) {
      return 'upload failed: $e';
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "UP1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "feat: chunked browser upload with 50MB cap"
```

---

### Task 7: User-initiated page file selector hook & SAF export support

**Files:**
- Modify: `lib/core/agent_service.dart:1250-1310` (wire `setOnShowFileSelector` in `controllerForTab`)
- Modify: `lib/core/agent_service.dart:8610-8650` (SAF export helper)
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:50-110` (SAF method channel handlers)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `webview_flutter_android` `AndroidWebViewController`, `file_picker`, `MainActivity`
- Produces: Native file chooser delegate for web pages; `exportFileToSaf` helper for user-visible file exports.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('SAF1: exportFileToSaf validates path containment and surfaces result', () async {
  final res = await AgentService.I.exportFileToSafForTest('../outside.txt');
  expect(res, contains('path escapes the session workspace'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SAF1"`
Expected: FAIL with "exportFileToSafForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  @visibleForTesting
  Future<String> exportFileToSafForTest(String relPath) async {
    final work = await _sessionWorkDir();
    final safe = containedPath(work, relPath);
    if (safe == null) {
      return 'path escapes the session workspace: $relPath';
    }
    final f = File(safe);
    if (!f.existsSync()) return 'file not found: $relPath';
    try {
      const channel = MethodChannel('ovid/native');
      final ok = await channel.invokeMethod<bool>('safExportFile', {
        'sourcePath': safe,
        'fileName': safe.split('/').last,
      });
      return ok == true ? 'exported ✓' : 'export cancelled';
    } catch (e) {
      return 'export failed: $e';
    }
  }
```

In `controllerForTab`:
```dart
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);

    if (WebViewPlatform.instance != null &&
        controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setOnShowFileSelector((params) async {
        try {
          final result = await FilePicker.platform.pickFiles(
            allowMultiple: params.mode == FileSelectorMode.openMultiple,
          );
          if (result == null || result.files.isEmpty) return [];
          return result.files
              .where((f) => f.path != null)
              .map((f) => Uri.file(f.path!).toString())
              .toList();
        } catch (_) {
          return [];
        }
      });
    }
```

In `MainActivity.kt`:
Add handler for `safExportFile`:
```kotlin
"safExportFile" -> {
    val src = call.argument<String>("sourcePath")
    val name = call.argument<String>("fileName")
    if (src != null && name != null) {
        val srcFile = File(src)
        if (srcFile.exists()) {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_TITLE, name)
            }
            startActivity(intent)
            result.success(true)
        } else {
            result.error("NOT_FOUND", "Source file not found", null)
        }
    } else {
        result.error("BAD_ARGS", "Missing sourcePath or fileName", null)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SAF1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt test/core_regression_test.dart
git commit -m "feat: page file chooser integration and SAF export support"
```

---

### Task 8: `AgentMode.control` enum, rank 4, and cold-start fallback

**Files:**
- Modify: `lib/core/agent_service.dart:75-108` (`AgentMode.control`, icons, colors)
- Modify: `lib/core/agent_service.dart:3570-3580` (tool schema mode enum)
- Modify: `lib/core/agent_service.dart:10105-10115` (`_modeRank`)
- Modify: `lib/core/commands.dart:268-285` (`/permission` confirm gate)
- Modify: `lib/core/state.dart:530-550` (cold start sanitize)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentMode`, `_modeRank`, `commands.dart`
- Produces: `AgentMode.control`, `_modeRank(control) == 4`, subagent child capped at `drive`, cold-start fallback to `drive`.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('CTRL1: AgentMode.control has rank 4, requires confirm, and subagent inherits capped at drive', () {
  expect(AgentMode.values.map((m) => m.name), contains('control'));
  expect(AgentService.modeRankForTest(AgentMode.control), equals(4));

  // Subagent child dispatched from control runs at drive
  final childMode = AgentService.I.childModeForTest(
    modeName: 'control',
    parentModeOverride: AgentMode.control,
  );
  expect(childMode, equals(AgentMode.drive));

  // Cold start sanitizes control to drive
  expect(AppState.sanitizeColdStartMode('control'), equals('drive'));
  expect(AppState.sanitizeColdStartMode('auto'), equals('auto'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL1"`
Expected: FAIL with "AgentMode.control isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
enum AgentMode { safe, auto, drive, studio, control }

extension AgentModeX on AgentMode {
  String get label => switch (this) {
    AgentMode.safe => 'Read-Only',
    AgentMode.auto => 'General',
    AgentMode.drive => 'Full Access',
    AgentMode.studio => 'Studio',
    AgentMode.control => 'Control',
  };

  String get description => switch (this) {
    AgentMode.safe => 'Reads only — refuses file/repo/device writes.',
    AgentMode.auto => 'Standard agent — can edit files and run tools.',
    AgentMode.drive => 'Unrestricted agent — can run commands and tools.',
    AgentMode.studio => 'IDE agent — focused on codebase and open files.',
    AgentMode.control => 'Automated device & in-app control with safety guardrails.',
  };

  IconData get icon => switch (this) {
    AgentMode.safe => Icons.visibility_outlined,
    AgentMode.auto => Icons.tune_outlined,
    AgentMode.drive => Icons.rocket_launch_outlined,
    AgentMode.studio => Icons.code_rounded,
    AgentMode.control => Icons.accessibility_new_outlined,
  };

  Color get color => switch (this) {
    AgentMode.safe => Aether.success,
    AgentMode.auto => Aether.accent,
    AgentMode.drive => Aether.warn,
    AgentMode.studio => const Color(0xFF9B7EDE),
    AgentMode.control => Aether.danger,
  };
}
```

In `_modeRank`:
```dart
  static int _modeRank(AgentMode m) => switch (m) {
    AgentMode.safe => 0,
    AgentMode.auto => 1,
    AgentMode.studio => 2,
    AgentMode.drive => 3,
    AgentMode.control => 4,
  };

  @visibleForTesting
  static int modeRankForTest(AgentMode m) => _modeRank(m);
```

In `_handleDispatchAgent` / `childModeForTest`:
```dart
  // Subagents can never escalate beyond parent rank, and NEVER inherit control mode
  if (resolved == AgentMode.control) {
    resolved = AgentMode.drive;
  }
```

In `lib/core/commands.dart`:
```dart
if ((target == AgentMode.drive || target == AgentMode.control) && !flags.contains('confirm')) {
  return 'Switching to ${target.label} mode grants strong permissions. '
      'Run "/permission ${target.name} confirm" to proceed.';
}
```

In `lib/core/state.dart`:
```dart
  static String sanitizeColdStartMode(String mode) {
    return mode == 'control' ? 'drive' : mode;
  }
```
Apply `sanitizeColdStartMode` when deserializing `ChatSession.mode` from JSON.

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart lib/core/commands.dart lib/core/state.dart test/core_regression_test.dart
git commit -m "feat: AgentMode.control with rank 4 and cold-start fallback"
```

---

### Task 9: Phase A in-app control tools (`device_tap`, `device_type`, `device_swipe`, `device_snapshot`)

**Files:**
- Modify: `lib/core/agent_service.dart:6360-6420` (add tool dispatch cases)
- Modify: `lib/core/agent_service.dart:7160-7240` (implement `device_*` handlers)
- Modify: `lib/core/agent_service.dart:7940-7970` (`_readOnlyBlock`)
- Modify: `lib/core/agent_service.dart:9280-9300` (`_mutatingTools`)
- Modify: `lib/core/agent_service.dart:2160-2260` (tool schemas & titles)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentMode.control`, `_activeTab`, `BrowserTab.controller`
- Produces: `device_tap`, `device_type`, `device_swipe`, `device_snapshot`; all denied in read-only and plan mode, and denied when not in control mode.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('CTRL2: device_* tools denied in read-only, plan mode, and non-control modes', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'ctrl2', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'ctrl2');
  });

  // Read-only block
  expect(await AgentService.I.dispatchForTest('device_tap', {'selector': 'button'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('device_type', {'text': 'hello'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('device_swipe', {'from_x': 0, 'from_y': 0, 'to_x': 10, 'to_y': 10}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('device_snapshot', {}), contains('READ-ONLY MODE'));

  // Switch to auto mode -> must be denied because not in control mode
  s.mode = 'auto';
  expect(await AgentService.I.dispatchForTest('device_tap', {'selector': 'button'}), contains('requires Control mode'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL2"`
Expected: FAIL with "unknown tool".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
Add `device_tap`, `device_type`, `device_swipe`, `device_snapshot` to `_mutatingTools` and `_readOnlyBlock`'s denied list.

Add tool dispatch cases:
```dart
      case 'device_tap':
      case 'device_type':
      case 'device_swipe':
      case 'device_snapshot':
        if (mode != AgentMode.control) {
          return 'DENIED: Tool "$name" requires Control mode.';
        }
        return await _handleDeviceControlTool(name, args);
```

Implement `_handleDeviceControlTool`:
```dart
  Future<String> _handleDeviceControlTool(String name, Map<String, dynamic> args) async {
    final tab = _activeTab;
    if (tab.controller == null && browserTabs.isEmpty) {
      return 'Control surface not available — open a page first (browser_open).';
    }
    tab.controller ??= controllerForTab(tab);

    switch (name) {
      case 'device_snapshot':
        return await _handleBrowserSnapshot();

      case 'device_tap':
        final sel = args['selector'] as String?;
        final x = args['x'] as num?;
        final y = args['y'] as num?;
        final js = sel != null
            ? '''
(() => {
  const el = document.querySelector(${jsonEncode(sel)});
  if (!el) return 'no element: $sel';
  el.scrollIntoView({block:'center', behavior:'instant'});
  const r = el.getBoundingClientRect();
  const cx = r.left + r.width / 2;
  const cy = r.top + r.height / 2;
  const opts = {clientX: cx, clientY: cy, bubbles: true};
  el.dispatchEvent(new PointerEvent('pointerdown', opts));
  el.dispatchEvent(new MouseEvent('mousedown', opts));
  el.dispatchEvent(new PointerEvent('pointerup', opts));
  el.dispatchEvent(new MouseEvent('mouseup', opts));
  el.click();
  return 'tapped ' + ${jsonEncode(sel)};
})()'''
            : '''
(() => {
  const cx = ${x ?? 0}, cy = ${y ?? 0};
  const el = document.elementFromPoint(cx, cy) || document.body;
  const opts = {clientX: cx, clientY: cy, bubbles: true};
  el.dispatchEvent(new PointerEvent('pointerdown', opts));
  el.dispatchEvent(new PointerEvent('pointerup', opts));
  el.click();
  return 'tapped at (' + cx + ',' + cy + ')';
})()''';
        final r = await tab.controller!.runJavaScriptReturningResult(js);
        _emit('shell', 'device tap');
        return r.toString();

      case 'device_type':
        final sel = args['selector'] as String?;
        final text = (args['text'] as String? ?? '');
        final submit = args['submit'] as bool? ?? false;
        final js = '''
(() => {
  const el = ${sel != null ? 'document.querySelector(${jsonEncode(sel)})' : 'document.activeElement || document.body'};
  if (!el) return 'no element found';
  if (el.focus) el.focus();
  if ('value' in el) {
    el.value = ${jsonEncode(text)};
    el.dispatchEvent(new Event('input', {bubbles:true}));
    el.dispatchEvent(new Event('change', {bubbles:true}));
  }
  ${submit ? '''
  const form = el.closest('form');
  if (form) { form.requestSubmit ? form.requestSubmit() : form.submit(); }
  else {
    el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
    el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
  }''' : ''}
  return 'typed into control target';
})()''';
        final r = await tab.controller!.runJavaScriptReturningResult(js);
        _emit('shell', 'device type');
        return r.toString();

      case 'device_swipe':
        final fx = args['from_x'] as num;
        final fy = args['from_y'] as num;
        final tx = args['to_x'] as num;
        final ty = args['to_y'] as num;
        final steps = (args['steps'] as num? ?? 5).toInt().clamp(1, 20);
        final js = '''
(() => {
  const el = document.elementFromPoint($fx, $fy) || document.body;
  el.dispatchEvent(new PointerEvent('pointerdown', {clientX: $fx, clientY: $fy, bubbles: true}));
  for (let i = 1; i <= $steps; i++) {
    const cx = $fx + ($tx - $fx) * (i / $steps);
    const cy = $fy + ($ty - $fy) * (i / $steps);
    el.dispatchEvent(new PointerEvent('pointermove', {clientX: cx, clientY: cy, bubbles: true}));
  }
  el.dispatchEvent(new PointerEvent('pointerup', {clientX: $tx, clientY: $ty, bubbles: true}));
  return 'swiped ($fx,$fy) -> ($tx,$ty)';
})()''';
        final r = await tab.controller!.runJavaScriptReturningResult(js);
        _emit('shell', 'device swipe');
        return r.toString();

      default:
        return 'unknown device tool: $name';
    }
  }
```

Add schemas to `_coreTools`:
```dart
  'device_tap' => {
    'name': 'device_tap',
    'description': 'Simulate tap or click on active control tab at selector or coordinates.',
    'parameters': {
      'type': 'object',
      'properties': {
        'selector': {'type': 'string', 'description': 'CSS selector'},
        'x': {'type': 'number', 'description': 'X viewport coordinate'},
        'y': {'type': 'number', 'description': 'Y viewport coordinate'},
      },
    },
  },
  'device_type': ...
  'device_swipe': ...
  'device_snapshot': ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL2"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "feat: Phase A in-app control tools with double gating"
```

---

### Task 10: Control safety guardrails (Sensitive domain denylist & Phase B gate)

**Files:**
- Modify: `lib/core/state.dart:40-60` (`kEnableDeviceControl`, `kDeniedControlDomains`)
- Modify: `lib/core/agent_service.dart:7160-7190` (denylist check in `_handleDeviceControlTool`)
- Modify: `lib/ui/chat_screen.dart:2100-2130` (control mode disclosure card)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `kDeniedControlDomains`, `kEnableDeviceControl`
- Produces: Blocking device control tools on sensitive banking/payment domains; in-chat disclosure message.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('SAFE1: control tools block execution on sensitive domains and Phase B is gated off', () async {
  expect(kEnableDeviceControl, isFalse);

  final isBlocked = AgentService.isDomainBlockedForControlForTest('https://www.paypal.com/signin');
  expect(isBlocked, isTrue);

  final isAllowed = AgentService.isDomainBlockedForControlForTest('https://example.com');
  expect(isAllowed, isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SAFE1"`
Expected: FAIL with "kEnableDeviceControl isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/state.dart`:
```dart
/// Phase B device-wide accessibility control compile-time gate.
const bool kEnableDeviceControl = false;

/// Sensitive domains where automated control mode is blocked.
const List<String> kDeniedControlDomains = [
  'paypal.com',
  'wise.com',
  'chase.com',
  'bankofamerica.com',
  'wellsfargo.com',
  'citigroup.com',
  'capitalone.com',
];

/// User-visible disclosure text when switching to Control mode.
const String kControlModeDisclosure =
    'Control mode lets Ovid operate the app on your behalf — tapping and typing '
    'inside pages you opened. It never sees other apps in this version, never '
    'autofills passwords, and every action is logged in this chat. You can switch '
    'modes any time; switching down takes effect immediately.';
```

In `lib/core/agent_service.dart`:
```dart
  @visibleForTesting
  static bool isDomainBlockedForControlForTest(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    for (final d in kDeniedControlDomains) {
      if (host == d || host.endsWith('.$d')) return true;
    }
    return false;
  }
```

In `_handleDeviceControlTool`:
```dart
    final currentUrl = tab.url;
    if (isDomainBlockedForControlForTest(currentUrl)) {
      return 'BLOCKED: Automated control is restricted on sensitive domains for your security ($currentUrl).';
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SAFE1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/state.dart lib/core/agent_service.dart lib/ui/chat_screen.dart test/core_regression_test.dart
git commit -m "feat: control mode safety denylist and disclosure copy"
```

---

### Task 11: Full regression verification & integration sweep

**Files:**
- Verify all modified files in `lib/` and `test/`
- Test: entire test suite `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Tasks 1-10 deliverables
- Produces: 0 analyzer warnings, 100% green test suite.

- [ ] **Step 1: Run static analysis**

Run: `/home/ubuntu/sdk/flutter/bin/flutter analyze`
Expected: "No issues found!"

- [ ] **Step 2: Run full regression test suite**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: All 385+ tests passed.

- [ ] **Step 3: Verification commit & tag checkpoint**

```bash
git status
git commit -m "chore: full regression verification and integration check" --allow-empty
```

---

## Self-Review

1. **Spec coverage:**
   - W1 (§2): Control mode architecture -> Task 8 (`AgentMode.control`, rank 4) & Task 9 (Phase A 4 tools)
   - W2 (§3): MCP/plugin re-init + tri-state health -> Task 3 (`ServiceHealth` model) & Task 4 (re-init wiring + UI)
   - W3 (§4): Real browser file handling -> Task 5 (200MB streaming download) & Task 6 (50MB chunked upload) & Task 7 (file selector hook + SAF export)
   - W4 (§5): Queue / Stop / Keep-alive semantics -> Task 1 (keep-alive) & Task 2 (smart stop)
   - W5 (§6): Play-safety guardrails -> Task 10 (denylist, disclosure copy)
   - W6 (§2.4): Accessibility disclosure flow gated off -> Task 10 (`kEnableDeviceControl = false`)
2. **Placeholder scan:** No TBD, no TODO, all exact paths, exact code blocks, exact terminal commands and assertions provided.
3. **Type consistency:** `ServiceHealth { connecting, working, failed }`, `AgentMode.control`, `stopRequested({String? sessionId})`, `downloadStreamHelperForTest`, `isDomainBlockedForControlForTest` match exactly across all tasks.
