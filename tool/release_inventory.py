#!/usr/bin/env python3
"""Inspect built APK/AAB bytes, never infer native type from a .so suffix.

Debug gates require valid structure/ABI/signature and the expected target. The
release-candidate (`release`) and production gates additionally require a
non-debuggable manifest; the release-candidate gate honors `--expected-target`
(e.g. 28) and accepts any non-debug signer, verifying a pinned certificate only
when one is supplied, and records 16 KB LOAD/RELRO and APK ZIP-alignment findings
without enforcing them (a target-28 sideload candidate ships ZIP-payload native
libs that inherently fail them). Production gates additionally enforce 64-bit
LOAD/RELRO plus APK ZIP alignment, require target API 36+, and pin the signer to
a required certificate SHA-256. None of these static checks establishes device
or Play qualification.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import zipfile

ABIS = {'arm64-v8a': (2, 183), 'armeabi-v7a': (1, 40), 'x86_64': (2, 62)}
BOOTSTRAP = 'libovid_bootstrap.so'
MAX_MEMBER = 256 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024


def elf_inventory(data, abi):
    if len(data) < 52 or data[:4] != b'\x7fELF' or data[4] not in (1, 2) or data[5] != 1:
        raise ValueError('invalid/truncated little-endian ELF')
    cls, machine = data[4], struct.unpack_from('<H', data, 18)[0]
    if (cls, machine) != ABIS[abi]:
        raise ValueError(f'ELF class/machine {cls}/{machine} does not match {abi}')
    if cls == 2:
        phoff = struct.unpack_from('<Q', data, 32)[0]
        stride, count = struct.unpack_from('<HH', data, 54)
        fmt, expected = '<IIQQQQQQ', 56
    else:
        phoff = struct.unpack_from('<I', data, 28)[0]
        stride, count = struct.unpack_from('<HH', data, 42)
        fmt, expected = '<IIIIIIII', 32
    if not count or stride != expected or phoff + stride * count > len(data):
        raise ValueError('invalid ELF program header table')
    loads, relro = [], []
    for i in range(count):
        fields = struct.unpack_from(fmt, data, phoff + i * stride)
        if cls == 2:
            kind, _, offset, address, _, size, memsize, align = fields
        else:
            kind, offset, address, _, size, memsize, _, align = fields
        if offset + size > len(data) or (kind == 1 and size > memsize):
            raise ValueError('ELF segment outside file or memory bounds')
        if kind == 1:
            loads.append({'alignment': align, 'offset': offset, 'vaddr': address})
        if kind == 0x6474e552:
            relro.append((address + memsize) % 16384)
    if not loads:
        raise ValueError('ELF has no PT_LOAD')
    errors = []
    if cls == 2:
        if any(p['alignment'] < 16384 or p['alignment'] & (p['alignment'] - 1)
               or (p['vaddr'] - p['offset']) % 16384 for p in loads):
            errors.append('PT_LOAD is not 16 KB aligned/congruent')
        if any(relro):
            errors.append('GNU_RELRO end is not 16 KB aligned')
    return {'kind': 'elf', 'class': cls, 'machine': machine,
            'loads': loads, 'relro_end_remainders': relro,
            'alignment_scope': '64-bit required' if cls == 2 else '32-bit inventory only',
            'alignment_errors': errors}


def checked_members(z):
    members = z.infolist()
    if len(members) > 100000 or sum(i.file_size for i in members) > MAX_TOTAL:
        raise ValueError('archive exceeds inventory bounds')
    names = set()
    for info in members:
        path = PurePosixPath(info.filename)
        if info.filename in names or path.is_absolute() or '..' in path.parts or '\\' in info.filename:
            raise ValueError('duplicate/unsafe archive member')
        if info.file_size > MAX_MEMBER or info.flag_bits & 1:
            raise ValueError('oversized/encrypted archive member')
        names.add(info.filename)
    return members


def inspect_native(source, kind, expected_abis):
    result = {'entries': [], 'errors': [], 'alignment_errors': [], 'abis': []}
    seen, bootstrap_abis, elf_abis, flutter_abis = set(), set(), set(), set()
    with zipfile.ZipFile(source) as z:
        for info in checked_members(z):
            pattern = r'lib/([^/]+)/([^/]+)' if kind == 'apk' else r'[^/]+/lib/([^/]+)/([^/]+)'
            match = re.fullmatch(pattern, info.filename)
            if not match or info.is_dir():
                continue
            abi, name = match.groups()
            seen.add(abi)
            entry = {'path': info.filename, 'abi': abi, 'size': info.file_size,
                     'compression': info.compress_type}
            result['entries'].append(entry)
            try:
                if abi not in ABIS:
                    raise ValueError(f'unsupported ABI {abi}')
                data = z.read(info)  # validates CRC; never extracts executable code
                entry['sha256'] = hashlib.sha256(data).hexdigest()
                if name == BOOTSTRAP:
                    entry.update(kind='bootstrap_zip', elfs=[])
                    with zipfile.ZipFile(io.BytesIO(data)) as nested:
                        for member in checked_members(nested):
                            payload = nested.read(member)
                            if not payload.startswith(b'\x7fELF'):
                                continue
                            child = elf_inventory(payload, abi)
                            child['path'] = member.filename
                            child['sha256'] = hashlib.sha256(payload).hexdigest()
                            entry['elfs'].append(child)
                            result['alignment_errors'].extend(
                                f'{info.filename}!{member.filename}: {e}' for e in child['alignment_errors'])
                    entry['elf_count'] = len(entry['elfs'])
                    if not entry['elf_count']:
                        raise ValueError('bootstrap contains no ELF')
                    bootstrap_abis.add(abi)
                else:
                    entry.update(elf_inventory(data, abi))
                    elf_abis.add(abi)
                    if name == 'libflutter.so':
                        flutter_abis.add(abi)
                    result['alignment_errors'].extend(
                        f'{info.filename}: {e}' for e in entry['alignment_errors'])
            except (ValueError, KeyError, struct.error, zipfile.BadZipFile, RuntimeError) as error:
                result['errors'].append(f'{info.filename}: {error}')
    result['abis'] = sorted(seen)
    if seen != expected_abis:
        result['errors'].append(f'ABI set {sorted(seen)} != expected {sorted(expected_abis)}')
    for abi in sorted(expected_abis):
        if abi not in bootstrap_abis:
            result['errors'].append(f'{abi}: missing valid bootstrap ZIP')
        if abi not in elf_abis:
            result['errors'].append(f'{abi}: missing outer ELF library')
        if abi not in flutter_abis:
            result['errors'].append(f'{abi}: missing valid libflutter.so')
    return result


def check_apk_signer(text, expected, production, release=False):
    fingerprints = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)', text)
    fingerprints = [f.lower() for f in fingerprints]
    if not fingerprints:
        raise ValueError('no verified signer certificates')
    if production or release:
        if re.search(r'CN\s*=\s*Android Debug', text, re.I):
            raise ValueError('debug certificate is forbidden for production')
        pinned = expected.replace(':', '').lower()
        # Production always pins; a release candidate pins only when a digest is supplied.
        if (production or pinned) and (not re.fullmatch('[0-9a-f]{64}', pinned)
                                       or set(fingerprints) != {pinned}):
            raise ValueError('production signer does not match required certificate SHA-256')
    return fingerprints


def command(args):
    run = subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, timeout=120)
    if run.returncode:
        raise ValueError(f'{Path(str(args[0])).name} {args[1]} failed (exit {run.returncode})')
    return run.stdout


def protobuf(data):
    """Read bounded wire fields used by AAPT Resources.proto XmlNode/Element."""
    position = 0
    def varint():
        nonlocal position
        value = 0
        for shift in range(0, 70, 7):
            if position >= len(data):
                raise ValueError('truncated protobuf')
            byte = data[position]
            position += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError('invalid protobuf varint')
    fields = {}
    while position < len(data):
        tag = varint()
        number, wire = tag >> 3, tag & 7
        if not number:
            raise ValueError('invalid protobuf tag')
        if wire == 0:
            value = varint()
        elif wire in (1, 2, 5):
            length = varint() if wire == 2 else (8 if wire == 1 else 4)
            if position + length > len(data):
                raise ValueError('truncated protobuf field')
            value = data[position:position + length]
            position += length
        else:
            raise ValueError('unsupported protobuf wire type')
        fields.setdefault(number, []).append(value)
    return fields


def bundle_manifest(data):
    # Schema: frameworks/base/tools/aapt2/Resources.proto, not source Gradle values.
    elements = []
    def walk(node, depth=0):
        if depth > 64:
            raise ValueError('manifest nesting too deep')
        fields = protobuf(node)
        if 1 not in fields:
            return
        element = protobuf(fields[1][0])
        name = element.get(3, [b''])[0].decode()
        attrs = {}
        for raw in element.get(4, []):
            attr = protobuf(raw)
            key = attr.get(2, [b''])[0].decode()
            value = attr.get(3, [b''])[0].decode()
            if not value and 6 in attr:
                item = protobuf(attr[6][0])
                if 7 in item:
                    primitive = protobuf(item[7][0])
                    for field in (6, 7):
                        if field in primitive:
                            value = str(primitive[field][0])
                    if 8 in primitive:
                        value = 'true' if primitive[8][0] else 'false'
            attrs[key] = value
        elements.append((name, attrs))
        for child in element.get(5, []):
            walk(child, depth + 1)
    walk(data)
    manifest = next(a for n, a in elements if n == 'manifest')
    sdk = next(a for n, a in elements if n == 'uses-sdk')
    app = next(a for n, a in elements if n == 'application')
    return {'package': manifest['package'], 'version_code': manifest.get('versionCode'),
            'version_name': manifest.get('versionName'), 'min_sdk': int(sdk['minSdkVersion']),
            'target_sdk': int(sdk['targetSdkVersion']),
            'debuggable': app.get('debuggable', 'false') in ('true', '1'),
            'extract_native_libs': app.get('extractNativeLibs', 'default'),
            'permissions': sorted(a['name'] for n, a in elements if n.startswith('uses-permission'))}


def apk_manifest(path, tools):
    badging = command([tools / 'aapt2', 'dump', 'badging', path])
    tree = command([tools / 'aapt2', 'dump', 'xmltree', path, '--file', 'AndroidManifest.xml'])
    def field(pattern):
        match = re.search(pattern, badging)
        if not match:
            raise ValueError(f'missing manifest field: {pattern}')
        return match[1]
    return {'package': field(r"package: name='([^']+)'"),
            'version_code': field(r"versionCode='([^']+)'"),
            'version_name': field(r"versionName='([^']*)'"),
            'min_sdk': int(field(r"(?:minSdkVersion|sdkVersion):'(\d+)'")),
            'target_sdk': int(field(r"targetSdkVersion:'(\d+)'")),
            'debuggable': 'application-debuggable' in badging,
            'extract_native_libs': re.findall(r'android:extractNativeLibs[^\n]+', tree),
            'permissions': sorted(re.findall(r"uses-permission[^:]*: name='([^']+)'", badging))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--mode', choices=('debug', 'production', 'release'), required=True)
    parser.add_argument('--expected-abis', default=','.join(ABIS))
    parser.add_argument('--expected-target', type=int, required=True)
    parser.add_argument('--expected-min', type=int, default=23)
    parser.add_argument('--certificate-sha256', default=os.environ.get('ANDROID_SIGNING_CERT_SHA256', ''))
    parser.add_argument('--build-tools', type=Path, default=Path(os.environ.get('ANDROID_HOME', '/opt/android-sdk')) / 'build-tools/36.0.0')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    production = args.mode == 'production'
    release = args.mode == 'release'
    strict = production or release
    report = {'schema': 1, 'artifact': str(args.artifact), 'mode': args.mode,
              'source_revision': os.environ.get('GITHUB_SHA'), 'errors': [],
              'qualification': 'static inventory only; no device, split-delivery or Play approval evidence'}
    kind = args.artifact.suffix.removeprefix('.')
    try:
        if kind not in ('apk', 'aab'):
            raise ValueError('expected an APK or AAB')
        with args.artifact.open('rb') as stream:
            report['sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
        report['size'] = args.artifact.stat().st_size
        native = inspect_native(args.artifact, kind, set(args.expected_abis.split(',')))
        report['native'] = native
        report['errors'].extend(native['errors'])
        # 16 KB LOAD/RELRO alignment is a Play/policy requirement enforced only
        # by the production gate. A target-28 release candidate ships the
        # ZIP-payload native libs that inherently fail it, so record the
        # findings for transparency without failing the candidate gate.
        if production:
            report['errors'].extend(native['alignment_errors'])
        else:
            report['alignment_scope'] = (
                'release candidate: 16 KB alignment/RELRO recorded but not '
                'enforced (target-28 sideload; not Play-qualified)'
            )
        if kind == 'apk':
            report['manifest'] = apk_manifest(args.artifact, args.build_tools)
        else:
            with zipfile.ZipFile(args.artifact) as z:
                report['manifest'] = bundle_manifest(z.read('base/manifest/AndroidManifest.xml'))
            report['zip_alignment'] = 'not applicable to AAB; delivered APKs require separate zipalign/device checks'
        manifest = report['manifest']
        if manifest['package'] != 'com.dhanuk.ovidai' or manifest['min_sdk'] != args.expected_min or manifest['target_sdk'] != args.expected_target:
            report['errors'].append('artifact package/minSdk/targetSdk differs from explicit inventory contract')
        if strict and manifest['debuggable']:
            report['errors'].append(f'{args.mode} manifest is debuggable')
        # A target-only bump cannot establish policy/runtime eligibility.
        report['target_policy'] = {'observed_target': manifest['target_sdk'],
                                   'api36_floor_met': manifest['target_sdk'] >= 36,
                                   'play_qualified': False}
        if production and not report['target_policy']['api36_floor_met']:
            report['errors'].append('production requires target API 36 or newer; the expected-target contract cannot lower this floor')
        try:
            if production and not re.fullmatch('[0-9a-f]{64}', args.certificate_sha256.replace(':', '').lower()):
                raise ValueError('required production certificate SHA-256 is absent/invalid')
            pinned = args.certificate_sha256 if (production or (release and args.certificate_sha256.strip())) else '-'
            if kind == 'apk':
                signer = command([args.build_tools / 'apksigner', 'verify', '--verbose', '--print-certs', args.artifact])
                report['signers_sha256'] = check_apk_signer(signer, args.certificate_sha256, production, release)
            else:
                signer = command(['java', Path(__file__).with_name('release_verify_bundle.java'),
                                  args.artifact, pinned])
                report['signers_sha256'] = json.loads(signer)
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            report['errors'].append(f'signing: {error}')
        if kind == 'apk':
            try:
                command([args.build_tools / 'zipalign', '-c', '-P', '16', '4', args.artifact])
                report['zip_alignment'] = '16 KB check passed'
            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                report['zip_alignment'] = str(error)
                if production:
                    report['errors'].append(f'ZIP alignment: {error}')
    except (ValueError, OSError, KeyError, StopIteration, struct.error, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        report['errors'].append(f'inventory: {error}')
    report['passed'] = not report['errors']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'report': str(args.output),
                      'errors': len(report['errors']),
                      'alignment_findings': len(report.get('native', {}).get('alignment_errors', []))}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
