"""Real lifecycle/SQL/gateway adapters; local storage and external-service doubles.

These tests do not assert deployed LiteLLM missing-key semantics: the HTTP fixture
deliberately rejects repeated successful deletions to expose lost checkpoints.
"""

import json
import sqlite3
from contextlib import contextmanager
from unittest.mock import patch

import httpx
import pytest

from server.account.adapters import GatewayData, RedisData, SqlData
from server.account.domain import AccountError, Lifecycle
from test_adapters import RedisFake
from test_lifecycle import Admin, Data, MemoryStore
from test_postgres import LocalConnection, LocalSession


class DurableStore:
    """Disk-backed JSON checkpoints, not a substitute for PostgreSQL locks."""

    def __init__(self, path):
        self.path = path

    @contextmanager
    def locked(self, uid):
        connection = LocalConnection()
        connection.db.close()
        connection.db = sqlite3.connect(self.path, isolation_level=None)
        try:
            yield LocalSession(connection)
        finally:
            connection.db.close()


class GatewayConnection:
    """Execute SqlData's parameterized UID manifest against local SQLite."""

    def __init__(self, path, forbid_deletes=False):
        self.db = sqlite3.connect(path)
        if forbid_deletes:
            self.db.set_authorizer(lambda action, *_: (
                sqlite3.SQLITE_DENY if action == sqlite3.SQLITE_DELETE else sqlite3.SQLITE_OK))

    def execute(self, query, parameters=()):
        return self.db.execute(query.as_string().replace('%s', '?'), parameters)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        try:
            return self.db.__exit__(*args)
        finally:
            self.db.close()


@pytest.mark.parametrize('failure', ['sql', 'redis', 'crash'])
def test_restart_resumes_after_acknowledged_gateway_deletion(tmp_path, failure):
    """Losing substage checkpoints repeats key deletion and strands auth cleanup."""
    lifecycle_path, gateway_path = tmp_path / 'account.db', tmp_path / 'gateway.db'
    with sqlite3.connect(lifecycle_path) as db:
        db.execute('CREATE TABLE account_deletions '
                   '(uid TEXT PRIMARY KEY, state TEXT, delete_after REAL, record TEXT)')
    with sqlite3.connect(gateway_path) as db:
        db.executescript('''
            CREATE TABLE keys (uid TEXT, token TEXT);
            CREATE TABLE users (uid TEXT);
            CREATE TABLE logs (uid TEXT);
            INSERT INTO keys VALUES ('alice', 'token-a'), ('alice', 'token-b'), ('bob', 'token-c');
            INSERT INTO users VALUES ('alice'), ('bob');
            INSERT INTO logs VALUES ('alice'), ('bob');
        ''')
        if failure == 'sql':
            db.execute("CREATE TRIGGER unavailable BEFORE DELETE ON users "
                       "BEGIN SELECT RAISE(FAIL, 'database unavailable'); END")

    manifest = {'scopes': [
        {'role': 'spend_logs', 'kind': 'uid', 'table': 'logs', 'column': 'uid'},
        {'role': 'keys', 'kind': 'uid', 'table': 'keys', 'column': 'uid', 'token_column': 'token'},
        {'role': 'users', 'kind': 'uid', 'table': 'users', 'column': 'uid'},
    ]}
    store, admin, redis = DurableStore(lifecycle_path), Admin(), RedisFake()
    now = [1000.25]
    unavailable = [failure != 'sql']
    sql_deletes_forbidden = [False]
    original_delete = redis.delete

    def redis_delete(key):
        original_delete(key)  # A partial external effect before the failure.
        if unavailable[0]:
            if failure == 'crash':
                raise SystemExit('worker stopped')
            raise RuntimeError('redis unavailable')

    redis.delete = redis_delete

    def transport(request):
        payload = json.loads(request.content)
        if request.url.path == '/key/block':
            assert payload['key'] in ('token-a', 'token-b')
            return httpx.Response(200)
        assert request.url.path == '/key/delete'
        assert payload == {'keys': ['token-a', 'token-b']}
        with sqlite3.connect(gateway_path) as db:
            if not db.execute("SELECT 1 FROM keys WHERE uid='alice'").fetchone():
                return httpx.Response(404)  # Must not guess that this means success.
            db.execute("DELETE FROM keys WHERE uid='alice'")
        return httpx.Response(200)

    claims = {'uid': 'alice', 'auth_time': 1000,
              'firebase': {'sign_in_provider': 'google.com'}}
    with patch('server.account.adapters.psycopg.connect',
               side_effect=lambda dsn: GatewayConnection(gateway_path, sql_deletes_forbidden[0])), \
            httpx.Client(base_url='https://gateway.invalid',
                         transport=httpx.MockTransport(transport)) as client:
        def service():
            return Lifecycle(DurableStore(lifecycle_path), admin,
                             GatewayData(SqlData('local', manifest), RedisData(redis), client),
                             lambda: now[0])

        first = service()
        assert first.request(claims, 'request-partial')['delete_after'] == 87400.25
        now[0] = 87400.25
        assert first.finalize('alice', scheduled=True)['state'] == 'fenced'
        now[0] = 87460.25
        expected = {'sql': sqlite3.IntegrityError, 'redis': RuntimeError, 'crash': SystemExit}
        with pytest.raises(expected[failure]):
            first.finalize('alice', scheduled=True)
        with store.locked('alice') as db:
            row = db.get('alice')
        assert row['state'] == 'deleting'
        assert row['cleanup_context']['tokens'] == ['token-a', 'token-b']
        assert 'alice' in admin.users  # Auth must survive any incomplete data stage.
        with sqlite3.connect(gateway_path) as db:
            assert db.execute('SELECT token FROM keys').fetchall() == [('token-c',)]
            if failure == 'sql':
                assert db.execute('SELECT uid FROM logs ORDER BY uid').fetchall() == [('alice',), ('bob',)]
                db.execute('DROP TRIGGER unavailable')
            else:
                # A committed SQL stage must not run again after Redis failure.
                sql_deletes_forbidden[0] = True
        unavailable[0] = False
        now[0] = row['next_attempt']
        assert service().finalize('alice', scheduled=True)['state'] == 'deleted'

    with store.locked('alice') as db:
        final = db.get('alice')
    assert 'cleanup_context' not in final
    assert 'alice' not in admin.users
    assert redis.values == {'user:bob:key': 'b'}
    assert redis.sets == {'ovid:uids': {'bob'}, 'ipacct:1.2.3.4': {'bob'}}
    with sqlite3.connect(gateway_path) as db:
        for table in ('keys', 'users', 'logs'):
            assert db.execute(f'SELECT uid FROM {table}').fetchall() == [('bob',)]


