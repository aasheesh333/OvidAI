import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/studio/live_preview_page.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, appChild) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: appChild!,
      ),
      home: child,
    );

/// Text that paints past the left or right edge of the screen.
List<String> _offScreenText(WidgetTester tester) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final off = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (rect.left < -0.5 || rect.right > width + 0.5) {
      off.add('"${(element.widget as Text).data}" $rect');
    }
  }
  return off;
}

/// Copy for the site being previewed. Production copy comes from the wiring
/// layer; the screen itself ships no sample values.
V2LivePreviewData _preview({
  V2PreviewStatus status = V2PreviewStatus.content,
  String? errorMessage,
  DateTime? expiresAt,
}) => V2LivePreviewData(
  status: status,
  siteName: 'Acme Cloud',
  url: 'acme-cloud.ovid.app',
  version: 'v1.4',
  eyebrow: 'Instant AI infrastructure',
  headline: 'Ship AI models in seconds, not weeks.',
  description:
      'Automated serverless clusters designed for real-time model serving.',
  primaryCta: 'Get started',
  secondaryCta: 'Documentation',
  metrics: const <V2PreviewMetric>[
    V2PreviewMetric(
      value: '99.99%',
      label: 'Uptime SLA',
      caption: 'Zero failover delay',
    ),
    V2PreviewMetric(
      value: '12ms',
      label: 'Latency',
      caption: 'Global edge nodes',
      icon: Icons.speed_rounded,
    ),
  ],
  featureTitle: 'Real-time routing engine',
  featureBody: 'Requests steer to the best available GPUs.',
  featureBadge: 'Auto-balancing live',
  expiresLabel: '55 min',
  expiresAt: expiresAt,
  errorMessage: errorMessage,
);

void main() {
  testWidgets('renders the phone preview in light and dark', (tester) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(V2LivePreviewPage(data: _preview()), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text('Live preview'), findsOneWidget);
      expect(find.text('Acme Cloud'), findsWidgets);
      expect(
        find.text('Ship AI models in seconds, not weeks.'),
        findsOneWidget,
      );
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('acme-cloud.ovid.app'), findsOneWidget);
      expect(find.text('Expires in 55 min'), findsOneWidget);
    }
  });

  testWidgets('loading state shows skeletons', (tester) async {
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(status: V2PreviewStatus.loading))),
    );
    // The shimmer never settles, so a single frame is enough.
    await tester.pump();

    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.text('Expires in 55 min'), findsNothing);
  });

  testWidgets('empty state starts a preview', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(status: V2PreviewStatus.empty),
          onStart: () => starts++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No preview running'), findsOneWidget);
    await tester.tap(find.text('Start preview'));
    expect(starts, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.error,
            errorMessage: 'The preview server did not answer.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The preview server did not answer.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('share is a compact secondary action', (tester) async {
    var shares = 0;
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(), onShareLink: () => shares++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Share'));
    await tester.tap(find.text('Share'));
    expect(shares, 1);
  });

  testWidgets('open calls its action', (tester) async {
    var opens = 0;
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(), onOpenInBrowser: () => opens++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Open'));
    await tester.tap(find.text('Open'));
    expect(opens, 1);
  });

  testWidgets('the viewer carries no explanatory paragraphs', (tester) async {
    await tester.pumpWidget(_app(V2LivePreviewPage(data: _preview())));
    await tester.pumpAndSettle();

    expect(find.text('Read-only preview'), findsNothing);
    expect(find.textContaining('Edits happen in Studio'), findsNothing);
    expect(
      find.textContaining('Changes from Studio show up here'),
      findsNothing,
    );
    expect(find.text('Live · Preview from your workspace'), findsNothing);
  });

  testWidgets('the expiry countdown ticks down and stops when expired', (
    tester,
  ) async {
    final expiresAt = DateTime.now().add(
      const Duration(minutes: 1, seconds: 5, milliseconds: 900),
    );
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(expiresAt: expiresAt))),
    );
    await tester.pump();

    expect(find.text('Expires in 1m 05s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Expires in 1m 03s'), findsOneWidget);

    // Running past the deadline stops the timer and says so plainly.
    await tester.pump(const Duration(seconds: 70));
    expect(find.text('Expired'), findsOneWidget);

    // Unmount so the periodic timer is cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refresh is wired and extend is not a primary action', (
    tester,
  ) async {
    var refreshes = 0;
    var extensions = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(),
          onRefresh: () => refreshes++,
          onExtend: () => extensions++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Refresh'));
    expect(refreshes, 1);

    expect(find.text('+30 min'), findsNothing);
    expect(extensions, 0);
  });

  testWidgets('lays out at 320 dp with 200 % text in light and dark', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(
          V2LivePreviewPage(
            data: _preview(),
            onShareLink: () {},
            onOpenInBrowser: () {},
            onStop: () {},
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Live preview'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(_offScreenText(tester), isEmpty);
    }
  });

  testWidgets('an empty preview never claims to be live', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: const V2LivePreviewData(siteName: 'Acme Cloud'),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('preview-waiting-frame')), findsOneWidget);
    expect(find.text('Online'), findsNothing);
    expect(find.text('Starting'), findsOneWidget);
    expect(find.text('Waiting for the first frame'), findsOneWidget);

    await tester.ensureVisible(find.text('Check again'));
    await tester.tap(find.text('Check again'));
    expect(retries, 1);
  });

  testWidgets('a broken frame shows an honest error, not a blank box', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: V2LivePreviewData(
            siteName: 'Acme Cloud',
            url: 'acme-cloud.ovid.app',
            frame: MemoryImage(Uint8List.fromList(<int>[1, 2, 3, 4])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('preview-frame-error')), findsOneWidget);
    expect(find.text('Frame did not load'), findsOneWidget);
  });

  testWidgets('empty state hides the start action when it is not wired', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2LivePreviewPage(
          data: V2LivePreviewData(status: V2PreviewStatus.empty),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No preview running'), findsOneWidget);
    expect(find.text('Start preview'), findsNothing);
  });

  testWidgets('waiting and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final scenarios = <String, V2LivePreviewData>{
      'waiting': const V2LivePreviewData(siteName: 'Acme Cloud'),
      'error': const V2LivePreviewData(
        status: V2PreviewStatus.error,
        errorMessage: 'The preview server did not answer.',
      ),
    };
    for (final dark in <bool>[false, true]) {
      for (final entry in scenarios.entries) {
        await tester.pumpWidget(
          _app(
            V2LivePreviewPage(data: entry.value, onRetry: () {}),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason:
              '${entry.key} overflowed at 320 dp / 200% text '
              '(${dark ? 'dark' : 'light'})',
        );
      }
    }
  });

  testWidgets('default data carries no sample copy', (tester) async {
    const data = V2LivePreviewData();
    expect(data.siteName, isEmpty);
    expect(data.url, isEmpty);
    expect(data.headline, isEmpty);
    expect(data.metrics, isEmpty);
    expect(data.expiresLabel, isEmpty);

    await tester.pumpWidget(_app(const V2LivePreviewPage(data: data)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Acme Cloud'), findsNothing);
    expect(find.text('Live preview'), findsOneWidget);
  });
}
