import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'usage_attempt.dart';

typedef UsageAttemptStagedWriter = Future<void> Function(File file, List<int> bytes);
typedef UsageAttemptOwnerFence = FutureOr<bool> Function();
typedef UsageAttemptDirectorySync = Future<void> Function(Directory directory);

/// Durable, account-scoped journal for local model attempts.
class UsageAttemptStore {
  UsageAttemptStore._({
    required this.accountRoot,
    required this.terminalHistoryLimit,
    required this.maxJournalBytes,
    required UsageAttemptStagedWriter writeStagedFile,
    required List<UsageAttempt> records,
    required int revision,
    required bool historyTruncated,
    required Map<String, int> tombstones,
    required Set<String> migrationMarkers,
    required UsageAttemptOwnerFence ownerFence,
    required UsageAttemptDirectorySync syncDirectory,
  })  : _writeStagedFile = writeStagedFile,
        _records = records,
        _revision = revision,
        _historyTruncated = historyTruncated,
        _tombstones = tombstones,
        _migrationMarkers = migrationMarkers,
        _ownerFence = ownerFence,
        _syncDirectory = syncDirectory;

  static const schemaVersion = 1;
  static const journalFileName = 'usage_attempts.json';

  final Directory accountRoot;
  final int terminalHistoryLimit;
  final int maxJournalBytes;
  final UsageAttemptStagedWriter _writeStagedFile;
  List<UsageAttempt> _records;
  int _revision;
  bool _historyTruncated;
  Map<String, int> _tombstones;
  Set<String> _migrationMarkers;
  final UsageAttemptOwnerFence _ownerFence;
  final UsageAttemptDirectorySync _syncDirectory;
  Future<void> _tail = Future<void>.value();

