import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/ui/conversation_share_sheet.dart';
import 'conversation_share_service_test.dart'
    show shareSession, shareReceipt, shareUrl;

void main() {
  testWidgets(
    'rebuilding with a new account service cannot publish the old preview',
    (tester) async {
      var uid = 'alice';
      var posts = 0;
      ConversationShareService service() => ConversationShareService(
        baseUrl: 'https://share.example.test',
        currentUid: () => uid,
        idToken: () async => uid,
        client: MockClient((r) async {
          if (r.method == 'POST') {
            posts++;
            return http.Response(jsonEncode(shareReceipt()), 201);
          }
          return http.Response('{"shares":[]}', 200);
        }),
      );
      final session = shareSession();
      Widget host() => MaterialApp(
        home: Scaffold(
          body: ConversationShareSheet(session: session, service: service()),
        ),
      );
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      uid = 'bob';
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(posts, 0);
      expect(find.textContaining('Account changed'), findsOneWidget);
    },
  );

  testWidgets(
    'refresh reconciles lost creation so revoke permits a new create',
    (tester) async {
      String? firstRequest;
      var revoked = false;
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'token',
        client: MockClient((r) async {
          if (r.method == 'POST') {
            final request = jsonDecode(r.body)['request_id'] as String;
            if (firstRequest == null) {
              firstRequest = request;
              throw http.ClientException('lost response');
            }
            if (request == firstRequest) return http.Response('', 409);
            revoked = false;
            return http.Response(
              jsonEncode({...shareReceipt(), 'request_id': request}),
              201,
            );
          }
          if (r.method == 'DELETE') {
            revoked = true;
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              'shares': firstRequest != null && !revoked
                  ? [
                      {...shareReceipt(), 'request_id': firstRequest},
                    ]
                  : [],
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationShareSheet(
              session: shareSession(),
              service: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.textContaining('already used'), findsNothing);
    },
  );

  testWidgets('preview then create then copy and revoke confirmed link', (
    tester,
  ) async {
    var created = false;
    var revoked = false;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'token',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          created = true;
          return http.Response(jsonEncode(shareReceipt()), 201);
        }
        if (request.method == 'DELETE') {
          revoked = true;
          return http.Response('', 204);
        }
        return http.Response(
          jsonEncode({
            'shares': created && !revoked ? [shareReceipt()] : [],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationShareSheet(
            session: shareSession(),
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('thinking secret'), findsNothing);
    expect(find.text('Copy link'), findsNothing);
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, shareUrl);
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(revoked, true);
    expect(find.text('Copy link'), findsNothing);
  });

  testWidgets('unconfigured deployment disables create', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationShareSheet(
            session: shareSession(),
            service: ConversationShareService(
              baseUrl: '',
              idToken: () async => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create link'),
          )
          .onPressed,
      isNull,
    );
    expect(find.textContaining('not configured'), findsOneWidget);
  });

  testWidgets('network failure displays no fabricated copy link', (
    tester,
  ) async {
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'token',
      client: MockClient(
        (r) async => r.method == 'GET'
            ? http.Response('{"shares":[]}', 200)
            : http.Response('failed', 503),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationShareSheet(
            session: shareSession(),
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create link'));
    await tester.pumpAndSettle();
    expect(find.text('Copy link'), findsNothing);
    expect(find.textContaining('unconfirmed'), findsOneWidget);
  });

  testWidgets(
    'lost create response retries frozen preview with same request ID',
    (tester) async {
      final bodies = <Map<String, dynamic>>[];
      final session = shareSession();
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'token',
        client: MockClient((r) async {
          if (r.method == 'GET') return http.Response('{"shares":[]}', 200);
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          if (bodies.length == 1) throw http.ClientException('response lost');
          return http.Response(jsonEncode(shareReceipt()), 201);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationShareSheet(session: session, service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      session.messages.first.content = 'Later edit';
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsNothing);
      await tester.tap(find.text('Create link'));
      await tester.pumpAndSettle();
      expect(bodies.length, 2);
      expect(bodies[0]['request_id'], bodies[1]['request_id']);
      expect((bodies[1]['messages'] as List).first['content'], 'Hello');
      expect(find.text('Copy link'), findsOneWidget);
    },
  );

  testWidgets(
    'existing link loads and failed revoke retains recovery control',
    (tester) async {
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'token',
        client: MockClient(
          (r) async => r.method == 'GET'
              ? http.Response(
                  jsonEncode({
                    'shares': [shareReceipt()],
                  }),
                  200,
                )
              : http.Response('failed', 503),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationShareSheet(
              session: shareSession(),
              service: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsOneWidget);
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      expect(find.text('Revoke'), findsOneWidget);
      expect(find.textContaining('unconfirmed'), findsOneWidget);
    },
  );

  testWidgets('compact large text preview scrolls without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ConversationShareSheet(
            session: shareSession(),
            service: ConversationShareService(
              baseUrl: '',
              idToken: () async => null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Answer'),
      150,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.text('Answer').hitTestable(), findsOneWidget);
  });
}
