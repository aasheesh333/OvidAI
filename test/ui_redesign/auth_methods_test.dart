import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/ui/auth_methods.dart';

/// Wraps [child] in a MaterialApp + Scaffold so the Aether primitives have the
/// Material ancestors they rely on (InkWell, Theme, Directionality).
Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SafeArea(child: Padding(
      padding: const EdgeInsets.all(16),
      child: child,
    ))));

/// Builds an [AuthMethods] widget pre-wired with a configurable social
/// callback and a phone-flow factory. The social callback resolves a
/// provided [Completer] so tests can control timing precisely.
AuthMethods _methods({
  required AuthProviders providers,
  AuthIntent intent = AuthIntent.signIn,
  Set<String> linkedIds = const {},
  Future<String?> Function(String id)? social,
  PhoneAuthFlow Function()? phone,
  VoidCallback? onSuccess,
  Future<String?> Function()? beforePhone,
  ValueChanged<bool>? onBusyChanged,
}) {
  return AuthMethods(
    providers: providers,
    intent: intent,
    linkedIds: linkedIds,
    social: social ?? (_) async => null,
    phone: phone ?? () => throw StateError('phone not configured in test'),
    onSuccess: onSuccess,
    beforePhone: beforePhone,
    onBusyChanged: onBusyChanged,
  );
}

/// Default no-op PhoneAuthFlow factory used when tests need the picker to be
/// constructible but no phone interaction is expected.
PhoneAuthFlow _noPhoneFlow() => PhoneAuthFlow(
      currentUid: () => null,
              verify: (_, _, _) async {},
      apply: (_) async {},
    );

