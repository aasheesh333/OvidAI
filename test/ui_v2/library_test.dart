import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/library_screen.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Library surface contract (v2 wave 05).
///
/// Pins the premium anatomy the Library owes callers:
///   * Tabs Memories / Artifacts / Shares switch via the segmented control;
///     Memories embeds the real [MemoryScreen] and keeps its state.
///   * The memory list renders a pinned row per file with an overflow menu.
///   * Every add entry point opens exactly one filename sheet.
///   * `Save` lives in the app bar and still persists through [MemoryStore].
///   * The calm empty state renders at 360×640 @ 2× in light and dark.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late AppState app;
  late bool wasDark;

  setUp(() {
    wasDark = Aether.dark;
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('library-v2-');
    app = AppState.createForTest(memoryStore: MemoryStore(dir));
  });

  tearDown(() async {
    await app.persistSessions();
    AppState.resetTestInstance();
    Aether.dark = wasDark;
    Aether.resetThemeCacheForTest();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const LibraryScreen()),
    );
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
  }

  testWidgets('tabs switch between Memories, Artifacts and Shares', (
    tester,
  ) async {
    await pumpLibrary(tester);

    // Memories tab: the embedded editor shows the real store list.
    expect(find.byType(MemoryScreen), findsOneWidget);
    expect(find.text('MEMORY.md'), findsWidgets);

    // An unsaved draft survives tab switches (IndexedStack keeps state).
    await tester.enterText(
      find.byKey(const Key('memory-content')),
      'draft kept across tabs',
    );

    await tester.tap(find.text('Artifacts'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing made yet'), findsOneWidget);
    expect(find.text('Open image receipts'), findsOneWidget);
    expect(find.text('MEMORY.md'), findsNothing);

    await tester.tap(find.text('Shares'));
    await tester.pumpAndSettle();
    expect(find.text('No shares yet'), findsOneWidget);
    expect(find.text('MEMORY.md'), findsNothing);

    await tester.tap(find.text('Memories'));
    await tester.pumpAndSettle();
    expect(find.text('MEMORY.md'), findsWidgets);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('memory-content')))
          .controller!
          .text,
      'draft kept across tabs',
    );
  });

  testWidgets('memory list renders pinned rows with overflow actions', (
    tester,
  ) async {
    await pumpLibrary(tester);

    // MEMORY.md is the pinned entrypoint; each row carries an overflow menu.
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Edit selects the already-open file — a no-op that closes the menu.
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(MemoryScreen), findsOneWidget);
  });

  testWidgets('every add entry point opens exactly one sheet', (tester) async {
    await pumpLibrary(tester);

    await tester.tap(find.text('Add memory'));
    await tester.pumpAndSettle();
    expect(find.byType(AetherSheet), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const Key('memory-filename')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AetherSheet), findsNothing);

    // The quiet list-level affordance opens the same single sheet.
    await tester.tap(find.text('Add file'));
    await tester.pumpAndSettle();
    expect(find.byType(AetherSheet), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AetherSheet), findsNothing);
  });

  testWidgets('save in the app bar persists through MemoryStore', (
    tester,
  ) async {
    await pumpLibrary(tester);

    final saveInAppBar = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('Save'),
    );
    expect(saveInAppBar, findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('memory-content')),
      'saved from the library',
    );
    await tester.tap(saveInAppBar);
    await tester.pumpAndSettle();

    expect(
      MemoryStore(dir).read(null, 'MEMORY.md').content,
      'saved from the library',
    );
  });

  testWidgets('calm empty state renders at 360x640 @2x in light and dark', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(720, 1280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app = AppState.createForTest(memoryStore: _EmptyListMemoryStore(dir));

    for (final dark in [false, true]) {
      Aether.dark = dark;
      Aether.resetThemeCacheForTest();
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const MemoryScreen()),
      );
      await tester.runAsync(() => app.prepareMemory());
      await tester.pumpAndSettle();

      expect(find.byType(AetherEmptyState), findsOneWidget);
      expect(find.text('No memories yet'), findsOneWidget);
      // Exactly one add action; no FAB, no bottom action bar.
      expect(find.text('Add memory'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('library shell fits 360x640 @2x without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(720, 1280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLibrary(tester);

    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Memories'), findsWidgets);
    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('Shares'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Store stub for the defensive empty-list branch. The real [MemoryStore]
/// always includes MEMORY.md, so this branch is unreachable in production.
class _EmptyListMemoryStore extends MemoryStore {
  _EmptyListMemoryStore(super.root);
  @override
  List<String> list(String? owner) => const [];
}
