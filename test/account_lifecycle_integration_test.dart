import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/reset_coordinator.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account switch fences, revokes, then binds without execution hydration',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('account-lifecycle-');
      SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
      final calls = <String>[];
      final app = AppState.createForTest(
        accountLifecycle: AccountLifecycleIntegration(
          onFence: () => calls.add('fence'),
          onRevoke: () async => calls.add('revoke'),
          onBind: (account, _) async => calls.add('bind:$account'),
          onClear: () async => calls.add('clear'),
          onVerifyEmpty: () async => true,
        ),
      );

      await app.transitionSessionAccount('firebase:b');

      expect(calls, ['fence', 'revoke', 'bind:firebase:b']);
      expect(calls, isNot(contains('hydrate')));
      await SessionSearch.I.close();
      SessionSearch.dbPathOverrideForTest = null;
      AppState.resetTestInstance();
      await root.delete(recursive: true);
    },
  );

  test(
    'production lifecycle composition is inert without account configuration',
    () {
      final integration = AppState.productionAccountLifecycleForTest(
        accountAvailable: false,
      );
      expect(() => integration.fenceSynchronously(), returnsNormally);
      expect(integration.onVerifyEmpty(), completion(isTrue));
    },
  );
}
