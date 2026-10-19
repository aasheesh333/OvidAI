// SE-008 / SE-009 — Settings → Export & import, backed by Ovid Cloud.
//
// Export pages the signed-in user's FULL history from the gateway
// (`GET /sessions` keyset pages, then every `GET /sessions/:id/messages`
// page) instead of reading the device's 50-message read cache, so a chat the
// user never opened on this phone still exports completely.
//
// Import uploads an archive's chats through `POST /import/sessions` (the same
// route the one-time history import uses). Every message carries a
// deterministic `clientMsgId` (sha256 over its archive identity), and the
// archive-chat → server-session mapping is remembered, so importing the same
// file twice continues into the same server chats and the server skips every
// message it already has. Nothing is written to local session storage: the
// restored chats come back through the normal cloud session refresh.

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state.dart';
import 'cloud_rest.dart';
import 'models.dart';

/// Thrown when the user stops an export or import with [CloudBackupCancelToken].
class CloudBackupCancelled implements Exception {
  const CloudBackupCancelled();
  @override
  String toString() => 'Stopped.';
}

/// Cooperative cancel: checked between every network page / upload chunk.
class CloudBackupCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const CloudBackupCancelled();
  }
}

enum CloudBackupPhase { listing, downloading, uploading }

/// One progress tick. [total] is 0 while the chat list is still being paged.
class CloudBackupProgress {
  const CloudBackupProgress(this.phase, this.done, this.total, this.messages);
  final CloudBackupPhase phase;

  /// Chats finished so far (listing: chats found so far).
  final int done;
  final int total;

  /// Messages fetched (export) or uploaded (import) so far.
  final int messages;

  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);
}

/// The server history as transcript sessions, ready for
/// `SettingsBackupService.export` / `planExport` / `writeJsonExport`.
class CloudExportSnapshot {
  const CloudExportSnapshot({
    required this.sessions,
    required this.messageCount,
    required this.skippedMessages,
  });
  final List<ChatSession> sessions;

  /// User and assistant messages included.
  final int messageCount;

  /// Tool and system rows (not part of the transcript archive format).
  final int skippedMessages;
}

/// Outcome of [CloudBackup.uploadArchiveSessions].
class CloudRestoreReport {
  const CloudRestoreReport({
    required this.chats,
    required this.imported,
    required this.duplicates,
    required this.alreadyInAccount,
    required this.leftOut,
  });

  /// Archive chats uploaded (or continued) into the account.
  final int chats;

  /// Messages the server stored by this run.
  final int imported;

  /// Messages the server already had from an earlier import of this file.
  final int duplicates;

  /// Archive chats that are still in this account (same server id), skipped.
  final int alreadyInAccount;

  /// Reasoning / compacted rows that are not uploaded as replies.
  final int leftOut;
}

/// Thrown when an import stopped after some chats were already uploaded. The
/// uploaded part stays in the account; importing the same file again
/// continues without duplicates.
class CloudRestorePartial implements Exception {
  const CloudRestorePartial(this.cause, this.chatsUploaded);
  final Object cause;
  final int chatsUploaded;
  @override
  String toString() => cause.toString();
}

/// User-facing copy for the Export & import screen. Kept here (not as raw
/// widget literals) until the strings move into the ARB.
abstract final class CloudBackupCopy {
  static const String screenTitle = 'Export & import';
  static const String screenSubtitle =
      'Download your Ovid Cloud chats as an archive, or upload one back.';
  static const String exportButton = 'Export';
  static const String importButton = 'Import archive…';
  static const String stop = 'Stop';
  static const String idle = 'Ready to export';
  static const String archiveReady = 'Archive ready to share';
  static const String statusPrefix = 'Export & import status: ';
  static const String exportHelp =
      'Export downloads every chat in your Ovid Cloud account, then opens '
      'Share / save so you choose where the archive goes.';
  static const String importHelp =
      'Import checks the archive, shows what it holds, and after you confirm '
      'uploads its chats to your Ovid Cloud account, where they keep their '
      'context and sync to your other devices. Importing the same file again '
      'adds nothing twice.';
  static const String jsonHelp =
      'A full JSON dump of your Ovid Cloud chats for other tools. It cannot be '
      'imported.';
  static const String scope =
      'Transcript-only export: the user and assistant messages of every chat '
      'in your Ovid Cloud account. It excludes settings, credentials, '
      'schedules, tool output, attachments, generated images and HTML '
      'artifacts. This is not a full app backup.';
  static const String secrets =
      'Chat text may contain secrets you put in it. It is not redacted. The '
      'export is a ZIP archive with unencrypted stored entries. Modified, '
      'compressed or legacy JSON archives cannot be imported.';
  static const String signInRequired =
      'Sign in to Ovid Cloud to export or import your chats.';

