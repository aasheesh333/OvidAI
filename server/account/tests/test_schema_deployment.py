"""Deployment-contract tests for the account PostgreSQL schemas.

Static checks run everywhere. Live checks use SYNC_TEST_DATABASE_URL with
psycopg and a unique schema per test, or an unprivileged local initdb cluster.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from server.sync.tests.postgres_schema_helper import PostgresSchemaTest

ROOT = Path(__file__).resolve().parents[3]
ACCOUNT = ROOT / "server" / "account"
SCHEMA = ACCOUNT / "schema.sql"
SYNC_SCHEMA = ACCOUNT / "schema_private_sync.sql"
MIGRATION = ACCOUNT / "migrations" / "003_private_sync.sql"


def without_comments(sql: str) -> str:
    return re.sub(r"--[^\n]*", "", sql)


def normalized(sql: str) -> str:
    return re.sub(r"\s+", " ", without_comments(sql)).strip().lower()


class AccountSchemaDeploymentTest(unittest.TestCase):
    def test_fresh_private_sync_schema_matches_upgrade_migration(self) -> None:
        fresh = normalized(SYNC_SCHEMA.read_text(encoding="utf-8"))
        migration = normalized(MIGRATION.read_text(encoding="utf-8"))
        self.assertEqual(fresh[fresh.index("begin;") :], migration[migration.index("begin;") :])

    def test_tombstone_trigger_is_guarded_and_permanent(self) -> None:
        sql = without_comments(MIGRATION.read_text(encoding="utf-8"))
        self.assertRegex(
            sql,
            r"(?is)if\s+not\s+exists\s*\(\s*select.*?from\s+pg_trigger"
            r".*?tgname\s*=\s*'sync_accounts_tombstone_guard'",
        )
        self.assertRegex(
            sql,
            r"(?is)before\s+update\s+or\s+delete\s+on\s+sync_accounts",
        )
        self.assertRegex(
            sql,
            r"(?is)old\.state\s*=\s*'deleted'.*?tombstone\s+is\s+permanent",
        )


class AccountPostgresDeploymentTest(PostgresSchemaTest):
    """Apply actual deployment SQL and verify PostgreSQL behavior."""

    def test_private_sync_schema_uses_builtin_sha256(self) -> None:
        # PostgreSQL 11+ provides sha256(bytea) in pg_catalog, independently of
        # pgcrypto: https://www.postgresql.org/docs/11/functions-binarystring.html
        expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        self.assertEqual(
            self.db.execute("SELECT encode(sha256('abc'::bytea), 'hex')").fetchone(),
            (expected,),
        )
        self.assertEqual(
            self.db.execute(
                "SELECT pronamespace::regnamespace::text FROM pg_proc "
                "WHERE oid = 'sha256(bytea)'::regprocedure"
            ).fetchone(),
            ("pg_catalog",),
        )
        self.apply(SCHEMA)
        self.apply(SYNC_SCHEMA)

    def test_reapplying_migration_keeps_trigger_and_tombstone_permanent(self) -> None:
        self.apply(SCHEMA)
        self.apply(SYNC_SCHEMA)
        self.apply(MIGRATION)
        self.apply(MIGRATION)

        trigger_count = self.db.execute(
            "SELECT count(*) FROM pg_trigger "
            "WHERE tgname = 'sync_accounts_tombstone_guard' "
            "AND tgrelid = 'sync_accounts'::regclass",
        ).fetchone()[0]
        self.assertEqual(trigger_count, 1)

        self.db.execute(
            "INSERT INTO sync_accounts(account_id, state, created_at, fenced_at, deleted_at) "
            "VALUES ('account-1', 'deleted', 1, 2, 3)",
        )
        for statement in (
            "UPDATE sync_accounts SET state = 'active' WHERE account_id = 'account-1'",
            "UPDATE sync_accounts SET created_at = 4 WHERE account_id = 'account-1'",
            "DELETE FROM sync_accounts WHERE account_id = 'account-1'",
        ):
            with self.subTest(statement=statement):
                with self.assertRaises(self.psycopg.errors.CheckViolation) as caught:
                    self.db.execute(statement)
                self.assertIn("tombstone is permanent", str(caught.exception))
                self.assertEqual(caught.exception.sqlstate, "23514")
                self.assertEqual(
                    self.db.execute("SELECT state, created_at FROM sync_accounts").fetchall(),
                    [("deleted", 1.0)],
                )


if __name__ == "__main__":
    unittest.main()
