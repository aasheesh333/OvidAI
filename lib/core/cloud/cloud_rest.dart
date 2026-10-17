import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../cloud_app_check.dart';
import '../firebase_service.dart';
import 'cloud_config.dart';
import 'models.dart';

/// The one error type for every non-2xx gateway answer. `code` comes from the
/// server's `{error:{code, message}}` envelope (or `'internal'` when the body
/// is unparseable); `resetsAt` is parsed from the `x-ovid-resets-at` response
/// header when present (spec §15 — e.g. 402 `daily_limit_reached` carries the
/// epoch-ms instant the allowance resets).
class CloudApiException implements Exception {
  CloudApiException({
    required this.status,
    required this.code,
    required this.message,
    this.resetsAt,
  });

  final int status;
  final String code;
  final String message;
  final DateTime? resetsAt;

  @override
  String toString() {
    final reset =
        resetsAt == null ? '' : ' (resets at ${resetsAt!.toIso8601String()})';
    return 'CloudApiException: $status $code: $message$reset';
  }
}

/// Binds the caller's Firebase identity to the two headers every
/// authenticated gateway call carries: `Authorization: Bearer <idToken>` and
/// `X-Firebase-AppCheck: <token>` (the gateway's authHook verifies both).
class CloudHeaders {
  /// Custom header sources. Both closures are optional; [idToken] returning
  /// null means "signed out" and [authorize] throws before any request goes
  /// out.
  CloudHeaders({
    Future<String?> Function()? idToken,
    Future<String> Function()? appCheck,
  }) : this._(_forceAwareOrNull(idToken), appCheck);

  CloudHeaders._(this._idToken, this._appCheck);

  /// Lifts a plain no-arg closure to the force-refresh-capable seam (a
  /// no-arg closure cannot re-mint a near-expiry token, so its force path is
  /// just a re-invocation).
  static Future<String?> Function({bool forceRefresh})? _forceAwareOrNull(
      Future<String?> Function()? idToken) {
    if (idToken == null) return null;
    return ({bool forceRefresh = false}) => idToken();
  }

  /// Force-refresh-capable seam: a plain no-arg closure cannot re-mint a
  /// near-expiry token, so the default singleton binds a force-aware one.
  final Future<String?> Function({bool forceRefresh})? _idToken;
  final Future<String> Function()? _appCheck;

  static CloudHeaders? _instance;

  /// The process-wide default: FirebaseService's ID token + CloudAppCheck.
  /// Lazy, so merely importing this file never touches Firebase.
  static CloudHeaders get I => _instance ??= CloudHeaders._(
        ({bool forceRefresh = false}) =>
            FirebaseService.I.getIdToken(forceRefresh: forceRefresh),
        _defaultAppCheck.getToken,
      );

  static final CloudAppCheck _defaultAppCheck = CloudAppCheck(
    initializeFirebase: () => FirebaseService.I.initialize(),
    activatedByFirebase: () => FirebaseService.I.accountService.enabled,
  );

  @visibleForTesting
  static CloudHeaders forTest({
    String idToken = 'test-id-token',
    String appCheck = 'test-app-check',
  }) =>
      CloudHeaders(
        idToken: () async => idToken,
        appCheck: () async => appCheck,
      );

  /// The two auth headers. [forceRefresh] re-mints the ID token first (the
  /// 401-retry path). Throws [CloudApiException] `(401, unauthenticated)`
  /// when signed out — no request is sent.
  Future<Map<String, String>> authorize({bool forceRefresh = false}) async {
    final token = await _idToken?.call(forceRefresh: forceRefresh);
    if (token == null || token.trim().isEmpty) {
      throw CloudApiException(
        status: 401,
        code: 'unauthenticated',
        message: 'Sign in to use Ovid Cloud.',
      );
    }
    final appCheckToken = await _appCheck?.call();
    return <String, String>{
      'Authorization': 'Bearer $token',
      'X-Firebase-AppCheck': appCheckToken ?? '',
    };
  }
}

