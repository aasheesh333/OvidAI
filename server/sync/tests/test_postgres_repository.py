"""Real PostgreSQL contract tests; only an explicit disposable test DSN is used."""

import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from uuid import uuid4

import pytest

from server.sync.canonical import canonical_bytes
from server.sync.errors import SyncError
from server.sync.repository import PostgresSyncRepository
from server.sync.results import BatchResult, ChangePage, DeviceEnrollment, StatePage
from server.sync.tests.test_memory_repository import record, tombstone


@pytest.fixture
def database():
    dsn = os.environ.get("SYNC_TEST_DATABASE_URL")
    if not dsn:
        pytest.skip("set SYNC_TEST_DATABASE_URL to an explicitly disposable PostgreSQL database")
    psycopg = pytest.importorskip("psycopg")
    from psycopg import sql
    schema = "sync_test_" + uuid4().hex
    with psycopg.connect(dsn, autocommit=True) as db:
        db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        db.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(schema)))
        root = Path(__file__).resolve().parents[2] / "account"
        db.execute((root / "schema.sql").read_text())
        db.execute((root / "schema_private_sync.sql").read_text())
        try:
            yield dsn, schema, db
        finally:
            db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))


@pytest.fixture
def setup(database):
    dsn, schema, db = database
    now = [1800000000.0]
    repo = PostgresSyncRepository(dsn=dsn, schema=schema, clock=lambda: now[0])
    device = repo.enroll("acct", True, "phone", "enroll").device_id
    return repo, device, now, db


def error(code, operation):
    with pytest.raises(SyncError) as caught:
        operation()
    assert caught.value.code == code
    return caught.value


def test_restart_replays_idempotency_and_cursor(setup, database):
    repo, device, now, db = setup
    upload = record(device=device)
    result = repo.admit_batch("acct", device, "batch", (upload,))
    assert isinstance(result, BatchResult)
    assert result.results[0].change_sequence == 1
    page = repo.changes("acct", device)
    assert isinstance(page, ChangePage)
    restarted = PostgresSyncRepository(dsn=database[0], schema=database[1], clock=lambda: now[0])
    assert restarted.admit_batch("acct", device, "batch", (upload,)) == result
    assert restarted.changes("acct", device, page.next_cursor).records == ()
    assert restarted.enroll("acct", True, "phone", "enroll").device_id == device
    error("integrity_conflict", lambda: restarted.admit_batch(
        "acct", device, "batch", (record(device=device, text="changed"),)))
    error("integrity_conflict", lambda: repo.enroll("acct", True, "tablet", "enroll"))
    error("integrity_conflict", lambda: repo.admit_batch("acct", device, "enroll", (upload,)))
    assert db.execute("SELECT count(*) FROM sync_ingest_admissions").fetchone()[0] == 1


def test_conflicts_stale_and_source_binding(setup):
    repo, device, _, db = setup
    first = record(device=device, revision=2)
    batch = repo.admit_batch("acct", device, "initial", (first,))
    changed = replace(first, revision=3, payload=replace(first.payload, display_title="new"))
    result = repo.admit_batch("acct", device, "mixed", (
        record("spoof", device="another"), record(device=device),
        record(device=device, revision=3, text="different"), changed))
    assert [r.status for r in result.results] == ["rejected", "duplicate", "conflict", "accepted"]
    assert result.results[1].change_sequence == batch.results[0].change_sequence
    assert result.results[3].change_sequence == 2
    assert db.execute("SELECT count(*) FROM sync_conflicts").fetchone()[0] == 1
    assert [r.change_sequence for r in repo.changes("acct", device).records] == [2]


def test_concurrent_enrollment_and_upload_are_serialized(setup, database):
    repo, device, now, db = setup
    def enroll(i):
        try:
            return repo.enroll("acct", True, str(i), "enroll-" + str(i))
        except SyncError as exc:
            return exc.code
    with ThreadPoolExecutor(max_workers=12) as pool:
        enrolled = list(pool.map(enroll, range(12)))
    assert sum(isinstance(item, DeviceEnrollment) for item in enrolled) == 9
    assert enrolled.count("quota_exhausted") == 3
    def upload(i):
        other = PostgresSyncRepository(dsn=database[0], schema=database[1], clock=lambda: now[0])
        return other.admit_batch("acct", device, "same", (record(device=device),))
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(upload, range(8)))
    assert all(result == results[0] for result in results)
    assert db.execute("SELECT last_change_sequence FROM sync_sequence_allocators").fetchone()[0] == 1


