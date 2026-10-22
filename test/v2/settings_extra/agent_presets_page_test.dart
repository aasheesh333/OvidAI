import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/agent_presets_page.dart';

const _models = <V2PresetModelOption>[
  V2PresetModelOption(id: 'auto', label: 'Ovid Auto'),
  V2PresetModelOption(id: 'ovid-pro', label: 'Ovid Pro'),
];

const _general = V2AgentPreset(
  id: 'general',
  name: 'General',
  description: 'Balanced help for everyday tasks.',
  modelLabel: 'Ovid Auto',
  modelId: 'auto',
  builtIn: true,
  icon: Icons.bolt_rounded,
  responseWaitSeconds: 300,
  permissionModeId: 'auto',
);

const _coder = V2AgentPreset(
  id: 'coder',
  name: 'Coder',
  description: 'Writes and reviews code with care.',
  modelLabel: 'Ovid Pro',
  modelId: 'ovid-pro',
  builtIn: true,
  icon: Icons.code_rounded,
  responseWaitSeconds: 300,
  permissionModeId: 'auto',
);

const _reviewer = V2AgentPreset(
  id: 'reviewer',
  name: 'Code reviewer',
  description: 'Checks changes for bugs and gaps.',
  modelLabel: 'Ovid Pro',
  modelId: 'ovid-pro',
  icon: Icons.rate_review_outlined,
  responseWaitSeconds: 120,
  permissionModeId: 'safe',
);

/// Records every write the page asks for. A pending [Completer] lets a test
/// hold the screen in its saving / deleting state.
class _Store {
  final List<String> applied = <String>[];
  final List<V2AgentPresetDraft> created = <V2AgentPresetDraft>[];
  final List<(String, V2AgentPresetDraft)> updated =
      <(String, V2AgentPresetDraft)>[];
  final List<String> deleted = <String>[];

  Completer<void>? applyGate;
  Completer<void>? createGate;
  Completer<void>? updateGate;
  Completer<void>? deleteGate;
  bool failApply = false;
  bool failCreate = false;
  bool failUpdate = false;
  bool failDelete = false;

  Future<void> apply(String id) async {
    applied.add(id);
    if (applyGate != null) await applyGate!.future;
    if (failApply) throw StateError('apply failed');
  }

  Future<void> create(V2AgentPresetDraft draft) async {
    created.add(draft);
    if (createGate != null) await createGate!.future;
    if (failCreate) throw StateError('create failed');
  }

  Future<void> update(String id, V2AgentPresetDraft draft) async {
    updated.add((id, draft));
    if (updateGate != null) await updateGate!.future;
    if (failUpdate) throw StateError('update failed');
  }

  Future<void> delete(String id) async {
    deleted.add(id);
    if (deleteGate != null) await deleteGate!.future;
    if (failDelete) throw StateError('delete failed');
  }
}

