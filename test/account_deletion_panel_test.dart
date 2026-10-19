import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/legal_links.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:ovid_ai/ui/widgets/external_link.dart';

void main() {
  for (final paid in [true, false]) {
    testWidgets('deletion confirm ${paid ? 'warns about' : 'omits'} the Play '
        'subscription (SH-012)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountDeletionPanel(
              service: AccountService(
                enabled: true,
                idToken: (_) async => 'id',
                client: MockClient(
                  (_) async => http.Response(
                    '{"state":"active","delete_after":null,"request_id":null}',
                    200,
                  ),
                ),
              ),
              subscriptionActive: () => paid,
              reauthenticate: (_) async => 'cancelled',
              requestDeletion: (_) async => throw StateError('no submit'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete your account'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('deletion-subscription-warning')),
        paid ? findsOneWidget : findsNothing,
      );
      expect(find.textContaining('Local workspaces'), findsNothing);
      await tester.tap(find.text('Keep account'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('removed deletion panel ignores late successful provider proof', (
    tester,
  ) async {
    final verification = Completer<String?>();
    var submitted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountDeletionPanel(
            service: AccountService(
              enabled: true,
              idToken: (_) async => 'id',
              appCheck: () async => 'app',
              client: MockClient(
                (_) async => http.Response(
                  '{"state":"active","delete_after":null,"request_id":null}',
                  200,
                ),
              ),
            ),
            reauthenticate: (_) => verification.future,
            requestDeletion: (_) async {
              submitted++;
              throw StateError('unexpected submission');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete your account'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Request deletion'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    verification.complete(null);
    await tester.pumpAndSettle();
    expect(submitted, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unactivated server offers a working web and email deletion request',
    (tester) async {
      final launched = <Uri>[];
      externalLinkLauncherForTest = (uri) async {
        launched.add(uri);
        return true;
      };
      addTearDown(() => externalLinkLauncherForTest = null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountDeletionPanel(
                service: AccountService(
                  enabled: false,
                  idToken: (_) async => null,
                  appCheck: () async => null,
                ),
                uid: 'uid-123',
                reauthenticate: (_) async => throw StateError('no reauth'),
                requestDeletion: (_) async =>
                    throw StateError('must not submit'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not available in this version'),
          findsOneWidget);
      expect(find.text('Delete your account'), findsNothing);
      await tester.tap(find.text('Request deletion'));
      await tester.pump();
      expect(launched.single, Uri.parse(LegalLinks.accountDeletionRequest));
      await tester.tap(find.text('Email a deletion request'));
      await tester.pump();
      expect(launched.last.scheme, 'mailto');
      expect(launched.last.path, LegalLinks.supportEmail);
      expect(Uri.decodeComponent(launched.last.query), contains('uid-123'));
    },
  );

  testWidgets(
    'no re-auth provider shows the deletion request link instead of a dead end',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountDeletionPanel(
                service: AccountService(
                  enabled: true,
                  idToken: (_) async => 'id',
                  appCheck: () async => 'app',
                  client: MockClient(
                    (_) async => http.Response(
                      '{"state":"active","delete_after":null,"request_id":null}',
                      200,
                    ),
                  ),
                ),
                canReauthenticate: false,
                reauthenticate: (_) async => throw StateError('no reauth'),
                requestDeletion: (_) async =>
                    throw StateError('must not submit'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('None of the sign-in methods'),
          findsOneWidget);
      expect(find.widgetWithText(AetherDangerButton, 'Request deletion'),
          findsOneWidget);
      expect(find.text('Email a deletion request'), findsOneWidget);
      expect(find.text('Delete your account'), findsNothing);
    },
  );

  testWidgets('panel restore goes through the account owner, not the raw API', (
    tester,
  ) async {
    var ownerRestores = 0;
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountDeletionPanel(
              service: AccountService(
                enabled: true,
                idToken: (_) async => 'id',
                appCheck: () async => 'app',
                client: MockClient((request) async {
                  calls.add(request.url.path);
                  return http.Response(
                    '{"state":"pending","delete_after":87400,"request_id":"request-0001"}',
                    200,
                  );
                }),
              ),
              reauthenticate: (_) async => null,
              requestDeletion: (_) async => throw StateError('must not request'),
              restore: () async {
                ownerRestores++;
                return const AccountDeletion('cancelled', null, 'request-0001');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore account'));
    await tester.pumpAndSettle();
    expect(ownerRestores, 1);
    expect(calls, isNot(contains('/account/deletion/cancel')));
    expect(find.text('Your deletion request was cancelled.'), findsOneWidget);
    expect(find.text('Restore account'), findsNothing);
  });

  testWidgets(
    'reauth failure prevents submission; server success shows exact deadline',
    (tester) async {
      String? verificationError =
          'That identity belongs to a different account.';
      var verifications = 0;
      var submitted = 0;
      final service = AccountService(
        enabled: true,
        idToken: (_) async => 'id',
        appCheck: () async => 'app',
        client: MockClient(
          (_) async => http.Response(
            '{"state":"active","delete_after":null,"request_id":null}',
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AccountDeletionPanel(
                service: service,
                reauthenticate: (unused) async {
                  expect(unused, isNull);
                  verifications++;
                  return verificationError;
                },
                requestDeletion: (id) async {
                  submitted++;
                  return AccountDeletion(
                    'pending',
                    DateTime.utc(2026, 10, 4, 12),
                    id,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> submit() async {
        await tester.tap(find.text('Delete your account'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.textContaining('social provider or phone'), findsOneWidget);
        final requestButton = find.text('Request deletion');
        await tester.ensureVisible(requestButton);
        await tester.tap(requestButton);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Delete your account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep account'));
      await tester.pumpAndSettle();
      expect(verifications, 0);
      expect(submitted, 0);

      await tester.tap(find.text('Delete your account'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(verifications, 0);

      await submit();
      expect(submitted, 0);
      expect(find.textContaining('different account'), findsOneWidget);
      verificationError = 'cancelled';
      await submit();
      expect(submitted, 0);
      expect(find.textContaining('different account'), findsNothing);
      expect(find.text('cancelled'), findsNothing);
      verificationError = null;
      await submit();
      expect(submitted, 1);
      expect(find.textContaining('Oct 4'), findsWidgets);
      expect(find.textContaining('T12:00:00.000Z'), findsNothing);
    },
  );

  testWidgets('duplicate restore taps are disabled while restore is pending', (
    tester,
  ) async {
    final verification = Completer<String?>();
    var verificationCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountDeletionPanel(
            service: AccountService(
              enabled: true,
              idToken: (_) async => 'id',
              appCheck: () async => 'app',
              client: MockClient(
                (_) async => http.Response(
                  '{"state":"pending","delete_after":87400,"request_id":"request-0001"}',
                  200,
                ),
              ),
            ),
            reauthenticate: (_) {
              verificationCalls++;
              return verification.future;
            },
            requestDeletion: (_) async => throw StateError('must not request'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore account'));
    await tester.pump();
    await tester.tap(find.text('Restore account'));
    expect(verificationCalls, 1);
    verification.complete('cancelled');
    await tester.pumpAndSettle();
  });
}
