import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/ui/auth_methods.dart';

void main() {
  testWidgets(
    'build phone override controls picker and disclosure precedes SMS',
    (tester) async {
      const phoneEnabled = bool.fromEnvironment(
        'OVID_AUTH_PHONE',
        defaultValue: true,
      );
      var smsRequests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthMethods(
              providers: AuthProviders(),
              intent: AuthIntent.signIn,
              social: (_) async => null,
              phone: () => PhoneAuthFlow(
                currentUid: () => null,
                verify: (_, _, _) async {
                  smsRequests++;
                },
                apply: (_) async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(
        find.text('Continue with Phone'),
        phoneEnabled ? findsOneWidget : findsNothing,
      );
      for (final label in [
        'GitHub',
        'Apple',
        'Microsoft',
        'Facebook',
        'Twitter',
        'Yahoo',
      ]) {
        expect(find.text('Continue with $label'), findsNothing);
      }
      if (phoneEnabled) {
        await tester.tap(find.text('Continue with Phone'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Your number is sent to Google'),
          findsOneWidget,
        );
        expect(smsRequests, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      expect(smsRequests, 0);
    },
  );
}
