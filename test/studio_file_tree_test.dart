import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/cloud/studio_files.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_file_tree.dart';
import 'package:ovid_ai/ui/studio_layout.dart';

import 'support/studio_fake_gateway.dart';

/// Studio file tree, re-pointed at the P7 workspace manifest.
///
/// The old path-set heuristic (and its `buildStudioTree` helper) is gone: the
/// server's nested `FileNode` tree is authoritative. These tests keep the
/// surviving directory rules and pin the regression the deleted
/// `studio_file_tree_test.dart:175` would have caught — tapping a folder must
/// render its children.
FileNode _file(String path) => FileNode(
      name: path.split('/').last,
      path: path,
      kind: 'file',
    );

FileNode _dir(String path, List<FileNode> children) => FileNode(
      name: path.split('/').last,
      path: path,
      kind: 'dir',
      children: children,
    );

void main() {
  group('flattenStudioTree derives rows from the server manifest', () {
    test('a null root yields no nodes', () {
      expect(flattenStudioTree(null, const {}), isEmpty);
    });

    test('top level lists directories before files', () {
      final root = _dir('', [
        _file('README.md'),
        _dir('lib', [_file('lib/b.dart'), _file('lib/a.dart')]),
      ]);
      final nodes = flattenStudioTree(root, const {});
      expect(nodes.map((n) => n.name).toList(), ['lib', 'README.md']);
      expect(nodes.first.isDirectory, isTrue);
      expect(nodes.first.depth, 0);
      expect(nodes.last.isDirectory, isFalse);
    });

    test('collapsed directories hide their children', () {
      final root = _dir('', [
        _dir('lib', [_file('lib/b.dart'), _file('lib/a.dart')]),
        _file('README.md'),
      ]);
      final nodes = flattenStudioTree(root, const {});
      expect(nodes.map((n) => '${n.depth}:${n.name}').toList(),
          ['0:lib', '0:README.md']);
      expect(nodes.any((n) => n.name == 'a.dart'), isFalse);
    });

    test('expanded directories reveal their children', () {
      final root = _dir('', [
        _dir('lib', [_file('lib/b.dart'), _file('lib/a.dart')]),
        _file('README.md'),
      ]);
      final nodes = flattenStudioTree(root, const {'lib'});
      expect(
        nodes.map((n) => '${n.depth}:${n.name}').toList(),
        ['0:lib', '1:a.dart', '1:b.dart', '0:README.md'],
      );
    });

    test('nested expansion keeps the depth chain', () {
      final root = _dir('', [
        _dir('lib', [
          _dir('lib/ui', [_file('lib/ui/a.dart')]),
          _file('lib/b.dart'),
        ]),
      ]);
      final nodes = flattenStudioTree(root, const {'lib', 'lib/ui'});
      expect(
        nodes.map((n) => '${n.depth}:${n.name}').toList(),
        ['0:lib', '1:ui', '2:a.dart', '1:b.dart'],
      );
    });

    test('an empty directory is still a directory', () {
      // The old path-set heuristic could not see an empty directory at all.
      final root = _dir('', [_dir('vendor', const [])]);
      final nodes = flattenStudioTree(root, const {});
      expect(nodes, hasLength(1));
      expect(nodes.single.path, 'vendor');
      expect(nodes.single.isDirectory, isTrue);
    });

    // ST-015: a folder the <5 KB manifest pruned used to expand to nothing.
    test('an expanded pruned folder ends with a "Show N more" row', () {
      final root = _dir('', [
        const FileNode(
          name: 'big',
          path: 'big',
          kind: 'dir',
          files: 40,
          dirs: 2,
        ),
        FileNode(
          name: 'partial',
          path: 'partial',
          kind: 'dir',
          omitted: 7,
          children: [_file('partial/a.ts')],
        ),
      ]);
      final collapsed = flattenStudioTree(root, const {});
      expect(collapsed.any((n) => n.isMore), isFalse);

      final nodes = flattenStudioTree(root, const {'big', 'partial'});
      expect(
        nodes.map((n) => '${n.depth}:${n.isMore ? 'more(${n.hiddenCount})' : n.name}'),
        ['0:big', '1:more(42)', '0:partial', '1:a.ts', '1:more(7)'],
      );
      final loaded = flattenStudioTree(root, const {'big', 'partial'},
          loadedDirs: const {'partial'});
      expect(loaded.where((n) => n.isMore).map((n) => n.path), ['big']);
    });

    test('sorting inside a level is case-insensitive and stable', () {
      final root = _dir('', [
        _dir('d', [
          _file('d/B.dart'),
          _file('d/a.dart'),
          _file('d/C.dart'),
          _dir('d/zebra', [_file('d/zebra/a.txt')]),
          _dir('d/Alpha', [_file('d/Alpha/b.txt')]),
        ]),
      ]);
      final nodes = flattenStudioTree(root, const {'d'});
      expect(
        nodes.map((n) => n.name).toList(),
        ['d', 'Alpha', 'zebra', 'a.dart', 'B.dart', 'C.dart'],
      );
    });
  });

  group('StudioFileTree widget', () {
    late FakeStudioGateway fake;
    late StudioRemoteClient remote;

    FakeStudioGateway seed() => FakeStudioGateway(
          files: {
            'src/main.dart': 'void main() {}',
            'README.md': '# hi',
          },
          roots: [
            FakeNode.dir('src', [FakeNode.file('src/main.dart')]),
            FakeNode.file('README.md'),
          ],
        );

    Future<void> pumpTree(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const Scaffold(
            body: SizedBox(
              width: 300,
              height: 500,
              child: StudioFileTree(sessionId: kFakeStudioSession),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      fake = seed();
      remote = installFakeStudio(fake);
    });

    tearDown(() {
      remote.clearAll();
    });

    testWidgets('renders folders as folders and expands them on tap',
        (tester) async {
      await pumpTree(tester);

      expect(find.text('src'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('main.dart'), findsNothing,
          reason: 'a collapsed folder must not leak its children');
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      // HIGH-1: the snapshot identity does not change on expansion, so a
      // cache keyed only on the snapshot used to return the stale rows.
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget,
          reason: 'expansion must be visible without colour alone');
      expect(find.byIcon(Icons.folder_outlined), findsNothing);

      // Collapsing hides them again.
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      expect(find.text('main.dart'), findsNothing);
    });

    testWidgets('tapping a file opens it as a tab', (tester) async {
      await pumpTree(tester);

      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(remote.openFiles(kFakeStudioSession), contains('README.md'));
      expect(remote.fileBuffer(kFakeStudioSession)['README.md'], '# hi');
    });

    testWidgets('rows meet the 44dp tap-target invariant', (tester) async {
      await pumpTree(tester);

      final targets = find.byType(StudioTapTarget);
      expect(targets, findsWidgets);
      for (final element in targets.evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget).first);
        expect(size.height, greaterThanOrEqualTo(kStudioTapTarget));
        expect(size.width, greaterThanOrEqualTo(kStudioTapTarget));
      }
    });

    testWidgets('a failed fetch is visibly distinct from an empty file',
        (tester) async {
      // The manifest advertises the file, but the read 404s.
      fake = FakeStudioGateway(
        files: const {},
        roots: [FakeNode.file('ghost.dart')],
      );
      remote = installFakeStudio(fake);
      await pumpTree(tester);

      await tester.tap(find.text('ghost.dart'));
      await tester.pumpAndSettle();

      expect(remote.openFiles(kFakeStudioSession), isNot(contains('ghost.dart')),
          reason: 'a failed fetch must not masquerade as an empty file');
      expect(find.byIcon(Icons.error_outline), findsOneWidget,
          reason: 'the row must carry a visible failure affordance');
    });

    testWidgets('the failed row is labelled for screen readers',
        (tester) async {
      fake = FakeStudioGateway(
        files: const {},
        roots: [FakeNode.file('ghost.dart')],
      );
      remote = installFakeStudio(fake);
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

    testWidgets('an empty manifest shows the empty state, not a broken tree',
        (tester) async {
      fake = FakeStudioGateway(files: const {}, roots: const []);
      remote = installFakeStudio(fake);
      await pumpTree(tester);
      expect(find.textContaining('No files yet'), findsOneWidget);
    });
  });
}
