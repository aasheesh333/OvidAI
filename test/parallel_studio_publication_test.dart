import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

void main() {
  final cache = RepoCache.I;
  final agent = AgentService.I;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'token'});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    cache.unbind();
    final app = AppState.createForTest();
    agent.debugPauseScheduleTimerForTest(true);
    app.activeSession!.repo = 'owner/one';
    cache.bind('owner/one', 'token', sessionId: app.activeSession!.id);
    studioLoginPromptOverrideForTest = (_) {};
    await GitHubService.I.initialize(client: MockClient((_) async =>
        http.Response(jsonEncode({'login': 'octocat'}), 200)));
  });
  tearDown(() async {
    studioLoginPromptOverrideForTest = null;
    studioRepoSyncProgressOverrideForTest = null;
    agent.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    cache.unbind();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  for (final replacement in ['binding', 'sync']) {
  testWidgets('obsolete sync failure cannot clear the replacement $replacement', (tester) async {
    final gate = Completer<void>();
    void Function(String)? progress;
    studioRepoSyncProgressOverrideForTest = (line) {
      progress = line;
      return gate.future;
    };
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const StudioScreen()));
    await tester.pump();
    expect(progress, isNotNull);
    if (replacement == 'binding') {
      cache.bind('owner/two', 'token', sessionId: AppState.I.activeSession!.id);
      cache.files['new.txt'] = 'new binding';
    } else {
      await cache.sync(client: MockClient((r) async => r.url.path.contains('/git/trees/')
          ? http.Response(jsonEncode({'tree': [{'type': 'blob', 'path': 'new.txt'}]}), 200)
          : http.Response('new binding', 200)));
    }
    progress!('synced 99 / 100 files');
    gate.completeError(StateError('repository binding changed'));
    await tester.pumpAndSettle();
    expect(cache.read('new.txt'), 'new binding');
    expect(find.textContaining('99 / 100'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  }

  testWidgets('a file fetch completing after rebind does not open or mark the replacement row failed', (tester) async {
    cache.treePaths.add('a.txt');
    final gate = Completer<http.Response>();
    final entered = Completer<void>();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const Scaffold(body: StudioFileTree())));
      await tester.tap(find.text('a.txt'));
      await tester.pump();
      expect(entered.isCompleted, isTrue);
      AppState.I.setRepoForSession(AppState.I.activeSession!.id, 'owner/two');
      cache.bind('owner/two', 'token', sessionId: AppState.I.activeSession!.id);
      cache.treePaths.add('a.txt');
      gate.complete(http.Response('old binding', 200));
      await tester.pumpAndSettle();
      expect(agent.studioOpenFiles, isEmpty);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(tester.takeException(), isNull);
    }, () => MockClient((_) {
      entered.complete();
      return gate.future;
    }));
  });
}
