import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';

void main() {
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);

  HtmlArtifact artifact() => HtmlArtifact.create('session', {
        'title': 'Premium artifact',
        'html': '<main>Hello</main>',
        'css': 'main { color: red; }',
        'javascript': 'console.log("hello");',
      });

  Future<void> pumpArtifact(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlArtifactView(artifact: artifact(), sessionId: 'session'),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('View source'));
    await tester.pump();
  }

  testWidgets('source view presents separately labeled HTML CSS and JavaScript sections',
      (tester) async {
    await pumpArtifact(tester);

    expect(find.text('HTML'), findsOneWidget);
    expect(find.text('CSS'), findsOneWidget);
    expect(find.text('JavaScript'), findsOneWidget);
    expect(find.text('<main>Hello</main>'), findsOneWidget);
    expect(find.text('main { color: red; }'), findsOneWidget);
    expect(find.text('console.log("hello");'), findsOneWidget);
    expect(find.byTooltip('Copy HTML'), findsOneWidget);
    expect(find.byTooltip('Copy CSS'), findsOneWidget);
    expect(find.byTooltip('Copy JavaScript'), findsOneWidget);
  }, variant: linux);

  testWidgets('copying a source section exposes live feedback', (tester) async {
    await pumpArtifact(tester);

    await tester.tap(find.byTooltip('Copy CSS'));
    await tester.pump();

    expect(find.text('CSS copied'), findsOneWidget);
    expect(
      await Clipboard.getData(Clipboard.kTextPlain),
      isNotNull,
    );
  }, variant: linux);

  testWidgets('unsupported preview keeps a visible non-blocking lifecycle status',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HtmlArtifactView(artifact: artifact(), sessionId: 'session'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Preview status'), findsOneWidget);
    expect(find.text('Interactive preview requires Android.'), findsOneWidget);
    expect(find.byTooltip('View source'), findsOneWidget);
  }, variant: linux);
}
