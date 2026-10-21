"""Runtime selection of the IP-hop store, resolver and fail-closed mode."""

import os
import tempfile
import unittest
from unittest.mock import patch

from server.account import runtime
from server.security.ip_hop import HeaderGeoResolver, SqliteIpHopStore


class IpHopRuntimeTests(unittest.TestCase):
    def test_absent_configuration_disables_the_guard(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(runtime._ip_hop())

    def test_fail_closed_requires_a_configured_store(self):
        with patch.dict(os.environ, {'IP_HOP_FAIL_CLOSED': 'true'}, clear=True):
            with self.assertRaisesRegex(ValueError, 'IP_HOP_FAIL_CLOSED'):
                runtime._ip_hop()

    def test_sqlite_path_builds_a_country_only_fail_open_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, 'ip_hop.db')
            with patch.dict(os.environ, {'IP_HOP_DATABASE_PATH': path},
                            clear=True):
                guard = runtime._ip_hop()
            self.addCleanup(guard.store.close)
            self.assertIsInstance(guard.store, SqliteIpHopStore)
            self.assertIsInstance(guard.resolver, HeaderGeoResolver)
            self.assertFalse(guard.fail_closed)

    def test_both_store_settings_are_rejected(self):
        env = {'IP_HOP_DATABASE_URL': 'postgresql://fixture/ip_hop',
               'IP_HOP_DATABASE_PATH': '/tmp/ip_hop.db'}
        with patch.dict(os.environ, env, clear=True), \
                self.assertRaisesRegex(ValueError, 'only one'):
            runtime._ip_hop()

    def test_postgres_dsn_selects_the_postgres_store(self):
        sentinel = object()
        env = {'IP_HOP_DATABASE_URL': 'postgresql://fixture/ip_hop'}
        with patch.dict(os.environ, env, clear=True), \
                patch('server.security.ip_hop.PostgresIpHopStore',
                      return_value=sentinel) as build, \
                patch('server.security.ip_hop.build_geo_resolver',
                      return_value=HeaderGeoResolver()):
            guard = runtime._ip_hop()
        self.assertIs(guard.store, sentinel)
        self.assertEqual(build.call_args.args[0], env['IP_HOP_DATABASE_URL'])
        self.assertTrue(build.call_args.kwargs['ensure_schema'])
        self.assertFalse(guard.fail_closed)

    def test_postgres_schema_creation_can_be_disabled(self):
        env = {'IP_HOP_DATABASE_URL': 'postgresql://fixture/ip_hop',
               'IP_HOP_POSTGRES_ENSURE_SCHEMA': 'false'}
        with patch.dict(os.environ, env, clear=True), \
                patch('server.security.ip_hop.PostgresIpHopStore',
                      return_value=object()) as build, \
                patch('server.security.ip_hop.build_geo_resolver',
                      return_value=HeaderGeoResolver()):
            runtime._ip_hop()
        self.assertFalse(build.call_args.kwargs['ensure_schema'])

    def test_geoip_paths_and_fail_closed_are_forwarded(self):
        env = {'IP_HOP_DATABASE_URL': 'postgresql://fixture/ip_hop',
               'IP_HOP_GEOIP_DB': '/geo/city.mmdb',
               'IP_HOP_GEOIP_ASN_DB': '/geo/asn.mmdb',
               'IP_HOP_FAIL_CLOSED': 'true'}
        with patch.dict(os.environ, env, clear=True), \
                patch('server.security.ip_hop.PostgresIpHopStore',
                      return_value=object()), \
                patch('server.security.ip_hop.build_geo_resolver',
                      return_value=HeaderGeoResolver()) as resolver:
            guard = runtime._ip_hop()
        resolver.assert_called_once_with(database_path='/geo/city.mmdb',
                                         asn_database_path='/geo/asn.mmdb',
                                         trust_geo_headers=False)
        self.assertTrue(guard.fail_closed)


if __name__ == '__main__':
    unittest.main()
