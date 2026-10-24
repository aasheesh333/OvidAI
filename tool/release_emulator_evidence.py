#!/usr/bin/env python3
"""Signed-release Android emulator evidence harness.

The only passing evidence path is an inspected production APK followed by real
ADB/UI-Automator operations. Raw logcat, notification text, UI text, account
identifiers, prompts, tokens, and unredacted screenshots are never written to
the evidence directory. This tool does not build an APK or perform Play work.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


PACKAGE = "com.dhanuk.ovidai"
REPORT_NAME = "release-emulator-acceptance.json"
BUILD_COMMAND = (
    "flutter build apk --release --target-platform android-x64 "
    "--dart-define=OVID_APPCHECK=false --dart-define=OVID_PRODUCTION=true"
)
BUILD_ARGUMENTS = [
    "flutter", "build", "apk", "--release", "--target-platform", "android-x64",
    "--dart-define=OVID_APPCHECK=false", "--dart-define=OVID_PRODUCTION=true",
]
FORBIDDEN_MARKERS = ("DEMO", "BYPASS", "SKIP_LOGIN", "TEST_STORE")
TITLE_KINDS = {
    "Ovid finished": "agentFinished",
    "Ovid stopped with an error": "agentFailed",
    "Ovid has a question": "agentNeedsInput",
    "Ovid needs your approval": "agentNeedsApproval",
}
KIND_TITLES = {value: key for key, value in TITLE_KINDS.items()}
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
SAFE_CLASS = re.compile(r"^[A-Za-z0-9_.$]+$")
SAFE_RESOURCE = re.compile(r"^[A-Za-z0-9_./:+-]+$")
BOUNDS = re.compile(r"^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$")


class HarnessError(Exception):
    """An error whose message is deliberately safe for the public report."""


class EvidenceStore:
    """A fresh directory accessed only through a no-follow directory FD."""

    FILES = {
        REPORT_NAME, "artifact-inspection.sanitized.json", "logcat.redacted.txt",
        "notification-dump.redacted.txt", "ui-latest.redacted.xml",
    }

    def __init__(self, path, fd, identity, parent_real):
        self.path = path
        self.fd = fd
        self.identity = identity
        self.parent_real = parent_real
        self.created = set()
        self.artifacts = set()

    @classmethod
    def create(cls, destination):
        path = Path(os.path.abspath(os.fspath(destination)))
        if path.name in ("", ".", "..") or os.path.lexists(path):
            raise HarnessError("evidence output must be a fresh non-symlink path")
        parent = path.parent
        if not parent.is_dir() or os.path.realpath(parent) != str(parent):
            raise HarnessError("evidence output parent must be an existing real directory")
        try:
            os.mkdir(path, 0o700)
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except OSError:
            raise HarnessError("fresh evidence output could not be created safely") from None
        try:
            info = os.fstat(fd)
            identity = (info.st_dev, info.st_ino)
            store = cls(path, fd, identity, str(parent))
            store._assert_contained()
            return store
        except Exception:
            os.close(fd)
            raise

    def _assert_contained(self):
        try:
            path_info = os.lstat(self.path)
            fd_info = os.fstat(self.fd)
        except OSError:
            raise HarnessError("evidence output containment/inode check failed") from None
        if (stat.S_ISLNK(path_info.st_mode) or not stat.S_ISDIR(path_info.st_mode)
                or (path_info.st_dev, path_info.st_ino) != self.identity
                or (fd_info.st_dev, fd_info.st_ino) != self.identity
                or os.path.realpath(self.path) != str(self.path)
                or os.path.realpath(self.path.parent) != self.parent_real
                or os.path.commonpath((str(self.path), self.parent_real)) != self.parent_real):
            raise HarnessError("evidence output symlink/path/inode containment changed")

    def write_atomic(self, name, data, replace=False):
        if name not in self.FILES:
            raise HarnessError("unrecognized evidence artifact name")
        self._assert_contained()
        if not replace and name in self.created:
            raise HarnessError("evidence artifact was already written")
        payload = data.encode("utf-8") if isinstance(data, str) else bytes(data)
        temporary = f".{name}.{secrets.token_hex(16)}.tmp"
        descriptor = None
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=self.fd,
            )
            view = memoryview(payload)
            while view:
                written = os.write(descriptor, view)
                view = view[written:]
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = None
            if replace:
                # Rename replaces a hostile link itself; it never follows its target.
                os.replace(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            else:
                # Atomic exclusive publication; unlike rename, link never overwrites.
                os.link(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd,
                        follow_symlinks=False)
                os.unlink(temporary, dir_fd=self.fd)
            published = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if not stat.S_ISREG(published.st_mode):
                raise HarnessError("published evidence is not a regular file")
            self.created.add(name)
            if name != REPORT_NAME:
                self.artifacts.add(name)
            os.fsync(self.fd)
        except (OSError, ValueError):
            raise HarnessError("atomic no-follow evidence write failed") from None
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except OSError:
                pass

    def artifact_names(self):
        return sorted(self.artifacts)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class PinnedApk:
    """Original APK FD/hash plus a verified private copy used for inspection/install."""

    def __init__(self, path, fd, info, digest):
        self.path = path
        self.fd = fd
        self.identity = (info.st_dev, info.st_ino)
        self.sha256 = digest
        self.install_path = None
        self.copy_fd = None
        self.copy_identity = None
        self.work_path = None
        self.work_identity = None

    @staticmethod
    def _hash_fd(fd):
        position = os.lseek(fd, 0, os.SEEK_CUR)
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            digest = hashlib.sha256()
            while chunk := os.read(fd, 1024 * 1024):
                digest.update(chunk)
            return digest.hexdigest()
        finally:
            os.lseek(fd, position, os.SEEK_SET)

    @classmethod
    def open(cls, source):
        path = Path(os.path.abspath(os.fspath(source)))
        if path.suffix != ".apk":
            raise HarnessError("the supplied release APK must be a regular .apk file")
        try:
            if stat.S_ISLNK(os.lstat(path).st_mode):
                raise HarnessError("APK symlink input is forbidden")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except HarnessError:
            raise
        except OSError:
            raise HarnessError("the supplied release APK cannot be opened without following links") from None
        try:
            info = os.fstat(fd)
            path_info = os.lstat(path)
            if (not stat.S_ISREG(info.st_mode)
                    or (path_info.st_dev, path_info.st_ino) != (info.st_dev, info.st_ino)):
                raise HarnessError("APK path/inode does not identify one regular file")
            return cls(path, fd, info, cls._hash_fd(fd))
        except Exception:
            os.close(fd)
            raise

    def create_verified_copy(self, work):
        if self.install_path is not None:
            raise HarnessError("verified private APK copy already exists")
        work = Path(work)
        try:
            os.mkdir(work, 0o700)
            work_info = os.lstat(work)
            if not stat.S_ISDIR(work_info.st_mode):
                raise HarnessError("verified private APK work directory is invalid")
            self.work_identity = (work_info.st_dev, work_info.st_ino)
            destination = work / "candidate.apk"
            copy_fd = os.open(
                destination,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
            )
            copy_info = os.fstat(copy_fd)
            self.install_path = destination
            self.copy_fd = copy_fd
            self.copy_identity = (copy_info.st_dev, copy_info.st_ino)
            self.work_path = work
        except OSError:
            raise HarnessError("verified private APK copy could not be created") from None
        try:
            os.lseek(self.fd, 0, os.SEEK_SET)
            while chunk := os.read(self.fd, 1024 * 1024):
                view = memoryview(chunk)
                while view:
                    view = view[os.write(copy_fd, view):]
            os.fsync(copy_fd)
            if self._hash_fd(copy_fd) != self.sha256:
                raise HarnessError("verified private APK copy content differs from the original")
            self.assert_original()
            return destination
        except Exception:
            os.close(copy_fd)
            self.copy_fd = None
            self._discard_private_copy()
            raise

    def assert_original(self):
        try:
            info = os.lstat(self.path)
            if stat.S_ISLNK(info.st_mode):
                raise HarnessError("APK symlink/path swap detected before install")
            if (info.st_dev, info.st_ino) != self.identity:
                raise HarnessError("APK path/inode swap detected before install")
            if self._hash_fd(self.fd) != self.sha256:
                raise HarnessError("APK content changed after original inspection")
        except HarnessError:
            raise
        except OSError:
            raise HarnessError("APK path/inode could not be reverified") from None

    def assert_copy(self):
        if self.install_path is None or self.copy_fd is None:
            raise HarnessError("verified private APK copy is missing")
        try:
            info = os.lstat(self.install_path)
            if (not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != self.copy_identity):
                raise HarnessError("verified private copy path/inode changed")
            if self._hash_fd(self.copy_fd) != self.sha256:
                raise HarnessError("verified private copy content changed")
        except HarnessError:
            raise
        except OSError:
            raise HarnessError("verified private copy could not be reverified") from None

    def assert_all(self):
        self.assert_original()
        self.assert_copy()

    def _discard_private_copy(self):
        if self.work_path is None or self.work_identity is None:
            return
        descriptor = None
        try:
            info = os.lstat(self.work_path)
            if (not stat.S_ISDIR(info.st_mode)
                    or (info.st_dev, info.st_ino) != self.work_identity):
                return
            descriptor = os.open(
                self.work_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            candidate = os.stat("candidate.apk", dir_fd=descriptor, follow_symlinks=False)
            if (stat.S_ISREG(candidate.st_mode)
                    and (candidate.st_dev, candidate.st_ino) == self.copy_identity):
                os.unlink("candidate.apk", dir_fd=descriptor)
            os.close(descriptor)
            descriptor = None
            info = os.lstat(self.work_path)
            if (stat.S_ISDIR(info.st_mode)
                    and (info.st_dev, info.st_ino) == self.work_identity):
                os.rmdir(self.work_path)
        except OSError:
            # A swapped/inaccessible work path is left alone, never followed.
            pass
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def close(self):
        for name in ("fd", "copy_fd"):
            descriptor = getattr(self, name, None)
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                setattr(self, name, None)
        self._discard_private_copy()


def sha256_text(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_file(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _valid_certificate(value):
    return bool(re.fullmatch(r"[0-9a-fA-F]{64}", value.replace(":", "")))


def validate_operator_environment(env):
    """Reject inherited demo/bypass inputs without serializing their values."""
    errors = []
    for name, value in env.items():
        if not value or not name.startswith("OVID_"):
            continue
        if name == "OVID_PLAY_BUILD" or any(marker in name for marker in FORBIDDEN_MARKERS):
            errors.append(f"forbidden operator environment input: {name}")
    if env.get("OVID_APPCHECK", "false") != "false":
        errors.append("OVID_APPCHECK=false is required for the sideload acceptance environment")
    if env.get("OVID_PRODUCTION", "true") != "true":
        errors.append("OVID_PRODUCTION=true is required for the acceptance environment")
    return errors


def _flag_name(argument):
    match = re.match(r"(?:--dart-define=)?(OVID_[A-Z0-9_]+)", argument)
    return match.group(1) if match else None


def validate_artifact(provenance, fresh, apk_sha256, certificate_sha256):
    """Validate matching build provenance and a fresh static APK inspection."""
    errors = []
    certificate = certificate_sha256.replace(":", "").lower()
    if not _valid_certificate(certificate_sha256):
        return ["a pinned 64-hex release certificate SHA-256 is required"]

    try:
        arguments = shlex.split(provenance.get("build_command") or "")
    except (ValueError, AttributeError):
        arguments = []
    forbidden = sorted({
        name for argument in arguments
        if (name := _flag_name(argument)) and (
            name == "OVID_PLAY_BUILD" or any(marker in name for marker in FORBIDDEN_MARKERS)
        )
    })
    for name in forbidden:
        errors.append(f"forbidden build flag in signed build provenance: {name}")
    if arguments != BUILD_ARGUMENTS:
        errors.append("signed build provenance does not contain the exact production sideload command")

    for label, report in (("signed build provenance", provenance), ("fresh APK inspection", fresh)):
        if report.get("sha256") != apk_sha256:
            errors.append(f"{label} does not match the supplied APK SHA-256")
        if report.get("passed") is not True:
            errors.append(f"{label} did not pass")
        if report.get("mode") != "production" or report.get("profile") != "sideload":
            errors.append(f"{label} is not a production sideload inspection")

    raw_errors = "\n".join(str(error) for error in fresh.get("errors", []))
    if "debug" in raw_errors.lower() and ("cert" in raw_errors.lower() or "sign" in raw_errors.lower()):
        errors.append("debug signing is forbidden for the inspected release APK")
    manifest = fresh.get("manifest") or {}
    if manifest.get("debuggable") is True:
        errors.append("the inspected release APK is debuggable")
    if (manifest.get("package") != PACKAGE or manifest.get("target_sdk") != 36
            or manifest.get("min_sdk") != 24):
        errors.append("the inspected APK package/minSdk/targetSdk contract is not 24/36 for Ovid")
    if fresh.get("signers_sha256") != [certificate]:
        errors.append("the inspected APK signer does not match the pinned release certificate")
    if (fresh.get("native") or {}).get("abis") != ["x86_64"]:
        errors.append("the inspected APK does not contain exactly the x86_64 emulator ABI")
    if fresh.get("zip_alignment") != "16 KB check passed":
        errors.append("the inspected APK has not passed 16 KB ZIP alignment")
    # Keep deterministic and avoid repeating a generic failure for every field.
    return list(dict.fromkeys(errors))


def _title_kind(title):
    if title in TITLE_KINDS:
        return TITLE_KINDS[title]
    if title.startswith("Scheduled task done:"):
        return "scheduleSucceeded"
    if title.startswith("Scheduled task failed:"):
        return "scheduleFailed"
    return None


def _dump_value(block, name):
    match = re.search(rf"(?m)^\s*{re.escape(name)}=(.*)$", block)
    if not match:
        return ""
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value


def parse_notification_dump(text):
    """Parse actual NotificationRecord rows, never sent/inbox bookkeeping."""
    records = []
    starts = list(re.finditer(r"(?m)^\s*NotificationRecord\(", text))
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        block = text[start.start():end]
        package = re.search(r"\bpkg=([A-Za-z0-9_.]+)", block)
        notification_id = re.search(r"\bid=(\d+)\b", block)
        post_time = re.search(r"\bpostTime=(\d+)\b", block)
        channel = re.search(r"\bchannelId=([A-Za-z0-9_.-]+)", block)
        if not (package and notification_id and post_time and channel):
            continue
        title = _dump_value(block, "android.title")
        body = _dump_value(block, "android.text")
        marker = re.match(r"^Acceptance ([0-9a-fA-F]{6,32}) — ", body)
        intent_ref = re.search(r"\bcontentIntent=PendingIntent\{([0-9a-fA-F]+):", block)
        records.append({
            "actual": True,
            "package": package.group(1),
            "id": int(notification_id.group(1)),
            "post_time": int(post_time.group(1)),
            "channel_id": channel.group(1),
            "kind": _title_kind(title),
            "kind_basis": "native notification title for a real UI chat run",
            "correlation_sha256": sha256_text(marker.group(1).lower()) if marker else None,
            "content_intent_ref": intent_ref.group(1).lower() if intent_ref else None,
            "title_sha256": sha256_text(title),
            "body_sha256": sha256_text(body),
        })
    return records


def notification_key_for_chat_route(route):
    """PushPayloadMapper supplies no key, so OvidNotification uses this default."""
    match = re.fullmatch(r"/c/([^\s/?#]{1,128})", route)
    if match is None:
        return None
    return f"agent_updates:{match.group(1)}"


def notification_id_for_chat_route(route):
    key = notification_key_for_chat_route(route)
    if key is None:
        return None
    value = 0x811C9DC5
    # Dart String.codeUnits are UTF-16 code units, including surrogate pairs.
    encoded = key.encode("utf-16-be")
    for offset in range(0, len(encoded), 2):
        unit = (encoded[offset] << 8) | encoded[offset + 1]
        value ^= unit
        value = (value * 0x01000193) & 0xFFFFFFFF
    return 2000 + (value & 0xFFFFF)


def request_code_for_notification(receipt):
    if type(receipt.get("id")) is not int:
        return None
    return 20_000 + (receipt["id"] & 0xFFFF)


def _pending_intent_content(block):
    action_match = re.search(r"\bact=([A-Za-z0-9_.]+)\b", block)
    data_match = re.search(r"\bdat=([^\s}]+)", block)
    action = action_match.group(1) if action_match else ""
    data = data_match.group(1) if data_match else ""
    request_code_match = re.search(r"\brequestCode=(\d+)\b", block)
    request_code = int(request_code_match.group(1)) if request_code_match else None
    # AOSP hides the route extra. Native OvidNotifications gives MainActivity
    # a null action and null data, which are the only stable Intent fields
    # available here. The decoy-to-target navigation proves the actual route.
    return {
        "request_code": request_code,
        "action_sha256": sha256_text(action),
        "data_sha256": sha256_text(data),
        # Intent(context, MainActivity::class.java) has null action; AOSP omits
        # act=. Explicit MAIN is a different identity and must be rejected.
        "action_correct": action == "",
        "data_correct": data == "",
        "chat_route": True,
        "notification_id": None,
        "route_sha256": None,
    }


def _pending_intent_states(block):
    """Prefer stable Key identity fields over transient PendingIntent dump data."""
    identity = re.search(
        r"\bintent=Intent\s*\{(.*?)\}\s+flags=0x[0-9a-fA-F]+\s+u=\d+\s*\}\s+requestCode=(\d+)",
        block, re.DOTALL)
    if identity:
        result = _pending_intent_content(identity.group(1))
        result["request_code"] = int(identity.group(2))
        return result
    # Fallback for the observed PendingIntentRecord dump: requestCode and
    # requestIntent are separate lines. AOSP prints (has extras) but not values.
    return _pending_intent_content(block)


def parse_pending_intents(text):
    """Correlate stable identity, never object identity hashes or extra values."""
    records = []
    starts = list(re.finditer(r"(?m)^\s*(?:\*\s*)?PendingIntentRecord\{([0-9a-fA-F]+)\s", text))
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        block = text[start.start():end]
        package = re.search(r"\bpackageName=([A-Za-z0-9_.]+)", block)
        sent = re.search(r"\bsent=(true|false)\b", block)
        canceled = re.search(r"\bcanceled=(true|false)\b", block)
        component = re.search(r"\bcmp=com\.dhanuk\.ovidai/(?:\.MainActivity|com\.dhanuk\.ovidai\.MainActivity)\b", block)
        record = {
            "ref": start.group(1).lower(),
            "package": package.group(1) if package else None,
            "component_correct": component is not None,
            # AOSP omits these flags entirely when both values are false.
            "sent": sent is not None and sent.group(1) == "true",
            "canceled": canceled is not None and canceled.group(1) == "true",
        }
        record.update(_pending_intent_states(block))
        records.append(record)
    return records


def _pending_intent_identity_matches(receipt, record):
    expected_request_code = request_code_for_notification(receipt)
    return (
        record["package"] == PACKAGE
        and record["request_code"] == expected_request_code
        and record["action_correct"]
        and record["data_correct"]
        and record["chat_route"]
        and record["component_correct"]
    )


def _matching_pending_intents(receipt, text):
    return [record for record in parse_pending_intents(text)
            if _pending_intent_identity_matches(receipt, record)]


def _pending_intent_content_evidence(record):
    return {
        "request_code": record["request_code"],
        "action_sha256": record["action_sha256"],
        "data_sha256": record["data_sha256"],
        "route_sha256": record["route_sha256"],
        "sent": record["sent"],
        "canceled": record["canceled"],
    }


def correlate_content_intent(receipt, pending_intents_text):
    matches = _matching_pending_intents(receipt, pending_intents_text)
    if len(matches) != 1 or matches[0]["sent"] or matches[0]["canceled"]:
        return None
    return {
        "correlated": True,
        "initially_unsent": True,
        "chat_route": True,
        **_pending_intent_content_evidence(matches[0]),
    }


def expected_content_intent(receipt):
    """Native null-action/null-data identity from the mapper-produced ID."""
    return {
        "request_code": request_code_for_notification(receipt),
        "action_sha256": sha256_text(""),
        "data_sha256": sha256_text(""),
    }


def validate_tap_transition(before, after, expected=None):
    """Require one stable contentIntent identity to move false→true, not canceled."""
    errors = []
    if not isinstance(before, dict) or before.get("initially_unsent") is not True:
        errors.append("contentIntent was not genuinely unsent before the tap")
    if not isinstance(after, dict):
        return errors + ["contentIntent after-tap state is missing"]
    if after.get("sent") is not True:
        errors.append("contentIntent did not transition to sent after the tap")
    if after.get("canceled") is not False:
        errors.append("contentIntent was canceled during the tap transition")
    for key in ("request_code", "action_sha256", "data_sha256"):
        expected_value = ((expected or {}).get(key)
                          if expected is not None else before.get(key))
        if ((expected_value is None and key != "request_code")
                or (key == "request_code" and not isinstance(expected_value, int))
                or after.get(key) != expected_value):
            errors.append(f"contentIntent identity changed across tap: {key}")
    if expected is None:
        # Direct correlation fixtures may carry a separately observed route
        # digest; the real AOSP path has no readable route extra.
        if before.get("route_sha256") is not None and after.get("route_sha256") != before["route_sha256"]:
            errors.append("contentIntent identity changed across tap: route_sha256")
    return errors


def _sanitize_receipt(receipt):
    if not receipt:
        return {"state": "not provided", "actual": False}
    result = {
        "state": "configured",
        "actual": receipt.get("actual") is True,
        "kind_basis": "native notification title for a real UI chat run",
    }
    package = receipt.get("package")
    if isinstance(package, str) and re.fullmatch(r"[A-Za-z0-9_.]+", package):
        result["package"] = package
    channel = receipt.get("channel_id")
    if isinstance(channel, str) and re.fullmatch(
            r"ovid_(?:agent_updates|scheduler_results|background_status)\.(?:chime|system|silent)\.v1",
            channel):
        result["channel_id"] = channel
    kind = receipt.get("kind")
    if kind in {"agentFinished", "agentFailed", "agentNeedsInput", "agentNeedsApproval",
                "scheduleSucceeded", "scheduleFailed"}:
        result["kind"] = kind
    for key in ("id", "post_time"):
        if type(receipt.get(key)) is int:
            result[key] = receipt[key]
    for key in ("title_sha256", "body_sha256", "correlation_sha256"):
        value = receipt.get(key)
        if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
            result[key] = value
    content = receipt.get("content_intent") or {}
    if isinstance(content, dict):
        result["content_intent"] = {
            "correlated": content.get("correlated") is True,
            "initially_unsent": content.get("initially_unsent") is True,
            "chat_route": content.get("chat_route") is True,
        }
        if type(content.get("request_code")) is int:
            result["content_intent"]["request_code"] = content["request_code"]
        for key in ("action_sha256", "data_sha256", "route_sha256"):
            value = content.get(key)
            if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                result["content_intent"][key] = value
    return result


def _xml_text_outside_inputs(xml_text, expected):
    try:
        root = ET.fromstring(xml_text)
    except (ET.ParseError, TypeError):
        return False
    for node in root.iter("node"):
        if node.get("class") == "android.widget.EditText":
            continue
        if expected in (node.get("text", "") + "\n" + node.get("content-desc", "")):
            return True
    return False


def execute_device_flow(device, prompt):
    """Correlate one run/session/receipt/tap and prove navigation from a decoy."""
    prepared = device.install_launch_and_sign_in()
    old_pid = device.process_id()
    run = device.trigger_real_run(prompt)
    run["_prompt"] = prompt
    stopped = device.force_stop() is True
    new_pid = device.relaunch_and_background()
    fresh_process = stopped and old_pid is not None and new_pid is not None and new_pid != old_pid
    baseline = device.prepare_deep_link_probe(run)
    background_killed = device.kill_background_process() is True
    raw_receipt = device.wait_for_notification(
        run["started_ms"], run.get("baseline_notification_ids", []), run)
    receipt_pid = device.process_id() if raw_receipt else None
    fresh_receipt_process = (background_killed and raw_receipt is not None
                             and receipt_pid is not None and receipt_pid not in (old_pid, new_pid))
    receipt = _sanitize_receipt(raw_receipt)
    content = receipt.get("content_intent") or {}
    correlated = (
        receipt["actual"]
        and receipt.get("correlation_sha256") == run.get("correlation_sha256")
        and content.get("correlated") is True
    )
    tapped = sent = route_matches = correct_chat = marker_present = actual_navigation = False
    screen_changed = False
    after_content = None
    if correlated:
        tap = device.tap_notification(raw_receipt, run["session_marker"])
        tapped = tap.get("shade_tapped") is True
        after_content = tap.get("after_content_intent")
        if after_content is None:
            after_content = {"sent": tap.get("sent_after_tap") is True, "canceled": False}
        sent = after_content.get("sent") is True
        route_matches = not validate_tap_transition(
            content, after_content, expected_content_intent(receipt))
        deadline = time.monotonic() + float(getattr(device, "chat_timeout", 90))
        while True:
            xml = device.current_ui_xml()
            prompt_present = _xml_text_outside_inputs(xml, prompt)
            marker_present = (device.verify_session_marker(run["session_marker"])
                              if prompt_present else False)
            correct_chat = prompt_present and marker_present
            screen_changed = sha256_text(xml) != baseline.get("screen_sha256")
            actual_navigation = (
                baseline.get("target_absent") is True and screen_changed and correct_chat
                and tapped and sent and route_matches
            )
            if actual_navigation or time.monotonic() >= deadline:
                break
            time.sleep(float(getattr(device, "poll_interval", 1)))
    return {
        "installed": prepared.get("installed") is True,
        "real_ui_sign_in": prepared.get("real_ui_sign_in") is True,
        "device": prepared.get("device", {"state": "not provided"}),
        "run": {
            "submitted": run.get("submitted") is True,
            "method": "real UI chat send with correlated renamed session",
            "started_ms": run.get("started_ms") if isinstance(run.get("started_ms"), int) else None,
            "correlation_sha256": run.get("correlation_sha256"),
            "session_title_sha256": sha256_text(run.get("session_marker", "")),
            "prompt_sha256": sha256_text(prompt),
        },
        "process": {
            "force_stopped": stopped,
            "relaunched_and_backgrounded": new_pid is not None,
            "fresh_process": fresh_process,
            "background_killed": background_killed,
            "fresh_receipt_process": fresh_receipt_process,
        },
        "receipt": receipt,
        "deep_link": {
            "notification_tapped": tapped,
            "content_intent_sent": sent,
            "route_matches": route_matches,
            "tap_transition_errors": validate_tap_transition(
                content, after_content, expected_content_intent(receipt)),
            "pre_tap_target_absent": baseline.get("target_absent") is True,
            "screen_changed": screen_changed,
            "actual_navigation": actual_navigation,
            "correct_existing_chat": correct_chat,
            "session_marker_present": marker_present,
            "correlation_sha256": run.get("correlation_sha256"),
            "prompt_sha256": sha256_text(prompt),
        },
    }


def validate_acceptance(evidence):
    errors = []
    if evidence.get("installed") is not True:
        errors.append("the exact inspected APK was not installed and hash-verified")
    if evidence.get("real_ui_sign_in") is not True:
        errors.append("real UI Firebase sign-in evidence is missing")
    if (evidence.get("run") or {}).get("submitted") is not True:
        errors.append("a real UI chat run was not submitted")
    process = evidence.get("process") or {}
    if process.get("force_stopped") is not True:
        errors.append("observed process stop is missing")
    if process.get("relaunched_and_backgrounded") is not True:
        errors.append("process relaunch/background evidence is missing")
    if process.get("fresh_process") is not True:
        errors.append("relaunch did not produce a distinct fresh process")
    if process.get("background_killed") is not True:
        errors.append("background process death before receipt is missing; local WebSocket delivery is not FCM evidence")
    if process.get("fresh_receipt_process") is not True:
        errors.append("a distinct fresh FCM receiver process was not observed")
    receipt = evidence.get("receipt") or {}
    if receipt.get("actual") is not True:
        errors.append("actual Android notification receipt is missing; sent/inbox records are not receipt evidence")
    else:
        started_ms = (evidence.get("run") or {}).get("started_ms")
        if (not isinstance(started_ms, int) or not isinstance(receipt.get("post_time"), int)
                or receipt["post_time"] < started_ms):
            errors.append("the actual notification was not observed after the real run")
        if receipt.get("package") != PACKAGE:
            errors.append("the actual notification belongs to the wrong package")
        if receipt.get("kind") != "agentFinished":
            errors.append("the real chat run did not produce the agentFinished kind")
        if not re.fullmatch(r"ovid_agent_updates\.(?:chime|system|silent)\.v1",
                            str(receipt.get("channel_id", ""))):
            errors.append("the actual notification is not on the agent_updates channel")
    run = evidence.get("run") or {}
    if receipt.get("correlation_sha256") != run.get("correlation_sha256"):
        errors.append("run/session/notification correlation is missing or unrelated")
    content = receipt.get("content_intent") or {}
    if content.get("correlated") is not True or content.get("chat_route") is not True:
        errors.append("notification contentIntent identity/correlation is missing")
    if content.get("initially_unsent") is not True:
        errors.append("notification contentIntent was already sent or stale before the tap")
    deep_link = evidence.get("deep_link") or {}
    if deep_link.get("notification_tapped") is not True:
        errors.append("the actual Android notification was not tapped")
    if deep_link.get("content_intent_sent") is not True:
        errors.append("the correlated contentIntent was not sent by the actual tap")
    if deep_link.get("route_matches") is not True:
        errors.append("the tapped contentIntent action/data/route identity does not match the receipt")
    errors.extend(deep_link.get("tap_transition_errors") or [])
    if deep_link.get("pre_tap_target_absent") is not True:
        errors.append("the target prompt/session was not absent from the pre-tap decoy")
    if deep_link.get("actual_navigation") is not True:
        errors.append("actual navigation from the decoy to the intended existing chat is missing")
    if deep_link.get("correct_existing_chat") is not True:
        errors.append("the notification tap did not open the correct existing chat")
    if deep_link.get("session_marker_present") is not True:
        errors.append("the intended session identity was not visible after navigation")
    if deep_link.get("correlation_sha256") != run.get("correlation_sha256"):
        errors.append("run/session/deep-link correlation identities do not match")
    if run.get("prompt_sha256") != deep_link.get("prompt_sha256"):
        errors.append("run/deep-link chat identities do not match")
    return errors


def validate_capture_artifacts(artifacts):
    labels = {
        "logcat.redacted.txt": "logcat",
        "notification-dump.redacted.txt": "notification dump",
        "ui-latest.redacted.xml": "UI XML",
    }
    present = set(artifacts)
    return [f"redacted {label} evidence is missing"
            for name, label in labels.items() if name not in present]


def redact_ui_xml(xml_text):
    """Retain layout/selector structure but drop every text/description value."""
    root = ET.fromstring(xml_text)
    boolean_attributes = {
        "checkable", "checked", "clickable", "enabled", "focusable", "focused",
        "long-clickable", "password", "scrollable", "selected", "visible-to-user",
    }

    def clean(node):
        kept = {}
        for key, value in node.attrib.items():
            if key == "class" and SAFE_CLASS.fullmatch(value):
                kept[key] = value
            elif key == "package" and re.fullmatch(r"[A-Za-z0-9_.]+", value):
                kept[key] = value
            elif key == "resource-id" and (not value or SAFE_RESOURCE.fullmatch(value)):
                kept[key] = value
            elif key == "bounds" and BOUNDS.fullmatch(value):
                kept[key] = value
            elif key in boolean_attributes and value in ("true", "false"):
                kept[key] = value
            elif key in ("index", "rotation") and value.isdigit():
                kept[key] = value
        replacement = ET.Element(node.tag, kept)
        for child in list(node):
            replacement.append(clean(child))
        return replacement

    return ET.tostring(clean(root), encoding="unicode") + "\n"


def redact_logcat(text):
    """Keep line digests/event classes only; raw log lines are never evidence."""
    rows = []
    for number, line in enumerate(text.splitlines(), 1):
        lowered = line.lower()
        if "fatal exception" in lowered or "androidruntime" in lowered:
            category = "android_runtime"
        elif "firebase" in lowered or "fcm" in lowered:
            category = "firebase_or_fcm"
        else:
            category = "other"
        rows.append({
            "line": number,
            "sha256": sha256_text(line),
            "category": category,
            "token_or_authorization_marker": bool(
                re.search(r"authorization|bearer|fcm.?token|registration.?token", lowered)),
        })
    return json.dumps(rows, indent=2) + "\n"


def redact_notification_dump(text):
    return json.dumps(parse_notification_dump(text), indent=2) + "\n"


def redact_screenshot(png, xml_text):
    """Fail closed: XML bounds cannot prove a frame or all sensitive pixels."""
    raise HarnessError(
        "screenshots are omitted because synchronized frame correspondence and "
        "complete sensitive-pixel masking cannot be proven")


def _read_json(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise HarnessError("a required JSON evidence file is missing or too large")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise HarnessError("a required JSON evidence file is unreadable") from None
    if not isinstance(value, dict):
        raise HarnessError("a required JSON evidence file has the wrong shape")
    return value


def _fresh_inventory(apk, certificate, out, env, provenance):
    root = Path(__file__).resolve().parents[1]
    android_home = Path(env.get("ANDROID_HOME", "/opt/android-sdk"))
    tools = android_home / "build-tools/36.0.0"
    child_env = {
        "PATH": env.get("PATH", os.defpath),
        "ANDROID_HOME": str(android_home),
        "OVID_RELEASE_BUILD_COMMAND": BUILD_COMMAND,
    }
    revision = provenance.get("source_revision")
    if isinstance(revision, str) and re.fullmatch(r"[0-9a-fA-F]{40,64}", revision):
        child_env["GITHUB_SHA"] = revision
    apk.assert_all()
    with tempfile.TemporaryDirectory(prefix=".raw-inventory-", dir=out.path) as directory:
        destination = Path(directory) / "inventory.json"
        try:
            result = subprocess.run([
                sys.executable, str(root / "tool/release_inventory.py"), str(apk.install_path),
                "--mode", "production", "--profile", "sideload", "--expected-target", "36",
                "--expected-abis", "x86_64", "--certificate-sha256", certificate,
                "--build-tools", str(tools), "--output", str(destination),
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, env=child_env)
        except (OSError, subprocess.TimeoutExpired):
            raise HarnessError("fresh APK inspection could not be executed") from None
        apk.assert_all()
        if not destination.is_file():
            raise HarnessError("fresh APK inspection produced no evidence") from None
        inventory = _read_json(destination)
        apk.assert_all()
        if result.returncode != 0 and inventory.get("passed") is True:
            raise HarnessError("fresh APK inspection exit/evidence disagreement")
        return inventory


def sanitize_inventory(inventory, apk_sha256):
    manifest = inventory.get("manifest") or {}
    native = inventory.get("native") or {}
    signers = [value.lower() for value in inventory.get("signers_sha256", [])
               if isinstance(value, str) and _valid_certificate(value)]
    revision = inventory.get("source_revision")
    return {
        "artifact": "supplied APK",
        "sha256": apk_sha256,
        "size": inventory.get("size") if isinstance(inventory.get("size"), int) else None,
        "source_revision": revision if isinstance(revision, str) and re.fullmatch(r"[0-9a-fA-F]{40,64}", revision) else None,
        "build_command": BUILD_COMMAND if inventory.get("build_command") == BUILD_COMMAND else "noncanonical/withheld",
        "manifest": {
            "package": manifest.get("package") if manifest.get("package") == PACKAGE else None,
            "min_sdk": manifest.get("min_sdk") if isinstance(manifest.get("min_sdk"), int) else None,
            "target_sdk": manifest.get("target_sdk") if isinstance(manifest.get("target_sdk"), int) else None,
            "debuggable": manifest.get("debuggable") is True,
        },
        "signers_sha256": signers,
        "abis": [value for value in native.get("abis", []) if value in ("x86_64", "arm64-v8a", "armeabi-v7a")],
        "zip_alignment_passed": inventory.get("zip_alignment") == "16 KB check passed",
        "passed": inventory.get("passed") is True,
    }


def _new_report(avd):
    return {
        "schema": 2,
        "qualification": "actual emulator evidence only; no Play approval or physical-device claim",
        "state": "not provided",
        "passed": False,
        "avd": avd,
        "errors": [],
        "artifacts": [],
        "captures": {
            "screenshot": {
                "state": "not provided",
                "reason": "omitted: frame correspondence and complete sensitive-pixel masking cannot be proven",
            },
            "raw_ui_xml_cleanup": {"state": "not provided"},
        },
        "limitations": [
            "Transient shell-staged UI XML is deleted and checked, but device/system logs and other tools' copies cannot be forensically erased by this harness.",
        ],
    }


def _write_report(out, report):
    report["artifacts"] = out.artifact_names()
    report["passed"] = not report["errors"] and report["state"] == "passed"
    if report["errors"]:
        report["state"] = "failed"
        report["passed"] = False
    out.write_atomic(
        REPORT_NAME,
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        replace=REPORT_NAME in out.created,
    )


class AdbDevice:
    """Real ADB/UI-Automator boundary; all persisted outputs are redacted."""

    def __init__(self, apk, avd, out, env):
        self.apk = apk
        self.avd = avd
        self.out = out
        self.env = env
        home = Path(env.get("ANDROID_HOME", "/opt/android-sdk"))
        self.adb = str(home / "platform-tools/adb")
        self.emulator = str(home / "emulator/emulator")
        self.serial = None
        self.last_ui = None
        self.last_notification_dump = ""
        self.remote_ui_paths = set()
        self.stage = "setup"

    def _run(self, arguments, timeout=60, check=True, device=True, pass_fds=()):
        command = [self.adb]
        if device and self.serial:
            command += ["-s", self.serial]
        command += [str(argument) for argument in arguments]
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, pass_fds=pass_fds)
        except (OSError, subprocess.TimeoutExpired):
            raise HarnessError(f"ADB {self.stage} did not complete") from None
        if check and result.returncode != 0:
            raise HarnessError(f"ADB {self.stage} failed")
        return result.stdout

    def _text(self, arguments, **kwargs):
        try:
            return self._run(arguments, **kwargs).decode("utf-8", errors="replace")
        except HarnessError:
            raise

    def _shell(self, *arguments, **kwargs):
        return self._run(["shell", *arguments], **kwargs)

    def _exec(self, *arguments, **kwargs):
        return self._run(["exec-out", *arguments], **kwargs)

    def _connected_serials(self):
        output = self._text(["devices"], device=False)
        return [line.split()[0] for line in output.splitlines()[1:]
                if line.strip().endswith("\tdevice") and "\t" in line]

    def _avd_for_serial(self, serial):
        self.serial = serial
        return self._text(["shell", "getprop", "ro.kernel.qemu.avd_name"], check=False).strip()

    def _connect(self):
        if self.serial:
            return
        self.stage = "emulator selection"
        for serial in self._connected_serials():
            if self._avd_for_serial(serial) == self.avd:
                break
            self.serial = None
        if self.serial is None:
            if self._connected_serials():
                raise HarnessError("an attached emulator does not match the requested AVD")
            listed = subprocess.run([self.emulator, "-list-avds"], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=30)
            avds = listed.stdout.decode("utf-8", errors="replace").splitlines()
            if listed.returncode or self.avd not in avds:
                raise HarnessError("the requested AVD is unavailable")
            subprocess.Popen([
                self.emulator, "-avd", self.avd, "-no-window", "-no-boot-anim",
                "-gpu", "swiftshader_indirect", "-no-snapshot", "-accel", "on",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline and self.serial is None:
                time.sleep(2)
                for serial in self._connected_serials():
                    if self._avd_for_serial(serial) == self.avd:
                        break
                    self.serial = None
            if self.serial is None:
                raise HarnessError("the requested emulator did not boot")
        self.stage = "Android boot wait"
        self._run(["wait-for-device"], timeout=120)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            if self._text(["shell", "getprop", "sys.boot_completed"], check=False).strip() == "1":
                return
            time.sleep(2)
        raise HarnessError("Android did not finish booting")

    def _remove_remote_ui(self, remote):
        if not re.fullmatch(r"/data/local/tmp/ovid-release-ui-[0-9a-f]{32}\.xml", remote):
            raise HarnessError("raw UI XML cleanup path is invalid")
        try:
            self._shell("rm", "-f", "--", remote, timeout=30)
            self._shell("test", "!", "-e", remote, timeout=30)
        except HarnessError:
            raise HarnessError("raw UI XML cleanup could not be verified") from None

    def _dump_ui(self):
        self.stage = "UI XML capture"
        remote = f"/data/local/tmp/ovid-release-ui-{secrets.token_hex(16)}.xml"
        self.remote_ui_paths.add(remote)
        try:
            self._shell("uiautomator", "dump", remote, timeout=30)
            raw = self._exec("cat", remote, timeout=30).decode("utf-8", errors="strict")
            start, end = raw.find("<?xml"), raw.rfind("</hierarchy>")
            if start < 0 or end < 0:
                raise HarnessError("UI Automator returned no usable hierarchy")
            raw = raw[start:end + len("</hierarchy>")]
            ET.fromstring(raw)
            self.last_ui = raw
            self.out.write_atomic("ui-latest.redacted.xml", redact_ui_xml(raw), replace=True)
            return raw
        finally:
            self._remove_remote_ui(remote)
            self.remote_ui_paths.discard(remote)

    def cleanup(self):
        errors = []
        for remote in sorted(self.remote_ui_paths):
            try:
                self._remove_remote_ui(remote)
            except HarnessError:
                errors.append("raw UI XML cleanup could not be verified on a failure path")
            else:
                self.remote_ui_paths.discard(remote)
        return errors

    @staticmethod
    def _nodes(xml_text):
        root = ET.fromstring(xml_text)
        parents = {child: parent for parent in root.iter() for child in parent}
        return list(root.iter("node")), parents

    @staticmethod
    def _center(node):
        match = BOUNDS.fullmatch(node.get("bounds", ""))
        if not match:
            raise HarnessError("a required UI control has no usable bounds")
        left, top, right, bottom = (int(value) for value in match.groups())
        return (left + right) // 2, (top + bottom) // 2

    def _matching_nodes(self, xml_text, label):
        nodes, parents = self._nodes(xml_text)
        matches = []
        for node in nodes:
            if label not in (node.get("text"), node.get("content-desc")):
                continue
            target = node
            while target in parents and target.get("clickable") != "true":
                target = parents[target]
            if node.get("enabled", "true") == "false":
                continue
            matches.append(target)
        return matches

    def _has_label(self, xml_text, label):
        return bool(self._matching_nodes(xml_text, label))

    def _tap_label(self, label, timeout=60):
        self.stage = "real UI control tap"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            matches = self._matching_nodes(self._dump_ui(), label)
            if len(matches) == 1:
                x, y = self._center(matches[0])
                self._shell("input", "tap", str(x), str(y))
                return
            if len(matches) > 1:
                raise HarnessError("a required UI control was ambiguous")
            time.sleep(1)
        raise HarnessError("a required real UI control was unavailable")

    def _wait_for(self, predicate, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            xml_text = self._dump_ui()
            if predicate(xml_text):
                return xml_text
            time.sleep(1)
        raise HarnessError(f"timed out during {self.stage}")

    def _pid(self):
        self.stage = "process identity check"
        value = self._text(["shell", "pidof", PACKAGE], check=False).strip()
        return int(value) if value.isdigit() else None

    def install_verified(self):
        self._connect()
        self.stage = "inspected APK installation"
        self.apk.assert_all()
        descriptor = self.apk.copy_fd
        self._run(["install", "-r", f"/proc/self/fd/{descriptor}"],
                  timeout=180, pass_fds=(descriptor,))
        self.apk.assert_all()
        self._shell("pm", "clear", PACKAGE, timeout=60)
        self._shell("pm", "grant", PACKAGE, "android.permission.POST_NOTIFICATIONS", check=False)
        package_path = self._text(["shell", "pm", "path", PACKAGE])
        match = re.search(r"(?m)^package:(/\S*base\.apk)\s*$", package_path)
        if not match:
            raise HarnessError("installed APK path evidence is missing")
        self.apk.assert_all()
        with tempfile.TemporaryDirectory(prefix=".installed-apk-", dir=self.apk.work_path) as directory:
            installed = Path(directory) / "base.apk"
            self._run(["pull", match.group(1), str(installed)], timeout=120)
            self.apk.assert_all()
            if not installed.is_file() or sha256_file(installed) != self.apk.sha256:
                raise HarnessError("installed APK differs from the originally inspected hash")

    def install_launch_and_sign_in(self):
        self.install_verified()
        self.stage = "release launcher"
        self._run(["logcat", "-c"], check=False)
        self._shell("am", "force-stop", PACKAGE)
        self._shell("monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
        self.stage = "real Firebase UI sign-in"
        initial = self._wait_for(lambda xml: self._has_label(xml, "Continue with Google")
                                 or self._has_label(xml, "Send"), timeout=90)
        if not self._has_label(initial, "Continue with Google"):
            raise HarnessError("the fresh release launch did not show the real sign-in gate")
        self._tap_label("Continue with Google")
        account = self.env.get("OVID_EMULATOR_ACCOUNT", "")
        if not account:
            raise HarnessError("OVID_EMULATOR_ACCOUNT is required to choose the real test account in the UI")
        self._tap_label(account, timeout=90)
        self.stage = "cloud account admission"
        self._wait_for(lambda xml: self._has_label(xml, "Send")
                       and not self._has_label(xml, "Continue with Google"), timeout=120)
        device = {
            "state": "passed",
            "api": int(self._text(["shell", "getprop", "ro.build.version.sdk"]).strip()),
            "abis": self._text(["shell", "getprop", "ro.product.cpu.abilist"]).strip().split(","),
        }
        return {"installed": True, "real_ui_sign_in": True, "device": device}

    def process_id(self):
        return self._pid()

    def verify_session_marker(self, session_marker):
        self.stage = "post-navigation session identity"
        self._tap_label("Open navigation drawer", timeout=30)
        try:
            xml = self._wait_for(lambda value: self._has_label(value, session_marker), timeout=30)
            return self._has_label(xml, session_marker)
        except HarnessError:
            return False
        finally:
            self._shell("input", "keyevent", "KEYCODE_BACK", check=False)
            self._wait_for(lambda value: self._has_label(value, "Send"), timeout=30)

    def _rename_chat_for_correlation(self, session_marker):
        self.stage = "real UI session correlation rename"
        self._tap_label("More options")
        self._tap_label("Rename chat")
        xml = self._dump_ui()
        nodes, _ = self._nodes(xml)
        fields = [node for node in nodes if node.get("class") == "android.widget.EditText"]
        if len(fields) != 1:
            raise HarnessError("the rename field was not uniquely available")
        x, y = self._center(fields[0])
        self._shell("input", "tap", str(x), str(y))
        self._shell("input", "keyevent", "--meta", "META_CTRL_ON", "KEYCODE_A")
        self._shell("input", "text", session_marker.replace(" ", "%s"))
        self._wait_for(lambda value: session_marker in value, timeout=30)
        self._tap_label("Save")
        if not self.verify_session_marker(session_marker):
            raise HarnessError("the real UI session correlation rename was not visible")

    def trigger_real_run(self, prompt):
        self.stage = "real UI chat run"
        marker = re.search(r"\bAcceptance(?: fixture)? ([0-9a-fA-F]{6,32})\b", prompt)
        if marker is None:
            raise HarnessError("the acceptance prompt lacks a safe run correlation nonce")
        nonce = marker.group(1).lower()
        session_marker = f"Acceptance {nonce}"
        correlation = sha256_text(nonce)
        baseline = {record["id"] for record in parse_notification_dump(
            self._text(["shell", "dumpsys", "notification", "--noredact"]))}
        self._rename_chat_for_correlation(session_marker)
        self.stage = "real UI chat run"
        self._dump_ui()
        nodes, _ = self._nodes(self.last_ui)
        composers = [node for node in nodes if node.get("class") == "android.widget.EditText"]
        if len(composers) != 1:
            raise HarnessError("the chat composer was not uniquely available")
        x, y = self._center(composers[0])
        self._shell("input", "tap", str(x), str(y))
        escaped = prompt.replace("\\", "\\\\").replace(" ", "%s")
        self._shell("input", "text", escaped)
        self._wait_for(lambda xml: prompt in xml, timeout=30)
        started_ms = int(time.time() * 1000)
        self._tap_label("Send", timeout=30)
        self.stage = "real run submission"
        self._wait_for(lambda xml: _xml_text_outside_inputs(xml, prompt), timeout=60)
        return {
            "submitted": True,
            "started_ms": started_ms,
            "baseline_notification_ids": sorted(baseline),
            "correlation_sha256": correlation,
            "session_marker": session_marker,
        }

    def force_stop(self):
        self.stage = "forced process stop"
        self._shell("am", "force-stop", PACKAGE)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self._pid() is None:
                return True
            time.sleep(0.25)
        return False

    def relaunch_and_background(self):
        self.stage = "fresh process relaunch"
        self._shell("monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
        deadline = time.monotonic() + 60
        pid = None
        while time.monotonic() < deadline:
            pid = self._pid()
            if pid is not None:
                break
            time.sleep(0.25)
        if pid is not None:
            self._shell("input", "keyevent", "KEYCODE_HOME")
        return pid

    def kill_background_process(self):
        """Clear force-stop, then kill the cached process so only FCM can wake it."""
        self.stage = "background process death before FCM receipt"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            self._shell("input", "keyevent", "KEYCODE_HOME")
            self._shell("am", "kill", PACKAGE)
            if self._pid() is None:
                return True
            time.sleep(0.25)
        return False

    def prepare_deep_link_probe(self, run):
        """Restore into a different chat so a no-op tap cannot reuse the target."""
        self.stage = "pre-tap decoy chat"
        self._shell("monkey", "-p", PACKAGE, "-c", "android.intent.category.LAUNCHER", "1")
        self._tap_label("More options")
        self._tap_label("New chat")
        xml = self._wait_for(lambda value: self._has_label(value, "Send"), timeout=60)
        target_absent = (not _xml_text_outside_inputs(xml, run["session_marker"])
                         and not _xml_text_outside_inputs(xml, run["_prompt"]))
        baseline = {
            "target_absent": target_absent,
            "screen_sha256": sha256_text(xml),
        }
        self._shell("input", "keyevent", "KEYCODE_HOME")
        if not target_absent:
            raise HarnessError("the pre-tap decoy still contains the target chat")
        return baseline

    def wait_for_notification(self, since, baseline_ids, run):
        self.stage = "actual Android notification receipt"
        timeout = int(self.env.get("OVID_EMULATOR_RECEIPT_TIMEOUT", "300"))
        deadline = time.monotonic() + min(max(timeout, 1), 1800)
        ignored = set(baseline_ids)
        while time.monotonic() < deadline:
            self.last_notification_dump = self._text([
                "shell", "dumpsys", "notification", "--noredact"])
            records = [record for record in parse_notification_dump(self.last_notification_dump)
                       if record["package"] == PACKAGE and record["id"] not in ignored
                       and record["post_time"] >= since
                       and record.get("correlation_sha256") == run.get("correlation_sha256")]
            records.sort(key=lambda record: record["post_time"], reverse=True)
            for record in records:
                pending = self._text(["shell", "dumpsys", "activity", "intents"])
                content = correlate_content_intent(record, pending)
                if content is not None:
                    record["content_intent"] = content
                    return record
            time.sleep(1)
        return None

    def _tap_correlated_shade_row(self, title, session_marker):
        self.stage = "correlated shade-row selection"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            xml = self._dump_ui()
            nodes, parents = self._nodes(xml)
            candidates = []
            for node in nodes:
                text = node.get("text", "") + "\n" + node.get("content-desc", "")
                if session_marker not in text:
                    continue
                target = node
                while target in parents and target.get("clickable") != "true":
                    target = parents[target]
                descendants = list(target.iter("node"))
                if any(title in (child.get("text"), child.get("content-desc"))
                       for child in descendants):
                    candidates.append(target)
            identities = {id(candidate) for candidate in candidates}
            if len(candidates) == 1 and len(identities) == 1:
                x, y = self._center(candidates[0])
                self._shell("input", "tap", str(x), str(y))
                return
            if len(candidates) > 1:
                raise HarnessError("the correlated notification shade row was ambiguous")
            time.sleep(1)
        raise HarnessError("the correlated notification shade row was unavailable")

    def tap_notification(self, receipt, session_marker):
        self.stage = "actual notification tap"
        title = KIND_TITLES.get(receipt.get("kind"))
        if title is None:
            raise HarnessError("the received notification kind has no safe UI selector")
        self._shell("cmd", "statusbar", "expand-notifications")
        self._tap_correlated_shade_row(title, session_marker)
        pending = self._text(["shell", "dumpsys", "activity", "intents"])
        matches = _matching_pending_intents(receipt, pending)
        self._shell("cmd", "statusbar", "collapse", check=False)
        if len(matches) != 1:
            raise HarnessError("the tapped contentIntent identity disappeared or became ambiguous")
        return {
            "shade_tapped": True,
            "after_content_intent": _pending_intent_content_evidence(matches[0]),
        }

    def current_ui_xml(self):
        self.stage = "correct existing chat verification"
        return self._wait_for(lambda xml: self._has_label(xml, "Send"), timeout=90)

    def capture_evidence(self):
        """Persist only text evidence whose redaction is well-defined."""
        captured = set()
        try:
            self.stage = "sanitized logcat capture"
            raw = self._run(["logcat", "-d"], timeout=60).decode("utf-8", errors="replace")
            self.out.write_atomic("logcat.redacted.txt", redact_logcat(raw))
            captured.add("logcat.redacted.txt")
        except (HarnessError, OSError, ValueError):
            pass
        try:
            self.stage = "sanitized notification capture"
            raw = self.last_notification_dump or self._text([
                "shell", "dumpsys", "notification", "--noredact"])
            self.out.write_atomic(
                "notification-dump.redacted.txt", redact_notification_dump(raw))
            captured.add("notification-dump.redacted.txt")
        except (HarnessError, OSError, ValueError):
            pass
        if "ui-latest.redacted.xml" in self.out.artifact_names():
            captured.add("ui-latest.redacted.xml")
        # Screenshots are intentionally not requested or persisted. A UI dump
        # cannot establish frame identity or mask custom/image-only secrets.
        return captured


def _argument_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--avd", required=True)
    parser.add_argument("--out", required=True)
    return parser


def _out_hint(arguments):
    try:
        index = arguments.index("--out")
        return arguments[index + 1]
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
                out = EvidenceStore.create(hint)
                report = _new_report("not provided")
                report["errors"].append("invalid harness arguments")
                _write_report(out, report)
                out.close()
            except HarnessError:
                pass
        return int(error.code)

    report = _new_report(args.avd if SAFE_NAME.fullmatch(args.avd) else "not provided")
    try:
        out = EvidenceStore.create(args.out)
    except HarnessError:
        # An unsafe/reused destination cannot receive a report without risking
        # an external write or attaching stale evidence. It still fails nonzero.
        return 2
    apk = None
    device = None
    captures_complete = False
    try:
        _write_report(out, report)
        if not SAFE_NAME.fullmatch(args.avd):
            raise HarnessError("AVD name is invalid")
        errors = validate_operator_environment(env)
        certificate = env.get("ANDROID_SIGNING_CERT_SHA256", "").replace(":", "").lower()
        if not _valid_certificate(certificate):
            errors.append("ANDROID_SIGNING_CERT_SHA256 must pin the release certificate")
        try:
            apk = PinnedApk.open(args.apk)
        except HarnessError as error:
            errors.append(str(error))
        if errors:
            report["errors"].extend(errors)
            return 1
        apk.create_verified_copy(out.path / f".apk-work-{secrets.token_hex(8)}")

        provenance_path = env.get("OVID_RELEASE_INVENTORY")
        provenance_path = Path(provenance_path) if provenance_path else apk.path.parent / "release-inventory.json"
        try:
            provenance = _read_json(provenance_path)
        except HarnessError:
            report["errors"].append(
                "matching signed build provenance is missing; set OVID_RELEASE_INVENTORY to the real release inventory")
            return 1
        fresh = _fresh_inventory(apk, certificate, out, env, provenance)
        report["artifact"] = sanitize_inventory(fresh, apk.sha256)
        out.write_atomic(
            "artifact-inspection.sanitized.json",
            json.dumps(report["artifact"], indent=2, sort_keys=True) + "\n")
        report["errors"].extend(validate_artifact(provenance, fresh, apk.sha256, certificate))
        if report["errors"]:
            return 1

        device = AdbDevice(apk, args.avd, out, env)
        evidence = execute_device_flow(device, "Reply with OK. Acceptance " + secrets.token_hex(4) + ".")
        report["evidence"] = evidence
        report["errors"].extend(validate_acceptance(evidence))
        captured = device.capture_evidence()
        captures_complete = True
        report["errors"].extend(validate_capture_artifacts(captured))
        report["state"] = "passed" if not report["errors"] else "failed"
        return 0 if report["state"] == "passed" else 1
    except HarnessError as error:
        report["errors"].append(str(error))
        report["state"] = "failed"
        return 1
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError):
        report["errors"].append("harness stopped before evidence was complete")
        report["state"] = "failed"
        return 1
    finally:
        cleanup_errors = []
        if device is not None:
            cleanup_errors = device.cleanup()
            report["errors"].extend(cleanup_errors)
            report["captures"]["raw_ui_xml_cleanup"] = {
                "state": "failed" if cleanup_errors else "passed",
            }
            if not captures_complete:
                captured = device.capture_evidence()
                report["errors"].extend(validate_capture_artifacts(captured))
        report["errors"] = list(dict.fromkeys(report["errors"]))
        report["passed"] = False
        if not report["errors"] and report["state"] == "passed":
            report["passed"] = True
        try:
            _write_report(out, report)
        except HarnessError:
            if apk is not None:
                apk.close()
            out.close()
            return 1
        if apk is not None:
            apk.close()
        out.close()


if __name__ == "__main__":
    sys.exit(main())
