import dataclasses
import unittest

from server.sync.conflicts import (
    Admission,
    Projection,
    classify_admission,
    project_record,
)
from server.sync.tests.test_dto import TS, payload, replay, upload
from server.sync.dto import parse_replay, parse_upload


def record(record_type="transcript", **changes):
    value = replay(record_type)
    value.update(changes)
    return parse_replay(value)


class ProjectionTests(unittest.TestCase):
    def test_projection_is_frozen_and_contains_only_comparable_record_state(self):
        projection = project_record(record())
        self.assertIsInstance(projection, Projection)
        self.assertEqual(projection.record_id, "rec-1")
        self.assertEqual(projection.record_type, "transcript")
        self.assertEqual(projection.revision, 1)
        self.assertEqual(projection.immutable, ("msg-1", None, "user", "hello"))
        self.assertEqual(projection.mutable, (None, None, None))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            projection.revision = 2

    def test_projection_does_not_change_when_source_wire_data_is_mutated(self):
        wire = replay()
        parsed = parse_replay(wire)
        projection = project_record(parsed)
        wire["payload"]["text"] = "changed"
        self.assertEqual(projection.immutable[3], "hello")


class AdmissionTests(unittest.TestCase):
    def test_new_record_is_admitted(self):
        self.assertEqual(classify_admission(record()), Admission.ADMIT)

    def test_upload_record_can_be_compared_with_stored_replay_record(self):
        self.assertEqual(
            classify_admission(parse_upload(upload()), record()), Admission.DUPLICATE
        )

    def test_same_revision_and_same_immutable_content_is_duplicate(self):
        current = record()
        incoming = record()
        self.assertEqual(classify_admission(incoming, current), Admission.DUPLICATE)

    def test_lower_revision_is_stale_even_when_mutable_fields_differ(self):
        current = record(revision=2)
        incoming = record(revision=1)
        self.assertEqual(classify_admission(incoming, current), Admission.STALE)

    def test_equal_revision_with_different_immutable_content_is_conflict(self):
        current = record()
        incoming = record(payload={**payload("transcript"), "text": "different"})
        self.assertEqual(classify_admission(incoming, current), Admission.CONFLICT)

    def test_same_record_id_with_different_record_type_is_conflict(self):
        current = record()
        incoming_wire = replay("activity")
        incoming_wire["recordId"] = current.record_id
        incoming = parse_replay(incoming_wire)
        self.assertEqual(classify_admission(incoming, current), Admission.CONFLICT)

    def test_higher_revision_with_immutable_content_changed_is_conflict(self):
        current = record()
        incoming = record(revision=2, payload={**payload("transcript"), "text": "different"})
        self.assertEqual(classify_admission(incoming, current), Admission.CONFLICT)

    def test_higher_revision_with_only_mutable_content_changed_is_higher_revision(self):
        current = record(record_type="activity")
        incoming_wire = replay("activity", revision=2)
        incoming_wire["payload"]["status"] = "succeeded"
        incoming = parse_replay(incoming_wire)
        self.assertEqual(classify_admission(incoming, current), Admission.HIGHER_REVISION)

    def test_tombstone_blocks_equal_and_lower_revision_records(self):
        tombstone = record("tombstone")
        incoming = record(recordId="msg-rec-1", revision=1)
        self.assertEqual(
            classify_admission(incoming, tombstone=tombstone), Admission.STALE
        )

    def test_tombstone_blocks_higher_revision_until_revision_exceeds_deletion(self):
        tombstone_wire = replay("tombstone", revision=2)
        tombstone_wire["payload"]["deletionRevision"] = 2
        tombstone = parse_replay(tombstone_wire)
        self.assertEqual(
            classify_admission(record(recordId="msg-rec-1", revision=2), tombstone=tombstone), Admission.STALE
        )
        self.assertEqual(
            classify_admission(record(recordId="msg-rec-1", revision=3), tombstone=tombstone), Admission.ADMIT
        )

    def test_all_record_types_have_deterministic_admission(self):
        for record_type in ("transcript", "providerMetadata", "usage", "activity"):
            with self.subTest(record_type=record_type):
                current = record(record_type)
                self.assertEqual(classify_admission(record(record_type), current), Admission.DUPLICATE)


if __name__ == "__main__":
    unittest.main()
