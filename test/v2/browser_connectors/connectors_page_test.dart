import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

const _connectors = <V2Connector>[
  V2Connector(
    id: 'github',
    name: 'GitHub',
    description: 'Sync repositories, branches, and pull requests',
    connected: true,
    category: 'Code',
    icon: Icons.code_rounded,
  ),
  V2Connector(
    id: 'drive',
    name: 'Google Drive',
    description: 'Import project docs, PDFs, and assets',
    connected: true,
    category: 'Files',
    icon: Icons.add_to_drive_outlined,
  ),
  V2Connector(
    id: 'notion',
    name: 'Notion',
    description: 'Search pages and create project wikis',
    connected: true,
    enabled: false,
    category: 'Notes',
    icon: Icons.edit_note_rounded,
  ),
  V2Connector(
    id: 'gmail',
    name: 'Gmail',
    description: 'Draft emails and summaries',
    connected: false,
    category: 'Mail',
    icon: Icons.mail_outline_rounded,
    popular: true,
  ),
  V2Connector(
    id: 'slack',
    name: 'Slack',
    description: 'Send notifications and alerts',
    connected: false,
    category: 'Chat',
    icon: Icons.forum_outlined,
    popular: true,
  ),
  V2Connector(
    id: 'figma',
    name: 'Figma',
    description: 'Inspect files and export components',
    connected: false,
    category: 'Design',
    icon: Icons.draw_outlined,
  ),
];

V2ConnectorsData _data({
  V2ConnectorsStatus status = V2ConnectorsStatus.content,
  List<V2Connector> connectors = _connectors,
}) {
  return V2ConnectorsData(connectors: connectors, status: status);
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(_app(child, theme: theme));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// Pumps at a phone-sized viewport with a text scaler, and fails if any laid-out
/// text paints outside the viewport (overflow, clipped or pushed off-screen).
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double scale = 2,
  double width = 320,
}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: inner!,
      ),
      home: child,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

void _expectNoTextOutsideScreen(WidgetTester tester) {
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final paragraph in tester.allRenderObjects.whereType<RenderParagraph>()) {
    if (!paragraph.attached || !paragraph.hasSize) continue;
    final box = paragraph.localToGlobal(Offset.zero) & paragraph.size;
    // Text inside a horizontal list is meant to sit off-screen until scrolled,
    // so only its vertical fit inside that strip matters; everything else must
    // stay inside the screen width (the vertical list may extend below the
    // fold).
    final strip = _horizontalViewportRect(paragraph);
    if (strip != null) {
      expect(
        box.top >= strip.top - 0.5 && box.bottom <= strip.bottom + 0.5,
        isTrue,
        reason: '"${paragraph.text.toPlainText()}" paints at $box, taller '
            'than its ${strip.height} dp horizontal strip',
      );
      continue;
    }
    expect(
      box.left >= -0.5 && box.right <= screen.width + 0.5,
      isTrue,
      reason: '"${paragraph.text.toPlainText()}" paints at $box '
          'outside the ${screen.width} dp viewport',
    );
  }
}

