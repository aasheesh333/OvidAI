import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
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
    await tester.tap(find.text('Delete all data'));
    await tester.pumpAndSettle();
    // The confirmation states what is and is not removed.
    expect(find.textContaining('API keys and tokens'), findsOneWidget);
    expect(find.textContaining('Not deleted:'), findsOneWidget);
    // Delete everything stays disabled until DELETE is typed (F-066).
    await tester.enterText(
      find.byKey(const ValueKey('aether-confirm-type')),
      'DELETE',
    );
    await tester.pump();
    await tester.tap(find.text('Delete everything'));
    await tester.pumpAndSettle();
    expect(find.text('Root gate'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.byType(SettingsResetScreen), findsNothing);
    expect(find.text('All data on this device was deleted.'), findsOneWidget);
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
      AgentService.I.debugPauseScheduleTimerForTest(true);
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
      AgentService.I.debugPauseScheduleTimerForTest(false);
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
      final row = find.widgetWithText(ListTile, 'Export chats');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Export and share JSON'));
        for (var i = 0; i < 20 && shared.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(shared, hasLength(1));
      expect(shared.single, contains('/ovid-chat-export-'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(jsonExports(), isEmpty);
      expect(find.textContaining('Export failed'), findsNothing);
    });
  });
}
