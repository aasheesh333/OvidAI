import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/legal_page.dart';

const _sections = <V2LegalSection>[
  V2LegalSection(
    heading: 'What we collect',
    body:
        'We collect only what is needed to run your sessions: the messages '
        'you send, the files you attach and your account details.',
    bullets: <String>[
      'Session messages and attached files',
      'Account and billing details',
    ],
  ),
  V2LegalSection(
    heading: 'How we use it',
    body:
        'Your data is used to run Ovid Si, keep your workspace in sync and '
        'answer support requests. We never sell it.',
  ),
  V2LegalSection(
    heading: 'Your choices',
    body: 'You can export or delete your data from Settings at any time.',
  ),
];

V2LegalPageData _data({
  String title = 'Privacy policy',
  V2LegalPageStatus status = V2LegalPageStatus.ready,
  List<V2LegalSection> sections = _sections,
  String updatedAt = '12 March 2026',
  String summary = 'How Ovid Si collects, uses and protects your data.',
  String errorMessage = 'We could not load this document.',
  bool offline = false,
  String offlineNote =
      "You're offline. This is the saved copy of the document.",
  VoidCallback? onBack,
  VoidCallback? onRetry,
}) {
  return V2LegalPageData(
    title: title,
    icon: Icons.shield_outlined,
    updatedAt: updatedAt,
    summary: summary,
    sections: sections,
    status: status,
    offline: offline,
    offlineNote: offlineNote,
    errorMessage: errorMessage,
    onBack: onBack,
    onRetry: onRetry,
  );
}

Future<void> _pump(
  WidgetTester tester,
  V2LegalPageData data, {
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
        child: LegalPage(data: data),
      ),
    ),
  );
  await tester.pump();
  // Long enough for the staggered entrance; a single pump keeps the loading
  // skeletons from needing pumpAndSettle (they shimmer forever).
  await tester.pump(const Duration(milliseconds: 900));
}

