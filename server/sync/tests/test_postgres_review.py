"""Regression coverage for partial retries, HTTP pagination and durable rates."""

import gzip
import json
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.sync.api import router
from server.sync.canonical import canonical_bytes
from server.sync.dto import ReplayRecord
from server.sync.postgres import PostgresSyncRepository
from server.sync.results import StatePage
from server.sync.tests.test_memory_repository import record, tombstone
from server.sync.tests.test_postgres_repository import database, setup, error


@pytest.fixture
def http(setup):
    repo, device, now, _ = setup
    @contextmanager
    def admission(claims):
        yield claims["uid"]
    app = FastAPI()
    app.include_router(router(repo, lambda *_: {"uid": "acct"}, admission, clock=lambda: now[0]))
    with TestClient(app, headers={"Authorization": "Bearer test", "X-Firebase-AppCheck": "test",
                                  "X-Sync-Device-Id": device}) as client:
        yield client


def upload(http, key, items):
    return http.post("/sync/v1/records", content=gzip.compress(canonical_bytes({
        "schemaVersion": 1, "idempotencyKey": key, "records": items})))


def test_same_key_reconsiders_only_retryable_results_after_restart(setup):
    repo, device, now, db = setup
    repo.admit_batch("acct", device, "seed", (record("existing", device=device),))
    db.execute("""INSERT INTO sync_ingest_admissions
        (account_id,change_sequence,record_id,revision,canonical_length,admitted_at)
        SELECT 'acct',n+100,'seed-' || n,1,1,%s FROM generate_series(1,9998) n""", (now[0],))
    items = (record("accepted", device=device), record("retry", device=device),
             record("existing", device=device, text="conflict"), record("bad", device="foreign"))
    first = repo.admit_batch("acct", device, "mixed", items)
    assert [r.status for r in first.results] == ["accepted", "retryable", "conflict", "rejected"]
    now[0] += 86400
    restarted = PostgresSyncRepository(dsn=repo._dsn, schema=repo.schema, clock=lambda: now[0])
    error("integrity_conflict", lambda: restarted.admit_batch("acct", device, "mixed", items[:-1]))
    retried = restarted.admit_batch("acct", device, "mixed", items)
    assert [r.status for r in retried.results] == ["accepted", "accepted", "conflict", "rejected"]
    assert retried.results[0] == first.results[0]
    assert retried.results[2:] == first.results[2:]
    assert retried.results[1].change_sequence == 3
    assert restarted.admit_batch("acct", device, "mixed", items) == retried
    assert db.execute("SELECT count(*) FROM sync_conflicts").fetchone()[0] == 1


def test_same_key_retry_recovers_retained_quota(setup):
    repo, device, _, db = setup
    db.execute("UPDATE sync_retained_bytes SET retained_bytes=104857600")
    items = (record(device=device),)
    assert repo.admit_batch("acct", device, "retry", items).results[0].status == "retryable"
    db.execute("UPDATE sync_retained_bytes SET retained_bytes=0")
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: repo.admit_batch("acct", device, "retry", items), range(4)))
    assert all(result == results[0] for result in results)
    assert results[0].results[0].status == "accepted"
    assert db.execute("SELECT count(*) FROM sync_ingest_admissions").fetchone()[0] == 1


@pytest.mark.parametrize("cursor", ["unknown", "has space", "x" * 513])
def test_http_invalid_cursors_require_reset(http, cursor):
    for route in ("changes", "state"):
        response = http.get("/sync/v1/" + route, params={"cursor": cursor})
        assert response.status_code == 409
        assert response.json()["code"] == "reset_required"


