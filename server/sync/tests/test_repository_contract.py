"""Contract tests for the dependency-free private-sync repository boundary."""

from __future__ import annotations

import dataclasses
import inspect
import types
import unittest
from typing import Any, get_type_hints

from server.sync.dto import ReplayRecord, UploadRecord
from server.sync.repository import (
    BatchResult,
    PRODUCTION_POSTGRES_AVAILABLE,
    PostgresSyncRepository,
    ReplayPage,
    SyncRepository,
)


class FakeRepository:
    """A deliberately persistence-free implementation used by these tests."""

    def __init__(self) -> None:
        self.deleted: list[str] = []

    def admit_batch(
        self,
        account_id: str,
        device_id: str,
        idempotency_key: str,
        records: tuple[UploadRecord, ...],
    ) -> BatchResult:
        return BatchResult(accepted=(), duplicates=())

    def changes(
        self,
        account_id: str,
        device_id: str,
        cursor: str | None = None,
        *,
        limit: int = 100,
        max_bytes: int = 262144,
    ) -> ReplayPage:
        return ReplayPage(records=(), next_cursor=cursor, has_more=False)

    def delete_account(self, account_id: str) -> None:
        self.deleted.append(account_id)

    def bootstrap(self, account_id, device_id, cursor=None):
        return None

    def enroll(self, account_id, consent, device_name, idempotency_key):
        return None

    def revoke(self, account_id, requester_device_id, target_device_id,
               idempotency_key, fresh_auth=False):
        return None


class ResultObjectTests(unittest.TestCase):
    def test_batch_result_is_immutable_and_typed(self) -> None:
        result = BatchResult(accepted=(), duplicates=())

        self.assertTrue(dataclasses.is_dataclass(result))
        self.assertTrue(getattr(type(result), "__dataclass_params__").frozen)
        self.assertEqual(result.accepted, ())
        self.assertEqual(result.duplicates, ())
        with self.assertRaises(dataclasses.FrozenInstanceError):
            result.accepted = ()  # type: ignore[misc]

    def test_replay_page_is_immutable_and_typed(self) -> None:
        page = ReplayPage(records=(), next_cursor="cursor-1", has_more=False)

        self.assertTrue(dataclasses.is_dataclass(page))
        self.assertTrue(getattr(type(page), "__dataclass_params__").frozen)
        self.assertEqual(page.next_cursor, "cursor-1")
        self.assertFalse(page.has_more)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            page.has_more = True  # type: ignore[misc]


class RepositoryProtocolTests(unittest.TestCase):
    def test_production_postgres_is_explicitly_unavailable(self):
        self.assertFalse(PRODUCTION_POSTGRES_AVAILABLE)
        with self.assertRaisesRegex(RuntimeError, "PostgreSQL sync repository is unavailable"):
            PostgresSyncRepository()

    def test_protocol_is_runtime_checkable_without_a_framework(self) -> None:
        self.assertIsInstance(FakeRepository(), SyncRepository)

    def test_protocol_methods_expose_typed_operations(self) -> None:
        self.assertIs(get_type_hints(SyncRepository.admit_batch)["return"], Any)
        self.assertIs(get_type_hints(SyncRepository.changes)["return"], Any)
        self.assertIs(get_type_hints(SyncRepository.delete_account)["return"], types.NoneType)

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

        self.assertEqual(batch, BatchResult(accepted=(), duplicates=()))
        self.assertEqual(page, ReplayPage(records=(), next_cursor=None, has_more=False))
        self.assertEqual(repository.deleted, ["account-1"])  # type: ignore[attr-defined]


if __name__ == "__main__":
    unittest.main()