  static String listing(int found) =>
      found == 0 ? 'Finding your chats…' : 'Finding your chats… $found so far';
  static String downloading(int done, int total) =>
      'Downloading chat $done of $total…';
  static String uploading(int done, int total) =>
      'Uploading chat $done of $total…';

  static String limits(int mib, int sessions, int messages) =>
      'Archive limit: $mib MiB; up to $sessions chats / $messages messages.';

  static String _n(int n, String one, String many) =>
      '$n ${n == 1 ? one : many}';

  static String exported(int chats, int messages) =>
      'Exported ${_n(chats, 'chat', 'chats')} · '
      '${_n(messages, 'message', 'messages')}.';
  static String leftOutTool(int n) =>
      ' ${_n(n, 'tool or system row was', 'tool or system rows were')} '
      'left out.';
  static String exportPartial(int kept, int skipped, String limit) =>
      ' It holds your ${_n(kept, 'most recent chat', 'most recent chats')}; '
      '${_n(skipped, 'older chat was', 'older chats were')} left out because '
      'of $limit.';
  static const String exportShared =
      ' Choose where to save the archive in the share sheet.';
  static const String exportNotShared = ' Tap Share archive to save it.';
  static const String exportStopped = 'Export stopped. Nothing was saved.';
  static const String importStopped = 'Import stopped. Nothing was uploaded.';
  static String exportLimit(String limit) =>
      'Export cancelled. Your chats exceed $limit.';
  static String exportPartialPrompt(int kept, int skipped, String limit) =>
      kept == 0
      ? 'Your chats exceed $limit. No chat fits in an archive.'
      : 'Your chats exceed $limit. Export your '
            '${_n(kept, 'most recent chat', 'most recent chats')} now? '
            '${_n(skipped, 'older chat', 'older chats')} will not be included.';
  static const String jsonShared =
      'JSON export ready. Choose where to save it in the share sheet. JSON '
      'files are for other tools and cannot be imported.';
  static const String jsonNotShared =
      'JSON export could not open the share sheet. Try again.';
  static const String shareOpened =
      'Share sheet opened. Choose a destination to save the archive.';
  static const String shareFailed = 'The share sheet could not be opened.';

  static String archiveSummary(int chats, int messages) =>
      'This archive holds ${_n(chats, 'chat', 'chats')} · '
      '${_n(messages, 'message', 'messages')}.';
  static const String importConfirm =
      'They will be uploaded to your Ovid Cloud account as chats that keep '
      'their context, so you can continue them on any device. Existing chats '
      'are not changed, and chats already in your account are skipped.';
  static const String importDeclined = ' Nothing was uploaded.';
  static String imported(CloudRestoreReport r) {
    final out = StringBuffer(
      'Uploaded ${_n(r.chats, 'chat', 'chats')} · '
      '${_n(r.imported, 'message', 'messages')} to your Ovid Cloud account.',
    );
    if (r.duplicates > 0) {
      out.write(
        ' ${_n(r.duplicates, 'message was', 'messages were')} already there.',
      );
    }
    if (r.alreadyInAccount > 0) {
      out.write(
        ' ${_n(r.alreadyInAccount, 'chat is', 'chats are')} already in your '
        'account and were skipped.',
      );
    }
    if (r.leftOut > 0) {
      out.write(
        ' ${_n(r.leftOut, 'reasoning or summary row was', 'reasoning or '
            'summary rows were')} not uploaded.',
      );
    }
    return out.toString();
  }

  static String importPartial(int chats, String reason) =>
      'Import stopped partway.${reason.isEmpty ? '' : ' $reason'} '
      '${_n(chats, 'chat was', 'chats were')} uploaded and stay in your '
      'account; importing the same file again continues without duplicates.';
}

