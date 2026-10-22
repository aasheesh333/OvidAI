import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
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
  sourceChatTitle: 'Landing page redesign',
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

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert_rounded));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('header is the file name with back and one menu', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData, onDelete: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsWidgets);
    expect(find.text('Artifact detail'), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    expect(find.text('Lines of code'), findsOneWidget);
    expect(find.text('Artifact hash'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
    // The origin chat really shows when the row carries one.
    expect(find.text('From chat · Landing page redesign'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactDetailPage(data: _codeData), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsWidgets);
    expect(find.byType(V2ArtifactPreview), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no host actions means no menu and no Open button', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('the single primary action is Open', (tester) async {
    _phone(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(data: _codeData, onOpenExternally: () => opened++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open'), findsOneWidget);
    await tester.tap(find.text('Open'));
    expect(opened, 1);
  });

  testWidgets('secondary actions live in the menu', (tester) async {
    _phone(tester);
    var downloads = 0;
    var shares = 0;
    var studio = 0;
    var deletes = 0;
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: _codeData,
          onDownload: () => downloads++,
          onShareLink: () => shares++,
          onOpenInStudio: () => studio++,
          onDelete: () => deletes++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Open in Studio'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(downloads, 1);

    await _openMenu(tester);
    await tester.tap(find.text('Share link'));
    await tester.pumpAndSettle();
    expect(shares, 1);
    // The host owns the share result, so the screen does not claim a copy.
    expect(find.text('Link copied'), findsNothing);

    await _openMenu(tester);
    await tester.tap(find.text('Open in Studio'));
    await tester.pumpAndSettle();
    expect(studio, 1);

    await _openMenu(tester);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deletes, 0, reason: 'delete is confirmed first');
    expect(find.text('Delete this artifact?'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(deletes, 1);
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
    expect(find.text('It may have been deleted.'), findsOneWidget);
    await tester.tap(find.text('Back'));
    expect(back, 1);
  });

  testWidgets('documents show preview plus metadata rows', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactDetailPage(data: _documentData)));
    await tester.pumpAndSettle();

    expect(find.byType(V2ArtifactPreview), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('18 pages'), findsOneWidget);
    expect(find.text('File type'), findsOneWidget);
    expect(find.text('Preview'), findsNothing);
    expect(find.text('Details'), findsNothing);
  });

  testWidgets('images preview inline', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _imageData)));
    await tester.pumpAndSettle();

    expect(find.text('No image preview'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('PNG image'), findsOneWidget);
    // No chat on the row: no origin line is invented.
    expect(find.textContaining('From chat'), findsNothing);
  });

  testWidgets('preview adds no header, no note and no extra rows', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();

    // Type and size live in the metadata rows, never twice on the page.
    expect(find.text('HTML5 + Tailwind · 14.2 KB'), findsNothing);
    expect(find.text('Read-only preview.'), findsNothing);
    expect(find.text('Lines of code'), findsOneWidget);
    expect(find.text('Access'), findsOneWidget);
    expect(find.byType(OButton), findsNothing);
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
  });

  testWidgets('metadata is capped at three rows', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: V2ArtifactDetailData(
            name: 'report.pdf',
            details: <V2ArtifactDetailRow>[
              V2ArtifactDetailRow(label: 'One', value: '1'),
              V2ArtifactDetailRow(label: 'Two', value: '2'),
              V2ArtifactDetailRow(label: 'Three', value: '3'),
              V2ArtifactDetailRow(label: 'Four', value: '4'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('One'), findsOneWidget);
    expect(find.text('Three'), findsOneWidget);
    expect(find.text('Four'), findsNothing);
  });

  testWidgets('content fits 320 dp at 200 % text in light and dark', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      _narrowPhone(tester);
      await tester.pumpWidget(
        _narrowApp(
          ArtifactDetailPage(
            data: _codeData,
            onDownload: () {},
            onOpenExternally: () {},
          ),
          dark: dark,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('portfolio-index.html'), findsWidgets);
      _expectNoClippedText(tester);
      await _scrollThrough(tester);
    }
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

    await _openMenu(tester);
    expect(find.text('Copy link'), findsOneWidget);
    await tester.tap(find.text('Copy link'));
    await tester.pump();
    await tester.pump();

    expect(copied, 'https://ovid.site/a/portfolio-index');
    expect(find.text('Link copied'), findsOneWidget);
  });

  testWidgets('Open opens the real URL without a handler', (tester) async {
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

    await tester.tap(find.text('Open'));
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
    expect(find.text('Metadata only'), findsNothing);
  });

  testWidgets('the preview kind is inferred from the file name', (
    tester,
  ) async {
    _phone(tester);
    const names = <String, String>{
      'shot.png': 'No image preview',
      'module.ts': 'No preview.',
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

      final header = find.descendant(
        of: find.byType(AppBar),
        matching: find.text(longName),
      );
      final title = tester.widget<Text>(header);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      final box = tester.getSize(header);
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(box.width, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the preview announces its kind', (tester) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    final cases = <V2ArtifactDetailData, Pattern>{
      _codeData: RegExp('Code preview'),
      _documentData: RegExp('Document, metadata only'),
      _imageData: RegExp('Image preview of token-usage-breakdown.png'),
    };
    for (final entry in cases.entries) {
      await tester.pumpWidget(_app(ArtifactDetailPage(data: entry.key)));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(entry.value),
        findsOneWidget,
        reason: entry.key.name,
      );
    }
    handle.dispose();
  });

  testWidgets('Download writes a real file and says so', (tester) async {
    // Real file I/O only runs in the real async zone; the widget-test zone
    // fakes timers, so the temp directory is created inside runAsync.
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ovid-artifact-test'),
    ))!;
    final source = File('${dir.path}/notes.txt')
      ..writeAsStringSync('first line\nsecond line');
    V2TranscriptIo.setDownloadDirectoryOverride(dir.path);
    addTearDown(() {
      V2TranscriptIo.reset();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: V2ArtifactDetailData(
            name: 'notes.txt',
            previewKind: V2ArtifactPreviewKind.document,
            documentText: 'first line\nsecond line',
            downloadUrl: source.uri.toString(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The whole download interaction runs in the real async zone: reading and
    // writing the file are real I/O, which only resumes there.
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    final saved = File('${dir.path}/Ovid/notes.txt');
    expect(saved.existsSync(), isTrue);
    expect(saved.readAsStringSync(), 'first line\nsecond line');
    expect(find.text('Saved notes.txt'), findsOneWidget);
  });

  testWidgets('loading, error, missing and content all render', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(
            status: V2ArtifactDetailStatus.loading,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(OSkeletonList), findsOneWidget);

    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(
            status: V2ArtifactDetailStatus.error,
          ),
          onRetry: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(
            status: V2ArtifactDetailStatus.missing,
          ),
          onBackToArtifacts: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('This artifact is gone'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);

    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _codeData)));
    await tester.pumpAndSettle();
    expect(find.byType(V2ArtifactPreview), findsOneWidget);
    expect(find.text('Lines of code'), findsOneWidget);
  });

  testWidgets('fits 320 to 1280 in both themes and text scales', (
    tester,
  ) async {
    for (final width in <double>[320, 600, 1024, 1280]) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: ArtifactDetailPage(
                data: _codeData,
                onDownload: () {},
                onOpenExternally: () {},
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: '$width dp at ${scale}x (${dark ? 'dark' : 'light'})',
          );
          expect(find.text('portfolio-index.html'), findsWidgets);
          // The body is centred and capped, never stretched.
          expect(
            tester.getSize(find.byType(V2ArtifactPreview)).width,
            lessThanOrEqualTo(720),
          );
        }
      }
    }
  });
}
