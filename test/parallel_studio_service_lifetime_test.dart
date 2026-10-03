import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  final cache = RepoCache.I;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late File file;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    cache.unbind();
    final app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    app.setRepoForSession(app.activeSession!.id, 'owner/one');
    agent.studioOpenFiles.clear();
    agent.fileBuffer.clear();
    agent.fileBuffer['a.txt'] = 'base';
    agent.studioOpenFiles.add('a.txt');
    agent.activeFilePath = 'a.txt';
    root = Directory.systemTemp.createTempSync('parallel-service-lifetime-');
    final session = app.activeSession!;
    file = File('${root.path}/workspaces/ws_${session.sandboxId ?? session.id}/a.txt');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('disk');
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
    agent.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    cache.unbind();
    AppState.resetTestInstance();
  });

  for (final action in ['edit', 'rebind', 'close']) {
    test('service save rejects $action while root is paused before any write', () async {
      final entered = Completer<void>();
      final gate = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      });
      final saving = agent.saveStudioFile('a.txt', 'stale save');
      // Observe errors immediately, then assert after releasing the root.
      final outcome = saving.then<Object?>((_) => null, onError: (Object e) => e);
      await entered.future;
      if (action == 'edit') agent.fileBuffer['a.txt'] = 'new typing';
      if (action == 'close') agent.closeStudioFile('a.txt');
      if (action == 'rebind') {
        final app = AppState.I;
        app.setRepoForSession(app.activeSession!.id, 'owner/two');
        cache.bind('owner/two', 'token', sessionId: app.activeSession!.id);
        agent.fileBuffer['a.txt'] = 'replacement';
      }
      gate.complete(root.path);
      expect(await outcome, isA<StateError>());
      expect(file.readAsStringSync(), 'disk');
      if (action == 'edit') expect(agent.fileBuffer['a.txt'], 'new typing');
      if (action == 'close') expect(agent.studioOpenFiles, isEmpty);
      if (action == 'rebind') expect(agent.fileBuffer['a.txt'], 'replacement');
      expect(cache.hasPending, isFalse);
    });
  }

  test('newer save wins when root responses arrive in reverse order', () async {
    final entered = Completer<void>();
    final firstRoot = Completer<String>();
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
      if (++calls == 1) { entered.complete(); return firstRoot.future; }
      return Future.value(root.path);
    });
    final old = agent.saveStudioFile('a.txt', 'old').then<Object?>((_) => null, onError: (Object e) => e);
    await entered.future;
    await agent.saveStudioFile('a.txt', 'new');
    firstRoot.complete(root.path);
    expect(await old, isA<StateError>());
    expect(file.readAsStringSync(), 'new');
    expect(agent.fileBuffer['a.txt'], 'new');
  });

  for (final action in ['edit', 'rebind', 'close']) {
    test('service reload ignores $action while root is paused', () async {
      final entered = Completer<void>();
      final gate = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) {
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      });
      final originalBucket = agent.fileBuffer;
      final reload = agent.syncOpenFilesFromDisk();
      await entered.future;
      if (action == 'edit') originalBucket['a.txt'] = 'new typing';
      if (action == 'close') agent.closeStudioFile('a.txt');
      if (action == 'rebind') {
        final app = AppState.I;
        app.setRepoForSession(app.activeSession!.id, 'owner/two');
        agent.fileBuffer['a.txt'] = 'replacement';
      }
      gate.complete(root.path);
      await reload;
      expect(originalBucket['a.txt'], action == 'edit' ? 'new typing' : 'base');
      if (action == 'rebind') expect(agent.fileBuffer['a.txt'], 'replacement');
      if (action == 'close') expect(agent.studioOpenFiles, isEmpty);
      expect(file.readAsStringSync(), 'disk');
    });
  }
}
