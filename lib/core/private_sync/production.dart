import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../reset_coordinator.dart';
import '../usage_attempt.dart' as local;
import 'client.dart';
import 'coordinator.dart';
import 'dto.dart';
import 'endpoint_policy.dart';
import 'file_outbox.dart';
import 'outbox.dart';
import 'protocol.dart' as wire;
import 'store.dart';

abstract interface class PrivateSyncSettingsController {
  Future<void> enroll();
}

Uri? configuredHttpsEndpoint(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}

String productionId() => List.generate(
  24,
  (_) => Random.secure().nextInt(256),
).map((n) => n.toRadixString(16).padLeft(2, '0')).join();

String accountDirectoryName(String uid) =>
    sha256.convert(utf8.encode(uid)).toString();

/// Portable metadata only. Callers pass these fields individually, never a
/// provider's persistence map (which may gain credential/runtime fields).
SyncUploadRecord privateProviderMetadataRecord(
  String device, {
  required String providerId,
  required String? modelId,
  required String endpoint,
  required String displayName,
  required bool supportsStreaming,
}) {
  final payload = ProviderMetadataPayload(
    providerId: providerId,
    modelId: modelId,
    endpoint: canonicalProviderEndpoint(endpoint, providerId),
    requestPurpose: null,
    displayName: displayName,
    supportsStreaming: supportsStreaming,
  );
  // Provider metadata is immutable: an explicit metadata edit creates a new
  // record, while credential/runtime changes leave this identity unchanged.
  return SyncUploadRecord(
    recordId:
        'provider-${sha256.convert(utf8.encode(jsonEncode(payload.toWire())))}',
    sourceDeviceId: device,
    conversationId: null,
    // ProviderConfig has no creation timestamp. Use a stable unknown epoch,
    // rather than invent a different creation identity on every snapshot.
    createdAt: '1970-01-01T00:00:00Z',
    revision: 1,
    payload: payload,
  );
}

Iterable<SyncUploadRecord> privateUsageSnapshot(
  String device,
  Iterable<local.UsageAttempt> attempts,
) sync* {
  for (final attempt in attempts) {
    final counts = [
      attempt.inputTokens,
      attempt.outputTokens,
      attempt.totalTokens,
    ];
    final provenance = counts
        .whereType<local.UsageTokenCount>()
        .map((c) => c.provenance)
        .toSet();
    final source = provenance.length == 1 ? provenance.single.name : 'unknown';
    final created = attempt.startedAt.toUtc().toIso8601String();
    yield SyncUploadRecord(
      recordId: attempt.attemptId,
      sourceDeviceId: device,
      conversationId: attempt.sessionId,
      createdAt: created,
      revision: attempt.revision,
      payload: UsagePayload(
        logicalRequestId: attempt.requestId,
        attemptId: attempt.attemptId,
        requestedModel: attempt.requestedModel,
        reportedModel: attempt.reportedModel,
        outcome: UsageOutcome.values.byName(attempt.outcome.name),
        inputTokens: attempt.inputTokens?.value,
        outputTokens: attempt.outputTokens?.value,
        totalTokens: attempt.totalTokens?.value,
        usageProvenance: UsageProvenance.values.byName(source),
        startedAt: created,
        completedAt: attempt.completedAt?.toUtc().toIso8601String(),
        elapsedMilliseconds: attempt.elapsed?.inMilliseconds,
      ),
    );
    yield SyncUploadRecord(
      recordId: 'activity-${attempt.attemptId}',
      sourceDeviceId: device,
      conversationId: attempt.sessionId,
      createdAt: created,
      revision: attempt.revision,
      payload: ActivityPayload(
        logicalRequestId: attempt.requestId,
        attemptId: attempt.attemptId,
        kind: ActivityKind.request,
        status: attempt.outcome == local.UsageOutcome.pending
            ? ActivityStatus.started
            : ActivityStatus.values.byName(attempt.outcome.name),
        updatedAt: attempt.completedAt?.toUtc().toIso8601String() ?? created,
        title: 'Model request',
        detail: '',
        usageRecordId: attempt.attemptId,
      ),
    );
  }
}

class ProductionSyncClock implements SyncClock {
  @override
  DateTime get now => DateTime.now();
  @override
  SyncTimer schedule(Duration delay, void Function() callback) =>
      _Timer(Timer(delay, callback));
}

class _Timer implements SyncTimer {
  _Timer(this.timer);
  final Timer timer;
  @override
  void cancel() => timer.cancel();
}

