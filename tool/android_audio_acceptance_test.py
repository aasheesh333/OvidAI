"""UNEXECUTED fixture-only tests for the Android audio acceptance harness.

No expected transcript, PCM buffer, signed audit, or report in this file is
on-device acceptance evidence. Tests must never call ADB, FFmpeg, Gradle, an
emulator, an audio device, a server audit command, or an APK build. The real
harness accepts only its live ADB/UI/host-audio/server-audit path.
"""

import hashlib
import hmac
import importlib.util
import json
import math
from pathlib import Path
import struct
import tempfile
import time
import unittest
from unittest import mock
import wave


HARNESS_PATH = Path(__file__).with_name("android_audio_evidence.py")
SCRIPT_PATH = Path(__file__).with_name("android_audio_acceptance.sh")
SCHEMA_PATH = Path(__file__).with_name("android_audio_evidence.schema.json")
CERTIFICATE = "a" * 64
ARTIFACT = "b" * 64
TRANSCRIPT = "c" * 64
NONCE = "0123456789abcdef0123456789abcdef"
KEY = bytes(range(32)).hex()
OPT_IN_ENV = {
    "OVID_AUDIO_ACCEPTANCE_OPT_IN": "YES_AUDIO_CAPABLE_EMULATOR",
    "OVID_AUDIO_ACCOUNT_OPT_IN": "YES_AUTHORIZED_TEST_ACCOUNT",
    "OVID_AUDIO_STIMULI_OPT_IN": "YES_SYNTHETIC_NON_PERSONAL",
    "OVID_AUDIO_SERVER_AUDIT_OPT_IN": "YES_AUTHORIZED_READ_ONLY_AUDIT",
    "OVID_AUDIO_EXCLUSIVE_OUTPUT_OPT_IN": "YES_DEDICATED_EMULATOR_OUTPUT",
    "OVID_EMULATOR_ACCOUNT": "fixture-account-not-for-device-use",
    "OVID_AUDIO_SERVER_AUDIT_COMMAND": "fixture-command-not-executed",
    "OVID_AUDIO_SERVER_AUDIT_HMAC_KEY": KEY,
    "ANDROID_SIGNING_CERT_SHA256": CERTIFICATE,
}


