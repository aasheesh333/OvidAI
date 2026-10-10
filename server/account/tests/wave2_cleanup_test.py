"""Production composition with actual SQLite; no external services contacted."""
import json
import sqlite3
from contextlib import contextmanager
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from server.account.domain import Lifecycle, AccountError
from server.account import runtime
from server.images.service import Ledger, ImageError
from server.shares.repository import ShareRepository
from parallel_account_cleanup_test import DurableStore
from test_lifecycle import Admin, Data


CLAIMS = {'uid': 'alice', 'auth_time': 1000,
          'firebase': {'sign_in_provider': 'google.com'}}
BODY = {'session_id': 'session-one', 'request_id': 'request-one',
        'messages': [{'role': 'user', 'content': 'public text'}]}


def configured(tmp_path):
    from server.account.stores import StoreConfig, provision, open_stores
    value = {'version': 1, 'images': {'path': str(tmp_path / 'images.db'),
             'store_id': '11111111-1111-4111-8111-111111111111'},
             'shares': {'path': str(tmp_path / 'shares.db'),
             'store_id': '22222222-2222-4222-8222-222222222222'}}
    path = tmp_path / 'stores.json'
    path.write_text(json.dumps(value))
    config = StoreConfig.load(path)
    provision(config)
    return config, open_stores(config)


def lifecycle(tmp_path, stores):
    from server.account.composition import CleanupData
    path = tmp_path / 'account.db'
    with sqlite3.connect(path) as db:
        db.execute('CREATE TABLE IF NOT EXISTS account_deletions '
                   '(uid TEXT PRIMARY KEY, state TEXT, delete_after REAL, record TEXT)')
    now, admin = [1000], Admin()
    return Lifecycle(DurableStore(path), admin, CleanupData(Data(), stores),
                     lambda: now[0]), now


def seed(stores):
    share = stores.shares.create('alice', BODY)
    other = stores.shares.create('bob', BODY)
    for uid in ('alice', 'bob'):
        stores.images.begin(uid, 'image-request', 'fingerprint', Decimal('1'), Decimal('10'), 'window')
        stores.images.settle(uid, 'image-request', '1', {'model': 'ovid-image', 'data': []})
    return share, other


@pytest.mark.parametrize('stage', ['images', 'shares'])
@pytest.mark.parametrize('crash', [False, True])
def test_cleanup_failure_and_restart_before_auth(tmp_path, stage, crash):
    from server.account.stores import open_stores
    from server.account.composition import CleanupData
    config, stores = configured(tmp_path)
    share, other = seed(stores)
    service, now = lifecycle(tmp_path, stores)
    service.request(CLAIMS, 'deletion-request')
    now[0] = 87400
    service.finalize('alice')
    now[0] += 60
    target = getattr(stores, stage)
    original = target.delete_account

    def fail(uid):
        original(uid)  # effect succeeded, acknowledgement/checkpoint lost
        raise SystemExit() if crash else RuntimeError('unavailable')

    with patch.object(target, 'delete_account', side_effect=fail):
        with pytest.raises(SystemExit if crash else RuntimeError):
            service.finalize('alice', scheduled=True)
    assert 'alice' in service.admin.users
    with service.store.locked('alice') as db:
        row = db.get('alice')
    assert 'data:' + stage not in row['completed']
    if stage == 'shares':
        assert 'data:images' in row['completed']
    now[0] = row['next_attempt']
    restarted_stores = open_stores(config)
    restarted = Lifecycle(service.store, service.admin, CleanupData(Data(), restarted_stores), lambda: now[0])
    if stage == 'shares':
        restarted_stores.images.delete_account = lambda uid: pytest.fail('completed image stage replayed')
    assert restarted.finalize('alice', scheduled=True)['state'] == 'deleted'
    assert 'alice' not in service.admin.users
    assert restarted_stores.shares.public(share['id']) is None
    assert restarted_stores.shares.public(other['id']) is not None
    with pytest.raises(ImageError, match='image_account_deleted'):
        restarted_stores.images.receipt('alice', 'image-request')
    assert restarted_stores.images.receipt('bob', 'image-request')['charged'] == '0.30'
    with pytest.raises(Exception):
        restarted_stores.shares.create('alice', BODY)


