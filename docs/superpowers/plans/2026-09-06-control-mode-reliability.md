# Control Mode, Service Reliability, Real File Handling & Play Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement device-wide Control Mode backed by an Android AccessibilityService (any app, including Back/Home/Recents), node-tree screen reading that avoids per-action screenshots, persistent keep-alive foreground service semantics, queue-aware smart Stop, tri-state health tracking with resume re-init, uncapped streaming browser downloads and uploads, and Play Store safety guardrails.

**Architecture:** Extend `AgentMode` with rank-4 `control` mode double-gated by mode check and read-only/plan blocks; decouple queue draining on cancel to allow single-turn abort when queued items exist vs global panic stop; replace in-memory byte buffers in browser file handling with streaming disk pipes and JS buffer chunking with no size ceiling; unify MCP and plugin health under a tri-state model (`connecting`, `working`, `failed`) refreshed on app resume; add `OvidAccessibilityService` exposing global navigation, gesture dispatch, node-tree reads with an event-driven dirty flag, delta diffs, node-handle actions, and screenshot only as a fallback.

**Tech Stack:** Flutter 3 / Dart 3, `webview_flutter` 4.8, `file_picker`, Android Foreground Service (`dataSync`), Android AccessibilityService, `flutter test`.

**Spec:** `docs/superpowers/specs/2026-09-06-control-mode-reliability-design.md` @ `0bd0c47`.

## Global Constraints

- Flutter binary path is `/home/ubuntu/sdk/flutter/bin/flutter` (`flutter` is not in global PATH).
- TDD RED→GREEN required; run verification commands before any success assertion.
- Downloads land in the session workspace (agent-readable, containment-checked), never public Downloads.
- Read-Only + plan-mode gates stay: every new interactive tool MUST be denied in both gates.
- Zero reference-web mentions in `lib/` and `test/`.
- Do not break the existing test suite (all currently-green tests must stay green).
- No artificial size caps on browser downloads or uploads — only real device free space limits.
- Node tree is the primary screen reader; screenshots only on empty tree, explicit request, or genuine image content.
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

### Task 5: Streaming browser downloads (uncapped, disk-space bounded)

