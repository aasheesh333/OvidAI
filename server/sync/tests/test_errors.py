"""Closed sync error DTO tests (stdlib unittest only)."""

import json
import unittest

from server.sync.canonical import canonical_bytes
from server.sync.errors import (
    ERROR_CODES,
    HTTP_STATUS,
    MAX_RETRY_AFTER_SECONDS,
    SyncError,
    parse_error,
)

SPEC_STATUS = {
    "invalid_request": 400,
    "unauthenticated": 401,
    "device_revoked": 403,
    "account_fenced": 403,
    "not_found": 404,
    "integrity_conflict": 409,
    "payload_too_large": 413,
    "schema_version_unsupported": 422,
    "invalid_record": 422,
    "endpoint_rejected": 422,
    "rate_limited": 429,
    "quota_exhausted": 429,
    "temporarily_unavailable": 503,
    "reset_required": 409,
}


class ErrorCodeSetTests(unittest.TestCase):
    def test_code_set_is_exactly_the_spec_enumeration(self):
        self.assertEqual(set(ERROR_CODES), set(SPEC_STATUS))

    def test_http_status_mapping_matches_spec(self):
        self.assertEqual(dict(HTTP_STATUS), SPEC_STATUS)
        for code, status in SPEC_STATUS.items():
            with self.subTest(code=code):
                self.assertEqual(SyncError(code).status, status)

    def test_reset_required_is_a_wire_error(self):
        self.assertEqual(SyncError("reset_required").status, 409)

    def test_unknown_code_rejected(self):
        for code in ("", "INVALID_REQUEST", "internal", None, 1):
            with self.subTest(code=code), self.assertRaises((ValueError, TypeError)):
                SyncError(code)


class ErrorMessageTests(unittest.TestCase):
    def test_messages_are_fixed_bounded_ascii(self):
        seen = set()
        for code in ERROR_CODES:
            with self.subTest(code=code):
                message = SyncError(code).message
                self.assertTrue(0 < len(message) <= 160)
                self.assertTrue(message.isascii())
                self.assertNotIn("{", message)
                self.assertNotIn("%", message)
                seen.add(message)
        self.assertEqual(len(seen), len(ERROR_CODES))

    def test_constructor_accepts_no_free_text(self):
        with self.assertRaises(TypeError):
            SyncError("invalid_request", None, "secret sk-test-123")  # noqa
        with self.assertRaises(TypeError):
            SyncError("invalid_request", message="secret sk-test-123")

    def test_str_and_repr_are_the_fixed_message(self):
        error = SyncError("endpoint_rejected")
        self.assertEqual(str(error), error.message)
        self.assertNotIn("http", repr(error).lower().replace("endpoint", ""))


class ErrorWireTests(unittest.TestCase):
    def test_wire_shape_is_closed(self):
        wire = SyncError("rate_limited", retry_after_seconds=30).to_wire()
        self.assertEqual(
            wire,
            {
                "schemaVersion": 1,
                "code": "rate_limited",
                "message": SyncError("rate_limited").message,
                "retryAfterSeconds": 30,
            },
        )

    def test_retry_after_defaults_to_null(self):
        self.assertIsNone(SyncError("not_found").to_wire()["retryAfterSeconds"])

    def test_retry_after_inclusive_bounds(self):
        self.assertEqual(MAX_RETRY_AFTER_SECONDS, 86400)
        for value in (0, 1, 86400):
            with self.subTest(value=value):
                self.assertEqual(
                    SyncError("quota_exhausted", retry_after_seconds=value).retry_after_seconds,
                    value,
                )
        for value in (-1, 86401, True, False, 1.0, "5"):
            with self.subTest(value=value), self.assertRaises((ValueError, TypeError)):
                SyncError("quota_exhausted", retry_after_seconds=value)

    def test_canonical_error_bytes(self):
        error = SyncError("temporarily_unavailable", retry_after_seconds=5)
        expected = (
            '{"code":"temporarily_unavailable","message":'
            + json.dumps(error.message)
            + ',"retryAfterSeconds":5,"schemaVersion":1}'
        )
        self.assertEqual(canonical_bytes(error.to_wire()), expected.encode("utf-8"))

    def test_status_and_http_headers_free(self):
        # The DTO is body-only; it carries no headers or echo of input.
        self.assertEqual(set(SyncError("invalid_record").to_wire()), {
            "schemaVersion", "code", "message", "retryAfterSeconds"})


class ParseErrorTests(unittest.TestCase):
    def valid(self):
        return SyncError("rate_limited", retry_after_seconds=10).to_wire()

    def test_round_trip(self):
        parsed = parse_error(self.valid())
        self.assertEqual(parsed.code, "rate_limited")
        self.assertEqual(parsed.retry_after_seconds, 10)
        self.assertEqual(parsed.to_wire(), self.valid())

    def test_rejects_unknown_missing_and_wrong_fields(self):
        cases = []
        extra = self.valid(); extra["detail"] = "x"; cases.append(extra)
        for key in ("schemaVersion", "code", "message", "retryAfterSeconds"):
            missing = self.valid(); del missing[key]; cases.append(missing)
        wrong_message = self.valid(); wrong_message["message"] = "server said: sk-123"; cases.append(wrong_message)
        wrong_version = self.valid(); wrong_version["schemaVersion"] = True; cases.append(wrong_version)
        wrong_code = self.valid(); wrong_code["code"] = "boom"; cases.append(wrong_code)
        wrong_retry = self.valid(); wrong_retry["retryAfterSeconds"] = 86401; cases.append(wrong_retry)
        cases.extend([None, [], "error"])
        for case in cases:
            with self.subTest(case=case), self.assertRaises(SyncError) as caught:
                parse_error(case)
            self.assertEqual(caught.exception.code, "invalid_request")

    def test_other_schema_version_is_unsupported(self):
        wire = self.valid(); wire["schemaVersion"] = 2
        with self.assertRaises(SyncError) as caught:
            parse_error(wire)
        self.assertEqual(caught.exception.code, "schema_version_unsupported")


if __name__ == "__main__":
    unittest.main()
