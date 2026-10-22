/// Web-safe contract for the four Data control actions.
///
/// The real work (CloudBackup, the zip service, the platform save dialog and
/// the app's temporary directory) needs `dart:io`, so it lives in
/// [data_control_export_io.dart]. The page imports this file conditionally and
/// only ever sees the types below. On web [createDataControlService] returns a
/// service that reports the real limitation instead of failing to compile.
library;

import 'package:flutter/foundation.dart' show immutable;

/// One progress tick from an export or import.
///
/// [label] is already user-facing copy ("Downloading chat 3 of 42…"); the page
/// only displays it. [fraction] is null while the total is not known yet.
@immutable
class V2TransferProgress {
  const V2TransferProgress({required this.label, this.fraction});

  final String label;
  final double? fraction;
}

/// A backup the user asked for could not be produced for a known reason.
///
/// Kept separate from [FormatException] so an archive the app wrote can name
/// its own reason, while a third-party file falls back to one honest sentence.
class V2BackupException implements Exception {
  const V2BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Outcome of writing one backup archive.
@immutable
class V2ExportOutcome {
  const V2ExportOutcome.saved(
    this.path, {
    required this.chats,
    required this.messages,
    required this.bytes,
    this.skippedChats = 0,
    this.limitHit,
  }) : shared = false,
       message = null,
       cancelled = false;

  const V2ExportOutcome.shared({
    required this.chats,
    required this.messages,
    required this.bytes,
    this.skippedChats = 0,
    this.limitHit,
  }) : path = null,
       shared = true,
       message = null,
       cancelled = false;

  const V2ExportOutcome.cancelled()
    : path = null,
      shared = false,
      chats = 0,
      messages = 0,
      bytes = 0,
      skippedChats = 0,
      limitHit = null,
      message = null,
      cancelled = true;

  const V2ExportOutcome.failed(String this.message)
    : path = null,
      shared = false,
      chats = 0,
      messages = 0,
      bytes = 0,
      skippedChats = 0,
      limitHit = null,
      cancelled = false;

  /// Where the archive was written, or null when it went to the share sheet.
  final String? path;

  /// True when the archive was handed to the system share sheet.
  final bool shared;

  final int chats;
  final int messages;
  final int bytes;

  /// Chats the archive limit kept out. Zero means every chosen chat is in.
  final int skippedChats;

  /// The first limit that was hit, in words the person can act on.
  final String? limitHit;

  /// Why the export failed, or null when it did not.
  final String? message;

  /// True when the user dismissed the picker or the share sheet.
  final bool cancelled;

  bool get isFailure => message != null;
}

/// What a parsed archive holds, shown before anything is uploaded.
@immutable
class V2ImportPreview {
  const V2ImportPreview({
    required this.fileName,
    required this.bytes,
    required this.chats,
    required this.messages,
    this.filesIncluded = 0,
    this.filesUnavailable = 0,
    this.sessions = const <Map<String, dynamic>>[],
  });

  final String fileName;

  /// Size of the file the user chose.
  final int bytes;

  final int chats;
  final int messages;

  /// Attachments the archive carries and that import will upload.
  final int filesIncluded;

  /// Attachments the archive lists but could not carry.
  final int filesUnavailable;

  /// The validated archive rows. Opaque to the page: it is handed back to
  /// [V2DataControlService.importBackup] so the file is parsed exactly once.
  final List<Map<String, dynamic>> sessions;
}

/// One archive chat that could not be added.
@immutable
class V2ImportFailure {
  const V2ImportFailure({required this.item, required this.reason});

  /// The chat title from the archive.
  final String item;

  /// The real reason the server or the network gave.
  final String reason;
}

/// Outcome of adding an archive to the account.
@immutable
class V2ImportOutcome {
  const V2ImportOutcome.completed({
    this.chats = 0,
    this.messages = 0,
    this.duplicates = 0,
    this.skippedChats = 0,
    this.files = 0,
    this.failures = const <V2ImportFailure>[],
  }) : message = null,
       cancelled = false;

