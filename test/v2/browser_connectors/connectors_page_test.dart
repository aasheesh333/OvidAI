import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/catalog_data.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

const _connected = <V2Connector>[
  V2Connector(
    id: 'github',
    name: 'GitHub',
    description: 'Sync repositories, branches, and pull requests',
    connected: true,
    category: 'Code',
    icon: Icons.code_rounded,
    builtIn: true,
  ),
  V2Connector(
    id: 'google-drive',
    name: 'Google Drive',
    description: 'Import project docs, PDFs, and assets',
    connected: true,
    category: 'Files',
    icon: Icons.add_to_drive_outlined,
    builtIn: true,
  ),
  V2Connector(
    id: 'notion',
    name: 'Notion',
    description: 'Search pages and create project wikis',
    connected: true,
    enabled: false,
    category: 'Notes',
    icon: Icons.edit_note_rounded,
    builtIn: true,
  ),
  V2Connector(
    id: 'gmail',
    name: 'Gmail',
    description: 'Draft emails and summaries',
    connected: false,
    category: 'Mail',
    icon: Icons.mail_outline_rounded,
    builtIn: true,
  ),
  V2Connector(
    id: 'slack',
    name: 'Slack',
    description: 'Send notifications and alerts',
    connected: false,
    category: 'Chat',
    icon: Icons.forum_outlined,
    builtIn: true,
  ),
  V2Connector(
    id: 'context7',
    name: 'context7',
    description: 'Up-to-date library docs',
    connected: false,
    category: 'Developer',
    kind: V2ConnectorKind.plugin,
    icon: Icons.menu_book_outlined,
    builtIn: true,
  ),
];

