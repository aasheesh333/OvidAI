import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/permissions_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Boots the permissions screen under a MaterialApp with the Aether theme so
/// that the premium reskin builds under the same conditions as production.
Widget _host() {
  return MaterialApp(
    theme: Aether.theme(),
    home: const PermissionsScreen(),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppState.I.globalPermissionGrants = [];
  });

  tearDown(() {
    AppState.I.globalPermissionGrants = [];
  });

  testWidgets(
    'renders Autonomy, Granted scopes, and Pending requests sections '
    'built from Aether primitives',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump();

      // All three eyebrow section titles present and uppercased by the
      // AetherSectionTitle primitive.
      expect(find.text('AUTONOMY'), findsOneWidget);
      expect(find.text('GRANTED SCOPES'), findsOneWidget);
      expect(find.text('PENDING REQUESTS'), findsOneWidget);

      // Each section is wrapped in an AetherCard (3 cards).
      expect(find.byType(AetherCard), findsNWidgets(3));

      // The autonomy scope remains explicit, including at large text sizes.
      expect(find.text('SESSION ONLY'), findsOneWidget);

      // There is no pending-request feed here: explain the real prompt
      // location without inventing a count or presenting fake controls.
      expect(find.text('Approval prompts appear in chat'), findsOneWidget);
      expect(find.text('No pending requests'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Allow'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Deny'), findsNothing);
      expect(find.widgetWithText(AetherGhostButton, 'Allow'), findsNothing);
      expect(find.widgetWithText(AetherGhostButton, 'Deny'), findsNothing);
    },
  );

  testWidgets(
    'legacy all-sessions grants from AppState surface in the Autonomy card',
    (tester) async {
      AppState.I.globalPermissionGrants = [
        PermissionGrant.path(
          '/data/legacy',
          global: true,
          recursive: true,
        ),
        PermissionGrant.host(
          'api.example.com',
          global: true,
        ),
      ];

      await tester.pumpWidget(_host());
      await tester.pump();

      // Legacy grant values must appear verbatim so the user can identify
      // what will be removed. Both path and host rows render in the
      // Autonomy card's legacy list.
      expect(find.text('path /data/legacy'), findsOneWidget);
      expect(find.text('host api.example.com'), findsOneWidget);

      // The legacy group label itself is rendered.
      expect(find.text('Legacy all-sessions grants'), findsOneWidget);
    },
  );

  testWidgets(
    'empty session grants render the "no decisions" affordance',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump();

      expect(
        find.textContaining(
          'No decisions for this session yet',
        ),
        findsOneWidget,
      );
    },
  );
}
