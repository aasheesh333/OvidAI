"""UNEXECUTED round-1 fixture regressions for Android audio acceptance.

Every value here is synthetic and non-device evidence. No test may invoke ADB,
FFmpeg, Gradle, an emulator, audio hardware, a server audit, or an APK build.
"""

import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest


HARNESS_PATH = Path(__file__).with_name("android_audio_evidence.py")
SCHEMA_PATH = Path(__file__).with_name("android_audio_evidence.schema.json")
CAPTURE = {
    "timing_source": "pulse_simple_latency_backdated_frames",
    "first_pcm_frame_host_us": 1_000_000_000,
    "first_pcm_frame_monotonic_ns": 5_000_000_000,
    "first_pcm_frame_uncertainty_us": 20_000,
    "source_latency_us": 15_000,
    "max_source_latency_us": 20_000,
    "capture_timing_uncertainty_us": 20_000,
    "sample_count": 80_000,
    "sample_rate": 16000,
    "channels": 1,
    "sample_format": "s16le",
    "frame_count": 20,
    "last_pcm_frame_host_us": 1_005_000_000,
    "last_pcm_frame_monotonic_ns": 10_000_000_000,
    "cumulative_discontinuity_us": 0,
    "end_to_end_discontinuity_us": 0,
    "last_emitted_frame_timestamp_validated": True,
}
ANCHOR = {
    "offset_ms": 0,
    "uncertainty_ms": 1,
    "series_validated": True,
    "clock_model": "repeated_bounded_anchors",
    "anchor_count": 4,
    "monotonic_bracketed": True,
    "max_offset_step_ms": 0,
    "max_anchor_gap_ms": 1000,
}
TRACE = {
    "source": "ovid.release.logcat",
    "channel": "ovid.tts.utterance",
    "requested_locale": "pa-IN",
    "resolved_locale": "pa-IN",
    "utterance_id": "ovid-answer-7",
    "native_utterance_id": "ovid-answer-7:synthesis-3",
    "device_process_id": 4242,
    "accepted_device_ms": 1_000_100,
    "started_device_ms": 1_000_500,
    "completed_device_ms": 1_001_300,
}
ARTIFACTS = [
    "artifact-inspection.sanitized.json",
    "logcat.redacted.txt",
    "ui-latest.redacted.xml",
]


