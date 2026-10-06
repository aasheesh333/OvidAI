import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/ui/conversation_share_sheet.dart';
import 'package:ovid_ai/ui/github_login_sheet.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

import '../conversation_share_service_test.dart'
    show shareReceipt, shareSession, shareUrl;

/// Wave-2 UI redesign smoke renders for the two sheet surfaces:
/// `conversation_share_sheet.dart` and `github_login_sheet.dart`.
/// Behavioral detail lives in `conversation_share_sheet_test.dart`,
/// `github_login_persistence_test.dart` and `github_login_restore_test.dart`;
/// this file pins the Aether composition of both sheets.
void main() {
  test('both sheets are AetherSheet surfaces, never AlertDialog', () {
    for (final path in const [
      'lib/ui/conversation_share_sheet.dart',
      'lib/ui/github_login_sheet.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src, contains('AetherSheet('), reason: path);
      expect(src, isNot(contains('AlertDialog')), reason: path);
    }
  });

  group('conversation share sheet', () {
    ConversationShareService serviceWithActiveLink() =>
        ConversationShareService(
          baseUrl: 'https://share.example.test',
          idToken: () async => 'token',
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'shares': [shareReceipt()],
                }),
                200,
              );
            }
            return http.Response('', 500);
          }),
        );

    testWidgets(
      'renders Aether sheet with centered QR, copy ghost and revoke danger',
      (tester) async {
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

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationShareSheet(
                session: shareSession(),
                service: serviceWithActiveLink(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AetherSheet), findsOneWidget);
        expect(find.text('Share conversation'), findsOneWidget);
        expect(find.text('Shareable link'), findsOneWidget);
        // The pure-Dart QR renderer paints into a CustomPaint grid.
        expect(find.byType(CustomPaint), findsWidgets);
        // Ghost copy + danger revoke, per the Aether button mapping.
        expect(find.widgetWithText(TextButton, 'Copy link'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Revoke'), findsOneWidget);

        final copyLink = find.widgetWithText(TextButton, 'Copy link');
        await tester.drag(find.byType(ListView), const Offset(0, -260));
        await tester.pumpAndSettle();
        await tester.tap(copyLink);
        await tester.pumpAndSettle();
        expect(copied, shareUrl);
      },
    );
  });

  group('github login sheet', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
    });

    http.Client githubClient({required bool authorize}) =>
        MockClient((request) async {
          if (request.url.path == '/login/device/code') {
            return http.Response(
              jsonEncode({
                'device_code': 'device-code',
                'user_code': 'ABCD-1234',
                'verification_uri': 'https://github.com/login/device',
                'expires_in': 900,
                'interval': 1,
              }),
              200,
            );
          }
          if (request.url.path == '/login/oauth/access_token') {
            return http.Response(
              jsonEncode(
                authorize
                    ? {'access_token': 'tok'}
                    : {'error': 'authorization_pending'},
              ),
              200,
            );
          }
          if (request.url.path == '/user') {
            return http.Response(jsonEncode({'login': 'octocat'}), 200);
          }
          return http.Response('not found', 404);
        });

    Future<void> openSheet(WidgetTester tester, http.Client client) async {
      await tester.runAsync(() async {
        // The singleton serializes token writes across tests. Run its async
        // work in the real zone rather than retaining a finished fake-time zone.
        await GitHubService.I.signOut();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () {
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        isDismissible: false,
                        backgroundColor: Colors.transparent,
                        builder: (_) => GithubLoginSheet(client: client),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        // Never pumpAndSettle while the sheet is open: the 1s expiry ticker
        // reschedules a frame every second and settle would time out.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      });
    }

    // The device flow starts on open; two pumps land on the code view without
    // tripping pumpAndSettle on the 1s expiry ticker.
    Future<void> frames(WidgetTester tester, [int n = 12]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> pumpToCodeView(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
    }

    testWidgets(
      'code view renders OAuth section, code field, sign-in primary, cancel ghost',
      (tester) async {
        await openSheet(tester, githubClient(authorize: false));
        await pumpToCodeView(tester);

        expect(find.byType(AetherSheet), findsOneWidget);
        // AetherSectionTitle uppercases its eyebrow.
        expect(find.text('GITHUB OAUTH'), findsOneWidget);
        expect(find.byType(AetherField), findsOneWidget);
        expect(find.text('ABCD-1234'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await frames(tester);
        expect(find.byType(GithubLoginSheet), findsNothing);
      },
    );

    testWidgets('copy chip still copies the code', (tester) async {
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

      await openSheet(tester, githubClient(authorize: false));
      await pumpToCodeView(tester);

      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, 'ABCD-1234');
      expect(find.text('Copied'), findsOneWidget);

      // Let the chip's 2s "Copied" reset timer elapse so no timer is left
      // pending at teardown.
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.text('Cancel'));
      await frames(tester);
    });

    testWidgets('sign-in launches the external browser verification page', (
      tester,
    ) async {
      String? launchedUrl;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') {
            launchedUrl = (call.arguments as Map)['url'] as String;
          }
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );

      await openSheet(tester, githubClient(authorize: false));
      await pumpToCodeView(tester);

      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(launchedUrl, 'https://github.com/login/device');

      await tester.tap(find.text('Cancel'));
      await frames(tester);
    });

    testWidgets('completed poll reaches the done view and pops true', (
      tester,
    ) async {
      await openSheet(tester, githubClient(authorize: true));
      await pumpToCodeView(tester);

      // Advance fake time through polling, secure storage and the UI rebuild.
      for (
        var i = 0;
        i < 20 && find.text('GitHub connected').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.text('GitHub connected'), findsOneWidget);
      expect(find.text('@octocat — repos ready in Studio'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await frames(tester);
      expect(find.byType(GithubLoginSheet), findsNothing);
      expect(GitHubService.I.token, 'tok');
      expect(
        await const FlutterSecureStorage().read(key: 'ovid_github_token'),
        'tok',
      );
      await tester.runAsync(() => GitHubService.I.signOut());
    });
  });
}
