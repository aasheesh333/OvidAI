import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/code_viewer.dart';

Widget _app(Widget child, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: child);

V2CodeViewerData _file({int count = 12, String name = 'main.dart'}) {
  return V2CodeViewerData(
    fileName: name,
    filePath: 'lib/src/$name',
    lines: [
      for (var i = 1; i <= count; i++)
        V2CodeViewerLine(text: 'final line$i = $i;', number: i),
    ],
  );
}

V2CodeViewerData _huge({int count = 30, int limit = 10}) {
  return V2CodeViewerData(
    fileName: 'generated.dart',
    lineLimit: limit,
    lines: [
      for (var i = 1; i <= count; i++)
        V2CodeViewerLine(text: 'generated $i;', number: i),
    ],
  );
}

const _diff = V2CodeViewerData(
  fileName: 'demo.dart',
  filePath: 'lib/demo.dart',
  diff: true,
  lines: <V2CodeViewerLine>[
    V2CodeViewerLine(text: 'class Demo {', oldNumber: 1, newNumber: 1),
    V2CodeViewerLine(
      text: 'final old = 2;',
      kind: V2CodeViewerLineKind.removed,
      oldNumber: 2,
    ),
    V2CodeViewerLine(
      text: 'final next = 3;',
      kind: V2CodeViewerLineKind.added,
      newNumber: 2,
    ),
    V2CodeViewerLine(text: '}', oldNumber: 3, newNumber: 3),
  ],
);

void main() {
  testWidgets('renders a read-only file with line numbers in both themes', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(V2CodeViewerPage(data: _file()), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      // The header is the only chrome: no read-only pill, no type, no count.
      expect(find.text('Read only'), findsNothing);
      expect(find.text('DART'), findsNothing);
      expect(find.text('12 lines'), findsNothing);
      expect(find.text('final line1 = 1;'), findsOneWidget);
      expect(find.text('final line12 = 12;'), findsOneWidget);
      expect(find.byKey(const Key('v2-code-viewer-surface')), findsOneWidget);
    }
  });

  testWidgets('numbers plain lines that arrive without numbers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2CodeViewerPage(
          data: V2CodeViewerData(
            fileName: 'notes.txt',
            lines: <V2CodeViewerLine>[
              V2CodeViewerLine(text: 'alpha'),
              V2CodeViewerLine(text: 'beta'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('copy is wired, disabled for empty content, absent when unwired', (
    tester,
  ) async {
    var copies = 0;
    await tester.pumpWidget(
      _app(V2CodeViewerPage(data: _file(), onCopy: () => copies++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('v2-code-viewer-copy')));
    expect(copies, 1);

    final handle = tester.ensureSemantics();
    // Wired but nothing to copy: disabled, not a dead enabled control.
    await tester.pumpWidget(
      _app(
        V2CodeViewerPage(
          data: const V2CodeViewerData(status: V2CodeViewerStatus.empty),
          onCopy: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byKey(const Key('v2-code-viewer-copy'))),
      isSemantics(isButton: true, isEnabled: false),
    );

    // No handler at all: the action is removed rather than shown disabled.
    await tester.pumpWidget(
      _app(
        const V2CodeViewerPage(
          data: V2CodeViewerData(status: V2CodeViewerStatus.empty),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('v2-code-viewer-copy')), findsNothing);
    handle.dispose();
  });

  testWidgets('long lines do not wrap and the surface scrolls horizontally', (
    tester,
  ) async {
    final longLine = 'final value = ${'x' * 240};';
    await tester.pumpWidget(
      _app(
        V2CodeViewerPage(
          data: V2CodeViewerData(
            fileName: 'wide.dart',
            lines: <V2CodeViewerLine>[V2CodeViewerLine(text: longLine)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final code = tester.widget<Text>(find.text(longLine));
    expect(code.softWrap, isFalse);
    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((view) => view.scrollDirection == Axis.horizontal);
    expect(horizontal, isNotEmpty);
  });

  testWidgets('caps a huge file and offers an external open', (tester) async {
    final handle = tester.ensureSemantics();
    var opens = 0;
    await tester.pumpWidget(
      _app(
        V2CodeViewerPage(
          data: V2CodeViewerData(
            fileName: 'generated.dart',
            lineLimit: 10,
            lines: [
              for (var i = 1; i <= 30; i++)
                V2CodeViewerLine(text: 'generated $i;', number: i),
            ],
          ),
          onOpenExternally: () => opens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('10 of 30 lines'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Large file. Showing the first 10 of 30 lines.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('v2-code-line-10')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-code-line-11')), findsNothing);
    expect(find.text('generated 10;'), findsOneWidget);
    expect(find.text('generated 11;'), findsNothing);

    await tester.tap(find.byKey(const Key('v2-code-viewer-open-externally')));
    expect(opens, 1);
    handle.dispose();
  });

  testWidgets('diff mode marks added and removed lines', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(V2CodeViewerPage(data: _diff, onCopy: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('demo.dart'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
    expect(find.text('−'), findsOneWidget);
    expect(find.text('final old = 2;'), findsOneWidget);
    expect(find.text('final next = 3;'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Removed line 2: final old = 2;'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Added line 2: final next = 3;'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Copy diff'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('diff mode numbers lines it has to infer', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const V2CodeViewerPage(
          data: V2CodeViewerData(
            fileName: 'inferred.dart',
            diff: true,
            lines: <V2CodeViewerLine>[
              V2CodeViewerLine(text: 'one'),
              V2CodeViewerLine(
                text: 'two removed',
                kind: V2CodeViewerLineKind.removed,
              ),
              V2CodeViewerLine(
                text: 'two added',
                kind: V2CodeViewerLineKind.added,
              ),
              V2CodeViewerLine(text: 'three'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Line 1: one'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Removed line 2: two removed'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Added line 2: two added'), findsOneWidget);
    expect(find.bySemanticsLabel('Line 3: three'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('external open is absent when it is not wired', (tester) async {
    await tester.pumpWidget(_app(V2CodeViewerPage(data: _huge())));
    await tester.pumpAndSettle();

    // The cap is still explained; the dead button is gone.
    expect(find.text('10 of 30 lines'), findsOneWidget);
    expect(
      find.byKey(const Key('v2-code-viewer-open-externally')),
      findsNothing,
    );
  });

  testWidgets('loading, empty and error states stay reachable', (tester) async {
    await tester.pumpWidget(
      _app(
        const V2CodeViewerPage(
          data: V2CodeViewerData(status: V2CodeViewerStatus.loading),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(OSkeletonList), findsOneWidget);

    var backs = 0;
    await tester.pumpWidget(
      _app(
        V2CodeViewerPage(
          data: const V2CodeViewerData(status: V2CodeViewerStatus.empty),
          onBack: () => backs++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No file selected'), findsOneWidget);
    await tester.tap(find.text('Back to workspace'));
    expect(backs, 1);

    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2CodeViewerPage(
          data: const V2CodeViewerData(
            status: V2CodeViewerStatus.error,
            errorMessage: 'This file is unavailable.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('This file is unavailable.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('320 dp at 200 % text does not overflow in either mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      for (final data in <V2CodeViewerData>[_file(count: 30), _diff, _huge()]) {
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: _app(V2CodeViewerPage(data: data), dark: dark),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(data.fileName), findsOneWidget);
      }
    }
  });
}
