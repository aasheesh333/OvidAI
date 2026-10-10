"""Retention against an isolated schema in an explicitly disposable PostgreSQL."""

import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from uuid import uuid4

import psycopg
import pytest
from psycopg import sql

from server.sync.canonical import canonical_bytes
from server.sync.dto import ActivityPayload, UsagePayload
from server.sync.errors import SyncError
from server.sync.postgres import PostgresSyncRepository
from server.sync.tests.test_memory_repository import record, tombstone, TS


DAY = 86400


@pytest.fixture(scope="session")
def retention_dsn():
    explicit = os.environ.get("SYNC_TEST_DATABASE_URL")
    if explicit:
        yield explicit
        return
    name = "ovid-sync-retention-" + uuid4().hex
    subprocess.run([
        "docker", "run", "--detach", "--rm", "--name", name,
        "--tmpfs", "/var/lib/postgresql/data",
        "-p", "127.0.0.1:55441:5432", "-e", "POSTGRES_PASSWORD=retention-test",
        "-e", "POSTGRES_DB=retention_test", "postgres:16-alpine",
    ], check=True, capture_output=True)
    try:
        dsn = "postgresql://postgres:retention-test@127.0.0.1:55441/retention_test"
        for _ in range(300):
            try:
                with psycopg.connect(dsn, connect_timeout=1):
                    break
            except psycopg.OperationalError as exc:
                last_error = str(exc)
                time.sleep(0.1)
        else:
            logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
            pytest.fail(f"disposable PostgreSQL did not become ready: {last_error}\n{logs.stdout}\n{logs.stderr}")
        yield dsn
    finally:
        subprocess.run(["docker", "rm", "--force", name], check=True, capture_output=True)


@pytest.fixture
def setup(retention_dsn):
    schema = "retention_test_" + uuid4().hex
    with psycopg.connect(retention_dsn, autocommit=True) as db:
        db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        try:
            db.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
            root = Path(__file__).resolve().parents[2] / "account"
            db.execute((root / "schema.sql").read_text())
            db.execute((root / "schema_private_sync.sql").read_text())
            now = [1800000000.0]
            repo = PostgresSyncRepository(dsn=retention_dsn, schema=schema, clock=lambda: now[0])
            device = repo.enroll("acct", True, "phone", "enroll").device_id
            yield repo, device, now, db
        finally:
            db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))


def fail(code, operation):
    with pytest.raises(SyncError) as caught:
        operation()
    assert caught.value.code == code


def drain(repo, limit=2):
    total = 0
    for _ in range(100):
        count = repo.purge_expired(limit=limit)
        assert 0 <= count <= limit
        total += count
        if count < limit:
            return total
    pytest.fail("retention made no bounded progress")


def ledger_matches(db):
    actual = db.execute("SELECT retained_bytes, retained_records FROM sync_retained_bytes WHERE account_id='acct'").fetchone()
    expected = db.execute("""SELECT COALESCE(sum(n),0),count(*) FROM (
        SELECT canonical_length n FROM sync_records WHERE account_id='acct' AND canonical_bytes IS NOT NULL
        UNION ALL SELECT canonical_length FROM sync_retention_markers WHERE account_id='acct') content""").fetchone()
    assert actual == expected


def activity(device, identity, *, status="started", request="req", usage=None):
    return replace(record(identity, device=device), record_type="activity", payload=ActivityPayload(
        request, "attempt", "request", status, TS, "A request", "verbose detail " * 100, usage))


def seed_compaction(repo, device):
    usage = replace(record("usage", device=device), record_type="usage", payload=UsagePayload(
        "req", "usage", None, None, "succeeded", 2, 3, 5, "providerReported", TS, TS, 1))
    records = (
        activity(device, "detail-a"), activity(device, "detail-b"),
        activity(device, "terminal", status="succeeded", usage="usage"),
        activity(device, "unresolved", request="other"),
        activity(device, "with-usage", usage="usage"), usage, record(device=device),
    )
    assert all(r.status == "accepted" for r in repo.admit_batch("acct", device, "initial", records).results)
    return records


