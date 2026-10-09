import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppState app;
  late ChatSession owner;
  late ChatSession unrelated;
  late ChatSession child;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('agent-memory-context-');
    app = AppState.createForTest(memoryStore: MemoryStore(root));
    SessionLedger.rootOverrideForTest = Directory('${root.path}/ledger')
      ..createSync();
    SessionSearch.dbPathOverrideForTest = '${root.path}/session-search.db';
    owner = ChatSession(id: 'owner', title: 'Owner', model: 'test');
    unrelated = ChatSession(id: 'unrelated', title: 'Unrelated', model: 'test');
    child = ChatSession(
      id: 'child',
      title: 'Child',
      model: 'test',
      parentId: owner.id,
      agentId: 'child-agent',
      agentContinuable: true,
      agentState: 'finished',
    );
    app.sessions.addAll([owner, unrelated, child]);
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test']
      ..selectedModel = 'test';
    for (final session in app.sessions) {
      session.providerId = provider.id;
    }
    await app.prepareMemory();
    AgentService.setRunSessionForTest(owner.id);
  });

  tearDown(() async {
    AgentService.llmOnceForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.clearRunCtxForTest();
    for (final id in ['owner', 'unrelated', 'child']) {
      await SessionLedger.I.close(id);
    }
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    root.deleteSync(recursive: true);
  });

  test(
    'agent request prompt includes global, owner session, and child memory',
    () async {
      final store = MemoryStore(root);
      store.save(null, 'MEMORY.md', 'GLOBAL_FACT', mode: 'append');
      store.save(owner.id, 'MEMORY.md', 'OWNER_FACT_V1', mode: 'append');

      final captured = <String, List<Map<String, dynamic>>>{
        for (final session in [owner, child, unrelated])
          session.id: AgentService.I.buildRequestMessages(session, 'SYSTEM'),
      };

      expect(captured[owner.id].toString(), contains('GLOBAL_FACT'));
      expect(captured[owner.id].toString(), contains('OWNER_FACT_V1'));
      expect(captured[child.id].toString(), contains('GLOBAL_FACT'));
      expect(captured[child.id].toString(), contains('OWNER_FACT_V1'));
      expect(captured[unrelated.id].toString(), contains('GLOBAL_FACT'));
      expect(
        captured[unrelated.id].toString(),
        isNot(contains('OWNER_FACT_V1')),
      );
      expect(
        captured[owner.id]!
            .where((row) => '${row['content']}'.contains('OWNER_FACT_V1'))
            .single['role'],
        'user',
      );

      store.save(owner.id, 'MEMORY.md', 'OWNER_FACT_V2', mode: 'append');
      final updated = AgentService.I.buildRequestMessages(owner, 'SYSTEM');
      expect(updated.toString(), contains('OWNER_FACT_V2'));
      expect(updated.toString(), contains('OWNER_FACT_V1'));
    },
  );

  test(
    'persisted memory remains available to a restored child prompt',
    () async {
      final store = MemoryStore(root);
      store.save(null, 'MEMORY.md', 'PERSISTED_GLOBAL', mode: 'append');
      store.save(owner.id, 'MEMORY.md', 'PERSISTED_OWNER', mode: 'append');

      final restored = [
        for (final session in [owner, unrelated, child])
          ChatSession.fromJson(jsonDecode(jsonEncode(session.toJson()))),
      ];
      AppState.resetTestInstance();
      app = AppState.createForTest(memoryStore: MemoryStore(root));
      app.sessions.addAll(restored);
      await app.prepareMemory();

      final restoredChild = app.sessionById(child.id)!;
      final prompt = AgentService.I.buildRequestMessages(
        restoredChild,
        'SYSTEM',
      );
      expect(prompt.toString(), contains('PERSISTED_GLOBAL'));
      expect(prompt.toString(), contains('PERSISTED_OWNER'));
      expect(
        AgentService.I
            .buildRequestMessages(app.sessionById(unrelated.id)!, 'SYSTEM')
            .toString(),
        isNot(contains('PERSISTED_OWNER')),
      );
    },
  );

  test('memory is isolated when the session account changes', () async {
    AppState.resetTestInstance();
    app = AppState.createForTest(
      memoryStore: MemoryStore(root),
      sessionAccountIdForTest: 'account-a',
    );
    expect(app.sessionAccountId, 'account-a');
    final accountAStore = await app.prepareMemory();
    expect(accountAStore.root.path, contains('account-'));
    await app.saveMemory(
      MemoryItem(id: 'account-a', content: 'ACCOUNT_A_GLOBAL'),
    );

    AppState.resetTestInstance();
    final accountB = AppState.createForTest(
      memoryStore: MemoryStore(root),
      sessionAccountIdForTest: 'account-b',
    );
    final accountBSession = ChatSession(
      id: 'account-b-session',
      title: 'Account B',
      model: 'test',
    );
    accountB.sessions.add(accountBSession);
    final accountBStore = await accountB.prepareMemory();
    expect(accountBStore.root.path, contains('account-'));
    expect(accountBStore.root.path, isNot(accountAStore.root.path));

    expect(
      accountB.memoryContext(accountBSession.id),
      isNot(contains('ACCOUNT_A_GLOBAL')),
    );
  });

  test('stale guest memory preparation cannot republish after account change', () async {
    final preparing = app.prepareMemory();
    final stalePreparation = expectLater(preparing, throwsA(isA<StateError>()));
    final transition = app.transitionSessionAccount('account-a');

    await transition;
    await stalePreparation;

    final accountSession = ChatSession(
      id: 'account-a-session',
      title: 'Account A',
      model: 'test',
    );
    app.sessions.add(accountSession);
    expect(
      app.memoryContext(accountSession.id),
      isNot(contains('ACCOUNT_A_GLOBAL')),
    );
    final accountStore = await app.prepareMemory();

    expect(accountStore.root.path, contains('account-'));
    expect(
      app.memoryContext(accountSession.id),
      isNot(contains('ACCOUNT_A_GLOBAL')),
    );
  });

  test('stale account memory preparation cannot republish after returning to guest', () async {
    AppState.resetTestInstance();
    app = AppState.createForTest(
      memoryStore: MemoryStore(root),
      sessionAccountIdForTest: 'account-a',
    );
    final accountSession = ChatSession(
      id: 'account-a-session',
      title: 'Account A',
      model: 'test',
    );
    app.sessions.add(accountSession);

    final preparing = app.prepareMemory();
    final stalePreparation = expectLater(preparing, throwsA(isA<StateError>()));
    final transition = app.transitionSessionAccount('guest');

    await transition;
    await stalePreparation;

    final guestSession = ChatSession(
      id: 'guest-session',
      title: 'Guest',
      model: 'test',
    );
    app.sessions.add(guestSession);
    expect(
      app.memoryContext(guestSession.id),
      isNot(contains('ACCOUNT_A_GLOBAL')),
    );
    final guestStore = await app.prepareMemory();

    expect(guestStore.root.path, root.path);
    expect(
      app.memoryContext(guestSession.id),
      isNot(contains('ACCOUNT_A_GLOBAL')),
    );
  });
}