def test_failed_operations_consume_durable_rate_admission(setup):
    repo, device, now, db = setup
    for _ in range(120):
        # Cursor errors must consume rate even though their operation rolls back.
        error("reset_required", lambda: repo.changes("acct", device, "unknown"))
    assert db.execute("SELECT request_count FROM sync_rate_windows WHERE route_class='replay'").fetchone() == (120,)
    error("rate_limited", lambda: repo.bootstrap("acct", device))
    now[0] += 60
    repo.admit_batch("acct", device, "key", ())
    for _ in range(29):
        error("integrity_conflict", lambda: repo.admit_batch("acct", device, "key", (record(device=device),)))
    error("rate_limited", lambda: repo.admit_batch("acct", device, "valid", ()))
    before = db.execute("SELECT sum(request_count) FROM sync_rate_windows").fetchone()[0]
    error("device_revoked", lambda: repo.changes("acct", "foreign"))
    assert db.execute("SELECT sum(request_count) FROM sync_rate_windows").fetchone()[0] == before


def test_http_expired_and_foreign_cursor_require_reset(http, setup):
    repo, device, now, _ = setup
    first = http.get("/sync/v1/state").json()["currentCursor"]
    other = repo.enroll("acct", True, "other", "other").device_id
    foreign = http.get("/sync/v1/changes", params={"cursor": first}, headers={"X-Sync-Device-Id": other})
    assert foreign.status_code == 409
    assert foreign.json()["code"] == "reset_required"
    now[0] += 30 * 86400
    expired = http.get("/sync/v1/state", params={"cursor": first})
    assert expired.status_code == 409
    assert expired.json()["code"] == "reset_required"


def test_http_snapshot_changes_skip_marker_after_first_hundred_and_handoff(http, setup):
    repo, device, now, db = setup
    for batch in range(2):
        response = upload(http, str(batch), [record(str(i), device=device).to_wire()
                          for i in range(batch * 100, (batch + 1) * 100)])
        assert response.status_code == 200
    # Use the real maintenance sweep to emit a marker after the first 100 rows.
    repo.admit_batch("acct", device, "delete", (tombstone("absent", device=device),))
    now[0] += 61 * 86400
    while repo.purge_expired(limit=100):
        pass
    assert db.execute("SELECT count(*) FROM sync_retention_markers").fetchone()[0] == 1
    first = http.get("/sync/v1/state")
    assert first.status_code == 200
    assert len(first.json()["records"]) == 100
    seen = [r["recordId"] for r in first.json()["records"]]
    cursor = first.json()["currentCursor"]
    assert upload(http, "after-snapshot", [record("later", device=device).to_wire()]).status_code == 200
    for _ in range(5):
        response = http.get("/sync/v1/changes", params={"cursor": cursor})
        assert response.status_code == 200, response.text
        assert len(response.content) <= 262144
        page = response.json()
        seen.extend(r["recordId"] for r in page["records"])
        cursor = page["nextCursor"]
        if not page["hasMore"]:
            break
    else:
        pytest.fail("snapshot never drained")
    assert seen == [str(i) for i in range(200)] + ["later"]
    assert http.get("/sync/v1/changes", params={"cursor": cursor}).json()["records"] == []


@pytest.mark.parametrize("bootstrap", [False, True])
def test_entire_page_envelope_fits_requested_budget(setup, bootstrap):
    repo, device, _, db = setup
    repo.admit_batch("acct", device, "seed", (record("one", device=device), record("two", device=device)))
    method = repo.bootstrap if bootstrap else repo.changes
    baseline = method("acct", device, limit=1)
    budget = len(canonical_bytes(baseline.to_wire()))
    page = method("acct", device, max_bytes=budget)
    assert len(canonical_bytes(page.to_wire())) <= budget
    assert [r.record_id for r in page.records] == ["one"]
    record_only_budget = len(canonical_bytes(page.records[0].to_wire())) + 1
    error("payload_too_large", lambda: method("acct", device, max_bytes=record_only_budget))
    cursor = page.current_cursor if bootstrap else page.next_cursor
    before = db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0]
    error("payload_too_large", lambda: method("acct", device, cursor, max_bytes=1))
    assert db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0] == before
    assert [r.record_id for r in method("acct", device, cursor).records] == ["two"]


