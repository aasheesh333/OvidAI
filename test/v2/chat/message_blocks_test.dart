import 'dart:io';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';

Widget _app(Widget home, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

Widget _blocksApp(
  String markdown, {
  bool dark = false,
  double textScale = 1,
  ValueChanged<String>? onCopyCode,
  ValueChanged<String>? onOpenLink,
  ValueChanged<String>? onDownload,
}) => _app(
  Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: V2MessageBlocks(
        markdown: markdown,
        onCopyCode: onCopyCode,
        onOpenLink: onOpenLink,
        onDownload: onDownload,
      ),
    ),
  ),
  dark: dark,
  textScale: textScale,
);

void _narrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const _parserMarkdown = r'''
# Release notes

Intro with **bold** and `code`.

- One
- Two
  - Nested

1. First
2. Second

```dart
void main() {}
```

```mermaid
flowchart LR
  A --> B
```

![Hero](https://images.example.com/hero.png)

[report.pdf](https://files.example.com/report.pdf)
[Download assets](https://example.com/assets)
[Open docs](https://docs.example.com)
https://example.com/raw.pdf
''';

const _kitchenSink = r'''
# Build complete

I designed **Vortex Studio** with `Flutter`.

- Dark mode
- Projects
  - Nested card with a long label that must wrap on a narrow screen
    - Deeper note

1. Clone the repository and install dependencies

```dart
void main() {
  runApp(const OvidApp());
}
```

```mermaid
flowchart LR
  A[Brief] --> B[Build]
```

![A very wide screenshot of the portfolio landing page](https://images.example.com/very/long/path/hero.png)

[a-very-long-artifact-file-name-that-needs-to-wrap.pdf](https://files.example.com/a-very-long-artifact-file-name-that-needs-to-wrap.pdf)

[Download the full brand kit and source files](https://example.com/assets/without-extension)

[Open the live preview of the portfolio](https://example.com/demo)

https://docs.example.com/a/very/long/path/that/does/not/end/in/a/file

---

Final note with an inline [link](https://example.com/docs).
''';

