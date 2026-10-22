import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

V2MemoryPageData _data({
  bool memoryEnabled = true,
  ValueChanged<bool>? onMemoryEnabledChanged,
  VoidCallback? onEditGlobal,
  ValueChanged<String>? onProjectTap,
  void Function(V2MemoryScope scope, String id)? onForgetMemory,
  VoidCallback? onResetAll,
  VoidCallback? onRetry,
  bool loading = false,
  String? errorMessage,
  List<String> globalMemory = const [
    'Prefers plain English.',
    'Works as a product designer.',
  ],
}) {
  return V2MemoryPageData(
    memoryEnabled: memoryEnabled,
    globalMemory: globalMemory,
    projects: const [
      V2MemoryProject(
        id: 'p1',
        name: 'Mobile App Redesign',
        detail: '4 rules · Synced 1h ago',
      ),
    ],
    sessionFiles: const [
      V2MemoryFile(
        id: 'f1',
        name: 'architecture-spec.md',
        detail: '42 KB · Markdown',
      ),
    ],
    loading: loading,
    errorMessage: errorMessage,
    onMemoryEnabledChanged: onMemoryEnabledChanged,
    onEditGlobal: onEditGlobal,
    onProjectTap: onProjectTap,
    onForgetMemory: onForgetMemory,
    onResetAll: onResetAll,
    onRetry: onRetry,
  );
}

void main() {
  testWidgets('one list holds every scope, one delete per row', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data(onResetAll: () {})), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
    // Every scope is in the same list, with its value beside the title.
    expect(find.text('Prefers plain English.'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('architecture-spec.md'), findsOneWidget);
    expect(find.text('Global'), findsWidgets);
    // One filter, four chips.
    for (final key in ['all', 'global', 'project', 'session']) {
      expect(
        find.byKey(ValueKey<String>('memory-scope-$key')),
        findsOneWidget,
      );
    }
    // One primary action, at the bottom.
    expect(find.text('Reset all memory'), findsOneWidget);

    // The duplicate chrome is gone.
    expect(find.text('Memory on'), findsNothing);
    expect(find.text('Share session memory'), findsNothing);
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

  testWidgets('empty state offers a way to add a memory', (tester) async {
    var added = 0;
    await tester.pumpWidget(
      _app(
        MemoryPage(data: V2MemoryPageData(onEditGlobal: () => added++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No memories yet'), findsOneWidget);
    await tester.tap(find.text('Add a memory'));
    await tester.pump();

    expect(added, 1);
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

  testWidgets('scope chips are real filters over the one list', (tester) async {
    await tester.pumpWidget(
      _app(MemoryPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-project')));
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
    expect(find.text('architecture-spec.md'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-session')));
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

  testWidgets('a scope with no rows says so instead of showing others', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MemoryPage(
          data: V2MemoryPageData(
            globalMemory: const ['Prefers plain English.'],
            onForgetMemory: (_, _) {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('memory-scope-session')));
    await tester.pumpAndSettle();

    expect(find.text('Nothing in this scope'), findsOneWidget);
    expect(find.text('Prefers plain English.'), findsNothing);
  });

  testWidgets('forget removes a global entry from the list and reports it', (
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

    final forget = find.byKey(
      const ValueKey<String>('memory-forget-global-0:Prefers plain English.'),
    );
    expect(forget, findsOneWidget);
    await tester.tap(forget);
    await tester.pumpAndSettle();

    expect(find.text('Prefers plain English.'), findsNothing);
    expect(find.text('Works as a product designer.'), findsOneWidget);
    expect(forgotten, ['global:0:Prefers plain English.']);
  });

  testWidgets('forget removes project and session rows and reports them', (
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
      find.byKey(const ValueKey<String>('memory-forget-project-p1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mobile App Redesign'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('memory-forget-session-f1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('architecture-spec.md'), findsNothing);

    expect(forgotten, ['project:p1', 'session:f1']);
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
      _app(MemoryPage(data: _data(onResetAll: () => reset++)), theme: OTheme.light()),
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

  testWidgets('lays out at 320 dp with 200 % text in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? OTheme.dark() : OTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: MemoryPage(
              data: _data(
                onForgetMemory: (_, _) {},
                onResetAll: () {},
                onProjectTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: 'dark: $dark');
      expect(find.text('Reset all memory'), findsOneWidget);
    }
  });
}
