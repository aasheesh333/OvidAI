import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/reset_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
  @override
  bool get isAnonymous => false;
  @override
  List<UserInfo> get providerData => const [];
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) =>
      Completer<String?>().future;
}

/// F-045 short-term fix: the splash no longer waits for the whole chat
/// history to hydrate (`transitionSessionAccount`).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(AppState.resetTestInstance);

  testWidgets('LoginGate leaves the splash before hydration completes', (
    tester,
  ) async {
    final hydration = Completer<void>(); // never completed
    AppState.createForTest(
      accountLifecycle: AccountLifecycleIntegration.production(
        dependencies: AccountLifecycleDependencies(
          onFence: () {},
          onRevoke: () {},
          onBind: (_, _) => hydration.future,
          onClear: () {},
          onVerifyEmpty: () => true,
        ),
      ),
    );
    final service = FirebaseService.forTest(
      initializeApp: () async {},
      configure: () async {},
      initialUser: _User('A'),
    );
    var initialized = false;
    unawaited(service.initialize().then((_) => initialized = true));

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
    await tester.pump(const Duration(milliseconds: 50));

    expect(initialized, isFalse, reason: 'hydration is still pending');
    expect(service.firstUserKnown, isTrue);
    expect(service.accountReady, isFalse);
    expect(find.text('Confirming your account'), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
