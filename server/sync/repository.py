"""Typed, persistence-agnostic contract for private-sync repositories.

This module defines the boundary used by sync application code. Concrete
repositories satisfy :class:`SyncRepository` through structural typing. The
PostgreSQL implementation is exported here without importing its driver until
an operation opens a connection.
"""

from __future__ import annotations

from typing import ClassVar, Protocol, runtime_checkable

from server.sync.dto import UploadRecord
from server.sync.results import (
    BatchResult,
    ChangePage,
    DeviceEnrollment,
    StatePage,
)


from server.sync.postgres import PostgresSyncRepository


PRODUCTION_POSTGRES_AVAILABLE = True


@runtime_checkable
class SyncRepository(Protocol):
    """Durable server authority required by the sync service.

    Implementations own the durable sync state and are the server authority for
    account-scoped replay, enrollment, and revocation decisions.  The protocol
    metadata makes that boundary explicit without providing a storage fallback.
    """

    durability: ClassVar[str] = "durable"
    authority: ClassVar[str] = "server"

    def admit_batch(
        self,
        account_id: str,
        device_id: str,
        idempotency_key: str,
        records: tuple[UploadRecord, ...],
    ) -> BatchResult:
        """Admit one idempotent upload batch."""

    def changes(
        self,
        account_id: str,
        device_id: str,
        cursor: str | None = None,
        *,
        limit: int = 100,
        max_bytes: int = 262144,
    ) -> ChangePage:
        """Return records after ``cursor`` for one authorized device."""

    def bootstrap(
        self, account_id: str, device_id: str, cursor: str | None = None
    ) -> StatePage:
        """Return the bounded state bootstrap for one authorized device."""

    def enroll(self, account_id: str, consent: bool, device_name: str,
               idempotency_key: str) -> DeviceEnrollment:
        """Enroll a device with explicit consent."""

    def revoke(self, account_id: str, requester_device_id: str,
               target_device_id: str, idempotency_key: str,
               fresh_auth: bool = False) -> DeviceEnrollment:
        """Revoke a device after fresh authentication."""

    def delete_account(self, account_id: str) -> None:
        """Delete all sync data belonging to an account."""
