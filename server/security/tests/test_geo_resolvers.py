"""GeoIP parsing, country-only degradation and deterministic resolver fakes."""

import os
import unittest

from server.security.ip_hop import (
    ChainGeoResolver,
    FakeGeoResolver,
    GeoInfo,
    HeaderGeoResolver,
    IpHopBlocked,
    IpHopGuard,
    MaxMindGeoResolver,
    RequestHeaders,
    SqliteIpHopStore,
    StaticGeoResolver,
    build_geo_resolver,
    geo_from_maxmind,
)

def trusted(headers):
    """Header view for a request that arrived through a trusted proxy."""
    return RequestHeaders(headers, peer_trusted=True)
def untrusted(headers):
    """Header view for a request that arrived directly from the client."""
    return RequestHeaders(headers, peer_trusted=False)


class FakeReader:
    def __init__(self, records):
        self.records = records
        self.closed = False

    def get(self, ip):
        return self.records.get(ip)

    def close(self):
        self.closed = True


def city_record(country='GB', city='London', latitude=51.5074,
                longitude=-0.1278):
    record = {'city': {'names': {'en': city}},
              'location': {'latitude': latitude, 'longitude': longitude}}
    if country is not None:
        record['country'] = {'iso_code': country}
    return record


class MaxMindParsingTests(unittest.TestCase):
    def test_city_database_parses_country_city_and_coordinates(self):
        reader = FakeReader({'1.2.3.4': city_record()})
        resolver = MaxMindGeoResolver('/geo/city.mmdb',
                                      reader_factory=lambda path: reader)
        self.assertEqual(resolver.resolve('1.2.3.4', {}),
                         GeoInfo('GB', None, 'London', 51.5074, -0.1278))

    def test_registered_country_is_the_fallback(self):
        record = city_record(country=None)
        record['registered_country'] = {'iso_code': 'de'}
        self.assertEqual(geo_from_maxmind(record).country, 'DE')

    def test_localized_city_falls_back_to_any_language(self):
        record = city_record()
        record['city'] = {'names': {'de': 'Berlin'}}
        self.assertEqual(geo_from_maxmind(record).city, 'Berlin')

    def test_missing_location_keeps_country_only(self):
        record = {'country': {'iso_code': 'GB'}}
        geo = geo_from_maxmind(record)
        self.assertEqual(geo.country, 'GB')
        self.assertIsNone(geo.latitude)
        self.assertIsNone(geo.longitude)

    def test_invalid_coordinates_are_dropped_together(self):
        geo = geo_from_maxmind(city_record(latitude=999, longitude=2.0))
        self.assertIsNone(geo.latitude)
        self.assertIsNone(geo.longitude)
        self.assertEqual(geo.country, 'GB')

    def test_asn_database_supplies_normalized_asn(self):
        readers = {
            '/geo/city.mmdb': FakeReader({'1.2.3.4': city_record()}),
            '/geo/asn.mmdb': FakeReader({'1.2.3.4': {'autonomous_system_number': 64500}}),
        }
        resolver = MaxMindGeoResolver('/geo/city.mmdb',
                                      asn_database_path='/geo/asn.mmdb',
                                      reader_factory=lambda path: readers[path])
        geo = resolver.resolve('1.2.3.4', {})
        self.assertEqual(geo.asn, 'AS64500')
        self.assertEqual(geo.city, 'London')

    def test_unknown_and_invalid_addresses_return_none(self):
        resolver = MaxMindGeoResolver(
            '/geo/city.mmdb',
            reader_factory=lambda path: FakeReader({'1.2.3.4': city_record()}))
        self.assertIsNone(resolver.resolve('5.6.7.8', {}))
        self.assertIsNone(resolver.resolve('not-an-ip', {}))
        self.assertIsNone(resolver.resolve('', {}))

    def test_unknown_country_code_is_dropped(self):
        geo = geo_from_maxmind(city_record(country='XX'))
        self.assertIsNone(geo.country)
        self.assertEqual(geo.city, 'London')

    def test_ipv4_mapped_address_is_unwrapped_before_lookup(self):
        reader = FakeReader({'1.2.3.4': city_record()})
        resolver = MaxMindGeoResolver('/geo/city.mmdb',
                                      reader_factory=lambda path: reader)
        self.assertEqual(resolver.resolve('::ffff:1.2.3.4', {}).country, 'GB')

    def test_close_closes_every_reader(self):
        city = FakeReader({})
        asn = FakeReader({})
        readers = {'/geo/city.mmdb': city, '/geo/asn.mmdb': asn}
        resolver = MaxMindGeoResolver('/geo/city.mmdb',
                                      asn_database_path='/geo/asn.mmdb',
                                      reader_factory=lambda path: readers[path])
        resolver.close()
        self.assertTrue(city.closed)
        self.assertTrue(asn.closed)

    def test_database_is_opened_eagerly_so_bad_configuration_fails_fast(self):
        def missing(path):
            raise FileNotFoundError(path)

        with self.assertRaises(FileNotFoundError):
            MaxMindGeoResolver('/missing.mmdb', reader_factory=missing)
        with self.assertRaises(ValueError):
            MaxMindGeoResolver('  ')


