import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_permissions.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

const _permissions = <V2ConnectorPermissionItem>[
  V2ConnectorPermissionItem(
    id: 'repo.read',
    name: 'Read repositories',
    scope: V2ConnectorPermissionScope.read,
    description: 'Clone code and inspect files',
    risk: V2ConnectorPermissionRisk.medium,
    toolIds: ['read_file'],
  ),
  V2ConnectorPermissionItem(
    id: 'checks.read',
    name: 'Read check runs',
    scope: V2ConnectorPermissionScope.read,
    description: 'See whether tests passed',
    risk: V2ConnectorPermissionRisk.low,
  ),
  V2ConnectorPermissionItem(
    id: 'pr.write',
    name: 'Open pull requests',
    scope: V2ConnectorPermissionScope.write,
    description: 'Submit code for your review',
    risk: V2ConnectorPermissionRisk.high,
    toolIds: ['open_pull_request'],
  ),
  V2ConnectorPermissionItem(
    id: 'org.admin',
    name: 'Manage organization access',
    scope: V2ConnectorPermissionScope.admin,
    description: 'Change who can use this repository',
    risk: V2ConnectorPermissionRisk.high,
  ),
];

const _tools = <V2ConnectorPermissionTool>[
  V2ConnectorPermissionTool(
    id: 'read_file',
    name: 'read_file',
    scope: V2ConnectorPermissionScope.read,
    description: 'Read a file in the repository',
    permissionId: 'repo.read',
  ),
  V2ConnectorPermissionTool(
    id: 'open_pull_request',
    name: 'open_pull_request',
    scope: V2ConnectorPermissionScope.write,
    description: 'Open a pull request for review',
    permissionId: 'pr.write',
  ),
  V2ConnectorPermissionTool(
    id: 'list_issues',
    name: 'list_issues',
    scope: V2ConnectorPermissionScope.read,
    description: 'List issues in a repository',
    permissionId: 'checks.read',
  ),
];

const _canDo = <String>[
  'Clone this repository into a cloud workspace.',
  'Open a pull request for your review.',
];

const _cannotDo = <String>[
  'Push directly to main.',
  'Read private repositories you have not granted.',
];