def test_bounded_expiry_restarts_progress_past_idle_accounts(setup):
    repo, device, now, db = setup
    repo.enroll("aaa-idle", True, "idle", "idle")
    later = repo.enroll("zzz-work", True, "later", "later").device_id
    repo.admit_batch("zzz-work", later, "upload", (record(device=later),))
    repo.admit_batch("acct", device, "upload", (record(device=device),))
    repo.changes("acct", device)
    now[0] += 30 * DAY
    # Every call is a new process-equivalent repository; no in-memory sweep cursor.
    for _ in range(30):
        restarted = PostgresSyncRepository(dsn=repo._dsn, schema=repo.schema, clock=lambda: now[0])
        count = restarted.purge_expired(limit=1)
        assert count in (0, 1)
        if not count:
            break
    else:
        pytest.fail("expired rows did not drain")
    for table in ("sync_cursors", "sync_idempotency", "sync_rate_windows", "sync_ingest_admissions"):
        assert db.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))).fetchone()[0] == 0
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 2


@pytest.mark.parametrize("limit", [0, -1, True, 1.5, 10001])
def test_invalid_limits(setup, limit):
    repo, _, _, _ = setup
    with pytest.raises(ValueError):
        repo.purge_expired(limit=limit)


def test_exact_expiry_boundaries_preserve_current_windows(setup):
    repo, device, now, db = setup
    repo.admit_batch("acct", device, "upload", (record(device=device),))
    repo.changes("acct", device)
    issued = now[0]
    now[0] += 59
    assert repo.purge_expired() == 0
    now[0] += 1
    assert repo.purge_expired() == 3  # upload account/device plus replay rate windows
    now[0] = issued + DAY - 1
    assert repo.purge_expired() == 0
    now[0] += 1
    assert repo.purge_expired() == 1
    assert db.execute("SELECT count(*) FROM sync_idempotency").fetchone()[0] == 2


def test_late_cursor_extends_horizon_even_after_cursor_is_removed(setup):
    repo, device, now, db = setup
    repo.admit_batch("acct", device, "initial", (record("first", device=device),))
    repo.admit_batch("acct", device, "delete", (tombstone(device=device, revision=4),))
    deletion_time = now[0]
    now[0] += 10 * DAY
    cursor = repo.bootstrap("acct", device, limit=1).current_cursor
    expiry = db.execute("SELECT expires_at FROM sync_cursors WHERE cursor_id=%s", (cursor,)).fetchone()[0]
    now[0] = deletion_time + 30 * DAY
    drain(repo)
    assert db.execute("SELECT purge_after FROM sync_records WHERE record_type='tombstone'").fetchone()[0] == expiry + 30 * DAY
    now[0] = expiry
    drain(repo)
    assert db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0] == 0
    assert not repo.bootstrap("acct", device).retention_markers
    now[0] = expiry + 30 * DAY - 1
    drain(repo)
    assert not repo.bootstrap("acct", device).retention_markers
    now[0] += 1
    drain(repo)
    fail("reset_required", lambda: repo.changes("acct", device))
    page = repo.bootstrap("acct", device)
    assert [r.record_id for r in page.records] == ["first"]
    assert json.loads(page.retention_markers[0])["markerKind"] == "tombstone_expiry"
    assert repo.changes("acct", device, page.current_cursor).records == ()
    stale = repo.admit_batch("acct", device, "late", (record(device=device, revision=3),))
    assert stale.results[0].status == "duplicate"
    assert repo.admit_batch("acct", device, "new", (record(device=device, revision=5),)).results[0].status == "accepted"
    ledger_matches(db)


