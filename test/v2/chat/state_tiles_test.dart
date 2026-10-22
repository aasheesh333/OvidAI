import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/states/state_tiles.dart';

const _titles = <V2StateTileKind, String>{
  V2StateTileKind.offline: "You're offline",
  V2StateTileKind.planLimited: 'Allowance used',
  V2StateTileKind.storageFull: 'Storage full',
  V2StateTileKind.abuseBlocked: 'Account blocked',
  V2StateTileKind.deletionPending: 'Deletion pending',
  V2StateTileKind.serverError: 'Request failed',
  V2StateTileKind.rateLimited: 'Rate limited',
  V2StateTileKind.updateRequired: 'Update required',
};

const _actions = <V2StateTileKind, String>{
  V2StateTileKind.offline: 'Retry',
  V2StateTileKind.planLimited: 'See plans',
  V2StateTileKind.storageFull: 'Manage storage',
  V2StateTileKind.abuseBlocked: 'Contact support',
  V2StateTileKind.deletionPending: 'Restore',
  V2StateTileKind.serverError: 'Try again',
  V2StateTileKind.rateLimited: 'Try again',
  V2StateTileKind.updateRequired: 'Open store',
};

void _noop() {}

Widget _app(Widget child, {bool dark = false}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.screen),
        child: child,
      ),
    ),
  );
}

Widget _narrowApp(Widget child, {required bool dark}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 640),
        textScaler: TextScaler.linear(2),
        disableAnimations: true,
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.screen),
          child: child,
        ),
      ),
    ),
  );
}

Widget _allTiles({void Function(V2StateTileKind kind)? onAction}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final kind in V2StateTileKind.values) ...[
        if (kind != V2StateTileKind.values.first)
          const SizedBox(height: OSpace.m),
        V2StateTile(
          key: ValueKey(kind),
          kind: kind,
          onAction: onAction == null ? null : () => onAction(kind),
        ),
      ],
    ],
  );
}

