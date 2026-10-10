import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dto.dart';
import 'protocol.dart';

typedef PrivateSyncStagedWriter =
    Future<void> Function(File file, List<int> bytes);
typedef PrivateSyncOwnerFence = FutureOr<bool> Function();
typedef PrivateSyncDirectorySync = Future<void> Function(Directory directory);

/// Durable, account-scoped typed projection of private sync replay records.
class PrivateSyncStore {
  PrivateSyncStore._({
    required this.accountRoot,
    required this.accountId,
    required this._writer,
    required this._ownerFence,
    required this._syncDirectory,
    required this._records,
    required this._tombstones,
    required this._cursor,
    required this._revision,
    required this._maxSequence,
    required this._stagingSuffix,
  });

  static const schemaVersion = 1;
  static const fileName = 'private_sync_store.json';
  static int _nextId = 0;
  static final Map<String, PrivateSyncStore> _open = {};

  final Directory accountRoot;
  String accountId;
  final PrivateSyncStagedWriter _writer;
  final PrivateSyncOwnerFence _ownerFence;
  final PrivateSyncDirectorySync _syncDirectory;
  final String _stagingSuffix;
  Map<String, SyncReplayRecord> _records;
  Map<String, int> _tombstones;
  String _cursor;
  int _revision;
  int _maxSequence;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();

  static Future<PrivateSyncStore> open({
    required Directory accountRoot,
    String? accountId,
    PrivateSyncOwnerFence ownerFence = _alwaysOwner,
    PrivateSyncStagedWriter? writeStagedFile,
    PrivateSyncDirectorySync syncDirectory = _noopSync,
  }) async {
    final key = accountRoot.absolute.path;
    final previous = _open[key];
    if (previous != null) await previous.close();
    await accountRoot.create(recursive: true);
    final file = File('${accountRoot.path}/$fileName');
    final json = await _read(file);
    final storedAccount = json?['accountId'];
    final resolvedAccount =
        accountId ?? (storedAccount is String ? storedAccount : '');
    if (storedAccount != null && storedAccount != resolvedAccount) {
      throw const FormatException('Private sync account mismatch');
    }
    final records = <String, SyncReplayRecord>{};
    final tombstones = <String, int>{};
    var cursor = '';
    var revision = 0;
    var maxSequence = 0;
    if (json != null) {
      _require(json, const {
        'schemaVersion',
        'accountId',
        'cursor',
        'revision',
        'maxSequence',
        'records',
        'tombstones',
      });
      if (json['schemaVersion'] != schemaVersion ||
          json['cursor'] is! String ||
          json['revision'] is! int ||
          json['revision'] < 0 ||
          json['maxSequence'] is! int ||
          json['maxSequence'] < 0 ||
          json['records'] is! List ||
          json['tombstones'] is! Map) {
        throw const FormatException('Malformed private sync store');
      }
      cursor = json['cursor'] as String;
      revision = json['revision'] as int;
      maxSequence = json['maxSequence'] as int;
      for (final raw in json['records'] as List) {
        final record = SyncReplayRecord.fromWire(raw);
        if (resolvedAccount.isEmpty ||
            record.accountId != resolvedAccount ||
            records.containsKey(record.recordId)) {
          throw const FormatException('Invalid private sync record');
        }
        records[record.recordId] = record;
      }
      for (final entry in (json['tombstones'] as Map).entries) {
        if (entry.key is! String || entry.value is! int || entry.value < 1) {
          throw const FormatException('Malformed private sync tombstone');
        }
        tombstones[entry.key as String] = entry.value as int;
      }
    }
    final store = PrivateSyncStore._(
      accountRoot: accountRoot,
      accountId: resolvedAccount,
      writer: writeStagedFile ?? _defaultWriter,
      ownerFence: ownerFence,
      syncDirectory: syncDirectory,
      records: records,
      tombstones: tombstones,
      cursor: cursor,
      revision: revision,
      maxSequence: maxSequence,
      stagingSuffix: '${DateTime.now().microsecondsSinceEpoch}-${++_nextId}',
    );
    _open[key] = store;
    return store;
  }

