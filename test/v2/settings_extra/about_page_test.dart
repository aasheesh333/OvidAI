import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_info.dart';
import 'package:ovid_ai/core/legal_links.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/about_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/legal_page.dart';

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
  testWidgets('renders the build and legal links in light', (tester) async {
    await _pump(tester, _versioned);

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('2.4.1 · build 418'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);

    // No hero, tagline, footer or duplicate account action.
    expect(find.text('Ovid Si'), findsNothing);
    expect(find.text('Chat. Code. Create.'), findsNothing);
    expect(find.text('Made for Android'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Contact support'), findsNothing);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _versioned, dark: true);

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
  });

  testWidgets('default data shows the real build info, not a demo string', (
    tester,
  ) async {
    await _pump(tester, const V2AboutPageData());

    // Version and build come from core/app_info.dart (dart-define or the
    // pubspec), so the shipped build is always shown.
    expect(
      find.text('$kAppVersion · build $kAppBuildNumber'),
      findsOneWidget,
    );
    expect(find.textContaining('v2.4.1'), findsNothing);
    // Unknown status with no checker is not a control at all.
    expect(find.text('System status'), findsNothing);
    expect(find.text('Operational'), findsNothing);
  });

  testWidgets('opens a legal row', (tester) async {
    var privacyTaps = 0;
    await _pump(tester, V2AboutPageData(onPrivacyPolicy: () => privacyTaps++));

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(privacyTaps, 1);
  });

  testWidgets('legal rows open a real destination without a callback', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final opened = <Uri>[];
    await _pump(
      tester,
      V2AboutPageData(
        openExternal: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );

    final node = tester.getSemantics(find.text('Privacy policy'));
    // Enabled rows are buttons with a tap action, not disabled placeholders.
    expect(node, isSemantics(isButton: true));
    handle.dispose();

    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(opened.single.toString(), LegalLinks.privacyPolicy);

    await tester.tap(find.text('Terms of service'));
    await tester.pumpAndSettle();
    expect(opened.last.toString(), LegalLinks.terms);

    // Licences are real data from the packages in this build.
    await tester.ensureVisible(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open-source licences'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('copy copies the real build label to the clipboard', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

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

    final setData = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    expect(
      (setData.arguments as Map)['text'],
      '2.4.1 · build 418',
    );
    expect(copies, 1);
  });

  testWidgets('shows a status row only when it is real', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      V2AboutPageData(
        systemStatus: V2SystemStatus.operational,
        onSystemStatus: () => opened++,
      ),
    );

    expect(find.text('System status'), findsOneWidget);
    expect(find.text('Operational'), findsOneWidget);

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('a failed status check retries', (tester) async {
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

    expect(find.text('System status'), findsOneWidget);
    expect(find.text('Could not check'), findsOneWidget);

    await tester.tap(find.text('System status'));
    await tester.pumpAndSettle();

    expect(retries, 1);
    expect(opened, 0);
  });

  testWidgets('a status row with no handler is not shown', (tester) async {
    await _pump(tester, const V2AboutPageData());
    expect(find.text('System status'), findsNothing);

    await _pump(
      tester,
      const V2AboutPageData(systemStatus: V2SystemStatus.degraded),
    );
    expect(find.text('System status'), findsNothing);
  });

  testWidgets('the minimal About has no support row', (tester) async {
    var contacts = 0;
    await _pump(
      tester,
      V2AboutPageData(onContactSupport: () => contacts++),
    );

    // Support lives in Account → Team & support. About keeps the build and
    // the three legal documents only.
    expect(find.text('Contact support'), findsNothing);
    expect(contacts, 0);
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
            systemStatus: V2SystemStatus.operational,
            onCopyVersion: () {},
            onPrivacyPolicy: () {},
            onTerms: () {},
            onLicences: () {},
            onContactSupport: () {},
            onSystemStatus: () {},
            onRetrySystemStatus: () {},
          ),
          dark: dark,
        );

        expect(errors, isEmpty, reason: errors.join('\n'));
        expect(find.text('Version'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Open-source licences'), 200);
        expect(find.text('Open-source licences'), findsOneWidget);
      },
    );
  }

  for (final width in <double>[600, 900]) {
    testWidgets('content is centred and capped at $width dp', (tester) async {
      await _pump(tester, _versioned, size: Size(width, 1600));

      final card = tester.getRect(find.byType(OCard).first);
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(card.width, lessThanOrEqualTo(limit));
      expect(card.width, lessThan(width), reason: 'rows must not stretch');
      expect(
        card.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }

  testWidgets('reduced motion keeps every row', (tester) async {
    await _pump(
      tester,
      V2AboutPageData(
        version: '2.4.1',
        build: '418',
        systemStatus: V2SystemStatus.operational,
        onSystemStatus: () {},
      ),
      reduceMotion: true,
    );

    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
    expect(find.text('System status'), findsOneWidget);
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
    await tester.scrollUntilVisible(find.text('Accepting these Terms'), 200);
    expect(find.text('Accepting these Terms'), findsOneWidget);
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
}