Finder _actionIn(V2StateTileKind kind, String label) =>
    find.descendant(of: find.byKey(ValueKey(kind)), matching: find.text(label));

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 3000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void _setNarrowView(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Walks every horizontal flex, including rows that sit below the fold. An
/// offscreen overflow is never painted, so `takeException` alone misses it.
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

Color _toneColor(OColors c, V2StateTileTone tone) => switch (tone) {
  V2StateTileTone.neutral => c.textMuted,
  V2StateTileTone.warn => c.warn,
  V2StateTileTone.danger => c.danger,
};

FilledButton _primaryButton(WidgetTester tester, String label) {
  final finder = find.ancestor(
    of: find.text(label),
    matching: find.byType(FilledButton),
  );
  return tester.widget<FilledButton>(finder.first);
}

void main() {
  test('every state has distinct defaults and one exit', () {
    final icons = <IconData>{};
    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(copy.title, isNotEmpty);
      expect(copy.message, isNotEmpty);
      expect(copy.actionLabel, isNotEmpty);
      expect(icons.add(copy.icon), isTrue, reason: '$kind reuses an icon');
    }
  });

  test('default copy stays inside the minimal text budget', () {
    int words(String value) => value.trim().split(RegExp(r'\s+')).length;
    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(words(copy.title), lessThanOrEqualTo(4), reason: '$kind title');
      expect(words(copy.message), lessThanOrEqualTo(12), reason: '$kind body');
      expect(
        words(copy.actionLabel),
        lessThanOrEqualTo(3),
        reason: '$kind action',
      );
      final secondary = copy.secondaryActionLabel;
      if (secondary != null) {
        expect(words(secondary), lessThanOrEqualTo(3));
      }
    }
  });

  testWidgets('renders all eight states in light mode', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(_allTiles()));
    await tester.pumpAndSettle();

    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(_actionIn(kind, _titles[kind]!), findsOneWidget);
      expect(_actionIn(kind, _actions[kind]!), findsOneWidget);
      expect(_actionIn(kind, copy.message), findsOneWidget);
      expect(find.byIcon(copy.icon), findsOneWidget);
    }
  });

  testWidgets('renders all eight states in dark mode', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(_allTiles(), dark: true));
    await tester.pumpAndSettle();

    for (final kind in V2StateTileKind.values) {
      expect(_actionIn(kind, _titles[kind]!), findsOneWidget);
      expect(_actionIn(kind, _actions[kind]!), findsOneWidget);
    }
  });

  testWidgets('uses the tone colour for each state in both themes', (
    tester,
  ) async {
    await _tall(tester);
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(_allTiles(), dark: dark));
      await tester.pumpAndSettle();
      final c = dark ? OColors.dark : OColors.light;

      for (final kind in V2StateTileKind.values) {
        final copy = V2StateTileCopy.of(kind);
        final icon = tester.widget<Icon>(find.byIcon(copy.icon));
        expect(
          icon.color,
          _toneColor(c, copy.tone),
          reason: '$kind should use its ${copy.tone.name} tone',
        );
      }
    }
  });

  testWidgets('every action fires its own callback', (tester) async {
    await _tall(tester);
    final fired = <V2StateTileKind>{};
    await tester.pumpWidget(
      _app(_allTiles(onAction: (kind) => fired.add(kind))),
    );
    await tester.pumpAndSettle();

    for (final kind in V2StateTileKind.values) {
      final finder = _actionIn(kind, _actions[kind]!);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    expect(fired, V2StateTileKind.values.toSet());
  });

  testWidgets(
    'a rate-limit countdown ticks from the deadline and stops at zero',
    (tester) async {
      await _tall(tester);
      final start = DateTime(2026, 10, 22, 12);
      var now = start;
      var taps = 0;

      await tester.pumpWidget(
        _app(
          V2StateTile.rateLimited(
            deadline: start.add(const Duration(seconds: 10)),
            clock: () => now,
            onAction: () => taps++,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Ready in 10s'), findsOneWidget);
      expect(_primaryButton(tester, 'Try again').onPressed, isNull);

      now = now.add(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Ready in 6s'), findsOneWidget);
      expect(_primaryButton(tester, 'Try again').onPressed, isNull);

      now = start.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Ready now'), findsOneWidget);
      expect(_primaryButton(tester, 'Try again').onPressed, isNotNull);

      // The timer must not keep waking the device or move past zero.
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Ready now'), findsOneWidget);
      expect(taps, 0);

      await tester.tap(find.text('Try again'));
      expect(taps, 1);
    },
  );

  testWidgets('an allowance countdown is derived from the reset timestamp', (
    tester,
  ) async {
    await _tall(tester);
    final start = DateTime(2026, 10, 22, 12);
    var now = start;

    await tester.pumpWidget(
      _app(
        V2StateTile.planLimited(
          deadline: start.add(const Duration(hours: 2)),
          clock: () => now,
          onAction: _noop,
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

  testWidgets('a deadline in the past is already clear and never ticks', (
    tester,
  ) async {
    final start = DateTime(2026, 10, 22, 12);
    await tester.pumpWidget(
      _app(
        V2StateTile.rateLimited(
          deadline: start.subtract(const Duration(seconds: 1)),
          clock: () => start,
          onAction: _noop,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Ready now'), findsOneWidget);
    expect(_primaryButton(tester, 'Try again').onPressed, isNotNull);
  });

  testWidgets('copy overrides keep the state but change its words', (
    tester,
  ) async {
    await _tall(tester);
    var fired = 0;
    await tester.pumpWidget(
      _app(
        V2StateTile(
          kind: V2StateTileKind.serverError,
          copy: V2StateTileCopy.serverError.copyWith(
            title: 'Run stopped',
            message: 'The run stopped at the eight-hour limit.',
            actionLabel: 'View run',
            tone: V2StateTileTone.warn,
          ),
          onAction: () => fired++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Run stopped'), findsOneWidget);
    expect(find.text('Request failed'), findsNothing);
    expect(
      find.text('The run stopped at the eight-hour limit.'),
      findsOneWidget,
    );

    await tester.tap(find.text('View run'));
    expect(fired, 1);
  });

  testWidgets('an empty action label hides the action row', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        V2StateTile(
          kind: V2StateTileKind.serverError,
          copy: V2StateTileCopy.serverError.copyWith(actionLabel: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Request failed'), findsOneWidget);
    expect(find.byType(OButton), findsNothing);
  });

  testWidgets('a secondary action is optional and fires independently', (
    tester,
  ) async {
    await _tall(tester);
    var retries = 0;
    var details = 0;
    await tester.pumpWidget(
      _app(
        V2StateTile.serverError(
          copy: V2StateTileCopy.serverError.copyWith(
            secondaryActionLabel: 'View details',
          ),
          onAction: () => retries++,
          onSecondaryAction: () => details++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('View details'));
    expect(details, 1);
    expect(retries, 0);

    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('missing callbacks keep the exit visible but disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.offline()));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    final disabled = tester.getSemantics(find.bySemanticsLabel('Retry').first);
    expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.pumpWidget(_app(V2StateTile.offline(onAction: _noop)));
    await tester.pumpAndSettle();

    final enabled = tester.getSemantics(find.bySemanticsLabel('Retry').first);
    expect(enabled.flagsCollection.isEnabled, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('title and body are one screen-reader node, action separate', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.offline(onAction: _noop)));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        "You're offline. Queued messages send when you reconnect.",
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Retry'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Queued messages send when you reconnect\.$'),
      ),
      findsNothing,
      reason: 'the body must not become a second node',
    );
    handle.dispose();
  });

  testWidgets('a state change is announced as a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.offline(onAction: _noop)));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byType(V2StateTile));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets(
      '320 dp at 200% text lays out cleanly (${dark ? 'dark' : 'light'})',
      (tester) async {
        _setNarrowView(tester);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        var taps = 0;
        await tester.pumpWidget(
          _narrowApp(_allTiles(onAction: (_) => taps++), dark: dark),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        for (final error in errors) {
          debugPrint(error.toString());
        }
        expect(errors, isEmpty);
        _expectNoOverflow(tester);

        // Every action stays a 48 dp target at double text.
        final buttons = find.byWidgetPredicate(
          (widget) => widget is FilledButton || widget is OutlinedButton,
        );
        expect(buttons, findsNWidgets(V2StateTileKind.values.length));
        for (final element in buttons.evaluate()) {
          expect(
            tester.getSize(find.byWidget(element.widget)).height,
            greaterThanOrEqualTo(48),
          );
        }

        // The last state is reachable and usable after scrolling.
        final lastAction = _actionIn(
          V2StateTileKind.updateRequired,
          _actions[V2StateTileKind.updateRequired]!,
        );
        await tester.scrollUntilVisible(
          lastAction,
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(lastAction);
        expect(taps, 1);
      },
    );
  }

  testWidgets('long injected copy wraps at 320 dp and 200% text', (
    tester,
  ) async {
    _setNarrowView(tester);

    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      _narrowApp(
        V2StateTile(
          kind: V2StateTileKind.planLimited,
          copy: V2StateTileCopy.planLimited.copyWith(
            title: 'Your monthly plan allowance is completely used',
            message:
                'Your chats are safe. Upgrade to a larger plan to keep '
                'working now, or wait for your allowance to reset.',
            actionLabel: 'Compare all plans',
            secondaryActionLabel: 'View usage details',
          ),
          onAction: _noop,
          onSecondaryAction: _noop,
        ),
        dark: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    for (final error in errors) {
      debugPrint(error.toString());
    }
    expect(errors, isEmpty);
    _expectNoOverflow(tester);
  });

  testWidgets('unbroken tokens wrap at 320 dp and 200 % text', (tester) async {
    _setNarrowView(tester);
    final token = 'a' * 140;

    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(
      _narrowApp(
        V2StateTile(
          kind: V2StateTileKind.planLimited,
          copy: V2StateTileCopy.planLimited.copyWith(
            title: 'Plan limit for $token',
            message: 'See https://example.com/$token before you upgrade.',
            actionLabel: 'See plans',
          ),
          onAction: _noop,
        ),
        dark: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(errors, isEmpty);
    _expectNoOverflow(tester);
  });
}
