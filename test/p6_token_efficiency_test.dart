import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// P6 (2026-09-13): device tools are omitted from the roster outside Control
/// mode — a smaller per-request payload, and never advertising tools that are
/// hard-denied.
void main() {
  tearDown(() => AgentService.setRunSessionForTest(''));

  int deviceCount() => AgentService.I
      .toolsForTest()
      .where(
        (t) =>
            (t['function']?['name'] as String?)?.startsWith('device_') == true,
      )
      .length;

  test('non-Control sessions carry no device_* tool schemas', () {
    final s = ChatSession(id: 'p6-auto', title: 'S', model: 'm', mode: 'auto');
    AppState.I.sessions.insert(0, s);
    AppState.I.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() {
      AppState.I.sessions.removeWhere((x) => x.id == s.id);
      AppState.I.activeSessionId = null;
    });
    expect(deviceCount(), 0);
  });

  test('Control sessions carry the device_* tool schemas', () {
    final s = ChatSession(
      id: 'p6-control',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    AppState.I.sessions.insert(0, s);
    AppState.I.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    addTearDown(() {
      AppState.I.sessions.removeWhere((x) => x.id == s.id);
      AppState.I.activeSessionId = null;
    });
    expect(deviceCount(), greaterThan(0));
  });
}
