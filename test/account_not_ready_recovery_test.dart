import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_login_gate_test.dart' show GateService;

class _RecoveryService extends GateService {
  int retries = 0;
  int signOuts = 0;
  Object? restoreError;
  Object? retryError;

  @override
  Future<void> retryAccountLogin() async {
    retries++;
    if (retryError != null) throw retryError!;
    return super.retryAccountLogin();
  }

  @override
  Future<void> restoreAccount() async {
    if (restoreError != null) throw restoreError!;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    isSignedIn = false;
    notifyListeners();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'ovid_welcomed': true}));

  Future<void> pumpGate(WidgetTester tester, GateService service) async {
    service.initialization.complete();
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
  }

  Future<void> dispose(WidgetTester tester, GateService service) async {
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  }

  testWidgets('local transition failure offers Retry and Sign out', (
    tester,
  ) async {
    final service = _RecoveryService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountTransitionFailed = true;
    await pumpGate(tester, service);
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(service.retries, 1);
    expect(find.text('Protected app'), findsOneWidget);
    await dispose(tester, service);
  });

  testWidgets('a silent wait becomes Retry and Sign out after 15 seconds', (
    tester,
  ) async {
    final service = _RecoveryService()
      ..isAvailable = true
      ..isSignedIn = true;
    await pumpGate(tester, service);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    await tester.pump(const Duration(seconds: 15));
    expect(find.textContaining('taking longer than usual'), findsOneWidget);
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(service.signOuts, 1);
    await dispose(tester, service);
  });

  testWidgets('a throwing restore shows inline copy and is not a crash', (
    tester,
  ) async {
    final service = _RecoveryService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountError = 'Account deletion is pending.'
      ..lastDeletionReceipt = AccountDeletion(
        'pending',
        DateTime.utc(2026, 11, 1),
        'request-1',
      )
      ..restoreError = const AccountException(
        'The server did not confirm account restoration.',
      );
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);
    await pumpGate(tester, service);
    await tester.tap(find.text('Restore account'));
    await tester.pumpAndSettle();
    expect(
      find.text('The server did not confirm account restoration.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(errors, isEmpty);
    // The button is usable again for another attempt.
    final restore = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Restore account'),
    );
    expect(restore.onPressed, isNotNull);

    service.retryError = StateError('raw internal failure');
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not confirm your account'),
        findsOneWidget);
    expect(find.textContaining('raw internal failure'), findsNothing);
    expect(tester.takeException(), isNull);
    await dispose(tester, service);
  });

  testWidgets('resume re-checks the account deletion state', (tester) async {
    final service = _RecoveryService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountReady = true;
    await pumpGate(tester, service);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.accountRechecks, 1);
    await dispose(tester, service);
  });
}