/// Screen rect of the nearest horizontal strip that clips [node], if any.
Rect? _horizontalViewportRect(RenderObject node) {
  RenderObject? parent = node.parent;
  while (parent != null) {
    if (parent is RenderViewport) {
      final axis = parent.axisDirection;
      if (axis == AxisDirection.left || axis == AxisDirection.right) {
        return parent.localToGlobal(Offset.zero) & parent.size;
      }
    }
    parent = parent.parent;
  }
  return null;
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 12; i++) {
    await tester.drag(scrollable, const Offset(0, -220));
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('connectors page shows installed rows, popular grid and limit', (
    tester,
  ) async {
    await _pump(tester, ConnectorsPage(data: _data()));

    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('POPULAR CONNECTORS'), findsOneWidget);
    expect(find.text('2 active'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Gmail'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Slack'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Free plan: 0 custom connectors. Go: 5.'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Free plan: 0 custom connectors. Go: 5.'), findsOneWidget);
  });

  testWidgets('connectors page renders in dark theme', (tester) async {
    await _pump(tester, ConnectorsPage(data: _data()), theme: OTheme.dark());

    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('POPULAR CONNECTORS'), findsOneWidget);
  });

  testWidgets('installed empty state offers browsing the catalog', (
    tester,
  ) async {
    var browsed = 0;
    V2ConnectorsTab? tab;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(
          connectors: _connectors
              .where((connector) => !connector.connected)
              .toList(),
        ),
        onBrowseConnectors: () => browsed++,
        onTabChanged: (value) => tab = value,
      ),
    );

    expect(find.text('No connectors yet'), findsOneWidget);
    expect(find.text('Browse connectors'), findsOneWidget);

    await tester.tap(find.text('Browse connectors'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(browsed, 1);
    expect(tab, V2ConnectorsTab.available);
  });

  testWidgets('tapping an installed connector opens it', (tester) async {
    String? opened;
    await _pump(
      tester,
      ConnectorsPage(data: _data(), onOpen: (id) => opened = id),
    );

    await tester.tap(find.text('GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 'github');
  });

  testWidgets('the installed switch reports the new value', (tester) async {
    String? toggledId;
    bool? toggledValue;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        onToggle: (id, value) {
          toggledId = id;
          toggledValue = value;
        },
      ),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(toggledId, 'github');
    expect(toggledValue, isFalse);
  });

  testWidgets('switching to Available shows the catalog rows', (tester) async {
    V2ConnectorsTab? tab;
    await _pump(
      tester,
      ConnectorsPage(data: _data(), onTabChanged: (value) => tab = value),
    );

    expect(find.text('Figma'), findsNothing);
    await tester.tap(find.text('Available'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tab, V2ConnectorsTab.available);
    expect(find.text('Figma'), findsOneWidget);
    expect(find.text('Connect'), findsWidgets);
  });

  testWidgets('a category chip filters the installed list', (tester) async {
    String? category;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        onCategoryChanged: (value) => category = value,
      ),
    );

    await tester.tap(find.text('Code'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(category, 'Code');
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Google Drive'), findsNothing);
    expect(find.text('Notion'), findsNothing);
  });

  testWidgets('an empty search offers clear filters', (tester) async {
    await _pump(tester, ConnectorsPage(data: _data()));

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('No installed connectors match'), findsOneWidget);
    expect(find.text('Clear filters'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('loading state shows skeleton rows', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(status: V2ConnectorsStatus.loading)),
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('plan note can open the upgrade path', (tester) async {
    var upgrades = 0;
    await _pump(
      tester,
      ConnectorsPage(data: _data(), onUpgrade: () => upgrades++),
    );

    await tester.scrollUntilVisible(
      find.text('Upgrade'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Upgrade'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(upgrades, 1);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(status: V2ConnectorsStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('installed tab fits 320 dp at 200% text (light)', (tester) async {
    await _pumpNarrow(tester, ConnectorsPage(data: _data()));
    _expectNoTextOutsideScreen(tester);
    await _scrollThrough(tester);
    _expectNoTextOutsideScreen(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('available tab fits 320 dp at 200% text (dark)', (tester) async {
    await _pumpNarrow(
      tester,
      ConnectorsPage(data: _data()),
      theme: OTheme.dark(),
    );
    await tester.tap(find.text('Available'));
    await tester.pump(const Duration(milliseconds: 400));
    _expectNoTextOutsideScreen(tester);
    await _scrollThrough(tester);
    _expectNoTextOutsideScreen(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both tabs fit 320 dp at normal text', (tester) async {
    await _pumpNarrow(tester, ConnectorsPage(data: _data()), scale: 1);
    _expectNoTextOutsideScreen(tester);

    await tester.tap(find.text('Available'));
    await tester.pump(const Duration(milliseconds: 400));
    await _scrollThrough(tester);
    _expectNoTextOutsideScreen(tester);

    await tester.drag(
      find.byType(Scrollable).first,
      const Offset(0, 4000),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Installed'));
    await tester.pump(const Duration(milliseconds: 400));
    await _scrollThrough(tester);
    _expectNoTextOutsideScreen(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states fit 320 dp at 200% text', (tester) async {
    await _pumpNarrow(
      tester,
      ConnectorsPage(
        data: _data(
          connectors: _connectors
              .where((connector) => !connector.connected)
              .toList(),
        ),
      ),
    );
    expect(find.text('No connectors yet'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);

    await _pumpNarrow(
      tester,
      ConnectorsPage(data: _data(status: V2ConnectorsStatus.error)),
    );
    expect(find.text('Something went wrong'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);
  });

  testWidgets('an empty catalog explains itself on the available tab', (
    tester,
  ) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(connectors: const <V2Connector>[])),
    );

    await tester.tap(find.text('Available'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('No connectors available'), findsOneWidget);
    expect(find.text('Everything is connected'), findsNothing);
  });

  testWidgets('reduced motion still shows every row', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: inner!,
        ),
        home: ConnectorsPage(data: _data()),
      ),
    );
    await tester.pump();

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
  });

  testWidgets('the switch keeps its label and state for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        onOpen: (_) {},
        onToggle: (_, _) {},
      ),
    );

    final data = tester
        .getSemantics(find.byType(Switch).first)
        .getSemanticsData();
    expect(data.label, contains('GitHub'));
    expect(data.flagsCollection.isToggled.toBoolOrNull(), isTrue);
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isTrue);

    // The row itself is still a button with one label, even though the switch
    // lives inside the same card.
    final row = find.bySemanticsLabel(
      'GitHub, Sync repositories, branches, and pull requests',
    );
    expect(row, findsOneWidget);
    expect(
      tester.getSemantics(row).getSemanticsData().flagsCollection.isButton,
      isTrue,
    );
    handle.dispose();
  });

  testWidgets('a switch with no callback is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, ConnectorsPage(data: _data()));

    final data = tester
        .getSemantics(find.byType(Switch).first)
        .getSemanticsData();
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isFalse);
    handle.dispose();
  });

  testWidgets('the app bar keeps the labelled action on a wide screen', (
    tester,
  ) async {
    await _pump(tester, ConnectorsPage(data: _data()));
    expect(find.text('Add custom'), findsOneWidget);
  });

  testWidgets('a 360 dp phone keeps the labelled add action', (tester) async {
    await _pumpNarrow(tester, ConnectorsPage(data: _data()), scale: 1, width: 360);
    _expectNoTextOutsideScreen(tester);
    expect(find.text('Add custom'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 320 dp phone falls back to the icon add action', (
    tester,
  ) async {
    await _pumpNarrow(tester, ConnectorsPage(data: _data()), scale: 1);
    _expectNoTextOutsideScreen(tester);
    expect(find.text('Add custom'), findsNothing);
    expect(find.bySemanticsLabel('Add custom connector'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
