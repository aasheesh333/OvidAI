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

/// Studio repo+branch binding UI (spec §5.4, §7): the branch picker must
/// update the session branch and re-sync, the `_boundSessionId` guard must
/// rebind a cache that belongs to another session, and a failed sync must
/// surface instead of leaving stale files under the new binding.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'tok'});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    studioListBranchesOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    await GitHubService.I.initialize(
      client: MockClient(
        (request) async => request.url.path == '/user'
            ? http.Response(jsonEncode({'login': 'octocat'}), 200)
            : http.Response('{}', 404),
      ),
    );
  });

  tearDown(() async {
    studioListBranchesOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    RepoCache.I.unbind();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
    );
    await tester.pump();
  }

  testWidgets('branch picker updates sessionBranch and re-syncs', (
    tester,
  ) async {
    app.activeSession!.repo = 'owner/repo';
    AgentService.I.repoFull = 'owner/repo';
    // The cache already belongs to this session, so the auth gate must not
    // auto-sync before we interact.
    RepoCache.I.bind(
      'owner/repo',
      'tok',
      branch: 'main',
      sessionId: app.activeSession!.id,
    );
    RepoCache.I.files['README.md'] = 'hi';

    var syncs = 0;
    studioRepoSyncOverrideForTest = () async {
      syncs++;
    };
    studioListBranchesOverrideForTest = (_, _) async => ['main', 'develop'];

    await pumpStudio(tester);

    expect(syncs, 0, reason: 'same-session cache does not re-sync on mount');

    await tester.tap(find.text('main'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('develop'));
    await tester.pumpAndSettle();

    expect(AgentService.I.sessionBranch, 'develop');
    expect(RepoCache.I.defaultBranch, 'develop');
    expect(syncs, 1, reason: 'picking a branch re-syncs the binding');
    expect(find.text('develop'), findsOneWidget);
  });

  testWidgets('auth gate rebinds when the cache belongs to another session', (
    tester,
  ) async {
    app.activeSession!.repo = 'owner/repo';
    AgentService.I.repoFull = 'owner/repo';
    RepoCache.I.bind(
      'owner/repo',
      'tok',
      branch: 'main',
      sessionId: 'some-other-session',
    );
    RepoCache.I.files['README.md'] = 'stale';

    var syncs = 0;
    studioRepoSyncOverrideForTest = () async {
      syncs++;
    };

    await pumpStudio(tester);
    await tester.pump();

    expect(syncs, 1, reason: 'foreign session binding triggers a re-sync');
  });

  testWidgets('a failed sync surfaces an error and drops stale files', (
    tester,
  ) async {
    app.activeSession!.repo = 'owner/repo';
    AgentService.I.repoFull = 'owner/repo';
    RepoCache.I.files['stale.md'] = 'old';

    studioRepoSyncOverrideForTest = () async {
      throw Exception('tree fetch 404');
    };

    await pumpStudio(tester);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('tree fetch 404'), findsWidgets);
    expect(RepoCache.I.files, isEmpty, reason: 'stale files must not remain');
  });

  test('branchForPickedRepo resets to the default branch or main', () {
    expect(
      branchForPickedRepo({'full_name': 'o/r', 'default_branch': 'trunk'}),
      'trunk',
    );
    expect(branchForPickedRepo({'full_name': 'o/r'}), 'main');
    expect(
      branchForPickedRepo({'full_name': 'o/r', 'default_branch': ''}),
      'main',
    );
    expect(branchForPickedRepo(null), 'main');
  });
}