void main() {
  group('AuthMethods — provider filtering by intent', () {
    testWidgets('signIn shows every configured provider', (tester) async {
      await tester.pumpWidget(
        _host(
          _methods(
            providers: AuthProviders(
              google: true,
              phone: true,
              socialIds: 'github.com,apple.com',
            ),
            intent: AuthIntent.signIn,
          ),
        ),
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with GitHub'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
      expect(find.text('Continue with Phone'), findsOneWidget);
      // Pre-amble instructional body copy is rendered.
      expect(
        find.textContaining('configured social provider or phone'),
        findsOneWidget,
      );
    });

    testWidgets('link intent excludes already-linked providers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _methods(
            providers: AuthProviders(
              google: true,
              phone: true,
              socialIds: 'github.com',
            ),
            intent: AuthIntent.link,
            linkedIds: const {'google.com'},
          ),
        ),
      );
      expect(find.text('Link GitHub'), findsOneWidget);
      expect(find.text('Link Phone'), findsOneWidget);
      expect(find.text('Link Google'), findsNothing);
    });

    testWidgets('reauthenticate intent shows only linked providers', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _methods(
            providers: AuthProviders(
              google: true,
              phone: true,
              socialIds: 'github.com',
            ),
            intent: AuthIntent.reauthenticate,
            linkedIds: const {'phone'},
          ),
        ),
      );
      expect(find.text('Verify with Phone'), findsOneWidget);
      expect(find.text('Verify with Google'), findsNothing);
      expect(find.text('Verify with GitHub'), findsNothing);
      // Reauth hides the migration help affordance.
      expect(find.text('Existing account help'), findsNothing);
    });
  });

  testWidgets('busy state disables all buttons while social call is in-flight',
      (tester) async {
    final completer = Completer<String?>();
    final calls = <String>[];
    final busyChanges = <bool>[];
    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(
            google: true,
            phone: false,
            socialIds: 'github.com',
          ),
          intent: AuthIntent.signIn,
          social: (id) {
            calls.add(id);
            return completer.future;
          },
          onBusyChanged: busyChanges.add,
        ),
      ),
    );

    await tester.tap(find.text('Continue with Google'));
    await tester.pump(); // kick off setState(_busy = true)

    // Busy caption appears.
    expect(
      find.text('Complete the authentication prompt to continue.'),
      findsOneWidget,
    );

    // All provider rows should now be disabled (onPressed == null).
    final providerButtons = find.descendant(
      of: find.byType(AuthMethods),
      matching: find.byType(OutlinedButton),
    );
    expect(providerButtons, findsNWidgets(2));
    for (final b in tester.widgetList<OutlinedButton>(providerButtons)) {
      expect(b.onPressed, isNull,
          reason: 'Provider buttons must be disabled while busy.');
    }
    final helpButton = find.widgetWithText(TextButton, 'Existing account help');
    expect(tester.widget<TextButton>(helpButton).onPressed, isNull);
    expect(busyChanges, [true]);

    await tester.tap(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with GitHub'));
    await tester.tap(helpButton);
    await tester.pump();
    expect(calls, ['google.com']);
    expect(busyChanges, [true]);
    expect(find.textContaining('identity-verified account recovery'), findsNothing);

    // Resolve the social call so the test exits cleanly.
    completer.complete(null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(busyChanges, [true, false]);
    expect(calls, ['google.com']);
    expect(
      find.text('Complete the authentication prompt to continue.'),
      findsNothing,
    );
    for (final b in tester.widgetList<OutlinedButton>(providerButtons)) {
      expect(b.onPressed, isNotNull);
    }
    expect(tester.widget<TextButton>(helpButton).onPressed, isNotNull);
  });

  testWidgets('error sentinel from social is rendered as inline danger text',
      (tester) async {
    const errorText = 'Authentication could not finish. Please retry.';
    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(google: true, phone: false),
          intent: AuthIntent.signIn,
          social: (_) async => errorText,
        ),
      ),
    );

    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(find.text(errorText), findsOneWidget);
    // Busy caption gone after completion.
    expect(
      find.text('Complete the authentication prompt to continue.'),
      findsNothing,
    );
  });

  testWidgets(
      'existing account help toggles the inline migration-help card',
      (tester) async {
    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(google: true, phone: false),
          intent: AuthIntent.signIn,
        ),
      ),
    );

    // Collapsed by default — help copy is NOT rendered yet.
    expect(
      find.textContaining('identity-verified account recovery'),
      findsNothing,
    );

    await tester.tap(find.text('Existing account help'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('identity-verified account recovery'),
      findsOneWidget,
    );
    // Toggle swaps the ghost-button label.
    expect(find.text('Hide existing account help'), findsOneWidget);

    await tester.tap(find.text('Hide existing account help'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('identity-verified account recovery'),
      findsNothing,
    );
    expect(find.text('Existing account help'), findsOneWidget);
  });

  testWidgets(
      'phone flow sends code, verifies via OTP input and dismisses with success',
      (tester) async {
    late PhoneCallbacks callbacks;
    var applied = 0;
    var success = 0;

    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(google: false, phone: true),
          intent: AuthIntent.signIn,
          phone: () => PhoneAuthFlow(
            currentUid: () => null,
            verify: (_, _, cb) async {
              callbacks = cb;
            },
            apply: (_) async {
              applied++;
            },
          ),
          onSuccess: () => success++,
        ),
      ),
    );

    await tester.tap(find.text('Continue with Phone'));
    await tester.pumpAndSettle();

    // Dialog opened — section eyebrow renders.
    expect(find.text('VERIFY PHONE'), findsOneWidget);

    // Enter the phone number into the AetherField's underlying TextField.
    final phoneField = find.byType(TextField).first;
    await tester.enterText(phoneField, '+14155550100');
    await tester.tap(find.text('Send code'));
    await tester.pump();

    // Simulate Firebase delivering the verification id.
    callbacks.codeSent('manual-vid', 42);
    await tester.pump();

    // 6-cell OTP input should now be present. Enter each digit.
    final otpCells = find.byType(TextField);
    // 1 phone number field + 6 OTP cells.
    expect(otpCells, findsNWidgets(7));
    const code = '123456';
    for (var i = 0; i < code.length; i++) {
      await tester.enterText(otpCells.at(i + 1), code[i]);
    }
    await tester.pump();

    await tester.tap(find.text('Verify code'));
    await tester.pumpAndSettle();

    expect(applied, 1);
    expect(success, 1);
    // Dialog gone.
    expect(find.text('VERIFY PHONE'), findsNothing);
  });

  testWidgets('cancel invokes flow.cancel and closes the dialog without success',
      (tester) async {
    late PhoneAuthFlow createdFlow;
    var applied = 0;

    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(google: false, phone: true),
          intent: AuthIntent.link,
          phone: () {
            createdFlow = PhoneAuthFlow(
              currentUid: () => 'uid-1',
      verify: (_, _, _) async {},
              apply: (_) async {
                applied++;
              },
            );
            return createdFlow;
          },
        ),
      ),
    );

    await tester.tap(find.text('Link Phone'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).first,
      '+14155550100',
    );
    await tester.tap(find.text('Send code'));
    await tester.pump();

    // Snapshot: sending a request on PhoneAuthFlow bumps `number` and starts a
    // cooldown. We now cancel via the dialog's Cancel button.
    expect(createdFlow.number, isNotNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Dialog closed, flow reset by cancel().
    expect(find.text('VERIFY PHONE'), findsNothing);
    expect(createdFlow.number, isNull);
    expect(applied, 0);
  });

  testWidgets(
      'beforePhone gating prevents dialog when verification error returned',
      (tester) async {
    await tester.pumpWidget(
      _host(
        _methods(
          providers: AuthProviders(google: false, phone: true),
          intent: AuthIntent.signIn,
          phone: _noPhoneFlow,
          beforePhone: () async => authError(
            FirebaseAuthException(code: 'requires-recent-login'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Continue with Phone'));
    await tester.pumpAndSettle();

    // Dialog never opened; error surfaces inline.
    expect(find.text('VERIFY PHONE'), findsNothing);
    expect(find.textContaining('Verify this account'), findsOneWidget);
  });
}
