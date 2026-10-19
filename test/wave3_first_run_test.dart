// Wave 3 first run and gate: one prompt at a time (EM-005, SH-031), the
// notification step (EM-016), no import sheet without importable chats
// (SH-010/EM-003), pushed routes dropped on sign-out (SH-007), and an
// immediate "Use a different account" (SH-033).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/history_import.dart';
import 'package:ovid_ai/core/notification_permission.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/first_run_steps.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_login_gate_test.dart' show GateService;

class _Service extends GateService {
  int signOuts = 0;
  @override
  Future<void> signOut() async {
    signOuts++;
    isSignedIn = false;
    accountReady = false;
    notifyListeners();
  }
}

class _Import extends HistoryImportService {
  _Import(SharedPreferences prefs, this.result)
    : super(
        rest: CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'http://test',
        ),
        history: SessionHistoryRepository.forTest(),
        prefs: prefs,
        account: 'u1',
      );
  final HistoryImportPlan result;
  @override
  Future<HistoryImportPlan> plan() async => result;
}

void main() {
  tearDown(FirstRunSteps.reset);

  Future<_Service> pumpReadyGate(
    WidgetTester tester, {
    HistoryImportService? import,
    Widget child = const Text('Protected app'),
  }) async {
    AppState.createForTest(sessionAccountIdForTest: 'firebase:u1');
    final service = _Service()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountReady = true;
    service.initialization.complete();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginGate(
          service: service,
          bindCloud: () async {},
          historyImportService: import,
          historyImportAccount: 'firebase:u1',
          child: child,
        ),
      ),
    );
    addTearDown(service.dispose);
    return service;
  }

  testWidgets('first-run prompts run one at a time, in order', (tester) async {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    final prefs = await SharedPreferences.getInstance();
    final log = <String>[];
    final notif = Completer<void>();
    FirstRunSteps.notifications = (_) {
      log.add('notifications');
      return notif.future;
    };
    FirstRunSteps.telemetry = (_) async => log.add('telemetry');
    final import = _Import(
      prefs,
      const HistoryImportPlan(sessions: 1, messages: 3, alreadyImported: false),
    );

    await pumpReadyGate(tester, import: import);
    await tester.pumpAndSettle();
    expect(log, ['notifications'],
        reason: 'telemetry waits for the notification step');
    expect(find.text('Import my chats'), findsNothing);

    notif.complete();
    await tester.pumpAndSettle();
    expect(log, ['notifications', 'telemetry']);
    expect(find.text('Import my chats'), findsOneWidget,
        reason: 'the import comes last');
  });

  for (final plan in const [
    HistoryImportPlan(sessions: 0, messages: 0, alreadyImported: false),
    HistoryImportPlan(sessions: 1, messages: 0, alreadyImported: false),
  ]) {
    testWidgets('no import sheet with ${plan.sessions} chats / '
        '${plan.messages} messages (SH-010, EM-003)', (tester) async {
      SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
      final prefs = await SharedPreferences.getInstance();
      FirstRunSteps.notifications = (_) async {};
      FirstRunSteps.telemetry = (_) async {};
      await pumpReadyGate(tester, import: _Import(prefs, plan));
      await tester.pumpAndSettle();
      expect(find.text('Import your chats'), findsNothing);
      expect(find.textContaining('0 messages'), findsNothing);
    });
  }

  testWidgets('signing out drops screens pushed above the gate (SH-007)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    FirstRunSteps.notifications = (_) async {};
    FirstRunSteps.telemetry = (_) async {};
    final service = await pumpReadyGate(
      tester,
      child: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Account screen')),
            ),
          ),
          child: const Text('open account'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open account'));
    await tester.pumpAndSettle();
    expect(find.text('Account screen'), findsOneWidget);

    await service.signOut();
    await tester.pumpAndSettle();
    expect(find.text('Account screen'), findsNothing);
    expect(find.text('Sign in or create an account'), findsOneWidget);
  });

  testWidgets('account confirmation offers "Use a different account" at once '
      '(SH-033)', (tester) async {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    AppState.createForTest(sessionAccountIdForTest: 'firebase:u1');
    final service = _Service()
      ..isAvailable = true
      ..isSignedIn = true;
    service.initialization.complete();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    await tester.pump();
    final link = find.byKey(const ValueKey('use-different-account'));
    expect(link, findsOneWidget);
    await tester.tap(link);
    await tester.pump();
    expect(service.signOuts, 1);
    await tester.pumpWidget(const SizedBox());
  });

  group('notification permission step (EM-016)', () {
    late List<String> calls;

    setUp(() {
      calls = [];
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(NotificationPermissionAccess.reset);

    Future<void> host(WidgetTester tester, PermissionStatus status) async {
      NotificationPermissionAccess.status = () async {
        calls.add('status');
        return status;
      };
      NotificationPermissionAccess.request = () async {
        calls.add('request');
        return PermissionStatus.granted;
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => askNotificationsOnce(context, isAndroid: true),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('denied: explains, then asks Android on "Turn on"', (
      tester,
    ) async {
      await host(tester, PermissionStatus.denied);
      expect(find.byKey(const ValueKey('first-run-notifications')),
          findsOneWidget);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(calls, ['status', 'request']);

      // Asked once per install.
      calls.clear();
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });

    testWidgets('"Not now" never requests', (tester) async {
      await host(tester, PermissionStatus.denied);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(calls, ['status']);
    });

    testWidgets('already granted: no dialog', (tester) async {
      await host(tester, PermissionStatus.granted);
      expect(find.byKey(const ValueKey('first-run-notifications')),
          findsNothing);
    });
  });
}
