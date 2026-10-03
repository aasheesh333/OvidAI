/// User-facing interpretation of an observed model failure. Unknown failures
/// remain unknown; an empty reply alone is not evidence of a timeout.
enum ModelFailureKind {
  emptyResponse,
  timeout,
  network,
  authentication,
  permission,
  rateLimit,
  unavailable,
  modelNotFound,
  invalidResponse,
  unknown,
}

class ModelFailure {
  const ModelFailure(this.kind, this.message, this.action, {this.detail = ''});

  final ModelFailureKind kind;
  final String message;
  final String action;
  final String detail;

  String get transcript =>
      '⚠️ $message\n\n$action'
      '${detail.isEmpty ? '' : '\n\nDetails: $detail'}';

  factory ModelFailure.fromError(String error) {
    final detail = error
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .join('\n');
    final lower = detail.toLowerCase();
    final status = int.tryParse(
      RegExp(r'^HTTP (\d{3})\b').firstMatch(detail)?.group(1) ?? '',
    );
    if (status != null) {
      final (kind, message, action) = switch (status) {
        401 => (
          ModelFailureKind.authentication,
          'The provider rejected authentication.',
          'Check your provider credentials in Settings, then retry.',
        ),
        403 => (
          ModelFailureKind.permission,
          'The provider denied this request.',
          'Check account and model access with your provider, then retry.',
        ),
        404 => (
          ModelFailureKind.modelNotFound,
          'The requested endpoint or model was not found.',
          'Check the provider URL and selected model in Settings.',
        ),
        429 => (
          ModelFailureKind.rateLimit,
          'The provider returned a rate or quota limit.',
          'Wait before retrying; check your provider quota if this continues.',
        ),
        >= 500 => (
          ModelFailureKind.unavailable,
          'The provider returned a server error.',
          'Retry later or choose another provider.',
        ),
        _ => (
          ModelFailureKind.unknown,
          'The provider rejected the request.',
          'Review the provider details below and check the selected model settings.',
        ),
      };
      return ModelFailure(kind, message, action, detail: detail);
    }
    if (lower.startsWith('empty response')) {
      return ModelFailure(
        ModelFailureKind.emptyResponse,
        'The provider returned no content, reasoning, or tool calls.',
        'Retry or choose another model. If this continues, check the provider endpoint and API format.',
        detail: detail,
      );
    }
    if (lower.contains('model stream idle') ||
        lower.contains('first-byte timeout') ||
        lower.contains('timeoutexception')) {
      return ModelFailure(
        ModelFailureKind.timeout,
        'The model request timed out.',
        'Retry. If your provider needs more time, adjust "AI response timeout" in Settings.',
        detail: detail,
      );
    }
    if (lower.contains('socketexception') ||
        lower.contains('handshakeexception') ||
        lower.contains('connect timeout')) {
      return ModelFailure(
        ModelFailureKind.network,
        'The connection to the provider failed.',
        'Check your network and provider URL, then retry.',
        detail: detail,
      );
    }
    if (lower.startsWith('invalid model response')) {
      return ModelFailure(
        ModelFailureKind.invalidResponse,
        'The provider response could not be read as a model stream.',
        'Check the provider endpoint and API format, then retry.',
        detail: detail,
      );
    }
    return ModelFailure(
      ModelFailureKind.unknown,
      'The model request failed.',
      'Retry. If it continues, review the provider details below.',
      detail: detail,
    );
  }

  static String httpError(
    int status,
    String provider,
    String model,
    String body,
  ) =>
      'HTTP $status $provider · $model\n${body.length > 180 ? body.substring(0, 180) : body}';
}
