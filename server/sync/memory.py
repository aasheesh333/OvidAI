"""Deterministic in-memory sync authority used by repository contract tests."""

from __future__ import annotations

import hashlib
import time
from datetime import datetime, timezone
from dataclasses import dataclass, replace

from server.sync.canonical import canonical_bytes
from server.sync.cursors import CursorError, MAX_CURSOR_TTL_SECONDS, decode_cursor, encode_cursor
from server.sync.dto import ReplayRecord, TombstonePayload, UploadRecord
from server.sync.errors import SyncError
from server.sync.policy import ENROLLED_DEVICES, device_can_enroll


DEFAULT_MAX_RECORDS = 10_000
DEFAULT_MAX_RETAINED_BYTES = 100 * 1024 * 1024
DEFAULT_MAX_BATCH_RECORDS = 100
DEFAULT_MAX_PAGE_RECORDS = 100
DEFAULT_MAX_PAGE_BYTES = 256 * 1024


@dataclass(frozen=True)
class RecordResult:
    status: str
    record: ReplayRecord

    def to_wire(self):
        return {
            "recordId": self.record.record_id,
            "status": self.status,
            "revision": self.record.revision,
            "changeSequence": self.record.change_sequence,
            "error": None,
        }


@dataclass(frozen=True)
class BatchResult:
    results: tuple[RecordResult, ...]

    @property
    def accepted(self):
        return sum(item.status == "accepted" for item in self.results)

    @property
    def duplicates(self):
        return sum(item.status == "duplicate" for item in self.results)

    @property
    def rejected(self):
        return sum(item.status == "rejected" for item in self.results)

    @property
    def conflicts(self):
        return sum(item.status == "conflict" for item in self.results)

    def to_wire(self):
        return {"schemaVersion": 1,
                "results": [item.to_wire() for item in self.results]}


@dataclass(frozen=True)
class ChangePage:
    records: tuple[ReplayRecord, ...]
    next_cursor: str
    has_more: bool

    @property
    def cursor(self):
        return self.next_cursor

    def to_wire(self):
        return {"schemaVersion": 1, "records": [item.to_wire() for item in self.records],
                "nextCursor": self.next_cursor, "hasMore": self.has_more}


@dataclass(frozen=True)
class StatePage:
    account_id: str
    records: tuple[ReplayRecord, ...]
    next_cursor: str
    has_more: bool
    accepted_record_count: int

    def to_wire(self):
        return {"schemaVersion": 1, "accountId": self.account_id,
                "currentCursor": self.next_cursor,
                "records": [item.to_wire() for item in self.records],
                "enrollmentStatus": "active", "retentionMarkers": []}


@dataclass
class _Account:
    devices: set[str]
    revoked_devices: set[str]
    deleted: bool
    sequence: int
    records: dict[str, ReplayRecord]
    tombstoned: set[str]
    changes: list[ReplayRecord]
    idempotency: dict[str, tuple[bytes, BatchResult]]
    enrollments: dict[str, tuple[bytes, object]]
    revocations: dict[str, tuple[bytes, object]]


