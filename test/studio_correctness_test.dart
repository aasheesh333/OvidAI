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

/// Studio screen correctness (2026-09-30 audit): the repo bar read
/// `AgentService.I.sessionRepoFull` without subscribing to anything, the repo
/// picker cast `r['full_name'] as String` behind a guard that tolerated a
/// missing one, and `RepoCache.sync`'s progress callback was never passed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'tok'});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    studioLoginPromptOverrideForTest = (_) {};
    studioRepoSyncOverrideForTest = () async {};
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
    studioLoginPromptOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    studioRepoSyncProgressOverrideForTest = null;
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
    await tester.pump(const Duration(milliseconds: 120));
  }

  group('the repo bar is live', () {
    testWidgets('an external repo change reaches the bar without interaction',
        (tester) async {
      app.activeSession!.repo = 'owner/repo';
      AgentService.I.repoFull = 'owner/repo';
      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'main',
        sessionId: app.activeSession!.id,
      );
      RepoCache.I.files['README.md'] = 'hi';

      await pumpStudio(tester);
      expect(find.text('owner/repo'), findsWidgets);

      // Another part of the app rebinds the session (agent tool, restart-time
      // backfill). Studio used to keep showing the previous repo.
      AppState.I.setRepoForSession(app.activeSession!.id, 'other/repo');
      await tester.pump();

      expect(find.text('other/repo'), findsWidgets,
          reason: 'the bar read sessionRepoFull without subscribing');
      expect(find.text('owner/repo'), findsNothing);
    });

    testWidgets('an external branch change reaches the bar', (tester) async {
      app.activeSession!.repo = 'owner/repo';
      AgentService.I.repoFull = 'owner/repo';
      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'main',
        sessionId: app.activeSession!.id,
      );
      RepoCache.I.files['README.md'] = 'hi';

      await pumpStudio(tester);
      expect(find.text('main'), findsWidgets);

      AppState.I.setBranchForSession(app.activeSession!.id, 'release');
      await tester.pump();

      expect(find.text('release'), findsWidgets);
    });
  });

  group('repo picker tolerates a partial GitHub payload', () {
    const repos = <Map<String, dynamic>>[
      {'full_name': 'octocat/full', 'name': 'full', 'language': 'Dart'},
      {'name': 'only-name', 'language': 'Rust'},
      {'language': 'Go'},
    ];

    String? result;
    Future<void> openSheet(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => StudioRepoSheet(repos: repos),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a repo with only `name` is pickable, not a crash',
        (tester) async {
      await openSheet(tester);

      expect(find.text('octocat/full'), findsOneWidget);
      expect(find.text('only-name'), findsOneWidget);
      expect(find.text('null'), findsNothing,
          reason: "the old fallback rendered the literal string 'null'");

      await tester.tap(find.text('only-name'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: "onTap did `r['full_name'] as String` behind a null-tolerant guard");
      expect(result, 'only-name');
    });

    testWidgets('a repo with no usable name is listed but not pickable',
        (tester) async {
      await openSheet(tester);

      expect(find.text(studioUnnamedRepoLabel), findsOneWidget);
      await tester.tap(find.text(studioUnnamedRepoLabel), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('open'), findsNothing,
          reason: 'the sheet must still be on screen — nothing was selected');
    });
  });

  group('sync progress is visible', () {
    testWidgets('the onLine callback drives a real progress readout',
        (tester) async {
      app.activeSession!.repo = 'owner/repo';
      AgentService.I.repoFull = 'owner/repo';
      RepoCache.I.bind(
        'owner/repo',
        'tok',
        branch: 'main',
        sessionId: 'some-other-session',
      );
      RepoCache.I.files['README.md'] = 'stale';
      studioRepoSyncOverrideForTest = null;

      final gate = Completer<void>();
      studioRepoSyncProgressOverrideForTest = (onLine) {
        onLine('fetching tree of owner/repo …');
        onLine('synced 25 / 400 files');
        return gate.future;
      };

      await pumpStudio(tester);
      await tester.pump();

      expect(find.textContaining('25 / 400'), findsWidgets,
          reason: 'a multi-minute serial fetch showed only an 11px spinner');
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.textContaining('25 / 400'), findsNothing,
          reason: 'progress must clear when the sync finishes');
    });
  });
}
