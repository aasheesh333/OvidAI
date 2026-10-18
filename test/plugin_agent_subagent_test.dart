import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';

/// Claude Code AGENT parity (audit 2026-09-25).
///
/// A plugin `agents/*.md` contribution is a SUBAGENT definition — its own
/// system prompt, its own model, its own tool allowlist, run in an isolated
/// context. Ovid used to inline it into the parent as prompt text (identical to
/// a command/skill), so the declared `model` was ignored and the agent shared
/// the parent's context and tools. It is now dispatched as a real subagent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
  });

  tearDown(AppState.resetTestInstance);

  group('createSubagentSession honours an agent model pin', () {
    test('a non-empty model override wins', () {
      final app = AppState.I;
      final parent = ChatSession(
        id: 'p', title: 'P', model: 'parent-model', mode: 'auto',
      );
      app.sessions.insert(0, parent);
      final child = app.createSubagentSession(
        parent: parent,
        label: 'reviewer',
        mode: 'auto',
        model: 'claude-agent-model',
      );
      expect(child.model, 'claude-agent-model');
    });

    test('an absent or blank model inherits the parent', () {
      final app = AppState.I;
      final parent = ChatSession(
        id: 'p2', title: 'P', model: 'parent-model', mode: 'auto',
      );
      app.sessions.insert(0, parent);
      expect(
        app.createSubagentSession(parent: parent, label: 'a', mode: 'auto')
            .model,
        'parent-model',
      );
      expect(
        app
            .createSubagentSession(
              parent: parent, label: 'b', mode: 'auto', model: '  ',
            )
            .model,
        'parent-model',
      );
    });
  });
}
