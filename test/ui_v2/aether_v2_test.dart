import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/widgets/aether_v2.dart';

/// Aether v2 premium primitives — render coverage in light + dark at 320px
/// and 360x640 with 2x text, plus the key interactions (dock collapse,
/// secret reveal, metric ring). Pulsing/shimmer animations repeat forever,
/// so every pump here is bounded — no pumpAndSettle on animated states.
void main() {
  setUp(() => Aether.dark = true);
  tearDown(() => Aether.dark = true);

  Widget host(Widget child, {double textScale = 1}) {
    return MaterialApp(
      theme: Aether.theme(),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: c!,
      ),
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.all(12), child: child),
          ),
        ),
      ),
    );
  }

  void setView(WidgetTester tester, Size logical, {double dpr = 1}) {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = Size(
      logical.width * dpr,
      logical.height * dpr,
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Matches only plain [Text] widgets — `find.text` also matches
  /// [EditableText], whose controller always holds the raw secret.
  Finder plainText(String s) =>
      find.byWidgetPredicate((w) => w is Text && w.data == s);

  Widget allPrimitives() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AetherDock(
          title: 'Queue',
          statusColor: Aether.accent,
          child: Text('3 queued messages waiting to send'),
        ),
        SizedBox(height: 12),
        AetherMetric(label: 'Context', value: '128k / 200k', percent: 0.64),
        SizedBox(height: 12),
        AetherSecretField(label: 'API key', saved: true, hint: 'sk-...'),
        SizedBox(height: 12),
        AetherSkeleton(height: 14),
        SizedBox(height: 12),
        Row(
          children: [
            AetherSpinner(),
            SizedBox(width: 12),
            Expanded(
              child: AetherStateRow(
                title: 'Everything is running smoothly',
                icon: Icons.favorite_border,
                color: Aether.success,
              ),
            ),
          ],
        ),
      ],
    );
  }

  group('AetherDock', () {
    for (final dark in [true, false]) {
      testWidgets('renders title, child, trailing, dot (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        Aether.dark = dark;
        setView(tester, const Size(320, 900));
        await tester.pumpWidget(
          host(
            const AetherDock(
              title: 'Goals',
              priority: 1,
              statusColor: Aether.success,
              trailing: Icon(Icons.add_task),
              child: Text('dock-body-marker'),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Goals'), findsOneWidget);
        expect(find.text('dock-body-marker'), findsOneWidget);
        expect(find.byIcon(Icons.add_task), findsOneWidget);
      });
    }

    testWidgets('collapses and expands via header tap (bounded pumps)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        setView(tester, const Size(360, 640));
        var changes = 0;
        bool? last;
        await tester.pumpWidget(
          host(
            AetherDock(
              title: 'Approvals',
              statusColor: Aether.warn,
              pulsing: true, // infinite pulse — bounded pumps only
              onExpansionChanged: (v) {
                changes++;
                last = v;
              },
              child: const Text('approval-body'),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('approval-body'), findsOneWidget);
        var node = tester.getSemantics(find.bySemanticsLabel('Approvals'));
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isExpanded, Tristate.isTrue);

        // Collapse: child leaves the tree (AnimatedSize still animating).
        await tester.tap(find.bySemanticsLabel('Approvals'));
        await tester.pump();
        expect(changes, 1);
        expect(last, isFalse);
        expect(find.text('approval-body'), findsNothing);
        await tester.pump(const Duration(milliseconds: 300));
        node = tester.getSemantics(find.bySemanticsLabel('Approvals'));
        expect(node.flagsCollection.isExpanded, Tristate.isFalse);

        // Expand again.
        await tester.tap(find.bySemanticsLabel('Approvals'));
        await tester.pump();
        expect(changes, 2);
        expect(last, isTrue);
        expect(find.text('approval-body'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('trailing action taps do not toggle the dock', (tester) async {
      setView(tester, const Size(360, 640));
      var trailingTaps = 0;
      await tester.pumpWidget(
        host(
          AetherDock(
            title: 'To-dos',
            trailing: IconButton(
              tooltip: 'Add to-do',
              onPressed: () => trailingTaps++,
              icon: const Icon(Icons.add),
            ),
            child: const Text('todo-body'),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Add to-do'));
      await tester.pump();
      expect(trailingTaps, 1);
      expect(find.text('todo-body'), findsOneWidget); // still expanded
    });

    testWidgets('honors initiallyExpanded: false', (tester) async {
      setView(tester, const Size(360, 640));
      await tester.pumpWidget(
        host(
          const AetherDock(
            title: 'History',
            initiallyExpanded: false,
            child: Text('history-body'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('History'), findsOneWidget);
      expect(find.text('history-body'), findsNothing);
    });
  });

  group('AetherMetric', () {
    for (final dark in [true, false]) {
      testWidgets('renders stats + ring (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        Aether.dark = dark;
        final semantics = tester.ensureSemantics();
        try {
          setView(tester, const Size(320, 900));
          await tester.pumpWidget(
            host(
              const AetherMetric(
                label: 'Context',
                value: '128k / 200k',
                percent: 0.64,
              ),
            ),
          );
          await tester.pump();
          expect(
            find.bySemanticsLabel('Context: 128k / 200k, 64%'),
            findsOneWidget,
          );
          final ring = find.descendant(
            of: find.byType(AetherMetric),
            matching: find.byType(CustomPaint),
          );
          expect(ring, findsOneWidget);
          final text = tester.widget<Text>(
            find.descendant(
              of: find.byType(AetherMetric),
              matching: find.byType(Text),
            ),
          );
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
        } finally {
          semantics.dispose();
        }
      });
    }

    testWidgets('clamps out-of-range percent in the ring + semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          host(
            const Column(
              children: [
                AetherMetric(label: 'High', value: 'v', percent: 1.5),
                AetherMetric(label: 'Low', value: 'v', percent: -0.5),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.bySemanticsLabel('High: v, 100%'), findsOneWidget);
        expect(find.bySemanticsLabel('Low: v, 0%'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('long label/value ellipsize at 320px without overflow', (
      tester,
    ) async {
      setView(tester, const Size(320, 900));
      await tester.pumpWidget(
        host(
          const AetherMetric(
            label: 'Context window usage for the current session',
            value: '128000 tokens used of 200000 available',
            percent: 0.9,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('AetherSecretField', () {
    testWidgets('reveal toggle shows text but semantics never echo the secret', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        setView(tester, const Size(360, 640));
        final controller = TextEditingController(text: 'sk-live-001');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          host(AetherSecretField(label: 'API key', controller: controller)),
        );
        await tester.pump();

        // Masked by default: no raw text rendered as plain text.
        expect(plainText('sk-live-001'), findsNothing);
        expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);

        // Reveal: raw text appears visually (overlay)...
        await tester.tap(find.byTooltip('Show API key'));
        await tester.pump();
        expect(plainText('sk-live-001'), findsOneWidget);
        // ...but the real field stays obscured and semantics never echo it.
        expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
        var node = tester.getSemantics(find.byType(TextField));
        expect(node.value.contains('sk-live-001'), isFalse);
        expect(find.bySemanticsLabel(RegExp('sk-live-001')), findsNothing);

        // Hide again.
        await tester.tap(find.byTooltip('Hide API key'));
        await tester.pump();
        expect(plainText('sk-live-001'), findsNothing);
        node = tester.getSemantics(find.byType(TextField));
        expect(node.value.contains('sk-live-001'), isFalse);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('typing updates the controller and fires onChanged', (
      tester,
    ) async {
      setView(tester, const Size(360, 640));
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      String? latest;
      await tester.pumpWidget(
        host(
          AetherSecretField(
            label: 'Token',
            controller: controller,
            onChanged: (v) => latest = v,
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'abc123');
      await tester.pump();
      expect(controller.text, 'abc123');
      expect(latest, 'abc123');
    });

    testWidgets('shows saved tick and inline error', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          host(
            const AetherSecretField(
              label: 'Token',
              saved: true,
              errorText: 'Invalid token',
            ),
          ),
        );
        await tester.pump();
        expect(find.bySemanticsLabel('Saved'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
        expect(find.text('Invalid token'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('AetherSkeleton + AetherSpinner', () {
    testWidgets('render with Loading semantics and advance on bounded pumps', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          host(
            const Column(
              children: [
                AetherSkeleton(height: 18),
                SizedBox(height: 8),
                AetherSpinner(),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(AetherSkeleton), findsOneWidget);
        expect(find.byType(AetherSpinner), findsOneWidget);
        expect(find.bySemanticsLabel('Loading'), findsNWidgets(2));
        expect(
          find.descendant(
            of: find.byType(AetherSpinner),
            matching: find.byType(CustomPaint),
          ),
          findsOneWidget,
        );
        // Advance shimmer + spin with bounded pumps (both repeat forever).
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('freeze to static blocks when animations are disabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: c!,
          ),
          home: const Scaffold(
            body: Column(children: [AetherSkeleton(), AetherSpinner()]),
          ),
        ),
      );
      await tester.pump();
      for (final type in [AetherSkeleton, AetherSpinner]) {
        expect(
          find.descendant(of: find.byType(type), matching: find.byType(AnimatedBuilder)),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('AetherStateRow', () {
    testWidgets('renders icon, title, action at >= 44px; dot variant pulses', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        setView(tester, const Size(320, 900));
        var actionTaps = 0;
        await tester.pumpWidget(
          host(
            Column(
              children: [
                AetherStateRow(
                  title: 'All systems operational',
                  icon: Icons.check_circle_outline,
                  color: Aether.success,
                  action: TextButton(
                    onPressed: () => actionTaps++,
                    child: const Text('Details'),
                  ),
                ),
                const AetherStateRow(title: 'Syncing memory', pulsing: true),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(find.text('All systems operational'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
        expect(find.text('Syncing memory'), findsOneWidget);
        final size = tester.getSize(
          find.bySemanticsLabel('All systems operational'),
        );
        expect(size.height, greaterThanOrEqualTo(44));

        await tester.tap(find.text('Details'));
        await tester.pump();
        expect(actionTaps, 1);
        // Bounded advance of the pulsing dot.
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  });

  group('responsive, light + dark', () {
    for (final dark in [true, false]) {
      testWidgets('all v2 primitives fit 320px (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        Aether.dark = dark;
        setView(tester, const Size(320, 900));
        await tester.pumpWidget(host(allPrimitives()));
        await tester.pump();
        expect(find.text('Queue'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      });

      testWidgets('all v2 primitives fit 360x640 @ 2x text (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        Aether.dark = dark;
        setView(tester, const Size(360, 640));
        await tester.pumpWidget(host(allPrimitives(), textScale: 2));
        await tester.pump();
        expect(find.text('Queue'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
