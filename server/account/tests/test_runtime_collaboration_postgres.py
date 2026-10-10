"""Real runtime wiring; only Firebase/gateway boundaries are replaced locally."""
import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
import pytest
from fastapi.testclient import TestClient

from server.account import runtime
from server.account.composition import CleanupData
from server.account.domain import Lifecycle
from server.account.postgres import PostgresStore
from server.account.retention import sweep
from server.collaboration.postgres import PostgresCollabRepository, PostgresCollabUnavailable
from server.collaboration.repository import CollabError
from test_lifecycle import Admin, Data
from wave2_cleanup_test import CLAIMS, configured


@pytest.fixture
def authority(tmp_path):
    dsn = os.environ.get('COLLAB_TEST_POSTGRES_DSN')
    if not dsn:
        pytest.skip('COLLAB_TEST_POSTGRES_DSN requires an isolated test database')
    schema = 'runtime_collab_' + uuid4().hex
    with psycopg.connect(dsn, autocommit=True) as db:
        db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        db.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(schema)))
        account = Path(__file__).resolve().parents[1]
        db.execute((account / 'schema.sql').read_text())
        db.execute((account / 'schema_collaboration.sql').read_text())
        identity = db.execute("SELECT secret FROM collab_secrets WHERE name='authority'").fetchone()[0]
    scoped = make_conninfo(dsn, options=f'-c search_path={schema}')
    _, stores = configured(tmp_path)
    env = {'ACCOUNT_DATABASE_URL': scoped,
           'ACCOUNT_STORE_CONFIG': str(tmp_path / 'stores.json'),
           'LIVE_COLLABORATION_BACKEND': 'postgres',
           'LIVE_COLLABORATION_CONFIGURED': 'true',
           'LIVE_COLLABORATION_ACTIVATED': 'false',
           'LIVE_COLLABORATION_AUTHORITY_ID': identity.removeprefix('collaboration:postgres:')}
    try:
        with patch.dict(os.environ, env, clear=True):
            yield PostgresStore(scoped), stores, identity, schema
    finally:
        with psycopg.connect(dsn, autocommit=True) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(schema)))


def test_retention_opens_same_account_schema_without_sync_or_http(authority):
    account, _, identity, schema = authority
    stores, sync, repo = runtime.build_retention()
    assert sync is None
    assert isinstance(repo, PostgresCollabRepository)
    assert repo._dsn == account.dsn
    assert repo.schema == schema
    assert repo.authority_identity == identity
    token = repo.create_session('alice', 'create')['sessionToken']
    with psycopg.connect(account.dsn) as db:
        db.execute('INSERT INTO collab_rates SELECT session_id, %s, 0 FROM collab_sessions', ('append',))
    assert sweep(stores, live_collaboration=repo, batch_size=1, max_batches=1) == {
        'images': 0, 'shares': 0, 'live_collaboration': 1, 'failed': []}
    assert repo.get_state('alice', token)['session']['lifecycle'] == 'active'


def test_retention_cli_purges_postgres_without_firebase(authority):
    account, _, _, _ = authority
    with psycopg.connect(account.dsn) as db:
        db.execute("INSERT INTO collab_rates VALUES ('retention-fixture', 'append', 0)")
    script = '''
import sys
from server.account.retention import main
result = main()
assert 'firebase_admin' not in sys.modules
assert 'server.account.adapters' not in sys.modules
raise SystemExit(result)
'''
    result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['live_collaboration'] == 1


@pytest.mark.parametrize('identity', [None, 'not-a-uuid', '11111111-1111-4111-8111-111111111111'])
def test_postgres_requires_expected_persisted_identity(authority, monkeypatch, identity):
    account, _, _, _ = authority
    if identity is None:
        monkeypatch.delenv('LIVE_COLLABORATION_AUTHORITY_ID')
    else:
        monkeypatch.setenv('LIVE_COLLABORATION_AUTHORITY_ID', identity)
    with pytest.raises(ValueError, match='AUTHORITY_ID' if identity != '11111111-1111-4111-8111-111111111111' else 'identity mismatch'):
        runtime._shared_repositories(account)


def test_postgres_rejects_sqlite_path_without_creating_file(authority, monkeypatch, tmp_path):
    account, _, _, _ = authority
    path = tmp_path / 'must-not-exist.db'
    monkeypatch.setenv('LIVE_COLLABORATION_DATABASE_PATH', str(path))
    with pytest.raises(ValueError, match='DATABASE_PATH'):
        runtime._shared_repositories(account)
    assert not path.exists()


def test_postgres_startup_never_provisions_missing_secrets(authority):
    account, _, _, _ = authority
    with psycopg.connect(account.dsn) as db:
        db.execute('DELETE FROM collab_secrets')
    with pytest.raises(PostgresCollabUnavailable):
        runtime._shared_repositories(account)
    with psycopg.connect(account.dsn) as db:
        assert db.execute('SELECT count(*) FROM collab_secrets').fetchone() == (0,)