class ProductionSyncJitter implements SyncJitter {
  final _random = Random();
  @override
  Duration delay(Duration cap) => Duration(
    milliseconds: 2000 + _random.nextInt(max(1, cap.inMilliseconds - 1999)),
  );
}

/// App-owned, lazy authenticated runtime. Construction performs no I/O. Only a
/// ready UID can bind, and only persisted explicit enrollment admits delivery.
class PrivateSyncProduction extends ChangeNotifier
    implements PrivateSyncSettingsController {
  PrivateSyncProduction({
    this.endpoint = const String.fromEnvironment('OVID_PRIVATE_SYNC_BASE_URL'),
    required this.rootDirectory,
    required this.accountReady,
    required this.currentUid,
    required this.idToken,
    required this.appCheckToken,
    http.Client Function()? httpClientFactory,
    this.snapshot,
    SyncClock? clock,
    SyncJitter? jitter,
  }) : httpClientFactory = httpClientFactory ?? http.Client.new,
       clock = clock ?? ProductionSyncClock(),
       jitter = jitter ?? ProductionSyncJitter();

  final String endpoint;
  final Future<Directory> Function() rootDirectory;
  final bool Function() accountReady;
  final String? Function() currentUid;
  final IdTokenProvider idToken;
  final AppCheckProvider appCheckToken;
  final http.Client Function() httpClientFactory;
  final Iterable<SyncUploadRecord> Function(String deviceId)? snapshot;
  final SyncClock clock;
  final SyncJitter jitter;
  String? _uid;
  int _epoch = 0;
  bool _foreground = false;
  bool _enrolled = false;
  String? _deviceId;
  Map<String, dynamic> _identity = {};
  Directory? _root;
  PrivateSyncStore? _store;
  PrivateSyncOutbox? _outbox;
  FileOutboxPersistence? _identityFile;
  FileOutboxPersistence? _outboxFile;
  PrivateSyncCoordinator? _coordinator;
  http.Client? _http;
  Future<void> _work = Future.value();
  Future<void> _exports = Future.value();
  String? error;
  SyncDeliveryStatus? deliveryStatus;

  bool get configured => configuredHttpsEndpoint(endpoint) != null;
  bool get available =>
      configured && accountReady() && _uid != null && currentUid() == _uid;
  bool get enrolled => available && _enrolled;
  String? get deviceId => _deviceId;
  List<SyncReplayRecord> get records =>
      available ? (_store?.records ?? const []) : const [];
  bool _owns(int epoch) => epoch == _epoch && available;

  AccountLifecycleDependencies get lifecycle => AccountLifecycleDependencies(
    onFence: fence,
    onRevoke: release,
    onBind: bind,
    onClear: clear,
    onVerifyEmpty: verifyEmpty,
  );

  Future<void> bind(String uid, int generation) async {
    if (!configured || !accountReady() || currentUid() != uid) return;
    if (_uid == uid && _store != null && _http != null) return;
    await release();
    _uid = uid;
    final epoch = _epoch;
    final base = await rootDirectory();
    if (!_owns(epoch)) return;
    _root = Directory('${base.path}/private-sync/${accountDirectoryName(uid)}');
    final root = _root!;
    _identityFile = FileOutboxPersistence(
      File('${root.path}/enrollment.json'),
      owns: () => _owns(epoch),
    );
    final bytes = await _identityFile!.read();
    if (!_owns(epoch)) return;
    _identity = bytes == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    if (_identity.isNotEmpty && _identity['accountId'] != uid) {
      throw StateError('Enrollment account mismatch');
    }
    _deviceId = _identity['deviceId'] as String?;
    _enrolled = _identity['enrolled'] == true;
    _identity['remoteActive'] ??= _enrolled;
    final store = await PrivateSyncStore.open(
      accountRoot: root,
      accountId: uid,
      ownerFence: () => _owns(epoch),
    );
    if (!_owns(epoch)) {
      await store.close();
      return;
    }
    _store = store;
    _outboxFile = FileOutboxPersistence(
      File('${root.path}/outbox.json'),
      owns: () => _owns(epoch),
    );
    _outbox = await PrivateSyncOutbox.open(
      _outboxFile!,
      accountId: uid,
      ownerId: productionId(),
    );
    if (!_owns(epoch)) return;
    _http = httpClientFactory();
    if (_enrolled) await _start(epoch);
    notifyListeners();
  }

  PrivateSyncClient _client(int epoch) => PrivateSyncClient(
    baseUri: configuredHttpsEndpoint(endpoint)!,
    httpClient: _http!,
    deviceId: _deviceId ?? '',
    generation: () => _epoch,
    idToken: (force) async {
      if (!_owns(epoch)) return null;
      final value = await idToken(force);
      return _owns(epoch) ? value : null;
    },
    appCheckToken: () async {
      if (!_owns(epoch)) throw StateError('Account changed');
      final value = await appCheckToken();
      if (!_owns(epoch) || value == null || value.isEmpty) {
        throw StateError('App Check unavailable');
      }
      return value;
    },
  );

  @override
  Future<void> enroll() => _serialize(() async {
    if (!available || _store == null) {
      throw StateError('Private sync is not configured for a ready account');
    }
    if (_enrolled) return;
    final epoch = _epoch;
    if (_identity['remoteActive'] == true && _deviceId != null) {
      await _serializeExport(() => _prepareNewDevice(epoch, _deviceId!));
      _identity['enrolled'] = true;
      await _saveIdentity();
      if (!_owns(epoch)) return;
      _enrolled = true;
      await _start(epoch);
      notifyListeners();
      return;
    }
    _identity = {
      ..._identity,
      'accountId': _uid,
      'idempotencyKey': _identity['idempotencyKey'] ?? productionId(),
      'deviceId': _identity['deviceId'] ?? productionId(),
      'enrolled': false,
    };
    _deviceId = _identity['deviceId'] as String;
    await _saveIdentity();
    if (!_owns(epoch)) return;
    final result = await _client(epoch).enroll(
      deviceName: 'Ovid',
      idempotencyKey: _identity['idempotencyKey'] as String,
    );
    if (!_owns(epoch)) return;
    if (result.status != wire.SyncEnrollmentStatus.active) {
      throw StateError('Device enrollment is not active');
    }
    _identity['deviceId'] = result.deviceId;
    _deviceId = result.deviceId;
    _identity['enrolled'] = false;
    _identity['remoteActive'] = true;
    await _serializeExport(() => _prepareNewDevice(epoch, result.deviceId));
    _identity['enrolled'] = true;
    await _saveIdentity();
    if (!_owns(epoch)) return;
    _deviceId = result.deviceId;
    _enrolled = true;
    error = null;
    await _start(epoch);
    notifyListeners();
  });

  Future<void> _saveIdentity() =>
      _identityFile!.writeAtomically(utf8.encode(jsonEncode(_identity)));

  Future<void> _start(int epoch) async {
    if (!_owns(epoch) || !_enrolled) return;
    _coordinator?.dispose();
    final coordinator = PrivateSyncCoordinator(
      client: _DeliveryClient(
        _client(epoch),
        (message) {
          if (_owns(epoch)) {
            error = message;
            notifyListeners();
          }
        },
        () {
          if (!_owns(epoch)) return;
          _enrolled = false;
          _coordinator?.dispose();
          _coordinator = null;
          error =
              'This device or account is no longer authorized. Enable sync again after restoring account access.';
          _identity['enrolled'] = false;
          _identity['remoteActive'] = false;
          _identity.remove('idempotencyKey');
          _identity.remove('deviceId');
          unawaited(
            _serialize(() async {
              if (_owns(epoch)) await _saveIdentity();
            }).catchError((Object _) {}),
          );
          notifyListeners();
        },
      ),
      store: _ProjectionStore(
        _store!,
        () => _owns(epoch),
        (records) => _validateReplay(epoch, records),
      ),
      outbox: _DeliveryOutbox(
        _outbox!,
        () => _capture(epoch),
        () => _owns(epoch),
        _serializeExport,
        clock,
        jitter,
        _report,
        () => _deviceId,
      ),
      clock: clock,
      jitter: jitter,
      onStatusChanged: (status) {
        if (_owns(epoch)) {
          deliveryStatus = status;
          notifyListeners();
        }
      },
    );
    _coordinator = coordinator;
    await coordinator.bindAccount(accountId: _uid!, generation: epoch);
    if (_owns(epoch) && _foreground) await coordinator.setForeground(true);
  }

  Future<void> _capture(int epoch) =>
      _serializeExport(() => _captureNow(epoch));

  Future<void> _validateReplay(
    int epoch,
    Iterable<SyncReplayRecord> records,
  ) => _serializeExport(() async {
    if (!_owns(epoch)) return;
    final known = {for (final row in _store!.records) row.recordId: row.record};
    for (final entry in await _outbox!.entries()) {
      known.putIfAbsent(entry.envelope.recordId, () => entry.envelope);
    }
    if (!_owns(epoch)) return;
    for (final row in records) {
      final record = row.record;
      final old = known[record.recordId];
      if (old != null &&
          (old.recordType != record.recordType ||
              old.conversationId != record.conversationId ||
              old.createdAt != record.createdAt ||
              ((old.payload is TranscriptPayload ||
                      old.payload is ProviderMetadataPayload) &&
                  old.payload != record.payload))) {
        _report(
          'Sync conflict: restored content differs from the original. The original content is preserved.',
        );
        throw const SyncTransientFailure();
      }
      known[record.recordId] = record;
    }
  });

  // Apply backpressure before reading a live snapshot. In particular, a
  // changing activity row must not create a new envelope on every quota retry.
  static const _maxPendingRecords = 32;
  static const _maxPendingBytes = 1024 * 1024;

  void _report(String message) {
    error = message;
    notifyListeners();
  }

  Future<void> _captureNow(int epoch) async {
    if (!_owns(epoch) || !_enrolled || snapshot == null) return;
    final outbox = _outbox!;
    final entries = await outbox.entries();
    if (!_owns(epoch)) return;
    final previous = {
      for (final row in _store!.records) row.recordId: row.record,
    };
    final deleted = {
      ..._store!.tombstones,
      for (final entry in entries)
        if (entry.envelope.payload case final TombstonePayload tombstone)
          tombstone.targetRecordId,
    };
    final pending = <String>{};
    var pendingBytes = 0;
    for (final entry in entries) {
      final old = previous[entry.envelope.recordId];
      if (old == null || old.revision < entry.envelope.revision) {
        previous[entry.envelope.recordId] = entry.envelope;
      }
      if (!deleted.contains(entry.envelope.recordId) &&
          (entry.state == OutboxState.pending ||
              entry.state == OutboxState.retryable)) {
        pending.add(entry.envelope.recordId);
        pendingBytes += entry.envelope.canonicalBytes().length;
      }
      if (entry.error != null) _report(entry.error!);
    }
    for (final source in snapshot!(_deviceId!)) {
      final record = _portableRecord(source);
      if (!_owns(epoch)) return;
      if (deleted.contains(source.recordId) ||
          deleted.contains(record.recordId)) {
        continue;
      }
      final old = previous[record.recordId];
      final sameIdentity =
          old == null ||
          (old.conversationId == record.conversationId &&
              old.createdAt == record.createdAt &&
              old.recordType == record.recordType);
      if (sameIdentity && old?.payload == record.payload) continue;
      if (old != null && old.sourceDeviceId != _deviceId) {
        _report(
          'A previous-device record is preserved under its original identity. Changes remain local.',
        );
        continue;
      }
      if (old != null &&
          (!sameIdentity ||
              record.payload is TranscriptPayload ||
              record.payload is ProviderMetadataPayload ||
              record.revision <= old.revision)) {
        _report(
          'Sync conflict: the original record is preserved. The edited content remains local; create a new record to sync it.',
        );
        continue;
      }
      if (pending.contains(record.recordId)) continue;
      if (pending.length >= _maxPendingRecords ||
          pendingBytes >= _maxPendingBytes) {
        _report(
          'Sync delivery is backlogged. Additional content remains local until pending records are delivered.',
        );
        break;
      }
      final next = SyncUploadRecord(
        recordId: record.recordId,
        sourceDeviceId: _deviceId!,
        conversationId: record.conversationId,
        createdAt: record.createdAt,
        revision: record.revision,
        payload: record.payload,
      );
      final bytes = next.canonicalBytes();
      if (bytes.length > maxRecordBytes) {
        _report('A record exceeds the sync record limit and remains local.');
        continue;
      }
      if (pendingBytes + bytes.length > _maxPendingBytes) break;
      await outbox.enqueue(sha256.convert(bytes).toString(), next);
      previous[next.recordId] = next;
      pending.add(next.recordId);
      pendingBytes += bytes.length;
    }
  }

  Future<void> _prepareNewDevice(int epoch, String device) async {
    if (!_owns(epoch)) return;
    final entries = await _outbox!.entries();
    final accepted = {
      for (final entry in entries)
        if (entry.state == OutboxState.acknowledged) entry.envelope.recordId,
      ..._store!.records.map((r) => r.recordId),
    };
    final mapping = Map<String, dynamic>.from(
      _identity['portableIds'] as Map? ?? {},
    );
    final devices = Map<String, dynamic>.from(
      _identity['portableDevices'] as Map? ?? {},
    );
    final candidates = <String, SyncUploadRecord>{};
    final existingIds = entries.map((e) => e.envelope.recordId).toSet();
    final deleted = {
      ..._store!.tombstones,
      for (final entry in entries)
        if (entry.envelope.payload case final TombstonePayload tombstone)
          tombstone.targetRecordId,
    };
    // Old submitted records may have reached the server even without an ACK.
    // Never reuse those immutable identities with a new device attribution.
    for (final entry in entries) {
      final record = entry.envelope;
      if (record.sourceDeviceId == device ||
          deleted.contains(record.recordId) ||
          accepted.contains(record.recordId) ||
          entry.state == OutboxState.acknowledged ||
          record.payload is TombstonePayload) {
        continue;
      }
      if (candidates.containsKey(record.recordId)) continue;
      if (entry.state == OutboxState.terminal &&
          !(entry.error?.startsWith('Previous-device upload') ?? false)) {
        continue;
      }
      final existing = mapping[record.recordId] as String?;
      if (existing != null &&
          (accepted.contains(existing) ||
              existingIds.contains(existing) ||
              deleted.contains(existing))) {
        continue;
      }
      candidates[record.recordId] = record;
      final newId = existing != null && devices[existing] == device
          ? existing
          : 'portable-${productionId()}';
      devices[newId] = device;
      final origins = mapping.keys
          .where((key) => mapping[key] == record.recordId)
          .toList();
      if (origins.isEmpty) {
        mapping[record.recordId] = newId;
      } else {
        for (final origin in origins) {
          mapping[origin] = newId;
        }
        mapping[record.recordId] = newId;
      }
    }
    _identity['portableIds'] = mapping;
    _identity['portableDevices'] = devices;
    // Persist mapping before quarantine: a crash cannot lose the origin mapping.
    await _saveIdentity();
    if (!_owns(epoch)) return;
    // A tombstone targets an existing remote identity, never its portable
    // replacement. Persist the new-device envelope before quarantining the
    // old one. Its deterministic ID and original timestamps make recovery
    // after either write idempotent, including older quarantined deletions.
    final deliveredDeletions = {
      ..._store!.tombstones,
      for (final entry in entries)
        if (entry.state == OutboxState.acknowledged &&
            entry.envelope.payload is TombstonePayload)
          (entry.envelope.payload as TombstonePayload).targetRecordId,
    };
    for (final entry in entries) {
      final record = entry.envelope;
      if (record.payload is! TombstonePayload ||
          record.sourceDeviceId == device ||
          entry.state == OutboxState.acknowledged ||
          (entry.state == OutboxState.terminal &&
              !(entry.error?.startsWith('Previous-device upload') ?? false))) {
        continue;
      }
      final payload = record.payload as TombstonePayload;
      if (deliveredDeletions.contains(payload.targetRecordId)) continue;
      final copy = SyncUploadRecord(
        recordId:
            'delete-${sha256.convert(utf8.encode(jsonEncode([device, payload.targetRecordId])))}',
        sourceDeviceId: device,
        conversationId: record.conversationId,
        createdAt: record.createdAt,
        revision: record.revision,
        payload: payload,
      );
      await _outbox!.enqueue(
        sha256.convert(copy.canonicalBytes()).toString(),
        copy,
      );
      if (!_owns(epoch)) return;
    }
    await _outbox!.quarantineOtherDevices(device);
    for (final record in candidates.values) {
      if (!_owns(epoch)) return;
      final portable = _portableRecord(record);
      final copy = SyncUploadRecord(
        recordId: portable.recordId,
        sourceDeviceId: device,
        conversationId: portable.conversationId,
        createdAt: portable.createdAt,
        revision: portable.revision,
        payload: portable.payload,
      );
      await _outbox!.enqueue(
        sha256.convert(copy.canonicalBytes()).toString(),
        copy,
      );
    }
    if (mapping.isNotEmpty && _owns(epoch)) {
      _report(
        'Previous-device uploads are quarantined and preserved locally. Portable content uses new record IDs; accepted originals are unchanged.',
      );
    }
  }

  SyncUploadRecord _portableRecord(SyncUploadRecord record) {
    final mapping = _identity['portableIds'] as Map? ?? const {};
    String? mapped(String? id) =>
        id == null ? null : (mapping[id] as String? ?? id);
    final id = mapped(record.recordId)!;
    if (id == record.recordId) return record;
    final payload = Map<String, Object?>.of(record.payload.toWire());
    if (record.payload is TranscriptPayload) {
      payload['messageId'] = id;
      payload['parentMessageId'] = mapped(
        payload['parentMessageId'] as String?,
      );
      payload['providerMetadataRecordId'] = mapped(
        payload['providerMetadataRecordId'] as String?,
      );
    } else if (record.payload is UsagePayload) {
      payload['attemptId'] = id;
    } else if (record.payload is ActivityPayload) {
      payload['attemptId'] = mapped(payload['attemptId'] as String?);
      payload['usageRecordId'] = mapped(payload['usageRecordId'] as String?);
    }
    return SyncUploadRecord(
      recordId: id,
      sourceDeviceId: record.sourceDeviceId,
      conversationId: record.conversationId,
      createdAt: record.createdAt,
      revision: record.revision,
      payload: SyncPayload.fromWire(record.recordType, payload),
    );
  }

  /// Called only by genuine local delete actions, before their local commit.
  /// The durable outbox is also the export history, so unloaded transcript
  /// prefixes and older provider versions are included without diffing a page.
  Future<void> recordLocalDeletion({
    Set<String> conversationIds = const {},
    Set<String> recordIds = const {},
    String? providerId,
  }) {
    final epoch = _epoch;
    if (!enrolled) return Future.value();
    return _serializeExport(() async {
      if (!_owns(epoch) || !_enrolled) return;
      final outbox = _outbox!;
      final entries = await outbox.entries();
      if (!_owns(epoch)) return;
      final known = {
        for (final row in _store!.records) row.recordId: row.record,
      };
      for (final entry in entries) {
        final record = entry.envelope;
        if (record.revision > (known[record.recordId]?.revision ?? 0)) {
          known[record.recordId] = record;
        }
      }
      // A local message retains its original ID. Follow both directions so
      // every submitted copy from successive enrollments is deleted too.
      final targets = {...recordIds};
      final mapping = _identity['portableIds'] as Map? ?? const {};
      var expanded = true;
      while (expanded) {
        expanded = false;
        for (final entry in mapping.entries) {
          if (targets.contains(entry.key) || targets.contains(entry.value)) {
            if (targets.add(entry.key as String)) expanded = true;
            if (targets.add(entry.value as String)) expanded = true;
          }
        }
      }
      final deleted = {
        ..._store!.tombstones,
        for (final entry in entries)
          if (entry.envelope.payload case final TombstonePayload tombstone)
            tombstone.targetRecordId,
      };
      for (final record in known.values) {
        final payload = record.payload;
        final matches = payload is TranscriptPayload
            ? conversationIds.contains(record.conversationId) ||
                  targets.contains(record.recordId)
            : payload is ProviderMetadataPayload &&
                  payload.providerId == providerId;
        if (!matches || deleted.contains(record.recordId)) continue;
        final deletedAt = DateTime.now().toUtc().toIso8601String();
        final tombstone = SyncUploadRecord(
          recordId: 'delete-${sha256.convert(utf8.encode(record.recordId))}',
          sourceDeviceId: _deviceId!,
          conversationId: record.conversationId,
          createdAt: deletedAt,
          revision: 1,
          payload: TombstonePayload(
            targetRecordId: record.recordId,
            deletionRevision: record.revision + 1,
            deletedAt: deletedAt,
            reason: TombstoneReason.user,
          ),
        );
        await outbox.enqueue(
          sha256.convert(tombstone.canonicalBytes()).toString(),
          tombstone,
        );
      }
    }).catchError((Object error) {
      if (_owns(epoch)) {
        _report(
          'Deletion could not be saved for sync. Your local content is preserved; retry the deletion.',
        );
      }
      throw StateError(
        'Deletion could not be saved for sync. Retry the deletion.',
      );
    });
  }

  Future<void> setForeground(bool value) async {
    if (_foreground == value) return;
    _foreground = value;
    if (!value) {
      _coordinator?.dispose();
      _coordinator = null;
    } else if (enrolled) {
      try {
        await _start(_epoch);
      } catch (_) {
        error =
            'Sync could not resume. Check local storage and try refreshing.';
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    if (enrolled && _foreground) await _coordinator?.refresh();
  }

  /// Local pause works offline, preserving both pending and restored content.
  Future<void> disable() {
    _enrolled = false;
    _coordinator?.dispose();
    _coordinator = null;
    notifyListeners();
    return _serialize(() async {
      if (!available) return;
      _enrolled = false;
      _coordinator?.dispose();
      _coordinator = null;
      _identity['enrolled'] = false;
      await _saveIdentity();
      notifyListeners();
    });
  }

  Future<void> revokeDevice({
    required Future<bool> Function() reauthenticate,
  }) => _serialize(() async {
    if (!available || _deviceId == null) return;
    final epoch = _epoch;
    // Keep enabled delivery intact if verification is cancelled or HTTP fails.
    if (!await reauthenticate() || !_owns(epoch)) return;
    final revokeScope = jsonEncode([
      _uid,
      _deviceId,
      _identity['idempotencyKey'],
    ]);
    if (_identity['revokeScope'] != revokeScope) {
      _identity['revokeScope'] = revokeScope;
      _identity['revokeKey'] = productionId();
    }
    _identity['revokeKey'] ??= productionId();
    await _saveIdentity();
    await _client(epoch).revoke(
      _deviceId!,
      idempotencyKey: _identity['revokeKey'] as String,
      forceRefresh: true,
    );
    if (!_owns(epoch)) return;
    _coordinator?.dispose();
    _coordinator = null;
    _enrolled = false;
    await _exports;
    if (!_owns(epoch)) return;
    _identity['enrolled'] = false;
    _identity['remoteActive'] = false;
    _identity.remove('deviceId');
    _identity.remove('idempotencyKey');
    await _saveIdentity();
    _deviceId = null;
    _report(
      'Device revoked. Local transcripts, restored data, and pending uploads are preserved.',
    );
    notifyListeners();
  });

  Future<void> _serialize(Future<void> Function() action) {
    final next = _work.then((_) => action());
    _work = next.catchError((Object _) {});
    return next;
  }

  Future<void> _serializeExport(Future<void> Function() action) {
    final next = _exports.then((_) => action());
    _exports = next.catchError((Object _) {});
    return next;
  }

  void fence() {
    _epoch++;
    _uid = null;
    _enrolled = false;
    _deviceId = null;
    _coordinator?.dispose();
    _coordinator = null;
    _http?.close();
    _http = null;
    deliveryStatus = null;
    notifyListeners();
  }

  Future<void> release() async {
    fence();
    await _work;
    await _exports;
    await _store?.close();
    await _identityFile?.drained;
    await _outboxFile?.drained;
    _store = null;
    _outbox = null;
    _identity = {};
  }

  Future<void> clear() async {
    await release();
    final root = Directory('${(await rootDirectory()).path}/private-sync');
    if (await root.exists()) await root.delete(recursive: true);
  }

  Future<bool> verifyEmpty() async =>
      !await Directory('${(await rootDirectory()).path}/private-sync').exists();
}

class _ProjectionStore implements PrivateSyncCoordinatorStore {
  _ProjectionStore(this.store, this.owns, this.validate);
  final PrivateSyncStore store;
  final bool Function() owns;
  final Future<void> Function(Iterable<SyncReplayRecord>) validate;
  @override
  String get cursor => store.cursor;
  @override
  Future<void> applyPage(Object page) async {
    try {
      if (page is wire.SyncChangePage) await validate(page.records);
      if (owns()) {
        await store.applyPage(
          page is wire.SyncChangePage
              ? {...page.toWire(), 'accountId': store.accountId}
              : page,
        );
      }
    } catch (_) {
      throw const SyncTransientFailure();
    }
  }

  @override
  Future<void> installState(Object page) async {
    try {
      if (page is wire.SyncStatePage) await validate(page.records);
      if (owns()) await store.installState(page);
    } catch (_) {
      throw const SyncTransientFailure();
    }
  }

  @override
  Future<void> clearAccount() => store.clearAccount();
}

class _DeliveryOutbox
    implements PrivateSyncCoordinatorOutbox, PrivateSyncResultOutbox {
  _DeliveryOutbox(
    this.outbox,
    this.capture,
    this.owns,
    this.serialize,
    this.clock,
    this.jitter,
    this.report,
    this.deviceId,
  );
  final PrivateSyncOutbox outbox;
  final Future<void> Function() capture;
  final bool Function() owns;
  final Future<void> Function(Future<void> Function()) serialize;
  final SyncClock clock;
  final SyncJitter jitter;
  final void Function(String) report;
  final String? Function() deviceId;

  @override
  Future<void> applyResults(
    List<OutboxEntry> submitted,
    wire.SyncBatchResult result,
  ) =>
      serialize(() async {
        if (!owns()) return;
        // Do not acknowledge a malformed or incomplete response.
        final outcomes = {
          for (final item in result.results) item.recordId: item,
        };
        if (outcomes.length != submitted.length ||
            result.results.length != submitted.length ||
            submitted.any((e) => !outcomes.containsKey(e.envelope.recordId))) {
          throw const SyncTransientFailure();
        }
        for (final entry in submitted) {
          if (!owns()) return;
          final item = outcomes[entry.envelope.recordId]!;
          switch (item.status) {
            case wire.SyncRecordOutcomeStatus.accepted:
            case wire.SyncRecordOutcomeStatus.duplicate:
              await outbox.acknowledge(entry.idempotencyKey);
            case wire.SyncRecordOutcomeStatus.rejected:
            case wire.SyncRecordOutcomeStatus.conflict:
              final message =
                  item.status == wire.SyncRecordOutcomeStatus.conflict
                  ? 'Sync conflict: the original content is preserved. The local draft has not been changed.'
                  : 'A sync record was rejected and quarantined. Your local content is preserved.';
              await outbox.terminal(entry.idempotencyKey, message);
              if (owns()) report(message);
            case wire.SyncRecordOutcomeStatus.retryable:
              final cap = Duration(
                seconds: min(60, 2 << entry.attempts.clamp(0, 5)),
              );
              final delay = Duration(
                milliseconds: max(
                  jitter.delay(cap).inMilliseconds,
                  (item.error?.retryAfterSeconds ?? 0) * 1000,
                ),
              );
              const message =
                  'Delivery will retry after a delay. Your local content is preserved; later records can still sync.';
              await outbox.retry(
                entry.idempotencyKey,
                retryAt: clock.now.add(delay),
                error: message,
              );
              if (owns()) report(message);
          }
        }
      }).catchError((Object _) {
        throw const SyncTransientFailure();
      });

  @override
  Future<Duration?> nextRetryDelay() async {
    Duration? next;
    final entries = await outbox.entries();
    final deleted = {
      for (final entry in entries)
        if (entry.envelope.payload case final TombstonePayload tombstone)
          tombstone.targetRecordId,
    };
    for (final entry in entries) {
      if (deleted.contains(entry.envelope.recordId) ||
          entry.state != OutboxState.retryable ||
          entry.retryAt == null ||
          entry.envelope.sourceDeviceId != deviceId()) {
        continue;
      }
      final delay = entry.retryAt!.difference(clock.now);
      final bounded = delay.isNegative ? Duration.zero : delay;
      if (next == null || bounded < next) next = bounded;
    }
    return next;
  }

  @override
  Future<List<OutboxEntry>> entries() async {
    try {
      await capture();
      if (!owns()) return [];
      final entries = await outbox.entries();
      final deleted = {
        for (final entry in entries)
          if (entry.envelope.payload case final TombstonePayload tombstone)
            tombstone.targetRecordId,
      };
      final pending = entries
          .where(
            (e) =>
                !deleted.contains(e.envelope.recordId) &&
                e.envelope.sourceDeviceId == deviceId() &&
                (e.retryAt == null || !e.retryAt!.isAfter(clock.now)) &&
                (e.state == OutboxState.pending ||
                    e.state == OutboxState.retryable),
          )
          .toList();
      // Deletion is deliverable even when content uploads exhaust quota.
      final tombstone = pending
          .where((e) => e.envelope.payload is TombstonePayload)
          .firstOrNull;
      return tombstone != null ? [tombstone] : pending.take(1).toList();
    } catch (_) {
      if (!owns()) return [];
      throw const SyncTransientFailure();
    }
  }

  @override
  Future<void> acknowledge(String key) async {
    try {
      await serialize(() async {
        if (owns()) await outbox.acknowledge(key);
      });
    } catch (_) {
      throw const SyncTransientFailure();
    }
  }

  @override
  Future<void> clearAccount() => outbox.clearAccount();
}

class _DeliveryClient implements PrivateSyncCoordinatorClient {
  _DeliveryClient(this.client, this.onError, this.onTerminal);
  final PrivateSyncClient client;
  final void Function(String) onError;
  final void Function() onTerminal;
  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on wire.SyncResetRequired {
      rethrow;
    } on SyncClientException catch (error) {
      if (error.code == 'device_revoked' || error.code == 'account_fenced') {
        onTerminal();
      } else {
        onError(
          'Sync unavailable. Delivery will retry while this app is foregrounded.',
        );
      }
      throw const SyncTransientFailure();
    } catch (_) {
      onError(
        'Sync unavailable. Delivery will retry while this app is foregrounded.',
      );
      throw const SyncTransientFailure();
    }
  }

  @override
  Future<wire.SyncBatchResult> upload(
    String key,
    List<SyncUploadRecord> records,
  ) => _call(() => client.upload(key, records));
  @override
  Future<wire.SyncChangePage> changes({required String cursor}) =>
      _call(() => client.changes(cursor: cursor));
  @override
  Future<wire.SyncStatePage> state() => _call(client.state);
}
