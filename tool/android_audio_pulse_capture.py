#!/usr/bin/env python3
"""PulseAudio PCM capture with measured per-frame timing metadata.

AUTHORED FOR LATER EXECUTION. This module is never run during the heavy-command
pause. It writes only length-prefixed records to stdout; PCM is never persisted
to a file. The parent acceptance harness keeps those records in memory and
retains only timing metadata, signal metrics, and hashes.

Timing is not based on process launch. Each PCM block is backdated from the
PulseAudio record-latency measurement after its read. The first returned block
therefore has a measured source-relative timestamp and conservative buffering
uncertainty. Missing/invalid latency is fatal; there is no silent time fallback.
"""

import argparse
import ctypes
import ctypes.util
import math
import os
import struct
import sys
import time


MAGIC = b"OVPCM002"
VERSION = 2
# PCM v2 little-endian/no-alignment layout: EXACTLY 12 logical values and
# 12 descriptors, 64 bytes total (24 bytes through sequence, then five 8-byte
# values). pack_record supplies and decode_records unpacks these same values:
#  1 magic=8s, 2 version=H, 3 header_size=H, 4 sample_rate=I,
#  5 channels=H, 6 sample_format=H, 7 sequence=I,
#  8 first_sample_host_us=Q, 9 first_sample_monotonic_ns=q,
# 10 source_latency_us=Q, 11 timing_uncertainty_us=Q, 12 pcm_size=Q.
HEADER = struct.Struct("<8sHHIHHIQqQQQ")
assert HEADER.size == 64
SAMPLE_RATE = 16000
SAMPLE_CHANNELS = 1
SAMPLE_FORMAT_S16LE = 1
PA_SAMPLE_FORMAT_S16LE = 3
PA_STREAM_RECORD = 2
UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1
MAX_RECORD_BYTES = 128 * 1024
MAX_CAPTURE_SECONDS = 120
# Per-frame jitter cannot hide an accumulating timestamp/PCM mismatch.
MAX_FRAME_DISCONTINUITY_US = 1000
MAX_CUMULATIVE_DISCONTINUITY_US = 2000
MAX_END_TO_END_DISCONTINUITY_US = 1000