def test_legacy_aggregate_data_cannot_skip_new_required_stages(tmp_path):
    _, stores = configured(tmp_path)
    share, _ = seed(stores)
    service, now = lifecycle(tmp_path, stores)
    service.request(CLAIMS, 'deletion-request')
    with service.store.locked('alice') as db:
        row = db.get('alice')
        row.update(state='deleting', completed=['keys', 'data'], cleanup_context={})
        db.save(row)
    now[0] = 90000
    service.finalize('alice')
    assert stores.shares.public(share['id']) is None
    with pytest.raises(ImageError):
        stores.images.receipt('alice', 'image-request')


@pytest.mark.parametrize('fenced', [False, True])
def test_cancel_preserves_both_stores(tmp_path, fenced):
    _, stores = configured(tmp_path)
    share, _ = seed(stores)
    service, now = lifecycle(tmp_path, stores)
    service.request(CLAIMS, 'deletion-request')
    now[0] = 87400
    if fenced:
        service.finalize('alice')
    assert service.cancel({**CLAIMS, 'auth_time': 87400})['state'] == 'cancelled'
    now[0] += 1000
    service.finalize('alice')
    assert stores.shares.public(share['id']) is not None
    assert stores.images.receipt('alice', 'image-request')['state'] == 'confirmed'


def test_config_refuses_missing_wrong_or_rebound_authority(tmp_path):
    from server.account.stores import StoreConfig, open_stores, provision
    config, stores = configured(tmp_path)
    provision(config)  # explicitly repeatable; preserves data
    seed(stores)
    with sqlite3.connect(stores.images.path) as db:
        db.execute("UPDATE ovid_store_identity SET store_id='different'")
    with pytest.raises(ValueError, match='identity'):
        open_stores(config)
    with pytest.raises(ValueError, match='identity'):
        provision(config)
    path = tmp_path / 'missing.json'
    path.write_text(json.dumps({'version': 1, 'images': {'path': str(tmp_path / 'absent.db'),
        'store_id': '11111111-1111-4111-8111-111111111111'},
        'shares': {'path': stores.shares.path, 'store_id': '22222222-2222-4222-8222-222222222222'}}))
    with pytest.raises(ValueError):
        open_stores(StoreConfig.load(path))
    assert not (tmp_path / 'absent.db').exists()


def test_store_switch_during_restart_never_deletes_auth(tmp_path):
    from server.account.composition import CleanupData
    _, stores = configured(tmp_path)
    service, now = lifecycle(tmp_path, stores)
    service.request(CLAIMS, 'deletion-request')
    now[0] = 87400
    service.finalize('alice')
    now[0] += 60
    with patch.object(stores.shares, 'delete_account', side_effect=RuntimeError()):
        with pytest.raises(RuntimeError):
            service.finalize('alice')
    stores.identities['shares'] = 'replacement-store'
    service.data = CleanupData(Data(), stores)
    with pytest.raises(ValueError, match='changed'):
        service.finalize('alice')
    assert 'alice' in service.admin.users


def test_account_app_factory_mounts_shares_with_fence_and_real_prefix(tmp_path):
    _, stores = configured(tmp_path)
    service, now = lifecycle(tmp_path, stores)
    service.admin.verify = lambda token, attestation, allow_disabled=False: (
        CLAIMS if token == 'verified' and attestation == 'checked' and not allow_disabled
        else (_ for _ in ()).throw(AccountError('invalid_authentication', 401)))
    with patch.object(runtime, 'build', return_value=(service, service.admin)), \
         patch.dict('os.environ', {'SHARE_BASE_URL': 'https://shares.invalid/prefix'}):
        app = runtime.create_app()
    with TestClient(app) as client:
        headers = {'Authorization': 'Bearer verified', 'X-Firebase-AppCheck': 'checked'}
        response = client.post('/prefix/shares', headers=headers, json=BODY)
        assert response.status_code == 201, response.text
        assert response.json()['url'].startswith('https://shares.invalid/prefix/s/')
        service.request(CLAIMS, 'deletion-request')
        assert client.post('/prefix/shares', headers=headers, json={**BODY, 'request_id': 'new-request'}).status_code == 403
        assert client.get('/prefix/shares', headers=headers).status_code == 403
        assert client.post('/prefix/shares', headers={'Authorization': 'Bearer verified'}, json=BODY).status_code == 401


