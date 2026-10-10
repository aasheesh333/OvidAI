import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/coordinator.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/outbox.dart' as delivery;
import 'package:ovid_ai/core/private_sync/protocol.dart' as wire;

class TimerFake implements SyncTimer {
  TimerFake(this.callback);
  final void Function() callback;
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
}

class ClockFake implements SyncClock {
  DateTime time = DateTime.utc(2026, 10, 9);
  final timers = <Duration, List<TimerFake>>{};
  int fired = 0;
  @override
  DateTime get now => time;
  @override
  SyncTimer schedule(Duration delay, void Function() callback) {
    final timer = TimerFake(callback);
    timers.putIfAbsent(delay, () => []).add(timer);
    return timer;
  }

  void fire(Duration delay) {
    for (final timer in List<TimerFake>.from(
      timers.remove(delay) ?? const [],
    )) {
      if (!timer.cancelled) timer.callback();
      fired++;
    }
  }
}

class JitterFake implements SyncJitter {
  final caps = <Duration>[];
  @override
  Duration delay(Duration cap) {
    caps.add(cap);
    return const Duration(seconds: 2);
  }
}

class PageFake implements wire.SyncChangePage {
  PageFake(this.nextCursor, {this.hasMore = false});
  @override
  final String nextCursor;
  @override
  final bool hasMore;
  @override
  final List<SyncReplayRecord> records = const [];
  @override
  Map<String, Object?> toWire() => {};
}

class StateFake implements wire.SyncStatePage {
  @override
  final String accountId = 'account-1';
  @override
  final String currentCursor = 'bootstrapped';
  @override
  final List<SyncReplayRecord> records = const [];
  @override
  final String enrollmentStatus = 'active';
  @override
  final List<String> retentionMarkers = const [];
  @override
  Map<String, Object?> toWire() => {};
}

class EntryFake implements delivery.OutboxEntry {
  @override
  final String idempotencyKey = 'key-1';
  @override
  final SyncUploadRecord envelope = SyncUploadRecord(
    recordId: 'record-1',
    sourceDeviceId: 'device-1',
    conversationId: null,
    createdAt: '2026-10-09T00:00:00Z',
    revision: 1,
    payload: TranscriptPayload(
      messageId: 'message-1',
      parentMessageId: null,
      kind: TranscriptKind.user,
      text: '',
      providerMetadataRecordId: null,
      requestPurpose: null,
      displayTitle: null,
    ),
  );
  @override
  final delivery.OutboxState state = delivery.OutboxState.pending;
  @override
  final int attempts = 0;
  @override
  final String? error = null;
}

class OutboxFake implements PrivateSyncCoordinatorOutbox {
  final pending = <delivery.OutboxEntry>[EntryFake()];
  int acknowledgements = 0;
  @override
  Future<List<delivery.OutboxEntry>> entries() async => pending;
  @override
  Future<void> acknowledge(String key) async {
    acknowledgements++;
    pending.clear();
  }

  @override
  Future<void> clearAccount() async => pending.clear();
}

class StoreFake implements PrivateSyncCoordinatorStore {
  @override
  String cursor = '0';
  final applied = <wire.SyncChangePage>[];
  int bootstraps = 0;
  int clears = 0;
  @override
  Future<void> applyPage(Object page) async {
    final typed = page as wire.SyncChangePage;
    applied.add(typed);
    cursor = typed.nextCursor;
  }

  @override
  Future<void> installState(Object page) async {
    bootstraps++;
    cursor = (page as wire.SyncStatePage).currentCursor;
  }

  @override
  Future<void> clearAccount() async {
    clears++;
    cursor = '0';
  }
}

class ClientFake implements PrivateSyncCoordinatorClient {
  final pages = <wire.SyncChangePage>[];
  int changesCalls = 0;
  int uploads = 0;
  int active = 0;
  int maxActive = 0;
  bool reset = false;
  int failures = 0;
  @override
  Future<wire.SyncBatchResult> upload(
    String key,
    List<SyncUploadRecord> records,
  ) async {
    uploads++;
    return wire.SyncBatchResult(results: const []);
  }

  @override
  Future<wire.SyncChangePage> changes({required String cursor}) async {
    changesCalls++;
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(Duration.zero);
    active--;
    if (reset) throw const SyncResetRequired();
    if (failures-- > 0) throw const SyncTransientFailure();
    return pages.isEmpty ? PageFake(cursor) : pages.removeAt(0);
  }

  @override
  Future<wire.SyncStatePage> state() async => StateFake();
}

void main() {
  late ClockFake clock;
  late JitterFake jitter;
  late ClientFake client;
  late StoreFake store;
  late OutboxFake outbox;
  late PrivateSyncCoordinator coordinator;

  setUp(() {
    clock = ClockFake();
    jitter = JitterFake();
    client = ClientFake();
    store = StoreFake();
    outbox = OutboxFake();
    coordinator = PrivateSyncCoordinator(
      client: client,
      store: store,
      outbox: outbox,
      clock: clock,
      jitter: jitter,
    );
  });
  tearDown(() => coordinator.dispose());

  test('foreground polls immediately and on the 15 second cadence', () async {
    client.pages.add(PageFake('1'));
    await coordinator.bindAccount(accountId: 'a', generation: 1);
    await coordinator.setForeground(true);
    await Future<void>.delayed(Duration.zero);
    clock.fire(const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(clock.fired, 1);
    expect(client.changesCalls, 2);
  });

  test('refresh is single-flight and drains hasMore pages', () async {
    client.pages
      ..add(PageFake('1', hasMore: true))
      ..add(PageFake('2'));
    await coordinator.bindAccount(accountId: 'a', generation: 1);
    final first = coordinator.refresh();
    final second = coordinator.refresh();
    await Future.wait([first, second]);
    expect(client.changesCalls, 2);
    expect(client.maxActive, 1);
    expect(store.cursor, '2');
  });

  test('retry is bounded jitter and stale begins after 45 seconds', () async {
    client.failures = 1;
    await coordinator.bindAccount(accountId: 'a', generation: 1);
    await coordinator.setForeground(true);
    expect(coordinator.status.retrying, isTrue);
    expect(jitter.caps, [const Duration(seconds: 2)]);
    clock.time = clock.time.add(const Duration(seconds: 45));
    expect(coordinator.status.isStale, isTrue);
  });

  test('reset bootstraps and account rebinding clears old state', () async {
    client.reset = true;
    await coordinator.bindAccount(accountId: 'a', generation: 1);
    await coordinator.setForeground(true);
    expect(store.bootstraps, 1);
    await coordinator.bindAccount(accountId: 'b', generation: 2);
    expect(store.clears, 1);
  });

  test('background and revoke stop polling and clear delivery', () async {
    await coordinator.bindAccount(accountId: 'a', generation: 1);
    await coordinator.setForeground(true);
    await coordinator.setForeground(false);
    clock.fire(const Duration(seconds: 15));
    expect(client.changesCalls, 1);
    await coordinator.revoke();
    expect(outbox.pending, isEmpty);
  });
}
