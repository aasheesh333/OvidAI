#!/usr/bin/env python3
"""Verify Android release inputs by metadata; never read credential payloads."""
import argparse
from dataclasses import asdict, dataclass, field
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import zipfile


WRAPPER_FILES = (
    'android/gradle/wrapper/gradle-wrapper.jar',
    'android/gradlew',
    'android/gradlew.bat',
)
SECRET_FILES = {
    'release-keystore.jks': 'android/release-keystore.jks',
    'keystore.properties': 'android/keystore.properties',
    'google-services.json': 'android/app/google-services.json',
}
REQUIRED_DEFINES = {'OVID_APPCHECK': 'false', 'OVID_PRODUCTION': 'true'}
FORBIDDEN_DEFINES = {
    'OVID_BILLING_DEMO',
    'OVID_E2E_SKIP_LOGIN',
    'OVID_PLAY_BUILD',
    'OVID_REVENUECAT_TEST_STORE',
    'OVID_REVENUECAT_TEST_STORE_KEY',
}


class ReleaseInputError(ValueError):
    """A release precondition failed without exposing credential contents."""


@dataclass
class ReleaseInputReport:
    wrapper_integrity: bool = True
    wrapper_hashes: dict = field(default_factory=dict)
    secret_modes: dict = field(default_factory=dict)
    secret_ignores: dict = field(default_factory=dict)
    errors: list = field(default_factory=list)

    @property
    def passed(self):
        return (self.wrapper_integrity and not self.errors
                and all(mode == 0o600 for mode in self.secret_modes.values())
                and len(self.secret_modes) == len(SECRET_FILES)
                and all(self.secret_ignores.values())
                and len(self.secret_ignores) == len(SECRET_FILES))


