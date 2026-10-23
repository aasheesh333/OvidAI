// The plan multipliers the product sells.
//
// Spec §4 (authoritative): Auto Mode allowance is
//   Free 1x · Ovid Go 1.5x · Ovid Plus 5x · Ovid Pro 20x
//
// The code carried 3 / 23 / 43 from an earlier cost model. Those numbers are
// what the pools hook actually multiplies the Free daily allowance by, so a
// drift here is a direct revenue and promise mismatch — this test pins the
// spec's values in every place the number lives.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/ui/v2/settings/plan_compare_table.dart';

void main() {
  test('the runtime multiplier map matches the spec', () {
    expect(ovidPlanMultipliers['free'], 1);
    expect(ovidPlanMultipliers['3x'], 1.5);
    expect(ovidPlanMultipliers['7x'], 5);
    expect(ovidPlanMultipliers['15x'], 20);
  });

  test('the fallback plan catalogue matches the spec', () {
    final byTier = {
      for (final plan in OvidPlanCatalog.fallback) plan.tier: plan,
    };
    expect(byTier['free']!.mult, 1);
    expect(byTier['3x']!.mult, 1.5);
    expect(byTier['7x']!.mult, 5);
    expect(byTier['15x']!.mult, 20);
  });

  test('the plans screen shows the spec multipliers', () {
    final byId = {
      for (final plan in V2PlanComparePlan.canonical) plan.id: plan,
    };
    expect(byId['free']!.autoMultiplier, 1);
    expect(byId['go']!.autoMultiplier, 1.5);
    expect(byId['plus']!.autoMultiplier, 5);
    expect(byId['pro']!.autoMultiplier, 20);
  });

  test('the displayed labels read as the spec states them', () {
    final byId = {
      for (final plan in V2PlanComparePlan.canonical) plan.id: plan,
    };
    expect(byId['go']!.autoMultiplierLabel, '1.5×');
    expect(byId['plus']!.autoMultiplierLabel, '5×');
    expect(byId['pro']!.autoMultiplierLabel, '20×');
  });
}