  String get cursor => _cursor;
  int get revision => _revision;
  List<SyncReplayRecord> get records => List.unmodifiable(_records.values);
  Set<String> get tombstones => Set.unmodifiable(_tombstones.keys);

  Future<void> applyPage(Object page) => _enqueue(() async {
    _checkOpen();
    final account = _pageAccount(page);
    final incoming = _pageRecords(page);
    final nextCursor = _pageCursor(page);
    if (accountId.isEmpty) accountId = account;
    if (account != accountId) {
      throw const FormatException('Private sync account mismatch');
    }
    _validatePage(incoming);
    final pageSequence = incoming.fold<int>(
      0,
      (max, item) => item.changeSequence > max ? item.changeSequence : max,
    );
    if (pageSequence < _maxSequence) {
      throw StateError('Private sync sequence regression');
    }
    final nextRecords = Map<String, SyncReplayRecord>.of(_records);
    final nextTombstones = Map<String, int>.of(_tombstones);
    var changed = false;
    for (final item in incoming) {
      final payload = item.payload;
      if (payload is TombstonePayload) {
        final old = nextTombstones[payload.targetRecordId] ?? 0;
        if (payload.deletionRevision > old) {
          nextTombstones[payload.targetRecordId] = payload.deletionRevision;
          changed = true;
        }
        final existing = nextRecords[payload.targetRecordId];
        if (existing != null &&
            existing.record.revision <= payload.deletionRevision) {
          nextRecords.remove(payload.targetRecordId);
          changed = true;
        }
        continue;
      }
      final blocked = nextTombstones[item.recordId];
      if (blocked != null) continue;
      final existing = nextRecords[item.recordId];
      if (existing != null) {
        if (item.record.revision < existing.record.revision) continue;
        if (item.record.revision == existing.record.revision) {
          if (item != existing) {
            throw StateError('Conflicting private sync revision');
          }
          continue;
        }
      }
      nextRecords[item.recordId] = item;
      changed = true;
    }
    final nextRevision = _revision + (changed ? 1 : 0);
    final nextSequence = pageSequence > _maxSequence
        ? pageSequence
        : _maxSequence;
    await _commit(
      nextRecords,
      nextTombstones,
      nextCursor,
      nextRevision,
      nextSequence,
    );
    _records = nextRecords;
    _tombstones = nextTombstones;
    _cursor = nextCursor;
    _revision = nextRevision;
    _maxSequence = nextSequence;
  });

  Future<void> installState(Object state) => _enqueue(() async {
    _checkOpen();
    final account = _pageAccount(state);
    final incoming = _pageRecords(state);
    final nextCursor = _pageCursor(state);
    if (accountId.isEmpty) accountId = account;
    if (account != accountId) {
      throw const FormatException('Private sync account mismatch');
    }
    _validatePage(incoming);
    final nextRecords = <String, SyncReplayRecord>{};
    final nextTombstones = <String, int>{};
    for (final item in incoming) {
      if (item.payload case final TombstonePayload tombstone) {
        nextTombstones[tombstone.targetRecordId] = tombstone.deletionRevision;
      } else if (!nextTombstones.containsKey(item.recordId)) {
        nextRecords[item.recordId] = item;
      }
    }
    final nextRevision = _revision + 1;
    final nextSequence = incoming.fold<int>(
      0,
      (max, item) => item.changeSequence > max ? item.changeSequence : max,
    );
    await _commit(
      nextRecords,
      nextTombstones,
      nextCursor,
      nextRevision,
      nextSequence,
    );
    _records = nextRecords;
    _tombstones = nextTombstones;
    _cursor = nextCursor;
    _revision = nextRevision;
    _maxSequence = nextSequence;
  });

  Future<void> clearAccount() => _enqueue(() async {
    _checkOpen();
    if (!await _ownerFence()) {
      throw StateError('Stale private sync account owner');
    }
    await _commit({}, {}, '', _revision + 1, 0);
    _records = {};
    _tombstones = {};
    _cursor = '';
    _revision++;
    _maxSequence = 0;
  });

