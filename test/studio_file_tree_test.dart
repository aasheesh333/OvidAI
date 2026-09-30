import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_file_tree.dart';
import 'package:ovid_ai/ui/studio_layout.dart';

/// Studio file tree (2026-09-30 audit).
///
/// The old tree guessed directories with "the next sorted path starts with
/// `p/`" (studio_screen.dart:1125), so a directory whose children were all
/// dropped by RepoCache's skip-list rendered as a *file*, and tapping it
/// opened an empty editor buffer indistinguishable from a real empty file
/// (`_openUnknownFile`, :1065). Directories are now derived from the path set
/// itself, and a failed fetch is a visible error state instead of a blank tab.
void main() {
  group('buildStudioTree derives directories from the path set', () {
    test('an empty path set yields no nodes', () {
      expect(buildStudioTree(const [], const {}), isEmpty);
    });

    test('top level lists directories before files', () {
      final nodes = buildStudioTree(
        ['lib/ui/a.dart', 'lib/b.dart', 'README.md'],
        const {},
      );
      expect(nodes.map((n) => n.name).toList(), ['lib', 'README.md']);
      expect(nodes.first.isDirectory, isTrue);
      expect(nodes.first.depth, 0);
      expect(nodes.last.isDirectory, isFalse);
    });

    test('collapsed directories hide their children', () {
      final nodes = buildStudioTree(
        ['lib/ui/a.dart', 'lib/b.dart', 'README.md'],
        const {'lib'},
      );
      expect(
        nodes.map((n) => '${n.depth}:${n.name}').toList(),
        ['0:lib', '1:ui', '1:b.dart', '0:README.md'],
      );
      expect(nodes.any((n) => n.name == 'a.dart'), isFalse);
    });

    test('expanded directories reveal their children', () {
      final nodes = buildStudioTree(
        ['lib/ui/a.dart', 'lib/b.dart', 'README.md'],
        const {'lib', 'lib/ui'},
      );
      expect(
        nodes.map((n) => '${n.depth}:${n.name}').toList(),
        ['0:lib', '1:ui', '2:a.dart', '1:b.dart', '0:README.md'],
      );
    });

    test('a directory is never reported as a file', () {
      // `vendor/` has exactly one descendant here; the old next-path heuristic
      // needed a *sibling ordering* accident to notice that.
      final nodes = buildStudioTree(['vendor/a/b.txt'], const {});
      expect(nodes, hasLength(1));
      expect(nodes.single.path, 'vendor');
      expect(nodes.single.isDirectory, isTrue,
          reason: 'must not render as a tappable file');
    });

    test('every node is either a real directory or a real path', () {
      const paths = [
        'a.txt',
        'lib/main.dart',
        'lib/ui/x.dart',
        'lib/ui/y.dart',
        'test/w_test.dart',
        'android/app/build.gradle',
      ];
      final nodes = buildStudioTree(
        paths,
        paths.expand(_allPrefixes).toSet(),
      );
      for (final n in nodes) {
        if (n.isDirectory) {
          expect(paths.any((p) => p.startsWith('${n.path}/')), isTrue,
              reason: '${n.path} claimed to be a directory');
        } else {
          expect(paths, contains(n.path),
              reason: '${n.path} claimed to be a file');
        }
      }
    });

    test('a directory with no surviving children does not appear at all', () {
      // RepoCache's skip-list drops `assets/logo.png`; the tree API never
      // hands Studio the `assets` entry, so it must not be invented.
      final nodes = buildStudioTree(['README.md'], const {});
      expect(nodes.map((n) => n.path), ['README.md']);
    });

    test('duplicates and junk segments are normalised away', () {
      final nodes = buildStudioTree(
        ['/lib/a.dart', 'lib/a.dart', 'lib//b.dart', ''],
        const {},
      );
      expect(nodes.map((n) => n.path), ['lib']);
      final open = buildStudioTree(
        ['/lib/a.dart', 'lib/a.dart', 'lib//b.dart', ''],
        const {'lib'},
      );
      expect(open.map((n) => n.path), ['lib', 'lib/a.dart', 'lib/b.dart']);
    });

    test('sorting inside a level is stable and case-insensitive', () {
      final nodes = buildStudioTree(
        ['d/B.dart', 'd/a.dart', 'd/C.dart', 'd/zebra/a.txt', 'd/Alpha/b.txt'],
        const {'d'},
      );
      expect(
        nodes.map((n) => n.name).toList(),
        ['d', 'Alpha', 'zebra', 'a.dart', 'B.dart', 'C.dart'],
      );
    });
  });

  group('StudioFileTree widget', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AgentNotificationService.I.resetForTest();
      AppState.resetTestInstance();
      RepoCache.I.unbind();
      AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
      for (final p in AgentService.I.studioOpenFiles.toList()) {
        AgentService.I.closeStudioFile(p);
      }
      AgentService.I.fileBuffer.clear();
      AgentService.I.activeFilePath = null;
    });

    tearDown(() {
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AgentNotificationService.I.resetForTest();
      RepoCache.I.unbind();
      AppState.resetTestInstance();
    });

    Future<void> pumpTree(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const Scaffold(
            body: SizedBox(width: 300, height: 500, child: StudioFileTree()),
          ),
        ),
      );
      await tester.pump();
    }

    void seedRepo() {
      RepoCache.I.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      RepoCache.I.treePaths
        ..clear()
        ..addAll(['lib/a.dart', 'lib/b.dart', 'README.md']);
      RepoCache.I.files
        ..clear()
        ..addAll({
          'lib/a.dart': 'void a() {}',
          'lib/b.dart': 'void b() {}',
          'README.md': '# hi',
        });
      RepoCache.I.notifyListeners();
    }

    testWidgets('renders folders as folders and expands them on tap',
        (tester) async {
      seedRepo();
      await pumpTree(tester);

      expect(find.text('lib'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('a.dart'), findsNothing,
          reason: 'a collapsed folder must not leak its children');
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

      await tester.tap(find.text('lib'));
      await tester.pumpAndSettle();

      expect(find.text('a.dart'), findsOneWidget);
      expect(find.text('b.dart'), findsOneWidget);
      expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget,
          reason: 'expansion must be visible without colour alone');
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
    });

    testWidgets('tapping a cached file opens it as a tab', (tester) async {
      seedRepo();
      await pumpTree(tester);

      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(AgentService.I.studioOpenFiles, contains('README.md'));
    });

    testWidgets('rows meet the 44dp tap-target invariant', (tester) async {
      seedRepo();
      await pumpTree(tester);

      final targets = find.byType(StudioTapTarget);
      expect(targets, findsWidgets);
      for (final e in targets.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget).first);
        expect(size.height, greaterThanOrEqualTo(kStudioTapTarget),
            reason: 'file-tree row was ~25dp');
        expect(size.width, greaterThanOrEqualTo(kStudioTapTarget));
      }
    });

    testWidgets('a failed fetch is visibly distinct from an empty file',
        (tester) async {
      // No binding: RepoCache.read() misses and fetchFile() cannot reach the
      // network, so the content is genuinely unavailable — NOT empty.
      RepoCache.I.unbind();
      RepoCache.I.treePaths
        ..clear()
        ..add('ghost.dart');
      RepoCache.I.files
        ..clear()
        ..addEntries([const MapEntry('empty.txt', '')]);
      RepoCache.I.notifyListeners();

      await pumpTree(tester);

      // The genuinely empty file opens normally.
      await tester.tap(find.text('empty.txt'));
      await tester.pumpAndSettle();
      expect(AgentService.I.studioOpenFiles, contains('empty.txt'));
      expect(AgentService.I.fileBuffer['empty.txt'], '');

      // The unreachable one must not open a blank tab.
      await tester.tap(find.text('ghost.dart'));
      await tester.pumpAndSettle();

      expect(AgentService.I.studioOpenFiles, isNot(contains('ghost.dart')),
          reason: 'a failed fetch must not masquerade as an empty file');
      expect(find.byIcon(Icons.error_outline), findsOneWidget,
          reason: 'the row must carry a visible failure affordance');
      expect(find.textContaining('Could not'), findsWidgets,
          reason: 'the failure must be explained, not silently blank');
    });

    testWidgets('the failed row is labelled for screen readers and retries',
        (tester) async {
      RepoCache.I.unbind();
      RepoCache.I.treePaths
        ..clear()
        ..add('ghost.dart');
      RepoCache.I.notifyListeners();

      await pumpTree(tester);
      await tester.tap(find.text('ghost.dart'));
      await tester.pumpAndSettle();

      final labels = tester
          .widgetList<Semantics>(find.ancestor(
            of: find.text('ghost.dart'),
            matching: find.byType(Semantics),
          ))
          .map((s) => s.properties.label ?? '')
          .toList();
      expect(labels.any((l) => l.toLowerCase().contains('could not')), isTrue,
          reason: 'the failure must reach a screen reader, not just the eye');
    });

    testWidgets('no repo shows the connect prompt, not a broken tree',
        (tester) async {
      RepoCache.I.unbind();
      RepoCache.I.notifyListeners();
      await pumpTree(tester);
      expect(find.textContaining('Connect a repo'), findsOneWidget);
    });
  });
}

Iterable<String> _allPrefixes(String path) sync* {
  final parts = path.split('/');
  for (var i = 1; i < parts.length; i++) {
    yield parts.sublist(0, i).join('/');
  }
}