def test_revoke_is_idempotent_including_self_and_invalidates_access(setup):
    repo, device, _, db = setup
    cursor = repo.changes("acct", device).next_cursor
    error("invalid_request", lambda: repo.revoke("acct", device, device, "no-auth"))
    result = repo.revoke("acct", device, device, "revoke", True)
    assert result.status == "revoked"
    assert repo.revoke("acct", device, device, "revoke", True) == result
    error("integrity_conflict", lambda: repo.revoke("acct", device, "other", "revoke", True))
    error("device_revoked", lambda: repo.changes("acct", device, cursor))
    assert db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0] == 0
    assert repo.enroll("acct", True, "replacement", "replacement").device_id != device


def test_retained_quota_exact_boundary_and_tombstone_byte_release(setup):
    repo, device, _, db = setup
    upload = record(device=device)
    repo.admit_batch("acct", device, "initial", (upload,))
    update = replace(upload, revision=2, payload=replace(upload.payload, display_title="a"))
    # null -> "a" shrinks the record by one byte; sequence/revision stay one digit.
    db.execute("UPDATE sync_retained_bytes SET retained_bytes=104857600")
    assert repo.admit_batch("acct", device, "shrink", (update,)).results[0].status == "accepted"
    assert db.execute("SELECT retained_bytes FROM sync_retained_bytes").fetchone()[0] == 104857599
    update = replace(update, revision=3, payload=replace(update.payload, display_title="ab"))
    assert repo.admit_batch("acct", device, "exact", (update,)).results[0].status == "accepted"
    assert db.execute("SELECT retained_bytes FROM sync_retained_bytes").fetchone()[0] == 104857600
    # Restore the real ledger and prove deletion frees the target bytes exactly.
    db.execute("UPDATE sync_retained_bytes SET retained_bytes=(SELECT sum(canonical_length) FROM sync_records)")
    repo.admit_batch("acct", device, "delete", (tombstone(device=device, revision=4),))
    remaining = repo.changes("acct", device).records
    assert [r.record_type for r in remaining] == ["tombstone"]
    assert db.execute("SELECT retained_bytes,retained_records FROM sync_retained_bytes").fetchone() == (
        len(canonical_bytes(remaining[0].to_wire())), 1)


def test_batch_boundaries_and_per_record_oversize_do_not_allocate_sequences(setup):
    repo, device, _, db = setup
    error("payload_too_large", lambda: repo.admit_batch("acct", device, "too-many", tuple(
        record(str(i), device=device) for i in range(101))))
    oversized = record("large", device=device, text="x" * 262144)
    result = repo.admit_batch("acct", device, "mixed", (oversized, record(device=device)))
    assert result.results[0].error.code == "payload_too_large"
    assert result.results[1].change_sequence == 1
    assert db.execute("SELECT count(*) FROM sync_ingest_admissions").fetchone()[0] == 1


@pytest.mark.parametrize("state", ["pending", "fenced", "deleting", "deleted"])
def test_lifecycle_states_fence_replay_and_mutation(setup, state):
    repo, device, _, db = setup
    db.execute("INSERT INTO account_deletions VALUES ('acct',%s,0,'{}')", (state,))
    for operation in (
        lambda: repo.changes("acct", device),
        lambda: repo.bootstrap("acct", device),
        lambda: repo.admit_batch("acct", device, "batch", (record(device=device),)),
        lambda: repo.revoke("acct", device, device, "revoke", True),
    ):
        error("account_fenced", operation)
    repo.delete_account("acct")
    assert db.execute("SELECT state FROM sync_accounts").fetchone()[0] == "deleted"


def test_retention_markers_request_reset_and_are_in_bounded_bootstrap(setup):
    repo, device, _, db = setup
    db.execute("""INSERT INTO sync_retention_markers
        (account_id, marker_kind, change_sequence, through_change_sequence, canonical_bytes,
         canonical_sha256, canonical_length, created_at)
        VALUES ('acct','retention_action',1,0,'{}',sha256('{}'),2,0)""")
    db.execute("UPDATE sync_sequence_allocators SET last_change_sequence=1")
    error("reset_required", lambda: repo.changes("acct", device))
    error("payload_too_large", lambda: repo.bootstrap("acct", device, max_bytes=1))
    page = repo.bootstrap("acct", device, max_bytes=256)
    assert len(canonical_bytes(page.to_wire())) <= 256
    assert page.retention_markers == ("{}",)
    assert repo.changes("acct", device, page.current_cursor).records == ()


def test_cursor_ownership_expiry_and_bounded_snapshot(setup):
    repo, device, now, _ = setup
    other = repo.enroll("acct", True, "tablet", "tablet").device_id
    repo.admit_batch("acct", device, "batch", tuple(record(str(i), device=device) for i in range(3)))
    first = repo.bootstrap("acct", device, limit=1)
    assert isinstance(first, StatePage)
    repo.admit_batch("acct", device, "later", (record("later", device=device),))
    second = repo.bootstrap("acct", device, first.current_cursor, limit=1)
    third = repo.bootstrap("acct", device, second.current_cursor, limit=1)
    assert [p.records[0].record_id for p in (first, second, third)] == ["0", "1", "2"]
    assert [r.record_id for r in repo.changes("acct", device, third.current_cursor).records] == ["later"]
    error("reset_required", lambda: repo.changes("acct", other, first.current_cursor))
    other_account = repo.enroll("other", True, "other", "enroll").device_id
    error("reset_required", lambda: repo.changes("other", other_account, first.current_cursor))
    error("payload_too_large", lambda: repo.changes("acct", device, max_bytes=1))
    now[0] += 30 * 86400
    error("reset_required", lambda: repo.changes("acct", device, first.current_cursor))


