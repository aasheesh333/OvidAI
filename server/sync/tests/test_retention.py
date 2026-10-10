"""Pure cursor-aware retention and compaction decisions."""

import unittest

from server.sync.retention import (
    Activity,
    Cursor,
    MarkerDecision,
    Tombstone,
    activity_compaction,
    marker_for_compaction,
    tombstone_horizon,
    tombstones_to_purge,
)


DAY = 24 * 60 * 60


class CursorHorizonTests(unittest.TestCase):
    def test_horizon_uses_latest_expiry_of_cursors_before_tombstone(self):
        cursors = [
            Cursor(position=4, expires_at=100),
            Cursor(position=9, expires_at=300),
            Cursor(position=10, expires_at=900),
        ]
        self.assertEqual(tombstone_horizon(10, cursors, retention_seconds=30 * DAY), 300 + 30 * DAY)

    def test_horizon_falls_back_to_deletion_time_without_referencing_cursor(self):
        self.assertEqual(
            tombstone_horizon(10, [Cursor(position=10, expires_at=300)], deletion_time=50),
            50 + 30 * DAY,
        )

    def test_invalid_cursor_position_and_expiry_are_rejected(self):
        with self.assertRaises(ValueError):
            tombstone_horizon(0, [], deletion_time=0)
        with self.assertRaises(ValueError):
            tombstone_horizon(2, [Cursor(position=-1, expires_at=1)], deletion_time=0)


class TombstoneRetentionTests(unittest.TestCase):
    def test_only_tombstones_past_cursor_aware_horizon_are_purgeable(self):
        tombstones = [
            Tombstone(record_id="old", change_sequence=4, deleted_at=0),
            Tombstone(record_id="young", change_sequence=9, deleted_at=900),
        ]
        cursors = [Cursor(position=4, expires_at=100)]
        self.assertEqual(
            tombstones_to_purge(tombstones, cursors, now=100 + 30 * DAY),
            ("old",),
        )

    def test_tombstone_order_is_deterministic_and_does_not_include_future_cursor(self):
        tombstones = [
            Tombstone(record_id="z", change_sequence=2, deleted_at=0),
            Tombstone(record_id="a", change_sequence=1, deleted_at=0),
        ]
        cursors = [Cursor(position=2, expires_at=100)]
        self.assertEqual(tombstones_to_purge(tombstones, cursors, now=30 * DAY), ("a", "z"))

    def test_tombstone_retention_never_selects_non_tombstone_shape(self):
        with self.assertRaises(ValueError):
            Tombstone(record_id="", change_sequence=1, deleted_at=0)


class ActivityCompactionTests(unittest.TestCase):
    def test_compacts_only_old_non_tombstoned_activity_and_groups_by_request(self):
        activities = [
            Activity("b", "req-2", 20, 0, 5, False),
            Activity("a", "req-1", 10, 0, 7, False),
            Activity("c", "req-1", 11, 0, 3, False),
            Activity("d", "req-3", 12, DAY, 9, False),
            Activity("e", "req-4", 13, 0, 8, True),
            Activity("f", None, 14, 0, 8, False),
        ]
        result = activity_compaction(activities, now=30 * DAY)
        self.assertEqual(tuple(item.logical_request_id for item in result), ("req-1", "req-2"))
        self.assertEqual(result[0].record_ids, ("a", "c"))
        self.assertEqual(result[0].through_change_sequence, 11)
        self.assertEqual(result[0].freed_bytes, 10)
        self.assertEqual(result[0].freed_records, 2)

    def test_activity_compaction_requires_logical_request_and_positive_age(self):
        with self.assertRaises(ValueError):
            activity_compaction([], now=0, age_seconds=0)


class MarkerDecisionTests(unittest.TestCase):
    def test_compaction_marker_is_replayable_after_all_summarized_changes(self):
        decision = marker_for_compaction(
            logical_request_id="req-1",
            through_change_sequence=11,
            marker_change_sequence=20,
            freed_bytes=10,
            freed_records=2,
        )
        self.assertEqual(
            decision,
            MarkerDecision(
                marker_kind="activity_compaction",
                change_sequence=20,
                through_change_sequence=11,
                logical_request_id="req-1",
                freed_bytes=10,
                freed_records=2,
            ),
        )

    def test_marker_rejects_non_forward_or_negative_accounting(self):
        with self.assertRaises(ValueError):
            marker_for_compaction("req", 20, 20, 0, 0)
        with self.assertRaises(ValueError):
            marker_for_compaction("req", 1, 2, -1, 0)


if __name__ == "__main__":
    unittest.main()
