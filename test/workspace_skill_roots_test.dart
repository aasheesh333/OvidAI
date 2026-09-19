import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

/// A project checked out into a session workspace can carry its own
/// `.claude/` and `.codex/` skills/commands/agents — the same project-local
/// convention the real [CC] and Codex harnesses use. Discovery must find them
/// and expose them to the agent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory work;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.sessions.clear();
    app.activeSessionId = null;
    SkillService.I.invalidateAllSessions();
    work = Directory.systemTemp.createTempSync('ovid-ws-');
  });

  tearDown(() {
    SkillService.I.invalidateAllSessions();
    AppState.resetTestInstance();
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  void write(String rel, String content) {
    final f = File('${work.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  Future<List<Skill>> discoverFor(String id) async {
    final app = AppState.I;
    final s = ChatSession(id: id, title: 'T', model: 'm')
      ..workspaceFolder = work.path;
    app.sessions.add(s);
    app.activeSessionId = id;
    await AgentService.I.refreshSkills(sessionId: id);
    return SkillService.I.skillsForSession(id);
  }

  test('discovers .claude/skills', () async {
    write(
      '.claude/skills/release/SKILL.md',
      '---\nname: release\ndescription: Cut a release\n---\n\nSteps.\n',
    );
    final skills = await discoverFor('ws-claude');
    expect(skills.map((s) => s.name), contains('release'));
  });

  test('discovers .claude/commands', () async {
    write(
      '.claude/commands/deploy.md',
      '---\nname: deploy\ndescription: Deploy it\n---\n\nRun deploy.\n',
    );
    final skills = await discoverFor('ws-cmd');
    expect(skills.map((s) => s.name), contains('deploy'));
  });

  test('discovers .codex/skills', () async {
    write(
      '.codex/skills/audit/SKILL.md',
      '---\nname: audit\ndescription: Security audit\n---\n\nAudit.\n',
    );
    final skills = await discoverFor('ws-codex');
    expect(skills.map((s) => s.name), contains('audit'));
  });

  test('discovers .claude/agents as agents', () async {
    write(
      '.claude/agents/reviewer.md',
      '---\nname: reviewer\ndescription: Reviews code\n---\n\nReview.\n',
    );
    final skills = await discoverFor('ws-agent');
    final reviewer = skills.where((s) => s.name == 'reviewer');
    expect(reviewer, isNotEmpty);
    expect(reviewer.first.isAgent, isTrue);
  });

  test('still discovers .agents/skills', () async {
    write(
      '.agents/skills/legacy/SKILL.md',
      '---\nname: legacy\ndescription: Old layout\n---\n\nOld.\n',
    );
    final skills = await discoverFor('ws-agents');
    expect(skills.map((s) => s.name), contains('legacy'));
  });
}