**Files:**
- Modify: `lib/core/agent_service.dart:8520-8565` (`_handleBrowserDownload` streaming)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `containedPath`, `_sessionWorkDir`, `HttpClient`
- Produces: `AgentService.downloadStreamHelperForTest`, no size cap, zero memory accumulation, partial-file cleanup on failure.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('DL1: streaming download writes directly to disk with no size cap', () async {
  final tempDir = Directory.systemTemp.createTempSync('dl1_test');
  final dest = '${tempDir.path}/test_out.bin';
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // A payload far larger than any old cap streams through untouched.
  final bigChunks = Stream<List<int>>.fromIterable(
    List.generate(64, (_) => List<int>.filled(64 * 1024, 65)),
  );
  final okResult = await AgentService.downloadStreamHelperForTest(
    dataStream: bigChunks,
    destPath: dest,
  );
  expect(okResult, contains('downloaded ✓'));
  expect(File(dest).lengthSync(), equals(64 * 64 * 1024));

  // A mid-stream error deletes the partial file instead of leaving junk.
  final failing = Stream<List<int>>.fromIterable([
    List<int>.filled(128, 66),
  ]).asyncExpand((c) async* {
    yield c;
    throw const SocketException('connection reset');
  });
  final failResult = await AgentService.downloadStreamHelperForTest(
    dataStream: failing,
    destPath: dest,
  );
  expect(failResult, contains('download failed'));
  expect(File(dest).existsSync(), isFalse);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "DL1"`
Expected: FAIL with "downloadStreamHelperForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  /// Stream [dataStream] straight to [destPath] in whatever chunks arrive.
  /// There is no artificial size cap: the only limit is real free space, and
  /// a write failure (ENOSPC or a dropped connection) deletes the partial
  /// file and reports honestly.
  @visibleForTesting
  static Future<String> downloadStreamHelperForTest({
    required Stream<List<int>> dataStream,
    required String destPath,
  }) async {
    final f = File(destPath);
    if (f.existsSync()) f.deleteSync();
    f.parent.createSync(recursive: true);
    final sink = f.openWrite();
    int received = 0;
    try {
      await for (final chunk in dataStream) {
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      return 'downloaded ✓ · ${f.uri.pathSegments.last} · $received bytes';
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
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
      final total = resp.contentLength;
      if (total > 0) {
        _emit('nav', 'downloading: $name (${(total / (1024 * 1024)).toStringAsFixed(1)} MB)');
      }
      final res = await downloadStreamHelperForTest(
        dataStream: resp,
        destPath: safe,
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
git commit -m "feat: uncapped streaming browser download"
```


---

### Task 6: Chunked browser file uploads (uncapped)

**Files:**
- Modify: `lib/core/agent_service.dart:8565-8615` (`_handleBrowserUpload` chunked)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `containedPath`, `_sessionWorkDir`, `BrowserTab.controller`
- Produces: `AgentService.chunkFileForUploadForTest`, no upload cap, 256KB base64 chunked JS staging via streaming reads.

- [ ] **Step 1: Write the failing test**

In `test/core_regression_test.dart`:

```dart
test('UP1: upload chunking splits bytes into 256KB segments with no size cap', () {
  final small = Uint8List(500 * 1024); // 500KB
  final chunks = AgentService.chunkFileForUploadForTest(small, chunkSize: 256 * 1024);
  expect(chunks.length, equals(2));
  expect(chunks[0].length, equals(256 * 1024));
  expect(chunks[1].length, equals(244 * 1024));

  // Exact multiples produce no trailing empty chunk.
  final exact = Uint8List(512 * 1024);
  final exactChunks = AgentService.chunkFileForUploadForTest(exact, chunkSize: 256 * 1024);
  expect(exactChunks.length, equals(2));

  // An empty file yields no chunks rather than one empty chunk.
  expect(AgentService.chunkFileForUploadForTest(Uint8List(0)), isEmpty);

  // Sizes far beyond any old cap still chunk cleanly — no ceiling exists.
  final huge = Uint8List(3 * 1024 * 1024);
  final hugeChunks = AgentService.chunkFileForUploadForTest(huge, chunkSize: 256 * 1024);
  expect(hugeChunks.length, equals(12));
  expect(hugeChunks.fold<int>(0, (a, c) => a + c.length), equals(huge.length));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "UP1"`
Expected: FAIL with "chunkFileForUploadForTest isn't defined".

- [ ] **Step 3: Write minimal implementation**

In `lib/core/agent_service.dart`:
```dart
  /// Split [bytes] into upload chunks. There is no size cap — chunking is
  /// what removes the JS string-length wall, so any file the device can
  /// store can be staged.
  @visibleForTesting
  static List<Uint8List> chunkFileForUploadForTest(Uint8List bytes, {int chunkSize = 256 * 1024}) {
    final List<Uint8List> chunks = [];
    for (int i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      chunks.add(bytes.sublist(i, end));
    }
    return chunks;
  }
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
    final tab = _activeTab;
    tab.controller ??= controllerForTab(tab);
    final fname = safe.split('/').last.replaceAll("'", '');
    try {
      // Stream the file so the whole thing is never resident in Dart memory;
      // each 256KB slice is base64'd and pushed into a JS-side buffer.
      await tab.controller!.runJavaScript('window.__ovidUploadBuf = [];');
      int staged = 0;
      await for (final slice in f.openRead()) {
        for (final chunk in chunkFileForUploadForTest(Uint8List.fromList(slice))) {
          await tab.controller!.runJavaScript(
            'window.__ovidUploadBuf.push(${jsonEncode(base64Encode(chunk))});',
          );
          staged += chunk.length;
        }
      }

      final jsFinalize = '''
(() => {
  const el = document.querySelector(${jsonEncode(sel)});
  if (!el) { window.__ovidUploadBuf = null; return 'no element: $sel'; }
  if (el.tagName.toLowerCase() !== 'input' || el.type !== 'file') {
    window.__ovidUploadBuf = null;
    return 'not a file input: $sel';
  }
  const parts = window.__ovidUploadBuf || [];
  window.__ovidUploadBuf = null;
  const blobs = parts.map(b => {
    const bin = atob(b);
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    return arr;
  });
  const file = new File(blobs, ${jsonEncode(fname)});
  const dt = new DataTransfer();
  dt.items.add(file);
  el.files = dt.files;
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true}));
  return 'staged ' + ${jsonEncode(fname)};
})()''';
      final r = await tab.controller!.runJavaScriptReturningResult(jsFinalize);
      _emit('shell', 'upload $rel → $sel ($staged bytes)');
      return r.toString();
    } catch (e) {
      try {
        await tab.controller!.runJavaScript('window.__ovidUploadBuf = null;');
      } catch (_) {}
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
git commit -m "feat: uncapped chunked browser upload"
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

### Task 9: Android device-control bridge (AccessibilityService + cached node tree)

**Files:**
- Create: `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt`
- Create: `android/app/src/main/res/xml/ovid_accessibility_service.xml`
- Modify: `android/app/src/main/AndroidManifest.xml` (register service)
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt` (MethodChannel bridge)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: Android `AccessibilityService`, `AccessibilityNodeInfo`, `dispatchGesture`, `performGlobalAction`, API 30 `takeScreenshot`.
- Produces native channel methods: `deviceServiceEnabled`, `deviceOpenAccessibilitySettings`, `deviceRead`, `deviceTap`, `deviceType`, `deviceSwipe`, `deviceSystemNav`, `deviceScreenshot`.
- `deviceRead` returns `{status, package, window, full, added, changed, removed}`; node rows contain stable `handle`, class, text, description, viewId, bounds, clickable/editable/scrollable/password/checked/focused flags.

- [ ] **Step 1: Write the failing source-contract test**

```dart
test('CTRL2: native accessibility service supports cached reads, global nav, gestures, and screenshots', () {
  final service = File(
    'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
  );
  expect(service.existsSync(), isTrue);
  final src = service.readAsStringSync();
  expect(src, contains('class OvidAccessibilityService : AccessibilityService()'));
  expect(src, contains('TYPE_WINDOW_CONTENT_CHANGED'));
  expect(src, contains('TYPE_WINDOW_STATE_CHANGED'));
  expect(src, contains('dirty = true'));
  expect(src, contains('rootInActiveWindow'));
  expect(src, contains('GLOBAL_ACTION_BACK'));
  expect(src, contains('GLOBAL_ACTION_HOME'));
  expect(src, contains('GLOBAL_ACTION_RECENTS'));
  expect(src, contains('dispatchGesture'));
  expect(src, contains('takeScreenshot'));

  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  expect(manifest, contains('.OvidAccessibilityService'));
  expect(manifest, contains('android.permission.BIND_ACCESSIBILITY_SERVICE'));
  expect(manifest, contains('android.accessibilityservice.AccessibilityService'));

  final config = File(
    'android/app/src/main/res/xml/ovid_accessibility_service.xml',
  ).readAsStringSync();
  expect(config, contains('typeWindowStateChanged|typeWindowContentChanged'));
  expect(config, contains('canRetrieveWindowContent="true"'));
  expect(config, contains('canPerformGestures="true"'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL2"`
Expected: FAIL because `OvidAccessibilityService.kt` does not exist.

- [ ] **Step 3: Implement the native service and bridge**

Create the service with these exact invariants:

```kotlin
class OvidAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var instance: OvidAccessibilityService? = null
            private set
    }

    private var dirty = true
    private var windowSignature = ""
    private var previousRows = linkedMapOf<String, Map<String, Any?>>()
    private val nodesByHandle = mutableMapOf<Int, AccessibilityNodeInfo>()
    private val handlesByStableKey = mutableMapOf<String, Int>()
    private var nextHandle = 1

    override fun onServiceConnected() { instance = this; dirty = true }
    override fun onDestroy() { clearNodeHandles(); instance = null; super.onDestroy() }
    override fun onInterrupt() = Unit

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> dirty = true
        }
    }
}
```

Implement `readScreen(forceFull: Boolean)` so it:

1. Returns `status=unchanged` without traversing if `!dirty && !forceFull`.
2. Traverses `rootInActiveWindow` only on demand, depth-first, max 300 visible/non-zero nodes and max depth 30.
3. Derives a stable key from `viewIdResourceName|className|text|contentDescription|bounds` and reuses its integer handle.
4. Keeps `AccessibilityNodeInfo.obtain(node)` in `nodesByHandle`, recycling old entries on rebuild.
5. Forces a full result when package/window signature changes; otherwise returns added/changed/removed delta maps.
6. Sets `dirty=false` only after a successful build.

Implement actions:

- `tap(handle,x,y)`: `ACTION_CLICK` on handle when supplied; otherwise `dispatchGesture` tap.
- `type(handle,text,submit)`: refuse nodes where `isPassword`; use `ACTION_SET_TEXT` bundle; submit with `ACTION_IME_ENTER` when available.
- `swipe(from,to,duration)`: `GestureDescription.StrokeDescription`.
- `systemNav(action)`: exact map `back/home/recents/notifications/quick_settings` to `GLOBAL_ACTION_*`.
- `takeScreen(result)`: API 30 `takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, ...)`, write PNG under `cacheDir/device-captures/`, return absolute path; lower APIs return an unsupported error.

Register the service in the manifest:

```xml
<service
    android:name=".OvidAccessibilityService"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/ovid_accessibility_service" />
</service>
```

Create `res/xml/ovid_accessibility_service.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged"
    android:accessibilityFeedbackType="feedbackGeneric"
    android:notificationTimeout="100"
    android:canRetrieveWindowContent="true"
    android:canPerformGestures="true"
    android:canTakeScreenshot="true"
    android:description="@string/ovid_accessibility_description" />
```

Add `ovid_accessibility_description` to `res/values/strings.xml` (create it if absent) and route every native channel method in `MainActivity.configureFlutterEngine`. `deviceOpenAccessibilitySettings` starts `Settings.ACTION_ACCESSIBILITY_SETTINGS`; all other methods return `SERVICE_DISABLED` when `instance == null`.

- [ ] **Step 4: Verify focused test and Android compilation**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL2"`
Expected: PASS.

Run: `/home/ubuntu/sdk/flutter/bin/flutter build apk --debug`
Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt android/app/src/main/AndroidManifest.xml android/app/src/main/res/xml/ovid_accessibility_service.xml android/app/src/main/res/values/strings.xml test/core_regression_test.dart
git commit -m "feat: Android accessibility control bridge and cached screen tree"
```

---

### Task 10: Device-control tools, safety gates, disclosure, and screenshot fallback

**Files:**
- Create: `lib/core/device_control_service.dart`
- Modify: `lib/core/state.dart` (denylist and disclosure constants)
- Modify: `lib/core/agent_service.dart` (schemas, dispatch, gates, handlers)
- Modify: `lib/core/commands.dart` and `lib/ui/chat_screen.dart` (control disclosure flow)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes native methods from Task 9 and `AgentMode.control` from Task 8.
- Produces `DeviceControlService.I`, `device_read`, `device_tap`, `device_type`, `device_swipe`, `device_system_nav`, `device_screenshot`.
- All device tools are denied by Read-Only and plan mode, denied unless mode is `control`, denied on sensitive packages/domains, and never available to subagents.

- [ ] **Step 1: Write failing behavioral tests**

```dart
test('CTRL3: all device tools are read-only blocked and require Control mode', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'ctrl3', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'ctrl3');
  });
  for (final tool in [
    'device_read', 'device_tap', 'device_type', 'device_swipe',
    'device_system_nav', 'device_screenshot',
  ]) {
    expect(await AgentService.I.dispatchForTest(tool, {}), contains('READ-ONLY MODE'));
  }
  s.mode = 'auto';
  expect(await AgentService.I.dispatchForTest('device_read', {}), contains('requires Control mode'));
});

