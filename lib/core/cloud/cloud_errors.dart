/// Human copy and recovery actions for every cloud send / run failure
/// (Wave 1a — CH-012, CH-019, CH-020, CH-031).
///
/// One table, used by the chat error row, the projection's inline failure
/// row and the outbox: a failure code always reads as a sentence a user can
/// act on, never a snake_case identifier, an HTTP status or provider stack
/// text. The raw server text survives only as optional detail.
library;

import 'dart:async' show TimeoutException;
import 'dart:io' show FileSystemException, HttpException, SocketException;

import 'cloud_rest.dart' show CloudApiException;
import 'error_text.dart';

/// What the user can do about a failure.
enum CloudErrorAction {
  /// Re-send the same prompt (same clientMsgId — never a double run).
  retry,

  /// The Ovid session expired: sign in again.
  signIn,

  /// The plan allowance ran out: open Plans.
  openPlans,

  /// The model is not available: open the model picker.
  pickModel,

  /// Nothing to do but wait (the app retries by itself).
  wait,

  /// Informational only.
  none,
}

/// How the outbox treats a delivery failure.
enum CloudFailureKind {
  /// Network/timeout/429/5xx: keep the prompt and retry with backoff.
  transient,

  /// The server refused this prompt (4xx). Keep it, mark it "Not sent" and
  /// let the user retry or discard — never drop it silently.
  refused,

  /// 409 `run_conflict`: the clientMsgId is already used — the prompt was
  /// accepted earlier, nothing to resend.
  alreadyAccepted,
}

/// Classifies a send failure (any thrown object, not only
/// [CloudApiException] — CH-012: a DNS failure on a brand-new chat must not
/// escape as an unhandled exception).
CloudFailureKind classifyCloudFailure(Object error) {
  if (error is CloudApiException) {
    final s = error.status;
    if (s == 409 && error.code == 'run_conflict') {
      return CloudFailureKind.alreadyAccepted;
    }
    if (s == 0 || s == 408 || s == 425 || s == 429 || s >= 500) {
      return CloudFailureKind.transient;
    }
    return CloudFailureKind.refused;
  }
  if (error is FileSystemException) return CloudFailureKind.refused;
  // SocketException, ClientException, TimeoutException, HandshakeException,
  // an App Check / token mint hiccup: all "could not reach Ovid right now".
  return CloudFailureKind.transient;
}

/// The stable failure code for any thrown object.
String cloudFailureCode(Object error) {
  if (error is CloudApiException) return error.code;
  if (error is FileSystemException) return 'attachment_missing';
  if (error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return 'network';
  }
  final text = '$error';
  if (text.contains('ClientException') ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused') ||
      text.contains('HandshakeException')) {
    return 'network';
  }
  return 'internal';
}

/// A user-facing rendering of one failure.
class CloudErrorCopy {
  const CloudErrorCopy({
    required this.text,
    required this.action,
    this.detail,
  });

  /// One or two plain sentences.
  final String text;
  final CloudErrorAction action;

  /// Raw server text, for an optional "Details" expander only.
  final String? detail;
}

