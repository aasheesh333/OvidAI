import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File recentFile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('recent_models_test_');
    recentFile = File('${tempDir.path}/recent_models.json');
    AppState.recentModelsFileOverrideForTest = recentFile;
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() async {
    AppState.recentModelsFileOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('selecting a model saves current and past selections to recent_models.json file', () async {
    final app = AppState.createForTest();
    final p = app.providers.first; // e.g. openrouter or ollama-local
    p.models = ['model-1', 'model-2', 'model-3'];

    // Select first model
    app.setModel(p.id, 'model-1');
    await app.persistRecentModels();
    expect(recentFile.existsSync(), isTrue, reason: 'recent_models.json file must be created');

    final content1 = jsonDecode(recentFile.readAsStringSync()) as Map<String, dynamic>;
    expect(content1['current']['model'], 'model-1');
    expect(content1['current']['providerId'], p.id);
    expect((content1['recent'] as List).length, 1);
    expect(content1['recent'][0]['model'], 'model-1');

    // Select second model
    app.setModel(p.id, 'model-2');
    await app.persistRecentModels();
    final content2 = jsonDecode(recentFile.readAsStringSync()) as Map<String, dynamic>;
    expect(content2['current']['model'], 'model-2');
    expect((content2['recent'] as List).length, 2);
    expect(content2['recent'][0]['model'], 'model-2');
    expect(content2['recent'][1]['model'], 'model-1');
  });

  test('AppState restores current and recent models from recent_models.json file', () async {
    // Pre-populate JSON file
    recentFile.writeAsStringSync(jsonEncode({
      'current': {'providerId': 'p1', 'model': 'saved-current-model'},
      'recent': [
        {'providerId': 'p1', 'model': 'saved-current-model'},
        {'providerId': 'p2', 'model': 'saved-past-model'},
      ],
    }));

    final app = AppState.createForTest();
    await app.initialize();

    expect(app.lastSelectedModel, 'saved-current-model');
    expect(app.lastSelectedProviderId, 'p1');
    expect(app.recentModels.length, 2);
    expect(app.recentModels[0].model, 'saved-current-model');
    expect(app.recentModels[1].model, 'saved-past-model');
  });

  testWidgets('ModelPickerSheet displays CURRENT badge and all past models in Recent section', (tester) async {
    final app = AppState.createForTest();
    // A BYOK provider: the picker's recents card hides Ovid Cloud rows until
    // the cloud catalogue is ready, and the catalogue never connects in
    // tests — so the Recent section is only reachable through a keyed
    // provider.
    final p = app.providers.firstWhere(
      (provider) => provider.id != AppState.ovidCloudProviderId,
    );
    p.models = ['gpt-4o', 'claude-sonnet-4', 'deepseek-r1'];
    p.apiKey = 'test-key';

    app.newSession();
    app.setModel(p.id, 'gpt-4o');
    app.setModel(p.id, 'claude-sonnet-4'); // now claude is current, gpt-4o is past

    // The picker is a DraggableScrollableSheet at 50% of the viewport with a
    // lazy sliver list — a tall viewport keeps the recents card mounted
    // instead of below the fold.
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: const ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Tap the header model label — the picker's trigger.
    await tester.tap(
      find.descendant(of: find.byType(AppBar), matching: find.text('claude-sonnet-4')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Should show "Recent" header
    expect(find.text('Recent'), findsOneWidget);

    // Current model has CURRENT indicator
    expect(find.text('CURRENT'), findsOneWidget);

    // Both current and past selected models are visible under Recent
    expect(find.text('claude-sonnet-4'), findsWidgets);
    expect(find.text('gpt-4o'), findsWidgets);
  });
}
