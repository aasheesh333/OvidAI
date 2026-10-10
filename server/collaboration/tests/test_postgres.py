"""Real PostgreSQL tests. Set COLLAB_TEST_POSTGRES_DSN to a disposable PG16 DB."""
import importlib.util
import os
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import psycopg
from psycopg import sql
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.account.postgres import PostgresStore
from server.collaboration.api import router
from server.collaboration.repository import CollabError
from server.collaboration.tests import test_contract_integration as contract
from server.collaboration.tests.test_repository import Clock, message


def test_postgres_authority_is_available():
    assert importlib.util.find_spec('server.collaboration.postgres') is not None


@pytest.fixture
def pg_schema():
    dsn = os.environ.get('COLLAB_TEST_POSTGRES_DSN')
    if not dsn:
        pytest.skip('COLLAB_TEST_POSTGRES_DSN is required for real PostgreSQL tests')
    schema = 'collab_test_' + uuid.uuid4().hex
    with psycopg.connect(dsn) as db:
        db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(schema)))
        db.execute(sql.SQL('SET search_path TO {}').format(sql.Identifier(schema)))
        db.execute(Path('server/account/schema.sql').read_text())
        db.execute(Path('server/account/schema_collaboration.sql').read_text())
    try:
        yield dsn, schema
    finally:
        with psycopg.connect(dsn) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(schema)))


@pytest.fixture
def pg(pg_schema):
    from server.collaboration.postgres import PostgresCollabRepository
    dsn, schema = pg_schema
    clock = Clock()
    def factory():
        return PostgresCollabRepository(PostgresStore(dsn), schema=schema, clock=clock)
    return factory(), clock, factory


@pytest.fixture(params=['sqlite', 'postgres'])
def service(request, tmp_path):
    if request.param == 'postgres':
        repo, clock, factory = request.getfixturevalue('pg')
    else:
        from server.collaboration.repository import CollabRepository
        clock = Clock()
        def factory():
            return CollabRepository(tmp_path / 'collab.sqlite', clock=clock)
        repo = factory()
    def connect():
        app = FastAPI()
        app.include_router(router(factory(), lambda uid, check: {'uid': uid},
                                  contract.admission), prefix='/chat')
        return TestClient(app)
    return repo, clock, connect


# Execute existing transport contracts unchanged against both real authorities.
test_http_batch_conflict = contract.test_http_batch_conflict_rolls_back_events_sequence_and_request
test_http_membership = contract.test_http_join_invite_retry_leave_rejoin_and_cursor_binding
test_http_rates = contract.test_durable_append_replay_rates_and_window_recovery
test_http_failed_admissions = contract.test_authorized_failed_requests_count_toward_durable_rate
test_cursor_binding = contract.test_cursor_cannot_be_forged_or_reused_after_leave
test_http_state_history = contract.test_state_returns_sequence_zero_membership_and_history_boundary


def concurrent(count, operation):
    barrier = threading.Barrier(count)
    def run(i):
        barrier.wait(timeout=20)
        return operation(i)
    with ThreadPoolExecutor(max_workers=count) as pool:
        return list(pool.map(run, range(count)))


def test_capacity_and_invite_consumption_across_instances(pg):
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    codes = [repo.create_invite('owner', token)['inviteCode'] for _ in range(18)]
    def join(i):
        try:
            return factory().join(f'u{i}', token, codes[i])
        except CollabError as error:
            return error.code
    results = concurrent(18, join)
    assert sum(isinstance(r, dict) for r in results) == 9
    assert results.count('session_full') == 9
    assert len(repo.get_state('owner', token)['members']) == 10
    with repo._connection() as db:
        assert db.execute('SELECT sum(uses) AS n FROM collab_invites').fetchone()['n'] == 9


def test_concurrent_create_append_and_restart_replay(pg):
    repo, clock, factory = pg
    created = concurrent(12, lambda i: factory().create_session('owner', 'create'))
    assert all(result == created[0] for result in created)
    token = created[0]['sessionToken']
    batch = [message('a'), message('b')]
    results = concurrent(12, lambda i: factory().append_batch(
        'owner', token, batch, idempotency_key='same'))
    assert all(result == results[0] for result in results)
    results = concurrent(16, lambda i: factory().append('owner', token, message(f'parallel-{i}')))
    assert sorted(r['eventSequence'] for r in results) == list(range(3, 19))
    clock.now += 5
    assert factory().append_batch('owner', token, batch, idempotency_key='same') == {
        **repo.append_batch('owner', token, batch, idempotency_key='same')}
    page = factory().replay('owner', token, created[0]['cursor'], limit=5)
    sequences = [e['eventSequence'] for e in page['events']]
    while page['hasMore']:
        page = factory().replay('owner', token, page['cursor'], limit=5)
        sequences.extend(e['eventSequence'] for e in page['events'])
    assert sequences == list(range(1, 19))


