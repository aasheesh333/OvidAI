import 'package:flutter/foundation.dart';

import '../billing_products.dart';
import 'cloud_rest.dart';

const Set<String> _activePurchaseStates = {
  'active',
  'purchased',
  'restored',
  'subscription_state_active',
  'cancelled',
  'canceled',
  'subscription_state_canceled',
};

const Set<String> _knownPurchaseStates = {
  ..._activePurchaseStates,
  'pending',
  'inactive',
  'expired',
  'refunded',
  'revoked',
  'free',
  'none',
};

/// The account's server-confirmed store entitlement. Client/store callbacks
/// are never a substitute for this projection.
@immutable
class BillingEntitlement {
  const BillingEntitlement({
    required this.tier,
    required this.period,
    required this.productId,
    required this.purchaseState,
    required this.expiresAt,
    this.autoRenewing,
  });

  factory BillingEntitlement.fromJson(Map<String, dynamic> json) {
    final tier = _requiredText(_field(json, 'tier'), 'tier');
    final productId = _optionalText(
      _field(json, 'productId', snake: 'product_id'),
      'productId',
    );
    final periodValue = _field(json, 'period');
    final period = periodValue == null
        ? (productId == null ? null : _periodForProduct(productId))
        : _period(periodValue);
    final purchaseState = _requiredText(
      _field(json, 'purchaseState', snake: 'purchase_state'),
      'purchaseState',
    ).toLowerCase();
    final expiresValue = _field(json, 'expiresAt', snake: 'expires_at');
    final expiresAt = expiresValue == null ? null : _date(expiresValue);
    final renewal = _field(json, 'autoRenewing', snake: 'auto_renewing');
    if (renewal != null && renewal is! bool) {
      throw const FormatException('autoRenewing must be a boolean');
    }
    final entitlement = BillingEntitlement(
      tier: tier,
      period: period,
      productId: productId,
      purchaseState: purchaseState,
      expiresAt: expiresAt,
      autoRenewing: renewal as bool?,
    );
    if (!entitlement._validShape) {
      throw const FormatException('Malformed billing entitlement');
    }
    return entitlement;
  }

  final String tier;
  final OvidBillingPeriod? period;
  final String? productId;
  final String? purchaseState;
  final DateTime? expiresAt;
  final bool? autoRenewing;

  bool get isActive => isActiveAt(DateTime.now());

  bool get _validShape {
    final canonical = _canonicalTier(tier);
    if (canonical == null) return false;
    final product = productId;
    if (product != null &&
        _canonicalTier(ovidTierForProduct(product)) != canonical) {
      return false;
    }
    final billingPeriod = period;
    if (billingPeriod != null &&
        product != null &&
        _periodForProduct(product) != billingPeriod) {
      return false;
    }
    final state = purchaseState?.toLowerCase();
    if (!_knownPurchaseStates.contains(state)) return false;
    if (_activePurchaseStates.contains(state) && canonical != 'free') {
      // Paid access requires a canonical product and a real period end. An
      // active-null-expiry response is malformed authority, never a grant.
      if (product == null || expiresAt == null) return false;
    }
    return true;
  }

  bool isActiveAt(DateTime now) {
    if (!_validShape) return false;
    final canonical = _canonicalTier(tier);
    if (canonical == null || canonical == 'free') return false;
    if (!_activePurchaseStates.contains(purchaseState?.toLowerCase())) {
      return false;
    }
    final expiry = expiresAt;
    return expiry != null && expiry.isAfter(now);
  }
}

class EntitlementClient {
  EntitlementClient({CloudRestClient? rest})
    : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static EntitlementClient? _instance;
  static EntitlementClient get I => _instance ??= EntitlementClient();

  @visibleForTesting
  static void installForTest(EntitlementClient? client) => _instance = client;

  /// Always performs a fresh authenticated read. There is deliberately no
  /// cross-account cache to replay after a restore or account switch.
  Future<BillingEntitlement?> current() async {
    final json = await _rest.getJson('/billing/entitlement');
    final raw = json.containsKey('entitlement') ? json['entitlement'] : json;
    if (raw == null) return null;
    if (raw is! Map) {
      throw const FormatException('Entitlement response was not an object');
    }
    if (raw.isEmpty) return null;
    const fields = {
      'tier',
      'period',
      'productId',
      'product_id',
      'purchaseState',
      'purchase_state',
      'expiresAt',
      'expires_at',
      'autoRenewing',
      'auto_renewing',
    };
    if (!raw.keys.any(fields.contains)) {
      // A successful response for some other resource is malformed, not proof
      // that this account is Free. Never let it revoke a valid usage tier.
      throw const FormatException(
        'Entitlement response had no entitlement fields',
      );
    }
    return BillingEntitlement.fromJson(Map<String, dynamic>.from(raw));
  }
}

/// Google Play management is available only for an active server entitlement.
/// Unknown, expired and refunded accounts get no subscription deep link.
Uri? billingManagementUri(BillingEntitlement? entitlement, {DateTime? now}) {
  if (entitlement == null || !entitlement.isActiveAt(now ?? DateTime.now())) {
    return null;
  }
  final productId = entitlement.productId;
  return playSubscriptionCenterUri(
    productId:
        productId != null && kOvidPlayProductIds.values.contains(productId)
        ? productId
        : null,
  );
}

Object? _field(Map<dynamic, dynamic> json, String camel, {String? snake}) {
  if (json.containsKey(camel)) return json[camel];
  if (snake != null && json.containsKey(snake)) return json[snake];
  return null;
}

String _requiredText(Object? raw, String field) {
  final value = _optionalText(raw, field);
  if (value == null) throw FormatException('$field must be a non-empty string');
  return value;
}

String? _optionalText(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! String) throw FormatException('$field must be a string');
  final value = raw.trim();
  if (value.isEmpty) throw FormatException('$field must not be empty');
  return value;
}

DateTime _date(Object? raw) {
  if (raw is! String) {
    throw const FormatException('expiresAt must be an ISO timestamp');
  }
  final value = DateTime.tryParse(raw.trim());
  if (value == null) {
    throw const FormatException('expiresAt must be an ISO timestamp');
  }
  return value;
}

OvidBillingPeriod _period(Object? raw) => switch (raw) {
  'monthly' => OvidBillingPeriod.monthly,
  'yearly' => OvidBillingPeriod.yearly,
  _ => throw const FormatException('Unknown billing period'),
};

OvidBillingPeriod? _periodForProduct(String productId) {
  for (final entry in kOvidPlayProductIds.entries) {
    if (entry.value == productId) return entry.key.$2;
  }
  return null;
}

String? _canonicalTier(String? raw) {
  final tier = raw?.trim().toLowerCase();
  return switch (tier) {
    'free' => 'free',
    'go' || '3x' => '3x',
    'plus' || '7x' => '7x',
    'pro' || '15x' => '15x',
    _ => null,
  };
}
