import base64
import json
import unittest
from types import SimpleNamespace

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.billing.api import mount_billing, pubsub_push_verifier
from server.billing.domain import BillingError, evaluate, parse_time
from server.billing.play import PlayDeveloperApi
from server.billing.products import account_hash, load_products
from server.billing.store import PurchaseStore, RedisTierSink

NOW = 1_800_000_000  # 2027-01-15
PRODUCTS = {'ovid_plus_monthly': '3x', 'ovid_pro_monthly': '7x', 'ovid_max_monthly': '15x'}


def iso(epoch):
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace('+00:00', 'Z')


def subscription(product='ovid_plus_monthly', state='SUBSCRIPTION_STATE_ACTIVE', expiry=NOW + 30 * 86400,
                 uid='u1', auto=True, linked=None, ack=False):
    resource = {
        'kind': 'androidpublisher#subscriptionPurchaseV2',
        'subscriptionState': state,
        'acknowledgementState': 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED' if ack else 'ACKNOWLEDGEMENT_STATE_PENDING',
        'lineItems': [{'productId': product, 'expiryTime': iso(expiry),
                       'autoRenewingPlan': {'autoRenewEnabled': auto}}],
    }
    if uid is not None:
        resource['externalAccountIdentifiers'] = {'obfuscatedExternalAccountId': account_hash(uid)}
    if linked:
        resource['linkedPurchaseToken'] = linked
    return resource


class FakePlay:
    """Stands in for PlayDeveloperApi; tokens map to SubscriptionPurchaseV2 dicts."""

    def __init__(self):
        self.tokens = {}
        self.calls = []
        self.fail = None

    def get_subscription(self, token):
        self.calls.append(token)
        if self.fail:
            raise self.fail
        if token not in self.tokens:
            raise BillingError(400, 'purchase_invalid')
        return self.tokens[token]


class FakeRedis:
    def __init__(self):
        self.values = {}
        self.expiry = {}

    def set(self, key, value, exat=None):
        self.values[key] = str(value)
        self.expiry[key] = exat

    def delete(self, *keys):
        for key in keys:
            self.values.pop(key, None)

    def get(self, key):
        return self.values.get(key)


def mint_fixture(rds):
    users = {'token-u1': 'u1', 'token-u2': 'u2'}

    def verify_id(token):
        if token not in users:
            raise ValueError('bad token')
        return {'sub': users[token]}

    def verify_app_check(token):
        if token != 'attest':
            raise ValueError('bad attestation')

    return SimpleNamespace(APPCHECK_ENABLED=True, rds=rds, verify_google_id_token=verify_id,
                           verify_app_check=verify_app_check, is_banned=lambda uid, ip: False)


def headers(user='u1'):
    return {'Authorization': f'Bearer token-{user}', 'X-Firebase-AppCheck': 'attest'}


def push(payload):
    return {'message': {'data': base64.b64encode(json.dumps(payload).encode()).decode(),
                        'messageId': '1'}, 'subscription': 'projects/p/subscriptions/s'}


