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

/// Copy for the site being previewed. Production copy comes from the wiring
/// layer; the screen itself ships no sample values.
V2LivePreviewData _preview({
  V2PreviewStatus status = V2PreviewStatus.content,
  String? errorMessage,
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
      expect(find.text('Live · Preview from your workspace'), findsOneWidget);
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

  testWidgets('share link reports the primary action', (tester) async {
    var shares = 0;
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(), onShareLink: () => shares++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Share link'));
    await tester.tap(find.text('Share link'));
    expect(shares, 1);
  });

  testWidgets('refresh and extend are wired to callbacks', (tester) async {
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

    await tester.tap(find.byTooltip('Refresh preview'));
    expect(refreshes, 1);

    await tester.ensureVisible(find.text('+30 min'));
    await tester.tap(find.text('+30 min'));
    expect(extensions, 1);
  });

  testWidgets('lays out at 320 dp with 200 % text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(V2LivePreviewPage(data: _preview()), dark: dark, textScale: 2),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Live preview'), findsOneWidget);
      expect(find.text('Live · Preview from your workspace'), findsOneWidget);
      expect(find.text('Share link'), findsOneWidget);
      expect(find.text('+30 min'), findsOneWidget);
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
