import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'diag.dart';

/// Public server receipt. Money stays a string: never parse it as a double.
class ImageReceipt {
  ImageReceipt._(
    this.accountId,
    this.requestId,
    this.fingerprint,
    this.state,
    this.charged,
  );

  final String accountId;
  final String requestId;
  final String fingerprint;
  final String state;
  final String? charged;

  factory ImageReceipt.parse(Object? value) {
    if (value is! Map) throw const FormatException('Invalid image receipt');
    final account = value['account_id'];
    final request = value['request_id'];
    final fingerprint = value['fingerprint'];
    final state = value['state'];
    final charged = value['charged'];
    if (account is! String ||
        account.isEmpty ||
        account.length > 128 ||
        request is! String ||
        !validImageRequestId(request) ||
        fingerprint is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
        !const ['pending', 'unknown', 'confirmed', 'failed'].contains(state)) {
      throw const FormatException('Invalid image receipt identity');
    }
    final terminal = state == 'confirmed' || state == 'failed';
    if (terminal ? !_exactMoney(charged) : charged != null) {
      throw const FormatException('Invalid exact image charge');
    }
    return ImageReceipt._(
      account,
      request,
      fingerprint,
      state as String,
      charged as String?,
    );
  }

  static bool _exactMoney(Object? value) {
    if (value is! String ||
        value.length > 300 ||
        !RegExp(
          r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[Ee][+-]?[0-9]{1,3})?$',
        ).hasMatch(value)) {
      return false;
    }
    // Decimal can serialize negative zero; other negative charges are invalid.
    return !value.startsWith('-') ||
        !RegExp(r'[1-9]').hasMatch(value.split(RegExp('[Ee]')).first);
  }

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'request_id': requestId,
    'fingerprint': fingerprint,
    'state': state,
    'charged': charged,
  };
}

bool validImageRequestId(String value) =>
    RegExp(r'^[A-Za-z0-9_.:-]{8,128}$').hasMatch(value);

/// Minimal durable admission. No prompt, input/output bytes, path or credentials.
/// A local pending row means submission MAY have happened, including after crash.
class ImageRequestRecord {
  const ImageRequestRecord({
    required this.accountId,
    required this.requestId,
    required this.fingerprint,
    this.state = 'pending',
    this.receipt,
  });

  final String accountId;
  final String requestId;
  final String fingerprint;
  final String state;
  final ImageReceipt? receipt;
  bool get unresolved => state == 'pending' || state == 'unknown';

  ImageRequestRecord withReceipt(ImageReceipt value) {
    if (value.accountId != accountId ||
        value.requestId != requestId ||
        value.fingerprint != fingerprint) {
      throw const FormatException('Mismatched image receipt');
    }
    return ImageRequestRecord(
      accountId: accountId,
      requestId: requestId,
      fingerprint: fingerprint,
      state: value.state,
      receipt: value,
    );
  }

  ImageRequestRecord get unknown => unresolved
      ? ImageRequestRecord(
          accountId: accountId,
          requestId: requestId,
          fingerprint: fingerprint,
          state: 'unknown',
          receipt: receipt,
        )
      : this;

  Map<String, Object?> toJson() => {
    'account_id': accountId,
    'request_id': requestId,
    'fingerprint': fingerprint,
    'state': state,
    'receipt': receipt?.toJson(),
  };

  factory ImageRequestRecord.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid image journal');
    // Reuse strict receipt identity validation for the local admission.
    final identity = ImageReceipt.parse({
      ...value,
      'state': 'pending',
      'charged': null,
    });
    final state = value['state'];
    if (!const ['pending', 'unknown', 'confirmed', 'failed'].contains(state)) {
      throw const FormatException('Invalid image journal state');
    }
    final record = ImageRequestRecord(
      accountId: identity.accountId,
      requestId: identity.requestId,
      fingerprint: identity.fingerprint,
      state: state as String,
    );
    final receipt = value['receipt'];
    if (receipt == null) return record; // May be a redacted dedup tombstone.
    final parsed = record.withReceipt(ImageReceipt.parse(receipt));
    if (parsed.state != state && !(state == 'unknown' && parsed.unresolved)) {
      throw const FormatException('Inconsistent image journal');
    }
    return ImageRequestRecord(
      accountId: record.accountId,
      requestId: record.requestId,
      fingerprint: record.fingerprint,
      state: state,
      receipt: parsed.receipt,
    );
  }
}

