import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Token-efficiency guard: the per-request tool roster is the dominant fixed
/// cost. This pins (a) that EVERY advertised capability is still present —
/// no feature may silently disappear to save tokens — and (b) the measured
/// schema size so a regression is visible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('token-budget-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  test('the full capability roster is advertised (no feature removed)', () {
    final s = ChatSession(id: 'tok-1', title: 'S', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() => AgentService.setRunSessionForTest(''));

    final names = AgentService.I
        .toolsForTest()
        .map((t) => (t['function'] as Map)['name'] as String)
        .toSet();

    // Every capability family must remain reachable. If a family is renamed
    // or dropped, this fails loudly rather than silently reducing features.
    const required = {
      'run_shell',
      'fs_edit',
      'fs_glob',
      'fs_grep',
      'file_read',
      'file_write',
      'browser_open',
      'browser_navigate',
      'browser_click',
      'browser_type',
      'browser_snapshot',
      'browser_evaluate',
      'web_search',
      'memory_search',
      'memory_save',
      'session_search',
      'commit',
      'repo_sync',
      'repo_tree',
      'job_start',
      'job_kill',
      'schedule_create',
      'todo_write',
      'skill',
      'dispatch_agent',
      'workflow',
      'ralph',
      'catalog_list_providers',
      'catalog_add_mcp',
      'agent_install_plugin',
      'agent_install_mcp',
      'request_permission',
      'ask_user_question',
      'generate_image',
      'read_image',
      'read_attachment',
      'send_message',
      'list_agents',
      'interrupt_agent',
      'preview',
      'create_goal',
      'get_goal',
      'update_goal',
      'exit_plan_mode',
      'report',
    };
    for (final name in required) {
      expect(names, contains(name), reason: '$name must remain advertised');
    }
  });

  test('compactDescription only shortens prose at word boundaries', () {
    expect(AgentService.compactDescription('short text', 160), 'short text');
    final long =
        'First sentence carries the meaning. Second sentence adds detail '
        'that can be trimmed when the payload budget is tight. Third tail.';
    final compacted = AgentService.compactDescription(long, 60);
    expect(compacted.length, lessThanOrEqualTo(61));
    expect(compacted, startsWith('First sentence carries the meaning.'));
    expect(compacted, endsWith('…'));
  });

  test('compacted roster keeps every tool callable contract intact', () {
    final s = ChatSession(id: 'tok-3', title: 'S', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() => AgentService.setRunSessionForTest(''));

    for (final tool in AgentService.I.toolsForTest()) {
      expect(tool['type'], 'function');
      final fn = tool['function'] as Map;
      expect((fn['name'] as String).isNotEmpty, isTrue);
      expect((fn['description'] as String).isNotEmpty, isTrue);
      final params = fn['parameters'] as Map;
      expect(params['type'], 'object');
      // Issue 8: zero-arg tools normalize to {'type':'object'} — empty
      // `properties` is omitted, never sent as {}.
      final props = params['properties'];
      expect(props == null || props is Map, isTrue,
          reason:
              '${fn['name']}: properties must be a Map or omitted when empty');
    }
  });

  test('records the measured tool-schema token cost', () {
    final s = ChatSession(id: 'tok-2', title: 'S', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() => AgentService.setRunSessionForTest(''));

    final tools = AgentService.I.toolsForTest();
    final chars = jsonEncode(tools).length;
    // ~4 chars/token heuristic used by the app's own meter.
    final approxTokens = chars ~/ 4;
    // ignore: avoid_print
    print(
      '[token-budget] tools=${tools.length} '
      'jsonChars=$chars approxTokens=$approxTokens',
    );
    // Regression ceiling: the roster must stay within a mobile-reasonable
    // envelope. Raise deliberately only with a measured justification.
    // Baseline before the schema compactor was ~8597; the compactor must
    // keep it under 8000 while advertising every required tool above.
    //
    // Measured 2026-09-23: 8080 (~+80 over the old ceiling). The growth is
    // intentional — the 6-workstream batch adds the `git_clone` tool
    // (Studio: session/global repo clone + local-folder clone). No schema
    // regression; ceiling raised to 8200 to cover it.
    //
    // Measured 2026-09-23: 8487 (~+407). The growth is intentional — the
    // GitHub-native batch adds `git_push` (declared but never implemented
    // until now), `git_pull`, `git_status`, `git_log`, `git_diff` (Studio:
    // the full git workflow for any cloned repo) plus a `gh` mention in
    // the run_shell description. Schemas kept terse; ceiling raised to
    // 8600 to cover it.
    expect(tools.length, greaterThan(80));
    expect(approxTokens, lessThan(8600));
  });
}