V2AgentPresetsPageData _data({
  V2AgentPresetsStatus status = V2AgentPresetsStatus.ready,
  List<V2AgentPreset> presets = const [_general, _coder, _reviewer],
  String? selectedId = 'general',
  _Store? store,
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
    models: _models,
    onSelect: onSelect,
    onCreate: onCreate,
    onEdit: onEdit,
    onDelete: onDelete,
    onRetry: onRetry,
    onApply: store?.apply,
    onCreatePreset: store?.create,
    onUpdatePreset: store?.update,
    onDeletePreset: store?.delete,
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

Future<void> _openMenu(WidgetTester tester, String id) async {
  final menu = find.byKey(ValueKey<String>('preset-menu-$id'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'renders one list with settings, built-in mark and active state',
    (tester) async {
      await _pump(tester, _data(store: _Store()));

      expect(find.text('Agent presets'), findsOneWidget);
      expect(find.text('General'), findsOneWidget);
      expect(find.text('Coder'), findsOneWidget);
      expect(find.text('Code reviewer'), findsOneWidget);
      // The subtitle is what the preset changes, not marketing copy.
      expect(
        find.text('Built-in · Ovid Auto · 5 min · General · Active'),
        findsOneWidget,
      );
      expect(
        find.text('Built-in · Ovid Pro · 5 min · General'),
        findsOneWidget,
      );
      expect(find.text('Ovid Pro · 2 min · Read-Only'), findsOneWidget);
      expect(find.text('Balanced help for everyday tasks.'), findsNothing);
      expect(find.text('YOUR PRESETS'), findsNothing);
      expect(find.byKey(const ValueKey<String>('presets-new')), findsOneWidget);
    },
  );

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(store: _Store()), dark: true);

    expect(find.text('Coder'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('presets-new')), findsOneWidget);
  });

  testWidgets('applying a preset writes it and moves the active marker', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    final coder = find.byKey(const ValueKey<String>('preset-coder'));
    await tester.tap(find.text('Coder'));
    await tester.pumpAndSettle();

    expect(store.applied, ['coder']);
    expect(
      find.descendant(
        of: coder,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Built-in · Ovid Pro · 5 min · General · Active'),
      findsOneWidget,
    );
  });

  testWidgets('a failed apply puts the marker back and reports it', (
    tester,
  ) async {
    final store = _Store()..failApply = true;
    await _pump(tester, _data(store: store));

    await tester.tap(find.text('Coder'));
    await tester.pumpAndSettle();

    expect(find.text('Could not apply preset.'), findsOneWidget);
    final general = find.byKey(const ValueKey<String>('preset-general'));
    expect(
      find.descendant(
        of: general,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('preset-coder')),
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('applying shows a row-level saving state', (tester) async {
    final store = _Store()..applyGate = Completer<void>();
    await _pump(tester, _data(store: store));

    await tester.tap(find.text('Coder'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('preset-applying-coder')),
      findsOneWidget,
    );

    store.applyGate!.complete();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('preset-applying-coder')),
      findsNothing,
    );
  });

  testWidgets('creates a preset with a model, wait and permission', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();

    expect(find.text('New preset'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      'Writer',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('preset-model-ovid-pro')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-wait-60')));
    await tester.tap(
      find.byKey(const ValueKey<String>('preset-permission-studio')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(store.created, hasLength(1));
    final draft = store.created.single;
    expect(draft.name, 'Writer');
    expect(draft.modelId, 'ovid-pro');
    expect(draft.modelLabel, 'Ovid Pro');
    expect(draft.responseWaitSeconds, 60);
    expect(draft.permissionModeId, 'studio');
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Ovid Pro · 1 min · Studio'), findsOneWidget);
  });

  testWidgets('rejects an empty name inline and does not write', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a name.'), findsOneWidget);
    expect(store.created, isEmpty);
    // The sheet stays open.
    expect(find.byKey(const ValueKey<String>('preset-name')), findsOneWidget);
  });

  testWidgets('rejects a duplicate name inline, case-insensitively', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      '  coder ',
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(find.text('That name is taken.'), findsOneWidget);
    expect(store.created, isEmpty);
  });

  testWidgets('a failed create stays in the sheet and reports it', (
    tester,
  ) async {
    final store = _Store()..failCreate = true;
    await _pump(tester, _data(store: store));

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      'Writer',
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('preset-save-error')),
      findsOneWidget,
    );
    expect(find.text('Could not save preset.'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('preset-name')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'Writer',
      ),
      findsNothing,
    );
  });

  testWidgets('create shows a saving state and blocks dismissal', (
    tester,
  ) async {
    final store = _Store()..createGate = Completer<void>();
    await _pump(tester, _data(store: store));

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      'Writer',
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pump();

    final save = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('preset-save')),
    );
    expect(save.loading, isTrue);
    expect(save.onPressed, isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey<String>('preset-name')))
          .enabled,
      isFalse,
    );

    store.createGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('preset-name')), findsNothing);
    expect(find.text('Writer'), findsOneWidget);
  });

  testWidgets('edits a custom preset and persists the full draft', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('preset-name')),
    );
    expect(field.controller!.text, 'Code reviewer');

    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      'Reviewer',
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-model-auto')));
    await tester.tap(find.byKey(const ValueKey<String>('preset-wait-600')));
    await tester.tap(
      find.byKey(const ValueKey<String>('preset-permission-drive')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(store.updated, hasLength(1));
    final (id, draft) = store.updated.single;
    expect(id, 'reviewer');
    expect(draft.name, 'Reviewer');
    expect(draft.modelId, 'auto');
    expect(draft.responseWaitSeconds, 600);
    expect(draft.permissionModeId, 'drive');
    expect(find.text('Reviewer'), findsOneWidget);
    expect(find.text('Ovid Auto · 10 min · Full Access'), findsOneWidget);
  });

  testWidgets('editing keeps the preset when the write fails', (tester) async {
    final store = _Store()..failUpdate = true;
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('preset-name')),
      'Reviewer',
    );
    await tester.tap(find.byKey(const ValueKey<String>('preset-save')));
    await tester.pumpAndSettle();

    expect(find.text('Could not save preset.'), findsOneWidget);
    expect(find.text('Code reviewer'), findsOneWidget);
  });

  testWidgets('delete confirms with the preset name and removes the row', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Code reviewer?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    expect(store.deleted, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(store.deleted, ['reviewer']);
    expect(find.text('Code reviewer'), findsNothing);
    expect(find.text('General'), findsOneWidget);
  });

  testWidgets('cancelling the confirm keeps the preset', (tester) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(store.deleted, isEmpty);
    expect(find.text('Code reviewer'), findsOneWidget);
  });

  testWidgets('a failed delete keeps the row and reports it', (tester) async {
    final store = _Store()..failDelete = true;
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Could not delete preset.'), findsOneWidget);
    expect(find.text('Code reviewer'), findsOneWidget);
  });

  testWidgets('deleting shows a row-level deleting state', (tester) async {
    final store = _Store()..deleteGate = Completer<void>();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('preset-deleting-reviewer')),
      findsOneWidget,
    );
    expect(find.text('Code reviewer'), findsOneWidget);

    store.deleteGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Code reviewer'), findsNothing);
  });

  testWidgets('built-in presets are marked and cannot be edited or deleted', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'general');

    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('the last built-in preset cannot be deleted', (tester) async {
    var deleted = 0;
    await _pump(
      tester,
      _data(
        presets: const [_general],
        selectedId: 'general',
        onDelete: (_) => deleted++,
      ),
    );

    // No delete path exists for a built-in, so there is no row menu at all
    // when duplication is not wired either.
    expect(
      find.byKey(const ValueKey<String>('preset-menu-general')),
      findsNothing,
    );
    expect(find.text('Delete'), findsNothing);
    expect(deleted, 0);
  });

  testWidgets('duplicating a built-in creates a copy under a free name', (
    tester,
  ) async {
    final store = _Store();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'general');
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    expect(store.created, hasLength(1));
    expect(store.created.single.name, 'General copy');
    expect(store.created.single.modelId, 'auto');
    expect(find.text('General copy'), findsOneWidget);
  });

  testWidgets('a duplicate copy name gets a suffix instead of colliding', (
    tester,
  ) async {
    const copy = V2AgentPreset(
      id: 'copy',
      name: 'General copy',
      description: '',
      modelLabel: 'Ovid Auto',
      modelId: 'auto',
    );
    final store = _Store();
    await _pump(
      tester,
      _data(presets: const [_general, _coder, copy], store: store),
    );

    await _openMenu(tester, 'general');
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    expect(store.created.single.name, 'General copy 2');
  });

  testWidgets('duplicating shows a page saving state and disables create', (
    tester,
  ) async {
    final store = _Store()..createGate = Completer<void>();
    await _pump(tester, _data(store: store));

    await _openMenu(tester, 'general');
    await tester.tap(find.text('Duplicate'));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('presets-busy')), findsOneWidget);
    final create = tester.widget<OIconButton>(
      find.byKey(const ValueKey<String>('presets-new')),
    );
    expect(create.onPressed, isNull);

    store.createGate!.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('presets-busy')), findsNothing);
  });

  testWidgets('renders the empty state and opens the create sheet', (
    tester,
  ) async {
    final store = _Store();
    await _pump(
      tester,
      _data(
        status: V2AgentPresetsStatus.empty,
        presets: const [],
        selectedId: null,
        store: store,
      ),
    );

    expect(find.text('No presets yet'), findsOneWidget);
    expect(
      find.text('Make a preset to change how Ovid works.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OButton, 'New preset'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('preset-name')), findsOneWidget);
    expect(find.text('New preset'), findsWidgets);
  });

  testWidgets('shows the skeleton while loading', (tester) async {
    await _pump(
      tester,
      _data(status: V2AgentPresetsStatus.loading, store: _Store()),
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

  testWidgets('legacy callbacks still drive select, create, edit and delete', (
    tester,
  ) async {
    String? selected;
    String? edited;
    String? deleted;
    var created = 0;
    await _pump(
      tester,
      _data(
        onSelect: (id) => selected = id,
        onCreate: () => created++,
        onEdit: (id) => edited = id,
        onDelete: (id) => deleted = id,
      ),
    );

    await tester.tap(find.text('Coder'));
    await tester.pumpAndSettle();
    expect(selected, 'coder');

    await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
    await tester.pumpAndSettle();
    expect(created, 1);

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edited, 'reviewer');

    await _openMenu(tester, 'reviewer');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 'reviewer');
  });

  testWidgets('hides every control that has no backing callback', (
    tester,
  ) async {
    await _pump(tester, _data());

    expect(find.byKey(const ValueKey<String>('presets-new')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('preset-menu-reviewer')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('preset-menu-general')),
      findsNothing,
    );
  });

  testWidgets('rows are at least 56 dp tall', (tester) async {
    await _pump(tester, _data(store: _Store()));

    for (final id in ['general', 'coder', 'reviewer']) {
      final size = tester.getSize(find.byKey(ValueKey<String>('preset-$id')));
      expect(size.height, greaterThanOrEqualTo(56));
    }
  });

  testWidgets('the row announces name, settings and active state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data(store: _Store()));

    expect(
      find.bySemanticsLabel(
        'General, Built-in · Ovid Auto · 5 min · General · Active',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Code reviewer, Ovid Pro · 2 min · Read-Only'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('the delete item announces the preset and is destructive', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data(store: _Store()));

    await _openMenu(tester, 'reviewer');
    expect(
      find.bySemanticsLabel('Delete Code reviewer, cannot be undone'),
      findsOneWidget,
    );

    handle.dispose();
  });

  testWidgets('centres and caps the list at 600 dp', (tester) async {
    await _pump(tester, _data(store: _Store()), size: const Size(600, 1000));

    final row = find.byKey(const ValueKey<String>('preset-general'));
    expect(tester.getSize(row).width, lessThanOrEqualTo(640));
    expect(tester.getCenter(row).dx, closeTo(300, 0.5));
  });

  testWidgets('centres and caps the list at 1280 dp', (tester) async {
    await _pump(tester, _data(store: _Store()), size: const Size(1280, 1000));

    final row = find.byKey(const ValueKey<String>('preset-general'));
    expect(tester.getSize(row).width, lessThanOrEqualTo(720));
  });

  testWidgets('every width, scale and theme renders without overflow', (
    tester,
  ) async {
    for (final width in [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          await _pump(
            tester,
            _data(store: _Store()),
            size: Size(width, 1200),
            textScale: scale,
            dark: dark,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$width dp at ${scale}x (${dark ? 'dark' : 'light'})',
          );
        }
      }
    }
  });

  testWidgets('the editor fits 320 dp at 200% text in light and dark', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await _pump(
        tester,
        _data(store: _Store()),
        size: const Size(320, 900),
        textScale: 2,
        dark: dark,
      );
      await tester.tap(find.byKey(const ValueKey<String>('presets-new')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey<String>('preset-save')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('preset-cancel')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('preset-cancel')));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('long names and models fit 320 dp at 200% text', (tester) async {
    const longBuiltIn = V2AgentPreset(
      id: 'long-built-in',
      name: 'Careful long-form writing partner',
      description:
          'Reads the whole brief before answering and keeps the tone calm '
          'and plain, even when the task is complicated.',
      modelLabel: 'Ovid Pro with extended thinking',
      modelId: 'ovid-pro',
      builtIn: true,
      icon: Icons.edit_note_rounded,
      responseWaitSeconds: 600,
      permissionModeId: 'drive',
    );
    const longCustom = V2AgentPreset(
      id: 'long-custom',
      name: 'My very long custom preset name that keeps going',
      description: 'Checks every change for bugs, gaps and missing tests.',
      modelLabel: 'Ovid Auto',
      modelId: 'auto',
      icon: Icons.tune_rounded,
    );

    final store = _Store();
    await _pump(
      tester,
      _data(
        presets: const [longBuiltIn, longCustom],
        selectedId: 'long-custom',
        store: store,
      ),
      size: const Size(320, 2000),
      textScale: 2,
    );

    expect(find.text('Careful long-form writing partner'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _openMenu(tester, 'long-custom');
    expect(find.text('Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('My very long custom preset name'),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion still shows every preset', (tester) async {
    await _pump(tester, _data(store: _Store()), reduceMotion: true);

    expect(find.text('General'), findsOneWidget);
    expect(find.text('Coder'), findsOneWidget);
    expect(find.text('Code reviewer'), findsOneWidget);
  });

  testWidgets('the row menu is a 48 dp labelled control', (tester) async {
    await _pump(tester, _data(store: _Store()));

    final menu = find.byKey(const ValueKey<String>('preset-menu-reviewer'));
    expect(menu, findsOneWidget);

    final size = tester.getSize(menu);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
