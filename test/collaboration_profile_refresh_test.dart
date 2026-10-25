import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/production.dart';

import 'collaboration_coordinator_test.dart' show FakeScheduler;

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Flutter tests.

const _sessionId = '00000000-0000-4000-8000-000000000001';
const _messageId = '00000000-0000-4000-8000-000000000002';

class _ProfileServer {
  final requests = <http.Request>[];
  final stateRequests = <http.Request>[];
  var ownerName = 'Old Owner';
  var friendName = 'Old Friend';
  var failState = false;
  Completer<void>? nextStateGate;
  final stateGates = <int, Completer<void>>{};
  String? nextStateOwnerName;

  Map<String, Object?> get state => {
    'schemaVersion': 1,
    'session': {
      'schemaVersion': 1,
      'sessionId': _sessionId,
      'ownerParticipantId': 'p-owner',
      'lifecycle': 'active',
    },
    'member': {
      'participantId': 'p-owner',
      'role': 'owner',
      'status': 'active',
      'displayName': ownerName,
    },
    'members': [
      {
        'participantId': 'p-owner',
        'role': 'owner',
        'status': 'active',
        'displayName': ownerName,
      },
      {
        'participantId': 'p-friend',
        'role': 'participant',
        'status': 'active',
        'displayName': friendName,
      },
    ],
    // Deliberately owner-only: this cannot supply the full renamed roster.
    'initialMembers': [
      {
        'participantId': 'p-owner',
        'role': 'owner',
        'status': 'active',
        'displayName': ownerName,
      },
    ],
    'replayThroughSequence': 1,
    'cursor': 'v1:0',
    'turn': null,
  };

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    http.Response json(Object? body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'cache-control': 'private, no-store'},
    );
    if (request.url.path == '/chat') {
      return json({
        'schemaVersion': 1,
        'sessionToken': 'tok',
        'session': state['session'],
        'member': state['member'],
        'cursor': 'v1:0',
      }, 201);
    }
    if (request.url.path == '/chat/tok/events') {
      return json({
        'schemaVersion': 1,
        'events': [
          {
            'schemaVersion': 1,
            'eventId': 'message:$_messageId',
            'sessionId': _sessionId,
            'eventSequence': 1,
            'senderParticipantId': 'p-friend',
            'kind': 'message',
            'createdAt': '2026-01-01T00:00:01.000Z',
            'payload': {'text': 'preserve this replayed message', 'role': 'user'},
          },
        ],
        'nextCursor': 'v1:opaque',
        'hasMore': false,
      });
    }
    if (request.url.path == '/chat/tok') {
      stateRequests.add(request);
      final responseOwnerName = nextStateOwnerName ?? ownerName;
      nextStateOwnerName = null;
      final gate = nextStateGate;
      nextStateGate = null;
      if (gate != null) await gate.future;
      final numberedGate = stateGates.remove(stateRequests.length);
      if (numberedGate != null) await numberedGate.future;
      if (failState) return http.Response('private upstream detail', 503,
          headers: {'cache-control': 'private, no-store'});
      final response = state;
      final member = Map<String, Object?>.from(response['member'] as Map)
        ..['displayName'] = responseOwnerName;
      final members = [
        for (final raw in response['members'] as List)
          Map<String, Object?>.from(raw as Map)
            ..['displayName'] = (raw as Map)['participantId'] == 'p-owner'
                ? responseOwnerName
                : (raw as Map)['displayName'],
      ];
      final initialMembers = [
        for (final raw in response['initialMembers'] as List)
          Map<String, Object?>.from(raw as Map)
            ..['displayName'] = responseOwnerName,
      ];
      return json({
        ...response,
        'member': member,
        'members': members,
        'initialMembers': initialMembers,
      });
    }
    return json({'error': {'code': 'not_found', 'message': 'Route not found.'}}, 404);
  }
}

