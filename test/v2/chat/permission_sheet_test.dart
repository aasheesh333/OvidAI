import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/permission_sheet.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

Widget _sheet({
  V2PermissionSheetData data = const V2PermissionSheetData(),
  ValueChanged<String>? onSelect,
  VoidCallback? onClose,
  VoidCallback? onRetry,
}) {
  return Scaffold(
    body: V2PermissionSheet(
      data: data,
      onSelect: onSelect ?? (_) {},
      onClose: onClose,
      onRetry: onRetry,
    ),
  );
}

Widget _scaled(Widget home, {required bool dark}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

const _modeLabels = ['Read-Only', 'General', 'Full Access', 'Studio'];

void main() {
  testWidgets('renders every mode with plain descriptions in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Choose what Ovid may do in this chat.'), findsOneWidget);
    for (final label in _modeLabels) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('No prompts'), findsOneWidget);
    expect(find.text('Ovid asks before pushing'), findsOneWidget);
    expect(
      find.textContaining('Full Access skips these prompts'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
    expect(find.byIcon(Icons.code_rounded), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await tester.pumpWidget(_app(_sheet(), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Permissions'), findsOneWidget);
    for (final label in _modeLabels) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Ovid asks before pushing'), findsOneWidget);
  });

  testWidgets('Full Access is the only danger row', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    final c = OColors.light;
    final rocket = tester.widget<Icon>(
      find.byIcon(Icons.rocket_launch_outlined),
    );
    expect(rocket.color, c.danger);

    final tag = tester.widget<Text>(find.text('No prompts'));
    expect(tag.style?.color, c.danger);

    // The safe modes keep the ordinary muted icon treatment.
    final readOnly = tester.widget<Icon>(
      find.byIcon(Icons.visibility_outlined),
    );
    expect(readOnly.color, c.textMuted);
  });

  testWidgets('a selected Full Access row uses the danger selection mark', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_sheet(data: const V2PermissionSheetData(selectedId: 'drive'))),
    );
    await tester.pumpAndSettle();

    final check = tester.widget<Icon>(find.byIcon(Icons.check_rounded));
    expect(check.color, OColors.light.onDanger);
  });

  testWidgets('current selection is announced', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(_sheet(data: const V2PermissionSheetData(selectedId: 'auto'))),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('General')).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      tester.getSemantics(find.text('Read-Only')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    expect(
      tester.getSemantics(find.text('Full Access')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('tapping a mode reports its id', (tester) async {
    final picks = <String>[];
    await tester.pumpWidget(_app(_sheet(onSelect: picks.add)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read-Only'));
    await tester.tap(find.text('General'));
    await tester.tap(find.text('Full Access'));
    await tester.ensureVisible(find.text('Studio'));
    await tester.tap(find.text('Studio'));

    expect(picks, ['safe', 'auto', 'drive', 'studio']);
  });

  testWidgets('danger row is announced as running without prompts', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.text('Full Access'));
    expect(node.label, contains('Full Access'));
    expect(node.label, contains('No confirmation prompts'));
    handle.dispose();
  });

  testWidgets('loading shows a skeleton and keeps the push note', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_sheet(data: const V2PermissionSheetData(loading: true))),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('General'), findsNothing);
    expect(find.text('Ovid asks before pushing'), findsOneWidget);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2PermissionSheetData(
            errorMessage: 'Could not load permissions.',
          ),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Permissions did not load'), findsOneWidget);
    expect(find.text('Could not load permissions.'), findsOneWidget);
    expect(find.text('General'), findsNothing);

    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('empty state has a next action', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      _app(
        _sheet(
          data: const V2PermissionSheetData(modes: []),
          onClose: () => closed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No permission modes'), findsOneWidget);
    expect(find.text('Close this sheet and try again.'), findsOneWidget);

    await tester.tap(find.text('Close'));
    expect(closed, 1);
  });

  testWidgets('controls meet the 48 dp touch target', (tester) async {
    await tester.pumpWidget(_app(_sheet()));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(OIconButton)).height,
      greaterThanOrEqualTo(48),
    );
    final rows = find.byType(OPressable);
    expect(rows, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      expect(tester.getSize(rows.at(i)).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('fits 320 dp at 200 % text in light and dark', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in [false, true]) {
      await tester.pumpWidget(_scaled(_sheet(), dark: dark));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Permissions'), findsOneWidget);
      for (final label in _modeLabels) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Ovid asks before pushing'), findsOneWidget);
    }
  });

  testWidgets('sheet helper closes after the pick', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showV2PermissionSheet(
                  context,
                  data: const V2PermissionSheetData(),
                  onSelect: (id) => picked = id,
                ),
                child: const Text('Open permissions'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open permissions'));
    await tester.pumpAndSettle();
    expect(find.text('Permissions'), findsOneWidget);

    await tester.ensureVisible(find.text('Studio'));
    await tester.tap(find.text('Studio'));
    await tester.pumpAndSettle();

    expect(picked, 'studio');
    expect(find.text('Permissions'), findsNothing);
  });
}
