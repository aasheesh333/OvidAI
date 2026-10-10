"""Contract tests for the dependency-free private-sync repository boundary."""

from __future__ import annotations

import dataclasses
import inspect
import unittest
from typing import get_type_hints

from server.sync.dto import UploadRecord
from server.sync.repository import (
    PRODUCTION_POSTGRES_AVAILABLE,
    PostgresSyncRepository,
    SyncRepository,
)
from server.sync.results import (
    BatchResult,
    ChangePage,
    DeviceEnrollment,
    StatePage,
)


class FakeRepository:
    """A deliberately persistence-free implementation used by these tests."""

    durability = "durable"
    authority = "server"

    def __init__(self) -> None:
        self.deleted: list[str] = []

    def admit_batch(
        self,
        account_id: str,
        device_id: str,
        idempotency_key: str,
        records: tuple[UploadRecord, ...],
    ) -> BatchResult:
        return BatchResult(results=())

    def changes(
        self,
        account_id: str,
        device_id: str,
        cursor: str | None = None,
        *,
        limit: int = 100,
        max_bytes: int = 262144,
    ) -> ChangePage:
        return ChangePage(records=(), next_cursor=cursor or "", has_more=False)

    def delete_account(self, account_id: str) -> None:
        self.deleted.append(account_id)

    def bootstrap(self, account_id, device_id, cursor=None) -> StatePage:
        return StatePage(account_id, cursor or "", (), "active", ())

    def enroll(self, account_id, consent, device_name, idempotency_key) -> DeviceEnrollment:
        return DeviceEnrollment("device-1", device_name, "2026-01-01T00:00:00Z", "active")

    def revoke(self, account_id, requester_device_id, target_device_id,
               idempotency_key, fresh_auth=False) -> DeviceEnrollment:
        return DeviceEnrollment(target_device_id, "", "2026-01-01T00:00:00Z", "revoked")


class ResultObjectTests(unittest.TestCase):
    def test_batch_result_is_immutable_and_typed(self) -> None:
        result = BatchResult(results=())

        self.assertTrue(dataclasses.is_dataclass(result))
        self.assertTrue(getattr(type(result), "__dataclass_params__").frozen)
        self.assertEqual(result.results, ())
        with self.assertRaises(dataclasses.FrozenInstanceError):
            result.results = ()  # type: ignore[misc]

    def test_change_page_is_immutable_and_typed(self) -> None:
        page = ChangePage(records=(), next_cursor="cursor-1", has_more=False)

        self.assertTrue(dataclasses.is_dataclass(page))
        self.assertTrue(getattr(type(page), "__dataclass_params__").frozen)
        self.assertEqual(page.next_cursor, "cursor-1")
        self.assertFalse(page.has_more)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            page.has_more = True  # type: ignore[misc]


class RepositoryProtocolTests(unittest.TestCase):
    def test_production_postgres_requires_explicit_authority(self):
        self.assertTrue(PRODUCTION_POSTGRES_AVAILABLE)
        with self.assertRaises(ValueError):
            PostgresSyncRepository()

    def test_production_authority_is_stable_and_does_not_expose_dsn(self):
        dsn = "postgresql://user:private-password@localhost/test"
        first = PostgresSyncRepository(dsn=dsn, schema="sync_test")
        second = PostgresSyncRepository(dsn=dsn, schema="sync_test")
        self.assertIsInstance(first, SyncRepository)
        self.assertEqual(first.authority_identity, second.authority_identity)
        self.assertNotIn("private-password", first.authority_identity)
        self.assertNotEqual(first.authority_identity,
                            PostgresSyncRepository(dsn=dsn, schema="other").authority_identity)

    def test_protocol_is_runtime_checkable_without_a_framework(self) -> None:
        self.assertIsInstance(FakeRepository(), SyncRepository)

    def test_protocol_exposes_durable_server_authority_metadata(self) -> None:
        self.assertEqual(SyncRepository.durability, "durable")
        self.assertEqual(SyncRepository.authority, "server")

    def test_protocol_methods_expose_typed_operations(self) -> None:
        self.assertIs(get_type_hints(SyncRepository.admit_batch)["return"], BatchResult)
        self.assertIs(get_type_hints(SyncRepository.changes)["return"], ChangePage)
        self.assertIs(get_type_hints(SyncRepository.bootstrap)["return"], StatePage)
        self.assertIs(get_type_hints(SyncRepository.enroll)["return"], DeviceEnrollment)
        self.assertIs(get_type_hints(SyncRepository.revoke)["return"], DeviceEnrollment)
        self.assertIs(get_type_hints(SyncRepository.delete_account)["return"], type(None))

        append = inspect.signature(SyncRepository.admit_batch)
        self.assertEqual(
            tuple(append.parameters),
            ("self", "account_id", "device_id", "idempotency_key", "records"),
        )
        self.assertEqual(get_type_hints(SyncRepository.admit_batch)["records"], tuple[UploadRecord, ...])

        replay = inspect.signature(SyncRepository.changes)
        self.assertEqual(
            tuple(replay.parameters),
            ("self", "account_id", "device_id", "cursor", "limit", "max_bytes"),
        )
        self.assertEqual(get_type_hints(SyncRepository.changes)["cursor"], str | None)
        self.assertEqual(replay.parameters["limit"].default, 100)
        self.assertEqual(replay.parameters["max_bytes"].default, 262144)

    def test_fake_can_return_contract_objects_and_delete_account(self) -> None:
        repository: SyncRepository = FakeRepository()

        batch = repository.admit_batch("account-1", "device-1", "key", ())
        page = repository.changes("account-1", "device-1")
        repository.delete_account("account-1")

        self.assertEqual(batch, BatchResult(results=()))
        self.assertEqual(page, ChangePage(records=(), next_cursor="", has_more=False))
        self.assertEqual(repository.deleted, ["account-1"])  # type: ignore[attr-defined]


if __name__ == "__main__":
    unittest.main()
