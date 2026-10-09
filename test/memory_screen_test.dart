import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    FilePicker.platform = _Picker(null);
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('memory-ui-');
    app = AppState.createForTest(memoryStore: MemoryStore(dir));
  });
  tearDown(() async {
    FilePicker.platform = _Picker(null);
    await app.persistSessions();
    AppState.resetTestInstance();
    dir.deleteSync(recursive: true);
  });

  testWidgets('import works when Android cannot map Markdown MIME filters', (tester) async {
    FilePicker.platform = _Picker(PlatformFile(
      name: 'portable.md', size: 7,
      bytes: Uint8List.fromList(utf8.encode('# Notes')),
    ))..rejectCustomFilter = true;
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-filename')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(MemoryStore(dir).list(null), ['MEMORY.md']);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(MemoryStore(dir).read(null, 'portable.md').content, '# Notes');
  });

  testWidgets('picker errors are readable and retry clears the stale error', (tester) async {
    final picker = _Picker(PlatformFile(
      name: 'retry.md', size: 0, bytes: Uint8List(0),
    ))..failure = PlatformException(code: 'secret-native-code', message: 'private/path');
    FilePicker.platform = picker;
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not import'), findsOneWidget);
    expect(find.textContaining('secret-native-code'), findsNothing);
    expect(find.textContaining('private/path'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    picker.failure = null;
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not import'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(MemoryStore(dir).list(null), ['MEMORY.md']);
    picker.file = null;
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('memory-filename')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  for (final fixture in [
    (name: 'notes.txt', bytes: <int>[65], message: 'plain .md filename'),
    (name: '../notes.md', bytes: <int>[65], message: 'plain .md filename'),
    (name: 'invalid.md', bytes: <int>[0xff], message: 'UTF-8'),
    (name: 'nul.md', bytes: <int>[65, 0], message: 'without NUL'),
    (name: 'large.md', bytes: List<int>.filled(32769, 65), message: 'exceeds 32 KiB'),
  ]) {
    testWidgets('import rejects ${fixture.name} before confirmation', (tester) async {
      FilePicker.platform = _Picker(PlatformFile(
        name: fixture.name, size: 0, // Provider metadata need not be accurate.
        bytes: Uint8List.fromList(fixture.bytes),
      ));
      await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
      await tester.runAsync(() => app.prepareMemory());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import .md'));
      await tester.pumpAndSettle();
      expect(find.textContaining(fixture.message), findsOneWidget);
      expect(find.byKey(const Key('memory-filename')), findsNothing);
      expect(MemoryStore(dir).list(null), ['MEMORY.md']);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  }

  testWidgets('path imports enforce actual byte limit and accept exactly 32 KiB', (tester) async {
    final source = File('${dir.path}/boundary.md')
      ..writeAsBytesSync(List<int>.filled(32769, 65));
    FilePicker.platform = _Picker(PlatformFile(
      name: 'boundary.md', path: source.path, size: 0,
    ));
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.runAsync(() => app.prepareMemory());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    expect(find.textContaining('exceeds 32 KiB'), findsOneWidget);
    expect(find.byKey(const Key('memory-filename')), findsNothing);
    source.writeAsStringSync('é' * 16384);
    await tester.tap(find.text('Import .md'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(MemoryStore(dir).read(null, 'boundary.md').content, 'é' * 16384);
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
  PlatformFile? file;
  bool rejectCustomFilter = false;
  PlatformException? failure;
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
  }) async {
    if (failure != null) throw failure!;
    if (rejectCustomFilter && type == FileType.custom) {
      throw PlatformException(code: 'FilePicker', message: 'Unsupported filter');
    }
    return file == null ? null : FilePickerResult([file!]);
  }
}
