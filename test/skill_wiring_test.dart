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

/// Wiring for two skill behaviors that were parsed but never consumed:
///   • supporting files bundled with a skill are surfaced to the model when
///     the skill loads (real [CC] skills reference bundled scripts/templates);
///   • a skill's `allowed-tools` restricts the tools usable after it loads.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory work;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('skill-wiring-');
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
    work = Directory.systemTemp.createTempSync('ovid-skill-ws-');
  });

  tearDown(() {
    SkillService.I.invalidateAllSessions();
    AgentService.setRunSessionForTest('');
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final f = File('${work.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  ChatSession session(String id) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['m']
      ..selectedModel = 'm';
    final s = ChatSession(
      id: id,
      title: 'T',
      providerId: provider.id,
      model: 'm',
      mode: 'auto',
    )..workspaceFolder = work.path;
    app.sessions.add(s);
    app.activeSessionId = id;
    return s;
  }

  test('loading a skill surfaces its supporting files', () async {
    write(
      'agents/release/SKILL.md',
      '---\nname: release\ndescription: Cut a release\n---\n\nRun the checklist.\n',
    );
    write('agents/release/scripts/cut.sh', '#!/bin/sh\necho cut\n');
    write('agents/release/templates/notes.md', 'Release notes template.\n');

    final s = session('skill-files');
    AgentService.setRunSessionForTest(s.id);
    await AgentService.I.refreshSkills(sessionId: s.id);

    final res = await AgentService.I.dispatchForTest('skill', {
      'name': 'release',
    });
    expect(res, contains('Run the checklist'));
    expect(res, contains('scripts/cut.sh'));
    expect(res, contains('echo cut'));
    expect(res, contains('Release notes template'));
  });

  test('allowed-tools from a skill restricts later tool use', () async {
    write(
      'agents/locked/SKILL.md',
      '---\nname: locked\ndescription: Read-only helper\n'
          'allowed-tools: Read, Glob\n---\n\nOnly read things.\n',
    );

    final s = session('skill-tools');
    AgentService.setRunSessionForTest(s.id);
    await AgentService.I.refreshSkills(sessionId: s.id);

    final loaded = await AgentService.I.dispatchForTest('skill', {
      'name': 'locked',
    });
    expect(loaded, contains('Only read things'));

    // A tool NOT in allowed-tools is refused with an instructive message.
    final denied = await AgentService.I.dispatchForTest('file_write', {
      'path': 'x.txt',
      'content': 'nope',
    });
    expect(denied.toLowerCase(), contains('allowed'));
    expect(denied, contains('file_write'));

    // The Skill tool itself stays available so the model can switch.
    final again = await AgentService.I.dispatchForTest('skill', {
      'name': 'locked',
    });
    expect(again, contains('Only read things'));
  });

  test('a skill without allowed-tools does not restrict tools', () async {
    write(
      'agents/open/SKILL.md',
      '---\nname: open\ndescription: Free helper\n---\n\nDo anything.\n',
    );
    final s = session('skill-open');
    AgentService.setRunSessionForTest(s.id);
    await AgentService.I.refreshSkills(sessionId: s.id);

    await AgentService.I.dispatchForTest('skill', {'name': 'open'});
    // todo_write is not a write tool; it must still work.
    final res = await AgentService.I.dispatchForTest('todo_write', {
      'todos': [
        {'content': 'a', 'status': 'pending'},
      ],
    });
    expect(res.toLowerCase(), isNot(contains('allowed-tools')));
  });
}
