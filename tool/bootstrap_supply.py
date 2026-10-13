#!/usr/bin/env python3
"""Verify pinned Termux assets and derive a deterministic, fresh bootstrap ZIP.

Pins were recorded in parallel-release-report.md from the upstream release API.
No network trust-on-first-use or checksum overrides are exposed by the CLI.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_inventory import elf_inventory

TAG = 'bootstrap-2026.08.23-r1%2Bapt.android-7'
BASE = f'https://github.com/termux/termux-packages/releases/download/{TAG}'
PINS = {
    'aarch64': {'size': 32672724, 'sha256': 'f902017cf09c84189732b6174b56d69b9890468f4fa7394fc1354b573153688e'},
    'arm': {'size': 29365088, 'sha256': '27fb2eaaf2ebb579e65cefcbfc7dab44ea9f2d1a0c7e73efe3a2f87a8ebfd359'},
    'x86_64': {'size': 32584674, 'sha256': '5f7c54e860df1ef5146b8475dc90e69af666da6588ca1fd47be8f7036b07e8cb'},
}
ABI_MAP = {'aarch64': 'arm64-v8a', 'arm': 'armeabi-v7a', 'x86_64': 'x86_64'}
# Derivation: the COMPLETE upstream bootstrap minus documentation/headers.
# Earlier recipes kept a hand-picked binary subset. dpkg itself then refused
# to run ("'diff' / 'start-stop-daemon' not found in PATH") and every package
# in var/lib/dpkg/status whose files were dropped stayed "installed" but
# missing, so maintainer scripts failed. Termux packages assume the whole
# essential set; only files nothing executes are dropped here.
DROP = ('share/man/', 'share/info/', 'share/doc/', 'include/',
        'libexec/installed-tests/', 'share/LICENSES/')
MAX_EXPANDED = 512 * 1024 * 1024

# proot runs every sandbox process with the app-private prefix bound at the
# compiled-in /data/data/com.termux/files/usr (see lib/core/termux_proot.dart).
# It is not part of the upstream bootstrap, so the exact signed Termux
# repository debs are vendored (tool/vendor/termux-debs/<arch>/) and pinned
# here; they are merged into the payload and registered in the dpkg database
# so apt can upgrade them like any other package.
VENDOR = Path(__file__).resolve().parent / 'vendor' / 'termux-debs'
DEB_PINS = {
    'aarch64': {
        'libandroid-shmem_0.7_aarch64.deb': '0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6',
        'libtalloc_2.5.0_aarch64.deb': '556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7',
        'proot_5.1.107.96_aarch64.deb': '8199dca06dccb693ec09fb1759e3e1ad08b4863f0c11c612f89c20bd9ecdc1a0',
    },
    'arm': {
        'libandroid-shmem_0.7_arm.deb': '5832fd11dca9be2a288dd8fbc2b2799b289c812c7a8764f1f8234c425aa64ce5',
        'libtalloc_2.5.0_arm.deb': '98ace4f1fcbb04b75e859a12b689a9ae4ac91ff8fd34ab221e5359c95ba47f52',
        'proot_5.1.107.96_arm.deb': '19cd0aa78583e46075381398f23f8ee3647e61f166b5d02a487d99312d4ea51d',
    },
    'x86_64': {
        'libandroid-shmem_0.7_x86_64.deb': 'ffa9e4c87467b158b148d0ff92dda796aa038276c2075af3269cdcdb06f25797',
        'libtalloc_2.5.0_x86_64.deb': 'b8c6d95f20075dc1f9ec6573575b2444e8d526e48e0d8d6d5cf4e071e6e06530',
        'proot_5.1.107.96_x86_64.deb': '77ea45540071ca543adda2b51aca2bc3761c52904d013fd0890682288eff9455',
    },
}
TERMUX_PREFIX = 'data/data/com.termux/files/usr/'
REQUIRED = ('SYMLINKS.txt', 'bin/bash', 'bin/gpgv', 'bin/gawk', 'bin/dpkg',
            'bin/diff', 'bin/start-stop-daemon', 'bin/proot',
            'libexec/proot/loader', 'lib/libtalloc.so.2', 'var/lib/dpkg/status')


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(asset, pin):
    if asset.stat().st_size != pin['size']:
        raise ValueError('upstream asset size mismatch')
    if digest(asset) != pin['sha256']:
        raise ValueError('upstream asset SHA256 mismatch')


def keep(name):
    return not name.startswith(DROP)


def _ar_members(data):
    if data[:8] != b'!<arch>\n':
        raise ValueError('not a deb (ar) archive')
    members, i = {}, 8
    while i < len(data):
        header = data[i:i + 60]
        name = header[:16].decode().strip().rstrip('/')
        size = int(header[48:58])
        i += 60
        members[name] = data[i:i + size]
        i += size + (size & 1)
    return members


def vendored_debs(abi):
    """Pinned vendored debs for [abi]: [(control_text, [(path, kind, data, mode, link)])]."""
    out = []
    for name, pin in sorted(DEB_PINS[abi].items()):
        data = (VENDOR / abi / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != pin:
            raise ValueError(f'vendored deb SHA256 mismatch: {name}')
        members = _ar_members(data)
        control_tar = next(v for k, v in members.items() if k.startswith('control.tar'))
        data_tar = next(v for k, v in members.items() if k.startswith('data.tar'))
        with tarfile.open(fileobj=io.BytesIO(control_tar)) as tar:
            control = tar.extractfile('./control').read().decode()
        entries = []
        with tarfile.open(fileobj=io.BytesIO(data_tar)) as tar:
            for member in tar.getmembers():
                rel = member.name.removeprefix('./')
                if not (rel + '/').startswith(TERMUX_PREFIX):
                    continue
                path = rel[len(TERMUX_PREFIX):] if rel != TERMUX_PREFIX.rstrip('/') else ''
                if '..' in PurePosixPath(path).parts:
                    raise ValueError(f'unsafe deb member: {member.name!r}')
                if member.isdir():
                    entries.append((path, 'dir', b'', 0o755, ''))
                elif member.issym():
                    entries.append((path, 'link', b'', 0o777, member.linkname))
                elif member.isfile():
                    mode = 0o755 if member.mode & 0o111 else 0o644
                    entries.append((path, 'file', tar.extractfile(member).read(), mode, ''))
                else:
                    raise ValueError(f'unsupported deb member type: {member.name!r}')
        out.append((control, entries))
    return out


def merge_vendored(contents, abi):
    """Add the vendored debs to [contents] and register them with dpkg."""
    status = contents['var/lib/dpkg/status'][0].decode()
    links = contents['SYMLINKS.txt'][0].decode()
    for control, entries in vendored_debs(abi):
        package = re.search(r'^Package: (\S+)$', control, re.M).group(1)
        if re.search(rf'^Package: {re.escape(package)}$', status, re.M):
            raise ValueError(f'vendored package already in bootstrap: {package}')
        listed, sums = [], []
        for path, kind, data, mode, link in entries:
            guest = '/' + TERMUX_PREFIX + path if path else '/' + TERMUX_PREFIX.rstrip('/')
            listed.append(guest.rstrip('/'))
            if kind == 'dir' or not keep(path):
                continue
            if kind == 'link':
                links += f'{link}←./{path}\n'
            else:
                contents[path] = (data, mode)
                sums.append(f'{hashlib.md5(data).hexdigest()}  {guest.lstrip("/")}\n')
        status = status.rstrip('\n') + '\n\n' + control.rstrip('\n').replace(
            f'Package: {package}\n', f'Package: {package}\nStatus: install ok installed\n', 1) + '\n'
        contents[f'var/lib/dpkg/info/{package}.list'] = (
            ('\n'.join(['/.', *sorted(set(l for l in listed if l))]) + '\n').encode(), 0o644)
        contents[f'var/lib/dpkg/info/{package}.md5sums'] = (''.join(sums).encode(), 0o644)
    contents['var/lib/dpkg/status'] = (status.encode(), 0o644)
    contents['SYMLINKS.txt'] = (links.encode(), 0o644)


def alignment_findings(contents, abi):
    """Report 16 KB PT_LOAD/GNU_RELRO failures for derived ELF payloads.

    These are properties of the compiled ELF bytes, so they cannot be repaired
    by ZIP packing choices. 64-bit ABIs are checked; ARM32 stays inventory-only.
    """
    findings = []
    for name, (data, _mode) in sorted(contents.items()):
        if not data.startswith(b'\x7fELF'):
            continue
        try:
            report = elf_inventory(data, abi)
        except ValueError:
            continue
        findings.extend({'path': name, 'error': error}
                        for error in report['alignment_errors'])
    return findings


def _symlinked(contents, path):
    return any(line.split('←', 1)[-1].removeprefix('./') == path
               for line in contents['SYMLINKS.txt'][0].decode().splitlines())


def build(asset, output, abi, pin):
    """Verify before even opening the archive; never extract into the host tree."""
    asset, output = Path(asset), Path(output)
    verify(asset, pin)
    contents = {}
    with zipfile.ZipFile(asset) as source:
        infos = source.infolist()
        if len(infos) > 100000 or sum(i.file_size for i in infos) > MAX_EXPANDED:
            raise ValueError('upstream expanded size/entry limit')
        seen = set()
        for info in infos:
            name = info.filename
            path = PurePosixPath(name)
            if (path.is_absolute() or '..' in path.parts or '\\' in name
                    or any(ord(c) < 32 for c in name) or name in seen
                    or str(path) != name.rstrip('/')):
                raise ValueError(f'unsafe or duplicate archive path: {name!r}')
            seen.add(name)
            kind = stat.S_IFMT(info.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f'unsupported archive member type: {name!r}')
            if info.is_dir() or not keep(name):
                continue
            data = source.read(info)  # bounded above, CRC checked by ZipFile
            mode = 0o755 if ((info.external_attr >> 16) & 0o111) else 0o644
            contents[name] = (data, mode)
    if not any(n.startswith('share/termux-keyring/') and n.endswith('.gpg') for n in contents):
        raise ValueError('missing keyring')
    if not any(n.startswith('share/terminfo/') for n in contents):
        raise ValueError('missing terminfo')
    merge_vendored(contents, abi)
    for required in REQUIRED:
        if required not in contents and not _symlinked(contents, required):
            raise ValueError(f'missing required payload: {required}')
    entries = [{'path': name, 'size': len(data), 'mode': f'{mode:04o}',
                'sha256': hashlib.sha256(data).hexdigest()}
               for name, (data, mode) in sorted(contents.items())]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.bootstrap-', dir=output.parent) as tmp:
        staged = Path(tmp) / 'payload.zip'
        # Inside the signed APK payload so runtime repair can verify a bounded
        # subset. The external manifest still binds the complete ZIP digest;
        # embedding that digest would create a circular hash dependency.
        repair_manifest = {
            'schema': 1, 'androidAbi': ABI_MAP[abi],
            'upstream': {'url': f'{BASE}/bootstrap-{abi}.zip', **pin},
            'entries': sorted(entries, key=lambda e: e['path']),
        }
        contents['.ovid-bootstrap-manifest.json'] = (
            (json.dumps(repair_manifest, sort_keys=True) + '\n').encode(), 0o644)
        repair_bytes = contents['.ovid-bootstrap-manifest.json'][0]
        entries.append({'path': '.ovid-bootstrap-manifest.json', 'size': len(repair_bytes),
                        'mode': '0644', 'sha256': hashlib.sha256(repair_bytes).hexdigest()})
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dest:
            for name, (data, mode) in sorted(contents.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                dest.writestr(info, data, compresslevel=9)
        manifest = {
            'schema': 1, 'derivation': 'ovid-termux-proot-v2', 'abi': abi,
            'androidAbi': ABI_MAP[abi],
            'upstream': {'url': f'{BASE}/bootstrap-{abi}.zip', **pin},
            'recipeSha256': digest(Path(__file__)),
            'output': {'sha256': digest(staged), 'size': staged.stat().st_size},
            'alignment_findings': alignment_findings(contents, ABI_MAP[abi]),
            'entries': sorted(entries, key=lambda e: e['path']),
        }
        staged_manifest = Path(tmp) / 'manifest.json'
        staged_manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        # Fresh replacement, never zip-update an old destination. Consumers
        # must match output digest to manifest (the pair is not one atomic file).
        os.replace(staged_manifest, output.with_suffix('.manifest.json'))
        os.replace(staged, output)
    return manifest


def acquire(cache, abi, offline):
    pin = PINS[abi]
    asset = cache / f'bootstrap-{abi}.zip'
    if asset.exists():
        verify(asset, pin)  # fail on a poisoned cache, never silently reuse
        return asset
    if offline:
        raise ValueError(f'missing pinned cached asset: {abi}')
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.download-', dir=cache) as tmp:
        staged = Path(tmp) / 'asset.zip'
        # curl max-filesize plus RLIMIT_FSIZE bounds chunked/older curl writes.
        def limits():
            import resource
            resource.setrlimit(resource.RLIMIT_FSIZE, (pin['size'], pin['size']))
        subprocess.run([
            'curl', '--fail', '--silent', '--show-error', '--location',
            '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
            '--connect-timeout', '20', '--max-time', '180',
            '--max-filesize', str(pin['size']), '--output', str(staged),
            f'{BASE}/bootstrap-{abi}.zip',
        ], check=True, timeout=600, preexec_fn=limits)
        verify(staged, pin)
        os.replace(staged, asset)
    return asset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('abis', nargs='*', default=list(PINS))
    parser.add_argument('--cache', type=Path, default=Path('/tmp/opencode/bootstrap-work'))
    parser.add_argument('--output-root', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'android/app/src/main/jniLibs')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--require-16kb', action='store_true',
                        help='fail if any derived 64-bit ELF fails PT_LOAD/GNU_RELRO 16 KB alignment')
    args = parser.parse_args()
    for abi in args.abis:
        if abi not in PINS:
            parser.error(f'unknown ABI: {abi}')
    failed = False
    for abi in args.abis:
        asset = acquire(args.cache, abi, args.offline)
        if not args.verify_only:
            manifest = build(asset, args.output_root / ABI_MAP[abi] / 'libovid_bootstrap.so', abi, PINS[abi])
            findings = manifest['alignment_findings']
            print(f'{abi}: verified upstream and derived {manifest["output"]["sha256"]}'
                  f' ({len(findings)} 16 KB alignment finding(s))')
            if args.require_16kb and findings:
                # Repacking cannot repair ELF RELRO/LOAD alignment; the pinned
                # upstream payload must be rebuilt with a 16 KB-capable toolchain.
                print(f'{abi}: refused: {len(findings)} derived ELF(s) fail 16 KB '
                      f'PT_LOAD/GNU_RELRO alignment; rebuild the pinned upstream payload',
                      file=sys.stderr)
                failed = True
        else:
            print(f'{abi}: pinned upstream verified')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
