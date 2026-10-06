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

/// Studio source-control experience (v2-11): filter, dirty decorations,
/// breadcrumb, and the collapsible Changes panel with stage/discard + inline
/// diff. The seeding pattern mirrors test/studio_file_tree_test.dart — the
/// cache is filled directly so no network is ever touched.
void main() {
  group('filterStudioPaths', () {
    const paths = [
      'README.md',
      'lib/a.dart',
      'lib/ui/b.dart',
      'docs/READING.txt',
    ];

    test('an empty query keeps every path', () {
      expect(filterStudioPaths(paths, ''), paths.toSet());
      expect(filterStudioPaths(paths, '   '), paths.toSet());
    });

    test('matching is case-insensitive and spans the whole path', () {
      expect(filterStudioPaths(paths, 'read'), {'README.md', 'docs/READING.txt'});
      expect(filterStudioPaths(paths, 'UI'), {'lib/ui/b.dart'});
      expect(filterStudioPaths(paths, 'zzz'), isEmpty);
    });
  });

  group('buildStudioLineDiff', () {
    test('a null before marks every line added', () {
      final lines = buildStudioLineDiff(null, 'one\ntwo\n');
      expect(lines.map((l) => l.kind),
          [StudioDiffLineKind.added, StudioDiffLineKind.added]);
      expect(lines.map((l) => l.text), ['one', 'two']);
    });

    test('a null after marks every line removed', () {
      final lines = buildStudioLineDiff('one\ntwo', null);
      expect(lines.map((l) => l.kind),
          [StudioDiffLineKind.removed, StudioDiffLineKind.removed]);
    });

    test('edits interleave removals before additions around context', () {
      final lines = buildStudioLineDiff('keep\nold\nend', 'keep\nnew\nend');
      expect(
        lines.map((l) => '${l.kind.name}:${l.text}'),
        ['context:keep', 'removed:old', 'added:new', 'context:end'],
      );
    });

    test('identical content is all context', () {
      final lines = buildStudioLineDiff('a\nb', 'a\nb');
      expect(lines.every((l) => l.kind == StudioDiffLineKind.context), isTrue);
      expect(lines, hasLength(2));
    });
  });

  group('StudioFileTree source control', () {
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

    void useView(WidgetTester tester, Size logical, double dpr) {
      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = logical * dpr;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> pumpTree(
      WidgetTester tester, {
      double width = 300,
      double height = 560,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: height,
              child: const StudioFileTree(),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// Bounded: two fixed pumps cover the 110ms row animations without
    /// relying on unbounded settling.
    Future<void> flush(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    void seedRepo() {
      RepoCache.I.bind('owner/repo', 'tok', branch: 'main', sessionId: 's1');
      RepoCache.I.treePaths
        ..clear()
        ..addAll(['lib/a.dart', 'lib/b.dart', 'README.md']);
      RepoCache.I.files
        ..clear()
        ..addAll({
          'lib/a.dart': 'void a() {}\n',
          'lib/b.dart': 'void b() {}\n',
          'README.md': '# hi\n',
        });
      RepoCache.I.notifyListeners();
    }

    testWidgets('the filter narrows rows and clearing restores them',
        (tester) async {
      seedRepo();
      await pumpTree(tester);

      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('studio-tree-filter')), 'read');
      await flush(tester);

      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('lib'), findsNothing,
          reason: 'a directory whose files all miss the filter must hide');
      expect(find.text('a.dart'), findsNothing);

      await tester.enterText(find.byKey(const Key('studio-tree-filter')), 'a.da');
      await flush(tester);

      expect(find.text('a.dart'), findsOneWidget,
          reason: 'filtering reveals matching children of collapsed folders');
      expect(find.text('b.dart'), findsNothing);
      expect(find.text('README.md'), findsNothing);

      await tester.enterText(find.byKey(const Key('studio-tree-filter')), '');
      await flush(tester);

      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('lib'), findsOneWidget);
    });

    testWidgets('a dirty decoration appears on the modified file row only',
        (tester) async {
      seedRepo();
      await pumpTree(tester);

      RepoCache.I.write('lib/a.dart', 'void a() { /* edited */ }\n');
      await flush(tester);

      await tester.tap(find.text('lib'));
      await flush(tester);

      expect(find.byKey(const Key('studio-dirty-lib/a.dart')), findsOneWidget,
          reason: 'a pending-commit file must be visibly marked');
      expect(find.byKey(const Key('studio-dirty-lib/b.dart')), findsNothing);
      expect(find.byKey(const Key('studio-dirty-README.md')), findsNothing);
      expect(find.byKey(const Key('studio-dirty-lib')), findsNothing,
          reason: 'directories never carry a file dirty marker');
    });

    testWidgets('the breadcrumb renders the active file path', (tester) async {
      seedRepo();
      await pumpTree(tester);

      expect(find.byKey(const Key('studio-tree-breadcrumb')), findsNothing,
          reason: 'no breadcrumb before a file is open');

      await tester.tap(find.text('lib'));
      await flush(tester);
      await tester.tap(find.text('a.dart'));
      await flush(tester);

      final crumb = find.byKey(const Key('studio-tree-breadcrumb'));
      expect(crumb, findsOneWidget);
      expect(
        find.descendant(of: crumb, matching: find.text('lib')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: crumb, matching: find.text('a.dart')),
        findsOneWidget,
      );
    });

    testWidgets('Changes panel: stage, inline diff, and discard a new file',
        (tester) async {
      seedRepo();
      await pumpTree(tester);

      expect(find.byKey(const Key('studio-changes-panel')), findsNothing,
          reason: 'a clean tree has no Changes panel');

      RepoCache.I.write('lib/new.dart', 'line one\nline two\n');
      await flush(tester);

      final panel = find.byKey(const Key('studio-changes-panel'));
      expect(panel, findsOneWidget);
      expect(find.text('new.dart'), findsOneWidget,
          reason: 'the changed file must be listed (lib/ stays collapsed)');
      expect(
        find.descendant(of: panel, matching: find.text('A')),
        findsOneWidget,
        reason: 'an untracked pending file is badged as added',
      );

      await tester.tap(find.byKey(const Key('studio-change-stage-lib/new.dart')));
      await flush(tester);
      expect(RepoCache.I.stagedMode('lib/new.dart'), '100644',
          reason: 'stage must flow through the existing staging contract');

      await tester.tap(find.byKey(const Key('studio-change-row-lib/new.dart')));
      await flush(tester);
      final diff = find.byKey(const Key('studio-change-diffview-lib/new.dart'));
      expect(diff, findsOneWidget, reason: 'tapping a change opens its diff');
      expect(
        find.descendant(of: diff, matching: find.textContaining('line one')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('studio-change-discard-lib/new.dart')));
      await tester.pumpAndSettle();
      expect(find.text('Discard'), findsWidgets,
          reason: 'discarding uncommitted work must confirm first');
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pumpAndSettle();

      expect(RepoCache.I.pendingPaths, isNot(contains('lib/new.dart')));
      expect(RepoCache.I.files.containsKey('lib/new.dart'), isFalse);
      expect(find.byKey(const Key('studio-changes-panel')), findsNothing,
          reason: 'with nothing pending the panel goes away');
    });

    testWidgets('Changes panel: a modified file diffs against the last synced '
        'content and has nothing destructive to discard', (tester) async {
      seedRepo();
      await pumpTree(tester);

      RepoCache.I.write('README.md', '# hi\nchanged line\n');
      await flush(tester);

      final row = find.byKey(const Key('studio-change-row-README.md'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
            of: find.byKey(const Key('studio-changes-panel')),
            matching: find.text('M')),
        findsOneWidget,
        reason: 'a synced-then-edited file is badged as modified',
      );

      await tester.tap(row);
      await flush(tester);
      final diff = find.byKey(const Key('studio-change-diffview-README.md'));
      expect(diff, findsOneWidget);
      expect(
        find.descendant(of: diff, matching: find.textContaining('changed line')),
        findsOneWidget,
        reason: 'the added line must render',
      );
      expect(
        tester
            .widgetList<Text>(find.descendant(
                of: diff, matching: find.byType(Text)))
            .any((t) => (t.data ?? '').startsWith('+')),
        isTrue,
        reason: 'added lines carry an explicit + gutter, not colour alone',
      );

      final discard = tester.widget<IconButton>(
          find.byKey(const Key('studio-change-discard-README.md')));
      expect(discard.onPressed, isNull,
          reason: 'a plain content edit is never silently destroyed; it is '
              'kept until commit, so discard stays disabled');

      await tester.tap(find.byKey(const Key('studio-change-stage-README.md')));
      await flush(tester);
      expect(RepoCache.I.stagedMode('README.md'), '100644');
    });

    testWidgets('Changes panel: a staged deletion is badged and diffs as '
        'fully removed', (tester) async {
      seedRepo();
      await pumpTree(tester);

      RepoCache.I.stageDeletion('lib/b.dart');
      await flush(tester);

      expect(
        find.descendant(
            of: find.byKey(const Key('studio-changes-panel')),
            matching: find.text('D')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('studio-change-row-lib/b.dart')));
      await flush(tester);
      final diff = find.byKey(const Key('studio-change-diffview-lib/b.dart'));
      expect(diff, findsOneWidget);
      expect(
        tester
            .widgetList<Text>(find.descendant(
                of: diff, matching: find.byType(Text)))
            .any((t) => (t.data ?? '').startsWith('-')),
        isTrue,
        reason: 'a staged deletion shows its last synced lines as removed',
      );
    });

    testWidgets('source-control tree fits 360x640 @2x and a wide panel',
        (tester) async {
      for (final config in [
        (const Size(360, 640), 2.0, 300.0),
        (const Size(1280, 800), 1.0, 420.0),
      ]) {
        useView(tester, config.$1, config.$2);
        seedRepo();
        RepoCache.I.write('lib/new.dart', 'line one\n');
        await pumpTree(tester, width: config.$3, height: config.$1.height);

        await tester.enterText(
            find.byKey(const Key('studio-tree-filter')), 'read');
        await flush(tester);
        expect(find.text('README.md'), findsOneWidget);
        await tester.enterText(find.byKey(const Key('studio-tree-filter')), '');
        await flush(tester);

        expect(find.byKey(const Key('studio-changes-panel')), findsOneWidget);
        await tester.tap(find.byKey(const Key('studio-change-row-lib/new.dart')));
        await flush(tester);
        expect(find.byKey(const Key('studio-change-diffview-lib/new.dart')),
            findsOneWidget);

        RepoCache.I.unbind();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    });
  });
}
