import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';

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
      expect(find.text('Mermaid'), findsOneWidget);
      expect(
        find.text('Diagram preview is not available on this device.'),
        findsOneWidget,
      );

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
}
