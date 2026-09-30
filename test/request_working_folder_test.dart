import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `request_working_folder` — the structured way for the agent to let the USER
/// choose this chat's working folder.
///
/// The system prompt already tells the model "if the task actually needs a
/// folder, ask the user which one instead of assuming this one", but until now
/// the only way to "ask" was free text, so the answer came back as a path the
/// model had to invent. This tool opens the real picker and pins the result,
/// which also marks the folder user-pinned (so the prompt stops describing it
/// as inherited).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late ChatSession s;
  late Directory real;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    real = Directory.systemTemp.createTempSync('ovid-pick-folder-');
    s = ChatSession(id: 'pick-1', title: 'P', model: 'm', mode: 'auto');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
  });

  tearDown(() {
    AgentService.directoryPickerForTest = null;
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
    if (real.existsSync()) real.deleteSync(recursive: true);
  });

  test('the tool is offered and tells the model not to guess a path', () {
    final tool = AgentService.I.toolsForTest().firstWhere(
      (t) => ((t['function'] as Map)['name']) == 'request_working_folder',
      orElse: () => throw StateError('request_working_folder not in roster'),
    );
    final desc = (tool['function'] as Map)['description'] as String;
    expect(desc, contains('picker'));
    expect(desc, contains('never guess'));
    // The schema compactor truncates long descriptions with an ellipsis, and
    // a truncated instruction is one the model never sees. The load-bearing
    // "never guess a path" text is front-loaded, so pin that it survives.
    expect(desc, isNot(endsWith('…')),
        reason: 'the compactor cut this description — the guidance is lost');
  });

  test('a picked folder is pinned to the RUN session and marked user-chosen',
      () async {
    AgentService.directoryPickerForTest = (title) async => real.path;

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {'reason': 'need the project'},
    );

    expect(out, contains(real.path));
    expect(s.workspaceFolder, real.path);
    expect(s.workspaceFolderPinned, isTrue,
        reason: 'the user chose it, so the prompt must say pinned, not inherited');
  });

  test('the picker reason is passed through as the dialog title', () async {
    String? seenTitle;
    AgentService.directoryPickerForTest = (title) async {
      seenTitle = title;
      return null;
    };

    await AgentService.I.dispatchForTest(
      'request_working_folder',
      {'reason': 'to run the build'},
    );

    expect(seenTitle, contains('to run the build'));
  });

  test('a cancelled picker pins nothing and says so honestly', () async {
    AgentService.directoryPickerForTest = (title) async => null;

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('cancelled'));
    expect(s.workspaceFolder, isNull);
    expect(s.workspaceFolderPinned, isFalse);
  });

  test('a folder that does not exist pins nothing', () async {
    AgentService.directoryPickerForTest =
        (title) async => '${real.path}/definitely-not-here';

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('does not exist'));
    expect(s.workspaceFolder, isNull);
  });

  test('a throwing picker is reported, not swallowed', () async {
    AgentService.directoryPickerForTest =
        (title) async => throw StateError('picker blew up');

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('folder picker failed'));
    expect(s.workspaceFolder, isNull);
  });

  test('Read-Only mode refuses it (it repoints where writes land)', () async {
    s.mode = AgentMode.safe.name;
    AgentService.directoryPickerForTest = (title) async => real.path;

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('READ-ONLY MODE'));
    expect(s.workspaceFolder, isNull);
  });

  test('a subagent cannot repoint the shared folder', () async {
    final child = app.createSubagentSession(
      parent: s,
      label: 'helper',
      mode: 'auto',
    );
    AgentService.setRunSessionForTest(child.id);
    AgentService.directoryPickerForTest = (title) async => real.path;

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('SUBAGENT'));
    expect(s.workspaceFolder, isNull,
        reason: 'a child must never move the parent\'s workspace');
  });

  test('plan mode refuses it (not in the research allowlist)', () async {
    s.planMode = true;
    AgentService.directoryPickerForTest = (title) async => real.path;

    final out = await AgentService.I.dispatchForTest(
      'request_working_folder',
      {},
    );

    expect(out, contains('PLAN MODE'));
    expect(s.workspaceFolder, isNull);
  });
}
