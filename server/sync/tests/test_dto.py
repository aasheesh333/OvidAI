"""Closed v1 DTO tests (stdlib unittest only).

FIELDS below is transcribed independently from the normative spec table so the
implementation is checked against the spec, not against itself.
"""

import copy
import dataclasses
import unittest

from server.sync.canonical import canonical_bytes, decode_strict
from server.sync.dto import (
    ActivityPayload,
    ProviderMetadataPayload,
    ReplayRecord,
    TombstonePayload,
    TranscriptPayload,
    UploadRecord,
    UsagePayload,
    parse_replay,
    parse_upload,
)
from server.sync.endpoints import EndpointPolicy
from server.sync.errors import SyncError

TS = "2026-10-08T12:34:56Z"
I32 = 2147483647
U32 = 4294967295

# kind: id | text | enum | int | bool | ts ; (kind, nullable, arg)
FIELDS = {
    "transcript": {
        "messageId": ("id", False, None),
        "parentMessageId": ("id", True, None),
        "kind": ("enum", False, ("user", "assistant", "system", "tool")),
        "text": ("text", False, (0, 262144)),
        "providerMetadataRecordId": ("id", True, None),
        "requestPurpose": ("text", True, (0, 128)),
        "displayTitle": ("text", True, (0, 256)),
    },
    "providerMetadata": {
        "providerId": ("text", False, (1, 64)),
        "modelId": ("text", True, (1, 128)),
        "endpoint": ("endpoint", False, None),
        "requestPurpose": ("text", True, (0, 128)),
        "displayName": ("text", True, (0, 256)),
        "supportsStreaming": ("bool", False, None),
    },
    "usage": {
        "logicalRequestId": ("id", False, None),
        "attemptId": ("id", False, None),
        "requestedModel": ("text", True, (1, 128)),
        "reportedModel": ("text", True, (1, 128)),
        "outcome": ("enum", False, ("pending", "succeeded", "failed", "cancelled", "interrupted", "unknown")),
        "inputTokens": ("int", True, (0, I32)),
        "outputTokens": ("int", True, (0, I32)),
        "totalTokens": ("int", True, (0, U32)),
        "usageProvenance": ("enum", False, ("providerReported", "locallyEstimated", "derived", "unknown", "legacyUnspecified")),
        "startedAt": ("ts", True, None),
        "completedAt": ("ts", True, None),
        "elapsedMilliseconds": ("int", True, (0, 604800000)),
    },
    "activity": {
        "logicalRequestId": ("id", True, None),
        "attemptId": ("id", True, None),
        "kind": ("enum", False, ("request", "tool", "mcp", "plugin", "browser", "build", "system")),
        "status": ("enum", False, ("queued", "started", "succeeded", "failed", "cancelled", "interrupted", "unknown")),
        "updatedAt": ("ts", False, None),
        "title": ("text", False, (0, 256)),
        "detail": ("text", False, (0, 2048)),
        "usageRecordId": ("id", True, None),
    },
    "tombstone": {
        "targetRecordId": ("id", False, None),
        "deletionRevision": ("int", False, (1, I32)),
        "deletedAt": ("ts", False, None),
        "reason": ("enum", False, ("user", "account", "retention", "conflict", "admin")),
    },
}

PAYLOAD_CLASSES = {
    "transcript": TranscriptPayload,
    "providerMetadata": ProviderMetadataPayload,
    "usage": UsagePayload,
    "activity": ActivityPayload,
    "tombstone": TombstonePayload,
}

SECRET_TEXT = (
    "my key is sk-live-SENTINEL0123456789abcdef and AKIAIOSFODNN7EXAMPLE\n"
    "password=hunter2 Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig\n"
    "-----BEGIN PRIVATE KEY-----\nMIIE\u0000\u001f\t\r\u2028\U0001F511 \"quoted\" \\path"
)


