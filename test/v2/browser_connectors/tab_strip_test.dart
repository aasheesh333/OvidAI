import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/browser/tab_strip.dart';

/// A real 1 × 1 PNG, used to prove the strip draws an injected favicon.
final _favicon = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// Sample session for the tests only. The widget itself ships no data.
const _tabs = <V2BrowserTabItem>[
  V2BrowserTabItem(id: 'docs', title: 'Docs', host: 'ovidsi.com'),
  V2BrowserTabItem(
    id: 'github',
    title: 'GitHub',
    host: 'github.com',
    icon: Icons.code_rounded,
  ),
  V2BrowserTabItem(
    id: 'inbox',
    title: 'Inbox',
    host: 'mail.ovidsi.com',
    headless: true,
  ),
];

const _scrollKey = ValueKey('v2-browser-tab-strip-scroll');

Widget _app(Widget child, {ThemeData? theme, double textScale = 1}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: (context, content) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: content!,
    ),
    home: Scaffold(
      body: Align(alignment: Alignment.topCenter, child: child),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 1,
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(_app(child, theme: theme, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('renders every open tab and no ownership note', (tester) async {
    await _pump(
      tester,
      const BrowserTabStrip(tabs: _tabs, activeTabId: 'docs'),
    );

    // Icon-only: the favicon is the tab, never a title label.
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-github')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-inbox')), findsOneWidget);
    expect(find.text('Docs'), findsNothing);
    expect(find.text('GitHub'), findsNothing);
    expect(find.text('Inbox'), findsNothing);
    expect(find.byKey(_scrollKey), findsOneWidget);
    expect(find.text('Ovid opens tabs'), findsNothing);
  });

  testWidgets('renders in dark theme', (tester) async {
    await _pump(
      tester,
      const BrowserTabStrip(tabs: _tabs, activeTabId: 'github'),
      theme: OTheme.dark(),
    );

    expect(find.byKey(const ValueKey('v2-browser-tab-github')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
  });

  testWidgets('there is no add control at all', (tester) async {
    await _pump(tester, const BrowserTabStrip(tabs: _tabs));

    // Tabs are agent-owned: no disabled plus, no tooltip explaining one.
    expect(find.byKey(const ValueKey('v2-browser-tab-add')), findsNothing);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.text('Ovid opens tabs'), findsNothing);
  });

  testWidgets('no tap, long-press or key can create a tab', (tester) async {
    final semantics = tester.ensureSemantics();
    var selects = 0;
    await _pump(
      tester,
      BrowserTabStrip(tabs: _tabs, onSelectTab: (_) => selects++),
    );

    await tester.longPress(find.byKey(const ValueKey('v2-browser-tab-docs')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));

    // The strip still holds exactly the tabs the agent opened.
    expect(find.byKey(const ValueKey('v2-browser-tab-docs')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-github')), findsOneWidget);
    expect(find.byKey(const ValueKey('v2-browser-tab-inbox')), findsOneWidget);
    expect(find.text('New tab'), findsNothing);
    expect(selects, 1); // the long-press selected that tab, it created none
    semantics.dispose();
  });

  testWidgets('the active tab is marked and only one tab is active', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      BrowserTabStrip(tabs: _tabs, activeTabId: 'github', onSelectTab: (_) {}),
    );
    expect(
      find.byKey(const ValueKey('v2-browser-tab-active-github')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('v2-browser-tab-active-docs')),
      findsNothing,
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('v2-browser-tab-github')),
    );
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, contains('GitHub'));
    semantics.dispose();
  });

  testWidgets('a missing active id falls back to the first tab', (
    tester,
  ) async {
    await _pump(
      tester,
      const BrowserTabStrip(tabs: _tabs, activeTabId: 'gone'),
    );

    expect(
      find.byKey(const ValueKey('v2-browser-tab-active-docs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('v2-browser-tab-active-github')),
      findsNothing,
    );
  });

  testWidgets('tapping a tab switches to it', (tester) async {
    String? selected;
    await _pump(
      tester,
      BrowserTabStrip(
        tabs: _tabs,
        activeTabId: 'docs',
        onSelectTab: (id) => selected = id,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('v2-browser-tab-github')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(selected, 'github');
  });

  testWidgets('closing a tab does not also switch to it', (tester) async {
    String? closed;
    String? selected;
    await _pump(
      tester,
      BrowserTabStrip(
        tabs: _tabs,
        activeTabId: 'docs',
        onSelectTab: (id) => selected = id,
        onCloseTab: (id) => closed = id,
      ),
    );

    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(closed, 'docs');
    expect(selected, isNull);
  });

  testWidgets('close controls are 48 dp targets for every tab', (tester) async {
    await _pump(tester, BrowserTabStrip(tabs: _tabs, onCloseTab: (_) {}));

    for (final tab in _tabs) {
      final size = tester.getSize(
        find.byKey(ValueKey('v2-browser-tab-close-${tab.id}')),
      );
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('a tab with no close callback has no close control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const BrowserTabStrip(tabs: _tabs));

    // There is no server close op, so an un-wired strip must not show an X
    // that cannot close anything.
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.bySemanticsLabel('Close Docs'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a tab with closable false has no close control', (tester) async {
    await _pump(
      tester,
      const BrowserTabStrip(
        tabs: [
          V2BrowserTabItem(
            id: 'pinned',
            title: 'Pinned',
            host: 'ovidsi.com',
            closable: false,
          ),
        ],
        onCloseTab: _noop,
      ),
    );

    expect(find.byKey(const ValueKey('v2-browser-tab-pinned')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('v2-browser-tab-close-pinned')),
      findsNothing,
    );
    expect(find.bySemanticsLabel('Close Pinned'), findsNothing);
  });

  testWidgets('an injected favicon replaces the fallback glyph', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserTabStrip(
        tabs: [
          V2BrowserTabItem(
            id: 'docs',
            title: 'Docs',
            host: 'ovidsi.com',
            favicon: _favicon,
          ),
          const V2BrowserTabItem(
            id: 'github',
            title: 'GitHub',
            host: 'github.com',
            icon: Icons.code_rounded,
          ),
        ],
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, same(_favicon));
    expect(find.byIcon(Icons.code_rounded), findsOneWidget);
    expect(find.byIcon(Icons.language_rounded), findsNothing);
  });

  testWidgets('the headless mark is an icon, not a word', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const BrowserTabStrip(tabs: _tabs));

    expect(
      find.byKey(const ValueKey('v2-browser-tab-headless-inbox')),
      findsOneWidget,
    );
    expect(find.byTooltip('Headless'), findsOneWidget);
    expect(find.text('Headless'), findsNothing);
    expect(
      find.byKey(const ValueKey('v2-browser-tab-headless-docs')),
      findsNothing,
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('v2-browser-tab-inbox')),
    );
    expect(node.label, contains('Headless'));
    semantics.dispose();
  });

  testWidgets('the strip scrolls horizontally when tabs overflow', (
    tester,
  ) async {
    final many = <V2BrowserTabItem>[
      for (var i = 0; i < 8; i++)
        V2BrowserTabItem(
          id: 'tab-$i',
          title: 'Open page $i',
          host: 'site$i.com',
        ),
    ];
    await _pump(
      tester,
      BrowserTabStrip(tabs: many),
      size: const Size(320, 640),
    );

    final scrollable = find.descendant(
      of: find.byKey(_scrollKey),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThan(0));

    await tester.drag(find.byKey(_scrollKey), const Offset(-320, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 dp at 200 % text lays out without overflow (light)', (
    tester,
  ) async {
    await _pump(
      tester,
      BrowserTabStrip(
        tabs: [
          const V2BrowserTabItem(
            id: 'docs',
            title: 'Ovid Si platform documentation',
            host: 'ovidsi.com',
            headless: true,
          ),
          const V2BrowserTabItem(
            id: 'github',
            title: 'A very long repository name',
            host: 'github.com',
          ),
        ],
        activeTabId: 'docs',
        onSelectTab: (_) {},
        onCloseTab: (_) {},
      ),
      textScale: 2,
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(_scrollKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey('v2-browser-tab-close-docs')),
      findsOneWidget,
    );
  });

  testWidgets('320 dp at 200 % text lays out without overflow (dark)', (
    tester,
  ) async {
    await _pump(
      tester,
      const BrowserTabStrip(tabs: _tabs, activeTabId: 'inbox'),
      theme: OTheme.dark(),
      textScale: 2,
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('v2-browser-tab-inbox')), findsOneWidget);
  });

  testWidgets('icon-only tabs still announce their names', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      BrowserTabStrip(tabs: _tabs, activeTabId: 'docs', onSelectTab: (_) {}),
    );

    expect(find.bySemanticsLabel('Docs, ovidsi.com'), findsOneWidget);
    expect(find.bySemanticsLabel('GitHub, github.com'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Inbox, mail.ovidsi.com, Headless')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('an empty strip renders nothing', (tester) async {    await _pump(
      tester,
      const BrowserTabStrip(tabs: <V2BrowserTabItem>[]),
      textScale: 2,
      size: const Size(320, 640),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(_scrollKey), findsNothing);
    expect(find.text('No tabs yet. Ovid opens the first one.'), findsNothing);
    expect(tester.getSize(find.byType(BrowserTabStrip)).height, 0);
  });
}

void _noop(String _) {}
