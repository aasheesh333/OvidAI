import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/reset_coordinator.dart';

/// In-memory stand-in for an app store. It records whether the coordinator
/// destroyed data before commit and lets a test make a single store fail.
class _FakeStore implements ResetStore {
  _FakeStore(this.name, {List<String>? data})
    : data = List.of(data ?? const ['user data']);

  @override
  final String name;

  List<String> data;
  bool failStage = false;
  bool failDelete = false;
  bool failVerify = false;
  bool verifyThrows = false;
  bool restoreCalled = false;
  int deleteCalls = 0;
  int verifyCalls = 0;

  List<String>? _snapshot;

  @override
  Future<void> stage() async {
    if (failStage) throw StateError('$name stage failed');
    _snapshot = List.of(data);
  }

  @override
  Future<void> delete() async {
    deleteCalls++;
    if (failDelete) throw StateError('$name delete failed');
    data = [];
  }

  @override
  Future<bool> verifyDeleted() async {
    verifyCalls++;
    if (verifyThrows) throw StateError('$name verify failed');
    if (failVerify) return false;
    return data.isEmpty;
  }

  @override
  Future<void> restore() async {
    restoreCalled = true;
    final snapshot = _snapshot;
    if (snapshot != null) data = List.of(snapshot);
  }
}

void main() {
  test(
    'successful reset deletes and verifies every enumerated store',
    () async {
      final stores = [
        _FakeStore('sessions'),
        _FakeStore('search'),
        _FakeStore('memory'),
      ];
      final coordinator = ResetCoordinator(stores);

      await coordinator.prepare();
      final report = await coordinator.commit();

      expect(report.success, isTrue);
      expect(report.verifiedComplete, isTrue);
      expect(report.failures, isEmpty);
      expect(report.completed, ['sessions', 'search', 'memory']);
      expect(report.stores.map((s) => s.name), [
        'sessions',
        'search',
        'memory',
      ]);
      expect(stores.every((s) => s.data.isEmpty), isTrue);
      expect(stores.every((s) => s.deleteCalls == 1), isTrue);
      expect(stores.every((s) => s.verifyCalls == 1), isTrue);
    },
  );

  test(
    'partial failure is reported per store, never a silent success',
    () async {
      final failing = _FakeStore('search')..failDelete = true;
      final stores = [_FakeStore('sessions'), failing, _FakeStore('memory')];
      final coordinator = ResetCoordinator(stores);

      await coordinator.prepare();
      final report = await coordinator.commit();

      expect(report.success, isFalse);
      expect(report.verifiedComplete, isFalse);
      expect(report.failures.map((s) => s.name), ['search']);
      expect(report.errors['search'], contains('delete failed'));
      expect(failing.data, isNotEmpty);
      // A failed store does not stop the coordinator from truthfully resetting
      // the stores that do succeed.
      expect(report.completed, ['sessions', 'memory']);
      expect(
        report.stores.singleWhere((s) => s.name == 'search').deleted,
        isFalse,
      );
      expect(
        report.stores.singleWhere((s) => s.name == 'search').verified,
        isFalse,
      );
    },
  );

  test(
    'readback failure blocks success even when delete throws no error',
    () async {
      final lingering = _FakeStore('ledger')..failVerify = true;
      final coordinator = ResetCoordinator([_FakeStore('sessions'), lingering]);

      await coordinator.prepare();
      final report = await coordinator.commit();

      expect(report.success, isFalse);
      final row = report.stores.singleWhere((s) => s.name == 'ledger');
      expect(row.deleted, isTrue);
      expect(row.verified, isFalse);
      expect(row.error, isNotNull);
    },
  );

  test('readback that throws is reported as a failure, not success', () async {
    final broken = _FakeStore('image-receipts')..verifyThrows = true;
    final coordinator = ResetCoordinator([broken]);

    await coordinator.prepare();
    final report = await coordinator.commit();

    expect(report.success, isFalse);
    expect(report.errors['image-receipts'], contains('readback failed'));
  });

  test(
    'no data is destroyed before commit; abort leaves stores intact',
    () async {
      final stores = [_FakeStore('sessions'), _FakeStore('memory')];
      final coordinator = ResetCoordinator(stores);

      await coordinator.prepare();
      expect(stores.every((s) => s.data.isNotEmpty), isTrue);
      expect(stores.every((s) => s.deleteCalls == 0), isTrue);

      await coordinator.abort();
      expect(stores.every((s) => s.data.isNotEmpty), isTrue);
      expect(stores.every((s) => s.restoreCalled), isTrue);
      expect(stores.every((s) => s.deleteCalls == 0), isTrue);

      await expectLater(coordinator.commit(), throwsStateError);
    },
  );

  test(
    'a failed prepare restores already-staged stores and never deletes',
    () async {
      final first = _FakeStore('sessions');
      final bad = _FakeStore('memory')..failStage = true;
      final coordinator = ResetCoordinator([first, bad]);

      await expectLater(coordinator.prepare(), throwsStateError);

      expect(first.restoreCalled, isTrue);
      expect(first.data, isNotEmpty);
      expect(first.deleteCalls, 0);
      expect(bad.deleteCalls, 0);
    },
  );

  test('commit and abort both require a prepared plan', () async {
    final coordinator = ResetCoordinator([_FakeStore('sessions')]);
    await expectLater(coordinator.commit(), throwsStateError);
    await expectLater(coordinator.abort(), throwsStateError);
  });

  test('a plan cannot be committed twice', () async {
    final coordinator = ResetCoordinator([_FakeStore('sessions')]);
    await coordinator.prepare();
    await coordinator.commit();
    await expectLater(coordinator.commit(), throwsStateError);
    await expectLater(coordinator.abort(), throwsStateError);
  });

  test('empty or duplicate store enumeration is rejected', () {
    expect(() => ResetCoordinator(const []), throwsArgumentError);
    expect(
      () => ResetCoordinator([_FakeStore('memory'), _FakeStore('memory')]),
      throwsArgumentError,
    );
  });

  test('report maps onto the SettingsActions reset contract', () async {
    final coordinator = ResetCoordinator([
      _FakeStore('sessions'),
      _FakeStore('search')..failDelete = true,
    ]);
    await coordinator.prepare();
    final result = (await coordinator.commit()).toSettingsResult();

    expect(result.success, isFalse);
    expect(result.verifiedComplete, isFalse);
    expect(result.completed, ['sessions']);
    expect(result.failures.keys, ['search']);
  });

  test(
    'canonical enumeration includes the usage participant in order',
    () async {
      final stores = <ResetStoreKind, ResetStore>{
        for (final kind in ResetStoreKind.values) kind: _FakeStore(kind.id),
      };
      final coordinator = ResetCoordinator.canonical(stores);

      await coordinator.prepare();
      final report = await coordinator.commit();

      expect(report.stores.map((store) => store.name), [
        'sessions',
        'search',
        'ledger',
        'memory',
        'usage',
        'account',
        'image-receipts',
        'shares',
      ]);
      expect(report.success, isTrue);
    },
  );
}