def test_bootstrap_handoff_reports_changes_beyond_snapshot(setup):
    repo, device, _, _ = setup
    first_record = record("a", device=device)
    repo.admit_batch("acct", device, "initial", (first_record, record("b", device=device)))
    first = repo.bootstrap("acct", device, limit=1)
    update = replace(first_record, revision=2, payload=replace(first_record.payload, display_title="updated"))
    repo.admit_batch("acct", device, "update", (update, record("c", device=device)))
    continuation = repo.changes("acct", device, first.current_cursor, limit=1)
    assert [r.record_id for r in continuation.records] == ["b"]
    assert continuation.has_more
    latest = repo.changes("acct", device, continuation.next_cursor)
    assert [(r.record_id, r.change_sequence) for r in latest.records] == [("a", 3), ("c", 4)]
    assert not latest.has_more


def test_tombstone_revision_cannot_lower_deletion_barrier(setup):
    repo, device, _, _ = setup
    deletion = tombstone(device=device, revision=4)
    repo.admit_batch("acct", device, "delete", (deletion,))
    lowered = replace(deletion, revision=5, payload=replace(deletion.payload, deletion_revision=1))
    result = repo.admit_batch("acct", device, "lower", (lowered,))
    assert result.results[0].status == "conflict"
    assert repo.admit_batch("acct", device, "late", (record(device=device, revision=3),)).results[0].status == "duplicate"


def test_fixed_rate_windows_enforce_each_scope(setup):
    repo, device, now, _ = setup
    devices = [device] + [repo.enroll("acct", True, str(i), "e" + str(i)).device_id for i in range(2)]
    for i in range(30):
        repo.admit_batch("acct", device, "a" + str(i), ())
    assert error("rate_limited", lambda: repo.admit_batch("acct", device, "blocked", ())).retry_after_seconds == 60
    for i in range(30):
        repo.admit_batch("acct", devices[1], "b" + str(i), ())
    error("rate_limited", lambda: repo.admit_batch("acct", devices[2], "account-block", ()))
    for _ in range(120):
        repo.changes("acct", device)
    error("rate_limited", lambda: repo.bootstrap("acct", device))
    now[0] += 60
    repo.admit_batch("acct", device, "blocked", ())
    repo.changes("acct", device)


def test_rolling_ingest_and_retained_delta_and_deletion_exemption(setup):
    repo, device, now, db = setup
    upload = record(device=device)
    repo.admit_batch("acct", device, "first", (upload,))
    initial = db.execute("SELECT retained_bytes FROM sync_retained_bytes").fetchone()[0]
    update = replace(upload, revision=2, payload=replace(upload.payload, display_title="title"))
    repo.admit_batch("acct", device, "update", (update,))
    current = repo.changes("acct", device).records[0]
    assert db.execute("SELECT retained_bytes FROM sync_retained_bytes").fetchone()[0] == len(canonical_bytes(current.to_wire()))
    assert initial < len(canonical_bytes(current.to_wire()))
    # Fill the real rolling ledger to its exact boundary without 10k network calls.
    db.execute("""INSERT INTO sync_ingest_admissions
        (account_id, change_sequence, record_id, revision, canonical_length, admitted_at)
        SELECT 'acct', n+100, 'seed-' || n, 1, 1, %s FROM generate_series(1,9998) n""", (now[0],))
    result = repo.admit_batch("acct", device, "full", (record("new", device=device),))
    assert result.results[0].error.code == "quota_exhausted"
    assert result.results[0].error.retry_after_seconds == 86400
    now[0] += 86400
    assert repo.admit_batch("acct", device, "next-day", (record("new", device=device),)).results[0].status == "accepted"
    db.execute("UPDATE sync_retained_bytes SET retained_bytes = 104857600")
    assert repo.admit_batch("acct", device, "bytes-full", (record("overflow", device=device),)).results[0].error.code == "quota_exhausted"
    assert repo.admit_batch("acct", device, "delete", (tombstone(device=device),)).results[0].status == "accepted"
    assert repo.admit_batch("acct", device, "late", (upload,)).results[0].status == "duplicate"
    assert "rec-1" not in [r.record_id for r in repo.changes("acct", device).records]