class InMemorySyncRepository:
    """A small, deterministic test authority; no persistence or concurrency claims."""

    def __init__(
        self,
        *,
        max_records: int = DEFAULT_MAX_RECORDS,
        max_retained_bytes: int = DEFAULT_MAX_RETAINED_BYTES,
        max_batch_records: int = DEFAULT_MAX_BATCH_RECORDS,
        max_devices: int = ENROLLED_DEVICES,
        cursor_secret: bytes = b"test-only sync cursor secret",
        now=None,
    ):
        self.max_records = max_records
        self.max_retained_bytes = max_retained_bytes
        self.max_batch_records = max_batch_records
        self.max_devices = max_devices
        self.cursor_secret = cursor_secret
        self.now = time.time if now is None else now
        self._accounts: dict[str, _Account] = {}

    def _account(self, uid: str) -> _Account:
        if type(uid) is not str or not uid:
            raise SyncError("invalid_request")
        return self._accounts.setdefault(uid, _Account(set(), set(), False, 0, {}, set(), [], {}, {}, {}))

    @staticmethod
    def _digest(value) -> bytes:
        return hashlib.sha256(canonical_bytes(value)).digest()

    def register_device(self, uid: str, device_id: str) -> None:
        account = self._account(uid)
        if account.deleted:
            raise SyncError("account_fenced")
        if type(device_id) is not str or not device_id:
            raise SyncError("invalid_request")
        account.devices.add(device_id)
        account.revoked_devices.discard(device_id)

    def enroll(self, uid: str, consent: bool, device_name: str, idempotency_key: str):
        if consent is not True or type(device_name) is not str or not device_name:
            raise SyncError("invalid_request")
        if type(idempotency_key) is not str or not idempotency_key:
            raise SyncError("invalid_request")
        account = self._account(uid)
        if account.deleted:
            raise SyncError("account_fenced")
        digest = self._digest({"consent": consent, "deviceName": device_name})
        replay = account.enrollments.get(idempotency_key)
        if replay is not None:
            if replay[0] != digest:
                raise SyncError("integrity_conflict")
            return replay[1]
        if not device_can_enroll(len(account.devices)) or len(account.devices) >= self.max_devices:
            raise SyncError("quota_exhausted")
        device_id = f"device-{len(account.devices) + 1}"
        self.register_device(uid, device_id)
        from server.sync.results import DeviceEnrollment
        result = DeviceEnrollment(device_id, device_name,
                                  datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                                  "active")
        account.enrollments[idempotency_key] = (digest, result)
        return result

    def revoke_device(self, uid: str, device_id: str) -> None:
        account = self._account(uid)
        if device_id not in account.devices:
            raise SyncError("not_found")
        account.revoked_devices.add(device_id)

    def revoke(self, uid: str, requester_device_id: str, target_device_id: str,
               idempotency_key: str, fresh_auth: bool = False):
        account = self._account(uid)
        if account.deleted:
            raise SyncError("account_fenced")
        if not fresh_auth or not idempotency_key:
            raise SyncError("invalid_request")
        digest = self._digest({"requesterDeviceId": requester_device_id,
                               "targetDeviceId": target_device_id,
                               "freshAuth": fresh_auth})
        replay = account.revocations.get(idempotency_key)
        if replay is not None:
            if replay[0] != digest:
                raise SyncError("integrity_conflict")
            return replay[1]
        self._authorize(uid, requester_device_id)
        self.revoke_device(uid, target_device_id)
        from server.sync.results import DeviceEnrollment
        result = DeviceEnrollment(target_device_id, "",
                                  datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                                  "revoked")
        account.revocations[idempotency_key] = (digest, result)
        return result

    def delete_account(self, uid: str) -> None:
        account = self._account(uid)
        account.deleted = True
        account.records.clear()
        account.changes.clear()
        account.idempotency.clear()
        account.enrollments.clear()
        account.revocations.clear()

    def _authorize(self, uid: str, device_id: str) -> _Account:
        account = self._account(uid)
        if account.deleted:
            raise SyncError("account_fenced")
        if device_id not in account.devices or device_id in account.revoked_devices:
            raise SyncError("device_revoked")
        return account

    @staticmethod
    def _fingerprint(record: UploadRecord) -> bytes:
        return canonical_bytes(record.to_wire())

    def _cursor(self, uid: str, device_id: str, sequence: int) -> str:
        if sequence == 0:
            return ""
        now = int(self.now())
        return encode_cursor(uid, device_id, sequence, now + MAX_CURSOR_TTL_SECONDS,
                             self.cursor_secret, now=now)

    def _read_cursor(self, uid: str, device_id: str, cursor: str | None) -> int:
        if cursor is None or cursor == "":
            return 0
        try:
            position = decode_cursor(cursor, uid, device_id, self.cursor_secret,
                                     now=int(self.now())).change_sequence
        except CursorError:
            raise SyncError("reset_required") from None
        if position > self._account(uid).sequence:
            raise SyncError("reset_required")
        return position

    def _retained_bytes(self, account: _Account) -> int:
        return sum(len(self._fingerprint(self._as_upload(record))) for record in account.records.values())

    @staticmethod
    def _as_upload(record: ReplayRecord) -> UploadRecord:
        return UploadRecord(
            record_id=record.record_id,
            source_device_id=record.source_device_id,
            record_type=record.record_type,
            conversation_id=record.conversation_id,
            created_at=record.created_at,
            revision=record.revision,
            payload=record.payload,
        )

    def admit_batch(self, uid: str, device_id: str, idempotency_key: str, records) -> BatchResult:
        account = self._authorize(uid, device_id)
        if type(idempotency_key) is not str or not idempotency_key:
            raise SyncError("invalid_request")
        records = tuple(records)
        if len(records) > self.max_batch_records:
            raise SyncError("payload_too_large")
        if any(not isinstance(item, UploadRecord) for item in records):
            raise SyncError("invalid_record")
        if idempotency_key in account.idempotency:
            digest = self._digest([item.to_wire() for item in records])
            stored_digest, result = account.idempotency[idempotency_key]
            if stored_digest != digest:
                raise SyncError("integrity_conflict")
            return result
        # Stage the whole batch: later records see earlier admissions, but a
        # conflict or quota failure must not publish any sequence or receipt.
        account = replace(account, records=dict(account.records),
                          tombstoned=set(account.tombstoned), changes=list(account.changes),
                          idempotency=dict(account.idempotency))
        results = []
        accepted = []
        for upload in records:
            existing = account.records.get(upload.record_id)
            if upload.record_id in account.tombstoned:
                results.append(RecordResult("duplicate", account.records[next(
                    key for key, value in account.records.items()
                    if isinstance(value.payload, TombstonePayload)
                    and value.payload.target_record_id == upload.record_id
                )]))
                continue
            if existing is not None:
                if isinstance(existing.payload, TombstonePayload):
                    results.append(RecordResult("duplicate", existing))
                    continue
                if upload.revision == existing.revision and self._fingerprint(upload) == self._fingerprint(self._as_upload(existing)):
                    results.append(RecordResult("duplicate", existing))
                    continue
                if upload.revision <= existing.revision:
                    raise SyncError("integrity_conflict")
            if isinstance(upload.payload, TombstonePayload):
                target = account.records.get(upload.payload.target_record_id)
                if target is not None and upload.revision <= target.revision:
                    raise SyncError("integrity_conflict")
            accepted.append(upload)
            account.sequence += 1
            replay = ReplayRecord.from_upload(upload, uid, account.sequence)
            account.records[upload.record_id] = replay
            account.changes.append(replay)
            if isinstance(upload.payload, TombstonePayload):
                account.records[upload.payload.target_record_id] = replay
                account.tombstoned.add(upload.payload.target_record_id)
            results.append(RecordResult("accepted", replay))
        if len(account.records) > self.max_records or self._retained_bytes(account) > self.max_retained_bytes:
            if any(not isinstance(upload.payload, TombstonePayload) for upload in accepted):
                raise SyncError("quota_exhausted")
        result = BatchResult(tuple(results))
        account.idempotency[idempotency_key] = (self._digest([item.to_wire() for item in records]), result)
        self._accounts[uid] = account
        return result

    def changes(self, uid: str, device_id: str, cursor: str | None = None, *, limit: int = DEFAULT_MAX_PAGE_RECORDS, max_bytes: int = DEFAULT_MAX_PAGE_BYTES) -> ChangePage:
        account = self._authorize(uid, device_id)
        if type(limit) is not int or not 1 <= limit <= DEFAULT_MAX_PAGE_RECORDS or type(max_bytes) is not int or max_bytes < 1:
            raise SyncError("invalid_request")
        position = self._read_cursor(uid, device_id, cursor)
        selected = []
        used = 0
        for item in account.changes:
            if item.change_sequence <= position:
                continue
            size = len(canonical_bytes(item.to_wire()))
            if not selected and size > max_bytes:
                raise SyncError("payload_too_large")
            if len(selected) >= limit or used + size > max_bytes:
                break
            selected.append(item)
            used += size
        next_position = selected[-1].change_sequence if selected else position
        has_more = any(item.change_sequence > next_position for item in account.changes)
        return ChangePage(tuple(selected), self._cursor(uid, device_id, next_position), has_more)

    def bootstrap(self, uid: str, device_id: str, cursor: str | None = None, *, limit: int = DEFAULT_MAX_PAGE_RECORDS, max_bytes: int = DEFAULT_MAX_PAGE_BYTES) -> StatePage:
        page = self.changes(uid, device_id, cursor, limit=limit, max_bytes=max_bytes)
        account = self._authorize(uid, device_id)
        return StatePage(uid, page.records, page.next_cursor, page.has_more,
                         len(account.records) - len(account.tombstoned))