def test_compaction_preserves_terminal_usage_transcript_and_emits_one_summary(setup):
    repo, device, now, db = setup
    records = seed_compaction(repo, device)
    now[0] += 30 * DAY - 1
    drain(repo)
    assert db.execute("SELECT count(*) FROM sync_retention_markers").fetchone()[0] == 0
    now[0] += 1
    drain(repo, limit=1)
    fail("reset_required", lambda: repo.changes("acct", device))
    page = repo.bootstrap("acct", device)
    assert {r.record_id for r in page.records} == {"terminal", "unresolved", "with-usage", "usage", "rec-1"}
    assert len(page.retention_markers) == 1
    marker = json.loads(page.retention_markers[0])
    assert marker["markerKind"] == "activity_compaction"
    assert marker["logicalRequestId"] == "req"
    assert marker["freedRecords"] == 2
    assert marker["summary"] == {"terminalRecordId": "terminal", "status": "succeeded", "updatedAt": TS, "usageRecordId": "usage"}
    assert canonical_bytes(marker).decode() == page.retention_markers[0]
    assert repo.changes("acct", device, page.current_cursor).records == ()
    assert repo.admit_batch("acct", device, "stale", (records[0],)).results[0].status == "duplicate"
    ledger_matches(db)
    assert repo.purge_expired() == 0


def test_failure_rolls_back_marker_bytes_and_sequence_then_retry_is_idempotent(setup):
    repo, device, now, db = setup
    seed_compaction(repo, device)
    now[0] += 30 * DAY
    db.execute("""CREATE FUNCTION reject_marker() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'injected retention failure'; END $$""")
    db.execute("CREATE TRIGGER reject_marker BEFORE INSERT ON sync_retention_markers FOR EACH ROW EXECUTE FUNCTION reject_marker()")
    before = db.execute("SELECT retained_bytes,retained_records FROM sync_retained_bytes").fetchone()
    fail("temporarily_unavailable", lambda: repo.purge_expired())
    assert db.execute("SELECT retained_bytes,retained_records FROM sync_retained_bytes").fetchone() == before
    assert db.execute("SELECT last_change_sequence FROM sync_sequence_allocators").fetchone()[0] == 7
    assert db.execute("SELECT count(*) FROM sync_records WHERE NOT tombstoned").fetchone()[0] == 7
    assert db.execute("SELECT count(*) FROM sync_idempotency").fetchone()[0] == 2
    db.execute("DROP TRIGGER reject_marker ON sync_retention_markers")
    drain(repo)
    assert repo.purge_expired() == 0
    assert db.execute("SELECT count(*) FROM sync_retention_markers").fetchone()[0] == 1
    ledger_matches(db)


def test_row_lock_skip_and_lifecycle_advisory_lock_and_permanent_fences(setup):
    repo, device, now, db = setup
    seed_compaction(repo, device)
    other = repo.enroll("other", True, "other", "enroll").device_id
    repo.admit_batch("other", other, "upload", (record(device=other),))
    repo.delete_account("deleted")
    db.execute("INSERT INTO account_deletions VALUES ('other','pending',0,'{}')")
    now[0] += 30 * DAY
    db.execute("SELECT pg_advisory_lock(hashtextextended('acct',714031))")
    try:
        with db.transaction():
            db.execute("SELECT account_id FROM sync_accounts WHERE account_id='acct' FOR UPDATE")
            with ThreadPoolExecutor(max_workers=1) as pool:
                assert pool.submit(repo.purge_expired).result(timeout=3) == 0
        with ThreadPoolExecutor(max_workers=2) as pool:
            counts = list(pool.map(lambda _: repo.purge_expired(), range(2)))
        assert sum(counts) > 0
    finally:
        db.execute("SELECT pg_advisory_unlock(hashtextextended('acct',714031))")
    assert db.execute("SELECT state FROM sync_accounts WHERE account_id='deleted'").fetchone()[0] == "deleted"
    assert db.execute("SELECT state FROM account_deletions WHERE uid='other'").fetchone()[0] == "pending"
    assert db.execute("SELECT count(*) FROM sync_records WHERE account_id='other'").fetchone()[0] == 1
    assert db.execute("SELECT count(*) FROM sync_retention_markers").fetchone()[0] == 1
    ledger_matches(db)


