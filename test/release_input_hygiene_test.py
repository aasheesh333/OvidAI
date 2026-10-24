#!/usr/bin/env python3
"""Release-input tests use only synthetic fixtures, never real credentials."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
WRAPPERS = (
    'android/gradle/wrapper/gradle-wrapper.jar',
    'android/gradlew',
    'android/gradlew.bat',
)
SECRETS = {
    'release-keystore.jks': 'android/release-keystore.jks',
    'keystore.properties': 'android/keystore.properties',
    'google-services.json': 'android/app/google-services.json',
}
REQUIRED_DEFINES = ('OVID_APPCHECK=false', 'OVID_PRODUCTION=true')
PLAY_OVERLAY_MARKER = 'google_analytics_adid_collection_enabled'


def manifest_proto(*, play_overlay=False):
    """Minimal AAPT XmlNode fixture with an optional real Play-only marker."""
    def field(number, value):
        length = len(value)
        size = (bytes([length]) if length < 128 else
                bytes([(length & 127) | 128, length >> 7]))
        return bytes([number * 8 + 2]) + size + value

    def element(name, attrs=(), children=()):
        body = field(3, name.encode())
        for key, value in attrs:
            body += field(4, field(2, key.encode()) + field(3, value.encode()))
        for child in children:
            body += field(5, child)
        return field(1, body)

    application_children = []
    if play_overlay:
        application_children.append(element(
            'meta-data', [('name', PLAY_OVERLAY_MARKER), ('value', 'false')]))
    return element('manifest', [('package', 'com.dhanuk.ovidai')], [
        element('uses-sdk', [('minSdkVersion', '24'), ('targetSdkVersion', '36')]),
        element('application', children=application_children),
    ])


def make_fixture(root, *, wrappers=True, secrets=True, ignores=True):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    # Authoritative Git checks use the real object database read-only, with the
    # temp fixture as work-tree. No repository/index/history mutation occurs.
    (root / '.git').write_text(f'gitdir: {ROOT / ".git"}\n')
    if wrappers:
        jar = root / WRAPPERS[0]
        jar.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(jar, 'w') as archive:
            archive.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n')
            archive.writestr('org/gradle/wrapper/GradleWrapperMain.class', b'fixture')
        (root / WRAPPERS[1]).write_text(
            '#!/bin/sh\n'
            'if [ -n "${FIXTURE_GRADLE_LOG:-}" ]; then\n'
            '  printf "%s\\n" "$*" > "$FIXTURE_GRADLE_LOG"\n'
            'fi\n'
            'exit 0\n')
        (root / WRAPPERS[2]).write_bytes(b'@echo off\r\nexit /b 0\r\n')
        (root / WRAPPERS[1]).chmod(0o755)
        (root / WRAPPERS[2]).chmod(0o644)
    if secrets:
        for relative in SECRETS.values():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            # Invalid UTF-8 plus a canary proves verification needs metadata only.
            path.write_bytes(b'\xff\x00secret-canary-do-not-print')
            path.chmod(0o600)
    if ignores:
        (root / '.gitignore').write_text(
            'android/app/google-services.json\n'
            'google-services.json\n'
            'android/keystore.properties\n'
            'android/release-keystore.jks\n'
            '*.jks\n'
            '*.keystore\n'
            'keystore.properties\n'
        )
        android = root / 'android'
        android.mkdir(exist_ok=True)
        (android / '.gitignore').write_text(
            'gradle-wrapper.jar\n'
            '/gradlew\n'
            '/gradlew.bat\n'
            '!/gradle/wrapper/gradle-wrapper.jar\n'
            '!/gradlew\n'
            '!/gradlew.bat\n'
            'key.properties\n'
            '**/*.keystore\n'
            '**/*.jks\n'
        )
    return root


class ReleaseInputHygieneTest(unittest.TestCase):
    def setUp(self):
        try:
            from tool import release_input_hygiene
        except ImportError:
            release_input_hygiene = None
        self.hygiene = release_input_hygiene
        self.assertIsNotNone(self.hygiene, 'release input hygiene helper is not implemented')

    def fixture_pair(self, directory, **kwargs):
        self.original = make_fixture(Path(directory) / 'original', **kwargs)
        self.dest = make_fixture(Path(directory) / 'destination', wrappers=False, **kwargs)

    def script_fixture(self, directory):
        root = Path(directory)
        repo = make_fixture(root / 'repo')
        tools = repo / 'tool'
        tools.mkdir()
        for name in ('release_sideload.sh', 'release_input_hygiene.py'):
            shutil.copy2(ROOT / 'tool' / name, tools / name)
        fake_bin = root / 'bin'
        fake_bin.mkdir()
        (fake_bin / 'flutter').write_text(
            '#!/usr/bin/env bash\n'
            'printf "called\\n" >> "$FIXTURE_BUILD_CALLS"\n'
            'profile="$(printenv ORG_GRADLE_PROJECT_ovid.play 2>/dev/null || true)"\n'
            'printf "ORG_GRADLE_PROJECT_ovid.play=%s\\n" '
            '"$profile" > "$FIXTURE_FLUTTER_ENV"\n'
            'printf "GRADLE_OPTS=%s\\n" "${GRADLE_OPTS:-}" '
            '>> "$FIXTURE_FLUTTER_ENV"\n'
            'exit 97\n')
        (fake_bin / 'flutter').chmod(0o755)
        return repo, fake_bin

    def run_sideload_fixture(self, repo, fake_bin, directory, *, extra_env=None,
                             evidence_path=None):
        root = Path(directory)
        env = {
            'PATH': f'{fake_bin}:/usr/local/bin:/usr/bin:/bin',
            'HOME': str(root),
            'ANDROID_SIGNING_CERT_SHA256': 'a' * 64,
            'FIXTURE_BUILD_CALLS': str(root / 'build-calls'),
            'FIXTURE_FLUTTER_ENV': str(root / 'flutter-env'),
            'FIXTURE_GRADLE_LOG': str(root / 'gradle-args'),
        }
        if extra_env:
            env.update(extra_env)
        return subprocess.run([
            'bash', str(repo / 'tool/release_sideload.sh'),
            '--apk-out', str(root / 'fresh-output.apk'),
            '--evidence-out', str(evidence_path or (root / 'evidence')),
        ], cwd=repo, env=env, capture_output=True, text=True, timeout=30)

    def test_restored_wrapper_must_match_original_and_secrets_stay_ignored_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                report = self.hygiene.verify_release_inputs(
                    original=self.original, destination=self.dest)
            self.assertTrue(report.wrapper_integrity, report.errors)
            self.assertTrue(report.passed, report.errors)
            self.assertEqual(report.secret_modes, {
                'release-keystore.jks': 0o600,
                'keystore.properties': 0o600,
                'google-services.json': 0o600,
            })
            self.assertEqual(report.secret_ignores, {
                'release-keystore.jks': True,
                'keystore.properties': True,
                'google-services.json': True,
            })
            self.assertNotIn('secret-canary', stdout.getvalue() + stderr.getvalue())
            for relative in WRAPPERS:
                self.assertEqual((self.original / relative).read_bytes(),
                                 (self.dest / relative).read_bytes())
                self.assertEqual(stat.S_IMODE((self.original / relative).stat().st_mode),
                                 stat.S_IMODE((self.dest / relative).stat().st_mode))

    def test_checksum_mismatch_fails_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            (self.dest / WRAPPERS[1]).write_text('#!/bin/sh\nexit 99\n')
            report = self.hygiene.verify_release_inputs(self.original, self.dest)
            self.assertFalse(report.wrapper_integrity)
            self.assertFalse(report.passed)
            self.assertTrue(any('hash' in error for error in report.errors))

    def test_restore_never_overwrites_different_destination_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            destination = self.dest / WRAPPERS[1]
            destination.write_text('different local wrapper\n')
            with self.assertRaises(self.hygiene.ReleaseInputError):
                self.hygiene.restore_release_wrapper(self.original, self.dest)
            self.assertEqual(destination.read_text(), 'different local wrapper\n')
            self.assertFalse((self.dest / WRAPPERS[0]).exists(),
                             'a refused preflight must not partially restore other files')

    def test_restore_rejects_invalid_original_jar_structure(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            with zipfile.ZipFile(self.original / WRAPPERS[0], 'w') as archive:
                archive.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n')
            with self.assertRaises(self.hygiene.ReleaseInputError):
                self.hygiene.restore_release_wrapper(self.original, self.dest)
            self.assertFalse((self.dest / WRAPPERS[0]).exists())

    def test_missing_original_wrapper_is_a_verification_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            (self.original / WRAPPERS[1]).unlink()
            report = self.hygiene.verify_release_inputs(self.original, self.dest)
            self.assertFalse(report.wrapper_integrity)
            self.assertFalse(report.passed)

    def test_secret_wrong_mode_is_rejected_without_reading_values(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            for name, relative in SECRETS.items():
                with self.subTest(secret=name):
                    path = self.dest / relative
                    path.chmod(0o644)
                    report = self.hygiene.verify_release_inputs(self.original, self.dest)
                    self.assertFalse(report.passed)
                    self.assertEqual(report.secret_modes[name], 0o644)
                    self.assertTrue(any(name in error and '0600' in error
                                        for error in report.errors))
                    path.chmod(0o600)

    def test_secret_ignore_rule_is_mandatory(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            ignore = self.dest / '.gitignore'
            android_ignore = self.dest / 'android/.gitignore'
            original_rules = ignore.read_text()
            original_android_rules = android_ignore.read_text()
            for name in SECRETS:
                with self.subTest(secret=name):
                    if name == 'google-services.json':
                        retained = [line for line in original_rules.splitlines()
                                    if 'google-services.json' not in line]
                    elif name == 'keystore.properties':
                        retained = [line for line in original_rules.splitlines()
                                    if 'keystore.properties' not in line]
                    else:
                        retained = [line for line in original_rules.splitlines()
                                    if 'jks' not in line and '*.keystore' != line]
                        android_ignore.write_text('\n'.join(
                            line for line in original_android_rules.splitlines()
                            if 'jks' not in line and '*.keystore' not in line) + '\n')
                    ignore.write_text('\n'.join(retained) + '\n')
                    report = self.hygiene.verify_release_inputs(self.original, self.dest)
                    self.assertFalse(report.passed)
                    self.assertFalse(report.secret_ignores[name])
                    self.assertTrue(any(name in error and 'ignored' in error
                                        for error in report.errors))
                    ignore.write_text(original_rules)
                    android_ignore.write_text(original_android_rules)

    def test_git_ignore_differential_spaces_negation_directories_and_absolute_paths(self):
        cases = (
            ('leading space is significant', ' android/release-keystore.jks\n',
             'android/release-keystore.jks', False, False),
            ('unescaped trailing spaces are stripped', 'android/release-keystore.jks   \n',
             'android/release-keystore.jks', True, False),
            ('escaped trailing space is significant', 'credential\\ \n',
             'credential ', True, False),
            ('escaped leading space is significant', '\\ credential\n',
             ' credential', True, False),
            ('negation reincludes a file', '*.jks\n!release-keystore.jks\n',
             'release-keystore.jks', False, False),
            ('directory rule includes descendants', 'secrets/\n',
             'secrets/nested/credential.json', True, False),
            ('excluded parent cannot be reincluded', 'secrets/\n!secrets/credential.json\n',
             'secrets/credential.json', True, False),
            ('absolute path inside work-tree', 'android/release-keystore.jks\n',
             'android/release-keystore.jks', True, True),
        )
        for label, rules, relative, expected, absolute in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = make_fixture(directory, wrappers=False, secrets=False, ignores=False)
                (root / '.gitignore').write_text(rules)
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b'fixture')
                argument = str(target) if absolute else relative
                oracle = subprocess.run([
                    'git', '-C', str(root), 'check-ignore', '--no-index', '-q', '--', argument,
                ], capture_output=True, text=True, timeout=30)
                self.assertEqual(oracle.returncode, 0 if expected else 1,
                                 (label, oracle.stderr))
                self.assertEqual(self.hygiene.is_ignored(root, argument), expected, label)

    def test_verify_does_not_certify_a_leading_space_as_a_secret_ignore(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            (self.dest / '.gitignore').write_text(' android/release-keystore.jks\n')
            (self.dest / 'android/.gitignore').write_text(
                'gradle-wrapper.jar\n/gradlew\n/gradlew.bat\n'
                '!/gradle/wrapper/gradle-wrapper.jar\n!/gradlew\n!/gradlew.bat\n')
            report = self.hygiene.verify_release_inputs(self.original, self.dest)
            self.assertFalse(report.secret_ignores['release-keystore.jks'])
            self.assertFalse(report.passed)

    def test_wrapper_files_must_be_unignored(self):
        with tempfile.TemporaryDirectory() as directory:
            self.fixture_pair(directory)
            self.hygiene.restore_release_wrapper(self.original, self.dest)
            android_ignore = self.dest / 'android/.gitignore'
            android_ignore.write_text('gradle-wrapper.jar\n/gradlew\n/gradlew.bat\n')
            report = self.hygiene.verify_release_inputs(self.original, self.dest)
            self.assertFalse(report.passed)
            self.assertTrue(any('not ignored' in error for error in report.errors))

    def test_build_defines_require_production_and_app_check_off(self):
        self.hygiene.validate_release_defines(REQUIRED_DEFINES)
        self.hygiene.validate_release_defines(
            '--dart-define=' + define for define in REQUIRED_DEFINES)
        for defines in (
            REQUIRED_DEFINES[:1],
            ('OVID_APPCHECK=true', 'OVID_PRODUCTION=true'),
            ('OVID_APPCHECK=false', 'OVID_PRODUCTION=false'),
            ('OVID_APPCHECK=false', 'OVID_PRODUCTION=true', 'OVID_PRODUCTION=false'),
        ):
            with self.subTest(defines=defines), self.assertRaises(ValueError):
                self.hygiene.validate_release_defines(defines)

    def test_forbidden_demo_login_bypass_play_and_test_store_defines_are_rejected(self):
        forbidden = (
            'OVID_BILLING_DEMO=true',
            'OVID_BILLING_DEMO=false',
            'OVID_E2E_SKIP_LOGIN=true',
            'OVID_LOGIN_BYPASS=true',
            'OVID_AUTH_LOGIN_BYPASS=true',
            'OVID_PLAY_BUILD=true',
            'OVID_PLAY_BUILD=false',
            'OVID_REVENUECAT_TEST_STORE=true',
            'OVID_REVENUECAT_TEST_STORE_KEY=do-not-print-this-value',
        )
        for define in forbidden:
            with self.subTest(define=define):
                with self.assertRaises(ValueError) as caught:
                    self.hygiene.validate_release_defines((*REQUIRED_DEFINES, define))
                self.assertNotIn('do-not-print-this-value', str(caught.exception))

    def test_build_environment_rejects_nonempty_forbidden_inputs(self):
        env = {'OVID_APPCHECK': 'false', 'OVID_PRODUCTION': 'true',
               'OVID_PLAY_BUILD': 'true'}
        with self.assertRaises(ValueError):
            self.hygiene.validate_build_environment(env)
        self.hygiene.validate_build_environment({
            'OVID_APPCHECK': 'false', 'OVID_PRODUCTION': 'true',
            'OVID_BILLING_DEMO': '',
        })

    def test_non_apk_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            disguised = root / 'disguised.apk'
            disguised.write_text('not an APK')
            with self.assertRaises(ValueError):
                self.hygiene.validate_apk_output(disguised)
            wrong_suffix = root / 'artifact.aab'
            with zipfile.ZipFile(wrong_suffix, 'w') as archive:
                archive.writestr('AndroidManifest.xml', b'manifest')
                archive.writestr('classes.dex', b'dex')
            with self.assertRaises(ValueError):
                self.hygiene.validate_apk_output(wrong_suffix)
            valid_shape = root / 'app-release.apk'
            with zipfile.ZipFile(valid_shape, 'w') as archive:
                archive.writestr('AndroidManifest.xml', b'manifest')
                archive.writestr('classes.dex', b'dex')
            self.hygiene.validate_apk_output(valid_shape)

    def test_existing_evidence_symlink_cannot_be_truncated_by_release_script(self):
        canary = b'existing-target-must-not-change\n'
        for evidence_kind in ('directory', 'symlink-directory'):
            with self.subTest(kind=evidence_kind), tempfile.TemporaryDirectory() as directory:
                repo, fake_bin = self.script_fixture(directory)
                root = Path(directory)
                target = root / 'target.json'
                target.write_bytes(canary)
                actual_evidence = root / 'actual-evidence'
                actual_evidence.mkdir()
                (actual_evidence / 'release-inputs.json').symlink_to(target)
                if evidence_kind == 'directory':
                    evidence = actual_evidence
                else:
                    evidence = root / 'evidence'
                    evidence.symlink_to(actual_evidence, target_is_directory=True)
                result = self.run_sideload_fixture(
                    repo, fake_bin, root, evidence_path=evidence)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_bytes(), canary)
                self.assertFalse((root / 'build-calls').exists(),
                                 'unsafe evidence must fail before any build command')

    def test_inventory_output_never_overwrites_existing_file_or_symlink_target(self):
        canary = b'inventory-target-must-not-change\n'
        for output_kind in ('existing-file', 'symlink'):
            with self.subTest(kind=output_kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / 'target.json'
                target.write_bytes(canary)
                output = root / 'release-inventory.json'
                if output_kind == 'symlink':
                    output.symlink_to(target)
                else:
                    output.write_bytes(canary)
                    target = output
                result = subprocess.run([
                    'python3', str(ROOT / 'tool/release_inventory.py'),
                    str(root / 'missing.apk'), '--mode', 'production',
                    '--profile', 'sideload', '--expected-target', '36',
                    '--expected-abis', 'x86_64', '--certificate-sha256', 'a' * 64,
                    '--output', str(output),
                ], cwd=ROOT, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_bytes(), canary)
                if output_kind == 'symlink':
                    self.assertTrue(output.is_symlink())

    def launcher_fixture(self, directory):
        root = Path(directory)
        root.mkdir(exist_ok=True)
        android = root / 'android'
        wrapper = android / 'gradle/wrapper'
        wrapper.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / 'android/gradlew', android / 'gradlew')
        shutil.copy2(ROOT / 'android/gradle/wrapper/gradle-wrapper.jar',
                     wrapper / 'gradle-wrapper.jar')
        java_home = root / 'fake-jdk'
        (java_home / 'bin').mkdir(parents=True)
        (java_home / 'bin/java').write_text(
            '#!/usr/bin/env bash\n'
            'printf "call\\n" >> "$FIXTURE_JAVA_CALLS"\n'
            'printf "<%s>\\n" "$@" > "$FIXTURE_JAVA_ARGS"\n'
            'printf "JAVA_OPTS=%s\\nGRADLE_OPTS=%s\\n" '
            '"${JAVA_OPTS:-}" "${GRADLE_OPTS:-}" > "$FIXTURE_JAVA_ENV"\n'
            'exit 0\n')
        (java_home / 'bin/java').chmod(0o755)
        return android, java_home

    def launcher_environment(self, root, java_home):
        root = Path(root)
        return {
            'PATH': f'{root / "bin"}:/usr/local/bin:/usr/bin:/bin',
            'HOME': str(root),
            'JAVA_HOME': str(java_home),
            'FIXTURE_JAVA_CALLS': str(root / 'java-calls'),
            'FIXTURE_JAVA_ARGS': str(root / 'java-args'),
            'FIXTURE_JAVA_ENV': str(root / 'java-env'),
            'GRADLE_OPTS': '-Dorg.gradle.project.ovid.play=true',
            'JAVA_OPTS': '-Dorg.gradle.project.ovid.play=true',
        }

    def test_actual_gradlew_launcher_neutralizes_jvm_option_injection(self):
        canary = b'launcher-canary-must-not-exist\n'
        cases = (
            ('GRADLE_OPTS', '-Dorg.gradle.project.ovid.play=true #'),
            ('JAVA_OPTS', '-Dorg.gradle.project.ovid.play=true #'),
            ('GRADLE_OPTS', '-Dorg.gradle.project.ovid.play=true ; : > "$CANARY"'),
            ('JAVA_OPTS', '-Dorg.gradle.project.ovid.play=true ; : > "$CANARY"'),
            ('GRADLE_OPTS', '-Dorg.gradle.project.ovid.play=true $(: > "$CANARY")'),
            ('JAVA_OPTS', '-Dorg.gradle.project.ovid.play=true $(: > "$CANARY")'),
            ('GRADLE_OPTS', '-Dorg.gradle.project.ovid.play=true `: > "$CANARY"`'),
            ('JAVA_OPTS', '-Dorg.gradle.project.ovid.play=true `: > "$CANARY"`'),
        )
        for option_name, injected in cases:
            with self.subTest(option=option_name, injected=injected), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                android, java_home = self.launcher_fixture(root)
                env = self.launcher_environment(root, java_home)
                env[option_name] = injected
                env['CANARY'] = str(root / 'canary')
                # The release script replaces both inherited option strings;
                # this is the sanitized environment at the real launcher edge.
                env['JAVA_OPTS'] = ''
                env['GRADLE_OPTS'] = '-Dorg.gradle.project.ovid.play=false'
                result = subprocess.run(
                    [str(android / 'gradlew'), '-Povid.play=false', '--version'],
                    cwd=android, env=env, capture_output=True, text=True, timeout=30)
                self.assertFalse((root / 'canary').exists(),
                                 (option_name, injected, result.stdout, result.stderr))
                self.assertEqual(result.returncode, 0, result.stderr)
                args = (root / 'java-args').read_text().splitlines()
                play_properties = [arg for arg in args
                                   if 'org.gradle.project.ovid.play=' in arg]
                self.assertTrue(play_properties, args)
                self.assertEqual(play_properties[-1],
                                 '<-Dorg.gradle.project.ovid.play=false>')

    def test_release_script_fixed_jvm_options_reach_both_launcher_boundaries(self):
        inherited = (
            '-Dorg.gradle.project.ovid.play=true '
            '-Duser.language=en '
            '# ; : > "$CANARY" $(: > "$CANARY") `: > "$CANARY"`'
        )
        for variable in ('GRADLE_OPTS', 'JAVA_OPTS'):
            with self.subTest(boundary='signing', inherited=variable), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo, fake_bin = self.script_fixture(root)
                android, java_home = self.launcher_fixture(repo)
                env = self.launcher_environment(root, java_home)
                env.update({
                    'ANDROID_SIGNING_CERT_SHA256': 'a' * 64,
                    'CANARY': str(root / 'canary'),
                    variable: inherited,
                })
                result = self.run_sideload_fixture(
                    repo, fake_bin, root, extra_env=env)
                self.assertEqual(result.returncode, 97, result.stderr)
                self.assertFalse((root / 'canary').exists())
                args = (root / 'java-args').read_text().splitlines()
                self.assertIn('<-Povid.play=false>', args)
                self.assertEqual(
                    [arg for arg in args if 'org.gradle.project.ovid.play=' in arg],
                    ['<-Dorg.gradle.project.ovid.play=false>'])

            with self.subTest(boundary='flutter', inherited=variable), \
                    tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                repo, fake_bin = self.script_fixture(root)
                android, java_home = self.launcher_fixture(repo)
                (fake_bin / 'flutter').write_text(
                    '#!/usr/bin/env bash\n'
                    '"' + str(android / 'gradlew') + '" -Povid.play=false --version\n'
                    'exit 97\n')
                (fake_bin / 'flutter').chmod(0o755)
                env = self.launcher_environment(root, java_home)
                env.update({
                    'ANDROID_SIGNING_CERT_SHA256': 'a' * 64,
                    'FIXTURE_BUILD_CALLS': str(root / 'build-calls'),
                    'FIXTURE_FLUTTER_ENV': str(root / 'flutter-env'),
                    'CANARY': str(root / 'canary'),
                    variable: inherited,
                })
                result = self.run_sideload_fixture(
                    repo, fake_bin, root, extra_env=env)
                self.assertEqual(result.returncode, 97, result.stderr)
                self.assertFalse((root / 'canary').exists())
                args = (root / 'java-args').read_text().splitlines()
                self.assertEqual(
                    [arg for arg in args if 'org.gradle.project.ovid.play=' in arg],
                    ['<-Dorg.gradle.project.ovid.play=false>'])

    def test_external_play_property_is_overridden_for_gradle_and_flutter(self):
        cases = (
            ('inherited-project-property', {'ORG_GRADLE_PROJECT_ovid.play': 'true'}, False),
            ('gradle-user-home-property', {}, True),
        )
        for label, extra_env, gradle_home_property in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                repo, fake_bin = self.script_fixture(directory)
                root = Path(directory)
                if gradle_home_property:
                    gradle_home = root / 'gradle-home'
                    gradle_home.mkdir()
                    (gradle_home / 'gradle.properties').write_text('ovid.play=true\n')
                    extra_env['GRADLE_USER_HOME'] = str(gradle_home)
                result = self.run_sideload_fixture(
                    repo, fake_bin, root, extra_env=extra_env)
                self.assertEqual(result.returncode, 97, result.stderr)
                gradle_args = (root / 'gradle-args').read_text()
                self.assertIn('-Povid.play=false', gradle_args)
                flutter_env = (root / 'flutter-env').read_text()
                self.assertIn('ORG_GRADLE_PROJECT_ovid.play=false', flutter_env)
                self.assertIn('-Dorg.gradle.project.ovid.play=false', flutter_env)

    def test_sideload_inventory_rejects_actual_play_manifest_overlay(self):
        from tool import release_inventory
        from tool.release_inventory_test import elf

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'fixture.aab'
            output = root / 'inventory.json'
            with zipfile.ZipFile(artifact, 'w') as archive:
                archive.writestr('base/manifest/AndroidManifest.xml',
                                 manifest_proto(play_overlay=True))
                archive.writestr('base/lib/arm64-v8a/libflutter.so', elf())
            args = [
                'release_inventory.py', str(artifact), '--mode', 'production',
                '--profile', 'sideload', '--expected-target', '36',
                '--expected-abis', 'arm64-v8a', '--certificate-sha256', 'a' * 64,
                '--output', str(output),
            ]
            with patch.object(release_inventory, 'command', return_value=json.dumps(['a' * 64])), \
                    patch('sys.argv', args), contextlib.redirect_stdout(io.StringIO()):
                code = release_inventory.main()
            report = json.loads(output.read_text())
            self.assertEqual(code, 1)
            self.assertTrue(any('Play manifest overlay' in error
                                for error in report['errors']), report['errors'])

    def test_restore_script_requires_original_worktree(self):
        env = os.environ.copy()
        env.pop('OVID_ORIGINAL_WORKTREE', None)
        result = subprocess.run(
            ['bash', str(ROOT / 'tool/restore_release_wrapper.sh')],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OVID_ORIGINAL_WORKTREE', result.stderr)

    def test_android_gitignore_unignores_only_the_wrapper_inputs(self):
        lines = (ROOT / 'android/.gitignore').read_text().splitlines()
        for rule in ('!/gradle/wrapper/gradle-wrapper.jar', '!/gradlew', '!/gradlew.bat'):
            self.assertIn(rule, lines)
        for rule in ('key.properties', '**/*.keystore', '**/*.jks'):
            self.assertIn(rule, lines)
            self.assertNotIn('!' + rule, lines)

    def test_release_script_and_gradle_enforce_the_static_production_contract(self):
        script_path = ROOT / 'tool/release_sideload.sh'
        self.assertTrue(script_path.is_file(), 'release sideload script is not implemented')
        script = ' '.join(script_path.read_text().split())
        signing = script.index('validateProductionReleaseSigning')
        build = script.index('flutter build apk')
        self.assertLess(signing, build)
        for required in (
            'flutter build apk --release',
            '--target-platform android-x64',
            '--dart-define=OVID_APPCHECK=false',
            '--dart-define=OVID_PRODUCTION=true',
            '--mode production',
            '--profile sideload',
            '--expected-target 36',
            '--expected-abis x86_64',
            '--certificate-sha256',
            'ANDROID_SIGNING_CERT_SHA256',
            'OVID_RELEASE_BUILD_COMMAND',
        ):
            self.assertIn(required, script)
        self.assertNotIn('flutter build appbundle', script)

        gradle = (ROOT / 'android/app/build.gradle.kts').read_text()
        for required in (
            'val ovidTargetSdk = 36', 'isMinifyEnabled = true',
            'signingConfig = signingConfigs.getByName("release")',
            'PrivateKey', 'Signature', 'certSha256', 'cert.checkValidity()',
            'CN=Android Debug',
        ):
            self.assertIn(required, gradle)
        app_check = (ROOT / 'lib/core/cloud_app_check.dart').read_text()
        self.assertNotIn('AndroidProvider.debug', app_check)
        self.assertIn('AndroidProvider.playIntegrity', app_check)

    def test_inventory_can_record_source_and_fixed_build_command(self):
        inventory = (ROOT / 'tool/release_inventory.py').read_text()
        self.assertIn("os.environ.get('GITHUB_SHA')", inventory)
        self.assertIn("os.environ.get('OVID_RELEASE_BUILD_COMMAND')", inventory)


if __name__ == '__main__':
    unittest.main()
