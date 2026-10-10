"""Pure private-sync policy tests."""

import unittest
from datetime import datetime, timedelta, timezone

from server.sync.policy import (
    ACCOUNT_INGEST_RECORDS,
    ACCOUNT_REPLAY_REQUESTS_PER_MINUTE,
    ACCOUNT_STREAMS,
    ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE,
    BATCH_CANONICAL_BYTES,
    BATCH_RECORDS,
    COMPRESSED_BODY_BYTES,
    DEVICE_STREAMS,
    DEVICE_UPLOAD_REQUESTS_PER_MINUTE,
    ENROLLED_DEVICES,
    RECORD_CANONICAL_BYTES,
    RETAINED_CANONICAL_BYTES,
    classify_revision,
    device_can_enroll,
    quota_allows,
    rate_limit_allows,
    stream_capacity_available,
)


class QuotaPolicyTests(unittest.TestCase):
    def test_quota_allows_each_spec_limit_but_not_limit_plus_one(self):
        self.assertTrue(quota_allows(1 * 1024 * 1024, COMPRESSED_BODY_BYTES))
        self.assertFalse(quota_allows(1 * 1024 * 1024 + 1, COMPRESSED_BODY_BYTES))
        self.assertTrue(quota_allows(8 * 1024 * 1024, BATCH_CANONICAL_BYTES))
        self.assertFalse(quota_allows(8 * 1024 * 1024 + 1, BATCH_CANONICAL_BYTES))
        self.assertTrue(quota_allows(100, BATCH_RECORDS))
        self.assertFalse(quota_allows(101, BATCH_RECORDS))
        self.assertTrue(quota_allows(256 * 1024, RECORD_CANONICAL_BYTES))
        self.assertFalse(quota_allows(256 * 1024 + 1, RECORD_CANONICAL_BYTES))
        self.assertTrue(quota_allows(10000, ACCOUNT_INGEST_RECORDS))
        self.assertFalse(quota_allows(10001, ACCOUNT_INGEST_RECORDS))
        self.assertTrue(quota_allows(100 * 1024 * 1024, RETAINED_CANONICAL_BYTES))
        self.assertFalse(quota_allows(100 * 1024 * 1024 + 1, RETAINED_CANONICAL_BYTES))


class RatePolicyTests(unittest.TestCase):
    def test_rate_limit_allows_limit_requests_and_rejects_the_next(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        timestamps = [now - timedelta(seconds=10)] * (ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE - 1)
        self.assertTrue(rate_limit_allows(timestamps, now, ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE))
        self.assertFalse(
            rate_limit_allows(
                timestamps + [now - timedelta(seconds=9)],
                now,
                ACCOUNT_UPLOAD_REQUESTS_PER_MINUTE,
            )
        )

    def test_rate_limit_expires_requests_at_the_window_boundary(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        expired = [now - timedelta(minutes=1)] * ACCOUNT_REPLAY_REQUESTS_PER_MINUTE
        self.assertTrue(rate_limit_allows(expired, now, ACCOUNT_REPLAY_REQUESTS_PER_MINUTE))

    def test_device_upload_rate_uses_the_spec_limit(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        timestamps = [now - timedelta(seconds=1)] * DEVICE_UPLOAD_REQUESTS_PER_MINUTE
        self.assertFalse(rate_limit_allows(timestamps, now, DEVICE_UPLOAD_REQUESTS_PER_MINUTE))


class DevicePolicyTests(unittest.TestCase):
    def test_enrollment_allows_up_to_ten_devices(self):
        self.assertTrue(device_can_enroll(ENROLLED_DEVICES - 1))
        self.assertFalse(device_can_enroll(ENROLLED_DEVICES))

    def test_stream_capacity_is_scoped_to_account_or_device(self):
        self.assertTrue(stream_capacity_available(ACCOUNT_STREAMS - 1, "account"))
        self.assertFalse(stream_capacity_available(ACCOUNT_STREAMS, "account"))
        self.assertTrue(stream_capacity_available(DEVICE_STREAMS - 1, "device"))
        self.assertFalse(stream_capacity_available(DEVICE_STREAMS, "device"))


class RevisionPolicyTests(unittest.TestCase):
    def test_lower_revision_is_stale(self):
        self.assertEqual(classify_revision(2, "new", 3, "old"), "stale")

    def test_equal_revision_with_same_content_is_duplicate(self):
        self.assertEqual(classify_revision(3, {"text": "same"}, 3, {"text": "same"}), "duplicate")

    def test_equal_revision_with_different_content_is_conflict(self):
        self.assertEqual(classify_revision(3, {"text": "local"}, 3, {"text": "server"}), "conflict")

    def test_higher_revision_is_update(self):
        self.assertEqual(classify_revision(4, "new", 3, "old"), "update")


if __name__ == "__main__":
    unittest.main()
