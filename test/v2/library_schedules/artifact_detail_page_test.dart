import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_actions.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';
import 'package:ovid_ai/ui/v2/library/artifact_preview.dart';

/// 320 dp wide at 200 % text — the smallest surface the contract supports.
Widget _narrowApp(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2)),
      child: child,
    ),
  ),
);

void _narrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Fails when a paragraph is laid out shorter than it needs, which is how
/// clipped text shows up (an ellipsis is allowed, a cut-off line is not).
/// Also fails when a text run paints past the screen edge.
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

/// Scrolls the page body from top to bottom so off-screen rows lay out too.
Future<void> _scrollThrough(WidgetTester tester) async {
  _expectNoClippedText(tester);
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  for (var i = 0; i < 80; i++) {
    final position = state.position;
    if (position.pixels + 0.5 >= position.maxScrollExtent) {
      // The extent can grow once more rows are built; stop only when a jump
      // no longer moves the viewport.
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      _expectNoClippedText(tester);
      if (position.pixels + 0.5 >= position.maxScrollExtent) break;
      continue;
    }
    position.jumpTo(
      (position.pixels + 120).clamp(0.0, position.maxScrollExtent),
    );
    await tester.pump();
    _expectNoClippedText(tester);
  }
}

const _codeData = V2ArtifactDetailData(
  name: 'portfolio-index.html',
  typeLabel: 'HTML5 + Tailwind',
  sizeLabel: '14.2 KB',
  createdLabel: 'Created today at 10:24 AM',
  versionLabel: 'v2.4 Ready',
  sourceChatTitle: 'Landing page redesign',
  sourcePrompt: 'Landing page redesign',
  previewKind: V2ArtifactPreviewKind.code,
  previewCodeFile: 'agent_manifest.ts',
  previewCode: 'export const client = createEngine({\n  streaming: true\n});',
  details: <V2ArtifactDetailRow>[
    V2ArtifactDetailRow(label: 'Lines of code', value: '486 lines'),
    V2ArtifactDetailRow(label: 'Artifact hash', value: 'sha256:7f9b4c0e'),
    V2ArtifactDetailRow(
      label: 'Access',
      value: 'Public preview enabled',
      tone: V2ArtifactDetailTone.success,
    ),
  ],
);

const _documentData = V2ArtifactDetailData(
  name: 'market-analysis-q2.pdf',
  typeLabel: 'PDF document',
  sizeLabel: '1.8 MB',
  createdLabel: 'Created yesterday',
  sourceChatTitle: 'Q2 market review',
  sourcePrompt: 'Summarise the Q2 numbers',
  previewKind: V2ArtifactPreviewKind.document,
  details: <V2ArtifactDetailRow>[
    V2ArtifactDetailRow(label: 'Pages', value: '18 pages'),
    V2ArtifactDetailRow(label: 'File type', value: 'PDF'),
  ],
);