def test_production_build_rejects_absent_store_config_before_external_setup():
    with patch.dict('os.environ', {'ACCOUNT_ACTIVATED': 'true'}, clear=True):
        with pytest.raises((ValueError, RuntimeError), match='ACCOUNT_STORE_CONFIG'):
            runtime.build()


def test_cleanup_has_named_shared_runtime_checkpoints_when_configured(tmp_path):
    from server.account.composition import CleanupData

    calls = []
    class Shared:
        def delete_account(self, uid):
            calls.append(uid)

    _, stores = configured(tmp_path)
    data = CleanupData(Data(), stores, private_sync=Shared(),
                       live_collaboration=Shared())
    assert [name for name, _ in data.deletion_steps()] == [
        'gateway', 'private_sync', 'live_collaboration', 'images', 'shares']
    for name, action in data.deletion_steps():
        if name in {'private_sync', 'live_collaboration'}:
            action('alice', {})
    assert calls == ['alice', 'alice']


def test_shared_runtimes_are_disabled_by_default(tmp_path):
    from server.account.composition import CleanupData

    _, stores = configured(tmp_path)
    data = CleanupData(Data(), stores)
    assert [name for name, _ in data.deletion_steps()] == [
        'gateway', 'images', 'shares']


def test_restart_cannot_drop_a_persisted_shared_cleanup_stage(tmp_path):
    from server.account.composition import CleanupData

    _, stores = configured(tmp_path)

    class Shared:
        authority_identity = 'shared-authority-v1'
        fail = False

        def delete_account(self, uid):
            if self.fail:
                raise RuntimeError('shared unavailable')

    shared = Shared()
    service, now = lifecycle(tmp_path, stores)
    service.data = CleanupData(Data(), stores, private_sync=shared)
    service.request(CLAIMS, 'deletion-request')
    now[0] = 87400
    service.finalize('alice')
    now[0] += 60
    shared.fail = True
    with pytest.raises(RuntimeError, match='shared unavailable'):
        service.finalize('alice')

    with service.store.locked('alice') as db:
        row = db.get('alice')
        assert row['cleanup_context']['cleanup_steps'] == [
            'gateway', 'private_sync', 'images', 'shares']
        assert row['cleanup_context']['authority_identities']['private_sync'] == \
            'shared-authority-v1'
        row['completed'] = ['keys']
        db.save(row)

    restarted = Lifecycle(
        service.store,
        service.admin,
        CleanupData(Data(), stores),
        lambda: now[0],
    )
    with pytest.raises(ValueError, match='cleanup stage|authority'):
        restarted.finalize('alice')

    with service.store.locked('alice') as db:
        assert db.get('alice')['state'] == 'deleting'


def test_cleanup_context_persists_authority_identities_for_sync_and_collaboration(tmp_path):
    from server.account.composition import CleanupData

    _, stores = configured(tmp_path)

    class Shared:
        def __init__(self, identity):
            self.authority_identity = identity

        def delete_account(self, uid):
            pass

    data = CleanupData(
        Data(),
        stores,
        private_sync=Shared('sync-db-v1'),
        live_collaboration=Shared('collab-db-v1'),
    )
    context = data.prepare('alice')
    assert context['authority_identities']['private_sync'] == 'sync-db-v1'
    assert context['authority_identities']['live_collaboration'] == 'collab-db-v1'
    assert context['cleanup_steps'] == [
        'gateway', 'private_sync', 'live_collaboration', 'images', 'shares']


