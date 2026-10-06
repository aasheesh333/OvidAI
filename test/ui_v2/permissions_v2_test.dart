// V2 UI — Permissions screen widget tests.
//
// The polished permissions screen keeps the strict permission model exactly:
// session grants come from AgentService.currentSession.grants, legacy
// all-sessions grants from AppState.globalPermissionGrants, and revocation
// routes through AgentService.revokeSessionPermissionGrant /
// AppState.revokeGlobalPermissionGrant. These tests pin the v2 contract:
//   * three calm sections (Autonomy / Granted scopes / Pending requests),
//     each with a one-line explainer instead of a prose wall,
//   * grant rows with a status pill (ALLOWED / DENIED / LEGACY) and one
//     clear, confirmed revoke action that actually removes the grant,
//   * a designed empty state for a decision-free session,
//   * overflow-free rendering at 360×640 @2× and a capped-width wide layout.
//
// Uses the same test seams as the ui_redesign suites (AppState.createForTest,
// AgentService.setRunSessionForTest). Revocation persists through real async
// (SharedPreferences mocks + microtask flush), so confirm flows run inside
// tester.runAsync with bounded pumps — never pumpAndSettle.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/permissions_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.globalPermissionGrants = [];
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    Aether.dark = true;
    AppState.resetTestInstance();
  });

  ChatSession seedSession(List<PermissionGrant> grants) {
    final s = ChatSession(
      id: 's1',
      title: 'Work',
      model: 'm',
      mode: 'auto',
      grants: grants,
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    return s;
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const PermissionsScreen()),
    );
    await tester.pump();
  }

  /// Taps the row revoke button identified by [key], confirms the dialog and
  /// lets the real async revoke + persist complete. Bounded: fixed-duration
  /// pumps plus one short real-async wait.
  Future<void> confirmRevoke(WidgetTester tester, ValueKey<String> key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pump();
    await tester.tap(find.byKey(key));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Revoke'),
        ),
      );
      await tester.pump();
      // Let revokeSessionPermissionGrant / revokeGlobalPermissionGrant and
      // the SharedPreferences-backed persist flush complete (real async).
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// SnackBars park a 4-second dismissal Timer on the fake clock; advance
  /// past it so no Timer is left pending at test end.
  Future<void> drainSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets(
    'renders Autonomy, Granted scopes and Pending sections with one-line '
    'explainers',
    (tester) async {
      await pumpScreen(tester);

      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('GRANTED SCOPES'), findsOneWidget);
      expect(find.text('PENDING REQUESTS'), findsOneWidget);
      expect(find.byType(AetherCard), findsNWidgets(3));

      // One-line explainers, not prose walls.
      expect(
        find.text('What the agent may decide on its own here.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Allow and Deny decisions remembered for this conversation.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Live approvals appear in the chat overlay, not here.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Workspace-confined modes enforce'),
        findsNothing,
      );

      // Calm section headers; pending section has no fake controls.
      expect(find.text('Session autonomy'), findsOneWidget);
      expect(find.text('SESSION ONLY'), findsOneWidget);
      expect(find.text('Approval prompts appear in chat'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Allow'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Deny'), findsNothing);
    },
  );

  testWidgets(
    'grant rows carry status pills and session revoke removes the grant',
    (tester) async {
      final s = seedSession([
        PermissionGrant.path('/work/project', sessionId: 's1', recursive: true),
        PermissionGrant.host('api.example.com', sessionId: 's1'),
        PermissionGrant.path(
          '/secret/notes.txt',
          sessionId: 's1',
          decision: PermissionGrant.decisionDeny,
        ),
      ]);
      app.globalPermissionGrants = [
        PermissionGrant.path('/data/legacy', global: true, recursive: true),
      ];

      await pumpScreen(tester);

      // Status pill per grant: two allows, one deny, one legacy entry.
      expect(find.widgetWithText(AetherPill, 'ALLOWED'), findsNWidgets(2));
      expect(find.widgetWithText(AetherPill, 'DENIED'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'LEGACY'), findsOneWidget);

      // Exact targets and coverage lines — no decision prose in the row.
      expect(find.text('path /work/project'), findsOneWidget);
      expect(find.text('host api.example.com'), findsOneWidget);
      expect(find.text('path /secret/notes.txt'), findsOneWidget);
      expect(find.text('path /data/legacy'), findsOneWidget);
      expect(find.text('Directory and descendants'), findsNWidgets(2));
      expect(find.text('Exact path'), findsOneWidget);
      expect(
        find.text('Host and subdomains, all ports and paths'),
        findsOneWidget,
      );
      expect(find.text('3 grants'), findsOneWidget);

      // Revoke the recursive path grant through the confirm dialog.
      await confirmRevoke(
        tester,
        const ValueKey('revoke-session-path-/work/project'),
      );

      expect(
        s.grants.any(
          (g) =>
              g.kind == PermissionGrant.kindPath && g.value == '/work/project',
        ),
        isFalse,
        reason: 'revokeSessionPermissionGrant must remove the grant',
      );
      expect(find.text('Revoked: path /work/project'), findsOneWidget);
      expect(find.text('path /work/project'), findsNothing);
      expect(find.widgetWithText(AetherPill, 'ALLOWED'), findsOneWidget);
      expect(find.text('2 grants'), findsOneWidget);
      await drainSnackBar(tester);
    },
  );

  testWidgets(
    'legacy grant revoke routes through AppState.revokeGlobalPermissionGrant',
    (tester) async {
      app.globalPermissionGrants = [
        PermissionGrant.path('/data/legacy', global: true, recursive: true),
      ];

      await pumpScreen(tester);

      expect(find.text('Legacy all-sessions grants'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'LEGACY'), findsOneWidget);

      await confirmRevoke(
        tester,
        const ValueKey('revoke-global-path-/data/legacy'),
      );

      expect(
        app.globalPermissionGrants,
        isEmpty,
        reason: 'revokeGlobalPermissionGrant must empty the legacy list',
      );
      expect(find.text('Revoked: path /data/legacy'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'LEGACY'), findsNothing);
      await drainSnackBar(tester);
    },
  );

  testWidgets(
    'designed empty state renders when the session holds no decisions',
    (tester) async {
      await pumpScreen(tester);

      expect(find.byType(AetherEmptyState), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
      expect(find.text('No decisions for this session yet'), findsOneWidget);
      expect(
        find.text('Allow or Deny in chat and the decision appears here.'),
        findsOneWidget,
      );

      // The other two sections still render around the empty state.
      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('PENDING REQUESTS'), findsOneWidget);
      expect(find.byType(AetherCard), findsNWidgets(3));
    },
  );

  testWidgets(
    'renders overflow-free at 360x640 @2x with pills and revoke reachable',
    (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      seedSession([
        PermissionGrant.path('/work/project', sessionId: 's1', recursive: true),
        PermissionGrant.host('api.example.com', sessionId: 's1'),
      ]);
      app.globalPermissionGrants = [
        PermissionGrant.path('/data/legacy', global: true, recursive: true),
      ];

      // A RenderFlex overflow would throw during this pump and fail the test.
      await pumpScreen(tester);

      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('SESSION ONLY'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'ALLOWED'), findsNWidgets(2));
      expect(find.widgetWithText(AetherPill, 'LEGACY'), findsOneWidget);

      // The revoke affordance stays reachable by scrolling at phone size.
      final revoke = find.byKey(
        const ValueKey('revoke-session-host-api.example.com'),
      );
      await tester.ensureVisible(revoke);
      await tester.pump();
      expect(revoke, findsOneWidget);

      final pending = find.text('PENDING REQUESTS');
      await tester.ensureVisible(pending);
      await tester.pump();
      expect(find.text('Approval prompts appear in chat'), findsOneWidget);
    },
  );

  testWidgets(
    'wide layout caps content width and shows every section without '
    'scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      seedSession([
        PermissionGrant.path('/work/project', sessionId: 's1', recursive: true),
      ]);

      await pumpScreen(tester);

      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('GRANTED SCOPES'), findsOneWidget);
      expect(find.text('PENDING REQUESTS'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'ALLOWED'), findsOneWidget);

      // Content is capped at a calm reading width instead of stretching.
      final capped = tester
          .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .where((b) => b.constraints.maxWidth == 760);
      expect(capped.length, 1);

      // All three sections fit in the viewport — no scrolling required.
      expect(tester.getRect(find.text('PENDING REQUESTS')).bottom, lessThan(1000));
    },
  );
}