class FakeResolverTests(unittest.TestCase):
    def test_exact_network_and_default_lookups_are_deterministic(self):
        london = GeoInfo('GB', 'AS1', 'London', 51.5074, -0.1278)
        paris = GeoInfo('FR', 'AS1', 'Paris', 48.8566, 2.3522)
        tokyo = GeoInfo('JP', 'AS3', 'Tokyo', 35.6762, 139.6503)
        resolver = FakeGeoResolver(
            {'1.2.3.4': london},
            networks={'10.0.0.0/8': paris, '10.1.0.0/16': tokyo},
            default=london)
        self.assertEqual(resolver.resolve('1.2.3.4', {}), london)
        # Longest prefix wins over the broader network.
        self.assertEqual(resolver.resolve('10.1.2.3', {}), tokyo)
        self.assertEqual(resolver.resolve('10.2.3.4', {}), paris)
        self.assertEqual(resolver.resolve('192.0.2.1', {}), london)
        self.assertEqual(resolver.resolve('bad-ip', {}), london)
        self.assertEqual(resolver.calls, ['1.2.3.4', '10.1.2.3', '10.2.3.4',
                                          '192.0.2.1', 'bad-ip'])
        self.assertEqual(resolver.resolve('10.1.2.3', {}), tokyo)

    def test_static_resolver_remains_exact_ip_only(self):
        london = GeoInfo('GB')
        resolver = StaticGeoResolver({'1.2.3.4': london})
        self.assertEqual(resolver.resolve('1.2.3.4', {}), london)
        self.assertIsNone(resolver.resolve('1.2.3.5', {}))


class CountryOnlyModeTests(unittest.TestCase):
    def setUp(self):
        self.store = SqliteIpHopStore()
        self.addCleanup(self.store.close)

    def test_header_resolver_defaults_to_country_without_coordinates(self):
        resolver = HeaderGeoResolver()
        geo = resolver.resolve('1.2.3.4', trusted({'cf-ipcountry': 'gb'}))
        self.assertEqual(geo, GeoInfo('GB'))
        self.assertIsNone(geo.latitude)
        self.assertIsNone(geo.longitude)

    def test_trusted_headers_add_coordinates_when_enabled(self):
        resolver = HeaderGeoResolver(trust_geo_headers=True)
        geo = resolver.resolve('1.2.3.4', trusted({
            'cf-ipcountry': 'GB', 'x-ovid-latitude': '51.5',
            'x-ovid-longitude': '-0.12', 'x-ovid-asn': '64500',
            'x-ovid-city': 'London'}))
        self.assertEqual(geo, GeoInfo('GB', 'AS64500', 'London', 51.5, -0.12))

    def test_geo_headers_from_an_untrusted_peer_are_ignored(self):
        resolver = HeaderGeoResolver(trust_geo_headers=True)
        spoofed = {'cf-ipcountry': 'JP', 'x-ovid-latitude': '35.6',
                   'x-ovid-longitude': '139.6', 'x-ovid-city': 'Tokyo'}
        self.assertIsNone(resolver.resolve('1.2.3.4', untrusted(spoofed)))
        # A bare mapping has no verified peer either.
        self.assertIsNone(HeaderGeoResolver().resolve('1.2.3.4',
                                                      {'cf-ipcountry': 'JP'}))

    def test_unknown_country_headers_are_dropped_behind_a_trusted_peer(self):
        resolver = HeaderGeoResolver()
        self.assertIsNone(resolver.resolve('1.2.3.4', trusted({'cf-ipcountry': 'XX'})))

    def test_build_without_database_is_country_only(self):
        resolver = build_geo_resolver()
        self.assertIsInstance(resolver, HeaderGeoResolver)
        self.assertEqual(
            resolver.resolve('1.2.3.4', trusted({'cf-ipcountry': 'FR'})),
            GeoInfo('FR'))
        self.assertIsNone(resolver.resolve('1.2.3.4', {'cf-ipcountry': 'FR'}))

    def test_country_only_mode_still_detects_country_bursts(self):
        guard = IpHopGuard(self.store, resolver=HeaderGeoResolver())
        guard.observe('alice', 'session-aaaa', '1.2.3.4',
                      headers=trusted({'cf-ipcountry': 'GB'}), now=1000)
        guard.observe('alice', 'session-bbbb', '1.2.4.5',
                      headers=trusted({'cf-ipcountry': 'FR'}), now=1100)
        guard.observe('alice', 'session-cccc', '10.0.0.1',
                      headers=trusted({'cf-ipcountry': 'DE'}), now=1200)
        with self.assertRaises(IpHopBlocked):
            guard.observe('alice', 'session-dddd', '9.9.9.9',
                          headers=trusted({'cf-ipcountry': 'JP'}), now=1300)
        audit = self.store.audit_rows('alice')[0]
        self.assertEqual(audit['reason'], 'country_burst')
        self.assertEqual(audit['session_id'], 'session-dddd')

    def test_spoofed_country_headers_cannot_fake_a_burst(self):
        guard = IpHopGuard(self.store, resolver=HeaderGeoResolver())
        for index, session in enumerate(('session-aaaa', 'session-bbbb',
                                         'session-cccc', 'session-dddd')):
            guard.observe('alice', session, f'10.0.0.{index + 1}',
                          headers=untrusted({'cf-ipcountry': 'GB'}),
                          now=1000 + index)
        self.assertEqual(self.store.active_blocks('alice', 1400), [])

    def test_country_only_mode_does_not_invent_travel_distance(self):
        guard = IpHopGuard(self.store, resolver=HeaderGeoResolver())
        guard.observe('alice', 'session-aaaa', '1.2.3.4',
                      headers=trusted({'cf-ipcountry': 'GB'}), now=1000)
        decision = guard.observe('alice', 'session-bbbb', '5.6.7.8',
                                 headers=trusted({'cf-ipcountry': 'GB'}), now=1100)
        self.assertIsNone(decision.reason)
        self.assertEqual(self.store.active_blocks('alice', 1100), [])


