import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const maxCollaborationRequestBytes = 1024 * 1024;
const maxCollaborationBatchBytes = 8 * 1024 * 1024;
const maxCollaborationEvents = 100;
const maxCollaborationResponseBytes = maxCollaborationBatchBytes + 128 * 1024;

/// Multi-use link invites; the 10-member cap is enforced at join time.
const maxCollaborationInviteUses = 50;

/// Longest server-side long-poll hold for replay (seconds).
const maxCollaborationLongPollSeconds = 25;

const _maxCollaborationCursorBytes = 4096;
final _sessionIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f-]{27}$',
  caseSensitive: false,
);
final _attachmentIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
final _contentTypePattern = RegExp(
  r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+$",
);
final _modelSecretPattern = RegExp(
  r'secret|password|api[_-]?key|byok|bearer|sk-',
  caseSensitive: false,
);

bool _validContentType(String value) =>
    value.length <= 255 &&
    !value.contains('*') &&
    _contentTypePattern.hasMatch(value);

bool _validModel(String value) =>
    value.isNotEmpty &&
    value.trim().isNotEmpty &&
    value.length <= 160 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
    !_modelSecretPattern.hasMatch(value);

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
  // The single-sender rule: another participant's turn is still running.
  'turn_locked': 'Another participant is replying',
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
  'storage_quota_exceeded': 'The storage allowance for this plan is exhausted.',
  'upload_limit_reached': 'The upload allowance for this plan is exhausted.',
  'target_not_found': 'Report target not found',
  'report_limit_reached': 'Report limit reached',
  'object_not_found': 'This file is no longer available.',
  'object_cleanup_required': 'The failed upload needs cleanup before it can be retried.',
  'attachment_too_large': 'Attachments are limited to 25000000 bytes.',
  'attachment_not_uploaded': 'The attachment object has not reached storage.',
  'attachment_size_mismatch': 'The uploaded object size does not match the attachment declaration.',
  'attachment_type_mismatch': 'The uploaded object Content-Type does not match the attachment declaration.',
  'attachment_changed': 'The attachment upload is no longer active.',
  'artifact_unavailable': 'This file is no longer available in Ovid Cloud.',
  'artifact_incomplete': 'This file did not finish uploading. Remove and re-attach it.',
  'model_unavailable': 'The requested model is unavailable',
  // The gateway answered "no such route": the collaboration surface is not
  // deployed. Never confuse this with a failure of this room.
  'collab_unavailable': 'Live sessions are unavailable',
};

const _errorMessageAliases = <String, Set<String>>{
  'temporarily_unavailable': {
    'The collaboration object service is temporarily unavailable',
  },
  'attachment_not_uploaded': {
    'The attachment object is not available in storage.',
  },
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
    this.turn,
  });

  final CollaborationSession session;
  final Member member;
  final List<Member> members;
  final CollaborationCursor cursor;
  final List<Member>? initialMembers;
  final int replayThroughSequence;

  /// Authoritative full-run lease from the top-level state DTO.
  final CollaborationTurn? turn;
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

class CollaborationAttachmentTicket {
  const CollaborationAttachmentTicket({
    required this.attachmentId,
    required this.uploadUrl,
    required this.path,
    required this.expiresAt,
    required this.contentType,
    required this.requiredHeaders,
    required this.declaredBytes,
  });

  final String attachmentId;
  final Uri uploadUrl;
  final String path;
  final DateTime expiresAt;
  final String contentType;
  final Map<String, String> requiredHeaders;
  final int declaredBytes;
}

class CollaborationFinalizedAttachment {
  const CollaborationFinalizedAttachment({
    required this.attachmentId,
    required this.size,
    required this.contentType,
  });

  final String attachmentId;
  final int size;
  final String contentType;
}

class CollaborationObjectUrl {
  const CollaborationObjectUrl({required this.url, required this.expiresAt});

  final Uri url;
  final DateTime expiresAt;
}

