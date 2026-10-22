
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/session_artifacts.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_tiles.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';

/// A real 1×1 PNG, so the thumbnail test decodes instead of hitting the
/// network.
final Uint8List _pngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tool state', () {
    test('maps the durable toolState tokens', () {
      expect(v2ToolStateOf('running'), V2ToolState.running);
      expect(v2ToolStateOf('ok'), V2ToolState.done);
      expect(v2ToolStateOf('error'), V2ToolState.failed);
      expect(v2ToolStateOf('stopped'), V2ToolState.stopped);
      expect(v2ToolStateOf('unknown'), V2ToolState.unknown);
      expect(
        v2ToolStateOf('Analyzing 4 systems', progress: 0.72),
        V2ToolState.running,
      );
      expect(
        v2ToolStateOf('Analyzing 4 systems', progress: 1),
        V2ToolState.done,
      );
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
        _app(const V2ToolTile(title: 'Browsing', status: 'ok', progress: 1)),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Done'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('shows the failed and stopped states honestly', (tester) async {
      await tester.pumpWidget(
        _app(const V2ToolTile(title: 'Deploy', status: 'error', progress: 1)),
      );
      expect(find.text('Failed'), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      await tester.pumpWidget(
        _app(const V2ToolTile(title: 'Deploy', status: 'stopped', progress: 1)),
      );
      expect(find.text('Stopped'), findsNothing);
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
      // The glyph carries the outcome; the detail pane does not restate it.
      expect(find.text('Status: Done'), findsNothing);
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
      // "Ready" is the default; it repeats the row and is not shown.
      expect(find.byType(OPill), findsNothing);

      await pumpLabel('Generating');
      expect(tester.widget<OPill>(find.byType(OPill)).tone, OPillTone.accent);

      await pumpLabel('Failed');
      expect(tester.widget<OPill>(find.byType(OPill)).tone, OPillTone.danger);
    });

    testWidgets(
      'tapping the card opens it; the menu owns Preview and Download',
      (tester) async {
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

        // The row has one menu, not a second icon per action.
        await tester.tap(find.bySemanticsLabel('Actions for portfolio.html'));
        await tester.pumpAndSettle();
        expect(find.text('Preview'), findsOneWidget);
        expect(find.text('Download'), findsOneWidget);
        expect(find.text('Copy'), findsNothing);

        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        expect(downloads, 1);
        // The menu action is its own control: the row must not also open.
        expect(opens, 1);

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
        expect(
          find.bySemanticsLabel('Actions for portfolio.html'),
          findsNothing,
          reason: 'no action is wired, so the row offers no menu',
        );
      },
    );

    testWidgets('the menu Preview opens the detail route', (tester) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => V2ArtifactTile(
              fileName: 'portfolio.html',
              meta: '14 KB',
              statusLabel: 'Ready',
              previewLabel: 'Preview',
              onOpen: () => openV2ArtifactDetail(
                context,
                fileName: 'portfolio.html',
                meta: '14 KB',
                statusLabel: 'Ready',
                previewLabel: 'Preview',
              ),
              onCopy: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Actions for portfolio.html'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ArtifactDetailPage), findsOneWidget);
    });

    testWidgets('Copy runs its real handler; the link label is honest', (
      tester,
    ) async {
      var copies = 0;
      Future<void> pump({required bool copyText}) => tester.pumpWidget(
        _app(
          V2ArtifactTile(
            fileName: 'diagram.png',
            meta: 'Image',
            statusLabel: 'Ready',
            previewLabel: 'Preview',
            copyText: copyText,
            onOpen: () {},
            onCopy: () => copies++,
          ),
        ),
      );

      await pump(copyText: true);
      await tester.tap(find.bySemanticsLabel('Actions for diagram.png'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copies, 1);

      // An image has no text to copy, so the menu says what it really does.
      await pump(copyText: false);
      await tester.tap(find.bySemanticsLabel('Actions for diagram.png'));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('a real thumbnail replaces the glyph, a missing one keeps it', (
      tester,
    ) async {
      Widget tile({ImageProvider? thumbnail}) => _app(
        V2ArtifactTile(
          fileName: 'diagram.png',
          meta: 'Image',
          statusLabel: 'Ready',
          previewLabel: 'Preview',
          icon: Icons.image_outlined,
          thumbnail: thumbnail,
          onOpen: () {},
        ),
      );

      await tester.pumpWidget(tile(thumbnail: MemoryImage(_pngBytes)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsNothing);

      await tester.pumpWidget(tile());
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
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

    testWidgets('the detail route carries the real size and text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => OButton(
              label: 'Open artifact',
              onPressed: () => openV2ArtifactDetail(
                context,
                fileName: 'notes.md',
                meta: 'Generated',
                statusLabel: 'Ready',
                previewLabel: 'Markdown',
                kind: ArtifactKind.document,
                sizeBytes: 14540,
                content: '# Real heading',
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open artifact'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ArtifactDetailPage), findsOneWidget);
      // The document preview shows the file's real text, and the metadata
      // reports the size the host passed.
      expect(
        find.textContaining('Real heading', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.text('14.2 KB'), findsWidgets);
    });
  });

  group('artifact copy', () {
    String? copied;

    setUp(() {
      copied = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('copies the inline text without a fetch', () async {
      final result = await v2CopyArtifactContent(
        fileName: 'preview.html',
        content: '<h1>Real page</h1>',
        url: 'https://files.example.com/preview.html',
        kind: ArtifactKind.html,
        client: MockClient((_) async => throw StateError('no fetch expected')),
      );

      expect(result, V2ArtifactCopyResult.text);
      expect(copied, '<h1>Real page</h1>');
    });

    test('fetches the file head when only a URL is known', () async {
      final result = await v2CopyArtifactContent(
        fileName: 'main.dart',
        url: 'https://files.example.com/main.dart',
        kind: ArtifactKind.code,
        client: MockClient(
          (request) async => http.Response('void main() {}', 200),
        ),
      );

      expect(result, V2ArtifactCopyResult.text);
      expect(copied, 'void main() {}');
    });

    test('copies the link for an image', () async {
      final result = await v2CopyArtifactContent(
        fileName: 'diagram.png',
        url: 'https://files.example.com/diagram.png',
        kind: ArtifactKind.image,
        client: MockClient((_) async => throw StateError('no fetch expected')),
      );

      expect(result, V2ArtifactCopyResult.link);
      expect(copied, 'https://files.example.com/diagram.png');
    });

    test('a failed fetch still copies the link', () async {
      final result = await v2CopyArtifactContent(
        fileName: 'main.dart',
        url: 'https://files.example.com/main.dart',
        kind: ArtifactKind.code,
        client: MockClient((_) async => http.Response('nope', 500)),
      );

      expect(result, V2ArtifactCopyResult.link);
      expect(copied, 'https://files.example.com/main.dart');
    });

    test('nothing to copy is reported, never faked', () async {
      final result = await v2CopyArtifactContent(
        fileName: 'diagram.png',
        kind: ArtifactKind.image,
      );

      expect(result, V2ArtifactCopyResult.failed);
      expect(copied, isNull);
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