/// The code → copy table. [message] is the server's own text; it is shown
/// only when it reads as human prose (never provider exceptions or stack
/// traces). [resetsAt] is the 402 allowance reset instant.
CloudErrorCopy cloudErrorCopy(
  String code, {
  String? message,
  DateTime? resetsAt,
  DateTime? now,
}) {
  final raw = (message ?? '').trim();
  final detail = raw.isEmpty || raw == code ? null : raw;
  switch (code) {
    case 'cancelled':
      return const CloudErrorCopy(
          text: 'Stopped.', action: CloudErrorAction.none);
    case 'daily_limit_reached':
      final when = resetsAt == null ? null : _resetPhrase(resetsAt, now);
      return CloudErrorCopy(
        text: when == null
            ? 'You have used your plan allowance for now. Upgrade for more, '
                'or try again later.'
            : 'You have used your plan allowance. It resets $when. '
                'Upgrade for more.',
        action: CloudErrorAction.openPlans,
        detail: detail,
      );
    case 'rate_limited':
      return CloudErrorCopy(
        text: 'Ovid is busy right now. Your message will be sent '
            'automatically in a moment.',
        action: CloudErrorAction.wait,
        detail: detail,
      );
    case 'unauthenticated':
    case 'sign_in_required':
    case 'forbidden':
    case 'invalid_authentication':
    case 'invalid_attestation':
    case 'reauthentication_required':
    case 'invalid_identity':
    case 'unsupported_identity':
    case 'reset_required':
      return CloudErrorCopy(
        text: 'Your Ovid session expired. Sign in again to continue.',
        action: CloudErrorAction.signIn,
        detail: detail,
      );
    case 'app_check_unavailable':
      return CloudErrorCopy(
        text: 'Ovid could not verify this copy of the app. Restart it and '
            'try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'timeout':
    case 'network':
    case 'request_timeout':
    case 'unreachable':
      return CloudErrorCopy(
        text: 'Connection problem. Ovid could not be reached.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'unavailable':
    case 'internal':
    case 'server_error':
    case 'upstream_error':
    case 'temporarily_unavailable':
    case 'no_provider':
    case 'method_not_allowed':
    case 'invalid_record':
    case 'key_layout':
    case 'group_max_ceiling':
    case 'evict_local_failed':
    case 'hibernate_failed':
      return CloudErrorCopy(
        text: 'Ovid had a problem handling this message. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'key_not_minted':
      return CloudErrorCopy(
        text: 'Ovid could not set up model access for your account. '
            'Try again in a moment.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'model_unavailable':
    case 'model_not_found':
    case 'unknown_model':
      return CloudErrorCopy(
        text: 'That model is not available on Ovid Cloud. Pick another '
            'model.',
        action: CloudErrorAction.pickModel,
        detail: detail,
      );
    case 'manual_model_not_allowed':
      return CloudErrorCopy(
        text: 'Your plan uses Auto only. Switch the model to Auto.',
        action: CloudErrorAction.pickModel,
        detail: detail,
      );
    case 'catalog_unavailable':
      return CloudErrorCopy(
        text: 'The model list could not be loaded. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'model_no_vision':
      return CloudErrorCopy(
        text: 'The selected model cannot read images. Pick a model that '
            'supports images, or remove the image.',
        action: CloudErrorAction.pickModel,
        detail: detail,
      );
    case 'unsupported_modality':
      return CloudErrorCopy(
        text: 'That model cannot handle this input. Pick another model.',
        action: CloudErrorAction.pickModel,
        detail: detail,
      );
    case 'model_terminal':
    case 'model_transient_exhausted':
      return CloudErrorCopy(
        text: 'The model provider failed to answer. Try again or pick '
            'another model.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'run_lost':
      return CloudErrorCopy(
        text: 'The task was interrupted on the server. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'run_queue_wait_timeout':
      return CloudErrorCopy(
        text: 'Your earlier task took too long, so this one did not start. '
            'Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'tool_rounds_exhausted':
      return CloudErrorCopy(
        text: 'The task used its step limit before finishing. Ask the agent '
            'to continue.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'hydrate_failed':
      return CloudErrorCopy(
        text: 'Your workspace could not be woken up. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'not_warm':
    case 'hydrate_timeout':
    case 'hydrating':
      return CloudErrorCopy(
        text: 'Your workspace is still starting. Try again in a moment.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'workspace_lost':
    case 'pty_gone':
      return CloudErrorCopy(
        text: 'The workspace restarted. Reopen this chat to continue.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'sandbox_busy':
    case 'workspace_busy':
    case 'session_busy':
      return CloudErrorCopy(
        text: 'Ovid is still working on this chat. Stop it, then try again.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'sandbox_unavailable':
      return CloudErrorCopy(
        text: 'Ovid could not start a workspace. Try again in a moment.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'disk_pressure':
      return CloudErrorCopy(
        text: 'The workspace is out of space. Remove a file and try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'baseline_mismatch':
      return CloudErrorCopy(
        text: 'That file changed since you opened it. Reload it and try '
            'again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'credential_leak':
      return CloudErrorCopy(
        text: 'That looked like a secret, so it was not sent. Remove the '
            'key and retry.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'no_workspace':
      return CloudErrorCopy(
        text: 'This chat has no workspace yet. Send a message to create one.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'not_attached':
    case 'not_controller':
      return CloudErrorCopy(
        text: 'You no longer control this browser tab. Reconnect to continue.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'run_not_cancellable':
      return CloudErrorCopy(
        text: 'That task already finished, so it could not be stopped.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'run_merged':
      return CloudErrorCopy(
        text: 'That message was already accepted. Wait for the reply.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'subagent_limit_exceeded':
      return CloudErrorCopy(
        text: 'Too many subagents are running. Wait for one to finish.',
        action: CloudErrorAction.wait,
        detail: detail,
      );
    case 'subagent_nested':
      return CloudErrorCopy(
        text: 'A subagent cannot start another subagent.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'subagent_log_failed':
      return CloudErrorCopy(
        text: 'Ovid could not save the subagent log. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'project_file_limit':
      return CloudErrorCopy(
        text: 'This project has reached its file limit. Remove a file first.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'limit_reached':
      return CloudErrorCopy(
        text: "You have reached your plan's limit. Remove one, or open Plans.",
        action: CloudErrorAction.openPlans,
        detail: detail,
      );
    case 'pro_required':
    case 'tier_required':
      return CloudErrorCopy(
        text: 'This needs a higher plan. Open Plans to upgrade.',
        action: CloudErrorAction.openPlans,
        detail: detail,
      );
    case 'billing_unavailable':
    case 'no_priced_model':
      return CloudErrorCopy(
        text: 'Plans cannot be loaded right now. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'name_taken':
    case 'label_taken':
    case 'server_exists':
    case 'already_exists':
      return CloudErrorCopy(
        text: 'That name is already in use. Choose another.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'not_empty':
      return CloudErrorCopy(
        text: 'That folder is not empty. Remove its contents first.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'file_too_large':
    case 'attachment_too_large':
      return CloudErrorCopy(
        text: 'That file is too large to send. Choose a smaller one.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'attachments_not_configured':
      return CloudErrorCopy(
        text: 'File uploads are unavailable right now. Try again later.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'unsupported_media_type':
      return CloudErrorCopy(
        text: 'That file type cannot be sent. Choose another file.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'upload_unverified':
    case 'hash_mismatch':
    case 'r2_short_read':
    case 'artifact_length_mismatch':
    case 'archive_length_mismatch':
    case 'file_not_in_archive':
      return CloudErrorCopy(
        text: 'That file did not upload completely. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'archive_corrupt':
    case 'archive_truncated':
    case 'archive_worker_exit':
      return CloudErrorCopy(
        text: 'That backup could not be read. Choose another file.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'image_capacity_unavailable':
    case 'no_capacity':
      return CloudErrorCopy(
        text: 'Image generation is full right now. Try again in a moment.',
        action: CloudErrorAction.wait,
        detail: detail,
      );
    case 'image_access_denied':
      return CloudErrorCopy(
        text: 'Image generation is not available on your plan. Open Plans.',
        action: CloudErrorAction.openPlans,
        detail: detail,
      );
    case 'image_request_pending':
      return CloudErrorCopy(
        text: 'That image is still being generated. Wait a moment.',
        action: CloudErrorAction.wait,
        detail: detail,
      );
    case 'image_unavailable':
    case 'image_request_failed':
      return CloudErrorCopy(
        text: 'That image could not be generated. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'account_deletion_pending':
    case 'account_deleted':
    case 'account_fenced':
      return CloudErrorCopy(
        text: 'This account cannot be used. Contact support.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'account_changed':
      return CloudErrorCopy(
        text: 'The account changed. Sign in again and retry.',
        action: CloudErrorAction.signIn,
        detail: detail,
      );
    case 'credential_unavailable':
      return CloudErrorCopy(
        text: 'Live chat credentials are unavailable. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'schema_version_unsupported':
    case 'endpoint_rejected':
      return CloudErrorCopy(
        text: 'This version of Ovid is out of date. Update the app to '
            'continue.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'not_member':
      return CloudErrorCopy(
        text: 'You are not a member of this space.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'ui_manifest_budget':
      return CloudErrorCopy(
        text: 'This app has too many screens to publish. Remove one and '
            'retry.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'validation_error':
    case 'invalid_arg':
    case 'invalid_request':
    case 'unsupported_n':
    case 'unsupported_size':
    case 'bad_message':
      return CloudErrorCopy(
        text: 'Ovid could not accept that. Change it and try again.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'attachment_unavailable':
    case 'attachment_missing':
      return CloudErrorCopy(
        text: 'An attached file could not be read. Attach it again and '
            'resend.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'hook_blocked':
    case 'hook_block_ignored':
      return CloudErrorCopy(
        text: raw.isNotEmpty && isHumanFailureText(raw)
            ? 'A workspace hook blocked this message: $raw'
            : 'A workspace hook blocked this message.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'too_many_subscriptions':
      return CloudErrorCopy(
        text: 'Too many chats are open for live updates. Reopen this chat.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'payload_too_large':
      return CloudErrorCopy(
        text: 'This message or file is too large to send.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'bad_request':
      return CloudErrorCopy(
        text: raw.isNotEmpty && isHumanFailureText(raw)
            ? raw
            : 'Ovid could not accept this message.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'not_found':
      return CloudErrorCopy(
        text: 'That is no longer on Ovid Cloud. Go back and try again.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'no_session':
      return const CloudErrorCopy(
        text: 'Start a chat first.',
        action: CloudErrorAction.none,
      );
    case 'authentication_required':
      return CloudErrorCopy(
        text: 'Your Ovid session expired. Sign in again to continue.',
        action: CloudErrorAction.signIn,
        detail: detail,
      );
    case 'explicit_consent_required':
      return CloudErrorCopy(
        text: 'Accept the updated terms to continue.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'model_catalog_unavailable':
      return CloudErrorCopy(
        text: 'The model list could not be loaded. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'duplicate_project_ref':
      return CloudErrorCopy(
        text: 'That project is already tagged in this message.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'too_many_project_refs':
      return CloudErrorCopy(
        text: 'Too many projects are tagged. Remove a few and retry.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'unknown_project_ref':
      return CloudErrorCopy(
        text: 'A tagged project no longer exists. Remove the tag.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'run_conflict':
      return CloudErrorCopy(
        text: 'That message was already accepted. Wait for the reply.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'file_service_not_configured':
    case 'storage_not_configured':
      return CloudErrorCopy(
        text: 'File storage is unavailable right now. Try again later.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'import_too_large':
      return CloudErrorCopy(
        text: 'That backup is too large to import.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'invalid_source':
      return CloudErrorCopy(
        text: 'That file is not an Ovid backup. Choose another.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'archive_unsafe':
      return CloudErrorCopy(
        text: 'That archive is not safe to install. Choose a trusted plugin.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'oauth_failed':
      return CloudErrorCopy(
        text: 'The connector sign-in failed. Try connecting again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'history_actions_unavailable':
      return CloudErrorCopy(
        text: 'History editing is unavailable here. Start a new chat.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'invalid_state':
      return CloudErrorCopy(
        text: 'That action is no longer available. Reload and try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'share_limit_reached':
      return CloudErrorCopy(
        text: 'You have reached the share limit. Revoke an old link.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'share_storage_limit_reached':
      return CloudErrorCopy(
        text: 'Shared storage is full. Revoke an old link to free space.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'report_limit_reached':
      return CloudErrorCopy(
        text: 'You have reached the report limit. Try again later.',
        action: CloudErrorAction.wait,
        detail: detail,
      );
    default:
      return CloudErrorCopy(
        text: raw.isNotEmpty && isHumanFailureText(raw)
            ? raw
            : 'Ovid could not handle that request. Try again, or contact '
                'support if it repeats.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
  }
}

/// The one sentence to show for [error]: its own server prose when that reads
/// as human, otherwise the mapped copy for its code. Never a status, an id or
/// a provider dump.
String cloudErrorSentence(CloudApiException error) =>
    cloudErrorDetail(error.message) ??
    cloudErrorCopy(error.code, message: error.message).text;

String _resetPhrase(DateTime resetsAt, DateTime? now) {
  final current = now ?? DateTime.now();
  final local = resetsAt.toLocal();
  final left = resetsAt.difference(current);
  if (left.isNegative || left.inSeconds < 60) return 'in under a minute';
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final h = left.inHours;
  final m = left.inMinutes % 60;
  final span = h > 0 ? '$h h ${m.toString().padLeft(2, '0')} m' : '$m min';
  return 'at $hh:$mm (in $span)';
}
