"""Shared synthetic-only Android audio fixture boundaries.

No Android/emulator/audio evidence. These helpers model process and timing only;
they do not make acceptance observations true and never contact a real device.
"""

import math
import os
import struct
import subprocess


FIXTURE_FRAME_COUNT = 24
FIXTURE_FRAGMENT_MS = 250
FIXTURE_CAPTURE_SECONDS = 6
FIXTURE_PCM_BYTES = FIXTURE_CAPTURE_SECONDS * 16000 * 2


def tone(seconds, rate=16000):
    return struct.pack(
        "<" + str(int(seconds * rate)) + "h",
        *[
            round(12000 * math.sin(2 * math.pi * 440 * index / rate))
            for index in range(int(seconds * rate))
        ],
    )


def silence(seconds, rate=16000):
    return struct.pack("<" + str(int(seconds * rate)) + "h", *([0] * int(seconds * rate)))


def baseline_capture(seconds=0.75):
    """Raw timed-capture-shaped silence; production computes baseline metrics."""
    return {"pcm": silence(seconds)}


def memory_pcm(payload):
    import socket
    read_sock, write_sock = socket.socketpair()
    try:
        write_sock.sendall(payload)
    finally:
        write_sock.close()
    read_fd = os.dup(read_sock.fileno())
    read_sock.close()
    return os.fdopen(read_fd, "rb", buffering=0, closefd=True)


class ControlledClock:
    def __init__(self):
        self.now = 5_000_000_000

    def monotonic_ns(self):
        return self.now

    def monotonic(self):
        return self.now / 1_000_000_000

    def clock_anchor(self):
        return self.anchor()

    def anchor(self, phase="capture_finish_wait"):
        elapsed_ms = (self.now - 5_000_000_000) // 1_000_000
        return {
            "offset_ms": 0,
            "uncertainty_ms": 1,
            "monotonic_ns": self.now,
            "device_wall_ms": 1_000_000 + elapsed_ms,
            "host_wall_ms": 1_000_000 + elapsed_ms,
            "phase": phase,
        }


class FakeProcess:
    """Process with a real nonblocking descriptor and controllable completion."""

    def __init__(self, clock, payload, exit_ns=None):
        self.clock = clock
        self.exit_ns = clock.now if exit_ns is None else exit_ns
        self.returncode = None
        self.killed = False
        self.wait_calls = []
        self.stdout = memory_pcm(payload)

    def wait(self, timeout=None):
        self.wait_calls.append(timeout)
        if self.killed:
            return -9
        if self.clock.monotonic_ns() >= self.exit_ns:
            self.returncode = 0
            return 0
        self.returncode = None
        raise subprocess.TimeoutExpired("fixture-process", timeout)

    def kill(self):
        self.killed = True
        self.returncode = -9


class FakeTtsAudio:
    """Complete fake TTS boundary that delegates to real HostAudio finish."""

    def __init__(self, gate, pulse):
        self.gate = gate
        self.pulse = pulse
        self.output_source = "fixture-output"
        self.mic_monitor = "fixture-mic"
        self.payload = fixture_frames(pulse)
        self.processes = set()
        self.captures = {}
        self.last_process = None
        self.last_capture = None
        self.calls = []

    def capture(self, source, seconds=0.75):
        self.calls.append("capture_baseline")
        return baseline_capture(seconds)

    def start_capture(self, source, seconds):
        self.calls.append("start_capture")
        if seconds < FIXTURE_CAPTURE_SECONDS:
            raise ValueError("fixture capture duration is shorter than its PCM timeline")
        return {"process_started_ns": 5_000_000_000, "seconds": seconds}

    def finish_capture(self, capture, on_wait=None):
        self.calls.append("finish_capture")
        audio = self.gate.HostAudio.__new__(self.gate.HostAudio)
        audio.processes = set()
        audio.captures = {}
        process = FakeProcess(ControlledClock(), self.payload)
        prepared = dict(capture, process=process)
        audio.processes.add(process)
        audio.captures[id(prepared)] = prepared
        self.processes = audio.processes
        self.captures = audio.captures
        self.last_process = process
        self.last_capture = prepared
        return audio.finish_capture(prepared, on_wait=on_wait)


def fixture_frames(pulse, *, count=FIXTURE_FRAME_COUNT,
                   fragment_ms=FIXTURE_FRAGMENT_MS, audible=True):
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
