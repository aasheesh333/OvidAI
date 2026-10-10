import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

import pytest
from psycopg.types.json import Jsonb

from server.collaboration.repository import CollabRepository, CollabError
from server.collaboration.tests.test_postgres import pg_schema, pg
from server.collaboration.tests.test_repository import Clock, message


def test_offline_migration_command_is_available():
    assert importlib.util.find_spec('server.collaboration.migrate') is not None


def migrate(source, destination, **overrides):
    from server.collaboration.migrate import import_sqlite
    options = dict(source=source.path, dsn=destination._dsn, schema=destination.schema,
                   confirm_source=str(Path(source.path).resolve()),
                   confirm_destination=destination.authority_identity, offline=True)
    options.update(overrides)
    return import_sqlite(**options)


@pytest.fixture
def source(tmp_path):
    return CollabRepository(tmp_path / 'source.sqlite', clock=Clock())


def populate(source):
    created = source.create_session('owner', 'create')
    token = created['sessionToken']
    invitation = source.create_invite('owner', token, max_uses=9, idempotency_key='invite')
    code = invitation['inviteCode']
    joined = source.join('guest', token, code, idempotency_key='join', with_cursor=True)
    appended = source.append_batch('guest', token, [message('a', 'héllo ☃'), message('b')], idempotency_key='batch')
    source.create_session('deleted', 'delete-me')
    source.delete_account('deleted')
    # Preserve every durable secret, including credentials used by older hosts.
    with source._connection(write=True) as db:
        db.execute('INSERT INTO collab_secrets VALUES (?,?)', ('token_secret', 'legacy-secret-fixture'))
    return created, invitation, joined, appended


def test_import_preserves_all_rows_tokens_cursors_and_exact_retry_results(source, pg):
    repo, _, factory = pg
    created, invitation, joined, appended = populate(source)
    token = created['sessionToken']
    before = source.get_state('owner', token)
    replay = source.replay('owner', token, created['cursor'])
    old_identity = repo.authority_identity
    result = migrate(source, repo)
    assert result['sessions'] == 1
    restarted = factory()
    assert restarted.authority_identity == old_identity
    # Compare storage before any PG request adds new rate rows.
    with source._connection() as local, restarted._connection() as remote:
        for table in ('collab_sessions', 'collab_memberships', 'collab_invites', 'collab_events',
                      'collab_requests', 'collab_invite_requests', 'collab_rates',
                      'deleted_accounts', 'deleted_sessions'):
            expected = [dict(r) for r in local.execute(f'SELECT * FROM {table}')]
            if not expected:
                continue
            columns = ','.join(expected[0])
            actual = remote.execute(f'SELECT {columns} FROM {table}').fetchall()
            assert sorted(actual, key=repr) == sorted(expected, key=repr), table
        assert remote.execute("SELECT secret FROM collab_secrets WHERE name='token_secret'").fetchone()['secret'] == 'legacy-secret-fixture'
    assert restarted.create_session('owner', 'create') == created
    assert restarted.create_invite('owner', token, max_uses=9, idempotency_key='invite') == invitation
    assert restarted.join('guest', token, invitation['inviteCode'], idempotency_key='join', with_cursor=True) == joined
    assert restarted.append_batch('guest', token, [message('a', 'héllo ☃'), message('b')], idempotency_key='batch') == appended
    assert restarted.get_state('owner', token) == before
    assert restarted.replay('owner', token, created['cursor']) == replay
    assert restarted.replay('guest', token, appended['nextCursor'])['events'] == []
    assert restarted.append('owner', token, message('next'))['eventSequence'] == 4
    with pytest.raises(CollabError, match='account_deleted'):
        restarted.create_session('deleted', 'new')


@pytest.mark.parametrize('overrides', [dict(offline=False), dict(confirm_source='wrong'),
                                      dict(confirm_destination='wrong')])
def test_explicit_offline_source_and_destination_confirmation_required(source, pg, overrides):
    repo, _, factory = pg
    populate(source)
    with pytest.raises(ValueError):
        migrate(source, repo, **overrides)
    assert factory()._secret == repo._secret
    with repo._connection() as db:
        assert db.execute('SELECT count(*) AS n FROM collab_sessions').fetchone()['n'] == 0


def test_import_refuses_nonempty_destination_without_changing_either_side(source, pg):
    repo, _, factory = pg
    populate(source)
    original = repo.create_session('destination-owner', 'existing')
    with pytest.raises(ValueError, match='destination_not_empty'):
        migrate(source, repo)
    assert factory().create_session('destination-owner', 'existing') == original
    assert factory()._secret == repo._secret
    assert source.create_session('owner', 'create')['sessionToken']


