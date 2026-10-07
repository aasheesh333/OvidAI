import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'cloud_app_check.dart';
import 'firebase_service.dart';
import 'state.dart';

class ConversationShareException implements Exception {
  const ConversationShareException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SharedMessage {
  const SharedMessage(this.role, this.content);
  final String role;
  final String content;
  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// Copy only the public-text allowlist, never Message/ChatSession.toJson().
/// Private envelope detection is defense in depth, not a general secret scanner.
class ConversationSnapshot {
  ConversationSnapshot._(this.sessionId, List<SharedMessage> messages)
    : messages = List.unmodifiable(messages);

  final String sessionId;
  final List<SharedMessage> messages;

  // Keep the policy aligned with server/shares/snapshot.py. Exclude the whole
  // row rather than trying to repair possibly unterminated private envelopes.
  static final _privateText = RegExp(
    r'<\s*/?\s*(?:think|thinking|analysis|reasoning|system-reminder|internal|secret)\b'
    r'|\[(?:report from subagent|subagent |schedule |plugin hook context|'
    r'context |system |user attachments|previous phase result)'
    r'|\bBackground subagent\s'
    r'|\b(?:authorization\s*:|bearer\s+|api[_-]?key\s*[:=]|'
    r'password\s*[:=]|secret\s*[:=]|access[_-]?token\s*[:=])'
    r'|-----BEGIN [A-Z ]*PRIVATE KEY-----|data:[^\s,]*;base64,'
    r'|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,})'
    r'|(?:/data/(?:user|data)/|/root/|/home/|file://)',
    caseSensitive: false,
  );

  factory ConversationSnapshot.fromSession(ChatSession session) {
    final messages = <SharedMessage>[];
    if (!session.isSubagent) {
      for (final message in session.messages) {
        if ((message.role == 'user' || message.role == 'assistant') &&
            message.kind == MsgKind.text &&
            !message.thinking &&
            message.toolName == null &&
            message.content.trim().isNotEmpty &&
            !_privateText.hasMatch(message.content)) {
          messages.add(SharedMessage(message.role, message.content));
        }
      }
    }
    return ConversationSnapshot._(session.id, messages);
  }

  bool get withinLimits =>
      messages.isNotEmpty &&
      messages.length <= 500 &&
      messages.every((m) => m.content.runes.length <= 20000) &&
      messages.fold<int>(0, (n, m) => n + utf8.encode(m.content).length) <=
          200000;

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'messages': [for (final message in messages) message.toJson()],
  };
}

class ConversationShare {
  const ConversationShare({
    required this.id,
    required this.url,
    required this.sessionId,
    required this.createdAt,
    required this.expiresAt,
    this.requestId,
  });
  final String id;
  final Uri url;
  final String sessionId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? requestId;
}

class ConversationShareService {
  ConversationShareService({
    this.baseUrl = const String.fromEnvironment('OVID_SHARE_BASE_URL'),
    required this.idToken,
    this.appCheck,
    this.currentUid,
    this.client,
  }) : _ownerUid = currentUid?.call();

  factory ConversationShareService.production() => ConversationShareService(
    idToken: () => FirebaseService.I.getIdToken(),
    appCheck: _cloudAppCheck.getToken,
    currentUid: () =>
        FirebaseService.I.accountReady ? FirebaseService.I.uid : null,
  );

  static final _cloudAppCheck = CloudAppCheck(
    initializeFirebase: () => FirebaseService.I.initialize(),
    activatedByFirebase: () => FirebaseService.I.accountService.enabled,
  );
  final String baseUrl;
  final Future<String?> Function() idToken;
  final Future<String?> Function()? appCheck;
  final String? Function()? currentUid;
  final String? _ownerUid;
  final http.Client? client;
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

  Uri? get _base {
    final uri = Uri.tryParse(baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty &&
            !RegExp(r'^(?:/[A-Za-z0-9_-]+)+$').hasMatch(uri.path))) {
      return null;
    }
    return uri;
  }

  bool get available => _base != null;
  bool get ownerIsCurrent =>
      currentUid == null || (_ownerUid != null && currentUid!() == _ownerUid);

  void _checkOwner() {
    if (!ownerIsCurrent) {
      throw const ConversationShareException(
        'Account changed or signed out. Reopen sharing after signing in.',
      );
    }
  }

