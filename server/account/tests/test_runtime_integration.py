"""Configured authorities remain responsible for cleanup with HTTP disabled."""
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from server.account import runtime
from server.account.composition import CleanupData
from server.account.retention import sweep
from wave2_cleanup_test import configured


def sync_env():
    return {'PRIVATE_SYNC_CONFIGURED': 'true', 'PRIVATE_SYNC_ACTIVATED': 'false',
            'PRIVATE_SYNC_AUTHORITY_ID': '33333333-3333-4333-8333-333333333333',
            'ACCOUNT_DATABASE_URL': 'postgresql://fixture.invalid/account'}


def test_direct_postgres_cleanup_survives_routes_disabled():
    from server.account.postgres import PostgresStore
    from server.sync.postgres import PostgresSyncRepository
    with patch.dict('os.environ', sync_env(), clear=True):
        repo, collab = runtime._shared_repositories(PostgresStore(sync_env()['ACCOUNT_DATABASE_URL']))
    assert isinstance(repo, PostgresSyncRepository)
    assert repo._dsn == sync_env()['ACCOUNT_DATABASE_URL']
    assert repo.authority_identity == 'private-sync:33333333-3333-4333-8333-333333333333'
    assert collab is None


@pytest.mark.parametrize('repo', [object(), SimpleNamespace(path='/tmp/db'),
                                 SimpleNamespace(authority_identity='')])
def test_cleanup_rejects_implicit_authority_identity(repo):
    data = CleanupData(SimpleNamespace(), SimpleNamespace(identities={}), private_sync=repo)
    with pytest.raises(ValueError, match='identity'):
        data.authority_identities()


@pytest.mark.parametrize('metadata', [dict(), {'durability': 'memory', 'authority': 'server'},
                                     {'durability': 'durable', 'authority': 'client'}])
def test_optional_factory_rejects_non_durable_metadata(metadata):
    repo = SimpleNamespace(authority_identity='fixture-authority', **metadata)
    with patch.dict('os.environ', {'PRIVATE_SYNC_REPOSITORY_FACTORY': 'fixture:build'}, clear=True), \
         patch.object(runtime, 'import_module', return_value=SimpleNamespace(build=lambda authority: repo)):
        with pytest.raises(ValueError, match='durable'):
            runtime._shared_repositories(object())


def test_direct_sync_requires_explicit_identity():
    env = sync_env()
    del env['PRIVATE_SYNC_AUTHORITY_ID']
    with patch.dict('os.environ', env, clear=True), pytest.raises(ValueError, match='AUTHORITY_ID'):
        runtime._shared_repositories(SimpleNamespace(dsn=env['ACCOUNT_DATABASE_URL']))


@pytest.mark.parametrize('backend', [None, 'sqlite'])
def test_collaboration_provisioned_identity_is_checked_with_routes_disabled(tmp_path, backend):
    env = {'LIVE_COLLABORATION_DATABASE_PATH': str(tmp_path / 'chat.db'),
           'LIVE_COLLABORATION_AUTHORITY_ID': '44444444-4444-4444-8444-444444444444',
           'LIVE_COLLABORATION_ACTIVATED': 'false'}
    if backend is not None:
        env['LIVE_COLLABORATION_BACKEND'] = backend
    with patch.dict('os.environ', env, clear=True):
        with pytest.raises(ValueError, match='missing'):
            runtime._shared_repositories(None)
        runtime.provision_collaboration()
        _, repo = runtime._shared_repositories(None)
        assert repo.authority_identity == 'live-collaboration:44444444-4444-4444-8444-444444444444'
        _, stores = configured(tmp_path)
        assert sweep(stores, live_collaboration=repo) == {'images': 0, 'shares': 0, 'failed': []}
        env['LIVE_COLLABORATION_AUTHORITY_ID'] = '55555555-5555-4555-8555-555555555555'
    with patch.dict('os.environ', env, clear=True), pytest.raises(ValueError, match='identity'):
        runtime._shared_repositories(None)


def test_shared_retention_is_bounded_and_failure_does_not_starve_stores(tmp_path):
    _, stores = configured(tmp_path)
    class Backlog:
        def __init__(self):
            self.remaining = 9
        def purge_expired(self, *, limit):
            count = min(limit, self.remaining)
            self.remaining -= count
            return count
    repo = Backlog()
    result = sweep(stores, private_sync=repo, batch_size=2, max_batches=3)
    assert result == {'images': 0, 'shares': 0, 'private_sync': 6, 'failed': []}
    assert repo.remaining == 3
    with patch.object(repo, 'purge_expired', side_effect=RuntimeError('secret credential')):
        result = sweep(stores, private_sync=repo, batch_size=2, max_batches=1)
    assert result == {'images': 0, 'shares': 0, 'private_sync': 0, 'failed': ['private_sync']}


def test_retention_construction_does_not_import_firebase_or_gateway(tmp_path):
    configured(tmp_path)
    env = {**sync_env(), 'ACCOUNT_STORE_CONFIG': str(tmp_path / 'stores.json')}
    script = '''
import sys
from server.account.runtime import build_retention
stores, sync, collaboration = build_retention()
assert sync is not None
assert 'firebase_admin' not in sys.modules
assert 'server.account.adapters' not in sys.modules
assert 'httpx' not in sys.modules
'''
    result = subprocess.run([sys.executable, '-c', script], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_sync_maintenance_bounds_and_rejects_invalid_repository_counts():
    from server.sync.maintenance import sweep
    class Backlog:
        remaining = 7
        def purge_expired(self, *, limit):
            count = min(limit, self.remaining)
            self.remaining -= count
            return count
    repo = Backlog()
    assert sweep(repo, batch_size=2, max_batches=2) == 4
    assert repo.remaining == 3
    assert sweep(repo, batch_size=2, max_batches=2) == 3
    for value in (0, True, 10001):
        with pytest.raises(ValueError):
            sweep(repo, batch_size=value)
    for value in (0, True, 101):
        with pytest.raises(ValueError):
            sweep(repo, max_batches=value)
    repo.purge_expired = lambda **kwargs: -1
    with pytest.raises(ValueError):
        sweep(repo)
