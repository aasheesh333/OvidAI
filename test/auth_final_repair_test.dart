import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/ui/auth_methods.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder get phoneField => find.descendant(
  of: find.byType(AuthPhoneDialog), matching: find.byType(TextField),
).first;

Future<void> tapVisible(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pump();
  await tester.tap(find.text(label));
}

void main() {
  testWidgets('provider cancellation releases busy state without success or password entry', (tester) async {
    final result = Completer<String?>();
    final calls = <String>[];
    var successes = 0;
    await tester.pumpWidget(host(AuthMethods(
      providers: AuthProviders(google: false, phone: false, socialIds: 'github.com,password,unknown'),
      intent: AuthIntent.signIn,
      social: (id) { calls.add(id); return result.future; },
      phone: () => throw StateError('Phone is disabled'),
      onSuccess: () => successes++,
    )));
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Continue with GitHub'));
    await tester.pump();
    await tester.tap(find.text('Continue with GitHub'));
    expect(calls, ['github.com']);
    result.complete('cancelled');
    await tester.pumpAndSettle();
    expect(successes, 0);
    expect(find.text('cancelled'), findsNothing);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNotNull);
  });

  for (final exit in ['cancel', 'back', 'owner']) {
    testWidgets('$exit invalidates pending phone callbacks before route disposal', (tester) async {
      final owner = ValueNotifier(true);
      late PhoneCallbacks callbacks;
      var applied = 0;
      var successes = 0;
      await tester.pumpWidget(host(ValueListenableBuilder<bool>(
        valueListenable: owner,
        builder: (_, visible, _) => visible ? AuthMethods(
          providers: AuthProviders(google: false),
          intent: AuthIntent.signIn,
          social: (_) async => null,
          phone: () => PhoneAuthFlow(
            currentUid: () => null,
            verify: (_, _, cb) async { callbacks = cb; },
            apply: (_) async { applied++; },
          ),
          onSuccess: () => successes++,
        ) : const Text('Replacement'),
      )));
      await tester.tap(find.text('Continue with Phone'));
      await tester.pumpAndSettle();
      await tester.enterText(phoneField, '+14155550100');
      await tapVisible(tester, 'Send code');
      await tester.pump();
      if (exit == 'cancel') {
        await tapVisible(tester, 'Cancel');
      } else if (exit == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        owner.value = false;
        await tester.pump();
      }
      callbacks.completed(PhoneAuthProvider.credential(verificationId: 'late', smsCode: '123456'));
      await tester.pumpAndSettle();
      expect(applied, 0);
      expect(successes, 0);
      expect(find.byType(AuthPhoneDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      owner.dispose();
    });
  }

  testWidgets('synchronous resend clears visible OTP and submits only the new code', (tester) async {
    var sends = 0;
    final codes = <String?>[];
    var successes = 0;
    await tester.pumpWidget(host(AuthMethods(
      providers: AuthProviders(google: false),
      intent: AuthIntent.signIn,
      social: (_) async => null,
      phone: () => PhoneAuthFlow(
        currentUid: () => null,
        verify: (_, _, callbacks) async { callbacks.codeSent('id-${++sends}', sends); },
        apply: (credential) async { codes.add((credential as PhoneAuthCredential).smsCode); },
      ),
      onSuccess: () => successes++,
    )));
    await tester.tap(find.text('Continue with Phone'));
    await tester.pumpAndSettle();
    await tester.enterText(phoneField, '+14155550100');
    await tapVisible(tester, 'Send code');
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(AuthPhoneDialog), matching: find.byType(TextField));
    expect(fields, findsNWidgets(7));
    for (var i = 0; i < 6; i++) {
      await tester.enterText(fields.at(i + 1), '123456'[i]);
    }
    await tester.pump(const Duration(seconds: 61));
    await tapVisible(tester, 'Resend code');
    await tester.pumpAndSettle();
    expect(sends, 2);
    for (var i = 1; i <= 6; i++) {
      expect(tester.widget<TextField>(fields.at(i)).controller!.text, isEmpty);
    }
    await tapVisible(tester, 'Verify code');
    await tester.pumpAndSettle();
    expect(codes, isEmpty);
    for (var i = 0; i < 6; i++) {
      await tester.enterText(fields.at(i + 1), '654321'[i]);
    }
    await tapVisible(tester, 'Verify code');
    await tester.pumpAndSettle();
    expect(codes, ['654321']);
    expect(successes, 1);
    expect(find.byType(AuthPhoneDialog), findsNothing);
  });
}
