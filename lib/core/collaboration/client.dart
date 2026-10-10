import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

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
  'temporarily_unavailable': 'The collaboration service is temporarily unavailable',
};

class CollaborationClientException implements Exception {
  const CollaborationClientException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

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
  });

  final CollaborationSession session;
  final Member member;
  final List<Member> members;
  final CollaborationCursor cursor;
}

class CollaborationJoinResult {
  const CollaborationJoinResult({required this.member, required this.cursor});

  final Member member;
  final CollaborationCursor cursor;
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
    this.appCheckToken,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final Future<String?> Function() accessToken;
  final Future<String?> Function()? appCheckToken;
  final http.Client _httpClient;

  Future<CollaborationCreateResult> create({required String requestId}) async {
    final data = await _request(
      'POST',
      '/chat',
      body: {
        'schemaVersion': collaborationSchemaVersion,
        'requestId': requestId,
        'idempotencyKey': requestId,
      },
      idempotencyKey: requestId,
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
      session: CollaborationSession.fromWire(_map(data, 'session')),
      member: Member.fromWire(_map(data, 'member')),
      cursor: _cursor(data, 'cursor'),
    );
  }

  Future<CollaborationState> state(String sessionToken) async {
    final data = await _request('GET', '/chat/$sessionToken');
    _exact(data, const {
      'schemaVersion',
      'session',
      'member',
      'members',
      'cursor',
    });
    _version(data);
    final members = _list(data, 'members');
    return CollaborationState(
      session: CollaborationSession.fromWire(_map(data, 'session')),
      member: Member.fromWire(_map(data, 'member')),
      members: [for (final value in members) Member.fromWire(_asMap(value))],
      cursor: _cursor(data, 'cursor'),
    );
  }

  Future<CollaborationJoinResult> join(
    String sessionToken, {
    required String invitationCode,
    required String idempotencyKey,
  }) async {
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
      member: Member.fromWire(_map(data, 'member')),
      cursor: _cursor(data),
    );
  }

  Future<CollaborationEventPage> events(
    String sessionToken, {
    CollaborationCursor? cursor,
  }) => replay(sessionToken, cursor: cursor);

  Future<CollaborationEventPage> replay(
    String sessionToken, {
    CollaborationCursor? cursor,
  }) async {
    final data = await _request(
      'GET',
      '/chat/$sessionToken/events',
      query: cursor == null ? null : {'cursor': cursor.value},
    );
    _exact(data, const {'schemaVersion', 'events', 'nextCursor', 'hasMore'});
    _version(data);
    final rawEvents = _list(data, 'events');
    return CollaborationEventPage(
      events: [
        for (final value in rawEvents)
          CollaborationEvent.fromWire(_asMap(value)),
      ],
      nextCursor: _cursor(data, 'nextCursor'),
      hasMore: _bool(data, 'hasMore'),
    );
  }

  Future<CollaborationEventPage> appendEvents(
    String sessionToken, {
    required List<Map<String, Object?>> events,
    required String idempotencyKey,
  }) async {
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
      events: [
        for (final value in _list(data, 'events'))
          CollaborationEvent.fromWire(_asMap(value)),
      ],
      nextCursor: _cursor(data, 'nextCursor'),
      hasMore: _bool(data, 'hasMore'),
    );
  }

  Future<CollaborationSession> close(
    String sessionToken, {
    required String idempotencyKey,
  }) async {
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
    return CollaborationSession.fromWire(_map(data, 'session'));
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) async {
    final token = await accessToken();
    if (token == null || token.isEmpty) {
      throw const CollaborationClientException('Authentication required.');
    }
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
    final appCheck = appCheckToken == null ? null : await appCheckToken!();
    if (appCheck == null || appCheck.isEmpty) {
      throw const CollaborationClientException('Authentication required.', statusCode: 401, code: 'unauthenticated');
    }
    headers['X-Firebase-AppCheck'] = appCheck;
    if (body != null) headers['Content-Type'] = 'application/json';
    try {
      final response = await _httpClient.send(
        http.Request(method, uri)
          ..headers.addAll(headers)
          ..body = body == null ? '' : jsonEncode(body),
      );
      final text = await response.stream.bytesToString();
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
        throw CollaborationClientException('Collaboration request failed.',
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
    return CollaborationCursor(value);
  }
}