def test_app_mounts_shared_runtimes_only_when_explicitly_activated(tmp_path):
    _, stores = configured(tmp_path)
    service, _ = lifecycle(tmp_path, stores)
    sync = object()
    collab = object()
    service.admin.verify = lambda *args, **kwargs: CLAIMS
    with patch.object(runtime, 'build', return_value=(service, service.admin)), \
         patch.dict('os.environ', {
             'SHARE_BASE_URL': 'https://shares.invalid',
             'PRIVATE_SYNC_ACTIVATED': 'true',
             'LIVE_COLLABORATION_ACTIVATED': 'true'}, clear=True), \
         patch('server.sync.runtime.mount_sync') as mount_sync, \
         patch('server.collaboration.runtime.mount_collaboration') as mount_collaboration:
        service.data.private_sync = sync
        service.data.live_collaboration = collab
        app = runtime.create_app()
    mount_sync.assert_called_once_with(app, sync, service, service.admin)
    mount_collaboration.assert_called_once_with(app, collab, service, service.admin)


def test_private_sync_factory_receives_existing_account_authority():
    authority = object()
    repository = object()
    module = SimpleNamespace(build_repository=lambda supplied: (
        repository if supplied is authority else None))
    with patch.dict('os.environ', {
        'PRIVATE_SYNC_ACTIVATED': 'true',
        'PRIVATE_SYNC_REPOSITORY_FACTORY': 'fixture:build_repository'}, clear=True), \
         patch.object(runtime, 'import_module', return_value=module):
        private_sync, collaboration = runtime._shared_repositories(authority)
    assert private_sync is repository
    assert collaboration is None


def test_bounded_retention_restarts_preserve_pending_and_dedup(tmp_path):
    from server.account.retention import sweep
    _, stores = configured(tmp_path)
    now = [1000]
    stores.images.clock = stores.shares.clock = lambda: now[0]
    for index in range(5):
        stores.images.begin('alice', str(index), 'fp', Decimal('1'), Decimal('100'), 'w')
        stores.images.settle('alice', str(index), '1', {'data': []})
        stores.shares.create('alice', {**BODY, 'request_id': 'request-' + str(index)})
    stores.images.begin('alice', 'unresolved', 'fp', Decimal('1'), Decimal('100'), 'w')
    now[0] += 100 * 86400
    result = sweep(stores, batch_size=2, max_batches=1)
    assert result == {'images': 2, 'shares': 2, 'failed': []}
    assert sweep(stores, batch_size=2, max_batches=2) == {'images': 3, 'shares': 3, 'failed': []}
    assert sweep(stores, batch_size=2, max_batches=2) == {'images': 0, 'shares': 0, 'failed': []}
    assert stores.images.receipt('alice', 'unresolved')['state'] == 'pending'
    assert stores.images.spent('alice', True) == Decimal('2.50')
    with stores.images.connect() as db:
        assert db.execute('SELECT count(*) FROM image_jobs WHERE response IS NOT NULL OR actual IS NOT NULL').fetchone()[0] == 0
    with pytest.raises(ImageError) as error:
        stores.images.begin('alice', '0', 'fp', Decimal('1'), Decimal('100'), 'w')
    assert error.value.status == 410


def test_retention_failure_does_not_starve_other_store(tmp_path):
    from server.account.retention import sweep
    _, stores = configured(tmp_path)
    share = stores.shares.create('alice', BODY)
    stores.shares.clock = lambda: share['expires_at'] + 1
    with patch.object(stores.images, 'purge_expired', side_effect=OSError('private path')):
        assert sweep(stores, batch_size=2, max_batches=1) == {'images': 0, 'shares': 1, 'failed': ['images']}


