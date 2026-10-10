"""Pure record projection and deterministic sync admission rules."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from server.sync.dto import (
    ActivityPayload,
    ProviderMetadataPayload,
    ReplayRecord,
    UploadRecord,
    TombstonePayload,
    TranscriptPayload,
    UsagePayload,
)


class Admission(str, Enum):
    ADMIT = "admit"
    DUPLICATE = "duplicate"
    STALE = "stale"
    CONFLICT = "conflict"
    HIGHER_REVISION = "higher_revision"


@dataclass(frozen=True)
class Projection:
    record_id: str
    record_type: str
    revision: int
    immutable: tuple[Any, ...]
    mutable: tuple[Any, ...]


def project_record(record: ReplayRecord | UploadRecord) -> Projection:
    """Return the immutable comparison view used by admission decisions."""
    payload = record.payload
    if isinstance(payload, TranscriptPayload):
        immutable = (payload.message_id, payload.parent_message_id, payload.kind, payload.text)
        mutable = (payload.provider_metadata_record_id, payload.request_purpose, payload.display_title)
    elif isinstance(payload, ProviderMetadataPayload):
        immutable = (payload.provider_id, payload.model_id, payload.endpoint)
        mutable = (payload.request_purpose, payload.display_name, payload.supports_streaming)
    elif isinstance(payload, UsagePayload):
        immutable = (payload.logical_request_id, payload.attempt_id, payload.requested_model)
        mutable = (
            payload.reported_model, payload.outcome, payload.input_tokens,
            payload.output_tokens, payload.total_tokens, payload.usage_provenance,
            payload.started_at, payload.completed_at, payload.elapsed_milliseconds,
        )
    elif isinstance(payload, ActivityPayload):
        immutable = (payload.logical_request_id, payload.attempt_id, payload.kind)
        mutable = (payload.status, payload.updated_at, payload.title, payload.detail, payload.usage_record_id)
    elif isinstance(payload, TombstonePayload):
        immutable = (payload.target_record_id,)
        mutable = (payload.deletion_revision, payload.deleted_at, payload.reason)
    else:  # pragma: no cover - DTO types are closed by parse_replay.
        raise TypeError("unsupported replay record payload")
    return Projection(record.record_id, record.record_type, record.revision, immutable, mutable)


def classify_admission(
    incoming: ReplayRecord | UploadRecord,
    current: ReplayRecord | UploadRecord | None = None,
    *,
    tombstone: ReplayRecord | UploadRecord | None = None,
) -> Admission:
    """Classify an incoming record without modifying either input record.

    A tombstone suppresses its target through its deletion revision. A record
    beyond that barrier is admitted and can represent a deliberate recreation.
    """
    incoming_view = project_record(incoming)
    if tombstone is not None:
        tombstone_payload = tombstone.payload
        if not isinstance(tombstone_payload, TombstonePayload):
            raise TypeError("tombstone must contain TombstonePayload")
        if incoming.record_id == tombstone_payload.target_record_id:
            if incoming.revision <= tombstone_payload.deletion_revision:
                return Admission.STALE

    if current is None:
        return Admission.ADMIT
    current_view = project_record(current)
    if incoming.record_id != current.record_id:
        return Admission.ADMIT
    if incoming.record_type != current.record_type:
        return Admission.CONFLICT
    if incoming.revision < current.revision:
        return Admission.STALE
    if incoming_view.immutable != current_view.immutable:
        return Admission.CONFLICT
    if incoming.revision == current.revision:
        return Admission.DUPLICATE
    return Admission.HIGHER_REVISION
