import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/conversation_share_sheet.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

import 'conversation_share_service_test.dart' show shareSession;

Future<void> _open(
  WidgetTester tester, {
  required Size size,
  required double scale,
  required WidgetBuilder sheet,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showAetherSheet<void>(context: context, builder: sheet),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('a ListView body at 320x568 / 2.0x keeps actions hit-testable '
        '(dark=$dark)', (tester) async {
      Aether.dark = dark;
      addTearDown(() => Aether.dark = false);
      var saved = false;
      await _open(
        tester,
        size: const Size(320, 568),
        scale: 2,
        sheet: (context) => AetherSheet(
          title: 'A long sheet title that wraps at large text',
          actions: [
            AetherGhostButton(label: 'Cancel', onPressed: () {}),
            AetherPrimaryButton(label: 'Save', onPressed: () => saved = true),
          ],
          child: ListView(
            children: [
              for (var i = 0; i < 40; i++) ListTile(title: Text('Row $i')),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Save').hitTestable(), findsOneWidget);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
      // The list scrolls inside the clamped body; nothing else has to.
      expect(find.text('Row 0').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Save'));
      expect(saved, isTrue);
    });
  }

  testWidgets('share sheet "Create link" is visible at 360x640 / 1.3x '
      'without scrolling', (tester) async {
    await _open(
      tester,
      size: const Size(360, 640),
      scale: 1.3,
      sheet: (_) => FractionallySizedBox(
        heightFactor: .92,
        child: ConversationShareSheet(
          session: shareSession(),
          service: ConversationShareService(
            baseUrl: '',
            idToken: () async => null,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final create = find.text('Create link');
    expect(create.hitTestable(), findsOneWidget);
    expect(tester.getRect(create).bottom, lessThanOrEqualTo(640));
    // Pinned: not inside any scroll view.
    expect(Scrollable.maybeOf(tester.element(create)), isNull);
  });

  testWidgets('showAetherSheet caps the sheet at 640dp on wide screens', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(1280, 800),
      scale: 1,
      sheet: (_) => const AetherSheet(title: 'Wide', child: Text('body')),
    );
    final surface = find.byKey(const ValueKey('aether-sheet-surface'));
    expect(tester.getSize(surface).width, lessThanOrEqualTo(640));
    expect(find.bySemanticsLabel('Wide'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Wide')).flagsCollection.isHeader,
      isTrue,
    );
  });
}
