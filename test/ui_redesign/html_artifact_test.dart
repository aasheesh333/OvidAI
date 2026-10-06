import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Smoke coverage for the Aether redesign of [HtmlArtifactView]. Tests use
/// an explicit Linux variant to exercise the unsupported-platform fallback
/// and source controls without mounting a native Android view.
HtmlArtifact _artifact({String sessionId = 'session-1'}) {
  return HtmlArtifact.create(sessionId, {
    'title': 'Demo artifact',
    'html': '<p>Hello marker</p>',
    'css': 'p { color: red; }',
    'javascript': 'void main() {}',
    'height': 320,
  });
}

Future<void> _pump(
  WidgetTester tester, {
  HtmlArtifact? artifact,
  String sessionId = 'session-1',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: HtmlArtifactView(artifact: artifact, sessionId: sessionId),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // The binding defaults to Android regardless of the host OS. A variant
  // restores the platform even when an assertion fails.
  final platform = TargetPlatformVariant.only(TargetPlatform.linux);

  testWidgets('inline artifact renders AetherCard, title, pill and ghost '
      'controls', (tester) async {
    await _pump(tester, artifact: _artifact());

    expect(find.byType(AetherCard), findsOneWidget);
    expect(find.text('Demo artifact'), findsOneWidget);

    // Title uses the AetherType.title preset (15sp / w600).
    final title = tester.widget<Text>(find.text('Demo artifact'));
    expect(title.style?.fontSize, AetherType.title.fontSize);
    expect(title.style?.fontWeight, AetherType.title.fontWeight);

    // Sandbox marker pill preserved.
    expect(find.text('OFFLINE SANDBOX'), findsOneWidget);

    // Source/expand actions are Aether ghost buttons with visible labels.
    expect(find.byType(AetherGhostButton), findsNWidgets(2));
    expect(
      find.widgetWithText(AetherGhostButton, 'View source'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(AetherGhostButton, 'Expand preview'),
      findsOneWidget,
    );
  }, variant: platform);

  testWidgets('View source toggles source view and restores preview', (
    tester,
  ) async {
    await _pump(tester, artifact: _artifact());

    final fallback = find.textContaining(
      'Interactive preview requires Android.',
    );
    expect(fallback, findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);

    await tester.tap(find.widgetWithText(AetherGhostButton, 'View source'));
    await tester.pump();

    // Label flips and the artifact source is shown as selectable text.
    expect(
      find.widgetWithText(AetherGhostButton, 'Show preview'),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('<p>Hello marker</p>'), findsOneWidget);
    expect(find.textContaining('p { color: red; }'), findsOneWidget);
    expect(find.textContaining('void main() {}'), findsOneWidget);
    expect(fallback, findsNothing);

    await tester.tap(find.widgetWithText(AetherGhostButton, 'Show preview'));
    await tester.pump();

    expect(
      find.widgetWithText(AetherGhostButton, 'View source'),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsNothing);
    expect(fallback, findsOneWidget);
    expect(find.byType(AndroidView), findsNothing);
  }, variant: platform);

  testWidgets('collapse toggle hides and restores the preview body', (
    tester,
  ) async {
    await _pump(tester, artifact: _artifact());

    expect(find.byType(AetherGhostButton), findsNWidgets(2));

    await tester.tap(find.byTooltip('Collapse artifact'));
    await tester.pump();
    expect(find.byType(AetherGhostButton), findsNothing);

    await tester.tap(find.byTooltip('Open artifact'));
    await tester.pump();
    expect(find.byType(AetherGhostButton), findsNWidgets(2));
  }, variant: platform);

  testWidgets('missing or foreign-session artifact shows fallback text', (
    tester,
  ) async {
    await _pump(tester, artifact: null);
    expect(
      find.text(
        'Artifact unavailable: missing, invalid, or owned by another session.',
      ),
      findsOneWidget,
    );
    expect(find.byType(AetherCard), findsNothing);

    await _pump(tester, artifact: _artifact(), sessionId: 'other-session');
    expect(
      find.text(
        'Artifact unavailable: missing, invalid, or owned by another session.',
      ),
      findsOneWidget,
    );
    expect(find.byType(AetherCard), findsNothing);
  }, variant: platform);

  testWidgets('Expand preview opens fullscreen host and Exit fullscreen '
      'returns inline', (tester) async {
    await _pump(tester, artifact: _artifact());

    await tester.tap(find.widgetWithText(AetherGhostButton, 'Expand preview'));
    await tester.pumpAndSettle();

    // Fullscreen dialog host: same ghost controls, flipped expand label.
    expect(
      find.widgetWithText(AetherGhostButton, 'Exit fullscreen'),
      findsOneWidget,
    );
    expect(find.text('Demo artifact'), findsWidgets);

    await tester.tap(find.widgetWithText(AetherGhostButton, 'Exit fullscreen'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(AetherGhostButton, 'Exit fullscreen'),
      findsNothing,
    );
    expect(
      find.widgetWithText(AetherGhostButton, 'Expand preview'),
      findsOneWidget,
    );
    expect(find.byType(AetherCard), findsOneWidget);
  }, variant: platform);
}
