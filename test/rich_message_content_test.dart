import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/static_rich_content.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';
import 'package:ovid_ai/ui/v2/chat/remote_attachment_tile.dart';

Widget _app(Widget child) => MaterialApp(
  theme: OTheme.light(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('settled GFM', () {
    test('tables retain headers, alignment and rows', () {
      final table =
          parseV2MessageBlocks(
                '| Name | Count |\n|:---|---:|\n| First | 1 |',
              ).single
              as V2TableBlock;
      expect(table.headers, <String>['Name', 'Count']);
      expect(table.align, <V2TableAlign>[V2TableAlign.start, V2TableAlign.end]);
      expect(table.rows, <List<String>>[
        <String>['First', '1'],
      ]);
    });

    testWidgets('task lists expose checked and unchecked states', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const V2MessageBlocks(
            markdown: '- [x] Ship\n- [ ] Verify\n- Ordinary',
          ),
        ),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('Completed task: Ship'), findsOneWidget);
      expect(find.bySemanticsLabel('Incomplete task: Verify'), findsOneWidget);
      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
      expect(find.text('Ordinary', findRichText: true), findsOneWidget);
    });

    testWidgets('strikethrough is text decoration, not deleted content', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(const V2MessageBlocks(markdown: 'Keep ~~remove~~ this')),
      );
      await tester.pump();

      expect(
        find.textContaining('Keep remove this', findRichText: true),
        findsOneWidget,
      );
      final decorated = <TextSpan>[];
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == 'remove' &&
              span.style?.decoration == TextDecoration.lineThrough) {
            decorated.add(span);
          }
          return true;
        });
      }
      expect(decorated, hasLength(1));
    });

    testWidgets('raw HTML is inert text and never an image or platform node', (
      tester,
    ) async {
      const raw = '<img src=x onerror=alert(1)><script>alert(2)</script>';
      final blocks = parseV2MessageBlocks(raw);
      expect(blocks.whereType<V2ImageBlock>(), isEmpty);
      expect(blocks.whereType<V2ParagraphBlock>(), isNotEmpty);

      await tester.pumpWidget(_app(const V2MessageBlocks(markdown: raw)));
      await tester.pump();
      expect(find.byType(AndroidView), findsNothing);
      expect(
        find.textContaining('<script>', findRichText: true),
        findsOneWidget,
      );
    });
  });

  group('settled content only', () {
    test(
      'message cache is stable, bounded by identity/content, and skips streams',
      () {
        var parses = 0;
        final cache = SettledContentCache<V2MessageBlock>(
          parser: (message) {
            parses++;
            return parseV2MessageBlocks(message.content);
          },
        );
        final message = Message(
          privateSyncId: 'settled-1',
          role: 'assistant',
          content: '**one**',
        );

        final first = cache.blocksFor(message);
        final second = cache.blocksFor(message);
        expect(identical(first, second), isTrue);
        expect(parses, 1);

        message.content = '**two**';
        cache.blocksFor(message);
        expect(parses, 2);
        expect(
          cache.blocksFor(
            Message(
              privateSyncId: 'live-1',
              role: 'assistant',
              kind: MsgKind.streaming,
              content: '**not settled**',
            ),
          ),
          isEmpty,
        );
        expect(parses, 2);
      },
    );

    testWidgets('settled code is highlighted and copies exact source', (
      tester,
    ) async {
      String? copied;
      await tester.pumpWidget(
        _app(
          V2MessageBlocks(
            markdown: '```dart\nvoid main() {\n  print("hi");\n}\n```',
            onCopyCode: (value) => copied = value,
          ),
        ),
      );
      await tester.pump();

      var highlighted = false;
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        if (!rich.text.toPlainText().contains('void main()')) continue;
        rich.text.visitChildren((span) {
          if (span is TextSpan &&
              span.text == 'void' &&
              span.style?.fontWeight == FontWeight.w600) {
            highlighted = true;
          }
          return true;
        });
      }
      expect(highlighted, isTrue);

      await tester.tap(find.bySemanticsLabel('Copy code'));
      await tester.pump();
      expect(copied, 'void main() {\n  print("hi");\n}');
    });

    testWidgets('streaming deltas stay plain and create no rich work', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const V2MessageBlocks(
            markdown: '```dart\nvoid main() {}\n```',
            settled: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('```dart'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy code'), findsNothing);
      expect(find.byType(Table), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('remote images and attachments', () {
    testWidgets('inline images have loading and real-pixel content states', (
      tester,
    ) async {
      final pending = Completer<Uint8List>();
      String? requested;
      await tester.pumpWidget(
        _app(
          V2MessageBlocks(
            markdown: 'Before ![Hero](https://images.example/hero.png) after',
            imageLoader: (url) {
              requested = url;
              return pending.future;
            },
          ),
        ),
      );
      await tester.pump();
      expect(requested, 'https://images.example/hero.png');
      expect(find.text('Loading image…'), findsOneWidget);
      expect(find.textContaining('Before', findRichText: true), findsOneWidget);
      expect(find.textContaining('after', findRichText: true), findsOneWidget);

      pending.complete(_tinyPng);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsWidgets);
      expect(
        tester.widgetList<Image>(find.byType(Image)).any((image) {
          final provider = image.image;
          return provider is MemoryImage ||
              (provider is ResizeImage &&
                  provider.imageProvider is MemoryImage);
        }),
        isTrue,
      );
      expect(find.text('Loading image…'), findsNothing);
    });

    testWidgets('image fetch failures show an honest error state', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          V2MessageBlocks(
            markdown: '![Hero](https://images.example/missing.png)',
            imageLoader: (_) async => throw StateError('missing'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(find.text('Loading image…'), findsNothing);
    });

    testWidgets('image error content fits 320 dp at 200 percent text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: V2MessageBlocks(
                markdown: '![Hero](https://images.example/missing.png)',
                imageLoader: (_) async => throw StateError('missing'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Image unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('attachment rows expose loading, ready, and failure states', (
      tester,
    ) async {
      var downloads = 0;
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              RemoteAttachmentTile(
                attachment: MessageAttachment(name: 'upload.txt', size: 0),
                state: RemoteAttachmentState.loading,
              ),
              RemoteAttachmentTile(
                attachment: MessageAttachment(
                  name: 'report.pdf',
                  size: 12,
                  url: 'https://files.example/report.pdf',
                ),
                state: RemoteAttachmentState.ready,
                onDownload: () => downloads++,
              ),
              RemoteAttachmentTile(
                attachment: MessageAttachment(name: 'missing.bin', size: 0),
                state: RemoteAttachmentState.error,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Uploading…'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('12 B'), findsOneWidget);
      expect(find.text('Attachment unavailable'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Download report.pdf'));
      expect(downloads, 1);
      expect(find.bySemanticsLabel('Download missing.bin'), findsNothing);
    });

    testWidgets('live user messages render their actual attachment metadata', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: V2LiveChatPage(
            data: V2LiveChatData(
              items: [
                V2LiveUserMessage(
                  id: 'u1',
                  text: 'Attached',
                  attachments: [
                    MessageAttachment(
                      name: 'notes.txt',
                      size: 4,
                      path: '/tmp/notes.txt',
                    ),
                    MessageAttachment(name: 'lost.txt', size: 0),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('lost.txt'), findsOneWidget);
      expect(find.text('Attachment unavailable'), findsOneWidget);
    });
  });

  group('static diagrams', () {
    testWidgets(
      'Mermaid renders to memory pixels without a platform HTML view',
      (tester) async {
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(StaticRichContentRenderer.channel, (
          call,
        ) async {
          calls.add(call);
          // Cancellation returns an outcome, never the render's image bytes.
          if (call.method == 'cancelRenderPng') return true;
          return _tinyPng;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            StaticRichContentRenderer.channel,
            null,
          ),
        );

        await tester.pumpWidget(
          _app(
            const V2MessageBlocks(
              markdown: '```mermaid\nflowchart LR\nA --> B\n```',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(calls.single.method, 'renderMermaidPng');
        expect(find.byType(AndroidView), findsNothing);
        expect(
          tester
              .widgetList<Image>(find.byType(Image))
              .any((image) => image.image is MemoryImage),
          isTrue,
        );
        expect(find.textContaining('flowchart LR'), findsOneWidget);
      },
    );

    test('an SVG fence is a static diagram block, not raw HTML', () {
      final block = parseV2MessageBlocks(
        '```svg\n<svg viewBox="0 0 1 1"><rect width="1" height="1"/></svg>\n```',
      ).single;
      expect(block, isA<V2SvgBlock>());
      expect((block as V2SvgBlock).source, contains('<rect'));
    });
  });
}

final Uint8List _tinyPng = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
