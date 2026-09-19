import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

/// Hot reload: editing a workspace SKILL.md must be picked up on the next
/// skill load, not require a manual Settings refresh or a new session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory work;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('skill-reload-');
    SessionLedger.rootOverrideForTest = tmp;
    SessionSearch.dbPathOverrideForTest = '${tmp.path}/search.db';
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    SkillService.I.invalidateAllSessions();
    work = Directory.systemTemp.createTempSync('ovid-reload-ws-');
  });

  tearDown(() {
    SkillService.I.invalidateAllSessions();
    AgentService.setRunSessionForTest('');
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  test('editing a workspace SKILL.md is picked up on the next load', () async {
    final file = File('${work.path}/agents/tip/SKILL.md');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '---\nname: tip\ndescription: A tip\n---\n\nVERSION ONE\n',
    );

    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['m']
      ..selectedModel = 'm';
    final s = ChatSession(id: 'reload-1', title: 'T', providerId: provider.id, model: 'm')
      ..workspaceFolder = work.path;
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);

    await AgentService.I.refreshSkills(sessionId: s.id);
    final first = await AgentService.I.dispatchForTest('skill', {
      'name': 'tip',
    });
    expect(first, contains('VERSION ONE'));

    // Edit on disk, no manual refresh.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    file.writeAsStringSync(
      '---\nname: tip\ndescription: A tip\n---\n\nVERSION TWO\n',
    );

    final second = await AgentService.I.dispatchForTest('skill', {
      'name': 'tip',
    });
    expect(
      second,
      contains('VERSION TWO'),
      reason: 'an edited SKILL.md must hot-reload',
    );
  });
}
