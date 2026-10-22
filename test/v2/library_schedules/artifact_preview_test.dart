import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';
import 'package:ovid_ai/ui/v2/library/artifact_preview.dart';

/// A valid 1×1 transparent PNG, so image previews decode without a network.
const _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

Widget _app(Widget child, {bool dark = false, double textScale = 1}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    builder: (context, home) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: home!,
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _narrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Fails when a paragraph is laid out shorter than it needs (a cut-off line)
/// or when a text run paints past the screen edge. An ellipsis is allowed.
void _expectNoClippedText(WidgetTester tester) {
  for (final paragraph
      in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!paragraph.hasSize) continue;
    final needed = paragraph.getMaxIntrinsicHeight(paragraph.size.width);
    expect(
      paragraph.size.height,
      greaterThanOrEqualTo(needed - 0.5),
      reason: 'clipped text: "${paragraph.text.toPlainText()}"',
    );
  }
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final text = (element.widget as Text).data ?? '';
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '"$text" paints past the left edge',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(width + 0.5),
      reason: '"$text" paints past the right edge',
    );
  }
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  _expectNoClippedText(tester);
  for (var i = 0; i < 80; i++) {
    final position = state.position;
    if (position.pixels + 0.5 >= position.maxScrollExtent) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      _expectNoClippedText(tester);
      if (position.pixels + 0.5 >= position.maxScrollExtent) break;
      continue;
    }
    position.jumpTo(
      (position.pixels + 160).clamp(0.0, position.maxScrollExtent),
    );
    await tester.pump();
    _expectNoClippedText(tester);
  }
}

const _imageData = V2ArtifactPreviewData(
  name: 'token-usage-breakdown.png',
  type: V2ArtifactPreviewType.image,
  typeLabel: 'PNG image',
  sizeLabel: '480 KB',
);

const _documentData = V2ArtifactPreviewData(
  name: 'market-analysis-q2.pdf',
  type: V2ArtifactPreviewType.document,
  typeLabel: 'PDF document',
  sizeLabel: '1.8 MB',
  metadata: <V2ArtifactPreviewMeta>[
    V2ArtifactPreviewMeta(label: 'Pages', value: '18 pages'),
    V2ArtifactPreviewMeta(label: 'Owner', value: 'Finance team'),
    V2ArtifactPreviewMeta(label: 'Created', value: 'Yesterday at 4:20 PM'),
  ],
);

const _pageData = V2ArtifactPreviewData(
  name: 'portfolio-index.html',
  type: V2ArtifactPreviewType.page,
  typeLabel: 'Web page',
  sizeLabel: '14.2 KB',
  pageUrl: 'https://ovid.site/preview/portfolio-index',
);

String _code(int lines) =>
    List.generate(lines, (i) => 'CODE_LINE_${i + 1} = true;').join('\n');

