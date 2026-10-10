"""Deterministic in-memory sync authority used by repository contract tests."""

from __future__ import annotations

import base64
import hashlib
from datetime import datetime, timezone
from dataclasses import dataclass

from server.sync.canonical import canonical_bytes
from server.sync.dto import ReplayRecord, TombstonePayload, UploadRecord
from server.sync.errors import SyncError


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
    idempotency: dict[str, BatchResult]


class InMemorySyncRepository:
    """A small, deterministic test authority; no persistence or concurrency claims."""

    def __init__(
        self,
        *,
        max_records: int = DEFAULT_MAX_RECORDS,
        max_retained_bytes: int = DEFAULT_MAX_RETAINED_BYTES,
        max_batch_records: int = DEFAULT_MAX_BATCH_RECORDS,
    ):
        self.max_records = max_records
        self.max_retained_bytes = max_retained_bytes
        self.max_batch_records = max_batch_records
        self._accounts: dict[str, _Account] = {}

    def _account(self, uid: str) -> _Account:
        if type(uid) is not str or not uid:
            raise SyncError("invalid_request")
        return self._accounts.setdefault(uid, _Account(set(), set(), False, 0, {}, set(), [], {}))

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
        device_id = f"device-{len(account.devices) + 1}"
        self.register_device(uid, device_id)
        from server.sync.results import DeviceEnrollment
        return DeviceEnrollment(device_id, device_name,
                                datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                                "active")

    def revoke_device(self, uid: str, device_id: str) -> None:
        account = self._account(uid)
        if device_id not in account.devices:
            raise SyncError("not_found")
        account.revoked_devices.add(device_id)

    def revoke(self, uid: str, requester_device_id: str, target_device_id: str,
               idempotency_key: str, fresh_auth: bool = False):
        self._authorize(uid, requester_device_id)
        if not fresh_auth or not idempotency_key:
            raise SyncError("invalid_request")
        self.revoke_device(uid, target_device_id)
        from server.sync.results import DeviceEnrollment
        return DeviceEnrollment(target_device_id, "",
                                datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                                "revoked")

    def delete_account(self, uid: str) -> None:
        account = self._account(uid)
        account.deleted = True
        account.records.clear()
        account.changes.clear()
        account.idempotency.clear()

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

    def _cursor(self, uid: str, sequence: int) -> str:
        raw = f"v1:{hashlib.sha256(uid.encode()).hexdigest()[:32]}:{sequence}".encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    def _read_cursor(self, uid: str, cursor: str | None) -> int:
        if cursor is None:
            return 0
        if type(cursor) is not str or len(cursor) > 512:
            raise SyncError("invalid_request")
        try:
            raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
            prefix, account_hash, sequence = raw.split(":")
            if prefix != "v1" or account_hash != hashlib.sha256(uid.encode()).hexdigest()[:32]:
                raise ValueError
            position = int(sequence)
        except (ValueError, UnicodeDecodeError):
            raise SyncError("invalid_request") from None
        if position < 0:
            raise SyncError("invalid_request")
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
        if idempotency_key in account.idempotency:
            return account.idempotency[idempotency_key]
        if any(not isinstance(item, UploadRecord) for item in records):
            raise SyncError("invalid_record")

        pending: list[tuple[UploadRecord, str, ReplayRecord | None]] = []
        new_count = 0
        new_bytes = 0
        for upload in records:
            existing = account.records.get(upload.record_id)
            if upload.record_id in account.tombstoned:
                pending.append((upload, "duplicate", account.records[next(
                    key for key, value in account.records.items()
                    if isinstance(value.payload, TombstonePayload)
                    and value.payload.target_record_id == upload.record_id
                )]))
                continue
            if existing is not None:
                if isinstance(existing.payload, TombstonePayload):
                    pending.append((upload, "duplicate", existing))
                    continue
                if upload.revision == existing.revision and self._fingerprint(upload) == self._fingerprint(self._as_upload(existing)):
                    pending.append((upload, "duplicate", existing))
                    continue
                if upload.revision <= existing.revision:
                    raise SyncError("integrity_conflict")
            if isinstance(upload.payload, TombstonePayload):
                target = account.records.get(upload.payload.target_record_id)
                if target is not None and upload.revision <= target.revision:
                    raise SyncError("integrity_conflict")
            new_count += 1 if existing is None else 0
            new_bytes += len(self._fingerprint(upload))
            pending.append((upload, "accepted", None))

        if len(account.records) + new_count > self.max_records or self._retained_bytes(account) + new_bytes > self.max_retained_bytes:
            # Deletion records remain admissible when the retained quota is full.
            if not all(isinstance(upload.payload, TombstonePayload) for upload, status, _ in pending if status == "accepted"):
                raise SyncError("quota_exhausted")

        results = []
        for upload, status, existing in pending:
            if status == "duplicate":
                results.append(RecordResult(status, existing))
                continue
            account.sequence += 1
            replay = ReplayRecord.from_upload(upload, uid, account.sequence)
            account.records[upload.record_id] = replay
            account.changes.append(replay)
            if isinstance(upload.payload, TombstonePayload):
                account.records[upload.payload.target_record_id] = replay
                account.tombstoned.add(upload.payload.target_record_id)
            results.append(RecordResult("accepted", replay))
        result = BatchResult(tuple(results))
        account.idempotency[idempotency_key] = result
        return result

    def changes(self, uid: str, device_id: str, cursor: str | None = None, *, limit: int = DEFAULT_MAX_PAGE_RECORDS, max_bytes: int = DEFAULT_MAX_PAGE_BYTES) -> ChangePage:
        account = self._authorize(uid, device_id)
        if type(limit) is not int or not 1 <= limit <= DEFAULT_MAX_PAGE_RECORDS or type(max_bytes) is not int or max_bytes < 1:
            raise SyncError("invalid_request")
        position = self._read_cursor(uid, cursor)
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
        return ChangePage(tuple(selected), self._cursor(uid, next_position), has_more)

    def bootstrap(self, uid: str, device_id: str, cursor: str | None = None, *, limit: int = DEFAULT_MAX_PAGE_RECORDS, max_bytes: int = DEFAULT_MAX_PAGE_BYTES) -> StatePage:
        page = self.changes(uid, device_id, cursor, limit=limit, max_bytes=max_bytes)
        account = self._authorize(uid, device_id)
        return StatePage(uid, page.records, page.next_cursor, page.has_more,
                         len(account.records) - len(account.tombstoned))
