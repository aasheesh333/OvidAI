"""Transactional private-sync authority over the explicitly deployed schema.

Lifecycle.access owns the UID advisory lock on a *different* connection. Never
take that advisory lock here: all sync operations, including cleanup, serialize
on sync_accounts FOR UPDATE. Lifecycle admission must surround public calls;
the account_deletions read is an additional defensive fence, not its replacement.

Cursors are unguessable, persisted positions, so they survive process restarts
without an in-memory signing secret. Bootstrap pins a high-water sequence; a
record superseded during pagination is subsequently delivered by changes().
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import secrets
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Callable, ClassVar

from server.sync.canonical import canonical_bytes
from server.sync.conflicts import Admission, classify_admission
from server.sync.cursors import MAX_CURSOR_TTL_SECONDS
from server.sync.dto import MAX_CHANGE_SEQUENCE, ReplayRecord, TombstonePayload, UploadRecord
from server.sync.errors import SyncError
from server.sync.policy import (
    ACCOUNT_INGEST_RECORDS, ACCOUNT_REPLAY_REQUESTS_PER_MINUTE,
    ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE, BATCH_CANONICAL_BYTES, BATCH_RECORDS,
    DEVICE_UPLOAD_REQUESTS_PER_MINUTE, ENROLLED_DEVICES, RECORD_CANONICAL_BYTES,
    RETAINED_CANONICAL_BYTES,
)
from server.sync.results import (
    BatchResult, ChangePage, DeviceEnrollment, RecordOutcome, RejectedUpload, StatePage,
    parse_batch_result, parse_device_enrollment,
)
from server.sync.retention import ACTIVITY_COMPACTION_AGE_SECONDS, TOMBSTONE_RETENTION_SECONDS


_ID = re.compile(r"[\x21-\x7e]{1,128}\Z")
_DAY = 86400
_IDEMPOTENCY_TTL = 30 * _DAY
_CHILD_TABLES = (
    "sync_leases", "sync_cursors", "sync_conflicts", "sync_changes",
    "sync_retention_markers", "sync_ingest_admissions", "sync_idempotency",
    "sync_rate_windows", "sync_records", "sync_devices",
    "sync_retained_bytes", "sync_sequence_allocators",
)

# Each branch produces at most one actionable row per account. Idle accounts
# never consume a batch slot. Oldest work first also prevents new traffic on an
# early account from starving later accounts across worker/process restarts.
_RETENTION_WORK = """
    (SELECT 'horizon' AS kind, r.record_id AS key, r.purge_after AS due
     FROM sync_records r WHERE r.account_id=a.account_id AND r.record_type='tombstone'
     AND r.purge_after IS NOT NULL AND EXISTS (
         SELECT 1 FROM sync_cursors c WHERE c.account_id=r.account_id
         AND c.position<r.change_sequence AND c.expires_at+%(retention)s>r.purge_after)
     ORDER BY r.purge_after,r.record_id LIMIT 1)
    UNION ALL
    (SELECT 'tombstone',r.record_id,r.purge_after FROM sync_records r
     WHERE r.account_id=a.account_id AND r.record_type='tombstone'
     AND r.purge_after<=%(now)s AND NOT EXISTS (
         SELECT 1 FROM sync_cursors c WHERE c.account_id=r.account_id
         AND c.position<r.change_sequence AND c.expires_at+%(retention)s>r.purge_after)
     ORDER BY r.purge_after,r.record_id LIMIT 1)
    UNION ALL
    (SELECT 'activity',r.record_id,r.updated_at+%(age)s FROM sync_records r
     WHERE r.account_id=a.account_id AND r.record_type='activity' AND NOT r.tombstoned
     AND r.updated_at<=%(now)s-%(age)s AND r.logical_request_id IS NOT NULL
     AND convert_from(r.canonical_bytes,'UTF8')::jsonb->'payload'->>'status' IN ('queued','started')
     AND convert_from(r.canonical_bytes,'UTF8')::jsonb->'payload'->>'usageRecordId' IS NULL
     AND EXISTS (SELECT 1 FROM sync_records t WHERE t.account_id=r.account_id
         AND t.logical_request_id=r.logical_request_id AND t.record_type='activity'
         AND NOT t.tombstoned AND t.change_sequence>r.change_sequence
         AND convert_from(t.canonical_bytes,'UTF8')::jsonb->'payload'->>'kind'='request'
         AND convert_from(t.canonical_bytes,'UTF8')::jsonb->'payload'->>'status'
             IN ('succeeded','failed','cancelled','interrupted'))
     ORDER BY r.updated_at,r.record_id LIMIT 1)
    UNION ALL
    (SELECT 'cursor',c.cursor_id,c.expires_at FROM sync_cursors c
     WHERE c.account_id=a.account_id AND c.expires_at<=%(now)s AND NOT EXISTS (
         SELECT 1 FROM sync_records r WHERE r.account_id=c.account_id
         AND r.record_type='tombstone' AND c.position<r.change_sequence
         AND r.purge_after<c.expires_at+%(retention)s)
     ORDER BY c.expires_at,c.cursor_id LIMIT 1)
    UNION ALL
    (SELECT 'idempotency',idempotency_key,expires_at FROM sync_idempotency
     WHERE account_id=a.account_id AND expires_at<=%(now)s
     ORDER BY expires_at,idempotency_key LIMIT 1)
    UNION ALL
    (SELECT 'rate',ctid::text,window_start+60 FROM sync_rate_windows
     WHERE account_id=a.account_id AND window_start+60<=%(now)s
     ORDER BY window_start,scope,device_id,route_class LIMIT 1)
    UNION ALL
    (SELECT 'ingest',change_sequence::text,admitted_at+86400 FROM sync_ingest_admissions
     WHERE account_id=a.account_id AND admitted_at<=%(now)s-86400
     ORDER BY admitted_at,change_sequence LIMIT 1)
