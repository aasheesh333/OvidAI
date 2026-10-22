import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/add_connector_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_detail_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_permissions.dart'
    as permissions;
import 'package:ovid_ai/ui/v2/connectors/connector_store.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A store whose writes fail, so the screens' rollback paths can be exercised.
/// Reads still work: only a refused write should change what the person sees.
class _FailingStore implements V2ConnectorStore {
  _FailingStore(Iterable<V2ConnectorConnection> initial)
    : _inner = V2MemoryConnectorStore(initial);

  final V2MemoryConnectorStore _inner;

  @override
  Future<List<V2ConnectorConnection>> load() => _inner.load();

  @override
  Future<V2ConnectorConnection?> find(String id) => _inner.find(id);

  @override
  Future<void> save(V2ConnectorConnection connection) =>
      throw StateError('storage unavailable');

  @override
  Future<void> remove(String id) => throw StateError('storage unavailable');

  @override
  Future<void> setEnabled(String id, bool enabled) =>
      throw StateError('storage unavailable');

  @override
  Future<void> setPermission(
    String id,
    V2ConnectorPermissionKind kind,
    bool granted,
  ) => throw StateError('storage unavailable');

  @override
  Future<void> setToolEnabled(String id, String toolId, bool enabled) =>
      throw StateError('storage unavailable');

  @override
  Future<void> setAutoSync(String id, bool autoSync) =>
      throw StateError('storage unavailable');
}

V2ConnectorConnection _github({bool enabled = true}) => V2ConnectorConnection(
  id: 'github',
  name: 'GitHub',
  description: 'Repositories and pull requests',
  endpoint: 'https://api.github.test',
  category: 'Code',
  kind: 'app',
  custom: false,
  enabled: enabled,
  auth: V2ConnectorAuth.apiKey,
  write: true,
  connectedAt: DateTime(2026, 10, 1),
);

const _rows = <V2Connector>[
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
    id: 'gmail',
    name: 'Gmail',
    description: 'Draft emails and summaries',
    connected: false,
    category: 'Mail',
    icon: Icons.mail_outline_rounded,
    builtIn: true,
  ),
  V2Connector(
    id: 'notion',
    name: 'Notion',
    description: 'Search pages and create project wikis',
    connected: false,
    category: 'Notes',
    icon: Icons.edit_note_rounded,
    builtIn: true,
  ),
];

V2ConnectorsData _list({
  V2ConnectorsStatus status = V2ConnectorsStatus.content,
  List<V2Connector> connectors = _rows,
}) => V2ConnectorsData(connectors: connectors, status: status);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(theme: theme ?? OTheme.light(), home: child),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

/// Pumps at one width and text scale, both themes, and returns nothing; the
/// caller asserts the layout exception channel stays empty.
Future<void> _pumpSized(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required double scale,
  required ThemeData theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
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

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    260,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 200));
}