def payload(record_type):
    return copy.deepcopy({
        "transcript": {"messageId": "msg-1", "parentMessageId": None, "kind": "user", "text": "hello",
                       "providerMetadataRecordId": None, "requestPurpose": None, "displayTitle": None},
        "providerMetadata": {"providerId": "openai", "modelId": "gpt-test", "endpoint": "https://api.openai.com/v1",
                             "requestPurpose": None, "displayName": "OpenAI", "supportsStreaming": True},
        "usage": {"logicalRequestId": "req-1", "attemptId": "att-1", "requestedModel": "gpt-test",
                  "reportedModel": None, "outcome": "succeeded", "inputTokens": 0, "outputTokens": None,
                  "totalTokens": 0, "usageProvenance": "providerReported", "startedAt": TS,
                  "completedAt": None, "elapsedMilliseconds": 0},
        "activity": {"logicalRequestId": "req-1", "attemptId": "att-1", "kind": "request", "status": "started",
                     "updatedAt": TS, "title": "Request", "detail": "", "usageRecordId": "att-1"},
        "tombstone": {"targetRecordId": "msg-rec-1", "deletionRevision": 1, "deletedAt": TS, "reason": "user"},
    }[record_type])


def upload(record_type="transcript", **overrides):
    record_id = {"usage": "att-1", "tombstone": "tomb-1"}.get(record_type, "rec-1")
    value = {"schemaVersion": 1, "recordId": record_id, "sourceDeviceId": "dev-1", "recordType": record_type,
             "conversationId": "conv-1", "createdAt": TS, "revision": 1, "payload": payload(record_type)}
    value.update(overrides)
    return value


def replay(record_type="transcript", **overrides):
    value = upload(record_type)
    value.update({"accountId": "acct-1", "changeSequence": 42})
    value.update(overrides)
    return value


def with_field(record_type, name, field_value):
    value = upload(record_type)
    value["payload"][name] = field_value
    if record_type == "usage" and name == "attemptId" and isinstance(field_value, str):
        value["recordId"] = field_value  # keep the recordId == attemptId identity rule
    return value