def _regular_file(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    return stat.S_ISREG(mode)


def _sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _jar_structure(path):
    """Return a structural fingerprint after validating the wrapper archive."""
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            if len(names) != len(set(names)):
                raise ReleaseInputError('wrapper JAR contains duplicate entries')
            for member in members:
                name = PurePosixPath(member.filename)
                if (name.is_absolute() or '..' in name.parts
                        or '\\' in member.filename or member.flag_bits & 1):
                    raise ReleaseInputError('wrapper JAR contains an unsafe entry')
            required = {'META-INF/MANIFEST.MF',
                        'org/gradle/wrapper/GradleWrapperMain.class'}
            if not required.issubset(names):
                raise ReleaseInputError('wrapper JAR lacks the Gradle wrapper structure')
            damaged = archive.testzip()
            if damaged is not None:
                raise ReleaseInputError('wrapper JAR has a checksum failure')
            return tuple((member.filename, member.file_size, member.CRC,
                          member.compress_type) for member in members)
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise ReleaseInputError('wrapper JAR is not a valid ZIP archive') from error


def _wrapper_source(path, relative):
    if not _regular_file(path):
        raise ReleaseInputError(f'{relative}: original is missing or not a regular file')
    result = {'sha256': _sha256(path)}
    if path.suffix == '.jar':
        result['zip_structure'] = _jar_structure(path)
    return result


def restore_release_wrapper(original, destination):
    """Restore only missing/identical wrapper files; never replace other bytes."""
    original, destination = Path(original), Path(destination)
    sources = {}
    for relative in WRAPPER_FILES:
        source = original / relative
        sources[relative] = _wrapper_source(source, relative)
        target = destination / relative
        if target.exists() or target.is_symlink():
            if not _regular_file(target):
                raise ReleaseInputError(f'{relative}: destination is not a regular file')
            if _sha256(target) != sources[relative]['sha256']:
                raise ReleaseInputError(
                    f'{relative}: destination hash differs; refusing to overwrite')
            if target.suffix == '.jar' and _jar_structure(target) != sources[relative]['zip_structure']:
                raise ReleaseInputError(
                    f'{relative}: destination ZIP structure differs; refusing to overwrite')

    created = []
    try:
        for relative in WRAPPER_FILES:
            target = destination / relative
            if target.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = original / relative
            mode = stat.S_IMODE(source.stat().st_mode)
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            created.append(target)
            with os.fdopen(descriptor, 'wb') as stream:
                with source.open('rb') as original_stream:
                    while chunk := original_stream.read(1024 * 1024):
                        stream.write(chunk)
            target.chmod(mode)
            if _sha256(target) != sources[relative]['sha256']:
                raise ReleaseInputError(f'{relative}: restored hash mismatch')
            if target.suffix == '.jar' and _jar_structure(target) != sources[relative]['zip_structure']:
                raise ReleaseInputError(f'{relative}: restored ZIP structure mismatch')
    except Exception:
        for target in created:
            target.unlink(missing_ok=True)
        raise


def is_ignored(root, relative):
    """Use Git itself for ordered, escaped, nested ignore-rule semantics."""
    root = Path(root).resolve()
    candidate = Path(relative)
    if candidate.is_absolute():
        try:
            argument = candidate.resolve().relative_to(root).as_posix()
        except ValueError:
            raise ReleaseInputError('ignore check path is outside the repository') from None
    else:
        relative_path = PurePosixPath(os.fspath(relative))
        if relative_path.is_absolute() or '..' in relative_path.parts:
            raise ReleaseInputError('unsafe relative path for ignore check')
        argument = relative_path.as_posix()
    # Inherited Git routing variables could certify a different work-tree.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('GIT_')}
    env['LC_ALL'] = 'C'
    try:
        result = subprocess.run([
            'git', '-C', str(root), 'check-ignore', '--no-index', '-q', '--', argument,
        ], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise ReleaseInputError('authoritative Git ignore check unavailable') from None
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise ReleaseInputError('authoritative Git ignore check failed')


def verify_release_inputs(original, destination):
    """Return a secret-free report; credential files are only lstat'ed."""
    original = Path(original) if original else None
    destination = Path(destination)
    report = ReleaseInputReport()
    wrapper_error_count = 0
    for relative in WRAPPER_FILES:
        report.wrapper_hashes[relative] = {}
        try:
            target = _wrapper_source(destination / relative, relative)
            report.wrapper_hashes[relative]['destination'] = target['sha256']
        except (ReleaseInputError, OSError) as error:
            report.errors.append(str(error))
            wrapper_error_count += 1
            target = None
        if original is not None:
            try:
                source = _wrapper_source(original / relative, relative)
                report.wrapper_hashes[relative]['original'] = source['sha256']
                if target is not None:
                    if source['sha256'] != target['sha256']:
                        raise ReleaseInputError(f'{relative}: wrapper hash mismatch')
                    if ('zip_structure' in source
                            and source['zip_structure'] != target['zip_structure']):
                        raise ReleaseInputError(f'{relative}: wrapper ZIP structure mismatch')
            except (ReleaseInputError, OSError) as error:
                report.errors.append(str(error))
                wrapper_error_count += 1
        if is_ignored(destination, relative):
            report.errors.append(f'{relative}: wrapper is ignored (required: not ignored)')
            wrapper_error_count += 1
    report.wrapper_integrity = wrapper_error_count == 0

    for name, relative in SECRET_FILES.items():
        path = destination / relative
        try:
            mode = path.lstat().st_mode
            if not stat.S_ISREG(mode):
                raise ReleaseInputError(f'{name}: missing or not a regular file')
            permissions = stat.S_IMODE(mode)
            report.secret_modes[name] = permissions
            if permissions != 0o600:
                report.errors.append(f'{name}: must have exact mode 0600')
        except (FileNotFoundError, ReleaseInputError) as error:
            report.secret_modes[name] = None
            if isinstance(error, ReleaseInputError):
                report.errors.append(str(error))
            else:
                report.errors.append(f'{name}: missing or not a regular file')
        ignored = is_ignored(destination, relative)
        report.secret_ignores[name] = ignored
        if not ignored:
            report.errors.append(f'{name}: must be ignored')
    return report


def _forbidden_define(name):
    return (name in FORBIDDEN_DEFINES
            or (name.startswith('OVID_')
                and any(marker in name for marker in ('DEMO', 'BYPASS', 'SKIP_LOGIN', 'TEST_STORE'))))


def _define_name(define):
    name = define.removeprefix('--dart-define=').partition('=')[0]
    if not re.fullmatch(r'OVID_[A-Z0-9_]+', name):
        raise ValueError('invalid Ovid build define')
    return name


def validate_release_defines(defines):
    parsed = {}
    for define in defines:
        normalized = define.removeprefix('--dart-define=')
        name = _define_name(normalized)
        if name in parsed:
            raise ValueError(f'duplicate build define: {name}')
        parsed[name] = normalized.partition('=')[2]
        if _forbidden_define(name):
            raise ValueError(f'forbidden production sideload define: {name}')
    for name, expected in REQUIRED_DEFINES.items():
        if parsed.get(name) != expected:
            raise ValueError(f'{name}={expected} is required')


def validate_build_environment(env):
    """Reject inherited switches before any signing or Flutter process starts."""
    validate_release_defines((
        f"OVID_APPCHECK={env.get('OVID_APPCHECK', 'false')}",
        f"OVID_PRODUCTION={env.get('OVID_PRODUCTION', 'true')}",
    ))
    for name, value in env.items():
        if value and _forbidden_define(name):
            raise ValueError(f'forbidden production sideload environment input: {name}')


def validate_apk_output(path):
    """Fail closed on a missing, disguised, or non-APK build output."""
    path = Path(path)
    if path.suffix != '.apk' or not _regular_file(path):
        raise ValueError('build output must be a regular .apk file')
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            if not {'AndroidManifest.xml', 'classes.dex'}.issubset(names):
                raise ValueError('APK archive lacks AndroidManifest.xml or classes.dex')
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError('build output is not a valid APK archive') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    restore = commands.add_parser('restore')
    restore.add_argument('--original', type=Path, required=True)
    restore.add_argument('--destination', type=Path, required=True)
    verify = commands.add_parser('verify')
    verify.add_argument('--original', type=Path)
    verify.add_argument('--destination', type=Path, required=True)
    commands.add_parser('check-build-environment')
    apk = commands.add_parser('check-apk')
    apk.add_argument('artifact', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'restore':
            restore_release_wrapper(args.original, args.destination)
            print('Wrapper restoration verified; different destination bytes were not overwritten.')
        elif args.command == 'verify':
            report = verify_release_inputs(args.original, args.destination)
            payload = asdict(report)
            payload['passed'] = report.passed
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 0 if report.passed else 1
        elif args.command == 'check-build-environment':
            validate_build_environment(os.environ)
        else:
            validate_apk_output(args.artifact)
        return 0
    except (OSError, ReleaseInputError, ValueError) as error:
        print(f'Release input refused: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
