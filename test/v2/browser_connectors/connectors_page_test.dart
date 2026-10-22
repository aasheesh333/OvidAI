import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/catalog_data.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_store.dart';
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
    expect(
      box.left >= -0.5 && box.right <= screen.width + 0.5,
      isTrue,
      reason:
          '"${paragraph.text.toPlainText()}" paints at $box '
          'outside the ${screen.width} dp viewport',
    );
  }
}

Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 12; i++) {
    await tester.drag(scrollable, const Offset(0, -220));
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('connector-filter')));
  await tester.pumpAndSettle();
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

  testWidgets('renders one flat catalog list with no kind or category chips', (
    tester,
  ) async {
    final data = const V2ConnectorsData();
    expect(data.catalog.length, 168);

    await _pump(
      tester,
      ConnectorsPage(data: data, plan: V2ConnectorPlan.plus),
    );

    // One header, no repeated section heading in the body.
    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('CONNECTORS'), findsNothing);
    expect(find.text('PLUGINS & MCP'), findsNothing);
    expect(find.text('GitHub'), findsOneWidget);

    // The chips are gone: kinds and categories live in the filter menu only.
    expect(find.byKey(const Key('kind-mcp')), findsNothing);
    expect(find.byKey(const Key('kind-apps')), findsNothing);
    expect(find.text('All'), findsNothing);
    expect(find.text('Mail'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Gmail'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Gmail'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Context7'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Context7'), findsOneWidget);
  });

  testWidgets('the one filter menu narrows the list to a kind', (tester) async {
    final data = const V2ConnectorsData();
    await _pump(
      tester,
      ConnectorsPage(data: data, plan: V2ConnectorPlan.plus),
    );

    await _openFilter(tester);
    await tester.tap(find.text('Add-ons'));
    await tester.pumpAndSettle();

    expect(find.text('Context7'), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);

    await _openFilter(tester);
    await tester.tap(find.text('Plugins'));
    await tester.pumpAndSettle();
    expect(find.text('Context7'), findsNothing);
    expect(find.text('Superpowers'), findsOneWidget);

    await _openFilter(tester);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('the filter menu can show only connected rows', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );

    await _openFilter(tester);
    await tester.tap(find.byKey(const ValueKey('connector-filter-connected')));
    await tester.pumpAndSettle();

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Notion'), findsOneWidget);
    expect(find.text('Gmail'), findsNothing);
    expect(find.text('context7'), findsNothing);
  });

  testWidgets('the cap is one line with a real upgrade action', (tester) async {
    var upgrades = 0;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        plan: V2ConnectorPlan.free,
        onUpgrade: () => upgrades++,
      ),
    );

    expect(find.byKey(const Key('connector-cap-banner')), findsOneWidget);
    expect(find.text('No custom connectors on Free.'), findsOneWidget);
    expect(find.textContaining('Free: 0'), findsNothing);

    await tester.tap(find.text('Upgrade'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(upgrades, 1);
  });

  testWidgets('Go at the cap says so with the 5-slot allowance', (tester) async {
    final store = V2MemoryConnectorStore([
      for (var i = 0; i < 5; i++)
        V2ConnectorConnection(
          id: 'custom-$i',
          name: 'Custom $i',
          endpoint: 'https://api$i.test',
          custom: true,
        ),
    ]);
    await _pump(
      tester,
      ConnectorsPage(
        data: const V2ConnectorsData(),
        plan: V2ConnectorPlan.go,
        store: store,
      ),
    );

    expect(find.text('All 5 custom slots used on Go.'), findsOneWidget);
  });

  testWidgets('an empty injected list still shows the built-in catalog', (
    tester,
  ) async {
    await _pump(
      tester,
      const ConnectorsPage(
        data: V2ConnectorsData(),
        plan: V2ConnectorPlan.plus,
      ),
    );

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('No connectors'), findsNothing);
  });

  testWidgets('connectors page renders in dark theme', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
      theme: OTheme.dark(),
    );

    expect(find.text('Connectors'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('search filters the active tab', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );

    // Installed holds GitHub, Google Drive and Notion.
    await tester.enterText(find.byType(TextField).first, 'github');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Notion'), findsNothing);

    // Available is searched on its own; a saved connector is not listed there.
    await tester.tap(find.byKey(const Key('connector-tab-available')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'gmail');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('GitHub'), findsNothing);
  });

  testWidgets('the two tabs carry counts and announce the selection', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );

    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('3'), findsNWidgets(2));

    final installed = tester.getSemantics(
      find.bySemanticsLabel('Installed, 3'),
    );
    expect(installed.flagsCollection.isSelected.toBoolOrNull(), isTrue);

    await tester.tap(find.byKey(const Key('connector-tab-available')));
    await tester.pump(const Duration(milliseconds: 300));

    final available = tester.getSemantics(
      find.bySemanticsLabel('Available, 3'),
    );
    expect(available.flagsCollection.isSelected.toBoolOrNull(), isTrue);
    expect(find.text('GitHub'), findsNothing);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Draft emails and summaries'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an empty Installed tab points at the catalogue', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(
          connectors: _connected
              .where((connector) => !connector.connected)
              .toList(),
        ),
        plan: V2ConnectorPlan.plus,
      ),
    );

    // Nothing is installed, so the catalogue is the useful first screen.
    expect(find.text('Gmail'), findsOneWidget);

    await tester.tap(find.byKey(const Key('connector-tab-installed')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No connectors yet'), findsOneWidget);

    await tester.tap(find.text('Browse available'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Gmail'), findsOneWidget);
  });

  testWidgets('the row switch reports the new value', (tester) async {
    String? toggledId;
    bool? toggledValue;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        plan: V2ConnectorPlan.plus,
        onToggle: (id, value) {
          toggledId = id;
          toggledValue = value;
        },
      ),
    );

    await tester.tap(find.byKey(const ValueKey('connector-switch-github')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(toggledId, 'github');
    expect(toggledValue, isFalse);
  });

  testWidgets('tapping a row opens the connector', (tester) async {
    String? opened;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        plan: V2ConnectorPlan.plus,
        onOpen: (id) => opened = id,
      ),
    );

    await tester.tap(find.text('GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 'github');
  });

  testWidgets('an available row offers Add instead of a switch', (tester) async {
    String? connected;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(
          connectors: _connected
              .where((connector) => !connector.connected)
              .toList(),
        ),
        plan: V2ConnectorPlan.plus,
        onConnect: (id) => connected = id,
      ),
    );

    expect(
      find.byKey(const ValueKey('connector-switch-gmail')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('connector-add-gmail')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(connected, 'gmail');
  });

  testWidgets('an empty search offers clear search', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Nothing matches'), findsOneWidget);
    expect(find.text('Clear search'), findsOneWidget);

    await tester.tap(find.text('Clear search'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('GitHub'), findsOneWidget);
  });

  testWidgets('loading state shows skeleton rows', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(status: V2ConnectorsStatus.loading),
        plan: V2ConnectorPlan.plus,
      ),
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(status: V2ConnectorsStatus.error),
        plan: V2ConnectorPlan.plus,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('an empty catalog offers add connector', (tester) async {
    var added = 0;
    await _pump(
      tester,
      ConnectorsPage(
        data: const V2ConnectorsData(
          connectors: <V2Connector>[],
          useBuiltInCatalog: false,
        ),
        plan: V2ConnectorPlan.plus,
        onAddCustom: () => added++,
      ),
    );

    expect(find.text('No connectors'), findsOneWidget);
    await tester.tap(find.text('Add connector').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(added, 1);
  });

  for (final dark in <bool>[false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await _pumpNarrow(
        tester,
        ConnectorsPage(
          data: const V2ConnectorsData(),
          plan: V2ConnectorPlan.plus,
        ),
        theme: dark ? OTheme.dark() : OTheme.light(),
      );
      _expectNoTextOutsideScreen(tester);
      await _scrollThrough(tester);
      _expectNoTextOutsideScreen(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the cap line fits 320 dp at 200% text', (tester) async {
    await _pumpNarrow(
      tester,
      ConnectorsPage(
        data: _data(),
        plan: V2ConnectorPlan.free,
        onUpgrade: () {},
      ),
    );
    expect(find.text('No custom connectors on Free.'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states fit 320 dp at 200% text', (tester) async {
    await _pumpNarrow(
      tester,
      ConnectorsPage(
        data: const V2ConnectorsData(
          connectors: <V2Connector>[],
          useBuiltInCatalog: false,
        ),
        plan: V2ConnectorPlan.plus,
      ),
    );
    expect(find.text('No connectors'), findsOneWidget);
    _expectNoTextOutsideScreen(tester);

    await _pumpNarrow(
      tester,
      ConnectorsPage(
        data: _data(status: V2ConnectorsStatus.error),
        plan: V2ConnectorPlan.plus,
      ),
    );
    expect(find.text('That did not work'), findsOneWidget);
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
        home: ConnectorsPage(
          data: _data(),
          plan: V2ConnectorPlan.plus,
        ),
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
        plan: V2ConnectorPlan.plus,
        onOpen: (_) {},
        onToggle: (_, _) {},
      ),
    );

    final data = tester
        .getSemantics(find.byKey(const ValueKey('connector-switch-github')))
        .getSemanticsData();
    expect(data.label, contains('GitHub'));
    expect(data.flagsCollection.isToggled.toBoolOrNull(), isTrue);
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isTrue);

    final row = find.bySemanticsLabel('GitHub, Connected');
    expect(row, findsOneWidget);
    expect(
      tester.getSemantics(row).getSemanticsData().flagsCollection.isButton,
      isTrue,
    );
    handle.dispose();
  });

  testWidgets('the row switch is wired even without a host callback', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final store = V2MemoryConnectorStore(const [
      V2ConnectorConnection(
        id: 'github',
        name: 'GitHub',
        endpoint: 'https://api.github.com',
        custom: false,
      ),
    ]);
    await _pump(
      tester,
      ConnectorsPage(
        data: _data(),
        plan: V2ConnectorPlan.plus,
        store: store,
      ),
    );

    final data = tester
        .getSemantics(find.byKey(const ValueKey('connector-switch-github')))
        .getSemanticsData();
    expect(data.flagsCollection.isEnabled.toBoolOrNull(), isNot(false));

    await tester.tap(find.byKey(const ValueKey('connector-switch-github')));
    await tester.pump(const Duration(milliseconds: 300));
    expect((await store.find('github'))!.enabled, isFalse);
    handle.dispose();
  });

  testWidgets('the header keeps one add action at any width', (tester) async {
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );
    expect(find.bySemanticsLabel('Add connector'), findsOneWidget);
    expect(find.text('Add custom'), findsNothing);

    await _pumpNarrow(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
      scale: 1,
    );
    expect(find.bySemanticsLabel('Add connector'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('at 600 dp the list centres in a 640 max width', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      ConnectorsPage(data: _data(), plan: V2ConnectorPlan.plus),
    );

    final list = tester.getRect(find.byType(CustomScrollView));
    expect(list.width, lessThanOrEqualTo(640));
    expect(list.center.dx, closeTo(300, 0.5));
    expect(tester.takeException(), isNull);
  });
}
