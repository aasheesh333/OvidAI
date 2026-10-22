import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';
import 'package:ovid_ai/ui/v2/onboarding/sign_in_page.dart';
import 'package:ovid_ai/ui/widgets/external_link.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  bool settle = true,
  V2SignInData data = const V2SignInData(),
  VoidCallback? onGoogle,
  VoidCallback? onPhone,
  V2PhoneAuthData? phoneData,
  ValueChanged<String>? onPhoneChanged,
  ValueChanged<V2PhoneCountry>? onPhoneCountryChanged,
  ValueChanged<String>? onSendPhoneCode,
  ValueChanged<String>? onVerifyPhoneCode,
  VoidCallback? onResendPhoneCode,
  VoidCallback? onChangePhoneNumber,
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
        onGoogle: onGoogle,
        onPhone: onPhone,
        phoneData: phoneData,
        onPhoneChanged: onPhoneChanged,
        onPhoneCountryChanged: onPhoneCountryChanged,
        onSendPhoneCode: onSendPhoneCode,
        onVerifyPhoneCode: onVerifyPhoneCode,
        onResendPhoneCode: onResendPhoneCode,
        onChangePhoneNumber: onChangePhoneNumber,
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
  testWidgets('sign in offers exactly Google and phone in light', (
    tester,
  ) async {
    await _pump(tester, onGoogle: () {}, onPhone: () {});

    // The shared identity opens the step, then the two providers.
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.bySemanticsLabel('Ovid Si logo'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with phone'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('the step renders no email form and no Apple control', (
    tester,
  ) async {
    await _pump(tester, onGoogle: () {}, onPhone: () {});

    // Email/password has no backend, so there is no form to fill in: a field
    // that cannot submit is a dead control (MINIMAL_UI_CONTRACT §8).
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Email address'), findsNothing);
    expect(find.text('Password'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    expect(find.byKey(const Key('sign-in-email')), findsNothing);
    expect(find.byKey(const Key('sign-in-password')), findsNothing);
    // Apple has no handler anywhere in the app, so it is never offered.
    expect(find.text('Continue with Apple'), findsNothing);
  });

  testWidgets('Google is the filled primary and phone is outlined', (
    tester,
  ) async {
    await _pump(tester, onGoogle: () {}, onPhone: () {});

    final google = tester.widget<OButton>(
      find.byKey(const Key('sign-in-submit')),
    );
    expect(google.variant, OButtonVariant.primary);
    final phone = tester.widget<OButton>(
      find.byKey(const Key('sign-in-phone')),
    );
    expect(phone.variant, OButtonVariant.secondary);
  });

  testWidgets('sign in renders correctly in dark', (tester) async {
    await _pump(tester, dark: true, onGoogle: () {}, onPhone: () {});

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with phone'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('Google calls back', (tester) async {
    var googleTaps = 0;
    await _pump(tester, onGoogle: () => googleTaps++, onPhone: () {});

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();

    expect(googleTaps, 1);
  });

  testWidgets('only the provider that was tapped shows in-flight', (
    tester,
  ) async {
    var loading = false;
    var googleCalls = 0;
    late StateSetter host;

    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) {
            host = setState;
            return SignInPage(
              data: V2SignInData(loading: loading),
              onGoogle: () {
                googleCalls++;
                setState(() => loading = true);
              },
              onPhone: () {},
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();

    final google = tester.widget<OButton>(
      find.byKey(const Key('sign-in-submit')),
    );
    final phone = tester.widget<OButton>(
      find.byKey(const Key('sign-in-phone')),
    );
    expect(googleCalls, 1);
    expect(google.loading, isTrue);
    expect(phone.loading, isFalse);
    expect(phone.onPressed, isNull);

    // A second tap cannot start the request again while it is in flight.
    await tester.tap(find.text('Continue with Google'), warnIfMissed: false);
    await tester.pump();
    expect(googleCalls, 1);

    // The host completed the request: both controls return to idle.
    host(() => loading = false);
    await tester.pump();
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-submit'))).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-phone'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('the phone action owns its own in-flight state', (tester) async {
    var loading = false;
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) => SignInPage(
            data: V2SignInData(loading: loading),
            onGoogle: () {},
            onPhone: () => setState(() => loading = true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sign-in-phone')));
    await tester.pump();

    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-phone'))).loading,
      isTrue,
    );
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-submit'))).loading,
      isFalse,
    );
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-submit'))).onPressed,
      isNull,
    );
  });

  testWidgets('cancellation returns to idle instead of showing an error', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2SignInData(error: 'cancelled'),
      onGoogle: () {},
      onPhone: () {},
    );

    expect(find.byKey(const Key('sign-in-error')), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-submit'))).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<OButton>(find.byKey(const Key('sign-in-phone'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('loading disables both actions and shows a spinner', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2SignInData(loading: true),
      onGoogle: () {},
      onPhone: () {},
      settle: false,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final google = tester.widget<OButton>(
      find.byKey(const Key('sign-in-submit')),
    );
    expect(google.onPressed, isNull);
    final phone = tester.widget<OButton>(
      find.byKey(const Key('sign-in-phone')),
    );
    expect(phone.onPressed, isNull);
  });

  testWidgets('error state explains the problem and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2SignInData(
        error: 'Sign-in failed. Check your connection and retry.',
      ),
      onRetry: () => retries++,
    );

    expect(
      find.text('Sign-in failed. Check your connection and retry.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('an error with nothing to retry shows no dead Try again', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2SignInData(error: 'Sign-in is unavailable right now.'),
    );

    expect(find.text('Sign-in is unavailable right now.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('legal links open the real documents before choosing', (
    tester,
  ) async {
    final opened = <Uri>[];
    externalLinkLauncherForTest = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => externalLinkLauncherForTest = null);

    await _pump(tester, onGoogle: () {}, onPhone: () {});

    expect(find.text('By continuing, you agree to'), findsOneWidget);
    expect(find.text('Terms'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);

    await tester.ensureVisible(find.text('Terms'));
    await tester.tap(find.text('Terms'));
    await tester.pump();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pump();

    expect(opened, hasLength(2));
    expect(opened[0].path, '/terms');
    expect(opened[1].path, '/privacy');
  });

  testWidgets('legal links disappear when no URL is configured', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const Scaffold(
          body: V2LegalNote(termsUrl: '', privacyUrl: ''),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Terms'), findsNothing);
    expect(find.text('Privacy Policy'), findsNothing);
    expect(find.text('By continuing, you agree to'), findsNothing);
  });

  testWidgets('wide window keeps the onboarding column capped', (tester) async {
    await _pump(tester, width: 1280, onGoogle: () {}, onPhone: () {});

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('sign-in-phone'))).width,
      lessThanOrEqualTo(592.5),
    );
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('wide dark window at 200% keeps the column capped', (
    tester,
  ) async {
    await _pump(
      tester,
      dark: true,
      width: 1280,
      textScale: 2,
      onGoogle: () {},
      onPhone: () {},
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('sign-in-phone'))).width,
      lessThanOrEqualTo(592.5),
    );
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
  });

  testWidgets('narrow phone at 200% text does not overflow in light', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      onGoogle: () {},
      onPhone: () {},
    );

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
        error: 'Sign-in failed. Check your connection and retry.',
      ),
      onRetry: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('reduced motion still shows every control', (tester) async {
    await _pump(
      tester,
      disableAnimations: true,
      onGoogle: () {},
      onPhone: () {},
    );

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
    expect(find.byKey(const Key('sign-in-phone')), findsOneWidget);
  });

  testWidgets('disabled controls are announced while loading', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      data: const V2SignInData(loading: true),
      onGoogle: () {},
      onPhone: () {},
      settle: false,
    );

    expect(
      tester.getSemantics(find.byKey(const Key('sign-in-submit'))),
      matchesSemantics(
        label: 'Continue with Google, loading',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
        hasTapAction: false,
      ),
    );
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
      expect(find.text('Phone sign-in'), findsOneWidget);
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(sent, '98765 43210');
      expect(find.text('Enter your code'), findsOneWidget);
      expect(find.textContaining('+91 98765 43210'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('phone-auth-code-field')),
        '123456',
      );
      await tester.pump();
      await tester.pump();

      // The sixth digit auto-submits; the explicit button is still allowed
      // and stays wired for assistive tech.
      expect(verified, '123456');
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

      expect(find.text('Phone sign-in'), findsOneWidget);
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

    testWidgets('a host-owned OTP flow is opened in one tap', (tester) async {
      var legacyTaps = 0;
      await _pump(tester, onPhone: () => legacyTaps++);

      await tester.ensureVisible(find.byKey(const Key('sign-in-phone')));
      await tester.tap(find.byKey(const Key('sign-in-phone')));
      await tester.pumpAndSettle();

      // The page does not ask for the number and then hand over to a second
      // flow that asks again.
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
