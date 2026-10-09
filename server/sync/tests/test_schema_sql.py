"""Static checks for the private-sync PostgreSQL migration and fresh schema.

Fresh installs apply schema.sql (portable account lifecycle) then
schema_private_sync.sql (PostgreSQL only).

Stdlib only. When PostgreSQL server binaries (initdb, pg_ctl, psql) are on
PATH, the files are also applied to a throwaway cluster under
/tmp/opencode/pgtest; otherwise that test is skipped, never claimed as passed.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
ACCOUNT = ROOT / 'server' / 'account'
MIGRATION = ACCOUNT / 'migrations' / '003_private_sync.sql'
SCHEMA = ACCOUNT / 'schema.sql'
SYNC_SCHEMA = ACCOUNT / 'schema_private_sync.sql'
PRE_SYNC_MIGRATION = ACCOUNT / 'migrations' / '002_retry_schedule.sql'

EXPECTED_TABLES = {
    'sync_accounts', 'sync_sequence_allocators', 'sync_devices',
    'sync_records', 'sync_changes', 'sync_idempotency',
    'sync_ingest_admissions', 'sync_retained_bytes', 'sync_cursors',
    'sync_leases', 'sync_rate_windows', 'sync_conflicts',
    'sync_retention_markers',
}
FORBIDDEN_COLUMN_WORDS = (
    'token', 'cookie', 'credential', 'password', 'secret', 'api_key',
    'apikey', 'authorization', 'grant', 'path', 'userinfo', 'endpoint_url',
)
CONSTRAINT_STARTS = ('constraint', 'primary', 'unique', 'check', 'foreign', 'exclude')


def strip_comments(sql: str) -> str:
    return re.sub(r'--[^\n]*', '', sql)


def strip_literals(sql: str) -> str:
    """Remove single-quoted literals (enum values, COMMENT text)."""
    return re.sub(r"'(?:[^']|'')*'", "''", sql)


def table_bodies(sql: str) -> dict:
    sql = strip_comments(sql)
    out = {}
    for match in re.finditer(r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+(\w+)\s*\(', sql, re.I):
        depth, i = 1, match.end()
        while depth:
            depth += {'(': 1, ')': -1}.get(sql[i], 0)
            i += 1
        out[match.group(1)] = sql[match.end():i - 1]
    return out


def split_top_level(body: str) -> list:
    parts, depth, current = [], 0, []
    for ch in body:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(current).strip())
            current = []
        else:
            current.append(ch)
    if ''.join(current).strip():
        parts.append(''.join(current).strip())
    return parts


def columns(body: str) -> list:
    names = []
    for part in split_top_level(body):
        first = part.split()[0].lower()
        if first not in CONSTRAINT_STARTS:
            names.append(first)
    return names


def normalized(text: str) -> str:
    return re.sub(r'\s+', ' ', text).strip().lower()


class MigrationStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = MIGRATION.read_text(encoding='utf-8')
        cls.sql = strip_comments(cls.raw)
        cls.tables = table_bodies(cls.raw)

    def test_creates_exactly_the_expected_tables(self):
        self.assertEqual(set(self.tables), EXPECTED_TABLES)
        creates = re.findall(r'CREATE\s+TABLE\s+(\w+)', self.sql, re.I)
        self.assertEqual(creates, ['IF'] * len(creates), 'every CREATE TABLE must use IF NOT EXISTS')

    def test_is_additive(self):
        code = strip_literals(self.sql)
        for pattern in (r'\bDROP\b', r'\bTRUNCATE\b', r'\bDELETE\s+FROM\b',
                        r'\bALTER\b', r'\bRENAME\b', r'\bUPDATE\s+\w+\s+SET\b'):
            self.assertIsNone(re.search(pattern, code, re.I), pattern)
        self.assertNotRegex(code, r'(?i)\baccount_deletions\b')

    def test_is_idempotent(self):
        code = strip_literals(self.sql)
        for kind in ('TABLE', 'INDEX', 'UNIQUE INDEX'):
            for match in re.finditer(rf'CREATE\s+{kind}\s+(\w+)', code, re.I):
                self.assertEqual(match.group(1).upper(), 'IF', match.group(0))
        for match in re.finditer(r'CREATE\s+(OR\s+REPLACE\s+)?FUNCTION', code, re.I):
            self.assertTrue(match.group(1), 'functions must use CREATE OR REPLACE')
        # Triggers have no IF NOT EXISTS before PG14; require a pg_trigger guard.
        for match in re.finditer(r'CREATE\s+TRIGGER\s+(\w+)', code, re.I):
            preceding = code[:match.start()]
            self.assertRegex(preceding[-400:], rf"(?is)IF\s+NOT\s+EXISTS\s*\(\s*SELECT.*pg_trigger.*tgname\s*=\s*''")
            self.assertIn(f"'{match.group(1)}'", self.sql)
        self.assertNotRegex(code, r'(?i)CREATE\s+(SEQUENCE|TYPE|VIEW|SCHEMA|EXTENSION)\b')

    def test_wrapped_in_one_transaction(self):
        statements = [s.strip() for s in self.sql.strip().split('\n') if s.strip()]
        self.assertEqual(statements[0], 'BEGIN;')
        self.assertEqual(statements[-1], 'COMMIT;')
        self.assertEqual(len(re.findall(r'^\s*BEGIN;\s*$', self.sql, re.M)), 1)
        self.assertEqual(len(re.findall(r'^\s*COMMIT;\s*$', self.sql, re.M)), 1)
        self.assertNotRegex(self.sql, r'(?i)CONCURRENTLY|VACUUM')

    def test_every_table_is_account_keyed(self):
        for name, body in self.tables.items():
            with self.subTest(table=name):
                self.assertIn('account_id', columns(body))
                pk = re.search(r'PRIMARY\s+KEY\s*\(([^)]*)\)', body, re.I)
                if pk:
                    self.assertEqual(pk.group(1).split(',')[0].strip(), 'account_id')
                else:
                    self.assertRegex(body, r'(?i)account_id\s+text\s+PRIMARY\s+KEY')

    def test_no_credential_or_path_columns(self):
        for name, body in self.tables.items():
            for column in columns(body):
                for word in FORBIDDEN_COLUMN_WORDS:
                    self.assertNotIn(word, column, f'{name}.{column}')

    def test_required_uniqueness(self):
        flat = {n: normalized(b) for n, b in self.tables.items()}
        self.assertIn('primary key (account_id, record_id)', flat['sync_records'])
        self.assertIn('unique (account_id, change_sequence)', flat['sync_records'])
        self.assertIn('primary key (account_id, change_sequence)', flat['sync_changes'])
        self.assertIn('primary key (account_id, device_id)', flat['sync_devices'])
        self.assertIn('unique (device_id)', flat['sync_devices'])
        self.assertIn('primary key (account_id, idempotency_key)', flat['sync_idempotency'])
        self.assertIn('unique (account_id, record_id, revision)', flat['sync_ingest_admissions'])
        self.assertIn('unique (account_id, change_sequence)', flat['sync_retention_markers'])
        self.assertIn('account_id text primary key', flat['sync_sequence_allocators'])

    def test_record_storage_shape(self):
        body = normalized(self.tables['sync_records'])
        for column in ('record_type', 'revision', 'canonical_bytes bytea',
                       'canonical_sha256 bytea', 'canonical_length integer',
                       'tombstoned boolean', 'conversation_id', 'logical_request_id'):
            self.assertIn(column, body)
        self.assertIn('canonical_sha256 = sha256(canonical_bytes)', body)
        self.assertIn('between 1 and 262144', body)
        self.assertNotIn('jsonb', body)

    def test_spec_bounds(self):
        leases = normalized(self.tables['sync_leases'])
        self.assertIn('acquired_at + 900', leases)
        self.assertIn('event_bytes <= 1048576', leases)
        rates = normalized(self.tables['sync_rate_windows'])
        for bound in ('request_count <= 60', 'request_count <= 120', 'request_count <= 30'):
            self.assertIn(bound, rates)
        self.assertIn('schema_version = 1', normalized(self.tables['sync_records']))

    def test_replay_cleanup_and_device_indexes(self):
        sql = normalized(self.sql)
        self.assertIn('sync_devices_active on sync_devices (account_id, created_at) where revoked_at is null', sql)
        self.assertIn('primary key (account_id, change_sequence)', normalized(self.tables['sync_changes']))
        self.assertIn('sync_leases_open_device', sql)
        self.assertIn('sync_records_purge_due', sql)

    def test_every_table_commented_with_spec_section(self):
        for name in EXPECTED_TABLES:
            self.assertRegex(self.raw, rf"COMMENT ON TABLE {name} IS\s*\n\s*'[^']*spec:")


class SchemaParityTest(unittest.TestCase):
    def test_fresh_sync_schema_contains_migration_objects(self):
        migration = strip_comments(MIGRATION.read_text(encoding='utf-8'))
        schema_raw = SYNC_SCHEMA.read_text(encoding='utf-8')
        schema = strip_comments(schema_raw)
        self.assertEqual(set(table_bodies(schema_raw)), EXPECTED_TABLES)
        body = migration[migration.index('BEGIN;'):]
        self.assertEqual(normalized(schema[schema.index('BEGIN;'):]), normalized(body))

    def test_existing_account_objects_unchanged(self):
        schema = SCHEMA.read_text(encoding='utf-8')
        self.assertTrue(schema.startswith('-- Run explicitly in the account database'))
        self.assertIn('CREATE TABLE IF NOT EXISTS account_deletions (', schema)
        self.assertIn('account_deletions_retry_due', schema)

    def test_account_schema_has_no_postgres_only_sync_ddl(self):
        """schema.sql is also executed by SQLite-backed tests; keep it portable."""
        raw = SCHEMA.read_text(encoding='utf-8')
        code = strip_comments(raw)
        self.assertEqual(set(table_bodies(raw)), {'account_deletions'})
        self.assertNotIn('Private account sync', raw)
        for pattern in (r'\bsync_\w+', r'\bchar_length\b', r'\bsha256\s*\(',
                        r'\bplpgsql\b', r'^\s*DO\b', r'GENERATED\s+ALWAYS',
                        r'\bbytea\b', r'CREATE\s+(OR\s+REPLACE\s+)?FUNCTION',
                        r'CREATE\s+TRIGGER'):
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, code, re.I | re.M))


PG_BINARIES = ('initdb', 'pg_ctl', 'psql')


@unittest.skipUnless(all(shutil.which(b) for b in PG_BINARIES),
                     'local PostgreSQL binaries (initdb, pg_ctl, psql) not on PATH')
class PostgresApplyTest(unittest.TestCase):
    """Apply schema/migrations to a disposable local cluster on a unix socket."""

    @classmethod
    def setUpClass(cls):
        base = Path('/tmp/opencode/pgtest')
        base.mkdir(parents=True, exist_ok=True)
        cls.work = Path(tempfile.mkdtemp(dir=base))
        cls.data = cls.work / 'data'
        cls.sock = cls.work / 'sock'
        cls.sock.mkdir()
        subprocess.run(['initdb', '-D', str(cls.data), '-A', 'trust', '-U', 'postgres'],
                       check=True, capture_output=True)
        subprocess.run(['pg_ctl', '-D', str(cls.data), '-w', '-l', str(cls.work / 'log'),
                        '-o', f"-k {cls.sock} -c listen_addresses='' -p 54329", 'start'],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        subprocess.run(['pg_ctl', '-D', str(cls.data), '-m', 'immediate', 'stop'],
                       capture_output=True)
        shutil.rmtree(cls.work, ignore_errors=True)

    def psql(self, db, *args, sql=None):
        return subprocess.run(
            ['psql', '-h', str(self.sock), '-p', '54329', '-U', 'postgres', '-d', db,
             '-v', 'ON_ERROR_STOP=1', '-qAt', *args],
            input=sql, check=True, capture_output=True, text=True).stdout

    def create_db(self, name):
        self.psql('postgres', '-c', f'CREATE DATABASE {name}')

    def sync_tables(self, db):
        rows = self.psql(db, '-c', "SELECT tablename FROM pg_tables WHERE tablename LIKE 'sync_%'")
        return set(rows.split())

    def apply_fresh(self, db):
        self.psql(db, '-f', str(SCHEMA))
        self.psql(db, '-f', str(SYNC_SCHEMA))

    def test_fresh_schema_twice(self):
        self.create_db('fresh')
        self.apply_fresh('fresh')
        self.apply_fresh('fresh')
        self.assertEqual(self.sync_tables('fresh'), EXPECTED_TABLES)

    def test_upgrade_pre_sync_preserves_rows_and_reapplies(self):
        self.create_db('upgrade')
        self.psql('upgrade', '-f', str(SCHEMA))
        self.psql('upgrade', '-f', str(PRE_SYNC_MIGRATION))
        self.psql('upgrade', '-c', "INSERT INTO account_deletions VALUES ('u1','pending',1,'{}')")
        self.psql('upgrade', '-f', str(MIGRATION))
        self.psql('upgrade', '-f', str(MIGRATION))
        self.assertEqual(self.sync_tables('upgrade'), EXPECTED_TABLES)
        self.assertEqual(self.psql('upgrade', '-c', 'SELECT count(*) FROM account_deletions').strip(), '1')

    def test_constraints_and_permanent_tombstone(self):
        self.create_db('behaviour')
        self.apply_fresh('behaviour')
        self.psql('behaviour', sql="""
            INSERT INTO sync_accounts VALUES ('a','active',0,NULL,NULL);
            INSERT INTO sync_devices VALUES ('a','d1','Phone',1,0,0,NULL,NULL);
            INSERT INTO sync_records (account_id, record_id, record_type, schema_version,
                source_device_id, revision, change_sequence, canonical_bytes,
                canonical_sha256, canonical_length, accepted_at, updated_at)
            VALUES ('a','r1','transcript',1,'d1',1,1,'\\x7b7d',sha256('\\x7b7d'),2,0,0);
        """)
        bad = [
            # duplicate change_sequence within an account
            """INSERT INTO sync_records (account_id, record_id, record_type, schema_version,
                source_device_id, revision, change_sequence, canonical_bytes,
                canonical_sha256, canonical_length, accepted_at, updated_at)
               VALUES ('a','r2','transcript',1,'d1',1,1,'\\x7b7d',sha256('\\x7b7d'),2,0,0)""",
            # digest mismatch
            """INSERT INTO sync_records (account_id, record_id, record_type, schema_version,
                source_device_id, revision, change_sequence, canonical_bytes,
                canonical_sha256, canonical_length, accepted_at, updated_at)
               VALUES ('a','r3','transcript',1,'d1',1,2,'\\x7b7d',sha256('\\x00'),2,0,0)""",
            # device id recycled under another account
            "INSERT INTO sync_accounts VALUES ('b','active',0,NULL,NULL);"
            "INSERT INTO sync_devices VALUES ('b','d1','Tab',1,0,0,NULL,NULL)",
        ]
        for statement in bad:
            with self.subTest(statement=statement[:40]):
                with self.assertRaises(subprocess.CalledProcessError):
                    self.psql('behaviour', sql=f'BEGIN; {statement}; COMMIT;')
        self.psql('behaviour', '-c', "UPDATE sync_accounts SET state='fenced', fenced_at=1 WHERE account_id='a'")
        self.psql('behaviour', '-c', "UPDATE sync_accounts SET state='deleted', deleted_at=2 WHERE account_id='a'")
        for statement in ("UPDATE sync_accounts SET state='active' WHERE account_id='a'",
                          "DELETE FROM sync_accounts WHERE account_id='a'"):
            with self.assertRaises(subprocess.CalledProcessError):
                self.psql('behaviour', '-c', statement)


if __name__ == '__main__':
    unittest.main()