test('CTRL4: node rows and deltas format compactly without screenshots', () {
  final full = DeviceControlService.formatReadResultForTest({
    'status': 'ok', 'full': true, 'package': 'com.example',
    'added': [
      {'handle': 12, 'class': 'Button', 'text': 'Send', 'bounds': [880,1520,1010,1600], 'clickable': true},
    ], 'changed': [], 'removed': [],
  });
  expect(full, contains('[12] Button "Send"'));
  expect(full, contains('clickable'));

  final delta = DeviceControlService.formatReadResultForTest({
    'status': 'ok', 'full': false, 'package': 'com.example',
    'added': [{'handle': 22, 'class': 'Toast', 'text': 'Message sent'}],
    'changed': [], 'removed': [12],
  });
  expect(delta, contains('+ [22] Toast "Message sent"'));
  expect(delta, contains('- [12]'));
  expect(DeviceControlService.formatReadResultForTest({'status': 'unchanged'}), 'screen unchanged');
});

test('SAFE1: control blocks sensitive packages/domains and password typing', () {
  expect(DeviceControlService.isSensitiveTargetForTest(packageName: 'com.paypal.android.p2pmobile'), isTrue);
  expect(DeviceControlService.isSensitiveTargetForTest(url: 'https://www.wise.com/send'), isTrue);
  expect(DeviceControlService.isSensitiveTargetForTest(packageName: 'com.example.notes'), isFalse);
  expect(kControlModeDisclosure, contains('Back / Home / Recents'));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL3|CTRL4|SAFE1"`
Expected: compile failures for missing `DeviceControlService` and unknown tools.

- [ ] **Step 3: Implement Dart bridge and compact formatter**

Create `DeviceControlService` with `MethodChannel('ovid/native')` methods matching Task 9. `read(full:false)` invokes `deviceRead` and calls `formatReadResultForTest`; if the result has no meaningful nodes, append exactly:

`Screen exposes no readable structure. Use device_screenshot if the current model supports images.`

The formatter emits full rows with no blank attributes and delta prefixes `+`, `~`, `-`. It never requests a screenshot itself. Screenshot use remains explicit, so repeated actions do not burn image tokens.

Add constants in `state.dart`:

```dart
const kDeniedControlDomains = <String>[
  'paypal.com', 'wise.com', 'chase.com', 'bankofamerica.com',
  'wellsfargo.com', 'citigroup.com', 'capitalone.com',
];
const kDeniedControlPackages = <String>[
  'com.paypal.android.p2pmobile', 'com.transferwise.android',
  'com.chase.sig.android', 'com.infonow.bofa',
  'com.wf.wellsfargomobile', 'com.citi.citimobile',
  'com.konylabs.capitalone',
];
const kControlModeDisclosure =
  'Control mode lets Ovid use your device the way you would. With your permission '
  'it can read what is on screen and tap, type, swipe, and use Back / Home / Recents '
  'in this app and in others. Screen content is sent only to the AI model you chose, '
  'is not stored or shared, and banking/payment screens and password fields are blocked. '
  'You enable this in Settings → Accessibility and can turn it off there at any time.';
```

- [ ] **Step 4: Add schemas, dispatch, and safety gates**

Add all six tool schemas with complete JSON schemas; `device_tap` accepts `node` or `x/y`, `device_type` requires `text` and accepts `node/submit`, `device_swipe` requires four coordinates and optional `duration_ms`, `device_system_nav` requires enum action, `device_read` accepts enum mode `delta|full`, screenshot has no args.

Add all six to `_mutatingTools` and `_readOnlyBlock`. Dispatch before browser cases:

```dart
case 'device_read':
case 'device_tap':
case 'device_type':
case 'device_swipe':
case 'device_system_nav':
case 'device_screenshot':
  if (mode != AgentMode.control) {
    return 'DENIED: Tool "$name" requires Control mode.';
  }
  if (_runSession?.isSubagent == true) {
    return 'DENIED: Subagents cannot control the device.';
  }
  return _handleDeviceControlTool(name, args);
```

Before mutating actions, query current package from `deviceRead` metadata and call `isSensitiveTargetForTest`; for Ovid's package also check `_activeTab.url`. For `device_type`, native Task 9 password refusal is mandatory defense-in-depth. Each successful action calls `_emit('shell', ...)`. `device_screenshot` records the returned PNG with `_recordProduced`, returning its workspace/cache path plus `Read it with read_image before choosing coordinates.`

- [ ] **Step 5: Add disclosure flow**

When `/permission control confirm` or the mode picker selects Control, present a modal using `kControlModeDisclosure` with actions `Not now` and `Enable Control`. `Enable Control` calls `DeviceControlService.I.openAccessibilitySettings()`, then sets the session mode. Do not request or open accessibility settings at app launch. If service remains disabled, keep the selected mode but show an inline notice with a retry button.

- [ ] **Step 6: Run focused and full verification**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL3|CTRL4|SAFE1"`
Expected: PASS.

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/core/device_control_service.dart lib/core/state.dart lib/core/agent_service.dart lib/core/commands.dart lib/ui/chat_screen.dart test/core_regression_test.dart
git commit -m "feat: device-wide control tools with node-tree vision and safety gates"
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
   - W1 (§2): Device-wide Control mode -> Task 8 (`AgentMode.control`, rank 4), Task 9 (native AccessibilityService), Task 10 (six agent tools)
   - W2 (§3): MCP/plugin re-init + tri-state health -> Task 3 (`ServiceHealth` model) & Task 4 (re-init wiring + UI)
   - W3 (§4): Real browser file handling -> Task 5 (uncapped streaming download), Task 6 (uncapped chunked upload), Task 7 (file selector hook + SAF export)
   - W4 (§5): Queue / Stop / Keep-alive semantics -> Task 1 (keep-alive) & Task 2 (smart stop)
   - W5 (§6): Play-safety guardrails -> Task 9 (user-enabled service only) & Task 10 (package/domain denylist, password refusal, disclosure)
   - W6 (§2.3): No repeated screenshots -> Task 9 (dirty flag, stable handles, node deltas) & Task 10 (`device_read` primary; explicit screenshot fallback)
2. **Placeholder scan:** No TBD, no TODO, all exact paths, exact code blocks, exact terminal commands and assertions provided.
3. **Type consistency:** `ServiceHealth { connecting, working, failed }`, `AgentMode.control`, `stopRequested({String? sessionId})`, `downloadStreamHelperForTest`, `DeviceControlService`, and the six `device_*` tools match exactly across all tasks.