def chunk_duration_us(pcm_bytes, sample_rate=SAMPLE_RATE, channels=SAMPLE_CHANNELS):
    if (pcm_bytes <= 0 or pcm_bytes % (2 * channels)
            or sample_rate <= 0 or channels <= 0):
        raise ValueError("invalid PCM chunk")
    return math.ceil(
        (pcm_bytes // (2 * channels)) * 1_000_000 / sample_rate)


def pack_record(sequence, first_sample_host_us, first_sample_monotonic_ns,
                source_latency_us, timing_uncertainty_us, pcm,
                sample_rate=SAMPLE_RATE, channels=SAMPLE_CHANNELS,
                sample_format=SAMPLE_FORMAT_S16LE):
    """Framing used by the real producer and independent synthetic fixtures."""
    if not pcm or len(pcm) > MAX_RECORD_BYTES:
        raise ValueError("invalid PCM record size")
    if (type(sequence) is not int or sequence < 0
            or type(first_sample_host_us) is not int or first_sample_host_us <= 0
            or type(first_sample_monotonic_ns) is not int or first_sample_monotonic_ns <= 0
            or type(source_latency_us) is not int or source_latency_us < 0
            or type(timing_uncertainty_us) is not int or timing_uncertainty_us <= 0
            or type(sample_rate) is not int or sample_rate <= 0
            or type(channels) is not int or channels <= 0
            or type(sample_format) is not int or sample_format <= 0):
        raise ValueError("invalid PCM timing metadata")
    chunk_duration_us(len(pcm), sample_rate, channels)
    return HEADER.pack(
        MAGIC, VERSION, HEADER.size, sample_rate, channels, sample_format,
        sequence, first_sample_host_us, first_sample_monotonic_ns,
        source_latency_us, timing_uncertainty_us, len(pcm)) + pcm


def decode_records(payload, expected_sample_rate=SAMPLE_RATE,
                   expected_channels=SAMPLE_CHANNELS,
                   expected_format=SAMPLE_FORMAT_S16LE):
    """Return PCM only with continuous, format-checked measured timing."""
    records = []
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < HEADER.size:
            raise ValueError("truncated PCM timing header")
        fields = HEADER.unpack_from(payload, offset)
        (magic, version, header_size, rate, channels, sample_format,
         sequence, host_us, mono_ns, latency_us, uncertainty_us, size) = fields
        if (magic != MAGIC or version != VERSION or header_size != HEADER.size
                or rate != expected_sample_rate or channels != expected_channels
                or sample_format != expected_format
                or size <= 0 or size > MAX_RECORD_BYTES
                or size % (2 * channels)):
            raise ValueError("invalid PCM timing header")
        end = offset + HEADER.size + size
        if end > len(payload):
            raise ValueError("truncated PCM record")
        records.append({
            "sequence": sequence,
            "host_us": host_us,
            "mono_ns": mono_ns,
            "latency_us": latency_us,
            "uncertainty_us": uncertainty_us,
            "pcm": payload[offset + HEADER.size:end],
            "channels": channels,
            "sample_format": sample_format,
            "sample_rate": rate,
        })
        offset = end
    if not records:
        raise ValueError("no timed PCM records")
    pcm_parts = []
    previous = None
    host_discontinuity = 0
    mono_discontinuity = 0
    sample_count = 0
    for index, record in enumerate(records):
        if record["sequence"] != index:
            raise ValueError("PCM record sequence is not contiguous")
        if (record["host_us"] <= 0 or record["mono_ns"] <= 0
                or record["latency_us"] < 0 or record["uncertainty_us"] <= 0
                or record["uncertainty_us"] > 2_000_000):
            raise ValueError("invalid PCM record timing")
        record["duration_us"] = chunk_duration_us(
            len(record["pcm"]), record["sample_rate"], record["channels"])
        record["sample_count"] = len(record["pcm"]) // (2 * record["channels"])
        sample_count += record["sample_count"]
        if previous is not None:
            expected_host = previous["host_us"] + previous["duration_us"]
            expected_mono = previous["mono_ns"] + previous["duration_us"] * 1000
            host_error = record["host_us"] - expected_host
            mono_error = record["mono_ns"] - expected_mono
            if (abs(host_error) > MAX_FRAME_DISCONTINUITY_US
                    or abs(mono_error) > MAX_FRAME_DISCONTINUITY_US * 1000):
                raise ValueError("PCM record timing is discontinuous")
            host_discontinuity += abs(host_error)
            mono_discontinuity += abs(mono_error) // 1000
            if (host_discontinuity > MAX_CUMULATIVE_DISCONTINUITY_US
                    or mono_discontinuity > MAX_CUMULATIVE_DISCONTINUITY_US):
                raise ValueError("cumulative PCM discontinuity exceeds budget")
        pcm_parts.append(record["pcm"])
        previous = record
    first = records[0]
    last = records[-1]
    pcm = b"".join(pcm_parts)
    expected_samples = len(pcm) // (2 * expected_channels)
    if expected_samples != sample_count:
        raise ValueError("PCM sample count mismatch")
    expected_duration_us = sample_count * 1_000_000 / expected_sample_rate
    last_host_us = last["host_us"] + last["duration_us"]
    last_mono_ns = last["mono_ns"] + last["duration_us"] * 1000
    host_end_error = abs(
        (last_host_us - first["host_us"]) - expected_duration_us)
    mono_end_error = abs(
        (last_mono_ns - first["mono_ns"]) / 1000 - expected_duration_us)
    if (host_end_error > MAX_END_TO_END_DISCONTINUITY_US
            or mono_end_error > MAX_END_TO_END_DISCONTINUITY_US):
        raise ValueError("last PCM frame does not match actual sample timeline")
    timeline = {
        "timing_source": "pulse_simple_latency_backdated_frames",
        "first_pcm_frame_host_us": first["host_us"],
        "first_pcm_frame_monotonic_ns": first["mono_ns"],
        "first_pcm_frame_uncertainty_us": max(
            record["uncertainty_us"] for record in records),
        "source_latency_us": first["latency_us"],
        "max_source_latency_us": max(record["latency_us"] for record in records),
        "capture_timing_uncertainty_us": max(
            record["uncertainty_us"] for record in records),
        "frame_count": len(records),
        "sample_count": sample_count,
        "sample_rate": expected_sample_rate,
        "channels": expected_channels,
        "sample_format": "s16le",
        "last_pcm_frame_host_us": last_host_us,
        "last_pcm_frame_monotonic_ns": last_mono_ns,
        "cumulative_discontinuity_us": max(host_discontinuity, mono_discontinuity),
        "end_to_end_discontinuity_us": max(host_end_error, mono_end_error),
        "last_emitted_frame_timestamp_validated": True,
    }
    return {"pcm": pcm, **timeline}


class PaSampleSpec(ctypes.Structure):
    _fields_ = [
        ("format", ctypes.c_int),
        ("rate", ctypes.c_uint32),
        ("channels", ctypes.c_uint8),
    ]


class PaBufferAttr(ctypes.Structure):
    _fields_ = [
        ("maxlength", ctypes.c_uint32),
        ("tlength", ctypes.c_uint32),
        ("prebuf", ctypes.c_uint32),
        ("minreq", ctypes.c_uint32),
        ("fragsize", ctypes.c_uint32),
    ]


class PulseSimple:
    """Thin libpulse-simple boundary; unavailable timing is never replaced."""

    def __init__(self, source, sample_rate, fragment_ms):
        if sys.byteorder != "little":
            raise RuntimeError("little-endian host PCM is required")
        library = ctypes.util.find_library("pulse-simple")
        if not library:
            raise RuntimeError("libpulse-simple is unavailable")
        self.lib = ctypes.CDLL(library)
        self.lib.pa_simple_new.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
            ctypes.c_char_p, ctypes.POINTER(PaSampleSpec), ctypes.c_void_p,
            ctypes.POINTER(PaBufferAttr), ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.pa_simple_new.restype = ctypes.c_void_p
        self.lib.pa_simple_read.argtypes = [
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
            ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.pa_simple_read.restype = ctypes.c_int
        self.lib.pa_simple_get_latency.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
        ]
        self.lib.pa_simple_get_latency.restype = ctypes.c_uint64
        self.lib.pa_simple_free.argtypes = [ctypes.c_void_p]
        self.lib.pa_simple_free.restype = None
        self.sample_rate = sample_rate
        spec = PaSampleSpec(PA_SAMPLE_FORMAT_S16LE, sample_rate, 1)
        fragment_bytes = (sample_rate * fragment_ms // 1000) * 2
        if fragment_bytes <= 0 or fragment_bytes > MAX_RECORD_BYTES:
            raise RuntimeError("capture fragment is invalid")
        self.fragment_bytes = fragment_bytes
        attributes = PaBufferAttr(
            UINT32_MAX, UINT32_MAX, UINT32_MAX, UINT32_MAX, fragment_bytes)
        error = ctypes.c_int(0)
        self.handle = self.lib.pa_simple_new(
            None, b"ovid-audio-acceptance", PA_STREAM_RECORD,
            os.fsencode(source), b"ovid-timed-capture", ctypes.byref(spec),
            None, ctypes.byref(attributes), ctypes.byref(error))
        if not self.handle:
            raise RuntimeError("PulseAudio record stream is unavailable")

    def read_timed_record(self, sequence):
        buffer = ctypes.create_string_buffer(self.fragment_bytes)
        error = ctypes.c_int(0)
        if self.lib.pa_simple_read(
                self.handle, buffer, self.fragment_bytes, ctypes.byref(error)) != 0 or error.value:
            raise RuntimeError("PulseAudio read failed")
        before_query_us = time.time_ns() // 1000
        before_query_ns = time.monotonic_ns()
        latency_us = self.lib.pa_simple_get_latency(self.handle, ctypes.byref(error))
        after_query_us = time.time_ns() // 1000
        after_query_ns = time.monotonic_ns()
        if error.value or latency_us == UINT64_MAX:
            raise RuntimeError("PulseAudio latency is unavailable")
        pcm = buffer.raw
        duration_us = chunk_duration_us(len(pcm), self.sample_rate)
        query_round_trip_us = max(0, after_query_us - before_query_us)
        query_mid_us = (before_query_us + after_query_us) // 2
        query_mid_ns = (before_query_ns + after_query_ns) // 2
        # The just-consumed block precedes the remaining pipeline latency.
        # Its oldest sample is backdated by latency + block duration. Retain a
        # conservative full-buffer uncertainty instead of pretending sample
        # timing is exact. No process-launch timestamp participates here.
        first_host_us = query_mid_us - latency_us - duration_us
        first_mono_ns = query_mid_ns - (latency_us + duration_us) * 1000
        buffering_us = latency_us + duration_us
        uncertainty_us = (
            buffering_us + math.ceil(query_round_trip_us / 2) + 1000)
        if first_host_us <= 0 or first_mono_ns <= 0 or uncertainty_us > 2_000_000:
            raise RuntimeError("capture timing is outside the accepted bound")
        return pack_record(
            sequence, first_host_us, first_mono_ns, latency_us,
            uncertainty_us, pcm, self.sample_rate,
            channels=SAMPLE_CHANNELS, sample_format=SAMPLE_FORMAT_S16LE)

    def close(self):
        if self.handle:
            self.lib.pa_simple_free(self.handle)
            self.handle = None


def run_capture(source, seconds, fragment_ms):
    stream = PulseSimple(source, SAMPLE_RATE, fragment_ms)
    try:
        deadline = time.monotonic() + seconds
        sequence = 0
        while time.monotonic() < deadline:
            record = stream.read_timed_record(sequence)
            view = memoryview(record)
            while view:
                written = os.write(1, view)
                view = view[written:]
            sequence += 1
        if sequence == 0:
            raise RuntimeError("no PCM frame was captured")
    finally:
        stream.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--seconds", required=True, type=float)
    parser.add_argument("--fragment-ms", type=int, default=20)
    args = parser.parse_args(argv)
    if not 0.1 <= args.seconds <= MAX_CAPTURE_SECONDS:
        return 2
    if not 5 <= args.fragment_ms <= 100:
        return 2
    try:
        run_capture(args.source, args.seconds, args.fragment_ms)
    except (OSError, RuntimeError, ValueError):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