def test_lifecycle_advisory_lock_is_not_reacquired_and_cleanup_is_permanent(setup, database):
    repo, device, _, db = setup
    db.execute("SELECT pg_advisory_lock(hashtextextended('acct', 714031))")
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            result = pool.submit(repo.admit_batch, "acct", device, "batch", (record(device=device),)).result(timeout=5)
        assert result.results[0].status == "accepted"
    finally:
        db.execute("SELECT pg_advisory_unlock(hashtextextended('acct', 714031))")
    repo.changes("acct", device)
    repo.admit_batch("acct", device, "conflict", (record(device=device, text="conflicting"),))
    db.execute("""INSERT INTO sync_leases
        (account_id, lease_id, device_id, lease_kind, acquired_at, renewed_at, expires_at)
        VALUES ('acct','lease',%s,'stream',0,0,900)""", (device,))
    db.execute("""INSERT INTO sync_retention_markers
        (account_id, marker_kind, change_sequence, through_change_sequence, canonical_bytes,
         canonical_sha256, canonical_length, created_at)
        VALUES ('acct','retention_action',2,1,'{}',sha256('{}'),2,0)""")
    # Every child table is populated; omitting any cleanup statement must fail.
    from psycopg import sql
    tables = db.execute("SELECT tablename FROM pg_tables WHERE schemaname=%s AND tablename LIKE 'sync_%%'", (database[1],)).fetchall()
    for (table,) in tables:
        assert db.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))).fetchone()[0] > 0
    db.execute("INSERT INTO account_deletions VALUES ('acct', 'pending', 0, '{}')")
    error("account_fenced", lambda: repo.enroll("acct", True, "blocked", "blocked"))
    repo.delete_account("acct")
    repo.delete_account("acct")
    for (table,) in tables:
        if table != "sync_accounts":
            assert db.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(table))).fetchone()[0] == 0
    assert db.execute("SELECT state FROM sync_accounts").fetchone()[0] == "deleted"
    error("account_fenced", lambda: repo.enroll("acct", True, "late", "late"))


def test_concurrent_distinct_uploads_share_rate_limit_and_monotonic_sequence(setup):
    repo, device, _, db = setup
    def upload(i):
        try:
            return repo.admit_batch("acct", device, "batch-" + str(i), (record(str(i), device=device),))
        except SyncError as exc:
            return exc.code
    with ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(upload, range(31)))
    assert results.count("rate_limited") == 1
    assert sorted(r.results[0].change_sequence for r in results if isinstance(r, BatchResult)) == list(range(1,31))
    assert db.execute("SELECT retained_records FROM sync_retained_bytes").fetchone()[0] == 30


def test_delete_racing_upload_never_leaves_child_rows(setup):
    repo, device, _, db = setup
    from threading import Barrier
    ready = Barrier(2)
    def upload():
        ready.wait()
        try:
            return repo.admit_batch("acct", device, "racing", (record(device=device),))
        except SyncError as exc:
            return exc.code
    def delete():
        ready.wait()
        repo.delete_account("acct")
    with ThreadPoolExecutor(max_workers=2) as pool:
        uploading, deleting = pool.submit(upload), pool.submit(delete)
        result = uploading.result(timeout=10)
        deleting.result(timeout=10)
    assert isinstance(result, BatchResult) or result == "account_fenced"
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 0
    assert db.execute("SELECT state FROM sync_accounts").fetchone()[0] == "deleted"


def test_account_authority_and_missing_schema_fail_closed_without_startup_ddl(database):
    from server.account.postgres import PostgresStore
    repo = PostgresSyncRepository(PostgresStore(database[0]), schema=database[1])
    assert repo.enroll("acct", True, "phone", "enroll").status == "active"
    absent = "sync_test_missing_" + uuid4().hex
    missing = PostgresSyncRepository(dsn=database[0], schema=absent)
    error("temporarily_unavailable", lambda: missing.enroll("acct", True, "phone", "enroll"))
    assert database[2].execute("SELECT count(*) FROM pg_namespace WHERE nspname=%s", (absent,)).fetchone()[0] == 0


def test_transaction_failure_rolls_back_sequence_record_and_idempotency(setup):
    repo, device, _, db = setup
    db.execute("""CREATE FUNCTION reject_ingest() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN RAISE EXCEPTION 'injected transaction failure'; END $$""")
    db.execute("CREATE TRIGGER reject_ingest BEFORE INSERT ON sync_ingest_admissions FOR EACH ROW EXECUTE FUNCTION reject_ingest()")
    error("temporarily_unavailable", lambda: repo.admit_batch("acct", device, "retry", (record(device=device),)))
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 0
    db.execute("DROP TRIGGER reject_ingest ON sync_ingest_admissions")
    assert repo.admit_batch("acct", device, "retry", (record(device=device),)).results[0].change_sequence == 1
