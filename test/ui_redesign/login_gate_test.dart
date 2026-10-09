import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:ovid_ai/ui/widgets/ovid_mark.dart';

/// Fake FirebaseService — same pattern as test/auth_login_gate_test.dart. All
/// state fields are mutable so tests can drive transitions, and no real
/// Firebase, cloud, or auth plumbing is reached. Tracks retry/sign-out calls
/// so tests can assert tap wiring.
class _GateService extends ChangeNotifier implements FirebaseService {
  final initialization = Completer<void>();
  @override
  bool isAvailable = false;
  @override
  bool isSignedIn = false;
  @override
  bool accountReady = false;
  @override
  String? accountError;
  @override
  final authProviders = AuthProviders();
  @override
  AccountDeletion? lastDeletionReceipt;

  int retryCalls = 0;
  int signOutCalls = 0;

  @override
  Future<void> initialize() => initialization.future;

  @override
  Future<void> retryAccountLogin() async {
    retryCalls++;
    accountError = null;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    isSignedIn = false;
    accountReady = false;
    accountError = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

Widget _host(Widget gate) => MaterialApp(home: gate);

void main() {
  setUp(() {
    LoginGate.disabledForTest = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    LoginGate.disabledForTest = false;
  });

  testWidgets('splash renders wordmark + spinner while initializing', (
    tester,
  ) async {
    final service = _GateService();
    await tester.pumpWidget(
      _host(
        LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    // Initial frame — splash should be up.
    await tester.pump();
    expect(find.byType(OvidWordmark), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);

    // Complete init so the splash animation can be torn down cleanly.
    service.initialization.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets('sign-in unavailable renders Retry and never leaks child', (
    tester,
  ) async {
    final service = _GateService();
    await tester.pumpWidget(
      _host(
        LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    service.initialization.complete();
    await tester.pumpAndSettle();

    expect(find.text('Sign-in is unavailable in this build.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets(
    'account not ready renders Retry + Sign out and both taps are wired',
    (tester) async {
      final service = _GateService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountError = 'Account check failed';
      service.initialization.complete();

      await tester.pumpWidget(
        _host(
          LoginGate(
            service: service,
            bindCloud: () async {},
            child: const Text('Protected app'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Confirming your account'), findsOneWidget);
      expect(find.text('Account check failed'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Sign out'), findsOneWidget);
      expect(find.text('Protected app'), findsNothing);

      // Tap Retry — clears the error, service notifies, UI rebuilds without
      // the error path. Use pump (not pumpAndSettle) because the spinner
      // path renders a CircularProgressIndicator that never settles.
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await tester.pump();
      expect(service.retryCalls, 1);

      // Error is cleared; the panel now shows the spinner (no Retry/Sign out)
      // because retryAccountLogin() leaves accountReady false by design.
      expect(find.text('Confirming your account'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Retry'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Sign out'), findsNothing);

      // Put the error back to re-render the action buttons, then tap Sign
      // out — the service transitions to signed-out and the login screen
      // appears.
      service.accountError = 'Account check failed again';
      service.notifyListeners();
      await tester.pump();
      expect(find.widgetWithText(TextButton, 'Sign out'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
      await tester.pump();
      await tester.pump();
      expect(service.signOutCalls, 1);
      // Signed out → login screen is up (also features the wordmark).
      expect(find.text('Protected app'), findsNothing);
      expect(find.byType(OvidWordmark), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );

  testWidgets(
    'pending account shows its deadline and disables restore in flight',
    (tester) async {
      final service = _GateService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountError = 'Account deletion is pending.'
        ..lastDeletionReceipt = AccountDeletion(
          'pending',
          DateTime.utc(2026, 10, 10, 12),
          'request-0001',
        );
      service.initialization.complete();

      await tester.pumpWidget(
        _host(
          LoginGate(
            service: service,
            bindCloud: () async {},
            child: const Text('Protected app'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('2026-10-10'), findsOneWidget);
      expect(
        find.textContaining('Signing in did not cancel deletion'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );

  testWidgets('signed-in child renders behind welcome overlay', (tester) async {
    // Fresh install: welcome has NOT been shown yet.
    SharedPreferences.setMockInitialValues({});

    final service = _GateService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountReady = true;
    service.initialization.complete();

    await tester.pumpWidget(
      _host(
        LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    // Settle the FutureBuilder-ish prefs probe + overlay insertion.
    await tester.pumpAndSettle();

    // Protected child is painted (overlay is non-modal; both are present).
    expect(find.text('Protected app'), findsOneWidget);
    expect(find.text('Welcome to Ovid Si'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, "Let's go"), findsOneWidget);

    // Let the 5s auto-dismiss timer fire so we don't tear down the widget
    // tree with a pending timer still queued.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets('welcome overlay auto-dismisses after 5s', (tester) async {
    SharedPreferences.setMockInitialValues({});

    final service = _GateService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountReady = true;
    service.initialization.complete();

    await tester.pumpWidget(
      _host(
        LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Ovid Si'), findsOneWidget);

    // Advance past the 5s auto-dismiss and let the overlay unmount.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Ovid Si'), findsNothing);
    expect(find.text('Protected app'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
