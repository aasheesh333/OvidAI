"""Typed, persistence-agnostic contract for private-sync repositories.

This module defines the boundary used by sync application code.  It contains
no storage, transport, framework, or database implementation; concrete
repositories may satisfy :class:`SyncRepository` through structural typing.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol, runtime_checkable

from server.sync.dto import ReplayRecord, UploadRecord


PRODUCTION_POSTGRES_AVAILABLE = False


class PostgresSyncRepository:
    """Reserved production boundary; PostgreSQL wiring is not shipped yet."""

    def __init__(self, *args, **kwargs):
        raise RuntimeError(
            "PostgreSQL sync repository is unavailable; configure a production "
            "Postgres implementation explicitly"
        )


@dataclass(frozen=True)
class BatchResult:
    """Outcome of appending one account-scoped upload batch.

    ``accepted`` contains records newly committed by the repository.  A record
    in ``duplicates`` was already committed with the same canonical identity
    and is returned as the existing server record for idempotent retry handling.
    """

    accepted: tuple[ReplayRecord, ...]
    duplicates: tuple[ReplayRecord, ...]


@dataclass(frozen=True)
class ReplayPage:
    """A bounded, ordered page of records following a replay cursor."""

    records: tuple[ReplayRecord, ...]
    next_cursor: str | None
    has_more: bool


@runtime_checkable
class SyncRepository(Protocol):
    """Account-scoped operations required by the sync service."""

    def admit_batch(
        self,
        account_id: str,
        device_id: str,
        idempotency_key: str,
        records: tuple[UploadRecord, ...],
    ) -> Any:
        """Admit one idempotent upload batch."""

    def changes(
        self,
        account_id: str,
        device_id: str,
        cursor: str | None = None,
        *,
        limit: int = 100,
        max_bytes: int = 262144,
    ) -> Any:
        """Return records after ``cursor`` for one authorized device."""

    def bootstrap(self, account_id: str, device_id: str, cursor: str | None = None) -> Any:
        """Return the bounded state bootstrap for one authorized device."""

    def enroll(self, account_id: str, consent: bool, device_name: str,
               idempotency_key: str) -> Any:
        """Enroll a device with explicit consent."""

    def revoke(self, account_id: str, requester_device_id: str,
               target_device_id: str, idempotency_key: str,
               fresh_auth: bool = False) -> Any:
        """Revoke a device after fresh authentication."""

    def delete_account(self, account_id: str) -> None:
        """Delete all sync data belonging to an account."""
