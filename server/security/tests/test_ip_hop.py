import json
import unittest
from contextlib import contextmanager

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.account.api import router
from server.account.domain import AccountError, Lifecycle
from server.security.ip_hop import (
    GeoInfo,
    IpHopBlocked,
    IpHopGuard,
    IpHopUnavailable,
    SqliteIpHopStore,
    StaticGeoResolver,
    coarse_prefix,
    session_from_token,
)

LONDON = GeoInfo(country='GB', asn='AS1', city='London',
                 latitude=51.5074, longitude=-0.1278)
PARIS = GeoInfo(country='FR', asn='AS1', city='Paris',
                latitude=48.8566, longitude=2.3522)
NEW_YORK = GeoInfo(country='US', asn='AS2', city='New York',
                   latitude=40.7128, longitude=-74.0060)
TOKYO = GeoInfo(country='JP', asn='AS3', city='Tokyo',
                latitude=35.6762, longitude=139.6503)
BERLIN = GeoInfo(country='DE', asn='AS9', city='Berlin',
                 latitude=52.5200, longitude=13.4050)


class MemoryStore:
    @contextmanager
    def locked(self, uid):
        yield self

    def get(self, uid):
        return None


class Admin:
    def user(self, uid):
        return None


class Data:
    pass


class IpHopTests(unittest.TestCase):
    def setUp(self):
        self.store = SqliteIpHopStore()
        self.emails = []
        self.guard = IpHopGuard(
            self.store,
            resolver=StaticGeoResolver({
                '1.2.3.4': LONDON,
                '1.2.4.5': PARIS,
                '5.6.7.8': NEW_YORK,
                '9.9.9.9': TOKYO,
                '10.0.0.1': BERLIN,
            }),
            email_hook=self.emails.append,
        )

    def tearDown(self):
        self.store.close()

    def test_same_asn_mobile_change_is_allowed(self):
        self.guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        decision = self.guard.observe('alice', 'session-bbbb', '1.2.4.5', now=1300)
        self.assertTrue(decision.recorded)
        self.assertIsNone(decision.reason)
        self.assertEqual(self.store.active_blocks('alice', 1300), [])
        self.assertEqual(self.emails, [])
        self.assertEqual(len(self.store.recent('alice', 0)), 2)

    def test_impossible_hop_blocks_newer_session_and_keeps_older(self):
        self.guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        with self.assertRaises(IpHopBlocked) as caught:
            self.guard.observe('alice', 'session-bbbb', '5.6.7.8', now=2800)
        self.assertEqual(caught.exception.code, 'session_blocked_ip_hop')
        self.assertEqual(caught.exception.status, 403)
        self.assertIsNotNone(self.store.blocked('alice', 'session-bbbb', 2800))
        self.assertIsNone(self.store.blocked('alice', 'session-aaaa', 2800))

        # The older session still works, even while the newer one is blocked.
        decision = self.guard.observe('alice', 'session-aaaa', '1.2.3.4', now=2900)
        self.assertTrue(decision.recorded)
        self.assertIsNone(self.store.blocked('alice', 'session-aaaa', 2900))
        self.assertEqual(len(self.emails), 1)
        self.assertEqual(self.store.audit_rows('alice')[0]['action'], 'block')

    def test_country_burst_blocks_the_newer_session(self):
        # Same ASN suppresses the travel-speed check; the country count alone
        # must still stop a rapid four-country burst.
        burst = {
            '1.2.3.4': GeoInfo('GB', 'AS9', 'London', 51.5074, -0.1278),
            '1.2.4.5': GeoInfo('FR', 'AS9', 'Paris', 48.8566, 2.3522),
            '10.0.0.1': GeoInfo('DE', 'AS9', 'Berlin', 52.5200, 13.4050),
            '9.9.9.9': GeoInfo('JP', 'AS9', 'Tokyo', 35.6762, 139.6503),
        }
        guard = IpHopGuard(self.store, resolver=StaticGeoResolver(burst),
                           email_hook=self.emails.append)
        guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        guard.observe('alice', 'session-bbbb', '1.2.4.5', now=1100)
        guard.observe('alice', 'session-cccc', '10.0.0.1', now=1200)
        with self.assertRaises(IpHopBlocked) as caught:
            guard.observe('alice', 'session-dddd', '9.9.9.9', now=1300)
        self.assertEqual(caught.exception.code, 'session_blocked_ip_hop')
        self.assertIsNotNone(self.store.blocked('alice', 'session-dddd', 1300))
        audit = self.store.audit_rows('alice')[0]
        self.assertEqual(audit['reason'], 'country_burst')
        self.assertEqual(audit['session_id'], 'session-dddd')
        self.assertEqual(len(self.emails), 1)

    def test_email_is_sent_once_per_account_window_without_raw_token(self):
        raw_token = 'super-secret-bearer-token'
        session_a = session_from_token(raw_token)
        self.guard.observe('alice', session_a, '1.2.3.4', now=1000)
        with self.assertRaises(IpHopBlocked):
            self.guard.observe('alice', 'session-bbbb', '5.6.7.8', now=1100)
        with self.assertRaises(IpHopBlocked):
            self.guard.observe('alice', 'session-cccc', '9.9.9.9', now=1200)

        self.assertEqual(len(self.emails), 1)
        self.assertEqual(len(self.store.alert_rows('alice')), 1)
        self.assertGreaterEqual(len(self.store.audit_rows('alice')), 2)
        event = self.emails[0]
        serialized = json.dumps(event, sort_keys=True)
        self.assertNotIn(raw_token, serialized)
        self.assertNotIn('1.2.3.4', serialized)
        self.assertNotIn('5.6.7.8', serialized)
        self.assertEqual(event['type'], 'ip_hop_block')
        self.assertEqual(event['location']['ip_prefix'], '5.6.7.0/24')
        self.assertEqual(event['previous_location']['ip_prefix'], '1.2.3.0/24')
        self.assertNotIn('authorization', serialized.lower())
        self.assertNotIn('token', serialized.lower())

    def test_blocked_session_does_not_poison_a_new_session_from_older_location(self):
        self.guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        with self.assertRaises(IpHopBlocked):
            self.guard.observe('alice', 'session-bbbb', '5.6.7.8', now=1100)
        # The blocked session's New York observation must not make a fresh
        # London session look like another impossible hop.
        decision = self.guard.observe('alice', 'session-cccc', '1.2.3.4', now=1200)
        self.assertTrue(decision.recorded)
        self.assertIsNone(decision.reason)
        self.assertIsNone(self.store.blocked('alice', 'session-cccc', 1200))

    def test_admin_unblock_restores_session_and_audits_override(self):
        self.guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        with self.assertRaises(IpHopBlocked):
            self.guard.observe('alice', 'session-bbbb', '5.6.7.8', now=1100)

        count = self.guard.admin_unblock(
            'alice', 'session-bbbb', actor='admin-1',
            reason='verified user travel', now=3000)
        self.assertEqual(count, 1)
        self.assertIsNone(self.store.blocked('alice', 'session-bbbb', 3000))
        self.assertTrue(self.store.override_active('alice', 'session-bbbb', 3001))

        # The override lets the reviewed session continue without immediately
        # re-triggering the same historical observations.
        decision = self.guard.observe('alice', 'session-bbbb', '5.6.7.8', now=3001)
        self.assertEqual(decision.reason, 'admin_override')
        audit = self.store.audit_rows('alice')
        unblocks = [row for row in audit if row['action'] == 'unblock']
        self.assertEqual(len(unblocks), 1)
        self.assertEqual(unblocks[0]['actor'], 'admin-1')
        self.assertEqual(unblocks[0]['reason'], 'verified user travel')

    def test_retention_prunes_by_age_and_per_account_bound(self):
        guard = IpHopGuard(
            self.store,
            resolver=StaticGeoResolver({f'10.0.0.{index}': BERLIN
                                        for index in range(1, 6)}),
            retention_seconds=100,
            max_observations_per_account=2,
            prune_interval_seconds=10_000,
        )
        for index in range(1, 6):
            guard.observe('alice', f'session-{index:04d}',
                          f'10.0.0.{index}', now=1000 + index)
        guard.prune(now=1005)
        remaining = self.store.recent('alice', 0)
        self.assertEqual([item.seen_at for item in remaining], [1004.0, 1005.0])

        guard.prune(now=2000)
        self.assertEqual(self.store.recent('alice', 0), [])

    def test_retention_prunes_audit_alerts_blocks_and_overrides(self):
        guard = IpHopGuard(
            self.store,
            resolver=StaticGeoResolver({'1.2.3.4': LONDON, '5.6.7.8': NEW_YORK}),
            email_hook=self.emails.append,
            audit_retention_seconds=100,
            block_seconds=50,
            override_seconds=50,
        )
        guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        with self.assertRaises(IpHopBlocked):
            guard.observe('alice', 'session-bbbb', '5.6.7.8', now=1100)
        guard.admin_unblock('alice', 'session-bbbb', actor='admin-1',
                            reason='verified travel', now=1200)

        result = guard.prune(now=2000)
        self.assertEqual(result['audit'], 2)
        self.assertEqual(result['alerts'], 1)
        self.assertEqual(result['blocks'], 1)
        self.assertEqual(result['overrides'], 1)
        self.assertEqual(self.store.audit_rows('alice'), [])
        self.assertEqual(self.store.alert_rows('alice'), [])
        self.assertEqual(self.store.active_blocks('alice', 2000), [])


