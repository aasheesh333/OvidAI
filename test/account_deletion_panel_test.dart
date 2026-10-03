import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';

void main() {
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
    'unactivated server explains blocker without pretending deletion works',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountDeletionPanel(
              service: AccountService(
                enabled: false,
                idToken: (_) async => null,
                appCheck: () async => null,
              ),
              reauthenticate: (_) async => null,
              requestDeletion: (_) async => throw StateError('must not submit'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not yet activated'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Delete your account'),
      );
      expect(button.onPressed, isNull);
    },
  );

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
        await tester.tap(find.text('Request deletion'));
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
      expect(find.textContaining('2026-10-04T12:00:00.000Z'), findsOneWidget);
    },
  );
}
