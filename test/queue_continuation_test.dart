import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Queue semantics:
///   • Stop pressed while a run is active → the next queued message starts
///     IMMEDIATELY as a new run (no manual resend).
///   • Stop NOT pressed → queued messages join the running request (drain),
///     which is covered elsewhere; here we pin the Stop path.
///
/// The old continuation was a single fire-and-forget `Future.delayed(250ms)`
/// → `runTask`. If `runTask` refused (re-entry guard, provider not ready) the
/// message had already been removed from the queue and was silently lost, so
/// the queue stalled. The continuation must retry instead of dropping.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  final app = AppState.I;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    agent.queuedRunStarterForTest = null;
    agent.dropSessionRun('q-a');
    agent.dropSessionRun('q-b');
    app.sessions.clear();
    app.activeSessionId = null;
  });

  ChatSession session(String id) {
    final s = ChatSession(id: id, title: 'T', model: 'm', mode: 'auto');
    app.sessions.add(s);
    app.activeSessionId = id;
    return s;
  }

  test('Stop with a queued message starts the next run immediately', () async {
    final s = session('q-a');
    final run = agent.runBucketForTest(s.id)
      ..activeRunId = 'run-a'
      ..queue.addAll(['second', 'third']);

    final started = <String>[];
    agent.queuedRunStarterForTest = (sessionId, text) async {
      started.add('$sessionId:$text');
    };

    // Simulate the Stop button on the running session.
    final preserved = agent.stopRequested(sessionId: s.id);
    expect(preserved, isTrue, reason: 'the queue must survive the stop');

    // The continuation is scheduled asynchronously; let it run.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      started,
      ['q-a:second'],
      reason: 'the head of the queue must start as a new run immediately',
    );
    // Only ONE message is promoted; the rest wait for that run to end.
    expect(run.queue, ['third']);
    // The promoted message is a real user row in the transcript.
    expect(s.messages.map((m) => m.content), contains('second'));
  });

  test('a continuation that cannot start yet retries instead of dropping',
      () async {
    final s = session('q-a');
    final run = agent.runBucketForTest(s.id)
      ..activeRunId = 'run-a'
      ..queue.add('only');

    var attempts = 0;
    agent.queuedRunStarterForTest = (sessionId, text) async {
      attempts++;
      // First two attempts are refused (run still unwinding / provider not
      // ready). The message must NOT be lost.
      if (attempts < 3) {
        throw StateError('run already active');
      }
    };
    AgentService.queuedContinuationRetryDelaysForTest = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ];

    agent.stopRequested(sessionId: s.id);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(attempts, greaterThanOrEqualTo(3));
    expect(run.queue, isEmpty);
    expect(
      s.messages.where((m) => m.content == 'only').length,
      1,
      reason: 'the message must be delivered exactly once',
    );
  });

  test(
      'a continuation for a deleted session is dropped with a notice, never '
      'fired into another session', () async {
    final s = session('q-a');
    agent.runBucketForTest(s.id)
      ..activeRunId = 'run-a'
      ..queue.add('orphan');

    final started = <String>[];
    agent.queuedRunStarterForTest = (sessionId, text) async {
      started.add('$sessionId:$text');
    };

    // Delete the session that owns the queue before the continuation runs.
    app.sessions.removeWhere((x) => x.id == s.id);
    final fallback = session('q-b');

    agent.stopRequested(sessionId: s.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The orphaned message must NEVER start a run in whatever session
    // happens to be active now — that would be spurious output in a
    // different chat after the response looked done.
    expect(
      started,
      isEmpty,
      reason: 'a queued message must never start in a different session',
    );
    // Instead the user sees a visible drop notice on the active session.
    expect(
      fallback.messages.map((m) => m.content),
      contains(contains('Dropped queued message')),
      reason: 'the user must see a visible drop notice',
    );
  });
}
