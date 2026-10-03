import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late Directory dir;
  late AppState app;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('memory-ui-');
    app = AppState.createForTest(memoryStore: MemoryStore(dir));
  });
  tearDown(() async {
    await app.persistSessions();
    AppState.resetTestInstance();
    dir.deleteSync(recursive: true);
  });

  testWidgets('edit/save updates persisted Markdown and agent context', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory-content')),
      'My preference <script>alert(1)</script>',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      MemoryStore(dir).read(null, 'MEMORY.md').content,
      contains('<script>'),
    );
    expect(
      agent.buildRequestMessages(app.activeSession!, 'sys').toString(),
      contains('My preference'),
    );
    // Imported markup is only plain editable text, never a WebView or HTML renderer.
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('Add file'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('memory-filename')),
      '../bad.md',
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('plain .md filename'), findsOneWidget);
  });

  testWidgets(
    'stale editor reports conflict and preserves newer user content',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
      await tester.runAsync(() => app.prepareMemory());
      await tester.pumpAndSettle();
      MemoryStore(dir).save(null, 'MEMORY.md', 'Newer edit', mode: 'append');
      await tester.enterText(
        find.byKey(const Key('memory-content')),
        'Stale edit',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Reload before saving'), findsOneWidget);
      expect(MemoryStore(dir).read(null, 'MEMORY.md').content, 'Newer edit');
    },
  );

  testWidgets(
    'import creates safe Markdown, reports conflicts and oversize input',
    (tester) async {
      final source = File('${dir.path}/picked.md')
        ..writeAsStringSync('Imported <script>bad()</script>');
      final picker = _Picker(
        PlatformFile(
          name: 'details.md',
          path: source.path,
          size: source.lengthSync(),
        ),
      );
      FilePicker.platform = picker;
      await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
      await tester.runAsync(() => app.prepareMemory());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import .md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(
        MemoryStore(dir).read(null, 'details.md').content,
        'Imported <script>bad()</script>',
      );
      expect(MemoryStore(dir).read(null, 'MEMORY.md').content, isEmpty);
      await tester.tap(find.text('Import .md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      picker.file = PlatformFile(
        name: 'large.md',
        path: source.path,
        size: 100000,
      );
      await tester.tap(find.text('Import .md'));
      await tester.pumpAndSettle();
      expect(find.textContaining('exceeds 32 KiB'), findsOneWidget);
      source.deleteSync();
    },
  );
}

class _Picker extends FilePicker {
  PlatformFile file;
  _Picker(this.file);
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([file]);
}
