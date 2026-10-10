import unittest

from server.sync.dto import ReplayRecord, parse_upload
from server.sync.canonical import canonical_bytes
from server.sync.errors import SyncError
from server.sync.memory import (
    BatchResult,
    ChangePage,
    InMemorySyncRepository,
    StatePage,
)


TS = "2026-10-08T12:34:56Z"


def record(record_id="rec-1", device="dev-1", revision=1, text="hello"):
    return parse_upload({
        "schemaVersion": 1,
        "recordId": record_id,
        "sourceDeviceId": device,
        "recordType": "transcript",
        "conversationId": "conv-1",
        "createdAt": TS,
        "revision": revision,
        "payload": {
            "messageId": "msg-1",
            "parentMessageId": None,
            "kind": "user",
            "text": text,
            "providerMetadataRecordId": None,
            "requestPurpose": None,
            "displayTitle": None,
        },
    })


def tombstone(target="rec-1", device="dev-1", revision=2):
    return parse_upload({
        "schemaVersion": 1,
        "recordId": "tomb-" + target,
        "sourceDeviceId": device,
        "recordType": "tombstone",
        "conversationId": "conv-1",
        "createdAt": TS,
        "revision": revision,
        "payload": {
            "targetRecordId": target,
            "deletionRevision": revision,
            "deletedAt": TS,
            "reason": "user",
        },
    })


class MemoryRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.repo = InMemorySyncRepository()
        self.repo.register_device("acct-1", "dev-1")
        self.repo.register_device("acct-1", "dev-2")

    def test_first_batch_is_sequenced_and_idempotently_replayed(self):
        first = self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])
        again = self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])

        self.assertIsInstance(first, BatchResult)
        self.assertEqual(first, again)
        self.assertEqual(first.accepted, 1)
        self.assertEqual(first.duplicates, 0)
        self.assertEqual(first.results[0].record, ReplayRecord.from_upload(record(), "acct-1", 1))
        self.assertEqual(self.repo.bootstrap("acct-1", "dev-2").accepted_record_count, 1)

    def test_batch_idempotency_key_rejects_a_different_request_digest(self):
        self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])

        with self.assertRaises(SyncError) as caught:
            self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record(text="changed")])

        self.assertEqual(caught.exception.code, "integrity_conflict")

    def test_enrollment_replays_the_original_result_and_enforces_device_cap(self):
        repo = InMemorySyncRepository(max_devices=2)
        repo.register_device("acct-1", "dev-1")

        first = repo.enroll("acct-1", True, "phone", "enroll-1")
        replay = repo.enroll("acct-1", True, "phone", "enroll-1")
        self.assertEqual(first, replay)

        with self.assertRaises(SyncError) as caught:
            repo.enroll("acct-1", True, "tablet", "enroll-2")
        self.assertEqual(caught.exception.code, "quota_exhausted")

    def test_enrollment_idempotency_key_rejects_a_different_request_digest(self):
        self.repo.enroll("acct-1", True, "phone", "enroll-1")

        with self.assertRaises(SyncError) as caught:
            self.repo.enroll("acct-1", True, "tablet", "enroll-1")

        self.assertEqual(caught.exception.code, "integrity_conflict")

    def test_revoke_replays_the_original_result_and_rejects_digest_mismatch(self):
        first = self.repo.revoke("acct-1", "dev-1", "dev-2", "revoke-1", True)
        replay = self.repo.revoke("acct-1", "dev-1", "dev-2", "revoke-1", True)
        self.assertEqual(first, replay)

        with self.assertRaises(SyncError) as caught:
            self.repo.revoke("acct-1", "dev-1", "dev-1", "revoke-1", True)
        self.assertEqual(caught.exception.code, "integrity_conflict")

    def test_same_record_retry_without_batch_replay_is_duplicate(self):
        self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])
        result = self.repo.admit_batch("acct-1", "dev-2", "batch-2", [record()])
        self.assertEqual((result.accepted, result.duplicates), (0, 1))
        self.assertEqual(result.results[0].record.change_sequence, 1)

    def test_revision_and_integrity_conflicts_do_not_publish_changes(self):
        self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])
        stale = self.repo.admit_batch("acct-1", "dev-2", "batch-2", [record(revision=1)])
        self.assertEqual(stale.duplicates, 1)
        with self.assertRaises(SyncError) as caught:
            self.repo.admit_batch("acct-1", "dev-2", "batch-3", [record(revision=1, text="different")])
        self.assertEqual(caught.exception.code, "integrity_conflict")
        self.assertEqual(self.repo.changes("acct-1", "dev-2").records[0].change_sequence, 1)

    def test_higher_revision_updates_and_allocates_new_sequence(self):
        self.repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])
        result = self.repo.admit_batch("acct-1", "dev-2", "batch-2", [record(revision=2, text="updated")])
        self.assertEqual(result.accepted, 1)
        page = self.repo.changes("acct-1", "dev-1")
        self.assertEqual([item.change_sequence for item in page.records], [1, 2])
        self.assertEqual(page.records[-1].payload.text, "updated")

    def test_cursor_is_account_bound_and_pages_are_deterministic(self):
        self.repo.admit_batch("acct-1", "dev-1", "a", [record("a")])
        self.repo.admit_batch("acct-1", "dev-1", "b", [record("b")])
        first = self.repo.changes("acct-1", "dev-2", limit=1)
        second = self.repo.changes("acct-1", "dev-2", cursor=first.next_cursor, limit=1)
        self.assertEqual([r.record_id for r in first.records], ["a"])
        self.assertEqual([r.record_id for r in second.records], ["b"])
        self.repo.register_device("other", "dev-2")
        with self.assertRaises(SyncError) as caught:
            self.repo.changes("other", "dev-2", cursor=first.next_cursor)
        self.assertEqual(caught.exception.code, "reset_required")

    def test_cursor_is_device_bound_and_expires(self):
        repo = InMemorySyncRepository(now=lambda: 100, cursor_secret=b"a" * 16)
        repo.register_device("acct-1", "dev-1")
        repo.admit_batch("acct-1", "dev-1", "batch-1", [record()])
        page = repo.changes("acct-1", "dev-1")

        repo.now = lambda: 100 + 30 * 24 * 60 * 60
        with self.assertRaises(SyncError) as caught:
            repo.changes("acct-1", "dev-1", cursor=page.next_cursor)
        self.assertEqual(caught.exception.code, "reset_required")

    def test_byte_limit_never_splits_a_record(self):
        self.repo.admit_batch("acct-1", "dev-1", "a", [record()])
        size = len(canonical_bytes(self.repo.changes("acct-1", "dev-2").records[0].to_wire()))
        with self.assertRaises(SyncError) as caught:
            self.repo.changes("acct-1", "dev-2", max_bytes=size - 1)
        self.assertEqual(caught.exception.code, "payload_too_large")

    def test_device_and_account_fences_apply_to_all_operations(self):
        self.repo.revoke_device("acct-1", "dev-1")
        for operation in (
            lambda: self.repo.admit_batch("acct-1", "dev-1", "x", [record()]),
            lambda: self.repo.changes("acct-1", "dev-1"),
            lambda: self.repo.bootstrap("acct-1", "dev-1"),
        ):
            with self.subTest(operation=operation):
                with self.assertRaises(SyncError) as caught:
                    operation()
                self.assertEqual(caught.exception.code, "device_revoked")
        self.repo.delete_account("acct-1")
        with self.assertRaises(SyncError) as caught:
            self.repo.changes("acct-1", "dev-2")
        self.assertEqual(caught.exception.code, "account_fenced")

    def test_tombstone_wins_against_late_upload_and_is_admitted_at_quota(self):
        repo = InMemorySyncRepository(max_retained_bytes=1)
        repo.register_device("acct-1", "dev-1")
        repo.admit_batch("acct-1", "dev-1", "delete", [tombstone()])
        result = repo.admit_batch("acct-1", "dev-1", "late", [record()])
        self.assertEqual(result.duplicates, 1)
        self.assertEqual(repo.bootstrap("acct-1", "dev-1").accepted_record_count, 1)

    def test_quota_failure_is_atomic_and_does_not_consume_idempotency_or_sequence(self):
        repo = InMemorySyncRepository(max_records=0)
        repo.register_device("acct-1", "dev-1")
        with self.assertRaises(SyncError) as caught:
            repo.admit_batch("acct-1", "dev-1", "batch", [record()])
        self.assertEqual(caught.exception.code, "quota_exhausted")
        repo.max_records = 1
        result = repo.admit_batch("acct-1", "dev-1", "batch", [record()])
        self.assertEqual(result.results[0].record.change_sequence, 1)

    def test_result_types_are_typed(self):
        self.assertIsInstance(self.repo.changes("acct-1", "dev-1"), ChangePage)
        self.assertIsInstance(self.repo.bootstrap("acct-1", "dev-1"), StatePage)

    def test_empty_cursor_does_not_skip_first_later_record(self):
        page = self.repo.changes("acct-1", "dev-1")
        self.assertEqual(page.next_cursor, "")
        self.repo.admit_batch("acct-1", "dev-1", "batch", [record()])
        later = self.repo.changes("acct-1", "dev-1", page.next_cursor)
        self.assertEqual([r.change_sequence for r in later.records], [1])
        self.assertNotEqual(later.next_cursor, "")

    def test_bad_cursor_requires_reset_even_for_empty_account(self):
        with self.assertRaises(SyncError) as caught:
            self.repo.changes("acct-1", "dev-1", "dummy")
        self.assertEqual(caught.exception.code, "reset_required")

    def test_duplicate_in_one_batch_allocates_only_one_sequence(self):
        result = self.repo.admit_batch("acct-1", "dev-1", "batch", [record(), record()])
        self.assertEqual((result.accepted, result.duplicates), (1, 1))
        self.assertEqual(len(self.repo.changes("acct-1", "dev-1").records), 1)

    def test_self_revocation_retry_replays_but_other_operations_stay_revoked(self):
        result = self.repo.revoke("acct-1", "dev-1", "dev-1", "self", True)
        self.assertEqual(self.repo.revoke("acct-1", "dev-1", "dev-1", "self", True), result)
        with self.assertRaises(SyncError) as caught:
            self.repo.changes("acct-1", "dev-1")
        self.assertEqual(caught.exception.code, "device_revoked")


if __name__ == "__main__":
    unittest.main()
