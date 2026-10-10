"""Runtime-composed cleanup on a real, isolated PostgreSQL schema."""
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from server.account import runtime
from server.account.composition import CleanupData
from server.account.domain import Lifecycle
from server.account.postgres import PostgresStore
from server.sync.errors import SyncError
from server.sync.postgres import PostgresSyncRepository
from server.sync.tests.postgres_schema_helper import PostgresSchemaTest
from test_lifecycle import Admin, Data
from wave2_cleanup_test import CLAIMS, configured


class RuntimePostgresCleanupTest(PostgresSchemaTest):
    def test_disabled_http_still_cleans_concrete_sync_before_auth_and_fences_restart(self):
        from psycopg.conninfo import make_conninfo

        account = Path(__file__).resolve().parents[1]
        self.apply(account / 'schema.sql')
        self.apply(account / 'schema_private_sync.sql')
        # Scope the lifecycle connection and sync repository to this test's
        # schema; no public tables or production configuration are touched.
        dsn = make_conninfo(self.dsn, options=f'-c search_path={self.schema}')
        authority = PostgresStore(dsn)
        env = {'ACCOUNT_DATABASE_URL': dsn, 'PRIVATE_SYNC_CONFIGURED': 'true',
               'PRIVATE_SYNC_ACTIVATED': 'false',
               'PRIVATE_SYNC_AUTHORITY_ID': '33333333-3333-4333-8333-333333333333'}
        with patch.dict('os.environ', env, clear=True):
            repository, collaboration = runtime._shared_repositories(authority)
        self.assertIsInstance(repository, PostgresSyncRepository)
        self.assertEqual(repository._dsn, dsn)
        self.assertIsNone(collaboration)
        repository.schema = self.schema
        repository.enroll('alice', True, 'phone', 'enroll-alice')
        repository.enroll('bob', True, 'phone', 'enroll-bob')

        with TemporaryDirectory() as directory:
            _, stores = configured(Path(directory))
            now, admin = [1000], Admin()
            service = Lifecycle(authority, admin, CleanupData(Data(), stores,
                                private_sync=repository), lambda: now[0])
            service.request(CLAIMS, 'delete-alice')
            now[0] = 87400
            service.finalize('alice')
            now[0] += 60
            # Observe the real database at the external Auth deletion boundary.
            delete_auth = admin.delete

            def checked_delete(uid):
                self.assertEqual(self.db.execute(
                    'SELECT state FROM sync_accounts WHERE account_id=%s', (uid,)
                ).fetchone(), ('deleted',))
                self.assertEqual(self.db.execute(
                    'SELECT count(*) FROM sync_devices WHERE account_id=%s', (uid,)
                ).fetchone(), (0,))
                return delete_auth(uid)

            admin.delete = checked_delete
            self.assertEqual(service.finalize('alice')['state'], 'deleted')
            self.assertNotIn('alice', admin.users)
            self.assertEqual(self.db.execute(
                "SELECT count(*) FROM sync_devices WHERE account_id='bob'"
            ).fetchone(), (1,))
            with authority.locked('alice') as session:
                self.assertIn('data:private_sync', session.get('alice')['completed'])

        with patch.dict('os.environ', env, clear=True):
            restarted, _ = runtime._shared_repositories(authority)
        restarted.schema = self.schema
        restarted.delete_account('alice')  # acknowledged replay remains idempotent
        with self.assertRaises(SyncError) as caught:
            restarted.enroll('alice', True, 'new-phone', 'enroll-again')
        self.assertEqual(caught.exception.code, 'account_fenced')
