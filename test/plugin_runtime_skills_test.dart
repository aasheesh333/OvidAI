import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ovid-runtime-skills-');
    SkillService.I.invalidateAllSessions();
    AgentService.skillCatalogInputsForTest = null;
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AgentService.skillCatalogInputsForTest = null;
    SkillService.I.invalidateAllSessions();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File write(String relative, String body) {
    final file = File('${root.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    return file;
  }

  test(
    'manifest mount exposes only declared kind-correct contributions',
    () async {
      write(
        'skills/research/SKILL.md',
        '---\nname: research\nuser-invocable: true\n---\nRESEARCH',
      );
      write('skills/research/reference.txt', 'REFERENCE');
      write('commands/research.md', '---\nname: research\n---\nCOMMAND');
      write('agents/research.md', '---\nname: research\n---\nAGENT');
      write('README.md', 'UNDECLARED');
      write('skills/hidden/SKILL.md', '---\nname: hidden\n---\nHIDDEN');
      final manifest = NormalizedPluginManifest(
        id: 'acme/research-kit',
        name: 'Research Kit',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: root.path,
        commands: const [
          PluginCommand(
            pluginId: 'acme/research-kit',
            name: 'research',
            path: 'commands/research.md',
          ),
        ],
        skills: const [
          PluginSkill(
            pluginId: 'acme/research-kit',
            name: 'research',
            path: 'skills/research/SKILL.md',
            supportingFiles: ['skills/research/reference.txt'],
          ),
        ],
        agents: const [
          PluginAgent(
            pluginId: 'acme/research-kit',
            name: 'research',
            path: 'agents/research.md',
          ),
        ],
      );
      final service = SkillService.forTest();

      await service.publishSessionCatalog(
        'A',
        mounts: [PluginCatalogMount(root.path, manifest)],
      );

      final snapshot = service.snapshotForSession('A');
      expect(snapshot.skills.map((entry) => entry.canonicalId), [
        'plugin:acme/research-kit/agent:research',
        'plugin:acme/research-kit/command:research',
        'plugin:acme/research-kit/skill:research',
      ]);
      expect(snapshot.skills.where((entry) => entry.name == 'hidden'), isEmpty);
      expect(
        snapshot
            .resolveAlias('plugin:acme/research-kit/skill:research')
            .unique
            ?.supportingFiles,
        ['reference.txt'],
      );
      expect(
        snapshot.skills.where((entry) => entry.path.endsWith('README.md')),
        isEmpty,
      );
      expect(
        snapshot
            .resolveAlias('plugin:acme/research-kit/command:research')
            .unique
            ?.kind,
        SkillContributionKind.command,
      );
      expect(
        snapshot
            .resolveAlias('plugin:acme/research-kit/skill:research')
            .unique
            ?.kind,
        SkillContributionKind.skill,
      );
      expect(
        snapshot
            .resolveAlias('plugin:acme/research-kit/agent:research')
            .unique
            ?.kind,
        SkillContributionKind.agent,
      );
      expect(snapshot.resolveAlias('research').options, [
        'plugin:acme/research-kit/agent:research',
        'plugin:acme/research-kit/command:research',
        'plugin:acme/research-kit/skill:research',
      ]);
    },
  );

  test(
    'same-session stale completion cannot overwrite a newer catalog',
    () async {
      final oldRoot = Directory('${root.path}/old')
        ..createSync(recursive: true);
      final newRoot = Directory('${root.path}/new')
        ..createSync(recursive: true);
      File('${oldRoot.path}/commands/old.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('OLD');
      File('${newRoot.path}/commands/new.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('NEW');
      NormalizedPluginManifest manifest(
        String id,
        String name,
        Directory dir,
      ) => NormalizedPluginManifest(
        id: id,
        name: name,
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: dir.path,
        commands: [
          PluginCommand(pluginId: id, name: name, path: 'commands/$name.md'),
        ],
      );
      final service = SkillService.forTest();
      final oldGate = Completer<void>();
      final oldPublish = service.publishSessionCatalog(
        'A',
        mounts: [
          PluginCatalogMount(
            oldRoot.path,
            manifest('acme/old', 'old', oldRoot),
          ),
        ],
        beforeScan: () => oldGate.future,
      );
      await Future<void>.delayed(Duration.zero);

      await service.publishSessionCatalog(
        'A',
        mounts: [
          PluginCatalogMount(
            newRoot.path,
            manifest('acme/new', 'new', newRoot),
          ),
        ],
      );
      oldGate.complete();
      await oldPublish;

      expect(service.resolveForSession('A', 'new').isUnique, isTrue);
      expect(service.resolveForSession('A', 'old').isAbsent, isTrue);
    },
  );

  test(
    'different sessions publish independently and invalidation blocks republish',
    () async {
      final aRoot = Directory('${root.path}/a')..createSync(recursive: true);
      final bRoot = Directory('${root.path}/b')..createSync(recursive: true);
      File('${aRoot.path}/commands/a.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('A');
      File('${bRoot.path}/commands/b.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('B');
      NormalizedPluginManifest manifest(
        String id,
        String name,
        Directory dir,
      ) => NormalizedPluginManifest(
        id: id,
        name: name,
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: dir.path,
        commands: [
          PluginCommand(pluginId: id, name: name, path: 'commands/$name.md'),
        ],
      );
      final service = SkillService.forTest();
      final gate = Completer<void>();
      final pendingA = service.publishSessionCatalog(
        'A',
        mounts: [
          PluginCatalogMount(aRoot.path, manifest('acme/a', 'a', aRoot)),
        ],
        beforeScan: () => gate.future,
      );
      await service.publishSessionCatalog(
        'B',
        mounts: [
          PluginCatalogMount(bRoot.path, manifest('acme/b', 'b', bRoot)),
        ],
      );
      service.dropSession('A');
      gate.complete();
      await pendingA;

      expect(service.skillsForSession('A'), isEmpty);
      expect(service.resolveForSession('B', 'b').isUnique, isTrue);
    },
  );

  test(
    'production refresh reserves generation before asynchronous input collection',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      final session = ChatSession(id: 'generation-A', title: 'A', model: 'm');
      app.sessions.add(session);
      final oldRoot = Directory('${root.path}/old-input')
        ..createSync(recursive: true);
      final newRoot = Directory('${root.path}/new-input')
        ..createSync(recursive: true);
      File('${oldRoot.path}/old.md').writeAsStringSync('OLD');
      File('${newRoot.path}/new.md').writeAsStringSync('NEW');
      final oldInputs = SkillCatalogInputs(roots: [oldRoot.path]);
      final newInputs = SkillCatalogInputs(roots: [newRoot.path]);
      final oldGate = Completer<SkillCatalogInputs>();
      var collections = 0;
      AgentService.skillCatalogInputsForTest = (_) {
        collections++;
        return collections == 1 ? oldGate.future : Future.value(newInputs);
      };
      addTearDown(AppState.resetTestInstance);

      final oldRefresh = AgentService.I.refreshSkills(sessionId: session.id);
      await Future<void>.delayed(Duration.zero);
      SkillService.I.invalidateSession(session.id);
      await AgentService.I.refreshSkills(sessionId: session.id);
      oldGate.complete(oldInputs);
      await oldRefresh;

      expect(
        SkillService.I.resolveForSession(session.id, 'new').isUnique,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(session.id, 'old').isAbsent,
        isTrue,
      );
    },
  );

  test('hostile and malformed declarations are excluded atomically', () async {
    final outside = File('${root.parent.path}/outside-${root.path.hashCode}.md')
      ..writeAsStringSync('OUTSIDE');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });
    write('skills/good/SKILL.md', 'GOOD');
    write('skills/wrong.md', 'WRONG KIND');
    write('agents/link.md', 'TARGET');
    final link = Link('${root.path}/commands/link.md');
    link.parent.createSync(recursive: true);
    link.createSync('${root.path}/agents/link.md');
    final supportLink = Link('${root.path}/skills/good/outside.txt')
      ..createSync(outside.path);
    expect(supportLink.existsSync(), isTrue);
    final manifest = NormalizedPluginManifest(
      id: 'acme/hostile',
      name: 'Hostile',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: root.path,
      commands: [
        PluginCommand(
          pluginId: 'acme/hostile',
          name: 'escape',
          path: '../${outside.path.split('/').last}',
        ),
        const PluginCommand(
          pluginId: 'acme/hostile',
          name: 'absolute',
          path: '/tmp/absolute.md',
        ),
        const PluginCommand(
          pluginId: 'acme/hostile',
          name: 'linked',
          path: 'commands/link.md',
        ),
        const PluginCommand(
          pluginId: 'other/owner',
          name: 'wrong-owner',
          path: 'skills/wrong.md',
        ),
        const PluginCommand(
          pluginId: 'acme/hostile',
          name: 'missing',
          path: 'commands/missing.md',
        ),
        const PluginCommand(
          pluginId: 'acme/hostile',
          name: 'wrong-kind',
          path: 'skills/good/SKILL.md',
        ),
      ],
      skills: const [
        PluginSkill(
          pluginId: 'acme/hostile',
          name: 'wrong-file',
          path: 'skills/wrong.md',
        ),
        PluginSkill(
          pluginId: 'acme/hostile',
          name: 'bad-support',
          path: 'skills/good/SKILL.md',
          supportingFiles: ['skills/good/outside.txt'],
        ),
      ],
    );
    final service = SkillService.forTest();

    await service.publishSessionCatalog(
      'A',
      mounts: [PluginCatalogMount(root.path, manifest)],
    );

    expect(service.skillsForSession('A'), isEmpty);
  });

  test('duplicate canonical ids reject the candidate snapshot', () async {
    write('commands/one.md', 'ONE');
    write('commands/two.md', 'TWO');
    final manifest = NormalizedPluginManifest(
      id: 'acme/duplicate',
      name: 'Duplicate',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: root.path,
      commands: const [
        PluginCommand(
          pluginId: 'acme/duplicate',
          name: 'same',
          path: 'commands/one.md',
        ),
        PluginCommand(
          pluginId: 'acme/duplicate',
          name: 'same',
          path: 'commands/two.md',
        ),
      ],
    );
    final service = SkillService.forTest();

    await expectLater(
      service.publishSessionCatalog(
        'A',
        mounts: [PluginCatalogMount(root.path, manifest)],
      ),
      throwsStateError,
    );
    expect(service.skillsForSession('A'), isEmpty);
  });

  test('published skills deeply copy mutable collections', () {
    final tools = <String>['read'];
    final frontmatter = <String, String>{'description': 'original'};
    final supporting = <String>['reference.md'];

    final skill = Skill(
      name: 'immutable',
      description: '',
      whenToUse: '',
      content: 'body',
      path: '/tmp/immutable.md',
      modelInvocable: true,
      userInvocable: true,
      allowedTools: tools,
      frontmatter: frontmatter,
      supportingFiles: supporting,
    );
    tools.add('write');
    frontmatter['description'] = 'mutated';
    supporting.add('outside.md');

    expect(skill.allowedTools, ['read']);
    expect(skill.frontmatter, {'description': 'original'});
    expect(skill.supportingFiles, ['reference.md']);
    expect(() => skill.allowedTools.add('shell'), throwsUnsupportedError);
    expect(
      () => skill.frontmatter['description'] = 'changed',
      throwsUnsupportedError,
    );
    expect(() => skill.supportingFiles.add('other.md'), throwsUnsupportedError);
  });

  test('canonical slash tokens preserve plugin punctuation and arguments', () {
    expect(
      parseSkillInvocation(
        '/plugin:acme-co/research-kit/skill:deep-review now',
      ),
      (token: 'plugin:acme-co/research-kit/skill:deep-review', args: 'now'),
    );
  });

  test(
    'startup mounts skills between plugin activation and session restore',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);

      final ids = (await app.buildReadinessTasks())
          .map((task) => task.id)
          .toList();

      expect(ids.indexOf('skill.mount'), ids.indexOf('plugin.activate') + 1);
      expect(
        ids.indexOf('skill.mount'),
        lessThan(ids.indexOf('session.restore')),
      );
    },
  );

  test(
    'explicit unknown session publishes no workspace or plugin fallback',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.sessions.add(ChatSession(id: 'known', title: 'Known', model: 'm'));
      addTearDown(() {
        SkillService.I.dropSession('unknown');
        AppState.resetTestInstance();
      });

      await AgentService.I.refreshSkills(sessionId: 'unknown');

      expect(SkillService.I.skillsForSession('unknown'), isEmpty);
    },
  );

  test(
    'ambiguous plugin alias lists exact options and executes nothing',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      final session = ChatSession(id: 'ambiguous-A', title: 'A', model: 'm');
      app.sessions.add(session);
      final first = Directory('${root.path}/first')
        ..createSync(recursive: true);
      final second = Directory('${root.path}/second')
        ..createSync(recursive: true);
      File('${first.path}/skills/review/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('FIRST MUST NOT EXECUTE');
      File('${second.path}/skills/review/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('SECOND MUST NOT EXECUTE');
      NormalizedPluginManifest manifest(String id, Directory dir) =>
          NormalizedPluginManifest(
            id: id,
            name: id,
            version: '1.0.0',
            format: PluginFormat.claudeCode,
            rootPath: dir.path,
            skills: [
              PluginSkill(
                pluginId: id,
                name: 'review',
                path: 'skills/review/SKILL.md',
              ),
            ],
          );
      final alpha = manifest('alpha/reviewer', first);
      final beta = manifest('beta/reviewer', second);
      PluginContributionRegistry.I.register(
        alpha,
        activation: PluginActivation.globalActive,
      );
      PluginContributionRegistry.I.register(
        beta,
        activation: PluginActivation.globalActive,
      );
      AgentService.setRunSessionForTest(session.id);
      addTearDown(() {
        AgentService.setRunSessionForTest('');
        PluginContributionRegistry.I.unregisterPlugin(alpha.id);
        PluginContributionRegistry.I.unregisterPlugin(beta.id);
        SkillService.I.dropSession(session.id);
        AppState.resetTestInstance();
      });
      await SkillService.I.publishSessionCatalog(
        session.id,
        mounts: [
          PluginCatalogMount(first.path, alpha),
          PluginCatalogMount(second.path, beta),
        ],
      );

      final result = await AgentService.I.dispatchForTest('skill', {
        'name': 'review',
      });

      expect(result, contains('plugin:alpha/reviewer/skill:review'));
      expect(result, contains('plugin:beta/reviewer/skill:review'));
      expect(result, contains('Nothing was loaded'));
      expect(result, isNot(contains('MUST NOT EXECUTE')));
    },
  );

  test(
    'removed contribution cannot invoke from a stale same-id snapshot',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      final session = ChatSession(id: 'upgrade-A', title: 'A', model: 'm');
      app.sessions.add(session);
      final oldFile = File('${root.path}/skills/old/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('REMOVED CONTENT MUST NOT EXECUTE');
      expect(oldFile.existsSync(), isTrue);
      final oldManifest = NormalizedPluginManifest(
        id: 'acme/upgrade',
        name: 'Upgrade',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: root.path,
        skills: const [
          PluginSkill(
            pluginId: 'acme/upgrade',
            name: 'old',
            path: 'skills/old/SKILL.md',
          ),
        ],
      );
      final newManifest = NormalizedPluginManifest(
        id: 'acme/upgrade',
        name: 'Upgrade',
        version: '2.0.0',
        format: PluginFormat.claudeCode,
        rootPath: root.path,
      );
      PluginContributionRegistry.I.register(
        oldManifest,
        activation: PluginActivation.globalActive,
      );
      AgentService.setRunSessionForTest(session.id);
      addTearDown(() {
        PluginContributionRegistry.I.unregisterPlugin(oldManifest.id);
        AppState.resetTestInstance();
      });
      await SkillService.I.publishSessionCatalog(
        session.id,
        mounts: [PluginCatalogMount(root.path, oldManifest)],
      );
      PluginContributionRegistry.I.register(
        newManifest,
        activation: PluginActivation.globalActive,
      );

      final result = await AgentService.I.dispatchForTest('skill', {
        'name': 'plugin:acme/upgrade/skill:old',
      });

      expect(result, contains('not active'));
      expect(result, isNot(contains('REMOVED CONTENT MUST NOT EXECUTE')));
    },
  );

  test(
    'registered generic plugin tool never executes an unrelated skill',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      final session = ChatSession(id: 'generic-A', title: 'A', model: 'm');
      app.sessions.add(session);
      app.activeSessionId = session.id;
      final workspace = Directory('${root.path}/workspace')
        ..createSync(recursive: true);
      File('${workspace.path}/foreign.md').writeAsStringSync(
        '---\nname: foreign\n---\nFOREIGN CONTENT MUST NOT EXECUTE',
      );
      final manifest = NormalizedPluginManifest(
        id: 'acme/runtime-plugin',
        name: 'Runtime Plugin',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: root.path,
        commands: const [
          PluginCommand(
            pluginId: 'acme/runtime-plugin',
            name: 'owned',
            path: 'commands/owned.md',
          ),
        ],
      );
      File('${root.path}/commands/owned.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('OWNED');
      final row = PluginItem(
        name: 'Runtime Plugin',
        author: 'acme',
        description: '',
        version: '1.0.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: manifest.id,
        activation: PluginActivation.globalActive,
      );
      app.plugins.add(row);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      AgentService.setRunSessionForTest(session.id);
      addTearDown(() {
        PluginContributionRegistry.I.unregisterPlugin(manifest.id);
        AppState.resetTestInstance();
      });
      await SkillService.I.publishSessionCatalog(
        session.id,
        roots: [workspace.path],
        mounts: [PluginCatalogMount(root.path, manifest)],
      );

      final result = await AgentService.I.dispatchForTest(
        'plugin_runtime_plugin',
        {'action': 'foreign'},
      );

      expect(result, contains('plugin:acme/runtime-plugin/command:owned'));
      expect(result, contains('Nothing was executed'));
      expect(result, isNot(contains('FOREIGN CONTENT MUST NOT EXECUTE')));
    },
  );

  test(
    'changed same-canonical contribution cannot execute stale content',
    () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      final session = ChatSession(id: 'replace-A', title: 'A', model: 'm');
      app.sessions.add(session);
      File('${root.path}/commands/old.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('OLD CONTENT MUST NOT EXECUTE');
      File('${root.path}/commands/new.md').writeAsStringSync('NEW CONTENT');
      NormalizedPluginManifest manifest(String path) =>
          NormalizedPluginManifest(
            id: 'acme/replace',
            name: 'Replace',
            version: '1.0.0',
            format: PluginFormat.claudeCode,
            rootPath: root.path,
            commands: [
              PluginCommand(
                pluginId: 'acme/replace',
                name: 'review',
                path: path,
              ),
            ],
          );
      final oldManifest = manifest('commands/old.md');
      final newManifest = manifest('commands/new.md');
      PluginContributionRegistry.I.register(
        oldManifest,
        activation: PluginActivation.globalActive,
      );
      AgentService.setRunSessionForTest(session.id);
      addTearDown(() {
        PluginContributionRegistry.I.unregisterPlugin(oldManifest.id);
        AppState.resetTestInstance();
      });
      await SkillService.I.publishSessionCatalog(
        session.id,
        mounts: [PluginCatalogMount(root.path, oldManifest)],
      );
      PluginContributionRegistry.I.register(
        newManifest,
        activation: PluginActivation.globalActive,
      );
      final current = PluginContributionRegistry.I.contributionByCanonicalId(
        'plugin:acme/replace/command:review',
      )!;

      final result = await AgentService.I.dispatchForTest(current.toolName, {});

      expect(result, contains('not mounted'));
      expect(result, isNot(contains('OLD CONTENT MUST NOT EXECUTE')));
    },
  );

  testWidgets('composer hides runtime plugins outside the rendered session', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    final a = ChatSession(id: 'composer-A', title: 'A', model: 'm');
    final b = ChatSession(id: 'composer-B', title: 'B', model: 'm');
    app.sessions.addAll([a, b]);
    app.activeSessionId = b.id;
    final manifest = NormalizedPluginManifest(
      id: 'acme/scoped-composer',
      name: 'Scoped Composer Plugin',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: root.path,
    );
    app.plugins.add(
      PluginItem(
        name: 'Scoped Composer Plugin',
        author: 'acme',
        description: '',
        version: '1.0.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: manifest.id,
        activation: PluginActivation.sessionActive,
        immediateSessionId: a.id,
      ),
    );
    PluginContributionRegistry.I.register(
      manifest,
      activation: PluginActivation.sessionActive,
      immediateSessionId: a.id,
    );
    AgentService.I.debugPauseScheduleTimerForTest(true);
    addTearDown(() {
      AgentService.I.debugPauseScheduleTimerForTest(false);
      PluginContributionRegistry.I.unregisterPlugin(manifest.id);
      AppState.resetTestInstance();
    });

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '/Scoped');
    await tester.pump();

    expect(find.text('Scoped Composer Plugin'), findsNothing);
  });

  test('stale legacy cache cannot expose a pending runtime skill', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    final cache = Directory.systemTemp.createTempSync('ovid-legacy-skill-');
    AppState.pluginCacheRootOverrideForTest = cache;
    final app = AppState.createForTest();
    final session = ChatSession(id: 'legacy-A', title: 'A', model: 'm');
    app.sessions.add(session);
    final row = PluginItem(
      name: 'Legacy',
      author: 'old',
      description: '',
      version: '1',
      category: 'Tool',
      installed: true,
      enabled: true,
      source: 'old/legacy',
      runtimeId: 'old/legacy',
      activation: PluginActivation.pendingGlobal,
    );
    app.plugins.add(row);
    final legacyDir = await app.pluginCacheDirFor(row.source!);
    File('${legacyDir.path}/skills/stale/SKILL.md')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('---\nname: stale\n---\nSTALE');
    addTearDown(() {
      SkillService.I.invalidateAllSessions();
      SkillService.I.clearRoots();
      AppState.pluginCacheRootOverrideForTest = null;
      AppState.resetTestInstance();
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });

    await AgentService.I.refreshSkills(sessionId: session.id);

    expect(
      SkillService.I.resolveForSession(session.id, 'stale').isAbsent,
      isTrue,
    );
  });

  test(
    'agent install mounts only its session and one boot promotes it globally',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      final staging = Directory.systemTemp.createTempSync('ovid-skill-stage-');
      final runtime = Directory.systemTemp.createTempSync(
        'ovid-skill-runtime-',
      );
      final source = Directory.systemTemp.createTempSync('ovid-skill-source-');
      PluginRuntimeManager.stagingRootOverrideForTest = staging;
      PluginRuntimeManager.runtimeRootOverrideForTest = runtime;
      addTearDown(() async {
        AgentService.setRunSessionForTest('');
        PluginContributionRegistry.I.unregisterPlugin('acme/research-kit');
        SkillService.I.invalidateAllSessions();
        SkillService.I.clearRoots();
        PluginRuntimeManager.stagingRootOverrideForTest = null;
        PluginRuntimeManager.runtimeRootOverrideForTest = null;
        AppState.resetTestInstance();
        for (final dir in [staging, runtime, source]) {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }
      });
      writeFixture(source);
      final app = AppState.createForTest();
      final aWork = Directory('${root.path}/a-work')
        ..createSync(recursive: true);
      final bWork = Directory('${root.path}/b-work')
        ..createSync(recursive: true);
      File('${aWork.path}/.dsh/skills/a-user/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('---\nname: a-user\n---\nA USER');
      File('${bWork.path}/.dsh/skills/b-user/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('---\nname: b-user\n---\nB USER');
      final a = ChatSession(
        id: 'A',
        title: 'A',
        model: 'm',
        workspaceFolder: aWork.path,
      );
      final b = ChatSession(
        id: 'B',
        title: 'B',
        model: 'm',
        workspaceFolder: bWork.path,
      );
      app.sessions.addAll([a, b]);
      app.activeSessionId = b.id;
      await AgentService.I.refreshSkills(sessionId: a.id);
      await AgentService.I.refreshSkills(sessionId: b.id);
      final row = PluginItem(
        name: 'Research Kit',
        author: 'acme',
        description: '',
        version: '1.0.0',
        category: 'Tool',
      );
      app.plugins.add(row);
      final inspection = await PluginRuntimeManager.I.inspect(
        LocalFolderPluginSource(source.path),
      );
      await AppState.pluginPermissions.save(
        PluginPermissionGrant(
          pluginId: inspection.manifest.id,
          manifestDigest: inspection.manifestDigest,
          capabilities: inspection.manifest.requestedCapabilities,
          approvedAt: DateTime.utc(2026, 9, 10),
        ),
      );
      final result = await app.installPlugin(
        row,
        inspection: inspection,
        origin: PluginInstallOrigin.agent,
        sessionId: a.id,
      );
      expect(result?.status, PluginInstallStatus.ok);

      expect(
        SkillService.I
            .resolveForSession(a.id, 'plugin:acme/research-kit/skill:research')
            .unique
            ?.content,
        'RESEARCH BODY',
      );
      expect(
        SkillService.I.resolveForSession(a.id, 'research').isUnique,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(b.id, 'research').isAbsent,
        isTrue,
      );
      expect(SkillService.I.resolveForSession(a.id, 'a-user').isUnique, isTrue);
      expect(SkillService.I.resolveForSession(b.id, 'b-user').isUnique, isTrue);

      await PluginRuntimeManager.I.activateForBoot(
        bootToken: Object(),
        connectMcp: false,
        reportFailure: true,
      );
      await AgentService.I.refreshSkills(sessionId: b.id);

      expect(
        SkillService.I.resolveForSession(b.id, 'research').isUnique,
        isTrue,
      );

      SkillService.I.invalidateAllSessions();
      await app.retryPlugin(row);
      expect(SkillService.I.resolveForSession(a.id, 'a-user').isUnique, isTrue);
      expect(SkillService.I.resolveForSession(b.id, 'b-user').isUnique, isTrue);
      expect(
        SkillService.I.resolveForSession(a.id, 'research').isUnique,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(b.id, 'research').isUnique,
        isTrue,
      );

      await app.disablePlugin(row);
      expect(
        SkillService.I.resolveForSession(a.id, 'research').isAbsent,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(b.id, 'research').isAbsent,
        isTrue,
      );

      await app.enablePlugin(row);
      expect(
        SkillService.I.resolveForSession(a.id, 'research').isUnique,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(b.id, 'research').isUnique,
        isTrue,
      );

      await app.uninstallPlugin(row);
      expect(
        SkillService.I.resolveForSession(a.id, 'research').isAbsent,
        isTrue,
      );
      expect(
        SkillService.I.resolveForSession(b.id, 'research').isAbsent,
        isTrue,
      );
    },
  );

  test(
    'legacy lifecycle rebuild keeps the compatibility catalog dispatchable',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      final cacheRoot = Directory.systemTemp.createTempSync(
        'ovid-legacy-compat-',
      );
      AppState.pluginCacheRootOverrideForTest = cacheRoot;
      final app = AppState.createForTest();
      addTearDown(() {
        AppState.pluginCacheRootOverrideForTest = null;
        AppState.resetTestInstance();
        if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
      });
      await app.initialize();
      AgentService.I;
      SkillService.I.clearRoots();

      final row = PluginItem(
        name: 'Legacy Compat Tools',
        author: 'old',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        source: 'old/legacy-compat',
      );
      app.plugins.add(row);
      addTearDown(() {
        app.plugins.remove(row);
        SkillService.I.clearRoots();
      });
      final dir = await app.pluginCacheDirFor(row.source!);
      File('${dir.path}/skills/legacy-skill/SKILL.md')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('---\nname: legacy-skill\n---\nLEGACY SKILL BODY');

      // A legacy lifecycle change must rebuild the global compatibility
      // catalog, not only the per-session runtime snapshots.
      await app.disablePlugin(row);
      await app.enablePlugin(row);

      expect(
        SkillService.I.resolveAlias('legacy-skill').isUnique,
        isTrue,
        reason: 'the legacy lifecycle rebuild repopulates the global catalog',
      );
      final dispatched = await AgentService.I.dispatchForTest(
        'plugin_legacy_compat_tools',
        {'action': 'legacy-skill'},
      );
      expect(dispatched, contains('LEGACY SKILL BODY'));

      await app.disablePlugin(row);
      expect(
        SkillService.I.resolveAlias('legacy-skill').isAbsent,
        isTrue,
        reason: 'disabling the legacy plugin removes its cached skill',
      );
    },
  );
}

void writeFixture(Directory source) {
  File('${source.path}/.claude-plugin/plugin.json')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '{"name":"Research Kit","author":"acme","version":"1.0.0"}',
    );
  File('${source.path}/skills/research/SKILL.md')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '---\nname: research\nuser-invocable: true\n---\nRESEARCH BODY',
    );
}
