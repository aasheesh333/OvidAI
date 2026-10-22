import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_model_preview.dart';
import 'package:ovid_ai/ui/v2/chat/model_picker_preview.dart';

/// The gallery previews are the manual review surface for the Auto/manual
/// contract, so the contract itself is asserted here too. If a preview ever
/// stops reflecting the gate, these tests fail before a reviewer is misled.

Widget _host(Widget child) => MaterialApp(
  theme: OTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('model picker preview', () {
    testWidgets('Free / Go shows locked rows and never fires onSelect', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(const V2ModelPickerPreview(manualModelsAllowed: false)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ovid 2 Flash'), findsOneWidget);
      expect(find.text('Ovid 2 Pro'), findsOneWidget);
      expect(
        find.text('Free plan uses Auto only.'),
        findsOneWidget,
        reason: 'the header explains why every manual row is locked',
      );
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));

      await tester.tap(find.text('Ovid 2 Pro'));
      await tester.pumpAndSettle();

      expect(find.textContaining('onSelect 0'), findsOneWidget);
      expect(find.textContaining('onSelect did not fire'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Free / Go still lets Auto through', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(const V2ModelPickerPreview(manualModelsAllowed: false)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('onSelect 1'), findsOneWidget);
      expect(find.textContaining('onSelect("auto") fired'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Plus / Pro fires onSelect with the picked model', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(const V2ModelPickerPreview(manualModelsAllowed: true)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Smart routing'), findsOneWidget);
      expect(find.text('Free plan uses Auto only.'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
      expect(
        find.text('All models are available on your plan.'),
        findsNothing,
        reason: 'the minimal picker has no footer paragraph',
      );

      await tester.tap(find.text('Ovid 2 Pro'));
      await tester.pumpAndSettle();

      expect(find.textContaining('onSelect 1'), findsOneWidget);
      expect(
        find.textContaining('onSelect("ovid-2-pro") fired'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives 320 dp at 200 % text', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: _host(const V2ModelPickerPreview(manualModelsAllowed: false)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('chat model preview', () {
    testWidgets('Auto answer names the router, manual answer names the model', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_host(const V2ChatModelPreview()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'add a dark mode toggle',
      );
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Auto routed'), findsOneWidget);

      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'refactor billing');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('You picked this model manually'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty drafts are not sent', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_host(const V2ChatModelPreview()));
      await tester.pumpAndSettle();

      expect(find.text('Test Auto vs manual'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.pump();

      expect(find.text('Test Auto vs manual'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
