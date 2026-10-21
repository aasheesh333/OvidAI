import 'dart:ui' show Tristate;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('primary button is 48dp, labelled and tappable', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Center(
          child: OButton(
            label: 'Continue',
            expand: true,
            onPressed: () => taps++,
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(OButton)).height, greaterThanOrEqualTo(48));
    expect(find.text('Continue'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(taps, 1);
  });

  testWidgets('disabled button is disabled for semantics and input', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const Center(child: OButton(label: 'Send', onPressed: null))),
    );
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('loading button replaces the icon with a spinner', (tester) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: OButton(
            label: 'Saving',
            icon: Icons.save_rounded,
            loading: true,
            onPressed: () {},
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.save_rounded), findsNothing);
  });

  testWidgets('empty state always offers a next action', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _app(
        OEmptyState(
          icon: Icons.chat_bubble_outline_rounded,
          title: 'No chats yet',
          message: 'Start with a hello and Ovid takes it from there.',
          action: OButton(
            label: 'New chat',
            onPressed: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('No chats yet'), findsOneWidget);
    expect(find.text('Start with a hello and Ovid takes it from there.'), findsOneWidget);
    await tester.tap(find.text('New chat'));
    expect(tapped, isTrue);
  });

  testWidgets('list row exposes title and subtitle', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _app(
        OListRow(
          title: 'Plan & billing',
          subtitle: 'Free · 3 GB',
          icon: Icons.credit_card_rounded,
          onTap: () => tapped = true,
        ),
      ),
    );
    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('Free · 3 GB'), findsOneWidget);
    await tester.tap(find.text('Plan & billing'));
    expect(tapped, isTrue);
  });

  testWidgets('search field shows its hint and emits text', (tester) async {
    String? value;
    await tester.pumpWidget(
      _app(
        OSearchField(hint: 'Search chats', onChanged: (v) => value = v),
      ),
    );
    expect(find.text('Search chats'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'landing');
    expect(value, 'landing');
  });

  testWidgets('chips report selection', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        Center(
          child: OChip(label: 'Images', selected: true, onTap: () {}),
        ),
      ),
    );
    final semantics = tester.getSemantics(find.byType(OChip));
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('reduced motion renders content without a delay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: OFadeSlide(
              delay: Duration(seconds: 2),
              child: Text('instant'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('instant'), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsNothing);
  });

  testWidgets('stagger keeps every child and order', (tester) async {
    await tester.pumpWidget(
      _app(
        OStagger(
          children: const [Text('one'), Text('two'), Text('three')],
        ),
      ),
    );
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('three'), findsOneWidget);
    // Flush the stagger timers so the test ends with no pending work.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('sheet shows a title and its content', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: OButton(
              label: 'Open',
              onPressed: () => showOSheet<void>(
                context,
                title: 'Share this chat',
                builder: (_) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Read-only link'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Share this chat'), findsOneWidget);
    expect(find.text('Read-only link'), findsOneWidget);
  });

  testWidgets('skeleton is static when animations are disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: OSkeleton(width: 120, height: 12)),
        ),
      ),
    );
    expect(find.byType(OSkeleton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(OSkeleton),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
  });

  testWidgets('OPill grows with 200% text instead of clipping its label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: OPill(
                label: 'Paid plans',
                tone: OPillTone.accent,
                dot: true,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final pill = tester.getSize(find.byType(OPill));
    expect(pill.height, greaterThan(24));
  });

  testWidgets('OAppBar keeps title and subtitle inside 200% text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: OScaffold(
            appBar: OAppBar(title: 'Plan and billing', subtitle: 'Free plan'),
            body: SizedBox.shrink(),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Plan and billing'), findsOneWidget);
    expect(find.text('Free plan'), findsOneWidget);
  });

  testWidgets('OPill renders an icon, a dot and a semantic label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const Center(
          child: OPill(
            label: 'Most popular',
            tone: OPillTone.accent,
            icon: Icons.star_rounded,
            dot: true,
            semanticLabel: 'Most popular plan',
          ),
        ),
      ),
    );
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('Most popular plan'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('compact button still keeps a 48dp target', (tester) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: OButton(
            label: 'Copy',
            size: OButtonSize.compact,
            onPressed: () {},
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byType(OButton)).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('OPressable announces disabled, not tappable', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const Scaffold(
          body: OPressable(
            semanticLabel: 'Unavailable action',
            child: Text('Unavailable'),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(OPressable));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
