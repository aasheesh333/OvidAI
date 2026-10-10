"""Explicit deployment factory; importing never connects to a live service."""

import json
import os
from importlib import import_module
from fastapi import FastAPI
from .api import router
from .domain import Lifecycle
from .composition import CleanupData
from .stores import StoreConfig, open_stores


def _activated(name):
    return os.environ.get(name) == 'true'


def _configured_repository(activation, setting, module_name, class_name, **kwargs):
    """Build an optional repository only after explicit activation/configuration."""
    if not _activated(activation):
        return None
    configured = os.environ.get(setting)
    if not configured:
        raise RuntimeError(f'{setting} is required when {activation}=true')
    module = import_module(module_name)
    repository = getattr(module, class_name)
    return repository(configured, **kwargs)


def _shared_repositories(account_authority):
    private_sync = None
    if _activated('PRIVATE_SYNC_ACTIVATED'):
        # Sync has deliberately not selected a storage implementation yet. An
        # explicitly configured factory receives the existing account authority
        # and is responsible for returning the SyncRepository implementation.
        factory = os.environ.get('PRIVATE_SYNC_REPOSITORY_FACTORY')
        if not factory:
            raise RuntimeError(
                'PRIVATE_SYNC_REPOSITORY_FACTORY is required when '
                'PRIVATE_SYNC_ACTIVATED=true')
        module_name, separator, attribute = factory.partition(':')
        if not separator:
            raise ValueError('PRIVATE_SYNC_REPOSITORY_FACTORY must be module:attribute')
        private_sync = getattr(import_module(module_name), attribute)(
            account_authority)

    live_collaboration = _configured_repository(
        'LIVE_COLLABORATION_ACTIVATED', 'LIVE_COLLABORATION_DATABASE_PATH',
        'server.collaboration.repository', 'CollabRepository')
    return private_sync, live_collaboration


def build():
    if os.environ.get('ACCOUNT_ACTIVATED') != 'true':
        raise RuntimeError('Account lifecycle is not activated; follow README activation checks')
    stores = open_stores(StoreConfig.load())
    import firebase_admin
    import httpx
    import redis
    from .adapters import FirebaseAdmin, GatewayData, RedisData, SqlData
    from .postgres import PostgresStore
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
    account_authority = PostgresStore(os.environ['ACCOUNT_DATABASE_URL'])
    private_sync, live_collaboration = _shared_repositories(account_authority)
    return Lifecycle(account_authority, admin,
                     CleanupData(data, stores, private_sync=private_sync,
                                 live_collaboration=live_collaboration)), admin


def create_app():
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