const _imageData = V2ArtifactDetailData(
  name: 'token-usage-breakdown.png',
  typeLabel: 'PNG image',
  sizeLabel: '480 KB',
  createdLabel: 'Created May 15',
  previewKind: V2ArtifactPreviewKind.image,
);

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _scrollToBottom(WidgetTester tester) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  state.position.jumpTo(state.position.maxScrollExtent);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the artifact in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    expect(find.text('Artifact detail'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsWidgets);
    expect(find.text('HTML5 + Tailwind'), findsWidgets);
    expect(find.text('v2.4 Ready'), findsOneWidget);
    // No host handlers and no URL: the page must not draw dead actions.
    expect(find.text('Download'), findsNothing);
    expect(find.text('Share link'), findsNothing);
    expect(find.text('Copy link'), findsNothing);
    expect(find.text('Open in Studio'), findsNothing);
    expect(find.text('Delete artifact'), findsNothing);
  });

  testWidgets('every action renders when it can really run', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(
            name: 'portfolio-index.html',
            previewKind: V2ArtifactPreviewKind.code,
            previewCodeFile: 'portfolio-index.html',
            previewCode: '<main></main>',
            downloadUrl: 'https://r2.test/portfolio-index.html',
            shareUrl: 'https://ovid.site/a/portfolio-index',
          ),
          onDownload: () {},
          onShareLink: () {},
          onOpenInStudio: () {},
          onDelete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Open in Studio'), findsOneWidget);
    expect(find.text('Delete artifact'), findsOneWidget);
  });

  testWidgets('renders the artifact in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ArtifactDetailPage(data: _codeData), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsWidgets);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
  });

  testWidgets('missing artifact offers a way back', (tester) async {
    _phone(tester);
    var back = 0;
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(
            status: V2ArtifactDetailStatus.missing,
          ),
          onBackToArtifacts: () => back++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('This artifact is gone'), findsOneWidget);
    await tester.tap(find.text('Back to artifacts'));
    expect(back, 1);
  });

  testWidgets('Download fires the primary callback', (tester) async {
    _phone(tester);
    var downloads = 0;
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onDownload: () => downloads++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download'));
    expect(downloads, 1);
  });

  testWidgets('Share link fires the callback and shows a copied state', (
    tester,
  ) async {
    _phone(tester);
    var shares = 0;
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onShareLink: () => shares++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Share link'));
    await tester.pump();

    expect(shares, 1);
    expect(find.text('Link copied'), findsOneWidget);
    expect(find.text('Share link'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    // The confirmation is temporary; the action comes back.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Link copied'), findsNothing);
  });

  testWidgets('Delete asks for confirmation before firing', (tester) async {
    _phone(tester);
    var deletes = 0;
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onDelete: () => deletes++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete artifact'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this artifact?'), findsOneWidget);
    expect(find.textContaining('frees 14.2 KB of storage'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deletes, 0);
    expect(find.text('Delete this artifact?'), findsNothing);

    await tester.tap(find.text('Delete artifact'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('Open in Studio fires for code artifacts', (tester) async {
    _phone(tester);
    var studio = 0;
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onOpenInStudio: () => studio++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open in Studio'));
    expect(studio, 1);
  });

  testWidgets('Open in Studio is not offered for images or documents', (
    tester,
  ) async {
    _phone(tester);
    for (final data in <V2ArtifactDetailData>[_imageData, _documentData]) {
      await tester.pumpWidget(
        _app(ArtifactDetailPage(data: data, onOpenInStudio: () {})),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open in Studio'), findsNothing);
    }
  });

  testWidgets('documents show metadata only and open externally', (
    tester,
  ) async {
    _phone(tester);
    var external = 0;
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: _documentData,
          onOpenExternally: () => external++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No heavy preview chrome or WebView-style page mockup.
    expect(find.text('Responsive view'), findsNothing);
    expect(find.text('Live preview'), findsNothing);
    expect(find.textContaining('was not available for preview'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('18 pages'), findsOneWidget);

    await _scrollToBottom(tester);
    await tester.tap(find.text('Open externally'));
    expect(external, 1);
  });

  testWidgets('images preview inline and offer an external open', (
    tester,
  ) async {
    _phone(tester);
    var external = 0;
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: _imageData,
          onOpenExternally: () => external++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image preview'), findsOneWidget);
    expect(find.text('Open externally'), findsOneWidget);

    await _scrollToBottom(tester);
    await tester.tap(find.text('Open externally'));
    expect(external, 1);
  });

  testWidgets('large code previews stop at the line cap', (tester) async {
    _phone(tester);
    final code = List.generate(
      500,
      (i) => 'CODE_LINE_${i + 1} = true;',
    ).join('\n');
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: V2ArtifactDetailData(
            name: 'huge-module.ts',
            typeLabel: 'TypeScript',
            sizeLabel: '920 KB',
            previewKind: V2ArtifactPreviewKind.code,
            previewCodeFile: 'huge-module.ts',
            previewCode: code,
            previewTotalLines: 500,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(v2ArtifactCodeLineCap, 120);
    expect(find.textContaining('CODE_LINE_120'), findsOneWidget);
    expect(find.textContaining('CODE_LINE_121'), findsNothing);
    expect(
      find.textContaining('Showing first 120 of 500 lines'),
      findsOneWidget,
    );
  });

  testWidgets('the preview area is the shared artifact preview', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: _codeData,
          onOpenExternally: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2ArtifactPreview), findsOneWidget);
    expect(find.text('HTML5 + Tailwind · 14.2 KB'), findsOneWidget);
    expect(find.text('agent_manifest.ts'), findsOneWidget);
    expect(find.textContaining('This preview is read-only'), findsOneWidget);
    expect(find.text('Open externally'), findsOneWidget);
  });

  testWidgets('the preview is replaced by details and comes back', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    expect(find.byType(V2ArtifactPreview), findsOneWidget);

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.byType(V2ArtifactPreview), findsNothing);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byType(V2ArtifactPreview), findsOneWidget);
  });

  testWidgets('Details tab reveals the technical rows', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    expect(find.text('Artifact hash'), findsNothing);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    expect(find.text('Artifact hash'), findsOneWidget);
    expect(find.text('sha256:7f9b4c0e'), findsOneWidget);
    expect(find.text('Public preview enabled'), findsOneWidget);

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Artifact hash'), findsNothing);
  });

  testWidgets('source chat row opens the original chat', (tester) async {
    _phone(tester);
    var chats = 0;
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onOpenChat: () => chats++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Made in chat'));
    expect(chats, 1);
  });

  testWidgets('content fits 320 dp at 200 % text in light', (tester) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(
        ArtifactDetailPage(data: _codeData, onDownload: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    _expectNoClippedText(tester);

    await tester.scrollUntilVisible(
      find.text('Download'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Download'), findsOneWidget);
    await _scrollThrough(tester);
  });

  testWidgets('document preview fits 320 dp at 200 % text in dark', (
    tester,
  ) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(
        ArtifactDetailPage(data: _documentData, onOpenExternally: () {}),
        dark: true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Open externally'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Open externally'), findsOneWidget);
    await _scrollThrough(tester);
  });

  testWidgets('details fit 320 dp at 200 % text in dark', (tester) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(const ArtifactDetailPage(data: _codeData), dark: true),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Details'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    await _scrollThrough(tester);
    expect(find.text('sha256:7f9b4c0e'), findsOneWidget);
  });

  testWidgets('empty, error and loading fit 320 dp at 200 % text', (
    tester,
  ) async {
    for (final status in <V2ArtifactDetailStatus>[
      V2ArtifactDetailStatus.loading,
      V2ArtifactDetailStatus.error,
      V2ArtifactDetailStatus.missing,
    ]) {
      _narrowPhone(tester);
      await tester.pumpWidget(
        _narrowApp(
          ArtifactDetailPage(
            data: V2ArtifactDetailData(status: status),
            onRetry: () {},
            onBackToArtifacts: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      _expectNoClippedText(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('controls are at least 48 dp and labelled', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onMore: () {})),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(OIconButton).first).height,
      greaterThanOrEqualTo(OSpace.touch),
    );
    expect(
      tester.getSize(find.byType(OIconButton).first).width,
      greaterThanOrEqualTo(OSpace.touch),
    );
    for (final button in tester.widgetList<OButton>(find.byType(OButton))) {
      expect(button.label, isNotEmpty);
      final height = tester.getSize(find.byWidget(button)).height;
      expect(height, greaterThanOrEqualTo(OSpace.touch));
    }
    // The two tabs are 48 dp tall and announce their selected state.
    for (final label in <String>['Preview', 'Details']) {
      final tab = tester.getSize(
        find
            .ancestor(of: find.text(label), matching: find.byType(OPressable))
            .first,
      );
      expect(tab.height, greaterThanOrEqualTo(OSpace.touch));
    }
  });

  testWidgets('reduced motion keeps every part of the page visible', (
    tester,
  ) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: ArtifactDetailPage(data: _codeData, onDownload: () {}),
          ),
        ),
      ),
    );
    await tester.pump();

    // No entrance delay: content is on screen on the first frame.
    expect(find.text('portfolio-index.html'), findsOneWidget);
    _expectNoClippedText(tester);

    await tester.scrollUntilVisible(
      find.text('Download'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
  });

  testWidgets('the snippet badge follows the file type', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    // `agent_manifest.ts` must not be labelled HTML.
    expect(find.text('TS'), findsWidgets);
    expect(find.text('HTML'), findsNothing);

    await tester.pumpWidget(
      _app(
        const ArtifactDetailPage(
          data: V2ArtifactDetailData(
            previewKind: V2ArtifactPreviewKind.code,
            previewCodeFile: 'portfolio-index.html',
            previewCode: '<main></main>',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('HTML'), findsWidgets);
  });

  group('wiring', () {
    testWidgets('Download is not rendered when nothing can be downloaded', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsNothing);
      expect(find.text('Share link'), findsNothing);
      expect(find.text('Delete artifact'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the missing state has no dead back button', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          const ArtifactDetailPage(
            data: V2ArtifactDetailData(status: V2ArtifactDetailStatus.missing),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('This artifact is gone'), findsOneWidget);
      expect(find.text('Back to artifacts'), findsNothing);
    });

    testWidgets('Download really writes the file and confirms the name', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('artifact-download-');
      addTearDown(() {
        V2TranscriptIo.setDownloadDirectoryOverride(null);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      V2TranscriptIo.setDownloadDirectoryOverride(dir.path);

      final source = File('${dir.path}/source.html')
        ..writeAsBytesSync(utf8.encode('<main>real bytes</main>'));
      _phone(tester);
      await tester.pumpWidget(
        _app(
          ArtifactDetailPage(
            data: V2ArtifactDetailData(
              name: 'portfolio-index.html',
              previewKind: V2ArtifactPreviewKind.code,
              previewCodeFile: 'portfolio-index.html',
              previewCode: '<main></main>',
              downloadUrl: source.uri.toString(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saved = File('${dir.path}/Ovid/portfolio-index.html');
      await tester.runAsync(() async {
        await tester.tap(find.text('Download'));
        for (var i = 0; i < 100 && !saved.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // Let the saver's continuation (and the confirmation) run too.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(saved.existsSync(), isTrue);
      expect(utf8.decode(saved.readAsBytesSync()), '<main>real bytes</main>');
      expect(find.text('Saved portfolio-index.html'), findsOneWidget);
    });

    testWidgets('Copy link really writes the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      _phone(tester);
      await tester.pumpWidget(
        _app(
          const ArtifactDetailPage(
            data: V2ArtifactDetailData(
              name: 'portfolio-index.html',
              previewKind: V2ArtifactPreviewKind.code,
              previewCodeFile: 'portfolio-index.html',
              previewCode: '<main></main>',
              shareUrl: 'https://ovid.site/a/portfolio-index',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Copy link'), findsOneWidget);
      await tester.tap(find.text('Copy link'));
      await tester.pump();
      await tester.pump();

      expect(copied, 'https://ovid.site/a/portfolio-index');
      expect(find.text('Link copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Copy link'), findsOneWidget);
    });

    testWidgets('Open externally opens the real URL without a handler', (
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
          const ArtifactDetailPage(
            data: V2ArtifactDetailData(
              name: 'market-analysis-q2.pdf',
              previewKind: V2ArtifactPreviewKind.document,
              openUrl: 'https://r2.test/market-analysis-q2.pdf',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Open externally'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Open externally'));
      await tester.pumpAndSettle();

      expect(opened, Uri.parse('https://r2.test/market-analysis-q2.pdf'));
    });

    testWidgets('document previews render the real text', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          const ArtifactDetailPage(
            data: V2ArtifactDetailData(
              name: 'market-analysis-q2.txt',
              previewKind: V2ArtifactPreviewKind.document,
              documentText:
                  'Q2 revenue grew 18%.\nRetention held at 91%.\n'
                  'Churn fell in every region.',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Document preview'), findsOneWidget);
      expect(find.textContaining('Q2 revenue grew 18%'), findsOneWidget);
      expect(find.textContaining('Retention held at 91%'), findsOneWidget);
      expect(find.text('Metadata only'), findsNothing);
    });

    testWidgets('the preview kind is inferred from the file name', (
      tester,
    ) async {
      _phone(tester);
      const names = <String, String>{
        'shot.png': 'Image preview unavailable',
        'module.ts': 'No preview lines were sent with this artifact.',
        'report.pdf': 'Metadata only',
      };
      for (final entry in names.entries) {
        await tester.pumpWidget(
          _app(ArtifactDetailPage(data: V2ArtifactDetailData(name: entry.key))),
        );
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      }
    });

    testWidgets('a long file name ellipsizes at 320 dp and 200 % text', (
      tester,
    ) async {
      const longName =
          'quarterly-revenue-and-retention-breakdown-for-every-region-'
          'final-final-v12-approved.xlsx';
      for (final dark in <bool>[false, true]) {
        _narrowPhone(tester);
        await tester.pumpWidget(
          _narrowApp(
            const ArtifactDetailPage(data: V2ArtifactDetailData(name: longName)),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();

        final title = tester.widget<Text>(find.text(longName).first);
        expect(title.maxLines, 2);
        expect(title.overflow, TextOverflow.ellipsis);
        final box = tester.getSize(find.text(longName).first);
        final width =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(box.width, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
      }
    });
  });
}
