// The manual-model gate: the server's answer wins, and an older gateway that
// does not send it falls back to the same plan table the server uses.
//
// The table here mirrors cloud/packages/shared/src/plans.ts (`planFor` /
// `manualModelsAllowed`). If this test and that file disagree, the client is
// offering a model the send route refuses with a 402.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/model_access.dart';
import 'package:ovid_ai/core/cloud/plan_tier.dart';

void main() {
  group('the local table resolves every spelling the server does', () {
    const cases = <(String?, OvidPlanId, bool)>[
      (null, OvidPlanId.free, false),
      ('', OvidPlanId.free, false),
      ('   ', OvidPlanId.free, false),
      ('free', OvidPlanId.free, false),
      // Canonical ids (the new users.tier values).
      ('go', OvidPlanId.go, false),
      ('plus', OvidPlanId.plus, true),
      ('pro', OvidPlanId.pro, true),
      // Legacy spellings that real rows still hold.
      ('3x', OvidPlanId.go, false),
      ('starter', OvidPlanId.go, false),
      ('7x', OvidPlanId.plus, true),
      ('15x', OvidPlanId.pro, true),
      ('max', OvidPlanId.pro, true),
      // Case and surrounding whitespace are not a different plan.
      ('  PLUS ', OvidPlanId.plus, true),
      (' Starter ', OvidPlanId.go, false),
      // Unknown is Free: the least privilege, exactly like the server.
      ('enterprise', OvidPlanId.free, false),
    ];

    for (final (tier, id, manual) in cases) {
      test('${tier ?? 'null'} -> ${id.name}, manual=$manual', () {
        expect(ovidPlanIdFor(tier), id);
        expect(ovidManualModelsAllowedForTier(tier), manual);
      });
    }
  });

  group('the server field wins when present', () {
    test('a server yes overrides a locally Auto-only tier', () {
      expect(ovidManualModelsAllowed(serverValue: true, tier: 'free'), isTrue);
      expect(
        ovidManualModelsAllowed(serverValue: true, tier: 'starter'),
        isTrue,
      );
    });

    test('a server no overrides a locally manual tier', () {
      expect(
        ovidManualModelsAllowed(serverValue: false, tier: 'plus'),
        isFalse,
      );
      expect(ovidManualModelsAllowed(serverValue: false, tier: '15x'), isFalse);
    });

    test('a missing field falls back to the local resolution', () {
      // The legacy fallback path: an older gateway sends no flag.
      expect(
        ovidManualModelsAllowed(serverValue: null, tier: 'starter'),
        isFalse,
      );
      expect(ovidManualModelsAllowed(serverValue: null, tier: 'go'), isFalse);
      expect(ovidManualModelsAllowed(serverValue: null, tier: 'plus'), isTrue);
      expect(ovidManualModelsAllowed(serverValue: null, tier: '7x'), isTrue);
      expect(ovidManualModelsAllowed(serverValue: null, tier: 'max'), isTrue);
      expect(ovidManualModelsAllowed(serverValue: null, tier: null), isFalse);
    });
  });

  group('GET /models parsing', () {
    test('a modern gateway carries the boolean', () {
      final access = CloudModelAccess.fromJson(const {
        'auto': 'auto',
        'models': ['auto', 'ovid-pro'],
        'tier': 'plus',
        'manualModelsAllowed': true,
        'known': true,
      });
      expect(access.manualModelsAllowed, isTrue);
      expect(access.tier, 'plus');
      expect(access.known, isTrue);
      expect(access.models, ['auto', 'ovid-pro']);
    });

    test('an older gateway has no field, so the fallback must decide', () {
      final access = CloudModelAccess.fromJson(const {
        'auto': 'auto',
        'models': ['auto'],
        'tier': 'starter',
        'known': true,
      });
      expect(access.manualModelsAllowed, isNull);
      expect(access.tier, 'starter');
    });

    test('a malformed field is treated as absent, not as false', () {
      final access = CloudModelAccess.fromJson(const {
        'tier': 'plus',
        'manualModelsAllowed': 'yes',
      });
      expect(access.manualModelsAllowed, isNull);
      expect(access.tier, 'plus');
    });
  });
}
