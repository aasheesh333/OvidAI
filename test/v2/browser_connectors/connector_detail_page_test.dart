import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_detail_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_permissions.dart'
    as permissions;

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

const _agents = <V2ConnectorAgent>[
  V2ConnectorAgent(
    id: 'main',
    name: 'Ovid main agent',
    description: 'Primary workspace orchestrator',
    accessLabel: 'Full access',
    fullAccess: true,
  ),
  V2ConnectorAgent(
    id: 'subagents',
    name: 'Subagents',
    description: 'Background tasks and linting',
    accessLabel: 'Read-only',
  ),
];

V2ConnectorDetailData _data({
  V2ConnectorDetailStatus status = V2ConnectorDetailStatus.content,
  bool connected = true,
  V2ConnectorUsage? usage,
  List<V2ConnectorActivity> activity = const <V2ConnectorActivity>[],
  List<V2ConnectorTool> tools = const <V2ConnectorTool>[],
  String safetyNote = '',
  bool builtIn = true,
}) {
  return V2ConnectorDetailData(
    id: 'github',
    name: 'GitHub',
    description:
        'Read repositories, open pull requests, and review code '
        'together.',
    icon: Icons.code_rounded,
    connected: connected,
    permissions: _permissions,
    tools: tools,
    agents: _agents,
    usage: usage,
    activity: activity,
    safetyNote: safetyNote,
    builtIn: builtIn,
    status: status,
  );
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump(const Duration(milliseconds: 300));
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

void main() {
  testWidgets('detail shows the connector, permissions and assigned agents', (
    tester,
  ) async {
    await _pump(tester, ConnectorDetailPage(data: _data()));

    expect(find.text('Connector details'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    await _scrollTo(tester, find.text('Permissions granted'));
    expect(find.text('Permissions granted'), findsOneWidget);
    expect(find.text('Read your repositories'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Used by'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Ovid main agent'), findsOneWidget);
    expect(find.text('Subagents'), findsOneWidget);
    expect(find.text('Full access'), findsOneWidget);
    expect(find.text('Read-only'), findsOneWidget);
  });

  testWidgets('detail lists tools and shows a safety note', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(
          tools: const [
            V2ConnectorTool(
              id: 'read_file',
              name: 'read_file',
              description: 'Read a file in the repository',
            ),
            V2ConnectorTool(
              id: 'open_pull_request',
              name: 'open_pull_request',
              description: 'Open a pull request for review',
              write: true,
            ),
          ],
        ),
      ),
    );

    await _scrollTo(tester, find.byKey(const Key('connector-safety-note')));
    expect(find.byKey(const Key('connector-safety-note')), findsOneWidget);
    expect(find.text('Built-in safety'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Tools'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('2 available'), findsOneWidget);
    expect(find.text('read_file'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('open_pull_request'), findsOneWidget);
    expect(find.text('Can change'), findsOneWidget);
  });

  testWidgets('custom connectors carry the custom safety note', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(
          builtIn: false,
          safetyNote:
              'Ovid never installs plugins from a chat message. Only add '
              'servers you trust.',
        ),
      ),
    );

    await _scrollTo(tester, find.text('Custom connector safety'));
    expect(find.text('Custom connector safety'), findsOneWidget);
    expect(
      find.text(
        'Ovid never installs plugins from a chat message. Only add '
        'servers you trust.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty tools explain the gap', (tester) async {
    await _pump(tester, ConnectorDetailPage(data: _data()));

    await tester.scrollUntilVisible(
      find.text('Tools'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('No tools yet. Ovid will list them here.'),
      findsOneWidget,
    );
  });

  testWidgets('detail renders in dark theme', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(data: _data()),
      theme: OTheme.dark(),
    );

    expect(find.text('Connector details'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);
    await _scrollTo(tester, find.text('Permissions granted'));
    expect(find.text('Permissions granted'), findsOneWidget);
  });

  testWidgets('detail shows usage and recent activity', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(
          usage: const V2ConnectorUsage(
            calls: 120,
            limit: 500,
            resetLabel: 'Resets Monday',
          ),
          activity: const [
            V2ConnectorActivity(
              id: 'pr',
              title: 'Created a pull request',
              detail: 'Added the new billing page',
              timeLabel: '2m',
            ),
            V2ConnectorActivity(
              id: 'fail',
              title: 'Sync failed',
              detail: 'Trying again in 5 minutes',
              timeLabel: '1h',
              ok: false,
            ),
          ],
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('Usage'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('120 of 500 calls'), findsOneWidget);
    expect(find.text('Resets Monday'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Recent activity'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Created a pull request'), findsOneWidget);
    expect(find.text('Sync failed'), findsOneWidget);
  });

  testWidgets('detail explains when there is no usage or activity yet', (
    tester,
  ) async {
    await _pump(tester, ConnectorDetailPage(data: _data()));

    await tester.scrollUntilVisible(
      find.text('Usage'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('No calls yet. Ovid will count them here.'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.text('Recent activity'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('No activity yet. Ovid will show what it did here.'),
      findsOneWidget,
    );
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
    expect(find.text('Connect GitHub'), findsOneWidget);

    await tester.tap(find.text('Connect GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(connects, 1);
  });

  testWidgets('disconnect asks for confirmation before the callback', (
    tester,
  ) async {
    var disconnects = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onDisconnect: () => disconnects++),
    );

    await tester.scrollUntilVisible(
      find.text('Disconnect GitHub'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Disconnect GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Disconnect GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect GitHub?'), findsOneWidget);
    expect(disconnects, 0);

    await tester.tap(find.text('Disconnect GitHub').last);
    await tester.pumpAndSettle();
    expect(disconnects, 1);
  });

  testWidgets('disconnect can be cancelled', (tester) async {
    var disconnects = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onDisconnect: () => disconnects++),
    );

    await tester.scrollUntilVisible(
      find.text('Disconnect GitHub'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Disconnect GitHub'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Disconnect GitHub'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep connected'));
    await tester.pumpAndSettle();
    expect(disconnects, 0);
  });

  testWidgets('the permissions row opens the grouped permissions screen', (
    tester,
  ) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: V2ConnectorDetailData(
          id: 'github',
          name: 'GitHub',
          description:
              'Read repositories, open pull requests, and review code together.',
          icon: Icons.code_rounded,
          connected: true,
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
          agents: _agents,
        ),
      ),
    );

    await _scrollTo(tester, find.byKey(const Key('connector-permissions-entry')));
    expect(
      find.byKey(const Key('connector-permissions-entry')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('connector-permissions-entry')));
    await tester.pumpAndSettle();

    expect(find.byType(permissions.ConnectorPermissionsPage), findsOneWidget);
    expect(find.text('Permissions'), findsWidgets);
    expect(find.text('2 of 2 granted'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Write'), findsOneWidget);
    expect(find.text('High risk'), findsWidgets);
    expect(find.text('Read your repositories'), findsWidgets);
  });

  testWidgets('the permissions row can be overridden by the wiring layer', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onOpenPermissions: () => opened++),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('connector-permissions-entry')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('connector-permissions-entry')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(opened, 1);
    expect(find.byType(permissions.ConnectorPermissionsPage), findsNothing);
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
    await tester.scrollUntilVisible(
      readSwitch,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(readSwitch);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(readSwitch);
    await tester.pump(const Duration(milliseconds: 300));
    expect(permissionId, 'read');
    expect(granted, isFalse);
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

  testWidgets('automatic sync reports the new value', (tester) async {
    bool? autoSync;
    await _pump(
      tester,
      ConnectorDetailPage(
        data: _data(),
        onAutoSyncChanged: (value) => autoSync = value,
      ),
    );

    final autoSyncSwitch = find.byKey(
      const Key('connector-autosync-switch'),
    );
    await _scrollTo(tester, autoSyncSwitch);
    await tester.ensureVisible(autoSyncSwitch);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(autoSyncSwitch);
    await tester.pump(const Duration(milliseconds: 300));
    expect(autoSync, isFalse);
  });

  testWidgets('empty permissions and agents explain the gap', (tester) async {
    await _pump(
      tester,
      ConnectorDetailPage(
        data: const V2ConnectorDetailData(
          id: 'github',
          name: 'GitHub',
          description: 'Read repositories and review code.',
          connected: true,
        ),
      ),
    );

    // No sample account or sync copy leaks in from the defaults.
    expect(find.text('alexrivera'), findsNothing);
    expect(find.text('Synced 2m ago'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('No permissions granted yet.'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No permissions granted yet.'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('No agents can use this connector yet.'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No agents can use this connector yet.'), findsOneWidget);
  });

  testWidgets('controls expose labels and announce the disabled state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(
      tester,
      ConnectorDetailPage(data: _data(), onPermissionChanged: (_, _) {}),
    );

    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    expect(find.bySemanticsLabel('Connector menu'), findsOneWidget);
    await _scrollTo(
      tester,
      find.bySemanticsLabel('Read your repositories permission'),
    );
    expect(
      find.bySemanticsLabel('Read your repositories permission'),
      findsOneWidget,
    );

    await tester.scrollUntilVisible(
      find.text('Disconnect GitHub'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final disconnect = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Disconnect GitHub'),
    );
    expect(
      disconnect.onPressed,
      isNotNull,
      reason: 'disconnect is wired to the store by default',
    );

    handle.dispose();
  });

  testWidgets('renders at 320 dp with 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = V2ConnectorDetailData(
      id: 'github',
      name: 'GitHub',
      description:
          'Read repositories, open pull requests, and review code together.',
      icon: Icons.code_rounded,
      accountLabel: 'alex.rivera@example.com',
      syncedLabel: 'Synced 2 minutes ago',
      accessLabel: 'Read & Write',
      permissions: _permissions,
      tools: const [
        V2ConnectorTool(
          id: 'read_file',
          name: 'read_file',
          description: 'Read a file in the repository',
        ),
        V2ConnectorTool(
          id: 'open_pull_request',
          name: 'open_pull_request',
          description: 'Open a pull request for review',
          write: true,
        ),
      ],
      agents: _agents,
      usage: const V2ConnectorUsage(
        calls: 120,
        limit: 500,
        resetLabel: 'Resets Monday',
      ),
      activity: const [
        V2ConnectorActivity(
          id: 'pr',
          title: 'Created a pull request',
          detail: 'Added the new billing page',
          timeLabel: '2m',
        ),
        V2ConnectorActivity(
          id: 'fail',
          title: 'Sync failed',
          detail: 'Trying again in 5 minutes',
          timeLabel: '1h',
          ok: false,
        ),
      ],
    );

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
              data: data,
              onDisconnect: () {},
              onConnect: () {},
              onPermissionChanged: (_, _) {},
              onAutoSyncChanged: (_) {},
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
}
