import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/states/state_tiles.dart';
import 'package:ovid_ai/ui/v2/states/system_states_page.dart';

const _allTitles = <String>[
  "You're offline",
  'Account blocked',
  'Allowance used',
  'Rate limited',
  'Update required',
];

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

FilledButton _primaryButton(WidgetTester tester, String label) {
  final finder = find.ancestor(
    of: find.text(label),
    matching: find.byType(FilledButton),
  );
  return tester.widget<FilledButton>(finder.first);
}

void _expectNoOverflow(WidgetTester tester) {
  for (final flex in tester.allRenderObjects.whereType<RenderFlex>()) {
    if (flex.direction != Axis.horizontal) continue;
    var right = 0.0;
    RenderBox? child = flex.firstChild;
    while (child != null) {
      final data = child.parentData! as FlexParentData;
      final edge = data.offset.dx + child.size.width;
      if (edge > right) right = edge;
      child = flex.childAfter(child);
    }
    expect(
      right,
      lessThanOrEqualTo(flex.size.width + 0.5),
      reason: 'a row paints past its box',
    );
  }
}

V2SystemStatesData _allConditions(DateTime now) => V2SystemStatesData(
  offline: true,
  blocked: true,
  allowanceUsed: true,
  allowanceResetsAt: now.add(const Duration(hours: 2)),
  rateLimitedUntil: now.add(const Duration(seconds: 10)),
  updateRequired: true,
);

