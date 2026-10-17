import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    Distribution.thinOverrideForTest = null;
    AgentService.collaborationLlmForTest = null;
  });

  tearDown(() {
    Distribution.thinOverrideForTest = null;
    AgentService.collaborationLlmForTest = null;
    AppState.resetTestInstance();
  });

  test(
    'thin client collab turn appends the turnTail notice and executes nothing',
    () async {
      Distribution.thinOverrideForTest = true;
      var executed = false;
      AgentService.collaborationLlmForTest = (provider, model, messages) async {
        executed = true;
        return 'this must never run on the thin client';
      };
      final app = AppState.createForTest();
      final session = app.activeSession;
      expect(session, isNotNull);
      final before = session!.messages.length;

      await expectLater(
        app.collaborationTurnForTest(
          providerId: 'any',
          model: 'any',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
        ),
        throwsA(isA<StateError>()),
      );

      expect(executed, isFalse, reason: 'no agent execution on the thin arm');
      expect(session.messages, hasLength(before + 1));
      final tail = session.messages.last;
      expect(tail.kind, MsgKind.turnTail);
      expect(tail.content, AppState.kCollaborationReadOnlyNotice);
      expect(tail.content, contains('read-only for now'));
    },
  );

  test('local arm still routes through the agent collaboration turn', () async {
    Distribution.thinOverrideForTest = false;
    var executed = false;
    AgentService.collaborationLlmForTest = (provider, model, messages) async {
      executed = true;
      return 'local reply';
    };
    final app = AppState.createForTest();
    // The local path resolves the provider first; a fake provider with no key
    // requirement lets the test seam above run.
    app.providers.add(
      ProviderConfig(
        id: 'test-provider',
        name: 'Test provider',
        description: 'test',
        baseUrl: 'https://example.invalid',
        selectedModel: 'test-model',
        custom: true,
        requiresApiKey: false,
      ),
    );

    final reply = await app.collaborationTurnForTest(
      providerId: 'test-provider',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
    );

    expect(executed, isTrue);
    expect(reply, 'local reply');
    expect(
      app.activeSession!.messages.where((m) => m.kind == MsgKind.turnTail),
      isEmpty,
    );
  });
}
