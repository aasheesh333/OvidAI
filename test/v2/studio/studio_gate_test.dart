import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/studio_gate.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: textScale == 1
          ? null
          : (context, content) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: content!,
            ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('shows the blocked copy and opens the picker', (tester) async {
    for (final dark in <bool>[false, true]) {
      var picks = 0;
      await tester.pumpWidget(
        _app(V2StudioGate(onPickFolder: () => picks++), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pick a folder to start coding'), findsOneWidget);
      expect(find.text('Pick a folder'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.byKey(const Key('studio-gate-pick-folder')));
      expect(picks, 1);
    }
  });

  testWidgets('a missing callback leaves the gate action disabled', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2StudioGate()));
    await tester.pumpAndSettle();

    final button = tester.widget<OButton>(
      find.byKey(const Key('studio-gate-pick-folder')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Repository setup is not available yet.'), findsNothing);
  });

  testWidgets('onPickRepo is accepted as an alias', (tester) async {
    var picks = 0;
    await tester.pumpWidget(_app(V2StudioGate(onPickRepo: () => picks++)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('studio-gate-pick-folder')));
    expect(picks, 1);
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(V2StudioGate(onPickFolder: () {}), dark: dark, textScale: 2),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pick a folder to start coding'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'gate overflowed at 320 dp / 200% text '
            '(${dark ? 'dark' : 'light'})',
      );
    }
  });
}
