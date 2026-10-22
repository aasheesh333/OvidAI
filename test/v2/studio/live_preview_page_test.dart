import 'dart:convert';
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

/// A real 1x1 transparent PNG: a frame that actually decodes.
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

ImageProvider _frame() => MemoryImage(_pngBytes);

/// Pump a few frames without waiting for the countdown timer to finish.
///
/// `pumpAndSettle` never settles while a preview deadline is ticking: the
/// periodic timer schedules a rebuild every second until the session expires.
Future<void> _pumpPreview(WidgetTester tester) async {
  await tester.pump();
  // Image decoding is real async work, not fake-clock work. Give it a turn
  // without letting the countdown timer run the session to expiry.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

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

V2LivePreviewData _preview({
  V2PreviewStatus status = V2PreviewStatus.live,
  bool withFrame = true,
  String url = 'https://acme-cloud.ovid.app',
  String siteName = 'acme/app',
  DateTime? expiresAt,
  String? errorMessage,
  String unavailableReason = '',
  double aspectRatio = 16 / 10,
}) => V2LivePreviewData(
  status: status,
  siteName: siteName,
  url: url,
  frame: withFrame ? _frame() : null,
  expiresAt: expiresAt,
  errorMessage: errorMessage,
  unavailableReason: unavailableReason,
  frameAspectRatio: aspectRatio,
);

void main() {
  test('countdown formatting is compact on screen and spoken in full', () {
    expect(
      formatPreviewCountdown(const Duration(hours: 2, minutes: 3)),
      '2h 03m',
    );
    expect(
      formatPreviewCountdown(const Duration(minutes: 5, seconds: 9)),
      '5m 09s',
    );
    expect(formatPreviewCountdown(const Duration(seconds: 9)), '9s');
    expect(formatPreviewCountdown(const Duration(milliseconds: 700)), '1s');
    expect(formatPreviewCountdown(Duration.zero), 'Expired');

    expect(
      formatPreviewCountdownSpoken(const Duration(minutes: 1, seconds: 5)),
      '1 minute 5 seconds',
    );
    expect(
      formatPreviewCountdownSpoken(const Duration(hours: 1, minutes: 2)),
      '1 hour 2 minutes',
    );
    expect(formatPreviewCountdownSpoken(Duration.zero), 'no time left');
  });

  testWidgets('renders a real frame with origin, time and wired actions', (
    tester,
  ) async {
    var reloads = 0;
    var copies = 0;
    var opens = 0;
    var stops = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            expiresAt: DateTime.now().add(
              const Duration(minutes: 5, seconds: 9, milliseconds: 500),
            ),
          ),
          onReload: () => reloads++,
          onCopyUrl: () => copies++,
          onOpenInBrowser: () => opens++,
          onStop: () => stops++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('Live preview'), findsOneWidget);
    expect(find.byKey(const Key('preview-frame')), findsOneWidget);
    expect(find.byKey(const Key('preview-status')), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('acme-cloud.ovid.app'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+m \d+s$')), findsOneWidget);

    // The frame is the page: no synthetic site copy and no fake chrome.
    expect(find.text('99.99%'), findsNothing);
    expect(find.text('Ship AI models in seconds, not weeks.'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);

    await tester.tap(find.byTooltip('Reload'));
    await tester.ensureVisible(find.text('Copy URL'));
    await tester.tap(find.text('Copy URL'));
    await tester.ensureVisible(find.text('Open in browser'));
    await tester.tap(find.text('Open in browser'));
    await tester.ensureVisible(find.text('Stop preview'));
    await tester.tap(find.text('Stop preview'));
    await tester.pump();

    expect(reloads, 1);
    expect(copies, 1);
    expect(opens, 1);
    expect(stops, 1);
  });

  testWidgets('absent handlers leave no dead controls', (tester) async {
    await tester.pumpWidget(_app(V2LivePreviewPage(data: _preview())));
    await _pumpPreview(tester);

    expect(find.byKey(const Key('preview-frame')), findsOneWidget);
    expect(find.byTooltip('Reload'), findsNothing);
    expect(find.text('Copy URL'), findsNothing);
    expect(find.text('Open in browser'), findsNothing);
    expect(find.text('Stop preview'), findsNothing);
  });

  testWidgets('connecting shows a skeleton and can be cancelled', (
    tester,
  ) async {
    var cancels = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.connecting,
            withFrame: false,
            expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          ),
          onCancel: () => cancels++,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('preview-connecting-frame')), findsOneWidget);
    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.text('Connecting'), findsOneWidget);
    expect(find.byKey(const Key('preview-status')), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    expect(find.text('No preview'), findsNothing);

    await tester.tap(find.text('Cancel'));
    expect(cancels, 1);

    // The skeleton loops; unmount so the animation/timer is disposed.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lost keeps the last frame dimmed and reconnects', (
    tester,
  ) async {
    var reconnects = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.lost,
            errorMessage: 'The sandbox stopped streaming.',
            expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
          onReconnect: () => reconnects++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.byKey(const Key('preview-frame')), findsOneWidget);
    expect(find.text('The sandbox stopped streaming.'), findsOneWidget);
    expect(find.text('Lost'), findsOneWidget);
    expect(find.text('Live'), findsNothing);

    // The reason and the action sit below the frame, so a short frame can
    // never hide them behind the dimmed image or the status pill.
    final frame = tester.getRect(find.byKey(const Key('preview-frame')));
    final reason = tester.getRect(find.text('The sandbox stopped streaming.'));
    expect(reason.top, greaterThan(frame.bottom));

    await tester.tap(find.text('Reconnect'));
    expect(reconnects, 1);
  });

  testWidgets('lost without a last frame still explains itself', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(status: V2PreviewStatus.lost, withFrame: false),
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.byKey(const Key('preview-frame')), findsOneWidget);
    expect(find.text('The preview stream stopped.'), findsOneWidget);
    expect(find.text('Lost'), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
  });

  testWidgets('lost keeps its reconnect action on screen at 200 % text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var reconnects = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.lost,
            errorMessage: 'The sandbox stopped streaming.',
            expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
          onReconnect: () => reconnects++,
          onCopyUrl: () {},
          onOpenInBrowser: () {},
          onStop: () {},
        ),
        textScale: 2,
      ),
    );
    await _pumpPreview(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Reconnect').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    expect(reconnects, 1);
  });

  testWidgets('lost falls back to reload for reconnect', (tester) async {
    var reloads = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(status: V2PreviewStatus.lost),
          onReload: () => reloads++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.byTooltip('Reload'), findsNothing);
    await tester.tap(find.text('Reconnect'));
    expect(reloads, 1);
  });

  testWidgets('error states the reason and retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.error,
            withFrame: false,
            errorMessage: 'The preview server did not answer.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('The preview server did not answer.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('expired says the session ended and starts a new one', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.expired,
            withFrame: false,
            errorMessage: 'The sandbox was shut down.',
          ),
          onStart: () => starts++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('Preview ended'), findsOneWidget);
    expect(find.text('The sandbox was shut down.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Reconnect'), findsNothing);

    await tester.tap(find.text('Start preview'));
    expect(starts, 1);
  });

  testWidgets('no source means an honest unavailable state, not a fake page', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2LivePreviewPage(data: V2LivePreviewData(siteName: 'acme/app')),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('No preview'), findsOneWidget);
    expect(find.text('No preview source for acme/app.'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    expect(find.text('Connecting'), findsNothing);
    expect(find.byKey(const Key('preview-frame')), findsNothing);
    expect(find.byKey(const Key('preview-status')), findsNothing);
    expect(find.text('Start preview'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a live status without a frame is unavailable, not live', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(status: V2PreviewStatus.live, withFrame: false),
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('No preview'), findsOneWidget);
    expect(find.text('No preview source for acme/app.'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    expect(find.byKey(const Key('preview-status')), findsNothing);
  });

  testWidgets('unavailable uses the supplied reason and start action', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.unavailable,
            withFrame: false,
            unavailableReason: 'The preview proxy is not configured.',
          ),
          onStart: () => starts++,
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('The preview proxy is not configured.'), findsOneWidget);
    await tester.tap(find.text('Start preview'));
    expect(starts, 1);
  });

  testWidgets('the countdown ticks from the deadline and ends the session', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            expiresAt: DateTime.now().add(
              const Duration(minutes: 1, seconds: 5, milliseconds: 500),
            ),
          ),
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.text('Expires in 1m 05s'), findsNothing);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('1m 05s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('1m 03s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 70));
    expect(find.text('Preview ended'), findsOneWidget);
    expect(find.byKey(const Key('preview-status')), findsNothing);
    expect(find.text('Live'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a broken frame is an error, never a blank live surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: V2LivePreviewData(
            status: V2PreviewStatus.live,
            siteName: 'acme/app',
            url: 'acme-cloud.ovid.app',
            frame: MemoryImage(Uint8List.fromList(<int>[1, 2, 3, 4])),
          ),
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(find.byKey(const Key('preview-frame-error')), findsOneWidget);
    expect(find.text('Frame failed'), findsOneWidget);
    expect(find.text('The preview frame could not be shown.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byKey(const Key('preview-status')), findsNothing);
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('default data carries no sample content', (tester) async {
    const data = V2LivePreviewData();
    expect(data.status, V2PreviewStatus.unavailable);
    expect(data.siteName, isEmpty);
    expect(data.url, isEmpty);
    expect(data.frame, isNull);
    expect(data.expiresAt, isNull);
    expect(data.origin, isEmpty);

    await tester.pumpWidget(_app(const V2LivePreviewPage(data: data)));
    await _pumpPreview(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('No preview'), findsOneWidget);
    expect(find.text('Live preview'), findsOneWidget);
    expect(find.text('Acme Cloud'), findsNothing);
  });

  testWidgets('landscape, portrait and wide stay in frame at 1x and 2x', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    const sizes = <Size>[
      Size(320, 640),
      Size(360, 640),
      Size(412, 915),
      Size(600, 900),
      Size(640, 360),
      Size(800, 600),
      Size(1024, 768),
      Size(1280, 800),
    ];
    final expiresAt = DateTime.now().add(const Duration(hours: 1, minutes: 2));
    for (final size in sizes) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final textScale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          final reason = '$size ${textScale}x ${dark ? 'dark' : 'light'}';
          await tester.pumpWidget(
            _app(
              V2LivePreviewPage(
                data: _preview(expiresAt: expiresAt),
                onReload: () {},
                onCopyUrl: () {},
                onOpenInBrowser: () {},
                onStop: () {},
              ),
              dark: dark,
              textScale: textScale,
            ),
          );
          await _pumpPreview(tester);

          expect(tester.takeException(), isNull, reason: reason);
          expect(find.text('Live preview'), findsOneWidget);
          expect(find.byKey(const Key('preview-frame')), findsOneWidget);
          expect(_offScreenText(tester), isEmpty, reason: reason);

          final rect = tester.getRect(find.byKey(const Key('preview-frame')));
          expect(rect.left, greaterThanOrEqualTo(-0.5), reason: reason);
          expect(rect.top, greaterThanOrEqualTo(-0.5), reason: reason);
          expect(
            rect.right,
            lessThanOrEqualTo(size.width + 0.5),
            reason: reason,
          );
          expect(
            rect.bottom,
            lessThanOrEqualTo(size.height + 0.5),
            reason: reason,
          );
          expect(
            rect.width / rect.height,
            closeTo(16 / 10, 0.02),
            reason: 'frame must keep its real aspect at $size',
          );
        }
      }
    }
  });

  testWidgets('every state fits portrait, landscape and wide at 1x and 2x', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    const sizes = <Size>[Size(320, 640), Size(640, 360), Size(1280, 800)];
    const states = <V2PreviewStatus>[
      V2PreviewStatus.connecting,
      V2PreviewStatus.lost,
      V2PreviewStatus.error,
      V2PreviewStatus.expired,
      V2PreviewStatus.unavailable,
    ];
    final expiresAt = DateTime.now().add(const Duration(hours: 1, minutes: 2));
    for (final status in states) {
      for (final size in sizes) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        for (final textScale in <double>[1, 2]) {
          for (final dark in <bool>[false, true]) {
            final reason =
                '$status $size ${textScale}x ${dark ? 'dark' : 'light'}';
            await tester.pumpWidget(
              _app(
                V2LivePreviewPage(
                  data: _preview(
                    status: status,
                    withFrame: status == V2PreviewStatus.lost,
                    expiresAt: expiresAt,
                    errorMessage: status == V2PreviewStatus.error
                        ? 'The preview server did not answer.'
                        : null,
                  ),
                  onCancel: () {},
                  onReconnect: () {},
                  onRetry: () {},
                  onStart: () {},
                  onStop: () {},
                ),
                dark: dark,
                textScale: textScale,
              ),
            );
            await _pumpPreview(tester);

            expect(tester.takeException(), isNull, reason: reason);
            expect(_offScreenText(tester), isEmpty, reason: reason);
            final actionLabel = switch (status) {
              V2PreviewStatus.connecting => 'Cancel',
              V2PreviewStatus.lost => 'Reconnect',
              V2PreviewStatus.error => 'Try again',
              V2PreviewStatus.expired ||
              V2PreviewStatus.unavailable => 'Start preview',
              V2PreviewStatus.live => 'Copy URL',
            };
            expect(
              find.text(actionLabel).hitTestable(),
              findsOneWidget,
              reason: '$reason: "$actionLabel" must stay on screen',
            );
            if (status == V2PreviewStatus.lost) {
              final frame = tester.getSize(
                find.byKey(const Key('preview-frame')),
              );
              expect(
                frame.width / frame.height,
                closeTo(16 / 10, 0.02),
                reason: reason,
              );
            }
          }
        }
      }
    }
  });

  testWidgets('a supplied viewport ratio is kept', (tester) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(aspectRatio: 4 / 3))),
    );
    await _pumpPreview(tester);

    final frame = tester.getSize(find.byKey(const Key('preview-frame')));
    expect(frame.width / frame.height, closeTo(4 / 3, 0.02));
  });

  testWidgets('frame and status are announced, with labelled actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
          onReload: () {},
          onCopyUrl: () {},
          onOpenInBrowser: () {},
          onStop: () {},
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(
      find.bySemanticsLabel('Live preview of https://acme-cloud.ovid.app'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Live, acme-cloud\.ovid\.app, \d+ minute'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Copy URL'), findsOneWidget);
    expect(find.bySemanticsLabel('Open in browser'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop preview'), findsOneWidget);
    expect(find.bySemanticsLabel('Reload preview'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('the pill announces the full status even when it ellipsizes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.connecting,
            withFrame: false,
            url: 'https://acme-cloud.ovid.app/a/very/long/path',
            expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
          onCancel: () {},
        ),
        textScale: 2,
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.bySemanticsLabel(RegExp(r'^Connecting, acme-cloud\.ovid\.app')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Cancel'), findsOneWidget);

    // The skeleton loops; unmount so the animation/timer is disposed.
    await tester.pumpWidget(const SizedBox());
    handle.dispose();
  });

  testWidgets('lost announces the frame, the pill and the reconnect action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        V2LivePreviewPage(
          data: _preview(
            status: V2PreviewStatus.lost,
            errorMessage: 'The sandbox stopped streaming.',
            expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          ),
          onReconnect: () {},
        ),
      ),
    );
    await _pumpPreview(tester);

    expect(
      find.bySemanticsLabel(
        'Last preview frame of https://acme-cloud.ovid.app',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Lost, acme-cloud\.ovid\.app, \d+ minute'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Reconnect'), findsOneWidget);

    handle.dispose();
  });

  testWidgets('reload is the only header action and hides without a handler', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(V2LivePreviewPage(data: _preview(), onReload: () {})),
    );
    await _pumpPreview(tester);
    expect(find.byTooltip('Reload'), findsOneWidget);

    await tester.pumpWidget(_app(V2LivePreviewPage(data: _preview())));
    await _pumpPreview(tester);
    expect(find.byTooltip('Reload'), findsNothing);
  });
}
