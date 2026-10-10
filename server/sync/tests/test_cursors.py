import base64
import unittest
from dataclasses import FrozenInstanceError

from server.sync.cursors import (
    MAX_CHANGE_SEQUENCE,
    MAX_CURSOR_BYTES,
    MAX_CURSOR_TTL_SECONDS,
    Cursor,
    CursorError,
    decode_cursor,
    encode_cursor,
)


SECRET = b"server-only cursor signing secret"
ACCOUNT = "account-123"
DEVICE = "device-456"
NOW = 1_700_000_000


def token(sequence=42, expires_at=NOW + 3600):
    return encode_cursor(
        ACCOUNT,
        DEVICE,
        sequence,
        expires_at,
        SECRET,
        now=NOW,
    )


class CursorTests(unittest.TestCase):
    def test_round_trip_returns_opaque_bound_position(self):
        encoded = token()

        self.assertIsInstance(encoded, str)
        self.assertLessEqual(len(encoded.encode("ascii")), MAX_CURSOR_BYTES)
        self.assertNotIn(ACCOUNT, encoded)
        self.assertNotIn(DEVICE, encoded)
        self.assertNotIn(SECRET.decode(), encoded)
        self.assertEqual(
            decode_cursor(encoded, ACCOUNT, DEVICE, SECRET, now=NOW),
            Cursor(change_sequence=42, expires_at=NOW + 3600),
        )

    def test_cursor_is_immutable(self):
        decoded = decode_cursor(token(), ACCOUNT, DEVICE, SECRET, now=NOW)

        with self.assertRaises(FrozenInstanceError):
            decoded.change_sequence = 7

    def test_wrong_account_or_device_is_rejected(self):
        encoded = token()

        for account, device in (("other-account", DEVICE), (ACCOUNT, "other-device")):
            with self.subTest(account=account, device=device):
                with self.assertRaises(CursorError):
                    decode_cursor(encoded, account, device, SECRET, now=NOW)

    def test_wrong_secret_is_rejected(self):
        with self.assertRaises(CursorError):
            decode_cursor(token(), ACCOUNT, DEVICE, b"different secret", now=NOW)

    def test_tampered_and_malformed_values_are_rejected(self):
        encoded = token()
        tampered = encoded[:-1] + ("A" if encoded[-1] != "A" else "B")
        malformed = ("!" * 513, "not-base64", "", "a=" + encoded)

        for value in (tampered, *malformed):
            with self.subTest(value=value):
                with self.assertRaises(CursorError):
                    decode_cursor(value, ACCOUNT, DEVICE, SECRET, now=NOW)

    def test_expiry_is_rejected_at_and_after_expiration(self):
        encoded = token(expires_at=NOW + 10)

        with self.assertRaises(CursorError):
            decode_cursor(encoded, ACCOUNT, DEVICE, SECRET, now=NOW + 10)
        with self.assertRaises(CursorError):
            decode_cursor(encoded, ACCOUNT, DEVICE, SECRET, now=NOW + 11)

    def test_expiry_must_be_within_bounded_lifetime(self):
        with self.assertRaises(CursorError):
            encode_cursor(ACCOUNT, DEVICE, 1, NOW + MAX_CURSOR_TTL_SECONDS + 1, SECRET, now=NOW)

    def test_sequence_and_expiry_values_are_bounded(self):
        for sequence in (0, -1, MAX_CHANGE_SEQUENCE + 1, True):
            with self.subTest(sequence=sequence), self.assertRaises(CursorError):
                encode_cursor(ACCOUNT, DEVICE, sequence, NOW + 1, SECRET, now=NOW)

        for expires_at in (NOW, NOW - 1, NOW + 0.5, True):
            with self.subTest(expires_at=expires_at), self.assertRaises(CursorError):
                encode_cursor(ACCOUNT, DEVICE, 1, expires_at, SECRET, now=NOW)

    def test_identity_and_secret_inputs_are_bounded(self):
        invalid = ("", "a" * 129, "account\n", True, 1)

        for account in invalid:
            with self.subTest(account=account), self.assertRaises(CursorError):
                encode_cursor(account, DEVICE, 1, NOW + 1, SECRET, now=NOW)
        for device in invalid:
            with self.subTest(device=device), self.assertRaises(CursorError):
                encode_cursor(ACCOUNT, device, 1, NOW + 1, SECRET, now=NOW)
        for secret in (b"", b"short", "not-bytes", True):
            with self.subTest(secret=secret), self.assertRaises(CursorError):
                encode_cursor(ACCOUNT, DEVICE, 1, NOW + 1, secret, now=NOW)

    def test_decode_rejects_non_string_or_oversized_cursor(self):
        for value in (None, b"bytes", 1, [token()], "A" * (MAX_CURSOR_BYTES + 1)):
            with self.subTest(value=type(value).__name__), self.assertRaises(CursorError):
                decode_cursor(value, ACCOUNT, DEVICE, SECRET, now=NOW)

    def test_token_uses_unpadded_url_safe_encoding(self):
        encoded = token()
        self.assertNotIn("=", encoded)
        self.assertEqual(base64.urlsafe_b64decode(encoded + "==").__class__, bytes)


if __name__ == "__main__":
    unittest.main()
