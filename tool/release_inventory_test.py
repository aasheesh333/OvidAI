"""Behavioral regressions for release gates; no signing/Firebase fixtures."""
import importlib.util
import contextlib
import io
import json
import struct
import tempfile
import unittest
import subprocess
import zipfile
from pathlib import Path
from unittest.mock import patch


def elf(machine=183, alignment=16384, relro_end=32768):
    # Minimal ELF64 with independently specified LOAD and GNU_RELRO headers.
    data = bytearray(512)
    data[:16] = b'\x7fELF\x02\x01\x01' + bytes(9)
    struct.pack_into('<HHIQQQIHHHHHH', data, 16,
                     3, machine, 1, 0, 64, 0, 0, 64, 56, 2, 0, 0, 0)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0, 0, 512, 512, alignment)
    struct.pack_into('<IIQQQQQQ', data, 120, 0x6474e552, 4,
                     0, 16384, 0, 0, relro_end - 16384, 1)
    return bytes(data)


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as z:
        for name, value in entries:
            z.writestr(name, value)
    return output.getvalue()


def manifest_proto(target, compiled_debuggable=None):
    # AAPT Resources.proto XmlNode/XmlElement/XmlAttribute wire format.
    def field(number, value):
        length = len(value)
        size = bytes([length]) if length < 128 else bytes([(length & 127) | 128, length >> 7])
        return bytes([number * 8 + 2]) + size + value

    def element(name, attrs=(), children=()):
        body = field(3, name.encode())
        for key, value in attrs:
            body += field(4, field(2, key.encode()) + field(3, value.encode()))
        if name == 'application' and compiled_debuggable is not None:
            body += field(4, field(2, b'debuggable') + field(6, field(7, b'\x40' + compiled_debuggable)))
        for child in children:
            body += field(5, child)
        return field(1, body)

    return element('manifest', [('package', 'com.dhanuk.ovidai')], [
        element('uses-sdk', [('minSdkVersion', '23'), ('targetSdkVersion', str(target))]),
        element('application'),
    ])


class ReleaseInventoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).with_name('release_inventory.py')
        if path.exists():
            spec = importlib.util.spec_from_file_location('inventory', path)
            cls.gate = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.gate)

    def setUp(self):
        self.assertTrue(hasattr(self, 'gate'), 'release artifact gate is not implemented')

    def inspect(self, entries, abis=('arm64-v8a',)):
        return self.gate.inspect_native(io.BytesIO(archive(entries)), 'apk', set(abis))

    def test_archive_so_is_not_elf_but_nested_elf_is_checked(self):
        bootstrap = archive([('bin/bash', elf(relro_end=28672))])
        report = self.inspect([('lib/arm64-v8a/libovid_bootstrap.so', bootstrap),
                               ('lib/arm64-v8a/libflutter.so', elf())])
        self.assertEqual(report['errors'], [])
        self.assertEqual(report['entries'][0]['kind'], 'bootstrap_zip')
        self.assertEqual(report['entries'][0]['elf_count'], 1)
        self.assertTrue(any('GNU_RELRO' in e for e in report['alignment_errors']))

    def test_rejects_wrong_machine_and_missing_abi(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', elf(machine=62))],
                              ('arm64-v8a', 'x86_64'))
        self.assertTrue(any('machine' in e for e in report['errors']))
        self.assertTrue(any('x86_64' in e for e in report['errors']))

    def test_rejects_arbitrary_zip_disguised_as_library(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', archive([('x', b'x')]))])
        self.assertTrue(any('ELF' in e for e in report['errors']))

    def test_rejects_bootstrap_with_no_elf(self):
        report = self.inspect([('lib/arm64-v8a/libovid_bootstrap.so', archive([('x', b'x')]))])
        self.assertTrue(any('no ELF' in e for e in report['errors']))

    def test_rejects_truncated_elf(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', b'\x7fELF')])
        self.assertTrue(report['errors'])

    def test_checks_load_alignment_independently_of_relro(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', elf(alignment=4096))])
        self.assertTrue(any('PT_LOAD' in e for e in report['alignment_errors']))

    def test_requires_bootstrap_for_each_delivered_abi(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', elf())])
        self.assertTrue(any('bootstrap' in e for e in report['errors']))

    def test_plugin_elf_alone_cannot_claim_a_working_flutter_abi(self):
        report = self.inspect([('lib/arm64-v8a/libplugin.so', elf()),
                               ('lib/arm64-v8a/libovid_bootstrap.so', archive([('bin/bash', elf())]))])
        self.assertTrue(any('libflutter.so' in e for e in report['errors']))

    def test_debug_certificate_cannot_be_approved_by_matching_fingerprint(self):
        text = ('Signer #1 certificate DN: CN=Android Debug, O=Android, C=US\n'
                'Signer #1 certificate SHA-256 digest: ' + 'a' * 64)
        with self.assertRaisesRegex(ValueError, 'debug'):
            self.gate.check_apk_signer(text, 'a' * 64, production=True)

    def test_wrong_or_missing_production_certificate_is_rejected(self):
        text = ('Signer #1 certificate DN: CN=Release\n'
                'Signer #1 certificate SHA-256 digest: ' + 'a' * 64)
        for expected in ('b' * 64, ''):
            with self.assertRaises(ValueError):
                self.gate.check_apk_signer(text, expected, production=True)

    def test_matching_non_debug_signer_is_accepted(self):
        text = ('Signer #1 certificate DN: CN=Release\n'
                'Signer #1 certificate SHA-256 digest: ' + 'a' * 64)
        self.assertEqual(self.gate.check_apk_signer(text, 'a' * 64, True), ['a' * 64])

    def test_actual_apk_manifest_with_installed_aapt2(self):
        root = Path(__file__).resolve().parents[1]
        apk = root / 'build/app/outputs/flutter-apk/app-release.apk'
        tools = Path('/opt/android-sdk/build-tools/36.0.0')
        if not apk.exists() or not tools.exists():
            self.skipTest('local reference APK/SDK not available')
        report = self.gate.apk_manifest(apk, tools)
        self.assertEqual(report['package'], 'com.dhanuk.ovidai')
        self.assertGreaterEqual(report['min_sdk'], 23)
        self.assertGreaterEqual(report['target_sdk'], report['min_sdk'])

    def test_unsigned_real_bootstrap_is_rejected_by_bundle_verifier(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(['java', str(root / 'tool/release_verify_bundle.java'),
                                 str(root / 'android/app/src/main/jniLibs/arm64-v8a/libovid_bootstrap.so'), '-'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unsigned or multi-signed bundle payload entry', result.stderr)

    def test_aab_native_layout_is_inspected(self):
        data = archive([('base/lib/arm64-v8a/libflutter.so', elf()),
                        ('base/lib/arm64-v8a/libovid_bootstrap.so', archive([('bin/bash', elf())]))])
        report = self.gate.inspect_native(io.BytesIO(data), 'aab', {'arm64-v8a'})
        self.assertEqual(report['errors'], [])
        self.assertEqual(report['alignment_errors'], [])

    def test_duplicate_library_members_are_rejected(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                self.inspect([('lib/arm64-v8a/libflutter.so', elf()),
                              ('lib/arm64-v8a/libflutter.so', elf())])

    def run_bundle_gate(self, target=36, certificate='a' * 64, mode='production'):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / 'fixture.aab'
            output = Path(directory) / 'report.json'
            artifact.write_bytes(archive([
                ('base/manifest/AndroidManifest.xml', manifest_proto(target)),
                ('base/lib/arm64-v8a/libflutter.so', elf()),
                ('base/lib/arm64-v8a/libovid_bootstrap.so', archive([('bin/bash', elf())])),
            ]))
            args = ['release_inventory.py', str(artifact), '--mode', mode,
                    '--expected-abis', 'arm64-v8a', '--expected-target', str(target),
                    '--certificate-sha256', certificate, '--output', str(output)]
            # Only signature verification is substituted: no test signing keys.
            with patch('sys.argv', args), patch.object(self.gate, 'command', return_value=json.dumps(['a' * 64])), contextlib.redirect_stdout(io.StringIO()):
                code = self.gate.main()
            return code, json.loads(output.read_text())

    def test_production_floor_cannot_be_lowered_with_expected_target(self):
        code, report = self.run_bundle_gate(target=28)
        self.assertEqual(code, 1)
        self.assertTrue(any('API 36' in error for error in report['errors']))
        self.assertFalse(report['target_policy']['api36_floor_met'])

    def test_production_bundle_rejects_missing_or_debug_sentinel_certificate(self):
        for certificate in ('', '-', 'invalid'):
            with self.subTest(certificate=certificate):
                code, report = self.run_bundle_gate(certificate=certificate)
                self.assertEqual(code, 1)
                self.assertTrue(any('certificate SHA-256' in error for error in report['errors']))

    def test_modern_target_passes_static_gate_but_never_claims_play_qualification(self):
        code, report = self.run_bundle_gate()
        self.assertEqual(code, 0)
        self.assertTrue(report['target_policy']['api36_floor_met'])
        self.assertFalse(report['target_policy']['play_qualified'])

    def test_debug_inventory_can_describe_legacy_target(self):
        code, report = self.run_bundle_gate(target=28, certificate='', mode='debug')
        self.assertEqual(code, 0)
        self.assertFalse(report['target_policy']['api36_floor_met'])

    def test_compiled_aapt_boolean_marks_bundle_debuggable(self):
        # XmlAttribute.compiled_item -> Item.prim -> Primitive.boolean_value;
        # AAPT encodes true as either 1 or Android's typed-data 0xffffffff.
        for value, expected in ((b'\x00', False), (b'\x01', True), (b'\xff\xff\xff\xff\x0f', True)):
            with self.subTest(value=value):
                self.assertEqual(self.gate.bundle_manifest(manifest_proto(36, value))['debuggable'], expected)


if __name__ == '__main__':
    unittest.main()
