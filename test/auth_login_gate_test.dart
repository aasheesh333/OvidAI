import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/ui/login_gate.dart';

class GateService extends ChangeNotifier implements FirebaseService {
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
  @override
  Future<void> initialize() => initialization.future;
  @override
  Future<void> retryAccountLogin() async {
    accountError = null;
    accountReady = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'ovid_welcomed': true}));

  testWidgets('loading and unavailable Firebase never reveal protected child', (
    tester,
  ) async {
    final service = GateService();
    await tester.pumpWidget(
      MaterialApp(
        home: LoginGate(
          service: service,
          bindCloud: () async {},
          child: const Text('Protected app'),
        ),
      ),
    );
    expect(find.text('Protected app'), findsNothing);
    service.initialization.complete();
    await tester.pumpAndSettle();
    expect(find.text('Sign-in is unavailable in this build.'), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);
    service.isAvailable = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Phone'), findsOneWidget);
    expect(find.text('Sign in with email'), findsNothing);
    expect(find.text('Protected app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets(
    'server acknowledgement gates authenticated account and signout hides child',
    (tester) async {
      final service = GateService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountError = 'Account check failed';
      var binds = 0;
      service.initialization.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: LoginGate(
            service: service,
            bindCloud: () async {
              binds++;
            },
            child: const Text('Protected app'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Account check failed'), findsOneWidget);
      expect(find.text('Protected app'), findsNothing);
      expect(binds, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Protected app'), findsOneWidget);
      expect(binds, 1);
      service.notifyListeners();
      await tester.pumpAndSettle();
      expect(binds, 1, reason: 'Repeated auth events must not rebind cloud.');
      service.isSignedIn = false;
      service.accountReady = false;
      service.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Protected app'), findsNothing);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(binds, 1, reason: 'Signing out must not start a cloud bind.');
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );

  for (final available in [false, true]) {
    testWidgets('gate recovery actions fit a short viewport: $available', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 280);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = GateService()
        ..isAvailable = available
        ..isSignedIn = available
        ..accountError = 'Account check failed';
      service.initialization.complete();
      var binds = 0;
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: LoginGate(
          service: service,
          bindCloud: () async { binds++; },
          child: const Text('Protected app'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Protected app'), findsNothing);
      expect(binds, 0);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Retry').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    });
  }

  testWidgets('signout removes the first-login welcome and its timer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = GateService()
      ..isAvailable = true
      ..isSignedIn = true
      ..accountReady = true;
    service.initialization.complete();
    await tester.pumpWidget(MaterialApp(home: LoginGate(
      service: service,
      bindCloud: () async {},
      child: const Text('Protected app'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Ovid'), findsOneWidget);
    service.isSignedIn = false;
    service.accountReady = false;
    service.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Ovid'), findsNothing);
    expect(find.text('Protected app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
