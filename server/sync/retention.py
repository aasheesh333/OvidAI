"""Pure retention and compaction decisions for private sync.

This module deliberately contains no persistence or clock access.  Callers
provide the cursor, record, and activity projections together with ``now`` and
apply the returned decisions transactionally with their database writes.
"""

from __future__ import annotations

from dataclasses import dataclass


TOMBSTONE_RETENTION_SECONDS = 30 * 24 * 60 * 60
ACTIVITY_COMPACTION_AGE_SECONDS = TOMBSTONE_RETENTION_SECONDS


def _integer(value: object, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ValueError("expected integer in range")
    return value


def _number(value: object, *, minimum: float = 0) -> float:
    if type(value) not in (int, float) or value < minimum:
        raise ValueError("expected non-negative number")
    return value


def _text(value: object, *, allow_none: bool = False) -> str | None:
    if allow_none and value is None:
        return None
    if type(value) is not str or not value:
        raise ValueError("expected non-empty text")
    return value


@dataclass(frozen=True)
class Cursor:
    """A cursor position and its lease expiry, projected from ``sync_cursors``."""

    position: int
    expires_at: float

    def __post_init__(self) -> None:
        _integer(self.position)
        _number(self.expires_at)


@dataclass(frozen=True)
class Tombstone:
    """A replayable record tombstone projected from ``sync_records``."""

    record_id: str
    change_sequence: int
    deleted_at: float

    def __post_init__(self) -> None:
        _text(self.record_id)
        _integer(self.change_sequence, minimum=1)
        _number(self.deleted_at)


@dataclass(frozen=True)
class Activity:
    """An activity revision eligible for logical-request compaction."""

    record_id: str
    logical_request_id: str | None
    change_sequence: int
    updated_at: float
    canonical_length: int
    tombstoned: bool

    def __post_init__(self) -> None:
        _text(self.record_id)
        _text(self.logical_request_id, allow_none=True)
        _integer(self.change_sequence, minimum=1)
        _number(self.updated_at)
        _integer(self.canonical_length, minimum=1)
        if type(self.tombstoned) is not bool:
            raise ValueError("tombstoned must be boolean")


@dataclass(frozen=True)
class CompactionDecision:
    logical_request_id: str
    record_ids: tuple[str, ...]
    through_change_sequence: int
    freed_bytes: int
    freed_records: int


@dataclass(frozen=True)
class MarkerDecision:
    """The replay-log fields for one ``sync_retention_markers`` row."""

    marker_kind: str
    change_sequence: int
    through_change_sequence: int
    logical_request_id: str | None
    freed_bytes: int
    freed_records: int


def tombstone_horizon(
    tombstone_change_sequence: int,
    cursors: tuple[Cursor, ...] | list[Cursor],
    *,
    deletion_time: float | None = None,
    retention_seconds: int = TOMBSTONE_RETENTION_SECONDS,
) -> float:
    """Return when a tombstone may be purged.

    The latest expiry among cursors positioned before the tombstone protects
    it.  If no such cursor exists, the deletion time is the conservative
    starting point.  ``position`` is a cursor position, so equality does not
    protect the tombstone.
    """

    _integer(tombstone_change_sequence, minimum=1)
    _integer(retention_seconds, minimum=0)
    if deletion_time is not None:
        _number(deletion_time)
    for cursor in cursors:
        if not isinstance(cursor, Cursor):
            raise ValueError("cursors must contain Cursor values")
    preceding_expiries = [
        cursor.expires_at
        for cursor in cursors
        if cursor.position < tombstone_change_sequence
    ]
    bases = preceding_expiries
    if deletion_time is not None:
        bases.append(deletion_time)
    base = max(bases, default=None)
    if base is None:
        raise ValueError("deletion_time is required when no preceding cursor exists")
    return base + retention_seconds


def tombstones_to_purge(
    tombstones: tuple[Tombstone, ...] | list[Tombstone],
    cursors: tuple[Cursor, ...] | list[Cursor],
    *,
    now: float,
    retention_seconds: int = TOMBSTONE_RETENTION_SECONDS,
) -> tuple[str, ...]:
    """Return purgeable tombstone IDs in stable record-ID order."""

    _number(now)
    for tombstone in tombstones:
        if not isinstance(tombstone, Tombstone):
            raise ValueError("tombstones must contain Tombstone values")
    result = []
    for tombstone in tombstones:
        horizon = tombstone_horizon(
            tombstone.change_sequence,
            cursors,
            deletion_time=tombstone.deleted_at,
            retention_seconds=retention_seconds,
        )
        if now >= horizon:
            result.append(tombstone.record_id)
    return tuple(sorted(result))


def activity_compaction(
    activities: tuple[Activity, ...] | list[Activity],
    *,
    now: float,
    age_seconds: int = ACTIVITY_COMPACTION_AGE_SECONDS,
) -> tuple[CompactionDecision, ...]:
    """Group old, live activity detail into one inert summary per request."""

    _number(now)
    _integer(age_seconds, minimum=1)
    for activity in activities:
        if not isinstance(activity, Activity):
            raise ValueError("activities must contain Activity values")
    groups: dict[str, list[Activity]] = {}
    for activity in activities:
        if activity.tombstoned or activity.logical_request_id is None:
            continue
        if now - activity.updated_at < age_seconds:
            continue
        groups.setdefault(activity.logical_request_id, []).append(activity)

    decisions = []
    for request_id, group in groups.items():
        ordered = sorted(group, key=lambda item: (item.change_sequence, item.record_id))
        decisions.append(
            CompactionDecision(
                logical_request_id=request_id,
                record_ids=tuple(item.record_id for item in ordered),
                through_change_sequence=max(item.change_sequence for item in ordered),
                freed_bytes=sum(item.canonical_length for item in ordered),
                freed_records=len(ordered),
            )
        )
    return tuple(sorted(decisions, key=lambda item: item.logical_request_id))


def marker_for_compaction(
    logical_request_id: str,
    through_change_sequence: int,
    marker_change_sequence: int,
    freed_bytes: int,
    freed_records: int,
) -> MarkerDecision:
    """Build the replay-visible marker decision for an activity summary."""

    _text(logical_request_id)
    _integer(through_change_sequence, minimum=0)
    _integer(marker_change_sequence, minimum=1)
    if through_change_sequence >= marker_change_sequence:
        raise ValueError("marker must follow the summarized changes")
    _integer(freed_bytes)
    _integer(freed_records)
    return MarkerDecision(
        marker_kind="activity_compaction",
        change_sequence=marker_change_sequence,
        through_change_sequence=through_change_sequence,
        logical_request_id=logical_request_id,
        freed_bytes=freed_bytes,
        freed_records=freed_records,
    )
