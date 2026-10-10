"""Shared service-boundary vectors; Dart reads SERVICE_VECTORS_JSON below.

The checkout has wire primitives but no sync router/result codec yet. Tests
exercise the real primitives; the HTTP no-store contract is explicitly pending.
Keep the fixture here because this task permits only two new test files.
"""

import copy
import json
import unittest
from unittest.mock import patch

from server.sync.canonical import canonical_bytes, decode_strict
from server.sync.dto import parse_replay
from server.sync.errors import SyncError, parse_error


SERVICE_VECTORS_JSON = r'''
{
  "results": [
    {
      "name": "changes.empty",
      "headers": {"cache-control": "no-store"},
      "body": {"schemaVersion": 1, "nextCursor": "cursor-7", "hasMore": false, "records": []},
      "canonical": "{\"hasMore\":false,\"nextCursor\":\"cursor-7\",\"records\":[],\"schemaVersion\":1}"
    },
    {
      "name": "reset",
      "headers": {"cache-control": "no-store"},
      "body": {"schemaVersion": 1, "code": "reset_required"},
      "canonical": "{\"code\":\"reset_required\",\"schemaVersion\":1}"
    },
    {
      "name": "error.rate_limited",
      "headers": {"cache-control": "no-store"},
      "status": 429,
      "body": {"schemaVersion": 1, "code": "rate_limited", "message": "Too many requests. Retry later.", "retryAfterSeconds": 30},
      "canonical": "{\"code\":\"rate_limited\",\"message\":\"Too many requests. Retry later.\",\"retryAfterSeconds\":30,\"schemaVersion\":1}"
    },
    {
      "name": "error.account_fenced",
      "headers": {"cache-control": "no-store"},
      "status": 403,
      "body": {"schemaVersion": 1, "code": "account_fenced", "message": "This account is not currently available for sync.", "retryAfterSeconds": null},
      "canonical": "{\"code\":\"account_fenced\",\"message\":\"This account is not currently available for sync.\",\"retryAfterSeconds\":null,\"schemaVersion\":1}"
    }
  ],
  "replay": {
    "schemaVersion": 1,
    "accountId": "acct-1",
    "changeSequence": 7,
    "recordId": "rec-1",
    "sourceDeviceId": "dev-1",
    "recordType": "transcript",
    "conversationId": "conv-1",
    "createdAt": "2026-10-08T12:00:00Z",
    "revision": 1,
    "payload": {
      "messageId": "msg-1",
      "parentMessageId": null,
      "kind": "tool",
      "text": "$(touch SENTINEL); <script>alert('SENTINEL')</script>\nAuthorization: Bearer SENTINEL 🔑",
      "providerMetadataRecordId": null,
      "requestPurpose": null,
      "displayTitle": null
    }
  }
}
'''

VECTORS = json.loads(SERVICE_VECTORS_JSON)


class ServiceResultVectorTests(unittest.TestCase):
    def test_result_envelopes_match_literal_cross_language_canonical_bytes(self):
        for vector in VECTORS["results"]:
            with self.subTest(vector=vector["name"]):
                self.assertEqual(
                    canonical_bytes(vector["body"]), vector["canonical"].encode("utf-8")
                )
                self.assertEqual(decode_strict(vector["canonical"]), vector["body"])

    def test_error_vectors_use_real_closed_error_codec_and_http_mapping(self):
        for vector in VECTORS["results"]:
            if not vector["name"].startswith("error."):
                continue
            with self.subTest(vector=vector["name"]):
                error = parse_error(decode_strict(vector["canonical"]))
                self.assertEqual(error.to_wire(), vector["body"])
                self.assertEqual(error.status, vector["status"])

    def test_reset_is_a_typed_error_for_the_coordinator(self):
        reset = VECTORS["results"][1]["body"]
        error = parse_error({**reset, "message": "The sync state must be reset.", "retryAfterSeconds": None})
        self.assertEqual(error.code, "reset_required")
        with self.assertRaises(SyncError):
            parse_replay(reset)

    def test_error_codec_rejects_echoed_secrets_extra_fields_and_bad_retry_hints(self):
        original = VECTORS["results"][2]["body"]
        mutations = [{"message": "SENTINEL raw provider failure"},
                     {"detail": "SENTINEL"}, {"records": [VECTORS["replay"]]},
                     {"code": "reset_required"}]
        mutations.extend({"retryAfterSeconds": value}
                         for value in (-1, 86401, True, 1.0, "30"))
        mutations.extend({"schemaVersion": value} for value in (True, "1", None))
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(SyncError) as caught:
                parse_error({**original, **mutation})
            self.assertEqual(caught.exception.code, "invalid_request")
            self.assertNotIn("SENTINEL", str(caught.exception))
            self.assertNotIn("SENTINEL", canonical_bytes(caught.exception.to_wire()).decode())
        for field in original:
            incomplete = dict(original)
            del incomplete[field]
            with self.subTest(missing=field), self.assertRaises(SyncError):
                parse_error(incomplete)

    def test_retry_zero_null_and_upper_bound_survive_wire_codec(self):
        original = VECTORS["results"][2]["body"]
        for retry in (None, 0, 86400):
            body = {**original, "retryAfterSeconds": retry}
            with self.subTest(retry=retry):
                self.assertEqual(parse_error(body).to_wire(), body)

    def test_http_success_reset_and_error_responses_are_no_store(self):
        for vector in VECTORS["results"]:
            self.assertEqual(vector["headers"]["cache-control"], "no-store")


class ServiceInertnessTests(unittest.TestCase):
    def test_replay_preserves_command_shaped_private_text_without_network_or_execution(self):
        wire = copy.deepcopy(VECTORS["replay"])
        # Tripwires guard real side-effect boundaries, not a fake parser.
        with patch("socket.socket", side_effect=AssertionError("network attempted")), \
                patch("subprocess.Popen", side_effect=AssertionError("execution attempted")), \
                patch("os.system", side_effect=AssertionError("execution attempted")):
            record = parse_replay(decode_strict(canonical_bytes(wire)))
            self.assertEqual(record.to_wire(), wire)
            self.assertEqual(record.payload.text, wire["payload"]["text"])
            wire["payload"]["text"] = "changed after parsing"
            self.assertEqual(record.payload.text, VECTORS["replay"]["payload"]["text"])

    def test_replay_rejects_runtime_or_credential_fields_at_both_levels(self):
        for field in ("callback", "command", "runtimeQueue", "processHandle", "apiKey", "authorization"):
            for level in ("envelope", "payload"):
                wire = copy.deepcopy(VECTORS["replay"])
                target = wire if level == "envelope" else wire["payload"]
                target[field] = "SENTINEL"
                with self.subTest(field=field, level=level), self.assertRaises(SyncError) as caught:
                    parse_replay(wire)
                self.assertEqual(caught.exception.code, "invalid_record")
                self.assertNotIn("SENTINEL", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
