"""UNEXECUTED round-3 architectural and producer-flow regressions.

All records are synthetic. No fixture is Android/emulator/audio evidence. A valid
external exclusive-capture audit is only a future connector contract, never a
claim that the stock emulator can supply such evidence. No ADB, audio, server,
Gradle, test-device, or APK command is invoked by this source.
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
HARNESS = TOOL / "android_audio_evidence.py"
PULSE = TOOL / "android_audio_pulse_capture.py"
KEY = bytes(range(32)).hex()
NONCE = "0123456789abcdef0123456789abcdef"
TRACE = {
    "source": "ovid.release.logcat",
    "channel": "ovid.tts.utterance",
    "requested_locale": "en-IN",
    "resolved_locale": "en-IN",
    "utterance_id": "ovid-answer-3",
    "native_utterance_id": "ovid-answer-3:synthesis-1",
    "device_process_id": 4242,
    "accepted_device_ms": 1_000_100,
    "started_device_ms": 1_001_000,
    "completed_device_ms": 1_001_800,
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pcm(samples):
    return struct.pack("<" + str(len(samples)) + "h", *samples)


def tone(seconds, rate=16000):
    return pcm([
        round(12000 * math.sin(2 * math.pi * 440 * index / rate))
        for index in range(int(seconds * rate))
    ])


def silence(seconds, rate=16000):
    return pcm([0] * int(seconds * rate))


def pack_frames(pulse, *, count=24, fragment_ms=250, step_ms=None,
                first_host_us=1_000_500_000, first_mono_ns=6_000_000_000,
                latency_us=20_000, uncertainty_us=25_000, audible=False):
    frames = []
    step = fragment_ms if step_ms is None else step_ms
    for index in range(count):
        data = tone(fragment_ms / 1000) if audible and index >= 4 else silence(fragment_ms / 1000)
        frames.append(pulse.pack_record(
            index,
            first_host_us + index * step * 1000,
            first_mono_ns + index * step * 1_000_000,
            latency_us,
            uncertainty_us,
            data,
        ))
    return b"".join(frames)


def capture(gate, pulse, **kwargs):
    decoded = pulse.decode_records(pack_frames(pulse, **kwargs))
    return decoded


def anchor(offset_ms=0, uncertainty_ms=1, index=0):
    return {
        "offset_ms": offset_ms,
        "uncertainty_ms": uncertainty_ms,
        "monotonic_ns": 5_000_000_000 + index * 1_000_000_000,
        "device_wall_ms": 1_000_000 + index * 1000 + offset_ms,
        "host_wall_ms": 1_000_000 + index * 1000,
    }


def clock_series(gate, captured, offsets=(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)):
    device = StaticClockDevice(offsets)
    series = gate.ClockAnchorSeries(device)
    for index in range(len(offsets)):
        series.sample("fixture_" + str(index))
    return series.validate(captured)


class StaticClockDevice:
    def __init__(self, offsets):
        self.offsets = list(offsets)
        self.index = 0

    def clock_anchor(self):
        value = anchor(offset_ms=self.offsets.pop(0), index=self.index)
        self.index += 1
        return value


class FakeProcess:
    def __init__(self, payload):
        descriptor = os.memfd_create("ovid-fixture-pcm", flags=0)
        view = memoryview(payload)
        while view:
            view = view[os.write(descriptor, view):]
        os.lseek(descriptor, 0, os.SEEK_SET)
        self.stdout = os.fdopen(descriptor, "rb", buffering=0, closefd=True)
        self.returncode = 0

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.returncode = -9


class Round3Regression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = load(HARNESS, "android_audio_evidence_round3")
        cls.pulse = load(PULSE, "android_audio_pulse_capture_round3")
        cls.captured = capture(cls.gate, cls.pulse)

    def setUp(self):
        self.sleep = mock.patch.object(self.gate.time, "sleep", return_value=None)
        self.sleep.start()
        self.addCleanup(self.sleep.stop)
        self.bounds = self.gate.capture_window_bounds(TRACE, self.captured, clock_series(self.gate, self.captured))

    def audit(self, **changes):
        start, end = self.gate.coverage_required_window(self.bounds)
        utterance_hash = hashlib.sha256(TRACE["utterance_id"].encode()).hexdigest()
        native_hash = hashlib.sha256(TRACE["native_utterance_id"].encode()).hexdigest()
        events = [
            {"sequence": 1, "kind": "native_callback", "type": "start", "epoch_ms": 1_001_000},
            {"sequence": 2, "kind": "native_callback", "type": "complete", "epoch_ms": 1_001_800},
        ]
        value = {
            "schema": self.gate.EXCLUSIVE_CAPTURE_SCHEMA,
            "run_nonce_sha256": self.gate.sha256_text(NONCE),
            "utterance_id_sha256": utterance_hash,
            "native_utterance_id_sha256": native_hash,
            "source": "authorized_exclusive_capture_connector",
            "capture_route_sha256": "a" * 64,
            "session_exclusive": True,
            "whole_interval": True,
            "required_start_device_ms": start,
            "required_end_device_ms": end,
            "first_pcm_frame_host_us": self.captured["first_pcm_frame_host_us"],
            "last_pcm_frame_host_us": self.captured["last_pcm_frame_host_us"],
            "sample_rate": 16000,
            "channels": 1,
            "sample_format": "s16le",
            "sample_count": self.captured["sample_count"],
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
            bytes.fromhex(KEY), self.gate.canonical_json(value), hashlib.sha256).hexdigest()
        return value

    def validate_audit(self, audit):
        return self.gate.validate_exclusive_capture_audit(
            audit, KEY, NONCE, TRACE, self.captured, self.bounds)

    def test_nonpublic_uid_and_session_are_unknown_never_substituted(self):
        # v2 was the invalid privileged UID/session contract. There is no
        # anonymized-v2 fallback into a passing v3 trace.
        raw = (
            "I/OvidTtsEvidence: v2 event=accepted logical=x native=x:synthesis-1 "
            "requested=en-IN resolved=en-IN session=-1 uid=-1 epochMs=1000100\n"
        )
        with self.assertRaises(self.gate.Blocked):
            self.gate.parse_tts_evidence(raw)
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(self.audit(device_uid=4242))
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(self.audit(audio_session_id=77))
        self.assertNotIn("device_uid", TRACE)
        self.assertNotIn("audio_session_id", TRACE)

    def test_duplicate_configs_sequence_gaps_and_callbackless_evidence_block(self):
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(self.audit(duplicate_configurations=1))
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(self.audit(callback_events=[
                {"sequence": 1, "kind": "native_callback", "type": "start", "epoch_ms": 1_001_000},
                {"sequence": 3, "kind": "native_callback", "type": "complete", "epoch_ms": 1_001_800},
            ]))
        callbackless = self.audit(callback_events=[
            {"sequence": 1, "kind": "manual_snapshot", "type": "start", "epoch_ms": 1_001_000},
            {"sequence": 2, "kind": "manual_snapshot", "type": "complete", "epoch_ms": 1_001_800},
        ], native_callback_count=0, manual_snapshot_count=2)
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(callbackless)
        with self.assertRaises(self.gate.Blocked):
            self.validate_audit(self.audit(native_callback_count=0))

    def test_valid_exclusive_contract_has_no_uid_or_manual_callback_substitutes(self):
        evidence = self.validate_audit(self.audit())
        self.assertEqual(evidence["coverage_type"], "whole_interval_exclusive_capture")
        self.assertTrue(evidence["session_exclusive"])
        self.assertEqual(evidence["manual_snapshot_count"], 0)
        self.assertNotIn("device_uid", evidence)
        self.assertNotIn("audio_session_id", evidence)
        self.assertEqual(self.gate.validate_exclusive_capture(evidence, self.bounds), [])

    def test_callbackless_stock_producer_blocks_before_pcm_can_qualify(self):
        with self.assertRaisesRegex(self.gate.Blocked, "session_exclusive_capture_unavailable"):
            self.run_tts_flow(audit=None)

    def test_external_exclusive_producer_flow_is_not_a_stock_device_pass(self):
        public, lifecycle = self.run_tts_flow(audit=self.audit())
        self.assertTrue(public["exclusive_capture"]["session_exclusive"])
        self.assertEqual(lifecycle, {})
        public["offline_before"] = {
            "airplane_mode": True, "connected_networks": 0,
            "connectivity_sha256": "f" * 64,
        }
        schema = json.loads((TOOL / "android_audio_evidence.schema.json").read_text())
        fragment = dict(schema["$defs"]["ttsCase"], **{"$defs": schema["$defs"]})
        self.assertEqual(self.gate.validate_report_schema(public, fragment), [])
        self.assertNotIn("device_uid", public)
        self.assertNotIn("audio_session_id", public)

    def test_clock_steps_and_drift_between_repeated_anchors_block(self):
        with self.assertRaises(self.gate.Blocked):
            clock_series(self.gate, self.captured, offsets=(0, 0, 0, 0, 0, 50, 50, 50, 50, 50, 50, 50))
        with self.assertRaises(self.gate.Blocked):
            clock_series(self.gate, self.captured, offsets=(0, 1, 2, 4, 7, 11, 16, 22, 29, 37, 46, 56))

    def test_repeated_clock_anchor_producer_samples_before_during_after(self):
        device = SequenceClockDevice()
        series = self.gate.ClockAnchorSeries(device)
        for phase in ("before_capture", "capture_started", "capture_midpoint", "capture_completed"):
            series.sample(phase)
        evidence = series.validate(self.captured)
        self.assertEqual([call[0] for call in device.calls], [
            "before_capture", "capture_started", "capture_midpoint", "capture_completed"])
        self.assertGreaterEqual(evidence["anchor_count"], 3)
        self.assertTrue(evidence["series_validated"])
        self.assertTrue(evidence["monotonic_bracketed"])

    def test_cumulative_discontinuity_and_last_frame_sample_math_block(self):
        # Real 20 ms framing: 1 ms per-frame discrepancies accumulate. There is
        # no independent per-frame tolerance that can hide their total drift.
        with self.assertRaises(ValueError):
            self.pulse.decode_records(pack_frames(
                self.pulse, count=5, fragment_ms=20, step_ms=21,
                uncertainty_us=25_000))
        base_host = 1_000_500_000
        base_mono = 6_000_000_000
        frames = [
            self.pulse.pack_record(0, base_host, base_mono, 20_000, 25_000, silence(0.02)),
            self.pulse.pack_record(1, base_host + 20_750, base_mono + 20_750_000,
                                   20_000, 25_000, silence(0.02)),
            self.pulse.pack_record(2, base_host + 41_500, base_mono + 41_500_000,
                                   20_000, 25_000, silence(0.02)),
        ]
        with self.assertRaisesRegex(ValueError, "last PCM frame does not match actual sample timeline"):
            self.pulse.decode_records(b"".join(frames))
        for malformed in (
            self.pulse.pack_record(0, 1_000_500_000, 6_000_000_000,
                                   20_000, 25_000, silence(0.02), channels=2),
            self.pulse.pack_record(0, 1_000_500_000, 6_000_000_000,
                                   20_000, 25_000, silence(0.02), sample_format=99),
            self.pulse.pack_record(0, 1_000_500_000, 6_000_000_000,
                                   20_000, 25_000, silence(0.02), sample_rate=8000),
        ):
            with self.assertRaises(ValueError):
                self.pulse.decode_records(malformed)

    def test_pulse_producer_backdates_actual_read_and_latency_not_launch(self):
        producer = self.pulse.PulseSimple.__new__(self.pulse.PulseSimple)
        producer.lib = FakePulseLib()
        producer.handle = 1
        producer.sample_rate = 16000
        producer.fragment_bytes = 640
        with mock.patch.object(self.pulse.time, "time_ns", side_effect=[
            1_001_000_000, 1_001_002_000,
        ]), mock.patch.object(self.pulse.time, "monotonic_ns", side_effect=[
            6_000_000_000, 6_000_002_000,
        ]):
            record = producer.read_timed_record(0)
        decoded = self.pulse.decode_records(record)
        self.assertEqual(decoded["first_pcm_frame_host_us"], 961_001)
        self.assertEqual(decoded["first_pcm_frame_monotonic_ns"], 5_960_001_000)
        self.assertEqual(decoded["sample_count"], 320)
        producer.lib.latency = self.pulse.UINT64_MAX
        with self.assertRaises(RuntimeError):
            producer.read_timed_record(1)

    def test_lifecycle_producer_uses_audio_calls_for_capture_order(self):
        device = FakeSttDevice()
        audio = FakeSttAudio(self.gate)
        flow = self.gate.AudioAcceptanceFlow(device, audio, None, [], "fixture-nonce")
        evidence = flow._run_stt_lifecycle(stimulus())
        self.assertTrue(evidence["stt_restart_draft_preserved"])
        self.assertIn("finish_capture", audio.calls)
        self.assertIn("observe_foreground", device.calls)
        self.assertLess(device.calls.index("observe_foreground"), device.calls.index("start_dictation_2"))
        self.assertEqual(device.start_count, 2)

    def run_tts_flow(self, audit):
        device = SequenceClockDevice()
        audio = FakeTtsAudio(self.gate, self.pulse)
        env = {}
        result = None
        if audit is not None:
            env = {
                "OVID_AUDIO_EXCLUSIVE_CAPTURE_COMMAND": "fixture-not-executed",
                "OVID_AUDIO_EXCLUSIVE_CAPTURE_HMAC_KEY": KEY,
            }
            result = mock.Mock(returncode=0, stdout=json.dumps(audit).encode())
        flow = self.gate.AudioAcceptanceFlow(
            device, audio, None, [], NONCE, env=env)
        with mock.patch.object(self.gate.subprocess, "run", return_value=result) as runner:
            public = flow._run_tts({
                "id": "en", "locale": "en-IN",
                "public": {"duration_ms": 3000, "audio_sha256": "a" * 64},
            }, lifecycle_case=False)
        if audit is None:
            runner.assert_not_called()
        return public


class SequenceClockDevice:
    def __init__(self):
        self.calls = []
        self.index = 0

    def clock_anchor(self):
        index = self.index
        self.index += 1
        return anchor(index=index * 3)

    def sample_clock(self, phase):
        self.calls.append((phase, self.index))
        return self.clock_anchor()

    def start_playback(self, expected_locale, on_sample=None):
        started = dict(TRACE, completed_device_ms=None)
        return {"trace": started}

    def wait_playback_complete(self, started, expected_locale, on_sample=None):
        if on_sample is not None:
            on_sample("capture_midpoint")
        return dict(TRACE)


FakeTtsAudio = fixture_support.FakeTtsAudio


class FakePulseLib:
    def __init__(self):
        self.latency = 20_000

    def pa_simple_read(self, handle, buffer, size, error):
        return 0

    def pa_simple_get_latency(self, handle, error):
        return self.latency


class FakeSttDevice:
    def __init__(self):
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
        return {"known": True, "active_tracks": 0,
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
        return fixture_support.baseline_capture()

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
        "id": "en", "locale": "en-IN",
        "_expected": ["synthetic draft acceptance"],
        "public": {"duration_ms": 3000, "audio_sha256": "d" * 64},
    }


if __name__ == "__main__":
    unittest.main()
