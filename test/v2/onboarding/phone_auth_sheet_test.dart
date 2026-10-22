import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';

Future<void> _pump(
  WidgetTester tester, {
  V2PhoneAuthData data = const V2PhoneAuthData(),
  ValueChanged<V2PhoneCountry>? onCountryChanged,
  ValueChanged<String>? onPhoneChanged,
  ValueChanged<String>? onSendCode,
  ValueChanged<String>? onCodeChanged,
  ValueChanged<String>? onVerify,
  VoidCallback? onResend,
  VoidCallback? onChangeNumber,
  VoidCallback? onClose,
  VoidCallback? onRetry,
  VoidCallback? onTerms,
  VoidCallback? onPrivacy,
  bool dark = false,
  bool settle = true,
  double width = 400,
  double height = 800,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
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
      home: Scaffold(
        body: V2PhoneAuthSheet(
          data: data,
          onCountryChanged: onCountryChanged,
          onPhoneChanged: onPhoneChanged,
          onSendCode: onSendCode,
          onCodeChanged: onCodeChanged,
          onVerify: onVerify,
          onResend: onResend,
          onChangeNumber: onChangeNumber,
          onClose: onClose,
          onRetry: onRetry,
          onTerms: onTerms,
          onPrivacy: onPrivacy,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

VoidCallback? _onPressed(WidgetTester tester, Key key) =>
    tester.widget<OButton>(find.byKey(key)).onPressed;

void _expectNoTextPastEdge(WidgetTester tester) {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject as RenderBox?;
    if (box == null || !box.hasSize) continue;
    final offset = box.localToGlobal(Offset.zero);
    if (!offset.dx.isFinite || !box.size.width.isFinite) continue;
    expect(
      offset.dx + box.size.width,
      lessThanOrEqualTo(size.width + 0.01),
      reason: 'Text extends past the right edge: ${element.widget}',
    );
  }
}

void main() {
  group('phone step', () {
    testWidgets('renders the number form and terms note in light', (
      tester,
    ) async {
      await _pump(tester, onClose: () {});

      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(find.text('Phone number'), findsOneWidget);
      expect(find.text('IN'), findsOneWidget);
      expect(find.text('+91'), findsOneWidget);
      expect(find.text('98765 43210'), findsOneWidget);
      expect(find.text('Send code'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-terms')), findsOneWidget);
      expect(find.text('By continuing, you agree to our '), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-close')), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-code')), findsNothing);
    });

    testWidgets('no close control when the sheet cannot dismiss itself', (
      tester,
    ) async {
      await _pump(tester);

      // A close icon with no handler is a dead control: the host must wire it.
      expect(find.byKey(const Key('phone-auth-close')), findsNothing);
    });

    testWidgets('renders in dark', (tester) async {
      await _pump(tester, dark: true);

      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(find.text('Send code'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-terms')), findsOneWidget);
    });

    testWidgets('send stays disabled until a number is typed', (tester) async {
      String? typed;
      String? sent;
      await _pump(
        tester,
        onPhoneChanged: (value) => typed = value,
        onSendCode: (value) => sent = value,
      );

      expect(_onPressed(tester, const Key('phone-auth-send')), isNull);

      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '98765 43210',
      );
      await tester.pump();

      expect(typed, '98765 43210');
      expect(_onPressed(tester, const Key('phone-auth-send')), isNotNull);

      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pump();

      expect(sent, '98765 43210');
    });

    testWidgets('country picker searches and reports the selection', (
      tester,
    ) async {
      V2PhoneCountry? selected;
      await _pump(tester, onCountryChanged: (country) => selected = country);

      await tester.tap(find.byKey(const Key('phone-auth-country')));
      await tester.pumpAndSettle();

      expect(find.text('Country code'), findsOneWidget);
      expect(find.text('India'), findsOneWidget);
      expect(find.text('United Kingdom'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('phone-auth-country-search')),
        'kingdom',
      );
      await tester.pump();

      expect(find.text('United Kingdom'), findsOneWidget);
      expect(find.text('India'), findsNothing);

      await tester.tap(find.text('United Kingdom'));
      await tester.pumpAndSettle();

      expect(selected?.region, 'GB');
      expect(selected?.dialCode, '+44');
      expect(find.text('Country code'), findsNothing);
    });

    testWidgets('country picker empty state offers a way back', (tester) async {
      await _pump(tester, onCountryChanged: (_) {});

      await tester.tap(find.byKey(const Key('phone-auth-country')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('phone-auth-country-search')),
        'zzzz',
      );
      await tester.pump();

      expect(find.text('No countries found'), findsOneWidget);
      expect(find.text('Clear search'), findsOneWidget);

      await tester.tap(find.text('Clear search').last);
      await tester.pump();

      expect(find.text('India'), findsOneWidget);
      expect(find.text('No countries found'), findsNothing);
    });

    testWidgets('error is announced and retried', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          phone: '98765 43210',
          error: 'That number does not look right. Check it and try again.',
        ),
        onRetry: () => retries++,
      );

      expect(
        find.text('That number does not look right. Check it and try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('phone-auth-error')), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('retry falls back to sending when no handler is wired', (
      tester,
    ) async {
      var sends = 0;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          phone: '98765 43210',
          error: 'The SMS could not be sent.',
        ),
        onSendCode: (_) => sends++,
      );

      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(sends, 1);
    });

    testWidgets('close reports once', (tester) async {
      var closes = 0;
      await _pump(tester, onClose: () => closes++);

      await tester.tap(find.byKey(const Key('phone-auth-close')));
      await tester.pump();

      expect(closes, 1);
    });

    testWidgets('terms and privacy links call their handlers', (tester) async {
      var terms = 0;
      var privacy = 0;
      final handle = tester.ensureSemantics();
      await _pump(tester, onTerms: () => terms++, onPrivacy: () => privacy++);

      await tester.tap(find.bySemanticsLabel('Terms'));
      await tester.tap(find.bySemanticsLabel('Privacy Policy'));
      await tester.pump();

      expect(terms, 1);
      expect(privacy, 1);
      handle.dispose();
    });
  });

  group('code step', () {
    const codeData = V2PhoneAuthData(
      step: V2PhoneAuthStep.code,
      phone: '98765 43210',
      resendSeconds: 45,
    );

    testWidgets('renders the code entry and resend timer', (tester) async {
      await _pump(tester, data: codeData);

      expect(find.text('Enter your code'), findsOneWidget);
      expect(
        find.text('We sent a 6-digit code to +91 98765 43210.'),
        findsOneWidget,
      );
      expect(find.text('Verification code'), findsOneWidget);
      expect(find.text('Enter all 6 digits'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-code')), findsOneWidget);
      expect(find.text('Resend code in 45s'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-resend')), findsNothing);
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);
    });

    testWidgets('six digits enable verify and verify reports the code', (
      tester,
    ) async {
      String? changed;
      String? verified;
      await _pump(
        tester,
        data: codeData,
        onCodeChanged: (value) => changed = value,
        onVerify: (value) => verified = value,
      );

      await tester.enterText(find.byKey(const Key('phone-auth-code')), '12345');
      await tester.pump();

      expect(changed, '12345');
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);

      await tester.enterText(
        find.byKey(const Key('phone-auth-code')),
        '123456',
      );
      await tester.pump();

      expect(_onPressed(tester, const Key('phone-auth-verify')), isNotNull);
      await tester.tap(find.byKey(const Key('phone-auth-verify')));
      await tester.pump();

      expect(verified, '123456');
      expect(find.text('1'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
    });

    testWidgets('non-digits never reach the field', (tester) async {
      String? changed;
      await _pump(
        tester,
        data: codeData,
        onCodeChanged: (value) => changed = value,
      );

      await tester.enterText(
        find.byKey(const Key('phone-auth-code')),
        '12ab34',
      );
      await tester.pump();

      expect(changed, '1234');
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);
    });

    testWidgets('resend is available once the timer reaches zero', (
      tester,
    ) async {
      var resends = 0;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onResend: () => resends++,
      );

      expect(find.byKey(const Key('phone-auth-resend-timer')), findsNothing);
      await tester.tap(find.byKey(const Key('phone-auth-resend')));
      await tester.pump();

      expect(resends, 1);
    });

    testWidgets('long waits format as minutes and seconds', (tester) async {
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          resendSeconds: 65,
        ),
      );

      expect(find.text('Resend code in 1:05'), findsOneWidget);
    });

    testWidgets('a wrong code shows an error and retries', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          error: 'That code did not work. Check it and try again.',
        ),
        onRetry: () => retries++,
      );

      expect(
        find.text('That code did not work. Check it and try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('change number and close report', (tester) async {
      var changes = 0;
      var closes = 0;
      await _pump(
        tester,
        data: codeData,
        onChangeNumber: () => changes++,
        onClose: () => closes++,
      );

      await tester.tap(find.byKey(const Key('phone-auth-back')));
      await tester.tap(find.byKey(const Key('phone-auth-change')));
      await tester.tap(find.byKey(const Key('phone-auth-close')));
      await tester.pump();

      expect(changes, 2);
      expect(closes, 1);
    });

    testWidgets('back falls back to close when no change handler is wired', (
      tester,
    ) async {
      var closes = 0;
      await _pump(tester, data: codeData, onClose: () => closes++);

      await tester.tap(find.byKey(const Key('phone-auth-back')));
      await tester.pump();

      expect(closes, 1);
    });
  });

  group('loading', () {
    testWidgets('phone step disables every action and shows progress', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        data: const V2PhoneAuthData(phone: '98765 43210', loading: true),
        settle: false,
        onCountryChanged: (_) {},
        onSendCode: (_) {},
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Sending code…'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('phone-auth-phone')))
            .enabled,
        isFalse,
      );
      expect(_onPressed(tester, const Key('phone-auth-send')), isNull);
      expect(
        tester.getSemantics(find.byKey(const Key('phone-auth-country'))),
        matchesSemantics(
          label: 'Country code, India, +91',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('phone-auth-send'))),
        matchesSemantics(
          label: 'Sending code…',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('code step disables entry and announces resend progress', (
      tester,
    ) async {
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          loading: true,
        ),
        settle: false,
        onVerify: (_) {},
      );

      expect(find.text('Verifying…'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('phone-auth-code-field')))
            .enabled,
        isFalse,
      );
      expect(find.text('One moment…'), findsOneWidget);
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);
    });
  });

  group('accessibility and narrow screens', () {
    testWidgets('country and code field carry explicit labels', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          code: '123456',
        ),
        onCountryChanged: (_) {},
      );

      expect(
        tester.getSemantics(find.byKey(const Key('phone-auth-code'))).label,
        '6-digit verification code',
      );
      expect(
        tester.getSemantics(find.byKey(const Key('phone-auth-code'))).value,
        '123456',
      );
      handle.dispose();
    });

    testWidgets('phone step fits 320 dp at 200% text in light', (tester) async {
      await _pump(
        tester,
        width: 320,
        textScale: 2,
        onCountryChanged: (_) {},
        onSendCode: (_) {},
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Sign in with your phone'), findsOneWidget);
      _expectNoTextPastEdge(tester);

      await tester.ensureVisible(find.byKey(const Key('phone-auth-send')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('code step with error fits 320 dp at 200% in dark', (
      tester,
    ) async {
      await _pump(
        tester,
        dark: true,
        width: 320,
        textScale: 2,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          error: 'That code did not work. Check the six digits and try again.',
          resendSeconds: 59,
        ),
        onRetry: () {},
        onResend: () {},
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Enter your code'), findsOneWidget);
      _expectNoTextPastEdge(tester);
    });

    testWidgets('country picker fits 320 dp at 200% text', (tester) async {
      await _pump(
        tester,
        width: 320,
        height: 720,
        textScale: 2,
        onCountryChanged: (_) {},
      );

      await tester.ensureVisible(find.byKey(const Key('phone-auth-country')));
      await tester.tap(find.byKey(const Key('phone-auth-country')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Country code'), findsOneWidget);
      _expectNoTextPastEdge(tester);

      await tester.enterText(
        find.byKey(const Key('phone-auth-country-search')),
        'zz',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('No countries found'), findsOneWidget);
    });

    testWidgets('reduced motion still renders every control', (tester) async {
      await _pump(
        tester,
        disableAnimations: true,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onResend: () {},
      );

      expect(find.text('Enter your code'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-code')), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-verify')), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-resend')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('external data changes update the visible fields', (
      tester,
    ) async {
      await _pump(tester, data: const V2PhoneAuthData(phone: '111'));

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const Scaffold(
            body: V2PhoneAuthSheet(data: V2PhoneAuthData(phone: '98765 43210')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const Key('phone-auth-phone')))
            .controller
            ?.text,
        '98765 43210',
      );
    });
  });
}
