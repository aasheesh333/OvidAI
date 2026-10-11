"""Product catalogue: Play subscription product IDs -> Ovid Cloud tiers.

PRODUCT DECISION PLACEHOLDERS. The product IDs below must match the
subscriptions created in Play Console (Monetize -> Subscriptions) and the
client constants in ``lib/core/play_billing.dart`` (``kOvidPlayProducts``).
Override without a code change with ``OVID_PLAY_PRODUCTS`` (JSON object
``{"product_id": "tier"}``).
"""
import hashlib
import json
import os

TIERS = ('free', '3x', '7x', '15x')
TIER_RANK = {tier: rank for rank, tier in enumerate(TIERS)}

DEFAULT_PRODUCTS = {
    'ovid_plus_monthly': '3x',
    'ovid_pro_monthly': '7x',
    'ovid_max_monthly': '15x',
}

# Shown on the Plans screen (F-200). Approximate, server-owned copy so client
# copy never drifts from limits. PLACEHOLDER numbers: confirm with pricing.
DEFAULT_PLAN_FEATURES = {
    'free': ['All Ovid Cloud chat models', 'About 30 messages a day',
             'Image generation within the daily allowance'],
    '3x': ['All Ovid Cloud chat models', 'About 3x the Free allowance, pooled over 30 days',
           'Image generation from the same allowance'],
    '7x': ['All Ovid Cloud chat models', 'About 7x the Free allowance, pooled over 30 days',
           'Image generation from the same allowance', 'Priority during busy periods'],
    '15x': ['All Ovid Cloud chat models', 'About 15x the Free allowance, pooled over 30 days',
            'Image generation from the same allowance', 'Priority during busy periods'],
}


def load_products(environ=None):
    environ = os.environ if environ is None else environ
    raw = environ.get('OVID_PLAY_PRODUCTS')
    if not raw:
        return dict(DEFAULT_PRODUCTS)
    parsed = json.loads(raw)
    if not isinstance(parsed, dict) or not parsed:
        raise ValueError('OVID_PLAY_PRODUCTS must be a non-empty JSON object')
    for product, tier in parsed.items():
        if not isinstance(product, str) or tier not in TIERS or tier == 'free':
            raise ValueError(f'invalid product mapping {product!r} -> {tier!r}')
    return dict(parsed)


def account_hash(uid):
    """Value the client passes as Play ``obfuscatedAccountId``.

    Must match ``ovidPlayAccountId`` in ``lib/core/play_billing.dart``: lower-case
    hex SHA-256 of ``"ovid:" + uid`` (64 chars, Play's limit). It binds a
    purchase token to the Firebase account that started the purchase.
    """
    return hashlib.sha256(f'ovid:{uid}'.encode('utf-8')).hexdigest()


def higher(a, b):
    return a if TIER_RANK.get(a, 0) >= TIER_RANK.get(b, 0) else b
