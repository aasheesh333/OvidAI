/// Native implementation of the Data control actions.
///
/// Only compiled when `dart:library.io` exists, so it may reach the cloud
/// backup service, the zip writer, the platform save dialog and the app's
/// temporary directory. Every method returns what actually happened: a saved
/// path, a shared file, a per-chat import failure or the bytes a cache clear
/// freed.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:path_provider/path_provider.dart';

import '../../../core/cloud/cloud_backup.dart';
import '../../../core/cloud/cloud_rest.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/diag.dart';
import '../../../core/native_share.dart';
import '../../../core/settings_actions.dart';
import '../../../core/settings_backup_service.dart';
import 'data_control_export.dart';
import 'storage_page.dart' show clearTemporaryCache;

// The page imports this file *instead of* the web one when dart:io exists, so
// the shared contract types have to travel with it.
export 'data_control_export.dart' hide createDataControlService;

/// The production service: real cloud history, real zip, real share sheet.
V2DataControlService createDataControlService() =>
    const _IoDataControlService();

/// The archive name the app has always written. Kept so a file saved by an
/// older build still imports.
const String _archiveName = 'ovid-transcripts-v1.zip';

class _IoDataControlService implements V2DataControlService {
  const _IoDataControlService();

  @override
  bool get available => true;

  // ── Export ────────────────────────────────────────────────────────────────

