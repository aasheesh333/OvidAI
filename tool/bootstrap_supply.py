#!/usr/bin/env python3
"""Verify pinned Termux assets and derive a deterministic, fresh bootstrap ZIP.

Pins were recorded in parallel-release-report.md from the upstream release API.
No network trust-on-first-use or checksum overrides are exposed by the CLI.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
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
BINS = set('''bash dash coreutils apt apt-get apt-cache apt-mark apt-config apt-key
dpkg dpkg-deb dpkg-query dpkg-trigger dpkg-divert dpkg-split dpkg-realpath
tar gzip gunzip zcat bzip2 bunzip2 xz unxz zstd unzstd curl wget gpgv
grep sed awk find xargs which less head tail cat ls cp mv rm mkdir rmdir touch
chmod chown ln uname whoami id env printenv ps top kill pkill date sleep true
false test sha256sum md5sum base64 cut sort uniq wc tr tee
termux-exec-ld-preload-lib termux-exec-system-linker-exec'''.split())
METHODS = set('copy gpgv http https file store rsh cdrom'.split())
TREES = ('etc/', 'share/terminfo/', 'share/termux-keyring/', 'var/lib/dpkg/')
MAX_EXPANDED = 512 * 1024 * 1024


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(asset, pin):
    if asset.stat().st_size != pin['size']:
        raise ValueError('upstream asset size mismatch')
    if digest(asset) != pin['sha256']:
        raise ValueError('upstream asset SHA256 mismatch')


def keep(name):
    parts = name.split('/')
    return (name == 'SYMLINKS.txt' or name.startswith(TREES)
            or (len(parts) == 2 and parts[0] == 'bin' and parts[1] in BINS)
            or (len(parts) == 2 and parts[0] == 'lib' and '.so' in parts[1])
            or (name.startswith('lib/apt/methods/') and parts[-1] in METHODS))


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


def build(asset, output, abi, pin):
    """Verify before even opening the archive; never extract into the host tree."""
    asset, output = Path(asset), Path(output)
    verify(asset, pin)
    entries, contents = [], {}
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
            entries.append({'path': name, 'size': len(data), 'mode': f'{mode:04o}',
                            'sha256': hashlib.sha256(data).hexdigest()})
    if not any(n.startswith('share/termux-keyring/') and n.endswith('.gpg') for n in contents):
        raise ValueError('missing keyring')
    if not any(n.startswith('share/terminfo/') for n in contents):
        raise ValueError('missing terminfo')
    for required in ('SYMLINKS.txt', 'bin/bash', 'bin/gpgv', 'var/lib/dpkg/status'):
        if required not in contents:
            raise ValueError(f'missing required payload: {required}')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.bootstrap-', dir=output.parent) as tmp:
        staged = Path(tmp) / 'payload.zip'
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as dest:
            for name, (data, mode) in sorted(contents.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                dest.writestr(info, data, compresslevel=9)
        manifest = {
            'schema': 1, 'derivation': 'ovid-agent-essential-v1', 'abi': abi,
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
