#!/usr/bin/env python3
"""Materialize CI release inputs only after validating all required values."""
import base64
import binascii
import json
import os
from pathlib import Path
import re
import sys


def inputs(env):
    names = ('KEYSTORE_B64', 'KEYSTORE_PASSWORD', 'KEY_ALIAS', 'KEY_PASSWORD',
             'ANDROID_SIGNING_CERT_SHA256', 'GOOGLE_SERVICES')
    missing = [name for name in names if not env.get(name, '').strip()]
    if missing:
        raise ValueError('missing release inputs: ' + ', '.join(missing))
    digest = env['ANDROID_SIGNING_CERT_SHA256'].replace(':', '').lower()
    if not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('invalid ANDROID_SIGNING_CERT_SHA256')
    try:
        keystore = base64.b64decode(''.join(env['KEYSTORE_B64'].split()), validate=True)
        firebase = json.loads(env['GOOGLE_SERVICES'])
        clients = firebase['client']
        valid = any(c['client_info']['android_client_info']['package_name'] == 'com.dhanuk.ovidai'
                    for c in clients)
        if not keystore or not valid or not firebase['project_info']['project_id']:
            raise ValueError()
    except (ValueError, KeyError, TypeError, binascii.Error):
        raise ValueError('invalid keystore encoding or Firebase Android configuration') from None
    return keystore, digest


def property_value(value):
    # java.util.Properties uses ISO-8859-1 and interprets backslashes/whitespace.
    escaped = []
    for char in value:
        code = ord(char)
        if char in '\\:=#! ':
            escaped.append('\\' + char)
        elif char == '\n':
            escaped.append('\\n')
        elif char == '\r':
            escaped.append('\\r')
        elif char == '\t':
            escaped.append('\\t')
        elif code < 32 or code > 126:
            encoded = char.encode('utf-16-be')
            escaped.extend('\\u' + encoded[i:i + 2].hex() for i in range(0, len(encoded), 2))
        else:
            escaped.append(char)
    return ''.join(escaped)


def main():
    try:
        keystore, digest = inputs(os.environ)
    except ValueError as error:
        print(f'Production release refused: {error}', file=sys.stderr)
        return 1
    android = Path(__file__).resolve().parents[1] / 'android'
    paths = [android / 'release-keystore.jks', android / 'keystore.properties', android / 'app/google-services.json']
    # Refuse to overwrite local/operator inputs; CI starts from a fresh checkout.
    if any(path.exists() for path in paths):
        print('Production release refused: release input destination already exists', file=sys.stderr)
        return 1
    values = {'storeFile': 'release-keystore.jks', 'storePassword': os.environ['KEYSTORE_PASSWORD'],
              'keyAlias': os.environ['KEY_ALIAS'], 'keyPassword': os.environ['KEY_PASSWORD'], 'certSha256': digest}
    content = ''.join(f'{key}={property_value(value)}\n' for key, value in values.items())
    os.umask(0o077)
    for path, data in zip(paths, (keystore, content.encode('ascii'), os.environ['GOOGLE_SERVICES'].encode())):
        with path.open('xb') as stream:
            stream.write(data)
    print('Release inputs prepared; Gradle will validate the private key and pinned certificate.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