/// Pumps at 320 dp and 200 % text and returns every framework error raised
/// while laying the page out.
Future<List<FlutterErrorDetails>> _pumpCatching(
  WidgetTester tester,
  V2LegalPageData data, {
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
        child: LegalPage(data: data),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  // The asset read is asynchronous; a cached read can land a frame later.
  for (
    var i = 0;
    i < 20 && find.byType(OSkeletonList).evaluate().isNotEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  FlutterError.onError = previous;
  return errors;
}

Future<void> _pumpDocument(
  WidgetTester tester,
  V2LegalDocument document, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
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
        ),
        child: LegalPage.document(document: document),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _pumpLicences(
  WidgetTester tester, {
  Stream<LicenseEntry> Function()? loadLicences,
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
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
        ),
        child: LicencesPage(loadLicences: loadLicences),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<List<FlutterErrorDetails>> _pumpLicencesCatching(
  WidgetTester tester, {
  required Stream<LicenseEntry> Function() loadLicences,
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
        child: LicencesPage(loadLicences: loadLicences),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));

  FlutterError.onError = previous;
  return errors;
}

void main() {
  testWidgets('renders title, updated date and sections in light', (
    tester,
  ) async {
    await _pump(tester, _data());

    // One heading per screen: the title lives in the app bar only.
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Last updated 12 March 2026'), findsOneWidget);
    expect(
      find.text('How Ovid Si collects, uses and protects your data.'),
      findsOneWidget,
    );
    expect(find.text('What we collect'), findsOneWidget);
    expect(find.text('How we use it'), findsOneWidget);
    expect(find.text('Your choices'), findsOneWidget);
    expect(find.text('Session messages and attached files'), findsOneWidget);
    expect(find.textContaining('We never sell it.'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(), dark: true);

    expect(find.text('Privacy policy'), findsWidgets);
    expect(find.text('What we collect'), findsOneWidget);
    expect(find.text('Your choices'), findsOneWidget);
  });

  testWidgets('the document has no copy chrome in the header', (tester) async {
    await _pump(tester, _data());

    expect(find.byTooltip('Copy document'), findsNothing);
    expect(find.bySemanticsLabel('Copy document'), findsNothing);
    expect(find.bySemanticsLabel('Back'), findsOneWidget);
  });

  testWidgets('hides the updated row when no date is known', (tester) async {
    await _pump(tester, _data(updatedAt: '', summary: ''));

    expect(find.textContaining('Last updated'), findsNothing);
    expect(find.text('What we collect'), findsOneWidget);
  });

  testWidgets('back invokes the injected callback', (tester) async {
    var backs = 0;
    await _pump(tester, _data(onBack: () => backs++));

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pump();

    expect(backs, 1);
  });

  testWidgets('back pops the route when no callback is wired', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LegalPage(data: _data()),
                ),
              ),
              child: const Text('Open document'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open document'));
    await tester.pumpAndSettle();

    expect(find.text('What we collect'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Open document'), findsOneWidget);
    expect(find.text('What we collect'), findsNothing);
  });

  testWidgets('shows the offline note with the saved copy', (tester) async {
    await _pump(tester, _data(offline: true));

    expect(
      find.text("You're offline. This is the saved copy of the document."),
      findsOneWidget,
    );
  });

  testWidgets('accepts the caller offline copy', (tester) async {
    await _pump(
      tester,
      _data(offline: true, offlineNote: 'Offline. Showing the last download.'),
    );

    expect(find.text('Offline. Showing the last download.'), findsOneWidget);
    expect(
      find.text("You're offline. This is the saved copy of the document."),
      findsNothing,
    );
  });

  testWidgets('hides the offline note when online', (tester) async {
    await _pump(tester, _data());

    expect(find.textContaining("You're offline"), findsNothing);
  });

  testWidgets('shows skeletons while loading', (tester) async {
    await _pump(tester, _data(status: V2LegalPageStatus.loading));

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('What we collect'), findsNothing);
  });

  testWidgets('error names the problem and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(
        status: V2LegalPageStatus.error,
        errorMessage: 'The document could not be downloaded.',
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Document unavailable'), findsOneWidget);
    expect(find.text('The document could not be downloaded.'), findsOneWidget);
    expect(find.text('What we collect'), findsNothing);

    await tester.tap(find.widgetWithText(OButton, 'Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('empty offers a retry as the next action', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(
        status: V2LegalPageStatus.empty,
        sections: const <V2LegalSection>[],
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Document unavailable'), findsOneWidget);
    expect(
      find.textContaining('Check your connection and try again'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OButton, 'Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('empty without a retry offers a way back', (tester) async {
    var backs = 0;
    await _pump(
      tester,
      _data(
        status: V2LegalPageStatus.empty,
        sections: const <V2LegalSection>[],
        onBack: () => backs++,
      ),
    );

    await tester.tap(find.widgetWithText(OButton, 'Go back'));
    await tester.pump();

    expect(backs, 1);
  });

  testWidgets('marks document and section headings for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data());

    expect(
      tester.getSemantics(find.text('Privacy policy').last),
      isSemantics(isHeader: true),
    );
    expect(
      tester.getSemantics(find.text('What we collect')),
      isSemantics(isHeader: true),
    );
    handle.dispose();
  });

  testWidgets('reduced motion keeps every section', (tester) async {
    await _pump(tester, _data(offline: true), reduceMotion: true);

    expect(find.text('Privacy policy'), findsWidgets);
    expect(find.text('What we collect'), findsOneWidget);
    expect(find.text('How we use it'), findsOneWidget);
    expect(find.text('Your choices'), findsOneWidget);
    expect(
      find.text("You're offline. This is the saved copy of the document."),
      findsOneWidget,
    );
  });

  for (final dark in [false, true]) {
    testWidgets(
      'no overflow at 320 dp and 200 % text (${dark ? 'dark' : 'light'})',
      (tester) async {
        final errors = await _pumpCatching(
          tester,
          _data(
            title: 'Open-source licences',
            updatedAt: '12 March 2026',
            summary:
                'Every package that ships with Ovid Si, its version and the '
                'licence it is distributed under.',
            offline: true,
            onBack: () {},
            sections: const <V2LegalSection>[
              V2LegalSection(
                heading: 'Flutter and the Dart SDK',
                body:
                    'Ovid Si is built with Flutter. Flutter and the Dart SDK '
                    'are distributed under the BSD 3-Clause licence.',
                bullets: <String>[
                  'Flutter 3.47.4 — BSD 3-Clause',
                  'Dart 3.9.2 — BSD 3-Clause',
                  'http 1.5.0 — BSD 3-Clause',
                ],
              ),
              V2LegalSection(
                heading: 'Other packages',
                body:
                    'The remaining packages are listed with their versions in '
                    'the notices file that ships with the app.',
              ),
              V2LegalSection(
                heading: 'Written offer',
                body:
                    'If a licence requires source code, write to support and '
                    'we will send it.',
              ),
            ],
          ),
          dark: dark,
        );

        expect(errors, isEmpty, reason: errors.join('\n'));
        expect(find.text('Open-source licences'), findsWidgets);
        expect(find.textContaining("You're offline"), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Flutter and the Dart SDK'),
          200,
        );
        expect(find.text('Flutter and the Dart SDK'), findsOneWidget);
      },
    );
  }

  testWidgets('no overflow with a long heading and body at 200 % text', (
    tester,
  ) async {
    final errors = await _pumpCatching(
      tester,
      _data(
        title: 'Terms of service with a deliberately long document title',
        updatedAt: '12 March 2026',
        summary:
            'These terms explain the agreement between you and Ovid Si when '
            'you use the app, the cloud workspace and every connected tool.',
        sections: const <V2LegalSection>[
          V2LegalSection(
            heading:
                'Subagents, sessions and projects that you create and share',
            body:
                'Each session is isolated. You decide whether to share it. '
                'Subagents never dispatch other subagents, and every log '
                'stays inside your workspace.',
            bullets: <String>[
              'A session can run for up to eight hours before it stops.',
              'Sharing is opt-in and can be revoked at any time.',
            ],
          ),
          V2LegalSection(
            heading: 'Billing',
            body:
                'Paid plans renew automatically until you cancel them in the '
                'store that processed the purchase.',
          ),
        ],
      ),
      dark: false,
    );

    expect(errors, isEmpty, reason: errors.join('\n'));
    await tester.scrollUntilVisible(find.text('Billing'), 200);
    expect(find.text('Billing'), findsOneWidget);
  });

  for (final width in <double>[600, 900, 1280]) {
    testWidgets('content is centred and capped at $width dp', (tester) async {
      await _pump(tester, _data(), size: Size(width, 1600));

      final body = tester.getRect(find.byType(ListView));
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(body.width, lessThanOrEqualTo(limit));
      expect(body.width, lessThan(width), reason: 'text must not stretch');
      expect(
        body.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }

  testWidgets('loads the published privacy policy from the bundled asset', (
    tester,
  ) async {
    await _pumpDocument(
      tester,
      V2LegalDocument.asset(
        assetPath: 'docs/legal/PRIVACY.md',
        title: 'Privacy policy',
        icon: Icons.shield_outlined,
      ),
    );

    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Last updated 21 October 2026'), findsOneWidget);
    expect(find.text('The short version'), findsOneWidget);
    expect(find.textContaining('Dhanuk Softwares'), findsWidgets);
    expect(find.textContaining('24-hour grace period'), findsWidgets);
  });

  testWidgets('loads the published terms from the bundled asset', (
    tester,
  ) async {
    await _pumpDocument(
      tester,
      V2LegalDocument.asset(
        assetPath: 'docs/legal/TERMS.md',
        title: 'Terms of service',
      ),
    );

    expect(find.text('Terms of service'), findsOneWidget);
    expect(find.text('Last updated 21 October 2026'), findsOneWidget);
    expect(find.text('The short version'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Accepting these Terms'),
      250,
    );
    expect(find.textContaining('Accepting these Terms'), findsOneWidget);
  });

  testWidgets('a missing document names the reason and retries', (
    tester,
  ) async {
    var attempts = 0;
    final document = V2LegalDocument(
      title: 'Privacy policy',
      kind: V2LegalDocumentKind.asset,
      load: () async {
        attempts++;
        if (attempts == 1) {
          throw const V2LegalLoadException('The bundled policy is missing.');
        }
        return '# Privacy policy\n\n**Last updated:** 1 January 2026\n\n'
            '## Summary\n\nRecovered copy.';
      },
    );

    await _pumpDocument(tester, document);

    expect(find.text('Document unavailable'), findsOneWidget);
    expect(find.text('The bundled policy is missing.'), findsOneWidget);
    expect(find.text('The short version'), findsNothing);

    await tester.tap(find.widgetWithText(OButton, 'Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Recovered copy.'), findsOneWidget);
  });

  testWidgets('an empty real document is an error, never a blank page', (
    tester,
  ) async {
    await _pumpDocument(
      tester,
      V2LegalDocument(title: 'Privacy policy', load: () async => '   \n\n'),
    );

    expect(find.text('Document unavailable'), findsOneWidget);
    expect(find.text('The document is empty.'), findsOneWidget);
  });

  testWidgets(
    'a fetched document renders, and an HTTP failure names the code',
    (tester) async {
      await _pumpDocument(
        tester,
        V2LegalDocument.url(
          url: Uri.parse('https://example.com/privacy'),
          title: 'Privacy policy',
          client: MockClient(
            (request) async => http.Response(
              '# Privacy policy\n\n## Summary\n\nFetched copy.',
              200,
            ),
          ),
        ),
      );

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Fetched copy.'), findsOneWidget);

      await _pumpDocument(
        tester,
        V2LegalDocument.url(
          url: Uri.parse('https://example.com/privacy'),
          title: 'Privacy policy',
          client: MockClient(
            (request) async => http.Response('unavailable', 503),
          ),
        ),
      );

      expect(find.text('Document unavailable'), findsOneWidget);
      expect(
        find.text('The document could not be downloaded. Try again.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a missing bundled asset names the reason and offers retry', (
    tester,
  ) async {
    await _pumpDocument(
      tester,
      V2LegalDocument.asset(
        assetPath: 'docs/legal/NOT_FOUND.md',
        title: 'Privacy policy',
      ),
    );

    expect(find.text('Document unavailable'), findsOneWidget);
    expect(
      find.text('The document is missing from this build.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OButton, 'Try again'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'the real privacy document has no overflow at 320 dp and 200 % text '
      '(${dark ? 'dark' : 'light'})',
      (tester) async {
        // Read the source directly: rootBundle caches its Future across tests,
        // and a cached Future from another test's fake-async zone never
        // completes here. The asset-loading path is covered above.
        final source = File('docs/legal/PRIVACY.md').readAsStringSync();
        final data = parseLegalMarkdown(
          source,
          fallbackTitle: 'Privacy policy',
        );
        final table = data.sections.firstWhere(
          (section) => section.heading == '2.1 At a glance',
        );
        final longSection = data.sections.firstWhere(
          (section) =>
              section.heading == '12. Deleting your account and your data',
        );

        // Each section is a Column, so every line in it is laid out even when
        // it starts below the fold. That catches overflow in the widest table
        // and in the longest bullet list without a 170k-pixel scroll.
        final tableErrors = await _pumpCatching(
          tester,
          V2LegalPageData(
            title: 'Privacy policy',
            sections: <V2LegalSection>[table],
          ),
          dark: dark,
        );
        expect(tableErrors, isEmpty, reason: tableErrors.join('\n'));
        expect(find.text('2.1 At a glance'), findsOneWidget);

        final longErrors = await _pumpCatching(
          tester,
          V2LegalPageData(
            title: 'Privacy policy',
            sections: <V2LegalSection>[longSection],
          ),
          dark: dark,
        );
        expect(longErrors, isEmpty, reason: longErrors.join('\n'));
        expect(
          find.text('12. Deleting your account and your data'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('licences page renders the real registry stream', (tester) async {
    await _pumpLicences(
      tester,
      loadLicences: () =>
          Stream<LicenseEntry>.fromIterable(const <LicenseEntry>[
            LicenseEntryWithLineBreaks(<String>[
              'alpha_pkg',
            ], 'Alpha licence text.'),
            LicenseEntryWithLineBreaks(<String>[
              'beta_pkg',
            ], 'Beta licence text.'),
          ]),
    );

    expect(find.text('Open-source licences'), findsOneWidget);
    expect(find.text('alpha_pkg'), findsOneWidget);
    expect(find.text('beta_pkg'), findsOneWidget);
    expect(find.text('Alpha licence text.'), findsOneWidget);
  });

  testWidgets('a registry failure names the reason and retries', (
    tester,
  ) async {
    var calls = 0;
    await _pumpLicences(
      tester,
      loadLicences: () {
        calls++;
        if (calls == 1) {
          return Stream<LicenseEntry>.error(StateError('registry down'));
        }
        return Stream<LicenseEntry>.fromIterable(const <LicenseEntry>[
          LicenseEntryWithLineBreaks(<String>[
            'alpha_pkg',
          ], 'Alpha licence text.'),
        ]);
      },
    );

    expect(find.text('Licences unavailable'), findsOneWidget);
    expect(
      find.text('The licence registry could not be read.'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OButton, 'Try again'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('alpha_pkg'), findsOneWidget);
  });

  testWidgets('an empty registry is an error, not an empty page', (
    tester,
  ) async {
    await _pumpLicences(
      tester,
      loadLicences: () => const Stream<LicenseEntry>.empty(),
    );

    expect(find.text('Licences unavailable'), findsOneWidget);
    expect(
      find.text('No licence notices were found in this build.'),
      findsOneWidget,
    );
  });

  for (final dark in [false, true]) {
    testWidgets('licences page has no overflow at 320 dp and 200 % text '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      final errors = await _pumpLicencesCatching(
        tester,
        dark: dark,
        loadLicences: () =>
            Stream<LicenseEntry>.fromIterable(const <LicenseEntry>[
              LicenseEntryWithLineBreaks(
                <String>[
                  'flutter_plugin_android_lifecycle_with_a_very_long_name',
                ],
                'Copyright 2026 The Ovid Si Authors. Permission is hereby '
                'granted, free of charge, to any person obtaining a copy '
                'of this software and associated documentation files.',
              ),
            ]),
      );

      expect(errors, isEmpty, reason: errors.join('\n'));
      expect(
        find.textContaining('flutter_plugin_android_lifecycle'),
        findsOneWidget,
      );
    });
  }

  for (final width in <double>[600, 900, 1280]) {
    testWidgets('licences content is capped at $width dp', (tester) async {
      await _pumpLicences(
        tester,
        size: Size(width, 1600),
        loadLicences: () =>
            Stream<LicenseEntry>.fromIterable(const <LicenseEntry>[
              LicenseEntryWithLineBreaks(<String>[
                'alpha_pkg',
              ], 'Alpha licence text.'),
            ]),
      );

      final body = tester.getRect(find.byType(ListView));
      final limit = width >= 900 ? 720.0 : 640.0;

      expect(body.width, lessThanOrEqualTo(limit));
      expect(body.width, lessThan(width), reason: 'text must not stretch');
      expect(
        body.center.dx,
        moreOrLessEquals(width / 2, epsilon: 1),
        reason: 'content must be centred, not left aligned',
      );
    });
  }
}
