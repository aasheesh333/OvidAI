"""Closed, immutable response envelopes for the private-sync API."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar

from server.sync.dto import ReplayRecord
from server.sync.errors import SyncError, parse_error

SCHEMA_VERSION = 1
_STATUSES = frozenset(("accepted", "duplicate", "rejected", "conflict", "retryable"))
_ENROLLMENT_STATUSES = frozenset(("active", "revoked"))


def _fail() -> None:
    raise SyncError("invalid_request")


def _text(value: Any, *, empty: bool = False) -> str:
    if type(value) is not str or (not empty and not value) or len(value) > 128:
        _fail()
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        _fail()
    return value


def _timestamp(value: Any) -> str:
    if type(value) is not str or not value.endswith("Z") or not value.isascii() or len(value) > 30:
        _fail()
    return value


def _versioned(value: object, keys: set[str]) -> dict:
    if type(value) is not dict or set(value) != keys or value["schemaVersion"] != SCHEMA_VERSION:
        _fail()
    if type(value["schemaVersion"]) is not int:
        _fail()
    return value


@dataclass(frozen=True)
class RecordOutcome:
    """The server's independent disposition of one uploaded record."""

    record_id: str
    status: str
    revision: int | None
    change_sequence: int | None
    error: SyncError | None

    def __post_init__(self) -> None:
        _text(self.record_id)
        if self.status not in _STATUSES:
            _fail()
        for value in (self.revision, self.change_sequence):
            if value is not None and (type(value) is not int or value < 1):
                _fail()
        if self.status in ("accepted", "duplicate"):
            if self.revision is None or self.change_sequence is None or self.error is not None:
                _fail()
        elif self.status in ("rejected", "conflict", "retryable"):
            if self.error is None or self.revision is not None or self.change_sequence is not None:
                _fail()

    def to_wire(self) -> dict:
        return {"recordId": self.record_id, "status": self.status,
                "revision": self.revision, "changeSequence": self.change_sequence,
                "error": None if self.error is None else self.error.to_wire()}

    @classmethod
    def from_wire(cls, value: object) -> "RecordOutcome":
        if type(value) is not dict or set(value) != {
            "recordId", "status", "revision", "changeSequence", "error"
        }:
            _fail()
        error = None if value["error"] is None else parse_error(value["error"])
        try:
            return cls(value["recordId"], value["status"], value["revision"],
                       value["changeSequence"], error)
        except SyncError:
            raise
        except (TypeError, ValueError):
            _fail()


@dataclass(frozen=True)
class BatchResult:
    results: tuple[RecordOutcome, ...]

    def __post_init__(self) -> None:
        if type(self.results) is not tuple or not all(isinstance(x, RecordOutcome) for x in self.results):
            _fail()

    def to_wire(self) -> dict:
        return {"schemaVersion": SCHEMA_VERSION,
                "results": [result.to_wire() for result in self.results]}


def parse_batch_result(value: object) -> BatchResult:
    value = _versioned(value, {"schemaVersion", "results"})
    if type(value["results"]) is not list:
        _fail()
    return BatchResult(tuple(RecordOutcome.from_wire(item) for item in value["results"]))


@dataclass(frozen=True)
class ChangePage:
    next_cursor: str
    has_more: bool
    records: tuple[ReplayRecord, ...]

    def __post_init__(self) -> None:
        _text(self.next_cursor, empty=True)
        if type(self.has_more) is not bool or type(self.records) is not tuple:
            _fail()
        if not all(isinstance(record, ReplayRecord) for record in self.records):
            _fail()

    def to_wire(self) -> dict:
        return {"schemaVersion": SCHEMA_VERSION, "nextCursor": self.next_cursor,
                "hasMore": self.has_more, "records": [r.to_wire() for r in self.records]}


def parse_change_page(value: object) -> ChangePage:
    value = _versioned(value, {"schemaVersion", "nextCursor", "hasMore", "records"})
    if type(value["records"]) is not list:
        _fail()
    return ChangePage(value["nextCursor"], value["hasMore"],
                      tuple(ReplayRecord.from_wire(item) for item in value["records"]))


@dataclass(frozen=True)
class DeviceEnrollment:
    device_id: str
    device_name: str
    created_at: str
    status: str

    def __post_init__(self) -> None:
        _text(self.device_id)
        _text(self.device_name, empty=True)
        _timestamp(self.created_at)
        if self.status not in _ENROLLMENT_STATUSES:
            _fail()

    def to_wire(self) -> dict:
        return {"schemaVersion": SCHEMA_VERSION, "deviceId": self.device_id,
                "deviceName": self.device_name, "createdAt": self.created_at,
                "status": self.status}


def parse_device_enrollment(value: object) -> DeviceEnrollment:
    value = _versioned(value, {"schemaVersion", "deviceId", "deviceName", "createdAt", "status"})
    return DeviceEnrollment(value["deviceId"], value["deviceName"], value["createdAt"], value["status"])


@dataclass(frozen=True)
class StatePage:
    account_id: str
    current_cursor: str
    records: tuple[ReplayRecord, ...]
    enrollment_status: str
    retention_markers: tuple[str, ...]

    def __post_init__(self) -> None:
        _text(self.account_id)
        _text(self.current_cursor, empty=True)
        if type(self.records) is not tuple or not all(isinstance(x, ReplayRecord) for x in self.records):
            _fail()
        if type(self.enrollment_status) is not str or not self.enrollment_status:
            _fail()
        if type(self.retention_markers) is not tuple or not all(type(x) is str for x in self.retention_markers):
            _fail()

    def to_wire(self) -> dict:
        return {"schemaVersion": SCHEMA_VERSION, "accountId": self.account_id,
                "currentCursor": self.current_cursor,
                "records": [r.to_wire() for r in self.records],
                "enrollmentStatus": self.enrollment_status,
                "retentionMarkers": list(self.retention_markers)}


def parse_state_page(value: object) -> StatePage:
    value = _versioned(value, {"schemaVersion", "accountId", "currentCursor", "records",
                               "enrollmentStatus", "retentionMarkers"})
    if type(value["records"]) is not list or type(value["retentionMarkers"]) is not list:
        _fail()
    return StatePage(value["accountId"], value["currentCursor"],
                     tuple(ReplayRecord.from_wire(item) for item in value["records"]),
                     value["enrollmentStatus"], tuple(value["retentionMarkers"]))
