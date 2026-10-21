import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/agent_presets_page.dart';

const _general = V2AgentPreset(
  id: 'general',
  name: 'General',
  description: 'Balanced help for everyday tasks.',
  modelLabel: 'Ovid Auto',
  builtIn: true,
  icon: Icons.bolt_rounded,
);

const _coder = V2AgentPreset(
  id: 'coder',
  name: 'Coder',
  description: 'Writes and reviews code with care.',
  modelLabel: 'Ovid Pro',
  builtIn: true,
  icon: Icons.code_rounded,
);

const _reviewer = V2AgentPreset(
  id: 'reviewer',
  name: 'Code reviewer',
  description: 'Checks changes for bugs and gaps.',
  modelLabel: 'Ovid Pro',
  icon: Icons.rate_review_outlined,
);

V2AgentPresetsPageData _data({
  V2AgentPresetsStatus status = V2AgentPresetsStatus.ready,
  List<V2AgentPreset> presets = const [_general, _coder, _reviewer],
  String? selectedId = 'general',
  ValueChanged<String>? onSelect,
  VoidCallback? onCreate,
  ValueChanged<String>? onEdit,
  ValueChanged<String>? onDelete,
  VoidCallback? onRetry,
}) {
  return V2AgentPresetsPageData(
    status: status,
    presets: presets,
    selectedId: selectedId,
    onSelect: onSelect,
    onCreate: onCreate,
    onEdit: onEdit,
    onDelete: onDelete,
    onRetry: onRetry,
  );
}

Future<void> _pump(
  WidgetTester tester,
  V2AgentPresetsPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool reduceMotion = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: AgentPresetsPage(data: data),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('renders built-in and custom presets in light', (tester) async {
    await _pump(tester, _data());

    expect(find.text('Agent presets'), findsOneWidget);
    expect(
      find.text('Presets change how Ovid approaches a task.'),
      findsOneWidget,
    );
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Built-in'), findsNWidgets(2));
    expect(find.text('YOUR PRESETS'), findsOneWidget);
    expect(find.text('Code reviewer'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(), dark: true);

    expect(find.text('Coder'), findsOneWidget);
    expect(find.text('New preset'), findsOneWidget);
  });

  testWidgets('selects a preset', (tester) async {
    String? selected;
    await _pump(tester, _data(onSelect: (id) => selected = id));

    final card = find.text('Coder');
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(selected, 'coder');
  });

  testWidgets('opens the custom preset menu and edits', (tester) async {
    String? edited;
    await _pump(tester, _data(onEdit: (id) => edited = id));

    final menu = find.byTooltip('Preset options');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(edited, 'reviewer');
  });

  testWidgets('asks before deleting a custom preset', (tester) async {
    String? deleted;
    await _pump(tester, _data(onDelete: (id) => deleted = id));

    final menu = find.byTooltip('Preset options');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(deleted, isNull);
    expect(find.text('Delete Code reviewer?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, 'reviewer');
  });

  testWidgets('renders the empty state and creates a preset', (tester) async {
    var creates = 0;
    await _pump(
      tester,
      _data(
        status: V2AgentPresetsStatus.empty,
        presets: const [],
        selectedId: null,
        onCreate: () => creates++,
      ),
    );

    expect(find.text('No presets yet'), findsOneWidget);
    await tester.tap(find.text('New preset'));
    await tester.pumpAndSettle();

    expect(creates, 1);
  });

  testWidgets('shows the skeleton while loading', (tester) async {
    await _pump(
      tester,
      _data(status: V2AgentPresetsStatus.loading),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('General'), findsNothing);
  });

  testWidgets('shows the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(status: V2AgentPresetsStatus.error, onRetry: () => retries++),
    );

    expect(find.text('We could not load your presets.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('renders at 320 dp with 200% text without overflow', (
    tester,
  ) async {
    await _pump(tester, _data(), size: const Size(320, 1400), textScale: 2);

    expect(find.text('General'), findsOneWidget);
    expect(find.text('New preset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error fit 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      _data(
        status: V2AgentPresetsStatus.empty,
        presets: const [],
        selectedId: null,
        onCreate: () {},
      ),
      size: const Size(320, 800),
      textScale: 2,
    );

    expect(find.text('No presets yet'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _pump(
      tester,
      _data(status: V2AgentPresetsStatus.error, onRetry: () {}),
      size: const Size(320, 800),
      textScale: 2,
    );

    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion still shows every preset', (tester) async {
    await _pump(tester, _data(), reduceMotion: true);

    expect(find.text('General'), findsOneWidget);
    expect(find.text('Coder'), findsOneWidget);
    expect(find.text('Code reviewer'), findsOneWidget);
    expect(find.text('New preset'), findsOneWidget);
  });

  testWidgets('the preset menu is a 48 dp labelled control', (tester) async {
    await _pump(tester, _data(onEdit: (_) {}, onDelete: (_) {}));

    final menu = find.byTooltip('Preset options');
    expect(menu, findsOneWidget);

    final size = tester.getSize(menu);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('announces the selected preset', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data(onSelect: (_) {}));

    expect(
      find.bySemanticsLabel(RegExp(r'^General preset, selected\.')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('hides menu actions that have no callback', (tester) async {
    await _pump(tester, _data());

    // No onEdit / onDelete: a custom preset has no menu at all.
    expect(find.byTooltip('Preset options'), findsNothing);
  });

  testWidgets('selecting a preset shows the new selection at once', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data(onSelect: (_) {}));

    expect(
      find.bySemanticsLabel(RegExp(r'^General preset, selected\.')),
      findsOneWidget,
    );

    await tester.tap(find.text('Coder'));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(RegExp(r'^Coder preset, selected\.')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^General preset, selected\.')),
      findsNothing,
    );
    handle.dispose();
  });

  testWidgets('deleting a preset removes it at once', (tester) async {
    var deleted = 0;
    await _pump(tester, _data(onDelete: (_) => deleted++));

    final menu = find.byTooltip('Preset options');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, 1);
    expect(find.text('Code reviewer'), findsNothing);
    expect(find.text('YOUR PRESETS'), findsNothing);
    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('long copy fits 320 dp at 200% text, menu and dialog', (
    tester,
  ) async {
    const longBuiltIn = V2AgentPreset(
      id: 'long-built-in',
      name: 'Careful long-form writing partner',
      description:
          'Reads the whole brief before answering and keeps the tone calm '
          'and plain, even when the task is complicated.',
      modelLabel: 'Ovid Pro with extended thinking',
      builtIn: true,
      icon: Icons.edit_note_rounded,
    );
    const longCustom = V2AgentPreset(
      id: 'long-custom',
      name: 'My very long custom preset name that keeps going',
      description: 'Checks every change for bugs, gaps and missing tests.',
      modelLabel: 'Ovid Auto',
      icon: Icons.tune_rounded,
    );

    String? deleted;
    await _pump(
      tester,
      _data(
        presets: const [longBuiltIn, longCustom],
        selectedId: 'long-custom',
        onSelect: (_) {},
        onCreate: () {},
        onDelete: (id) => deleted = id,
      ),
      size: const Size(320, 1000),
      textScale: 2,
    );

    expect(find.text('Careful long-form writing partner'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final menu = find.byTooltip('Preset options');
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();

    // Only the wired action is offered.
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('My very long custom preset name'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 'long-custom');
  });
}