  Future<void> close() async {
    await _tail;
    _closed = true;
    if (identical(_open[accountRoot.absolute.path], this)) {
      _open.remove(accountRoot.absolute.path);
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _commit(
    Map<String, SyncReplayRecord> records,
    Map<String, int> tombstones,
    String cursor,
    int revision,
    int maxSequence,
  ) async {
    if (!await _ownerFence()) {
      throw StateError('Stale private sync account owner');
    }
    final bytes = utf8.encode(
      jsonEncode({
        'schemaVersion': schemaVersion,
        'accountId': accountId,
        'cursor': cursor,
        'revision': revision,
        'maxSequence': maxSequence,
        'records': records.values.map((e) => e.toWire()).toList(),
        'tombstones': tombstones,
      }),
    );
    final target = File('${accountRoot.path}/$fileName');
    final temp = File('${target.path}.tmp.$_stagingSuffix');
    try {
      await _writer(temp, bytes);
      if (_closed || !await _ownerFence()) {
        throw StateError('Stale private sync account owner');
      }
      await temp.rename(target.path);
      await _syncDirectory(accountRoot);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Private sync store is closed');
  }

  static void _validatePage(List<SyncReplayRecord> records) {
    final ids = <String>{};
    for (final item in records) {
      if (!ids.add(item.recordId)) {
        throw const FormatException('Duplicate private sync page record');
      }
    }
  }

  static String _pageAccount(Object page) {
    final value = _field(page, 'accountId');
    if (value is String) return value;
    final records = _pageRecords(page);
    if (records.isEmpty) {
      throw const FormatException('Page account ID is required');
    }
    return records.first.accountId;
  }

  static String _pageCursor(Object page) {
    if (page is SyncChangePage) return page.nextCursor;
    if (page is SyncStatePage) return page.currentCursor;
    final value =
        _field(page, 'cursor') ??
        _field(page, 'nextCursor') ??
        _field(page, 'next_cursor') ??
        _field(page, 'currentCursor');
    if (value is! String) {
      throw const FormatException('Page cursor is required');
    }
    return value;
  }

  static List<SyncReplayRecord> _pageRecords(Object page) {
    if (page is SyncChangePage) return page.records;
    if (page is SyncStatePage) return page.records;
    final raw =
        _field(page, 'records') ??
        _field(page, 'changes') ??
        _field(page, 'items');
    if (raw is! Iterable) {
      throw const FormatException('Page records are required');
    }
    return raw
        .map(
          (item) =>
              item is SyncReplayRecord ? item : SyncReplayRecord.fromWire(item),
        )
        .toList();
  }

  static Object? _field(Object object, String name) {
    if (object is Map) return object[name];
    try {
      return switch (name) {
        'accountId' => (object as dynamic).accountId,
        'cursor' => (object as dynamic).cursor,
        'nextCursor' => (object as dynamic).nextCursor,
        'next_cursor' => (object as dynamic).next_cursor,
        'currentCursor' => (object as dynamic).currentCursor,
        'records' => (object as dynamic).records,
        'changes' => (object as dynamic).changes,
        'items' => (object as dynamic).items,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _read(File file) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) {
        throw const FormatException('Private sync store must be an object');
      }
      return Map<String, dynamic>.from(value);
    } catch (error) {
      if (error is FormatException) rethrow;
      throw FormatException('Malformed private sync store: $error');
    }
  }

  static void _require(Map<String, dynamic> value, Set<String> required) {
    if (value.length != required.length ||
        !value.keys.every(required.contains)) {
      throw const FormatException(
        'Unexpected or missing private sync store fields',
      );
    }
  }

  static Future<void> _defaultWriter(File file, List<int> bytes) =>
      file.writeAsBytes(bytes, flush: true);
  static Future<bool> _alwaysOwner() async => true;
  static Future<void> _noopSync(Directory _) async {}
}
