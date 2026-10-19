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
      return CloudErrorCopy(
        text: 'Your Ovid session expired. Sign in again to send this '
            'message.',
        action: CloudErrorAction.signIn,
        detail: detail,
      );
    case 'timeout':
    case 'network':
      return CloudErrorCopy(
        text: 'Connection problem. Ovid could not be reached.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'unavailable':
    case 'internal':
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
      return CloudErrorCopy(
        text: 'That model is not available on Ovid Cloud. Pick another '
            'model.',
        action: CloudErrorAction.pickModel,
        detail: detail,
      );
    case 'model_no_vision':
      return CloudErrorCopy(
        text: 'The selected model cannot read images. Pick a model that '
            'supports images, or remove the image.',
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
    case 'attachment_unavailable':
    case 'attachment_missing':
      return CloudErrorCopy(
        text: 'An attached file could not be read. Attach it again and '
            'resend.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'hook_blocked':
      return CloudErrorCopy(
        text: raw.isNotEmpty && _looksHuman(raw)
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
        text: raw.isNotEmpty && _looksHuman(raw)
            ? raw
            : 'Ovid could not accept this message.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
    case 'not_found':
      return CloudErrorCopy(
        text: 'This chat no longer exists on Ovid Cloud. Start a new chat.',
        action: CloudErrorAction.none,
        detail: detail,
      );
    case 'no_session':
      return const CloudErrorCopy(
        text: 'Start a chat first.',
        action: CloudErrorAction.none,
      );
    default:
      return CloudErrorCopy(
        text: raw.isNotEmpty && _looksHuman(raw)
            ? raw
            : 'Something went wrong. Try again.',
        action: CloudErrorAction.retry,
        detail: detail,
      );
  }
}

/// True for short server prose; false for provider exception dumps, stack
/// traces, JSON blobs and identifiers.
bool _looksHuman(String text) {
  if (text.length > 240) return false;
  if (text.contains('\n    at ') || text.contains('Traceback')) return false;
  if (text.contains('Error:') ||
      text.contains('Exception') ||
      text.contains('litellm') ||
      text.startsWith('{') ||
      text.startsWith('[')) {
    return false;
  }
  if (RegExp(r'^[a-z0-9_]+$').hasMatch(text)) return false;
  return true;
}

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
