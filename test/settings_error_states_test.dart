import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/settings_screen.dart';

class _ThrowingPicker extends FilePicker {
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
  }) async =>
      throw PlatformException(code: 'unknown_path', message: 'no picker');
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l = appLocalizationsFallback;
  late Directory root;

  void mockPaths(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, handler);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('settings-errors-');
    mockPaths((_) async => root.path);
  });

  tearDown(() async {
    refreshSkillsForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await root.delete(recursive: true);
  });

  void expectNoRawText() {
    for (final raw in ['Bad state', 'Exception', 'StateError']) {
      expect(find.textContaining(raw), findsNothing, reason: raw);
    }
  }

  testWidgets('refreshSkills throwing shows an error with Retry', (
    tester,
  ) async {
    var calls = 0;
    refreshSkillsForTest = () async {
      calls++;
      if (calls == 1) throw StateError('skills index locked');
    };
    await tester.pumpWidget(const MaterialApp(home: SkillsScreen()));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining(l.skillsLoadFailed), findsOneWidget);
    expectNoRawText();
    await tester.tap(find.text(l.actionRetry));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text(l.actionRetry), findsNothing);
    expect(find.textContaining(l.skillsLoadFailed), findsNothing);
  });

  testWidgets('skill upload picker failure reports instead of crashing', (
    tester,
  ) async {
    FilePicker.platform = _ThrowingPicker();
    refreshSkillsForTest = () async {};
    await tester.pumpWidget(const MaterialApp(home: SkillsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Upload .md skill'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(l.skillsUploadFailed(l.errorDevice)), findsOneWidget);
    expectNoRawText();
  });

  testWidgets('storage measurement failure shows — and Retry, not 0 B', (
    tester,
  ) async {
    mockPaths((_) async => throw PlatformException(code: 'no_dir'));
    await tester.pumpWidget(MaterialApp(home: storageScreenForTest()));
    await tester.pumpAndSettle();
    expect(find.text(l.storageMeasureFailed), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
    expect(find.text(l.storageSizeUnknown), findsNWidgets(4));
    expectNoRawText();

    mockPaths((_) async => root.path);
    await tester.tap(find.text(l.actionRetry));
    await tester.pump();
    // Directory sizing is real file IO; let it finish outside fake async.
    for (
      var i = 0;
      i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text(l.storageMeasureFailed), findsNothing);
    expect(find.text(l.storageSizeUnknown), findsNothing);
  });

  group('cookie clear copy', () {
    test('full success is one plain sentence', () {
      final message = cookieClearMessage(
        l,
        profiles: 3,
        cleared: 3,
        profilesSupported: true,
      );
      expect(message, 'Signed out of websites in the in-app browser.');
    });

    test('unsupported profiles share the default jar, so no partial', () {
      expect(
        cookieClearMessage(
          l,
          profiles: 3,
          cleared: 0,
          profilesSupported: false,
        ),
        l.storageCookiesCleared,
      );
    });

    test('partial variant only when some profiles failed', () {
      final message = cookieClearMessage(
        l,
        profiles: 3,
        cleared: 1,
        profilesSupported: true,
      );
      expect(message, contains('2 chat browser profiles'));
      expect(message, isNot(contains('jar')));
      expect(message, isNot(contains('cannot be verified')));
    });
  });
}