/// Cloud-backed export and import for the Export & import screen.
class CloudBackup {
  CloudBackup({CloudRestClient? rest, SharedPreferences? prefs})
    : _rest = rest ?? CloudRestClient.I,
      _prefsOverride = prefs;

  final CloudRestClient _rest;
  final SharedPreferences? _prefsOverride;

  /// The gateway's MAX_PAGE_LIMIT.
  static const int pageSize = 100;

  /// `POST /import/sessions` rejects more than this per call.
  static const int maxMessagesPerCall = 500;

  /// Archive-chat identity → server session id (continuation for a re-import).
  static const String restoreMapKey = 'ovid_cloud_backup_restore_sessions';

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  // ── Export ───────────────────────────────────────────────────────────────

  /// Every chat in the account with every message, oldest message first.
  Future<CloudExportSnapshot> fetchHistory({
    void Function(CloudBackupProgress progress)? onProgress,
    CloudBackupCancelToken? cancel,
  }) async {
    final dtos = await _listAllSessions(onProgress, cancel);
    final sessions = <ChatSession>[];
    var included = 0;
    var skipped = 0;
    for (var i = 0; i < dtos.length; i++) {
      final dto = dtos[i];
      final rows = <MessageDto>[];
      String? before;
      do {
        cancel?.throwIfCancelled();
        final page = await _rest.pageMessages(
          dto.id,
          limit: pageSize,
          before: before,
        );
        rows.addAll(page.items);
        // Guard against a server that repeats a cursor: never loop forever.
        final next = page.nextCursor;
        before = page.items.isEmpty || next == before ? null : next;
      } while (before != null);
      final messages = <Message>[];
      // Pages are newest-first; the archive is chronological.
      for (final row in rows.reversed) {
        if (row.role != 'user' && row.role != 'assistant') {
          skipped++;
          continue;
        }
        messages.add(
          Message(
            role: row.role,
            content: row.content,
            time: row.createdAt,
            toolState: 'ok',
            privateSyncId: row.id,
          ),
        );
      }
      included += messages.length;
      final title = dto.title?.trim();
      sessions.add(
        ChatSession(
          id: dto.id,
          title: title == null || title.isEmpty ? 'Untitled chat' : title,
          model: 'auto',
          mode: dto.mode,
          createdAt: dto.createdAt,
          updatedAt: dto.updatedAt,
          messages: messages,
        ),
      );
      _emit(
        onProgress,
        CloudBackupProgress(
          CloudBackupPhase.downloading,
          i + 1,
          dtos.length,
          included,
        ),
      );
    }
    return CloudExportSnapshot(
      sessions: List.unmodifiable(sessions),
      messageCount: included,
      skippedMessages: skipped,
    );
  }

  Future<List<SessionDto>> _listAllSessions(
    void Function(CloudBackupProgress progress)? onProgress,
    CloudBackupCancelToken? cancel,
  ) async {
    final out = <SessionDto>[];
    final seen = <String>{};
    String? cursor;
    _emit(
      onProgress,
      const CloudBackupProgress(CloudBackupPhase.listing, 0, 0, 0),
    );
    do {
      cancel?.throwIfCancelled();
      final page = await _rest.listSessions(limit: pageSize, cursor: cursor);
      for (final s in page.items) {
        if (seen.add(s.id)) out.add(s);
      }
      final next = page.nextCursor;
      cursor = page.items.isEmpty || next == cursor ? null : next;
      _emit(
        onProgress,
        CloudBackupProgress(CloudBackupPhase.listing, out.length, 0, 0),
      );
    } while (cursor != null);
    return out;
  }

  // ── Import ───────────────────────────────────────────────────────────────

