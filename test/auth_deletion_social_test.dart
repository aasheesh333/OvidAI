import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';

void main() {
  testWidgets(
    'deletion uses provider proof; failure and cancellation never submit',
    (tester) async {
      String? error = 'That identity belongs to a different account.';
      var submissions = 0;
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
            body: AccountDeletionPanel(
              service: service,
              reauthenticate: (unused) async {
                expect(unused, isNull);
                return error;
              },
              requestDeletion: (id) async {
                submissions++;
                return AccountDeletion(
                  'pending',
                  DateTime.utc(2026, 10, 4),
                  id,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> submit() async {
        await tester.tap(find.text('Delete your account'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('Request deletion'));
        await tester.pumpAndSettle();
      }

      await submit();
      expect(submissions, 0);
      expect(find.textContaining('different account'), findsOneWidget);
      error = 'cancelled';
      await submit();
      expect(submissions, 0);
      error = null;
      await submit();
      expect(submissions, 1);
      expect(find.textContaining('2026-10-04'), findsOneWidget);
    },
  );
}
