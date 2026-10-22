/// The Play product catalogue, with no plugin or Firebase dependency.
///
/// The plan screen only needs the product ids, but importing
/// `core/play_billing.dart` for them pulled in `in_app_purchase` and
/// `core/ovid_cloud_service.dart` → Firebase → sqlite3 → `dart:ffi`, which
/// cannot compile for the web gallery. Keeping the catalogue pure lets the UI
/// read it and the service import both.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The billing period a plan is sold for.
///
/// Monthly is the default everywhere: an existing caller that passes no period
/// keeps buying the monthly product.
enum OvidBillingPeriod { monthly, yearly }

/// PRODUCT DECISION PLACEHOLDERS: Play Console subscription product IDs per
/// Ovid Cloud tier and billing period. The monthly ids must match
/// `server/billing/products.py` (or the server's `OVID_PLAY_PRODUCTS`).
///
/// A yearly request must resolve its own product: falling back to the monthly
/// product would charge the wrong period at the wrong price.
const Map<(String, OvidBillingPeriod), String> kOvidPlayProductIds = {
  ('3x', OvidBillingPeriod.monthly): 'ovid_plus_monthly',
  ('3x', OvidBillingPeriod.yearly): 'ovid_plus_yearly',
  ('7x', OvidBillingPeriod.monthly): 'ovid_pro_monthly',
  ('7x', OvidBillingPeriod.yearly): 'ovid_pro_yearly',
  ('15x', OvidBillingPeriod.monthly): 'ovid_max_monthly',
  ('15x', OvidBillingPeriod.yearly): 'ovid_max_yearly',
};

/// Monthly product per tier. Kept for callers that only need the default
/// period (the subscription centre, the legacy billing screen); it is derived
/// from [kOvidPlayProductIds] so the two can never drift.
final Map<String, String> kOvidPlayProducts = {
  for (final entry in kOvidPlayProductIds.entries)
    if (entry.key.$2 == OvidBillingPeriod.monthly) entry.key.$1: entry.value,
};

/// The Play product for [tier] and [period], or null when that combination is
/// not configured. Callers must never substitute another period's product.
String? ovidPlayProductId(
  String tier, [
  OvidBillingPeriod period = OvidBillingPeriod.monthly,
]) => kOvidPlayProductIds[(tier, period)];

/// Android application ID (also the server's `OVID_PLAY_PACKAGE`).
const String kOvidPlayPackage = 'com.dhanuk.ovidai';

/// Play `obfuscatedAccountId` for [uid]: hex SHA-256 of `ovid:<uid>`. The
/// server requires it to match the signed-in Firebase UID, so a purchase token
/// cannot be redeemed by another account. Mirrors `account_hash` on the server.
String ovidPlayAccountId(String uid) =>
    sha256.convert(utf8.encode('ovid:$uid')).toString();

/// Play subscription centre (cancel, downgrade, update payment). With a
/// product ID it opens that subscription directly.
Uri playSubscriptionCenterUri({String? productId}) => Uri.https(
  'play.google.com',
  '/store/account/subscriptions',
  productId == null ? null : {'sku': productId, 'package': kOvidPlayPackage},
);

/// Tier for a Play product ID, or null when it is not an Ovid plan.
String? ovidTierForProduct(String productId) {
  for (final entry in kOvidPlayProductIds.entries) {
    if (entry.value == productId) return entry.key.$1;
  }
  return null;
}
