import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;
  final agent = AgentService.I;
  late ChatSession a, b, child;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('memory-agent-');
    app = AppState.createForTest(memoryStore: MemoryStore(dir));
    SessionLedger.rootOverrideForTest = Directory('${dir.path}/ledger')
      ..createSync();
    a = ChatSession(id: 'a', title: 'A', model: 'test');
    b = ChatSession(id: 'b', title: 'B', model: 'test');
    child = ChatSession(
      id: 'child',
      title: 'Child',
      model: 'test',
      parentId: 'a',
      agentId: 'sub-1',
      agentContinuable: true,
      agentState: 'finished',
    );
    app.sessions
      ..clear()
      ..addAll([a, b, child]);
    app.activeSessionId = b.id;
    AgentService.setRunSessionForTest(a.id);
    await app.prepareMemory();
  });
  tearDown(() async {
    await app.persistSessions();
    AgentService.setRunSessionForTest('');
    agent.clearRunCtxForTest();
    AgentService.llmOnceForTest = null;
    for (final id in ['a', 'b', 'child']) {
      await SessionLedger.I.close(id);
    }
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    dir.deleteSync(recursive: true);
  });

  test(
    'tools route session scope to owning lineage, not active chat or supplied IDs',
    () async {
      expect(
        await agent.dispatchForTest('memory_save', {
          'scope': 'global',
          'content': 'Personal preference',
        }),
        contains('saved'),
      );
      expect(
        await agent.dispatchForTest('memory_save', {
          'scope': 'session',
          'content': 'Project secret',
        }),
        contains('saved'),
      );
      final initial = agent.buildRequestMessages(a, 'SYSTEM');
      final memory = initial
          .where((m) => '${m['content']}'.contains('Project secret'))
          .single;
      expect(memory['role'], 'user');
      expect(initial.first, {'role': 'system', 'content': 'SYSTEM'});
      expect(
        agent.buildRequestMessages(b, 'SYSTEM').toString(),
        isNot(contains('Project secret')),
      );
      expect(
        agent.buildRequestMessages(child, 'SYSTEM').toString(),
        contains('Project secret'),
      );
      AgentService.setRunSessionForTest(child.id);
      final read =
          jsonDecode(
                await agent.dispatchForTest('memory_read', {
                  'scope': 'session',
                }),
              )
              as Map;
      expect(read['content'], 'Project secret');
      expect(
        await agent.dispatchForTest('memory_save', {
          'scope': 'session',
          'content': 'Child update',
          'mode': 'replace',
          'revision': read['revision'],
        }),
        contains('saved'),
      );
      expect(
        agent.buildRequestMessages(a, 'SYSTEM').toString(),
        contains('Child update'),
      );
      AgentService.setRunSessionForTest(b.id);
      app.shareSessionMemory = true;
      expect(
        await agent.dispatchForTest('memory_read', {
          'scope': 'session',
          'session_id': 'a',
        }),
        contains('error'),
      );
      expect(
        await agent.dispatchForTest('memory_read', {'scope': 'session'}),
        isNot(contains('Child update')),
      );
      expect(
        await agent.dispatchForTest('memory_save', {'content': 'Ambiguous'}),
        contains('error'),
      );
      expect(
        await agent.dispatchForTest('memory_read', {'scope': '../global'}),
        contains('error'),
      );
    },
  );

  test(
    'memory toggle gates context and tools; deletion cleans root and children',
    () async {
      await agent.dispatchForTest('memory_save', {
        'scope': 'session',
        'content': 'Delete me',
      });
      app.memoryEnabled = false;
      expect(
        agent.buildRequestMessages(a, 'sys').toString(),
        isNot(contains('Delete me')),
      );
      expect(
        await agent.dispatchForTest('memory_read', {'scope': 'session'}),
        contains('disabled'),
      );
      expect(
        agent.toolsForTest().where(
          (t) =>
              ((t['function'] as Map)['name'] as String).startsWith('memory_'),
        ),
        isEmpty,
      );
      app.memoryEnabled = true;
      app.deleteSession(a.id);
      await app.persistSessions();
      expect(MemoryStore(dir).read('a', 'MEMORY.md').content, isEmpty);
      AgentService.setRunSessionForTest('');
      agent.setRunCtxForTest(agent.runBucketForTest(a.id), a, 0);
      expect(
        await agent.dispatchForTest('memory_save', {
          'scope': 'session',
          'content': 'Resurrect',
        }),
        isNot(contains('saved')),
      );
    },
  );

  test(
    'legacy snippet migration persists once without replacing MEMORY.md',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ovid_memories',
        jsonEncode([
          for (var i = 0; i < 100; i++)
            {
              'id': 'old$i',
              'content': 'Legacy preference $i',
              'createdAt': '2026-01-01T00:00:00Z',
            },
        ]),
      );
      MemoryStore(dir).save(null, 'MEMORY.md', 'User authored', mode: 'append');
      AppState.resetTestInstance();
      app = AppState.createForTest(memoryStore: MemoryStore(dir));
      await app.prepareMemory();
      expect(MemoryStore(dir).read(null, 'MEMORY.md').content, 'User authored');
      expect(MemoryStore(dir).search('a', 'Legacy preference'), hasLength(1));
      expect(prefs.containsKey('ovid_memories'), isFalse);
      AppState.resetTestInstance();
      app = AppState.createForTest(memoryStore: MemoryStore(dir));
      await app.prepareMemory();
      expect(MemoryStore(dir).search('a', 'Legacy preference'), hasLength(1));
    },
  );

  test(
    'persisted lineage routes main and child model requests after restart',
    () async {
      final store = MemoryStore(dir);
      store.save(null, 'MEMORY.md', 'Global model fact', mode: 'append');
      store.save('a', 'MEMORY.md', 'Owning project fact', mode: 'append');
      final restored = [
        for (final s in [a, b, child])
          ChatSession.fromJson(jsonDecode(jsonEncode(s.toJson()))),
      ];
      AppState.resetTestInstance();
      app = AppState.createForTest(memoryStore: MemoryStore(dir));
      app.sessions
        ..clear()
        ..addAll(restored);
      app.activeSessionId = 'b';
      AgentService.setRunSessionForTest('');
      agent.restoreSubagentHandles();
      final provider = app.providerById('ollama-local')!;
      provider
        ..baseUrl = 'http://127.0.0.1:1/v1'
        ..models = ['test']
        ..selectedModel = 'test';
      final captured = <String, List<Map<String, dynamic>>>{};
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        captured[session.id] = List.of(msgs);
        return {
          'role': 'assistant',
          'content': 'done',
          'finish_reason': 'stop',
        };
      };
      for (final session in restored) {
        session.providerId = provider.id;
        if (session.isSubagent) session.agentContinuable = true;
        session.messages.add(
          Message(role: 'user', content: 'Use saved context'),
        );
        await agent
            .runTask('Use saved context', sessionId: session.id)
            .timeout(const Duration(seconds: 20));
        if (session.isSubagent) {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (session.agentState == 'running' &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(session.agentState, 'finished');
        }
      }
      expect(captured.keys, containsAll(['a', 'b', 'child']));
      for (final id in ['a', 'child']) {
        final rows = captured[id]!;
        expect(
          rows
              .where((m) => '${m['content']}'.contains('Owning project fact'))
              .single['role'],
          'user',
        );
        expect(rows.toString(), contains('Global model fact'));
      }
      expect(captured['b'].toString(), contains('Global model fact'));
      expect(captured['b'].toString(), isNot(contains('Owning project fact')));
    },
  );

  test(
    'extra files are paged by tools and never searchable from other roots',
    () async {
      await agent.dispatchForTest('memory_save', {
        'scope': 'session',
        'file': 'project.md',
        'mode': 'create',
        'content': 'Confidential ${'x' * 12000}',
      });
      final read =
          jsonDecode(
                await agent.dispatchForTest('memory_read', {
                  'scope': 'session',
                  'file': 'project.md',
                }),
              )
              as Map;
      expect(read['content'], hasLength(8000));
      expect(read['next_offset'], 8000);
      expect(read['files'], contains('project.md'));
      expect(
        await agent.dispatchForTest('memory_search', {'query': 'Confidential'}),
        contains('project.md'),
      );
      AgentService.setRunSessionForTest('b');
      app.shareSessionMemory = true;
      expect(
        await agent.dispatchForTest('memory_search', {'query': 'Confidential'}),
        isNot(contains('project.md')),
      );
      app.deleteSession('child');
      await app.persistSessions();
      expect(
        MemoryStore(dir).read('a', 'project.md').content,
        contains('Confidential'),
      );
    },
  );

  test(
    'factory reset clears Markdown even if legacy migration is malformed',
    () async {
      final store = MemoryStore(dir);
      store.save(null, 'MEMORY.md', 'Forget global', mode: 'append');
      store.save('a', 'MEMORY.md', 'Forget session', mode: 'append');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ovid_memories', 'invalid json');
      await app.deleteAllData();
      expect(store.read(null, 'MEMORY.md').content, isEmpty);
      expect(store.read('a', 'MEMORY.md').content, isEmpty);
      expect(prefs.containsKey('ovid_memories'), isFalse);
    },
  );
}
