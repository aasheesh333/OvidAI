import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_tiles.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.l),
          child: child,
        ),
      ),
    );

void main() {
  group('tool state', () {
    test('maps the durable toolState tokens', () {
      expect(v2ToolStateOf('running'), V2ToolState.running);
      expect(v2ToolStateOf('ok'), V2ToolState.done);
      expect(v2ToolStateOf('error'), V2ToolState.failed);
      expect(v2ToolStateOf('stopped'), V2ToolState.stopped);
      expect(v2ToolStateOf('unknown'), V2ToolState.unknown);
      expect(v2ToolStateOf('Analyzing 4 systems', progress: 0.72), V2ToolState.running);
      expect(v2ToolStateOf('Analyzing 4 systems', progress: 1), V2ToolState.done);
    });

    test('turns tokens into human labels and keeps prose', () {
      expect(v2ToolStatusLabel('running', V2ToolState.running), 'Running');
      expect(v2ToolStatusLabel('ok', V2ToolState.done), 'Done');
      expect(v2ToolStatusLabel('error', V2ToolState.failed), 'Failed');
      expect(v2ToolStatusLabel('stopped', V2ToolState.stopped), 'Stopped');
      expect(
        v2ToolStatusLabel('Analyzing 4 design systems', V2ToolState.running),
        'Analyzing 4 design systems',
      );
    });

    test('maps artifact labels to real states', () {
      expect(v2ArtifactStateOf('Ready'), V2ArtifactState.ready);
      expect(v2ArtifactStateOf('generating'), V2ArtifactState.working);
      expect(v2ArtifactStateOf('Failed'), V2ArtifactState.failed);
      expect(v2ArtifactStateOf('14.2 KB'), V2ArtifactState.unknown);
    });
  });

  group('V2ThinkingTile', () {
    testWidgets('expands and collapses its details', (tester) async {
      var expanded = false;
      Widget build() => StatefulBuilder(
        builder: (context, setState) => V2ThinkingTile(
          label: 'Thinking process',
          details: const ['First thought', 'Second thought'],
          expanded: expanded,
          onToggle: () => setState(() => expanded = !expanded),
        ),
      );

      await tester.pumpWidget(_app(build()));
      expect(find.text('First thought'), findsNothing);

      await tester.tap(find.text('Thinking process'));
      await tester.pump();
      expect(find.text('First thought'), findsOneWidget);

      await tester.tap(find.text('Thinking process'));
      await tester.pump();
      expect(find.text('First thought'), findsNothing);
    });

    testWidgets('is not a button without a toggle handler', (tester) async {
      await tester.pumpWidget(
        _app(
          const V2ThinkingTile(
            label: 'Thinking',
            details: ['One'],
            expanded: false,
            onToggle: null,
          ),
        ),
      );
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });
  });

  group('V2ToolTile', () {
    testWidgets('running shows a progress bar, finished does not', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const V2ToolTile(
            title: 'Browsing',
            status: 'running',
            progress: 0.55,
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await tester.pumpWidget(
        _app(
          const V2ToolTile(title: 'Browsing', status: 'ok', progress: 1),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('shows the failed and stopped states honestly', (tester) async {
      await tester.pumpWidget(
        _app(const V2ToolTile(title: 'Deploy', status: 'error', progress: 1)),
      );
      expect(find.text('Failed'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.pumpWidget(
        _app(const V2ToolTile(title: 'Deploy', status: 'stopped', progress: 1)),
      );
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    });

    testWidgets('expands its details', (tester) async {
      var expanded = false;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => V2ToolTile(
              title: 'Search',
              status: 'ok',
              progress: 1,
              details: const ['3 results'],
              expanded: expanded,
              onToggle: () => setState(() => expanded = !expanded),
            ),
          ),
        ),
      );
      expect(find.text('3 results'), findsNothing);
      await tester.tap(find.text('Search'));
      await tester.pump();
      expect(find.text('3 results'), findsOneWidget);
      expect(find.text('Status: Done'), findsOneWidget);
    });
  });

  group('V2ArtifactTile', () {
    testWidgets('status pill matches the real state', (tester) async {
      Future<void> pumpLabel(String label) => tester.pumpWidget(
        _app(
          V2ArtifactTile(
            fileName: 'portfolio.html',
            meta: '14 KB',
            statusLabel: label,
            previewLabel: 'Preview',
            onOpen: () {},
          ),
        ),
      );

      await pumpLabel('Ready');
      expect(
        tester.widget<OPill>(find.byType(OPill)).tone,
        OPillTone.success,
      );

      await pumpLabel('Generating');
      expect(tester.widget<OPill>(find.byType(OPill)).tone, OPillTone.accent);

      await pumpLabel('Failed');
      expect(tester.widget<OPill>(find.byType(OPill)).tone, OPillTone.danger);
    });

    testWidgets('tapping the card opens it; download appears only when wired', (
      tester,
    ) async {
      var opens = 0;
      var downloads = 0;
      await tester.pumpWidget(
        _app(
          V2ArtifactTile(
            fileName: 'portfolio.html',
            meta: '14 KB',
            statusLabel: 'Ready',
            previewLabel: 'Preview',
            onOpen: () => opens++,
            onDownload: () => downloads++,
          ),
        ),
      );

      await tester.tap(find.text('portfolio.html'));
      expect(opens, 1);
      await tester.tap(find.text('Download'));
      expect(downloads, 1);

      await tester.pumpWidget(
        _app(
          V2ArtifactTile(
            fileName: 'portfolio.html',
            meta: '14 KB',
            statusLabel: 'Ready',
            previewLabel: 'Preview',
            onOpen: () {},
          ),
        ),
      );
      expect(find.text('Download'), findsNothing);
    });

    testWidgets('the default detail route opens with the real file name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => OButton(
              label: 'Open artifact',
              onPressed: () => openV2ArtifactDetail(
                context,
                fileName: 'portfolio.html',
                meta: '14.2 KB',
                statusLabel: 'Ready',
                previewLabel: 'Interactive canvas',
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open artifact'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ArtifactDetailPage), findsOneWidget);
      expect(find.text('portfolio.html'), findsWidgets);

      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.text('Interactive canvas'), findsWidgets);
    });
  });

  testWidgets('tiles lay out at 320 dp and 200 % text in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        _app(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const V2ThinkingTile(
                label:
                    'Thinking about a very long unbroken label '
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                details: [
                  'https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                ],
                expanded: true,
                onToggle: null,
              ),
              const SizedBox(height: OSpace.m),
              const V2ToolTile(
                title: 'Searching aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                status: 'running',
                progress: 0.5,
                expanded: true,
                onToggle: null,
              ),
              const SizedBox(height: OSpace.m),
              V2ArtifactTile(
                fileName:
                    'a-very-long-artifact-file-name-that-needs-to-wrap.html',
                meta: '14.2 KB · Just generated',
                statusLabel: 'Ready',
                previewLabel: 'Interactive HTML5 canvas preview',
                onOpen: () {},
                onDownload: () {},
              ),
            ],
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.takeException(),
        isNull,
        reason: 'tile overflow at 320 dp / 200 % (${dark ? 'dark' : 'light'})',
      );
    }
  });
}
