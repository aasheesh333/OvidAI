import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/ui/private_sync_settings_screen.dart';
import 'private_sync_review_composition_test.dart' show Harness;

void main() {
  testWidgets(
    'production settings verifies before revoke and offline local disable remains usable',
    (tester) async {
      late Directory root;
      late Harness harness;
      late PrivateSyncProduction owner;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('sync-revoke-ui-');
        harness = Harness(root)..failRevoke = true;
        owner = harness.owner();
        await owner.bind('alice', 1);
        await owner.enroll();
      });
      var verified = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PrivateSyncSettingsScreen(
            controller: owner,
            reauthenticate: () async {
              verified++;
              return true;
            },
          ),
        ),
      );
      final revoke = find.text('Verify identity and revoke device');
      await tester.ensureVisible(revoke);
      await tester.runAsync(() async {
        await tester.tap(revoke);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // Wait for actual file persistence and HTTP failure, not a fake controller.
      await tester.runAsync(() async {
        await owner.refresh();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(verified, 1);
      expect(harness.deletes, 1);
      expect(owner.enrolled, true);
      final disable = find.text('Disable sync on this device');
      await tester.ensureVisible(disable);
      await tester.runAsync(() async {
        await tester.tap(disable);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(owner.enrolled, false);
      expect(harness.deletes, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await owner.release();
        await root.delete(recursive: true);
      });
    },
  );
}
