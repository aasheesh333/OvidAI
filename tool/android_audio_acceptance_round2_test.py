"""UNEXECUTED round-2 producer-flow fixtures for Android audio acceptance.

No frame, player, timestamp, or report here is device evidence. No test invokes
ADB, FFmpeg, PulseAudio, Gradle, an emulator, audio hardware, a server, or an APK.
"""

import hashlib
import hmac
import importlib.util
import json
import os
import math
from pathlib import Path
import struct
import unittest
from unittest import mock

import android_audio_fixture_support as fixture_support


TOOL = Path(__file__).resolve().parent
HARNESS_PATH = TOOL / "android_audio_evidence.py"
PULSE_PATH = TOOL / "android_audio_pulse_capture.py"
SAMPLE_RATE = 16000
NONCE = "0123456789abcdef0123456789abcdef"
KEY = bytes(range(32)).hex()
ANCHOR = {
    "offset_ms": 0.0,
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
    "requested_locale": "en-IN",
    "resolved_locale": "en-IN",
    "utterance_id": "ovid-answer-2",
    "native_utterance_id": "ovid-answer-2:synthesis-1",
    "device_process_id": 4242,
    "accepted_device_ms": 1_000_100,
    "started_device_ms": 1_001_000,
    "completed_device_ms": 1_001_800,
}


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pcm(samples):
    return struct.pack("<" + str(len(samples)) + "h", *samples)


def tone(seconds, rate=SAMPLE_RATE):
    return pcm([
        round(12000 * math.sin(2 * math.pi * 440 * index / rate))
        for index in range(int(seconds * rate))
    ])


def silence(seconds, rate=SAMPLE_RATE):
    return pcm([0] * int(seconds * rate))


def capture_result(gate, pulse, delayed=True, audible=False):
    first_host_us = 1_000_500_000 if delayed else 1_000_000_000
    first_mono_ns = 6_000_000_000 if delayed else 5_000_000_000
    frames = []
    fragment_seconds = fixture_support.FIXTURE_FRAGMENT_MS / 1000
    for sequence in range(fixture_support.FIXTURE_FRAME_COUNT):
        chunk = tone(fragment_seconds) if audible and sequence >= 4 else silence(fragment_seconds)
        frames.append(pulse.pack_record(
            sequence=sequence,
            first_sample_host_us=(
                first_host_us + sequence * fixture_support.FIXTURE_FRAGMENT_MS * 1000),
            first_sample_monotonic_ns=(
                first_mono_ns + sequence * fixture_support.FIXTURE_FRAGMENT_MS * 1_000_000),
            source_latency_us=20_000,
            timing_uncertainty_us=25_000,
            pcm=chunk,
        ))
    return b"".join(frames)


def exclusive_audit(gate, captured, bounds, **changes):
    start, end = gate.coverage_required_window(bounds)
    events = [
        {"sequence": 1, "kind": "native_callback", "type": "start", "epoch_ms": 1_001_000},
        {"sequence": 2, "kind": "native_callback", "type": "complete", "epoch_ms": 1_001_800},
    ]
    value = {
        "schema": gate.EXCLUSIVE_CAPTURE_SCHEMA,
        "run_nonce_sha256": gate.sha256_text(NONCE),
        "utterance_id_sha256": gate.sha256_text(TRACE["utterance_id"]),
        "native_utterance_id_sha256": gate.sha256_text(TRACE["native_utterance_id"]),
        "source": "authorized_exclusive_capture_connector",
        "capture_route_sha256": "a" * 64,
        "session_exclusive": True,
        "whole_interval": True,
        "required_start_device_ms": start,
        "required_end_device_ms": end,
        "first_pcm_frame_host_us": captured["first_pcm_frame_host_us"],
        "last_pcm_frame_host_us": captured["last_pcm_frame_host_us"],
        "sample_rate": 16000,
        "channels": 1,
        "sample_format": "s16le",
        "sample_count": captured["sample_count"],
        "callback_events": events,
        "native_callback_count": len(events),
        "manual_snapshot_count": 0,
        "unattributed_transitions": 0,
        "unmatched_output_events": 0,
        "matched_track_gaps": 0,
        "duplicate_configurations": 0,
        "queried_ms": TRACE["completed_device_ms"],
    }
    value.update(changes)
    value.pop("signature", None)
    value["signature"] = hmac.new(
        bytes.fromhex(KEY), gate.canonical_json(value), hashlib.sha256).hexdigest()
    return value


