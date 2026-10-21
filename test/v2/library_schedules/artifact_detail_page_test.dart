import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';

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
  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
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
  for (var i = 0; i < 60; i++) {
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

/// The two overlay pills sit inside the preview stage at every text scale.
void _expectStagePillsInsideStage(WidgetTester tester) {
  final responsive = tester.getRect(find.text('Responsive view'));
  final live = tester.getRect(find.text('Live preview'));
  final stage = tester.getRect(
    find
        .ancestor(
          of: find.text('Responsive view'),
          matching: find.byType(ClipRRect),
        )
        .first,
  );
  expect(responsive.overlaps(live), isFalse);
  expect(responsive.left, greaterThanOrEqualTo(stage.left));
  expect(responsive.right, lessThanOrEqualTo(stage.right));
  expect(live.left, greaterThanOrEqualTo(stage.left));
  expect(live.right, lessThanOrEqualTo(stage.right));
  expect(live.bottom, lessThanOrEqualTo(stage.bottom));
}

const _data = V2ArtifactDetailData(
  name: 'portfolio-index.html',
  typeLabel: 'HTML5 + Tailwind',
  sizeLabel: '14.2 KB',
  createdLabel: 'Created today at 10:24 AM',
  versionLabel: 'v2.4 Ready',
  sourceChatTitle: 'Landing page redesign',
  sourcePrompt: 'Landing page redesign',
  previewHeadline: 'Building generative interfaces & reactive engines.',
  previewSubtitle:
      'Full-stack developer crafting resilient interfaces with precision.',
  previewTag: 'Available for Q3 projects',
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

Widget _app(Widget home, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: home,
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('renders the artifact in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('Artifact detail'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('HTML5 + Tailwind'), findsOneWidget);
    expect(find.text('v2.4 Ready'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('renders the artifact in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ArtifactDetailPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('Share link'), findsOneWidget);
    expect(find.text('Open in Studio'), findsOneWidget);
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
      _app(
        ArtifactDetailPage(data: _data, onDownload: () => downloads++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download'));
    expect(downloads, 1);
  });

  testWidgets('Details tab reveals the technical rows', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _data)));
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
      _app(
        ArtifactDetailPage(data: _data, onOpenChat: () => chats++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Made in chat'));
    expect(chats, 1);
  });

  testWidgets('content fits 320 dp at 200 % text in light', (tester) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(const ArtifactDetailPage(data: _data)),
    );
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    _expectStagePillsInsideStage(tester);
    _expectNoClippedText(tester);

    await tester.scrollUntilVisible(
      find.text('Download'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Download'), findsOneWidget);
    await _scrollThrough(tester);
  });

  testWidgets('details fit 320 dp at 200 % text in dark', (tester) async {
    _narrowPhone(tester);
    await tester.pumpWidget(
      _narrowApp(const ArtifactDetailPage(data: _data), dark: true),
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
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _data)));
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
            child: const ArtifactDetailPage(data: _data),
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
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _data)));
    await tester.pumpAndSettle();

    // `agent_manifest.ts` must not be labelled HTML.
    expect(find.text('TS'), findsOneWidget);
    expect(find.text('HTML'), findsNothing);

    await tester.pumpWidget(
      _app(
        const ArtifactDetailPage(
          data: V2ArtifactDetailData(
            previewCodeFile: 'portfolio-index.html',
            previewCode: '<main></main>',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('HTML'), findsOneWidget);
  });

  testWidgets('Download is announced as disabled with no handler', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    await tester.pumpWidget(_app(const ArtifactDetailPage(data: _data)));
    await tester.pumpAndSettle();

    final button = tester.widget<OButton>(
      find.widgetWithText(OButton, 'Download'),
    );
    expect(button.onPressed, isNull);
    final node = tester.getSemantics(find.widgetWithText(OButton, 'Download'));
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    handle.dispose();
  });
}