def load_harness():
    spec = importlib.util.spec_from_file_location("android_audio_evidence_round1", HARNESS_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pcm(samples):
    return struct.pack("<" + str(len(samples)) + "h", *samples)


def interval_pcm(total_seconds, active_start, active_end, rate=16000):
    samples = []
    for index in range(int(total_seconds * rate)):
        seconds = index / rate
        value = round(12000 * math.sin(2 * math.pi * 440 * seconds)) if active_start <= seconds < active_end else 0
        samples.append(value)
    return pcm(samples)


def window(gate, trace=None):
    return gate.capture_window_bounds(trace or TRACE, CAPTURE, ANCHOR)


def exclusive_capture(gate, bounds, background=False):
    required_start, required_end = gate.coverage_required_window(bounds)
    return {
        "coverage_type": (
            "background_segment_exclusive_capture" if background
            else "whole_interval_exclusive_capture"),
        "source": "authorized_exclusive_capture_connector",
        "capture_route_sha256": "a" * 64,
        "session_exclusive": True,
        "whole_interval": True,
        "native_callback_sequence_complete": True,
        "utterance_start_callback_observed": True,
        "utterance_completion_callback_observed": True,
        "utterance_id_sha256": hashlib.sha256(TRACE["utterance_id"].encode()).hexdigest(),
        "native_utterance_id_sha256": hashlib.sha256(TRACE["native_utterance_id"].encode()).hexdigest(),
        "callback_sequence_sha256": "e" * 64,
        "event_count": 2,
        "native_callback_count": 2,
        "manual_snapshot_count": 0,
        "unattributed_transitions": 0,
        "unmatched_output_events": 0,
        "matched_track_gaps": 0,
        "duplicate_configurations": 0,
        "required_start_device_ms": required_start,
        "required_end_device_ms": required_end,
        "first_observed_device_ms": TRACE["started_device_ms"],
        "last_observed_device_ms": TRACE["completed_device_ms"],
        "max_observed_gap_ms": TRACE["completed_device_ms"] - TRACE["started_device_ms"],
        "capture_uncertainty_us": bounds["clock_uncertainty_us"],
        "sample_rate": 16000,
        "channels": 1,
        "sample_format": "s16le",
        "sample_count": bounds["capture_sample_count"],
    }


def metrics(gate, audible=True):
    raw = interval_pcm(1, 0, 1) if audible else pcm([0] * 16000)
    return gate.pcm_metrics(raw)


def tts_case(gate, language_id="pa"):
    trace = dict(TRACE)
    locale = gate.LANGUAGES[language_id]["locale"]
    trace["requested_locale"] = locale
    trace["resolved_locale"] = locale
    output_capture, bounds = gate.utterance_capture_metrics(
        dict(CAPTURE, pcm=interval_pcm(5, 0.601, 1.199)), trace, ANCHOR)
    return {
        "id": language_id,
        "expected_locale": locale,
        "requested_locale": locale,
        "resolved_locale": locale,
        "locale_match": True,
        "utterance_id_sha256": hashlib.sha256(trace["utterance_id"].encode()).hexdigest(),
        "native_utterance_id_sha256": hashlib.sha256(trace["native_utterance_id"].encode()).hexdigest(),
        "utterance_source": "ovid.release.logcat",
        "utterance_channel": "ovid.tts.utterance",
        "device_process_id": trace["device_process_id"],
        "accepted_device_ms": trace["accepted_device_ms"],
        "started_device_ms": trace["started_device_ms"],
        "completed_device_ms": trace["completed_device_ms"],
        "exclusive_capture": exclusive_capture(gate, bounds),
        "capture_window": bounds,
        "offline_synthesis_observed": True,
        "autoplay_absent_before_tap": True,
        "playback_started": True,
        "playback_completed": True,
        "android_playback_track_observed": True,
        "output_capture": output_capture,
        "raw_audio_retained": False,
        "offline_before": {
            "airplane_mode": True,
            "connected_networks": 0,
            "connectivity_sha256": "f" * 64,
        },
    }


def lifecycle(gate):
    draft_hash = hashlib.sha256(b"nonempty synthetic partial").hexdigest()
    track = {
        "known": True,
        "active_tracks": 0,
        "source": "android.media.audio_flinger",
        "channel": "ovid.stt.record",
        "observed_monotonic_ns": 5_000_000_000,
        "dump_sha256": "1" * 64,
    }
    return {
        "stt_background_cancelled": True,
        "stt_background_mic_inactive": True,
        "stt_foreground_no_auto_resume": True,
        "stt_new_gesture_required": True,
        "stt_background_draft_unchanged": True,
        "stt_pre_background_draft_nonempty": True,
        "stt_pre_background_draft_characters": 25,
        "stt_pre_background_draft_sha256": draft_hash,
        "stt_post_foreground_draft_sha256": draft_hash,
        "stt_restart_draft_sha256": draft_hash,
        "stt_restart_gesture_observed": True,
        "stt_restart_draft_preserved": True,
        "stt_record_tracks_before": dict(track, active_tracks=1),
        "stt_record_tracks_background": track,
        "stt_record_tracks_foreground": track,
        "stt_restart_record_tracks": dict(track, active_tracks=1),
        "stt_lifecycle_input_capture": metrics(gate),
        "tts_background_playback_continues": True,
        "tts_foreground_completion_without_new_gesture": True,
        "tts_background_coverage": exclusive_capture(gate, window(gate), background=True),
        "tts_background_capture": metrics(gate),
    }


def complete_report(gate):
    report = gate._new_report("fixture-avd")
    report.update({
        "evidence_origin": "real_adb_ui_and_host_audio",
        "state": "passed",
        "execution": {
            "run_nonce_sha256": "2" * 64,
            "started_ms": 100,
            "finished_ms": 200,
        },
        "artifact": {
            "artifact": "supplied APK",
            "sha256": "3" * 64,
            "installed_sha256": "3" * 64,
            "size": 1234,
            "source_revision": "a" * 40,
            "build_command": "fixture provenance not a build invocation",
            "manifest": {
                "package": "com.dhanuk.ovidai",
                "min_sdk": 24,
                "target_sdk": 36,
                "debuggable": False,
            },
            "signers_sha256": ["4" * 64],
            "abis": ["x86_64"],
            "zip_alignment_passed": True,
            "passed": True,
        },
        "device": {
            "avd": "fixture-avd",
            "state": "prepared",
            "emulator": True,
            "explicit_serial": True,
            "serial_sha256": "5" * 64,
            "api": 36,
            "abis": ["x86_64"],
            "real_ui_sign_in": True,
            "audio_preflight": {
                "microphone_baseline": metrics(gate, audible=False),
                "output_baseline": metrics(gate, audible=False),
                "music_stream_unmuted": True,
                "music_stream_volume": 8,
            },
        },
        "opt_in": {
            "audio_emulator": True,
            "authorized_account": True,
            "synthetic_stimuli": True,
            "authorized_server_audit": True,
            "exclusive_emulator_output": True,
        },
        "stimuli": [
            {
                "id": language_id,
                "locale": contract["locale"],
                "audio_sha256": hashlib.sha256(language_id.encode()).hexdigest(),
                "expected_transcript_sha256": hashlib.sha256(contract["locale"].encode()).hexdigest(),
                "duration_ms": 3000,
                "attestation": "synthetic_non_personal_operator_supplied",
            }
            for language_id, contract in gate.LANGUAGES.items()
        ],
        "stt": {"cases": []},
        "tts": {"cases": [tts_case(gate, language_id) for language_id in gate.LANGUAGES]},
        "lifecycle": lifecycle(gate),
        "network": {
            "scope": "authorized_ovid_backend_and_object_storage",
            "audit_authenticated": True,
            "audit_fresh": True,
            "request_count": 6,
            "json_message_requests": 6,
            "text_only_message_requests": 6,
            "recognized_transcript_post_observed": True,
            "recognized_transcript_post_sha256": "6" * 64,
            "forbidden": {
                "multipart": 0,
                "audio_mime": 0,
                "audio_fields": 0,
                "attachment_uploads": 0,
                "websocket_binary_frames": 0,
                "unclassified": 0,
            },
        },
        "storage": {
            "server_audio_objects": 0,
            "server_audio_records": 0,
            "server_audio_bytes": 0,
            "scan_complete": True,
        },
        "artifacts": ARTIFACTS.copy(),
        "blockers": [],
        "errors": [],
    })
    for stimulus in report["stimuli"]:
        report["stt"]["cases"].append({
            "id": stimulus["id"],
            "locale": stimulus["locale"],
            "stimulus_sha256": stimulus["audio_sha256"],
            "expected_transcript_sha256": stimulus["expected_transcript_sha256"],
            "offline_before": {
                "airplane_mode": True,
                "connected_networks": 0,
                "connectivity_sha256": "7" * 64,
            },
            "offline_after": {
                "airplane_mode": True,
                "connected_networks": 0,
                "connectivity_sha256": "8" * 64,
            },
            "downloaded_locale_required": True,
            "virtual_microphone_observed": True,
            "final_transcript_observed": True,
            "normalized_transcript_match": True,
            "input_capture": metrics(gate),
            "raw_audio_retained": False,
        })
    report["passed"] = True
    return report


class Round1RegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = load_harness()

    def test_store_report_writes_exclude_report_and_emit_schema_valid_json(self):
        with tempfile.TemporaryDirectory() as directory:
            store = self.gate.AudioEvidenceStore.create(Path(directory) / "evidence")
            report = self.gate._new_report("fixture-avd")
            self.gate._write_report(store, report)
            self.gate._write_report(store, report)
            published = json.loads((store.path / self.gate.REPORT_NAME).read_text())
            self.assertNotIn(self.gate.REPORT_NAME, published["artifacts"])
            self.assertNotIn(self.gate.REPORT_NAME, store.artifact_names())
            self.assertEqual(self.gate.validate_report_schema(published), [])
            self.assertFalse(published["passed"])
            store.close()

    def test_schema_invalid_pass_is_downgraded_and_cannot_exit_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            store = self.gate.AudioEvidenceStore.create(Path(directory) / "evidence")
            for name in ARTIFACTS:
                store.write_atomic(name, b"fixture sanitized artifact")
            report = complete_report(self.gate)
            report["unexpected_fixture_field"] = "must not survive"
            self.gate._write_report(store, report)
            published = json.loads((store.path / self.gate.REPORT_NAME).read_text())
            self.assertFalse(published["passed"])
            self.assertNotEqual(published["state"], "passed")
            self.assertNotEqual(self.gate.report_exit_code(published), 0)
            self.assertNotIn("unexpected_fixture_field", published)
            self.assertEqual(published["artifacts"], ARTIFACTS)
            self.assertEqual(self.gate.validate_report_schema(published), [])
            store.close()

    def test_complete_fixture_shape_matches_schema_but_is_not_device_evidence(self):
        report = complete_report(self.gate)
        self.assertEqual(self.gate.validate_acceptance(report), [])
        self.assertEqual(self.gate.validate_report_schema(report), [])
        # This is only a schema/validator fixture, never output from a device run.
        self.assertNotIn("device_run_id", report)

    def test_capture_artifacts_are_exact_not_a_subset(self):
        self.assertEqual(self.gate.validate_capture_artifacts(ARTIFACTS), [])
        self.assertTrue(self.gate.validate_capture_artifacts(ARTIFACTS + [self.gate.REPORT_NAME]))
        self.assertTrue(self.gate.validate_capture_artifacts(ARTIFACTS + [ARTIFACTS[0]]))

    def test_requested_and_resolved_punjabi_locale_are_not_manifest_claims(self):
        self.assertEqual(self.gate.validate_tts_locale(TRACE, "pa-IN"), [])
        generic = dict(TRACE, requested_locale="pa")
        self.assertIn("tts_requested_locale_mismatch", self.gate.validate_tts_locale(generic, "pa-IN"))
        other = dict(TRACE, resolved_locale="pa-PK")
        self.assertIn("tts_resolved_locale_mismatch", self.gate.validate_tts_locale(other, "pa-IN"))
        public = self.gate.sanitize_tts_trace(TRACE)
        self.assertEqual(public["requested_locale"], "pa-IN")
        self.assertEqual(public["resolved_locale"], "pa-IN")

    def test_native_trace_requires_unique_matching_utterances_and_ordered_time(self):
        raw = (
            "I/OvidTtsEvidence: v3 event=accepted logical=ovid-answer-7 native=ovid-answer-7:synthesis-3 "
            "requested=pa-IN resolved=pa-IN epochMs=1000100ch=1000100\n"
            "I/OvidTtsEvidence: v3 event=start logical=ovid-answer-7 native=ovid-answer-7:synthesis-3 "
            "requested=pa-IN resolved=pa-IN epochMs=1000500ch=1000500\n"
            "I/OvidTtsEvidence: v3 event=done logical=ovid-answer-7 native=ovid-answer-7:synthesis-3 "
            "requested=pa-IN resolved=pa-IN epochMs=1001300ch=1001300\n"
        )
        parsed = self.gate.parse_tts_evidence(raw, device_pid=4242)
        self.assertEqual(self.gate.validate_tts_trace(parsed, "pa-IN"), [])
        mismatched = raw.replace("event=done logical=ovid-answer-7", "event=done logical=ovid-answer-8")
        with self.assertRaises(self.gate.AcceptanceFailed):
            self.gate.parse_tts_evidence(mismatched)
        reordered = raw.replace("epochMs=1001300", "epochMs=1000400")
        parsed_reordered = self.gate.parse_tts_evidence(reordered, device_pid=4242)
        self.assertIn(
            "tts_timestamp_order_invalid",
            self.gate.validate_tts_trace(parsed_reordered, "pa-IN"))

    def test_only_pcm_inside_native_utterance_bounds_counts(self):
        baseline = self.gate.pcm_metrics(pcm([0] * 12000))
        inside = interval_pcm(5, 0.601, 1.199)
        measured, bounds = self.gate.utterance_capture_metrics(
            dict(CAPTURE, pcm=inside), TRACE, ANCHOR)
        self.assertEqual(self.gate.signal_errors(measured, baseline), [])
        self.assertEqual(bounds, window(self.gate))
        outside = interval_pcm(5, 1.5, 2.5)
        silent, _ = self.gate.utterance_capture_metrics(
            dict(CAPTURE, pcm=outside), TRACE, ANCHOR)
        self.assertIn("audio_signal_absent", self.gate.signal_errors(silent, baseline))

    def test_exclusive_capture_rejects_unmatched_or_incomplete_evidence(self):
        case = tts_case(self.gate)
        self.assertEqual(
            self.gate.validate_exclusive_capture(
                case["exclusive_capture"], case["capture_window"]), [])
        for field, value in (
            ("device_process_id", 999),
            ("unmatched_output_events", 1),
            ("matched_track_gaps", 1),
            ("unattributed_transitions", 1),
            ("whole_interval", False),
            ("native_callback_sequence_complete", False),
            ("max_observed_gap_ms", 1001),
            ("max_observed_gap_ms", 0),
            ("source", "unrelated.source"),
            ("manual_snapshot_count", 1),
        ):
            with self.subTest(field=field):
                broken = dict(case["exclusive_capture"], **{field: value})
                self.assertTrue(self.gate.validate_exclusive_capture(
                    broken, case["capture_window"]))
        # Two native events means exactly start plus one terminal. Neither an
        # 18-callback aggregate nor a false short gap may describe a long one.
        for changes in (
            {"event_count": 18, "native_callback_count": 18},
            {"event_count": 3, "native_callback_count": 3},
            {"max_observed_gap_ms": 799},
            {
                "last_observed_device_ms": TRACE["completed_device_ms"] + 2000,
                "max_observed_gap_ms": 1000,
            },
        ):
            with self.subTest(changes=changes):
                broken = dict(case["exclusive_capture"], **changes)
                self.assertTrue(self.gate.validate_exclusive_capture(
                    broken, case["capture_window"]))
        schema = json.loads(SCHEMA_PATH.read_text())
        fragment = dict(schema["$defs"]["exclusiveCapture"], **{"$defs": schema["$defs"]})
        self.assertEqual(self.gate.validate_report_schema(
            case["exclusive_capture"], fragment), [])
        stale_schema = dict(
            case["exclusive_capture"], event_count=18, native_callback_count=18)
        self.assertTrue(self.gate.validate_report_schema(stale_schema, fragment))
        case = tts_case(self.gate)
        case["capture_window"] = dict(case["capture_window"], pcm_start_ms=0)
        self.assertIn(
            "tts_capture_window_correlation_invalid",
            self.gate.validate_public_tts_case(case))
        wrong_metrics = tts_case(self.gate)
        wrong_metrics["output_capture"] = dict(
            wrong_metrics["output_capture"], duration_ms=1)
        self.assertIn(
            "tts_capture_metrics_window_mismatch",
            self.gate.validate_public_tts_case(wrong_metrics))

    def test_unknown_record_track_is_not_known_zero_activity(self):
        unknown = self.gate.parse_track_dump(
            "Record Tracks:\n  unfamiliar opaque record representation\n", "record")
        self.assertFalse(unknown["known"])
        self.assertEqual(unknown["active_tracks"], 0)
        empty = self.gate.parse_track_dump("Record Tracks:\n  (no tracks)\n", "record")
        self.assertTrue(empty["known"])
        self.assertEqual(empty["active_tracks"], 0)
        active = self.gate.parse_track_dump(
            "Record Tracks:\n  Track 0x01, pid 42\n    State: ACTIVE\n", "record")
        self.assertTrue(active["known"])
        self.assertEqual(active["active_tracks"], 1)
        inactive = self.gate.parse_track_dump(
            "Record Tracks:\n  Track 0x01, pid 42\n    State: INACTIVE\n", "record")
        self.assertTrue(inactive["known"])
        self.assertEqual(inactive["active_tracks"], 0)

    def test_stt_lifecycle_requires_nonempty_preserved_draft_and_direct_restart(self):
        evidence = lifecycle(self.gate)
        self.assertEqual(self.gate.validate_stt_lifecycle(evidence), [])
        for field, value in (
            ("stt_pre_background_draft_nonempty", False),
            ("stt_pre_background_draft_characters", 0),
            ("stt_pre_background_draft_sha256", hashlib.sha256(b"").hexdigest()),
            ("stt_post_foreground_draft_sha256", "0" * 64),
            ("stt_restart_draft_sha256", "0" * 64),
            ("stt_restart_gesture_observed", False),
            ("stt_restart_draft_preserved", False),
        ):
            with self.subTest(field=field):
                broken = dict(evidence, **{field: value})
                self.assertTrue(self.gate.validate_stt_lifecycle(broken))
        no_track = dict(evidence)
        no_track["stt_restart_record_tracks"] = dict(
            evidence["stt_restart_record_tracks"], active_tracks=0)
        self.assertTrue(self.gate.validate_stt_lifecycle(no_track))


if __name__ == "__main__":
    unittest.main()
