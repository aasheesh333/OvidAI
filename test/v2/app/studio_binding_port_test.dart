import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_work_routes.dart';

/// The Studio binding writes the chosen repo/branch onto the session, which is
/// what the agent tools read; signed out it must never claim to be ready.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
  });

  tearDown(() {
    StudioBindingPort.instance?.dispose();
    StudioBindingPort.installForTest(null);
    AppState.resetTestInstance();
  });

  test('signed out, the port is not ready and binds nothing', () {
    final port = GitHubStudioBindingPort();
    StudioBindingPort.installForTest(port);

    expect(port.ready, isFalse);
    expect(port.bindingFor('session-1'), isNull);
  });

  test('bind persists the repo and branch for that session', () async {
    final session = ChatSession(
      id: 'studio-session',
      title: 'Studio',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;

    final port = GitHubStudioBindingPort();
    await port.bind(session.id, repo: 'ovid/app', branch: 'feature/x');

    expect(session.repo, 'ovid/app');
    expect(session.branch, 'feature/x');
    final binding = port.bindingFor(session.id);
    expect(binding?.repo, 'ovid/app');
    expect(binding?.branch, 'feature/x');
    expect(binding?.ready, isTrue);
  });
}