def test_deletion_fence_cleanup_and_caller_advisory_lock(pg):
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    other = repo.create_session('host', 'create')['sessionToken']
    code = repo.create_invite('host', other, max_uses=9)['inviteCode']
    repo.join('owner', other, code, idempotency_key='join')
    repo.append('owner', token, message('private'))
    # Lifecycle callers hold this lock on another connection, including cleanup.
    with PostgresStore(repo._dsn).locked('owner'):
        factory().get_state('owner', token)
        factory().delete_account('owner')
    factory().delete_account('owner')
    for operation in [lambda: factory().create_session('owner', 'new'),
                      lambda: factory().join('owner', other, code),
                      lambda: factory().replay('owner', token)]:
        with pytest.raises(CollabError, match='account_deleted'):
            operation()
    assert len(repo.get_state('host', other)['members']) == 1
    assert repo.replay('host', other)['events'][-1]['payload']['action'] == 'left'
    with repo._connection() as db:
        assert db.execute("SELECT count(*) AS n FROM collab_requests WHERE uid='owner'").fetchone()['n'] == 0
        assert db.execute('SELECT count(*) AS n FROM deleted_sessions').fetchone()['n'] == 1


@pytest.mark.parametrize('state,code', [('pending', 'account_deletion_pending'),
    ('fenced', 'account_deletion_pending'), ('deleting', 'account_deletion_pending'),
    ('deleted', 'account_deleted')])
def test_defensive_account_lifecycle_check(pg, state, code):
    repo, _, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    with repo._connection(write=True) as db:
        db.execute('INSERT INTO account_deletions VALUES (%s,%s,0,%s)', ('owner', state, '{}'))
    with pytest.raises(CollabError) as caught:
        factory().get_state('owner', token)
    assert caught.value.code == code
    factory().delete_account('owner')


def test_join_delete_race_never_resurrects(pg):
    repo, _, factory = pg
    token = repo.create_session('host', 'create')['sessionToken']
    code = repo.create_invite('host', token, max_uses=9)['inviteCode']
    def run(i):
        if i % 2:
            factory().delete_account(f'victim{i // 2}')
        else:
            try:
                factory().join(f'victim{i // 2}', token, code)
            except CollabError as error:
                assert error.code == 'account_deleted'
    concurrent(16, run)
    assert len(repo.get_state('host', token)['members']) == 1


def test_schema_idempotent_identity_and_no_constructor_ddl(pg):
    from server.collaboration.postgres import PostgresCollabRepository
    repo, _, factory = pg
    created = repo.create_session('owner', 'create')
    with repo._connection(write=True) as db:
        db.execute(Path('server/account/schema_collaboration.sql').read_text())
        db.execute(Path('server/account/migrations/004_live_collaboration.sql').read_text())
    assert factory().create_session('owner', 'create') == created
    assert factory().authority_identity == repo.authority_identity
    assert PostgresCollabRepository(dsn=repo._dsn, schema=repo.schema,
        authority_id=repo.authority_identity).authority_identity == repo.authority_identity
    with pytest.raises(ValueError):
        PostgresCollabRepository(dsn=repo._dsn, schema=repo.schema, authority_id='wrong')
    # A read-only transaction at connection startup makes even accidental DDL fail.
    read_only = psycopg.conninfo.make_conninfo(repo._dsn, options='-c default_transaction_read_only=on')
    assert PostgresCollabRepository(dsn=read_only, schema=repo.schema).authority_identity == repo.authority_identity


def test_quota_rollback_and_maintenance_preserve_retries(pg, monkeypatch):
    from server.collaboration import repository as policy
    repo, clock, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    monkeypatch.setattr(policy, 'MAX_ROLLING_EVENTS', 1)
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.append_batch('owner', token, [message('a'), message('b')], idempotency_key='batch')
    accepted = repo.append_batch('owner', token, [message('a')], idempotency_key='batch')
    assert accepted['events'][0]['eventSequence'] == 1
    monkeypatch.setattr(policy, 'MAX_REQUEST_RESULT_BYTES', 1)
    with pytest.raises(CollabError, match='quota_exhausted'):
        repo.create_invite('owner', token, idempotency_key='invite')
    clock.now += 61
    assert repo.purge_expired(limit=1) == 1
    assert factory().purge_expired(limit=10) == 1
    assert factory().append_batch('owner', token, [message('a')], idempotency_key='batch') == accepted


def test_session_locks_do_not_serialize_unrelated_sessions(pg):
    repo, _, factory = pg
    first = repo.create_session('a', 'create')
    other = repo.create_session('b', 'create')['sessionToken']
    with repo._connection(write=True) as db:
        db.execute('SELECT * FROM collab_sessions WHERE session_id=%s FOR UPDATE',
                   (first['session']['sessionId'],))
        with ThreadPoolExecutor(max_workers=1) as pool:
            assert pool.submit(factory().append, 'b', other, message('free')).result(timeout=5)['eventSequence'] == 1


def test_explicit_none_clock_uses_wall_time_and_accepts_dsn_authority(pg_schema):
    from types import SimpleNamespace
    from server.collaboration.postgres import PostgresCollabRepository
    dsn, schema = pg_schema
    before = time.time()
    repo = PostgresCollabRepository(SimpleNamespace(dsn=dsn), schema=schema, clock=None)
    token = repo.create_session('owner', 'create')['sessionToken']
    assert repo.get_state('owner', token)['member']['role'] == 'owner'
    with repo._connection() as db:
        created = db.execute('SELECT created_at FROM collab_sessions').fetchone()['created_at']
    assert before <= created <= time.time()