class BrokenStore(SqliteIpHopStore):
    """Healthy block lookup, failing observation writes."""

    def record(self, observation):
        raise RuntimeError('observation authority unavailable')


class ExplodingResolver:
    def resolve(self, ip, headers):
        raise RuntimeError('geo database unavailable')


class FailClosedTests(unittest.TestCase):
    def setUp(self):
        self.store = BrokenStore()
        self.addCleanup(self.store.close)

    def test_fail_open_is_the_default_and_returns_a_decision(self):
        guard = IpHopGuard(self.store, resolver=StaticGeoResolver({}))
        decision = guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        self.assertFalse(decision.recorded)
        self.assertEqual(decision.reason, 'guard_unavailable')
        self.assertTrue(decision.allowed)

    def test_fail_closed_raises_a_503_when_the_store_cannot_record(self):
        guard = IpHopGuard(self.store, resolver=StaticGeoResolver({}),
                           fail_closed=True)
        with self.assertRaises(IpHopUnavailable) as caught:
            guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        self.assertEqual(caught.exception.code, 'ip_hop_unavailable')
        self.assertEqual(caught.exception.status, 503)

    def test_fail_closed_blocks_requests_without_a_usable_address(self):
        guard = IpHopGuard(self.store, fail_closed=True)
        with self.assertRaises(IpHopUnavailable):
            guard.observe('alice', 'session-aaaa', '', now=1000)
        with self.assertRaises(IpHopUnavailable):
            guard.observe('alice', 'session-aaaa', 'not-an-ip', now=1000)

    def test_fail_open_skips_requests_without_a_usable_address(self):
        guard = IpHopGuard(self.store)
        decision = guard.observe('alice', 'session-aaaa', '', now=1000)
        self.assertFalse(decision.recorded)
        self.assertEqual(decision.reason, 'invalid_address')

    def test_existing_block_is_enforced_even_when_writes_fail(self):
        self.store.block('alice', 'session-bbbb', 'impossible_travel', 'event-1',
                         900, 2000)
        guard = IpHopGuard(self.store, fail_closed=True)
        with self.assertRaises(IpHopBlocked) as caught:
            guard.observe('alice', 'session-bbbb', '1.2.3.4', now=1000)
        self.assertEqual(caught.exception.event_id, 'event-1')

    def test_resolver_failure_alone_does_not_fail_closed(self):
        store = SqliteIpHopStore()
        self.addCleanup(store.close)
        guard = IpHopGuard(store, resolver=ExplodingResolver(), fail_closed=True)
        decision = guard.observe('alice', 'session-aaaa', '1.2.3.4', now=1000)
        self.assertTrue(decision.recorded)
        self.assertIsNone(decision.reason)
        self.assertEqual(len(store.recent('alice', 0)), 1)


class AccountIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.store = SqliteIpHopStore()
        self.emails = []
        self.now = 1000
        self.guard = IpHopGuard(
            self.store,
            resolver=StaticGeoResolver({'1.2.3.4': LONDON, '5.6.7.8': NEW_YORK}),
            email_hook=self.emails.append,
            clock=lambda: self.now,
        )
        service = Lifecycle(MemoryStore(), Admin(), Data(), lambda: self.now,
                            ip_hop=self.guard)
        self.service = service

        def verify(token, appcheck, allow_disabled=False):
            if appcheck != 'attested':
                raise AccountError('invalid_token', 401)
            if token == 'admin':
                return {'uid': 'admin', 'admin': True, 'auth_time': self.now,
                        'firebase': {'sign_in_provider': 'google.com'}}
            if token != 'valid':
                raise AccountError('invalid_token', 401)
            return {'uid': 'alice', 'auth_time': self.now,
                    'firebase': {'sign_in_provider': 'google.com'}}

        app = FastAPI()
        app.include_router(router(service, verify))
        self.client = TestClient(app)

    def tearDown(self):
        self.store.close()

    def headers(self, session, ip):
        return {'Authorization': 'Bearer valid', 'X-Firebase-AppCheck': 'attested',
                'X-Session-Id': session, 'CF-Connecting-IP': ip}

    def test_authenticated_route_returns_session_blocked_ip_hop(self):
        self.assertEqual(self.client.get('/account/deletion',
                         headers=self.headers('session-aaaa', '1.2.3.4')).status_code, 200)
        self.now = 1100
        response = self.client.get('/account/deletion',
                                   headers=self.headers('session-bbbb', '5.6.7.8'))
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()['detail'], 'session_blocked_ip_hop')
        self.now = 1200
        self.assertEqual(self.client.get('/account/deletion',
                         headers=self.headers('session-aaaa', '1.2.3.4')).status_code, 200)
        self.assertEqual(len(self.emails), 1)

    def test_admin_unblock_route_requires_admin_claim_and_audits(self):
        self.client.get('/account/deletion',
                        headers=self.headers('session-aaaa', '1.2.3.4'))
        self.now = 1100
        self.assertEqual(self.client.get('/account/deletion',
                         headers=self.headers('session-bbbb', '5.6.7.8')).status_code, 403)

        self.now = 5000
        admin_headers = {'Authorization': 'Bearer admin',
                         'X-Firebase-AppCheck': 'attested',
                         'X-Session-Id': 'session-admin',
                         'CF-Connecting-IP': '5.6.7.8'}
        denied = self.client.post(
            '/account/security/alice/sessions/session-bbbb/unblock',
            headers=self.headers('session-aaaa', '1.2.3.4'),
            json={'reason': 'verified travel'})
        self.assertEqual(denied.status_code, 403)
        self.assertEqual(denied.json()['detail'], 'admin_required')

        response = self.client.post(
            '/account/security/alice/sessions/session-bbbb/unblock',
            headers=admin_headers, json={'reason': 'verified travel'})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), 1)
        self.assertIsNone(self.store.blocked('alice', 'session-bbbb', 5000))
        self.assertEqual(
            [row['action'] for row in self.store.audit_rows('alice')][0], 'unblock')

    def test_access_uses_middleware_request_context(self):
        from server.security.ip_hop import (request_context, reset_request_context,
                                            set_request_context)

        class Request:
            headers = {'authorization': 'Bearer valid', 'cf-connecting-ip': '1.2.3.4',
                       'x-session-id': 'session-aaaa'}

        token = set_request_context(request_context(Request()))
        try:
            with self.service.access({'uid': 'alice',
                                      'firebase': {'sign_in_provider': 'google.com'}}):
                pass
        finally:
            reset_request_context(token)
        self.assertEqual(len(self.store.recent('alice', 0)), 1)

    def test_fail_closed_guard_returns_ip_hop_unavailable(self):
        store = BrokenStore()
        self.addCleanup(store.close)
        guard = IpHopGuard(store, fail_closed=True)
        service = Lifecycle(MemoryStore(), Admin(), Data(), lambda: self.now,
                            ip_hop=guard)

        def verify(token, appcheck, allow_disabled=False):
            if token != 'valid' or appcheck != 'attested':
                raise AccountError('invalid_token', 401)
            return {'uid': 'alice', 'auth_time': self.now,
                    'firebase': {'sign_in_provider': 'google.com'}}

        app = FastAPI()
        app.include_router(router(service, verify))
        client = TestClient(app)
        response = client.get('/account/deletion',
                              headers=self.headers('session-aaaa', '1.2.3.4'))
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()['detail'], 'ip_hop_unavailable')


class FingerprintTests(unittest.TestCase):
    def test_coarse_prefix_is_ipv4_24_and_ipv6_48(self):
        self.assertEqual(coarse_prefix('1.2.3.4'), '1.2.3.0/24')
        self.assertEqual(coarse_prefix('2001:db8:abcd::1'), '2001:db8:abcd::/48')
        with self.assertRaises(ValueError):
            coarse_prefix('not-an-ip')

    def test_session_from_token_is_not_the_token(self):
        token = 'raw-token-value'
        session = session_from_token(token)
        self.assertNotIn(token, session)
        self.assertTrue(session.startswith('tok_'))


if __name__ == '__main__':
    unittest.main()