def test_max_record_must_fit_both_response_envelopes_before_admission(http, setup):
    repo, device, _, db = setup
    empty = record(device=device, text="")
    replay = ReplayRecord.from_upload(empty, "acct", 1)
    # Include the complete larger (state) response, not merely canonical record bytes.
    overhead = len(canonical_bytes(StatePage("acct", "x" * 43, (replay,), "active", ()).to_wire()))
    boundary = record(device=device, text="x" * (262144 - overhead))
    result = upload(http, "boundary", [boundary.to_wire()])
    assert result.status_code == 200
    assert result.json()["results"][0]["status"] == "accepted"
    for path in ("state", "changes"):
        response = http.get("/sync/v1/" + path)
        assert response.status_code == 200
        assert len(response.content) <= 262144
        assert response.json()["records"][0]["payload"]["text"] == boundary.payload.text
    too_big = replace(boundary, record_id="new")
    # Both IDs are three/five bytes respectively; size the candidate independently.
    large = ReplayRecord.from_upload(too_big, "acct", 2)
    extra = 262145 - len(canonical_bytes(StatePage("acct", "x" * 43, (large,), "active", ()).to_wire()))
    too_big = replace(too_big, payload=replace(too_big.payload, text=too_big.payload.text + "x" * extra))
    refused = upload(http, "too-large", [too_big.to_wire()])
    assert refused.json()["results"][0]["error"]["code"] == "payload_too_large"
    assert db.execute("SELECT last_change_sequence FROM sync_sequence_allocators").fetchone()[0] == 1


def test_legacy_max_size_record_page_failure_does_not_advance_cursor(http, setup):
    repo, device, _, db = setup
    cursor = http.get("/sync/v1/state").json()["currentCursor"]
    repo.admit_batch("acct", device, "seed", (record(device=device),))
    # Simulate a row admitted by the former record-only size policy.
    base = ReplayRecord.from_upload(record(device=device, text=""), "acct", 1)
    size = 262144 - len(canonical_bytes(base.to_wire()))
    legacy = replace(base, payload=replace(base.payload, text="x" * size))
    encoded = canonical_bytes(legacy.to_wire())
    assert len(encoded) == 262144
    db.execute("""UPDATE sync_records SET canonical_bytes=%s,canonical_sha256=sha256(%s),
        canonical_length=%s""", (encoded, encoded, len(encoded)))
    count = db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0]
    refused = http.get("/sync/v1/changes", params={"cursor": cursor})
    assert refused.status_code == 413
    assert db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0] == count
    assert db.execute("SELECT position FROM sync_cursors WHERE cursor_id=%s", (cursor,)).fetchone()[0] == 0
    encoded = canonical_bytes(base.to_wire())
    db.execute("""UPDATE sync_records SET canonical_bytes=%s,canonical_sha256=sha256(%s),
        canonical_length=%s""", (encoded, encoded, len(encoded)))
    recovered = http.get("/sync/v1/changes", params={"cursor": cursor})
    assert recovered.status_code == 200
    assert recovered.json()["records"][0]["recordId"] == "rec-1"


def test_http_byte_limited_pages_never_exceed_envelope_budget(http, setup):
    _, device, _, _ = setup
    assert upload(http, "large-page", [record(str(i), device=device, text="x" * 130700).to_wire()
                                      for i in range(3)]).status_code == 200
    state = http.get("/sync/v1/state")
    assert state.status_code == 200
    assert len(state.content) <= 262144
    assert len(state.json()["records"]) == 1
    cursor = state.json()["currentCursor"]
    seen = [r["recordId"] for r in state.json()["records"]]
    for _ in range(3):
        page = http.get("/sync/v1/changes", params={"cursor": cursor})
        assert page.status_code == 200
        assert len(page.content) <= 262144
        seen.extend(r["recordId"] for r in page.json()["records"])
        cursor = page.json()["nextCursor"]
        if not page.json()["hasMore"]:
            break
    assert seen == ["0", "1", "2"]


