import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const maxCollaborationRequestBytes = 1024 * 1024;
const maxCollaborationBatchBytes = 8 * 1024 * 1024;
const maxCollaborationEvents = 100;
const maxCollaborationResponseBytes = maxCollaborationBatchBytes + 128 * 1024;

const _errorMessages = <String, String>{
  'unauthenticated': 'Authentication required',
  'invalid_request': 'Invalid request',
  'not_member': 'Not a session member',
  'not_owner': 'Owner permission required',
  'invite_invalid': 'Invitation is invalid',
  'membership_revoked': 'Membership is revoked',
  'session_not_found': 'Session not found',
  'member_not_found': 'Member not found',
  'session_closed': 'Session is closed',
  'session_full': 'Session is full',
  'owner_not_removable': 'Owner cannot be removed',
  'event_id_conflict': 'Event conflicts with an existing event',
  'request_already_used': 'Request was already used',
  'cursor_reset': 'Replay cursor must be reset',
  'account_deleted': 'Account is unavailable',
  'account_deletion_pending': 'Account is unavailable',
  'unsupported_identity': 'Authentication required',
  'invite_not_found': 'Invitation not found',
  'rate_limited': 'Collaboration rate limit exceeded',
  'quota_exhausted': 'Collaboration quota exceeded',
  'payload_too_large': 'Collaboration payload is too large',
  'temporarily_unavailable': 'The collaboration service is temporarily unavailable',
};

class CollaborationClientException implements Exception {
  const CollaborationClientException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  /// Only authoritative session/account/member failures end the saved session.
  /// Local credential acquisition failures and target-specific mutations retry.
  bool get isTerminalSessionError => const {
    'unauthenticated', 'not_member', 'membership_revoked', 'session_not_found',
    'session_closed', 'account_deleted', 'account_deletion_pending',
    'unsupported_identity',
  }.contains(code);

  @override
  String toString() => message;
}

class CollaborationCursor {
  const CollaborationCursor(this.value);

  final String value;
}

class CollaborationCreateResult {
  const CollaborationCreateResult({
    required this.sessionToken,
    required this.session,
    required this.member,
    required this.cursor,
  });

  final String sessionToken;
  final CollaborationSession session;
  final Member member;
  final CollaborationCursor cursor;
}

class CollaborationState {
  const CollaborationState({
    required this.session,
    required this.member,
    required this.members,
    required this.cursor,
    this.initialMembers,
    this.replayThroughSequence = 0,
  });

  final CollaborationSession session;
  final Member member;
  final List<Member> members;
  final CollaborationCursor cursor;
  final List<Member>? initialMembers;
  final int replayThroughSequence;
}

class CollaborationJoinResult {
  const CollaborationJoinResult({required this.member, required this.cursor});

  final Member member;
  final CollaborationCursor cursor;
}

class CollaborationInvite {
  const CollaborationInvite({required this.inviteId, required this.inviteCode,
    required this.expiresAt, required this.maxUses});

  final String inviteId;
  final String inviteCode;
  final DateTime expiresAt;
  final int maxUses;
}

class CollaborationEventPage {
  const CollaborationEventPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<CollaborationEvent> events;
  final CollaborationCursor nextCursor;
  final bool hasMore;
}

class CollaborationClient {
  CollaborationClient({
    required this.baseUri,
    required this.accessToken,
    required this.appCheckToken,
    this.requestTimeout = const Duration(seconds: 30),
    http.Client? httpClient,
  }) : assert(requestTimeout > Duration.zero), _httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final Future<String?> Function() accessToken;
  final Future<String?> Function() appCheckToken;
  final http.Client _httpClient;
  final Duration requestTimeout;

  Future<CollaborationCreateResult> create({required String requestId}) async {
    final data = await _request(
      'POST',
      '/chat',
      body: {
        'schemaVersion': collaborationSchemaVersion,
        'requestId': requestId,
        'idempotencyKey': requestId,
      },
    );
    _exact(data, const {
      'schemaVersion',
      'sessionToken',
      'session',
      'member',
      'cursor',
    });
    _version(data);
    return CollaborationCreateResult(
      sessionToken: _string(data, 'sessionToken'),
      session: _wire(() => CollaborationSession.fromWire(_map(data, 'session'))),
      member: _wire(() => Member.fromWire(_map(data, 'member'))),
      cursor: _cursor(data, 'cursor'),
    );
  }