Finder _addAction() => find.byWidgetPredicate(
  (widget) => widget is OIconButton && widget.semanticLabel == 'Add connector',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('connectors list', () {
    testWidgets('all four states render', (tester) async {
      await _pump(
        tester,
        ConnectorsPage(
          data: _list(status: V2ConnectorsStatus.loading),
          plan: V2ConnectorPlan.plus,
        ),
      );
      expect(find.byType(OSkeletonList), findsOneWidget);

      await _pump(
        tester,
        ConnectorsPage(
          data: _list(status: V2ConnectorsStatus.error),
          plan: V2ConnectorPlan.plus,
          onRetry: () {},
        ),
      );
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      await _pump(
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

      await _pump(
        tester,
        ConnectorsPage(data: _list(), plan: V2ConnectorPlan.plus),
      );
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('a refused switch write rolls back and says so', (
      tester,
    ) async {
      final store = _FailingStore([_github()]);
      await _pump(
        tester,
        ConnectorsPage(
          data: _list(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
          plan: V2ConnectorPlan.plus,
        ),
      );

      final switchKey = const ValueKey('connector-switch-github');
      expect(tester.widget<Switch>(find.byKey(switchKey)).value, isTrue);

      await tester.tap(find.byKey(switchKey));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.widget<Switch>(find.byKey(switchKey)).value,
        isTrue,
        reason: 'the store refused, so the switch must show the saved state',
      );
      expect(find.text('Could not save that change.'), findsOneWidget);
    });

    testWidgets('a display-only row keeps its new value instead of snapping', (
      tester,
    ) async {
      await _pump(
        tester,
        ConnectorsPage(data: _list(), plan: V2ConnectorPlan.plus),
      );

      final switchKey = const ValueKey('connector-switch-github');
      await tester.tap(find.byKey(switchKey));
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.widget<Switch>(find.byKey(switchKey)).value, isFalse);
      expect(find.text('Paused'), findsOneWidget);
    });

    testWidgets('the cap disables add and offers a real upgrade path', (
      tester,
    ) async {
      var upgrades = 0;
      await _pump(
        tester,
        ConnectorsPage(
          data: _list(),
          plan: V2ConnectorPlan.free,
          onUpgrade: () => upgrades++,
        ),
      );

      expect(tester.widget<OIconButton>(_addAction()).onPressed, isNull);
      expect(find.byKey(const Key('connector-cap-banner')), findsOneWidget);
      expect(find.text('No custom connectors on Free.'), findsOneWidget);

      await tester.tap(find.text('Upgrade'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(upgrades, 1);
    });

    testWidgets('Plus at 20 custom connectors reports its own allowance', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore([
        for (var i = 0; i < 20; i++)
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
          data: _list(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
          plan: V2ConnectorPlan.plus,
        ),
      );

      expect(find.text('All 20 custom slots used on Plus.'), findsOneWidget);
      expect(tester.widget<OIconButton>(_addAction()).onPressed, isNull);
    });

    testWidgets('search also matches a category', (tester) async {
      await _pump(
        tester,
        ConnectorsPage(data: _list(), plan: V2ConnectorPlan.plus),
      );

      // Gmail is not installed, so the match is in the Available tab.
      await tester.tap(find.byKey(const Key('connector-tab-available')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).first, 'mail');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Gmail'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
    });

    testWidgets('a filter with no rows offers to show all', (tester) async {
      await _pump(
        tester,
        ConnectorsPage(
          data: _list(
            connectors: _rows.where((row) => !row.connected).toList(),
          ),
          plan: V2ConnectorPlan.plus,
        ),
      );

      await tester.tap(find.byKey(const Key('connector-filter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('connector-filter-connected')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Empty filter'), findsOneWidget);
      expect(find.text('Try a different search.'), findsNothing);

      await tester.tap(find.text('Show all'));
      await tester.pumpAndSettle();
      expect(find.text('Gmail'), findsOneWidget);
    });

    testWidgets('rows and switches are labelled for screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        ConnectorsPage(data: _list(), plan: V2ConnectorPlan.plus),
      );

      expect(find.bySemanticsLabel('GitHub, Connected'), findsOneWidget);

      final switchData = tester
          .getSemantics(find.byKey(const ValueKey('connector-switch-github')))
          .getSemanticsData();
      expect(switchData.label, contains('GitHub'));
      expect(switchData.flagsCollection.isToggled.toBoolOrNull(), isTrue);
      expect(switchData.flagsCollection.isEnabled.toBoolOrNull(), isTrue);
      handle.dispose();
    });
  });

  group('connector detail', () {
    V2ConnectorDetailData data({bool connected = true}) =>
        v2ConnectorDetailForRow(
          _github().toRow(),
          connection: connected ? _github() : null,
        );

    testWidgets('all four states render', (tester) async {
      await _pump(
        tester,
        ConnectorDetailPage(
          data: const V2ConnectorDetailData(
            id: 'github',
            name: 'GitHub',
            description: '',
            status: V2ConnectorDetailStatus.loading,
          ),
        ),
      );
      expect(find.byType(OSkeletonList), findsOneWidget);

      await _pump(
        tester,
        ConnectorDetailPage(
          data: const V2ConnectorDetailData(
            id: 'github',
            name: 'GitHub',
            description: '',
            status: V2ConnectorDetailStatus.error,
          ),
          onRetry: () {},
        ),
      );
      expect(find.text('Something went wrong'), findsOneWidget);

      await _pump(
        tester,
        ConnectorDetailPage(data: data(connected: false), onConnect: () {}),
      );
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);

      await _pump(tester, ConnectorDetailPage(data: data()));
      expect(find.text('Test connection'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(4));
    });

    testWidgets('all three permission switches persist', (tester) async {
      final store = V2MemoryConnectorStore([_github()]);
      await _pump(
        tester,
        ConnectorDetailPage(
          data: data(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      for (final id in ['read', 'write', 'execute']) {
        final key = ValueKey('connector-permission-switch-$id');
        await _scrollTo(tester, find.byKey(key));
        await tester.tap(find.byKey(key));
        await tester.pump(const Duration(milliseconds: 300));
      }

      final saved = (await store.find('github'))!;
      expect(saved.read, isFalse);
      expect(saved.write, isFalse);
      expect(saved.execute, isTrue);
    });

    testWidgets('a refused permission write rolls back and explains', (
      tester,
    ) async {
      final store = _FailingStore([_github()]);
      await _pump(
        tester,
        ConnectorDetailPage(
          data: data(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      final key = const ValueKey('connector-permission-switch-read');
      await _scrollTo(tester, find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.widget<Switch>(find.byKey(key)).value, isTrue);
      expect(find.text('Could not save that permission.'), findsOneWidget);
    });

    testWidgets('a refused enabled write rolls the status switch back', (
      tester,
    ) async {
      final store = _FailingStore([_github()]);
      await _pump(
        tester,
        ConnectorDetailPage(
          data: data(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      const key = Key('connector-enabled-switch');
      await tester.tap(find.byKey(key));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.widget<Switch>(find.byKey(key)).value, isTrue);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Could not save that change.'), findsOneWidget);
    });

    testWidgets('disconnect confirms, then removes the connection and secret', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore([_github()]);
      final secrets = V2MemoryConnectorSecrets();
      await secrets.write('github', 'sk-secret');
      await _pump(
        tester,
        ConnectorDetailPage(data: data(), store: store, secrets: secrets),
      );

      await _scrollTo(tester, find.text('Disconnect'));
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect GitHub?'), findsOneWidget);

      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();

      expect(await store.find('github'), isNull);
      expect(await secrets.read('github'), isNull);
    });

    testWidgets('the connector and permission switches announce state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        ConnectorDetailPage(
          data: data(),
          store: V2MemoryConnectorStore([_github()]),
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      final enabled = tester
          .getSemantics(find.byKey(const Key('connector-enabled-switch')))
          .getSemanticsData();
      expect(enabled.label, 'GitHub connector');
      expect(enabled.flagsCollection.isToggled.toBoolOrNull(), isTrue);

      final readKey = const ValueKey('connector-permission-switch-read');
      await _scrollTo(tester, find.byKey(readKey));
      final read = tester.getSemantics(find.byKey(readKey)).getSemanticsData();
      expect(read.label, contains('Read data'));
      expect(read.flagsCollection.isToggled.toBoolOrNull(), isTrue);
      handle.dispose();
    });
  });

  group('add connector', () {
    testWidgets('the key is only ever shown masked and lands in the vault', (
      tester,
    ) async {
      final store = V2PrefsConnectorStore();
      final secrets = V2MemoryConnectorSecrets();
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
          store: store,
          secrets: secrets,
        ),
      );

      final keyField = find.byKey(const Key('add-connector-key'));
      expect(tester.widget<TextField>(keyField).obscureText, isTrue);
      expect(find.bySemanticsLabel('Show key'), findsNothing);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);

      await tester.enterText(
        find.byKey(const Key('add-connector-name')),
        'Internal API',
      );
      await tester.enterText(
        find.byKey(const Key('add-connector-url')),
        'https://api.internal.test/v1',
      );
      await tester.enterText(keyField, 'sk-super-secret');
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.widget<TextField>(keyField).obscureText, isTrue);
      await tester.tap(find.byKey(const Key('connector-save')));
      await tester.pump(const Duration(milliseconds: 500));

      final saved = (await store.load()).single;
      expect(await secrets.read(saved.id), 'sk-super-secret');

      final prefs = await SharedPreferences.getInstance();
      final blob = prefs.getString(V2PrefsConnectorStore.storageKey) ?? '';
      expect(blob, isNot(contains('sk-super-secret')));
    });

    testWidgets('all four states render', (tester) async {
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(
            plan: V2ConnectorPlan.plus,
            status: V2AddConnectorStatus.loading,
          ),
        ),
      );
      expect(find.byType(OSkeletonList), findsOneWidget);

      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(
            plan: V2ConnectorPlan.plus,
            status: V2AddConnectorStatus.error,
          ),
          onRetry: () {},
        ),
      );
      expect(find.text('Something went wrong'), findsOneWidget);

      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(
            plan: V2ConnectorPlan.plus,
            status: V2AddConnectorStatus.blocked,
          ),
          onBack: () {},
        ),
      );
      expect(find.text('Add connectors here'), findsOneWidget);

      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
        ),
      );
      expect(find.byKey(const Key('add-connector-name')), findsOneWidget);
    });

    testWidgets('permission switches announce their name and state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
        ),
      );

      final readSwitch = find.descendant(
        of: find.byKey(const Key('connector-permission-read')),
        matching: find.byType(Switch),
      );
      final data = tester.getSemantics(readSwitch).getSemanticsData();
      expect(data.label, 'Read data');
      expect(data.flagsCollection.isToggled.toBoolOrNull(), isTrue);
      expect(data.flagsCollection.isEnabled.toBoolOrNull(), isTrue);
      handle.dispose();
    });

    testWidgets('the cap blocks save and offers upgrade, never chat install', (
      tester,
    ) async {
      var upgrades = 0;
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.free),
          onUpgrade: () => upgrades++,
        ),
      );

      expect(
        tester
            .widget<OIconButton>(find.byKey(const Key('connector-save')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('connector-cap-notice')), findsOneWidget);
      // No copy anywhere suggests a chat prompt can install a connector.
      expect(find.textContaining('install'), findsNothing);

      await tester.tap(find.byKey(const Key('connector-cap-upgrade')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(upgrades, 1);
    });
  });

  group('connector permissions', () {
    permissions.V2ConnectorPermissionsData content({
      permissions.V2ConnectorPermissionsStatus status =
          permissions.V2ConnectorPermissionsStatus.content,
    }) => permissions.V2ConnectorPermissionsData(
      connectorId: 'github',
      connectorName: 'GitHub',
      permissions: const [
        permissions.V2ConnectorPermissionItem(
          id: 'read',
          name: 'Read data',
          scope: permissions.V2ConnectorPermissionScope.read,
        ),
      ],
      tools: const [
        permissions.V2ConnectorPermissionTool(
          id: 'list_issues',
          name: 'list_issues',
          scope: permissions.V2ConnectorPermissionScope.read,
          permissionId: 'read',
        ),
      ],
      status: status,
    );

    testWidgets('all four states render', (tester) async {
      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(
          data: content(
            status: permissions.V2ConnectorPermissionsStatus.loading,
          ),
        ),
      );
      expect(find.byType(OSkeletonList), findsOneWidget);

      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(
          data: content(status: permissions.V2ConnectorPermissionsStatus.error),
          onRetry: () {},
        ),
      );
      expect(find.text('Something went wrong'), findsOneWidget);

      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(
          data: permissions.V2ConnectorPermissionsData(
            connectorId: 'github',
            connectorName: 'GitHub',
            status: permissions.V2ConnectorPermissionsStatus.empty,
          ),
        ),
      );
      expect(find.text('No permissions to review'), findsOneWidget);

      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(data: content()),
      );
      expect(
        find.byKey(const ValueKey('connector-permissions-summary')),
        findsOneWidget,
      );
      expect(find.text('Full access'), findsOneWidget);
    });

    testWidgets('a refused tool write rolls back the switch', (tester) async {
      final store = _FailingStore([_github()]);
      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(data: content(), store: store),
      );

      final key = const ValueKey(
        'connector-permissions-tool-switch-list_issues',
      );
      await _scrollTo(tester, find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.widget<Switch>(find.byKey(key)).value, isTrue);
      expect(find.text('Could not save that tool. Try again.'), findsOneWidget);
    });

    testWidgets('a refused revoke puts the grant back', (tester) async {
      final store = _FailingStore([_github()]);
      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(data: content(), store: store),
      );

      final revoke = find.byKey(
        const ValueKey('connector-permission-revoke-read'),
      );
      await _scrollTo(tester, revoke);
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke permission'));
      await tester.pumpAndSettle();

      expect(find.text('Granted'), findsOneWidget);
      expect(find.text('Revoked'), findsNothing);
      expect(
        find.text('Could not save that change. Try again.'),
        findsOneWidget,
      );
    });

    testWidgets('no back arrow when the page cannot pop', (tester) async {
      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(data: content()),
      );
      expect(find.bySemanticsLabel('Back'), findsNothing);
    });

    testWidgets('the tool switch is named and announces its state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        permissions.ConnectorPermissionsPage(data: content()),
      );

      final key = const ValueKey(
        'connector-permissions-tool-switch-list_issues',
      );
      await _scrollTo(tester, find.byKey(key));
      final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
      expect(data.label, 'list_issues tool');
      expect(data.flagsCollection.isToggled.toBoolOrNull(), isTrue);
      expect(data.flagsCollection.isEnabled.toBoolOrNull(), isTrue);
      handle.dispose();
    });
  });

  group('responsive and themed', () {
    for (final width in <double>[320, 412, 800, 1280]) {
      for (final dark in <bool>[false, true]) {
        testWidgets('connectors list at ${width.toInt()} dp, 200% text '
            '(${dark ? 'dark' : 'light'})', (tester) async {
          await _pumpSized(
            tester,
            ConnectorsPage(data: _list(), plan: V2ConnectorPlan.plus),
            size: Size(width, 640),
            scale: 2,
            theme: dark ? OTheme.dark() : OTheme.light(),
          );

          final list = tester.getRect(find.byType(CustomScrollView));
          expect(list.width, lessThanOrEqualTo(640));
          expect(list.center.dx, closeTo(width / 2, 0.5));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('detail and add centre at 640 on a 1280 window', (
      tester,
    ) async {
      await _pumpSized(
        tester,
        ConnectorDetailPage(
          data: v2ConnectorDetailForRow(
            _github().toRow(),
            connection: _github(),
          ),
          store: V2MemoryConnectorStore([_github()]),
          secrets: V2MemoryConnectorSecrets(),
        ),
        size: const Size(1280, 800),
        scale: 1,
        theme: OTheme.dark(),
      );
      final detail = tester.getRect(find.byType(ListView));
      expect(detail.width, lessThanOrEqualTo(640));
      expect(detail.center.dx, closeTo(640, 0.5));

      await _pumpSized(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
        ),
        size: const Size(1280, 800),
        scale: 1,
        theme: OTheme.light(),
      );
      final add = tester.getRect(find.byType(ListView));
      expect(add.width, lessThanOrEqualTo(640));
      expect(add.center.dx, closeTo(640, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('permissions centre at 640 on a 1280 window', (tester) async {
      await _pumpSized(
        tester,
        permissions.ConnectorPermissionsPage(
          data: permissions.V2ConnectorPermissionsData(
            connectorId: 'github',
            connectorName: 'GitHub',
            permissions: const [
              permissions.V2ConnectorPermissionItem(
                id: 'read',
                name: 'Read data',
                scope: permissions.V2ConnectorPermissionScope.read,
              ),
            ],
          ),
        ),
        size: const Size(1280, 800),
        scale: 1,
        theme: OTheme.dark(),
      );
      final body = tester.getRect(find.byType(ListView));
      expect(body.width, lessThanOrEqualTo(640));
      expect(body.center.dx, closeTo(640, 0.5));
      expect(tester.takeException(), isNull);
    });

    for (final width in <double>[320, 412, 800, 1280]) {
      for (final dark in <bool>[false, true]) {
        testWidgets('permissions fit ${width.toInt()} dp at 200% text '
            '(${dark ? 'dark' : 'light'})', (tester) async {
          await _pumpSized(
            tester,
            permissions.ConnectorPermissionsPage(
              data: permissions.V2ConnectorPermissionsData(
                connectorId: 'github',
                connectorName: 'GitHub',
                permissions: const [
                  permissions.V2ConnectorPermissionItem(
                    id: 'read',
                    name: 'Read data',
                    scope: permissions.V2ConnectorPermissionScope.read,
                  ),
                  permissions.V2ConnectorPermissionItem(
                    id: 'write',
                    name: 'Write & update',
                    scope: permissions.V2ConnectorPermissionScope.write,
                    risk: permissions.V2ConnectorPermissionRisk.medium,
                  ),
                ],
                tools: const [
                  permissions.V2ConnectorPermissionTool(
                    id: 'list_issues',
                    name: 'list_issues',
                    scope: permissions.V2ConnectorPermissionScope.read,
                    permissionId: 'read',
                  ),
                ],
              ),
            ),
            size: Size(width, 640),
            scale: 2,
            theme: dark ? OTheme.dark() : OTheme.light(),
          );

          expect(
            tester.getRect(find.byType(ListView)).width,
            lessThanOrEqualTo(640),
          );
          for (var i = 0; i < 8; i++) {
            expect(tester.takeException(), isNull);
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -260),
            );
            await tester.pump(const Duration(milliseconds: 200));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