@pytest.mark.parametrize('outcome', ['not-found', 'lost-response'])
def test_unacknowledged_gateway_cleanup_never_authorizes_auth_deletion(outcome):
    """A 404 or timeout is not evidence of cache eviction/complete cleanup."""
    class Database:
        def __init__(self):
            self.logs = ['token-a']

        def tokens(self, uid):
            return ['token-a']

        def delete_data(self, uid, tokens):
            self.logs.clear()

    def transport(request):
        if request.url.path == '/key/block':
            return httpx.Response(200)
        if outcome == 'lost-response':
            raise httpx.ReadTimeout('unknown outcome', request=request)
        return httpx.Response(404)

    store, admin, sql_data, redis = MemoryStore(), Admin(), Database(), RedisFake()
    now = [1000]
    claims = {'uid': 'alice', 'auth_time': 1000,
              'firebase': {'sign_in_provider': 'google.com'}}
    with httpx.Client(base_url='https://gateway.invalid',
                      transport=httpx.MockTransport(transport)) as client:
        data = GatewayData(sql_data, RedisData(redis), client)
        service = Lifecycle(store, admin, data, lambda: now[0])
        service.request(claims, 'request-unknown')
        now[0] = 87400
        service.finalize('alice', scheduled=True)
        now[0] = 87460
        error = httpx.ReadTimeout if outcome == 'lost-response' else httpx.HTTPStatusError
        for _ in range(2):
            with pytest.raises(error):
                Lifecycle(store, admin, data, lambda: now[0]).finalize('alice', scheduled=True)
            row = store.get('alice')
            assert row['state'] == 'deleting'
            assert row['completed'] == ['keys']
            assert row['cleanup_context']['tokens'] == ['token-a']
            assert admin.users['alice']['disabled']
            assert sql_data.logs == ['token-a']
            assert 'user:alice:key' in redis.values
            now[0] = row['next_attempt']


def test_fractional_server_deadline_alias_and_exact_settlement_across_restart():
    """Rounding grace/settlement down or resetting an alias receipt deletes early."""
    store, admin, data = MemoryStore(), Admin(), Data()
    now = [1000.25]
    claims = {'uid': 'alice', 'auth_time': 1000,
              'firebase': {'sign_in_provider': 'phone'}}
    service = Lifecycle(store, admin, data, lambda: now[0])
    receipt = service.request(claims, 'request-original')
    assert receipt['delete_after'] == 87400.25
    now[0] = 1300
    assert service.request(claims, 'request-alias') == receipt
    now[0] = 1300.001
    with pytest.raises(AccountError, match='reauthentication_required'):
        service.request(claims, 'request-expired')
    assert store.get('alice')['request_aliases'] == ['request-alias']
    restarted = Lifecycle(store, admin, data, lambda: now[0])
    now[0] = 87400.249
    assert restarted.finalize('alice', scheduled=True) == receipt
    assert not admin.users['alice']['disabled']
    now[0] = 87400.25
    assert restarted.finalize('alice', scheduled=True)['state'] == 'fenced'
    now[0] = 87460.249
    assert restarted.finalize('alice', scheduled=True)['state'] == 'fenced'
    assert 'alice' in data.profiles
    with pytest.raises(AccountError), restarted.access(claims):
        pytest.fail('fenced account gained gateway access')
    now[0] = 87460.25
    assert restarted.finalize('alice', scheduled=True)['state'] == 'deleted'
    assert 'alice' not in admin.users


@pytest.mark.parametrize('fenced', [False, True])
def test_exact_deadline_cancel_beats_cleanup_and_alias_cannot_resurrect(fenced):
    """A grace login at the deadline still wins before irreversible deletion."""
    store, admin, data = MemoryStore(), Admin(), Data()
    now = [1000]
    claims = {'uid': 'alice', 'auth_time': 1000,
              'firebase': {'sign_in_provider': 'phone'}}
    service = Lifecycle(store, admin, data, lambda: now[0])
    service.request(claims, 'request-original')
    service.request(claims, 'request-alias')
    now[0] = claims['auth_time'] = 87400
    if fenced:
        assert service.finalize('alice', scheduled=True)['state'] == 'fenced'
        claims['_account_disabled'] = True
    restarted = Lifecycle(store, admin, data, lambda: now[0])
    assert restarted.login(claims)['state'] == 'cancelled'
    assert restarted.request(claims, 'request-alias')['state'] == 'cancelled'
    restarted.request(claims, 'request-newone')
    with pytest.raises(AccountError, match='request_already_completed'):
        restarted.request(claims, 'request-alias')
    assert store.get('alice')['delete_after'] == 173800
    assert not admin.users['alice']['disabled']
    assert 'alice' in data.profiles
