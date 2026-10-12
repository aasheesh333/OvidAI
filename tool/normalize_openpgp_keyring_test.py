import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from normalize_openpgp_keyring import normalize  # noqa: E402


class NormalizeTest(unittest.TestCase):
    def test_one_octet_header_becomes_two_octet(self):
        body = bytes(range(0x33))
        src = bytes([0x98, len(body)]) + body + bytes([0xB4, 3]) + b'uid'
        out = normalize(src)
        self.assertEqual(out[:3], bytes([0x99, 0x00, 0x33]))
        self.assertEqual(out[3:3 + len(body)], body)
        self.assertEqual(out[3 + len(body):], bytes([0xB5, 0x00, 3]) + b'uid')

    def test_two_octet_and_new_format_are_copied(self):
        src = bytes([0x99, 0x00, 0x02, 1, 2, 0xC6, 0x02, 3, 4])
        self.assertEqual(normalize(src), src)

    def test_rejects_garbage_and_truncation(self):
        with self.assertRaises(ValueError):
            normalize(b'-----BEGIN PGP')
        with self.assertRaises(ValueError):
            normalize(bytes([0x98, 0x10, 1]))


if __name__ == '__main__':
    unittest.main()