def test_postgres_startup_never_deploys_missing_schema(authority):
    account, _, _, _ = authority
    with psycopg.connect(account.dsn) as db:
        db.execute('DROP TABLE collab_secrets')
    with pytest.raises(PostgresCollabUnavailable):
        runtime._shared_repositories(account)
    with psycopg.connect(account.dsn) as db:
        assert db.execute("SELECT to_regclass('collab_secrets')").fetchone() == (None,)


def test_postgres_rejects_sqlite_provision_command(authority):
    with pytest.raises(ValueError, match='migrate'):
        runtime.provision_collaboration()


def test_postgres_requires_lifecycle_table_and_never_falls_back(authority, tmp_path):
    account, _, _, _ = authority
    with psycopg.connect(account.dsn) as db:
        db.execute('DROP TABLE account_deletions')
    with pytest.raises(PostgresCollabUnavailable):
        runtime.build_retention()
    assert not (tmp_path / 'collaboration.db').exists()


def test_postgres_requires_account_authority(authority):
    with pytest.raises(ValueError, match='account authority'):
        runtime._shared_repositories(None)


def test_postgres_retention_reports_purge_failure(authority):
    _, stores, _, _ = authority
    _, repo = runtime._shared_repositories(authority[0])
    with psycopg.connect(authority[0].dsn) as db:
        db.execute('DROP TABLE collab_rates')
    result = sweep(stores, live_collaboration=repo, batch_size=1, max_batches=1)
    assert result == {'images': 0, 'shares': 0, 'live_collaboration': 0,
                      'failed': ['live_collaboration']}


def test_postgres_runtime_cli_checks_binding(authority):
    result = subprocess.run([sys.executable, '-m', 'server.account.runtime'],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'PostgreSQL collaboration identity checked' in result.stdout
    assert 'no remote connectivity checked' not in result.stdout


def test_schema_dependency_can_be_patched_before_repository_construction(authority):
    account, _, identity, schema = authority
    # Same dependency seam used by deployments' runtime tests: select the schema
    # before the constructor reads collab_secrets, never mutate repo.schema later.
    with patch.object(runtime, '_account_schema', return_value=schema):
        _, repo = runtime._shared_repositories(account)
    assert repo.authority_identity == identity
    token = repo.create_session('alice', 'schema-dependency')['sessionToken']
    assert repo.get_state('alice', token)['session']['lifecycle'] == 'active'


def test_build_and_mount_use_postgres_with_lifecycle_admission(authority, monkeypatch, tmp_path):
    account, _, _, _ = authority
    from server.account import adapters
    admin, gateway = Admin(), Data()
    admin.verify = lambda token, check, **kwargs: CLAIMS
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'scopes': [
        {'table': 'keys', 'column': 'uid', 'kind': 'uid', 'role': 'keys', 'token_column': 'token'},
        {'table': 'users', 'column': 'uid', 'kind': 'uid', 'role': 'users'},
        {'table': 'logs', 'column': 'uid', 'kind': 'uid', 'role': 'spend_logs'}]}))
    for name, value in {'ACCOUNT_ACTIVATED': 'true', 'LIVE_COLLABORATION_ACTIVATED': 'true',
                        'FIREBASE_PROJECT_ID': 'fixture', 'ACCOUNT_FIREBASE_APP_IDS': 'fixture',
                        'ACCOUNT_CLEANUP_MANIFEST': str(manifest),
                        'LITELLM_DATABASE_URL': 'fixture', 'LITELLM_BASE': 'https://fixture.invalid',
                        'LITELLM_MASTER_KEY': 'fixture', 'REDIS_URL': 'redis://fixture.invalid',
                        'SHARE_BASE_URL': 'https://fixture.invalid'}.items():
        monkeypatch.setenv(name, value)
    # Patch the external dependency boundaries; runtime.build, schema discovery,
    # lifecycle, repository, mount and HTTP handlers all execute for real.
    with patch('firebase_admin.initialize_app', return_value=object()), \
         patch.object(adapters, 'FirebaseAdmin', return_value=admin), \
         patch.object(adapters.SqlData, 'validate'), \
         patch.object(adapters, 'GatewayData', return_value=gateway):
        app = runtime.create_app()
    with TestClient(app) as client:
        headers = {'Authorization': 'Bearer fixture', 'X-Firebase-AppCheck': 'fixture'}
        response = client.post('/chat', json={'schemaVersion': 1, 'requestId': 'create',
                                             'idempotencyKey': 'create'}, headers=headers)
        assert response.status_code == 200, response.text
        token = response.json()['sessionToken']
        _, repo = runtime._shared_repositories(account)
        assert repo.get_state('alice', token)['session']['lifecycle'] == 'active'
        service = Lifecycle(account, admin, CleanupData(gateway, authority[1], live_collaboration=repo), lambda: 1000)
        service.request(CLAIMS, 'delete-alice')
        response = client.get('/chat/' + token, headers=headers)
        assert response.status_code == 403
        assert response.json()['code'] == 'account_deletion_pending'
    monkeypatch.setenv('LIVE_COLLABORATION_ACTIVATED', 'false')
    with patch('firebase_admin.initialize_app', return_value=object()), \
         patch.object(adapters, 'FirebaseAdmin', return_value=admin), \
         patch.object(adapters.SqlData, 'validate'), \
         patch.object(adapters, 'GatewayData', return_value=gateway):
        service, _ = runtime.build()
        disabled_app = runtime.create_app()
    assert isinstance(service.data.live_collaboration, PostgresCollabRepository)
    with TestClient(disabled_app) as client:
        assert client.post('/chat', json={'requestId': 'other'}, headers=headers).status_code == 404


