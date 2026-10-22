import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_detail_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_permissions.dart'
    as permissions;
import 'package:ovid_ai/ui/v2/connectors/connector_probe.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_store.dart';

class _FakeProbe implements V2ConnectorProbe {
  _FakeProbe(this.report);

  final V2ConnectorTestReport report;
  V2ConnectorConnection? lastConnection;

  @override
  Future<V2ConnectorTestReport> test(
    V2ConnectorConnection connection, {
    String? apiKey,
  }) async {
    lastConnection = connection;
    return report;
  }
}

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

const _permissions = <V2ConnectorPermission>[
  V2ConnectorPermission(
    id: 'read',
    name: 'Read your repositories',
    description: 'Lets Ovid clone code and inspect files',
  ),
  V2ConnectorPermission(
    id: 'branches',
    name: 'Create branches',
    description: 'Lets Ovid make isolated feature branches',
  ),
  V2ConnectorPermission(
    id: 'pulls',
    name: 'Open pull requests',
    description: 'Lets Ovid submit code for your review',
  ),
];

V2ConnectorDetailData _data({
  V2ConnectorDetailStatus status = V2ConnectorDetailStatus.content,
  bool connected = true,
  List<V2ConnectorPermission> permissions = _permissions,
  String endpoint = 'https://api.github.test',
}) {
  return V2ConnectorDetailData(
    id: 'github',
    name: 'GitHub',
    description:
        'Read repositories, open pull requests, and review code '
        'together.',
    icon: Icons.code_rounded,
    connected: connected,
    endpoint: endpoint,
    permissions: permissions,
    status: status,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(_app(child, theme: theme));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Pumps the page on top of a real route so `Navigator.canPop` is true.
Future<void> _pumpPushed(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: const Scaffold(body: SizedBox.shrink()),
    ),
  );
  final context = tester.element(find.byType(Scaffold));
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('detail is status, one test button, grants and disconnect', (
    tester,
  ) async {
    await _pump(tester, ConnectorDetailPage(data: _data()));

    // The connector name is the header, not a second body heading.
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Connector details'), findsNothing);
    expect(find.text('Connected'), findsOneWidget);

    // One test button, no endpoint paragraph or safety card.
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('https://api.github.test'), findsNothing);
    expect(find.byKey(const Key('connector-safety-note')), findsNothing);
    // The status switch plus the three grants.
    expect(find.byType(Switch), findsNWidgets(4));
    expect(find.text('PERMISSIONS'), findsOneWidget);

    await _scrollTo(tester, find.text('Open pull requests'));
    expect(find.text('Read your repositories'), findsOneWidget);
    expect(find.text('Create branches'), findsOneWidget);
    expect(find.text('Open pull requests'), findsOneWidget);

    // Destructive action lives at the bottom, in danger style.
    await _scrollTo(tester, find.text('Disconnect'));
    final disconnect = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Disconnect'),
    );
    expect(disconnect.onPressed, isNotNull);
    expect(find.text('Tools'), findsNothing);
    expect(find.text('Usage'), findsNothing);
    expect(find.text('Recent activity'), findsNothing);
    expect(find.text('Automatic sync'), findsNothing);
  });

  testWidgets('detail renders in dark theme', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(data: _data()),
      theme: OTheme.dark(),
    );

    expect(find.text('GitHub'), findsOneWidget);
    await _scrollTo(tester, find.text('PERMISSIONS'));
    expect(find.text('PERMISSIONS'), findsOneWidget);
  });

  testWidgets('the status switch reports the new value', (tester) async {
    bool? enabled;
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(),
        onEnabledChanged: (value) => enabled = value,
      ),
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('connector-enabled-card')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(enabled, isFalse);
  });

  testWidgets('the test button runs the probe and shows the reason', (
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
      ConnectorDetailPage(data: _data(), probe: probe),
    );

    await tester.tap(find.text('Test connection'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(probe.lastConnection?.endpoint, 'https://api.github.test');
    expect(
      find.text('The server rejected the credential (HTTP 401).'),
      findsOneWidget,
    );
  });

  testWidgets('a permission switch reports the new grant', (tester) async {
    String? permissionId;
    bool? granted;
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(),
        onPermissionChanged: (id, value) {
          permissionId = id;
          granted = value;
        },
      ),
    );

    final readSwitch = find.byKey(
      const ValueKey('connector-permission-switch-read'),
    );
    await _scrollTo(tester, readSwitch);
    await tester.tap(readSwitch);
    await tester.pump(const Duration(milliseconds: 300));
    expect(permissionId, 'read');
    expect(granted, isFalse);
  });

  testWidgets('disconnect asks for confirmation before the callback', (
    tester,
  ) async {
    var disconnects = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onDisconnect: () => disconnects++),
    );

    await _scrollTo(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect GitHub?'), findsOneWidget);
    expect(disconnects, 0);

    await tester.tap(find.text('Disconnect').last);
    await tester.pumpAndSettle();
    expect(disconnects, 1);
  });

  testWidgets('disconnect can be cancelled', (tester) async {
    var disconnects = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onDisconnect: () => disconnects++),
    );

    await _scrollTo(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep connected'));
    await tester.pumpAndSettle();
    expect(disconnects, 0);
  });

  testWidgets('the menu opens the grouped permissions screen', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: V2ConnectorDetailData(
          id: 'github',
          name: 'GitHub',
          description: 'Read repositories and review code.',
          connected: true,
          endpoint: 'https://api.github.test',
          authLabel: 'OAuth',
          risk: V2ConnectorPermissionRisk.high,
          permissions: const [
            V2ConnectorPermission(
              id: 'read',
              name: 'Read your repositories',
              description: 'Lets Ovid clone code and inspect files',
              scope: V2ConnectorPermissionScope.read,
            ),
            V2ConnectorPermission(
              id: 'branches',
              name: 'Create branches',
              description: 'Lets Ovid make isolated feature branches',
              scope: V2ConnectorPermissionScope.write,
              risk: V2ConnectorPermissionRisk.medium,
            ),
          ],
          tools: const [
            V2ConnectorTool(
              id: 'read_file',
              name: 'read_file',
              description: 'Read a file in the repository',
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Connector menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review permissions'));
    await tester.pumpAndSettle();

    expect(find.byType(permissions.ConnectorPermissionsPage), findsOneWidget);
    expect(find.text('2 of 2 granted'), findsOneWidget);
    expect(find.text('High risk'), findsWidgets);
  });

  testWidgets('the menu can be overridden by the wiring layer', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onMenu: () => opened++),
    );

    await tester.tap(find.bySemanticsLabel('Connector menu'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(opened, 1);
  });

  testWidgets('not connected state offers a connect action', (tester) async {
    var connects = 0;
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(connected: false),
        onConnect: () => connects++,
      ),
    );

    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(connects, 1);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(status: V2ConnectorDetailStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('a pushed detail page has a back arrow and one menu action', (
    tester,
  ) async {
    await _pumpPushed(tester, ConnectorDetailPage(data: _data()));

    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    expect(find.bySemanticsLabel('Connector menu'), findsOneWidget);
  });

  testWidgets('renders at 320 dp with 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: ConnectorDetailPage(
              data: _data(),
              onDisconnect: () {},
              onConnect: () {},
              onPermissionChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      // Walk the whole page so every lazily built child lays out.
      for (var i = 0; i < 10; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('at 600 dp the detail centres in a 640 max width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, ConnectorDetailPage(data: _data()));

    final list = tester.getRect(find.byType(ListView));
    expect(list.width, lessThanOrEqualTo(640));
    expect(list.center.dx, closeTo(300, 0.5));
    expect(tester.takeException(), isNull);
  });
}
