#!/usr/bin/env python3
"""Losslessly re-encode OpenPGP old-format one-octet packet headers.

Why: some apt-key builds accept a binary ``trusted.gpg.d/*.gpg`` keyring only
when its FIRST byte is 0x99 (old-format public-key packet with a two-octet
length) or 0xC6 (new-format public-key packet).  Upstream Termux ships
``thunder-coding.gpg`` (an ed25519 key) whose first packet is small enough to
use a one-octet length, i.e. first byte 0x98, and those apt-key builds warn
"The key(s) in the keyring ... are ignored as the file has an unsupported
filetype".

The conversion rewrites ONLY packet headers: every old-format packet with
length-type 0 (one-octet length) is re-encoded with length-type 1 (two-octet
big-endian length).  Packet bodies are copied byte-for-byte, so the key
material, user IDs, self-signatures and fingerprint are unchanged (the
fingerprint hashes a canonical 0x99 header, never the stored header).

Usage: normalize_openpgp_keyring.py INPUT OUTPUT
Verify: gpg --show-keys --with-colons INPUT OUTPUT  (fpr lines identical).
"""
import sys


def normalize(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        tag = data[i]
        if not tag & 0x80:
            raise ValueError(f'offset {i}: not an OpenPGP packet header')
        if tag & 0x40:  # new format: copy header + body verbatim
            j = i + 1
            first = data[j]
            if first < 192:
                length, j = first, j + 1
            elif first < 224:
                length, j = ((first - 192) << 8) + data[j + 1] + 192, j + 2
            elif first == 255:
                length, j = int.from_bytes(data[j + 1:j + 5], 'big'), j + 5
            else:
                raise ValueError(f'offset {i}: partial body lengths unsupported')
            out += data[i:j + length]
            i = j + length
            continue
        ltype = tag & 0x03
        if ltype == 3:
            raise ValueError(f'offset {i}: indeterminate length unsupported')
        size = (1, 2, 4)[ltype]
        length = int.from_bytes(data[i + 1:i + 1 + size], 'big')
        body = data[i + 1 + size:i + 1 + size + length]
        if len(body) != length:
            raise ValueError(f'offset {i}: truncated packet')
        if ltype == 0:
            out.append((tag & 0xFC) | 0x01)
            out += length.to_bytes(2, 'big')
        else:
            out += data[i:i + 1 + size]
        out += body
        i += 1 + size + length
    return bytes(out)


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], 'rb') as f:
        src = f.read()
    dst = normalize(src)
    with open(argv[2], 'wb') as f:
        f.write(dst)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
