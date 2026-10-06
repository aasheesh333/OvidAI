"""Offline bootstrap provenance/derivation tests; no upstream downloads."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

HELPER = Path(__file__).resolve().parents[1] / 'tool/bootstrap_supply.py'


class BootstrapSupplyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wave2-bootstrap-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.asset = self.root / 'upstream.zip'
        with zipfile.ZipFile(self.asset, 'w') as z:
            for name, data in {
                'bin/bash': b'shell', 'bin/gpgv': b'verifier',
                'bin/unwanted': b'omit', 'lib/libfixture.so': b'library',
                'share/termux-keyring/fixture.gpg': b'public key',
                'share/terminfo/x/xterm': b'terminal',
                'var/lib/dpkg/status': b'Package: fixture\n',
                'SYMLINKS.txt': 'bash\u2190bin/sh\n'.encode(),
                'etc/apt/sources.list': b'deb https://example.test stable main',
            }.items():
                z.writestr(name, data)
        self.pin = {
            'sha256': hashlib.sha256(self.asset.read_bytes()).hexdigest(),
            'size': self.asset.stat().st_size,
        }
        self.out = self.root / 'output/libovid_bootstrap.so'

    def helper(self):
        self.assertTrue(HELPER.is_file(), 'bootstrap verification helper is missing')
        spec = importlib.util.spec_from_file_location('bootstrap_supply', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_tampered_cached_asset_rejected_before_extract_or_output(self):
        helper = self.helper()
        self.asset.write_bytes(self.asset.read_bytes() + b'tampered')
        with self.assertRaisesRegex(ValueError, 'size|SHA256'):
            helper.build(self.asset, self.out, 'aarch64', self.pin)
        self.assertFalse(self.out.exists())

    def test_wrong_hash_same_size_rejected(self):
        helper = self.helper()
        self.pin['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            helper.build(self.asset, self.out, 'aarch64', self.pin)

    def test_fresh_deterministic_output_and_manifest_bind_input_and_subset(self):
        helper = self.helper()
        helper.build(self.asset, self.out, 'aarch64', self.pin)
        first = self.out.read_bytes()
        manifest = self.out.with_suffix('.manifest.json').read_bytes()
        with zipfile.ZipFile(self.out, 'a') as z:
            z.writestr('stale-from-old-build', 'stale')
        helper.build(self.asset, self.out, 'aarch64', self.pin)
        self.assertEqual(first, self.out.read_bytes())
        self.assertEqual(manifest, self.out.with_suffix('.manifest.json').read_bytes())
        with zipfile.ZipFile(self.out) as z:
            self.assertIn('share/terminfo/x/xterm', z.namelist())
            self.assertIn('var/lib/dpkg/status', z.namelist())
            self.assertNotIn('bin/unwanted', z.namelist())
            self.assertNotIn('stale-from-old-build', z.namelist())
        m = json.loads(manifest)
        self.assertEqual(m['upstream']['sha256'], self.pin['sha256'])
        self.assertEqual(m['output']['sha256'], hashlib.sha256(first).hexdigest())
        self.assertIn('bin/bash', [entry['path'] for entry in m['entries']])

    def test_traversal_in_pinned_archive_rejected_before_publication(self):
        helper = self.helper()
        with zipfile.ZipFile(self.asset, 'a') as z:
            z.writestr('../escape', 'bad')
        self.pin.update(size=self.asset.stat().st_size,
                        sha256=hashlib.sha256(self.asset.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'path'):
            helper.build(self.asset, self.out, 'aarch64', self.pin)
        self.assertFalse(self.out.exists())

    def test_missing_keyring_rejected(self):
        helper = self.helper()
        with zipfile.ZipFile(self.asset, 'w') as z:
            z.writestr('SYMLINKS.txt', '')
            z.writestr('share/terminfo/x/xterm', 'terminal')
        self.pin.update(size=self.asset.stat().st_size,
                        sha256=hashlib.sha256(self.asset.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, 'keyring'):
            helper.build(self.asset, self.out, 'aarch64', self.pin)

    def test_production_pins_match_prior_release_evidence(self):
        helper = self.helper()
        self.assertEqual(helper.PINS['aarch64'], {
            'size': 32672724,
            'sha256': 'f902017cf09c84189732b6174b56d69b9890468f4fa7394fc1354b573153688e',
        })
        self.assertEqual(helper.PINS['arm']['sha256'],
                         '27fb2eaaf2ebb579e65cefcbfc7dab44ea9f2d1a0c7e73efe3a2f87a8ebfd359')
        self.assertEqual(helper.PINS['x86_64']['sha256'],
                         '5f7c54e860df1ef5146b8475dc90e69af666da6588ca1fd47be8f7036b07e8cb')

    def test_offline_acquire_verifies_cached_asset_without_transport(self):
        helper = self.helper()
        cached = self.root / 'bootstrap-aarch64.zip'
        self.asset.rename(cached)
        with mock.patch.dict(helper.PINS, {'aarch64': self.pin}), \
                mock.patch.object(helper.subprocess, 'run') as transport:
            self.assertEqual(helper.acquire(self.root, 'aarch64', True), cached)
        transport.assert_not_called()

    def test_offline_missing_cache_fails_without_transport_or_output(self):
        helper = self.helper()
        cache = self.root / 'missing-cache'
        with mock.patch.object(helper.subprocess, 'run') as transport:
            with self.assertRaisesRegex(ValueError, 'missing pinned cached asset'):
                helper.acquire(cache, 'aarch64', True)
        transport.assert_not_called()
        self.assertFalse(cache.exists())
        self.assertFalse(self.out.exists())

    def test_poisoned_cache_never_falls_back_to_download(self):
        helper = self.helper()
        cached = self.root / 'bootstrap-aarch64.zip'
        self.asset.rename(cached)
        original = cached.read_bytes()
        for offline in (False, True):
            for poisoned in (original + b'tampered', b'x' * len(original)):
                with self.subTest(offline=offline, size=len(poisoned)):
                    cached.write_bytes(poisoned)
                    with mock.patch.dict(helper.PINS, {'aarch64': self.pin}), \
                            mock.patch.object(helper.subprocess, 'run') as transport:
                        with self.assertRaisesRegex(ValueError, 'size|SHA256'):
                            helper.acquire(self.root, 'aarch64', offline)
                    transport.assert_not_called()
                    self.assertEqual(cached.read_bytes(), poisoned)

    def test_offline_verify_only_does_not_build_or_publish(self):
        helper = self.helper()
        self.asset.rename(self.root / 'bootstrap-aarch64.zip')
        argv = [str(HELPER), '--offline', '--verify-only', '--cache',
                str(self.root), '--output-root', str(self.out.parent), 'aarch64']
        with mock.patch.dict(helper.PINS, {'aarch64': self.pin}), \
                mock.patch('sys.argv', argv), \
                mock.patch.object(helper.subprocess, 'run') as transport, \
                mock.patch.object(helper, 'build') as build, \
                mock.patch('builtins.print') as printed:
            helper.main()
        transport.assert_not_called()
        build.assert_not_called()
        printed.assert_called_once_with('aarch64: pinned upstream verified')
        self.assertFalse(self.out.parent.exists())

    def test_rejected_input_preserves_existing_output_and_manifest(self):
        helper = self.helper()
        helper.build(self.asset, self.out, 'aarch64', self.pin)
        before = self.out.read_bytes()
        manifest = self.out.with_suffix('.manifest.json')
        before_manifest = manifest.read_bytes()
        self.asset.write_bytes(b'x' * self.pin['size'])
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            helper.build(self.asset, self.out, 'aarch64', self.pin)
        self.assertEqual(self.out.read_bytes(), before)
        self.assertEqual(manifest.read_bytes(), before_manifest)


if __name__ == '__main__':
    unittest.main()
