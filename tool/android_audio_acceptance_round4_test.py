"""UNEXECUTED round-4 regressions for Android audio acceptance.

All inputs are synthetic fixtures, never device evidence. No test invokes ADB,
audio hardware, PulseAudio, a server, an emulator, Gradle, or an APK build.
"""

import hashlib
import hmac
import importlib.util
import math
from pathlib import Path
import struct
import unittest
from unittest import mock

import android_audio_fixture_support as fixture_support


TOOL = Path(__file__).resolve().parent
HARNESS_PATH = TOOL / "android_audio_evidence.py"
PULSE_PATH = TOOL / "android_audio_pulse_capture.py"
KEY = bytes(range(32)).hex()
NONCE = "0123456789abcdef0123456789abcdef"
TRACE = {
    "source": "ovid.release.logcat",
    "channel": "ovid.tts.utterance",
    "requested_locale": "en-IN",
    "resolved_locale": "en-IN",
    "utterance_id": "ovid-answer-4",
    "native_utterance_id": "ovid-answer-4:synthesis-1",
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


def packed_frames(pulse, *, count=24, fragment_ms=250, audible=False):
    frames = []
    for index in range(count):
        data = tone(fragment_ms / 1000) if audible and index >= 4 else silence(fragment_ms / 1000)
        frames.append(pulse.pack_record(
            index,
            1_000_500_000 + index * fragment_ms * 1000,
            6_000_000_000 + index * fragment_ms * 1_000_000,
            20_000,
            25_000,
            data,
        ))
    return b"".join(frames)


def repeated_anchor(index):
    return {
        "offset_ms": 0,
        "uncertainty_ms": 1,
        "series_validated": True,
        "clock_model": "repeated_bounded_anchors",
        "anchor_count": 4,
        "monotonic_bracketed": True,
        "max_offset_step_ms": 0,
        "max_anchor_gap_ms": 1000,
    }


ANCHOR = repeated_anchor(0)


FakeProcess = fixture_support.FakeProcess
ControlledClock = fixture_support.ControlledClock


class Round4Regression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = load(HARNESS_PATH, "android_audio_evidence_round4")
        cls.pulse = load(PULSE_PATH, "android_audio_pulse_capture_round4")
        cls.captured = cls.pulse.decode_records(packed_frames(cls.pulse))
        cls.bounds = cls.gate.capture_window_bounds(TRACE, cls.captured, ANCHOR)

    def setUp(self):
        self.sleep = mock.patch.object(self.gate.time, "sleep", return_value=None)
        self.sleep.start()
        self.addCleanup(self.sleep.stop)

    def audit(self, events=None, **changes):
        start, end = self.gate.coverage_required_window(self.bounds)
        events = events or [
            {"sequence": 1, "kind": "native_callback", "type": "start", "epoch_ms": 1_001_000},
            {"sequence": 2, "kind": "native_callback", "type": "complete", "epoch_ms": 1_001_800},
        ]
        value = {
            "schema": self.gate.EXCLUSIVE_CAPTURE_SCHEMA,
            "run_nonce_sha256": self.gate.sha256_text(NONCE),
            "utterance_id_sha256": self.gate.sha256_text(TRACE["utterance_id"]),
            "native_utterance_id_sha256": self.gate.sha256_text(TRACE["native_utterance_id"]),
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

    def validate(self, audit):
        return self.gate.validate_exclusive_capture_audit(
            audit, KEY, NONCE, TRACE, self.captured, self.bounds)

    def test_native_callbacks_require_one_ordered_start_and_terminal(self):
        def event(sequence, event_type, epoch_ms, kind="native_callback"):
            return {
                "sequence": sequence,
                "kind": kind,
                "type": event_type,
                "epoch_ms": epoch_ms,
            }

        valid = self.validate(self.audit())
        self.assertEqual(valid["native_callback_count"], 2)
        self.assertEqual(valid["manual_snapshot_count"], 0)
        self.assertEqual(valid["max_observed_gap_ms"], 800)
        self.assertTrue(valid["utterance_start_callback_observed"])
        self.assertTrue(valid["utterance_completion_callback_observed"])
        stopped = self.audit(events=[
            event(1, "start", 1_001_000),
            event(2, "stop", 1_001_800),
        ])
        self.assertEqual(self.validate(stopped)["native_callback_count"], 2)

        # Every counterexample fits the 1000 ms gap budget. These isolate
        # lifecycle cardinality/order rather than tripping the liveness gap.
        invalid_lifecycles = (
            [  # repeated start
                event(1, "start", 1_001_000),
                event(2, "start", 1_001_400),
                event(3, "complete", 1_001_800),
            ],
            [  # terminal before start
                event(1, "complete", 1_001_800),
                event(2, "start", 1_001_900),
            ],
            [  # post-terminal event
                event(1, "start", 1_001_000),
                event(2, "complete", 1_001_800),
                event(3, "stop", 1_001_900),
            ],
            [  # repeated terminal
                event(1, "start", 1_001_000),
                event(2, "complete", 1_001_800),
                event(3, "complete", 1_001_900),
            ],
        )
        for events in invalid_lifecycles:
            with self.subTest(events=events):
                with self.assertRaises(self.gate.Blocked):
                    self.validate(self.audit(events=events))

        # Neither liveness nor manual records can repair lifecycle or coverage.
        for events in (
            [
                event(1, "start", 1_001_000),
                event(2, "liveness", 1_001_200),
                event(3, "complete", 1_001_800),
            ],
            [
                event(1, "start", 1_001_000, kind="manual_snapshot"),
                event(2, "complete", 1_001_800, kind="manual_snapshot"),
            ],
        ):
            with self.subTest(events=events):
                with self.assertRaises(self.gate.Blocked):
                    self.validate(self.audit(events=events))

    def test_v2_header_has_exactly_twelve_matching_values_and_blocks_malformed(self):
        header = self.pulse.HEADER
        self.assertEqual(header.format, "<8sHHIHHIQqQQQ")
        self.assertEqual(header.size, 64)
        self.assertEqual(struct.calcsize(header.format), 64)
        # The exact 12 logical values, in wire order. Six producer arguments
        # plus six fixed header values must unpack to this identical tuple.
        expected = (
            self.pulse.MAGIC, self.pulse.VERSION, 64, 16000, 1,
            self.pulse.SAMPLE_FORMAT_S16LE, 0,
            1_000_500_000, 6_000_000_000, 20_000, 25_000, 640,
        )
        self.assertEqual(len(expected), 12)
        record = self.pulse.pack_record(
            expected[6], expected[7], expected[8], expected[9], expected[10],
            silence(0.02))
        self.assertEqual(len(record), 64 + 640)
        fields = header.unpack_from(record)
        self.assertEqual(len(fields), 12)
        self.assertEqual(fields, expected)
        self.assertEqual(record[:header.size], header.pack(*expected))
        decoded = self.pulse.decode_records(record)
        self.assertEqual(decoded["pcm"], silence(0.02))
        self.assertEqual(decoded["sample_count"], 320)
        self.assertEqual(decoded["first_pcm_frame_host_us"], expected[7])
        self.assertEqual(decoded["first_pcm_frame_monotonic_ns"], expected[8])
        self.assertEqual(decoded["source_latency_us"], expected[9])
        bad_magic = bytearray(record)
        bad_magic[:8] = b"NOTPCM02"
        malformed_records = {
            "truncated_header": record[:63],
            "truncated_pcm": record[:-1],
            "declared_pcm_missing": record[:64] + b"truncated",
            "malformed_magic": bytes(bad_magic),
        }
        for name, malformed in malformed_records.items():
            with self.subTest(case=name):
                with self.assertRaises(ValueError):
                    self.pulse.decode_records(malformed)

    def test_blocking_finish_and_shared_fake_capture_contract(self):
        clock = ControlledClock()
        process = FakeProcess(
            clock, packed_frames(self.pulse, audible=True), exit_ns=17_000_000_000)
        audio = self.host_audio()
        with mock.patch.object(self.gate.subprocess, "Popen", return_value=process), \
                mock.patch.object(self.gate.time, "monotonic_ns", side_effect=clock.monotonic_ns), \
                mock.patch.object(self.gate.time, "monotonic", side_effect=clock.monotonic):
            capture = audio.start_capture("fixture-output", 20)
            series = self.gate.ClockAnchorSeries(clock)
            series.sample("before_capture_finish")

            def intermediate(phase):
                clock.now += 2_000_000_000
                series.sample(phase)

            captured = audio.finish_capture(capture, on_wait=intermediate)
            # Model the real final anchor query after the last residual-wait
            # sample; equal adjacent monotonic anchors are never valid.
            clock.now += 1_000_000_000
            series.sample("after_capture")
            anchor = series.validate(captured)
        timestamps = [entry["monotonic_ns"] for entry in series.anchors]
        self.assertEqual(len(timestamps), len(set(timestamps)))
        self.assertGreater(timestamps[-1], timestamps[-2])
        self.assertEqual(captured["sample_count"], 96_000)
        self.assertGreaterEqual(anchor["anchor_count"], 5)
        self.assertLessEqual(anchor["max_anchor_gap_ms"], 4000)
        self.assertTrue(anchor["monotonic_bracketed"])
        phases = [entry["phase"] for entry in series.anchors]
        self.assertGreaterEqual(phases.count("capture_finish_wait"), 2)
        self.assertEqual(audio.processes, set())
        self.assertEqual(audio.captures, {})
        self.assertTrue(process.stdout.closed)
        self.assertNotIn("reader", capture)

        # The shared round-2/3 fake uses this same real finish/close boundary,
        # accepts on_wait, owns both resource collections, and returns raw PCM.
        shared = fixture_support.FakeTtsAudio(self.gate, self.pulse)
        self.assertEqual(len(shared.payload), 193_536)
        self.assertEqual(fixture_support.FIXTURE_PCM_BYTES, 192_000)
        self.assertEqual(shared.processes, set())
        self.assertEqual(shared.captures, {})
        baseline = shared.capture("fixture-output")
        self.assertEqual(set(baseline), {"pcm"})
        self.assertEqual(baseline["pcm"], silence(0.75))
        shared_capture = shared.start_capture(
            "fixture-output", fixture_support.FIXTURE_CAPTURE_SECONDS)
        shared_result = shared.finish_capture(
            shared_capture, on_wait=lambda phase: None)
        self.assertEqual(shared_capture["seconds"], 6)
        self.assertEqual(shared.last_capture["expected_max"], 333_440)
        self.assertIn("pcm", shared_result)
        self.assertNotIn("peak", shared_result)
        self.assertEqual(shared_result["sample_count"], 96_000)
        self.assertEqual(len(shared_result["pcm"]), 192_000)
        self.assertEqual(shared.processes, set())
        self.assertEqual(shared.captures, {})
        self.assertTrue(shared.last_process.stdout.closed)

    def test_finish_failure_kills_reaps_and_closes_without_thread_leaks(self):
        clock = ControlledClock()
        process = FakeProcess(
            clock, packed_frames(self.pulse), exit_ns=17_000_000_000)
        audio = self.host_audio()
        with mock.patch.object(self.gate.subprocess, "Popen", return_value=process), \
                mock.patch.object(self.gate.time, "monotonic_ns", side_effect=clock.monotonic_ns), \
                mock.patch.object(self.gate.time, "monotonic", side_effect=clock.monotonic):
            capture = audio.start_capture("fixture-output", 20)
            series = self.gate.ClockAnchorSeries(clock)
            series.sample("before_capture_finish")
            calls = []

            def fail_after_samples(phase):
                calls.append(phase)
                clock.now += 2_000_000_000
                series.sample(phase)
                if len(calls) == 3:
                    raise self.gate.Blocked("clock_step_detected")

            with self.assertRaises(self.gate.Blocked):
                audio.finish_capture(capture, on_wait=fail_after_samples)
        self.assertTrue(process.killed)
        self.assertEqual(audio.processes, set())
        self.assertEqual(audio.captures, {})
        self.assertTrue(process.stdout.closed)
        self.assertNotIn("reader", capture)

    def test_pulse_units_match_producer_arithmetic_exactly(self):
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

    def test_final_frame_adverse_case_isolates_end_to_end_not_per_frame_gate(self):
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

    def host_audio(self):
        with mock.patch.object(self.gate.shutil, "which", return_value="/fixture/ffmpeg"):
            return self.gate.HostAudio({
                "OVID_AUDIO_MIC_SINK": "fixture-sink",
                "OVID_AUDIO_MIC_MONITOR": "fixture-mic",
                "OVID_AUDIO_OUTPUT_SOURCE": "fixture-output",
            })


class FakePulseLib:
    def pa_simple_read(self, handle, buffer, size, error):
        return 0

    def pa_simple_get_latency(self, handle, error):
        return 20_000


if __name__ == "__main__":
    unittest.main()
