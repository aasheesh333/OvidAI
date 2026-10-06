// Smoke tests for the Wave 2 Aether reskin of AccountDeletionPanel.
//
// Verifies the reskin composition:
//   * the pending state renders an AetherCard wrapped in a warn left rule,
//     the countdown toward the server deadline, and the AetherGhostButton
//     'Cancel request' (with the danger request action hidden);
//   * the request flow's confirmation dialog drives the reauth hook and the
//     deletion request through the AetherDangerButton 'Request deletion',
//     then renders the returned pending status immediately;
//   * 'Cancel request' re-checks the server status and surfaces the
//     cancelled state, restoring the request action.
//
// Behavior parity (late-proof guard, unactivated-server copy, reauth
// failure surfacing) is covered by test/account_deletion_panel_test.dart
// and test/auth_deletion_social_test.dart; it is not repeated here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Minimal fake account server: answers GET /deletion from mutable state.
class _FakeAccountServer {
  String state = 'active';
  DateTime? deleteAfter;
  String? requestId;
  int statusCalls = 0;

  Future<http.Response> _handler(http.Request _) async {
    statusCalls++;
    final da = deleteAfter;
    final id = requestId;
    return http.Response(
      '{"state":"$state",'
      '"delete_after":${da == null ? 'null' : da.millisecondsSinceEpoch / 1000},'
      '"request_id":${id == null ? 'null' : '"$id"'}}',
      200,
    );
  }

  AccountService get service => AccountService(
    enabled: true,
    idToken: (_) async => 'id',
    appCheck: () async => 'app',
    client: MockClient(_handler),
  );
}

bool _hasWarnLeftRule(Widget w) {
  if (w is! Container) return false;
  final decoration = w.decoration;
  if (decoration is! BoxDecoration) return false;
  final border = decoration.border;
  if (border is! Border) return false;
  return border.left.color == Aether.warn &&
      border.left.width == 3 &&
      border.left.style == BorderStyle.solid;
}

Finder warnRule() => find.byWidgetPredicate(_hasWarnLeftRule);

Widget host({
  required AccountService service,
  required Future<String?> Function(String?) reauthenticate,
  required Future<AccountDeletion> Function(String) requestDeletion,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: AccountDeletionPanel(
        service: service,
        reauthenticate: reauthenticate,
        requestDeletion: requestDeletion,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'pending state: warn left-rule AetherCard, countdown, cancel ghost',
    (tester) async {
      final server = _FakeAccountServer()
        ..state = 'pending'
        ..deleteAfter = DateTime.now().add(const Duration(hours: 23, minutes: 30))
        ..requestId = 'req-pending';
      await tester.pumpWidget(
        host(
          service: server.service,
          reauthenticate: (_) async => null,
          requestDeletion: (_) async =>
              throw StateError('must not request while pending'),
        ),
      );
      await tester.pumpAndSettle();

      // AetherCard titled 'Deletion requested' wrapped in the warn left rule.
      expect(find.text('Deletion requested'), findsOneWidget);
      final rule = warnRule();
      expect(rule, findsOneWidget);
      expect(
        find.descendant(of: rule, matching: find.byType(AetherCard)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rule, matching: find.text('Deletion requested')),
        findsOneWidget,
      );

      // Countdown toward the server deadline plus the exact UTC timestamp.
      expect(find.textContaining('remaining'), findsOneWidget);
      expect(find.textContaining('Scheduled after'), findsOneWidget);

      // Pending swaps the danger request action for the ghost cancel action.
      expect(
        find.widgetWithText(AetherGhostButton, 'Cancel request'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherDangerButton, 'Delete your account'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'request flow: dialog danger button drives reauth then deletion request',
    (tester) async {
      final server = _FakeAccountServer(); // active
      final deadline = DateTime.now().toUtc().add(
        const Duration(hours: 23, minutes: 30),
      );
      var reauthCalls = 0;
      String? requestedId;
      await tester.pumpWidget(
        host(
          service: server.service,
          reauthenticate: (unused) async {
            reauthCalls++;
            expect(unused, isNull);
            return null;
          },
          requestDeletion: (id) async {
            requestedId = id;
            return AccountDeletion('pending', deadline, id);
          },
        ),
      );
      await tester.pumpAndSettle();

      // Not pending: danger request action present, no cancel ghost, no rule.
      expect(
        find.widgetWithText(AetherDangerButton, 'Delete your account'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherGhostButton, 'Cancel request'),
        findsNothing,
      );
      expect(warnRule(), findsNothing);

      await tester.tap(
        find.widgetWithText(AetherDangerButton, 'Delete your account'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete your account?'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(AetherDangerButton, 'Request deletion'),
      );
      await tester.pumpAndSettle();

      expect(reauthCalls, 1);
      expect(requestedId, isNotNull);
      expect(requestedId!.length, 48); // 24 random bytes, hex-encoded
      // Initial refresh only — the request response is rendered directly.
      expect(server.statusCalls, 1);

      // The returned pending status is rendered immediately: rule + countdown.
      expect(warnRule(), findsOneWidget);
      expect(find.text('Deletion requested'), findsOneWidget);
      expect(find.textContaining(deadline.toIso8601String()), findsOneWidget);
      expect(find.textContaining('remaining'), findsOneWidget);
      expect(
        find.widgetWithText(AetherGhostButton, 'Cancel request'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'cancel request: ghost re-checks status and surfaces cancelled state',
    (tester) async {
      final server = _FakeAccountServer()
        ..state = 'pending'
        ..deleteAfter = DateTime.now().add(const Duration(hours: 23, minutes: 30))
        ..requestId = 'req-pending';
      await tester.pumpWidget(
        host(
          service: server.service,
          reauthenticate: (_) async => null,
          requestDeletion: (_) async => throw StateError('must not request'),
        ),
      );
      await tester.pumpAndSettle();
      expect(server.statusCalls, 1);
      expect(find.text('Deletion requested'), findsOneWidget);

      // Server-side cancellation happens on next sign-in; the panel's cancel
      // action re-checks the status.
      server.state = 'cancelled';
      await tester.tap(find.widgetWithText(AetherGhostButton, 'Cancel request'));
      await tester.pumpAndSettle();

      expect(server.statusCalls, 2);
      expect(
        find.text('Your deletion request was cancelled.'),
        findsOneWidget,
      );
      expect(find.text('Deletion requested'), findsNothing);
      expect(warnRule(), findsNothing);
      expect(
        find.widgetWithText(AetherGhostButton, 'Cancel request'),
        findsNothing,
      );
      expect(
        find.widgetWithText(AetherDangerButton, 'Delete your account'),
        findsOneWidget,
      );
    },
  );
}