class FakeProcess:
    def __init__(self, payload):
        self.stdout = fixture_support.memory_pcm(payload)
        self.returncode = 0

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.returncode = -9


class Round2Fixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = load_module(HARNESS_PATH, "android_audio_evidence_round2")
        cls.pulse = load_module(PULSE_PATH, "android_audio_pulse_capture_round2")

    def setUp(self):
        self.sleep = mock.patch.object(self.gate.time, "sleep", return_value=None)
        self.sleep.start()
        self.addCleanup(self.sleep.stop)

    def host_audio(self):
        with mock.patch.object(self.gate.shutil, "which", return_value="/fixture/ffmpeg"):
            return self.gate.HostAudio({
                "OVID_AUDIO_MIC_SINK": "fixture-sink",
                "OVID_AUDIO_MIC_MONITOR": "fixture-mic",
                "OVID_AUDIO_OUTPUT_SOURCE": "fixture-output",
            })

    def test_delayed_first_pcm_frame_not_process_launch_is_sample_zero(self):
        audio = self.host_audio()
        payload = capture_result(self.gate, self.pulse, delayed=True)
        self.assertEqual(len(payload), 193_536)
        self.assertEqual(fixture_support.FIXTURE_PCM_BYTES, 192_000)
        with mock.patch.object(self.gate.subprocess, "Popen", return_value=FakeProcess(payload)):
            capture = audio.start_capture(
                "fixture-output", fixture_support.FIXTURE_CAPTURE_SECONDS)
            result = audio.finish_capture(capture)
        self.assertEqual(capture["seconds"], 6)
        self.assertEqual(capture["expected_max"], 333_440)
        self.assertEqual(result["sample_count"], 96_000)
        self.assertEqual(len(result["pcm"]), 192_000)
        self.assertEqual(result["first_pcm_frame_host_us"], 1_000_500_000)
        self.assertEqual(result["first_pcm_frame_monotonic_ns"], 6_000_000_000)
        self.assertEqual(result["first_pcm_frame_uncertainty_us"], 25_000)
        self.assertEqual(result["source_latency_us"], 20_000)
        self.assertNotEqual(result["first_pcm_frame_monotonic_ns"], capture["process_started_ns"])
        bounds = self.gate.capture_window_bounds(TRACE, result, ANCHOR)
        self.assertEqual(bounds["first_pcm_frame_device_ms"], 1_000_500)
        self.assertEqual(bounds["clock_uncertainty_us"], 28_000)
        self.assertEqual(bounds["pcm_start_ms"], 628)
        self.assertEqual(bounds["pcm_end_ms"], 1172)

    def test_unframed_or_discontinuous_capture_never_falls_back_to_launch_time(self):
        for payload in (b"not-a-pcm-frame", capture_result(self.gate, self.pulse)[:-3]):
            with self.subTest(length=len(payload)):
                audio = self.host_audio()
                with mock.patch.object(self.gate.subprocess, "Popen", return_value=FakeProcess(payload)):
                    capture = audio.start_capture(
                        "fixture-output", fixture_support.FIXTURE_CAPTURE_SECONDS)
                    with self.assertRaisesRegex(
                            self.gate.Blocked, "audio_capture_timing_unavailable"):
                        audio.finish_capture(capture)

    def test_excessive_clock_offset_blocks_instead_of_shifting_window(self):
        result = self.pulse.decode_records(capture_result(self.gate, self.pulse))
        with self.assertRaises(self.gate.Blocked):
            self.gate.capture_window_bounds(TRACE, result, dict(ANCHOR, offset_ms=5001))

    def test_discontinuous_frame_timing_is_blocked(self):
        records = [
            self.pulse.pack_record(0, 1_000_000_000, 5_000_000_000, 20_000, 25_000, silence(0.25)),
            self.pulse.pack_record(1, 1_001_000_000, 5_250_000_000, 20_000, 25_000, silence(0.25)),
        ]
        audio = self.host_audio()
        with mock.patch.object(self.gate.subprocess, "Popen", return_value=FakeProcess(b"".join(records))):
            capture = audio.start_capture("fixture-output", 1)
            with self.assertRaisesRegex(
                    self.gate.Blocked, "audio_capture_timing_unavailable"):
                audio.finish_capture(capture)

    def test_unrelated_energy_after_initial_ovid_trace_is_rejected_by_producer_flow(self):
        with self.assertRaises(self.gate.AcceptanceFailed):
            self.run_tts_flow(unmatched_output_events=1)

    def test_whole_interval_sequence_gap_or_unattributed_transition_blocks(self):
        for changes in (
            {"callback_events": [
                {"sequence": 1, "kind": "native_callback", "type": "start", "epoch_ms": 1_001_000},
                {"sequence": 3, "kind": "native_callback", "type": "complete", "epoch_ms": 1_001_800},
            ]},
            {"unattributed_transitions": 1},
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(self.gate.Blocked):
                    self.run_tts_flow(**changes)

    def test_valid_producer_flow_uses_coverage_not_one_shot_track(self):
        public, lifecycle = self.run_tts_flow()
        self.assertTrue(public["exclusive_capture"]["whole_interval"])
        self.assertEqual(public["exclusive_capture"]["unmatched_output_events"], 0)
        self.assertEqual(public["exclusive_capture"]["matched_track_gaps"], 0)
        self.assertNotIn("playback_observation", public)
        self.assertEqual(lifecycle, {})
        public["offline_before"] = {
            "airplane_mode": True,
            "connected_networks": 0,
            "connectivity_sha256": "f" * 64,
        }
        schema = json.loads((TOOL / "android_audio_evidence.schema.json").read_text())
        fragment = dict(schema["$defs"]["ttsCase"], **{"$defs": schema["$defs"]})
        self.assertEqual(self.gate.validate_report_schema(public, fragment), [])

    def test_mixed_known_and_unknown_record_sections_are_unknown(self):
        valid = "  Track 0x01, pid 42\n    State: INACTIVE\n"
        for residue in (
            "  unrecognized before\n" + valid,
            valid + "  unrecognized after\n",
            valid + "Opaque: unknown\n",
            valid + "  Track 0x02, pid 43\n",
        ):
            with self.subTest(residue=residue):
                parsed = self.gate.parse_track_dump("Record Tracks:\n" + residue, "record")
                self.assertFalse(parsed["known"])
                self.assertEqual(parsed["active_tracks"], 0)

    def test_lifecycle_producer_sequences_partial_background_and_direct_restart(self):
        device = FakeSttDevice()
        audio = FakeSttAudio(self.gate)
        flow = self.gate.AudioAcceptanceFlow(device, audio, None, [], "fixture-nonce")
        evidence = flow._run_stt_lifecycle(stimulus())
        self.assertTrue(evidence["stt_pre_background_draft_nonempty"])
        self.assertTrue(evidence["stt_restart_gesture_observed"])
        self.assertTrue(evidence["stt_restart_draft_preserved"])
        self.assertEqual(device.start_count, 2)
        self.assertEqual(device.stop_count, 1)
        self.assertLess(device.calls.index("background"), device.calls.index("observe_background"))
        self.assertLess(device.calls.index("observe_background"), device.calls.index("foreground"))
        self.assertIn("finish_capture", audio.calls)
        self.assertIn("observe_foreground", device.calls)
        self.assertLess(device.calls.index("observe_foreground"), device.calls.index("start_dictation_2"))
        self.assertEqual(device.calls[-1], "stop_dictation")

    def test_unknown_background_record_state_stops_lifecycle_before_restart(self):
        device = FakeSttDevice(unknown_background=True)
        audio = FakeSttAudio(self.gate)
        flow = self.gate.AudioAcceptanceFlow(device, audio, None, [], "fixture-nonce")
        with self.assertRaises(self.gate.Blocked):
            flow._run_stt_lifecycle(stimulus())
        self.assertEqual(device.start_count, 1)
        self.assertNotIn("foreground", device.calls)
        self.assertNotIn("start_dictation_2", device.calls)

    def run_tts_flow(self, **changes):
        device = FakeTtsDevice()
        audio = FakeTtsAudio(self.gate, self.pulse)
        captured = self.pulse.decode_records(audio.payload)
        bounds = self.gate.capture_window_bounds(TRACE, captured, ANCHOR)
        audit = exclusive_audit(self.gate, captured, bounds, **changes)
        env = {
            "OVID_AUDIO_EXCLUSIVE_CAPTURE_COMMAND": "fixture-not-executed",
            "OVID_AUDIO_EXCLUSIVE_CAPTURE_HMAC_KEY": KEY,
        }
        flow = self.gate.AudioAcceptanceFlow(
            device, audio, None, [], NONCE, env=env)
        result = mock.Mock(returncode=0, stdout=json.dumps(audit).encode())
        with mock.patch.object(self.gate.subprocess, "run", return_value=result):
            return flow._run_tts({
                "id": "en",
                "locale": "en-IN",
                "public": {"duration_ms": 3000, "audio_sha256": "a" * 64},
            }, lifecycle_case=False)


class FakeTtsDevice:
    def __init__(self, journal=None):
        self.journal = journal
        self.calls = []
        self.clock_index = 0

    def clock_anchor(self):
        index = self.clock_index
        self.clock_index += 1
        return {
            "offset_ms": 0,
            "uncertainty_ms": 1,
            "monotonic_ns": 5_000_000_000 + index * 3_000_000_000,
            "device_wall_ms": 1_000_000 + index * 3000,
            "host_wall_ms": 1_000_000 + index * 3000,
        }

    def start_playback(self, expected_locale, on_sample=None):
        self.calls.append("start_playback")
        started = dict(TRACE, completed_device_ms=None)
        return {"trace": started}

    def wait_playback_complete(self, started, expected_locale, on_sample=None):
        self.calls.append("wait_complete")
        return dict(TRACE)

    def observe_tracks(self, *args, **kwargs):
        raise AssertionError("one-shot AudioFlinger playback snapshots must not be used")


FakeTtsAudio = fixture_support.FakeTtsAudio


class FakeSttDevice:
    def __init__(self, unknown_background=False):
        self.unknown_background = unknown_background
        self.calls = []
        self.start_count = 0
        self.stop_count = 0
        self.backgrounded = False

    def clear_composer(self):
        self.calls.append("clear_composer")

    def start_dictation(self):
        self.start_count += 1
        self.calls.append("start_dictation_" + str(self.start_count))
        return {"known": True, "active_tracks": 1, "source": "android.media.audio_flinger",
                "channel": "ovid.stt.record", "observed_monotonic_ns": 1,
                "dump_sha256": "b" * 64}

    def wait_partial_draft(self, alternatives):
        self.calls.append("wait_partial_draft")
        return "synthetic draft"

    def background(self):
        self.backgrounded = True
        self.calls.append("background")

    def foreground(self):
        self.backgrounded = False
        self.calls.append("foreground")

    def require_foreground(self, expected):
        self.calls.append("require_" + str(expected))

    def observe_tracks(self, kind):
        self.calls.append("observe_" + ("background" if self.backgrounded else "foreground"))
        known = not (self.backgrounded and self.unknown_background)
        return {"known": known, "active_tracks": 0,
                "source": "android.media.audio_flinger", "channel": "ovid.stt.record",
                "observed_monotonic_ns": 2, "dump_sha256": "c" * 64}

    def composer_text(self):
        self.calls.append("composer_text")
        return "synthetic draft"

    def wait_label(self, labels, timeout=15):
        self.calls.append("wait_label")

    def stop_dictation(self):
        self.stop_count += 1
        self.calls.append("stop_dictation")


class FakeSttAudio:
    def __init__(self, gate):
        self.gate = gate
        self.mic_monitor = "fixture-mic"
        self.calls = []

    def capture(self, source):
        self.calls.append("capture_baseline")
        return {"pcm": silence(0.75)}

    def start_capture(self, source, seconds):
        self.calls.append("start_capture")
        return {"fake": True}

    def start_play(self, stimulus):
        self.calls.append("start_play")
        return object()

    def finish_play(self, process):
        self.calls.append("finish_play")

    def finish_capture(self, capture):
        self.calls.append("finish_capture")
        return {"pcm": tone(1)}


def stimulus():
    return {
        "id": "en",
        "locale": "en-IN",
        "_expected": ["synthetic draft acceptance"],
        "public": {"duration_ms": 3000, "audio_sha256": "d" * 64},
    }


if __name__ == "__main__":
    unittest.main()
