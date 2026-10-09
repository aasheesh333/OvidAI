"""Execute store SQL locally; no PostgreSQL service or credentials are used.

SQLite exercises relational selection/upserts and the additive index migration.
Its JSON extraction is adapted to PostgreSQL's ->> text result. This does not
validate PostgreSQL advisory locks, query plans, or concurrent DDL.
"""

import json
import sqlite3
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from psycopg.types.json import Jsonb
from server.account.domain import AccountError, Lifecycle
from server.account.postgres import PostgresStore, Session
from server.account.worker import sweep
from test_lifecycle import Admin, Data


ACCOUNT = Path(__file__).resolve().parents[1]


class LocalConnection:
    def __init__(self):
        self.db = sqlite3.connect(':memory:', isolation_level=None)
        def text_value(document, key):
            value = json.loads(document).get(key)
            if value is None or isinstance(value, str):
                return value
            return json.dumps(value)
        self.db.create_function('->>', 2, text_value, deterministic=True)

    def execute(self, query, parameters=()):
        return self.db.execute(query.replace('%s', '?'), tuple(
            json.dumps(value.obj) if isinstance(value, Jsonb) else value
            for value in parameters))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class LocalSession(Session):
    def get(self, uid):
        result = super().get(uid)
        return json.loads(result) if result else None


class LocalStore(PostgresStore):
    def __init__(self, connection):
        super().__init__('unused-local-test')
        self.connection = connection

    @contextmanager
    def locked(self, uid):
        yield LocalSession(self.connection)


class PostgresTests(unittest.TestCase):
    def setUp(self):
        self.connection = LocalConnection()
        self.addCleanup(self.connection.db.close)
        self.connect = patch('server.account.postgres.psycopg.connect',
                             return_value=self.connection)
        self.connect.start()
        self.addCleanup(self.connect.stop)
        self.session = LocalSession(self.connection)
        self.store = LocalStore(self.connection)

    def legacy_schema(self):
        self.connection.db.executescript('''
            CREATE TABLE account_deletions (
                uid text PRIMARY KEY, state text NOT NULL,
                delete_after double precision NOT NULL, record jsonb NOT NULL
            );
        ''')

    def test_due_respects_retry_for_cleanup_and_cancel_recovery_on_old_schema(self):
        self.legacy_schema()
        for uid, state, deadline, fields in (
                ('legacy', 'pending', 100, {}),
                ('later', 'pending', 201, {}),
                ('retry', 'deleting', 90, {'next_attempt': 201}),
                ('recover', 'cancelled', 300, {'fence_owned': True}),
                ('recover-later', 'cancelled', 50, {'fence_owned': True, 'next_attempt': 201}),
                ('cancelled', 'cancelled', 50, {'fence_owned': False}),
                ('deleted', 'deleted', 50, {})):
            self.session.save(dict(uid=uid, state=state, delete_after=deadline, **fields))
        self.assertEqual(self.store.due(200), ['legacy', 'recover'])
        self.assertEqual(self.store.due(201), ['legacy', 'later', 'recover', 'recover-later', 'retry'])

    def test_poison_first_100_with_production_due_query(self):
        self.legacy_schema()
        for index in range(101):
            self.session.save(dict(uid=f'user-{index:03}', request_id=f'request-{index:03}',
                                   state='deleting', delete_after=1000 + index,
                                   fence_owned=True, completed=[], cleanup_context={}))
        data = Data()
        def poison(uid, context):
            if uid != 'user-100':
                raise RuntimeError('poison')
        data.revoke_keys = poison
        now = [100000]
        service = Lifecycle(self.store, Admin(), data, lambda: now[0])
        self.assertEqual(sweep(service), 100)
        # Even if earlier failures are eligible again, unattempted work leads.
        now[0] += 120
        restarted = Lifecycle(LocalStore(self.connection), service.admin, data, lambda: now[0])
        self.assertEqual(restarted.store.due(now[0])[0], 'user-100')
        self.assertEqual(sweep(restarted), 99)
        self.assertEqual(self.session.get('user-100')['state'], 'deleted')

    def test_retry_order_uses_attempts_and_stable_uid_tiebreak(self):
        self.legacy_schema()
        for uid, attempts, deadline in (('b', 1, 20), ('a', 1, 20), ('c', 2, 10)):
            self.session.save(dict(uid=uid, state='deleting', delete_after=deadline,
                                   next_attempt=100, attempts=attempts))
        self.assertEqual(self.store.due(100), ['a', 'b', 'c'])

    def test_coalesced_ids_survive_json_roundtrip_and_new_session(self):
        self.legacy_schema()
        now = [1000]
        admin, data = Admin(), Data()
        claims = {'uid': 'alice', 'auth_time': 1000,
                  'firebase': {'sign_in_provider': 'phone'}}
        service = Lifecycle(self.store, admin, data, lambda: now[0])
        first = service.request(claims, 'request-aaaa')
        self.assertEqual(service.request(claims, 'request-bbbb'), first)
        now[0] = claims['auth_time'] = 1001
        service.cancel(claims)
        restarted = Lifecycle(LocalStore(self.connection), admin, data, lambda: now[0])
        self.assertEqual(restarted.request(claims, 'request-bbbb')['state'], 'cancelled')
        restarted.request(claims, 'request-cccc')
        with self.assertRaisesRegex(AccountError, 'request_already_completed'):
            restarted.request(claims, 'request-bbbb')
        self.assertEqual(self.session.get('alice')['request_id'], 'request-cccc')

    def test_additive_migration_is_repeatable_and_preserves_old_records(self):
        self.legacy_schema()
        row = dict(uid='alice', request_id='request-old', state='cancelled',
                   delete_after=100, fence_owned=True, previous_requests=['request-older'])
        self.session.save(row)
        migration = (ACCOUNT / 'migrations' / '002_retry_schedule.sql').read_text()
        self.connection.db.executescript(migration)
        self.connection.db.executescript(migration)
        self.assertEqual(self.session.get('alice'), row)
        self.assertEqual(self.store.due(100), ['alice'])
        row.update(attempts=1, next_attempt=160)
        self.session.save(row)
        self.assertEqual(self.store.due(100), [])
        self.assertEqual(self.store.due(160), ['alice'])

    def test_fresh_schema_can_also_apply_migration(self):
        self.connection.db.executescript((ACCOUNT / 'schema.sql').read_text())
        self.connection.db.executescript(
            (ACCOUNT / 'migrations' / '002_retry_schedule.sql').read_text())
        self.session.save(dict(uid='alice', state='pending', delete_after=100))
        self.assertEqual(self.store.due(100), ['alice'])