  static Future<UsageAttemptStore> open({
    required Directory accountRoot,
    int terminalHistoryLimit = 500,
    int maxJournalBytes = 1024 * 1024,
    UsageAttemptStagedWriter? writeStagedFile,
    UsageAttemptOwnerFence ownerFence = _alwaysOwner,
    UsageAttemptDirectorySync syncDirectory = _bestEffortDirectorySync,
  }) async {
    if (terminalHistoryLimit < 0 || maxJournalBytes < 1) {
      throw ArgumentError('Invalid journal limits');
    }
    await accountRoot.create(recursive: true);
    final file = File('${accountRoot.path}/$journalFileName');
    var records = <UsageAttempt>[];
    var revision = 0;
    var truncated = false;
    if (await file.exists()) {
      final bytes = await _readCapped(file, maxJournalBytes);
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map) throw const FormatException('Journal must be an object');
        final json = Map<String, dynamic>.from(decoded);
        _requireKeys(json, const {'schemaVersion', 'revision', 'historyTruncated', 'attempts'},
            optional: const {'tombstones', 'migrationMarkers'});
        if (json['schemaVersion'] is! int || json['schemaVersion'] != schemaVersion ||
            (json['revision'] as int) < 0 || json['historyTruncated'] is! bool ||
            json['attempts'] is! List) throw const FormatException('Malformed journal metadata');
        revision = json['revision'] as int;
        truncated = json['historyTruncated'] as bool;
        final tombstones = json['tombstones'];
        if (tombstones != null && tombstones is! Map) throw const FormatException('Malformed tombstones');
        final markers = json['migrationMarkers'];
        if (markers != null &&
            (markers is! List || !markers.every((item) => item is String))) {
          throw const FormatException('Malformed migration markers');
        }
        for (final value in json['attempts'] as List) {
          if (value is! Map) throw const FormatException('Malformed attempt');
          final record = UsageAttempt.fromJson(Map<String, dynamic>.from(value));
          if (records.any((item) => item.attemptId == record.attemptId)) {
            throw const FormatException('Duplicate attempt ID');
          }
          records.add(record);
        }
      } on FormatException {
        rethrow;
      } catch (error) {
        throw FormatException('Malformed journal: $error');
      }
    }
    final store = UsageAttemptStore._(
      accountRoot: accountRoot,
      terminalHistoryLimit: terminalHistoryLimit,
      maxJournalBytes: maxJournalBytes,
      writeStagedFile: writeStagedFile ?? _defaultWriter,
      records: List<UsageAttempt>.unmodifiable(records),
      revision: revision,
      historyTruncated: truncated,
      tombstones: <String, int>{},
      migrationMarkers: <String>{},
      ownerFence: ownerFence,
      syncDirectory: syncDirectory,
    );
    final decodedJson = await _readJsonMetadata(file, maxJournalBytes);
    if (decodedJson != null) {
      final rawTombstones = decodedJson['tombstones'];
      if (rawTombstones is Map) {
        store._tombstones = rawTombstones.map((key, value) {
          if (key is! String || value is! int || value < 1) throw const FormatException('Malformed tombstone');
          return MapEntry(key, value);
        });
      }
      final rawMarkers = decodedJson['migrationMarkers'];
      if (rawMarkers is List) store._migrationMarkers = rawMarkers.cast<String>().toSet();
    }
    if (records.any((item) => item.outcome == UsageOutcome.pending)) {
      var classified = records.map((record) {
        if (record.outcome != UsageOutcome.pending) return record;
        return UsageAttempt(
          attemptId: record.attemptId, requestId: record.requestId, revision: record.revision + 1,
          sourceDevice: record.sourceDevice, provider: record.provider,
          requestedModel: record.requestedModel, reportedModel: record.reportedModel,
          purpose: record.purpose, sessionId: record.sessionId, runId: record.runId,
          startedAt: record.startedAt, completedAt: record.completedAt, elapsed: record.elapsed,
          dispatchStage: record.dispatchStage, outcome: UsageOutcome.interrupted,
          inputTokens: record.inputTokens, outputTokens: record.outputTokens,
          totalTokens: record.totalTokens,
        );
      }).toList();
      final classifiedTerminal = classified.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      var classifiedTruncated = truncated;
      if (classifiedTerminal.length > terminalHistoryLimit) {
        classifiedTruncated = true;
        classifiedTerminal.removeRange(terminalHistoryLimit, classifiedTerminal.length);
      }
      classified = classifiedTerminal;
      store._records = classified;
      store._revision += records.where((item) => item.outcome == UsageOutcome.pending).length;
      store._historyTruncated = classifiedTruncated;
      await store._persist(classified, store._revision, classifiedTruncated);
    } else {
      final bounded = records.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      var boundedTruncated = truncated;
      if (bounded.length > terminalHistoryLimit) {
        boundedTruncated = true;
        bounded.removeRange(terminalHistoryLimit, bounded.length);
      }
      if (bounded.length != records.length || boundedTruncated != truncated) {
        store._records = bounded;
        store._historyTruncated = boundedTruncated;
        store._revision++;
        await store._persist(bounded, store._revision, boundedTruncated);
      }
    }
    return store;
  }

  List<UsageAttempt> get snapshot => List<UsageAttempt>.unmodifiable(_records);
  List<UsageAttempt> get pending => List<UsageAttempt>.unmodifiable(
      _records.where((record) => record.outcome == UsageOutcome.pending));
  List<UsageAttempt> get terminal => List<UsageAttempt>.unmodifiable(
      _records.where((record) => record.outcome != UsageOutcome.pending));
  int get revision => _revision;
  bool get historyTruncated => _historyTruncated;
  Set<String> get migrationMarkers => Set<String>.unmodifiable(_migrationMarkers);

  Future<bool> upsert(UsageAttempt record) => _enqueue(() async {
    if (!await _ownerFence()) throw StateError('Stale usage account owner');
    if (_tombstones.containsKey(record.attemptId)) return false;
    final existingIndex = _records.indexWhere((item) => item.attemptId == record.attemptId);
    if (existingIndex >= 0) {
      final existing = _records[existingIndex];
      if (record.revision < existing.revision) return false;
      if (record.revision == existing.revision) {
        if (record == existing) return false;
        throw StateError('Conflicting usage attempt revision');
      }
    }
    var next = [..._records];
    if (existingIndex >= 0) next[existingIndex] = record; else next.add(record);
    var nextTruncated = _historyTruncated;
    final terminal = next.where((item) => item.outcome != UsageOutcome.pending).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final pendingRecords = next.where((item) => item.outcome == UsageOutcome.pending).toList();
    final nextTombstones = {..._tombstones};
    if (terminal.length > terminalHistoryLimit) {
      nextTruncated = true;
      for (final removed in terminal.skip(terminalHistoryLimit)) {
        nextTombstones[removed.attemptId] = removed.revision;
      }
      terminal.removeRange(terminalHistoryLimit, terminal.length);
    }
    next = [...pendingRecords, ...terminal];
    await _persist(next, _revision + 1, nextTruncated, tombstones: nextTombstones);
    _records = List<UsageAttempt>.unmodifiable(next);
    _revision++;
    _historyTruncated = nextTruncated;
    _tombstones = nextTombstones;
    return true;
  });

  /// Imports caller-assigned stable IDs once. The input is deliberately an
  /// immutable Task-1 record list; old integer values are relabeled as
  /// legacy-unspecified instead of being presented as provider measurements.
  Future<int> migrateLegacy({required String marker, required Iterable<UsageAttempt> records}) =>
      _enqueue(() async {
        if (!await _ownerFence()) throw StateError('Stale usage account owner');
        if (_migrationMarkers.contains(marker)) return 0;
        final imported = <UsageAttempt>[];
        for (final record in records) {
          if (_tombstones.containsKey(record.attemptId) ||
              _records.any((item) => item.attemptId == record.attemptId) ||
              imported.any((item) => item.attemptId == record.attemptId)) continue;
          imported.add(_legacyRecord(record));
        }
        final next = [..._records, ...imported];
        final nextMarkers = {..._migrationMarkers, marker};
        await _persist(next, _revision + (imported.isEmpty ? 0 : 1), _historyTruncated,
            migrationMarkers: nextMarkers);
        _records = List<UsageAttempt>.unmodifiable(next);
        if (imported.isNotEmpty) _revision++;
        _migrationMarkers = nextMarkers;
        return imported.length;
      });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_, __) {});
    return result;
  }

  Future<void> _persist(List<UsageAttempt> records, int revision, bool truncated,
      {Map<String, int>? tombstones, Set<String>? migrationMarkers}) async {
    final bytes = utf8.encode(jsonEncode({
      'schemaVersion': schemaVersion,
      'revision': revision,
      'historyTruncated': truncated,
      'attempts': records.map((record) => record.toJson()).toList(),
      'tombstones': tombstones ?? _tombstones,
      'migrationMarkers': (migrationMarkers ?? _migrationMarkers).toList(),
    }));
    if (bytes.length > maxJournalBytes) throw StateError('Usage journal exceeds size limit');
    final target = File('${accountRoot.path}/$journalFileName');
    final temp = File('${target.path}.tmp');
    try {
      await _writeStagedFile(temp, bytes);
      await temp.rename(target.path);
      // Dart has no portable directory fsync API. Callers may inject a
      // platform-specific best-effort sync; file contents are already flushed.
      await _syncDirectory(accountRoot);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  static Future<void> _defaultWriter(File file, List<int> bytes) => file.writeAsBytes(bytes, flush: true);
  static Future<bool> _alwaysOwner() async => true;
  static Future<void> _bestEffortDirectorySync(Directory _) async {}

  static Future<List<int>> _readCapped(File file, int limit) async {
    final handle = await file.open();
    final bytes = <int>[];
    try {
      while (bytes.length <= limit) {
        final chunk = await handle.read(8192);
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
        if (bytes.length > limit) throw const FormatException('Journal exceeds size limit');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  static Future<Map<String, dynamic>?> _readJsonMetadata(File file, int limit) async {
    if (!await file.exists()) return null;
    final bytes = await _readCapped(file, limit);
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  static UsageAttempt _legacyRecord(UsageAttempt record) => UsageAttempt(
        attemptId: record.attemptId, requestId: record.requestId, revision: record.revision,
        sourceDevice: record.sourceDevice, provider: record.provider,
        requestedModel: record.requestedModel, reportedModel: record.reportedModel,
        purpose: record.purpose, sessionId: record.sessionId, runId: record.runId,
        startedAt: record.startedAt, completedAt: record.completedAt, elapsed: record.elapsed,
        dispatchStage: record.dispatchStage, outcome: record.outcome,
        inputTokens: _legacyTokens(record.inputTokens), outputTokens: _legacyTokens(record.outputTokens),
        totalTokens: _legacyTokens(record.totalTokens),
      );

  static UsageTokenCount? _legacyTokens(UsageTokenCount? token) => token == null
      ? null
      : token.value == null ? UsageTokenCount.unknown() : UsageTokenCount.legacy(token.value!);

  static void _requireKeys(Map<String, dynamic> json, Set<String> expected,
      {Set<String> optional = const {}}) {
    if (json.length < expected.length || !json.keys.every((key) => expected.contains(key) || optional.contains(key))) {
      throw const FormatException('Unexpected or missing journal fields');
    }
  }
}