  /// Uploads validated archive sessions (`StagedSettingsBackup.sessions`).
  ///
  /// Fails before any upload when the account cannot be read (signed out,
  /// offline). A failure after the first upload is a [CloudRestorePartial].
  Future<CloudRestoreReport> uploadArchiveSessions(
    List<Map<String, dynamic>> sessions, {
    void Function(CloudBackupProgress progress)? onProgress,
    CloudBackupCancelToken? cancel,
  }) async {
    // Also the sign-in / reachability check: nothing is uploaded unless the
    // account's chat list could be read.
    final existing = {
      for (final s in await _listAllSessions(null, cancel)) s.id,
    };
    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    final map = _readMap(prefs);
    var chats = 0;
    var imported = 0;
    var duplicates = 0;
    var already = 0;
    var leftOut = 0;
    var uploadedChats = 0;
    for (var s = 0; s < sessions.length; s++) {
      final session = sessions[s];
      final archiveId = session['id'] as String;
      if (_uuid.hasMatch(archiveId) && existing.contains(archiveId)) {
        already++;
        _emitUpload(onProgress, s + 1, sessions.length, imported + duplicates);
        continue;
      }
      final batch = <ImportMessage>[];
      final rows = session['messages'] as List;
      for (var i = 0; i < rows.length; i++) {
        final m = Map<String, dynamic>.from(rows[i] as Map);
        if (m['kind'] != 'text') {
          leftOut++;
          continue;
        }
        batch.add(
          ImportMessage(
            clientMsgId: clientMsgIdFor(archiveId, i, m),
            role: m['role'] as String,
            content: m['content'] as String,
            createdAt: DateTime.parse(m['time'] as String),
          ),
        );
      }
      if (batch.isEmpty) {
        _emitUpload(onProgress, s + 1, sessions.length, imported + duplicates);
        continue;
      }
      final key = _sessionKey(session);
      final title = session['title'] as String?;
      final createdAt = DateTime.parse(session['createdAt'] as String);
      try {
        var serverId = map[key];
        for (var c = 0; c < batch.length; c += maxMessagesPerCall) {
          cancel?.throwIfCancelled();
          final chunk = batch.sublist(
            c,
            math.min(c + maxMessagesPerCall, batch.length),
          );
          ImportReport report;
          try {
            report = await _rest.importMessages(
              sessionId: serverId,
              title: serverId == null ? title : null,
              createdAt: serverId == null ? createdAt : null,
              messages: chunk,
            );
          } on CloudApiException catch (e) {
            // The remembered chat was deleted (or belongs to another
            // account): start a fresh one and re-send from the first chunk.
            if (e.status != 404 || serverId == null) rethrow;
            map.remove(key);
            serverId = null;
            c = -maxMessagesPerCall;
            continue;
          }
          if (serverId == null) {
            serverId = report.sessionId;
            map[key] = serverId;
            await prefs.setString(restoreMapKey, jsonEncode(map));
          }
          imported += report.imported;
          duplicates += report.skipped;
          uploadedChats = chats + 1;
        }
      } catch (e) {
        if (uploadedChats > 0) throw CloudRestorePartial(e, uploadedChats);
        rethrow;
      }
      chats++;
      _emitUpload(onProgress, s + 1, sessions.length, imported + duplicates);
    }
    return CloudRestoreReport(
      chats: chats,
      imported: imported,
      duplicates: duplicates,
      alreadyInAccount: already,
      leftOut: leftOut,
    );
  }

  /// sha256 over the archive identity of one message: 64 hex chars, exactly
  /// the server's `clientMsgId` limit. Same file → same ids → no duplicates.
  static String clientMsgIdFor(
    String archiveSessionId,
    int index,
    Map<String, dynamic> message,
  ) {
    final input = <String>[
      'ovid-backup-v1',
      archiveSessionId,
      '$index',
      '${message['role']}',
      '${message['time']}',
      '${message['content']}',
    ].join('\u0000');
    return sha256.convert(utf8.encode(input)).toString();
  }

  static String _sessionKey(Map<String, dynamic> session) => sha256
      .convert(utf8.encode('${session['id']}\u0000${session['createdAt']}'))
      .toString();

  static Map<String, String> _readMap(SharedPreferences prefs) {
    final raw = prefs.getString(restoreMapKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  static void _emitUpload(
    void Function(CloudBackupProgress progress)? onProgress,
    int done,
    int total,
    int messages,
  ) => _emit(
    onProgress,
    CloudBackupProgress(CloudBackupPhase.uploading, done, total, messages),
  );

  /// Progress reporting never fails the operation. A cancel requested from
  /// inside the callback is honoured at the next checkpoint.
  static void _emit(
    void Function(CloudBackupProgress progress)? onProgress,
    CloudBackupProgress progress,
  ) {
    try {
      onProgress?.call(progress);
    } catch (_) {}
  }
}
