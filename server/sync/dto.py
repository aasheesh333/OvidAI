"""Closed, immutable v1 private-sync DTOs.

Exact camelCase wire names, closed field sets, ``schemaVersion == 1``,
integers that reject ``bool``, inclusive bounds and Unicode-scalar text limits
come from docs/superpowers/specs/2026-10-08-private-account-sync-design.md.

These are data-only types: there is no generic map-to-runtime conversion and
no field may carry a callback, command, credential or process handle.
Transcript text is preserved verbatim (private sync never applies public-share
redaction).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Callable, ClassVar, Mapping, Union

from server.sync.endpoints import EndpointPolicy, validate_endpoint
from server.sync.errors import SyncError

SCHEMA_VERSION = 1
MAX_ID_BYTES = 128
MAX_TIMESTAMP_BYTES = 30
INT32_MAX = 2147483647
UINT32_MAX = 4294967295
MAX_ELAPSED_MS = 604800000
# changeSequence is server-assigned; bounded by the JSON exact-integer range.
MAX_CHANGE_SEQUENCE = 2**53 - 1

RECORD_TYPES = ("transcript", "providerMetadata", "usage", "activity", "tombstone")

# Visible ASCII (0x21..0x7E): no spaces or controls in opaque IDs.
_ID = re.compile(r"\A[\x21-\x7e]{1,128}\Z")
_TIMESTAMP = re.compile(
    r"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,9})?Z\Z"
)


class _Bad(Exception):
    pass


# --------------------------------------------------------------------------
# Field validators. Each returns the value or raises _Bad.


def _id(value):
    if type(value) is not str or not _ID.match(value):
        raise _Bad()
    return value


def _text(low: int, high: int) -> Callable[[Any], str]:
    def check(value):
        if type(value) is not str or not low <= len(value) <= high:
            raise _Bad()
        try:
            value.encode("utf-8")  # rejects lone surrogates
        except UnicodeEncodeError:
            raise _Bad() from None
        return value

    return check


def _int(low: int, high: int) -> Callable[[Any], int]:
    def check(value):
        if type(value) is not int or not low <= value <= high:
            raise _Bad()
        return value

    return check


def _bool(value):
    if type(value) is not bool:
        raise _Bad()
    return value


def _enum(*allowed: str) -> Callable[[Any], str]:
    options = frozenset(allowed)

    def check(value):
        if type(value) is not str or value not in options:
            raise _Bad()
        return value

    return check


def _days(year: int, month: int) -> int:
    if month == 2:
        leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
        return 29 if leap else 28
    return 30 if month in (4, 6, 9, 11) else 31


def _timestamp(value):
    if type(value) is not str or len(value) > MAX_TIMESTAMP_BYTES or not value.isascii():
        raise _Bad()
    match = _TIMESTAMP.match(value)
    if match is None:
        raise _Bad()
    year, month, day, hour, minute, second = (int(part) for part in match.groups()[:6])
    if not (
        1 <= year
        and 1 <= month <= 12
        and 1 <= day <= _days(year, month)
        and hour <= 23
        and minute <= 59
        and second <= 59  # leap seconds are not accepted
    ):
        raise _Bad()
    return value


def _nullable(check: Callable[[Any], Any]) -> Callable[[Any], Any]:
    def nullable(value):
        return None if value is None else check(value)

    return nullable


# --------------------------------------------------------------------------
# Payloads


def _read_closed(value: object, spec: tuple) -> dict:
    """Validate a closed object against ((wireName, attr, check), ...)."""
    if type(value) is not dict or set(value) != {name for name, _, _ in spec}:
        raise _Bad()
    return {attr: check(value[name]) for name, attr, check in spec}


class _Payload:
    _SPEC: ClassVar[tuple]

    @classmethod
    def from_wire(cls, value: object, **_context):
        try:
            return cls(**_read_closed(value, cls._SPEC))
        except _Bad:
            raise SyncError("invalid_record") from None

    def to_wire(self) -> dict:
        return {name: getattr(self, attr) for name, attr, _ in self._SPEC}


@dataclass(frozen=True)
class TranscriptPayload(_Payload):
    message_id: str
    parent_message_id: str | None
    kind: str
    text: str
    provider_metadata_record_id: str | None
    request_purpose: str | None
    display_title: str | None

    _SPEC: ClassVar[tuple] = (
        ("messageId", "message_id", _id),
        ("parentMessageId", "parent_message_id", _nullable(_id)),
        ("kind", "kind", _enum("user", "assistant", "system", "tool")),
        ("text", "text", _text(0, 262144)),
        ("providerMetadataRecordId", "provider_metadata_record_id", _nullable(_id)),
        ("requestPurpose", "request_purpose", _nullable(_text(0, 128))),
        ("displayTitle", "display_title", _nullable(_text(0, 256))),
    )


@dataclass(frozen=True)
class ProviderMetadataPayload(_Payload):
    provider_id: str
    model_id: str | None
    endpoint: str
    request_purpose: str | None
    display_name: str | None
    supports_streaming: bool

    _SPEC: ClassVar[tuple] = (
        ("providerId", "provider_id", _text(1, 64)),
        ("modelId", "model_id", _nullable(_text(1, 128))),
        ("endpoint", "endpoint", _text(1, 2048)),
        ("requestPurpose", "request_purpose", _nullable(_text(0, 128))),
        ("displayName", "display_name", _nullable(_text(0, 256))),
        ("supportsStreaming", "supports_streaming", _bool),
    )

    @classmethod
    def from_wire(cls, value: object, *, endpoint_policies: Mapping[str, EndpointPolicy] | None = None, **_context):
        record = super().from_wire(value)
        # Validation runs on upload and again on every import/replay parse; the
        # stored value is always the canonical credential-free identity.
        canonical = validate_endpoint(record.endpoint, record.provider_id, policies=endpoint_policies)
        return cls(**{**record.__dict__, "endpoint": canonical})


@dataclass(frozen=True)
class UsagePayload(_Payload):
    logical_request_id: str
    attempt_id: str
    requested_model: str | None
    reported_model: str | None
    outcome: str
    input_tokens: int | None
    output_tokens: int | None
    total_tokens: int | None
    usage_provenance: str
    started_at: str | None
    completed_at: str | None
    elapsed_milliseconds: int | None

    _SPEC: ClassVar[tuple] = (
        ("logicalRequestId", "logical_request_id", _id),
        ("attemptId", "attempt_id", _id),
        ("requestedModel", "requested_model", _nullable(_text(1, 128))),
        ("reportedModel", "reported_model", _nullable(_text(1, 128))),
        ("outcome", "outcome", _enum("pending", "succeeded", "failed", "cancelled", "interrupted", "unknown")),
        ("inputTokens", "input_tokens", _nullable(_int(0, INT32_MAX))),
        ("outputTokens", "output_tokens", _nullable(_int(0, INT32_MAX))),
        ("totalTokens", "total_tokens", _nullable(_int(0, UINT32_MAX))),
        ("usageProvenance", "usage_provenance",
         _enum("providerReported", "locallyEstimated", "derived", "unknown", "legacyUnspecified")),
        ("startedAt", "started_at", _nullable(_timestamp)),
        ("completedAt", "completed_at", _nullable(_timestamp)),
        ("elapsedMilliseconds", "elapsed_milliseconds", _nullable(_int(0, MAX_ELAPSED_MS))),
    )


@dataclass(frozen=True)
class ActivityPayload(_Payload):
    logical_request_id: str | None
    attempt_id: str | None
    kind: str
    status: str
    updated_at: str
    title: str
    detail: str
    usage_record_id: str | None

    _SPEC: ClassVar[tuple] = (
        ("logicalRequestId", "logical_request_id", _nullable(_id)),
        ("attemptId", "attempt_id", _nullable(_id)),
        ("kind", "kind", _enum("request", "tool", "mcp", "plugin", "browser", "build", "system")),
        ("status", "status", _enum("queued", "started", "succeeded", "failed", "cancelled", "interrupted", "unknown")),
        ("updatedAt", "updated_at", _timestamp),
        ("title", "title", _text(0, 256)),
        ("detail", "detail", _text(0, 2048)),
        ("usageRecordId", "usage_record_id", _nullable(_id)),
    )


@dataclass(frozen=True)
class TombstonePayload(_Payload):
    target_record_id: str
    deletion_revision: int
    deleted_at: str
    reason: str

    _SPEC: ClassVar[tuple] = (
        ("targetRecordId", "target_record_id", _id),
        ("deletionRevision", "deletion_revision", _int(1, INT32_MAX)),
        ("deletedAt", "deleted_at", _timestamp),
        ("reason", "reason", _enum("user", "account", "retention", "conflict", "admin")),
    )


Payload = Union[TranscriptPayload, ProviderMetadataPayload, UsagePayload, ActivityPayload, TombstonePayload]

PAYLOAD_TYPES: Mapping[str, type] = {
    "transcript": TranscriptPayload,
    "providerMetadata": ProviderMetadataPayload,
    "usage": UsagePayload,
    "activity": ActivityPayload,
    "tombstone": TombstonePayload,
}


# --------------------------------------------------------------------------
# Envelopes

_UPLOAD_SPEC = (
    ("recordId", "record_id", _id),
    ("sourceDeviceId", "source_device_id", _id),
    ("recordType", "record_type", _enum(*RECORD_TYPES)),
    ("conversationId", "conversation_id", _nullable(_id)),
    ("createdAt", "created_at", _timestamp),
    ("revision", "revision", _int(1, INT32_MAX)),
)
_REPLAY_EXTRA = (
    ("accountId", "account_id", _id),
    ("changeSequence", "change_sequence", _int(1, MAX_CHANGE_SEQUENCE)),
)


def _parse_envelope(value: object, spec: tuple, endpoint_policies) -> dict:
    if type(value) is not dict:
        raise SyncError("invalid_record")
    expected = {"schemaVersion", "payload"} | {name for name, _, _ in spec}
    if set(value) != expected:
        raise SyncError("invalid_record")
    version = value["schemaVersion"]
    if type(version) is not int:
        raise SyncError("invalid_record")
    if version != SCHEMA_VERSION:
        raise SyncError("schema_version_unsupported")
    try:
        fields = {attr: check(value[name]) for name, attr, check in spec}
    except _Bad:
        raise SyncError("invalid_record") from None
    payload_type = PAYLOAD_TYPES[fields["record_type"]]
    fields["payload"] = payload_type.from_wire(value["payload"], endpoint_policies=endpoint_policies)
    _check_identity(fields)
    return fields


def _check_identity(fields: dict) -> None:
    payload = fields["payload"]
    # Identity rule: a usage record's recordId is its attemptId.
    if isinstance(payload, UsagePayload) and fields["record_id"] != payload.attempt_id:
        raise SyncError("invalid_record")
    if isinstance(payload, TombstonePayload) and fields["record_id"] == payload.target_record_id:
        raise SyncError("invalid_record")


@dataclass(frozen=True)
class UploadRecord:
    """Client-submitted record. Never carries accountId or changeSequence."""

    record_id: str
    source_device_id: str
    record_type: str
    conversation_id: str | None
    created_at: str
    revision: int
    payload: Payload

    @classmethod
    def from_wire(cls, value: object, *, endpoint_policies: Mapping[str, EndpointPolicy] | None = None):
        return cls(**_parse_envelope(value, _UPLOAD_SPEC, endpoint_policies))

    def to_wire(self) -> dict:
        wire = {"schemaVersion": SCHEMA_VERSION}
        wire.update({name: getattr(self, attr) for name, attr, _ in _UPLOAD_SPEC})
        wire["payload"] = self.payload.to_wire()
        return wire


@dataclass(frozen=True)
class ReplayRecord:
    """Stored/replayed record including server-derived account and sequence."""

    record_id: str
    account_id: str
    source_device_id: str
    record_type: str
    conversation_id: str | None
    created_at: str
    revision: int
    change_sequence: int
    payload: Payload

    @classmethod
    def from_wire(cls, value: object, *, endpoint_policies: Mapping[str, EndpointPolicy] | None = None):
        return cls(**_parse_envelope(value, _UPLOAD_SPEC + _REPLAY_EXTRA, endpoint_policies))

    @classmethod
    def from_upload(cls, record: UploadRecord, account_id: str, change_sequence: int) -> "ReplayRecord":
        """Attach server-derived fields; inputs are validated like wire values."""
        try:
            _id(account_id)
            _int(1, MAX_CHANGE_SEQUENCE)(change_sequence)
        except _Bad:
            raise SyncError("invalid_record") from None
        return cls(account_id=account_id, change_sequence=change_sequence, **record.__dict__)

    def to_wire(self) -> dict:
        wire = {"schemaVersion": SCHEMA_VERSION}
        wire.update({name: getattr(self, attr) for name, attr, _ in _UPLOAD_SPEC + _REPLAY_EXTRA})
        wire["payload"] = self.payload.to_wire()
        return wire


def parse_upload(value: object, *, endpoint_policies: Mapping[str, EndpointPolicy] | None = None) -> UploadRecord:
    return UploadRecord.from_wire(value, endpoint_policies=endpoint_policies)


def parse_replay(value: object, *, endpoint_policies: Mapping[str, EndpointPolicy] | None = None) -> ReplayRecord:
    return ReplayRecord.from_wire(value, endpoint_policies=endpoint_policies)
