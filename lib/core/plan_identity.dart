/// Single source of truth for Ovid Cloud plan identity.
///
/// Maps a server tier code (`free` / `3x` / `7x` / `15x`) to its display
/// name (FREE / PLUS / PRO / MAX), allowance multiplier (×1 / ×3 / ×7 / ×15),
/// and price in whole INR (0 / 499 / 899 / 1699). Prices are INR only — no
/// surface may ever derive or render a USD amount from this table.
///
/// The server stays authoritative for tier state and exact billing; this is
/// the client's one canonical read model for "what is this plan called and
/// what does it cost", replacing the per-screen tier→label copies that
/// previously lived in billing, usage, and account surfaces.
library;

/// One plan's identity. Immutable and comparable by [tier].
class PlanIdentity {
  const PlanIdentity._({
    required this.tier,
    required this.name,
    required this.title,
    required this.multiplier,
    required this.multiplierLabel,
    required this.priceInr,
    required this.priceLabel,
  });

  /// Server tier code: `free`, `3x`, `7x`, or `15x`.
  final String tier;

  /// Uppercase plan name for pills: FREE / PLUS / PRO / MAX.
  final String name;

  /// Title-case plan name for headings: Free / Plus / Pro / Max.
  final String title;

  /// Multiplier over the Free base usage allowance: 1 / 3 / 7 / 15.
  ///
  /// Matches the server contract mirrored by `ovidPlanMultipliers` in
  /// `ovid_cloud_service.dart`; the client only ever displays it, never
  /// applies it to a budget.
  final int multiplier;

  /// Display multiplier: ×1 / ×3 / ×7 / ×15.
  final String multiplierLabel;

  /// Price in whole INR: 0 / 499 / 899 / 1699.
  final int priceInr;

  /// Display price, INR only: `Free` / `₹499` / `₹899` / `₹1699`.
  final String priceLabel;

  static const free = PlanIdentity._(
    tier: 'free',
    name: 'FREE',
    title: 'Free',
    multiplier: 1,
    multiplierLabel: '×1',
    priceInr: 0,
    priceLabel: 'Free',
  );

  static const plus = PlanIdentity._(
    tier: '3x',
    name: 'PLUS',
    title: 'Plus',
    multiplier: 3,
    multiplierLabel: '×3',
    priceInr: 499,
    priceLabel: '₹499',
  );

  static const pro = PlanIdentity._(
    tier: '7x',
    name: 'PRO',
    title: 'Pro',
    multiplier: 7,
    multiplierLabel: '×7',
    priceInr: 899,
    priceLabel: '₹899',
  );

  static const max = PlanIdentity._(
    tier: '15x',
    name: 'MAX',
    title: 'Max',
    multiplier: 15,
    multiplierLabel: '×15',
    priceInr: 1699,
    priceLabel: '₹1699',
  );

  /// All plans in ascending allowance order.
  static const List<PlanIdentity> all = [free, plus, pro, max];

  /// Identity for a server [tier] code, or null when the tier is unknown.
  static PlanIdentity? forTier(String? tier) {
    for (final plan in all) {
      if (plan.tier == tier) return plan;
    }
    return null;
  }

  /// Rank of [tier] in [all], or -1 when unknown. Higher rank = more
  /// allowance; used to tell upgrades from plan changes.
  static int rankOf(String? tier) {
    for (var i = 0; i < all.length; i++) {
      if (all[i].tier == tier) return i;
    }
    return -1;
  }

  /// The next plan above [tier], or null when [tier] is unknown or already
  /// the top plan. Drives the single "next plan" call-to-action.
  static PlanIdentity? nextAfter(String? tier) {
    final rank = rankOf(tier);
    if (rank < 0 || rank >= all.length - 1) return null;
    return all[rank + 1];
  }

  /// Pill label summarising already-decided plan state.
  ///
  /// Honours [isPaid] so a paid flag is never invented from the tier alone:
  /// unpaid or Free accounts read FREE; unknown tiers read UNKNOWN rather
  /// than leaking a raw server code; the empty tier reads FREE.
  static String pillLabel(String tier, {required bool isPaid}) {
    final identity = forTier(tier);
    if (identity == null) return tier.isEmpty ? free.name : 'UNKNOWN';
    if (!isPaid || identity.tier == free.tier) return free.name;
    return identity.name;
  }
}
