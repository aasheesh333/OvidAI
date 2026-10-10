"""Closed private-sync error DTO.

Wire shape is exactly ``{schemaVersion, code, message, retryAfterSeconds}``.
Messages are fixed per code; no constructor path accepts caller-supplied text,
so request bodies, transcript text, endpoints and credentials can never be
echoed in an error.
"""

from __future__ import annotations

from types import MappingProxyType

SCHEMA_VERSION = 1
MAX_RETRY_AFTER_SECONDS = 86400

# code -> (HTTP status, fixed non-sensitive message <= 160 chars)
_TABLE = {
    "invalid_request": (400, "The request is malformed."),
    "unauthenticated": (401, "Authentication is required."),
    "device_revoked": (403, "This device is no longer authorized for private sync."),
    "account_fenced": (403, "This account is not currently available for sync."),
    "not_found": (404, "The requested resource was not found."),
    "integrity_conflict": (409, "The record conflicts with the stored canonical record."),
    "payload_too_large": (413, "The request or record exceeds the allowed size."),
    "schema_version_unsupported": (422, "The schema version is not supported."),
    "invalid_record": (422, "The record does not match the sync contract."),
    "endpoint_rejected": (422, "The provider endpoint is not an allowed endpoint identity."),
    "rate_limited": (429, "Too many requests. Retry later."),
    "quota_exhausted": (429, "The sync quota is exhausted."),
    "temporarily_unavailable": (503, "The sync service is temporarily unavailable."),
    "reset_required": (409, "The sync state must be reset."),
}

ERROR_CODES = frozenset(_TABLE)
HTTP_STATUS = MappingProxyType({code: status for code, (status, _) in _TABLE.items()})
MESSAGES = MappingProxyType({code: message for code, (_, message) in _TABLE.items()})
_WIRE_KEYS = frozenset({"schemaVersion", "code", "message", "retryAfterSeconds"})


def _is_int(value) -> bool:
    return type(value) is int


class SyncError(Exception):
    """Typed sync failure. Only ``code`` and a bounded retry hint are accepted."""

    __slots__ = ("code", "retry_after_seconds")

    def __init__(self, code: str, retry_after_seconds: int | None = None):
        if type(code) is not str:
            raise TypeError("code must be a str")
        if code not in _TABLE:
            raise ValueError("unknown sync error code")
        if retry_after_seconds is not None:
            if not _is_int(retry_after_seconds):
                raise TypeError("retry_after_seconds must be an int or None")
            if not 0 <= retry_after_seconds <= MAX_RETRY_AFTER_SECONDS:
                raise ValueError("retry_after_seconds out of range")
        super().__init__(_TABLE[code][1])
        self.code = code
        self.retry_after_seconds = retry_after_seconds

    @property
    def status(self) -> int:
        return _TABLE[self.code][0]

    @property
    def message(self) -> str:
        return _TABLE[self.code][1]

    def __str__(self) -> str:
        return self.message

    def __repr__(self) -> str:
        return f"SyncError({self.code!r}, retry_after_seconds={self.retry_after_seconds!r})"

    def __eq__(self, other) -> bool:
        return (
            isinstance(other, SyncError)
            and other.code == self.code
            and other.retry_after_seconds == self.retry_after_seconds
        )

    def __hash__(self) -> int:
        return hash((self.code, self.retry_after_seconds))

    def to_wire(self) -> dict:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "code": self.code,
            "message": self.message,
            "retryAfterSeconds": self.retry_after_seconds,
        }


def parse_error(value: object) -> SyncError:
    """Strictly parse a received error body. Anything off-contract is invalid_request."""
    if type(value) is not dict or set(value) != _WIRE_KEYS:
        raise SyncError("invalid_request")
    version = value["schemaVersion"]
    if not _is_int(version):
        raise SyncError("invalid_request")
    if version != SCHEMA_VERSION:
        raise SyncError("schema_version_unsupported")
    code = value["code"]
    if type(code) is not str or code not in _TABLE or value["message"] != _TABLE[code][1]:
        raise SyncError("invalid_request")
    retry = value["retryAfterSeconds"]
    if retry is not None and (not _is_int(retry) or not 0 <= retry <= MAX_RETRY_AFTER_SECONDS):
        raise SyncError("invalid_request")
    return SyncError(code, retry)