class CollaborationClient {
  CollaborationClient({
    required this.baseUri,
    required this.accessToken,
    this.appCheckToken,
    this.requestTimeout = const Duration(seconds: 30),
    http.Client? httpClient,
  }) : assert(requestTimeout > Duration.zero), _httpClient = httpClient ?? http.Client();

  final Uri baseUri;
  final Future<String?> Function() accessToken;
  /// Null when App Check is off (`OVID_APPCHECK`, the default): no header
  /// is sent and none is required. When set, a token is mandatory.
  final Future<String?> Function()? appCheckToken;
  final http.Client _httpClient;
  final Duration requestTimeout;

  Future<CollaborationCreateResult> create({
    required String requestId,
    String? sessionId,
  }) async {
    if (sessionId != null && !_sessionIdPattern.hasMatch(sessionId)) {
      _invalidRequest();
    }
    final data = await _request(
      'POST',
      '/chat',
      body: {
        'schemaVersion': collaborationSchemaVersion,
        'requestId': requestId,
        'idempotencyKey': requestId,
        if (sessionId != null) 'sessionId': sessionId,
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
      // Server-owned sender turn (single-sender contract). Parsed by the
      // reducer from events; the bootstrap state only needs to tolerate it.
      if (data.containsKey('turn')) 'turn',
    });
    _version(data);
    final members = _list(data, 'members');
    // Server cap is 50 active members (owner included).
    if (members.length > 50) _invalidResponse();
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
      turn: data['turn'] == null
          ? null
          : _wire(() => CollaborationTurn.fromWire(data['turn'])),
    );
  }

  Future<CollaborationTurnResult> turn(
    String sessionToken, {
    required String idempotencyKey,
    required String text,
    String? model,
    List<String> attachmentIds = const [],
  }) async {
    _segment(sessionToken);
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(idempotencyKey) ||
        text.trim().isEmpty) {
      _invalidRequest();
    }
    if (model != null && !_validModel(model)) _invalidRequest();
    final ids = <String>{};
    for (final id in attachmentIds) {
      if (!_attachmentIdPattern.hasMatch(id) || !ids.add(id)) {
        _invalidRequest();
      }
    }
    final data = await _request('POST', '/chat/$sessionToken/turns', body: {
      'schemaVersion': collaborationSchemaVersion,
      'idempotencyKey': idempotencyKey,
      'text': text,
      if (model != null) 'model': model,
      if (attachmentIds.isNotEmpty) 'attachmentIds': attachmentIds,
    });
    return _wire(() => CollaborationTurnResult.fromWire(data));
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
    if (maxUses < 1 || maxUses > maxCollaborationInviteUses ||
        ttlSeconds < 1 || ttlSeconds > 7 * 86400) {
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
    if (expiresAt == null || !expires.endsWith('Z') || uses is! int || uses < 1 ||
        uses > maxCollaborationInviteUses ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code)) {
      _invalidResponse();
    }
    return CollaborationInvite(inviteId: _string(data, 'inviteId'), inviteCode: code,
      expiresAt: expiresAt, maxUses: uses);
  }

  /// Owner-only: the link stops admitting new members; members stay.
  Future<void> revokeInvite(String sessionToken, {required String inviteId}) async {
    _segment(sessionToken);
    if (!RegExp(r'^i[0-9a-f]{32}$').hasMatch(inviteId)) _invalidRequest();
    final data = await _request('DELETE', '/chat/$sessionToken/invites/$inviteId');
    _exact(data, const {'schemaVersion', 'inviteId', 'revoked'});
    _version(data);
    if (data['inviteId'] != inviteId || data['revoked'] != true) _invalidResponse();
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

  /// [waitSeconds] > 0 long-polls: the server holds the request until new
  /// events exist or the wait elapses (then returns an empty page).
  Future<CollaborationEventPage> replay(
    String sessionToken, {
    CollaborationCursor? cursor,
    int waitSeconds = 0,
  }) async {
    _segment(sessionToken);
    if (cursor != null &&
        (cursor.value.isEmpty ||
            utf8.encode(cursor.value).length > _maxCollaborationCursorBytes)) {
      _invalidRequest();
    }
    if (waitSeconds < 0 || waitSeconds > maxCollaborationLongPollSeconds) {
      _invalidRequest();
    }
    final data = await _request(
      'GET',
      '/chat/$sessionToken/events',
      query: {
        if (cursor != null) 'cursor': cursor.value,
        if (waitSeconds > 0) 'wait': '$waitSeconds',
      },
      timeout: waitSeconds > 0
          ? requestTimeout + Duration(seconds: waitSeconds)
          : null,
    );
    _exact(data, const {'schemaVersion', 'events', 'nextCursor', 'hasMore'});
    _version(data);
    return CollaborationEventPage(
      events: _events(data, maxBytes: 256 * 1024),
      nextCursor: _cursor(data, 'nextCursor'),
      hasMore: _bool(data, 'hasMore'),
    );
  }

  Future<CollaborationAttachmentTicket> createAttachment(
    String sessionToken, {
    required String idempotencyKey,
    required String name,
    required int size,
    required String contentType,
  }) async {
    _segment(sessionToken);
    if (name.isEmpty ||
        name.length > 255 ||
        size <= 0 ||
        size > 25000000 ||
        !_validContentType(contentType)) {
      _invalidRequest();
    }
    final data = await _request('POST', '/chat/$sessionToken/attachments', body: {
      'schemaVersion': collaborationSchemaVersion,
      'idempotencyKey': idempotencyKey,
      'name': name,
      'size': size,
      'contentType': contentType,
    });
    _exact(data, const {
      'schemaVersion',
      'attachmentId',
      'uploadUrl',
      'path',
      'expiresAt',
      'contentType',
      'requiredHeaders',
      'uploadHeaders',
    });
    _version(data);
    final attachmentId = _id(data, 'attachmentId');
    if (!_attachmentIdPattern.hasMatch(attachmentId)) _invalidResponse();
    final path = _string(data, 'path');
    final segment = path.startsWith('uploads/') ? path.substring(8) : '';
    if (!RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(segment) ||
        segment.startsWith('.') ||
        segment.contains('..')) {
      _invalidResponse();
    }
    final requiredHeaders = _stringMap(data['requiredHeaders']);
    final uploadHeaders = _stringMap(data['uploadHeaders']);
    if (requiredHeaders.length != uploadHeaders.length ||
        requiredHeaders.entries.any((entry) => uploadHeaders[entry.key] != entry.value)) {
      _invalidResponse();
    }
    for (final entry in requiredHeaders.entries) {
      if (!_headerName.hasMatch(entry.key) ||
          entry.value.contains(RegExp(r'[\r\n]')) ||
          const {'authorization', 'cookie', 'x-firebase-appcheck'}
              .contains(entry.key.toLowerCase())) {
        _invalidResponse();
      }
    }
    return CollaborationAttachmentTicket(
      attachmentId: attachmentId,
      uploadUrl: _url(data, 'uploadUrl'),
      path: path,
      expiresAt: _timestamp(data, 'expiresAt'),
      contentType: _contentType(data, 'contentType'),
      requiredHeaders: Map.unmodifiable(requiredHeaders),
      declaredBytes: size,
    );
  }

  /// Uploads actual bytes directly to the server-issued signed URL. No account
  /// credential, App Check, or extra header is added to the signed request.
  Future<void> uploadAttachment(
    CollaborationAttachmentTicket ticket,
    List<int> bytes,
  ) async {
    if (bytes.isEmpty || bytes.length != ticket.declaredBytes) _invalidRequest();
    final abort = Completer<void>();
    final request = http.AbortableRequest('PUT', ticket.uploadUrl,
        abortTrigger: abort.future)
      ..followRedirects = false
      ..headers.addAll(ticket.requiredHeaders)
      ..bodyBytes = bytes;
    try {
      final response = await _httpClient.send(request).timeout(requestTimeout,
          onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw const CollaborationClientException(
          'Collaboration request timed out.',
          code: 'request_timeout',
        );
      });
      await _readBody(response, abort);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const CollaborationClientException('Collaboration upload failed.');
      }
    } on CollaborationClientException {
      rethrow;
    } catch (_) {
      throw const CollaborationClientException('Collaboration upload failed.');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<CollaborationFinalizedAttachment> finalizeAttachment(
    String sessionToken, {
    required String attachmentId,
  }) async {
    _segment(sessionToken);
    if (!_attachmentIdPattern.hasMatch(attachmentId)) _invalidRequest();
    final data = await _request(
      'POST',
      '/chat/$sessionToken/attachments/$attachmentId/finalize',
      body: {'schemaVersion': collaborationSchemaVersion},
    );
    _exact(data, const {
      'schemaVersion',
      'attachmentId',
      'status',
      'size',
      'contentType',
    });
    _version(data);
    final size = data['size'];
    if (_string(data, 'attachmentId') != attachmentId ||
        data['status'] != 'ready' ||
        size is! int ||
        size <= 0) {
      _invalidResponse();
    }
    return CollaborationFinalizedAttachment(
      attachmentId: attachmentId,
      size: size,
      contentType: _contentType(data, 'contentType'),
    );
  }

  Future<CollaborationObjectUrl> objectUrl(
    String sessionToken, {
    String? artifactId,
    String? attachmentId,
  }) async {
    _segment(sessionToken);
    if ((artifactId == null) == (attachmentId == null) ||
        (artifactId != null && !_attachmentIdPattern.hasMatch(artifactId)) ||
        (attachmentId != null && !_attachmentIdPattern.hasMatch(attachmentId))) {
      _invalidRequest();
    }
    final kind = artifactId != null ? 'artifacts' : 'attachments';
    final id = artifactId ?? attachmentId!;
    final data = await _request(
      'GET',
      '/chat/$sessionToken/$kind/$id/url',
    );
    _exact(data, const {'schemaVersion', 'url', 'expiresAt'});
    _version(data);
    return CollaborationObjectUrl(
      url: _url(data, 'url'),
      expiresAt: _timestamp(data, 'expiresAt'),
    );
  }

  Future<String> report(
    String sessionToken, {
    required String requestId,
    required String kind,
    required String targetId,
    required String reason,
    String? details,
  }) async {
    _segment(sessionToken);
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(requestId) ||
        !const {'collab_message', 'collab_participant'}.contains(kind) ||
        targetId.isEmpty ||
        targetId.length > 128 ||
        !const {
          'sexual',
          'child_safety',
          'hate',
          'violence',
          'self_harm',
          'illegal',
          'misleading',
          'privacy',
          'spam',
          'other',
        }.contains(reason) ||
        (details != null && details.runes.length > 1000)) {
      _invalidRequest();
    }
    final data = await _request('POST', '/chat/$sessionToken/reports', body: {
      'schemaVersion': collaborationSchemaVersion,
      'requestId': requestId,
      'kind': kind,
      'targetId': targetId,
      'reason': reason,
      if (details != null) 'details': details,
    });
    _exact(data, const {'schemaVersion', 'reportId'});
    _version(data);
    return _id(data, 'reportId');
  }

  Future<void> block(String sessionToken, {required String participantId}) =>
      _setBlock(sessionToken, participantId, true);

  Future<void> unblock(String sessionToken, {required String participantId}) =>
      _setBlock(sessionToken, participantId, false);

  Future<void> _setBlock(
    String sessionToken,
    String participantId,
    bool blocked,
  ) async {
    _segment(sessionToken);
    _segment(participantId);
    if (participantId == 'me') _invalidRequest();
    final data = await _request(
      blocked ? 'PUT' : 'DELETE',
      '/chat/$sessionToken/blocks/$participantId',
      body: blocked ? {'schemaVersion': collaborationSchemaVersion} : null,
    );
    _exact(data, const {'schemaVersion', 'participantId', 'blocked'});
    _version(data);
    if (data['participantId'] != participantId || data['blocked'] != blocked) {
      _invalidResponse();
    }
  }

  Future<void> removeMessage(
    String sessionToken, {
    required String messageId,
  }) async {
    _segment(sessionToken);
    _segment(messageId);
    final data = await _request(
      'DELETE',
      '/chat/$sessionToken/messages/$messageId',
    );
    _exact(data, const {'schemaVersion', 'messageId', 'removed'});
    _version(data);
    if (data['messageId'] != messageId || data['removed'] != true) {
      _invalidResponse();
    }
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
    Duration? timeout,
  }) async {
    final abort = Completer<void>();
    try {
      return await _performRequest(method, path, query: query, body: body, abort: abort)
          .timeout(timeout ?? requestTimeout, onTimeout: () {
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
      if (body.containsKey('idempotencyKey') &&
          (key is! String || !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key))) {
        _invalidRequest();
      }
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
      appCheck = await appCheckToken?.call();
    } catch (_) {
      throw const CollaborationClientException('Credentials are temporarily unavailable.', code: 'credential_unavailable');
    }
    if (token == null ||
        token.trim().isEmpty ||
        (appCheckToken != null && (appCheck == null || appCheck.trim().isEmpty))) {
      throw const CollaborationClientException('Credentials are temporarily unavailable.', code: 'credential_unavailable');
    }
    if (abort.isCompleted) throw const CollaborationClientException('Collaboration request timed out.', code: 'request_timeout');
    final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
    final routePath = path.startsWith('/chat') && basePath.endsWith('/chat')
        ? path.substring('/chat'.length)
        : path;
    final uri = baseUri.replace(
      path: '$basePath$routePath',
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
    };
    if (appCheck != null && appCheck.trim().isNotEmpty) {
      headers['X-Firebase-AppCheck'] = appCheck;
    }
    if (body != null) headers['Content-Type'] = 'application/json';
    try {
      final response = await _httpClient.send(
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..body = encoded,
      );
      final bytes = await _readBody(response, abort);
      final text = utf8.decode(bytes);
      final cacheDirectives = (response.headers['cache-control'] ?? '')
          .toLowerCase()
          .split(',')
          .map((value) => value.trim())
          .toSet();
      if (!cacheDirectives.contains('no-store')) {
        throw const CollaborationClientException('Invalid collaboration response.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final parsed = _asMap(jsonDecode(text));
        // The gateway's own answer for an unmounted route is the CLOUD
        // envelope (`{ error: { code, message } }`), not this contract. The
        // collaboration routes are not deployed yet, so report that instead
        // of "invalid response" — a real missing room still arrives inside
        // the collaboration envelope with `session_not_found`.
        if (const {404, 405, 501}.contains(response.statusCode) &&
            parsed['schemaVersion'] == null) {
          throw CollaborationClientException(
            'Live sessions are unavailable',
            statusCode: response.statusCode,
            code: 'collab_unavailable',
          );
        }
        _exact(parsed, const {'schemaVersion', 'code', 'message'});
        final code = parsed['code'];
        if (parsed['schemaVersion'] != collaborationSchemaVersion ||
            code is! String ||
            (_errorMessages[code] != parsed['message'] &&
                !(_errorMessageAliases[code]?.contains(parsed['message']) ?? false))) {
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

  static String _id(Map<String, Object?> data, String key) {
    final value = _string(data, key);
    if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(value)) {
      _invalidResponse();
    }
    return value;
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) _invalidResponse();
    final result = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! String) _invalidResponse();
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }

  static Uri _url(Map<String, Object?> data, String key) {
    final value = _string(data, key);
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        utf8.encode(value).length > 16384) {
      _invalidResponse();
    }
    return uri;
  }

  static DateTime _timestamp(Map<String, Object?> data, String key) {
    final value = _string(data, key);
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !value.endsWith('Z')) _invalidResponse();
    return parsed;
  }

  static String _contentType(Map<String, Object?> data, String key) {
    final value = _string(data, key);
    if (!_validContentType(value)) _invalidResponse();
    return value;
  }

  static CollaborationCursor _cursor(
    Map<String, Object?> data, [
    String key = 'cursor',
  ]) {
    final value = _string(data, key);
    if (utf8.encode(value).length > _maxCollaborationCursorBytes) {
      _invalidResponse();
    }
    return CollaborationCursor(value);
  }
}