def test_database_failure_is_typed_sanitized_and_rolls_back(pg):
    repo, _, _ = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    with repo._connection(write=True) as db:
        db.execute('ALTER TABLE collab_requests RENAME TO unavailable_requests')
    try:
        with pytest.raises(CollabError) as caught:
            repo.append_batch('owner', token, [message('private-event')], idempotency_key='private-key')
        assert caught.value.code == 'temporarily_unavailable'
        assert caught.value.status == 500
        assert str(caught.value) == 'temporarily_unavailable'
        assert caught.value.__suppress_context__
    finally:
        with repo._connection(write=True) as db:
            db.execute('ALTER TABLE unavailable_requests RENAME TO collab_requests')
    assert repo.replay('owner', token)['events'] == []
    assert repo.append('owner', token, message('retry'))['eventSequence'] == 1


@pytest.mark.parametrize('secret', [None, 'not-a-hex-key', '00'])
def test_incomplete_signing_configuration_fails_closed_without_repair(pg, secret):
    repo, _, factory = pg
    with repo._connection(write=True) as db:
        db.execute("DELETE FROM collab_secrets WHERE name='cursor'")
        if secret is not None:
            db.execute("INSERT INTO collab_secrets VALUES ('cursor',%s)", (secret,))
    with pytest.raises(CollabError) as caught:
        factory()
    assert caught.value.code == 'temporarily_unavailable'
    with repo._connection() as db:
        row = db.execute("SELECT secret FROM collab_secrets WHERE name='cursor'").fetchone()
    assert row == (None if secret is None else {'secret': secret})


def test_membership_revocation_rejoin_and_close_survive_instances(pg):
    import json
    repo, _, factory = pg
    created = repo.create_session('owner', 'create')
    token = created['sessionToken']
    old = repo.create_invite('owner', token, max_uses=9)['inviteCode']
    guest = repo.join('guest', token, old, idempotency_key='join', with_cursor=True)
    repo.revoke_member('owner', token, guest['member']['participantId'])
    with pytest.raises(CollabError, match='membership_revoked'):
        factory().join('guest', token, old)
    fresh = factory().create_invite('owner', token)['inviteCode']
    again = factory().join('guest', token, fresh, idempotency_key='rejoin')
    assert again == guest['member']
    with pytest.raises(CollabError, match='cursor_reset'):
        factory().replay('guest', token, guest['cursor'])
    with pytest.raises(CollabError, match='request_already_used'):
        factory().join('guest', token, old, idempotency_key='join')
    with pytest.raises(CollabError, match='not_owner'):
        factory().close('guest', token)
    closed = factory().close('owner', token)
    assert closed['lifecycle'] == 'closed'
    assert factory().close('owner', token) == closed
    assert factory().create_session('owner', 'create')['session'] == closed
    for operation in (lambda: factory().replay('guest', token),
                      lambda: factory().join('new', token, fresh),
                      lambda: factory().append('owner', token, message('late'))):
        with pytest.raises(CollabError, match='session_closed'):
            operation()
    with repo._connection() as db:
        rows = db.execute('SELECT sequence,envelope FROM collab_events ORDER BY sequence').fetchall()
    assert [row['sequence'] for row in rows] == [1, 2, 3, 4, 5]
    assert [json.loads(row['envelope'])['payload'] for row in rows[-2:]] == [
        {'code': 'sessionClosing'}, {'code': 'sessionClosed'}]


def test_invite_revocation_expiry_and_owner_authorization(pg):
    repo, clock, factory = pg
    token = repo.create_session('owner', 'create')['sessionToken']
    invitation = repo.create_invite('owner', token, max_uses=2, ttl_seconds=1)
    guest = repo.join('guest', token, invitation['inviteCode'])
    with pytest.raises(CollabError, match='not_owner'):
        factory().revoke_invite('guest', token, invitation['inviteId'])
    with pytest.raises(CollabError, match='owner_not_removable'):
        factory().leave('owner', token)
    with pytest.raises(CollabError, match='member_not_found'):
        factory().revoke_member('owner', token, 'absent')
    clock.now += 1
    with pytest.raises(CollabError, match='invite_invalid'):
        factory().join('new', token, invitation['inviteCode'])
    invitation = repo.create_invite('owner', token)
    factory().revoke_invite('owner', token, invitation['inviteId'])
    factory().revoke_invite('owner', token, invitation['inviteId'])
    with pytest.raises(CollabError, match='invite_invalid'):
        factory().join('new', token, invitation['inviteCode'])
    with pytest.raises(CollabError, match='invite_not_found'):
        factory().revoke_invite('owner', token, 'absent')
    assert factory().leave('guest', token) == {'member': {**guest, 'status': 'left'}}
    assert factory().leave('guest', token) == {'member': {**guest, 'status': 'left'}}
