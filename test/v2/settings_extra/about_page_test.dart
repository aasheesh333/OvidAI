import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_info.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/about_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/legal_page.dart';

const _versioned = V2AboutPageData(version: '2.4.1', build: '418');

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

/// Taps a row that pushes a page which first renders skeletons. The skeleton
/// pulse never settles, so pump the route and the asset read explicitly before
/// waiting for the content.
Future<void> _openAndSettle(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// Pumps at 320 dp and 200 % text and returns every framework error raised
/// while laying the page out.
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
  testWidgets('renders the app name, build and legal rows in light', (
    tester,
  ) async {
    await _pump(tester, _versioned);

    expect(find.text('About'), findsOneWidget);
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('2.4.1 (build 418)'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);

    // One identity line, not a second version row or a marketing block.
    expect(find.text('Version'), findsNothing);
    expect(find.text('Chat. Code. Create.'), findsNothing);
    expect(find.text('Made for Android'), findsNothing);
    expect(find.text('BUILD'), findsNothing);
    expect(find.text('LEGAL'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
    expect(find.text('Contact support'), findsNothing);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _versioned, dark: true);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
  });

  testWidgets('default data shows the real build info, not a demo string', (
    tester,
  ) async {
    await _pump(tester, const V2AboutPageData());

    // Version and build come from core/app_info.dart (dart-define or the
    // pubspec), so the shipped build is always shown.
    expect(find.text('$kAppVersion (build $kAppBuildNumber)'), findsOneWidget);
    expect(find.textContaining('v2.4.1'), findsNothing);
    // Unknown status with no checker is not a control at all.
    expect(find.text('System status'), findsNothing);
    expect(find.text('Operational'), findsNothing);
  });

  testWidgets(
    'external legal rows call the host and announce leaving the app',
    (tester) async {
      final handle = tester.ensureSemantics();
      var privacy = 0;
      var terms = 0;
      await _pump(
        tester,
        V2AboutPageData(
          onPrivacyPolicy: () => privacy++,
          onTerms: () => terms++,
        ),
      );

      final node = tester.getSemantics(find.text('Privacy policy'));
      expect(node, isSemantics(isButton: true));
      expect(node, isSemantics(hint: 'Opens in your browser'));
      handle.dispose();

      await tester.tap(find.text('Privacy policy'));
      await tester.pumpAndSettle();
      expect(privacy, 1);
      expect(find.byType(LegalPage), findsNothing);

      await tester.tap(find.text('Terms of service'));
      await tester.pumpAndSettle();
      expect(terms, 1);
      expect(find.byType(LegalPage), findsNothing);
    },
  );

  testWidgets('privacy row opens the real bundled document', (tester) async {
    await _pump(tester, const V2AboutPageData());

    await _openAndSettle(tester, find.text('Privacy policy'));

    expect(find.byType(LegalPage), findsOneWidget);
    expect(find.text('Last updated 21 October 2026'), findsOneWidget);
    expect(find.text('The short version'), findsOneWidget);
    expect(find.textContaining('Dhanuk Softwares'), findsWidgets);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();

    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
  });

  testWidgets('terms row opens the real bundled document', (tester) async {
    await _pump(tester, const V2AboutPageData());

    await _openAndSettle(tester, find.text('Terms of service'));

    expect(find.byType(LegalPage), findsOneWidget);
    expect(find.textContaining('Dhanuk Softwares'), findsWidgets);
    await tester.scrollUntilVisible(
      find.textContaining('Accepting these Terms'),
      200,
    );
    expect(find.textContaining('Accepting these Terms'), findsOneWidget);
  });

  testWidgets('licences row opens the real Flutter licence registry', (
    tester,
  ) async {
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(<String>[
        'ovid_test_package',
      ], 'Ovid test licence text.');
    });
    await _pump(tester, const V2AboutPageData());

    await _openAndSettle(tester, find.text('Open-source licences'));

    expect(find.byType(LicencesPage), findsOneWidget);
    expect(find.text('ovid_test_package'), findsOneWidget);
    expect(find.text('Ovid test licence text.'), findsOneWidget);
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
    expect((setData.arguments as Map)['text'], '2.4.1 (build 418)');
    expect(copies, 1);
  });

  testWidgets('shows no status row: About is the build plus legal', (
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

    expect(find.text('System status'), findsNothing);
    expect(find.text('Operational'), findsNothing);
    expect(opened, 0);
  });

  testWidgets('the minimal About has no support row', (tester) async {
    var contacts = 0;
    await _pump(tester, V2AboutPageData(onContactSupport: () => contacts++));

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
        expect(find.text('Ovid Si'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Open-source licences'), 200);
        expect(find.text('Open-source licences'), findsOneWidget);
      },
    );
  }

  for (final width in <double>[600, 900, 1280]) {
    testWidgets('content is centred and capped at $width dp', (tester) async {
      await _pump(tester, _versioned, size: Size(width, 1600));

      final row = tester.getRect(find.byType(OListRow).first);
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(row.width, lessThanOrEqualTo(limit));
      expect(row.width, lessThan(width), reason: 'rows must not stretch');
      expect(
        row.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }

  testWidgets('reduced motion keeps every row', (tester) async {
    await _pump(tester, _versioned, reduceMotion: true);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Open-source licences'), findsOneWidget);
  });
}