abstract class _ImageJournal {
  Future<String?> read();
  Future<void> write(String value);
}

/// A rejected update with the authoritative row captured under the journal lock.
/// Callers must keep this exact accounting instead of publishing the conflict.
class ImageReceiptConflict extends StateError {
  ImageReceiptConflict(this.record)
    : super('Conflicting terminal image receipt');

  final ImageRequestRecord record;
}

enum ImageAdmissionReason {
  accountUnavailable,
  identityConflict,
  capabilityUnavailable,
  unresolved,
}

/// Expected admission failures are distinct from journal read/write failures.
class ImageAdmissionError extends StateError {
  ImageAdmissionError(this.reason, {this.record}) : super(reason.name);
  final ImageAdmissionReason reason;
  final ImageRequestRecord? record;
}

class _PreferencesJournal implements _ImageJournal {
  _PreferencesJournal(this.preferences);
  final Future<SharedPreferences> Function() preferences;
  @override
  Future<String?> read() async {
    final prefs = await preferences();
    await prefs.reload();
    return prefs.getString(ImageReceiptStore.storageKey);
  }

  @override
  Future<void> write(String value) async {
    if (!await (await preferences()).setString(
      ImageReceiptStore.storageKey,
      value,
    )) {
      throw StateError('Image receipt persistence failed');
    }
  }
}

/// Authoritative app-private journal. Flush the new file before atomic rename;
/// never truncate the previous durable admission on an interrupted update.
class _FileJournal implements _ImageJournal {
  _FileJournal(this.directory);
  final Future<Directory> Function() directory;
  Future<File> _file() async =>
      File('${(await directory()).path}/${ImageReceiptStore.fileName}');
  @override
  Future<String?> read() async {
    final file = await _file();
    try {
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Image journal too large');
      }
      return await file.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.image-journal-');
    try {
      final temporary = File('${staging.path}/journal');
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(file.path);
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (e) {
        Diag.swallow('image_receipt_store.staging_cleanup', e);
      }
    }
  }
}