def load_harness():
    if not HARNESS_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("android_audio_evidence", HARNESS_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pcm(samples):
    return struct.pack("<" + str(len(samples)) + "h", *samples)


def tone(seconds=1.0, rate=16000, amplitude=12000):
    return pcm([
        round(amplitude * math.sin(2 * math.pi * 440 * index / rate))
        for index in range(int(seconds * rate))
    ])


def signed_audit(gate, **changes):
    finished = int(time.time() * 1000) - 1000
    value = {
        "schema": gate.SERVER_AUDIT_SCHEMA,
        "run_nonce_sha256": gate.sha256_text(NONCE),
        "account_run_key_sha256": gate.account_run_key(
            NONCE, OPT_IN_ENV["OVID_EMULATOR_ACCOUNT"]),
        "artifact_sha256": ARTIFACT,
        "run_started_ms": finished - 1000,
        "run_finished_ms": finished,
        "queried_ms": finished + 1,
        "scope": "ovid_gateway_and_object_storage",
        "read_only": True,
        "requests": {
            "total": 10,
            "message_json": 6,
            "text_only_message_json": 6,
            "multipart": 0,
            "audio_mime": 0,
            "audio_fields": 0,
            "attachment_uploads": 0,
            "websocket_binary_frames": 0,
            "unclassified": 0,
        },
        "transcript_post_sha256s": [TRANSCRIPT],
        "storage": {
            "audio_objects": 0,
            "audio_records": 0,
            "audio_bytes": 0,
            "scan_complete": True,
        },
    }
    value.update(changes)
    value.pop("signature", None)
    value["signature"] = hmac.new(
        bytes.fromhex(KEY), gate.canonical_json(value), hashlib.sha256).hexdigest()
    return value


class HarnessTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = load_harness()

    def setUp(self):
        self.assertIsNotNone(self.gate, "Android audio harness is not implemented")

    def validate_audit(self, audit):
        return self.gate.validate_server_audit(
            audit, NONCE, OPT_IN_ENV["OVID_EMULATOR_ACCOUNT"], ARTIFACT,
            audit["run_started_ms"], audit["run_finished_ms"], TRANSCRIPT,
            KEY, minimum_messages=6)

    def test_unicode_transcript_matching_is_exact_after_normalization(self):
        self.assertTrue(self.gate.transcript_matches(
            "  यह केवल लिखित उत्तर है। ", ["यह केवल लिखित उत्तर है"]))
        self.assertTrue(self.gate.transcript_matches(
            "Acceptance, ONE", ["acceptance one"]))
        self.assertTrue(self.gate.transcript_matches(
            "ஒலி சோதனை", ["ஒலி சோதனை."]))
        self.assertTrue(self.gate.transcript_matches(
            "ਆਡੀਓ ਜਾਂਚ", ["ਆਡੀਓ ਜਾਂਚ"]))
        self.assertFalse(self.gate.transcript_matches(
            "a different transcript", ["acceptance one"]))
        self.assertFalse(self.gate.transcript_matches("", [""]))

    def test_safe_tts_prompt_does_not_contain_its_exact_answer(self):
        prompt, expected = self.gate.AudioAcceptanceFlow.safe_tts_prompt(NONCE)
        self.assertNotIn(expected, prompt)
        self.assertIn(NONCE, expected)
        self.assertIn("RUN" + NONCE, prompt)
        self.assertTrue(prompt.isascii())
        self.assertTrue(expected.isascii())

    def test_real_pcm_metrics_reject_silence_dc_and_clipping(self):
        baseline = self.gate.pcm_metrics(pcm([0] * 12000))
        metrics = self.gate.pcm_metrics(tone())
        self.assertEqual(self.gate.baseline_errors(baseline), [])
        self.assertEqual(self.gate.signal_errors(metrics, baseline), [])
        self.assertNotIn("audio_signal_absent", self.gate.signal_errors(metrics, baseline))
        silent = self.gate.pcm_metrics(pcm([0] * 16000))
        self.assertIn("audio_signal_absent", self.gate.signal_errors(silent, baseline))
        direct_current = self.gate.pcm_metrics(pcm([10000] * 16000))
        self.assertTrue(self.gate.signal_errors(direct_current, baseline))
        clipped = self.gate.pcm_metrics(pcm([32767, -32768] * 8000))
        self.assertIn("audio_signal_clipped", self.gate.signal_errors(clipped, baseline))
        self.assertEqual(self.gate.baseline_errors(metrics), ["audio_source_busy"])

    def test_pcm_windows_are_bounded_and_never_emit_samples(self):
        raw = tone()
        start, end = 100, 600
        metrics = self.gate.pcm_metrics(self.gate.pcm_window(raw, start, end))
        self.assertEqual(metrics["duration_ms"], 500)
        serialized = json.dumps(metrics)
        self.assertNotIn(str(list(raw[:20])), serialized)
        with self.assertRaises(ValueError):
            self.gate.pcm_window(raw, -1, 100)
        with self.assertRaises(ValueError):
            self.gate.pcm_window(raw, 900, 2000)

    def test_authenticated_server_audit_sanitizes_to_counts_and_digests(self):
        network, storage = self.validate_audit(signed_audit(self.gate))
        self.assertTrue(network["audit_authenticated"])
        self.assertTrue(network["recognized_transcript_post_observed"])
        self.assertEqual(storage["server_audio_objects"], 0)
        serialized = json.dumps([network, storage])
        for forbidden in (NONCE, OPT_IN_ENV["OVID_EMULATOR_ACCOUNT"], KEY, "signature"):
            self.assertNotIn(forbidden, serialized)

    def test_bad_server_audit_signature_is_not_accepted(self):
        audit = signed_audit(self.gate)
        audit["signature"] = "0" * 64
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "server_audit_invalid"):
            self.validate_audit(audit)

    def test_audio_upload_and_server_storage_fail_even_with_valid_signature(self):
        upload = signed_audit(self.gate)
        upload["requests"]["audio_fields"] = 1
        upload = signed_audit(self.gate, requests=upload["requests"])
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "audio_upload_detected"):
            self.validate_audit(upload)
        stored = signed_audit(self.gate, storage={
            "audio_objects": 1, "audio_records": 0, "audio_bytes": 100,
            "scan_complete": True,
        })
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "server_audio_storage_detected"):
            self.validate_audit(stored)

    def test_stale_or_unrelated_server_audit_is_rejected(self):
        stale = signed_audit(self.gate)
        stale["queried_ms"] = stale["run_finished_ms"] - 1
        stale = signed_audit(self.gate, queried_ms=stale["queried_ms"])
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "server_audit_stale_or_future"):
            self.validate_audit(stale)
        unrelated = signed_audit(self.gate, transcript_post_sha256s=["d" * 64])
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "recognized_transcript_post_not_proven"):
            self.validate_audit(unrelated)

    def test_fixture_origin_can_never_be_device_acceptance(self):
        report = self.gate._new_report("fixture-avd")
        report["state"] = "passed"
        errors = self.gate.validate_acceptance(report)
        self.assertIn("real_device_evidence_origin_required", errors)
        self.assertIn("actual_release_provenance_required", errors)
        self.assertIn("multilingual_stt_incomplete", errors)

    def test_explicit_opt_in_and_no_voice_override_are_mandatory(self):
        with self.assertRaisesRegex(self.gate.Blocked, "opt_in"):
            self.gate.validate_operator({}, "ovid34", "emulator-5554")
        self.assertIsNone(self.gate.validate_operator(
            OPT_IN_ENV, "ovid34", "emulator-5554"))
        override = dict(OPT_IN_ENV, OVID_VOICE_ENABLED="fixture-secret-value")
        with self.assertRaisesRegex(self.gate.AcceptanceFailed, "voice_flag_override_forbidden"):
            self.gate.validate_operator(override, "ovid34", "emulator-5554")

    def test_audio_tool_and_endpoint_absence_are_blocked(self):
        with mock.patch.object(self.gate.shutil, "which", return_value=None):
            with self.assertRaisesRegex(self.gate.Blocked, "audio_ffmpeg_unavailable"):
                self.gate.HostAudio({})
        with mock.patch.object(self.gate.shutil, "which", return_value="/fixture/ffmpeg"):
            with self.assertRaisesRegex(self.gate.Blocked, "audio_endpoints_not_configured"):
                self.gate.HostAudio({})

    def test_evidence_store_refuses_raw_audio_screenshots_and_unknown_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            store = self.gate.AudioEvidenceStore.create(Path(directory) / "evidence")
            for name in ("microphone.wav", "tts.pcm", "screen.png", "server-raw.json"):
                with self.subTest(name=name):
                    with self.assertRaises(self.gate.release.HarnessError):
                        store.write_atomic(name, b"fixture-must-not-be-retained")
            store.close()

    def test_missing_opt_in_writes_only_sanitized_blocked_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            out = root / "evidence"
            secret_path = root / "private-apk-and-account-name.apk"
            rc = self.gate.main([
                "--apk", str(secret_path), "--avd", "ovid34",
                "--serial", "emulator-5554", "--stimuli", str(root / "private-manifest.json"),
                "--out", str(out),
            ], env={})
            self.assertEqual(rc, 2)
            report_path = out / self.gate.REPORT_NAME
            report = json.loads(report_path.read_text())
            self.assertEqual(report["state"], "blocked")
            self.assertFalse(report["passed"])
            self.assertEqual(report["evidence_origin"], "none")
            text = report_path.read_text()
            self.assertNotIn(str(root), text)
            self.assertNotIn("emulator-5554", text)

    def test_required_sanitized_capture_set(self):
        complete = {
            "artifact-inspection.sanitized.json", "logcat.redacted.txt",
            "ui-latest.redacted.xml",
        }
        self.assertEqual(self.gate.validate_capture_artifacts(complete), [])
        self.assertEqual(
            self.gate.validate_capture_artifacts({"logcat.redacted.txt"}),
            ["capture_artifacts_missing"])

    def test_schema_and_wrapper_are_source_only_and_do_not_build(self):
        schema = json.loads(SCHEMA_PATH.read_text())
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(schema["properties"]["schema"]["const"], self.gate.SCHEMA)
        source = HARNESS_PATH.read_text()
        wrapper = SCRIPT_PATH.read_text()
        for text in (source, wrapper):
            self.assertNotIn("flutter build", text)
            self.assertNotIn("gradle", text.lower())
            self.assertNotIn("screencap", text)
        self.assertIn("exec python3", wrapper)