def test_late_import_failure_rolls_back_rows_secret_and_identity(source, pg):
    repo, _, factory = pg
    created, *_ = populate(source)
    with source._connection(write=True) as db:
        db.execute('UPDATE collab_events SET envelope=? WHERE sequence=3', ('not-json',))
    with pytest.raises(ValueError, match='invalid_source_data'):
        migrate(source, repo)
    restarted = factory()
    assert restarted._secret == repo._secret
    assert restarted.authority_identity == repo.authority_identity
    with repo._connection() as db:
        for table in ('collab_sessions', 'collab_memberships', 'collab_events', 'collab_requests',
                      'collab_invites', 'collab_invite_requests', 'deleted_accounts', 'deleted_sessions'):
            assert db.execute(f'SELECT count(*) AS n FROM {table}').fetchone()['n'] == 0
    assert source.create_session('owner', 'create') == created


def test_unknown_source_columns_rejected_instead_of_silently_losing_credentials(source, pg):
    repo, _, _ = pg
    populate(source)
    with source._connection(write=True) as db:
        db.execute('ALTER TABLE collab_sessions ADD COLUMN unknown_credential TEXT')
    with pytest.raises(ValueError, match='unsupported_source_schema'):
        migrate(source, repo)


def test_cli_import_and_identity_do_not_print_credentials(source, pg):
    repo, _, factory = pg
    created, invitation, *_ = populate(source)
    prefix = [sys.executable, '-m', 'server.collaboration.migrate',
              '--destination-dsn-env', 'COLLAB_MIGRATION_DSN', '--schema', repo.schema]
    env = {**os.environ, 'COLLAB_MIGRATION_DSN': repo._dsn}
    identity = subprocess.run(prefix + ['identity'], env=env, capture_output=True, text=True, timeout=20)
    assert identity.returncode == 0
    assert repo.authority_identity in identity.stdout
    command = prefix + ['import-sqlite', '--source-sqlite', source.path,
                        '--confirm-source', str(Path(source.path).resolve()),
                        '--confirm-destination', repo.authority_identity, '--offline']
    accepted = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
    assert accepted.returncode == 0, accepted.stderr
    rejected = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
    assert rejected.returncode != 0
    for result in (identity, accepted, rejected):
        output = result.stdout + result.stderr
        for credential in (repo._dsn, created['sessionToken'], invitation['inviteCode'], source._secret.hex()):
            assert credential not in output
    assert factory().create_session('owner', 'create') == created


def test_churn_member_order_stays_identical_after_import_and_updates(source, pg):
    repo, _, factory = pg
    token = source.create_session('owner', 'create')['sessionToken']
    code = source.create_invite('owner', token, max_uses=9)['inviteCode']
    for uid in ('a', 'b', 'c'):
        source.join(uid, token, code)
    source.leave('a', token)
    source.join('d', token, code)  # c and d have the same joined_order
    migrate(source, repo)
    remote = factory()
    for authority in (source, remote):
        authority.leave('c', token)
        authority.join('c', token, code)
    assert remote.get_state('owner', token) == source.get_state('owner', token)


def test_import_rejects_sequence_gap_atomically(source, pg):
    repo, _, factory = pg
    populate(source)
    with source._connection(write=True) as db:
        db.execute('DELETE FROM collab_events WHERE sequence=2')
    with pytest.raises(ValueError, match='invalid_source_data'):
        migrate(source, repo)
    assert factory()._secret == repo._secret
    with repo._connection() as db:
        assert db.execute('SELECT count(*) AS n FROM collab_sessions').fetchone()['n'] == 0


def test_cli_schema_deployment_is_explicit_and_restart_stable(pg):
    repo, _, factory = pg
    prefix = [sys.executable, '-m', 'server.collaboration.migrate',
              '--destination-dsn-env', 'COLLAB_MIGRATION_DSN', '--schema', repo.schema]
    env = {**os.environ, 'COLLAB_MIGRATION_DSN': repo._dsn}
    for _ in range(2):
        deployed = subprocess.run(prefix + ['schema'], env=env, capture_output=True, text=True, timeout=20)
        assert deployed.returncode == 0, deployed.stdout + deployed.stderr
    assert factory()._secret == repo._secret
    assert factory().authority_identity == repo.authority_identity