def test_disabled_routes_cleanup_replays_before_auth_and_fences_restart(authority):
    account, stores, identity, _ = authority
    _, repo = runtime._shared_repositories(account)
    repo.create_session('alice', 'create-alice')
    bob = repo.create_session('bob', 'create-bob')['sessionToken']
    now, admin = [1000], Admin()
    service = Lifecycle(account, admin, CleanupData(Data(), stores, live_collaboration=repo), lambda: now[0])
    service.request(CLAIMS, 'delete-alice')
    now[0] = 87400
    service.finalize('alice')
    now[0] += 60
    original = repo.delete_account
    def lost_ack(uid):
        original(uid)
        raise RuntimeError('lost acknowledgement')
    with patch.object(repo, 'delete_account', side_effect=lost_ack), pytest.raises(RuntimeError):
        service.finalize('alice', scheduled=True)
    assert 'alice' in admin.users
    with account.locked('alice') as db:
        row = db.get('alice')
    assert row['cleanup_context']['authority_identities']['live_collaboration'] == identity
    assert 'data:live_collaboration' not in row['completed']
    _, restarted = runtime._shared_repositories(account)
    now[0] = row['next_attempt']
    def checked_delete(uid):
        with psycopg.connect(account.dsn) as db:
            assert db.execute('SELECT uid FROM deleted_accounts WHERE uid=%s', (uid,)).fetchone() == (uid,)
            assert db.execute('SELECT count(*) FROM collab_sessions WHERE owner_uid=%s', (uid,)).fetchone() == (0,)
        admin.users.pop(uid)
    admin.delete = checked_delete
    service = Lifecycle(account, admin, CleanupData(Data(), stores, live_collaboration=restarted), lambda: now[0])
    assert service.finalize('alice', scheduled=True)['state'] == 'deleted'
    assert 'alice' not in admin.users
    assert restarted.get_state('bob', bob)['session']['lifecycle'] == 'active'
    with pytest.raises(CollabError, match='account_deleted'):
        restarted.create_session('alice', 'resurrection')


@pytest.mark.parametrize('legacy', [False, True])
def test_cleanup_cannot_resume_across_backend_migration(authority, legacy):
    account, stores, identity, _ = authority
    _, repo = runtime._shared_repositories(account)
    repo.create_session('alice', 'create')
    admin, gateway = Admin(), Data()
    data = CleanupData(gateway, stores, live_collaboration=repo)
    context = {} if legacy else data.prepare('alice')
    if not legacy:
        context['authority_identities']['live_collaboration'] = 'live-collaboration:' + identity.split(':')[-1]
    service = Lifecycle(account, admin, data, lambda: 1000)
    service.request(CLAIMS, 'delete-alice')
    with account.locked('alice') as db:
        row = db.get('alice')
        row.update(state='deleting', completed=['keys', 'data'], cleanup_context=context)
        db.save(row)
    service.clock = lambda: 90000
    with pytest.raises(ValueError, match='authority'):
        service.finalize('alice', scheduled=True)
    assert 'alice' in admin.users
    assert 'alice' in gateway.profiles
    with psycopg.connect(account.dsn) as db:
        assert db.execute("SELECT count(*) FROM collab_sessions WHERE owner_uid='alice'").fetchone() == (1,)


@pytest.mark.parametrize('backend', ['', 'POSTGRES', 'unknown'])
def test_invalid_backend_fails_even_without_activation(backend):
    with patch.dict(os.environ, {'LIVE_COLLABORATION_BACKEND': backend}, clear=True):
        with pytest.raises(ValueError, match='BACKEND'):
            runtime._shared_repositories(None)
