import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/client.dart' as client;
import 'package:ovid_ai/core/collaboration/coordinator.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/store.dart';

void main() {
  late FakeScheduler scheduler;
  late FakeClient transport;
  late CollaborationStore store;
  late CollaborationCoordinator coordinator;
  late double random;

  setUp(() {
    scheduler = FakeScheduler();
    transport = FakeClient();
    store = CollaborationStore(MemoryCollaborationStoreBackend(), ownerFence: 'a');
    random = 1;
    coordinator = CollaborationCoordinator(
      client: transport,
      store: store,
      accountId: 'a',
      sessionToken: 'route-a',
      scheduler: scheduler,
      random: () => random,
    );
  });

  tearDown(() => coordinator.dispose());

  test('uncommitted gap keeps transport cursor and retries the missing history', () async {
    coordinator.start();
    await flush();
    transport.replayResult = (_, _) async => page(sequence: 3, text: 'gap');
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    expect(coordinator.cursor!.value, 'cursor-1');
    expect(store.cursor, 1);
    expect(coordinator.isStale, isTrue);
    transport.replayResult = (_, _) async => client.CollaborationEventPage(
      events: [...page(sequence: 2, text: 'missing').events, ...page(sequence: 3, text: 'gap').events],
      nextCursor: const client.CollaborationCursor('cursor-3'), hasMore: false);
    scheduler.advance(const Duration(seconds: 2));
    await flush();
    expect(coordinator.cursor!.value, 'cursor-3');
    expect(store.state!.messages.map((m) => m.text), ['hello', 'missing', 'gap']);
  });

  test('failed initial state retries bootstrap before replay', () async {
    var offline = true;
    transport.stateResult = (_) async {
      if (offline) throw StateError('offline');
      return bootstrap('session-a');
    };
    coordinator.start();
    await flush();
    offline = false;
    scheduler.advance(const Duration(seconds: 2));
    await flush();
    expect(transport.stateCalls, 2);
    expect(store.state!.messages.single.text, 'hello');
    expect(transport.cursors, ['bootstrap-cursor']);
  });

  for (final code in ['not_member', 'session_closed']) {
    test('terminal $code during bootstrap fences store and stops retries', () async {
      coordinator.start();
      await flush();
      transport.stateResult = (_) async => throw client.CollaborationClientException(
        'fixed', statusCode: code == 'not_member' ? 403 : 409, code: code);
      coordinator.bind(accountId: 'a', sessionToken: 'route-a', store: store);
      await flush();
      scheduler.advance(const Duration(minutes: 5));
      await flush();
      expect(store.state, isNull);
      expect(coordinator.cursor, isNull);
      expect(scheduler.activeCount, 0);
    });
  }

  test('closed session during poll stops and clears stale read projection', () async {
    coordinator.start();
    await flush();
    transport.replayResult = (_, _) async => throw const client.CollaborationClientException(
      'closed', statusCode: 409, code: 'session_closed');
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    expect(store.state, isNull);
    expect(coordinator.cursor, isNull);
    expect(scheduler.activeCount, 0);
  });

  test('bootstraps real store and polls every 15 seconds without overlap', () async {
    coordinator.start();
    await flush();
    expect(store.state!.session.sessionId, 'session-a');
    expect(store.state!.messages.single.text, 'hello');
    expect(transport.cursors, ['bootstrap-cursor']);
    scheduler.advance(const Duration(seconds: 14));
    await flush();
    expect(transport.cursors, ['bootstrap-cursor']);
    scheduler.advance(const Duration(seconds: 1));
    await flush();
    expect(transport.cursors, ['bootstrap-cursor', 'cursor-1']);
    expect(coordinator.isStale, isFalse);
  });

  test('hung poll becomes stale at 45s and successful recovery clears stale', () async {
    coordinator.start();
    await flush();
    final pending = Completer<client.CollaborationEventPage>();
    transport.replayResult = (_, _) => pending.future;
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    scheduler.advance(const Duration(seconds: 29));
    expect(coordinator.isStale, isFalse);
    scheduler.advance(const Duration(seconds: 1));
    expect(coordinator.isStale, isTrue);
    pending.complete(page());
    await flush();
    expect(coordinator.isStale, isFalse);
    expect(transport.cursors.length, 2);
  });

  test('failed replay retries with bounded exponential jitter and resets on success', () async {
    transport.replayResult = (_, _) async => throw StateError('offline');
    coordinator.start();
    await flush();
    expect(coordinator.isStale, isTrue);
    expect(coordinator.reconnectDelay, const Duration(seconds: 2));
    for (final seconds in [2, 4, 8, 16, 32, 60]) {
      expect(coordinator.reconnectDelay, Duration(seconds: seconds));
      scheduler.advance(Duration(seconds: seconds));
      await flush();
    }
    expect(coordinator.reconnectDelay, const Duration(seconds: 60));
    random = 0;
    scheduler.advance(const Duration(seconds: 60));
    await flush();
    expect(coordinator.reconnectDelay, const Duration(seconds: 2));
    transport.replayResult = (_, _) async => page();
    scheduler.advance(const Duration(seconds: 2));
    await flush();
    expect(coordinator.isStale, isFalse);
    expect(coordinator.reconnectDelay, isNull);
    expect(store.state!.messages.single.text, 'hello');
  });

  test('cursor reset bootstraps then replays from the beginning', () async {
    coordinator.start();
    await flush();
    var reset = true;
    transport.replayResult = (_, cursor) async {
      if (reset) {
        reset = false;
        throw const client.CollaborationClientException('reset', statusCode: 410);
      }
      return page();
    };
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    expect(transport.stateCalls, 2);
    expect(transport.cursors, ['bootstrap-cursor', 'cursor-1', 'bootstrap-cursor']);
    expect(store.state!.messages.single.text, 'hello');
    expect(coordinator.cursor!.value, 'cursor-1');
  });

  test('failed bootstrap after cursor reset retries state before replay', () async {
    coordinator.start();
    await flush();
    transport.replayResult = (_, _) async => throw const client.CollaborationClientException(
      'reset', statusCode: 410, code: 'cursor_reset');
    transport.stateResult = (_) async => throw StateError('offline');
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    transport.stateResult = (_) async => bootstrap('session-a');
    transport.replayResult = (_, _) async => page();
    scheduler.advance(const Duration(seconds: 2));
    await flush();
    expect(transport.stateCalls, 3);
    expect(transport.cursors.last, 'bootstrap-cursor');
  });

  for (final switchAccount in [false, true]) {
    test('late replay fenced by ${switchAccount ? 'account' : 'session'} replacement', () async {
      coordinator.start();
      await flush();
      final pending = Completer<client.CollaborationEventPage>();
      transport.replayResult = (token, _) => token == 'route-a'
          ? pending.future : Future.value(page(session: 'session-b'));
      scheduler.advance(const Duration(seconds: 15));
      await flush();
      final nextStore = switchAccount
          ? CollaborationStore(MemoryCollaborationStoreBackend(), ownerFence: 'b')
          : store;
      coordinator.bind(
        accountId: switchAccount ? 'b' : 'a',
        sessionToken: 'route-b',
        store: nextStore,
      );
      await flush();
      pending.complete(page(sequence: 2, text: 'old result'));
      await flush();
      expect(nextStore.state!.session.sessionId, 'session-b');
      expect(nextStore.state!.messages.map((m) => m.text), ['hello']);
      expect(coordinator.cursor!.value, 'cursor-1');
    });
  }

  test('dispose fences late bootstrap and cancels all polling timers', () async {
    final pending = Completer<client.CollaborationState>();
    transport.stateResult = (_) => pending.future;
    coordinator.start();
    coordinator.dispose();
    pending.complete(bootstrap('session-a'));
    await flush();
    scheduler.advance(const Duration(minutes: 5));
    await flush();
    expect(store.state, isNull);
    expect(transport.cursors, isEmpty);
    expect(scheduler.activeCount, 0);
  });

  test('drains only a bounded number of pages per cadence', () async {
    transport.replayResult = (_, _) async => page(hasMore: true);
    coordinator.start();
    await flush();
    expect(transport.cursors.length, 4);
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    expect(transport.cursors.length, 8);
  });

  test('revoked membership stops polling and fences the projection', () async {
    coordinator.start();
    await flush();
    transport.replayResult = (_, _) async =>
        throw const client.CollaborationClientException('revoked', statusCode: 403, code: 'membership_revoked');
    scheduler.advance(const Duration(seconds: 15));
    await flush();
    scheduler.advance(const Duration(minutes: 5));
    await flush();
    expect(store.state, isNull);
    expect(transport.cursors.length, 2);
    expect(scheduler.activeCount, 0);
  });
}