/// Serialized durable app-private file journal. Corrupt/read-failed storage is
/// fail-closed, never treated as empty. Use from the main app isolate. The
/// optional preferences adapter supports embedded callers, but production uses
/// flushed file writes (SharedPreferences does not guarantee disk durability).
/// Keep [fileName] during local reset/restore to preserve paid dedup fences.
class ImageReceiptStore {
  ImageReceiptStore({
    Future<SharedPreferences> Function()? preferences,
    Future<Directory> Function()? directory,
  }) : _journal = preferences != null
           ? _PreferencesJournal(preferences)
           : _FileJournal(directory ?? getApplicationSupportDirectory);
  static const storageKey = 'image_request_journal_v1';
  static const fileName = 'image_request_journal_v1.json';
  static Future<void> _tail = Future.value();
  final _ImageJournal _journal;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace trace) {});
    return result;
  }

  Future<
    ({_ImageJournal prefs, List<ImageRequestRecord> rows, Set<String> blocked})
  >
  _load() async {
    final prefs = _journal;
    final raw = await prefs.read();
    if (raw == null) {
      return (prefs: prefs, rows: <ImageRequestRecord>[], blocked: <String>{});
    }
    if (raw.length > 8 * 1024 * 1024) {
      throw const FormatException('Image journal too large');
    }
    final json = jsonDecode(raw);
    if (json is! Map ||
        json['version'] != 1 ||
        json['rows'] is! List ||
        json['blocked'] is! List) {
      throw const FormatException('Invalid image journal');
    }
    final rows = (json['rows'] as List)
        .map(ImageRequestRecord.fromJson)
        .toList();
    final keys = rows
        .map((r) => jsonEncode([r.accountId, r.requestId]))
        .toSet();
    if (keys.length != rows.length) {
      throw const FormatException('Duplicate image journal row');
    }
    return (
      prefs: prefs,
      rows: rows,
      blocked: (json['blocked'] as List).cast<String>().toSet(),
    );
  }

  Future<void> _write(
    _ImageJournal prefs,
    List<ImageRequestRecord> rows,
    Set<String> blocked,
  ) async {
    final raw = jsonEncode({
      'version': 1,
      'rows': rows.map((r) => r.toJson()).toList(),
      'blocked': blocked.toList(),
    });
    if (raw.length > 8 * 1024 * 1024) {
      throw StateError('Image receipt persistence failed');
    }
    await prefs.write(raw);
  }

  Future<List<ImageRequestRecord>> list(String accountId) => _serial(() async {
    final data = await _load();
    return List.unmodifiable(data.rows.where((r) => r.accountId == accountId));
  });

  /// Atomically records intent before network submission. Existing IDs are
  /// read-only, and unresolved work blocks replacement IDs for the whole UID.
  Future<({ImageRequestRecord record, bool created})> reserve(
    ImageRequestRecord candidate, {
    required bool Function() isCurrent,
    required bool Function() canSubmit,
  }) => _serial(() async {
    final data = await _load();
    if (!isCurrent() || data.blocked.contains(candidate.accountId)) {
      throw ImageAdmissionError(ImageAdmissionReason.accountUnavailable);
    }
    final existing = data.rows
        .where(
          (r) =>
              r.accountId == candidate.accountId &&
              r.requestId == candidate.requestId,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.fingerprint != candidate.fingerprint) {
        throw ImageAdmissionError(
          ImageAdmissionReason.identityConflict,
          record: existing,
        );
      }
      return (record: existing, created: false);
    }
    if (!canSubmit()) {
      throw ImageAdmissionError(ImageAdmissionReason.capabilityUnavailable);
    }
    final unresolved = data.rows
        .where((r) => r.accountId == candidate.accountId && r.unresolved)
        .firstOrNull;
    if (unresolved != null) {
      throw ImageAdmissionError(
        ImageAdmissionReason.unresolved,
        record: unresolved,
      );
    }
    data.rows.add(candidate);
    await _write(data.prefs, data.rows, data.blocked);
    return (record: candidate, created: true);
  });

  Future<ImageRequestRecord> update(
    ImageRequestRecord incoming, {
    required bool Function() isCurrent,
  }) => _serial(() async {
    final data = await _load();
    if (!isCurrent() || data.blocked.contains(incoming.accountId)) {
      throw StateError('Image account unavailable');
    }
    final index = data.rows.indexWhere(
      (r) =>
          r.accountId == incoming.accountId &&
          r.requestId == incoming.requestId,
    );
    if (index < 0 || data.rows[index].fingerprint != incoming.fingerprint) {
      throw StateError('Missing image admission');
    }
    final existing = data.rows[index];
    if (!existing.unresolved) {
      // A reordered pending read must never regress a confirmed/failed receipt.
      if (incoming.unresolved) return existing;
      if (existing.state != incoming.state ||
          (existing.receipt != null &&
              existing.receipt!.charged != incoming.receipt?.charged)) {
        throw ImageReceiptConflict(existing);
      }
      // A local-reset tombstone deliberately drops receipt detail. A late
      // in-flight update may not republish it after cleanup.
      if (existing.receipt == null) return existing;
    }
    data.rows[index] = incoming;
    await _write(data.prefs, data.rows, data.blocked);
    return incoming;
  });

  /// Local reset removes receipt details but retains admission tombstones.
  /// Account deletion additionally closes admission for this UID permanently.
  /// Session-owned output files are cleaned by the session/workspace owner.
  Future<void> redactAccount(String accountId, {bool deleted = false}) =>
      _serial(() async {
        final data = await _load();
        if (deleted) data.blocked.add(accountId);
        final rows = data.rows
            .map(
              (r) => r.accountId != accountId
                  ? r
                  : ImageRequestRecord(
                      accountId: r.accountId,
                      requestId: r.requestId,
                      fingerprint: r.fingerprint,
                      state: r.state,
                    ),
            )
            .toList();
        await _write(data.prefs, rows, data.blocked);
      });
}
