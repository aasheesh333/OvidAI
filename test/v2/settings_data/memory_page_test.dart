import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';

Widget _app(
  Widget home, {
  required ThemeData theme,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: home,
);

const _facts = <V2MemoryEntry>[
  V2MemoryEntry(id: 'g1', text: 'Prefers plain English.'),
  V2MemoryEntry(id: 'g2', text: 'Works as a product designer.'),
];

const _projects = <V2MemoryProject>[
  V2MemoryProject(
    id: 'p1',
    name: 'Mobile App Redesign',
    detail: '4 rules · Synced 1h ago',
  ),
];

const _files = <V2MemoryFile>[
  V2MemoryFile(id: 'f1', name: 'architecture-spec.md', detail: '42 KB'),
];

V2MemoryPageData _data({
  bool memoryEnabled = true,
  ValueChanged<bool>? onMemoryEnabledChanged,
  VoidCallback? onEditGlobal,
  ValueChanged<String>? onProjectTap,
  V2MemoryForget? onForgetMemory,
  V2MemoryEdit? onEditMemory,
  V2MemoryAdd? onAddMemory,
  VoidCallback? onResetAll,
  VoidCallback? onRetry,
  bool loading = false,
  String? errorMessage,
  List<V2MemoryEntry>? globalEntries = _facts,
  List<V2MemoryProject> projects = _projects,
  List<V2MemoryFile> files = _files,
}) {
  return V2MemoryPageData(
    memoryEnabled: memoryEnabled,
    globalEntries: globalEntries,
    projects: projects,
    sessionFiles: files,
    loading: loading,
    errorMessage: errorMessage,
    onMemoryEnabledChanged: onMemoryEnabledChanged,
    onEditGlobal: onEditGlobal,
    onProjectTap: onProjectTap,
    onForgetMemory: onForgetMemory,
    onEditMemory: onEditMemory,
    onAddMemory: onAddMemory,
    onResetAll: onResetAll,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('one list holds every scope and every count is real', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onResetAll: () {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsOneWidget);

    // Counts are per scope and add up to All.
    expect(find.text('All 4'), findsOneWidget);
    expect(find.text('Global 2'), findsOneWidget);
    expect(find.text('Project 1'), findsOneWidget);
    expect(find.text('Chat 1'), findsOneWidget);

    for (final key in ['all', 'global', 'project', 'chat']) {
      expect(find.byKey(ValueKey<String>('memory-scope-$key')), findsOneWidget);
    }
    expect(find.text('Reset all memory'), findsOneWidget);

    // No duplicated chrome from the old screen.
    expect(find.text('Memory on'), findsNothing);
    expect(find.text('Share chat memory'), findsNothing);
    expect(find.text('Export memory'), findsNothing);
    expect(find.textContaining('Memory automatically gathers'), findsNothing);
    expect(find.textContaining('cannot be undone'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('architecture-spec.md'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsOneWidget);
  });

  testWidgets('scope chips are real filters and keep honest counts', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-scope-project')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
    expect(find.text('architecture-spec.md'), findsNothing);
    // The counts describe the data, not the filtered view.
    expect(find.text('All 4'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-chat')));
    await tester.pumpAndSettle();
    expect(find.text('architecture-spec.md'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-global')));
    await tester.pumpAndSettle();
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-all')));
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsOneWidget);
  });

  testWidgets('a scope with no rows says so and still shows the filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(files: const [], onForgetMemory: (_, _) => true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-chat')));
    await tester.pumpAndSettle();

    expect(find.text('No memories in this scope'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
    expect(find.text('Chat 0'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('memory-scope-all')),
      findsOneWidget,
    );
    // This is not the empty state: the memory still holds other facts.
    expect(find.text('No memories yet'), findsNothing);
  });

  testWidgets('truly empty memory shows the empty state, not a no-match', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            globalEntries: const [],
            projects: const [],
            files: const [],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memories yet'), findsOneWidget);
    expect(find.text('No memories in this scope'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('memory-scope-all')),
      findsNothing,
    );
  });

  testWidgets('empty state can turn memory back on', (tester) async {
    bool? value;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            memoryEnabled: false,
            onMemoryEnabledChanged: (next) => value = next,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memories yet'), findsOneWidget);
    await tester.tap(find.text('Turn on memory'));
    await tester.pump();

    expect(value, isTrue);
  });

  testWidgets('no add control without a real write path', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            onEditGlobal: () => opened++,
            globalEntries: const [],
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The old screen opened a read-only file list from here. With no add
    // handler there is no add control at all.
    expect(find.text('Add a memory'), findsNothing);
    expect(find.byKey(const ValueKey<String>('memory-add')), findsNothing);
    expect(opened, 0);

    // The files destination is real, so it stays reachable from the header.
    final files = find.byKey(const ValueKey<String>('memory-files'));
    expect(files, findsOneWidget);
    await tester.tap(files);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('add opens an editor and renders the entry the service made', (
    tester,
  ) async {
    String? written;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            globalEntries: const [],
            onAddMemory: (text) async {
              written = text;
              return V2MemoryEntry(id: 'new-1', text: text);
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a memory'));
    await tester.pumpAndSettle();
    expect(find.text('Add memory'), findsOneWidget);

    final save = find.byKey(const ValueKey<String>('memory-editor-save'));
    expect(tester.widget<OButton>(save).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey<String>('memory-editor-field')),
      'Likes tea.',
    );
    await tester.pump();
    expect(tester.widget<OButton>(save).onPressed, isNotNull);

    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(written, 'Likes tea.');
    expect(find.text('Likes tea.'), findsOneWidget);
    expect(find.text('Global 1'), findsOneWidget);
    expect(find.text('No memories yet'), findsNothing);
  });

  testWidgets('the add action sits in the header when facts exist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onAddMemory: (text) async => V2MemoryEntry(id: 'n', text: text),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final add = find.byKey(const ValueKey<String>('memory-add'));
    expect(add, findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text('Add memory'), findsOneWidget);
  });

  testWidgets('shows a skeleton while memory loads', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data(loading: true)), theme: OTheme.light()),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            errorMessage: 'Memory could not load right now.',
            onRetry: () => retried++,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory could not load right now.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('forget keeps the row until the service succeeds', (
    tester,
  ) async {
    final answer = Completer<bool>();
    var calls = 0;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onForgetMemory: (scope, id) {
              calls++;
              expect(scope, V2MemoryScope.global);
              expect(id, 'g1');
              return answer.future;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-global:g1')),
    );
    await tester.pump();

    // In flight: the fact is still on screen, marked as being forgotten.
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Global 2'), findsOneWidget);
    expect(calls, 1);

    answer.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Prefers plain English.'), findsNothing);
    expect(find.text('Works as a product designer.'), findsOneWidget);
    expect(find.text('Global 1'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a failed forget keeps the row and reports inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onForgetMemory: (_, _) async => false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-global:g1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Global 2'), findsOneWidget);
    expect(find.text('Could not forget that memory.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('memory-action-error')),
      findsOneWidget,
    );
  });

  testWidgets('a forget that throws is reported, not swallowed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onForgetMemory: (_, _) async => throw StateError('offline'),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-global:g1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Could not forget that memory.'), findsOneWidget);
  });

  testWidgets('a legacy void handler never removes the row optimistically', (
    tester,
  ) async {
    final forgotten = <String>[];
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onForgetMemory: (scope, id) => forgotten.add('${scope.name}:$id'),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-global:g1')),
    );
    await tester.pumpAndSettle();

    expect(forgotten, ['global:g1']);
    // No completion signal, so the row stays until the owner sends new data.
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Could not forget that memory.'), findsNothing);
  });

  testWidgets('forget removes project and session rows after success', (
    tester,
  ) async {
    final forgotten = <String>[];
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onForgetMemory: (scope, id) async {
              forgotten.add('${scope.name}:$id');
              return true;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-project:p1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-session:f1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('architecture-spec.md'), findsNothing);

    expect(forgotten, ['project:p1', 'session:f1']);
  });

  testWidgets('edit opens the fact with its text and saves it', (tester) async {
    String? edited;
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: _data(
            onEditMemory: (scope, id, text) async {
              edited = '${scope.name}:$id:$text';
              return text;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prefers plain English.'));
    await tester.pumpAndSettle();

    expect(find.text('Edit memory'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('memory-editor-field')),
    );
    expect(field.controller!.text, 'Prefers plain English.');

    await tester.enterText(
      find.byKey(const ValueKey<String>('memory-editor-field')),
      'Prefers British English.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('memory-editor-save')));
    await tester.pumpAndSettle();

    expect(edited, 'global:g1:Prefers British English.');
    expect(find.text('Prefers British English.'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
  });

  testWidgets('a failed edit keeps the old fact and the typed text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onEditMemory: (_, _, _) async => null)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prefers plain English.'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('memory-editor-field')),
      'Prefers British English.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('memory-editor-save')));
    await tester.pumpAndSettle();

    // The sheet stays open with the reason and the typed text.
    expect(find.text('Could not save that memory.'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('memory-editor-field')),
    );
    expect(field.controller!.text, 'Prefers British English.');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Nothing was written to the list.
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Prefers British English.'), findsNothing);
  });

  testWidgets('saving disables the editor while the handler runs', (
    tester,
  ) async {
    final answer = Completer<String?>();
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onEditMemory: (_, _, _) => answer.future)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Prefers plain English.'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('memory-editor-field')),
      'Prefers British English.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('memory-editor-save')));
    await tester.pump();

    final save = find.byKey(const ValueKey<String>('memory-editor-save'));
    expect(tester.widget<OButton>(save).loading, isTrue);
    expect(tester.widget<OButton>(save).onPressed, isNull);

    answer.complete('Prefers British English.');
    await tester.pumpAndSettle();
    expect(find.text('Prefers British English.'), findsOneWidget);
  });

  testWidgets('the project row opens the project', (tester) async {
    String? opened;
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onProjectTap: (id) => opened = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mobile App Redesign'));
    await tester.pump();

    expect(opened, 'p1');
  });

  testWidgets('reset is the single bottom action', (tester) async {
    var reset = 0;
    await tester.pumpWidget(
      _app(
        MemoryPage(data: _data(onResetAll: () => reset++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<OButton>(
      find.widgetWithText(OButton, 'Reset all memory'),
    );
    expect(button.onPressed, isNotNull);
    await tester.tap(find.text('Reset all memory'));
    await tester.pump();

    expect(reset, 1);
  });

  testWidgets(
    'each fact announces its text and scope, forget says destructive',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          MemoryPage(data: _data(onForgetMemory: (_, _) async => true)),
          theme: OTheme.light(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Prefers plain English., Global memory'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Mobile App Redesign, Project memory'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('architecture-spec.md, Chat memory'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Forget Prefers plain English., destructive'),
        findsOneWidget,
      );

      // The selected filter is announced as selected.
      final before = tester.getSemantics(
        find.bySemanticsLabel('Global, 2 entries'),
      );
      expect(
        before.getSemanticsData().flagsCollection.isSelected,
        ui.Tristate.isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('memory-scope-global')),
      );
      await tester.pumpAndSettle();

      final after = tester.getSemantics(
        find.bySemanticsLabel('Global, 2 entries'),
      );
      expect(
        after.getSemanticsData().flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      handle.dispose();
    },
  );

  testWidgets('320 dp at 200 % text: no overflow, rows stay tappable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        _app(
          MemoryPage(
            data: _data(
              onForgetMemory: (_, _) async => true,
              onEditMemory: (_, _, text) async => text,
              onAddMemory: (text) async => V2MemoryEntry(id: 'n', text: text),
              onResetAll: () {},
              onProjectTap: (_) {},
            ),
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Reset all memory'), findsOneWidget);
      final row = find.byKey(const ValueKey<String>('memory-row-global:g1'));
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('320 to 1280 at 1x and 2x, light and dark, content capped', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            _app(
              MemoryPage(
                data: _data(
                  onForgetMemory: (_, _) async => true,
                  onResetAll: () {},
                ),
              ),
              theme: dark ? OTheme.dark() : OTheme.light(),
              textScaler: TextScaler.linear(scale),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: '$width dp at $scale, dark: $dark',
          );

          if (width >= 600) {
            final cap = width >= 900 ? 720.0 : 640.0;
            final body = tester.getSize(find.byType(CustomScrollView).first);
            expect(
              body.width,
              lessThanOrEqualTo(cap),
              reason: '$width dp should cap its column at $cap',
            );
          }
        }
      }
    }
  });
}