class DomainTest(unittest.TestCase):
    def test_active_grace_and_canceled_until_expiry_grant(self):
        for state in ('SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
                      'SUBSCRIPTION_STATE_CANCELED'):
            with self.subTest(state=state):
                ent = evaluate(subscription(state=state), PRODUCTS, NOW)
                self.assertEqual((ent.status, ent.tier), ('active', '3x'))
        self.assertFalse(evaluate(subscription(state='SUBSCRIPTION_STATE_CANCELED'), PRODUCTS, NOW).auto_renewing)

    def test_pending_on_hold_paused_expired_do_not_grant(self):
        cases = {'SUBSCRIPTION_STATE_PENDING': 'pending', 'SUBSCRIPTION_STATE_ON_HOLD': 'expired',
                 'SUBSCRIPTION_STATE_PAUSED': 'expired', 'SUBSCRIPTION_STATE_EXPIRED': 'expired',
                 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED': 'expired'}
        for state, status in cases.items():
            with self.subTest(state=state):
                ent = evaluate(subscription(state=state), PRODUCTS, NOW)
                self.assertEqual((ent.status, ent.tier), (status, 'free'))
        past = evaluate(subscription(expiry=NOW - 1), PRODUCTS, NOW)
        self.assertEqual(past.tier, 'free')

    def test_unknown_product_never_grants(self):
        with self.assertRaises(BillingError) as raised:
            evaluate(subscription(product='other'), PRODUCTS, NOW)
        self.assertEqual(raised.exception.code, 'unknown_product')

    def test_nanosecond_timestamps_parse(self):
        self.assertEqual(parse_time('2027-01-15T08:00:00.123456789Z'),
                         parse_time('2027-01-15T08:00:00.123456Z'))

    def test_product_override_validation(self):
        self.assertEqual(load_products({'OVID_PLAY_PRODUCTS': '{"a": "7x"}'}), {'a': '7x'})
        for raw in ('{"a": "free"}', '{"a": "99x"}', '[]', '{}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                load_products({'OVID_PLAY_PRODUCTS': raw})


class PlayApiTest(unittest.TestCase):
    def client(self, handler):
        return httpx.Client(transport=httpx.MockTransport(handler), base_url='https://play.test')

    def test_get_uses_subscriptionsv2_with_bearer(self):
        seen = []

        def handler(request):
            seen.append(request)
            return httpx.Response(200, json=subscription())
        api = PlayDeveloperApi('com.dhanuk.ovidai', lambda: 'sa-token', self.client(handler))
        self.assertEqual(api.get_subscription('tok/1')['subscriptionState'], 'SUBSCRIPTION_STATE_ACTIVE')
        self.assertEqual(seen[0].url.raw_path, b'/androidpublisher/v3/applications/com.dhanuk.ovidai'
                                               b'/purchases/subscriptionsv2/tokens/tok%2F1')
        self.assertEqual(seen[0].headers['authorization'], 'Bearer sa-token')

    def test_invalid_token_and_transient_errors(self):
        api = PlayDeveloperApi('p', lambda: 't', self.client(lambda r: httpx.Response(404)))
        with self.assertRaises(BillingError) as raised:
            api.get_subscription('x')
        self.assertEqual((raised.exception.status, raised.exception.code), (400, 'purchase_invalid'))
        calls = []

        def flaky(request):
            calls.append(1)
            return httpx.Response(500)
        api = PlayDeveloperApi('p', lambda: 't', self.client(flaky), retries=1)
        with self.assertRaises(BillingError) as raised:
            api.get_subscription('x')
        self.assertEqual(raised.exception.code, 'play_unavailable')
        self.assertEqual(len(calls), 2)


class BillingApiTest(unittest.TestCase):
    def setUp(self):
        self.play = FakePlay()
        self.rds = FakeRedis()
        self.store = PurchaseStore(':memory:')
        self.now = NOW
        self.app = FastAPI()
        self.mint = mint_fixture(self.rds)
        self.service = mount_billing(
            self.mint, self.app, environ={'OVID_RTDN_SHARED_SECRET': 'push-secret'},
            api=self.play, store=self.store, clock=lambda: self.now)
        self.client = TestClient(self.app)

    def verify(self, token='tok-1', product='ovid_plus_monthly', user='u1'):
        return self.client.post('/billing/verify', headers=headers(user),
                                json={'purchase_token': token, 'product_id': product,
                                      'package_name': 'com.dhanuk.ovidai'})

    def rtdn(self, payload, secret='push-secret'):
        return self.client.post(f'/billing/rtdn?secret={secret}', json=push(payload))

    def test_verified_purchase_sets_tier_and_asks_client_to_acknowledge(self):
        self.play.tokens['tok-1'] = subscription()
        response = self.verify()
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.assertEqual((body['ok'], body['status'], body['tier'], body['acknowledge']),
                         (True, 'active', '3x', True))
        self.assertTrue(body['auto_renewing'])
        self.assertEqual(self.rds.get('user:u1:tier'), '3x')
        self.assertEqual(self.rds.expiry['user:u1:tier'], NOW + 30 * 86400 + RedisTierSink.SKEW_SECONDS)
        self.assertEqual(self.rds.get('user:u1:tier_expires_at'), str(NOW + 30 * 86400))

    def test_verify_is_idempotent_per_token(self):
        self.play.tokens['tok-1'] = subscription()
        first = self.verify().json()
        second = self.verify().json()
        self.assertEqual(first, second)
        self.assertEqual(self.rds.get('user:u1:tier'), '3x')

    def test_unverified_or_foreign_purchases_never_set_a_tier(self):
        # Unknown to Google.
        response = self.verify(token='forged')
        self.assertEqual((response.status_code, response.json()['error']['code']), (400, 'purchase_invalid'))
        # Bought by another account (obfuscated account id mismatch).
        self.play.tokens['tok-2'] = subscription(uid='u2')
        response = self.verify(token='tok-2')
        self.assertEqual((response.status_code, response.json()['error']['code']), (403, 'account_mismatch'))
        # No account id at all.
        self.play.tokens['tok-3'] = subscription(uid=None)
        self.assertEqual(self.verify(token='tok-3').status_code, 403)
        # Product the server does not sell.
        self.assertEqual(self.verify(product='other').json()['error']['code'], 'unknown_product')
        # Google unreachable: 503, no grant, client must not acknowledge.
        self.play.tokens['tok-4'] = subscription()
        self.play.fail = BillingError(503, 'play_unavailable')
        self.assertEqual(self.verify(token='tok-4').status_code, 503)
        self.assertNotIn('user:u1:tier', self.rds.values)

    def test_token_cannot_be_replayed_from_another_account(self):
        self.play.tokens['tok-1'] = subscription()
        self.assertEqual(self.verify().status_code, 200)
        response = self.verify(user='u2')
        self.assertEqual((response.status_code, response.json()['error']['code']),
                         (409, 'purchase_owned_by_another_account'))
        self.assertNotIn('user:u2:tier', self.rds.values)

    def test_pending_purchase_is_not_acknowledged_or_granted(self):
        self.play.tokens['tok-1'] = subscription(state='SUBSCRIPTION_STATE_PENDING')
        response = self.verify()
        self.assertEqual(response.status_code, 202)
        self.assertEqual((response.json()['status'], response.json()['acknowledge']), ('pending', False))
        self.assertNotIn('user:u1:tier', self.rds.values)

    def test_auth_is_required(self):
        response = self.client.post('/billing/verify', json={'purchase_token': 't', 'product_id': 'ovid_plus_monthly'})
        self.assertEqual(response.status_code, 401)
        response = self.client.post('/billing/verify', headers={'Authorization': 'Bearer token-u1'},
                                    json={'purchase_token': 't', 'product_id': 'ovid_plus_monthly'})
        self.assertEqual(response.status_code, 401)

    def test_unconfigured_service_is_closed(self):
        app = FastAPI()
        service = mount_billing(self.mint, app, environ={})
        self.assertFalse(service.configured)
        self.assertFalse(service.usage_fields('u1')['billing_enabled'])
        response = TestClient(app).post('/billing/verify', headers=headers(),
                                        json={'purchase_token': 't', 'product_id': 'ovid_plus_monthly'})
        self.assertEqual((response.status_code, response.json()['error']['code']), (503, 'billing_unavailable'))

    def test_usage_fields_expose_renewal_and_features(self):
        self.play.tokens['tok-1'] = subscription()
        self.verify()
        fields = self.service.usage_fields('u1')
        self.assertTrue(fields['billing_enabled'])
        self.assertEqual(fields['plan_expires_at'], iso(NOW + 30 * 86400))
        self.assertTrue(fields['plan_auto_renews'])
        self.assertEqual([p['tier'] for p in fields['plans']], ['free', '3x', '7x', '15x'])
        self.assertEqual(fields['plans'][1]['product_id'], 'ovid_plus_monthly')
        self.assertTrue(all(p['features'] for p in fields['plans']))

    # ---- RTDN ---------------------------------------------------------------
    def test_rtdn_requires_push_auth(self):
        self.assertEqual(self.rtdn({}, secret='wrong').status_code, 403)
        closed = pubsub_push_verifier({})
        self.assertFalse(closed({}, {'secret': ''}))

    def test_rtdn_renew_cancel_expire_cycle(self):
        self.play.tokens['tok-1'] = subscription()
        self.verify()
        # Renewal extends the expiry.
        self.play.tokens['tok-1'] = subscription(expiry=NOW + 60 * 86400)
        note = {'packageName': 'com.dhanuk.ovidai',
                'subscriptionNotification': {'notificationType': 2, 'purchaseToken': 'tok-1'}}
        self.assertEqual(self.rtdn(note).status_code, 204)
        self.assertEqual(self.rds.get('user:u1:tier_expires_at'), str(NOW + 60 * 86400))
        # User cancels: keeps access, auto-renew off.
        self.play.tokens['tok-1'] = subscription(state='SUBSCRIPTION_STATE_CANCELED', expiry=NOW + 60 * 86400)
        note['subscriptionNotification']['notificationType'] = 3
        self.rtdn(note)
        self.assertEqual(self.rds.get('user:u1:tier'), '3x')
        self.assertFalse(self.service.usage_fields('u1')['plan_auto_renews'])
        # Expiry: tier removed.
        self.now = NOW + 61 * 86400
        self.play.tokens['tok-1'] = subscription(state='SUBSCRIPTION_STATE_EXPIRED', expiry=NOW + 60 * 86400)
        note['subscriptionNotification']['notificationType'] = 13
        self.rtdn(note)
        self.assertNotIn('user:u1:tier', self.rds.values)

    def test_rtdn_upgrade_replaces_linked_token(self):
        self.play.tokens['tok-1'] = subscription()
        self.verify()
        self.play.tokens['tok-2'] = subscription(product='ovid_max_monthly', linked='tok-1')
        self.assertEqual(self.verify(token='tok-2', product='ovid_max_monthly').json()['tier'], '15x')
        self.assertEqual(self.store.get('tok-1')['status'], 'replaced')
        # A late RTDN for the old token cannot resurrect it.
        self.rtdn({'subscriptionNotification': {'notificationType': 2, 'purchaseToken': 'tok-1'}})
        self.assertEqual(self.store.get('tok-1')['status'], 'replaced')
        self.assertEqual(self.rds.get('user:u1:tier'), '15x')

    def test_rtdn_revoke_and_voided_refund_remove_tier(self):
        self.play.tokens['tok-1'] = subscription()
        self.verify()
        self.rtdn({'voidedPurchaseNotification': {'purchaseToken': 'tok-1', 'productType': 1}})
        self.assertNotIn('user:u1:tier', self.rds.values)
        self.assertEqual(self.store.get('tok-1')['status'], 'revoked')
        # Sticky: a re-verify cannot re-grant a refunded token.
        self.assertFalse(self.verify().json()['ok'])
        self.assertNotIn('user:u1:tier', self.rds.values)

    def test_rtdn_for_unbound_token_is_stored_and_bound_on_verify(self):
        self.play.tokens['tok-9'] = subscription()
        self.rtdn({'subscriptionNotification': {'notificationType': 4, 'purchaseToken': 'tok-9'}})
        self.assertIsNone(self.store.get('tok-9')['uid'])
        self.assertNotIn('user:u1:tier', self.rds.values)
        self.assertEqual(self.verify(token='tok-9').json()['tier'], '3x')
        self.assertEqual(self.store.get('tok-9')['uid'], 'u1')

    def test_rtdn_transient_play_error_asks_pubsub_to_retry(self):
        self.play.fail = BillingError(503, 'play_unavailable')
        response = self.rtdn({'subscriptionNotification': {'notificationType': 2, 'purchaseToken': 'tok-1'}})
        self.assertEqual(response.status_code, 503)

    def test_rtdn_malformed_and_test_notifications_are_acknowledged(self):
        self.assertEqual(self.client.post('/billing/rtdn?secret=push-secret',
                                          json={'message': {'data': '!!'}}).status_code, 204)
        self.assertEqual(self.rtdn({'testNotification': {'version': '1.0'}}).status_code, 204)
        self.assertEqual(self.rtdn({'packageName': 'other.app',
                                    'subscriptionNotification': {'purchaseToken': 'x'}}).status_code, 204)
        self.assertEqual(self.play.calls, [])


if __name__ == '__main__':
    unittest.main()