  Future<CollaborationState> state(String sessionToken) async {
    _segment(sessionToken);
    final data = await _request('GET', '/chat/$sessionToken');
    _exact(data, {
      'schemaVersion',
      'session',
      'member',
      'members',
      'cursor',
      if (data.containsKey('initialMembers')) 'initialMembers',
      if (data.containsKey('replayThroughSequence')) 'replayThroughSequence',
    });
    _version(data);
    final members = _list(data, 'members');
    if (members.length > 10) _invalidResponse();
    final through = data['replayThroughSequence'] ?? 0;
    if (through is! int || through < 0 ||
        data.containsKey('initialMembers') != data.containsKey('replayThroughSequence')) {
      _invalidResponse();
    }
    final initial = data.containsKey('initialMembers') ? _list(data, 'initialMembers') : null;
    if (initial != null && initial.length != 1) _invalidResponse();
    return CollaborationState(
      session: _wire(() => CollaborationSession.fromWire(_map(data, 'session'))),
      member: _wire(() => Member.fromWire(_map(data, 'member'))),
      members: [for (final value in members) _wire(() => Member.fromWire(_asMap(value)))],
      cursor: _cursor(data, 'cursor'),
      initialMembers: initial == null ? null : [for (final value in initial) _wire(() => Member.fromWire(_asMap(value)))],
      replayThroughSequence: through,
    );
  }

  Future<CollaborationJoinResult> join(
    String sessionToken, {
    required String invitationCode,
    required String idempotencyKey,
  }) async {
    _segment(sessionToken);
    if (invitationCode.isEmpty || invitationCode.length > 512) _invalidRequest();
    final data = await _request(
      'POST',
      '/chat/$sessionToken/members',
        body: {
          'schemaVersion': collaborationSchemaVersion,
          'invitationCode': invitationCode,
          'idempotencyKey': idempotencyKey,
        },
    );
    _exact(data, const {'schemaVersion', 'member', 'cursor'});
    _version(data);
    return CollaborationJoinResult(
      member: _wire(() => Member.fromWire(_map(data, 'member'))),
      cursor: _cursor(data),
    );
  }

