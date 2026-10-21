import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';
import 'package:ovid_ai/ui/v2/onboarding/sign_in_page.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  bool settle = true,
  V2SignInData data = const V2SignInData(),
  ValueChanged<String>? onEmailChanged,
  ValueChanged<String>? onPasswordChanged,
  void Function(String email, String password)? onSubmit,
  VoidCallback? onGoogle,
  VoidCallback? onPhone,
  V2PhoneAuthData? phoneData,
  ValueChanged<String>? onPhoneChanged,
  ValueChanged<V2PhoneCountry>? onPhoneCountryChanged,
  ValueChanged<String>? onSendPhoneCode,
  ValueChanged<String>? onVerifyPhoneCode,
  VoidCallback? onResendPhoneCode,
  VoidCallback? onChangePhoneNumber,
  VoidCallback? onApple,
  VoidCallback? onForgotPassword,
  VoidCallback? onCreateAccount,
  VoidCallback? onLanguageTap,
  VoidCallback? onRetry,
  double width = 400,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: SignInPage(
        data: data,
        onEmailChanged: onEmailChanged,
        onPasswordChanged: onPasswordChanged,
        onSubmit: onSubmit,
        onGoogle: onGoogle,
        onPhone: onPhone,
        phoneData: phoneData,
        onPhoneChanged: onPhoneChanged,
        onPhoneCountryChanged: onPhoneCountryChanged,
        onSendPhoneCode: onSendPhoneCode,
        onVerifyPhoneCode: onVerifyPhoneCode,
        onResendPhoneCode: onResendPhoneCode,
        onChangePhoneNumber: onChangePhoneNumber,
        onApple: onApple,
        onForgotPassword: onForgotPassword,
        onCreateAccount: onCreateAccount,
        onLanguageTap: onLanguageTap,
        onRetry: onRetry,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('sign in renders all providers and the form in light', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('Email address'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('sign in renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('sign in submits the typed email and password', (tester) async {
    String? submittedEmail;
    String? submittedPassword;
    await _pump(
      tester,
      onSubmit: (email, password) {
        submittedEmail = email;
        submittedPassword = password;
      },
    );

    await tester.enterText(
      find.byKey(const Key('sign-in-email')),
      'ada@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'secret-pass',
    );
    await tester.ensureVisible(find.byKey(const Key('sign-in-submit')));
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pump();

    expect(submittedEmail, 'ada@example.com');
    expect(submittedPassword, 'secret-pass');
  });

  testWidgets('password visibility toggles', (tester) async {
    await _pump(tester);

    final passwordField = find.byKey(const Key('sign-in-password'));
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);

    await tester.ensureVisible(
      find.byKey(const Key('sign-in-password-toggle')),
    );
    await tester.tap(find.byKey(const Key('sign-in-password-toggle')));
    await tester.pump();

    expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
  });

  testWidgets('language selector and social providers call back', (
    tester,
  ) async {
    var languageTaps = 0;
    var googleTaps = 0;
    var appleTaps = 0;
    await _pump(
      tester,
      onLanguageTap: () => languageTaps++,
      onGoogle: () => googleTaps++,
      onApple: () => appleTaps++,
    );

    await tester.tap(find.byKey(const Key('sign-in-language')));
    await tester.tap(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Apple'));
    await tester.pump();

    expect(languageTaps, 1);
    expect(googleTaps, 1);
    expect(appleTaps, 1);
  });

  testWidgets('loading disables the form and shows a spinner', (tester) async {
    await _pump(tester, data: const V2SignInData(loading: true), settle: false);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final submit = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(submit.onPressed, isNull);
    final email = tester.widget<TextField>(
      find.byKey(const Key('sign-in-email')),
    );
    expect(email.enabled, isFalse);
  });

  testWidgets('error state explains the problem and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2SignInData(
        error: 'We could not sign you in. Check your email and password.',
      ),
      onRetry: () => retries++,
    );

    expect(
      find.text('We could not sign you in. Check your email and password.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('narrow phone at 200% text does not overflow in light', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('narrow phone at 200% text does not overflow with an error', (
    tester,
  ) async {
    await _pump(
      tester,
      dark: true,
      width: 320,
      textScale: 2,
      data: const V2SignInData(
        error: 'We could not sign you in. Check your email and password.',
      ),
      onRetry: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('reduced motion still shows every control', (tester) async {
    await _pump(tester, disableAnimations: true);

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
    expect(find.byKey(const Key('sign-in-language')), findsOneWidget);
  });

  testWidgets('disabled controls are announced while loading', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, data: const V2SignInData(loading: true), settle: false);

    expect(
      tester.getSemantics(find.byKey(const Key('sign-in-submit'))),
      matchesSemantics(
        label: 'Sign in',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
    handle.dispose();
  });

  testWidgets(
    'language selector is labelled and reports disabled while loading',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        data: const V2SignInData(loading: true),
        settle: false,
      );

      expect(
        tester.getSemantics(find.byKey(const Key('sign-in-language'))),
        matchesSemantics(
          label: 'Language, English',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      handle.dispose();
    },
  );

  testWidgets('a long language name does not overflow at 320 dp', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: const V2SignInData(language: 'ਪੰਜਾਬੀ (India)'),
      onLanguageTap: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('ਪੰਜਾਬੀ (India)'), findsOneWidget);
  });

  testWidgets('language selector announces the language once', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onLanguageTap: () {});

    expect(find.bySemanticsLabel('Language, English'), findsOneWidget);
    handle.dispose();
  });

  group('phone sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('sign-in-phone')));
      await tester.tap(find.byKey(const Key('sign-in-phone')));
      await tester.pumpAndSettle();
    }

    testWidgets('phone action opens the sheet instead of only calling back', (
      tester,
    ) async {
      var phoneTaps = 0;
      await _pump(tester, onPhone: () => phoneTaps++, onSendPhoneCode: (_) {});

      await openSheet(tester);

      expect(find.byType(V2PhoneAuthSheet), findsOneWidget);
      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-phone')), findsOneWidget);
      // Opening the sheet is the action; the legacy callback is not fired.
      expect(phoneTaps, 0);
    });

    testWidgets('send maps the typed national number', (tester) async {
      String? sent;
      await _pump(
        tester,
        onPhone: () {},
        onSendPhoneCode: (phone) => sent = phone,
      );

      await openSheet(tester);
      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '98765 43210',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pump();

      expect(sent, '98765 43210');
    });

    testWidgets('host step change moves the sheet to code entry and verifies', (
      tester,
    ) async {
      String? sent;
      String? verified;
      var phoneData = const V2PhoneAuthData();

      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: StatefulBuilder(
            builder: (context, setState) => SignInPage(
              phoneData: phoneData,
              onPhone: () {},
              onSendPhoneCode: (phone) {
                sent = phone;
                phoneData = V2PhoneAuthData(
                  step: V2PhoneAuthStep.code,
                  phone: phone,
                  resendSeconds: 30,
                );
                setState(() {});
              },
              onVerifyPhoneCode: (code) => verified = code,
              onResendPhoneCode: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await openSheet(tester);
      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '98765 43210',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pumpAndSettle();

      expect(sent, '98765 43210');
      expect(find.text('Enter your code'), findsOneWidget);
      expect(find.textContaining('+91 98765 43210'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('phone-auth-code-field')),
        '123456',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone-auth-verify')));
      await tester.pump();

      expect(verified, '123456');
    });

    testWidgets('resend maps to its callback once the countdown is over', (
      tester,
    ) async {
      var resends = 0;
      await _pump(
        tester,
        phoneData: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onPhone: () {},
        onSendPhoneCode: (_) {},
        onVerifyPhoneCode: (_) {},
        onResendPhoneCode: () => resends++,
      );

      await openSheet(tester);
      expect(find.byKey(const Key('phone-auth-resend')), findsOneWidget);

      await tester.tap(find.byKey(const Key('phone-auth-resend')));
      await tester.pump();

      expect(resends, 1);
    });

    testWidgets('change number returns the sheet to the number step', (
      tester,
    ) async {
      await _pump(
        tester,
        phoneData: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onPhone: () {},
        onSendPhoneCode: (_) {},
        onVerifyPhoneCode: (_) {},
      );

      await openSheet(tester);
      await tester.tap(find.byKey(const Key('phone-auth-back')));
      await tester.pumpAndSettle();

      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-code-field')), findsNothing);
    });

    testWidgets('change number host callback is honoured', (tester) async {
      var changes = 0;
      await _pump(
        tester,
        phoneData: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onPhone: () {},
        onSendPhoneCode: (_) {},
        onVerifyPhoneCode: (_) {},
        onChangePhoneNumber: () => changes++,
      );

      await openSheet(tester);
      await tester.tap(find.byKey(const Key('phone-auth-back')));
      await tester.pump();

      expect(changes, 1);
    });

    testWidgets('close dismisses the sheet without signing in', (tester) async {
      var phoneTaps = 0;
      await _pump(tester, onPhone: () => phoneTaps++, onSendPhoneCode: (_) {});

      await openSheet(tester);
      await tester.tap(find.byKey(const Key('phone-auth-close')));
      await tester.pumpAndSettle();

      expect(find.byType(V2PhoneAuthSheet), findsNothing);
      expect(phoneTaps, 0);
      expect(find.text('Welcome back'), findsOneWidget);
    });

    testWidgets('legacy host with only onPhone still owns its OTP flow', (
      tester,
    ) async {
      var legacyTaps = 0;
      await _pump(tester, onPhone: () => legacyTaps++);

      await openSheet(tester);
      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '98765 43210',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pumpAndSettle();

      expect(legacyTaps, 1);
      expect(find.byType(V2PhoneAuthSheet), findsNothing);
    });

    testWidgets('phone action is disabled when onPhone is null', (
      tester,
    ) async {
      await _pump(tester);

      final phone = tester.widget<OButton>(
        find.byKey(const Key('sign-in-phone')),
      );
      expect(phone.onPressed, isNull);
    });

    testWidgets('sheet fits 320 dp at 200 % text', (tester) async {
      await _pump(
        tester,
        width: 320,
        textScale: 2,
        onPhone: () {},
        onSendPhoneCode: (_) {},
      );

      await openSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('phone-auth-phone')), findsOneWidget);
    });
  });
}
