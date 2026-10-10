import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/collaboration/client.dart';
import 'collaboration_coordinator_test.dart' show FakeScheduler;

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  for (final appCheck in [false, true]) {
    for (final throwsOffline in [false, true]) {
      test('${appCheck ? 'AppCheck' : 'token'} offline ${throwsOffline ? 'throw' : 'null'} retains session and reconnects', () async {
        final dir = await Directory.systemTemp.createTemp('collab-credentials');
        addTearDown(() => dir.delete(recursive: true));
        final server = SessionTransport();
        final scheduler = FakeScheduler();
        var offline = false;
        Future<String?> credential() async {
          if (!offline) return 'credential';
          if (throwsOffline) throw StateError('offline private detail');
          return null;
        }
        CollaborationProduction make() => CollaborationProduction(endpoint: 'https://test.invalid',
          rootDirectory: () async => dir, accountReady: () => true, currentUid: () => 'owner',
          accessToken: appCheck ? () async => 'token' : credential,
          appCheckToken: appCheck ? credential : () async => 'check',
          scheduler: scheduler, httpClientFactory: () => MockClient(server.respond));
        var owner = make();
        await owner.bind('owner', 0);
        await owner.create();
        owner.setForeground(true);
        await until(() => server.stateReads == 1 && scheduler.activeCount == 2 && !owner.stale);
        offline = true;
        owner.refresh();
        await until(() => owner.stale);
        await expectLater(owner.sendMessage('offline send'), throwsA(
          isA<CollaborationClientException>().having((e) => e.code, 'code', 'credential_unavailable')
            .having((e) => e.statusCode, 'not an HTTP denial', isNull)));
        expect(owner.sessionToken, 'token');
        offline = false;
        server.add('after reconnect');
        scheduler.advance(const Duration(seconds: 2));
        await until(() => owner.state?.messages.lastOrNull?.text == 'after reconnect');
        await owner.release();
        owner = make();
        await owner.bind('owner', 1);
        expect(owner.sessionToken, 'token');
        await owner.release();
      });
    }
  }

  test('displayed member deleted before revoke returns member_not_found without clearing owner session', () async {
    final dir = await Directory.systemTemp.createTemp('collab-target-deleted');
    addTearDown(() => dir.delete(recursive: true));
    final server = SessionTransport();
    var targetDeleted = false;
    CollaborationProduction make() => CollaborationProduction(endpoint: 'https://test.invalid',
      rootDirectory: () async => dir, accountReady: () => true, currentUid: () => 'owner',
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      httpClientFactory: () => MockClient((request) async {
        if (request.method == 'DELETE' && targetDeleted) {
          return http.Response(jsonEncode({'schemaVersion': 1, 'code': 'member_not_found',
            'message': 'Member not found'}), 404, headers: {'cache-control': 'no-store'});
        }
        return server.respond(request);
      }));
    var owner = make();
    await owner.bind('owner', 0);
    await owner.create();
    server.events.add({'schemaVersion': 1, 'eventId': 'joined', 'sessionId': 'session',
      'eventSequence': 1, 'senderParticipantId': 'target', 'kind': 'membership',
      'createdAt': '2026-10-10T00:00:00Z',
      'payload': {'action': 'joined', 'participantId': 'target', 'role': 'participant'}});
    owner.setForeground(true);
    await until(() => owner.state?.members.containsKey('target') == true);
    targetDeleted = true;
    await expectLater(owner.revokeMember('target'), throwsA(isA<CollaborationClientException>()
      .having((e) => e.code, 'code', 'member_not_found')));
    expect(owner.sessionToken, 'token');
    expect(owner.isOwner, isTrue);
    await owner.sendMessage('still owner');
    await owner.release();
    owner = make();
    await owner.bind('owner', 1);
    expect(owner.sessionToken, 'token');
    await owner.release();
  });

  for (final terminal in ['not_member', 'session_closed', 'unauthenticated']) {
    test('$terminal clears durable session and permits fresh create after restart', () async {
      final dir = await Directory.systemTemp.createTemp('collab-terminal');
      addTearDown(() => dir.delete(recursive: true));
      final unrelated = File('${dir.path}/account-settings');
      await unrelated.writeAsString('keep');
      final server = SessionTransport();
      CollaborationProduction make() => CollaborationProduction(endpoint: 'https://test.invalid',
        rootDirectory: () async => dir, accountReady: () => true, currentUid: () => 'owner',
        accessToken: () async => 'token', appCheckToken: () async => 'check',
        httpClientFactory: () => MockClient(server.respond));
      var owner = make();
      await owner.bind('owner', 0);
      await owner.create();
      server.terminal = terminal;
      owner.setForeground(true);
      await until(() => owner.sessionToken == null);
      await owner.release();
      owner = make();
      await owner.bind('owner', 1);
      expect(owner.sessionToken, isNull);
      expect(await unrelated.readAsString(), 'keep');
      server.terminal = null;
      await owner.create();
      expect(owner.sessionToken, 'token');
      await owner.release();
    });
  }

  test('500 history messages and sends every ten seconds retain recent visibility without bootstrap reset', () async {
    final dir = await Directory.systemTemp.createTemp('collab-send');
    addTearDown(() => dir.delete(recursive: true));
    final server = SessionTransport();
    final scheduler = FakeScheduler();
    final owner = CollaborationProduction(endpoint: 'https://test.invalid',
      rootDirectory: () async => dir, accountReady: () => true, currentUid: () => 'owner',
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      scheduler: scheduler, httpClientFactory: () => MockClient(server.respond));
    await owner.bind('owner', 0);
    await owner.create();
    for (var i = 0; i < 500; i++) { server.add('history-$i'); }
    owner.setForeground(true);
    await until(() => owner.state?.lastSequence == 400);
    for (var i = 0; i < 3; i++) {
      scheduler.advance(const Duration(seconds: 10));
      await owner.sendMessage('recent-$i');
      await until(() => owner.state?.messages.last.text == 'recent-$i');
      expect(owner.state!.messages.length, 501 + i);
      expect(server.stateReads, 1);
    }
    await owner.release();
  });
}

