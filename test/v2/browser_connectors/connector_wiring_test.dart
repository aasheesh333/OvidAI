import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/add_connector_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_detail_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_permissions.dart' as perms;
import 'package:ovid_ai/ui/v2/connectors/connector_probe.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_store.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A probe that returns a fixed report, so the UI contract can be tested
/// without a network. The real probe is exercised against a local server below.
class _FakeProbe implements V2ConnectorProbe {
  _FakeProbe(this.report);

  final V2ConnectorTestReport report;
  V2ConnectorConnection? lastConnection;
  String? lastKey;

  @override
  Future<V2ConnectorTestReport> test(
    V2ConnectorConnection connection, {
    String? apiKey,
  }) async {
    lastConnection = connection;
    lastKey = apiKey;
    return report;
  }
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


Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    260,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _fillCustomForm(
  WidgetTester tester, {
  String name = 'Internal API',
  String url = 'https://api.internal.test/v1',
  String key = 'sk-internal',
}) async {
  await _scrollTo(tester, find.byKey(const Key('add-connector-name')));
  await tester.enterText(find.byKey(const Key('add-connector-name')), name);
  await tester.enterText(find.byKey(const Key('add-connector-url')), url);
  await tester.enterText(find.byKey(const Key('add-connector-key')), key);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('connector store', () {
    test('persists connections, switches and permissions across instances', () async {
      final store = V2PrefsConnectorStore();
      await store.save(_github());

      final reopened = V2PrefsConnectorStore();
      final saved = await reopened.find('github');
      expect(saved, isNotNull);
      expect(saved!.endpoint, 'https://api.github.test');
      expect(saved.enabled, isTrue);

      await reopened.setEnabled('github', false);
      await reopened.setPermission(
        'github',
        V2ConnectorPermissionKind.write,
        false,
      );
      await reopened.setToolEnabled('github', 'list_issues', false);
      await reopened.setAutoSync('github', true);

      // A third instance proves the change reached storage, not just memory.
      final third = V2PrefsConnectorStore();
      final updated = (await third.find('github'))!;
      expect(updated.enabled, isFalse);
      expect(updated.write, isFalse);
      expect(updated.disabledTools, contains('list_issues'));
      expect(updated.autoSync, isTrue);

      await third.remove('github');
      expect(await V2PrefsConnectorStore().find('github'), isNull);
    });

    test('an API key never reaches SharedPreferences', () async {
      final store = V2PrefsConnectorStore();
      final secrets = V2MemoryConnectorSecrets();
      final connection = _github().copyWith(name: 'GitHub');
      await store.save(connection);
      await secrets.write(connection.id, 'sk-super-secret');

      final prefs = await SharedPreferences.getInstance();
      final blob = prefs.getString(V2PrefsConnectorStore.storageKey) ?? '';
      expect(blob, isNot(contains('sk-super-secret')));
      expect(await secrets.read(connection.id), 'sk-super-secret');
    });

    test('the plan allowance is Free 0, Go 5 and Plus/Pro 20', () {
      expect(V2ConnectorPlan.forTier('free').connectorLimit, 0);
      expect(V2ConnectorPlan.forTier('3x').connectorLimit, 5);
      expect(V2ConnectorPlan.forTier('7x').connectorLimit, 20);
      expect(V2ConnectorPlan.forTier('15x').connectorLimit, 20);
      expect(V2ConnectorPlan.forTier(null).connectorLimit, 0);
      expect(V2ConnectorPlan.forTier('mystery').connectorLimit, 0);
    });
  });

  group('real connection probe', () {
    setUp(() {
      // The widget-test binding installs an HttpClient mock that answers 400
      // to everything. This group talks to a real loopback server.
      HttpOverrides.global = null;
    });

    test('reports the status a real server returns', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? authorization;
      server.listen((request) async {
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        request.response.statusCode = request.uri.path == '/bad' ? 500 : 200;
        request.response.write('ok');
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final probe = V2HttpConnectorProbe(
        timeout: const Duration(seconds: 5),
      );
      final connection = V2ConnectorConnection(
        id: 'local',
        name: 'Local',
        endpoint: 'http://127.0.0.1:${server.port}/ok',
      );

      final ok = await probe.test(connection, apiKey: 'sk-live');
      expect(ok.ok, isTrue);
      expect(ok.statusCode, 200);
      expect(ok.message, contains('HTTP 200'));
      expect(authorization, 'Bearer sk-live');

      final bad = await probe.test(
        V2ConnectorConnection(
          id: 'local',
          name: 'Local',
          endpoint: 'http://127.0.0.1:${server.port}/bad',
        ),
      );
      expect(bad.ok, isFalse);
      expect(bad.statusCode, 500);
      expect(bad.message, contains('HTTP 500'));
    });

    test('reports a real refusal instead of a canned success', () async {
      final probe = V2HttpConnectorProbe(timeout: const Duration(seconds: 2));
      final report = await probe.test(
        const V2ConnectorConnection(
          id: 'closed',
          name: 'Closed',
          endpoint: 'http://127.0.0.1:1/mcp',
        ),
      );
      expect(report.ok, isFalse);
      expect(report.message, isNotEmpty);
    });

    test('a command connector is reported as untestable, not passed', () async {
      final report = await V2HttpConnectorProbe().test(
        const V2ConnectorConnection(
          id: 'cmd',
          name: 'Cmd',
          endpoint: 'node /workspace/server.js',
          target: V2ConnectorTarget.command,
        ),
      );
      expect(report.ok, isFalse);
      expect(report.unsupported, isTrue);
      expect(report.message, contains('workspace session'));
    });
  });

  group('add connector wiring', () {
    testWidgets('saving a custom connector persists the real config', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore();
      final secrets = V2MemoryConnectorSecrets();
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
          store: store,
          secrets: secrets,
        ),
      );

      await _fillCustomForm(tester);
      await tester.tap(find.byKey(const Key('connector-save')));
      await tester.pump(const Duration(milliseconds: 500));

      final saved = (await store.load()).single;
      expect(saved.name, 'Internal API');
      expect(saved.endpoint, 'https://api.internal.test/v1');
      expect(saved.custom, isTrue);
      expect(await secrets.read(saved.id), 'sk-internal');
    });

    testWidgets('a catalog connector is set up without using a plan slot', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore();
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(
            plan: V2ConnectorPlan.free,
            presetId: 'gmail',
            presetName: 'Gmail',
            presetDescription: 'Draft emails and summaries',
            presetCategory: 'Mail',
          ),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      expect(find.byKey(const Key('connector-cap-notice')), findsNothing);
      expect(find.text('Setting up Gmail'), findsOneWidget);

      await _fillCustomForm(
        tester,
        name: 'Gmail',
        url: 'https://gmail.internal.test/mcp',
      );
      await tester.tap(find.byKey(const Key('connector-save')));
      await tester.pump(const Duration(milliseconds: 500));

      final saved = (await store.load()).single;
      expect(saved.id, 'gmail');
      expect(saved.custom, isFalse, reason: 'built-in apps do not use a slot');
      expect(saved.endpoint, 'https://gmail.internal.test/mcp');
    });