  Future<CollaborationInvite> createInvite(
    String sessionToken, {
    required String idempotencyKey,
    int maxUses = 1,
    int ttlSeconds = 86400,
  }) async {
    _segment(sessionToken);
    if (maxUses < 1 || maxUses > 9 || ttlSeconds < 1 || ttlSeconds > 7 * 86400) {
      _invalidRequest();
    }
    final data = await _request('POST', '/chat/$sessionToken/members', body: {
      'schemaVersion': collaborationSchemaVersion, 'idempotencyKey': idempotencyKey,
      'maxUses': maxUses, 'ttlSeconds': ttlSeconds,
    });
    _exact(data, const {'schemaVersion', 'inviteId', 'inviteCode', 'expiresAt', 'maxUses'});
    _version(data);
    final expires = _string(data, 'expiresAt');
    final expiresAt = DateTime.tryParse(expires);
    final uses = data['maxUses'];
    final code = _string(data, 'inviteCode');
    if (expiresAt == null || !expires.endsWith('Z') || uses is! int || uses < 1 || uses > 9 ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code)) {
      _invalidResponse();
    }
    return CollaborationInvite(inviteId: _string(data, 'inviteId'), inviteCode: code,
      expiresAt: expiresAt, maxUses: uses);
  }

  Future<Member> revokeMember(String sessionToken, {required String participantId}) async {
    _segment(sessionToken);
    _segment(participantId);
    if (participantId == 'me') _invalidRequest();
    return _removeMember('/chat/$sessionToken/members/$participantId', MemberStatus.revoked);
  }

  Future<Member> leave(String sessionToken) async {
    _segment(sessionToken);
    return _removeMember('/chat/$sessionToken/members/me', MemberStatus.left);
  }

  Future<Member> _removeMember(String path, MemberStatus status) async {
    final data = await _request('DELETE', path);
    _exact(data, const {'schemaVersion', 'member'});
    _version(data);
    final member = _wire(() => Member.fromWire(_map(data, 'member')));
    if (member.status != status || member.role != MemberRole.participant) _invalidResponse();
    return member;
  }

  Future<CollaborationEventPage> events(
    String sessionToken, {
    CollaborationCursor? cursor,
  }) => replay(sessionToken, cursor: cursor);

  Future<CollaborationEventPage> replay(
    String sessionToken, {
    CollaborationCursor? cursor,
  }) async {
    _segment(sessionToken);
    if (cursor != null && (cursor.value.isEmpty || utf8.encode(cursor.value).length > 512)) {
      _invalidRequest();
    }
    final data = await _request(
      'GET',
      '/chat/$sessionToken/events',
      query: cursor == null ? null : {'cursor': cursor.value},
    );
    _exact(data, const {'schemaVersion', 'events', 'nextCursor', 'hasMore'});
    _version(data);
    return CollaborationEventPage(
      events: _events(data, maxBytes: 256 * 1024),
      nextCursor: _cursor(data, 'nextCursor'),
      hasMore: _bool(data, 'hasMore'),
    );
  }

  Future<CollaborationEventPage> appendEvents(
    String sessionToken, {
    required List<Map<String, Object?>> events,
    required String idempotencyKey,
  }) async {
    _segment(sessionToken);
    if (events.isEmpty || events.length > maxCollaborationEvents) _invalidRequest();
    final ids = <Object?>{};
    for (final event in events) {
      if (event.length != 4 || !event.keys.toSet().containsAll(
          const {'schemaVersion', 'eventId', 'kind', 'payload'}) ||
          !const {'message', 'modelStatus', 'usage', 'presence'}.contains(event['kind']) ||
          !ids.add(event['eventId'])) {
        _invalidRequest();
      }
      try {
        CollaborationEvent.fromWire({...event, 'sessionId': 'validation',
          'senderParticipantId': 'validation', 'eventSequence': 1,
          'createdAt': '2000-01-01T00:00:00.000Z'});
      } on CollaborationWireException {
        _invalidRequest();
      }
    }
    final data = await _request(
      'POST',
      '/chat/$sessionToken/events',
      body: {
        'schemaVersion': collaborationSchemaVersion,
        'idempotencyKey': idempotencyKey,
        'events': events,
      },
    );
    _exact(data, const {'schemaVersion', 'events', 'nextCursor', 'hasMore'});
    _version(data);
    return CollaborationEventPage(
      events: _events(data, maxBytes: maxCollaborationBatchBytes + 128 * 1024),
      nextCursor: _cursor(data, 'nextCursor'),
      hasMore: _bool(data, 'hasMore'),
    );
  }

  Future<CollaborationSession> close(
    String sessionToken, {
    required String idempotencyKey,
  }) async {
    _segment(sessionToken);
    final data = await _request(
      'POST',
      '/chat/$sessionToken/close',
      body: {
        'schemaVersion': collaborationSchemaVersion,
        'idempotencyKey': idempotencyKey,
      },
    );
    _exact(data, const {'schemaVersion', 'session'});
    _version(data);
    return _wire(() => CollaborationSession.fromWire(_map(data, 'session')));
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final abort = Completer<void>();
    try {
      return await _performRequest(method, path, query: query, body: body, abort: abort)
          .timeout(requestTimeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw const CollaborationClientException('Collaboration request timed out.', code: 'request_timeout');
      });
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Map<String, Object?>> _performRequest(
    String method, String path, {
    Map<String, String>? query, Map<String, Object?>? body,
    required Completer<void> abort,
  }) async {
    var encoded = '';
    if (body != null) {
      final key = body['idempotencyKey'];
      if (key is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key)) _invalidRequest();
      try {
        encoded = jsonEncode(body);
      } catch (_) {
        _invalidRequest();
      }
      if (utf8.encode(encoded).length > maxCollaborationRequestBytes) {
        throw const CollaborationClientException('Collaboration payload is too large',
          statusCode: 413, code: 'payload_too_large');
      }
    }
    final String? token;
    final String? appCheck;
    try {
      token = await accessToken();
      appCheck = await appCheckToken();
    } catch (_) {
      throw const CollaborationClientException('Credentials are temporarily unavailable.', code: 'credential_unavailable');
    }
    if (token == null || token.trim().isEmpty || appCheck == null || appCheck.trim().isEmpty) {
      throw const CollaborationClientException('Credentials are temporarily unavailable.', code: 'credential_unavailable');
    }
    if (abort.isCompleted) throw const CollaborationClientException('Collaboration request timed out.', code: 'request_timeout');
    final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
    final routePath = path.startsWith('/chat') && basePath.endsWith('/chat')
        ? path.substring('/chat'.length)
        : path;
    final uri = baseUri.replace(
      path: '$basePath$routePath',
      queryParameters: query,
    );
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
    };
    headers['X-Firebase-AppCheck'] = appCheck;
    if (body != null) headers['Content-Type'] = 'application/json';
    try {
      final response = await _httpClient.send(
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..headers.addAll(headers)
          ..body = encoded,
      );
      final bytes = await _readBody(response, abort);
      final text = utf8.decode(bytes);
      if (response.headers['cache-control']?.toLowerCase() != 'no-store') {
        throw const CollaborationClientException('Invalid collaboration response.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final parsed = _asMap(jsonDecode(text));
        _exact(parsed, const {'schemaVersion', 'code', 'message'});
        final code = parsed['code'];
        if (parsed['schemaVersion'] != collaborationSchemaVersion ||
            code is! String || _errorMessages[code] != parsed['message']) {
          throw const CollaborationClientException('Invalid collaboration response.');
        }
        throw CollaborationClientException(_errorMessages[code]!,
            statusCode: response.statusCode, code: code);
      }
      final decoded = jsonDecode(text);
      return _asMap(decoded);
    } on CollaborationClientException {
      rethrow;
    } on CollaborationWireException {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    } on FormatException {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    } catch (_) {
      throw const CollaborationClientException('Collaboration request failed.');
    }
  }

  Future<List<int>> _readBody(http.StreamedResponse response, Completer<void> abort) async {
    final result = Completer<List<int>>();
    final bytes = <int>[];
    late StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen((chunk) {
      if (result.isCompleted) return;
      if (bytes.length + chunk.length > maxCollaborationResponseBytes) {
        result.completeError(const CollaborationClientException('Invalid collaboration response.'));
        unawaited(subscription.cancel());
      } else {
        bytes.addAll(chunk);
      }
    }, onDone: () {
      if (!result.isCompleted) result.complete(bytes);
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    });
    unawaited(abort.future.then((_) {
      if (!result.isCompleted) {
        result.completeError(const CollaborationClientException('Collaboration request timed out.', code: 'request_timeout'));
        unawaited(subscription.cancel());
      }
    }));
    return result.future;
  }

  static Never _invalidRequest() => throw const CollaborationClientException(
    'Invalid request', statusCode: 400, code: 'invalid_request');

  static Never _invalidResponse() => throw const CollaborationClientException('Invalid collaboration response.');

  static void _segment(String value) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(value) || value == '.' || value == '..') {
      _invalidRequest();
    }
  }

  static T _wire<T>(T Function() decode) {
    try {
      return decode();
    } on CollaborationWireException {
      _invalidResponse();
    } on FormatException {
      _invalidResponse();
    }
  }

  static List<CollaborationEvent> _events(Map<String, Object?> data, {required int maxBytes}) {
    final raw = _list(data, 'events');
    if (raw.length > maxCollaborationEvents) _invalidResponse();
    var bytes = 0;
    final events = <CollaborationEvent>[];
    for (final value in raw) {
      final event = _wire(() => CollaborationEvent.fromWire(_asMap(value)));
      bytes += utf8.encode(jsonEncode(event.toWire())).length;
      if (bytes > maxBytes) _invalidResponse();
      events.add(event);
    }
    return events;
  }

  static void _exact(Map<String, Object?> data, Set<String> keys) {
    if (data.keys.toSet().length != keys.length ||
        !data.keys.toSet().containsAll(keys)) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
  }

  static void _version(Map<String, Object?> data) {
    if (data['schemaVersion'] != collaborationSchemaVersion) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
  }

  static String _string(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! String || value.isEmpty) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
    return value;
  }

  static bool _bool(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! bool) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
    return value;
  }

  static Map<String, Object?> _map(Map<String, Object?> data, String key) =>
      _asMap(data[key]);

  static List<Object?> _list(Map<String, Object?> data, String key) {
    final value = data[key];
    if (value is! List) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
    return value.cast<Object?>();
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is! Map) {
      throw const CollaborationClientException(
        'Invalid collaboration response.',
      );
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const CollaborationClientException(
          'Invalid collaboration response.',
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static CollaborationCursor _cursor(
    Map<String, Object?> data, [
    String key = 'cursor',
  ]) {
    final value = _string(data, key);
    if (utf8.encode(value).length > 512) _invalidResponse();
    return CollaborationCursor(value);
  }
}