class SessionTransport {
  final events = <Map<String, Object?>>[];
  int stateReads = 0;
  String? terminal;
  final session = {'schemaVersion': 1, 'sessionId': 'session', 'ownerParticipantId': 'owner', 'lifecycle': 'active'};
  final member = {'participantId': 'owner', 'role': 'owner', 'status': 'active'};
  Map<String, Object?> add(String text, [String? id]) {
    final event = <String, Object?>{'schemaVersion': 1, 'eventId': id ?? 'e${events.length}',
      'sessionId': 'session', 'eventSequence': events.length + 1, 'senderParticipantId': 'owner',
      'kind': 'message', 'createdAt': '2026-10-10T00:00:00Z', 'payload': {'text': text}};
    events.add(event);
    return event;
  }
  Future<http.Response> respond(http.Request request) async {
    http.Response ok(Object body, [int status = 200]) => http.Response(jsonEncode(body), status,
      headers: {'cache-control': 'no-store'});
    if (terminal != null) {
      return ok({'schemaVersion': 1, 'code': terminal,
        'message': terminal == 'unauthenticated' ? 'Authentication required' : terminal == 'not_member' ? 'Not a session member' : 'Session is closed'},
        terminal == 'unauthenticated' ? 401 : terminal == 'not_member' ? 403 : 409);
    }
    if (request.url.path == '/chat') {
      return ok({'schemaVersion': 1, 'sessionToken': 'token',
        'session': session, 'member': member, 'cursor': '0'});
    }
    if (request.url.path.endsWith('/events')) {
      if (request.method == 'POST') {
        final raw = (jsonDecode(request.body)['events'] as List).single;
        final event = add(raw['payload']['text'] as String, raw['eventId'] as String);
        return ok({'schemaVersion': 1, 'events': [event], 'nextCursor': '${events.length}', 'hasMore': false});
      }
      final start = int.parse(request.url.queryParameters['cursor'] ?? '0');
      final page = events.skip(start).take(100).toList();
      return ok({'schemaVersion': 1, 'events': page, 'nextCursor': '${start + page.length}',
        'hasMore': start + page.length < events.length});
    }
    stateReads++;
    return ok({'schemaVersion': 1, 'session': session, 'member': member, 'members': [member],
      'initialMembers': [member], 'replayThroughSequence': events.length, 'cursor': '0'});
  }
}
