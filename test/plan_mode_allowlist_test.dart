import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Plan mode must be PLAN-ONLY, DSH-style: explore, read, write the plan, and
/// ask for approval — nothing else.
///
/// SECURITY (2026-09-24): the gate was a BLOCKLIST (`_mutatingTools`), which
/// fails OPEN — anything not listed ran freely while "planning". Two concrete
/// escapes shipped:
///
///   • every non-interaction `browser_*` tool was unlisted, so a planning agent
///     could open tabs, navigate live pages, resize, and **close the user's
///     tabs** — plus unrestricted network egress. With the `javascript:` hole
///     that was script execution during planning.
///   • `interrupt_agent` and `send_message` were unlisted, so a plan-mode agent
///     could stop or steer ANOTHER session — which is not in plan mode — into
///     performing the mutation for it.
///
/// The gate is now an allowlist: unlisted tools, including any tool added in
/// future, are refused by default.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ChatSession s;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    s = ChatSession(id: 'plan-allow', title: 'P', model: 'm', mode: 'auto')
      ..planMode = true;
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
  });

  tearDown(() {
    s.planMode = false;
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Future<String> call(
    String tool, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      return await AgentService.I.dispatchForTest(tool, args);
    } on Object catch (e) {
      // The plan gate LET THE TOOL THROUGH and it then hit an unmocked
      // platform channel (path_provider, webview, …). For this suite that is a
      // pass: the assertion is about the gate, not the tool's own IO.
      return 'TOOL_RAN_PAST_THE_GATE: $e';
    }
  }

  group('plan mode refuses the browser drivers the blocklist missed', () {
    test('navigation and tab lifecycle are refused', () async {
      for (final tool in [
        'browser_open',
        'browser_navigate',
        'browser_new_tab',
        'browser_close_tab',
        'browser_switch_tab',
        'browser_back',
        'browser_forward',
        'browser_reload',
        'browser_resize',
        'browser_scroll',
        'browser_hover',
      ]) {
        expect(
          await call(tool, {'url': 'https://example.com'}),
          contains('PLAN MODE ACTIVE'),
          reason: '$tool must not run while planning',
        );
      }
    });

    test('interaction tools stay refused', () async {
      for (final tool in ['browser_click', 'browser_type', 'browser_evaluate']) {
        expect(
          await call(tool, {'selector': 'a'}),
          contains('PLAN MODE ACTIVE'),
          reason: '$tool must not run while planning',
        );
      }
    });
  });

  group('plan mode cannot act through another session', () {
    test('interrupt_agent and send_message are refused', () async {
      expect(
        await call('interrupt_agent', {'agent_id': 'sub-1'}),
        contains('PLAN MODE ACTIVE'),
      );
      expect(
        await call('send_message', {'agent_id': 'sub-1', 'message': 'rm -rf /'}),
        contains('PLAN MODE ACTIVE'),
      );
      // Spawning is refused too (it was already blocked, but now by the
      // allowlist rather than by being listed).
      expect(
        await call('dispatch_agent', {'prompt': 'do it instead'}),
        contains('PLAN MODE ACTIVE'),
      );
    });
  });

  group('the allowlist fails closed', () {
    test('an unknown or future tool is refused by default', () async {
      expect(
        await call('some_tool_added_next_release', {}),
        contains('PLAN MODE ACTIVE'),
        reason: 'a blocklist would have allowed this',
      );
    });

    test('mutating core tools stay refused', () async {
      expect(
        await call('run_code', {'code': '1+1', 'lang': 'python'}),
        contains('PLAN MODE ACTIVE'),
      );
      expect(
        await call('run_shell', {'command': 'ls'}),
        contains('PLAN MODE ACTIVE'),
      );
      expect(
        await call('file_write', {'path': 'x.txt', 'content': 'x'}),
        contains('PLAN MODE ACTIVE'),
      );
      expect(await call('commit', {'message': 'm'}), contains('PLAN MODE ACTIVE'));
      expect(
        await call('device_tap', {'x': 1, 'y': 1}),
        contains('PLAN MODE ACTIVE'),
      );
    });
  });

  group('planning itself still works', () {
    test('read-only tools are NOT refused by the plan gate', () async {
      // These must not come back with the plan-mode refusal. They may fail for
      // their own reasons (missing file, no such repo) — that is fine; the
      // point is the plan gate let them through.
      for (final tool in [
        'todo_write',
        'git_status',
        'git_log',
        'git_diff',
        'memory_search',
        'session_search',
        'list_agents',
        'job_list',
        'schedule_list',
        'catalog_list_models',
      ]) {
        final out = await call(tool, {'q': 'x', 'query': 'x'});
        expect(
          out,
          isNot(contains('PLAN MODE ACTIVE')),
          reason: '$tool is read-only and must be usable while planning',
        );
      }
    });

    test('todo_write actually records the plan', () async {
      final out = await call('todo_write', {
        'todos': [
          {'content': 'step one', 'status': 'pending', 'priority': 'high'},
        ],
      });
      expect(out, isNot(contains('PLAN MODE ACTIVE')));
    });

    test('file_read and the search tools are allowed through the gate',
        () async {
      for (final tool in ['file_read', 'fs_glob', 'fs_grep']) {
        final out = await call(tool, {'path': 'nope.txt', 'pattern': '*'});
        expect(
          out,
          isNot(contains('PLAN MODE ACTIVE')),
          reason: '$tool is a read and must be usable while planning',
        );
      }
    });
  });

  group('leaving plan mode unlocks execution', () {
    test('the same call is no longer plan-refused once planMode is off',
        () async {
      s.planMode = false;
      final out = await call('run_shell', {'command': 'true'});
      expect(out, isNot(contains('PLAN MODE ACTIVE')));
    });
  });
}
