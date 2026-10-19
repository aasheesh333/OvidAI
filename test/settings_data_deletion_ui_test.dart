import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_action_widgets.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('verified reset returns to the root and says what happened', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Root gate')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Settings'))),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsResetScreen(
          reset: () async => const SettingsResetResult(
            completed: ['sessions'],
            verifiedComplete: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('API keys and tokens'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear this device'));
    await tester.pumpAndSettle();
    // The confirmation states truthfully what is and is not removed: this
    // device vs cloud account data (SE-003).
    expect(find.textContaining('API keys and tokens'), findsOneWidget);
    expect(find.textContaining('Not deleted:'), findsOneWidget);
    expect(find.textContaining('everything in Ovid Cloud'), findsOneWidget);
    expect(find.textContaining('plugins, MCP servers'), findsNothing,
        reason: 'stores that no longer exist on the device are not listed');
    // The confirm stays disabled until DELETE is typed (F-066).
    await tester.enterText(
      find.byKey(const ValueKey('aether-confirm-type')),
      'DELETE',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear this device').last);
    await tester.pumpAndSettle();
    expect(find.text('Root gate'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.byType(SettingsResetScreen), findsNothing);
    expect(find.textContaining('This device was cleared'), findsOneWidget);
  });

  testWidgets('cloud deletion is a separate account-deletion path (SE-003)', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsResetScreen(
          reset: () async => const SettingsResetResult(
            completed: ['sessions'],
            verifiedComplete: true,
          ),
          onDeleteAccount: () => opened++,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reset-delete-account')),
      200,
    );
    await tester.tap(find.byKey(const ValueKey('reset-delete-account')));
    expect(opened, 1);
  });

  group('export chats', () {
    late Directory root;
    final shared = <String>[];

    setUp(() async {
      shared.clear();
      root = await Directory.systemTemp.createTemp('export-chats-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => root.path,
      );
      messenger.setMockMethodCallHandler(const MethodChannel('ovid/native'), (
        call,
      ) async {
        if (call.method == 'shareFile') {
          final path = (call.arguments as Map)['filePath'] as String;
          // The native side copies the file before the chooser opens.
          expect(File(path).existsSync(), isTrue);
          shared.add(path);
          return true;
        }
        return null;
      });
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest();
    });

    tearDown(() async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('ovid/native'),
        null,
      );
      AppState.resetTestInstance();
      await root.delete(recursive: true);
    });

    List<String> jsonExports() => [
      for (final entity in root.listSync(recursive: true))
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith('ovid-sessions-'))
          entity.path,
    ];

    testWidgets('after export and share no plaintext copy remains', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(540, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const SettingsScreen()),
      );
      await tester.pump();
      // Export chats moved into Export data (PR-6d, F-144).
      final row = find.text('Export data');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.ensureVisible(find.text('JSON (for other tools)'));
        await tester.tap(find.text('JSON (for other tools)'));
        for (var i = 0; i < 20 && shared.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(shared, hasLength(1));
      expect(shared.single, contains('/ovid-json-'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(jsonExports(), isEmpty);
      expect(find.textContaining('Export failed'), findsNothing);
    });
  });
}
