"""Stdlib deployment checks plus explicitly dependency-gated runtime integration."""

from __future__ import annotations

import re
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENT = ROOT / "server" / "account" / "DEPLOYMENT.md"
ACCOUNT = ROOT / "server" / "account"


def requires_modules(*names):
    missing = [name for name in names if importlib.util.find_spec(name) is None]
    return unittest.skipIf(bool(missing), 'Server integration requires ' + ', '.join(missing)
                           + '; install server/account/requirements.txt in this Python environment')


class DeploymentConfigTest(unittest.TestCase):
    def command(self, module, env, *args):
        return subprocess.run([sys.executable, '-m', module, *args], cwd=ROOT,
                              env=env, capture_output=True, text=True)

    @requires_modules('pydantic', 'PIL', 'psycopg')
    def test_configured_postgres_cli_without_firebase_or_activation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            config = json.loads((ROOT / 'examples/account-stores.json').read_text())
            for name in ('images', 'shares'):
                config[name]['path'] = str(path / (name + '.db'))
            config_path = path / 'stores.json'
            config_path.write_text(json.dumps(config))
            env = {'PATH': os.defpath, 'ACCOUNT_STORE_CONFIG': str(config_path),
                   'PRIVATE_SYNC_CONFIGURED': 'true', 'PRIVATE_SYNC_ACTIVATED': 'false',
                   'PRIVATE_SYNC_AUTHORITY_ID': '33333333-3333-4333-8333-333333333333',
                   'ACCOUNT_DATABASE_URL': 'postgresql://unused.invalid/account'}
            result = self.command('server.account.stores', env, '--provision')
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.command('server.account.runtime', env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('no remote connectivity checked', result.stdout)
            del env['PRIVATE_SYNC_AUTHORITY_ID']
            result = self.command('server.account.runtime', env)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn('unused.invalid', result.stdout + result.stderr)

    def assert_retention_configuration_failure(self, module):
        result = self.command(module, {'ACCOUNT_DATABASE_URL': 'secret-bearing-invalid-value'})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertTrue(json.loads(result.stdout)['failed'])
        self.assertNotIn('secret-bearing', result.stdout)

    def test_account_retention_cli_configuration_failure_is_nonsecret(self):
        self.assert_retention_configuration_failure('server.account.retention')

    @requires_modules('psycopg')
    def test_sync_retention_cli_configuration_failure_is_nonsecret(self):
        self.assert_retention_configuration_failure('server.sync.maintenance')

    def test_example_store_configuration_parses_without_server_dependencies(self):
        # Exercise the real stdlib config loader, without provisioning/importing
        # repositories. Operational provisioning is covered by the integration above.
        script = '''
import json, pathlib, sys
from server.account.stores import StoreConfig
root = pathlib.Path(sys.argv[1])
value = json.loads(pathlib.Path(sys.argv[2]).read_text())
for name in ('images', 'shares'):
    value[name]['path'] = str(root / (name + '.db'))
path = root / 'stores.json'
path.write_text(json.dumps(value))
config = StoreConfig.load(path)
assert config.images['path'] != config.shares['path']
value['shares']['store_id'] = value['images']['store_id']
path.write_text(json.dumps(value))
try:
    StoreConfig.load(path)
except ValueError:
    pass
else:
    raise AssertionError('Duplicate authority identities accepted')
assert not list(root.glob('*.db')), 'Configuration check created an authority'
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, '-S', '-c', script, directory,
                                     str(ROOT / 'examples/account-stores.json')], cwd=ROOT,
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_flutter_runner_covers_indexed_and_untracked_nested_tests(self):
        # An indexed file is what git ls-files (and CI after checkout) discovers.
        # No commit is required to exercise both sides of that boundary.
        spec = importlib.util.spec_from_file_location('suite_runner', ROOT / 'tool/run_flutter_suite.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'test/nested').mkdir(parents=True)
            (root / 'test/first_test.dart').write_text('// indexed fixture')
            subprocess.run(['git', 'init', '-q', str(root)], check=True, capture_output=True)
            subprocess.run(['git', 'add', 'test'], cwd=root, check=True, capture_output=True)
            (root / 'test/nested/new_test.dart').write_text('// untracked fixture')
            (root / 'test/helper.dart').write_text('// not a test')
            expected = ['test/first_test.dart', 'test/nested/new_test.dart']
            self.assertEqual(runner.discover(root), expected)
            subprocess.run(['git', 'add', 'test'], cwd=root, check=True, capture_output=True)
            tracked = subprocess.check_output(['git', 'ls-files', 'test/**_test.dart'],
                                              cwd=root, text=True).splitlines()
            self.assertEqual(tracked, expected)
            self.assertEqual(runner.discover(root), expected)

    def test_flutter_runner_covers_current_ci_manifest_and_new_files(self):
        spec = importlib.util.spec_from_file_location('suite_runner', ROOT / 'tool/run_flutter_suite.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others',
                                         '--exclude-standard', 'test'], cwd=ROOT).decode().split('\0')
        expected = sorted({name for name in files if name.endswith('_test.dart')
                           and (ROOT / name).is_file()})
        self.assertTrue(expected)
        self.assertEqual(runner.discover(ROOT), expected)

    def test_documented_fresh_and_upgrade_commands_use_matching_sql(self) -> None:
        text = DEPLOYMENT.read_text(encoding="utf-8")
        self.assertRegex(text, r"psql\s+\S+\s+-v\s+ON_ERROR_STOP=1\s+-f\s+server/account/schema\.sql")
        self.assertRegex(
            text,
            r"psql\s+\S+\s+-v\s+ON_ERROR_STOP=1\s+-f\s+server/account/schema_private_sync\.sql",
        )
        self.assertRegex(
            text,
            r"psql\s+\S+\s+-v\s+ON_ERROR_STOP=1\s+-f\s+server/account/migrations/002_retry_schedule\.sql",
        )
        self.assertRegex(
            text,
            r"psql\s+\S+\s+-v\s+ON_ERROR_STOP=1\s+-f\s+server/account/migrations/003_private_sync\.sql",
        )

    def test_documented_postgres_boundary_is_explicit(self) -> None:
        text = DEPLOYMENT.read_text(encoding="utf-8")
        self.assertIn("PostgreSQL only", text)
        self.assertIn("ACCOUNT_DATABASE_URL", text)
        self.assertNotRegex(text, r"(?i)(sqlite|fallback).*postgres")

    def test_referenced_sql_files_exist(self) -> None:
        for relative in re.findall(r"server/account/[\w/.-]+\.sql", DEPLOYMENT.read_text(encoding="utf-8")):
            self.assertTrue((ROOT / relative).is_file(), relative)


if __name__ == "__main__":
    unittest.main()