client.CollaborationState bootstrap(String session) => client.CollaborationState(
  session: CollaborationSession(sessionId: session, ownerParticipantId: 'owner', lifecycle: SessionLifecycle.active),
  member: const Member(participantId: 'owner', role: MemberRole.owner, status: MemberStatus.active),
  members: const [Member(participantId: 'owner', role: MemberRole.owner, status: MemberStatus.active)],
  cursor: const client.CollaborationCursor('bootstrap-cursor'),
);

client.CollaborationEventPage page({String session = 'session-a', int sequence = 1, String text = 'hello', bool hasMore = false}) =>
    client.CollaborationEventPage(
      events: [CollaborationEvent.fromWire({
        'schemaVersion': 1, 'eventId': 'event-$sequence', 'sessionId': session,
        'eventSequence': sequence, 'senderParticipantId': 'owner', 'kind': 'message',
        'createdAt': '2026-10-09T00:00:00Z', 'payload': {'text': text},
      })],
      nextCursor: client.CollaborationCursor('cursor-$sequence'), hasMore: hasMore,
    );

class FakeClient extends client.CollaborationClient {
  FakeClient() : super(baseUri: Uri.parse('https://unused.invalid'), accessToken: () async => null, appCheckToken: () async => null);
  final cursors = <String?>[];
  int stateCalls = 0;
  Future<client.CollaborationState> Function(String) stateResult =
      (token) async => bootstrap(token == 'route-a' ? 'session-a' : 'session-b');
  Future<client.CollaborationEventPage> Function(String, client.CollaborationCursor?) replayResult =
      (_, _) async => page();
  @override
  Future<client.CollaborationState> state(String sessionToken) {
    stateCalls++;
    return stateResult(sessionToken);
  }
  @override
  Future<client.CollaborationEventPage> replay(String sessionToken, {client.CollaborationCursor? cursor}) {
    cursors.add(cursor?.value);
    return replayResult(sessionToken, cursor);
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

class FakeScheduler implements CollaborationTimerScheduler {
  final _timers = <FakeTimer>[];
  Duration elapsed = Duration.zero;
  int get activeCount => _timers.where((t) => !t.cancelled).length;
  @override
  CollaborationTimer schedule(Duration delay, void Function() callback) {
    final timer = FakeTimer(elapsed + delay, callback);
    _timers.add(timer);
    return timer;
  }
  void advance(Duration duration) {
    elapsed += duration;
    for (final timer in List.of(_timers)) {
      if (!timer.cancelled && timer.fireAt <= elapsed) {
        timer.cancelled = true;
        timer.callback();
      }
    }
    _timers.removeWhere((timer) => timer.cancelled);
  }
}

class FakeTimer implements CollaborationTimer {
  FakeTimer(this.fireAt, this.callback);
  final Duration fireAt;
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}
