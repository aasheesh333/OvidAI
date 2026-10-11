import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _memory = '''# Preferences
- Prefers dark mode
- Uses Python 3.12
  for scripts

## Projects
* Ovid app
  - nested detail

A plain paragraph
spanning two lines.

```
code block
- not an entry
```
''';

void main() {
  group('splitMemoryEntries', () {
    test('splits bullets and paragraphs under their headings', () {
      final entries = splitMemoryEntries(_memory);
      expect(entries.map((e) => e.text).toList(), [
        'Prefers dark mode',
        'Uses Python 3.12\nfor scripts',
        'Ovid app\n- nested detail',
        'A plain paragraph\nspanning two lines.',
        '```\ncode block\n- not an entry\n```',
      ]);
      expect(entries.map((e) => e.heading).toList(), [
        'Preferences',
        'Preferences',
        'Projects',
        'Projects',
        'Projects',
      ]);
    });

    test('empty or heading-only files have no entries', () {
      expect(splitMemoryEntries(''), isEmpty);
      expect(splitMemoryEntries('# Title\n\n'), isEmpty);
    });

    test('removing an entry keeps the rest and collapses gaps', () {
      final entries = splitMemoryEntries(_memory);
      final out = removeMemoryEntry(_memory, entries[1]);
      expect(out, isNot(contains('Python')));
      expect(out, contains('- Prefers dark mode\n\n## Projects'));
      final second = splitMemoryEntries(out);
      expect(second.length, 4);
      final paragraph = second.firstWhere((e) => e.text.startsWith('A plain'));
      final lastOut = removeMemoryEntry(out, paragraph);
      expect(lastOut, isNot(contains('\n\n\n')));
      expect(lastOut, isNot(contains('A plain paragraph')));
    });

    test('removing the only entry leaves an empty file', () {
      const md = '- only one\n';
      expect(removeMemoryEntry(md, splitMemoryEntries(md).single), '');
    });
  });

  group('MemoryScreen entries', () {
    late Directory dir;
    late AppState app;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('memory-entries-');
      app = AppState.createForTest(memoryStore: MemoryStore(dir));
    });
    tearDown(() async {
      await app.persistSessions();
      AppState.resetTestInstance();
      dir.deleteSync(recursive: true);
    });

    testWidgets('lists entries, deletes one on confirm, raw editor on demand', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      MemoryStore(dir).save(
        null,
        'MEMORY.md',
        '# Preferences\n- Prefers dark mode\n- Uses Python\n',
        mode: 'replace',
        revision: const MemoryDocument('MEMORY.md', '').revision,
      );
      await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
      await tester.runAsync(() => app.prepareMemory());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('memory-content')), findsNothing);
      expect(find.text('Prefers dark mode'), findsOneWidget);
      expect(find.text('Uses Python'), findsOneWidget);
      expect(find.text('Preferences'), findsOneWidget);
      expect(find.textContaining('Last updated'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete memory').last);
      await tester.pumpAndSettle();
      expect(find.text('Delete this memory?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Uses Python'), findsNothing);
      expect(
        MemoryStore(dir).read(null, 'MEMORY.md').content,
        '# Preferences\n- Prefers dark mode\n',
      );

      await tester.tap(find.text('Edit as Markdown'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('memory-content')), findsOneWidget);
    });
  });
}