void main() {
  testWidgets('image previews render the image and open externally', (
    tester,
  ) async {
    _phone(tester);
    var opens = 0;
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: _imageData.name,
            type: V2ArtifactPreviewType.image,
            typeLabel: _imageData.typeLabel,
            sizeLabel: _imageData.sizeLabel,
            image: MemoryImage(Uint8List.fromList(_onePixelPng)),
          ),
          onOpenExternally: () => opens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('token-usage-breakdown.png'), findsOneWidget);
    expect(find.text('PNG image · 480 KB'), findsOneWidget);
    // The caption that repeated what the image already says is gone.
    expect(find.text('Image preview'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Open externally'), findsOneWidget);

    await tester.tap(find.text('Open externally'));
    expect(opens, 1);
  });

  testWidgets('image previews fall back to a placeholder without an image', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const V2ArtifactPreview(data: _imageData)));
    await tester.pumpAndSettle();

    expect(find.text('No image preview'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code previews stop at the line cap and open externally', (
    tester,
  ) async {
    _phone(tester);
    var opens = 0;
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'huge-module.ts',
            type: V2ArtifactPreviewType.code,
            typeLabel: 'TypeScript',
            sizeLabel: '920 KB',
            codeFile: 'huge-module.ts',
            code: _code(500),
          ),
          onOpenExternally: () => opens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(v2ArtifactPreviewCodeLineCap, 120);
    expect(find.textContaining('CODE_LINE_120'), findsOneWidget);
    expect(find.textContaining('CODE_LINE_121'), findsNothing);
    expect(find.textContaining('120 of 500 lines'), findsOneWidget);
    expect(find.text('TS'), findsOneWidget);

    await tester.ensureVisible(find.text('Open externally'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open externally'));
    expect(opens, 1);
  });

  testWidgets('code previews report the real length when only a head arrives', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'large.py',
            type: V2ArtifactPreviewType.code,
            codeFile: 'large.py',
            code: _code(5),
            codeTotalLines: 900,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Python'), findsOneWidget);
    expect(find.textContaining('5 of 900 lines'), findsOneWidget);
  });

  testWidgets('empty code sends no lines but still offers the file', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: const V2ArtifactPreviewData(
            name: 'empty.ts',
            type: V2ArtifactPreviewType.code,
            codeFile: 'empty.ts',
          ),
          onOpenExternally: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No preview.'), findsOneWidget);
    expect(find.textContaining(' of '), findsNothing);
    expect(find.text('Open externally'), findsOneWidget);
  });

  testWidgets('document previews show metadata only and open externally', (
    tester,
  ) async {
    _phone(tester);
    var opens = 0;
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(data: _documentData, onOpenExternally: () => opens++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('Metadata only'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('18 pages'), findsOneWidget);
    expect(find.text('Finance team'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    // The file body is never laid out, even if a caller sends one by mistake.
    expect(find.textContaining('CODE_LINE'), findsNothing);

    await tester.tap(find.text('Open externally'));
    expect(opens, 1);
  });

  testWidgets('page previews draw a placeholder, not a WebView', (
    tester,
  ) async {
    _phone(tester);
    var opens = 0;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(V2ArtifactPreview(data: _pageData, onOpenExternally: () => opens++)),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Page thumbnail placeholder'), findsOneWidget);
    expect(find.textContaining('ovid.site/preview'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byType(UiKitView), findsNothing);
    expect(find.byType(PlatformViewLink), findsNothing);

    await tester.tap(find.text('Open externally'));
    expect(opens, 1);
    handle.dispose();
  });

  testWidgets('page previews accept a supplied static thumbnail', (
    tester,
  ) async {
    _phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: _pageData.name,
            type: V2ArtifactPreviewType.page,
            typeLabel: _pageData.typeLabel,
            pageUrl: _pageData.pageUrl,
            pageThumbnail: MemoryImage(Uint8List.fromList(_onePixelPng)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(
      find.bySemanticsLabel('Page thumbnail for portfolio-index.html'),
      findsOneWidget,
    );
    expect(find.byType(AndroidView), findsNothing);

    handle.dispose();
  });

  testWidgets('heavy files skip the inline body and open externally', (
    tester,
  ) async {
    _phone(tester);
    var opens = 0;
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'huge-module.ts',
            type: V2ArtifactPreviewType.code,
            typeLabel: 'TypeScript',
            sizeLabel: '920 MB',
            codeFile: 'huge-module.ts',
            code: _code(500),
            heavy: true,
          ),
          onOpenExternally: () => opens++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Large file'), findsOneWidget);
    expect(find.text('Too large to preview'), findsOneWidget);
    expect(find.textContaining('CODE_LINE'), findsNothing);

    await tester.tap(find.text('Open externally'));
    expect(opens, 1);
  });

  testWidgets('no external action is drawn without a handler or URL', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const V2ArtifactPreview(data: _documentData)));
    await tester.pumpAndSettle();

    // A disabled "Open externally" would be a dead control.
    expect(find.text('Open externally'), findsNothing);
    expect(find.byType(OButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the host can hide the header and footer chrome', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'report.pdf',
            typeLabel: 'PDF',
            sizeLabel: '1 MB',
          ),
          showHeader: false,
          showFooter: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The stage is all a detail page needs: it owns the name and the facts.
    expect(find.text('report.pdf'), findsNothing);
    expect(find.text('PDF · 1 MB'), findsNothing);
    expect(find.text('Read-only preview.'), findsNothing);
    expect(find.text('Metadata only'), findsOneWidget);
  });

  testWidgets('the external action opens the real URL without a handler', (
    tester,
  ) async {
    Uri? opened;
    V2TranscriptIo.debugOpenOverride = (uri) async {
      opened = uri;
      return true;
    };
    addTearDown(V2TranscriptIo.reset);

    _phone(tester);
    await tester.pumpWidget(
      _app(
        const V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'report.pdf',
            type: V2ArtifactPreviewType.document,
            openUrl: 'https://r2.test/report.pdf',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open externally'));
    await tester.pumpAndSettle();
    expect(opened, Uri.parse('https://r2.test/report.pdf'));
  });

  testWidgets('code previews give every token family its own style', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'sample.ts',
            type: V2ArtifactPreviewType.code,
            codeFile: 'sample.ts',
            code: "const answer = 42;\nfinal label = 'done';\n// note",
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(
      find.byKey(const ValueKey<String>('artifact-preview-code')),
    );
    final styles = <String>{};
    text.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.style != null) {
        final style = span.style!;
        if (style.color != null ||
            style.fontWeight != null ||
            style.fontStyle != null) {
          styles.add('${style.color}|${style.fontWeight}|${style.fontStyle}');
        }
      }
      return true;
    });
    // The palette is monochrome on purpose (three-colour system): keywords,
    // strings, numbers and comments are separated by ink step and weight
    // instead of hue, so they must not collapse into one style.
    expect(styles.length, greaterThanOrEqualTo(4));
  });

  testWidgets('document previews render the real text', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'notes.txt',
            type: V2ArtifactPreviewType.document,
            documentText: 'First real line.\nSecond real line.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Document preview'), findsOneWidget);
    expect(find.textContaining('First real line.'), findsOneWidget);
    expect(find.textContaining('Second real line.'), findsOneWidget);
    expect(find.text('Metadata only'), findsNothing);
  });

  testWidgets('long document text stops at the line cap', (tester) async {
    _phone(tester);
    final body = List.generate(400, (i) => 'DOC_LINE_${i + 1}').join('\n');
    await tester.pumpWidget(
      _app(
        V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'long.txt',
            type: V2ArtifactPreviewType.document,
            documentText: body,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('DOC_LINE_120'), findsOneWidget);
    expect(find.textContaining('DOC_LINE_121'), findsNothing);
    expect(find.textContaining('120 of 400 lines'), findsOneWidget);
  });

  testWidgets('all preview types fit 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    final samples = <V2ArtifactPreviewData>[
      _imageData,
      V2ArtifactPreviewData(
        name: 'large.py',
        type: V2ArtifactPreviewType.code,
        typeLabel: 'Python',
        sizeLabel: '900 KB',
        codeFile: 'large.py',
        code: _code(30),
        codeTotalLines: 900,
      ),
      _documentData,
      _pageData,
    ];

    for (final dark in <bool>[false, true]) {
      for (final data in samples) {
        _narrowPhone(tester);
        await tester.pumpWidget(
          _app(
            V2ArtifactPreview(data: data, onOpenExternally: () {}),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(data.name), findsWidgets);
        expect(find.text('Open externally'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _scrollThrough(tester);
      }
    }
  });

  testWidgets('heavy preview fits 320 dp at 200 % text', (tester) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _app(
        const V2ArtifactPreview(
          data: V2ArtifactPreviewData(
            name: 'semantic-search.bin',
            type: V2ArtifactPreviewType.document,
            typeLabel: 'Binary',
            sizeLabel: '920 MB',
            heavy: true,
          ),
        ),
        dark: true,
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Too large to preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _scrollThrough(tester);
  });
}