V2ConnectorsData _data({
  V2ConnectorsStatus status = V2ConnectorsStatus.content,
  List<V2Connector> connectors = _connected,
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
  for (final paragraph
      in tester.allRenderObjects.whereType<RenderParagraph>()) {
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
        reason:
            '"${paragraph.text.toPlainText()}" paints at $box, taller '
            'than its ${strip.height} dp horizontal strip',
      );
      continue;
    }
    expect(
      box.left >= -0.5 && box.right <= screen.width + 0.5,
      isTrue,
      reason:
          '"${paragraph.text.toPlainText()}" paints at $box '
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
  test('maps every catalog entry to a row with a kind and icon', () {
    expect(v2BuiltInCatalog.length, v2Catalog.length);
    expect(v2BuiltInCatalog.length, 168);
    for (var i = 0; i < v2Catalog.length; i++) {
      final entry = v2Catalog[i];
      final row = v2BuiltInCatalog[i];
      expect(row.id, entry.id);
      expect(row.name, entry.name);
      expect(row.description, entry.description);
      expect(row.category, entry.category);
      expect(row.builtIn, entry.builtIn);
      expect(row.connected, isFalse);
      expect(row.kind, switch (entry.kind) {
        V2CatalogKind.connector => V2ConnectorKind.app,
        V2CatalogKind.plugin => V2ConnectorKind.plugin,
        V2CatalogKind.mcp => V2ConnectorKind.mcp,
      });
      expect(row.isMcp, entry.isMcp);
      expect(row.sectionTitle, entry.sectionTitle);
    }
  });

  testWidgets('renders the full 168-entry catalog in two labelled sections', (
    tester,
  ) async {
    final data = const V2ConnectorsData();
    expect(data.catalog.length, 168);
    expect(data.apps.length, greaterThanOrEqualTo(100));
    expect(data.plugins.length, greaterThanOrEqualTo(20));
    expect(data.mcpServers.length, greaterThanOrEqualTo(20));
    expect(
      data.pluginsAndMcp.length,
      data.plugins.length + data.mcpServers.length,
    );

    await _pump(tester, ConnectorsPage(data: data));

    // The app bar says "Connectors"; the section header is uppercased.
    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('CONNECTORS'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);

    final connectorsCount = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('connectors-count')),
        matching: find.byType(Text),
      ),
    );
    expect(int.parse(connectorsCount.data!), data.apps.length);

    await tester.scrollUntilVisible(
      find.text('Gmail'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Gmail'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('PLUGINS & MCP'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    final pluginsCount = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('plugins-count')),
        matching: find.byType(Text),
      ),
    );
    // Plugins and MCP servers share the section count, as the contract says.
    expect(int.parse(pluginsCount.data!), data.pluginsAndMcp.length);

    await tester.scrollUntilVisible(
      find.text('Context7'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Context7'), findsOneWidget);
  });

  testWidgets('the MCP tab narrows the catalog to MCP servers', (tester) async {
    final data = const V2ConnectorsData();
    await _pump(tester, ConnectorsPage(data: data));

    expect(find.byKey(const Key('kind-mcp')), findsOneWidget);
    await tester.tap(find.byKey(const Key('kind-mcp')));
    await tester.pump(const Duration(milliseconds: 400));

    // Only the Plugins & MCP section remains, and its count is MCP-only.
    expect(find.text('CONNECTORS'), findsNothing);
    expect(find.text('PLUGINS & MCP'), findsOneWidget);
    final count = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('plugins-count')),
        matching: find.byType(Text),
      ),
    );
    expect(int.parse(count.data!), data.mcpServers.length);
    expect(find.text('Context7'), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);

    await tester.tap(find.byKey(const Key('kind-plugins')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Context7'), findsNothing);
    expect(find.text('Superpowers'), findsOneWidget);

    await tester.tap(find.byKey(const Key('kind-all')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('CONNECTORS'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('the plan note keeps the custom-connector limits', (
    tester,
  ) async {
    await _pump(tester, ConnectorsPage(data: _data()));

    await tester.scrollUntilVisible(
      find.textContaining('Free: 0'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Go: 5'), findsOneWidget);
    expect(find.textContaining('Plus & Pro: 20'), findsOneWidget);
  });

  testWidgets('an empty injected list still shows the built-in catalog', (
    tester,
  ) async {
    // The route placeholder passes an empty list until wiring lands; the
    // built-ins must still be there.
    await _pump(tester, const ConnectorsPage(data: V2ConnectorsData()));

    expect(find.text('CONNECTORS'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('No connectors available'), findsNothing);
  });

  testWidgets('connectors page renders in dark theme', (tester) async {
    await _pump(tester, ConnectorsPage(data: _data()), theme: OTheme.dark());

    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('CONNECTORS'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('PLUGINS & MCP'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PLUGINS & MCP'), findsOneWidget);
  });

  testWidgets('search filters both sections', (tester) async {
    await _pump(tester, ConnectorsPage(data: _data()));

    await tester.enterText(find.byType(TextField).first, 'context7');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('context7'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('PLUGINS & MCP'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('PLUGINS & MCP'), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);
    expect(find.text('CONNECTORS'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'github');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('context7'), findsNothing);
    expect(find.text('CONNECTORS'), findsOneWidget);
    expect(find.text('PLUGINS & MCP'), findsNothing);
  });

  testWidgets('a category chip filters the catalog', (tester) async {
    String? category;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        onCategoryChanged: (value) => category = value,
      ),
    );

    await tester.tap(find.text('Mail'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(category, 'Mail');
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);
    expect(find.text('context7'), findsNothing);
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

  testWidgets('tapping a row opens the connector', (tester) async {
    String? opened;
    await _pump(
      tester,
      ConnectorsPage(data: _data(), onOpen: (id) => opened = id),
    );

    await tester.tap(find.text('GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 'github');
  });

  testWidgets('the connect action fires for an available row', (tester) async {
    String? connected;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(
          connectors: _connected
              .where((connector) => !connector.connected)
              .toList(),
        ),
        onConnect: (id) => connected = id,
      ),
    );

    await tester.tap(find.text('Connect').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(connected, 'gmail');
  });

  testWidgets('an empty search offers clear filters', (tester) async {
    await _pump(tester, ConnectorsPage(data: _data()));

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('No matches'), findsOneWidget);
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
    await tester.ensureVisible(find.text('Upgrade'));
    await tester.pump(const Duration(milliseconds: 300));
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

  testWidgets('an empty catalog explains itself and offers add custom', (
    tester,
  ) async {
    var added = 0;
    await _pump(
      tester,
      ConnectorsPage(
        data: const V2ConnectorsData(
          connectors: <V2Connector>[],
          useBuiltInCatalog: false,
        ),
        onAddCustom: () => added++,
      ),
    );

    expect(find.text('No connectors available'), findsOneWidget);
    await tester.tap(find.text('Add custom').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(added, 1);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpNarrow(
        tester,
        ConnectorsPage(data: const V2ConnectorsData()),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );
      _expectNoTextOutsideScreen(tester);
      await _scrollThrough(tester);
      _expectNoTextOutsideScreen(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty and error states fit 320 dp at 200% text', (tester) async {
    await _pumpNarrow(
      tester,
      ConnectorsPage(
        data: const V2ConnectorsData(
          connectors: <V2Connector>[],
          useBuiltInCatalog: false,
        ),
      ),
    );
    expect(find.text('No connectors available'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);

    await _pumpNarrow(
      tester,
      ConnectorsPage(data: _data(status: V2ConnectorsStatus.error)),
    );
    expect(find.text('Something went wrong'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);
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
      ConnectorsPage(data: _data(), onOpen: (_) {}, onToggle: (_, _) {}),
    );

    final data = tester
        .getSemantics(find.byType(Switch).first)
        .getSemanticsData();
    expect(data.label, contains('GitHub'));
    expect(data.flagsCollection.isToggled.toBoolOrNull(), isTrue);
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isTrue);

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
