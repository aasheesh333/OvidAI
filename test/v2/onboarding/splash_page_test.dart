import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/splash_page.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  V2SplashData data = const V2SplashData(),
  VoidCallback? onRetry,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool reducedMotion = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reducedMotion,
        ),
        child: child!,
      ),
      home: SplashPage(data: data, onRetry: onRetry),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets('splash renders the mark, name and tagline in light', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('CHAT. CODE. CREATE.'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);
  });

  testWidgets('splash renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('CHAT. CODE. CREATE.'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);
  });

  testWidgets('splash has no call to action on the happy path', (tester) async {
    await _pump(tester);

    expect(find.byType(OButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('splash progress follows injected data and is announced once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      data: const V2SplashData(progress: 0.75, statusLabel: 'Almost ready'),
    );

    final progress = tester.widget<OProgressBar>(find.byType(OProgressBar));
    expect(progress.value, 0.75);
    expect(find.text('Almost ready'), findsOneWidget);

    // The bar and its label are one node: a screen reader hears the sentence
    // once, with the percentage attached.
    final node = tester.getSemantics(
      find.bySemanticsLabel('Almost ready'),
    );
    expect(node.value, '75 percent');
    expect(find.bySemanticsLabel('Ovid Si logo'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('splash defaults carry no demo progress', (tester) async {
    const data = V2SplashData();
    expect(data.progress, 0);
    expect(data.statusLabel, 'Starting your agent');
    expect(data.hasError, isFalse);

    await _pump(tester);
    final progress = tester.widget<OProgressBar>(find.byType(OProgressBar));
    expect(progress.value, 0);
  });

  testWidgets('splash error state shows the message and retries', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2SplashData(errorLabel: 'We could not reach Ovid Si.'),
      onRetry: () => retries++,
    );

    expect(find.text('We could not reach Ovid Si.'), findsOneWidget);
    expect(find.byType(OProgressBar), findsNothing);
    expect(find.text('Try again'), findsOneWidget);

    // The retry control meets the 48 dp touch target.
    expect(tester.getSize(find.byType(OButton)).height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('splash hides retry when no handler can retry', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      data: const V2SplashData(errorLabel: 'We could not reach Ovid Si.'),
    );

    // The failure is announced, but no dead "Try again" is offered.
    expect(
      find.bySemanticsLabel('We could not reach Ovid Si.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsNothing);
    expect(find.byType(OButton), findsNothing);

    handle.dispose();
  });

  testWidgets('splash fits 320 dp at 200 % text without overflow', (
    tester,
  ) async {
    for (final data in const [
      V2SplashData(),
      V2SplashData(errorLabel: 'We could not reach Ovid Si.'),
    ]) {
      for (final dark in const [false, true]) {
        await _pump(
          tester,
          data: data,
          onRetry: () {},
          dark: dark,
          size: const Size(320, 568),
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Ovid Si'), findsOneWidget);
        expect(find.text('CHAT. CODE. CREATE.'), findsOneWidget);

        // The identity block must fit above the footer instead of scrolling
        // under it: no clipped wordmark or tagline.
        final tagline = tester.getRect(find.text('CHAT. CODE. CREATE.'));
        final footerTop = data.hasError
            ? tester.getRect(find.text(data.errorLabel!)).top
            : tester.getRect(find.byType(OProgressBar)).top;
        expect(tagline.bottom, lessThan(footerTop));
      }
    }
  });

  testWidgets('splash shows its content with reduced motion', (tester) async {
    await _pump(tester, reducedMotion: true, settle: false);

    // Motion is bypassed rather than hiding the content behind a delay.
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('CHAT. CODE. CREATE.'), findsOneWidget);
  });
}
