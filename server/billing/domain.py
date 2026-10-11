"""Pure evaluation of a Play ``SubscriptionPurchaseV2`` into an entitlement.

Reference: androidpublisher v3 ``purchases.subscriptionsv2.get``.
No I/O here so every state transition is unit-testable.
"""
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .products import TIER_RANK

# States in which the user keeps access until ``expiryTime``. CANCELED means
# auto-renew was turned off; access continues to the end of the paid period.
ENTITLED_STATES = frozenset({
    'SUBSCRIPTION_STATE_ACTIVE',
    'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
    'SUBSCRIPTION_STATE_CANCELED',
})
PENDING_STATES = frozenset({'SUBSCRIPTION_STATE_PENDING'})


class BillingError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status
        self.code = code


@dataclass(frozen=True)
class Entitlement:
    """What one purchase token currently grants."""
    status: str  # active | pending | expired | revoked | replaced
    tier: str  # tier granted by this token right now ('free' unless active)
    product_id: str
    expires_at: int | None  # epoch seconds
    auto_renewing: bool
    linked_token: str | None = None
    account_hash: str | None = None
    acknowledged: bool = False
    test_purchase: bool = False
    state: str = ''
    extra: dict = field(default_factory=dict)

    @property
    def active(self):
        return self.status == 'active'


def parse_time(value):
    if not value:
        return None
    text = value.replace('Z', '+00:00')
    # Play may send nanosecond precision; Python accepts at most microseconds.
    if '.' in text:
        head, rest = text.split('.', 1)
        digits = ''.join(ch for ch in rest if ch.isdigit())
        suffix = rest[len(digits):]
        text = f'{head}.{digits[:6]}{suffix}'
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def evaluate(resource, products, now):
    """Map a SubscriptionPurchaseV2 resource to an :class:`Entitlement`.

    ``products`` maps product IDs to tiers; unknown products never grant a tier.
    ``now`` is epoch seconds.
    """
    if not isinstance(resource, dict):
        raise BillingError(502, 'play_invalid_response')
    state = resource.get('subscriptionState') or 'SUBSCRIPTION_STATE_UNSPECIFIED'
    items = []
    for item in resource.get('lineItems') or []:
        if not isinstance(item, dict):
            continue
        product = item.get('productId')
        if product not in products:
            continue
        try:
            expiry = parse_time(item.get('expiryTime'))
        except ValueError:
            expiry = None
        auto = bool((item.get('autoRenewingPlan') or {}).get('autoRenewEnabled'))
        items.append((product, expiry, auto))
    if not items:
        raise BillingError(400, 'unknown_product')
    # Highest tier first, then the latest expiry (an upgrade line wins).
    items.sort(key=lambda row: (TIER_RANK[products[row[0]]], row[1] or 0), reverse=True)
    product, expiry, auto = items[0]
    ids = resource.get('externalAccountIdentifiers') or {}
    common = dict(
        product_id=product,
        expires_at=expiry,
        auto_renewing=auto and state != 'SUBSCRIPTION_STATE_CANCELED',
        linked_token=resource.get('linkedPurchaseToken') or None,
        account_hash=ids.get('obfuscatedExternalAccountId') or None,
        acknowledged=resource.get('acknowledgementState') == 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
        test_purchase='testPurchase' in resource,
        state=state,
    )
    if state in PENDING_STATES:
        return Entitlement(status='pending', tier='free', **common)
    if state in ENTITLED_STATES and expiry is not None and expiry > now:
        return Entitlement(status='active', tier=products[product], **common)
    return Entitlement(status='expired', tier='free', **common)
