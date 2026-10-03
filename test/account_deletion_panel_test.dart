import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';

void main() {
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
              usesPassword: true,
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
      var authenticated = false;
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
                usesPassword: true,
                reauthenticate: (_) async =>
                    authenticated ? null : 'Wrong password',
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
        await tester.enterText(find.byType(TextField), 'password');
        await tester.tap(find.text('Request deletion'));
        await tester.pumpAndSettle();
      }

      await submit();
      expect(submitted, 0);
      expect(find.text('Wrong password'), findsOneWidget);
      authenticated = true;
      await submit();
      expect(submitted, 1);
      expect(find.textContaining('2026-10-04'), findsOneWidget);
    },
  );
}