  /// Retain this ID across an uncertain create retry for the SAME preview.
  static String newRequestId() {
    final random = Random.secure();
    return base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  Future<ConversationShare> create(
    ConversationSnapshot snapshot, {
    required String requestId,
  }) async {
    if (!snapshot.withinLimits) {
      throw const ConversationShareException(
        'Share 1–500 completed text messages, up to 200 KB in total and 20,000 characters each.',
      );
    }
    final data = await _call(
      'POST',
      '/shares',
      body: {...snapshot.toJson(), 'request_id': requestId},
    );
    return _parse(data, snapshot.sessionId);
  }

  Future<List<ConversationShare>> list(String sessionId) async {
    final data = await _call(
      'GET',
      '/shares',
      query: {'session_id': sessionId},
    );
    try {
      return [for (final row in data['shares'] as List) _parse(row, sessionId)];
    } on ConversationShareException {
      rethrow;
    } catch (_) {
      throw const ConversationShareException('Invalid share server response.');
    }
  }

  Future<void> revoke(String id) async {
    if (!_tokenPattern.hasMatch(id)) {
      throw const ConversationShareException('Invalid share ID.');
    }
    await _call('DELETE', '/shares/$id');
  }

  Future<String> fork(String id, {required String requestId}) async {
    if (!_tokenPattern.hasMatch(id)) {
      throw const ConversationShareException('Invalid share ID.');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(requestId)) {
      throw const ConversationShareException('Invalid fork request ID.');
    }
    final data = await _call(
      'POST',
      '/shares/$id/fork',
      body: {'request_id': requestId},
    );
    final sessionId = data['session_id'];
    if (sessionId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(sessionId)) {
      throw const ConversationShareException('The share server returned an invalid fork.');
    }
    return sessionId;
  }

  /// Local share state owned by this service, for the verified all-store reset.
  ///
  /// This service is deliberately stateless: [create] returns the parsed
  /// [ConversationShare] to its caller, [list] re-reads the server, and nothing
  /// is cached here. There are no share receipts, IDs, tokens, or per-session
  /// browser profiles held locally, so the truthful local count is always zero.
  /// Server-side shares are owned by the share server; deleting them is a
  /// separate owner's responsibility and is intentionally not attempted here.
  Future<int> localShareCount() async => 0;

  /// Clears local share state owned by this service. It owns none (see
  /// [localShareCount]), so this is a documented no-op. It never issues a
  /// server DELETE: remote share deletion belongs to the server share owner.
  Future<void> clearLocal() async {}

  ConversationShare _parse(dynamic data, String sessionId) {
    try {
      final id = data['id'] as String;
      final url = Uri.parse(data['url'] as String);
      final created = data['created_at'] as num;
      final expires = data['expires_at'] as num;
      final requestId = data['request_id'] as String?;
      if (!_tokenPattern.hasMatch(id) ||
          data['session_id'] != sessionId ||
          url.toString() != '${_base!}/s/$id' ||
          !created.isFinite ||
          !expires.isFinite ||
          expires <= created ||
          (requestId != null &&
              !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(requestId))) {
        throw const FormatException();
      }
      return ConversationShare(
        id: id,
        url: url,
        sessionId: sessionId,
        requestId: requestId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (created * 1000).round(),
          isUtc: true,
        ),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (expires * 1000).round(),
          isUtc: true,
        ),
      );
    } catch (_) {
      throw const ConversationShareException(
        'The share server returned an invalid link. Creation is unconfirmed; refresh existing links.',
      );
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final base = _base;
    if (base == null) {
      throw const ConversationShareException(
        'Sharing is unavailable: deployment is not configured.',
      );
    }
    final transport = client ?? http.Client();
    try {
      _checkOwner();
      final token = await idToken().timeout(const Duration(seconds: 20));
      if (token == null || token.trim().isEmpty) {
        throw const ConversationShareException(
          'Sign in to share a conversation.',
        );
      }
      final attestation = await appCheck?.call().timeout(
        const Duration(seconds: 20),
      );
      if (appCheck != null &&
          (attestation == null || attestation.trim().isEmpty)) {
        throw const ConversationShareException(
          'App verification is unavailable. Please retry.',
        );
      }
      _checkOwner();
      final uri = Uri.parse('$base$path').replace(queryParameters: query);
      // Do not follow redirects with Firebase credentials or accept a redirect
      // as a confirmed create. A deployment must expose the exact API paths.
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        if (attestation != null && attestation.isNotEmpty)
          'X-Firebase-AppCheck': attestation,
        'Content-Type': 'application/json',
      });
      if (body != null) request.body = jsonEncode(body);
      final response = await transport
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      _checkOwner();
      final expectedStatus = switch (method) {
        'POST' => 201,
        'DELETE' => 204,
        _ => 200,
      };
      if (response.statusCode != expectedStatus) {
        throw ConversationShareException(switch (response.statusCode) {
          401 => 'Sign in again to verify your identity.',
          403 => 'This account or app is not allowed to share.',
          409 =>
            'This request was already used, revoked, or expired. Refresh existing links.',
          422 => 'The snapshot contains unsupported or private content.',
          429 => 'Share storage limit reached. Contact support if it persists.',
          _ =>
            'Share operation is unconfirmed. Refresh existing links and retry.',
        });
      }
      if (method == 'DELETE') return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on ConversationShareException {
      rethrow;
    } catch (_) {
      throw const ConversationShareException(
        'Share operation is unconfirmed. Check your connection and refresh existing links.',
      );
    } finally {
      if (client == null) transport.close();
    }
  }
}