V2ConnectorPermissionsData _data({
  V2ConnectorPermissionsStatus status = V2ConnectorPermissionsStatus.content,
  List<V2ConnectorPermissionItem> permissions = _permissions,
  List<V2ConnectorPermissionTool> tools = _tools,
  List<String> canDo = _canDo,
  List<String> cannotDo = _cannotDo,
  String revokeNote = '',
}) {
  return V2ConnectorPermissionsData(
    connectorId: 'github',
    connectorName: 'GitHub',
    connectorDescription: 'Read repositories and review code.',
    connectorIcon: Icons.code_rounded,
    accountLabel: 'alex.rivera@example.com',
    permissions: permissions,
    tools: tools,
    canDo: canDo,
    cannotDo: cannotDo,
    status: status,
    revokeNote: revokeNote,
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

/// Pumps the page on top of a real route so `Navigator.canPop` is true and the
/// back arrow has somewhere to go.
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
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('groups permissions into Read, Write and Admin with risk badges', (
    tester,
  ) async {
    await _pump(tester, ConnectorPermissionsPage(data: _data()));

    final readGroup = find.byKey(
      const ValueKey('connector-permissions-group-read'),
    );
    final writeGroup = find.byKey(
      const ValueKey('connector-permissions-group-write'),
    );
    final adminGroup = find.byKey(
      const ValueKey('connector-permissions-group-admin'),
    );

    expect(readGroup, findsOneWidget);
    expect(find.descendant(of: readGroup, matching: find.text('Read')), findsOneWidget);
    expect(
      find.descendant(of: readGroup, matching: find.text('2 of 2 granted')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: readGroup,
        matching: find.text('Read repositories'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: readGroup,
        matching: find.text('Read check runs'),
      ),
      findsOneWidget,
    );

    await _scrollTo(tester, writeGroup);
    expect(
      find.descendant(of: writeGroup, matching: find.text('Write')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: writeGroup,
        matching: find.text('Open pull requests'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: writeGroup, matching: find.text('High risk')),
      findsWidgets,
    );

    await _scrollTo(tester, adminGroup);
    expect(
      find.descendant(of: adminGroup, matching: find.text('Admin')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: adminGroup,
        matching: find.text('Manage organization access'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('summary counts grants and describes the access level', (
    tester,
  ) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(
          permissions: const [
            V2ConnectorPermissionItem(
              id: 'repo.read',
              name: 'Read repositories',
              scope: V2ConnectorPermissionScope.read,
              granted: false,
            ),
            V2ConnectorPermissionItem(
              id: 'pr.write',
              name: 'Open pull requests',
              scope: V2ConnectorPermissionScope.write,
            ),
          ],
        ),
      ),
    );

    expect(find.text('1 of 2 granted'), findsWidgets);
    expect(find.text('Limited access'), findsOneWidget);
    expect(find.text('alex.rivera@example.com'), findsOneWidget);
  });

  testWidgets('tools list names each tool, its scope and its owner', (
    tester,
  ) async {
    await _pump(tester, ConnectorPermissionsPage(data: _data()));

    final readFile = find.byKey(
      const ValueKey('connector-permissions-tool-read_file'),
    );
    await _scrollTo(tester, readFile);

    expect(
      find.descendant(of: readFile, matching: find.text('read_file')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: readFile,
        matching: find.text('Read a file in the repository'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: readFile, matching: find.text('Read')),
      findsOneWidget,
    );

    final pullRequest = find.byKey(
      const ValueKey('connector-permissions-tool-open_pull_request'),
    );
    await _scrollTo(tester, pullRequest);
    expect(
      find.descendant(of: pullRequest, matching: find.text('Write')),
      findsOneWidget,
    );
  });

  testWidgets('revoking a permission asks first and then blocks its tools', (
    tester,
  ) async {
    String? revokedId;
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(),
        onRevokePermission: (id) => revokedId = id,
      ),
    );

    final revoke = find.byKey(
      const ValueKey('connector-permission-revoke-pr.write'),
    );
    await _scrollTo(tester, revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();

    expect(find.text('Revoke “Open pull requests”?'), findsOneWidget);
    expect(revokedId, isNull);

    await tester.tap(find.text('Revoke permission'));
    await tester.pumpAndSettle();

    expect(revokedId, 'pr.write');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('connector-permission-pr.write')),
        matching: find.text('Revoked'),
      ),
      findsOneWidget,
    );
    expect(find.text('“Open pull requests” revoked.'), findsOneWidget);

    final tool = find.byKey(
      const ValueKey('connector-permissions-tool-open_pull_request'),
    );
    await _scrollTo(tester, tool);
    expect(
      find.descendant(of: tool, matching: find.text('Blocked')),
      findsOneWidget,
    );
  });

  testWidgets('revoking can be cancelled without calling the adapter', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(),
        onRevokePermission: (_) => calls++,
      ),
    );

    final revoke = find.byKey(
      const ValueKey('connector-permission-revoke-repo.read'),
    );
    await _scrollTo(tester, revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();

    expect(find.text('Revoke “Read repositories”?'), findsOneWidget);
    await tester.tap(find.text('Keep access'));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Granted'), findsWidgets);
  });

  testWidgets('revoke all confirms, revokes every row and reports it', (
    tester,
  ) async {
    var revokeAllCalls = 0;
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(),
        onRevokeAll: () => revokeAllCalls++,
      ),
    );

    final revokeAll = find.byKey(
      const ValueKey('connector-permissions-revoke-all'),
    );
    await _scrollTo(tester, revokeAll);
    await tester.tap(revokeAll);
    await tester.pumpAndSettle();

    expect(find.text('Revoke all access to GitHub?'), findsOneWidget);
    expect(revokeAllCalls, 0);

    await tester.tap(find.text('Revoke all access').last);
    await tester.pumpAndSettle();

    expect(revokeAllCalls, 1);
    expect(find.text('All GitHub access revoked.'), findsOneWidget);

    final button = tester.widget<OButton>(revokeAll);
    expect(button.onPressed, isNull);
  });

  testWidgets('revoke all is disabled when nothing is granted', (tester) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(
          permissions: const [
            V2ConnectorPermissionItem(
              id: 'repo.read',
              name: 'Read repositories',
              scope: V2ConnectorPermissionScope.read,
              granted: false,
            ),
          ],
        ),
        onRevokeAll: () {},
      ),
    );

    expect(find.text('No access'), findsOneWidget);

    final revokeAll = find.byKey(
      const ValueKey('connector-permissions-revoke-all'),
    );
    await _scrollTo(tester, revokeAll);

    final button = tester.widget<OButton>(revokeAll);
    expect(button.onPressed, isNull);
  });

  testWidgets('can and cannot lists state the exact limits', (tester) async {
    await _pump(tester, ConnectorPermissionsPage(data: _data()));

    final canDo = find.byKey(
      const ValueKey('connector-permissions-can-do'),
    );
    await _scrollTo(tester, canDo);
    expect(
      find.descendant(of: canDo, matching: find.text('What Ovid can do')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: canDo,
        matching: find.text('Clone this repository into a cloud workspace.'),
      ),
      findsOneWidget,
    );

    final cannotDo = find.byKey(
      const ValueKey('connector-permissions-cannot-do'),
    );
    await _scrollTo(tester, cannotDo);
    expect(
      find.descendant(
        of: cannotDo,
        matching: find.text('What Ovid cannot do'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cannotDo,
        matching: find.text('Push directly to main.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('empty lists explain the gap', (
    tester,
  ) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(
          tools: const [],
          canDo: const [],
          cannotDo: const [],
        ),
      ),
    );

    // A connector with no tool manifest gets no tools card at all.
    expect(
      find.byKey(const ValueKey('connector-permissions-tools')),
      findsNothing,
    );
    expect(find.text('No tools exposed'), findsNothing);

    final canDo = find.byKey(const ValueKey('connector-permissions-can-do'));
    await _scrollTo(tester, canDo);
    expect(find.text('Nothing yet. Grant a permission above.'), findsOneWidget);

    final cannotDo = find.byKey(
      const ValueKey('connector-permissions-cannot-do'),
    );
    await _scrollTo(tester, cannotDo);
    expect(
      find.text('No limits are listed for this connector.'),
      findsOneWidget,
    );
  });

  testWidgets('no permissions shows an empty state with a way back', (
    tester,
  ) async {
    var backs = 0;
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(permissions: const []),
        onBack: () => backs++,
      ),
    );

    expect(find.text('No permissions to review'), findsOneWidget);
    expect(
      find.text(
        'GitHub has not asked for anything yet.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Back to connector'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(backs, 1);
  });

  testWidgets('explicit empty status also shows the empty state', (
    tester,
  ) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(status: V2ConnectorPermissionsStatus.empty),
      ),
    );

    expect(find.text('No permissions to review'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(status: V2ConnectorPermissionsStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('That did not work'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(status: V2ConnectorPermissionsStatus.loading),
      ),
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('No permissions to review'), findsNothing);
  });

  testWidgets('renders in dark theme', (tester) async {
    await _pump(
      tester,
      ConnectorPermissionsPage(data: _data()),
      theme: OTheme.dark(),
    );

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('2 of 2 granted'), findsWidgets);
  });

  testWidgets('risk badges and revoke actions expose semantic labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpPushed(
      tester,
      ConnectorPermissionsPage(
        data: _data(),
        onRevokePermission: (_) {},
      ),
    );

    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    await _scrollTo(
      tester,
      find.byKey(const ValueKey('connector-permission-revoke-repo.read')),
    );
    expect(find.bySemanticsLabel('Medium risk'), findsWidgets);
    expect(
      find.bySemanticsLabel('Revoke Read repositories'),
      findsOneWidget,
    );

    await _scrollTo(
      tester,
      find.byKey(const ValueKey('connector-permissions-group-write')),
    );
    expect(find.bySemanticsLabel('High risk'), findsWidgets);

    handle.dispose();
  });

  testWidgets('disabled revoke all announces its state', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ConnectorPermissionsPage(
        data: _data(
          permissions: const [
            V2ConnectorPermissionItem(
              id: 'repo.read',
              name: 'Read repositories',
              scope: V2ConnectorPermissionScope.read,
              granted: false,
            ),
          ],
        ),
        onRevokeAll: () {},
      ),
    );

    final revokeAll = find.byKey(
      const ValueKey('connector-permissions-revoke-all'),
    );
    await _scrollTo(tester, revokeAll);

    expect(
      find.bySemanticsLabel(RegExp('Revoke all access')),
      findsWidgets,
    );
    final semantics = tester.getSemantics(revokeAll).getSemanticsData();
    expect(
      semantics.label,
      contains('Revoke all access, no permissions granted'),
    );
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('renders at 320 dp with 200% text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = _data();
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: ConnectorPermissionsPage(
              data: data,
              onRevokePermission: (_) {},
              onRevokeAll: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      // Walk the whole page so every lazily built child lays out.
      for (var i = 0; i < 14; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -320));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
    }
  });
}