  const V2ImportOutcome.cancelled()
    : chats = 0,
      messages = 0,
      duplicates = 0,
      skippedChats = 0,
      files = 0,
      failures = const <V2ImportFailure>[],
      message = null,
      cancelled = true;

  const V2ImportOutcome.failed(
    String this.message, {
    this.chats = 0,
    this.messages = 0,
    this.duplicates = 0,
    this.skippedChats = 0,
    this.files = 0,
    this.failures = const <V2ImportFailure>[],
  }) : cancelled = false;

  final int chats;
  final int messages;
  final int duplicates;
  final int skippedChats;
  final int files;

  /// Chats that could not be added, each with its own reason.
  final List<V2ImportFailure> failures;

  /// A run-level failure, or null when the run finished.
  final String? message;

  final bool cancelled;

  bool get isFailure => message != null;
}

/// Outcome of deleting this device's copy of the account data.
@immutable
class V2DeleteOutcome {
  const V2DeleteOutcome({
    required this.completed,
    required this.failures,
    required this.verified,
  }) : message = null;

  const V2DeleteOutcome.failed(String this.message)
    : completed = 0,
      failures = const <String, String>{},
      verified = false;

  /// Stores that were removed and read back empty.
  final int completed;

  /// Stores that could not be removed, with the reason each gave.
  final Map<String, String> failures;

  /// True only when every store was removed and read back.
  final bool verified;

  /// A run-level failure (for example the reset owner is not connected).
  final String? message;

  int get total => completed + failures.length;

  bool get success => verified && failures.isEmpty && message == null;
}

/// The real work behind the Data control rows.
///
/// The page owns no platform code: it calls this interface and renders the
/// progress and the outcome it gets back. Tests inject a fake; web gets the
/// service from [createDataControlService].
abstract class V2DataControlService {
  /// False when this platform cannot back the rows at all (web). The page then
  /// falls back to a host callback, or hides the row.
  bool get available;

  Future<V2ExportOutcome> exportBackup({
    Set<String>? sessionIds,
    void Function(V2TransferProgress progress)? onProgress,
  });

  /// Picks and validates a backup file. Returns null when the user cancelled;
  /// throws [V2BackupException] when the file is not an importable archive.
  Future<V2ImportPreview?> pickImport();

  Future<V2ImportOutcome> importBackup(
    V2ImportPreview preview, {
    void Function(V2TransferProgress progress)? onProgress,
  });

  /// Bytes currently held in the app's temporary directory.
  Future<int> cacheBytes();

  /// Deletes the temporary directory's contents and returns the bytes freed.
  Future<int> clearCache();

  /// Removes this device's copy of the account data and reads every store
  /// back. Cloud chats and the account itself are out of scope.
  Future<V2DeleteOutcome> deleteDeviceData();
}

/// Web: the rows are backed by the app, so this service is not available.
V2DataControlService createDataControlService() =>
    const _UnavailableDataControlService();

class _UnavailableDataControlService implements V2DataControlService {
  const _UnavailableDataControlService();

  @override
  bool get available => false;

  @override
  Future<V2ExportOutcome> exportBackup({
    Set<String>? sessionIds,
    void Function(V2TransferProgress progress)? onProgress,
  }) async => const V2ExportOutcome.failed('Saving a backup needs the app.');

  @override
  Future<V2ImportPreview?> pickImport() async =>
      throw const V2BackupException('Importing a backup needs the app.');

  @override
  Future<V2ImportOutcome> importBackup(
    V2ImportPreview preview, {
    void Function(V2TransferProgress progress)? onProgress,
  }) async => const V2ImportOutcome.failed('Importing a backup needs the app.');

  @override
  Future<int> cacheBytes() async => 0;

  @override
  Future<int> clearCache() async => 0;

  @override
  Future<V2DeleteOutcome> deleteDeviceData() async =>
      const V2DeleteOutcome.failed('Deleting data needs the app.');
}