void main() {
  group('parseV2MessageBlocks', () {
    test('parses headings, lists, code, diagrams, images and links', () {
      final blocks = parseV2MessageBlocks(_parserMarkdown);

      expect(blocks, hasLength(10));

      final heading = blocks[0] as V2HeadingBlock;
      expect(heading.level, 1);
      expect(heading.text, 'Release notes');

      final paragraph = blocks[1] as V2ParagraphBlock;
      expect(paragraph.text, 'Intro with **bold** and `code`.');

      final bullets = blocks[2] as V2BulletListBlock;
      expect(bullets.ordered, isFalse);
      expect(bullets.items.map((item) => item.text), ['One', 'Two', 'Nested']);
      expect(bullets.items.last.depth, 1);

      final ordered = blocks[3] as V2BulletListBlock;
      expect(ordered.ordered, isTrue);
      expect(ordered.items.map((item) => item.text), ['First', 'Second']);

      final code = blocks[4] as V2CodeBlock;
      expect(code.language, 'dart');
      expect(code.code, 'void main() {}');

      final diagram = blocks[5] as V2DiagramBlock;
      expect(diagram.title, 'Flowchart');
      expect(diagram.source, contains('A --> B'));

      final image = blocks[6] as V2ImageBlock;
      expect(image.alt, 'Hero');
      expect(image.url, 'https://images.example.com/hero.png');

      final report = blocks[7] as V2FileBlock;
      expect(report.fileName, 'report.pdf');
      expect(report.href, 'https://files.example.com/report.pdf');

      final links = blocks[8] as V2DownloadLinksBlock;
      expect(links.links.map((link) => link.label), [
        'Download assets',
        'Open docs',
      ]);
      expect(links.links.first.isDownload, isTrue);
      expect(links.links.last.isDownload, isFalse);

      final bareFile = blocks[9] as V2FileBlock;
      expect(bareFile.fileName, 'raw.pdf');
    });

    test('joins soft-wrapped paragraphs and strips closing hashes', () {
      final blocks = parseV2MessageBlocks(
        'First line\nsecond line\r\n\r\n## Heading ##\r\n\r\n---\r\n',
      );

      expect((blocks[0] as V2ParagraphBlock).text, 'First line second line');
      expect((blocks[1] as V2HeadingBlock).text, 'Heading');
      expect(blocks[2], isA<V2DividerBlock>());
    });

    test('keeps an unclosed fence as a code block', () {
      final blocks = parseV2MessageBlocks('```python\nprint("hi")');

      expect(blocks.single, isA<V2CodeBlock>());
      final code = blocks.single as V2CodeBlock;
      expect(code.language, 'python');
      expect(code.code, 'print("hi")');
    });

    test('version-like labels stay links, file hrefs become cards', () {
      final blocks = parseV2MessageBlocks(
        '[v1.2](https://example.com)\n\n'
        '[Data](https://example.com/data.csv)',
      );

      expect(blocks[0], isA<V2DownloadLinksBlock>());
      final link = (blocks[0] as V2DownloadLinksBlock).links.single;
      expect(link.isDownload, isFalse);
      expect((blocks[1] as V2FileBlock).fileName, 'data.csv');
    });
  });

  group('V2MessageBlocks', () {
    testWidgets('renders headings, bullets and inline emphasis', (
      tester,
    ) async {
      await tester.pumpWidget(
        _blocksApp(
          '# Release notes\n\n'
          'Built **Vortex Studio** with `Flutter`.\n\n'
          '- Dark mode\n'
          '- Projects',
        ),
      );
      await tester.pump();

      expect(find.text('Release notes', findRichText: true), findsOneWidget);
      expect(
        find.textContaining(
          'Built Vortex Studio with Flutter',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Dark mode', findRichText: true), findsOneWidget);
      expect(find.text('Projects', findRichText: true), findsOneWidget);

      final rich = tester.widgetList<RichText>(find.byType(RichText));
      final bold = rich.any((widget) {
        var found = false;
        widget.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == 'Vortex Studio' &&
              span.style?.fontWeight == FontWeight.w600) {
            found = true;
          }
          return !found;
        });
        return found;
      });
      expect(bold, isTrue, reason: 'inline bold should stay bold');
    });

    testWidgets('code block copies and confirms for two seconds', (
      tester,
    ) async {
      String? copied;
      await tester.pumpWidget(
        _blocksApp(
          '```dart\nvoid main() {}\n```',
          onCopyCode: (code) => copied = code,
        ),
      );
      await tester.pump();

      expect(find.text('DART'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Copy code'));
      await tester.pump();

      expect(copied, 'void main() {}');
      expect(find.bySemanticsLabel('Code copied'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
    });

    testWidgets('diagram, image, file and link cards fire callbacks', (
      tester,
    ) async {
      String? opened;
      String? downloaded;
      await tester.pumpWidget(
        _blocksApp(
          '```mermaid\nflowchart LR\n  A --> B\n```\n\n'
          '![Hero shot](https://images.example.com/hero.png)\n\n'
          '[report.pdf](https://files.example.com/report.pdf)\n\n'
          '[Download assets](https://example.com/assets)\n\n'
          '[Open docs](https://docs.example.com)',
          onOpenLink: (url) => opened = url,
          onDownload: (url) => downloaded = url,
        ),
      );
      await tester.pump();

      expect(find.text('Flowchart'), findsOneWidget);
      // The source is the label; a static "Mermaid" badge added nothing.
      expect(find.text('Mermaid'), findsNothing);
      // The card shows the real source instead of a fake preview sentence.
      expect(find.textContaining('flowchart LR'), findsOneWidget);

      expect(find.text('Hero shot'), findsOneWidget);
      expect(find.text('images.example.com'), findsOneWidget);
      await tester.ensureVisible(find.text('Hero shot'));
      await tester.pump();
      await tester.tap(find.text('Hero shot'));
      expect(opened, 'https://images.example.com/hero.png');

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('PDF file'), findsOneWidget);
      final reportDownload = find.bySemanticsLabel('Download report.pdf');
      await tester.ensureVisible(reportDownload);
      await tester.pump();
      await tester.tap(reportDownload);
      expect(downloaded, 'https://files.example.com/report.pdf');

      final assetsDownload = find.bySemanticsLabel('Download assets');
      await tester.ensureVisible(assetsDownload);
      await tester.pump();
      await tester.tap(assetsDownload);
      expect(downloaded, 'https://example.com/assets');

      final openDocs = find.bySemanticsLabel('Open docs');
      await tester.ensureVisible(openDocs);
      await tester.pump();
      await tester.tap(openDocs);
      expect(opened, 'https://docs.example.com');
    });

    testWidgets(
      'lays out every block at 320 dp and 200 % text in both themes',
      (tester) async {
        _narrowPhone(tester);

        for (final dark in [false, true]) {
          await tester.pumpWidget(
            _blocksApp(_kitchenSink, dark: dark, textScale: 2),
          );
          await tester.pump();

          expect(
            tester.takeException(),
            isNull,
            reason: 'overflow in ${dark ? 'dark' : 'light'} at 320 dp / 200 %',
          );

          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, -2000),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets('live chat renders rich assistant blocks at 320 dp', (
      tester,
    ) async {
      _narrowPhone(tester);

      for (final dark in [false, true]) {
        await tester.pumpWidget(
          _app(
            const V2LiveChatPage(
              data: V2LiveChatData(
                items: [
                  V2LiveAssistantMessage(id: 'a1', markdown: _kitchenSink),
                ],
              ),
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.takeException(), isNull);
        expect(find.text('Build complete', findRichText: true), findsOneWidget);
      }
    });

    testWidgets('live chat forwards block callbacks', (tester) async {
      String? copied;
      String? opened;
      String? downloaded;
      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: const V2LiveChatData(
              items: [V2LiveAssistantMessage(id: 'a1', markdown: _kitchenSink)],
            ),
            onCopyCode: (code) => copied = code,
            onOpenLink: (url) => opened = url,
            onDownloadLink: (url) => downloaded = url,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.ensureVisible(find.bySemanticsLabel('Copy code'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Copy code'));
      expect(copied, contains('runApp'));

      await tester.ensureVisible(
        find.bySemanticsLabel(RegExp('^Download a-very-long-artifact')),
      );
      await tester.pump();
      await tester.tap(
        find.bySemanticsLabel(RegExp('^Download a-very-long-artifact')),
      );
      expect(
        downloaded,
        'https://files.example.com/a-very-long-artifact-file-name-that-needs-to-wrap.pdf',
      );

      await tester.ensureVisible(
        find.bySemanticsLabel('Open the live preview of the portfolio'),
      );
      await tester.pump();
      await tester.tap(
        find.bySemanticsLabel('Open the live preview of the portfolio'),
      );
      expect(opened, 'https://example.com/demo');

      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('real transcript actions', () {
    setUp(V2TranscriptIo.reset);
    tearDown(V2TranscriptIo.reset);

    testWidgets('copy puts the exact code on the clipboard, without fences', (
      tester,
    ) async {
      const code =
          'final greeting = "hello";\n'
          'print(greeting); // `tick` and \$5\n'
          'void main() {}';
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(_blocksApp('```dart\n$code\n```'));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Copy code'));
      await tester.pump();

      final data =
          calls
                  .firstWhere((call) => call.method == 'Clipboard.setData')
                  .arguments
              as Map;
      expect(data['text'], code);
      // The check glyph and the spoken announcement carry the confirmation;
      // no extra "Copied" text is added to the header.
      expect(find.bySemanticsLabel('Code copied'), findsOneWidget);
      expect(find.text('Copied'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
    });

    testWidgets('inline links are tappable and open the real URL', (
      tester,
    ) async {
      Uri? opened;
      V2TranscriptIo.debugOpenOverride = (uri) async {
        opened = uri;
        return true;
      };

      await tester.pumpWidget(
        _blocksApp('Read [the docs](https://example.com/docs) before you run.'),
      );
      await tester.pump();

      final rich = tester.widget<RichText>(find.byType(RichText).first);
      TapGestureRecognizer? recognizer;
      (rich.text as TextSpan).visitChildren((span) {
        if (span is TextSpan && span.text == 'the docs') {
          recognizer = span.recognizer as TapGestureRecognizer?;
        }
        return true;
      });
      expect(recognizer, isNotNull, reason: 'the link must carry a handler');
      recognizer!.onTap!();
      await tester.pump();

      expect(opened, Uri.parse('https://example.com/docs'));
    });

    testWidgets('a host callback still wins over the default opener', (
      tester,
    ) async {
      String? hostOpened;
      await tester.pumpWidget(
        _blocksApp(
          'Read [the docs](https://example.com/docs).',
          onOpenLink: (href) => hostOpened = href,
        ),
      );
      await tester.pump();

      final rich = tester.widget<RichText>(find.byType(RichText).first);
      TapGestureRecognizer? recognizer;
      (rich.text as TextSpan).visitChildren((span) {
        if (span is TextSpan && span.text == 'the docs') {
          recognizer = span.recognizer as TapGestureRecognizer?;
        }
        return true;
      });
      recognizer!.onTap!();
      expect(hostOpened, 'https://example.com/docs');
    });

    testWidgets('an Open row works without a host callback', (tester) async {
      Uri? opened;
      V2TranscriptIo.debugOpenOverride = (uri) async {
        opened = uri;
        return true;
      };

      await tester.pumpWidget(
        _blocksApp('[Open docs](https://docs.example.com)'),
      );
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Open docs'));
      await tester.pump();

      expect(opened, Uri.parse('https://docs.example.com'));
    });

    test('the default downloader writes real bytes to a real file', () async {
      final temp = await Directory.systemTemp.createTemp('ovid-download');
      addTearDown(() => temp.delete(recursive: true));
      V2TranscriptIo.setDownloadDirectoryOverride(temp.path);

      final path = await v2SaveTranscriptBytes(
        Uint8List.fromList([104, 105]),
        'report.txt',
      );

      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).readAsBytesSync(), [104, 105]);
      expect(path, endsWith('Ovid/report.txt'));
    });

    test('download names come from the file, URL or label, never a fence', () {
      expect(
        v2DownloadFileName(
          'https://files.example.com/a/report.pdf',
          suggestedName: 'Download report.pdf',
        ),
        'Download report.pdf',
      );
      expect(
        v2DownloadFileName('https://files.example.com/a/report.pdf'),
        'report.pdf',
      );
      expect(
        v2DownloadFileName('https://files.example.com/download?id=7'),
        'download',
      );
      expect(
        v2DownloadFileName(
          'https://files.example.com/download?id=7',
          suggestedName: 'Download the brand kit',
        ),
        'Download the brand kit',
      );
      expect(v2DownloadFileName('https://files.example.com/'), 'download');
      expect(
        v2TranscriptLinkUri('javascript:alert(1)'),
        isNull,
        reason: 'only http, https and file links may open',
      );
    });

    testWidgets('Download stays wired without a host callback', (tester) async {
      await tester.pumpWidget(
        _blocksApp('[report.txt](ftp://example.com/report.txt)'),
      );
      await tester.pump();

      final button = find.bySemanticsLabel('Download report.txt');
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pump();

      expect(find.text('This file cannot be downloaded.'), findsOneWidget);
    });

    testWidgets('the image download control is always wired', (tester) async {
      await tester.pumpWidget(
        _blocksApp('![Hero](https://images.example.com/hero.png)'),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('Download image'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Open image: Hero')), findsOneWidget);
    });
  });

  testWidgets('long unbroken markdown fits 320 dp at 200 % in both themes', (
    tester,
  ) async {
    _narrowPhone(tester);
    final hash = 'a' * 140;
    final markdown =
        '# $hash\n\n'
        'A hash $hash and a URL https://example.com/$hash.\n\n'
        '`$hash`\n\n'
        '- $hash\n\n'
        '**$hash** and *$hash*\n\n'
        '[Open $hash](https://example.com/$hash)';

    for (final dark in [false, true]) {
      await tester.pumpWidget(_blocksApp(markdown, dark: dark, textScale: 2));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason: 'long tokens overflow (${dark ? 'dark' : 'light'})',
      );
      for (final flex in tester.allRenderObjects.whereType<RenderFlex>()) {
        if (flex.direction != Axis.horizontal) continue;
        var right = 0.0;
        RenderBox? child = flex.firstChild;
        while (child != null) {
          final data = child.parentData! as FlexParentData;
          final edge = data.offset.dx + child.size.width;
          if (edge > right) right = edge;
          child = flex.childAfter(child);
        }
        expect(
          right,
          lessThanOrEqualTo(flex.size.width + 0.5),
          reason: 'a row paints past its box (${dark ? 'dark' : 'light'})',
        );
      }
    }
  });
}
