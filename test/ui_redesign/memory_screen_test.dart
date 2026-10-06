import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Memory screen Aether redesign contract (wave 2 UI).
///
/// Pins the public anatomy the redesign owes callers:
///   * [AetherSectionTitle] eyebrow 'MEMORIES' with the scope explainer.
///   * One [AetherCard] per memory file: pin glyph, filename, scope caption,
///     and an overflow menu offering Edit / Delete.
///   * FAB [AetherPrimaryButton] 'Add memory' opens an [AetherSheet] whose
///     `memory-filename` field creates a real store file.
///   * [AetherEmptyState] when the scope lists no files (defensive branch —
///     the real store always lists the MEMORY.md entrypoint).
///
/// Behavior preservation (CRUD through [MemoryStore], revision conflicts,
/// import validation) stays covered by `test/memory_screen_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('memory-ui-redesign-');
    app = AppState.createForTest(memoryStore: MemoryStore(dir));
  });

  tearDown(() async {
    await app.persistSessions();
    AppState.resetTestInstance();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const MemoryScreen()),
    );
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
  }

  testWidgets('renders section title and a pinned card per memory file', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.byType(AetherSectionTitle), findsOneWidget);
    expect(find.text('MEMORIES'), findsOneWidget);

    // MEMORY.md is always listed and carries the filled pin glyph.
    expect(find.byType(AetherCard), findsWidgets);
    expect(find.text('MEMORY.md'), findsWidgets);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);

    // CRUD affordances preserved: editor, save, add-file, import.
    expect(find.byKey(const Key('memory-content')), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Add file'), findsOneWidget);
    expect(find.text('Import .md'), findsOneWidget);

    // Overflow exposes Edit / Delete for the entrypoint row.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Edit stays wired: selecting the already-open file is a no-op close.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(MemoryScreen), findsOneWidget);
  });

  testWidgets('Add memory FAB opens AetherSheet and creates the file', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Add memory'));
    await tester.pumpAndSettle();
    expect(find.byType(AetherSheet), findsOneWidget);
    expect(find.text('Add memory file'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('memory-filename')),
      'ideas.md',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(MemoryStore(dir).list(null), contains('ideas.md'));
    expect(find.text('ideas.md'), findsWidgets);

    // The new, non-pinned row offers Delete; the store cannot remove files,
    // so the UI says so instead of pretending a removal happened.
    await tester.tap(find.byIcon(Icons.more_vert).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete not supported'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('editor save still persists through MemoryStore', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(
      find.byKey(const Key('memory-content')),
      '# Prefs\nDark mode',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      MemoryStore(dir).read(null, 'MEMORY.md').content,
      contains('Dark mode'),
    );
  });

  testWidgets('shows AetherEmptyState when the scope lists no files', (
    tester,
  ) async {
    app = AppState.createForTest(memoryStore: _EmptyListMemoryStore(dir));
    await pumpScreen(tester);

    expect(find.byType(AetherEmptyState), findsOneWidget);
    expect(find.text('No memories yet'), findsOneWidget);
    // Empty-state action and FAB both offer the add flow.
    expect(find.text('Add memory'), findsWidgets);
  });
}

/// Store stub for the defensive empty-list branch. The real [MemoryStore]
/// always includes MEMORY.md, so this branch is unreachable in production.
class _EmptyListMemoryStore extends MemoryStore {
  _EmptyListMemoryStore(super.root);
  @override
  List<String> list(String? owner) => const [];
}
