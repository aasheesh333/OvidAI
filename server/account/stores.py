"""Explicit local authorities shared by API, account cleanup and retention.

Imports do not load Firebase/Postgres or open databases. Provisioning is an
operator action; ordinary startup NEVER creates a missing authority database.
"""
import argparse
import json
import os
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID


@dataclass(frozen=True)
class StoreConfig:
    images: dict
    shares: dict

    @classmethod
    def load(cls, path=None):
        path = path or os.environ.get('ACCOUNT_STORE_CONFIG')
        if not path:
            raise ValueError('ACCOUNT_STORE_CONFIG is required')
        with open(path, encoding='utf-8') as source:
            value = json.load(source)
        if set(value) != {'version', 'images', 'shares'} or value['version'] != 1:
            raise ValueError('Invalid authority configuration')
        for name in ('images', 'shares'):
            entry = value[name]
            if not isinstance(entry, dict) or set(entry) != {'path', 'store_id'}:
                raise ValueError('Each authority requires path and store_id')
            path = Path(entry['path'])
            if not path.is_absolute() or not path.parent.is_dir() or path.is_symlink():
                raise ValueError('Authority path must be absolute with an existing local parent')
            if str(UUID(entry['store_id'])) != entry['store_id']:
                raise ValueError('Authority store_id must be a canonical UUID')
        if Path(value['images']['path']).resolve() == Path(value['shares']['path']).resolve():
            raise ValueError('Authorities require distinct database paths')
        if value['images']['store_id'] == value['shares']['store_id']:
            raise ValueError('Authorities require distinct store identities')
        return cls(value['images'], value['shares'])


def _identity(entry, kind, *, provision=False):
    path = Path(entry['path'])
    if not provision and not path.is_file():
        raise ValueError('Configured authority database is missing')
    uri = path.as_uri() + ('?mode=rwc' if provision else '?mode=rw')
    with closing(sqlite3.connect(uri, uri=True, timeout=15)) as connection, connection as db:
        db.execute('BEGIN IMMEDIATE')
        if provision:
            db.execute('CREATE TABLE IF NOT EXISTS ovid_store_identity '
                       '(kind TEXT PRIMARY KEY, store_id TEXT NOT NULL)')
            db.execute('INSERT OR IGNORE INTO ovid_store_identity VALUES (?, ?)',
                       (kind, entry['store_id']))
        try:
            rows = db.execute('SELECT kind, store_id FROM ovid_store_identity').fetchall()
        except sqlite3.OperationalError:
            raise ValueError('Authority identity is not provisioned') from None
        if rows != [(kind, entry['store_id'])]:
            raise ValueError('Configured authority identity mismatch')


@dataclass
class Stores:
    images: object
    shares: object
    identities: dict


def open_stores(config):
    # Validate BOTH authorities before constructors run additive migrations.
    _identity(config.images, 'images')
    _identity(config.shares, 'shares')
    from server.images.service import Ledger
    from server.shares.repository import ShareRepository
    return Stores(Ledger(config.images['path']), ShareRepository(config.shares['path']),
                  {name: getattr(config, name)['store_id'] for name in ('images', 'shares')})


def provision(config):
    """Explicitly bind existing reviewed stores, or initialize new empty stores.

    An identity is never overwritten. Copying a database copies its identity;
    correctness still requires host inventory, shared mounts and restore policy.
    """
    for name in ('images', 'shares'):
        _identity(getattr(config, name), name, provision=True)
    return open_stores(config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provision', action='store_true')
    args = parser.parse_args()
    config = StoreConfig.load()
    (provision if args.provision else open_stores)(config)


if __name__ == '__main__':
    main()