/// Thin REST client for the gateway's `/cloud/v1` surface. All DTO shapes in
/// `models.dart`; all non-2xx answers surface as [CloudApiException]. A 401
/// from the server is retried exactly ONCE with a force-refreshed ID token
/// before the exception is thrown.
class CloudRestClient {
  CloudRestClient({
    http.Client? httpClient,
    CloudHeaders? headers,
    String? restBase,
  })  : _httpClient = httpClient ?? http.Client(),
        _headers = headers ?? CloudHeaders.I,
        _restBase = _stripTrailingSlash(restBase ?? CloudConfig.restBase);

  final http.Client _httpClient;
  final CloudHeaders _headers;
  final String _restBase;

  static CloudRestClient? _instance;

  /// The process-wide default client (prod restBase, real headers).
  static CloudRestClient get I => _instance ??= CloudRestClient();

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(CloudRestClient client) => _instance = client;

  // -------------------------------------------------------------------------
  // Raw JSON plumbing (the error mapping is pinned here)
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> getJson(String path,
      {Map<String, String>? query}) async {
    return _decode(await _authed('GET', _uri(path, query), null));
  }

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    return _decode(await _authed('POST', _uri(path), body));
  }

  Future<Map<String, dynamic>> patchJson(String path, {Object? body}) async {
    return _decode(await _authed('PATCH', _uri(path), body));
  }

  /// Sends with auth headers; on a 401, refreshes the ID token (force) and
  /// retries exactly once — a stale cached token self-heals, a real
  /// unauthenticated failure still surfaces.
  Future<http.Response> _authed(
      String method, Uri uri, Object? body) async {
    final first =
        await _raw(method, uri, await _headers.authorize(), jsonBody: body);
    if (first.statusCode != 401) return first;
    return _raw(method, uri, await _headers.authorize(forceRefresh: true),
        jsonBody: body);
  }

  Future<http.Response> _raw(
    String method,
    Uri uri,
    Map<String, String> headers, {
    Object? jsonBody,
    List<int>? byteBody,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(jsonBody);
    } else if (byteBody != null) {
      request.bodyBytes = byteBody;
    }
    return http.Response.fromStream(await _httpClient.send(request));
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _toError(response);
    }
    final dynamic parsed = _tryJson(response.body);
    if (parsed is Map<String, dynamic>) return parsed;
    throw CloudApiException(
      status: response.statusCode,
      code: 'internal',
      message: 'Unexpected response format from Ovid Cloud.',
    );
  }

  /// Non-2xx → parse `{"error":{"code","message"}}`; an unparseable body
  /// collapses to `code:'internal'`. `x-ovid-resets-at` (epoch ms or ISO) is
  /// attached when present.
  CloudApiException _toError(http.Response response) {
    var code = 'internal';
    var message = 'Ovid Cloud request failed (HTTP ${response.statusCode}).';
    final dynamic parsed = _tryJson(response.body);
    if (parsed is Map && parsed['error'] is Map) {
      final error = parsed['error'] as Map<dynamic, dynamic>;
      final parsedCode = error['code'];
      final parsedMessage = error['message'];
      if (parsedCode is String && parsedCode.isNotEmpty) code = parsedCode;
      if (parsedMessage is String && parsedMessage.isNotEmpty) {
        message = parsedMessage;
      }
    }
    return CloudApiException(
      status: response.statusCode,
      code: code,
      message: message,
      resetsAt: _resetsAt(response),
    );
  }

  dynamic _tryJson(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// `x-ovid-resets-at`: all-digits → epoch milliseconds; anything else → an
  /// ISO 8601 stamp. Case-insensitive header lookup.
  DateTime? _resetsAt(http.Response response) {
    String? raw;
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'x-ovid-resets-at') {
        raw = entry.value;
        break;
      }
    }
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(text)) {
      return DateTime.fromMillisecondsSinceEpoch(int.parse(text), isUtc: true);
    }
    return DateTime.tryParse(text);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_restBase$path');
    final params = <String, String>{
      for (final entry in (query ?? const <String, String>{}).entries)
        if (entry.value.isNotEmpty) entry.key: entry.value,
    };
    return params.isEmpty ? uri : uri.replace(queryParameters: params);
  }

  static String _stripTrailingSlash(String base) {
    var out = base;
    while (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Endpoint surface (every later client task consumes these)
  // -------------------------------------------------------------------------

  /// GET /health — the ONE public route: no auth headers are attached. Both
  /// the 200 ok and the 503 degraded variants carry the same
  /// `{status, checks:{db, redisQ}}` body, so both parse into [CloudHealth].
  Future<CloudHealth> health() async {
    final response = await _raw(
        'GET', _uri('/health'), const <String, String>{});
    final dynamic parsed = _tryJson(response.body);
    if (parsed is Map<String, dynamic> &&
        parsed['status'] is String &&
        parsed['checks'] is Map) {
      return CloudHealth.fromJson(parsed);
    }
    throw _toError(response);
  }

  /// POST /auth/ticket → the single-use WS ticket.
  Future<String> mintTicket() async {
    final json = await postJson('/auth/ticket');
    final ticket = json['ticket'];
    if (ticket is String && ticket.isNotEmpty) return ticket;
    throw CloudApiException(
      status: 500,
      code: 'internal',
      message: 'Ticket response was malformed.',
    );
  }

  Future<SessionDto> createSession({String? title}) async {
    return SessionDto.fromJson(await postJson('/sessions',
        body: <String, Object>{'title': ?title}));
  }

  Future<CloudPage<SessionDto>> listSessions(
      {int limit = 50, String? cursor}) async {
    final json = await getJson('/sessions', query: <String, String>{
      'limit': '$limit',
      'cursor': ?cursor,
    });
    return CloudPage.fromJson(json, SessionDto.fromJson);
  }

  Future<SessionDto> getSession(String id) async =>
      SessionDto.fromJson(await getJson('/sessions/$id'));

  /// PATCH /sessions/:id — only the fields provided are sent (the server
  /// requires at least one and rejects unknown keys).
  Future<SessionDto> patchSession(String id, {String? title, String? mode}) async {
    return SessionDto.fromJson(await patchJson('/sessions/$id', body: <String, Object>{
      'title': ?title,
      'mode': ?mode,
    }));
  }

  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
  }) async {
    return SendMessageResponse.fromJson(await postJson(
      '/sessions/$sessionId/messages',
      body: <String, Object>{
        'content': content,
        if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
        if (clientMsgId != null && clientMsgId.isNotEmpty)
          'clientMsgId': clientMsgId,
      },
    ));
  }

  Future<CloudPage<MessageDto>> pageMessages(String sessionId,
      {int limit = 50, String? before}) async {
    final json =
        await getJson('/sessions/$sessionId/messages', query: <String, String>{
      'limit': '$limit',
      'before': ?before,
    });
    return CloudPage.fromJson(json, MessageDto.fromJson);
  }

  Future<RunCancelResponse> cancelRun(String runId) async =>
      RunCancelResponse.fromJson(await postJson('/runs/$runId/cancel'));

  Future<AttachmentUpload> createAttachment(String sessionId,
      {required String name, required int size}) async {
    return AttachmentUpload.fromJson(await postJson(
      '/sessions/$sessionId/attachments',
      body: <String, Object>{'name': name, 'size': size},
    ));
  }

  /// Raw PUT of the attachment bytes to the presigned R2 URL — NO
  /// Authorization / App Check headers (they would corrupt the signature;
  /// the URL itself is the credential).
  Future<void> uploadAttachmentBytes(
      AttachmentUpload upload, List<int> bytes) async {
    final response = await _raw('PUT', Uri.parse(upload.uploadUrl),
        const <String, String>{},
        byteBody: bytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // R2 answers XML, not the gateway's JSON envelope → 'internal'.
      throw _toError(response);
    }
  }

  Future<ImportReport> importMessages({
    String? sessionId,
    String? title,
    DateTime? createdAt,
    required List<ImportMessage> messages,
  }) async {
    return ImportReport.fromJson(await postJson('/import/sessions',
        body: <String, Object>{
          'sessionId': ?sessionId,
          'title': ?title,
          if (createdAt != null)
            'createdAt': createdAt.toUtc().toIso8601String(),
          'messages': [for (final message in messages) message.toJson()],
        }));
  }

  /// POST /devices (P4-owned route) — body `{"token": <fcm>, "platform": …}`
  /// per P4's `deviceRegisterRequestSchema` (strict; platform "android").
  /// The 200 DeviceDto answer is nothing the caller needs back.
  Future<void> registerDevice(
      {required String fcmToken, String platform = 'android'}) async {
    await postJson('/devices',
        body: <String, Object>{'token': fcmToken, 'platform': platform});
  }
}
