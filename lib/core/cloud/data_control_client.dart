/// The two destructive account routes:
///   POST /cloud/v1/data/delete-all
///   POST /cloud/v1/memory/reset
///
/// The contract is the BUILT gateway, not a sketch:
///   cloud/apps/gateway/src/routes/dataControl.ts
///
///   * The body is STRICT: exactly `{ "confirmation": "<typed email>" }`. The
///     caller's uid comes from the bearer token; a body `uid` is rejected by
///     the server's `.strict()` schema, so this client never adds one.
///   * Phone confirmation does not exist server-side (no phone is stored on
///     the account), so this client never offers or sends one.
///   * A refusal is reduced to a status + code. The server's `message` is
///     dropped on purpose: screens say their own one plain sentence, so raw
///     provider or deployment text can never reach the UI.
///   * Nothing is claimed here. The counts in [DataDeletionCounts] and the
///     file count from [DataControlClient.resetMemory] are the server's
///     answer; a caller that did not receive one must not say "deleted".
library;

import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

/// What the server confirmed it deleted (`{deleted:{...}}`).
@immutable
class DataDeletionCounts {
  const DataDeletionCounts({
    this.sessions = 0,
    this.attachments = 0,
    this.artifacts = 0,
    this.workspaceFiles = 0,
    this.storageObjects = 0,
  });

  /// Throws [DataControlFailure] when the envelope is missing or malformed:
  /// a 200 that does not say what was deleted is not a success to report.
  factory DataDeletionCounts.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const DataControlFailure(status: 0, code: 'invalid_response');
    }
    int count(String key) {
      final value = raw[key];
      if (value is! num || !value.isFinite || value < 0) {
        throw const DataControlFailure(status: 0, code: 'invalid_response');
      }
      return value.toInt();
    }

    return DataDeletionCounts(
      sessions: count('sessions'),
      attachments: count('attachments'),
      artifacts: count('artifacts'),
      workspaceFiles: count('workspaceFiles'),
      storageObjects: count('storageObjects'),
    );
  }

  final int sessions;
  final int attachments;
  final int artifacts;
  final int workspaceFiles;
  final int storageObjects;

  /// Chats plus files plus artifacts plus workspace archives. Storage objects
  /// are bytes behind those rows, so they are not counted again here.
  int get total => sessions + attachments + artifacts + workspaceFiles;

  /// A second call is a success with zeroes; the screen says so instead of
  /// implying it deleted something.
  bool get isEmpty => total == 0 && storageObjects == 0;
}

/// One refused action, reduced to what a screen may say.
///
/// Deliberately not a [CloudApiException]: this type cannot carry the
/// server's prose, so a screen that renders [message] is structurally unable
/// to repeat provider text.
@immutable
class DataControlFailure implements Exception {
  const DataControlFailure({required this.status, required this.code});

  /// The HTTP status, or 0 when no answer arrived (timeout/unreachable) or
  /// the answer was malformed.
  final int status;

  /// The gateway's `error.code` (`confirmation_mismatch`, …), `unreachable`,
  /// `timeout` or `invalid_response`.
  final String code;

  /// The one sentence the screen shows.
  String get message => dataControlFailureMessage(status: status, code: code);

  @override
  String toString() => 'DataControlFailure($status $code)';
}

/// One plain sentence per refusal. The code decides; the status only breaks
/// ties (auth, rate limit, unknown), so a new server code can never surface
/// as raw text.
String dataControlFailureMessage({required int status, required String code}) {
  switch (code) {
    case 'confirmation_mismatch':
      return 'Type the email address registered on this account to confirm.';
    case 'confirmation_unavailable':
      return 'This action needs an email address on your account.';
    case 'storage_not_configured':
      // A deployment setting, not a transient fault: retrying changes nothing
      // until the operator configures storage, so do not tell them to.
      return 'Files cannot be removed right now, so nothing was deleted.';
    case 'storage_delete_failed':
      return 'Your chats were not deleted. Stored-file removal may be '
          'incomplete; try again to finish.';
    case 'client_upgrade_required':
      return 'Update Ovid Si before deleting your data. Nothing was deleted.';
    case 'storage_delete_partial':
      return 'Some stored files were removed before this failed. '
          'Your chats remain; try again to finish.';
    case 'timeout':
    case 'unreachable':
      return 'Ovid Cloud did not answer, so the result is unknown. '
          'Check your data before retrying.';
    case 'invalid_response':
      return 'Ovid Cloud answered unexpectedly, so the result is unknown. '
          'Check your data before retrying.';
    case 'unauthenticated':
    case 'app_check_unavailable':
      return 'Sign in to Ovid Cloud first.';
  }
  if (status == 401 || status == 403) return 'Sign in to Ovid Cloud first.';
  if (status == 409) return 'This action is unavailable on this account.';
  if (status == 429) {
    return 'Too many attempts. Wait a moment and try again.';
  }
  return 'Ovid could not confirm the result. Check your data before trying again.';
}

/// Thin client over the two destructive routes.
///
/// Both calls are idempotent set deletes: a second call answers 200 with
/// zeroes, so a retry after an ambiguous failure is safe.
class DataControlClient {
  DataControlClient({CloudRestClient? rest})
    : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static DataControlClient? _instance;

  /// Process-wide default.
  static DataControlClient get I => _instance ??= DataControlClient();

  /// Test wiring only.
  @visibleForTesting
  static void installForTest(DataControlClient client) => _instance = client;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// POST /data/delete-all — every chat and everything a chat owns, plus the
  /// storage bytes those rows reference.
  Future<DataDeletionCounts> deleteAll({required String confirmation}) {
    return _post('/data/delete-all', confirmation, (json) {
      return DataDeletionCounts.fromJson(json['deleted']);
    });
  }

  /// POST /memory/reset — every memory file the account owns: chat, project
  /// and the shared (global) file. Returns how many the server removed.
  Future<int> resetMemory({required String confirmation}) {
    return _post('/memory/reset', confirmation, (json) {
      final reset = json['reset'];
      final files = reset is Map ? reset['files'] : null;
      if (files is! num || !files.isFinite || files < 0) {
        throw const DataControlFailure(status: 0, code: 'invalid_response');
      }
      return files.toInt();
    });
  }

  Future<T> _post<T>(
    String path,
    String confirmation,
    T Function(Map<String, dynamic> json) parse,
  ) async {
    final Map<String, dynamic> json;
    try {
      // The one body field. The typed value goes verbatim; the server trims
      // and compares case-insensitively, and its refusal is the gate.
      json = await _rest.postJson(
        path,
        body: {'confirmation': confirmation},
        headers: const {
          'x-ovid-client-capabilities': 'data-control-partial-v1',
        },
      );
    } on CloudApiException catch (e) {
      throw DataControlFailure(status: e.status, code: e.code);
    } catch (_) {
      throw const DataControlFailure(status: 0, code: 'unreachable');
    }
    try {
      return parse(json);
    } on DataControlFailure {
      rethrow;
    } catch (_) {
      throw const DataControlFailure(status: 0, code: 'invalid_response');
    }
  }
}