void main() {
  testWidgets('the default screen is recovered, never an empty page', (
    tester,
  ) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(find.text('System states'), findsOneWidget);
    expect(find.text('What is blocking chat'), findsOneWidget);
    expect(find.text('All clear'), findsOneWidget);
    expect(find.text('Ovid is ready when you are.'), findsOneWidget);
    expect(find.byType(V2StateTile), findsNothing);
  });

  testWidgets('one live condition renders exactly one tile and its exit', (
    tester,
  ) async {
    await _tall(tester);
    var retries = 0;
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: const V2SystemStatesData(offline: true),
          onRetryConnection: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2StateTile), findsOneWidget);
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Messages wait until you reconnect.'), findsOneWidget);
    expect(find.text('All clear'), findsNothing);

    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('every condition reaches its real action', (tester) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    var now = start;
    var retries = 0;
    var plans = 0;
    var support = 0;
    var rateRetries = 0;
    var stores = 0;

    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: _allConditions(start),
          clock: () => now,
          onRetryConnection: () => retries++,
          onSeePlans: () => plans++,
          onContactSupport: () => support++,
          onRetryRateLimit: () => rateRetries++,
          onOpenStore: () => stores++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('See plans'));
    await tester.tap(find.text('Contact support'));
    await tester.tap(find.text('Open store'));

    // The rate-limit exit is closed until the countdown reaches zero.
    expect(_primaryButton(tester, 'Try again').onPressed, isNull);
    now = start.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(_primaryButton(tester, 'Try again').onPressed, isNotNull);
    await tester.tap(find.text('Try again'));

    expect(retries, 1);
    expect(plans, 1);
    expect(support, 1);
    expect(rateRetries, 1);
    expect(stores, 1);
  });

  testWidgets('multiple conditions render once each in precedence order', (
    tester,
  ) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    await tester.pumpWidget(
      _app(V2SystemStatesPage(data: _allConditions(start), clock: () => start)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2StateTile), findsNWidgets(_allTitles.length));
    for (final title in _allTitles) {
      expect(find.text(title), findsOneWidget);
    }

    final positions = <double>[
      for (final title in _allTitles) tester.getTopLeft(find.text(title)).dy,
    ];
    for (var i = 1; i < positions.length; i++) {
      expect(
        positions[i],
        greaterThan(positions[i - 1]),
        reason: 'tile order must follow V2SystemStatesData.precedence',
      );
    }
  });

  testWidgets('rate-limit countdown ticks from a timestamp and stops at zero', (
    tester,
  ) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    var now = start;
    var retries = 0;

    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: V2SystemStatesData(
            rateLimitedUntil: start.add(const Duration(seconds: 10)),
          ),
          clock: () => now,
          onRetryRateLimit: () => retries++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Ready in 10s'), findsOneWidget);
    expect(_primaryButton(tester, 'Try again').onPressed, isNull);

    now = now.add(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ready in 6s'), findsOneWidget);

    now = start.add(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ready now'), findsOneWidget);
    expect(_primaryButton(tester, 'Try again').onPressed, isNotNull);

    await tester.tap(find.text('Try again'));
    expect(retries, 1);

    // No negative countdown and no second firing after the window.
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Ready now'), findsOneWidget);
    expect(retries, 1);
  });

  testWidgets('allowance countdown comes from the reset instant', (
    tester,
  ) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    var now = start;

    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: V2SystemStatesData(
            allowanceUsed: true,
            allowanceResetsAt: start.add(const Duration(hours: 2)),
          ),
          clock: () => now,
          onSeePlans: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Resets in 2h 0m'), findsOneWidget);
    expect(_primaryButton(tester, 'See plans').onPressed, isNotNull);

    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Resets in 1h 59m'), findsOneWidget);
  });

  testWidgets('expired deadlines clear into the recovered state', (
    tester,
  ) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: V2SystemStatesData(
            allowanceUsed: true,
            allowanceResetsAt: start.subtract(const Duration(seconds: 1)),
            rateLimitedUntil: start.subtract(const Duration(seconds: 1)),
          ),
          clock: () => start,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(V2StateTile), findsNothing);
    expect(find.text('All clear'), findsOneWidget);
  });

  testWidgets('the recovered state offers the way back', (tester) async {
    await _tall(tester);
    var back = 0;
    await tester.pumpWidget(
      _app(V2SystemStatesPage(onBackToChat: () => back++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back to chat'));
    expect(back, 1);
  });

  testWidgets('title and body read as one node, then the action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          data: const V2SystemStatesData(offline: true, updateRequired: true),
          onRetryConnection: () {},
          onOpenStore: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        "You're offline. Messages wait until you reconnect.",
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Update required. Install the latest version to keep chatting.',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Open store'), findsOneWidget);

    // Visual order is spoken order: offline copy, Retry, update copy, store.
    final offline = tester.getTopLeft(find.text("You're offline")).dy;
    final retry = tester.getTopLeft(find.text('Retry')).dy;
    final update = tester.getTopLeft(find.text('Update required')).dy;
    final store = tester.getTopLeft(find.text('Open store')).dy;
    expect(offline, lessThan(retry));
    expect(retry, lessThan(update));
    expect(update, lessThan(store));
    handle.dispose();
  });

  testWidgets('320 to 1280, 100% and 200% text, light and dark fit', (
    tester,
  ) async {
    final start = DateTime(2026, 10, 22, 12);
    for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          _setSize(tester, Size(width, 900));

          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          addTearDown(() => FlutterError.onError = previous);

          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: TextScaler.linear(scale),
                ),
                child: V2SystemStatesPage(
                  data: _allConditions(start),
                  clock: () => start,
                  onRetryConnection: () {},
                  onSeePlans: () {},
                  onContactSupport: () {},
                  onRetryRateLimit: () {},
                  onOpenStore: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));

          if (width <= 412) {
            await tester.scrollUntilVisible(
              find.text('Open store'),
              240,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pump();
          }

          for (final error in errors) {
            debugPrint(error.toString());
          }
          expect(
            errors,
            isEmpty,
            reason: '$width dp / ${scale}x / ${dark ? 'dark' : 'light'}',
          );
          _expectNoOverflow(tester);

          if (width >= OBreakpoints.tablet) {
            final cap = OBreakpoints.contentMaxWidth(width);
            final tile = tester.getSize(find.byType(V2StateTile).first);
            expect(
              tile.width,
              lessThanOrEqualTo(cap + 0.5),
              reason: '$width dp must centre a capped column',
            );
          }
        }
      }
    }
  });
}
