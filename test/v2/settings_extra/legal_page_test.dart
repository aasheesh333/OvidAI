import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  VoidCallback? onCopy,
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
    onCopy: onCopy,
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

  FlutterError.onError = previous;
  return errors;
}

void main() {
  testWidgets('renders title, updated date and sections in light', (
    tester,
  ) async {
    await _pump(tester, _data());

    // The title is shown in the app bar and again as the document heading.
    expect(find.text('Privacy policy'), findsWidgets);
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

  testWidgets('copy action invokes the injected callback', (tester) async {
    var copies = 0;
    await _pump(tester, _data(onCopy: () => copies++));

    await tester.tap(find.byTooltip('Copy document'));
    await tester.pump();

    expect(copies, 1);
  });

  testWidgets('copy action copies the document when unwired', (tester) async {
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

    await _pump(tester, _data());

    await tester.tap(find.byTooltip('Copy document'));
    await tester.pumpAndSettle();

    final setData = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    final text = (setData.arguments as Map)['text'] as String;
    expect(text, contains('Privacy policy'));
    expect(text, contains('Last updated 12 March 2026'));
    expect(text, contains('What we collect'));
    expect(text, contains('Session messages and attached files'));
    expect(find.text('Document copied.'), findsOneWidget);
  });

  testWidgets('copy action stays disabled while the document is loading', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      _data(status: V2LegalPageStatus.loading, onCopy: () {}),
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    final node = tester.getSemantics(find.bySemanticsLabel('Copy document'));
    expect(node, isSemantics(hasEnabledState: true, isEnabled: false));
    handle.dispose();
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
    expect(find.textContaining('not available right now'), findsOneWidget);

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
            onCopy: () {},
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
        expect(find.text('Flutter and the Dart SDK'), findsOneWidget);
        expect(find.textContaining("You're offline"), findsOneWidget);
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
    expect(find.text('Billing'), findsOneWidget);
  });
}
