"""Pure private-sync quota, rate, device, and revision policies."""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Literal

COMPRESSED_BODY_BYTES = 1 * 1024 * 1024
BATCH_CANONICAL_BYTES = 8 * 1024 * 1024
BATCH_RECORDS = 100
RECORD_CANONICAL_BYTES = 256 * 1024
ACCOUNT_INGEST_RECORDS = 10_000
RETAINED_CANONICAL_BYTES = 100 * 1024 * 1024

ENROLLED_DEVICES = 10
ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE = 60
ACCOUNT_REPLAY_REQUESTS_PER_MINUTE = 120
DEVICE_UPLOAD_REQUESTS_PER_MINUTE = 30
ACCOUNT_STREAMS = 2
DEVICE_STREAMS = 1

RATE_WINDOW = timedelta(minutes=1)

RevisionResult = Literal["stale", "duplicate", "update", "conflict"]


def quota_allows(used: int, limit: int) -> bool:
    """Return whether a non-negative usage value is within an inclusive limit."""
    return used <= limit


def rate_limit_allows(
    request_times: list[datetime],
    now: datetime,
    limit: int,
    *,
    window: timedelta = RATE_WINDOW,
) -> bool:
    """Return whether one request may be admitted in the rolling window."""
    window_start = now - window
    active = sum(window_start < request_time <= now for request_time in request_times)
    return active < limit


def device_can_enroll(enrolled_devices: int) -> bool:
    """Return whether another device fits under the account enrollment cap."""
    return enrolled_devices < ENROLLED_DEVICES


def stream_capacity_available(active_streams: int, scope: Literal["account", "device"]) -> bool:
    """Return whether another stream fits for an account or device."""
    limit = ACCOUNT_STREAMS if scope == "account" else DEVICE_STREAMS
    return active_streams < limit


def classify_revision(
    incoming_revision: int,
    incoming_content: object,
    stored_revision: int,
    stored_content: object,
) -> RevisionResult:
    """Classify an upload against the canonical record already stored."""
    if incoming_revision < stored_revision:
        return "stale"
    if incoming_revision > stored_revision:
        return "update"
    return "duplicate" if incoming_content == stored_content else "conflict"
