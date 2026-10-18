import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/ui/github_login_sheet.dart';

/// PR-6e (F-171, F-177, F-178): GitHub device-flow sign-in survives
/// transient network failures, does not flood TalkBack with a per-second
/// countdown, and never shows raw exception text.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
  });

  tearDown(() async {
    await GitHubService.I.signOut();
  });

  group('pollForToken treats transport trouble as pending (F-178)', () {
    test(
      'SocketException, 502 and HTML bodies keep polling to a token',
      () async {
        var polls = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/user') {
            return http.Response(jsonEncode({'login': 'octocat'}), 200);
          }
          polls++;
          switch (polls) {
            case 1:
              throw const SocketException('Failed host lookup');
            case 2:
              return http.Response('bad gateway', 502);
            case 3:
              return http.Response('<html>captive portal</html>', 200);
            default:
              return http.Response(jsonEncode({'access_token': 'tok'}), 200);
          }
        });
        final waits = <Duration>[];
        final token = await GitHubService.I.pollForToken(
          deviceCode: 'dc',
          intervalSec: 1,
          maxWait: const Duration(minutes: 5),
          client: client,
          waitForNextPoll: (d) async => waits.add(d),
        );
        expect(token, 'tok');
        expect(polls, 4);
        expect(
          waits[1],
          greaterThan(waits[0]),
          reason: 'a transport failure backs off on top of the interval',
        );
      },
    );

    test('an OAuth error still fails', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":"access_denied"}', 200),
      );
      await expectLater(
        GitHubService.I.pollForToken(
          deviceCode: 'dc',
          intervalSec: 1,
          client: client,
          waitForNextPoll: (_) async {},
        ),
        throwsA(
          isA<GitHubAuthException>().having(
            (e) => e.code,
            'code',
            'access_denied',
          ),
        ),
      );
    });
  });

  group('GithubLoginSheet', () {
    Future<void> open(
      WidgetTester tester,
      http.Client client, {
      Future<void> Function(Duration interval)? waitForNextPoll,
    }) async {
      await tester.runAsync(() async {
        // The singleton serializes token writes across tests: run its async
        // work in the real zone (same pattern as share_sheets_test).
        await GitHubService.I.signOut();
        await tester.pumpWidget(
          MaterialApp(
             home: Scaffold(
               body: GithubLoginSheet(
                 client: client,
                 waitForNextPoll: waitForNextPoll,
               ),
             ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
    }

    http.Response deviceCode() => http.Response(
      jsonEncode({
        'device_code': 'dc',
        'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900,
        'interval': 1,
      }),
      200,
    );

    testWidgets('first poll throws SocketException, second returns a token '
        '-> done', (tester) async {
      var polls = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/login/device/code') return deviceCode();
        if (request.url.path == '/user') {
          return http.Response(jsonEncode({'login': 'octocat'}), 200);
        }
        if (++polls == 1) {
          throw const SocketException('Network is unreachable');
        }
        return http.Response(jsonEncode({'access_token': 'tok'}), 200);
      });
      await open(tester, client, waitForNextPoll: (_) async {});
      expect(find.text('ABCD-1234'), findsOneWidget);

      for (
        var i = 0;
        i < 40 && find.text('GitHub connected').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Something went wrong'), findsNothing);
      expect(find.text('GitHub connected'), findsOneWidget);
      expect(polls, greaterThanOrEqualTo(2));
    });

    testWidgets(
      '5 s in the code state leaves the live-region label unchanged',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final client = MockClient((request) async {
          if (request.url.path == '/login/device/code') return deviceCode();
          return http.Response('{"error":"authorization_pending"}', 200);
        });
        await open(tester, client);
        final before = tester.getSemantics(find.byKey(githubLoginStatusKey));
        final label = before.label;
        expect(label, isNot(contains('remaining')));
        await tester.pump(const Duration(seconds: 5));
        final after = tester.getSemantics(find.byKey(githubLoginStatusKey));
        expect(after.label, label);
        expect(
          find.textContaining('remaining'),
          findsOneWidget,
          reason: 'the countdown is still visible to sighted users',
        );
        // Unmount so the poll loop and the countdown stop.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        semantics.dispose();
      },
    );

    testWidgets('a start failure shows human copy, raw text only in Details', (
      tester,
    ) async {
      final client = MockClient((request) async {
        throw http.ClientException(
          "SocketException: Failed host lookup: 'github.com'",
          request.url,
        );
      });
      await open(tester, client);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.textContaining('ClientException'), findsNothing);
      expect(find.textContaining('connect'), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pump();
      expect(find.textContaining('Failed host lookup'), findsOneWidget);
    });
  });
}
