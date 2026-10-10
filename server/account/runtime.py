"""Explicit deployment factory; importing never connects to a live service."""

import json
import os
from importlib import import_module
from pathlib import Path
from uuid import UUID
from .composition import CleanupData
from .stores import StoreConfig, open_stores


def _activated(name):
    value = os.environ.get(name, 'false')
    if value not in ('true', 'false'):
        raise ValueError(f'{name} must be true or false')
    return value == 'true'


def _configured(prefix, *settings):
    # Configuration owns cleanup; activation controls only HTTP admission.
    configured = _activated(prefix + '_CONFIGURED')
    activated = _activated(prefix + '_ACTIVATED')
    return configured or activated or any(os.environ.get(name) for name in settings)


def _authority_id(name):
    value = os.environ.get(name)
    try:
        if str(UUID(value)) == value:
            return value
    except (ValueError, TypeError, AttributeError):
        pass
    raise ValueError(f'{name} requires a stable canonical UUID')


def _collaboration_entry():
    path = Path(os.environ.get('LIVE_COLLABORATION_DATABASE_PATH', ''))
    if not path.is_absolute() or not path.parent.is_dir() or path.is_symlink():
        raise ValueError('LIVE_COLLABORATION_DATABASE_PATH requires an absolute local path')
    return {'path': str(path),
            'store_id': _authority_id('LIVE_COLLABORATION_AUTHORITY_ID')}


def provision_collaboration():
    """Explicit operator binding, never performed by API/worker startup."""
    from .stores import _identity
    from server.collaboration.repository import CollabRepository
    entry = _collaboration_entry()
    _identity(entry, 'live_collaboration', provision=True)
    return CollabRepository(entry['path'])


def _shared_repositories(account_authority):
    private_sync = None
    if _configured('PRIVATE_SYNC', 'PRIVATE_SYNC_REPOSITORY_FACTORY',
                   'PRIVATE_SYNC_AUTHORITY_ID'):
        factory = os.environ.get('PRIVATE_SYNC_REPOSITORY_FACTORY')
        if factory:
            module_name, separator, attribute = factory.partition(':')
            if not separator or not module_name or not attribute or ':' in attribute:
                raise ValueError('PRIVATE_SYNC_REPOSITORY_FACTORY must be module:attribute')
            private_sync = getattr(import_module(module_name), attribute)(account_authority)
        else:
            from server.sync.postgres import PostgresSyncRepository
            identity = _authority_id('PRIVATE_SYNC_AUTHORITY_ID')
            private_sync = PostgresSyncRepository(account_authority)
            # Operator identity survives credential rotation and URI aliases.
            private_sync.authority_identity = 'private-sync:' + identity
        if (getattr(private_sync, 'durability', None) != 'durable' or
                getattr(private_sync, 'authority', None) != 'server'):
            raise ValueError('Private sync requires durable server authority metadata')
        CleanupData._authority_identity(private_sync)

    live_collaboration = None
    if _configured('LIVE_COLLABORATION', 'LIVE_COLLABORATION_DATABASE_PATH',
                   'LIVE_COLLABORATION_AUTHORITY_ID'):
        from .stores import _identity
        from server.collaboration.repository import CollabRepository
        entry = _collaboration_entry()
        _identity(entry, 'live_collaboration')
        live_collaboration = CollabRepository(entry['path'])
        live_collaboration.authority_identity = 'live-collaboration:' + entry['store_id']
    return private_sync, live_collaboration


def build_retention():
    """Open configured authorities without Firebase, mint, or HTTP dependencies."""
    from .postgres import PostgresStore
    stores = open_stores(StoreConfig.load())
    authority = PostgresStore(os.environ['ACCOUNT_DATABASE_URL']) if _configured(
        'PRIVATE_SYNC', 'PRIVATE_SYNC_REPOSITORY_FACTORY', 'PRIVATE_SYNC_AUTHORITY_ID') else None
    private_sync, collaboration = _shared_repositories(authority)
    return stores, private_sync, collaboration


def build():
    from .domain import Lifecycle
    if os.environ.get('ACCOUNT_ACTIVATED') != 'true':
        raise RuntimeError('Account lifecycle is not activated; follow README activation checks')
    stores = open_stores(StoreConfig.load())
    from .postgres import PostgresStore
    account_authority = PostgresStore(os.environ['ACCOUNT_DATABASE_URL'])
    private_sync, live_collaboration = _shared_repositories(account_authority)
    import firebase_admin
    import httpx
    import redis
    from .adapters import FirebaseAdmin, GatewayData, RedisData, SqlData
    admin = FirebaseAdmin(firebase_admin.initialize_app(options={
        'projectId': os.environ['FIREBASE_PROJECT_ID']}),
        os.environ['ACCOUNT_FIREBASE_APP_IDS'].split(','))
    with open(os.environ['ACCOUNT_CLEANUP_MANIFEST'], encoding='utf-8') as source:
        manifest = json.load(source)
    sql_data = SqlData(os.environ['LITELLM_DATABASE_URL'], manifest)
    sql_data.validate()
    client = httpx.Client(base_url=os.environ['LITELLM_BASE'], timeout=30,
                          headers={'Authorization': 'Bearer ' + os.environ['LITELLM_MASTER_KEY']})
    data = GatewayData(sql_data, RedisData(redis.from_url(
        os.environ['REDIS_URL'], decode_responses=True)), client)
    return Lifecycle(account_authority, admin,
                     CleanupData(data, stores, private_sync=private_sync,
                                 live_collaboration=live_collaboration)), admin


def create_app():
    from fastapi import FastAPI
    from .api import router
    service, admin = build()
    app = FastAPI(title='Ovid account lifecycle')
    app.include_router(router(service, admin.verify))
    from server.shares.runtime import mount_shares
    mount_shares(app, service.data.stores.shares, service, admin,
                 os.environ['SHARE_BASE_URL'])
    if _activated('PRIVATE_SYNC_ACTIVATED'):
        from server.sync.runtime import mount_sync
        mount_sync(app, service.data.private_sync, service, admin)
    if _activated('LIVE_COLLABORATION_ACTIVATED'):
        from server.collaboration.runtime import mount_collaboration
        mount_collaboration(app, service.data.live_collaboration, service, admin)
    return app


def main():
    """Local configuration check/provisioning CLI; never activates HTTP."""
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provision-collaboration', action='store_true')
    args = parser.parse_args()
    try:
        if args.provision_collaboration:
            provision_collaboration()
        else:
            build_retention()
    except Exception:
        print('Account authority configuration invalid', flush=True)
        return 1
    print('Account authority configuration valid (no remote connectivity checked)', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
