#!/usr/bin/env python3
"""Signed-release Android on-device STT/TTS audio acceptance harness.

AUTHORED FOR LATER EXECUTION; no acceptance was executed while authoring.
This tool never builds an APK, changes a voice flag, launches an emulator, or
accepts replayed fixtures as device evidence. Passing requires real ADB/UI and
host-audio observations plus a fresh authenticated read-only server audit.
Raw audio exists only in process memory; no screenshots or raw audio are saved.
"""

import argparse
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import selectors
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import time
import unicodedata
import wave
import xml.etree.ElementTree as ET

import android_audio_pulse_capture as pulse_capture
import release_emulator_evidence as release


PACKAGE = release.PACKAGE
REPORT_NAME = "android-audio-acceptance.json"
CAPTURE_ARTIFACTS = (
    "artifact-inspection.sanitized.json",
    "logcat.redacted.txt",
    "ui-latest.redacted.xml",
)
SCHEMA_PATH = Path(__file__).with_name("android_audio_evidence.schema.json")
SCHEMA = "ovid.android.audio.acceptance/v1"
STIMULI_SCHEMA = "ovid.android.audio.stimuli/v1"
SERVER_AUDIT_SCHEMA = "ovid.android.audio.server-audit/v1"
SAMPLE_RATE = 16000
MAX_STIMULUS_BYTES = 20 * 1024 * 1024
MAX_SERVER_AUDIT_BYTES = 1024 * 1024
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SAFE_CODE = re.compile(r"^[a-z0-9_.-]{1,96}$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
SAFE_SERIAL = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
LANGUAGES = {
    "en": {"locale": "en-IN", "label": "English"},
    "hi": {"locale": "hi-IN", "label": "हिन्दी"},
    "hinglish": {"locale": "hi-IN", "label": "Hinglish"},
    "pa": {"locale": "pa-IN", "label": "ਪੰਜਾਬੀ"},
    "ta": {"locale": "ta-IN", "label": "தமிழ்"},
}
OPT_INS = {
    "OVID_AUDIO_ACCEPTANCE_OPT_IN": "YES_AUDIO_CAPABLE_EMULATOR",
    "OVID_AUDIO_ACCOUNT_OPT_IN": "YES_AUTHORIZED_TEST_ACCOUNT",
    "OVID_AUDIO_STIMULI_OPT_IN": "YES_SYNTHETIC_NON_PERSONAL",
    "OVID_AUDIO_SERVER_AUDIT_OPT_IN": "YES_AUTHORIZED_READ_ONLY_AUDIT",
    "OVID_AUDIO_EXCLUSIVE_OUTPUT_OPT_IN": "YES_DEDICATED_EMULATOR_OUTPUT",
}
VOICE_UNAVAILABLE = "On-device voice is not available in this release."
MIC_UNAVAILABLE = "Microphone access is off. Allow it in Settings to use voice input."
STT_FAILED = "Voice input could not start. Try again."
TTS_UNAVAILABLE = "On-device playback cannot use this language on this device."


class AudioFailure(Exception):
    def __init__(self, code):
        self.code = code if SAFE_CODE.fullmatch(code) else "harness_incomplete"
        super().__init__(self.code)


class Blocked(AudioFailure):
    """A required capability or authorized evidence source is unavailable."""


class AcceptanceFailed(AudioFailure):
    """An actual observation contradicts the acceptance contract."""


class AudioEvidenceStore(release.EvidenceStore):
    FILES = {
        REPORT_NAME,
        "artifact-inspection.sanitized.json",
        "logcat.redacted.txt",
        "ui-latest.redacted.xml",
    }

    def write_atomic(self, name, data, replace=False):
        super().write_atomic(name, data, replace=replace)
        # The parent excludes its own module-global report name, not ours.
        self.artifacts.discard(REPORT_NAME)

    def artifact_names(self):
        return [name for name in super().artifact_names() if name != REPORT_NAME]


def sha256_text(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def account_run_key(nonce, account):
    return sha256_text(nonce + "\0" + account)


def normalize_transcript(value):
    """Unicode-aware comparison; punctuation/case variants are not new content."""
    normalized = unicodedata.normalize("NFKC", value).casefold()
    kept = []
    for char in normalized:
        if char.isspace() or unicodedata.category(char)[0] not in ("L", "M", "N"):
            kept.append(" ")
        else:
            kept.append(char)
    return " ".join("".join(kept).split())


def transcript_matches(observed, alternatives):
    actual = normalize_transcript(observed)
    return len(actual) >= 3 and any(
        actual == normalize_transcript(candidate) for candidate in alternatives
    )


def _rms(samples):
    if not samples:
        return 0.0
    mean = sum(samples) / len(samples)
    return math.sqrt(sum((sample - mean) ** 2 for sample in samples) / len(samples))


def pcm_metrics(pcm, sample_rate=SAMPLE_RATE):
    """Return only bounded signal metrics and a digest, never sample bytes."""
    if not isinstance(pcm, bytes) or len(pcm) < 2 or len(pcm) % 2:
        raise ValueError("invalid PCM")
    count = len(pcm) // 2
    samples = struct.unpack("<" + str(count) + "h", pcm)
    window_size = max(1, sample_rate // 20)
    windows = [
        _rms(samples[offset:offset + window_size])
        for offset in range(0, count, window_size)
        if len(samples[offset:offset + window_size]) >= window_size // 2
    ]
    stride = max(1, count // 4096)
    return {
        "duration_ms": round(count * 1000 / sample_rate, 3),
        "samples": count,
        "peak": max(abs(sample) for sample in samples),
        "rms": round(_rms(samples), 3),
        "dc_offset": round(abs(sum(samples) / count), 3),
        "max_window_rms": round(max(windows, default=0.0), 3),
        "active_windows_50ms": sum(value >= 80 for value in windows),
        "clipped_samples": sum(abs(sample) >= 32760 for sample in samples),
        "distinct_samples": len(set(samples[::stride])),
        "sha256": sha256_bytes(pcm),
    }


def pcm_window(pcm, start_ms, end_ms, sample_rate=SAMPLE_RATE):
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError("invalid PCM window")
    start = int(start_ms * sample_rate / 1000) * 2
    end = int(end_ms * sample_rate / 1000) * 2
    if end > len(pcm):
        raise ValueError("PCM window outside capture")
    return pcm[start:end]


def baseline_errors(metrics):
    if metrics["duration_ms"] < 250:
        return ["audio_baseline_too_short"]
    if metrics["peak"] > 2000 or metrics["rms"] > 200:
        return ["audio_source_busy"]
    return []


def signal_errors(metrics, baseline, short=False):
    errors = []
    minimum_windows = 1 if short else 3
    if metrics["duration_ms"] < 250:
        errors.append("audio_capture_too_short")
    if (metrics["peak"] < 1000 or metrics["rms"] < 80
            or metrics["max_window_rms"] < 160
            or metrics["rms"] < max(80, baseline["rms"] * 3)
            or metrics["active_windows_50ms"] < minimum_windows):
        errors.append("audio_signal_absent")
    if metrics["distinct_samples"] < 16 or metrics["dc_offset"] > 2000:
        errors.append("audio_signal_invalid")
    if metrics["clipped_samples"] > metrics["samples"] * 0.01:
        errors.append("audio_signal_clipped")
    return errors


def _hash_fd(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return digest.hexdigest()


def close_stimuli(stimuli):
    for case in stimuli or []:
        fd = case.get("_fd")
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
            case["_fd"] = None


def load_stimuli(manifest_path):
    """Pin real synthetic WAV inputs; these inputs are never device evidence."""
    opened = []
    pending_fd = None
    try:
        path = Path(manifest_path)
        if not path.is_file() or path.stat().st_size > 1024 * 1024:
            raise Blocked("stimulus_manifest_unavailable")
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise Blocked("stimulus_manifest_invalid")
        attestation = manifest.get("attestation") or {}
        if not isinstance(attestation, dict):
            raise Blocked("stimulus_attestation_required")
        if (manifest.get("schema") != STIMULI_SCHEMA
                or attestation.get("synthetic_non_personal_only") is not True
                or attestation.get("authorized_virtual_microphone_use") is not True):
            raise Blocked("stimulus_attestation_required")
        rows = manifest.get("cases")
        if not isinstance(rows, list) or len(rows) != len(LANGUAGES):
            raise Blocked("multilingual_stimuli_required")
        by_id = {}
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str):
                raise Blocked("stimulus_manifest_invalid")
            if row["id"] in by_id:
                raise Blocked("stimulus_manifest_invalid")
            by_id[row["id"]] = row
        if set(by_id) != set(LANGUAGES):
            raise Blocked("multilingual_stimuli_required")
        for language_id, contract in LANGUAGES.items():
            row = by_id[language_id]
            alternatives = row.get("expected_transcripts")
            audio = row.get("audio") or {}
            if not isinstance(audio, dict):
                raise Blocked("stimulus_manifest_invalid")
            if (row.get("locale") != contract["locale"]
                    or not isinstance(alternatives, list) or not 1 <= len(alternatives) <= 4
                    or any(not isinstance(value, str) or not 3 <= len(value) <= 256
                           or not normalize_transcript(value) for value in alternatives)):
                raise Blocked("stimulus_manifest_invalid")
            supplied_hash = audio.get("sha256")
            source = audio.get("path")
            if (not isinstance(source, str) or not source
                    or not isinstance(supplied_hash, str) or not HEX64.fullmatch(supplied_hash)
                    or supplied_hash == "0" * 64):
                raise Blocked("stimulus_audio_pin_required")
            source_path = Path(source)
            if not source_path.is_absolute():
                source_path = path.parent / source_path
            if stat.S_ISLNK(os.lstat(source_path).st_mode):
                raise Blocked("stimulus_audio_symlink_forbidden")
            fd = os.open(source_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            pending_fd = fd
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or not 44 <= info.st_size <= MAX_STIMULUS_BYTES:
                raise Blocked("stimulus_audio_invalid")
            if _hash_fd(fd) != supplied_hash:
                raise Blocked("stimulus_audio_hash_mismatch")
            with os.fdopen(os.dup(fd), "rb") as stream:
                with wave.open(stream, "rb") as wav:
                    if (wav.getnchannels() not in (1, 2) or wav.getsampwidth() != 2
                            or not 8000 <= wav.getframerate() <= 48000
                            or wav.getcomptype() != "NONE"):
                        raise Blocked("stimulus_audio_format_unsupported")
                    duration_ms = wav.getnframes() * 1000 / wav.getframerate()
            if not 2000 <= duration_ms <= 12000:
                raise Blocked("stimulus_audio_duration_invalid")
            case = {
                "id": language_id,
                "locale": contract["locale"],
                "label": contract["label"],
                "_fd": fd,
                "_expected": list(alternatives),
                "public": {
                    "id": language_id,
                    "locale": contract["locale"],
                    "audio_sha256": supplied_hash,
                    "expected_transcript_sha256": sha256_text(
                        normalize_transcript(alternatives[0])),
                    "duration_ms": round(duration_ms, 3),
                    "attestation": "synthetic_non_personal_operator_supplied",
                },
            }
            opened.append(case)
            pending_fd = None
        return opened
    except Blocked:
        if pending_fd is not None:
            try:
                os.close(pending_fd)
            except OSError:
                pass
        close_stimuli(opened)
        raise
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            json.JSONDecodeError, wave.Error):
        if pending_fd is not None:
            try:
                os.close(pending_fd)
            except OSError:
                pass
        close_stimuli(opened)
        raise Blocked("stimulus_manifest_or_audio_invalid") from None


class HostAudio:
    """Real FFmpeg/Pulse-compatible host boundary; PCM is pipes/memory only."""

    def __init__(self, env):
        self.ffmpeg = shutil.which("ffmpeg")
        if not self.ffmpeg:
            raise Blocked("audio_ffmpeg_unavailable")
        self.sink = env.get("OVID_AUDIO_MIC_SINK", "")
        self.mic_monitor = env.get("OVID_AUDIO_MIC_MONITOR", "")
        self.output_source = env.get("OVID_AUDIO_OUTPUT_SOURCE", "")
        values = (self.sink, self.mic_monitor, self.output_source)
        if (any(not value or len(value) > 256 or "\0" in value or "\n" in value
                for value in values) or len(set(values)) != len(values)):
            raise Blocked("audio_endpoints_not_configured")
        self.processes = set()
        self.captures = {}
        self.capture_helper = Path(__file__).with_name("android_audio_pulse_capture.py")
        if not self.capture_helper.is_file():
            raise Blocked("timed_audio_capture_helper_unavailable")

    def capture(self, source, seconds=0.75):
        return self.finish_capture(self.start_capture(source, seconds))

    def _capture_arguments(self, source, seconds):
        return [
            sys.executable, str(self.capture_helper),
            "--source", source, "--seconds", f"{seconds:.3f}",
            "--fragment-ms", "20",
        ]

    def start_capture(self, source, seconds):
        try:
            process = subprocess.Popen(
                self._capture_arguments(source, seconds), stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            raise Blocked("audio_capture_unavailable") from None
        capture = {
            "process": process,
            # Process lifetime is for timeout management only, never PCM time.
            "process_started_ns": time.monotonic_ns(),
            "seconds": seconds,
            "chunks": [],
            "overflow": False,
            "expected_max": int(
                (seconds + 2) * SAMPLE_RATE * 2
                + (seconds * 1000 / 5 + 10) * pulse_capture.HEADER.size),
            "eof": False,
        }
        self.processes.add(process)
        self.captures[id(capture)] = capture
        try:
            self._configure_capture_stream(capture)
        except BaseException:
            self._abort_capture(capture)
            raise
        return capture

    def _configure_capture_stream(self, capture):
        capture.setdefault("chunks", [])
        capture.setdefault("overflow", False)
        capture.setdefault("eof", False)
        capture.setdefault("expected_max", int(
            (capture["seconds"] + 2) * SAMPLE_RATE * 2
            + (capture["seconds"] * 1000 / 5 + 10) * pulse_capture.HEADER.size))
        if capture.get("selector") is not None:
            return
        process = capture["process"]
        selector = selectors.DefaultSelector()
        try:
            descriptor = process.stdout.fileno()
            os.set_blocking(descriptor, False)
            selector.register(descriptor, selectors.EVENT_READ)
        except BaseException:
            selector.close()
            raise
        capture["selector"] = selector

    def _drain_available(self, capture):
        process = capture["process"]
        while not capture["eof"]:
            try:
                chunk = process.stdout.read(65536)
            except BlockingIOError:
                return
            except (OSError, ValueError):
                raise Blocked("audio_capture_read_failed") from None
            if chunk is None:
                return
            if chunk == b"":
                capture["eof"] = True
                return
            capture["chunks"].append(chunk)
            if sum(map(len, capture["chunks"])) > capture["expected_max"]:
                capture["overflow"] = True
                raise Blocked("audio_capture_overflow")

    def _close_capture(self, capture, kill):
        process = capture["process"]
        cleanup_failed = False
        if kill:
            try:
                if process.returncode is None:
                    process.kill()
                    process.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                cleanup_failed = True
        selector = capture.get("selector")
        if selector is not None:
            try:
                selector.close()
            except (OSError, ValueError):
                cleanup_failed = True
        try:
            process.stdout.close()
        except (OSError, ValueError):
            cleanup_failed = True
        self.captures.pop(id(capture), None)
        self.processes.discard(process)
        if cleanup_failed:
            raise Blocked("audio_cleanup_failed")

    def _abort_capture(self, capture):
        # Cleanup is mandatory on every failure; never silently leak a process.
        self._close_capture(capture, kill=True)

    def _finish_capture_wait(self, capture, on_wait):
        process = capture["process"]
        self._configure_capture_stream(capture)
        deadline = time.monotonic() + capture["seconds"] + 20
        while True:
            if on_wait is not None:
                on_wait("capture_finish_wait")
            self._drain_available(capture)
            try:
                returncode = process.wait(timeout=0)
            except subprocess.TimeoutExpired:
                returncode = None
            if returncode is not None and capture["eof"]:
                break
            if time.monotonic() >= deadline:
                raise Blocked("audio_capture_deadline_exceeded")
            capture["selector"].select(timeout=0.25)
        stdout = b"".join(capture["chunks"])
        if (returncode or capture["overflow"] or not capture["eof"] or not stdout):
            raise Blocked("audio_capture_unavailable")
        try:
            return pulse_capture.decode_records(stdout)
        except ValueError:
            raise Blocked("audio_capture_timing_unavailable") from None

    def finish_capture(self, capture, on_wait=None):
        try:
            result = self._finish_capture_wait(capture, on_wait)
        except BaseException:
            self._abort_capture(capture)
            raise
        self._close_capture(capture, kill=False)
        return result

    def start_play(self, stimulus):
        fd = stimulus["_fd"]
        if fd is None:
            raise Blocked("stimulus_audio_unavailable")
        if _hash_fd(fd) != stimulus["public"]["audio_sha256"]:
            raise AcceptanceFailed("stimulus_audio_changed")
        command = [
            self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
            "-re", "-f", "wav", "-i", f"/proc/self/fd/{fd}",
            "-map", "0:a:0", "-f", "pulse", self.sink,
        ]
        try:
            process = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, pass_fds=(fd,))
        except OSError:
            raise Blocked("virtual_microphone_unavailable") from None
        self.processes.add(process)
        return process

    def finish_play(self, process):
        try:
            returncode = process.wait(timeout=30)
        except subprocess.SubprocessError:
            process.kill()
            process.wait()
            raise Blocked("virtual_microphone_unavailable") from None
        finally:
            self.processes.discard(process)
        if returncode:
            raise Blocked("virtual_microphone_unavailable")

    def cleanup(self):
        errors = []
        for capture in list(self.captures.values()):
            try:
                self._close_capture(capture, kill=True)
            except Blocked as error:
                errors.append(error.code)
        for process in list(self.processes):
            try:
                process.kill()
                process.wait(timeout=5)
            except (OSError, subprocess.SubprocessError):
                errors.append("audio_cleanup_failed")
            self.processes.discard(process)
        return list(dict.fromkeys(errors))

def _track_field(block, name):
    match = re.search(
        rf"\b{re.escape(name)}\s*(?::|=|\s)\s*([A-Za-z0-9_-]+)", block)
    return match.group(1) if match else None


def _track_int(block, name):
    value = _track_field(block, name)
    if value is None or not re.fullmatch(r"-?\d+", value):
        return None
    return int(value)


def _track_header(line):
    """Fully consume one narrow Track grammar; any residue is rejected."""
    parts = line.strip().split(",")
    if re.fullmatch(r"Track\s+(?:0x[0-9a-fA-F]+|\d+)", parts[0].strip()) is None:
        return None
    fields = {}
    for part in parts[1:]:
        match = re.fullmatch(
            r"\s*(pid|stream|streamType)\s*(?::|=|\s)\s*"
            r"([A-Za-z0-9_-]+)\s*", part)
        if match is None:
            return None
        name, value = match.groups()
        if name in fields and fields[name] != value:
            return None
        fields[name] = value
    return fields


def _track_body_field(line):
    state = re.fullmatch(
        r"\s*State:\s*(ACTIVE|INACTIVE|STOPPED|PAUSED|FLUSHED)\s*",
        line, re.IGNORECASE)
    if state:
        return "state", state.group(1).upper()
    active = re.fullmatch(
        r"\s*[Aa]ctive:\s*(true|false|1|0|yes|no)\s*", line, re.IGNORECASE)
    if active:
        return "active", active.group(1).lower()
    identity = re.fullmatch(
        r"\s*(pid|stream|streamType)\s*(?::|=|\s)\s*"
        r"([A-Za-z0-9_-]+)\s*", line)
    if identity:
        return identity.group(1), identity.group(2)
    return None


def parse_track_dump(dump, kind, expected_pid=None, expected_stream=None):
    """Understand the complete section or return UNKNOWN, including residue."""
    wanted = "Record Tracks:" if kind == "record" else "Playback Tracks:"
    other = "Playback Tracks:" if kind == "record" else "Record Tracks:"
    header = re.search(rf"(?m)^\s*{re.escape(wanted)}\s*$", dump)
    result = {
        "known": False,
        "active_tracks": 0,
        "matching_active_tracks": 0,
        "dump_sha256": sha256_text(dump),
    }
    if header is None:
        return result
    section = dump[header.end():]
    next_other = re.search(rf"(?m)^\s*{re.escape(other)}\s*$", section)
    if next_other:
        section = section[:next_other.start()]
    next_top_level = re.search(
        r"(?m)^\s*(?:Output threads|Input threads|Playback threads|Record threads|"
        r"Audio HAL|Devices|Outputs|Inputs|Streams|Effects):\s*$", section)
    if next_top_level:
        section = section[:next_top_level.start()]
    stripped = section.strip()
    if not stripped or stripped.lower() in ("(no tracks)", "no tracks", "none", "(empty)"):
        result["known"] = True
        return result
    tracks = []
    current = None

    def finish(track):
        if track is None:
            return True
        states = track.pop("states")
        if len(states) != 1:
            return False
        track["active"] = states[0] in ("ACTIVE", "active", "true", "1", "yes")
        tracks.append(track)
        return True

    for line in section.splitlines():
        if not line.strip():
            continue
        if re.match(r"\s*Track\s+", line):
            if not finish(current):
                return result
            fields = _track_header(line)
            if fields is None:
                return result
            current = {**fields, "states": []}
            continue
        if current is None:
            return result
        parsed = _track_body_field(line)
        if parsed is None:
            return result
        name, value = parsed
        if name in ("state", "active"):
            current["states"].append(value)
        else:
            if name in current and current[name] != value:
                return result
            current[name] = value
    if not finish(current) or not tracks:
        return result
    active_count = 0
    matching = 0
    for track in tracks:
        pid_value = track.get("pid")
        pid = int(pid_value) if pid_value and re.fullmatch(r"-?\d+", pid_value) else None
        stream_value = track.get("stream") or track.get("streamType")
        stream = None
        if stream_value is not None:
            if stream_value.upper() in ("MUSIC", "STREAM_MUSIC"):
                stream = 3
            elif re.fullmatch(r"-?\d+", stream_value):
                stream = int(stream_value)
        if pid is None or (kind == "playback" and stream is None):
            return result
        if track["active"]:
            active_count += 1
            if (expected_pid is not None and pid == expected_pid
                    and stream == expected_stream):
                matching += 1
    result.update(
        known=True, active_tracks=active_count, matching_active_tracks=matching)
    return result


class AudioAdbDevice(release.AdbDevice):
    """Explicit serial only; real release UI, with fail-closed audio observations."""

    def __init__(self, apk, avd, serial, out, env):
        super().__init__(apk, avd, out, env)
        self.serial = serial

    def _connect(self):
        self.stage = "explicit audio emulator selection"
        try:
            if self.serial not in self._connected_serials():
                raise Blocked("audio_emulator_unavailable")
            if self._text(["shell", "getprop", "ro.kernel.qemu"], check=False).strip() != "1":
                raise Blocked("explicit_device_is_not_an_emulator")
            avd = self._text([
                "shell", "getprop", "ro.kernel.qemu.avd_name"], check=False).strip()
            if avd != self.avd:
                raise Blocked("audio_emulator_avd_mismatch")
            self._run(["wait-for-device"], timeout=120)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                booted = self._text([
                    "shell", "getprop", "sys.boot_completed"], check=False).strip()
                if booted == "1":
                    break
                time.sleep(1)
            else:
                raise Blocked("audio_emulator_boot_unavailable")
            api_text = self._text(["shell", "getprop", "ro.build.version.sdk"]).strip()
            if not api_text.isdigit() or int(api_text) < 33:
                raise Blocked("on_device_stt_api_unavailable")
        except release.HarnessError:
            raise Blocked("audio_emulator_unavailable") from None

    def grant_microphone(self):
        self.stage = "authorized microphone permission"
        try:
            self._shell("pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO")
            package_dump = self._text(["shell", "dumpsys", "package", PACKAGE])
        except release.HarnessError:
            raise Blocked("microphone_permission_unavailable") from None
        match = re.search(
            r"android\.permission\.RECORD_AUDIO[^\n]*granted=(true|false)", package_dump)
        if not match or match.group(1) != "true":
            raise Blocked("microphone_permission_unavailable")

    @staticmethod
    def _composer_from_xml(xml_text):
        root = ET.fromstring(xml_text)
        fields = [node for node in root.iter("node")
                  if node.get("class") == "android.widget.EditText"]
        if len(fields) != 1:
            raise Blocked("release_composer_unavailable")
        return fields[0].get("text", "")

    def composer_text(self, xml_text=None):
        return self._composer_from_xml(xml_text or self._dump_ui())

    def clear_composer(self):
        xml_text = self._dump_ui()
        root = ET.fromstring(xml_text)
        fields = [node for node in root.iter("node")
                  if node.get("class") == "android.widget.EditText"]
        if len(fields) != 1:
            raise Blocked("release_composer_unavailable")
        x, y = self._center(fields[0])
        self._shell("input", "tap", str(x), str(y))
        self._shell("input", "keyevent", "--meta", "META_CTRL_ON", "KEYCODE_A")
        self._shell("input", "keyevent", "KEYCODE_DEL")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.composer_text() == "":
                return
            time.sleep(0.25)
        raise AcceptanceFailed("release_composer_clear_failed")

    def tap_first(self, labels, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            matches = []
            for label in labels:
                for node in self._matching_nodes(xml_text, label):
                    matches.append(node)
            identities = {id(node) for node in matches}
            if len(matches) == 1 and len(identities) == 1:
                x, y = self._center(matches[0])
                self._shell("input", "tap", str(x), str(y))
                return
            if len(matches) > 1:
                raise Blocked("release_ui_control_ambiguous")
            time.sleep(0.5)
        raise Blocked("release_ui_control_unavailable")

    def wait_label(self, labels, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            if any(self._has_label(xml_text, label) for label in labels):
                return xml_text
            time.sleep(0.5)
        raise Blocked("release_ui_state_unavailable")

    def new_chat(self):
        # V2 shows both "Open menu" and "More options" simultaneously; only
        # the former opens the drawer containing its New chat action.
        current = self._dump_ui()
        if self._has_label(current, "Open menu"):
            self.tap_first(["Open menu"])
        else:
            self.tap_first(["More options"])
        self.tap_first(["New chat"])
        self.wait_label(["Voice input", "Send"])
        self.clear_composer()

    def set_voice_language(self, stimulus):
        self.tap_first(["Open menu"])
        self.tap_first(["Settings"])
        self.tap_first(["Appearance"])
        self.tap_first(["Voice language"])
        self.tap_first([stimulus["label"]])
        # A back key can either dismiss the still-closing sheet or pop a page.
        # Navigate by the observed composer, never by a fixed back count.
        for _ in range(4):
            xml_text = self._dump_ui()
            if (self._has_label(xml_text, "Voice input")
                    and self._has_label(xml_text, "Send")):
                self._composer_from_xml(xml_text)
                return
            self._shell("input", "keyevent", "KEYCODE_BACK")
            time.sleep(0.5)
        raise Blocked("release_chat_navigation_failed")

    def enter_ascii_prompt(self, prompt):
        if (not prompt or len(prompt) > 1000
                or any(ord(char) < 32 or ord(char) > 126 for char in prompt)
                or "%" in prompt):
            raise AcceptanceFailed("safe_prompt_invalid")
        self.clear_composer()
        xml_text = self._dump_ui()
        root = ET.fromstring(xml_text)
        fields = [node for node in root.iter("node")
                  if node.get("class") == "android.widget.EditText"]
        if len(fields) != 1:
            raise Blocked("release_composer_unavailable")
        x, y = self._center(fields[0])
        self._shell("input", "tap", str(x), str(y))
        self._shell("input", "text", prompt.replace("\\", "\\\\").replace(" ", "%s"))
        if self.composer_text() != prompt:
            raise AcceptanceFailed("safe_prompt_entry_failed")
        self.tap_first(["Send"])

    @staticmethod
    def _exact_text_count(xml_text, expected):
        root = ET.fromstring(xml_text)
        count = 0
        for node in root.iter("node"):
            if node.get("class") == "android.widget.EditText":
                continue
            if (node.get("text", "").strip() == expected
                    or node.get("content-desc", "").strip() == expected):
                count += 1
        return count

    def wait_exact_text(self, expected, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            count = self._exact_text_count(xml_text, expected)
            if count == 1:
                return
            if count > 1:
                raise AcceptanceFailed("release_ui_identity_ambiguous")
            time.sleep(1)
        raise Blocked("safe_release_answer_unavailable")

    def send_current_draft(self, observed_transcript):
        if self.composer_text() != observed_transcript:
            raise AcceptanceFailed("stt_draft_identity_changed")
        self.tap_first(["Send"])
        self.wait_exact_text(observed_transcript, timeout=120)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.composer_text() == "":
                return
            time.sleep(0.5)
        raise AcceptanceFailed("transcript_submission_not_observed")

    @staticmethod
    def voice_error(xml_text):
        if VOICE_UNAVAILABLE in xml_text:
            return "release_voice_gate_closed"
        if MIC_UNAVAILABLE in xml_text:
            return "microphone_permission_unavailable"
        if STT_FAILED in xml_text:
            return "stt_locale_or_microphone_unavailable"
        if TTS_UNAVAILABLE in xml_text:
            return "tts_locale_unavailable"
        return None

    def start_dictation(self):
        self.tap_first(["Voice input"])
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            error = self.voice_error(xml_text)
            if error:
                raise Blocked(error)
            if self._has_label(xml_text, "Stop voice input"):
                observation = self.observe_tracks("record")
                if not observation["known"] or observation["active_tracks"] < 1:
                    raise Blocked("virtual_microphone_unavailable")
                return observation
            time.sleep(0.25)
        raise Blocked("stt_locale_or_microphone_unavailable")

    def wait_dictation_result(self, alternatives, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            error = self.voice_error(xml_text)
            if error:
                raise Blocked(error)
            listening = self._has_label(xml_text, "Stop voice input")
            observed = self.composer_text(xml_text)
            if not listening and self._has_label(xml_text, "Voice input"):
                if transcript_matches(observed, alternatives):
                    return observed
                raise AcceptanceFailed("stt_transcript_mismatch")
            time.sleep(0.25)
        raise AcceptanceFailed("stt_final_result_missing")

    def wait_partial_draft(self, alternatives, timeout=12):
        deadline = time.monotonic() + timeout
        normalized_expected = [normalize_transcript(value) for value in alternatives]
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            error = self.voice_error(xml_text)
            if error:
                raise Blocked(error)
            observed = self.composer_text(xml_text)
            normalized = normalize_transcript(observed)
            if (len(normalized) >= 3 and any(
                    expected.startswith(normalized) for expected in normalized_expected)):
                return observed
            time.sleep(0.2)
        raise Blocked("stt_partial_draft_unavailable")

    def stop_dictation(self):
        self.tap_first(["Stop voice input"], timeout=10)
        self.wait_label(["Voice input"], timeout=20)
        tracks = self.observe_tracks("record")
        if not tracks["known"]:
            raise Blocked("lifecycle_observation_unavailable")
        if tracks["active_tracks"]:
            raise AcceptanceFailed("stt_restart_microphone_still_active")
        return tracks

    def start_playback(self, expected_locale, on_sample=None):
        pid = self._pid()
        if pid is None:
            raise Blocked("release_process_unavailable")
        self._run(["logcat", "-c"], check=False)
        initial = self._dump_ui()
        if self._has_label(initial, "Pause answer"):
            raise AcceptanceFailed("tts_autoplay_detected")
        self.tap_first(["Play answer"])
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if on_sample is not None:
                on_sample("playback_start_poll")
            xml_text = self._dump_ui()
            error = self.voice_error(xml_text)
            if error:
                raise Blocked(error)
            if self._has_label(xml_text, "Pause answer"):
                raw, current_pid = self.tts_evidence_log()
                if current_pid != pid:
                    raise AcceptanceFailed("tts_process_identity_changed")
                if "event=accepted" not in raw or "event=start" not in raw:
                    time.sleep(0.2)
                    continue
                trace = parse_tts_evidence(
                    raw, require_done=False, device_pid=current_pid)
                errors = validate_tts_trace(
                    trace, expected_locale, require_complete=False)
                if any("locale" in error for error in errors):
                    raise AcceptanceFailed("tts_locale_mismatch")
                if errors:
                    raise Blocked("tts_evidence_unavailable")
                # A start trace is only an admission check. Final acceptance
                # requires the event-driven whole-interval playback journal.
                return {"trace": trace}
            time.sleep(0.2)
        raise Blocked("audio_output_unavailable")

    def wait_playback_complete(self, started, expected_locale, timeout=45, on_sample=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if on_sample is not None:
                on_sample("capture_midpoint")
            xml_text = self._dump_ui()
            error = self.voice_error(xml_text)
            if error:
                raise AcceptanceFailed("tts_playback_failed")
            raw, current_pid = self.tts_evidence_log()
            if current_pid != started["trace"]["device_process_id"]:
                raise AcceptanceFailed("tts_process_identity_changed")
            if "event=done" in raw:
                trace = parse_tts_evidence(raw, require_done=True, device_pid=current_pid)
                errors = validate_tts_trace(trace, expected_locale)
                if errors:
                    raise AcceptanceFailed("tts_completion_evidence_invalid")
                for key in (
                        "utterance_id", "native_utterance_id",
                        "requested_locale", "resolved_locale", "device_process_id"):
                    if trace[key] != started["trace"][key]:
                        raise AcceptanceFailed("tts_utterance_identity_changed")
                if (self._has_label(xml_text, "Play answer")
                        and not self._has_label(xml_text, "Pause answer")):
                    return trace
            time.sleep(0.25)
        raise AcceptanceFailed("tts_completion_not_observed")

    def background(self):
        self._shell("input", "keyevent", "KEYCODE_HOME")
        time.sleep(0.5)

    def foreground(self):
        self._shell("monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
        time.sleep(0.5)

    def is_foreground(self):
        text = self._text(["shell", "dumpsys", "activity", "activities"], check=False)
        markers = re.findall(
            r"(?m)^\s*(?:topResumedActivity|ResumedActivity).*?$", text)
        if not markers:
            return None
        return any(PACKAGE in marker for marker in markers)

    def observe_tracks(self, kind, expected_pid=None, expected_stream=None):
        dump = self._text(["shell", "dumpsys", "media.audio_flinger"], check=False)
        observation = parse_track_dump(
            dump, kind, expected_pid=expected_pid, expected_stream=expected_stream)
        observation.update({
            "source": "android.media.audio_flinger",
            "channel": "ovid.stt.record" if kind == "record" else "ovid.tts.playback",
            "observed_monotonic_ns": time.monotonic_ns(),
        })
        if kind == "playback":
            observation.update({
                "stream": "MUSIC" if expected_stream == 3 else "unknown",
                "device_process_id": expected_pid,
            })
        else:
            observation.pop("matching_active_tracks", None)
        return observation

    def clock_anchor(self):
        before_wall = time.time_ns() / 1_000_000
        before_mono = time.monotonic_ns()
        value = self._text(["shell", "date", "+%s%3N"]).strip()
        after_mono = time.monotonic_ns()
        after_wall = time.time_ns() / 1_000_000
        if not value.isdigit() or len(value) != 13:
            raise Blocked("device_clock_unavailable")
        round_trip = (after_mono - before_mono) / 1_000_000
        if round_trip < 0 or round_trip > 50:
            raise Blocked("device_clock_uncertainty_exceeded")
        host_wall_ms = (before_wall + after_wall) / 2
        offset_ms = int(value) - host_wall_ms
        if abs(offset_ms) > 5000:
            raise Blocked("device_clock_offset_untrusted")
        return {
            "offset_ms": offset_ms,
            "uncertainty_ms": max(1, math.ceil(round_trip / 2) + 1),
            "monotonic_ns": (before_mono + after_mono) // 2,
            "device_wall_ms": int(value),
            "host_wall_ms": host_wall_ms,
        }

    def tts_evidence_log(self):
        pid = self._pid()
        if pid is None:
            raise Blocked("release_process_unavailable")
        raw = self._run([
            "logcat", "-d", f"--pid={pid}", "-s", "OvidTtsEvidence",
        ], timeout=30).decode("utf-8", errors="strict")
        return raw, pid

    def require_foreground(self, expected):
        actual = self.is_foreground()
        if actual is None:
            raise Blocked("lifecycle_observation_unavailable")
        if actual is not expected:
            raise AcceptanceFailed("activity_lifecycle_transition_failed")

    def music_volume(self):
        output = self._text([
            "shell", "media", "volume", "--stream", "3", "--get"], check=False)
        match = re.search(r"volume is (\d+)", output)
        if match and "muted" not in output.lower() and int(match.group(1)) > 0:
            return {"music_stream_unmuted": True, "music_stream_volume": int(match.group(1))}
        dump = self._text(["shell", "dumpsys", "audio"], check=False)
        block = dump.split("STREAM_MUSIC", 1)
        if len(block) == 2:
            section = block[1].split("STREAM_", 1)[0]
            muted = re.search(r"Muted:\s*(true|false)", section)
            volumes = [int(value) for value in re.findall(r"(?::|\s)(\d+)(?:\D|$)", section)]
            if muted and muted.group(1) == "false" and any(value > 0 for value in volumes):
                return {"music_stream_unmuted": True, "music_stream_volume": max(volumes)}
        raise Blocked("audio_output_volume_unavailable")

    def stop_audio(self):
        try:
            self._shell("input", "keyevent", "KEYCODE_HOME", check=False)
            self._shell("am", "force-stop", PACKAGE)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if self._pid() is None:
                    return
                time.sleep(0.25)
        except release.HarnessError:
            pass
        raise AcceptanceFailed("audio_cleanup_failed")

    def capture_evidence(self):
        captured = set()
        try:
            raw = self._run(["logcat", "-d"], timeout=60).decode("utf-8", errors="replace")
            self.out.write_atomic("logcat.redacted.txt", release.redact_logcat(raw))
            captured.add("logcat.redacted.txt")
        except (release.HarnessError, OSError, ValueError):
            pass
        if "ui-latest.redacted.xml" in self.out.artifact_names():
            captured.add("ui-latest.redacted.xml")
        return captured


class DeviceNetwork:
    """Airplane-mode offline proof with restoration of the initial online state."""

    def __init__(self, device):
        self.device = device
        self.initial = None
        self.online_required = False

    def _setting(self, name):
        return self.device._text(["shell", "settings", "get", "global", name]).strip()

    def _airplane(self, enabled):
        value = "1" if enabled else "0"
        self.device._shell("settings", "put", "global", "airplane_mode_on", value)
        self.device._shell(
            "am", "broadcast", "-a", "android.intent.action.AIRPLANE_MODE",
            "--ez", "state", "true" if enabled else "false")

    def _connected_networks(self):
        dump = self.device._text(["shell", "dumpsys", "connectivity"], check=False)
        connected = []
        for line in dump.splitlines():
            if ("NetworkAgentInfo" in line and "CONNECTED" in line
                    and re.search(r"WIFI|MOBILE|ETHERNET|VPN", line, re.IGNORECASE)):
                connected.append(line)
        return connected, sha256_text(dump)

    def initialize(self):
        try:
            airplane = self._setting("airplane_mode_on")
            wifi = self._setting("wifi_on")
            mobile = self._setting("mobile_data")
            if airplane != "0" or wifi not in ("0", "1") or mobile not in ("0", "1"):
                raise Blocked("network_control_unavailable")
            connected, _ = self._connected_networks()
            if not connected:
                raise Blocked("authorized_online_account_network_required")
            self.initial = {"airplane": airplane, "wifi": wifi, "mobile": mobile}
            self.online_required = True
        except release.HarnessError:
            raise Blocked("network_control_unavailable") from None

    def offline(self):
        if self.initial is None:
            raise Blocked("network_control_uninitialized")
        try:
            self._airplane(True)
            self.device._shell("svc", "wifi", "disable", check=False)
            self.device._shell("svc", "data", "disable", check=False)
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                connected, digest = self._connected_networks()
                if self._setting("airplane_mode_on") == "1" and not connected:
                    return {"airplane_mode": True, "connected_networks": 0,
                            "connectivity_sha256": digest}
                time.sleep(0.5)
        except release.HarnessError:
            pass
        raise Blocked("verified_offline_state_unavailable")

    def online(self):
        if self.initial is None:
            raise Blocked("network_control_uninitialized")
        try:
            self._airplane(False)
            self.device._shell("svc", "wifi", "enable", check=False)
            self.device._shell("svc", "data", "enable", check=False)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                connected, digest = self._connected_networks()
                if self._setting("airplane_mode_on") == "0" and connected:
                    return {"airplane_mode": False, "connected_networks": len(connected),
                            "connectivity_sha256": digest}
                time.sleep(0.5)
        except release.HarnessError:
            pass
        raise Blocked("authorized_online_network_restore_failed")

    def restore(self):
        if self.initial is None:
            return
        try:
            self._airplane(False)
            self.device._shell("svc", "wifi", "enable" if self.initial["wifi"] == "1" else "disable")
            self.device._shell("svc", "data", "enable" if self.initial["mobile"] == "1" else "disable")
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                connected, _ = self._connected_networks()
                if connected:
                    self.online_required = False
                    return
                time.sleep(0.5)
        except release.HarnessError:
            pass
        raise AcceptanceFailed("network_cleanup_failed")

def canonical_json(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def run_server_audit(env, nonce, account, artifact_sha256, started_ms, finished_ms,
                     transcript_sha256):
    command_text = env.get("OVID_AUDIO_SERVER_AUDIT_COMMAND", "")
    key_text = env.get("OVID_AUDIO_SERVER_AUDIT_HMAC_KEY", "")
    try:
        command = shlex.split(command_text)
        key = bytes.fromhex(key_text)
    except (ValueError, TypeError):
        raise Blocked("server_audit_configuration_invalid") from None
    if not command or len(key) < 32:
        raise Blocked("server_audit_not_configured")
    child_env = dict(env)
    child_env.update({
        "OVID_AUDIO_AUDIT_RUN_NONCE": nonce,
        "OVID_AUDIO_AUDIT_ACCOUNT": account,
        "OVID_AUDIO_AUDIT_ACCOUNT_RUN_KEY_SHA256": account_run_key(nonce, account),
        "OVID_AUDIO_AUDIT_ARTIFACT_SHA256": artifact_sha256,
        "OVID_AUDIO_AUDIT_RUN_STARTED_MS": str(started_ms),
        "OVID_AUDIO_AUDIT_RUN_FINISHED_MS": str(finished_ms),
        "OVID_AUDIO_AUDIT_EXPECT_TRANSCRIPT_SHA256": transcript_sha256,
    })
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=120, env=child_env, check=False)
    except (OSError, subprocess.SubprocessError):
        raise Blocked("authorized_server_audit_unavailable") from None
    if result.returncode or not result.stdout or len(result.stdout) > MAX_SERVER_AUDIT_BYTES:
        raise Blocked("authorized_server_audit_unavailable")
    try:
        audit = json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError):
        raise AcceptanceFailed("server_audit_invalid") from None
    if not isinstance(audit, dict):
        raise AcceptanceFailed("server_audit_invalid")
    return audit


def validate_server_audit(audit, nonce, account, artifact_sha256, started_ms,
                          finished_ms, transcript_sha256, key_text, minimum_messages):
    """Authenticate a fresh backend+object-store audit; retain counts/digests only."""
    try:
        key = bytes.fromhex(key_text)
        supplied = audit.get("signature")
        if len(key) < 32 or not isinstance(supplied, str) or not HEX64.fullmatch(supplied):
            raise AcceptanceFailed("server_audit_invalid")
        payload = {key_name: value for key_name, value in audit.items() if key_name != "signature"}
        expected = hmac.new(key, canonical_json(payload), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, supplied):
            raise AcceptanceFailed("server_audit_invalid")
        if (payload.get("schema") != SERVER_AUDIT_SCHEMA
                or payload.get("run_nonce_sha256") != sha256_text(nonce)
                or payload.get("account_run_key_sha256") != account_run_key(nonce, account)
                or payload.get("artifact_sha256") != artifact_sha256
                or payload.get("run_started_ms") != started_ms
                or payload.get("run_finished_ms") != finished_ms
                or payload.get("scope") != "ovid_gateway_and_object_storage"
                or payload.get("read_only") is not True):
            raise AcceptanceFailed("server_audit_invalid")
        queried_ms = payload.get("queried_ms")
        now_ms = int(time.time() * 1000)
        if (type(queried_ms) is not int or queried_ms < finished_ms
                or queried_ms > now_ms + 5000):
            raise AcceptanceFailed("server_audit_stale_or_future")
        requests = payload.get("requests") or {}
        storage = payload.get("storage") or {}
        numeric_requests = {}
        for name in (
                "total", "message_json", "text_only_message_json", "multipart",
                "audio_mime", "audio_fields", "attachment_uploads",
                "websocket_binary_frames", "unclassified"):
            value = requests.get(name)
            if type(value) is not int or value < 0:
                raise AcceptanceFailed("server_audit_invalid")
            numeric_requests[name] = value
        if (numeric_requests["message_json"] < minimum_messages
                or numeric_requests["text_only_message_json"] != numeric_requests["message_json"]
                or numeric_requests["message_json"] > numeric_requests["total"]):
            raise AcceptanceFailed("server_audit_scope_incomplete")
        forbidden = (
            "multipart", "audio_mime", "audio_fields", "attachment_uploads",
            "websocket_binary_frames", "unclassified")
        if any(numeric_requests[name] for name in forbidden):
            raise AcceptanceFailed("audio_upload_detected")
        posts = payload.get("transcript_post_sha256s")
        if (not isinstance(posts, list) or len(posts) > 16
                or any(not isinstance(value, str) or not HEX64.fullmatch(value) for value in posts)
                or posts.count(transcript_sha256) != 1):
            raise AcceptanceFailed("recognized_transcript_post_not_proven")
        storage_values = {}
        for name in ("audio_objects", "audio_records", "audio_bytes"):
            value = storage.get(name)
            if type(value) is not int or value < 0:
                raise AcceptanceFailed("server_audit_invalid")
            storage_values[name] = value
        if storage.get("scan_complete") is not True:
            raise AcceptanceFailed("server_storage_audit_incomplete")
        if any(storage_values.values()):
            raise AcceptanceFailed("server_audio_storage_detected")
        network = {
            "scope": "authorized_ovid_backend_and_object_storage",
            "audit_authenticated": True,
            "audit_fresh": True,
            "request_count": numeric_requests["total"],
            "json_message_requests": numeric_requests["message_json"],
            "text_only_message_requests": numeric_requests["text_only_message_json"],
            "recognized_transcript_post_observed": True,
            "recognized_transcript_post_sha256": transcript_sha256,
            "forbidden": {name: numeric_requests[name] for name in forbidden},
        }
        sanitized_storage = {
            "server_audio_objects": storage_values["audio_objects"],
            "server_audio_records": storage_values["audio_records"],
            "server_audio_bytes": storage_values["audio_bytes"],
            "scan_complete": True,
        }
        return network, sanitized_storage
    except AcceptanceFailed:
        raise
    except (AttributeError, TypeError, ValueError):
        raise AcceptanceFailed("server_audit_invalid") from None


def validate_tts_locale(trace, expected_locale):
    errors = []
    if trace.get("requested_locale") != expected_locale:
        errors.append("tts_requested_locale_mismatch")
    if trace.get("resolved_locale") != expected_locale:
        errors.append("tts_resolved_locale_mismatch")
    return errors


def parse_tts_evidence(raw, require_done=True, device_pid=None):
    """Read only the release PID's structured, content-free native metadata."""
    events = {"accepted": [], "start": [], "done": []}
    pattern = re.compile(
        r"v3 event=(accepted|start|done) logical=([A-Za-z0-9_.:-]{1,96}) "
        r"native=([A-Za-z0-9_.:-]{1,128}) requested=([A-Za-z0-9_.:-]{1,96}) "
        r"resolved=([A-Za-z0-9_.:-]{1,96}) epochMs=(\d+)")
    for line in raw.splitlines():
        if "OvidTtsEvidence:" not in line:
            continue
        match = pattern.search(line)
        if match is None:
            raise Blocked("tts_evidence_format_unknown")
        event, logical, native, requested, resolved, epoch = match.groups()
        events[event].append({
            "logical": logical,
            "native": native,
            "requested": requested,
            "resolved": resolved,
            "epoch": int(epoch),
        })
    if len(events["accepted"]) != 1 or len(events["start"]) != 1 or len(events["done"]) > 1:
        raise AcceptanceFailed("tts_evidence_identity_ambiguous")
    if require_done and len(events["done"]) != 1:
        raise Blocked("tts_completion_evidence_missing")
    accepted = events["accepted"][0]
    started = events["start"][0]
    done = events["done"][0] if events["done"] else None
    for event in [started] + ([done] if done else []):
        if any(event[key] != accepted[key] for key in ("logical", "native", "requested", "resolved")):
            raise AcceptanceFailed("tts_utterance_identity_mismatch")
    # UID/session identity is deliberately absent. Stock unprivileged Android
    # configurations are anonymized and cannot supply independent provenance.
    return {
        "source": "ovid.release.logcat",
        "channel": "ovid.tts.utterance",
        "requested_locale": accepted["requested"],
        "resolved_locale": accepted["resolved"],
        "utterance_id": accepted["logical"],
        "native_utterance_id": accepted["native"],
        "device_process_id": device_pid,
        "accepted_device_ms": accepted["epoch"],
        "started_device_ms": started["epoch"],
        "completed_device_ms": done["epoch"] if done else None,
    }


def validate_tts_trace(trace, expected_locale, require_complete=True):
    errors = validate_tts_locale(trace, expected_locale)
    if (trace.get("source") != "ovid.release.logcat"
            or trace.get("channel") != "ovid.tts.utterance"):
        errors.append("tts_evidence_source_invalid")
    logical = trace.get("utterance_id")
    native = trace.get("native_utterance_id")
    if (not isinstance(logical, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,96}", logical)
            or not isinstance(native, str)
            or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", native)
            or not native.startswith(logical + ":synthesis-")):
        errors.append("tts_utterance_identity_invalid")
    if type(trace.get("device_process_id")) is not int or trace["device_process_id"] <= 0:
        errors.append("tts_device_process_invalid")
    timestamps = [trace.get(name) for name in (
        "accepted_device_ms", "started_device_ms", "completed_device_ms")]
    if any(type(value) is not int for value in timestamps[:2]):
        errors.append("tts_timestamp_invalid")
        return errors
    if require_complete and type(timestamps[2]) is not int:
        errors.append("tts_completion_evidence_missing")
        return errors
    if timestamps[1] < timestamps[0]:
        errors.append("tts_timestamp_order_invalid")
    if timestamps[2] is not None and timestamps[2] <= timestamps[1]:
        errors.append("tts_timestamp_order_invalid")
    return list(dict.fromkeys(errors))


def sanitize_tts_trace(trace):
    return {
        "requested_locale": trace.get("requested_locale"),
        "resolved_locale": trace.get("resolved_locale"),
        "utterance_id_sha256": sha256_text(trace.get("utterance_id", "")),
        "native_utterance_id_sha256": sha256_text(trace.get("native_utterance_id", "")),
        "utterance_source": trace.get("source"),
        "utterance_channel": trace.get("channel"),
        "device_process_id": trace.get("device_process_id"),
        "accepted_device_ms": trace.get("accepted_device_ms"),
        "started_device_ms": trace.get("started_device_ms"),
        "completed_device_ms": trace.get("completed_device_ms"),
    }


CLOCK_MAX_OFFSET_STEP_MS = 20
CLOCK_MAX_ANCHOR_GAP_MS = 4000
CLOCK_MIN_ANCHORS = 3


class ClockAnchorSeries:
    """Repeated host/device anchors with explicit step, drift and gap budgets."""

    def __init__(self, device):
        self.device = device
        self.anchors = []

    def sample(self, phase):
        if hasattr(self.device, "sample_clock"):
            value = self.device.sample_clock(phase)
        else:
            value = self.device.clock_anchor()
        if not isinstance(value, dict):
            raise Blocked("device_clock_unavailable")
        self.anchors.append(dict(value, phase=phase))

    def validate(self, capture):
        if len(self.anchors) < CLOCK_MIN_ANCHORS:
            raise Blocked("repeated_clock_anchors_required")
        anchors = self.anchors
        required = (
            "offset_ms", "uncertainty_ms", "monotonic_ns",
            "device_wall_ms", "host_wall_ms",
        )
        for anchor in anchors:
            if any(type(anchor.get(name)) not in (int, float) for name in required):
                raise Blocked("device_clock_unavailable")
            if (not math.isfinite(anchor["offset_ms"])
                    or abs(anchor["offset_ms"]) > 5000
                    or type(anchor["uncertainty_ms"]) is not int
                    or not 1 <= anchor["uncertainty_ms"] <= 26):
                raise Blocked("device_clock_uncertainty_exceeded")
        max_gap_ms = 0
        max_step_ms = 0
        for index, anchor in enumerate(anchors):
            if index == 0:
                continue
            previous = anchors[index - 1]
            monotonic_gap = anchor["monotonic_ns"] - previous["monotonic_ns"]
            if (monotonic_gap <= 0 or anchor["host_wall_ms"] < previous["host_wall_ms"]
                    or anchor["device_wall_ms"] < previous["device_wall_ms"]):
                raise Blocked("device_clock_regression")
            gap_ms = monotonic_gap / 1_000_000
            max_gap_ms = max(max_gap_ms, gap_ms)
            if gap_ms > CLOCK_MAX_ANCHOR_GAP_MS:
                raise Blocked("clock_anchor_gap_exceeded")
            step_ms = abs(anchor["offset_ms"] - previous["offset_ms"])
            max_step_ms = max(max_step_ms, step_ms)
            if step_ms > CLOCK_MAX_OFFSET_STEP_MS:
                raise Blocked("clock_step_detected")
        offset_drift = max(anchor["offset_ms"] for anchor in anchors) - min(
            anchor["offset_ms"] for anchor in anchors)
        if offset_drift > CLOCK_MAX_OFFSET_STEP_MS:
            raise Blocked("clock_drift_exceeded")
        first_frame_ns = capture.get("first_pcm_frame_monotonic_ns")
        last_frame_ns = capture.get("last_pcm_frame_monotonic_ns")
        if type(first_frame_ns) is not int or type(last_frame_ns) is not int:
            raise Blocked("capture_first_frame_timing_unavailable")
        if (anchors[0]["monotonic_ns"] > first_frame_ns
                or anchors[-1]["monotonic_ns"] < last_frame_ns
                or not any(first_frame_ns < anchor["monotonic_ns"] < last_frame_ns
                           for anchor in anchors[1:-1])):
            raise Blocked("clock_anchors_do_not_bracket_capture")
        offsets = sorted(anchor["offset_ms"] for anchor in anchors)
        return {
            "series_validated": True,
            "clock_model": "repeated_bounded_anchors",
            "anchor_count": len(anchors),
            "offset_ms": offsets[len(offsets) // 2],
            "uncertainty_ms": max(anchor["uncertainty_ms"] for anchor in anchors) + math.ceil(max_step_ms),
            "max_offset_step_ms": max_step_ms,
            "max_offset_drift_ms": offset_drift,
            "max_anchor_gap_ms": max_gap_ms,
            "monotonic_bracketed": True,
            "first_anchor_monotonic_ns": anchors[0]["monotonic_ns"],
            "last_anchor_monotonic_ns": anchors[-1]["monotonic_ns"],
        }


def capture_window_bounds(trace, capture, anchor):
    """Map native utterance bounds onto the measured first PCM frame timeline."""
    if (type(anchor.get("offset_ms")) not in (int, float)
            or not math.isfinite(anchor["offset_ms"])
            or abs(anchor["offset_ms"]) > 5000
            or anchor.get("series_validated") is not True
            or anchor.get("clock_model") != "repeated_bounded_anchors"
            or type(anchor.get("anchor_count")) is not int
            or anchor["anchor_count"] < CLOCK_MIN_ANCHORS
            or anchor.get("monotonic_bracketed") is not True
            or type(anchor.get("max_offset_step_ms")) not in (int, float)
            or anchor["max_offset_step_ms"] > CLOCK_MAX_OFFSET_STEP_MS
            or type(anchor.get("max_anchor_gap_ms")) not in (int, float)
            or anchor["max_anchor_gap_ms"] > CLOCK_MAX_ANCHOR_GAP_MS
            or type(anchor.get("uncertainty_ms")) is not int
            or anchor["uncertainty_ms"] < 1 or anchor["uncertainty_ms"] > 125):
        raise Blocked("device_clock_uncertainty_exceeded")
    accepted_device = trace.get("accepted_device_ms")
    started_device = trace.get("started_device_ms")
    completed_device = trace.get("completed_device_ms")
    if (type(accepted_device) is not int or type(started_device) is not int
            or type(completed_device) is not int
            or not accepted_device <= started_device < completed_device):
        raise Blocked("tts_utterance_interval_unavailable")
    integer_fields = (
        "first_pcm_frame_host_us", "first_pcm_frame_monotonic_ns",
        "first_pcm_frame_uncertainty_us", "source_latency_us",
        "max_source_latency_us", "capture_timing_uncertainty_us", "sample_count",
        "sample_rate", "channels", "frame_count",
        "last_pcm_frame_host_us", "last_pcm_frame_monotonic_ns",
        "cumulative_discontinuity_us",
    )
    if any(type(capture.get(name)) is not int for name in integer_fields):
        raise Blocked("capture_first_frame_timing_unavailable")
    if (type(capture.get("end_to_end_discontinuity_us")) not in (int, float)
            or not math.isfinite(capture["end_to_end_discontinuity_us"])
            or capture["end_to_end_discontinuity_us"] < 0):
        raise Blocked("capture_first_frame_timing_unavailable")
    expected_duration_us = capture["sample_count"] * 1_000_000 / capture["sample_rate"]
    if (capture["first_pcm_frame_host_us"] <= 0
            or capture["first_pcm_frame_monotonic_ns"] <= 0
            or capture["first_pcm_frame_uncertainty_us"] <= 0
            or capture["capture_timing_uncertainty_us"] <= 0
            or capture["source_latency_us"] < 0
            or capture["max_source_latency_us"] < capture["source_latency_us"]
            or capture["first_pcm_frame_uncertainty_us"] < capture["source_latency_us"]
            or capture["capture_timing_uncertainty_us"] < capture["max_source_latency_us"]
            or capture["sample_count"] <= 0 or capture["frame_count"] <= 0
            or capture["sample_rate"] != SAMPLE_RATE or capture["channels"] != 1
            or capture.get("sample_format") != "s16le"
            or capture.get("last_emitted_frame_timestamp_validated") is not True
            or capture["cumulative_discontinuity_us"] > pulse_capture.MAX_CUMULATIVE_DISCONTINUITY_US
            or capture["end_to_end_discontinuity_us"] > pulse_capture.MAX_END_TO_END_DISCONTINUITY_US
            or abs(capture["last_pcm_frame_host_us"] - capture["first_pcm_frame_host_us"]
                   - expected_duration_us) > pulse_capture.MAX_END_TO_END_DISCONTINUITY_US
            or abs((capture["last_pcm_frame_monotonic_ns"]
                    - capture["first_pcm_frame_monotonic_ns"]) / 1000
                   - expected_duration_us) > pulse_capture.MAX_END_TO_END_DISCONTINUITY_US
            or capture.get("timing_source") != "pulse_simple_latency_backdated_frames"):
        raise Blocked("capture_first_frame_timing_unavailable")
    capture_uncertainty_us = max(
        capture["first_pcm_frame_uncertainty_us"],
        capture["capture_timing_uncertainty_us"],
        capture["cumulative_discontinuity_us"],
        capture["end_to_end_discontinuity_us"],
    )
    total_uncertainty_us = (
        capture_uncertainty_us + anchor["uncertainty_ms"] * 1000 + 2000)
    if total_uncertainty_us > 2_000_000:
        raise Blocked("capture_timing_uncertainty_exceeded")
    first_device_ms = capture["first_pcm_frame_host_us"] / 1000 + anchor["offset_ms"]
    if first_device_ms <= 0:
        raise Blocked("capture_first_frame_timing_unavailable")
    first_mono_ns = capture["first_pcm_frame_monotonic_ns"]
    guard_us = total_uncertainty_us + 100_000
    pcm_start = (started_device - first_device_ms) * 1000 + guard_us
    pcm_end = (completed_device - first_device_ms) * 1000 - guard_us
    # Include no sample outside the guarded interval. Quantize once so the
    # selected-window duration and pcm_metrics agree at fractional clock offsets.
    start_sample = math.ceil(pcm_start * SAMPLE_RATE / 1_000_000)
    end_sample = math.floor(pcm_end * SAMPLE_RATE / 1_000_000)
    if start_sample < 0 or end_sample - start_sample < SAMPLE_RATE // 4:
        raise Blocked("tts_utterance_interval_too_short")
    if end_sample > capture["sample_count"]:
        raise Blocked("tts_utterance_capture_window_unavailable")
    pcm_start_ms = start_sample * 1000 / SAMPLE_RATE
    pcm_end_ms = end_sample * 1000 / SAMPLE_RATE
    start_offset_ns = round((started_device - first_device_ms) * 1_000_000)
    end_offset_ns = round((completed_device - first_device_ms) * 1_000_000)
    return {
        "source": "ovid.native.utterance_bounds",
        "channel": "ovid.tts.utterance",
        "timing_source": capture["timing_source"],
        "first_pcm_frame_host_us": capture["first_pcm_frame_host_us"],
        "first_pcm_frame_monotonic_ns": first_mono_ns,
        "first_pcm_frame_device_ms": first_device_ms,
        "first_pcm_frame_uncertainty_us": capture["first_pcm_frame_uncertainty_us"],
        "source_latency_us": capture["source_latency_us"],
        "max_source_latency_us": capture["max_source_latency_us"],
        "capture_timing_uncertainty_us": capture["capture_timing_uncertainty_us"],
        "capture_sample_count": capture["sample_count"],
        "sample_rate": capture["sample_rate"],
        "channels": capture["channels"],
        "sample_format": capture["sample_format"],
        "frame_count": capture["frame_count"],
        "last_pcm_frame_host_us": capture["last_pcm_frame_host_us"],
        "last_pcm_frame_monotonic_ns": capture["last_pcm_frame_monotonic_ns"],
        "cumulative_discontinuity_us": capture["cumulative_discontinuity_us"],
        "end_to_end_discontinuity_us": capture["end_to_end_discontinuity_us"],
        "last_emitted_frame_timestamp_validated": True,
        "clock_anchor_count": anchor["anchor_count"],
        "clock_max_offset_step_ms": anchor["max_offset_step_ms"],
        "clock_max_anchor_gap_ms": anchor["max_anchor_gap_ms"],
        "clock_monotonic_bracketed": True,
        "host_device_offset_ms": anchor["offset_ms"],
        "device_clock_uncertainty_ms": anchor["uncertainty_ms"],
        "clock_uncertainty_us": total_uncertainty_us,
        "interval_guard_ms": guard_us / 1000,
        "utterance_started_monotonic_ns": first_mono_ns + start_offset_ns,
        "utterance_completed_monotonic_ns": first_mono_ns + end_offset_ns,
        "pcm_start_ms": pcm_start_ms,
        "pcm_end_ms": pcm_end_ms,
    }


def utterance_capture_metrics(capture, trace, anchor):
    bounds = capture_window_bounds(trace, capture, anchor)
    if len(capture.get("pcm", b"")) // 2 != capture["sample_count"]:
        raise Blocked("capture_sample_count_mismatch")
    try:
        selected = pcm_window(capture["pcm"], bounds["pcm_start_ms"], bounds["pcm_end_ms"])
    except (KeyError, ValueError):
        raise Blocked("tts_utterance_capture_window_unavailable") from None
    return pcm_metrics(selected), bounds


EXCLUSIVE_CAPTURE_SCHEMA = "ovid.android.audio.exclusive-capture/v1"
EXCLUSIVE_MAX_CALLBACK_GAP_MS = 1000
NATIVE_CALLBACK_TRANSITIONS = {"start", "complete", "stop"}
NONPUBLIC_IDENTITY_FIELDS = {
    "device_uid", "audio_session_id", "audioSessionId", "clientUid", "clientPid",
    "client_uid", "client_session", "sessionId", "uid", "session",
    "playerState", "playerInterfaceId",
}


def reject_nonpublic_identity(value):
    if isinstance(value, dict):
        if any(key in value for key in NONPUBLIC_IDENTITY_FIELDS):
            raise Blocked("nonpublic_player_identity_unavailable")
        for child in value.values():
            reject_nonpublic_identity(child)
    elif isinstance(value, list):
        for child in value:
            reject_nonpublic_identity(child)


def _signed_audit_payload(audit, key_text):
    try:
        key = bytes.fromhex(key_text)
        supplied = audit.get("signature")
        if len(key) < 32 or not isinstance(supplied, str) or not HEX64.fullmatch(supplied):
            raise AcceptanceFailed("exclusive_capture_audit_invalid")
        payload = {name: value for name, value in audit.items() if name != "signature"}
        expected = hmac.new(key, canonical_json(payload), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expected, supplied):
            raise AcceptanceFailed("exclusive_capture_audit_invalid")
        return payload
    except AcceptanceFailed:
        raise
    except (AttributeError, TypeError, ValueError):
        raise AcceptanceFailed("exclusive_capture_audit_invalid") from None


def coverage_required_window(bounds, segment=None):
    uncertainty_ms = bounds["clock_uncertainty_us"] / 1000
    if segment is None:
        start = bounds["first_pcm_frame_device_ms"] + bounds["pcm_start_ms"]
        end = bounds["first_pcm_frame_device_ms"] + bounds["pcm_end_ms"]
    else:
        start = segment.get("start_device_ms")
        end = segment.get("end_device_ms")
        if type(start) not in (int, float) or type(end) not in (int, float):
            raise Blocked("playback_coverage_interval_invalid")
    if end <= start:
        raise Blocked("playback_coverage_interval_invalid")
    return (
        math.floor(start - uncertainty_ms - 1),
        math.ceil(end + uncertainty_ms + 1),
    )


def validate_exclusive_capture_audit(audit, key_text, nonce, trace, capture, bounds,
                                     segment=None):
    """Authenticate a future truly exclusive external capture connector.

    Stock Android UID/session configurations are never accepted here. The
    connector must independently supply native player lifecycle callbacks and
    exact sample/interval identity, not an attestation inferred from PCM energy.
    """
    if not isinstance(audit, dict):
        raise AcceptanceFailed("exclusive_capture_audit_invalid")
    reject_nonpublic_identity(audit)
    payload = _signed_audit_payload(audit, key_text)
    required_start, required_end = coverage_required_window(bounds, segment)
    events = payload.get("callback_events")
    if not isinstance(events, list) or not 2 <= len(events) <= 256:
        raise Blocked("native_player_callbacks_required")
    if (payload.get("native_callback_count") != len(events)
            or payload.get("manual_snapshot_count") != 0):
        raise Blocked("native_player_callbacks_required")
    if payload.get("unattributed_transitions") != 0:
        raise Blocked("playback_unattributed_transition")
    if payload.get("duplicate_configurations") != 0:
        raise Blocked("playback_configuration_ambiguous")
    expected = {
        "schema": EXCLUSIVE_CAPTURE_SCHEMA,
        "run_nonce_sha256": sha256_text(nonce),
        "utterance_id_sha256": sha256_text(trace.get("utterance_id", "")),
        "native_utterance_id_sha256": sha256_text(trace.get("native_utterance_id", "")),
        "source": "authorized_exclusive_capture_connector",
        "session_exclusive": True,
        "whole_interval": True,
        "required_start_device_ms": required_start,
        "required_end_device_ms": required_end,
        "first_pcm_frame_host_us": capture.get("first_pcm_frame_host_us"),
        "last_pcm_frame_host_us": capture.get("last_pcm_frame_host_us"),
        "sample_rate": SAMPLE_RATE,
        "channels": 1,
        "sample_format": "s16le",
        "sample_count": capture.get("sample_count"),
        "native_callback_count": len(payload.get("callback_events") or []),
        "manual_snapshot_count": 0,
        "unattributed_transitions": 0,
        "unmatched_output_events": 0,
        "matched_track_gaps": 0,
        "duplicate_configurations": 0,
    }
    for name, value in expected.items():
        if payload.get(name) != value:
            raise AcceptanceFailed("exclusive_capture_audit_mismatch")
    if not isinstance(payload.get("capture_route_sha256"), str) or not HEX64.fullmatch(
            payload["capture_route_sha256"]):
        raise AcceptanceFailed("exclusive_capture_route_invalid")
    queried_ms = payload.get("queried_ms")
    if (type(queried_ms) is not int or queried_ms < trace.get("completed_device_ms", 0)
            or queried_ms > int(time.time() * 1000) + 5000):
        raise AcceptanceFailed("exclusive_capture_audit_stale")
    max_gap = 0
    start_seen = False
    complete_seen = False
    for index, event in enumerate(events):
        if not isinstance(event, dict) or set(event) != {
                "sequence", "kind", "type", "epoch_ms"}:
            raise Blocked("native_player_callback_record_invalid")
        if event["kind"] != "native_callback" or event["type"] not in NATIVE_CALLBACK_TRANSITIONS:
            raise Blocked("manual_snapshot_cannot_be_callback")
        # One genuine lifecycle only: first=start, last=complete XOR stop.
        # No repeated start, repeated terminal, or post-terminal record can
        # contribute to sequence, gap, or interval coverage.
        if index == 0:
            if event["type"] != "start":
                raise Blocked("native_player_lifecycle_order_invalid")
        elif event["type"] == "start":
            raise Blocked("native_player_lifecycle_order_invalid")
        is_terminal = event["type"] in ("complete", "stop")
        if is_terminal != (index == len(events) - 1):
            raise Blocked("native_player_lifecycle_order_invalid")
        if (type(event["sequence"]) is not int
                or type(event["epoch_ms"]) is not int
                or (index > 0 and event["sequence"] != events[index - 1]["sequence"] + 1)):
            raise Blocked("native_player_callback_sequence_gap")
        if index > 0:
            gap = event["epoch_ms"] - events[index - 1]["epoch_ms"]
            if gap < 0:
                raise Blocked("native_player_callback_clock_regression")
            max_gap = max(max_gap, gap)
            if gap > EXCLUSIVE_MAX_CALLBACK_GAP_MS:
                raise Blocked("native_player_callback_liveness_gap")
        if index == 0 and (
                trace["started_device_ms"] <= event["epoch_ms"]
                <= trace["started_device_ms"] + EXCLUSIVE_MAX_CALLBACK_GAP_MS):
            start_seen = True
        if index == len(events) - 1 and (
                trace["completed_device_ms"] <= event["epoch_ms"]
                <= trace["completed_device_ms"] + EXCLUSIVE_MAX_CALLBACK_GAP_MS):
            complete_seen = True
    if (events[0]["epoch_ms"] > required_start
            or events[-1]["epoch_ms"] < required_end):
        raise Blocked("exclusive_capture_interval_not_covered")
    if not start_seen or not complete_seen:
        raise Blocked("native_player_utterance_transitions_missing")
    return {
        "coverage_type": (
            "background_segment_exclusive_capture" if segment is not None
            else "whole_interval_exclusive_capture"),
        "source": "authorized_exclusive_capture_connector",
        "capture_route_sha256": payload["capture_route_sha256"],
        "session_exclusive": True,
        "whole_interval": True,
        "native_callback_sequence_complete": True,
        "utterance_start_callback_observed": True,
        "utterance_completion_callback_observed": True,
        "utterance_id_sha256": expected["utterance_id_sha256"],
        "native_utterance_id_sha256": expected["native_utterance_id_sha256"],
        "callback_sequence_sha256": sha256_bytes(canonical_json(events)),
        "event_count": len(events),
        "native_callback_count": len(events),
        "manual_snapshot_count": 0,
        "unattributed_transitions": 0,
        "unmatched_output_events": 0,
        "matched_track_gaps": 0,
        "duplicate_configurations": 0,
        "required_start_device_ms": required_start,
        "required_end_device_ms": required_end,
        "first_observed_device_ms": events[0]["epoch_ms"],
        "last_observed_device_ms": events[-1]["epoch_ms"],
        "max_observed_gap_ms": max_gap,
        "capture_uncertainty_us": bounds["clock_uncertainty_us"],
        "sample_rate": SAMPLE_RATE,
        "channels": 1,
        "sample_format": "s16le",
        "sample_count": capture["sample_count"],
    }


EXCLUSIVE_EVIDENCE_FIELDS = {
    "coverage_type", "source", "capture_route_sha256", "session_exclusive",
    "whole_interval", "native_callback_sequence_complete",
    "utterance_start_callback_observed", "utterance_completion_callback_observed",
    "utterance_id_sha256", "native_utterance_id_sha256",
    "callback_sequence_sha256", "event_count", "native_callback_count",
    "manual_snapshot_count", "unattributed_transitions", "unmatched_output_events",
    "matched_track_gaps", "duplicate_configurations", "required_start_device_ms",
    "required_end_device_ms", "first_observed_device_ms", "last_observed_device_ms",
    "max_observed_gap_ms", "capture_uncertainty_us", "sample_rate", "channels",
    "sample_format", "sample_count",
}


def validate_exclusive_capture(evidence, bounds):
    errors = []
    if set(evidence) != EXCLUSIVE_EVIDENCE_FIELDS:
        errors.append("exclusive_capture_fields_invalid")
    try:
        reject_nonpublic_identity(evidence)
    except Blocked:
        return ["nonpublic_player_identity_unavailable"]
    coverage_type = evidence.get("coverage_type")
    if coverage_type not in (
            "whole_interval_exclusive_capture", "background_segment_exclusive_capture"):
        errors.append("exclusive_capture_type_invalid")
        return errors
    expected = {
        "source": "authorized_exclusive_capture_connector",
        "session_exclusive": True,
        "whole_interval": True,
        "native_callback_sequence_complete": True,
        "utterance_start_callback_observed": True,
        "utterance_completion_callback_observed": True,
        "manual_snapshot_count": 0,
        "unattributed_transitions": 0,
        "unmatched_output_events": 0,
        "matched_track_gaps": 0,
        "duplicate_configurations": 0,
        "sample_rate": SAMPLE_RATE,
        "channels": 1,
        "sample_format": "s16le",
        "sample_count": bounds.get("capture_sample_count"),
        "capture_uncertainty_us": bounds.get("clock_uncertainty_us"),
    }
    for name, value in expected.items():
        if evidence.get(name) != value:
            errors.append("exclusive_capture_" + name + "_invalid")
    for name in ("capture_route_sha256", "utterance_id_sha256",
                 "native_utterance_id_sha256", "callback_sequence_sha256"):
        if not isinstance(evidence.get(name), str) or not HEX64.fullmatch(evidence[name]):
            errors.append("exclusive_capture_identity_invalid")
    if (type(evidence.get("event_count")) is not int
            or type(evidence.get("native_callback_count")) is not int
            or evidence["native_callback_count"] != 2
            or evidence["event_count"] != 2):
        errors.append("native_player_callbacks_required")
    required_start = evidence.get("required_start_device_ms")
    required_end = evidence.get("required_end_device_ms")
    if type(required_start) is not int or type(required_end) is not int or required_end <= required_start:
        errors.append("exclusive_capture_interval_invalid")
        return list(dict.fromkeys(errors))
    if coverage_type == "whole_interval_exclusive_capture":
        try:
            if (required_start, required_end) != coverage_required_window(bounds):
                errors.append("exclusive_capture_interval_mismatch")
        except (Blocked, KeyError, TypeError, ValueError):
            errors.append("exclusive_capture_interval_mismatch")
    first_observed = evidence.get("first_observed_device_ms")
    last_observed = evidence.get("last_observed_device_ms")
    if (type(first_observed) is not int or type(last_observed) is not int
            or first_observed > required_start or last_observed < required_end):
        errors.append("exclusive_capture_interval_not_covered")
    max_gap = evidence.get("max_observed_gap_ms")
    if (type(max_gap) is not int
            or not 0 < max_gap <= EXCLUSIVE_MAX_CALLBACK_GAP_MS):
        errors.append("native_player_callback_liveness_gap")
    elif (type(first_observed) is int and type(last_observed) is int
            and last_observed - first_observed != max_gap):
        # Exactly two raw transitions means their endpoint delta is the only
        # gap; a sanitized aggregate cannot underreport a longer lifecycle.
        errors.append("native_player_callback_liveness_gap")
    return list(dict.fromkeys(errors))


def run_exclusive_capture_audit(env, nonce, trace, capture, bounds, segment=None):
    command_text = env.get("OVID_AUDIO_EXCLUSIVE_CAPTURE_COMMAND", "")
    key_text = env.get("OVID_AUDIO_EXCLUSIVE_CAPTURE_HMAC_KEY", "")
    if not command_text:
        raise Blocked("session_exclusive_capture_unavailable")
    try:
        command = shlex.split(command_text)
        if not command or len(bytes.fromhex(key_text)) < 32:
            raise Blocked("session_exclusive_capture_unavailable")
    except ValueError:
        raise Blocked("exclusive_capture_configuration_invalid") from None
    required_start, required_end = coverage_required_window(bounds, segment)
    child_env = dict(env)
    child_env.update({
        "OVID_AUDIO_EXCLUSIVE_RUN_NONCE": nonce,
        "OVID_AUDIO_EXCLUSIVE_UTTERANCE_SHA256": sha256_text(trace["utterance_id"]),
        "OVID_AUDIO_EXCLUSIVE_NATIVE_UTTERANCE_SHA256": sha256_text(trace["native_utterance_id"]),
        "OVID_AUDIO_EXCLUSIVE_REQUIRED_START_MS": str(required_start),
        "OVID_AUDIO_EXCLUSIVE_REQUIRED_END_MS": str(required_end),
        "OVID_AUDIO_EXCLUSIVE_FIRST_FRAME_HOST_US": str(capture["first_pcm_frame_host_us"]),
        "OVID_AUDIO_EXCLUSIVE_LAST_FRAME_HOST_US": str(capture["last_pcm_frame_host_us"]),
        "OVID_AUDIO_EXCLUSIVE_SAMPLE_COUNT": str(capture["sample_count"]),
        "OVID_AUDIO_EXCLUSIVE_SAMPLE_RATE": str(SAMPLE_RATE),
        "OVID_AUDIO_EXCLUSIVE_CHANNELS": "1",
        "OVID_AUDIO_EXCLUSIVE_SAMPLE_FORMAT": "s16le",
        "OVID_AUDIO_EXCLUSIVE_UTTERANCE_STARTED_MS": str(trace["started_device_ms"]),
        "OVID_AUDIO_EXCLUSIVE_UTTERANCE_COMPLETED_MS": str(trace["completed_device_ms"]),
    })
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=120, env=child_env, check=False)
    except (OSError, subprocess.SubprocessError):
        raise Blocked("session_exclusive_capture_unavailable") from None
    if result.returncode or not result.stdout or len(result.stdout) > MAX_SERVER_AUDIT_BYTES:
        raise Blocked("session_exclusive_capture_unavailable")
    try:
        audit = json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError):
        raise AcceptanceFailed("exclusive_capture_audit_invalid") from None
    if not isinstance(audit, dict):
        raise AcceptanceFailed("exclusive_capture_audit_invalid")
    return validate_exclusive_capture_audit(
        audit, key_text, nonce, trace, capture, bounds, segment=segment)


def validate_public_tts_case(case):
    errors = validate_tts_locale(case, case.get("expected_locale"))
    if case.get("locale_match") is not True:
        errors.append("tts_locale_match_not_observed")
    for name in ("utterance_id_sha256", "native_utterance_id_sha256"):
        if not isinstance(case.get(name), str) or not HEX64.fullmatch(case[name]):
            errors.append("tts_utterance_identity_invalid")
    if (case.get("utterance_source") != "ovid.release.logcat"
            or case.get("utterance_channel") != "ovid.tts.utterance"):
        errors.append("tts_evidence_source_invalid")
    try:
        reject_nonpublic_identity(case)
    except Blocked:
        errors.append("nonpublic_player_identity_unavailable")
    timestamps = [case.get(name) for name in (
        "accepted_device_ms", "started_device_ms", "completed_device_ms")]
    if any(type(value) is not int for value in timestamps):
        errors.append("tts_timestamp_invalid")
        return list(dict.fromkeys(errors))
    if not timestamps[0] <= timestamps[1] < timestamps[2]:
        errors.append("tts_timestamp_order_invalid")
    bounds = case.get("capture_window") or {}
    capture = {
        name: bounds.get(name) for name in (
            "timing_source", "first_pcm_frame_host_us",
            "first_pcm_frame_monotonic_ns", "first_pcm_frame_uncertainty_us",
            "source_latency_us", "max_source_latency_us",
            "capture_timing_uncertainty_us", "sample_count", "sample_rate",
            "channels", "sample_format", "frame_count",
            "last_pcm_frame_host_us", "last_pcm_frame_monotonic_ns",
            "cumulative_discontinuity_us", "end_to_end_discontinuity_us",
        )
    }
    capture["sample_count"] = bounds.get("capture_sample_count")
    capture["last_emitted_frame_timestamp_validated"] = bounds.get(
        "last_emitted_frame_timestamp_validated")
    try:
        expected_bounds = capture_window_bounds(case, capture, {
            "series_validated": True,
            "clock_model": "repeated_bounded_anchors",
            "anchor_count": bounds.get("clock_anchor_count"),
            "monotonic_bracketed": bounds.get("clock_monotonic_bracketed"),
            "max_offset_step_ms": bounds.get("clock_max_offset_step_ms"),
            "max_anchor_gap_ms": bounds.get("clock_max_anchor_gap_ms"),
            "offset_ms": bounds.get("host_device_offset_ms"),
            "uncertainty_ms": bounds.get("device_clock_uncertainty_ms"),
        })
    except Blocked:
        expected_bounds = None
    if bounds != expected_bounds:
        errors.append("tts_capture_window_correlation_invalid")
        return list(dict.fromkeys(errors))
    output = case.get("output_capture") or {}
    expected_duration = bounds["pcm_end_ms"] - bounds["pcm_start_ms"]
    if (type(output.get("duration_ms")) not in (int, float)
            or abs(output["duration_ms"] - expected_duration) > 0.01):
        errors.append("tts_capture_metrics_window_mismatch")
    exclusive = case.get("exclusive_capture") or {}
    for name in ("utterance_id_sha256", "native_utterance_id_sha256"):
        if exclusive.get(name) != case.get(name):
            errors.append("exclusive_capture_utterance_identity_mismatch")
    errors.extend(validate_exclusive_capture(exclusive, bounds))
    return list(dict.fromkeys(errors))


class AudioAcceptanceFlow:
    def __init__(self, device, audio, network, stimuli, nonce, env=None):
        self.device = device
        self.audio = audio
        self.network = network
        self.stimuli = stimuli
        self.nonce = nonce
        self.env = dict(env or {})
        self.stt_cases = []
        self.tts_cases = []
        self.lifecycle = {}
        self.transcript_post_sha256 = None

    def _baseline(self, source, unavailable_code):
        captured = self.audio.capture(source)
        pcm = captured["pcm"] if isinstance(captured, dict) else captured
        metrics = pcm_metrics(pcm)
        if baseline_errors(metrics):
            raise Blocked("audio_source_busy")
        if metrics["duration_ms"] < 250:
            raise Blocked(unavailable_code)
        return metrics

    def preflight(self):
        self.network.initialize()
        mic_baseline = self._baseline(
            self.audio.mic_monitor, "virtual_microphone_unavailable")
        output_baseline = self._baseline(
            self.audio.output_source, "audio_output_unavailable")
        return {
            "microphone_baseline": mic_baseline,
            "output_baseline": output_baseline,
            **self.device.music_volume(),
        }

    def _run_stt(self, stimulus):
        self.device.clear_composer()
        baseline = self._baseline(
            self.audio.mic_monitor, "virtual_microphone_unavailable")
        before_offline = self.network.offline()
        started = self.device.start_dictation()
        capture = self.audio.start_capture(
            self.audio.mic_monitor, stimulus["public"]["duration_ms"] / 1000 + 5)
        time.sleep(0.5)
        playback = self.audio.start_play(stimulus)
        self.audio.finish_play(playback)
        pcm = self.audio.finish_capture(capture)["pcm"]
        metrics = pcm_metrics(pcm)
        if signal_errors(metrics, baseline):
            raise Blocked("virtual_microphone_signal_unavailable")
        observed = self.device.wait_dictation_result(stimulus["_expected"])
        after_offline = self.network.offline()
        public = {
            "id": stimulus["id"],
            "locale": stimulus["locale"],
            "stimulus_sha256": stimulus["public"]["audio_sha256"],
            "expected_transcript_sha256": stimulus["public"]["expected_transcript_sha256"],
            "offline_before": before_offline,
            "offline_after": after_offline,
            "downloaded_locale_required": True,
            "virtual_microphone_observed": started["active_tracks"] > 0,
            "final_transcript_observed": True,
            "normalized_transcript_match": True,
            "input_capture": metrics,
            "raw_audio_retained": False,
        }
        return public, observed

    def _run_stt_lifecycle(self, stimulus):
        self.device.clear_composer()
        baseline = self._baseline(
            self.audio.mic_monitor, "virtual_microphone_unavailable")
        before = self.device.start_dictation()
        capture = self.audio.start_capture(
            self.audio.mic_monitor, stimulus["public"]["duration_ms"] / 1000 + 5)
        time.sleep(0.5)
        playback = self.audio.start_play(stimulus)
        draft_before_background = self.device.wait_partial_draft(stimulus["_expected"])
        self.device.background()
        self.device.require_foreground(False)
        time.sleep(0.75)
        background_tracks = self.device.observe_tracks("record")
        if not background_tracks["known"]:
            raise Blocked("lifecycle_observation_unavailable")
        if background_tracks["active_tracks"]:
            raise AcceptanceFailed("stt_background_microphone_active")
        self.device.foreground()
        self.device.require_foreground(True)
        self.audio.finish_play(playback)
        pcm = self.audio.finish_capture(capture)["pcm"]
        metrics = pcm_metrics(pcm)
        if signal_errors(metrics, baseline):
            raise Blocked("virtual_microphone_signal_unavailable")
        draft_after_foreground = self.device.composer_text()
        self.device.wait_label(["Voice input"], timeout=15)
        foreground_tracks = self.device.observe_tracks("record")
        if not foreground_tracks["known"]:
            raise Blocked("lifecycle_observation_unavailable")
        unchanged = draft_after_foreground == draft_before_background
        if not unchanged or foreground_tracks["active_tracks"]:
            raise AcceptanceFailed("stt_foreground_auto_resume_detected")
        # Direct fresh-gesture restart and persistence check: no later locale
        # case is allowed to substitute for this observation.
        restart_tracks = self.device.start_dictation()
        draft_at_restart = self.device.composer_text()
        restart_unchanged = draft_at_restart == draft_before_background
        if not restart_unchanged:
            raise AcceptanceFailed("stt_restart_draft_not_preserved")
        self.device.stop_dictation()
        draft_hash = sha256_text(draft_before_background)
        evidence = {
            "stt_background_cancelled": True,
            "stt_background_mic_inactive": True,
            "stt_foreground_no_auto_resume": True,
            "stt_new_gesture_required": True,
            "stt_background_draft_unchanged": unchanged,
            "stt_pre_background_draft_nonempty": bool(
                normalize_transcript(draft_before_background)),
            "stt_pre_background_draft_characters": len(
                normalize_transcript(draft_before_background)),
            "stt_pre_background_draft_sha256": draft_hash,
            "stt_post_foreground_draft_sha256": sha256_text(draft_after_foreground),
            "stt_restart_draft_sha256": sha256_text(draft_at_restart),
            "stt_restart_gesture_observed": True,
            "stt_restart_draft_preserved": restart_unchanged,
            "stt_record_tracks_before": before,
            "stt_record_tracks_background": background_tracks,
            "stt_record_tracks_foreground": foreground_tracks,
            "stt_restart_record_tracks": restart_tracks,
            "stt_lifecycle_input_capture": metrics,
        }
        if validate_stt_lifecycle(evidence):
            raise AcceptanceFailed("stt_lifecycle_contract_failed")
        return evidence

    @staticmethod
    def safe_tts_prompt(nonce):
        suffix = (
            f"{nonce}. Synthetic offline playback uses safe non personal words "
            "for this acceptance check.")
        expected = "Ovid audio acceptance " + suffix
        prompt = (
            "Reply with exactly this sentence, replacing RUN with one space and "
            "adding no commentary: Ovid audio acceptance RUN" + suffix)
        return prompt, expected

    def _run_tts(self, stimulus, lifecycle_case):
        baseline = self._baseline(self.audio.output_source, "audio_output_unavailable")
        clock = ClockAnchorSeries(self.device)
        clock.sample("before_capture")
        capture = self.audio.start_capture(self.audio.output_source, 20)
        clock.sample("capture_started")
        time.sleep(0.75)
        clock.sample("before_playback")
        started = self.device.start_playback(
            stimulus["locale"], on_sample=clock.sample)
        background_bounds = None
        lifecycle = {}
        if lifecycle_case:
            self.device.background()
            self.device.require_foreground(False)
            clock.sample("background_started")
            background_start_ms = time.time_ns() / 1_000_000
            time.sleep(1.0)
            background_end_ms = time.time_ns() / 1_000_000
            clock.sample("background_finished")
            background_bounds = (background_start_ms, background_end_ms)
            self.device.foreground()
            self.device.require_foreground(True)
            clock.sample("foreground_restored")
        completed = self.device.wait_playback_complete(
            started, stimulus["locale"], on_sample=clock.sample)
        clock.sample("before_capture_finish")
        captured = self.audio.finish_capture(capture, on_wait=clock.sample)
        clock.sample("after_capture")
        anchor = clock.validate(captured)
        metrics, bounds = utterance_capture_metrics(captured, completed, anchor)
        # Provenance is evaluated before signal energy. Stock UID/session and
        # callback-less paths BLOCK; loud unrelated PCM cannot rescue them.
        coverage = run_exclusive_capture_audit(
            self.env, self.nonce, completed, captured, bounds)
        if lifecycle_case:
            segment = {
                "start_device_ms": background_bounds[0] + anchor["offset_ms"],
                "end_device_ms": background_bounds[1] + anchor["offset_ms"],
            }
            background_coverage = run_exclusive_capture_audit(
                self.env, self.nonce, completed, captured, bounds, segment=segment)
            if validate_exclusive_capture(background_coverage, bounds):
                raise AcceptanceFailed("tts_background_coverage_invalid")
            start_ms = segment["start_device_ms"] - bounds["first_pcm_frame_device_ms"]
            end_ms = segment["end_device_ms"] - bounds["first_pcm_frame_device_ms"]
            try:
                background_metrics = pcm_metrics(
                    pcm_window(captured["pcm"], start_ms, end_ms))
            except ValueError:
                raise Blocked("tts_background_capture_window_unavailable") from None
            if signal_errors(background_metrics, baseline, short=True):
                raise AcceptanceFailed("tts_background_audio_not_observed")
            lifecycle = {
                "tts_background_playback_continues": True,
                "tts_foreground_completion_without_new_gesture": True,
                "tts_background_coverage": background_coverage,
                "tts_background_capture": background_metrics,
            }
        if signal_errors(metrics, baseline):
            raise Blocked("audible_tts_capture_unavailable")
        public = {
            "id": stimulus["id"],
            "expected_locale": stimulus["locale"],
            **sanitize_tts_trace(completed),
            "locale_match": not validate_tts_locale(completed, stimulus["locale"]),
            "exclusive_capture": coverage,
            "capture_window": bounds,
            "offline_synthesis_observed": True,
            "autoplay_absent_before_tap": True,
            "playback_started": True,
            "playback_completed": True,
            "android_playback_track_observed": True,
            "output_capture": metrics,
            "raw_audio_retained": False,
        }
        if validate_public_tts_case(public):
            raise AcceptanceFailed("tts_public_correlation_invalid")
        return public, lifecycle

    def run(self):
        preflight = self.preflight()
        for index, stimulus in enumerate(self.stimuli):
            self.device.set_voice_language(stimulus)
            self.device.new_chat()
            public, observed = self._run_stt(stimulus)
            self.stt_cases.append(public)
            if index == 0:
                # Preserve the real recognized draft for the online text-only
                # submission before the separate lifecycle probe clears it.
                self.network.online()
                self.device.send_current_draft(observed)
                self.transcript_post_sha256 = sha256_text(observed)
                self.device.clear_composer()
                self.network.offline()
                self.lifecycle.update(self._run_stt_lifecycle(stimulus))
            self.network.online()
            self.device.clear_composer()
        for index, stimulus in enumerate(self.stimuli):
            self.device.set_voice_language(stimulus)
            self.device.new_chat()
            prompt, expected = self.safe_tts_prompt(self.nonce)
            self.device.enter_ascii_prompt(prompt)
            self.device.wait_exact_text(expected)
            offline = self.network.offline()
            public, lifecycle = self._run_tts(stimulus, index == 0)
            public["offline_before"] = offline
            self.tts_cases.append(public)
            self.lifecycle.update(lifecycle)
            self.network.online()
        if self.transcript_post_sha256 is None:
            raise AcceptanceFailed("recognized_transcript_post_not_proven")
        return {
            "audio_preflight": preflight,
            "stimuli": [case["public"] for case in self.stimuli],
            "stt": {"cases": self.stt_cases},
            "tts": {"cases": self.tts_cases},
            "lifecycle": self.lifecycle,
            "transcript_post_sha256": self.transcript_post_sha256,
        }

def validate_stt_lifecycle(evidence):
    errors = []
    for name in (
            "stt_background_cancelled", "stt_background_mic_inactive",
            "stt_foreground_no_auto_resume", "stt_new_gesture_required",
            "stt_background_draft_unchanged", "stt_pre_background_draft_nonempty",
            "stt_restart_gesture_observed", "stt_restart_draft_preserved"):
        if evidence.get(name) is not True:
            errors.append("stt_lifecycle_" + name + "_missing")
    characters = evidence.get("stt_pre_background_draft_characters")
    if type(characters) is not int or characters < 3:
        errors.append("stt_pre_background_draft_empty")
    hashes = [evidence.get(name) for name in (
        "stt_pre_background_draft_sha256", "stt_post_foreground_draft_sha256",
        "stt_restart_draft_sha256")]
    empty_hash = sha256_text("")
    if (any(not isinstance(value, str) or not HEX64.fullmatch(value) for value in hashes)
            or hashes[0] == empty_hash):
        errors.append("stt_pre_background_draft_empty")
    if len(set(hashes)) != 1:
        errors.append("stt_lifecycle_draft_not_preserved")
    for name in ("stt_record_tracks_background", "stt_record_tracks_foreground"):
        track = evidence.get(name) or {}
        if track.get("known") is not True or track.get("active_tracks") != 0:
            errors.append("stt_lifecycle_record_track_not_inactive")
    restart = evidence.get("stt_restart_record_tracks") or {}
    if (restart.get("known") is not True or restart.get("active_tracks") != 1
            or restart.get("source") != "android.media.audio_flinger"
            or restart.get("channel") != "ovid.stt.record"):
        errors.append("stt_fresh_dictation_restart_not_observed")
    return list(dict.fromkeys(errors))


def validate_capture_artifacts(artifacts):
    if not isinstance(artifacts, (list, tuple, set)):
        return ["capture_artifacts_missing"]
    artifact_set = set(artifacts)
    if len(artifact_set) != len(artifacts):
        return ["capture_artifacts_exact_set_required"]
    if not set(CAPTURE_ARTIFACTS).issubset(artifact_set):
        return ["capture_artifacts_missing"]
    if artifact_set != set(CAPTURE_ARTIFACTS):
        return ["capture_artifacts_exact_set_required"]
    return []


def validate_acceptance(report):
    """Independent fail-closed report gate; fixture origin can never qualify."""
    errors = []
    if report.get("evidence_origin") != "real_adb_ui_and_host_audio":
        errors.append("real_device_evidence_origin_required")
    if any(report.get("opt_in", {}).get(name) is not True
           for name in ("audio_emulator", "authorized_account", "synthetic_stimuli",
                        "authorized_server_audit", "exclusive_emulator_output")):
        errors.append("explicit_opt_in_missing")
    privacy = report.get("privacy") or {}
    expected_privacy = {
        "screenshots": "not_collected",
        "raw_audio_retention": "none_memory_only",
        "raw_transcript_retention": "none",
        "account_retention": "none",
        "raw_server_payload_retention": "none",
    }
    if privacy != expected_privacy:
        errors.append("privacy_contract_invalid")
    flags = report.get("voice_flags") or {}
    if flags != {"changed_by_harness": False, "bypassed_by_harness": False}:
        errors.append("voice_flag_contract_invalid")
    execution = report.get("execution") or {}
    if (not isinstance(execution.get("run_nonce_sha256"), str)
            or not HEX64.fullmatch(execution["run_nonce_sha256"])
            or type(execution.get("started_ms")) is not int
            or type(execution.get("finished_ms")) is not int
            or execution["finished_ms"] < execution["started_ms"]):
        errors.append("execution_identity_incomplete")
    artifact = report.get("artifact") or {}
    artifact_hash = artifact.get("sha256")
    if (not isinstance(artifact_hash, str) or not HEX64.fullmatch(artifact_hash)
            or artifact.get("installed_sha256") != artifact_hash
            or artifact.get("passed") is not True
            or not isinstance(artifact.get("source_revision"), str)
            or not re.fullmatch(r"[0-9a-fA-F]{40,64}", artifact["source_revision"])):
        errors.append("actual_release_provenance_required")
    device = report.get("device") or {}
    if (device.get("emulator") is not True or device.get("explicit_serial") is not True
            or device.get("real_ui_sign_in") is not True
            or type(device.get("api")) is not int or device["api"] < 33
            or not isinstance(device.get("serial_sha256"), str)
            or not HEX64.fullmatch(device["serial_sha256"])):
        errors.append("audio_capable_emulator_evidence_required")
    preflight = device.get("audio_preflight") or {}
    mic_baseline = preflight.get("microphone_baseline")
    output_baseline = preflight.get("output_baseline")
    if (preflight.get("music_stream_unmuted") is not True
            or type(preflight.get("music_stream_volume")) is not int
            or preflight["music_stream_volume"] <= 0
            or not isinstance(mic_baseline, dict)
            or not isinstance(output_baseline, dict)):
        errors.append("audio_preflight_incomplete")
    else:
        if baseline_errors(mic_baseline) or baseline_errors(output_baseline):
            errors.append("audio_preflight_baseline_invalid")
    stimuli = report.get("stimuli") or []
    stimuli_by_id = {case.get("id"): case for case in stimuli}
    if (len(stimuli) != len(LANGUAGES)
            or {case.get("id") for case in stimuli} != set(LANGUAGES)
            or any(case.get("attestation") != "synthetic_non_personal_operator_supplied"
                   for case in stimuli)):
        errors.append("multilingual_stimuli_incomplete")
    stt_cases = (report.get("stt") or {}).get("cases") or []
    if len(stt_cases) != len(LANGUAGES) or {case.get("id") for case in stt_cases} != set(LANGUAGES):
        errors.append("multilingual_stt_incomplete")
    for case in stt_cases:
        stimulus = stimuli_by_id.get(case.get("id")) or {}
        if (case.get("normalized_transcript_match") is not True
                or case.get("final_transcript_observed") is not True
                or case.get("virtual_microphone_observed") is not True
                or case.get("downloaded_locale_required") is not True
                or case.get("raw_audio_retained") is not False
                or case.get("locale") != LANGUAGES.get(case.get("id"), {}).get("locale")
                or case.get("stimulus_sha256") != stimulus.get("audio_sha256")
                or case.get("expected_transcript_sha256") != stimulus.get("expected_transcript_sha256")
                or not isinstance(case.get("input_capture"), dict)):
            errors.append("stt_case_not_proven")
        if isinstance(mic_baseline, dict) and isinstance(case.get("input_capture"), dict):
            if signal_errors(case["input_capture"], mic_baseline):
                errors.append("stt_input_signal_not_proven")
        for name in ("offline_before", "offline_after"):
            observation = case.get(name) or {}
            if observation.get("airplane_mode") is not True or observation.get("connected_networks") != 0:
                errors.append("stt_offline_case_not_proven")
    tts_cases = (report.get("tts") or {}).get("cases") or []
    if len(tts_cases) != len(LANGUAGES) or {case.get("id") for case in tts_cases} != set(LANGUAGES):
        errors.append("multilingual_tts_incomplete")
    for case in tts_cases:
        if (case.get("offline_synthesis_observed") is not True
                or case.get("autoplay_absent_before_tap") is not True
                or case.get("playback_started") is not True
                or case.get("playback_completed") is not True
                or case.get("android_playback_track_observed") is not True
                or case.get("raw_audio_retained") is not False
                or case.get("expected_locale") != LANGUAGES.get(case.get("id"), {}).get("locale")
                or not isinstance(case.get("output_capture"), dict)):
            errors.append("tts_case_not_proven")
        errors.extend(validate_public_tts_case(case))
        if isinstance(output_baseline, dict) and isinstance(case.get("output_capture"), dict):
            if signal_errors(case["output_capture"], output_baseline):
                errors.append("tts_output_signal_not_proven")
        offline = case.get("offline_before") or {}
        if offline.get("airplane_mode") is not True or offline.get("connected_networks") != 0:
            errors.append("tts_offline_case_not_proven")
    lifecycle = report.get("lifecycle") or {}
    errors.extend(validate_stt_lifecycle(lifecycle))
    for name in (
            "tts_background_playback_continues",
            "tts_foreground_completion_without_new_gesture"):
        if lifecycle.get(name) is not True:
            errors.append("lifecycle_case_not_proven")
    lifecycle_input = lifecycle.get("stt_lifecycle_input_capture")
    if (not isinstance(lifecycle_input, dict) or not isinstance(mic_baseline, dict)
            or signal_errors(lifecycle_input, mic_baseline)):
        errors.append("stt_lifecycle_input_not_proven")
    background_capture = lifecycle.get("tts_background_capture")
    if (not isinstance(background_capture, dict) or not isinstance(output_baseline, dict)
            or signal_errors(background_capture, output_baseline, short=True)):
        errors.append("tts_background_signal_not_proven")
    if tts_cases:
        first_case = tts_cases[0]
        background_coverage = lifecycle.get("tts_background_coverage") or {}
        if (background_coverage.get("coverage_type")
                != "background_segment_exclusive_capture"):
            errors.append("tts_background_coverage_not_whole_interval")
        errors.extend(validate_exclusive_capture(
            background_coverage, first_case["capture_window"]))
    else:
        errors.append("tts_background_coverage_not_correlated")
    network = report.get("network") or {}
    if (network.get("audit_authenticated") is not True
            or network.get("audit_fresh") is not True
            or network.get("recognized_transcript_post_observed") is not True):
        errors.append("server_network_audit_not_proven")
    forbidden = network.get("forbidden") or {}
    required_forbidden = {
        "multipart", "audio_mime", "audio_fields", "attachment_uploads",
        "websocket_binary_frames", "unclassified",
    }
    if set(forbidden) != required_forbidden or any(forbidden.get(name) != 0 for name in required_forbidden):
        errors.append("audio_upload_detected")
    storage = report.get("storage") or {}
    if (storage.get("scan_complete") is not True
            or any(storage.get(name) != 0 for name in (
                "server_audio_objects", "server_audio_records", "server_audio_bytes"))):
        errors.append("server_audio_storage_detected")
    errors.extend(validate_capture_artifacts(report.get("artifacts") or []))
    return list(dict.fromkeys(errors))


def _json_equal(left, right):
    if isinstance(left, bool) and isinstance(right, bool):
        return left == right
    if isinstance(left, bool) != isinstance(right, bool):
        return False
    if isinstance(left, dict) and isinstance(right, dict):
        return (left.keys() == right.keys() and all(
            _json_equal(left[key], right[key]) for key in left))
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(
            _json_equal(a, b) for a, b in zip(left, right))
    if left is None or right is None:
        return left is right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return not isinstance(left, bool) and not isinstance(right, bool) and left == right
    return type(left) is type(right) and left == right


def _schema_type_matches(value, expected):
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return type(value) is int
    if expected == "number":
        return type(value) in (int, float) and math.isfinite(value)
    if expected == "null":
        return value is None
    raise ValueError("unsupported schema type")


def _validate_schema_node(value, schema, root, path):
    if not isinstance(schema, dict):
        raise ValueError("invalid schema node")
    if "$ref" in schema:
        reference = schema["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#/$defs/"):
            raise ValueError("unsupported schema reference")
        target = root
        for part in reference[2:].split("/"):
            target = target[part]
        return _validate_schema_node(value, target, root, path)
    errors = []
    expected_type = schema.get("type")
    if expected_type is not None:
        types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(_schema_type_matches(value, item) for item in types):
            return [path + ":type"]
    if "const" in schema and not _json_equal(value, schema["const"]):
        errors.append(path + ":const")
    if "enum" in schema and not any(_json_equal(value, item) for item in schema["enum"]):
        errors.append(path + ":enum")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                errors.append(path + ":required")
        for name, child in properties.items():
            if name in value:
                errors.extend(_validate_schema_node(value[name], child, root, path + "." + name))
        additional = schema.get("additionalProperties", True)
        extras = [name for name in value if name not in properties]
        if additional is False and extras:
            errors.append(path + ":additionalProperties")
        elif isinstance(additional, dict):
            for name in extras:
                errors.extend(_validate_schema_node(value[name], additional, root, path + "." + name))
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(path + ":minItems")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(path + ":maxItems")
        if schema.get("uniqueItems") is True:
            encoded = [canonical_json(item) for item in value]
            if len(set(encoded)) != len(encoded):
                errors.append(path + ":uniqueItems")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(_validate_schema_node(item, schema["items"], root, path + "[]"))
    if isinstance(value, str):
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(path + ":maxLength")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            errors.append(path + ":pattern")
    if type(value) in (int, float) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(path + ":minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(path + ":maximum")
    for child in schema.get("allOf", []):
        errors.extend(_validate_schema_node(value, child, root, path))
    if "if" in schema:
        branch = "then" if not _validate_schema_node(value, schema["if"], root, path) else "else"
        if branch in schema:
            errors.extend(_validate_schema_node(value, schema[branch], root, path))
    supported = {
        "$ref", "type", "const", "enum", "properties", "required",
        "additionalProperties", "items", "minItems", "maxItems", "uniqueItems",
        "pattern", "minimum", "maximum", "maxLength", "allOf", "if", "then", "else",
        "$schema", "$id", "title", "$defs",
    }
    if set(schema) - supported:
        raise ValueError("unsupported schema keyword")
    return errors


def validate_report_schema(report, schema=None):
    """Validate the actual strict schema with its small, explicit keyword set."""
    try:
        root = schema
        if root is None:
            if not SCHEMA_PATH.is_file() or SCHEMA_PATH.stat().st_size > 1024 * 1024:
                return ["evidence_schema_unavailable"]
            root = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        return list(dict.fromkeys(_validate_schema_node(report, root, root, "$")))
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, re.error):
        return ["evidence_schema_validator_failed"]


def _new_report(avd):
    return {
        "schema": SCHEMA,
        "qualification": (
            "actual signed-release audio-capable emulator evidence only; "
            "no physical-device or physical-speaker qualification"),
        "evidence_origin": "none",
        "state": "blocked",
        "passed": False,
        "device": {"avd": avd if SAFE_NAME.fullmatch(avd) else "not_provided"},
        "opt_in": {
            "audio_emulator": False,
            "authorized_account": False,
            "synthetic_stimuli": False,
            "authorized_server_audit": False,
            "exclusive_emulator_output": False,
        },
        "voice_flags": {"changed_by_harness": False, "bypassed_by_harness": False},
        "privacy": {
            "screenshots": "not_collected",
            "raw_audio_retention": "none_memory_only",
            "raw_transcript_retention": "none",
            "account_retention": "none",
            "raw_server_payload_retention": "none",
        },
        "errors": [],
        "blockers": ["acceptance_incomplete"],
        "artifacts": [],
        "limitations": [
            "host output-monitor evidence is not a physical-speaker claim",
            "server storage scope is the authenticated audit account and acceptance window",
        ],
    }


def _read_published_report(out):
    out._assert_contained()
    try:
        descriptor = os.open(
            REPORT_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=out.fd)
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
                raise release.HarnessError("published report is invalid")
            published = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise release.HarnessError("published report could not be verified") from None
    if not isinstance(published, dict):
        raise release.HarnessError("published report has the wrong shape")
    return published


def _write_report(out, report):
    report["errors"] = list(dict.fromkeys(report["errors"]))
    report["blockers"] = list(dict.fromkeys(report["blockers"]))
    report["artifacts"] = out.artifact_names()
    if report["state"] == "passed":
        try:
            report["errors"].extend(validate_acceptance(report))
        except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, re.error):
            report["errors"].append("evidence_acceptance_validation_failed")
        report["errors"] = list(dict.fromkeys(report["errors"]))
    report["passed"] = (
        report["state"] == "passed" and not report["errors"] and not report["blockers"])
    if not report["passed"] and report["state"] == "passed":
        report["state"] = "failed"
    final = report
    if validate_report_schema(final):
        device = final.get("device")
        avd = device.get("avd", "not_provided") if isinstance(device, dict) else "not_provided"
        final = _new_report(avd if isinstance(avd, str) else "not_provided")
        final.update({
            "state": "failed",
            "passed": False,
            "errors": ["evidence_schema_invalid"],
            "blockers": [],
            "artifacts": out.artifact_names(),
        })
        if validate_report_schema(final):
            raise release.HarnessError("schema-safe failure report could not be constructed")
    try:
        payload = json.dumps(
            final, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"
    except (TypeError, ValueError):
        raise release.HarnessError("report serialization failed") from None
    out.write_atomic(
        REPORT_NAME, payload, replace=REPORT_NAME in out.created)
    published = _read_published_report(out)
    if validate_report_schema(published) or not _json_equal(published, final):
        raise release.HarnessError("published report failed schema verification")
    report.clear()
    report.update(published)


def report_exit_code(report):
    if validate_report_schema(report):
        return 1
    if report.get("state") == "passed" and report.get("passed") is True:
        try:
            return 0 if not validate_acceptance(report) else 1
        except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, re.error):
            return 1
    return 2 if report.get("state") == "blocked" else 1


def validate_operator(env, avd, serial):
    if not SAFE_NAME.fullmatch(avd) or not SAFE_SERIAL.fullmatch(serial):
        raise Blocked("explicit_audio_emulator_selection_invalid")
    for name, expected in OPT_INS.items():
        if env.get(name) != expected:
            raise Blocked("explicit_audio_and_account_opt_in_required")
    if not env.get("OVID_EMULATOR_ACCOUNT"):
        raise Blocked("authorized_account_required")
    if any("VOICE" in name and value for name, value in env.items()):
        raise AcceptanceFailed("voice_flag_override_forbidden")
    if release.validate_operator_environment(env):
        raise AcceptanceFailed("operator_environment_invalid")
    if not env.get("OVID_AUDIO_SERVER_AUDIT_COMMAND"):
        raise Blocked("server_audit_not_configured")
    try:
        if len(bytes.fromhex(env.get("OVID_AUDIO_SERVER_AUDIT_HMAC_KEY", ""))) < 32:
            raise Blocked("server_audit_not_configured")
    except ValueError:
        raise Blocked("server_audit_configuration_invalid") from None


def _argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--avd", required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--stimuli", required=True)
    parser.add_argument("--out", required=True)
    return parser


def _out_hint(arguments):
    try:
        return arguments[arguments.index("--out") + 1]
    except (ValueError, IndexError):
        return None


def main(argv=None, env=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    env = dict(os.environ if env is None else env)
    try:
        args = _argument_parser().parse_args(arguments)
    except SystemExit as error:
        hint = _out_hint(arguments)
        if error.code and hint:
            try:
                out = AudioEvidenceStore.create(hint)
                report = _new_report("not_provided")
                report["blockers"] = ["invalid_harness_arguments"]
                _write_report(out, report)
                out.close()
            except release.HarnessError:
                pass
        return int(error.code)
    report = _new_report(args.avd)
    try:
        out = AudioEvidenceStore.create(args.out)
    except release.HarnessError:
        return 2
    apk = None
    device = None
    audio = None
    network = None
    stimuli = []
    flow_complete = False
    try:
        _write_report(out, report)
        validate_operator(env, args.avd, args.serial)
        report["opt_in"] = {
            "audio_emulator": True,
            "authorized_account": True,
            "synthetic_stimuli": True,
            "authorized_server_audit": True,
            "exclusive_emulator_output": True,
        }
        report["blockers"] = []
        stimuli = load_stimuli(args.stimuli)
        certificate = env.get("ANDROID_SIGNING_CERT_SHA256", "").replace(":", "").lower()
        try:
            apk = release.PinnedApk.open(args.apk)
            apk.create_verified_copy(out.path / f".audio-apk-work-{secrets.token_hex(8)}")
            provenance_path = env.get("OVID_RELEASE_INVENTORY")
            provenance_path = Path(provenance_path) if provenance_path else apk.path.parent / "release-inventory.json"
            provenance = release._read_json(provenance_path)
            fresh = release._fresh_inventory(apk, certificate, out, env, provenance)
        except (release.HarnessError, OSError, ValueError):
            raise AcceptanceFailed("actual_release_provenance_required") from None
        revision = fresh.get("source_revision")
        if (release.validate_artifact(provenance, fresh, apk.sha256, certificate)
                or not isinstance(revision, str)
                or not re.fullmatch(r"[0-9a-fA-F]{40,64}", revision)
                or provenance.get("source_revision") != revision):
            raise AcceptanceFailed("artifact_provenance_invalid")
        report["artifact"] = release.sanitize_inventory(fresh, apk.sha256)
        out.write_atomic(
            "artifact-inspection.sanitized.json",
            json.dumps(report["artifact"], indent=2, sort_keys=True) + "\n")
        audio = HostAudio(env)
        device = AudioAdbDevice(apk, args.avd, args.serial, out, env)
        prepared = device.install_launch_and_sign_in()
        device.grant_microphone()
        report["artifact"]["installed_sha256"] = apk.sha256
        device_evidence = prepared.get("device") or {}
        report["device"].update({
            "state": "prepared",
            "emulator": True,
            "explicit_serial": True,
            "serial_sha256": sha256_text(args.serial),
            "api": device_evidence.get("api"),
            "abis": [value for value in device_evidence.get("abis", [])
                     if value in ("x86_64", "arm64-v8a", "armeabi-v7a")],
            "real_ui_sign_in": prepared.get("real_ui_sign_in") is True,
        })
        if report["device"]["real_ui_sign_in"] is not True:
            raise Blocked("authorized_account_sign_in_required")
        nonce = secrets.token_hex(16)
        started_ms = int(time.time() * 1000)
        report["execution"] = {
            "run_nonce_sha256": sha256_text(nonce),
            "started_ms": started_ms,
        }
        network = DeviceNetwork(device)
        flow = AudioAcceptanceFlow(device, audio, network, stimuli, nonce, env=env)
        observed = flow.run()
        report["evidence_origin"] = "real_adb_ui_and_host_audio"
        report["device"]["audio_preflight"] = observed["audio_preflight"]
        for name in ("stimuli", "stt", "tts", "lifecycle"):
            report[name] = observed[name]
        time.sleep(2)
        finished_ms = int(time.time() * 1000)
        report["execution"]["finished_ms"] = finished_ms
        audit = run_server_audit(
            env, nonce, env["OVID_EMULATOR_ACCOUNT"], apk.sha256,
            started_ms, finished_ms, observed["transcript_post_sha256"])
        network_evidence, storage = validate_server_audit(
            audit, nonce, env["OVID_EMULATOR_ACCOUNT"], apk.sha256,
            started_ms, finished_ms, observed["transcript_post_sha256"],
            env.get("OVID_AUDIO_SERVER_AUDIT_HMAC_KEY", ""), len(stimuli) + 1)
        report["network"] = network_evidence
        report["storage"] = storage
        flow_complete = True
        report["state"] = "passed"
    except Blocked as error:
        report["state"] = "blocked"
        report["blockers"].append(error.code)
    except AcceptanceFailed as error:
        report["state"] = "failed"
        report["errors"].append(error.code)
    except release.HarnessError:
        report["state"] = "failed"
        report["errors"].append("release_device_or_artifact_operation_failed")
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError,
            ET.ParseError, UnicodeError, struct.error, subprocess.SubprocessError):
        report["state"] = "failed"
        report["errors"].append("harness_incomplete")
    finally:
        if audio is not None:
            report["errors"].extend(audio.cleanup())
        if network is not None and network.online_required:
            try:
                network.restore()
            except (AcceptanceFailed, release.HarnessError, OSError, ValueError) as error:
                report["errors"].append(
                    error.code if isinstance(error, AcceptanceFailed) else "network_cleanup_failed")
        if device is not None:
            try:
                device.stop_audio()
            except (AcceptanceFailed, release.HarnessError, OSError, ValueError) as error:
                report["errors"].append(
                    error.code if isinstance(error, AcceptanceFailed) else "audio_cleanup_failed")
            device.capture_evidence()
            try:
                if device.cleanup():
                    report["errors"].append("raw_ui_cleanup_failed")
            except release.HarnessError:
                report["errors"].append("raw_ui_cleanup_failed")
        close_stimuli(stimuli)
        if apk is not None:
            apk.close()
        report["artifacts"] = out.artifact_names()
        if flow_complete:
            report["errors"].extend(validate_acceptance(report))
        if report["errors"] and report["state"] == "passed":
            report["state"] = "failed"
        if report["state"] == "passed":
            report["blockers"] = []
        try:
            _write_report(out, report)
        except release.HarnessError:
            out.close()
            return 1
        out.close()
    return report_exit_code(report)


if __name__ == "__main__":
    sys.exit(main())
