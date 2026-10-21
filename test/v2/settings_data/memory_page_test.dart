import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

V2MemoryPageData _data({
  ValueChanged<bool>? onMemoryEnabledChanged,
  ValueChanged<bool>? onShareSessionMemoryChanged,
  VoidCallback? onEditGlobal,
  VoidCallback? onExport,
  VoidCallback? onResetAll,
}) {
  return V2MemoryPageData(
    memoryEnabled: true,
    shareSessionMemory: false,
    globalMemory: const [
      'Prefers plain English.',
      'Works as a product designer.',
    ],
    globalVersionLabel: 'Ovid Core v2.4',
    projects: const [
      V2MemoryProject(
        id: 'p1',
        name: 'Mobile App Redesign',
        detail: '4 rules · Synced 1h ago',
      ),
    ],
    sessionFiles: const [
      V2MemoryFile(
        id: 'f1',
        name: 'architecture-spec.md',
        detail: '42 KB · Markdown',
      ),
    ],
    onMemoryEnabledChanged: onMemoryEnabledChanged,
    onShareSessionMemoryChanged: onShareSessionMemoryChanged,
    onEditGlobal: onEditGlobal,
    onExport: onExport,
    onResetAll: onResetAll,
  );
}

void main() {
  testWidgets('renders the memory controls in light mode', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Memory on'), findsOneWidget);
    expect(find.text('Share session memory'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsOneWidget);
    expect(find.text('1 file cached'), findsOneWidget);
    expect(find.text('Ovid Core v2.4'), findsOneWidget);
    expect(find.text('Export memory'), findsOneWidget);
    expect(find.text('Reset all memory'), findsOneWidget);
  });

  testWidgets('ships no fabricated memory version label', (tester) async {
    await tester.pumpWidget(
      _app(
        const MemoryPage(
          data: V2MemoryPageData(globalMemory: ['Prefers plain English.']),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Ovid Core'), findsNothing);
    expect(find.text('Prefers plain English.'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory on'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsOneWidget);
  });

  testWidgets('empty state offers a way to add a memory', (tester) async {
    var added = false;
    await tester.pumpWidget(
      _app(
        MemoryPage(data: V2MemoryPageData(onEditGlobal: () => added = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memories yet'), findsOneWidget);
    await tester.tap(find.text('Add a memory'));
    expect(added, isTrue);
  });

  testWidgets('empty state can turn memory back on', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            memoryEnabled: false,
            onMemoryEnabledChanged: (value) => next = value,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memories yet'), findsOneWidget);
    await tester.tap(find.text('Turn on memory'));
    expect(next, isTrue);
  });

  testWidgets('export fires the primary callback', (tester) async {
    var exported = false;
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onExport: () => exported = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Export memory'));
    await tester.tap(find.text('Export memory'));
    expect(exported, isTrue);
  });

  testWidgets('memory switch reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(onMemoryEnabledChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-master-switch')),
    );
    expect(next, isFalse);
  });

  testWidgets('share session memory switch reports the new value', (
    tester,
  ) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(onShareSessionMemoryChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-share-session-switch')),
    );
    expect(next, isTrue);
  });

  testWidgets('session section explains when no files are cached', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: const V2MemoryPageData(
            globalMemory: ['Prefers plain English.'],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 files cached'), findsOneWidget);
    expect(
      find.textContaining('No files are cached for this chat.'),
      findsOneWidget,
    );
  });

  testWidgets('lays out at 320 dp with 200 % text in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final states = <String, V2MemoryPageData>{
      'content': _data(),
      'empty': const V2MemoryPageData(),
      'error': const V2MemoryPageData(
        errorMessage: 'Memory could not load right now.',
      ),
    };

    for (final theme in [OTheme.light(), OTheme.dark()]) {
      for (final state in states.entries) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: MemoryPage(data: state.value),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: state.key);

        // No paragraph may be laid out wider than the screen. A title in an
        // unbounded Row used to measure 358 dp here and paint off-screen.
        for (final paragraph in tester
            .allRenderObjects
            .whereType<RenderParagraph>()) {
          final left = paragraph.localToGlobal(Offset.zero).dx;
          expect(left, greaterThanOrEqualTo(-0.5), reason: state.key);
          expect(
            left + paragraph.size.width,
            lessThanOrEqualTo(320.5),
            reason: state.key,
          );
        }
      }
    }

    // Content-state details, on the tree from the last iteration.
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: MemoryPage(data: _data()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Labels must keep a readable share of their row instead of being
    // squeezed by the trailing count or action.
    for (final label in const [
      'ACTIVE PREFERENCES',
      'GLOBAL MEMORY',
      'PROJECT MEMORY',
      'SESSION FILES',
    ]) {
      final width = tester
          .renderObject<RenderParagraph>(find.text(label))
          .size
          .width;
      expect(width, greaterThan(150), reason: '$label is squeezed');
    }

    // Long file names wrap to two lines and then ellipsize instead of
    // painting over the download control.
    final name = tester.widget<Text>(find.text('architecture-spec.md'));
    expect(name.maxLines, 2);
    expect(name.overflow, TextOverflow.ellipsis);

    // Everything stays reachable.
    await tester.scrollUntilVisible(find.text('Reset all memory'), 300);
    expect(find.text('Reset all memory'), findsOneWidget);
  });

  testWidgets('shows a skeleton while memory loads', (tester) async {
    await tester.pumpWidget(
      _app(
        const MemoryPage(data: V2MemoryPageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Export memory'), findsNothing);
  });

  testWidgets('disabled memory switch is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const MemoryPage(
          data: V2MemoryPageData(globalMemory: ['Prefers plain English.']),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final data = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('memory-master-toggle')),
        )
        .getSemanticsData();
    handle.dispose();

    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
  });

  testWidgets('project row and file download fire their callbacks', (
    tester,
  ) async {
    String? tappedProject;
    String? downloadedFile;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            globalMemory: const ['Prefers plain English.'],
            projects: const [
              V2MemoryProject(id: 'p1', name: 'Mobile App Redesign', detail: '4 rules'),
            ],
            sessionFiles: const [
              V2MemoryFile(
                id: 'f1',
                name: 'architecture-spec.md',
                detail: '42 KB',
              ),
            ],
            onProjectTap: (id) => tappedProject = id,
            onFileDownload: (id) => downloadedFile = id,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Mobile App Redesign'));
    await tester.tap(find.text('Mobile App Redesign'));
    expect(tappedProject, 'p1');

    final download = find.byWidgetPredicate(
      (widget) =>
          widget is OIconButton &&
          widget.semanticLabel == 'Download architecture-spec.md',
    );
    await tester.ensureVisible(download);
    await tester.tap(download);
    expect(downloadedFile, 'f1');
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            errorMessage: 'Memory could not load right now.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory could not load right now.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });
}