    testWidgets('required fields explain themselves inline', (tester) async {
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
          store: V2MemoryConnectorStore(),
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      await tester.tap(find.byKey(const Key('connector-save')));
      await tester.pump(const Duration(milliseconds: 300));
      await _scrollTo(tester, find.byKey(const Key('add-connector-name')));

      expect(find.text('Give this connector a name.'), findsOneWidget);
      expect(find.text('Paste the API key this server expects.'), findsOneWidget);
    });

    testWidgets('the Free cap disables save and offers a real upgrade', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore();
      var upgrades = 0;
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.free),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
          onUpgrade: () => upgrades++,
        ),
      );

      await _fillCustomForm(tester);

      final save = tester.widget<OIconButton>(
        find.byKey(const Key('connector-save')),
      );
      expect(save.onPressed, isNull, reason: 'Free has no connector slots');
      expect(await store.load(), isEmpty);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('connector-cap-upgrade')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(upgrades, 1);
    });

    testWidgets('a failed test shows the real reason, never success', (
      tester,
    ) async {
      final probe = _FakeProbe(
        const V2ConnectorTestReport(
          ok: false,
          statusCode: 401,
          message: 'The server rejected the credential (HTTP 401).',
        ),
      );
      await _pump(
        tester,
        AddConnectorPage(
          data: const V2AddConnectorData(plan: V2ConnectorPlan.plus),
          store: V2MemoryConnectorStore(),
          secrets: V2MemoryConnectorSecrets(),
          probe: probe,
        ),
      );

      await _fillCustomForm(tester, key: 'sk-bad');
      await _scrollTo(tester, find.text('Test connection'));
      await tester.tap(find.text('Test connection'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(probe.lastConnection?.endpoint, 'https://api.internal.test/v1');
      expect(probe.lastKey, 'sk-bad');
      expect(
        find.text('The server rejected the credential (HTTP 401).'),
        findsOneWidget,
      );
      expect(
        find.text('Connection works. You can save this connector.'),
        findsNothing,
      );

      // Editing the endpoint invalidates the result that described it.
      await tester.enterText(
        find.byKey(const Key('add-connector-url')),
        'https://api.internal.test/v2',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('The server rejected the credential (HTTP 401).'),
        findsNothing,
      );
    });
  });

  group('add connector at 320 dp and 200 % text', () {
    for (final dark in <bool>[false, true]) {
      testWidgets('the Free cap notice fits (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: AddConnectorPage(
                data: const V2AddConnectorData(plan: V2ConnectorPlan.free),
                store: V2MemoryConnectorStore(),
                secrets: V2MemoryConnectorSecrets(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < 14; i++) {
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
  });

  group('connectors list wiring', () {
    testWidgets('a saved connection shows as connected and opens detail', (
      tester,
    ) async {
      final store = V2MemoryConnectorStore([_github()]);
      await _pump(
        tester,
        ConnectorsPage(
          data: const V2ConnectorsData(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      expect(find.text('On'), findsWidgets);

      // Narrow to the saved row before opening it.
      await tester.enterText(find.byType(TextField).first, 'github');
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('GitHub').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(ConnectorDetailPage), findsOneWidget);
      expect(find.text('Test connection'), findsOneWidget);
    });

    testWidgets('the row switch persists through the store', (tester) async {
      final store = V2MemoryConnectorStore([_github()]);
      await _pump(
        tester,
        ConnectorsPage(
          data: const V2ConnectorsData(),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      await tester.tap(find.byType(Switch).first);
      await tester.pump(const Duration(milliseconds: 400));

      expect((await store.find('github'))!.enabled, isFalse);
      expect(find.text('Paused'), findsWidgets);
    });
  });

  group('connector detail wiring', () {
    testWidgets('enable/disable persists', (tester) async {
      final store = V2MemoryConnectorStore([_github()]);
      final row = _github().toRow();
      await _pump(
        tester,
        ConnectorDetailPage(
          data: v2ConnectorDetailForRow(row, connection: _github()),
          store: store,
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      final enabled = find.byKey(const Key('connector-enabled-card'));
      await tester.ensureVisible(enabled);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.descendant(of: enabled, matching: find.byType(Switch)),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect((await store.find('github'))!.enabled, isFalse);
    });

    testWidgets('test connection reports the real failure reason', (
      tester,
    ) async {
      final probe = _FakeProbe(
        const V2ConnectorTestReport(
          ok: false,
          statusCode: 404,
          message: 'The server answered, but nothing is served at that path '
              '(HTTP 404).',
        ),
      );
      await _pump(
        tester,
        ConnectorDetailPage(
          data: v2ConnectorDetailForRow(
            _github().toRow(),
            connection: _github(),
          ),
          store: V2MemoryConnectorStore([_github()]),
          secrets: V2MemoryConnectorSecrets(),
          probe: probe,
        ),
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('connector-test-card')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Test connection'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Test connection'));
      await tester.pump(const Duration(milliseconds: 500));

      expect(probe.lastConnection?.endpoint, 'https://api.github.test');
      expect(
        find.textContaining('nothing is served at that path'),
        findsOneWidget,
      );
    });

    testWidgets('a catalog row with no saved connection is not "Connected"', (
      tester,
    ) async {
      final row = _github().toRow().copyWith(connected: false);
      await _pump(
        tester,
        ConnectorDetailPage(
          data: v2ConnectorDetailForRow(row),
          store: V2MemoryConnectorStore(),
          secrets: V2MemoryConnectorSecrets(),
        ),
      );

      expect(find.text('Connected'), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
    });
  });

  group('320 dp at 200 % text', () {
    for (final dark in <bool>[false, true]) {
      testWidgets('the cap banner and rows fit (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: ConnectorsPage(
                data: const V2ConnectorsData(),
                store: V2MemoryConnectorStore([_github()]),
                secrets: V2MemoryConnectorSecrets(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < 10; i++) {
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -260),
          );
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('the detail test card fits (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: ConnectorDetailPage(
                data: v2ConnectorDetailForRow(
                  _github().toRow(),
                  connection: _github(),
                ),
                store: V2MemoryConnectorStore([_github()]),
                secrets: V2MemoryConnectorSecrets(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        for (var i = 0; i < 12; i++) {
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
  });

  group('permissions screen wiring', () {
    testWidgets('a tool switch persists and explains the state', (tester) async {
      final store = V2MemoryConnectorStore([_github()]);
      final data = perms.V2ConnectorPermissionsData(
        connectorId: 'github',
        connectorName: 'GitHub',
        permissions: [
          perms.V2ConnectorPermissionItem(
            id: 'read',
            name: V2ConnectorPermissionKind.read.title,
            scope: perms.V2ConnectorPermissionScope.read,
            description: V2ConnectorPermissionKind.read.description,
          ),
        ],
        tools: const [
          perms.V2ConnectorPermissionTool(
            id: 'list_issues',
            name: 'list_issues',
            scope: perms.V2ConnectorPermissionScope.read,
            description: 'List issues in a repository',
            permissionId: 'read',
          ),
        ],
      );

      await _pump(
        tester,
        perms.ConnectorPermissionsPage(data: data, store: store),
      );

      // The description is the connector's real capability, not a canned line.
      expect(find.text(V2ConnectorPermissionKind.read.description), findsOneWidget);

      final toolSwitch = find.byKey(
        const ValueKey('connector-permissions-tool-switch-list_issues'),
      );
      await tester.scrollUntilVisible(
        toolSwitch,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(toolSwitch);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(toolSwitch);
      await tester.pump(const Duration(milliseconds: 400));

      expect((await store.find('github'))!.disabledTools, contains('list_issues'));
      expect(find.text('Off'), findsWidgets);
    });
  });
}