class ResolverChainTests(unittest.TestCase):
    def test_database_coordinates_merge_with_header_country(self):
        reader = FakeReader({'1.2.3.4': city_record(country=None)})
        resolver = build_geo_resolver(
            database_path='/geo/city.mmdb', reader_factory=lambda path: reader)
        self.assertIsInstance(resolver, ChainGeoResolver)
        geo = resolver.resolve('1.2.3.4', trusted({'cf-ipcountry': 'GB'}))
        self.assertEqual(geo, GeoInfo('GB', None, 'London', 51.5074, -0.1278))

    def test_database_coordinates_ignore_an_untrusted_header_country(self):
        reader = FakeReader({'1.2.3.4': city_record(country=None)})
        resolver = build_geo_resolver(
            database_path='/geo/city.mmdb', reader_factory=lambda path: reader)
        geo = resolver.resolve('1.2.3.4', untrusted({'cf-ipcountry': 'GB'}))
        self.assertEqual(geo, GeoInfo(None, None, 'London', 51.5074, -0.1278))

    def test_database_country_wins_over_header(self):
        reader = FakeReader({'1.2.3.4': city_record(country='DE')})
        resolver = build_geo_resolver(
            database_path='/geo/city.mmdb', reader_factory=lambda path: reader)
        self.assertEqual(
            resolver.resolve('1.2.3.4', trusted({'cf-ipcountry': 'GB'})).country,
            'DE')

    def test_failing_resolver_does_not_discard_the_next_one(self):
        class Broken:
            def resolve(self, ip, headers):
                raise RuntimeError('database unavailable')

        chain = ChainGeoResolver(Broken(), HeaderGeoResolver())
        self.assertEqual(chain.resolve('1.2.3.4', trusted({'cf-ipcountry': 'FR'})),
                         GeoInfo('FR'))

    def test_all_resolvers_failing_is_an_error_not_a_silent_none(self):
        class Broken:
            def resolve(self, ip, headers):
                raise RuntimeError('database unavailable')

        chain = ChainGeoResolver(Broken(), Broken())
        with self.assertRaises(RuntimeError):
            chain.resolve('1.2.3.4', trusted({'cf-ipcountry': 'FR'}))

    def test_asn_database_requires_a_city_database(self):
        with self.assertRaises(ValueError):
            build_geo_resolver(asn_database_path='/geo/asn.mmdb')


class RealDatabaseTests(unittest.TestCase):
    """Optional smoke test against a real ``.mmdb`` file."""

    def test_real_database_returns_a_normalized_location(self):
        path = os.environ.get('IP_HOP_TEST_GEOIP_DB')
        if not path:
            self.skipTest('IP_HOP_TEST_GEOIP_DB requires a MaxMind test database')
        ip = os.environ.get('IP_HOP_TEST_GEOIP_IP', '81.2.69.142')
        resolver = MaxMindGeoResolver(path)
        self.addCleanup(resolver.close)
        geo = resolver.resolve(ip, {})
        self.assertIsNotNone(geo)
        self.assertIsNotNone(geo.country)
        self.assertIsNotNone(geo.latitude)
        self.assertIsNotNone(geo.longitude)


if __name__ == '__main__':
    unittest.main()
