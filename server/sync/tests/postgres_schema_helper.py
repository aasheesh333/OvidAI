"""Disposable PostgreSQL schema support shared by deployment SQL tests.

Set SYNC_TEST_DATABASE_URL to a test database (including a Docker PostgreSQL
instance) and install psycopg. Each test creates and drops only its own schema.
Without a URL, an unprivileged local initdb/pg_ctl cluster is used if available.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from uuid import uuid4


class PostgresSchemaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.dsn = os.environ.get("SYNC_TEST_DATABASE_URL")
        try:
            import psycopg
        except ImportError:
            if cls.dsn:
                raise RuntimeError("SYNC_TEST_DATABASE_URL requires psycopg") from None
            raise unittest.SkipTest("PostgreSQL schema tests require psycopg") from None
        cls.psycopg = psycopg
        if cls.dsn:
            return
        if not all(shutil.which(binary) for binary in ("initdb", "pg_ctl")):
            raise unittest.SkipTest(
                "set SYNC_TEST_DATABASE_URL or install local initdb and pg_ctl"
            )
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            raise unittest.SkipTest(
                "initdb cannot run as root; set SYNC_TEST_DATABASE_URL"
            )
        work = tempfile.TemporaryDirectory(prefix="schema-pg-", dir="/tmp/opencode")
        cls.addClassCleanup(work.cleanup)
        data = Path(work.name) / "data"
        sock = Path(work.name) / "sock"
        sock.mkdir()
        subprocess.run(
            ["initdb", "-D", str(data), "-A", "trust", "-U", "postgres"],
            check=True, capture_output=True,
        )
        cls.addClassCleanup(
            subprocess.run,
            ["pg_ctl", "-D", str(data), "-m", "immediate", "stop"],
            capture_output=True,
        )
        subprocess.run(
            ["pg_ctl", "-D", str(data), "-w", "-l", str(Path(work.name) / "log"),
             "-o", f"-k {sock} -c listen_addresses='' -p 54329", "start"],
            check=True, capture_output=True,
        )
        cls.dsn = f"host={sock} port=54329 user=postgres dbname=postgres"

    def setUp(self):
        super().setUp()
        from psycopg import sql

        self.db = self.psycopg.connect(self.dsn, autocommit=True)
        self.addCleanup(self.db.close)
        self.schema = "schema_test_" + uuid4().hex
        self.db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(self.schema)))
        self.addCleanup(self.drop_schema)
        # pg_catalog remains implicitly visible; public and other test schemas
        # cannot supply tables, functions, or extensions to these tests.
        self.db.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(self.schema)))

    def drop_schema(self):
        from psycopg import sql

        # Deployment SQL contains explicit BEGIN/COMMIT. Recover even if it
        # failed mid-transaction so cleanup doesn't leak an isolated schema.
        self.db.execute("ROLLBACK")
        self.db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(self.schema)))

    def apply(self, path):
        self.db.execute(path.read_text(encoding="utf-8"))
