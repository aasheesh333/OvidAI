"""Behavioral regressions for release gates; no signing/Firebase fixtures."""
import importlib.util
import hashlib
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


def elf_segments(loads, relro, alignment=16384):
    # ELF64 with explicit PT_LOAD (vaddr, memsz) rows and one GNU_RELRO (vaddr, memsz).
    count = len(loads) + 1
    data = bytearray(2 * 16384)
    data[:16] = b'\x7fELF\x02\x01\x01' + bytes(9)
    struct.pack_into('<HHIQQQIHHHHHH', data, 16,
                     3, 183, 1, 0, 64, 0, 0, 64, 56, count, 0, 0, 0)
    for i, (vaddr, memsz) in enumerate(loads):
        struct.pack_into('<IIQQQQQQ', data, 64 + 56 * i, 1, 5, vaddr % 16384, vaddr, 0, 0, memsz, alignment)
    struct.pack_into('<IIQQQQQQ', data, 64 + 56 * len(loads), 0x6474e552, 4,
                     0, relro[0], 0, 0, relro[1], 1)
    return bytes(data)


def elf32(machine=40, alignment=16384, relro_end=32768):
    # Minimal ELF32 with independently specified LOAD and GNU_RELRO headers.
    data = bytearray(512)
    data[:16] = b'\x7fELF\x01\x01\x01' + bytes(9)
    struct.pack_into('<HHIIIIIHHHHHH', data, 16,
                     3, machine, 1, 0, 52, 0, 0, 52, 32, 2, 0, 0, 0)
    struct.pack_into('<IIIIIIII', data, 52, 1, 0, 0, 0, 512, 512, 5, alignment)
    struct.pack_into('<IIIIIIII', data, 84, 0x6474e552, 0, 16384, 0, 0,
                     relro_end - 16384, 4, 1)
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
        element('uses-sdk', [('minSdkVersion', '24'), ('targetSdkVersion', str(target))]),
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
        # Shipping the payload is an error now, but its contents are still
        # inspected — an alignment problem inside it must not be hidden.
        self.assertTrue(any('must not ship' in e for e in report['errors']))
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

    def test_alignment_findings_are_classified_by_origin(self):
        bootstrap = archive([('bin/bash', elf(relro_end=28672))])
        report = self.inspect([('lib/arm64-v8a/libovid_bootstrap.so', bootstrap),
                               ('lib/arm64-v8a/libflutter.so', elf(relro_end=28672))])
        summary = report['alignment_summary']
        self.assertEqual(summary['total'], 2)
        self.assertEqual(summary['outer_native_libraries'], 1)
        self.assertEqual(summary['bootstrap_payload_elfs'], 1)
        self.assertTrue(all('libovid_bootstrap.so!' in e
                            for e in report['payload_alignment_errors']))
        self.assertTrue(all(e.startswith('lib/arm64-v8a/libflutter.so:')
                            for e in report['outer_alignment_errors']))

    def test_relro_end_inside_its_load_page_is_not_a_16kb_finding(self):
        # Flutter engine / prebuilt sqlite3 shape: 64-bit LOADs aligned to 16 KB
        # or more, RELRO end only 4 KB aligned but well inside its own LOAD with
        # the next LOAD starting on a later 16 KB page.
        data = elf_segments([(0, 0xad7ef0), (0xae7ef0, 0x5b110), (0xb521e8, 0x107f8)],
                            (0xae7ef0, 0x5b110))
        self.assertEqual(self.gate.elf_inventory(data, 'arm64-v8a')['alignment_errors'], [])

    def test_relro_that_rounds_into_the_next_load_is_still_a_finding(self):
        # RELRO end 0x6000 rounds to 0x8000, which reaches the next LOAD's first
        # 16 KB page (0x8000).
        data = elf_segments([(0, 0x4000), (0x4000, 0x2000), (0x8100, 0x100)],
                            (0x4000, 0x2000))
        errors = self.gate.elf_inventory(data, 'arm64-v8a')['alignment_errors']
        self.assertEqual(errors, [])  # 0x8000 == floor16k(0x8100): still contained
        data = elf_segments([(0, 0x4000), (0x4000, 0x2000), (0x6000, 0x100)],
                            (0x4000, 0x2000))
        errors = self.gate.elf_inventory(data, 'arm64-v8a')['alignment_errors']
        self.assertTrue(any('GNU_RELRO' in e for e in errors))

    def test_relro_outside_every_load_is_a_finding(self):
        data = elf_segments([(0, 0x4000)], (0x4000, 0x1000))
        errors = self.gate.elf_inventory(data, 'arm64-v8a')['alignment_errors']
        self.assertTrue(any('GNU_RELRO' in e for e in errors))

    def test_play_profile_forbids_bootstrap_payload(self):
        lib = ('lib/arm64-v8a/libflutter.so', elf())
        clean = self.gate.inspect_native(io.BytesIO(archive([lib])), 'apk',
                                         {'arm64-v8a'}, 'play')
        self.assertEqual(clean['errors'], [])
        shipped = self.gate.inspect_native(io.BytesIO(archive([
            lib, ('lib/arm64-v8a/libovid_bootstrap.so', archive([('bin/bash', elf())]))])),
            'apk', {'arm64-v8a'}, 'play')
        self.assertTrue(any('must not ship libovid_bootstrap.so' in e for e in shipped['errors']))

    def test_sideload_profile_ships_no_sandbox_payload_either(self):
        # P8 Task 13 removed the on-device sandbox from every channel, so a
        # payload-free APK is the CORRECT shape for sideload too.
        report = self.gate.inspect_native(
            io.BytesIO(archive([('lib/arm64-v8a/libflutter.so', elf())])),
            'apk', {'arm64-v8a'})
        self.assertEqual(report['errors'], [])

    def test_a_sandbox_payload_is_rejected_in_both_profiles(self):
        for profile in (None, 'sideload', 'play'):
            with self.subTest(profile=profile):
                report = self.gate.inspect_native(
                    io.BytesIO(archive([
                        ('lib/arm64-v8a/libflutter.so', elf()),
                        ('lib/arm64-v8a/libovid_bootstrap.so', archive([('bin/bash', elf())])),
                    ])),
                    'apk', {'arm64-v8a'}, profile or 'sideload')
                self.assertTrue(
                    any('must not ship libovid_bootstrap.so' in e for e in report['errors']))

    def test_a_payload_free_build_passes_the_native_gate(self):
        report = self.inspect([('lib/arm64-v8a/libflutter.so', elf())])
        self.assertEqual(report['errors'], [])
        self.assertEqual(report['bootstrap_abis'], [])

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

    def test_unsigned_archive_is_rejected_by_bundle_verifier(self):
        # The verifier must reject an archive whose entries are not signed.
        # Built in a temp dir: the old version pointed at the Termux bootstrap
        # payload, which the cloud migration deleted, so the test only ever
        # passed when a CI step had generated that file first.
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            payload = Path(directory) / 'payload.zip'
            payload.write_bytes(archive([('lib/arm64-v8a/libflutter.so', elf())]))
            result = subprocess.run(['java', str(root / 'tool/release_verify_bundle.java'),
                                     str(payload), '-'],
                                    capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unsigned or multi-signed bundle payload entry', result.stderr)

    def test_aab_native_layout_is_inspected(self):
        data = archive([('base/lib/arm64-v8a/libflutter.so', elf())])
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

    def run_bundle_gate(self, target=36, certificate='a' * 64, mode='production',
                        manifest_target=None, debuggable=None, relro_end=32768,
                        profile=None, bootstrap=False):
        manifest_target = target if manifest_target is None else manifest_target
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / 'fixture.aab'
            output = Path(directory) / 'report.json'
            artifact.write_bytes(archive([
                ('base/manifest/AndroidManifest.xml', manifest_proto(manifest_target, debuggable)),
                ('base/lib/arm64-v8a/libflutter.so', elf(relro_end=relro_end)),
            ] + ([('base/lib/arm64-v8a/libovid_bootstrap.so',
                   archive([('bin/bash', elf(relro_end=relro_end))]))] if bootstrap else [])))
            args = ['release_inventory.py', str(artifact), '--mode', mode,
                    '--expected-abis', 'arm64-v8a', '--expected-target', str(target),
                    '--certificate-sha256', certificate, '--output', str(output)]
            if profile:
                args += ['--profile', profile]
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

    def test_production_alignment_failure_names_elf_remediation(self):
        # A misaligned GNU_RELRO end is an ELF property, not a ZIP-packaging
        # property; the production gate must fail with the rebuild guidance and
        # must not imply that repacking the bootstrap ZIP can fix it.
        code, report = self.run_bundle_gate(relro_end=28672)
        self.assertEqual(code, 1)
        self.assertTrue(any('16 KB alignment' in e for e in report['errors']))
        self.assertIn('alignment_remediation', report)
        summary = report['native']['alignment_summary']
        self.assertEqual(summary['outer_native_libraries'], 1)
        # No sandbox payload ships any more, so there are no payload ELFs.
        self.assertEqual(summary['bootstrap_payload_elfs'], 0)

    def test_production_play_profile_passes_without_bootstrap(self):
        code, report = self.run_bundle_gate(profile='play', bootstrap=False)
        self.assertEqual((code, report['errors']), (0, []))
        self.assertEqual(report['profile'], 'play')

    def test_production_play_profile_rejects_bootstrap_payload(self):
        code, report = self.run_bundle_gate(profile='play', bootstrap=True)
        self.assertEqual(code, 1)
        self.assertTrue(any('must not ship libovid_bootstrap.so' in e for e in report['errors']))

    def test_production_sideload_profile_rejects_a_sandbox_payload(self):
        for profile in (None, 'sideload'):
            with self.subTest(profile=profile):
                code, report = self.run_bundle_gate(profile=profile, bootstrap=True)
                self.assertEqual(code, 1)
                self.assertTrue(
                    any('must not ship libovid_bootstrap.so' in e for e in report['errors']))

    def test_debug_inventory_can_describe_legacy_target(self):
        code, report = self.run_bundle_gate(target=28, certificate='', mode='debug')
        self.assertEqual(code, 0)
        self.assertFalse(report['target_policy']['api36_floor_met'])

    def test_release_candidate_accepts_target_36_non_debug_signed(self):
        # CI's sideload release candidate targets API 36 (EM-001 / CT-017).
        code, report = self.run_bundle_gate(target=36, certificate='a' * 64, mode='release')
        self.assertEqual(code, 0)
        self.assertTrue(report['target_policy']['api36_floor_met'])
        self.assertFalse(report['target_policy']['play_qualified'])

    def test_release_candidate_rejects_a_legacy_artifact_against_the_36_contract(self):
        code, report = self.run_bundle_gate(target=36, certificate='a' * 64,
                                            mode='release', manifest_target=28)
        self.assertEqual(code, 1)
        self.assertTrue(any('inventory contract' in error for error in report['errors']))

    def test_release_candidate_accepts_any_non_debug_signer_without_pin(self):
        code, report = self.run_bundle_gate(target=28, certificate='', mode='release')
        self.assertEqual(code, 0)

    def test_release_candidate_rejects_debuggable_manifest(self):
        code, report = self.run_bundle_gate(target=28, certificate='a' * 64,
                                            mode='release', debuggable=b'\x01')
        self.assertEqual(code, 1)
        self.assertTrue(any('debuggable' in error for error in report['errors']))

    def test_release_candidate_rejects_wrong_target(self):
        code, report = self.run_bundle_gate(target=28, certificate='a' * 64,
                                            mode='release', manifest_target=27)
        self.assertEqual(code, 1)
        self.assertTrue(any('inventory contract' in error for error in report['errors']))

    def test_release_mode_rejects_debug_signer_and_honors_optional_pin(self):
        debug = ('Signer #1 certificate DN: CN=Android Debug, O=Android, C=US\n'
                 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64)
        with self.assertRaisesRegex(ValueError, 'debug'):
            self.gate.check_apk_signer(debug, '', production=False, release=True)
        release = ('Signer #1 certificate DN: CN=Release\n'
                   'Signer #1 certificate SHA-256 digest: ' + 'a' * 64)
        self.assertEqual(self.gate.check_apk_signer(release, '', production=False, release=True),
                         ['a' * 64])
        self.assertEqual(self.gate.check_apk_signer(release, 'a' * 64, production=False, release=True),
                         ['a' * 64])
        with self.assertRaises(ValueError):
            self.gate.check_apk_signer(release, 'b' * 64, production=False, release=True)

    def test_compiled_aapt_boolean_marks_bundle_debuggable(self):
        # XmlAttribute.compiled_item -> Item.prim -> Primitive.boolean_value;
        # AAPT encodes true as either 1 or Android's typed-data 0xffffffff.
        for value, expected in ((b'\x00', False), (b'\x01', True), (b'\xff\xff\xff\xff\x0f', True)):
            with self.subTest(value=value):
                self.assertEqual(self.gate.bundle_manifest(manifest_proto(36, value))['debuggable'], expected)


class BootstrapSupplyAlignmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).with_name('bootstrap_supply.py')
        if path.exists():
            spec = importlib.util.spec_from_file_location('bootstrap_supply', path)
            cls.supply = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.supply)

    def setUp(self):
        self.assertTrue(hasattr(self, 'supply'), 'bootstrap supply tool is not implemented')

    def fixture_build(self, root, *, gawk=True):
        source = root / 'upstream.zip'
        entries = {
            'bin/bash': elf(), 'bin/gpgv': elf(), 'bin/apt': elf(),
            'bin/apt-get': elf(), 'bin/dpkg': elf(), 'bin/diff': elf(),
            'bin/start-stop-daemon': elf(),
            # Dropped by the derivation (documentation/headers only).
            'share/man/man1/bash.1.gz': b'man', 'include/stdio.h': b'header',
            'SYMLINKS.txt': 'gawk←./bin/awk\nbash←./bin/sh\n'.encode(),
            'var/lib/dpkg/status': b'Package: gawk\nStatus: install ok installed\n',
            'share/termux-keyring/fixture.gpg': b'fixture',
            'share/terminfo/x/xterm': b'fixture',
        }
        if gawk:
            entries['bin/gawk'] = elf()
        with zipfile.ZipFile(source, 'w') as z:
            for name, data in entries.items():
                info = zipfile.ZipInfo(name)
                info.external_attr = (0o100755 if name.startswith('bin/') else 0o100644) << 16
                z.writestr(info, data)
        pin = {'size': source.stat().st_size,
               'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
        output = root / 'derived.zip'
        self.supply.build(source, output, 'aarch64', pin)
        return output

    def test_derived_bootstrap_retains_awk_symlink_target_and_repair_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = self.fixture_build(Path(directory))
            with zipfile.ZipFile(output) as z:
                self.assertIn('gawk←./bin/awk', z.read('SYMLINKS.txt').decode())
                self.assertIn('bin/gawk', z.namelist())
                self.assertEqual(z.read('bin/gawk'), elf())
                self.assertEqual((z.getinfo('bin/gawk').external_attr >> 16) & 0o777, 0o755)
                manifest = json.loads(z.read('.ovid-bootstrap-manifest.json'))
                self.assertEqual(manifest['androidAbi'], 'arm64-v8a')
                for name in ('bin/gawk', 'bin/apt', 'bin/apt-get', 'SYMLINKS.txt'):
                    entry = next(e for e in manifest['entries'] if e['path'] == name)
                    self.assertEqual(entry['sha256'], hashlib.sha256(z.read(name)).hexdigest())
                    self.assertEqual(entry['size'], len(z.read(name)))

    def test_derivation_keeps_dpkg_prerequisites_and_drops_only_docs(self):
        # 2026-10-13 emulator repro: the hand-picked subset dropped diff and
        # start-stop-daemon, so every dpkg run aborted with "expected programs
        # not found in PATH".
        with tempfile.TemporaryDirectory() as directory:
            output = self.fixture_build(Path(directory))
            with zipfile.ZipFile(output) as z:
                names = set(z.namelist())
        for kept in ('bin/dpkg', 'bin/diff', 'bin/start-stop-daemon', 'bin/apt-get'):
            self.assertIn(kept, names)
        self.assertNotIn('share/man/man1/bash.1.gz', names)
        self.assertNotIn('include/stdio.h', names)

    def test_vendored_proot_is_merged_and_registered_with_dpkg(self):
        with tempfile.TemporaryDirectory() as directory:
            output = self.fixture_build(Path(directory))
            with zipfile.ZipFile(output) as z:
                names = set(z.namelist())
                status = z.read('var/lib/dpkg/status').decode()
                links = z.read('SYMLINKS.txt').decode()
                proot_list = z.read('var/lib/dpkg/info/proot.list').decode()
                manifest = json.loads(z.read('.ovid-bootstrap-manifest.json'))
        for path in ('bin/proot', 'libexec/proot/loader', 'lib/libtalloc.so.2.5.0',
                     'lib/libandroid-shmem.so'):
            self.assertIn(path, names)
        self.assertIn('libtalloc.so.2.5.0←./lib/libtalloc.so.2', links)
        for package in ('proot', 'libtalloc', 'libandroid-shmem'):
            self.assertRegex(status, rf'Package: {package}\nStatus: install ok installed\n')
        self.assertIn('Package: gawk', status)  # bootstrap entries kept
        self.assertIn('/data/data/com.termux/files/usr/bin/proot', proot_list)
        # Runtime repair verifies SYMLINKS.txt/status against the manifest.
        entry = next(e for e in manifest['entries'] if e['path'] == 'SYMLINKS.txt')
        self.assertEqual(entry['size'], len(links.encode()))

    def test_vendored_deb_pins_are_enforced(self):
        for abi, pins in self.supply.DEB_PINS.items():
            for name, sha in pins.items():
                data = (self.supply.VENDOR / abi / name).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), sha, name)

    def test_missing_gawk_fails_before_derived_output_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'derived.zip').write_bytes(b'previous good payload')
            with self.assertRaisesRegex(ValueError, 'bin/gawk'):
                self.fixture_build(root, gawk=False)
            self.assertEqual((root / 'derived.zip').read_bytes(), b'previous good payload')

    def test_aligned_payload_has_no_findings(self):
        contents = {'bin/bash': (elf(), 0o755), 'lib/libc.so': (elf(), 0o644)}
        self.assertEqual(self.supply.alignment_findings(contents, 'arm64-v8a'), [])

    def test_misaligned_relro_is_reported_per_member_and_skips_non_elf(self):
        contents = {'bin/bash': (elf(relro_end=28672), 0o755),
                    'bin/dash': (elf(), 0o755),
                    'share/terminfo/x': (b'not-elf', 0o644)}
        findings = self.supply.alignment_findings(contents, 'arm64-v8a')
        self.assertEqual([f['path'] for f in findings], ['bin/bash'])
        self.assertIn('GNU_RELRO', findings[0]['error'])

    def test_arm32_payload_stays_inventory_only(self):
        contents = {'bin/bash': (elf32(relro_end=28672), 0o755)}
        self.assertEqual(self.supply.alignment_findings(contents, 'armeabi-v7a'), [])

    def run_supply(self, argv, findings):
        manifest = {'output': {'sha256': 'x'}, 'alignment_findings': findings}
        with patch.object(self.supply, 'acquire', return_value=Path('/tmp/asset')), \
                patch.object(self.supply, 'build', return_value=manifest), \
                patch('sys.argv', ['bootstrap_supply.py', *argv]), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return self.supply.main()

    def test_require_16kb_fails_closed_on_findings(self):
        findings = [{'path': 'bin/bash', 'error': 'GNU_RELRO end is not 16 KB aligned'}]
        self.assertEqual(self.run_supply(['aarch64', '--require-16kb'], findings), 1)
        self.assertEqual(self.run_supply(['aarch64'], findings), 0)

    def test_require_16kb_passes_clean_payload(self):
        self.assertEqual(self.run_supply(['aarch64', '--require-16kb'], []), 0)


if __name__ == '__main__':
    unittest.main()
