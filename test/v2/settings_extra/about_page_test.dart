import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/about_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/legal_page.dart';
import 'package:ovid_ai/ui/v2/states/state_tiles.dart';

const _versioned = V2AboutPageData(
  version: '2.4.1',
  build: '418',
  systemStatus: V2SystemStatus.operational,
);

Future<void> _pump(
  WidgetTester tester,
  V2AboutPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: AboutPage(data: data),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps at the given size and text scale and returns every framework error
/// (overflow, assertion, ...) raised while laying the page out.
Future<List<FlutterErrorDetails>> _pumpCatching(
  WidgetTester tester,
  V2AboutPageData data, {
  required bool dark,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = previous);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: AboutPage(data: data),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));

  FlutterError.onError = previous;
  return errors;
}

void main() {
  testWidgets('renders the app mark and rows in light', (tester) async {
    await _pump(tester, _versioned);

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Chat. Code. Create.'), findsOneWidget);
    expect(find.text('v2.4.1 (418)'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Operational'), findsOneWidget);
    expect(find.text('2.4.1 · build 418'), findsOneWidget);
    expect(find.text('Made for Android'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _versioned, dark: true);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('System status'), findsOneWidget);
    expect(find.text('Operational'), findsOneWidget);
  });

  testWidgets('default data shows no sample version or status', (tester) async {
    await _pump(tester, const V2AboutPageData());

    expect(find.textContaining('v2.4.1'), findsNothing);
    expect(find.text('Operational'), findsNothing);
    expect(find.text('Version and build'), findsNothing);
    // Static copy that belongs to the product is still there.
    expect(find.text('Chat. Code. Create.'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
  });

  testWidgets('opens a legal row', (tester) async {
    var privacyTaps = 0;
    await _pump(tester, V2AboutPageData(onPrivacyPolicy: () => privacyTaps++));

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(privacyTaps, 1);
  });

  testWidgets('delete account opens the deletion flow', (tester) async {
    var deletes = 0;
    await _pump(tester, V2AboutPageData(onDeleteAccount: () => deletes++));

    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.textContaining('This cannot be undone.'), findsOneWidget);

    final row = find.byKey(const ValueKey<String>('about-delete-account'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(deletes, 1);
  });

  testWidgets('delete account is announced as disabled when unwired', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const V2AboutPageData());

    final node = tester.getSemantics(find.text('Delete account'));
    expect(node, isSemantics(hasEnabledState: true, isEnabled: false));
    expect(node.label, contains('Delete account'));
    expect(node.label, contains('cannot be undone'));
    handle.dispose();
  });

  testWidgets('copies the version from the build row', (tester) async {
    var copies = 0;
    await _pump(
      tester,
      V2AboutPageData(
        version: '2.4.1',
        build: '418',
        onCopyVersion: () => copies++,
      ),
    );

    final copy = find.byTooltip('Copy version info');
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();

    expect(copies, 1);
  });

  testWidgets('announces a row with no callback as disabled', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const V2AboutPageData());

    final node = tester.getSemantics(find.text('Privacy policy'));
    expect(node, isSemantics(hasEnabledState: true, isEnabled: false));
    handle.dispose();
  });

  testWidgets('shows the status while it is being checked', (tester) async {
    await _pump(
      tester,
      const V2AboutPageData(systemStatus: V2SystemStatus.checking),
    );

    expect(find.text('Checking…'), findsOneWidget);
    expect(find.text('Checking the latest status.'), findsOneWidget);
  });

  testWidgets('a failed status check explains itself and retries', (
    tester,
  ) async {
    var retries = 0;
    var opened = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.error,
        onRetrySystemStatus: () => retries++,
        onSystemStatus: () => opened++,
      ),
    );

    expect(find.text('Could not check'), findsOneWidget);
    expect(
      find.text('We could not reach the status page. Tap to try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(retries, 1);
    expect(opened, 0);
  });

  testWidgets('a failed status check falls back to the status page', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.error,
        onSystemStatus: () => opened++,
      ),
    );

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('opens the status page when the status is healthy', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.operational,
        onSystemStatus: () => opened++,
      ),
    );

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'no overflow at 320 dp and 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        final errors = await _pumpCatching(
          tester,
          V2AboutPageData(
            version: '2.4.1',
            build: '418',
            tagline: 'Chat. Code. Create. Ask anything, build anything.',
            systemStatus: V2SystemStatus.operational,
            onCopyVersion: () {},
            onPrivacyPolicy: () {},
            onTerms: () {},
            onLicences: () {},
            onContactSupport: () {},
            onSystemStatus: () {},
            onRetrySystemStatus: () {},
            onDeleteAccount: () {},
          ),
          dark: dark,
        );

        expect(errors, isEmpty, reason: errors.join('\n'));
        expect(find.text('Privacy policy'), findsOneWidget);
        expect(find.text('Delete account'), findsOneWidget);
        // No room for the pill at this width and scale: the status folds into
        // the subtitle instead of squeezing the row title.
        expect(
          find.textContaining('Operational · Check if Ovid'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('no overflow at 320 dp and 200 % text with a degraded status', (
    tester,
  ) async {
    final errors = await _pumpCatching(
      tester,
      const V2AboutPageData(
        version: '2.4.1',
        build: '418',
        systemStatus: V2SystemStatus.degraded,
      ),
      dark: false,
    );

    expect(errors, isEmpty, reason: errors.join('\n'));
    expect(find.text('System status'), findsOneWidget);
    // The status pill must not squeeze the row title away at 200 % text.
    expect(tester.getSize(find.text('System status')).width, greaterThan(80));
  });

  testWidgets('reduced motion keeps every row', (tester) async {
    await _pump(tester, _versioned, reduceMotion: true);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
    expect(find.text('System status'), findsOneWidget);
    expect(find.text('Version and build'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Made for Android'), findsOneWidget);
  });

  test('the standard documents carry the published policy and terms', () {
    const docs = V2AboutLegalDocuments.standard;

    expect(docs.privacyPolicy.title, 'Privacy policy');
    expect(docs.privacyPolicy.updatedAt, '21 October 2026');
    expect(docs.terms.title, 'Terms of service');
    expect(docs.terms.updatedAt, '21 October 2026');
    expect(docs.licences.title, 'Open-source licences');
    expect(docs.privacyPolicy.sections, isNotEmpty);
    expect(docs.terms.sections, isNotEmpty);
    expect(docs.licences.sections, isNotEmpty);

    final privacyCopy = docs.privacyPolicy.sections
        .map((section) => '${section.body} ${section.bullets.join(' ')}')
        .join(' ');
    expect(privacyCopy, contains('24-hour grace period'));
    expect(privacyCopy, contains('Dhanuk Softwares'));
    expect(privacyCopy, contains('support@ovidsi.com'));

    final termsCopy = docs.terms.sections
        .map((section) => '${section.body} ${section.bullets.join(' ')}')
        .join(' ');
    expect(termsCopy, contains('Google Play'));
    expect(termsCopy, contains('24-hour grace period'));
    expect(termsCopy, contains('50 subagents'));
  });

  testWidgets('privacy row opens the in-app document', (tester) async {
    await _pump(
      tester,
      const V2AboutPageData(legalDocuments: V2AboutLegalDocuments.standard),
    );

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.byType(LegalPage), findsOneWidget);
    expect(find.text('Last updated 21 October 2026'), findsOneWidget);
    expect(find.text('The short version'), findsOneWidget);
    expect(find.textContaining('Dhanuk Softwares'), findsWidgets);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
  });

  testWidgets('terms row opens the in-app document', (tester) async {
    await _pump(
      tester,
      const V2AboutPageData(legalDocuments: V2AboutLegalDocuments.standard),
    );

    await tester.tap(find.text('Terms of service'));
    await tester.pumpAndSettle();

    expect(find.byType(LegalPage), findsOneWidget);
    expect(find.text('Accepting these Terms'), findsOneWidget);
    expect(find.text('Plans, payments and subscriptions'), findsOneWidget);
  });

  testWidgets('licences row opens the in-app document', (tester) async {
    await _pump(
      tester,
      const V2AboutPageData(legalDocuments: V2AboutLegalDocuments.standard),
    );

    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();

    expect(find.byType(LegalPage), findsOneWidget);
    expect(find.text('Flutter and the Dart SDK'), findsOneWidget);
    expect(find.text('Flutter — BSD 3-Clause'), findsOneWidget);
  });

  testWidgets('the in-app document takes precedence over a URL callback', (
    tester,
  ) async {
    var callbacks = 0;
    await _pump(
      tester,
      V2AboutPageData(
        legalDocuments: V2AboutLegalDocuments.standard,
        onPrivacyPolicy: () => callbacks++,
      ),
    );

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.byType(LegalPage), findsOneWidget);
    expect(callbacks, 0);
  });

  testWidgets('system status is a state tile that opens the status page', (
    tester,
  ) async {
    var opened = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.operational,
        onSystemStatus: () => opened++,
      ),
    );

    expect(find.byType(V2StateTile), findsOneWidget);
    expect(find.text('System status'), findsOneWidget);
    expect(find.text('Operational'), findsOneWidget);
    expect(find.text('Check if Ovid is working normally.'), findsOneWidget);

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('a failed status check renders as a warning state tile', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.error,
        onRetrySystemStatus: () => retries++,
      ),
    );

    expect(find.byType(V2StateTile), findsOneWidget);
    expect(find.text('Could not check'), findsOneWidget);
    expect(
      find.text('We could not reach the status page. Tap to try again.'),
      findsOneWidget,
    );

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });
}
