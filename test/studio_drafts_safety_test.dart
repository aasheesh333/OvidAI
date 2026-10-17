import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

/// Studio drafts and file safety (screen review 06 §1, §4, §5, §7 —
/// F-071 … F-077): unsaved code must never be lost or shown as SAVED, binary
/// files must never be re-encoded, and large files must not freeze the UI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'tok'});
    AppState.resetTestInstance();
    RepoCache.I.unbind();
    StudioDraftStore.I.disableForTest();
    studioLoginPromptOverrideForTest = (_) {};
    studioRepoSyncOverrideForTest = () async {};
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    agent.debugPauseScheduleTimerForTest(true);
    agent.debugForgetStudioStateForTest();
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
    agent.debugPauseScheduleTimerForTest(false);
    agent.debugForgetStudioStateForTest();
    StudioDraftStore.I.disableForTest();
    RepoCache.I.unbind();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  /// API-mode binding for the active session with two synced files.
  Future<void> bindRepo() async {
    app.activeSession!.repo = 'owner/repo';
    agent.repoFull = 'owner/repo';
    RepoCache.I.bind('owner/repo', 'tok',
        branch: 'main', sessionId: app.activeSession!.id);
    RepoCache.I.treePaths
      ..clear()
      ..addAll(['lib/a.dart', 'README.md']);
    RepoCache.I.files
      ..clear()
      ..addAll({'lib/a.dart': 'void a() {}', 'README.md': '# hi'});
    RepoCache.I.notifyListeners();
  }

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// StudioScreen keeps indeterminate progress animations alive, so
  /// pumpAndSettle never returns there; pump a bounded series of frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets real file IO started from the widget zone complete.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  final openStudioKey = GlobalKey<NavigatorState>();

  /// A home route that pushes Studio, so back really leaves the screen.
  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: openStudioKey,
      theme: Aether.theme(),
      home: const Scaffold(body: Text('home')),
    ));
  }

  Future<void> pushStudio(WidgetTester tester) async {
    openStudioKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const StudioScreen()),
    );
    await settle(tester);
  }

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(studioEditorFieldKey)).controller!;

  group('F-071 drafts survive leaving Studio', () {
    testWidgets('back with a draft asks first; Discard restores the saved text',
        (tester) async {
      setSurface(tester, const Size(1000, 800));
      await bindRepo();
      agent.openStudioFile('lib/a.dart', 'void a() {}');
      await pumpHome(tester);
      await pushStudio(tester);

      await tester.enterText(find.byKey(studioEditorFieldKey), 'my draft');
      await tester.pump();
      expect(find.text('UNSAVED'), findsOneWidget);

      // Android back.
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Leave Studio with unsaved changes?'), findsOneWidget);
      expect(find.byType(StudioScreen), findsOneWidget);

      // Cancel keeps the user in Studio with the draft.
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(controller(tester).text, 'my draft');

      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.tap(find.text('Discard'));
      await settle(tester);
      expect(find.byType(StudioScreen), findsNothing);

      await pushStudio(tester);
      expect(controller(tester).text, 'void a() {}');
      expect(find.text('SAVED'), findsOneWidget);
      expect(agent.hasDirtyStudioBuffers, isFalse);
    });

    testWidgets('a draft that left the screen comes back UNSAVED, not SAVED',
        (tester) async {
      setSurface(tester, const Size(1000, 800));
      await bindRepo();
      agent.openStudioFile('lib/a.dart', 'void a() {}');
      await pumpHome(tester);
      await pushStudio(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'kept draft');
      await tester.pump();
      // Leave without the guard (e.g. the route is removed by the system).
      openStudioKey.currentState!.pop();
      await settle(tester);

      // A tree tap delivers the disk bytes again; the draft must win.
      agent.openStudioFile('lib/a.dart', 'void a() {}');
      await pushStudio(tester);
      expect(controller(tester).text, 'kept draft');
      expect(find.text('UNSAVED'), findsOneWidget);
    });

    testWidgets('closing a dirty tab asks first', (tester) async {
      await bindRepo();
      agent.openStudioFile('lib/a.dart', 'void a() {}');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Column(children: [
            StudioEditorTabs(),
            Expanded(child: StudioEditor()),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioEditorFieldKey), 'draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Close tab a.dart'));
      await tester.pumpAndSettle();
      expect(find.text('Close a.dart?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(agent.studioOpenFiles, contains('lib/a.dart'));

      await tester.tap(find.byTooltip('Close tab a.dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(agent.studioOpenFiles, isNot(contains('lib/a.dart')));
      expect(agent.fileBuffer['lib/a.dart'], 'void a() {}');
      expect(agent.isStudioFileDirty('lib/a.dart'), isFalse);
    });

    testWidgets('editor drafts are persisted and restored after process death',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('studio-drafts-');
      addTearDown(() => dir.deleteSync(recursive: true));
      StudioDraftStore.I.enable(root: () async => dir);
      agent.openStudioFile('notes.txt', 'saved');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioEditor()),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioEditorFieldKey), 'unsaved work');
      await tester.pump();
      // App paused: pending drafts are written now.
      await tester.runAsync(() => StudioDraftStore.I.flush());

      // Process death: every in-memory bucket is gone.
      await tester.pumpWidget(const SizedBox());
      agent.debugForgetStudioStateForTest();
      // The first access recreates the bucket and starts the restore.
      await tester.runAsync(() async {
        expect(agent.fileBuffer['notes.txt'], isNull);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(agent.fileBuffer['notes.txt'], 'unsaved work');
      expect(agent.isStudioFileDirty('notes.txt'), isTrue);
      expect(agent.activeFilePath, 'notes.txt');
    });
  });

  group('F-072 compact panel toggle keeps the editor', () {
    testWidgets('360x740: toggling the folder panel twice keeps state + UNSAVED',
        (tester) async {
      setSurface(tester, const Size(360, 740));
      await bindRepo();
      agent.openStudioFile('lib/a.dart', 'void a() {}');
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await settle(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'typed');
      await tester.pump();
      final before = tester.state<EditableTextState>(find.byType(EditableText).first);

      await tester.tap(find.byTooltip('Toggle files'));
      await settle(tester);
      expect(find.byType(StudioFileTree), findsOneWidget);
      await tester.tap(find.byTooltip('Toggle files'));
      await settle(tester);

      final after = tester.state<EditableTextState>(find.byType(EditableText).first);
      expect(identical(before, after), isTrue);
      expect(find.text('UNSAVED'), findsOneWidget);
      expect(controller(tester).text, 'typed');
    });
  });

  group('F-073 / F-074 uncommitted API-mode edits', () {
    testWidgets('sign-out warns about uncommitted files before signing out',
        (tester) async {
      setSurface(tester, const Size(1000, 800));
      await bindRepo();
      RepoCache.I.write('a.txt', 'x');
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('GitHub account'));
      await settle(tester);
      await tester.tap(find.text('Sign out'));
      await settle(tester);
      expect(find.textContaining('You have 1 uncommitted file(s)'), findsOneWidget);
      expect(find.text('Commit first'), findsOneWidget);
      expect(find.text('Discard and sign out'), findsOneWidget);
      // Nothing was signed out or discarded yet.
      expect(GitHubService.I.isLoggedIn, isTrue);
      expect(RepoCache.I.dirtyCount, 1);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(RepoCache.I.files['a.txt'], 'x');
    });

    test('process death restores uncommitted API-mode edits on bind', () async {
      final dir = Directory.systemTemp.createTempSync('repo-drafts-');
      addTearDown(() => dir.deleteSync(recursive: true));
      StudioDraftStore.I.enable(root: () async => dir);
      final cache = RepoCache.I;
      cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      cache.write('a.txt', 'x');
      await StudioDraftStore.I.flush();

      // Process death: memory is gone (unbind clears every working copy).
      cache.unbind();
      await StudioDraftStore.I.flush();
      expect(cache.files, isEmpty);

      cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.files['a.txt'], 'x');
      expect(cache.pendingPaths, ['a.txt']);

      // A different binding never adopts it.
      cache.bind('owner/repo', 'tok', branch: 'dev', sessionId: 's1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.files['a.txt'], isNull);

      // Discard and sign out removes the record.
      await cache.discardPersistedDrafts();
      cache.unbind();
      cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.files['a.txt'], isNull);
    });
  });

  group('F-075 binary files', () {
    test('content sniffing', () {
      expect(looksBinaryBytes([0x50, 0x4b, 0x00, 0x03]), isTrue);
      expect(looksBinaryBytes(utf8.encode('plain text')), isFalse);
      expect(looksBinaryText('ab\u0000cd'), isTrue);
      expect(looksBinaryText('��ab'), isTrue);
      expect(looksBinaryText('héllo wörld'), isFalse);
    });

    test('RepoCache.write refuses a path holding binary content', () {
      final cache = RepoCache.I;
      cache.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      cache.files['app.db'] = 'SQLite format 3\u0000��';
      expect(() => cache.write('app.db', 'edited'), throwsStateError);
      expect(cache.hasPending, isFalse);
      expect(cache.files['app.db'], startsWith('SQLite'));
    });

    testWidgets('a file with NUL bytes opens the binary placeholder',
        (tester) async {
      final root = Directory.systemTemp.createTempSync('studio-binary-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/data.db').writeAsBytesSync([0x53, 0x51, 0x00, 0x01, 0xff]);
      app.setSessionWorkspaceFolder(root.path);
      RepoCache.I.bind('', '', sessionId: app.activeSession!.id,
          workspaceFolder: root.path);
      await tester.runAsync(() => RepoCache.I.sync());
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Row(children: [
            SizedBox(width: 260, child: StudioFileTree()),
            Expanded(child: StudioEditor()),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('data.db'));
      await drain(tester);
      expect(find.text('Binary file — not editable'), findsOneWidget);
      expect(find.byKey(studioEditorFieldKey), findsNothing);
      expect(find.text('BINARY'), findsOneWidget);
      expect(() => RepoCache.I.write('data.db', 'x'), throwsStateError);
    });
  });

  group('F-076 large files', () {
    testWidgets('a 3 MB file opens the too-large view without a sync read',
        (tester) async {
      final root = Directory.systemTemp.createTempSync('studio-large-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/big.txt').writeAsStringSync('x' * (3 * 1024 * 1024));
      File('${root.path}/small.txt').writeAsStringSync('ok');
      app.setSessionWorkspaceFolder(root.path);
      RepoCache.I.bind('', '', sessionId: app.activeSession!.id,
          workspaceFolder: root.path);
      await tester.runAsync(() => RepoCache.I.sync());
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: Row(children: [
            SizedBox(width: 260, child: StudioFileTree()),
            Expanded(child: StudioEditor()),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      // The tap must take the async stat/read path (FileSystemEntity.type +
      // File.length), not RepoCache.read's typeSync + readAsBytesSync.
      final asyncStats = <String>[];
      await IOOverrides.runZoned(
        () async {
          await tester.tap(find.text('big.txt'));
          await drain(tester);
        },
        fseGetType: (path, followLinks) {
          asyncStats.add(path);
          return Future.value(
              FileSystemEntity.typeSync(path, followLinks: followLinks));
        },
      );
      expect(asyncStats.where((p) => p.endsWith('big.txt')), isNotEmpty);
      expect(find.text('Too large to open on device'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(agent.fileBuffer['big.txt'], isEmpty,
          reason: 'the content is never loaded into the editor');
    });

    testWidgets('a 300 KB file opens read-only; Edit anyway gives a field',
        (tester) async {
      final text = List.generate(30000, (i) => 'line $i').join('\n');
      expect(text.length, greaterThan(kStudioViewerThreshold));
      agent.openStudioFile('gen.txt', text);
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioEditor()),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(studioEditorFieldKey), findsNothing);
      expect(find.text('READ-ONLY'), findsOneWidget);
      expect(find.text('line 0'), findsOneWidget);
      await tester.tap(find.text('Edit anyway'));
      await tester.pumpAndSettle();
      expect(find.byKey(studioEditorFieldKey), findsOneWidget);
      expect(find.text('SAVED'), findsOneWidget);
    });
  });

  group('F-077 controllers are pruned', () {
    testWidgets('closing a clean tab drops its field', (tester) async {
      agent.openStudioFile('a.txt', 'A');
      agent.openStudioFile('b.txt', 'B');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: StudioEditor()),
      ));
      await tester.pumpAndSettle();
      agent.selectStudioFile('a.txt');
      await tester.pumpAndSettle();
      expect(
        find.byKey(studioEditorFieldKey, skipOffstage: false),
        findsNWidgets(2),
      );
      agent.closeStudioFile('b.txt');
      await tester.pumpAndSettle();
      expect(
        find.byKey(studioEditorFieldKey, skipOffstage: false),
        findsOneWidget,
      );
      expect(controller(tester).text, 'A');
    });
  });
}
