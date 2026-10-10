"""Typed private-sync result envelope tests."""

import dataclasses
import unittest

from server.sync.dto import parse_replay
from server.sync.errors import SyncError
from server.sync.results import (
    BatchResult,
    ChangePage,
    DeviceEnrollment,
    RecordOutcome,
    StatePage,
    parse_batch_result,
    parse_change_page,
    parse_device_enrollment,
    parse_state_page,
)

TS = "2026-10-08T12:34:56Z"


def replay():
    return parse_replay({
        "schemaVersion": 1, "recordId": "rec-1", "accountId": "acct-1",
        "sourceDeviceId": "dev-1", "recordType": "transcript",
        "conversationId": None, "createdAt": TS, "revision": 1,
        "changeSequence": 7,
        "payload": {"messageId": "msg-1", "parentMessageId": None,
                     "kind": "user", "text": "hello",
                     "providerMetadataRecordId": None, "requestPurpose": None,
                     "displayTitle": None},
    })


class ResultEnvelopeTests(unittest.TestCase):
    def test_batch_result_round_trips_typed_outcomes(self):
        result = BatchResult((
            RecordOutcome("rec-1", "accepted", 2, 8, None),
            RecordOutcome("rec-2", "rejected", None, None, SyncError("invalid_record")),
        ))
        wire = result.to_wire()
        self.assertEqual(set(wire), {"schemaVersion", "results"})
        self.assertEqual(parse_batch_result(wire), result)
        self.assertEqual(wire["results"][0], {
            "recordId": "rec-1", "status": "accepted", "revision": 2,
            "changeSequence": 8, "error": None,
        })

    def test_pages_round_trip_and_use_immutable_record_collections(self):
        changes = ChangePage("cursor-2", True, (replay(),))
        state = StatePage("acct-1", "cursor-9", (replay(),), "enrolled", ("marker",))
        self.assertEqual(parse_change_page(changes.to_wire()), changes)
        self.assertEqual(parse_state_page(state.to_wire()), state)
        self.assertIsInstance(changes.records, tuple)
        self.assertIsInstance(state.records, tuple)

    def test_device_enrollment_round_trips(self):
        enrollment = DeviceEnrollment("device-2", "Tablet", TS, "active")
        self.assertEqual(parse_device_enrollment(enrollment.to_wire()), enrollment)
        self.assertEqual(set(enrollment.to_wire()), {
            "schemaVersion", "deviceId", "deviceName", "createdAt", "status",
        })

    def test_result_objects_are_frozen(self):
        outcome = RecordOutcome("rec-1", "duplicate", 1, 3, None)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            outcome.status = "accepted"

    def test_closed_fields_and_invalid_outcomes_are_rejected(self):
        valid = BatchResult((RecordOutcome("rec-1", "duplicate", 1, 3, None),)).to_wire()
        for bad in (
            {**valid, "extra": 1},
            {"schemaVersion": 1},
            {**valid, "schemaVersion": 2},
            {"schemaVersion": 1, "results": [{"recordId": "rec-1", "status": "wat",
                                                "revision": None, "changeSequence": None,
                                                "error": None}]},
        ):
            with self.subTest(value=bad), self.assertRaises(SyncError):
                parse_batch_result(bad)

    def test_outcome_error_and_success_fields_are_consistent(self):
        good = BatchResult((RecordOutcome("rec-1", "accepted", 1, 1, None),)).to_wire()
        bad = {"schemaVersion": 1, "results": [{
            "recordId": "rec-1", "status": "accepted", "revision": None,
            "changeSequence": None, "error": None,
        }]}
        with self.assertRaises(SyncError):
            parse_batch_result(bad)
        rejected = BatchResult((RecordOutcome(
            "rec-1", "rejected", None, None, SyncError("invalid_record")),
        )).to_wire()
        self.assertEqual(parse_batch_result(rejected).results[0].error.code, "invalid_record")


if __name__ == "__main__":
    unittest.main()
