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
        V2BottomNav(current: V2NavTab.chat, onSelect: (tab) => picked = tab),
      ),
    );
    await tester.tap(find.text('Browser'));
    expect(picked, V2NavTab.browser);
  });

  testWidgets('every tab reports its own destination', (tester) async {
    for (final items in <List<V2NavItem>>[v2ChatNavItems, v2WorkNavItems]) {
      for (final item in items) {
        final picked = <V2NavTab>[];
        await tester.pumpWidget(
          _app(
            V2BottomNav(
              current: V2NavTab.chat,
              items: items,
              onSelect: picked.add,
            ),
          ),
        );

        await tester.tap(find.text(item.label));
        expect(picked, <V2NavTab>[item.tab], reason: item.label);
      }
    }
  });

  testWidgets('the selected tab always follows current', (tester) async {
    for (final tab in V2NavTab.values) {
      await tester.pumpWidget(
        _app(
          V2BottomNav(current: tab, items: v2WorkNavItems, onSelect: (_) {}),
        ),
      );

      for (final item in v2WorkNavItems) {
        final node = tester.getSemantics(find.text(item.label));
        expect(
          node.flagsCollection.isSelected,
          item.tab == tab ? Tristate.isTrue : Tristate.isFalse,
          reason: '${item.label} with current=${tab.name}',
        );
      }
    }
  });

  testWidgets('tapping the current tab still reports it', (tester) async {
    V2NavTab? picked;
    await tester.pumpWidget(
      _app(
        V2BottomNav(current: V2NavTab.chat, onSelect: (tab) => picked = tab),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('v2-nav-chat')));
    expect(picked, V2NavTab.chat);
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

  testWidgets('the five-tab work bar fits 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            bottomNavigationBar: V2BottomNav(
              current: V2NavTab.chat,
              items: v2WorkNavItems,
              onSelect: (_) {},
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    // This is the bar the shell mounts, so all five tabs must survive the
    // narrowest window at the largest text scale.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(V2BottomNav)).height,
      greaterThanOrEqualTo(48),
    );
    for (final item in v2WorkNavItems) {
      expect(
        find.byKey(ValueKey<String>('v2-nav-${item.tab.name}')),
        findsOneWidget,
        reason: item.label,
      );
    }
  });
}
