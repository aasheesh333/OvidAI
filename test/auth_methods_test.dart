import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/ui/auth_methods.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

Finder get _phoneNumberField => find.descendant(
  of: find.descendant(
    of: find.byType(AuthPhoneDialog),
    matching: find.widgetWithText(AetherField, 'Phone number'),
  ),
  matching: find.byType(TextField),
);

void main() {
  for (final width in [320.0, 360.0, 390.0, 411.0]) {
    testWidgets('social account actions fit ${width}dp at 1.3x', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const AuthScreen(),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Existing account help'),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('Existing account help'));
      await tester.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(
        find.textContaining('identity-verified account recovery'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final removeOwner in [false, true]) {
    testWidgets(
      removeOwner
          ? 'removing login picker invalidates its still-open phone dialog'
          : 'back dismiss invalidates automatic verification before exit animation',
      (tester) async {
        late PhoneCallbacks callbacks;
        var applied = 0;
        final showPicker = ValueNotifier(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showPicker,
                builder: (_, show, _) => show
                    ? AuthMethods(
                        providers: AuthProviders(google: false, phone: true),
                        intent: AuthIntent.signIn,
                        social: (_) async => null,
                        phone: () => PhoneAuthFlow(
                          currentUid: () => null,
                          verify: (_, _, cb) async {
                            callbacks = cb;
                          },
                          apply: (_) async {
                            applied++;
                          },
                        ),
                      )
                    : const Text('Replacement screen'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Continue with Phone'));
        await tester.pumpAndSettle();
        expect(find.byType(AuthPhoneDialog), findsOneWidget);
        await tester.enterText(
          _phoneNumberField,
          '+14155550100',
        );
        await tester.tap(find.text('Send code'));
        await tester.pump();
        if (removeOwner) {
          showPicker.value = false;
          await tester.pump();
        } else {
          await tester.binding.handlePopRoute();
        }
        callbacks.completed(
          PhoneAuthProvider.credential(
            verificationId: 'late',
            smsCode: '123456',
          ),
        );
        await tester.pumpAndSettle();
        expect(applied, 0);
        expect(find.byType(AuthPhoneDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        showPicker.dispose();
      },
    );
  }
  testWidgets(
    'account sign-in screen exposes social flow without password routes',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Forgot password'), findsNothing);
      expect(find.text('Sign in with email'), findsNothing);
      await tester.tap(find.text('Existing account help'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('identity-verified account recovery'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'picker offers only configured methods and reports provider failure',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthMethods(
              providers: AuthProviders(
                google: false,
                phone: false,
                socialIds: 'github.com',
              ),
              intent: AuthIntent.signIn,
              social: (_) async => authError(
                FirebaseAuthException(code: 'operation-not-allowed'),
              ),
              phone: () => throw StateError('phone disabled'),
            ),
          ),
        ),
      );
      expect(find.text('Continue with GitHub'), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      expect(find.text('Continue with Phone'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Continue with GitHub'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not enabled'), findsOneWidget);
    },
  );

  testWidgets('phone manual UI submits code and dismisses with success', (
    tester,
  ) async {
    late PhoneCallbacks callbacks;
    var applied = 0;
    var success = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthMethods(
            providers: AuthProviders(google: false, phone: true),
            intent: AuthIntent.signIn,
            social: (_) async => null,
            phone: () => PhoneAuthFlow(
              currentUid: () => null,
              verify: (_, _, cb) async {
                callbacks = cb;
              },
              apply: (_) async {
                applied++;
              },
            ),
            onSuccess: () {
              success++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Continue with Phone'));
    await tester.pumpAndSettle();
    expect(find.byType(AuthPhoneDialog), findsOneWidget);
    await tester.enterText(
      _phoneNumberField,
      '+14155550100',
    );
    await tester.tap(find.text('Send code'));
    await tester.pump();
    callbacks.codeSent('manual', 123);
    await tester.pump();
    final otpCells = find.descendant(
      of: find.byType(AuthPhoneDialog),
      matching: find.byType(TextField),
    );
    // The phone-number field is first; the segmented OTP owns the next six.
    expect(otpCells, findsNWidgets(7));
    const code = '123456';
    for (var i = 0; i < code.length; i++) {
      await tester.enterText(otpCells.at(i + 1), code[i]);
    }
    await tester.tap(find.text('Verify code'));
    await tester.pumpAndSettle();
    expect(applied, 1);
    expect(success, 1);
    expect(find.byType(AuthPhoneDialog), findsNothing);
  });

  testWidgets('closing phone dialog discards late automatic completion', (
    tester,
  ) async {
    late PhoneCallbacks callbacks;
    var applied = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthMethods(
            providers: AuthProviders(google: false, phone: true),
            intent: AuthIntent.link,
            social: (_) async => null,
            phone: () => PhoneAuthFlow(
              currentUid: () => 'alice',
              verify: (_, _, cb) async {
                callbacks = cb;
              },
              apply: (_) async {
                applied++;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Link Phone'));
    await tester.pumpAndSettle();
    expect(find.byType(AuthPhoneDialog), findsOneWidget);
    await tester.enterText(
      _phoneNumberField,
      '+14155550100',
    );
    await tester.tap(find.text('Send code'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    callbacks.completed(
      PhoneAuthProvider.credential(verificationId: 'late', smsCode: '123456'),
    );
    await tester.pumpAndSettle();
    expect(applied, 0);
    expect(find.byType(AuthPhoneDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
