import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/l10n/l10n.dart';
import 'package:ovid_ai/ui/settings_screen.dart';

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await root.delete(recursive: true);
  });

  void expectNoRawText() {
    for (final raw in ['Bad state', 'Exception', 'StateError']) {
      expect(find.textContaining(raw), findsNothing, reason: raw);
    }
  }

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

}