  @override
  Future<V2ExportOutcome> exportBackup({
    Set<String>? sessionIds,
    void Function(V2TransferProgress progress)? onProgress,
  }) async {
    Directory? scratch;
    try {
      onProgress?.call(const V2TransferProgress(label: 'Reading your chats…'));
      final snapshot = await CloudBackup().fetchHistory(
        onProgress: (progress) => onProgress?.call(_exportProgress(progress)),
      );
      // Null means "every chat"; a set carries the picker's real selection, so
      // a tick the user cleared can never reappear in the archive.
      final chosen = sessionIds == null
          ? snapshot.sessions
          : [
              for (final session in snapshot.sessions)
                if (sessionIds.contains(session.id)) session,
            ];
      final plan = SettingsBackupService.planExport(chosen);
      if (plan.included.isEmpty) {
        return V2ExportOutcome.failed(
          plan.limitHit ?? 'There is nothing to export yet.',
        );
      }
      onProgress?.call(const V2TransferProgress(label: 'Packing backup…'));
      final bytes = await SettingsBackupService().export(plan.included);
      final messages = plan.included.fold<int>(
        0,
        (sum, session) => sum + session.messages.length,
      );

      final temp = await getTemporaryDirectory();
      scratch = await temp.createTemp('ovid-backup-');
      final file = File('${scratch.path}/$_archiveName');
      await file.writeAsBytes(bytes, flush: true);

      onProgress?.call(const V2TransferProgress(label: 'Opening share sheet…'));
      try {
        // Android stages its own short-lived copy before the chooser opens.
        await NativeShare.file(file.path);
        return V2ExportOutcome.shared(
          chats: plan.included.length,
          messages: messages,
          bytes: bytes.length,
          skippedChats: plan.skipped.length,
          limitHit: plan.limitHit,
        );
      } on MissingPluginException {
        // Desktop and the test host have no native channel: fall through to
        // the platform save dialog, which is still a real file.
      } on PlatformException {
        // The share sheet refused; the save dialog is the honest fallback.
      }

      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Ovid backup',
        fileName: _archiveName,
        type: FileType.custom,
        allowedExtensions: const <String>['zip'],
        bytes: bytes,
      );
      if (path == null) return const V2ExportOutcome.cancelled();
      return V2ExportOutcome.saved(
        path,
        chats: plan.included.length,
        messages: messages,
        bytes: bytes.length,
        skippedChats: plan.skipped.length,
        limitHit: plan.limitHit,
      );
    } on CloudBackupCancelled {
      return const V2ExportOutcome.cancelled();
    } catch (error) {
      return V2ExportOutcome.failed(_reason(error));
    } finally {
      // The archive lives in the user's destination (or the share sheet's
      // own cache); this copy is only scratch.
      if (scratch != null) {
        try {
          if (await scratch.exists()) await scratch.delete(recursive: true);
        } catch (error) {
          Diag.swallow('data_control.export_cleanup', error);
        }
      }
    }
  }

  static V2TransferProgress _exportProgress(CloudBackupProgress progress) {
    return switch (progress.phase) {
      CloudBackupPhase.listing => V2TransferProgress(
        label: progress.done == 0
            ? 'Finding your chats…'
            : 'Finding chats… ${progress.done}',
      ),
      CloudBackupPhase.downloading => V2TransferProgress(
        label: 'Downloading chat ${progress.done} of ${progress.total}…',
        fraction: progress.fraction,
      ),
      CloudBackupPhase.uploading => V2TransferProgress(
        label: 'Uploading chat ${progress.done} of ${progress.total}…',
        fraction: progress.fraction,
      ),
    };
  }

  // ── Import ────────────────────────────────────────────────────────────────

  @override
  Future<V2ImportPreview?> pickImport() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final path = picked.files.single.path;
    if (path == null) {
      throw const V2BackupException('That file could not be read.');
    }
    final file = File(path);
    final length = await file.length();
    if (length > SettingsBackupService.maxArchiveBytes) {
      throw const V2BackupException('That file is larger than 64 MB.');
    }
    final temp = await getTemporaryDirectory();
    final StagedSettingsBackup staged;
    try {
      staged = await SettingsBackupService().stage(
        await file.readAsBytes(),
        temp,
      );
    } on FormatException {
      throw const V2BackupException('That file is not an Ovid backup.');
    } on FileSystemException {
      throw const V2BackupException('That file could not be read.');
    }
    try {
      final sessions = List<Map<String, dynamic>>.of(staged.sessions);
      if (sessions.isEmpty) {
        throw const V2BackupException('That archive has no chats.');
      }
      var messages = 0;
      for (final session in sessions) {
        messages += (session['messages'] as List?)?.length ?? 0;
      }
      return V2ImportPreview(
        fileName: _fileName(path),
        bytes: length,
        chats: sessions.length,
        messages: messages,
        filesIncluded: staged.attachments.length,
        sessions: sessions,
      );
    } finally {
      await staged.dispose();
    }
  }

  @override
  Future<V2ImportOutcome> importBackup(
    V2ImportPreview preview, {
    void Function(V2TransferProgress progress)? onProgress,
  }) async {
    final backup = CloudBackup();
    // Chats already in the account are skipped by the service without counting
    // them, which would make a later per-chat failure point at the wrong row.
    // Reading the account first also fails here, before anything uploads.
    final Set<String> existing;
    try {
      existing = await _existingSessionIds();
    } catch (error) {
      return V2ImportOutcome.failed(_reason(error));
    }
    var skippedChats = 0;
    final fresh = <Map<String, dynamic>>[];
    for (final session in preview.sessions) {
      final id = session['id'];
      if (id is String && _uuid.hasMatch(id) && existing.contains(id)) {
        skippedChats++;
      } else {
        fresh.add(session);
      }
    }
    var remaining = fresh;
    final failures = <V2ImportFailure>[];
    var chats = 0;
    var messages = 0;
    var duplicates = 0;

    void tick(int done) => onProgress?.call(
      V2TransferProgress(
        label: 'Uploading chat $done of ${preview.chats}…',
        fraction: preview.chats == 0 ? null : done / preview.chats,
      ),
    );

    while (remaining.isNotEmpty) {
      try {
        final report = await backup.uploadArchiveSessions(
          remaining,
          onProgress: (progress) {
            if (progress.phase != CloudBackupPhase.uploading) return;
            tick(progress.done);
          },
        );
        chats += report.chats;
        messages += report.imported;
        duplicates += report.duplicates;
        skippedChats += report.alreadyInAccount;
        break;
      } on CloudRestorePartial catch (partial) {
        // The service uploads in archive order and stops at the first chat it
        // cannot write, so the failing row is the one just past the uploaded
        // count. It is named with the server's own reason.
        final failed = partial.chatsUploaded;
        chats += failed;
        if (failed < remaining.length) {
          failures.add(
            V2ImportFailure(
              item: _titleOf(remaining[failed]),
              reason: _reason(partial.cause),
            ),
          );
          remaining = remaining.sublist(failed + 1);
          tick(chats + failures.length);
        } else {
          remaining = const <Map<String, dynamic>>[];
          return V2ImportOutcome.failed(
            _reason(partial.cause),
            chats: chats,
            messages: messages,
            duplicates: duplicates,
            skippedChats: skippedChats,
            files: preview.filesIncluded,
            failures: failures,
          );
        }
      } on CloudBackupCancelled {
        return const V2ImportOutcome.cancelled();
      } catch (error) {
        return V2ImportOutcome.failed(
          _reason(error),
          chats: chats,
          messages: messages,
          duplicates: duplicates,
          skippedChats: skippedChats,
          files: preview.filesIncluded,
          failures: failures,
        );
      }
    }

    try {
      // The imported chats become ordinary cloud chats in the sidebar.
      await CloudSessionStore.I.refreshSessions();
    } catch (error) {
      Diag.swallow('data_control.import_refresh', error);
    }

    return V2ImportOutcome.completed(
      chats: chats,
      messages: messages,
      duplicates: duplicates,
      skippedChats: skippedChats,
      files: preview.filesIncluded,
      failures: failures,
    );
  }

  static String _titleOf(Map<String, dynamic> session) {
    final title = (session['title'] as String?)?.trim() ?? '';
    return title.isEmpty ? 'Untitled chat' : title;
  }

  // ── Cache ─────────────────────────────────────────────────────────────────

  @override
  Future<int> cacheBytes() async {
    final dir = await getTemporaryDirectory();
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        bytes += await entity.length();
      } catch (error) {
        Diag.swallow('data_control.cache_size', error);
      }
    }
    return bytes;
  }

  @override
  Future<int> clearCache() => clearTemporaryCache();

  // ── Delete ────────────────────────────────────────────────────────────────

  @override
  Future<V2DeleteOutcome> deleteDeviceData() async {
    final reset = SettingsActions.resetAll;
    if (reset == null) {
      return const V2DeleteOutcome.failed(
        'Deletion is not connected. Nothing was deleted.',
      );
    }
    try {
      // The verified reset fences writers, removes every local store and reads
      // each one back; the report is the only success signal.
      final result = await reset();
      return V2DeleteOutcome(
        completed: result.completed.length,
        failures: Map<String, String>.of(result.failures),
        verified: result.verifiedComplete,
      );
    } catch (error) {
      return V2DeleteOutcome.failed(_reason(error));
    }
  }
}

