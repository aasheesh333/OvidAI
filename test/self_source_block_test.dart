import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.sessions
      ..clear()
      ..add(ChatSession(id: 's', title: 'S', model: 'm', mode: 'drive'));
    app.activeSessionId = 's';
    AgentService.setRunSessionForTest('s');
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
  });

  const source = '/data/data/com.dhanuk.ovidai/lib/core/agent_service.dart';

  test('every mode and tool refuses Ovid source and package files', () async {
    expect(AgentService.isOvidSelfSourcePath(source), isTrue);
    expect(
      AgentService.isOvidSelfSourcePath(
        '/data/user/0/com.dhanuk.ovidai/files/sessions/s/notes.md',
      ),
      isFalse,
    );
    for (final mode in ['auto', 'drive', 'studio', 'control']) {
      AppState.I.sessionById('s')!.mode = mode;
      for (final call in [
        ('file_read', {'path': source}),
        ('fs_edit', {'command': 'view', 'path': source}),
        ('run_shell', {'command': 'cat $source'}),
      ]) {
        final out = await AgentService.I.dispatchForTest(call.$1, call.$2);
        expect(out, contains('own application source'), reason: '$mode ${call.$1}');
        expect(AgentService.I.pendingApproval, isNull);
      }
    }
  });
}
