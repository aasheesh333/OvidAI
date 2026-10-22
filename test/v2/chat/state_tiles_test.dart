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
  V2StateTileKind.planLimited: 'Plan limit reached',
  V2StateTileKind.storageFull: 'Storage full',
  V2StateTileKind.abuseBlocked: 'Account suspended',
  V2StateTileKind.deletionPending: 'Account deletion pending',
  V2StateTileKind.serverError: 'Something went wrong',
};

const _actions = <V2StateTileKind, String>{
  V2StateTileKind.offline: 'Retry',
  V2StateTileKind.planLimited: 'See plans',
  V2StateTileKind.storageFull: 'Manage storage',
  V2StateTileKind.abuseBlocked: 'Get help',
  V2StateTileKind.deletionPending: 'Restore',
  V2StateTileKind.serverError: 'Try again',
};

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

Widget _allTiles({
  void Function(V2StateTileKind kind)? onAction,
  bool named = false,
}) {
  final tiles = <Widget>[
    if (named) ...[
      // The named constructors are the ergonomic call site for each state.
      V2StateTile.offline(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.offline),
      ),
      V2StateTile.planLimited(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.planLimited),
      ),
      V2StateTile.storageFull(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.storageFull),
      ),
      V2StateTile.abuseBlocked(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.abuseBlocked),
      ),
      V2StateTile.deletionPending(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.deletionPending),
      ),
      V2StateTile.serverError(
        onAction: onAction == null
            ? null
            : () => onAction(V2StateTileKind.serverError),
      ),
    ] else
      for (final kind in V2StateTileKind.values)
        V2StateTile(
          kind: kind,
          onAction: onAction == null ? null : () => onAction(kind),
        ),
  ];
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < tiles.length; i++) ...[
        if (i > 0) const SizedBox(height: OSpace.m),
        tiles[i],
      ],
    ],
  );
}

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 2600));
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

void main() {
  test('every state has distinct defaults and a next action', () {
    final icons = <IconData>{};
    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(copy.title, isNotEmpty);
      expect(copy.message, isNotEmpty);
      expect(copy.actionLabel, isNotEmpty);
      expect(copy.icon, isNotNull);
      expect(icons.add(copy.icon), isTrue, reason: '$kind reuses an icon');
    }
  });

  test('default copy stays inside the minimal text budget', () {
    int words(String value) => value.trim().split(RegExp(r'\s+')).length;
    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(words(copy.title), lessThanOrEqualTo(4), reason: '$kind title');
      expect(words(copy.message), lessThanOrEqualTo(18), reason: '$kind body');
      expect(
        words(copy.actionLabel),
        lessThanOrEqualTo(3),
        reason: '$kind action',
      );
    }
  });

  testWidgets('renders all six states in light mode', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(_allTiles(named: true)));
    await tester.pumpAndSettle();

    for (final kind in V2StateTileKind.values) {
      final copy = V2StateTileCopy.of(kind);
      expect(find.text(_titles[kind]!), findsOneWidget);
      expect(find.text(_actions[kind]!), findsOneWidget);
      expect(find.text(copy.message), findsOneWidget);
      expect(find.byIcon(copy.icon), findsOneWidget);
    }
  });

  testWidgets('renders all six states in dark mode', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(_allTiles(named: true), dark: true));
    await tester.pumpAndSettle();

    for (final kind in V2StateTileKind.values) {
      expect(find.text(_titles[kind]!), findsOneWidget);
      expect(find.text(_actions[kind]!), findsOneWidget);
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
      await tester.tap(find.text(_actions[kind]!));
      await tester.pump();
    }

    expect(fired, V2StateTileKind.values.toSet());
  });

  testWidgets('a detail line carries measured data and keeps copy separate', (
    tester,
  ) async {
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        V2StateTile.planLimited(detail: 'Resets in 6h 12m', onAction: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Plan limit reached'), findsOneWidget);
    expect(find.text('Resets in 6h 12m'), findsOneWidget);
    expect(
      find.text('Your allowance is spent. Upgrade now or wait for the reset.'),
      findsOneWidget,
    );
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
            message: 'The run stopped when it reached the 8-hour limit.',
            actionLabel: 'View run',
            tone: V2StateTileTone.warn,
          ),
          detail: 'Stopped at 8h',
          onAction: () => fired++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Run stopped'), findsOneWidget);
    expect(find.text('Something went wrong'), findsNothing);
    expect(
      find.text('The run stopped when it reached the 8-hour limit.'),
      findsOneWidget,
    );
    expect(find.text('Stopped at 8h'), findsOneWidget);

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

    expect(find.text('Something went wrong'), findsOneWidget);
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

  testWidgets('missing callbacks disable and announce their actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.planLimited()));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    final disabled = tester.getSemantics(
      find.bySemanticsLabel('See plans').first,
    );
    expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.pumpWidget(_app(V2StateTile.planLimited(onAction: () {})));
    await tester.pumpAndSettle();

    final enabled = tester.getSemantics(
      find.bySemanticsLabel('See plans').first,
    );
    expect(enabled.flagsCollection.isEnabled, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('copy and message are exposed to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.offline(onAction: () {})));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(RegExp("You're offline")), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Messages will send when you reconnect')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Retry'),
      findsOneWidget,
      reason: 'the action is a separate button node',
    );
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
        expect(buttons, findsNWidgets(6));
        for (final element in buttons.evaluate()) {
          expect(
            tester.getSize(find.byWidget(element.widget)).height,
            greaterThanOrEqualTo(48),
          );
        }

        // The last state is reachable and usable after scrolling.
        await tester.scrollUntilVisible(
          find.text('Try again'),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Try again'));
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
                'working now, or wait for your allowance to reset at the start '
                'of the next month.',
            actionLabel: 'Compare all plans',
            secondaryActionLabel: 'View usage details',
          ),
          detail: 'Resets in 6h 12m · 50,000,000 tokens used',
          onAction: () {},
          onSecondaryAction: () {},
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

  testWidgets('a state change is announced as a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(V2StateTile.offline(onAction: () {})));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byType(V2StateTile));
    expect(node.flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
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
          detail: token,
          onAction: () {},
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