def test_http_malformed_and_oversized_siblings_keep_identity_and_digest(http, setup):
    repo, device, _, db = setup
    valid = record("good", device=device).to_wire()
    malformed = {**record("bad", device=device).to_wire(), "unexpected": "private sentinel"}
    oversized = record("large", device=device, text="x" * 262144).to_wire()
    items = [valid, malformed, oversized, None, {"recordId": "missing-fields"}]
    first = upload(http, "mixed", items)
    assert first.status_code == 200, first.text
    outcomes = first.json()["results"]
    assert [r["status"] for r in outcomes] == ["accepted", "rejected", "rejected", "rejected", "rejected"]
    assert [outcomes[i]["recordId"] for i in (0, 1, 2, 4)] == ["good", "bad", "large", "missing-fields"]
    assert outcomes[3]["recordId"] and len(outcomes[3]["recordId"]) <= 128
    assert "private sentinel" not in first.text
    assert upload(http, "mixed", items).json() == first.json()
    changed = [valid, {**malformed, "unexpected": "different"}, *items[2:]]
    assert upload(http, "mixed", changed).json()["code"] == "integrity_conflict"
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 1


def test_full_request_limits_remain_atomic_even_with_invalid_siblings(http, setup):
    _, device, _, db = setup
    items = [record("good", device=device).to_wire(), {"bad": "x" * (8 * 1024 * 1024)}]
    response = upload(http, "too-large", items)
    assert response.status_code == 413
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 0


@pytest.mark.parametrize("revision", [
    "100000000000000000000", "1e20", "1e308", "1.7976931348623157e308",
    '"100000000000000000000"', "true", "null", "[]", '{"value":1e20}',
])
def test_http_invalid_numeric_revision_preserves_valid_sibling_and_retry(http, setup, revision):
    _, device, _, db = setup
    valid = record("good", device=device).to_wire()
    invalid = record("bad", device=device).to_wire()
    # Send literal JSON numbers: the test must not normalize the input through
    # Python's integer serializer before exercising the HTTP strict decoder.
    invalid_json = json.dumps(invalid).replace('"revision": 1', '"revision": ' + revision)
    raw = ('{"schemaVersion":1,"idempotencyKey":"numeric","records":['
           + json.dumps(valid) + ',' + invalid_json + ']}').encode()
    first = http.post("/sync/v1/records", content=gzip.compress(raw))
    assert first.status_code == 200, first.text
    outcomes = first.json()["results"]
    assert [(item["recordId"], item["status"]) for item in outcomes] == [
        ("good", "accepted"), ("bad", "rejected")]
    assert outcomes[0]["changeSequence"] == 1
    assert outcomes[1]["error"]["code"] == "invalid_record"
    retry = http.post("/sync/v1/records", content=gzip.compress(raw))
    assert retry.status_code == 200
    assert retry.json() == first.json()
    mismatch = upload(http, "numeric", [valid, {**invalid, "revision": 0}])
    assert mismatch.status_code == 409
    assert mismatch.json()["code"] == "integrity_conflict"
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 1
    assert db.execute("SELECT count(*) FROM sync_ingest_admissions").fetchone()[0] == 1


@pytest.mark.parametrize("revision", ['1,"revision":1e20', "1e309"])
def test_http_duplicate_keys_and_nonfinite_numbers_remain_atomic(http, setup, revision):
    _, device, _, db = setup
    valid = record("good", device=device).to_wire()
    invalid = json.dumps(record("bad", device=device).to_wire()).replace(
        '"revision": 1', '"revision": ' + revision)
    raw = ('{"schemaVersion":1,"idempotencyKey":"invalid-json","records":['
           + json.dumps(valid) + ',' + invalid + ']}').encode()
    for _ in range(2):
        response = http.post("/sync/v1/records", content=gzip.compress(raw))
        assert response.status_code == 400
        assert response.json()["code"] == "invalid_request"
    assert db.execute("SELECT count(*) FROM sync_records").fetchone()[0] == 0
    assert db.execute("SELECT count(*) FROM sync_idempotency WHERE operation='upload'").fetchone()[0] == 0
