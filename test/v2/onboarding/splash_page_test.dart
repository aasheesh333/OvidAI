import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/onboarding/splash_page.dart';

const _slowMessage = 'Still starting. Check connection.';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  V2SplashData data = const V2SplashData(),
  VoidCallback? onRetry,
  VoidCallback? onReady,
  Duration? slowAfter = const Duration(seconds: 10),
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
      home: SplashPage(
        data: data,
        onRetry: onRetry,
        onReady: onReady,
        slowAfter: slowAfter,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Lets the screen's honest watchdog expire and paints the resulting state.
Future<void> _expireSlow(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

int _words(String value) =>
    value.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

bool _isHorizontalScroll(Widget widget) =>
    widget is SingleChildScrollView &&
    widget.scrollDirection == Axis.horizontal;

void main() {
  testWidgets('splash renders the mark and name in light', (tester) async {
    await _pump(tester);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.bySemanticsLabel('Ovid Si logo'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);
  });

  testWidgets('splash renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Ovid Si'), findsOneWidget);
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
    final node = tester.getSemantics(find.bySemanticsLabel('Almost ready'));
    expect(node.value, '75 percent');
    expect(find.bySemanticsLabel('Ovid Si logo'), findsOneWidget);
    expect(find.bySemanticsLabel('Almost ready'), findsOneWidget);

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

  testWidgets('progress never advances on a timer, only with new data', (
    tester,
  ) async {
    await _pump(tester, data: const V2SplashData(progress: 0.25));
    expect(tester.widget<OProgressBar>(find.byType(OProgressBar)).value, 0.25);

    // Two seconds of wall clock must not move the bar: no fake fill.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.widget<OProgressBar>(find.byType(OProgressBar)).value, 0.25);

    await _pump(tester, data: const V2SplashData(progress: 0.5));
    expect(tester.widget<OProgressBar>(find.byType(OProgressBar)).value, 0.5);
  });

  testWidgets('out-of-range and NaN progress never crash the bar', (
    tester,
  ) async {
    for (final progress in const [double.nan, -1.0, 1.4]) {
      await _pump(tester, data: V2SplashData(progress: progress));

      expect(tester.takeException(), isNull);
      final bar = tester.widget<OProgressBar>(find.byType(OProgressBar));
      expect(bar.value, inInclusiveRange(0, 1));
      expect(bar.value.isNaN, isFalse);
    }
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
    expect(
      tester.getSize(find.byType(OButton)).height,
      greaterThanOrEqualTo(48),
    );

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

  testWidgets('a blank error is not a failure state', (tester) async {
    await _pump(tester, data: const V2SplashData(errorLabel: '   '));

    expect(find.byType(OProgressBar), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a long error stays one line and keeps its full semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    const message =
        'Ovid could not start. Check your connection and try again.';
    await _pump(
      tester,
      data: const V2SplashData(errorLabel: message),
      onRetry: () {},
      size: const Size(320, 568),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final line = tester.getRect(find.text(message));
    // One caption line at 200 % is ~34 dp; a paragraph would be much taller.
    expect(line.height, lessThan(50));
    expect(find.bySemanticsLabel(message), findsOneWidget);

    handle.dispose();
  });

  testWidgets('slow state appears only after a real timeout and retries', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2SplashData(progress: 0.2),
      slowAfter: const Duration(milliseconds: 40),
      onRetry: () => retries++,
      settle: false,
    );

    // Before the timeout the screen is still honestly loading.
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text(_slowMessage), findsNothing);
    expect(find.byType(OProgressBar), findsOneWidget);

    await _expireSlow(tester);
    expect(find.text(_slowMessage), findsOneWidget);
    expect(find.byType(OProgressBar), findsNothing);
    expect(find.text('Try again'), findsOneWidget);

    // Retry returns to loading immediately, even if the host's callback does
    // not change the data, and re-arms the watchdog.
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
    expect(find.text(_slowMessage), findsNothing);
    expect(find.byType(OProgressBar), findsOneWidget);

    await _expireSlow(tester);
    expect(find.text(_slowMessage), findsOneWidget);
  });

  testWidgets('slow state without a handler shows no dead retry', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      slowAfter: const Duration(milliseconds: 10),
      settle: false,
    );

    await _expireSlow(tester);
    expect(find.text(_slowMessage), findsOneWidget);
    expect(find.byType(OButton), findsNothing);
    expect(find.text('Try again'), findsNothing);

    final node = tester.getSemantics(find.bySemanticsLabel(_slowMessage));
    expect(node.flagsCollection.isLiveRegion, isTrue);

    handle.dispose();
  });

  testWidgets('slow state is announced with the retry after it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      slowAfter: const Duration(milliseconds: 10),
      onRetry: () {},
      settle: false,
    );
    await _expireSlow(tester);

    final wordmark = tester.getRect(find.text('Ovid Si'));
    final message = tester.getRect(find.text(_slowMessage));
    final retry = tester.getRect(find.byKey(const Key('splash-retry')));
    expect(wordmark.bottom, lessThan(message.top));
    expect(message.bottom, lessThan(retry.top));
    expect(find.bySemanticsLabel('Try again'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('ready advances exactly once, even across rebuilds', (
    tester,
  ) async {
    var readyCalls = 0;
    await _pump(
      tester,
      data: const V2SplashData(progress: 1),
      onReady: () => readyCalls++,
    );

    expect(readyCalls, 1);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);

    // A host rebuild with the same ready data must not advance again.
    await _pump(
      tester,
      data: const V2SplashData(progress: 1),
      onReady: () => readyCalls++,
    );
    expect(readyCalls, 1);

    // Nor may a later ready transition re-fire after the screen already
    // advanced: one screen can never double-navigate.
    await _pump(
      tester,
      data: const V2SplashData(progress: 0.4),
      onReady: () => readyCalls++,
    );
    await _pump(
      tester,
      data: const V2SplashData(progress: 1),
      onReady: () => readyCalls++,
    );
    expect(readyCalls, 1);
  });

  testWidgets('progress reaching 100 % advances exactly once', (tester) async {
    var readyCalls = 0;
    await _pump(
      tester,
      data: const V2SplashData(progress: 0.5),
      onReady: () => readyCalls++,
    );
    expect(readyCalls, 0);

    await _pump(
      tester,
      data: const V2SplashData(progress: 1),
      onReady: () => readyCalls++,
    );
    expect(readyCalls, 1);

    await _pump(
      tester,
      data: const V2SplashData(progress: 1),
      onReady: () => readyCalls++,
    );
    expect(readyCalls, 1);
  });

  testWidgets('not-ready data never advances', (tester) async {
    var readyCalls = 0;
    await _pump(
      tester,
      data: const V2SplashData(progress: 0.99),
      onReady: () => readyCalls++,
    );

    expect(readyCalls, 0);
    expect(find.text('Ready'), findsNothing);
  });

  testWidgets('an error at 100 % is still an error, not ready', (tester) async {
    var readyCalls = 0;
    await _pump(
      tester,
      data: const V2SplashData(
        progress: 1,
        errorLabel: 'We could not reach Ovid Si.',
      ),
      onReady: () => readyCalls++,
    );

    expect(readyCalls, 0);
    expect(find.text('We could not reach Ovid Si.'), findsOneWidget);
    expect(find.text('Ready'), findsNothing);
  });

  testWidgets('ready stops animating: nothing loops after the screen settles', (
    tester,
  ) async {
    await _pump(tester, data: const V2SplashData(progress: 1), onReady: () {});
    await tester.pump(const Duration(seconds: 1));

    expect(tester.binding.transientCallbackCount, 0);
    expect(find.text('Ready'), findsOneWidget);
  });

  testWidgets('entrance motion is 200 ms or less', (tester) async {
    await _pump(tester, settle: false);

    final slides = tester.widgetList<OFadeSlide>(find.byType(OFadeSlide));
    expect(slides, isNotEmpty);
    for (final slide in slides) {
      expect(
        slide.duration,
        isNotNull,
        reason: 'splash must not fall back to the 260 ms default',
      );
      expect(
        slide.duration!.inMilliseconds,
        lessThanOrEqualTo(OMotion.base.inMilliseconds),
      );
    }
  });

  testWidgets('splash shows its content with reduced motion', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, reducedMotion: true, settle: false);

    // Motion is bypassed rather than hiding the content behind a delay, and
    // the progress bar is painted statically instead of animating its fill.
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.byType(OProgressBar), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.bySemanticsLabel('Starting your agent'), findsOneWidget);

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

        // The identity block must fit above the footer instead of scrolling
        // under it: no clipped wordmark.
        final wordmark = tester.getRect(find.text('Ovid Si'));
        final footerTop = data.hasError
            ? tester.getRect(find.text(data.errorLabel!)).top
            : tester.getRect(find.byType(OProgressBar)).top;
        expect(wordmark.bottom, lessThan(footerTop));
      }
    }
  });

  testWidgets('splash fits every band at 100 % and 200 % text', (tester) async {
    const widths = <double>[320, 360, 412, 600, 900];
    const states = <V2SplashData>[
      V2SplashData(progress: 0.35),
      V2SplashData(progress: 1),
      V2SplashData(errorLabel: 'We could not reach Ovid Si.'),
    ];

    for (final width in widths) {
      for (final scale in const <double>[1, 2]) {
        for (final dark in const [false, true]) {
          for (final state in states) {
            await _pump(
              tester,
              data: state,
              onRetry: () {},
              onReady: () {},
              dark: dark,
              size: Size(width, width < 600 ? 568 : 900),
              textScale: scale,
            );

            final reason = '${width}dp @ ${scale}x, dark=$dark, $state';
            expect(tester.takeException(), isNull, reason: reason);
            expect(
              find.byWidgetPredicate(_isHorizontalScroll),
              findsNothing,
              reason: '$reason scrolled horizontally',
            );
            expect(find.text('Ovid Si'), findsOneWidget, reason: reason);
            expect(
              tester.getCenter(find.text('Ovid Si')).dx,
              closeTo(width / 2, 1),
              reason: '$reason is not centred',
            );
          }

          await _pump(
            tester,
            slowAfter: const Duration(milliseconds: 10),
            onRetry: () {},
            dark: dark,
            size: Size(width, width < 600 ? 568 : 900),
            textScale: scale,
            settle: false,
          );
          await _expireSlow(tester);

          final reason = '${width}dp @ ${scale}x, dark=$dark, slow';
          expect(tester.takeException(), isNull, reason: reason);
          expect(find.text(_slowMessage), findsOneWidget, reason: reason);
          expect(
            find.byWidgetPredicate(_isHorizontalScroll),
            findsNothing,
            reason: '$reason scrolled horizontally',
          );
          expect(
            tester.getCenter(find.text('Ovid Si')).dx,
            closeTo(width / 2, 1),
            reason: '$reason is not centred',
          );
        }
      }
    }
  });

  test('splash copy stays inside the one-line text budget', () {
    expect(_words(const V2SplashData().statusLabel), lessThanOrEqualTo(6));
    expect(_words(_slowMessage), lessThanOrEqualTo(6));
    expect(_words('Ready'), lessThanOrEqualTo(6));
    expect(_words('Try again'), lessThanOrEqualTo(3));
  });
}
