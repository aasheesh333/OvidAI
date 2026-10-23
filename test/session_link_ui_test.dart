import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/ui/collab_session_screen.dart';
import 'package:ovid_ai/ui/conversation_share_sheet.dart';
import 'package:ovid_ai/ui/shared_conversation_screen.dart';

import 'conversation_share_service_test.dart' show shareSession;

const _token = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';
const _code = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';

void main() {
  testWidgets('share sheet first asks Read only or Collab', (tester) async {
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'token',
      client: MockClient((_) async => http.Response('{"shares":[]}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationShareSheet(session: shareSession(), service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Share this chat'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Collab'), findsOneWidget);
    expect(find.textContaining('own model'), findsOneWidget);

    await tester.tap(find.text('Read only'));
    await tester.pumpAndSettle();
    expect(find.text('Read-only link'), findsOneWidget);
    expect(find.text('Create link'), findsOneWidget);

    await tester.ensureVisible(find.text('Back'));
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Share this chat'), findsOneWidget);
  });

  testWidgets('read-only viewer retries after a failure and labels roles', (tester) async {
    var calls = 0;
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      publicOrigin: 'https://share.example.test',
      idToken: () async => 'token',
      client: MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('nope', 503);
        return http.Response(
          jsonEncode({
            'session_id': 's',
            'messages': [
              {'role': 'user', 'content': 'Question'},
              {'role': 'assistant', 'content': '```dart\nprint(1);\n```'},
            ],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(home: SharedConversationScreen(token: _token, service: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('This link is unavailable or expired.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('User'), findsOneWidget);
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
    expect(find.text('Continue this chat in Ovid'), findsOneWidget);
  });

  testWidgets('joining a full session shows 50/50', (tester) async {
    final root = await tester.runAsync(() => Directory.systemTemp.createTemp('join-'));
    addTearDown(() => root!.delete(recursive: true));
    final controller = CollaborationProduction(
      endpoint: 'https://api.example.test',
      rootDirectory: () async => root!,
      accountReady: () => true,
      currentUid: () => 'bob',
      accessToken: () async => 'id',
      appCheckToken: () async => 'app',
      httpClientFactory: () => MockClient(
        (_) async => http.Response(
          jsonEncode({'schemaVersion': 1, 'code': 'session_full', 'message': 'Session is full'}),
          409,
          headers: {'cache-control': 'no-store'},
        ),
      ),
    );
    await tester.runAsync(() => controller.bind('bob', 1));
    expect(controller.available, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: CollabJoinScreen(token: _token, invite: _code, controller: controller),
      ),
    );
    await tester.pump();
    final join = find.byIcon(Icons.group_add_outlined);
    await tester.ensureVisible(join);
    await tester.tap(join);
    // Real file I/O (durable request keys) interleaves with fake-async pumps.
    for (var i = 0; i < 40 && find.text('This session is full (50/50).').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.text('This session is full (50/50).'), findsOneWidget);
    await tester.runAsync(controller.release);
  });
}