Future<void> _until(bool Function() condition) async {
  for (var index = 0; index < 400 && !condition(); index++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory root;
  late _ProfileServer server;
  late FakeScheduler scheduler;
  late String uid;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('collab-profile-refresh-');
    server = _ProfileServer();
    scheduler = FakeScheduler();
    uid = 'alice';
  });
  tearDown(() => root.delete(recursive: true));

  CollaborationProduction make() => CollaborationProduction(
    endpoint: 'https://collab.example.test',
    rootDirectory: () async => root,
    accountReady: () => true,
    currentUid: () => uid,
    accessToken: () async => 'token',
    scheduler: scheduler,
    httpClientFactory: () => MockClient(server.handle),
  );

  test('bootstrapped force refresh applies FULL roster and names without replay reset', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    owner.setForeground(true);
    await _until(() =>
        server.stateRequests.length >= 2 && owner.state?.messages.length == 1);
    final baselineReads = server.stateRequests.length;
    final baselineCursor = owner.state!.lastSequence;
    server.ownerName = 'New Owner';
    server.friendName = 'New Friend';
    final gate = Completer<void>();
    server.nextStateGate = gate;

    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == baselineReads + 1);
    gate.complete();
    await _until(() => owner.state?.nameOf('p-friend') == 'New Friend');

    // One forced operation performs before/after-replay reads; the duplicate
    // call is coalesced rather than starting another operation.
    expect(server.stateRequests, hasLength(baselineReads + 2));
    expect(owner.state!.members, hasLength(2));
    expect(owner.state!.nameOf('p-owner'), 'New Owner');
    expect(owner.state!.messages.single.text, 'preserve this replayed message');
    expect(owner.state!.lastSequence, baselineCursor);
    await owner.release();
  });

  test('forced rename during a pre-confirmation second GET leaves a trailing read', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    final gate = Completer<void>();
    server.stateGates[2] = gate;
    owner.setForeground(true);
    await _until(() => server.stateRequests.length == 2);

    server.ownerName = 'Post Confirmation Name';
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    gate.complete();
    await _until(() => server.stateRequests.length >= 3);
    await _until(() => owner.state?.nameOf('p-owner') == 'Post Confirmation Name');
    expect(owner.state!.messages.single.text, 'preserve this replayed message');
    await owner.release();
  });

  test('coordinator second rename while its forced read is outstanding gets a trailing read', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    owner.setForeground(true);
    await _until(() => server.stateRequests.length >= 2);
    final gate = Completer<void>();
    server.nextStateGate = gate;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 3);

    server.ownerName = 'Second Coordinator Name';
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    gate.complete();
    await _until(() => server.stateRequests.length >= 4);
    await _until(() => owner.state?.nameOf('p-owner') == 'Second Coordinator Name');
    await owner.release();
  });

  test('coordinator-path late response is fenced by account replacement', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    owner.setForeground(true);
    await _until(() => server.stateRequests.length >= 2);
    final gate = Completer<void>();
    server.nextStateOwnerName = 'Stale Coordinator Name';
    server.nextStateGate = gate;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 3);

    await owner.release();
    uid = 'bob';
    await owner.bind('bob', 8);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(owner.state, isNull);
    expect(owner.sessionToken, isNull);
    await owner.release();
  });

  test('detached second rename while the first read is outstanding gets a trailing read', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    final first = Completer<void>();
    server.nextStateGate = first;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 1);
    server.ownerName = 'Second Confirmed Name';
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    first.complete();
    await _until(() => server.stateRequests.length == 2);
    await _until(() => owner.state?.nameOf('p-owner') == 'Second Confirmed Name');
    await owner.release();
  });

  test('profile refresh without a live session is a no-op', () async {
    final owner = make();
    await owner.bind('alice', 7);
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await Future<void>.delayed(Duration.zero);
    expect(server.stateRequests, isEmpty);
    expect(server.requests, isEmpty);
    await owner.release();
  });

  test('detached unbootstrapped refresh coalesces and installs full server members', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    server.ownerName = 'New Owner';
    server.friendName = 'New Friend';
    final gate = Completer<void>();
    server.nextStateGate = gate;

    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 1);
    gate.complete();
    await _until(() => owner.state?.nameOf('p-friend') == 'New Friend');

    expect(server.stateRequests, hasLength(1));
    expect(owner.state!.members, hasLength(2));
    expect(owner.state!.nameOf('p-owner'), 'New Owner');
    expect(owner.state!.messages, isEmpty);
    await owner.release();
  });

  test('stale UID and generation cannot publish a late profile response', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    owner.forceRefreshAfterProfileRename(uid: 'bob', generation: 7);
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 6);
    expect(server.stateRequests, isEmpty);

    server.ownerName = 'Stale Owner';
    final gate = Completer<void>();
    server.nextStateGate = gate;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 1);
    await owner.release();
    uid = 'bob';
    await owner.bind('bob', 8);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(owner.state, isNull);
    expect(owner.sessionToken, isNull);
    await owner.release();
  });

  test('same-UID generation replacement fences the previous profile response', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    server.nextStateOwnerName = 'Stale Generation Name';
    final gate = Completer<void>();
    server.nextStateGate = gate;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => server.stateRequests.length == 1);

    await owner.bind('alice', 8);
    expect(owner.state, isNull);
    server.ownerName = 'Current Generation Name';
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(owner.state, isNull);
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    expect(server.stateRequests, hasLength(1));
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 8);
    await _until(() => owner.state?.nameOf('p-owner') == 'Current Generation Name');
    expect(server.stateRequests, hasLength(2));
    await owner.release();
  });

  test('refresh failure after a successful rename stays fire-and-forget and retryable', () async {
    final owner = make();
    await owner.bind('alice', 7);
    await owner.create(sessionId: _sessionId);
    server.ownerName = 'Durably Renamed';
    server.failState = true;

    expect(
      () => owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7),
      returnsNormally,
    );
    await _until(() => server.stateRequests.length == 1);
    await Future<void>.delayed(Duration.zero);
    expect(owner.state!.nameOf('p-owner'), 'Old Owner');

    server.failState = false;
    owner.forceRefreshAfterProfileRename(uid: 'alice', generation: 7);
    await _until(() => owner.state?.nameOf('p-owner') == 'Durably Renamed');
    await owner.release();
  });
}