class StimulusFixtureTest(unittest.TestCase):
    """Loader fixtures only: silent WAVs are not speech or acceptance evidence."""

    @classmethod
    def setUpClass(cls):
        cls.gate = load_harness()

    def setUp(self):
        self.assertIsNotNone(self.gate, "Android audio harness is not implemented")

    def make_manifest(self, root):
        rows = []
        for language_id, contract in self.gate.LANGUAGES.items():
            audio_path = root / (language_id + "-silent-fixture.wav")
            with wave.open(str(audio_path), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16000)
                output.writeframes(pcm([0] * 32000))
            rows.append({
                "id": language_id,
                "locale": contract["locale"],
                "expected_transcripts": ["synthetic " + language_id + " acceptance"],
                "audio": {
                    "path": str(audio_path),
                    "sha256": hashlib.sha256(audio_path.read_bytes()).hexdigest(),
                },
            })
        manifest = {
            "schema": self.gate.STIMULI_SCHEMA,
            "attestation": {
                "synthetic_non_personal_only": True,
                "authorized_virtual_microphone_use": True,
            },
            "cases": rows,
        }
        path = root / "stimuli.json"
        path.write_text(json.dumps(manifest))
        return path

    def test_all_five_languages_are_pinned_without_retaining_paths_or_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root)
            cases = self.gate.load_stimuli(manifest)
            self.assertEqual([case["id"] for case in cases], list(self.gate.LANGUAGES))
            public = json.dumps([case["public"] for case in cases])
            self.assertNotIn(str(root), public)
            self.assertNotIn("synthetic en acceptance", public)
            self.gate.close_stimuli(cases)

    def test_missing_language_and_same_inode_mutation_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self.make_manifest(root)
            decoded = json.loads(manifest.read_text())
            decoded["cases"].pop()
            manifest.write_text(json.dumps(decoded))
            with self.assertRaisesRegex(self.gate.Blocked, "multilingual_stimuli_required"):
                self.gate.load_stimuli(manifest)
            manifest = self.make_manifest(root)
            cases = self.gate.load_stimuli(manifest)
            with (root / "en-silent-fixture.wav").open("ab") as output:
                output.write(b"mutation")
            with mock.patch.object(self.gate.shutil, "which", return_value="/fixture/ffmpeg"):
                audio = self.gate.HostAudio({
                    "OVID_AUDIO_MIC_SINK": "fixture-sink",
                    "OVID_AUDIO_MIC_MONITOR": "fixture-mic",
                    "OVID_AUDIO_OUTPUT_SOURCE": "fixture-output",
                })
                with self.assertRaisesRegex(self.gate.AcceptanceFailed, "stimulus_audio_changed"):
                    audio.start_play(cases[0])
            self.assertEqual(audio.processes, set())
            self.gate.close_stimuli(cases)


if __name__ == "__main__":
    unittest.main()