String _fileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.isEmpty ? path : parts.last;
}

/// The server session ids already in this account. Also the sign-in and
/// reachability check: nothing is uploaded unless this read succeeds.
Future<Set<String>> _existingSessionIds() async {
  final ids = <String>{};
  String? cursor;
  do {
    final page = await CloudRestClient.I.listSessions(
      limit: 100,
      cursor: cursor,
    );
    for (final session in page.items) {
      ids.add(session.id);
    }
    final next = page.nextCursor;
    cursor = page.items.isEmpty || next == cursor ? null : next;
  } while (cursor != null);
  return ids;
}

/// Same shape `CloudBackup` uses to decide a chat is already in the account.
final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// One honest sentence for a failure, never a stack trace.
String _reason(Object error) {
  if (error is V2BackupException) return error.message;
  if (error is BackupLimitException) return error.message;
  if (error is FormatException) return 'That file is not an Ovid backup.';
  if (error is CloudApiException) {
    if (error.status == 401 || error.status == 403) {
      return 'Sign in to Ovid Cloud first.';
    }
    return error.message;
  }
  if (error is MissingPluginException) {
    return 'This device cannot open the share sheet.';
  }
  if (error is FileSystemException) {
    return 'The file could not be written. Check free space.';
  }
  return 'Could not finish. Try again.';
}