def test_actual_build_uses_provisioned_stores_and_gateway_stages(tmp_path):
    from server.account.composition import CleanupData
    config, stores = configured(tmp_path)
    share, _ = seed(stores)
    manifest_path = tmp_path / 'manifest.json'
    manifest_path.write_text(json.dumps({'scopes': [
        {'role': 'keys', 'kind': 'uid', 'table': 'keys', 'column': 'uid', 'token_column': 'token'},
        {'role': 'users', 'kind': 'uid', 'table': 'users', 'column': 'uid'},
        {'role': 'spend_logs', 'kind': 'uid', 'table': 'logs', 'column': 'uid'}]}))
    env = {'ACCOUNT_ACTIVATED': 'true', 'ACCOUNT_STORE_CONFIG': str(tmp_path / 'stores.json'),
           'ACCOUNT_CLEANUP_MANIFEST': str(manifest_path), 'ACCOUNT_DATABASE_URL': 'fixture-account',
           'LITELLM_DATABASE_URL': 'fixture-litellm', 'FIREBASE_PROJECT_ID': 'fixture-project',
           'ACCOUNT_FIREBASE_APP_IDS': 'fixture-app', 'LITELLM_BASE': 'https://litellm.invalid',
           'LITELLM_MASTER_KEY': 'fixture', 'REDIS_URL': 'redis://fixture.invalid'}
    # Only external connection boundaries are replaced. The production build,
    # manifest adapter, cleanup composition and on-disk store constructors run.
    with patch.dict('os.environ', env, clear=True), \
         patch('firebase_admin.initialize_app', return_value=object()), \
         patch('server.account.adapters.SqlData.validate'), \
         patch('redis.from_url', return_value=object()):
        service, admin = runtime.build()
    try:
        assert isinstance(service.data, CleanupData)
        assert service.data.stores.identities == stores.identities
        assert service.data.stores.shares.public(share['id']) is not None
        assert [name for name, _ in service.data.deletion_steps()] == ['gateway', 'sql', 'redis', 'images', 'shares']
        assert service.store.dsn == 'fixture-account'
    finally:
        service.data.gateway.client.close()


@pytest.mark.parametrize('value', [0, -1, True, 1.5, 10001])
def test_retention_rejects_unbounded_batch_sizes(tmp_path, value):
    from server.account.retention import sweep
    _, stores = configured(tmp_path)
    for call in (lambda: sweep(stores, batch_size=value),
                 lambda: stores.images.purge_expired(value),
                 lambda: stores.shares.purge_expired(value)):
        with pytest.raises(ValueError):
            call()


def test_share_mutation_holds_account_lock_through_commit(tmp_path):
    _, stores = configured(tmp_path)
    service, now = lifecycle(tmp_path, stores)
    locked = [False]
    original = service.access
    @contextmanager
    def access(claims):
        with original(claims) as uid:
            locked[0] = True
            try:
                yield uid
            finally:
                locked[0] = False
    service.access = access
    service.admin.verify = lambda *args, **kwargs: CLAIMS
    create = stores.shares.create
    def guarded_create(*args):
        assert locked[0], 'check-then-write race outside account lock'
        return create(*args)
    stores.shares.create = guarded_create
    with patch.object(runtime, 'build', return_value=(service, service.admin)), \
         patch.dict('os.environ', {'SHARE_BASE_URL': 'https://shares.invalid'}):
        app = runtime.create_app()
    with TestClient(app) as client:
        assert client.post('/shares', headers={'Authorization': 'Bearer verified'}, json=BODY).status_code == 201


def test_existing_sqlite_migrations_repeat_without_renewing_deadlines(tmp_path):
    from server.account.stores import open_stores, provision
    config, stores = configured(tmp_path)
    seed(stores)
    with stores.images.connect() as db:
        before = [tuple(row) for row in db.execute('SELECT * FROM image_jobs ORDER BY account')]
    with stores.shares._connection() as db:
        shares_before = [tuple(row) for row in db.execute('SELECT * FROM shares ORDER BY owner_uid')]
    for _ in range(2):
        provision(config)
        reopened = open_stores(config)
        with reopened.images.connect() as db:
            assert [tuple(row) for row in db.execute('SELECT * FROM image_jobs ORDER BY account')] == before
        with reopened.shares._connection() as db:
            assert [tuple(row) for row in db.execute('SELECT * FROM shares ORDER BY owner_uid')] == shares_before


def test_retention_image_connections_release_file_handles(tmp_path):
    ledger = Ledger(tmp_path / 'image.db')
    with ledger.connect() as connection:
        assert connection.execute('SELECT 1').fetchone()[0] == 1
    with pytest.raises(sqlite3.ProgrammingError, match='closed'):
        connection.execute('SELECT 1')
