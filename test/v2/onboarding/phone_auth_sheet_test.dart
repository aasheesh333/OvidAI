import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';
import 'package:ovid_ai/ui/widgets/external_link.dart';

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

/// Stops a running resend ticker before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
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
    testWidgets('renders the number form and legal note in light', (
      tester,
    ) async {
      await _pump(tester, onClose: () {});

      expect(find.text('Phone sign-in'), findsOneWidget);
      expect(find.text('We text you a 6-digit code.'), findsOneWidget);
      expect(find.text('Phone number'), findsOneWidget);
      expect(find.text('IN'), findsOneWidget);
      expect(find.text('+91'), findsOneWidget);
      expect(find.text('98765 43210'), findsOneWidget);
      expect(find.text('Send code'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-terms')), findsOneWidget);
      expect(find.text('By continuing, you agree to'), findsOneWidget);
      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
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

      expect(find.text('Phone sign-in'), findsOneWidget);
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

    testWidgets('an invalid number is rejected before a request is sent', (
      tester,
    ) async {
      var sends = 0;
      await _pump(tester, onSendCode: (_) => sends++);

      await tester.enterText(find.byKey(const Key('phone-auth-phone')), '123');
      await tester.pump();
      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pump();

      expect(sends, 0);
      expect(find.text('Enter a valid number.'), findsOneWidget);
      // A validation problem is corrected in the field, not retried blindly.
      expect(find.text('Try again'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '98765 43210',
      );
      await tester.pump();
      expect(find.text('Enter a valid number.'), findsNothing);

      await tester.tap(find.byKey(const Key('phone-auth-send')));
      await tester.pump();
      expect(sends, 1);
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
      final handle = tester.ensureSemantics();
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
      expect(
        tester
            .getSemantics(find.byKey(const Key('phone-auth-error')))
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );

      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retries, 1);
      handle.dispose();
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

    testWidgets('legal links open the real documents', (tester) async {
      final opened = <Uri>[];
      externalLinkLauncherForTest = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => externalLinkLauncherForTest = null);

      await _pump(tester, onClose: () {});

      await tester.ensureVisible(find.text('Terms'));
      await tester.tap(find.text('Terms'));
      await tester.pump();
      await tester.ensureVisible(find.text('Privacy Policy'));
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

    testWidgets('keyboard inset adds scroll room below the last control', (
      tester,
    ) async {
      // A Scaffold removes the bottom view inset from its body, so mount the
      // sheet the way a bottom-sheet route does: inside a plain Material.
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
            child: child!,
          ),
          home: Material(child: V2PhoneAuthSheet(onSendCode: (_) {})),
        ),
      );
      await tester.pumpAndSettle();

      final scroll = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(V2PhoneAuthSheet),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final padding = scroll.padding!.resolve(TextDirection.ltr);
      expect(padding.bottom, greaterThanOrEqualTo(OSpace.xl + 300));

      await tester.ensureVisible(find.byKey(const Key('phone-auth-send')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('code step', () {
    const codeData = V2PhoneAuthData(
      step: V2PhoneAuthStep.code,
      phone: '98765 43210',
    );

    testWidgets('renders the code entry and the destination number', (
      tester,
    ) async {
      await _pump(tester, data: codeData, onChangeNumber: () {});

      expect(find.text('Enter your code'), findsOneWidget);
      expect(find.text('Sent to +91 98765 43210'), findsOneWidget);
      expect(find.text('Verification code'), findsOneWidget);
      expect(find.text('Enter all 6 digits'), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-code')), findsOneWidget);
      expect(find.byKey(const Key('phone-auth-resend')), findsNothing);
      expect(find.byKey(const Key('phone-auth-resend-timer')), findsNothing);
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);
      expect(find.byKey(const Key('phone-auth-back')), findsOneWidget);
    });

    testWidgets('six digits enable verify and its button reports the code', (
      tester,
    ) async {
      String? verified;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          code: '123456',
        ),
        onVerify: (value) => verified = value,
      );

      expect(_onPressed(tester, const Key('phone-auth-verify')), isNotNull);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);

      await tester.tap(find.byKey(const Key('phone-auth-verify')));
      await tester.pump();

      expect(verified, '123456');
    });

    testWidgets('the sixth digit auto-submits exactly once', (tester) async {
      String? changed;
      final verified = <String>[];
      await _pump(
        tester,
        data: codeData,
        onCodeChanged: (value) => changed = value,
        onVerify: verified.add,
      );

      await tester.enterText(find.byKey(const Key('phone-auth-code')), '12345');
      await tester.pump();

      expect(changed, '12345');
      expect(verified, isEmpty);
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);

      await tester.enterText(
        find.byKey(const Key('phone-auth-code')),
        '123456',
      );
      await tester.pump();

      expect(changed, '123456');
      expect(verified, ['123456']);

      // A rebuild, or the same six digits arriving again, must not resubmit.
      await tester.pump();
      expect(verified, ['123456']);

      // The explicit button stays wired for assistive tech and can retry.
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNotNull);
      await tester.tap(find.byKey(const Key('phone-auth-verify')));
      await tester.pump();
      expect(verified, ['123456', '123456']);
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

    testWidgets('resend timer ticks down and then becomes a button', (
      tester,
    ) async {
      var resends = 0;
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          resendSeconds: 3,
        ),
        onResend: () => resends++,
        settle: false,
      );

      expect(find.text('Resend code in 3s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 2s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 1s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('phone-auth-resend-timer')), findsNothing);
      expect(find.byKey(const Key('phone-auth-resend')), findsOneWidget);

      await tester.tap(find.byKey(const Key('phone-auth-resend')));
      await tester.pump();

      expect(resends, 1);
      // A resend starts a fresh window so the button cannot be spammed.
      expect(find.byKey(const Key('phone-auth-resend')), findsNothing);
      expect(find.text('Resend code in 1:00'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('host countdown updates restart the visible timer', (
      tester,
    ) async {
      var data = const V2PhoneAuthData(
        step: V2PhoneAuthStep.code,
        phone: '98765 43210',
        resendSeconds: 3,
      );
      late StateSetter host;

      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                host = setState;
                return V2PhoneAuthSheet(data: data, onResend: () {});
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Resend code in 3s'), findsOneWidget);

      host(
        () => data = const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          resendSeconds: 10,
        ),
      );
      await tester.pump();

      expect(find.text('Resend code in 10s'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Resend code in 9s'), findsOneWidget);

      await _unmount(tester);
    });

    testWidgets('resend is available once the timer reaches zero', (
      tester,
    ) async {
      var resends = 0;
      await _pump(tester, data: codeData, onResend: () => resends++);

      expect(find.byKey(const Key('phone-auth-resend-timer')), findsNothing);
      await tester.tap(find.byKey(const Key('phone-auth-resend')));
      await tester.pump();

      expect(resends, 1);
    });

    testWidgets('resend is absent when no handler is wired', (tester) async {
      await _pump(tester, data: codeData, onVerify: (_) {});

      // A button with no handler is a dead control, so it is not rendered.
      expect(find.byKey(const Key('phone-auth-resend')), findsNothing);
      expect(find.byKey(const Key('phone-auth-resend-timer')), findsNothing);
    });

    testWidgets('long waits format as minutes and seconds', (tester) async {
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          resendSeconds: 65,
        ),
        onResend: () {},
        settle: false,
      );

      expect(find.text('Resend code in 1:05'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('a wrong code shows an error and retries', (tester) async {
      var retries = 0;
      final handle = tester.ensureSemantics();
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
      expect(
        tester
            .getSemantics(find.byKey(const Key('phone-auth-error')))
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retries, 1);
      handle.dispose();
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
      await tester.tap(find.byKey(const Key('phone-auth-close')));
      await tester.pump();

      expect(changes, 1);
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

    testWidgets('back is absent when there is no change or close handler', (
      tester,
    ) async {
      await _pump(tester, data: codeData);

      // A back arrow that cannot change the number or close the sheet is a
      // dead control, so the header renders no leading action.
      expect(find.byKey(const Key('phone-auth-back')), findsNothing);
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

    testWidgets('code step disables entry while the code is verified', (
      tester,
    ) async {
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          code: '123456',
          loading: true,
        ),
        settle: false,
        onVerify: (_) {},
      );

      expect(find.text('Verifying…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('phone-auth-code-field')))
            .enabled,
        isFalse,
      );
      expect(_onPressed(tester, const Key('phone-auth-verify')), isNull);
    });
  });

  group('accessibility and narrow screens', () {
    testWidgets('the code field carries an explicit label and value', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
          code: '123456',
        ),
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

    testWidgets('country button carries its country and dial code', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, onCountryChanged: (_) {});

      expect(
        tester.getSemantics(find.byKey(const Key('phone-auth-country'))).label,
        'Country code, India, +91',
      );
      handle.dispose();
    });

    testWidgets('copy stays inside the header and button budgets', (
      tester,
    ) async {
      int words(String text) =>
          text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

      await _pump(tester, onSendCode: (_) {});

      expect(words('Phone sign-in'), lessThanOrEqualTo(3));
      expect(words('We text you a 6-digit code.'), lessThanOrEqualTo(6));
      expect(words('Send code'), lessThanOrEqualTo(3));

      await _unmount(tester);

      await _pump(
        tester,
        data: const V2PhoneAuthData(
          step: V2PhoneAuthStep.code,
          phone: '98765 43210',
        ),
        onVerify: (_) {},
      );

      expect(words('Enter your code'), lessThanOrEqualTo(3));
      expect(words('Sent to +91 98765 43210'), lessThanOrEqualTo(6));
      expect(words('Verify and continue'), lessThanOrEqualTo(3));
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
      expect(find.text('Phone sign-in'), findsOneWidget);
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

    testWidgets('wide window keeps the sheet column capped', (tester) async {
      await _pump(tester, width: 1280, onSendCode: (_) {});

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const Key('phone-auth-send'))).width,
        lessThanOrEqualTo(460.5),
      );
    });

    testWidgets('wide dark window at 200% keeps the sheet capped', (
      tester,
    ) async {
      await _pump(
        tester,
        dark: true,
        width: 1280,
        height: 900,
        textScale: 2,
        onSendCode: (_) {},
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const Key('phone-auth-send'))).width,
        lessThanOrEqualTo(460.5),
      );
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