def test_one_item_compaction_budget_and_snapshot_handoff(setup):
    repo, device, now, db = setup
    seed_compaction(repo, device)
    now[0] += 30 * DAY - 1
    drain(repo)
    snapshot = repo.bootstrap("acct", device, limit=1)
    now[0] += 1
    assert repo.purge_expired(limit=1) == 1
    assert db.execute("SELECT count(*) FROM sync_records WHERE tombstoned").fetchone()[0] == 1
    marker = db.execute("SELECT change_sequence,freed_records FROM sync_retention_markers").fetchone()
    assert marker == (8, 1)
    ledger_matches(db)
    assert repo.purge_expired(limit=1) == 1
    assert db.execute("SELECT count(*) FROM sync_records WHERE tombstoned").fetchone()[0] == 2
    assert db.execute("SELECT change_sequence,freed_records FROM sync_retention_markers").fetchone() == (9, 2)
    # Finish a snapshot pinned before compaction; its live handoff must reset.
    continuation = repo.bootstrap("acct", device, snapshot.current_cursor)
    assert not continuation.retention_markers
    fail("reset_required", lambda: repo.changes("acct", device, continuation.current_cursor))
    rebuilt = repo.bootstrap("acct", device)
    assert len(rebuilt.retention_markers) == 1
    assert repo.changes("acct", device, rebuilt.current_cursor).records == ()
    ledger_matches(db)


def test_legacy_cursor_horizon_is_saved_before_expiry_and_fence_survives(setup):
    repo, device, now, db = setup
    repo.admit_batch("acct", device, "initial", (record(device=device),))
    repo.admit_batch("acct", device, "delete", (tombstone(device=device, revision=4),))
    deleted = now[0]
    # A cursor issued by the repository version predating horizon persistence.
    db.execute("""INSERT INTO sync_cursors
        (account_id,cursor_id,device_id,position,issued_at,last_used_at,expires_at)
        VALUES ('acct','legacy',%s,0,%s,%s,%s)""",
               (device, deleted + DAY, deleted + DAY, deleted + 2 * DAY))
    now[0] += 31 * DAY
    drain(repo, limit=1)
    assert db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0] == 0
    assert db.execute("SELECT purge_after FROM sync_records WHERE record_type='tombstone'").fetchone()[0] == deleted + 32 * DAY
    assert db.execute("SELECT count(*) FROM sync_retention_markers").fetchone()[0] == 0
    now[0] += DAY
    drain(repo, limit=1)
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 2
    assert repo.admit_batch("acct", device, "stale", (record(device=device, revision=3),)).results[0].status == "duplicate"
    assert not repo.bootstrap("acct", device).records
    ledger_matches(db)


def test_missing_schema_fails_closed_without_ddl(setup):
    repo, _, _, db = setup
    absent = "missing_" + uuid4().hex
    missing = PostgresSyncRepository(dsn=repo._dsn, schema=absent)
    fail("temporarily_unavailable", missing.purge_expired)
    assert db.execute("SELECT count(*) FROM pg_namespace WHERE nspname=%s", (absent,)).fetchone()[0] == 0


def test_older_deletion_barrier_cannot_resurrect_compacted_revision(setup):
    repo, device, now, db = setup
    detail = replace(activity(device, "detail"), revision=3)
    repo.admit_batch("acct", device, "initial", (
        detail, activity(device, "terminal", status="succeeded")))
    now[0] += 30 * DAY
    drain(repo)
    repo.admit_batch("acct", device, "old-deletion", (tombstone("detail", device=device, revision=1),))
    result = repo.admit_batch("acct", device, "stale", (replace(detail, revision=2),))
    assert result.results[0].status == "duplicate"
    assert db.execute("SELECT canonical_bytes FROM sync_records WHERE record_id='detail'").fetchone()[0] is None
    ledger_matches(db)