def import_command(source, repo):
    return subprocess.run([
        sys.executable, '-m', 'server.collaboration.migrate',
        '--destination-dsn-env', 'COLLAB_MIGRATION_DSN', '--schema', repo.schema,
        'import-sqlite', '--source-sqlite', source.path,
        '--confirm-source', str(Path(source.path).resolve()),
        '--confirm-destination', repo.authority_identity, '--offline',
    ], env={**os.environ, 'COLLAB_MIGRATION_DSN': repo._dsn},
        capture_output=True, text=True, timeout=20)


@pytest.mark.parametrize('state', ['pending', 'fenced', 'deleting'])
@pytest.mark.parametrize('obligations', ['bound', 'collaboration_done', 'legacy', 'completed_only'])
def test_cli_rejects_unfinished_cleanup_before_copy(source, pg, state, obligations):
    from server.collaboration.migrate import SOURCE_COLUMNS
    repo, _, factory = pg
    created, *_ = populate(source)
    record = {'uid': 'inflight', 'state': state, 'completed': ['keys'],
              'cleanup_context': {
                  'authority_identities': {'live_collaboration': 'live-collaboration:source'},
                  'cleanup_steps': ['gateway', 'live_collaboration', 'images', 'shares']}}
    if obligations == 'collaboration_done':
        record['completed'] += ['data:gateway', 'data:live_collaboration',
                                'data:images', 'data:shares', 'data']
    elif obligations == 'legacy':
        record['cleanup_context'] = {}
    elif obligations == 'completed_only':
        del record['cleanup_context']
    with repo._connection(write=True) as db:
        db.execute('INSERT INTO account_deletions VALUES (%s,%s,0,%s)',
                   ('inflight', state, Jsonb(record)))
        before = db.execute('SELECT * FROM account_deletions').fetchall()
        secrets = db.execute('SELECT * FROM collab_secrets ORDER BY name').fetchall()
        # Sequence increments survive rollback: distinguish a true preflight
        # from copying first and merely rolling back after discovering cleanup.
        db.execute('CREATE SEQUENCE copy_probe')
        db.execute("""CREATE FUNCTION probe_copy() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN PERFORM nextval('copy_probe'); RETURN NEW; END $$""")
        db.execute('CREATE TRIGGER probe_copy BEFORE INSERT ON collab_sessions '
                   'FOR EACH ROW EXECUTE FUNCTION probe_copy()')
    result = import_command(source, repo)
    assert result.returncode == 1, result.stdout + result.stderr
    assert json.loads(result.stdout) == {'error': 'unfinished_account_cleanup'}
    assert result.stderr == ''
    with repo._connection() as db:
        assert db.execute('SELECT is_called FROM copy_probe').fetchone()['is_called'] is False
        assert db.execute('SELECT * FROM account_deletions').fetchall() == before
        assert db.execute('SELECT * FROM collab_secrets ORDER BY name').fetchall() == secrets
        for table in (*SOURCE_COLUMNS, 'collab_accounts'):
            if table != 'collab_secrets':
                assert db.execute(f'SELECT count(*) AS n FROM {table}').fetchone()['n'] == 0
    assert factory().authority_identity == repo.authority_identity
    assert source.create_session('owner', 'create') == created


@pytest.mark.parametrize('state', ['deleted', 'cancelled'])
def test_cli_allows_terminal_account_tombstones_without_rewriting_checkpoints(source, pg, state):
    repo, _, factory = pg
    created, *_ = populate(source)
    # Retained legacy context on a terminal row must not force a checkpoint rewrite.
    record = {'uid': 'deleted', 'state': state, 'completed': ['keys', 'data', 'auth'],
              'cleanup_context': {'authority_identities': {
                  'live_collaboration': 'live-collaboration:source'}}}
    with repo._connection(write=True) as db:
        db.execute('INSERT INTO account_deletions VALUES (%s,%s,0,%s)',
                   ('deleted', state, Jsonb(record)))
        before = db.execute('SELECT * FROM account_deletions').fetchall()
    result = import_command(source, repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)['sessions'] == 1
    with repo._connection() as db:
        assert db.execute('SELECT * FROM account_deletions').fetchall() == before
        assert db.execute('SELECT uid FROM deleted_accounts').fetchall() == [{'uid': 'deleted'}]
        assert db.execute('SELECT count(*) AS n FROM deleted_sessions').fetchone()['n'] == 1
    restarted = factory()
    assert restarted.authority_identity == repo.authority_identity
    assert restarted.create_session('owner', 'create') == created