class Base(unittest.TestCase):
    def assertRejected(self, value, code="invalid_record", parser=parse_upload, **kwargs):
        with self.assertRaises(SyncError) as caught:
            parser(value, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception


class PayloadFieldTests(Base):
    def test_valid_records_round_trip_exactly(self):
        for record_type in FIELDS:
            with self.subTest(record_type=record_type):
                wire = upload(record_type)
                record = parse_upload(wire)
                self.assertIsInstance(record, UploadRecord)
                self.assertIsInstance(record.payload, PAYLOAD_CLASSES[record_type])
                self.assertEqual(record.to_wire(), wire)
                self.assertEqual(parse_upload(decode_strict(canonical_bytes(wire))), record)

    def test_payload_field_sets_are_exact(self):
        for record_type, fields in FIELDS.items():
            with self.subTest(record_type=record_type):
                self.assertEqual(set(payload(record_type)), set(fields))
                cls = PAYLOAD_CLASSES[record_type]
                self.assertEqual(cls.from_wire(payload(record_type)).to_wire(), payload(record_type))

    def test_missing_and_unknown_payload_fields(self):
        for record_type, fields in FIELDS.items():
            for name in fields:
                value = upload(record_type)
                del value["payload"][name]
                with self.subTest(record_type=record_type, missing=name):
                    self.assertRejected(value)
            for extra in ("apiKey", "runtimeQueue", "workspacePath", "attachmentBytes", "processHandle",
                          "command", "authorization", "messageid", "display"):
                with self.subTest(record_type=record_type, extra=extra):
                    self.assertRejected(with_field(record_type, extra, None))

    def test_types_bounds_and_nullability(self):
        for record_type, fields in FIELDS.items():
            for name, (kind, nullable, arg) in fields.items():
                good, bad = [], [[], {}]
                if kind == "id":
                    good += ["a", "A" * 128, "id-~!._:/@" ]
                    bad += ["", "A" * 129, "\u00e9", "has space", "tab\t", "nl\n", "\x7f", 1, True]
                elif kind == "text":
                    low, high = arg
                    good += ["a" * low, "\U0001F600" * high, "a" * high]
                    bad += ["a" * (high + 1), "\U0001F600" * (high + 1), "\ud800", 1, True]
                    if low:
                        bad.append("")
                elif kind == "int":
                    low, high = arg
                    good += [low, high]
                    bad += [low - 1, high + 1, True, False, float(low), str(low)]
                elif kind == "bool":
                    good += [True, False]
                    bad += [0, 1, "true"]
                elif kind == "ts":
                    good += [TS]
                    bad += ["2026-10-08T12:34:56+00:00", 0]
                elif kind == "enum":
                    good += list(arg)
                    bad += [arg[0].upper(), arg[0] + " ", "", 0]
                elif kind == "endpoint":
                    bad += [1, True]
                (good if nullable else bad).append(None)
                for candidate in good:
                    with self.subTest(record_type=record_type, field=name, good=repr(candidate)[:40]):
                        record = parse_upload(with_field(record_type, name, candidate))
                        self.assertEqual(record.to_wire()["payload"][name], candidate)
                for candidate in bad:
                    with self.subTest(record_type=record_type, field=name, bad=repr(candidate)[:40]):
                        self.assertRejected(with_field(record_type, name, candidate))

    def test_null_versus_zero_is_preserved(self):
        for name in ("inputTokens", "outputTokens", "totalTokens", "elapsedMilliseconds"):
            with self.subTest(field=name):
                zero = parse_upload(with_field("usage", name, 0))
                null = parse_upload(with_field("usage", name, None))
                self.assertEqual(getattr(zero.payload, _snake(name)), 0)
                self.assertIsNone(getattr(null.payload, _snake(name)))
                self.assertNotEqual(canonical_bytes(zero.to_wire()), canonical_bytes(null.to_wire()))

    def test_empty_strings_versus_null(self):
        record = parse_upload(with_field("transcript", "displayTitle", ""))
        self.assertEqual(record.payload.display_title, "")
        self.assertIsNone(parse_upload(upload("transcript")).payload.display_title)

    def test_full_size_transcript_text(self):
        text = "\U0001F600" * 262144
        self.assertEqual(parse_upload(with_field("transcript", "text", text)).payload.text, text)
        self.assertRejected(with_field("transcript", "text", text + "a"))


class TimestampTests(Base):
    def test_timestamps(self):
        good = ["2026-10-08T12:34:56Z", "2026-10-08T12:34:56.123456789Z", "2024-02-29T00:00:00Z",
                "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.9Z"]
        bad = ["2026-10-08T12:34:56+00:00", "2026-10-08T12:34:56-05:00", "2026-10-08 12:34:56Z",
               "2026-10-08t12:34:56z", "2026-13-01T00:00:00Z", "2023-02-29T00:00:00Z", "2026-00-10T00:00:00Z",
               "2026-10-08T24:00:00Z", "2026-10-08T12:60:00Z", "2026-10-08T12:34:60Z", "2026-10-08T12:34:56.Z",
               "2026-10-08T12:34:56.1234567890Z", "2026-10-08T12:34Z", "2026-10-08", "", "0000-01-01T00:00:00Z",
               "\uff12026-10-08T12:34:56Z", "2026-10-08T12:34:56Z\n", " 2026-10-08T12:34:56Z"]
        for value in good:
            with self.subTest(good=value):
                self.assertEqual(parse_upload(upload(createdAt=value)).created_at, value)
        for value in bad:
            with self.subTest(bad=value):
                self.assertRejected(upload(createdAt=value))


class EnvelopeTests(Base):
    def test_upload_and_replay_key_sets(self):
        self.assertEqual(set(upload()), {"schemaVersion", "recordId", "sourceDeviceId", "recordType",
                                         "conversationId", "createdAt", "revision", "payload"})
        record = parse_replay(replay())
        self.assertIsInstance(record, ReplayRecord)
        self.assertEqual(record.account_id, "acct-1")
        self.assertEqual(record.change_sequence, 42)
        self.assertEqual(record.to_wire(), replay())
        self.assertEqual(ReplayRecord.from_wire(replay()), record)
        self.assertEqual(UploadRecord.from_wire(upload()), parse_upload(upload()))

    def test_upload_rejects_server_fields(self):
        self.assertRejected(upload(accountId="acct-1"))
        self.assertRejected(upload(changeSequence=1))

    def test_replay_requires_server_fields(self):
        for name in ("accountId", "changeSequence"):
            value = replay()
            del value[name]
            with self.subTest(missing=name):
                self.assertRejected(value, parser=parse_replay)
        for bad in (0, -1, True, 1.0, "1", None, 9007199254740992):
            with self.subTest(changeSequence=bad):
                self.assertRejected(replay(changeSequence=bad), parser=parse_replay)
        self.assertEqual(parse_replay(replay(changeSequence=9007199254740991)).change_sequence, 9007199254740991)
        for bad in ("", "a" * 129, None, 1, "\u00e9"):
            with self.subTest(accountId=bad):
                self.assertRejected(replay(accountId=bad), parser=parse_replay)

    def test_missing_and_unknown_envelope_fields(self):
        for name in upload():
            value = upload()
            del value[name]
            with self.subTest(missing=name):
                self.assertRejected(value)
        for extra in ("apiKey", "session", "runtimeQueue", "ownerId", "uid", "recordid"):
            with self.subTest(extra=extra):
                self.assertRejected(upload(**{extra: None}))

    def test_schema_version(self):
        for bad in (0, 2, -1, 100):
            with self.subTest(version=bad):
                self.assertRejected(upload(schemaVersion=bad), code="schema_version_unsupported")
                self.assertRejected(replay(schemaVersion=bad), code="schema_version_unsupported", parser=parse_replay)
        for bad in (True, 1.0, "1", None):
            with self.subTest(version=bad):
                self.assertRejected(upload(schemaVersion=bad))

    def test_envelope_ids_revision_and_type(self):
        for name in ("recordId", "sourceDeviceId"):
            for bad in ("", "a" * 129, None, 1, "\u00e9", "a b"):
                with self.subTest(field=name, bad=bad):
                    self.assertRejected(upload(**{name: bad}))
        self.assertIsNone(parse_upload(upload(conversationId=None)).conversation_id)
        self.assertRejected(upload(conversationId=""))
        for good in (1, I32):
            self.assertEqual(parse_upload(upload(revision=good)).revision, good)
        for bad in (0, -1, I32 + 1, True, 1.0, None):
            with self.subTest(revision=bad):
                self.assertRejected(upload(revision=bad))
        for bad in ("Transcript", "session", "", None, 1):
            with self.subTest(recordType=bad):
                self.assertRejected(upload(recordType=bad))

    def test_payload_must_match_record_type(self):
        for bad in (None, [], "x", payload("usage")):
            with self.subTest(payload=bad):
                self.assertRejected(upload("transcript", payload=bad))

    def test_usage_record_id_equals_attempt_id(self):
        self.assertRejected(upload("usage", recordId="other"))
        value = upload("usage")
        value["payload"]["attemptId"] = "att-2"
        self.assertRejected(value)
        value["recordId"] = "att-2"
        self.assertEqual(parse_upload(value).record_id, "att-2")

    def test_tombstone_cannot_target_itself(self):
        self.assertRejected(upload("tombstone", recordId="msg-rec-1"))

    def test_non_object_inputs(self):
        for bad in (None, [], "{}", 1, b"{}"):
            with self.subTest(value=bad):
                self.assertRejected(bad)
                self.assertRejected(bad, parser=parse_replay)

    def test_duplicate_keys_rejected_at_decode(self):
        raw = b'{"schemaVersion":1,"schemaVersion":1}'
        with self.assertRaises(SyncError) as caught:
            decode_strict(raw)
        self.assertEqual(caught.exception.code, "invalid_request")


class SharedVectorRecordTests(Base):
    def test_record_vectors_parse_and_round_trip_to_exact_bytes(self):
        import json
        from pathlib import Path
        path = Path(__file__).resolve().parents[3] / "test" / "fixtures" / "private_sync" / "canonical_vectors.json"
        vectors = json.loads(path.read_text(encoding="utf-8"))["vectors"]
        records = [v for v in vectors if v["name"].startswith("record.")]
        self.assertGreaterEqual(len(records), 7)
        seen = set()
        for vector in records:
            parser = parse_replay if vector["name"].startswith("record.replay.") else parse_upload
            with self.subTest(name=vector["name"]):
                record = parser(vector["input"])
                seen.add((parser.__name__, record.record_type))
                self.assertEqual(canonical_bytes(record.to_wire()), vector["canonical"].encode("utf-8"))
        for record_type in FIELDS:
            self.assertIn(("parse_upload", record_type), seen)


class PrivacyAndSafetyTests(Base):
    def test_secret_like_transcript_text_is_preserved_verbatim(self):
        wire = with_field("transcript", "text", SECRET_TEXT)
        record = parse_upload(wire)
        self.assertEqual(record.payload.text, SECRET_TEXT)
        self.assertEqual(record.to_wire()["payload"]["text"], SECRET_TEXT)
        decoded = parse_upload(decode_strict(canonical_bytes(record.to_wire())))
        self.assertEqual(decoded.payload.text, SECRET_TEXT)
        self.assertIn("sk-live-SENTINEL".encode(), canonical_bytes(record.to_wire()))

    def test_errors_never_echo_input(self):
        error = self.assertRejected(with_field("transcript", "SENTINEL_FIELD", "SENTINEL_VALUE"))
        self.assertNotIn("SENTINEL", str(error) + repr(error) + repr(error.args))
        error = self.assertRejected(upload(recordId="SENTINEL\u00e9"))
        self.assertNotIn("SENTINEL", str(error) + repr(error))

    def test_provider_endpoint_is_validated_and_canonicalized(self):
        for bad in ("https://user:pw@api.example.com/", "https://api.example.com/v1?api_key=SENTINEL",
                    "http://api.example.com/", "https://api.example.com/#frag", "javascript:alert(1)"):
            with self.subTest(endpoint=bad):
                error = self.assertRejected(with_field("providerMetadata", "endpoint", bad), code="endpoint_rejected")
                self.assertNotIn("SENTINEL", str(error))
        record = parse_upload(with_field("providerMetadata", "endpoint", "HTTPS://API.OpenAI.com:443/v1/./x"))
        self.assertEqual(record.payload.endpoint, "https://api.openai.com/v1/x")
        self.assertEqual(record.to_wire()["payload"]["endpoint"], "https://api.openai.com/v1/x")

    def test_endpoint_policy_is_explicit(self):
        wire = with_field("providerMetadata", "endpoint", "http://localhost:11434/v1")
        wire["payload"]["providerId"] = "ollama"
        self.assertRejected(wire, code="endpoint_rejected")
        policies = {"ollama": EndpointPolicy(allowed_schemes=frozenset({"https", "http"}))}
        self.assertEqual(parse_upload(wire, endpoint_policies=policies).payload.endpoint, "http://localhost:11434/v1")
        self.assertEqual(parse_replay({**wire, "accountId": "a", "changeSequence": 1},
                                      endpoint_policies=policies).payload.endpoint, "http://localhost:11434/v1")

    def test_records_are_immutable(self):
        record = parse_upload(upload())
        with self.assertRaises(dataclasses.FrozenInstanceError):
            record.record_id = "x"
        with self.assertRaises(dataclasses.FrozenInstanceError):
            record.payload.text = "x"
        wire = record.to_wire()
        wire["payload"]["text"] = "mutated"
        self.assertEqual(record.payload.text, "hello")

    def test_input_mutation_after_parse_has_no_effect(self):
        wire = upload()
        record = parse_upload(wire)
        wire["payload"]["text"] = "mutated"
        self.assertEqual(record.payload.text, "hello")

    def test_dto_module_imports_are_data_only(self):
        import server.sync.canonical as canonical
        import server.sync.dto as dto
        import server.sync.endpoints as endpoints
        import server.sync.errors as errors
        forbidden = ("socket", "subprocess", "http", "urllib.request", "requests", "httpx", "asyncio",
                     "multiprocessing", "threading", "os", "server.shares", "server.account")
        for module in (canonical, dto, endpoints, errors):
            source = open(module.__file__, encoding="utf-8").read()
            for name in forbidden:
                with self.subTest(module=module.__name__, name=name):
                    self.assertNotRegex(source, rf"(?m)^\s*(import|from)\s+{name.replace('.', '[.]')}\b")


def _snake(name):
    return "".join("_" + c.lower() if c.isupper() else c for c in name)


if __name__ == "__main__":
    unittest.main()
