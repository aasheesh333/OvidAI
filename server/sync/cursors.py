"""Pure, opaque cursors for account/device-scoped sync replay."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import re
import secrets
import struct
from dataclasses import dataclass


MAX_CURSOR_BYTES = 512
MAX_CHANGE_SEQUENCE = 2**53 - 1
MAX_CURSOR_TTL_SECONDS = 30 * 24 * 60 * 60
MIN_SECRET_BYTES = 16
MAX_SECRET_BYTES = 128
MAX_ID_BYTES = 128

_VERSION = b"C1"
_NONCE_BYTES = 16
_MAC_BYTES = hashlib.sha256().digest_size
_PAYLOAD_BYTES = len(_VERSION) + 8 + 8 + _NONCE_BYTES
_TOKEN_BYTES = _PAYLOAD_BYTES + _MAC_BYTES
_ID = re.compile(r"^[\x21-\x7e]{1,128}$")
_TOKEN = re.compile(r"^[A-Za-z0-9_-]+$")


class CursorError(ValueError):
    """Raised for every malformed, expired, or context-invalid cursor."""


@dataclass(frozen=True)
class Cursor:
    change_sequence: int
    expires_at: int


def _identity(value: object) -> bytes:
    if type(value) is not str or not _ID.fullmatch(value):
        raise CursorError("invalid cursor")
    return value.encode("ascii")


def _secret(value: object) -> bytes:
    if type(value) is not bytes or not MIN_SECRET_BYTES <= len(value) <= MAX_SECRET_BYTES:
        raise CursorError("invalid cursor")
    return value


def _clock(value: object) -> int:
    if type(value) is not int or value < 0:
        raise CursorError("invalid cursor")
    return value


def _context(account_id: str, device_id: str) -> bytes:
    account = _identity(account_id)
    device = _identity(device_id)
    return b"sync-cursor\0" + len(account).to_bytes(2, "big") + account + device


def _mac(secret: bytes, context: bytes, payload: bytes) -> bytes:
    return hmac.new(secret, context + payload, hashlib.sha256).digest()


def encode_cursor(
    account_id: str,
    device_id: str,
    change_sequence: int,
    expires_at: int,
    secret: bytes,
    *,
    now: int | None = None,
) -> str:
    """Encode a short-lived cursor without serializing account/device IDs."""
    context = _context(account_id, device_id)
    signing_secret = _secret(secret)
    current = _clock(0 if now is None else now)
    if type(change_sequence) is not int or not 1 <= change_sequence <= MAX_CHANGE_SEQUENCE:
        raise CursorError("invalid cursor")
    if type(expires_at) is not int or not current < expires_at <= current + MAX_CURSOR_TTL_SECONDS:
        raise CursorError("invalid cursor")

    payload = _VERSION + struct.pack(">QQ", change_sequence, expires_at) + secrets.token_bytes(_NONCE_BYTES)
    token = base64.urlsafe_b64encode(payload + _mac(signing_secret, context, payload)).rstrip(b"=")
    if len(token) > MAX_CURSOR_BYTES:
        raise CursorError("invalid cursor")
    return token.decode("ascii")


def decode_cursor(
    value: object,
    account_id: str,
    device_id: str,
    secret: bytes,
    *,
    now: int | None = None,
) -> Cursor:
    """Authenticate and decode a cursor for exactly one account and device."""
    context = _context(account_id, device_id)
    signing_secret = _secret(secret)
    current = _clock(0 if now is None else now)
    if type(value) is not str or not 1 <= len(value.encode("utf-8")) <= MAX_CURSOR_BYTES:
        raise CursorError("invalid cursor")
    if _TOKEN.fullmatch(value) is None:
        raise CursorError("invalid cursor")
    try:
        encoded = value.encode("ascii")
        raw = base64.b64decode(encoded + b"=" * (-len(encoded) % 4), altchars=b"-_", validate=True)
    except (UnicodeEncodeError, binascii.Error, ValueError):
        raise CursorError("invalid cursor") from None
    if len(raw) != _TOKEN_BYTES:
        raise CursorError("invalid cursor")
    payload, supplied_mac = raw[:-_MAC_BYTES], raw[-_MAC_BYTES:]
    if not hmac.compare_digest(supplied_mac, _mac(signing_secret, context, payload)):
        raise CursorError("invalid cursor")
    if payload[: len(_VERSION)] != _VERSION:
        raise CursorError("invalid cursor")
    try:
        sequence, expires_at = struct.unpack(">QQ", payload[len(_VERSION) : len(_VERSION) + 16])
    except struct.error:
        raise CursorError("invalid cursor") from None
    if not 1 <= sequence <= MAX_CHANGE_SEQUENCE or expires_at <= current:
        raise CursorError("invalid cursor")
    if expires_at > current + MAX_CURSOR_TTL_SECONDS:
        raise CursorError("invalid cursor")
    return Cursor(sequence, expires_at)
