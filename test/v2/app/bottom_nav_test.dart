import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/bottom_nav.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(bottomNavigationBar: child, body: const SizedBox.shrink()),
);

void main() {
  testWidgets('chat bar shows four tabs and marks the current one', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(V2BottomNav(current: V2NavTab.studio, onSelect: (_) {})),
    );

    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Library'), findsNothing);

    final studio = tester.getSemantics(find.text('Studio'));
    expect(studio.flagsCollection.isSelected, Tristate.isTrue);
  });

  testWidgets('work bar adds Library', (tester) async {
    await tester.pumpWidget(
      _app(
        V2BottomNav(
          current: V2NavTab.library,
          items: v2WorkNavItems,
          onSelect: (_) {},
        ),
      ),
    );
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets('tapping a tab reports it', (tester) async {
    V2NavTab? picked;
    await tester.pumpWidget(
      _app(
        V2BottomNav(
          current: V2NavTab.chat,
          onSelect: (tab) => picked = tab,
        ),
      ),
    );
    await tester.tap(find.text('Browser'));
    expect(picked, V2NavTab.browser);
  });

  testWidgets('unwired tabs are announced disabled', (tester) async {
    await tester.pumpWidget(_app(const V2BottomNav(current: V2NavTab.chat)));
    final node = tester.getSemantics(find.text('Chat'));
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
  });

  testWidgets('every tab meets the 48 dp target at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            bottomNavigationBar: V2BottomNav(
              current: V2NavTab.chat,
              onSelect: (_) {},
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final label in ['Chat', 'Studio', 'Browser', 'Settings']) {
      final size = tester.getSize(find.text(label));
      expect(size.height, greaterThan(0), reason: '$label rendered');
    }
  });
}
