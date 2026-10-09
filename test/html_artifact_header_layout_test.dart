import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';

void main() {
  final linux = TargetPlatformVariant.only(TargetPlatform.linux);
  const title = 'An unusually long HTML and CSS preview title';

  for (final (width, scale) in [(800.0, 1.0), (320.0, 1.0), (240.0, 2.0)]) {
    testWidgets('header actions stay usable in one row at $width / $scale', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: HtmlArtifactView(
                artifact: HtmlArtifact.create('owner', {
                  'title': title,
                  'html': '<main>Hello</main>',
                  'css': 'main { color: red; }',
                }),
                sessionId: 'owner',
              ),
            ),
          ),
        ),
      );

      void expectHeader(String sourceAction, String expandAction) {
        expect(tester.takeException(), isNull);
        final titleRect = tester.getRect(find.text(title));
        final sourceRect = tester.getRect(find.byTooltip(sourceAction));
        final expandRect = tester.getRect(find.byTooltip(expandAction));
        expect(sourceRect.center.dy, closeTo(titleRect.center.dy, 1));
        expect(expandRect.center.dy, closeTo(sourceRect.center.dy, 1));
        expect(sourceRect.right, lessThanOrEqualTo(expandRect.left));
        for (final rect in [sourceRect, expandRect]) {
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(width));
        }
        expect(find.byTooltip(sourceAction).hitTestable(), findsOneWidget);
        expect(find.byTooltip(expandAction).hitTestable(), findsOneWidget);
      }

      expectHeader('View source', 'Expand preview');
      await tester.tap(find.byTooltip('View source'));
      await tester.pumpAndSettle();
      expect(find.text('<main>Hello</main>'), findsOneWidget);
      expect(find.text('main { color: red; }'), findsOneWidget);
      expectHeader('Show preview', 'Expand preview');
      await tester.tap(find.byTooltip('Show preview'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);

      await tester.tap(find.byTooltip('Expand preview'));
      await tester.pumpAndSettle();
      expectHeader('View source', 'Exit fullscreen');
      await tester.tap(find.byTooltip('View source'));
      await tester.pumpAndSettle();
      expect(find.text('<main>Hello</main>'), findsOneWidget);
      expectHeader('Show preview', 'Exit fullscreen');
      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pumpAndSettle();
      expectHeader('View source', 'Expand preview');

      await tester.tap(find.byTooltip('Collapse artifact'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('View source'), findsNothing);
      expect(find.text('Preview status'), findsNothing);
      await tester.tap(find.byTooltip('Open artifact'));
      await tester.pumpAndSettle();
      expectHeader('View source', 'Expand preview');
    }, variant: linux);
  }
}