"""


def _identity(value: str) -> None:
    if type(value) is not str or _ID.fullmatch(value) is None:
        raise SyncError("invalid_request")


def _digest(value: object) -> bytes:
    return hashlib.sha256(canonical_bytes(value)).digest()


def _timestamp(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")


class PostgresSyncRepository:
    durability: ClassVar[str] = "durable"
    authority: ClassVar[str] = "server"

    def __init__(self, account_authority=None, *, dsn: str | None = None,
                 schema: str = "public", clock: Callable[[], float] | None = None):
        if account_authority is not None:
            if dsn is not None:
                raise ValueError("provide one explicit PostgreSQL authority")
            source = getattr(account_authority, "store", account_authority)
            dsn = source if isinstance(source, str) else getattr(source, "dsn", None)
        if type(dsn) is not str or not dsn.strip():
            raise ValueError("an explicit PostgreSQL authority or DSN is required")
        if type(schema) is not str or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,62}", schema):
            raise ValueError("invalid PostgreSQL schema")
        self._dsn = dsn
        self.schema = schema
        self.clock = time.time if clock is None else clock
        self.authority_identity = "private-sync:postgres:" + _digest(
            {"dsn": dsn, "schema": schema}).hex()

    @contextmanager
    def _transaction(self, account_id: str, *, deleting: bool = False):
        import psycopg
        from psycopg import sql
        from psycopg.rows import dict_row

        _identity(account_id)
        try:
            with psycopg.connect(self._dsn, row_factory=dict_row, connect_timeout=10) as db:
                db.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                db.execute(sql.SQL("SET LOCAL search_path TO {}").format(sql.Identifier(self.schema)))
                db.execute("SET LOCAL lock_timeout = '10s'")
                db.execute("SET LOCAL statement_timeout = '30s'")
                db.execute("""INSERT INTO sync_accounts (account_id, state, created_at)
                    VALUES (%s, 'active', %s) ON CONFLICT DO NOTHING""",
                           (account_id, self.clock()))
                account = db.execute("SELECT state FROM sync_accounts WHERE account_id=%s FOR UPDATE",
                                     (account_id,)).fetchone()
                now = self.clock()  # sample after waiting for the account lock
                if not deleting:
                    lifecycle = db.execute("SELECT state FROM account_deletions WHERE uid=%s",
                                           (account_id,)).fetchone()
                    if account["state"] != "active" or (lifecycle and lifecycle["state"] != "cancelled"):
                        raise SyncError("account_fenced")
                    db.execute("""INSERT INTO sync_sequence_allocators (account_id)
                        VALUES (%s) ON CONFLICT DO NOTHING""", (account_id,))
                    db.execute("""INSERT INTO sync_retained_bytes (account_id, updated_at)
                        VALUES (%s, %s) ON CONFLICT DO NOTHING""", (account_id, now))
                yield db, now, account["state"]
        except psycopg.Error:
            # Database errors can contain canonical bytes or connection details.
            raise SyncError("temporarily_unavailable") from None

    @staticmethod
    def _device(db, account_id: str, device_id: str, *, allow_revoked: bool = False):
        _identity(device_id)
        row = db.execute("SELECT * FROM sync_devices WHERE account_id=%s AND device_id=%s",
                         (account_id, device_id)).fetchone()
        if row is None or (row["revoked_at"] is not None and not allow_revoked):
            raise SyncError("device_revoked")
        return row

    @staticmethod
    def _cached(db, account_id, key, operation, device_id, digest, now):
        _identity(key)
        db.execute("DELETE FROM sync_idempotency WHERE account_id=%s AND expires_at<=%s",
                   (account_id, now))
        row = db.execute("SELECT * FROM sync_idempotency WHERE account_id=%s AND idempotency_key=%s",
                         (account_id, key)).fetchone()
        if row is None:
            return None
        if (row["operation"] != operation or row["device_id"] != device_id
                or bytes(row["request_sha256"]) != digest):
            raise SyncError("integrity_conflict")
        if row["state"] != "completed":
            raise SyncError("temporarily_unavailable", 1)
        wire = json.loads(bytes(row["result_bytes"]))
        return parse_batch_result(wire) if operation == "upload" else parse_device_enrollment(wire)

    @staticmethod
    def _remember(db, account_id, key, operation, device_id, digest, result, now):
        db.execute("""INSERT INTO sync_idempotency
            (account_id, idempotency_key, operation, device_id, request_sha256,
             state, result_bytes, created_at, expires_at)
            VALUES (%s,%s,%s,%s,%s,'completed',%s,%s,%s)""",
                   (account_id, key, operation, device_id, digest,
                    canonical_bytes(result.to_wire()), now, now + _IDEMPOTENCY_TTL))

    @staticmethod
    def _rate(db, account_id, device_id, route, now):
        start = math.floor(now / 60) * 60
        scopes = [("account", "", ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE if route == "upload"
                   else ACCOUNT_REPLAY_REQUESTS_PER_MINUTE)]
        if route == "upload":
            scopes.append(("device", device_id, DEVICE_UPLOAD_REQUESTS_PER_MINUTE))
        db.execute("DELETE FROM sync_rate_windows WHERE account_id=%s AND window_start<%s",
                   (account_id, start))
        for scope, device, limit in scopes:
            row = db.execute("""INSERT INTO sync_rate_windows
                (account_id, scope, device_id, route_class, window_start, request_count)
                VALUES (%s,%s,%s,%s,%s,1)
                ON CONFLICT (account_id, scope, device_id, route_class, window_start)
                DO UPDATE SET request_count=sync_rate_windows.request_count+1
                WHERE sync_rate_windows.request_count < %s RETURNING request_count""",
                             (account_id, scope, device, route, start, limit)).fetchone()
            if row is None:
                raise SyncError("rate_limited", max(1, math.ceil(start + 60 - now)))

    def _admit_rate(self, account_id, device_id, route):
        """Charge an authorized attempt even when its subsequent operation fails.

        Both transactions take only the sync account row lock. The operation
        rechecks its account/device fence after the gap (revocation or deletion
        may have committed in between).
        """
        with self._transaction(account_id) as (db, now, _):
            self._device(db, account_id, device_id)
            self._rate(db, account_id, device_id, route, now)

    def enroll(self, account_id: str, consent: bool, device_name: str,
               idempotency_key: str) -> DeviceEnrollment:
        _identity(idempotency_key)
        if consent is not True or type(device_name) is not str or not 1 <= len(device_name) <= 128:
            raise SyncError("invalid_request")
        try:
            device_name.encode("utf-8")
        except UnicodeEncodeError:
            raise SyncError("invalid_request") from None
        digest = _digest({"consent": consent, "deviceName": device_name})
        with self._transaction(account_id) as (db, now, _):
            cached = self._cached(db, account_id, idempotency_key, "enroll", None, digest, now)
            if cached is not None:
                return cached
            count = db.execute("SELECT count(*) AS n FROM sync_devices WHERE account_id=%s AND revoked_at IS NULL",
                               (account_id,)).fetchone()["n"]
            if count >= ENROLLED_DEVICES:
                raise SyncError("quota_exhausted")
            device_id = secrets.token_urlsafe(32)
            db.execute("""INSERT INTO sync_devices
                (account_id, device_id, device_label, consent_version, consented_at, created_at)
                VALUES (%s,%s,%s,1,%s,%s)""", (account_id, device_id, device_name, now, now))
            result = DeviceEnrollment(device_id, device_name, _timestamp(now), "active")
            self._remember(db, account_id, idempotency_key, "enroll", None, digest, result, now)
            return result

    def revoke(self, account_id: str, requester_device_id: str,
               target_device_id: str, idempotency_key: str,
               fresh_auth: bool = False) -> DeviceEnrollment:
        for value in (requester_device_id, target_device_id, idempotency_key):
            _identity(value)
        if fresh_auth is not True:
            raise SyncError("invalid_request")
        digest = _digest({"requesterDeviceId": requester_device_id,
                          "targetDeviceId": target_device_id, "freshAuth": fresh_auth})
        with self._transaction(account_id) as (db, now, _):
            requester = self._device(db, account_id, requester_device_id, allow_revoked=True)
            cached = self._cached(db, account_id, idempotency_key, "revoke", requester_device_id, digest, now)
            if cached is not None:
                return cached  # allows retry of a successful self-revocation
            if requester["revoked_at"] is not None:
                raise SyncError("device_revoked")
            target = db.execute("SELECT * FROM sync_devices WHERE account_id=%s AND device_id=%s",
                                (account_id, target_device_id)).fetchone()
            if target is None:
                raise SyncError("not_found")
            db.execute("""UPDATE sync_devices SET revoked_at=%s, revocation_kind='device'
                WHERE account_id=%s AND device_id=%s AND revoked_at IS NULL""",
                       (max(now, target["created_at"]), account_id, target_device_id))
            db.execute("DELETE FROM sync_cursors WHERE account_id=%s AND device_id=%s",
                       (account_id, target_device_id))
            db.execute("""UPDATE sync_leases SET ended_at=%s, end_reason='revoked'
                WHERE account_id=%s AND device_id=%s AND ended_at IS NULL""",
                       (now, account_id, target_device_id))
            result = DeviceEnrollment(target_device_id, target["device_label"],
                                      _timestamp(target["created_at"]), "revoked")
            self._remember(db, account_id, idempotency_key, "revoke", requester_device_id, digest, result, now)
            return result

    def admit_wire_batch(self, account_id: str, device_id: str, idempotency_key: str,
                         records: list[object]) -> BatchResult:
        """Keep malformed siblings in the same durable idempotency envelope."""
        if type(records) is not list or len(records) > BATCH_RECORDS:
            raise SyncError("payload_too_large")
        reserved = {item.get("recordId") for item in records if isinstance(item, dict)
                    and type(item.get("recordId")) is str}
        prepared = []
        for index, wire in enumerate(records):
            encoded = canonical_bytes(wire)
            try:
                if len(encoded) > RECORD_CANONICAL_BYTES:
                    raise SyncError("payload_too_large")
                prepared.append(UploadRecord.from_wire(wire))
            except SyncError as exc:
                record_id = wire.get("recordId") if isinstance(wire, dict) else None
                if type(record_id) is not str or _ID.fullmatch(record_id) is None:
                    # Request-position IDs are stable on retry and cannot alias
                    # any caller-supplied ID, including a later sibling's ID.
                    suffix = 0
                    record_id = f"invalid-item-{index}-{suffix}"
                    while record_id in reserved:
                        suffix += 1
                        record_id = f"invalid-item-{index}-{suffix}"
                    reserved.add(record_id)
                prepared.append(RejectedUpload(record_id, encoded, exc))
        return self.admit_batch(account_id, device_id, idempotency_key, tuple(prepared))

    def admit_batch(self, account_id: str, device_id: str, idempotency_key: str,
                    records: tuple[UploadRecord | RejectedUpload, ...]) -> BatchResult:
        self._admit_rate(account_id, device_id, "upload")
        _identity(idempotency_key)
        records = tuple(records)
        if len(records) > BATCH_RECORDS:
            raise SyncError("payload_too_large")
        if any(not isinstance(record, (UploadRecord, RejectedUpload)) for record in records):
            raise SyncError("invalid_record")
        wires = [record.to_wire() for record in records]
        if sum(len(canonical_bytes(wire)) for wire in wires) > BATCH_CANONICAL_BYTES:
            raise SyncError("payload_too_large")
        digest = _digest({"deviceId": device_id, "records": wires})
        with self._transaction(account_id) as (db, now, _):
            self._device(db, account_id, device_id)
            cached = self._cached(db, account_id, idempotency_key, "upload", device_id, digest, now)
            if cached is not None and all(item.status != "retryable" for item in cached.results):
                return cached
            db.execute("DELETE FROM sync_ingest_admissions WHERE account_id=%s AND admitted_at<=%s",
                       (account_id, now - _DAY))
            result = BatchResult(tuple(
                cached.results[index] if cached is not None and cached.results[index].status != "retryable"
                else self._admit(db, account_id, device_id, record, now)
                for index, record in enumerate(records)))
            if cached is None:
                self._remember(db, account_id, idempotency_key, "upload", device_id, digest, result, now)
            else:
                # Keep the original request digest and lease; only dispositions
                # explicitly marked retryable can progress to a terminal result.
                db.execute("""UPDATE sync_idempotency SET result_bytes=%s
                    WHERE account_id=%s AND idempotency_key=%s""",
                           (canonical_bytes(result.to_wire()), account_id, idempotency_key))
            return result

    @staticmethod
    def _failure(record, code, status="rejected", retry=None):
        return RecordOutcome(record.record_id, status, None, None, SyncError(code, retry))

    @staticmethod
    def _record(row):
        return ReplayRecord.from_wire(json.loads(bytes(row["canonical_bytes"])))

    def _admit(self, db, account_id, device_id, upload, now):
        if isinstance(upload, RejectedUpload):
            return upload.outcome()
        if upload.source_device_id != device_id:
            return self._failure(upload, "invalid_record")
        try:
            upload = UploadRecord.from_wire(upload.to_wire())
        except SyncError as exc:
            return self._failure(upload, exc.code)
        existing = db.execute("SELECT * FROM sync_records WHERE account_id=%s AND record_id=%s",
                              (account_id, upload.record_id)).fetchone()
        barrier = db.execute("""SELECT * FROM sync_records WHERE account_id=%s AND target_record_id=%s
            ORDER BY (convert_from(canonical_bytes,'UTF8')::jsonb->'payload'->>'deletionRevision')::bigint DESC
            LIMIT 1""", (account_id, upload.record_id)).fetchone()
        current = self._record(existing) if existing and existing["canonical_bytes"] is not None else None
        tomb = self._record(barrier) if barrier else None
        # Compacted identities retain their revision even though their detail is
        # gone. Never treat such a row as an unseen upload and resurrect it.
        if existing and existing["canonical_bytes"] is None:
            if upload.revision <= existing["revision"]:
                return RecordOutcome(upload.record_id, "duplicate", existing["revision"],
                                     existing["change_sequence"], None)
            if tomb is None:
                return self._failure(upload, "integrity_conflict", "conflict")
        admission = classify_admission(upload, current, tombstone=tomb)
        if (current and isinstance(current.payload, TombstonePayload)
                and isinstance(upload.payload, TombstonePayload)
                and upload.revision > current.revision
                and upload.payload.deletion_revision < current.payload.deletion_revision):
            admission = Admission.CONFLICT
        if admission in (Admission.DUPLICATE, Admission.STALE):
            canonical = tomb if tomb and upload.revision <= tomb.payload.deletion_revision else current
            return RecordOutcome(upload.record_id, "duplicate", canonical.revision, canonical.change_sequence, None)
        if admission == Admission.CONFLICT or (existing and existing["record_type"] != upload.record_type):
            submitted = canonical_bytes(upload.to_wire())
            if len(submitted) > RECORD_CANONICAL_BYTES:
                return self._failure(upload, "payload_too_large")
            db.execute("""INSERT INTO sync_conflicts
                (account_id, record_id, record_type, source_device_id, canonical_revision,
                 canonical_sha256, submitted_revision, submitted_sha256, submitted_length, detected_at)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING""",
                       (account_id, upload.record_id, upload.record_type, device_id, existing["revision"],
                        existing["canonical_sha256"], upload.revision, hashlib.sha256(submitted).digest(), len(submitted), now))
            return self._failure(upload, "integrity_conflict", "conflict")

        sequence = db.execute("SELECT last_change_sequence FROM sync_sequence_allocators WHERE account_id=%s",
                              (account_id,)).fetchone()["last_change_sequence"] + 1
        if sequence > MAX_CHANGE_SEQUENCE:
            return self._failure(upload, "temporarily_unavailable", "retryable")
        replay = ReplayRecord.from_upload(upload, account_id, sequence)
        encoded = canonical_bytes(replay.to_wire())
        # A maximum-size DTO alone is not necessarily replayable: account,
        # cursor and array/envelope bytes also consume the 256 KiB page budget.
        # Reject before sequence allocation rather than store an undeliverable
        # record. Existing larger rows fail paging without advancing the cursor.
        if (len(encoded) > RECORD_CANONICAL_BYTES
                or self._page_size(account_id, "x" * 43, (replay,), (), bootstrap=True) > RECORD_CANONICAL_BYTES
                or self._page_size(account_id, "x" * 43, (replay,), (), bootstrap=False) > RECORD_CANONICAL_BYTES):
            return self._failure(upload, "payload_too_large")
        exempt = isinstance(upload.payload, TombstonePayload)
        old_length = (existing["canonical_length"] or 0) if existing else 0
        byte_delta = len(encoded) - old_length
        record_delta = 0 if old_length else 1
        target = None
        purge_after = None
        if exempt:
            target = db.execute("SELECT * FROM sync_records WHERE account_id=%s AND record_id=%s",
                                (account_id, upload.payload.target_record_id)).fetchone()
            if target and target["record_type"] == "tombstone":
                return self._failure(upload, "invalid_record")
            expiry = db.execute("SELECT max(expires_at) AS expiry FROM sync_cursors WHERE account_id=%s AND position<%s",
                                (account_id, sequence)).fetchone()["expiry"]
            purge_after = max(now, expiry or now) + TOMBSTONE_RETENTION_SECONDS
            if target and target["revision"] <= upload.payload.deletion_revision:
                byte_delta -= target["canonical_length"] or 0
                record_delta -= int(target["canonical_bytes"] is not None)
            else:
                target = None
        else:
            usage = db.execute("""SELECT count(*) AS n, min(admitted_at) AS oldest
                FROM sync_ingest_admissions WHERE account_id=%s AND NOT quota_exempt
                AND admitted_at>%s""", (account_id, now - _DAY)).fetchone()
            if usage["n"] >= ACCOUNT_INGEST_RECORDS:
                retry = max(1, min(_DAY, math.ceil(usage["oldest"] + _DAY - now)))
                return self._failure(upload, "quota_exhausted", "retryable", retry)
            retained = db.execute("SELECT retained_bytes FROM sync_retained_bytes WHERE account_id=%s",
                                  (account_id,)).fetchone()["retained_bytes"]
            if retained + byte_delta > RETAINED_CANONICAL_BYTES:
                return self._failure(upload, "quota_exhausted", "retryable")
        db.execute("UPDATE sync_sequence_allocators SET last_change_sequence=%s WHERE account_id=%s",
                   (sequence, account_id))
        db.execute("""INSERT INTO sync_records
            (account_id, record_id, record_type, schema_version, source_device_id, revision,
             change_sequence, conversation_id, logical_request_id, target_record_id,
             canonical_bytes, canonical_sha256, canonical_length, accepted_at, updated_at, purge_after)
            VALUES (%s,%s,%s,1,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT (account_id, record_id) DO UPDATE SET
                source_device_id=EXCLUDED.source_device_id, revision=EXCLUDED.revision,
                change_sequence=EXCLUDED.change_sequence, conversation_id=EXCLUDED.conversation_id,
                logical_request_id=EXCLUDED.logical_request_id, target_record_id=EXCLUDED.target_record_id,
                canonical_bytes=EXCLUDED.canonical_bytes, canonical_sha256=EXCLUDED.canonical_sha256,
                canonical_length=EXCLUDED.canonical_length, updated_at=EXCLUDED.updated_at,
                purge_after=EXCLUDED.purge_after, tombstoned=false""",
                   (account_id, upload.record_id, upload.record_type, device_id, upload.revision,
                    sequence, upload.conversation_id, getattr(upload.payload, "logical_request_id", None),
                    upload.payload.target_record_id if exempt else None, encoded,
                    hashlib.sha256(encoded).digest(), len(encoded), now, now, purge_after))
        if target:
            db.execute("""UPDATE sync_records SET tombstoned=true, canonical_bytes=NULL,
                canonical_sha256=NULL, canonical_length=NULL, updated_at=%s, purge_after=%s
                WHERE account_id=%s AND record_id=%s""",
                       (now, purge_after, account_id, target["record_id"]))
        db.execute("""INSERT INTO sync_changes
            (account_id, change_sequence, change_kind, record_id, revision, committed_at)
            VALUES (%s,%s,%s,%s,%s,%s)""",
                   (account_id, sequence, "tombstone" if exempt else "record", upload.record_id, upload.revision, now))
        db.execute("""INSERT INTO sync_ingest_admissions
            (account_id, change_sequence, record_id, revision, canonical_length, quota_exempt, admitted_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s)""",
                   (account_id, sequence, upload.record_id, upload.revision, len(encoded), exempt, now))
        db.execute("""UPDATE sync_retained_bytes SET retained_bytes=retained_bytes+%s,
            retained_records=retained_records+%s, updated_at=%s WHERE account_id=%s""",
                   (byte_delta, record_delta, now, account_id))
        return RecordOutcome(upload.record_id, "accepted", upload.revision, sequence, None)

    @staticmethod
    def _position(db, account_id, device_id, cursor, now):
        if cursor is None or cursor == "":
            return 0, None
        if type(cursor) is not str or _ID.fullmatch(cursor) is None:
            raise SyncError("reset_required")
        row = db.execute("""SELECT position, snapshot_sequence FROM sync_cursors
            WHERE account_id=%s AND device_id=%s AND cursor_id=%s AND expires_at>%s""",
                         (account_id, device_id, cursor, now)).fetchone()
        if row is None:
            raise SyncError("reset_required")
        db.execute("UPDATE sync_cursors SET last_used_at=%s WHERE account_id=%s AND cursor_id=%s",
                   (now, account_id, cursor))
        return row["position"], row["snapshot_sequence"]

    @staticmethod
    def _cursor(db, account_id, device_id, position, snapshot, now, *, token=None):
        token = secrets.token_urlsafe(32) if token is None else token
        db.execute("""INSERT INTO sync_cursors
            (account_id, cursor_id, device_id, position, snapshot_sequence, issued_at, last_used_at, expires_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
                   (account_id, token, device_id, position, snapshot, now, now, now + MAX_CURSOR_TTL_SECONDS))
        # Persist protection at issuance, so revocation/expiry cannot erase the
        # last protecting lease. Retired tombstones (NULL horizon) stay retired.
        db.execute("""UPDATE sync_records SET purge_after=GREATEST(purge_after,%s)
            WHERE account_id=%s AND record_type='tombstone'
            AND purge_after IS NOT NULL AND change_sequence>%s""",
                   (now + MAX_CURSOR_TTL_SECONDS + TOMBSTONE_RETENTION_SECONDS, account_id, position))
        return token

    @staticmethod
    def _page_size(account_id, token, records, markers, *, bootstrap, has_more=False):
        envelope = (StatePage(account_id, token, tuple(records), "active", tuple(markers))
                    if bootstrap else ChangePage(token, has_more, tuple(records)))
        return len(canonical_bytes(envelope.to_wire()))

    def _page(self, db, account_id, device_id, cursor, limit, max_bytes, now, *, bootstrap):
        if (type(limit) is not int or not 1 <= limit <= 100 or type(max_bytes) is not int
                or not 1 <= max_bytes <= RECORD_CANONICAL_BYTES):
            raise SyncError("invalid_request")
        position, snapshot = self._position(db, account_id, device_id, cursor, now)
        highwater = db.execute("SELECT last_change_sequence FROM sync_sequence_allocators WHERE account_id=%s",
                               (account_id,)).fetchone()["last_change_sequence"]
        if bootstrap and snapshot is None:
            snapshot = highwater
        upper = snapshot if snapshot is not None else highwater
        rows = db.execute("""SELECT change_sequence, canonical_bytes, false AS marker FROM sync_records
            WHERE account_id=%s AND change_sequence>%s AND change_sequence<=%s AND NOT tombstoned
            AND (record_type<>'tombstone' OR purge_after IS NOT NULL)
            UNION ALL
            SELECT change_sequence, canonical_bytes, true AS marker FROM sync_retention_markers
            WHERE account_id=%s AND change_sequence>%s AND change_sequence<=%s
            ORDER BY change_sequence LIMIT %s""",
                          (account_id, position, upper, account_id, position, upper, limit + 1)).fetchall()
        selected, markers, count = [], [], 0
        token = secrets.token_urlsafe(32)
        if self._page_size(account_id, token, selected, markers, bootstrap=bootstrap) > max_bytes:
            raise SyncError("payload_too_large")
        for row in rows:
            if count >= limit:
                break
            next_records, next_markers = selected, markers
            if row["marker"]:
                if snapshot is None:
                    raise SyncError("reset_required")
                if bootstrap:
                    next_markers = [*markers, bytes(row["canonical_bytes"]).decode("utf-8")]
                # A changes() cursor continuing a state rebuild has already
                # reset its local projection. Skip snapshot markers: the
                # current records include their effects. Markers created after
                # the pinned snapshot still require a reset at live handoff.
            else:
                next_records = [*selected, self._record(row)]
            candidate_more = count + 1 < len(rows) or upper < highwater
            if self._page_size(account_id, token, next_records, next_markers,
                               bootstrap=bootstrap, has_more=candidate_more) > max_bytes:
                if not count:
                    raise SyncError("payload_too_large")
                break
            selected, markers = next_records, next_markers
            position = row["change_sequence"]
            count += 1
        more = count < len(rows)
        if not more:
            position = upper  # safely advance over superseded/removed entries
        token = self._cursor(db, account_id, device_id, position, snapshot if more else None, now, token=token)
        return ChangePage(token, more or upper < highwater, tuple(selected)), tuple(markers)

    def changes(self, account_id: str, device_id: str, cursor: str | None = None,
                *, limit: int = 100, max_bytes: int = 262144) -> ChangePage:
        self._admit_rate(account_id, device_id, "replay")
        with self._transaction(account_id) as (db, now, _):
            self._device(db, account_id, device_id)
            page, _ = self._page(db, account_id, device_id, cursor, limit, max_bytes, now, bootstrap=False)
            return page

    def bootstrap(self, account_id: str, device_id: str, cursor: str | None = None,
                  *, limit: int = 100, max_bytes: int = 262144) -> StatePage:
        self._admit_rate(account_id, device_id, "replay")
        with self._transaction(account_id) as (db, now, _):
            self._device(db, account_id, device_id)
            page, markers = self._page(db, account_id, device_id, cursor, limit, max_bytes, now, bootstrap=True)
            return StatePage(account_id, page.next_cursor, page.records, "active", markers)

    def purge_expired(self, limit: int = 500) -> int:
        """Commit at most ``limit`` retention work items (1..10000).

        An item expires one auxiliary row, extends one legacy tombstone horizon,
        retires one tombstone from replay, or compacts one activity detail. Its
        marker/sequence/byte-ledger writes are part of that same item. The whole
        call is atomic. SKIP LOCKED leaves busy accounts for a later timer run;
        a short batch therefore means no *currently unlocked* eligible work.

        Tombstone bytes remain charged as permanent deletion barriers: the
        deployed schema cannot represent a byte-free tombstone. No account or
        record deletion fence is removed. Candidate discovery uses database
        indexes; the item/lock budget does not bound PostgreSQL rows examined.
        """
        import psycopg
        from psycopg import sql
        from psycopg.rows import dict_row

        if type(limit) is not int or not 1 <= limit <= 10000:
            raise ValueError("Invalid retention batch size")
        try:
            with psycopg.connect(self._dsn, row_factory=dict_row, connect_timeout=10) as db:
                db.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                db.execute(sql.SQL("SET LOCAL search_path TO {}").format(sql.Identifier(self.schema)))
                db.execute("SET LOCAL lock_timeout = '10s'")
                db.execute("SET LOCAL statement_timeout = '30s'")
                now = self.clock()
                params = {"now": now, "retention": TOMBSTONE_RETENTION_SECONDS,
                          "age": ACTIVITY_COMPACTION_AGE_SECONDS}
                count = 0
                for _ in range(limit):
                    account = db.execute("""SELECT a.account_id FROM sync_accounts a
                        CROSS JOIN LATERAL (SELECT * FROM (""" + _RETENTION_WORK + """) work
                            ORDER BY due,kind,key LIMIT 1) w
                        WHERE a.state='active' AND NOT EXISTS (
                            SELECT 1 FROM account_deletions d WHERE d.uid=a.account_id
                            AND d.state<>'cancelled')
                        ORDER BY w.due,a.account_id LIMIT 1 FOR UPDATE OF a SKIP LOCKED""",
                                         params).fetchone()
                    if account is None:
                        break
                    # Re-read after acquiring the lock: the candidate statement
                    # may have raced a writer committing just before the lock.
                    work = db.execute("""SELECT w.* FROM sync_accounts a CROSS JOIN LATERAL (
                        SELECT * FROM (""" + _RETENTION_WORK + """) work
                        ORDER BY due,kind,key LIMIT 1) w WHERE a.account_id=%(account)s""",
                                      {**params, "account": account["account_id"]}).fetchone()
                    if work is None:
                        continue
                    self._purge_item(db, account["account_id"], work, now)
                    count += 1
                return count
        except psycopg.Error:
            raise SyncError("temporarily_unavailable") from None

    def _purge_item(self, db, account_id, work, now):
        from psycopg import sql

        kind, key = work["kind"], work["key"]
        auxiliary = {"cursor": ("sync_cursors", "cursor_id"),
                     "idempotency": ("sync_idempotency", "idempotency_key"),
                     "rate": ("sync_rate_windows", "ctid"),
                     "ingest": ("sync_ingest_admissions", "change_sequence")}
        if kind in auxiliary:
            table, column = auxiliary[kind]
            db.execute(sql.SQL("DELETE FROM {} WHERE account_id=%s AND {}=%s").format(
                sql.Identifier(table), sql.Identifier(column)), (account_id, key))
            return
        row = db.execute("SELECT * FROM sync_records WHERE account_id=%s AND record_id=%s",
                         (account_id, key)).fetchone()
        if kind == "horizon":
            db.execute("""UPDATE sync_records SET purge_after=(
                SELECT max(expires_at)+%s FROM sync_cursors WHERE account_id=%s AND position<%s)
                WHERE account_id=%s AND record_id=%s""",
                       (TOMBSTONE_RETENTION_SECONDS, account_id, row["change_sequence"], account_id, key))
            return
        summary, request, freed_bytes, freed_records = None, None, 0, 0
        if kind == "tombstone":
            db.execute("UPDATE sync_records SET purge_after=NULL WHERE account_id=%s AND record_id=%s",
                       (account_id, key))
            # Keep the record and target identity/revision fences permanently.
            db.execute("DELETE FROM sync_changes WHERE account_id=%s AND change_sequence=%s",
                       (account_id, row["change_sequence"]))
        else:
            request = row["logical_request_id"]
            terminal = db.execute("""SELECT * FROM sync_records WHERE account_id=%s
                AND logical_request_id=%s AND record_type='activity' AND NOT tombstoned
                AND convert_from(canonical_bytes,'UTF8')::jsonb->'payload'->>'kind'='request'
                AND convert_from(canonical_bytes,'UTF8')::jsonb->'payload'->>'status'
                    IN ('succeeded','failed','cancelled','interrupted')
                ORDER BY change_sequence DESC LIMIT 1""", (account_id, request)).fetchone()
            payload = self._record(terminal).payload
            summary = {"terminalRecordId": terminal["record_id"], "status": payload.status,
                       "updatedAt": payload.updated_at, "usageRecordId": payload.usage_record_id}
            freed_bytes, freed_records = row["canonical_length"], 1
            db.execute("""UPDATE sync_records SET tombstoned=true, canonical_bytes=NULL,
                canonical_sha256=NULL, canonical_length=NULL WHERE account_id=%s AND record_id=%s""",
                       (account_id, key))
        self._retention_marker(db, account_id, "tombstone_expiry" if kind == "tombstone"
                               else "activity_compaction", row["change_sequence"], request,
                               freed_bytes, freed_records, summary, now)

    @staticmethod
    def _retention_marker(db, account_id, kind, through, request, freed_bytes, freed_records, summary, now):
        previous = None
        if request is not None:
            previous = db.execute("""SELECT * FROM sync_retention_markers WHERE account_id=%s
                AND marker_kind='activity_compaction' AND logical_request_id=%s
                ORDER BY change_sequence DESC LIMIT 1""", (account_id, request)).fetchone()
        sequence = db.execute("""UPDATE sync_sequence_allocators
            SET last_change_sequence=last_change_sequence+1
            WHERE account_id=%s AND last_change_sequence<%s RETURNING last_change_sequence""",
                              (account_id, MAX_CHANGE_SEQUENCE)).fetchone()
        if sequence is None:
            raise SyncError("temporarily_unavailable")
        sequence = sequence["last_change_sequence"]
        wire = {"schemaVersion": 1, "accountId": account_id, "markerKind": kind,
                "changeSequence": sequence, "throughChangeSequence": max(
                    through, previous["through_change_sequence"] if previous else 0),
                "logicalRequestId": request, "createdAt": _timestamp(now),
                "freedBytes": freed_bytes + (previous["freed_bytes"] if previous else 0),
                "freedRecords": freed_records + (previous["freed_records"] if previous else 0)}
        if summary is not None:
            wire["summary"] = summary
        encoded = canonical_bytes(wire)
        if previous:
            # Replace the bounded per-request summary at a NEW sequence. A
            # snapshot pinned before this transaction hands off to a reset.
            db.execute("DELETE FROM sync_changes WHERE account_id=%s AND change_sequence=%s",
                       (account_id, previous["change_sequence"]))
            db.execute("DELETE FROM sync_retention_markers WHERE account_id=%s AND marker_id=%s",
                       (account_id, previous["marker_id"]))
        marker = db.execute("""INSERT INTO sync_retention_markers
            (account_id,marker_kind,change_sequence,through_change_sequence,logical_request_id,
             freed_bytes,freed_records,canonical_bytes,canonical_sha256,canonical_length,created_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING marker_id""",
                            (account_id, kind, sequence, wire["throughChangeSequence"], request,
                             wire["freedBytes"], wire["freedRecords"], encoded,
                             hashlib.sha256(encoded).digest(), len(encoded), now)).fetchone()
        db.execute("""INSERT INTO sync_changes
            (account_id,change_sequence,change_kind,marker_id,committed_at)
            VALUES (%s,%s,'marker',%s,%s)""", (account_id, sequence, marker["marker_id"], now))
        db.execute("""UPDATE sync_retained_bytes SET retained_bytes=retained_bytes+%s,
            retained_records=retained_records+%s,updated_at=%s WHERE account_id=%s""",
                   (len(encoded) - (previous["canonical_length"] if previous else 0) - freed_bytes,
                    int(previous is None) - freed_records, now, account_id))

    def delete_account(self, account_id: str) -> None:
        from psycopg import sql

        with self._transaction(account_id, deleting=True) as (db, now, state):
            for table in _CHILD_TABLES:
                db.execute(sql.SQL("DELETE FROM {} WHERE account_id=%s").format(sql.Identifier(table)), (account_id,))
            if state != "deleted":
                db.execute("""UPDATE sync_accounts SET state='deleted',
                    fenced_at=COALESCE(fenced_at,%s), deleted_at=%s WHERE account_id=%s""",
                           (now, now, account_id))
