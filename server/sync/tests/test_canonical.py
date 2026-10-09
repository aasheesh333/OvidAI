"""RFC 8785 (JCS) codec and strict decoder tests (stdlib unittest only).

Expected strings below are hand-copied from RFC 8785 or hand-written, never
derived from the serializer under test.
"""

import json
import math
import struct
import unittest
from pathlib import Path

from server.sync.canonical import CanonicalizationError, canonical_bytes, decode_strict
from server.sync.errors import SyncError

REPO_ROOT = Path(__file__).resolve().parents[3]
VECTORS_PATH = REPO_ROOT / "test" / "fixtures" / "private_sync" / "canonical_vectors.json"


def f64(bits: int) -> float:
    return struct.unpack(">d", bits.to_bytes(8, "big"))[0]


def jcs(value) -> str:
    return canonical_bytes(value).decode("utf-8")


# RFC 8785 Appendix B: IEEE-754 bit pattern -> canonical serialization.
RFC8785_NUMBERS = [
    (0x0000000000000000, "0"),
    (0x8000000000000000, "0"),
    (0x0000000000000001, "5e-324"),
    (0x8000000000000001, "-5e-324"),
    (0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308"),
    (0xFFEFFFFFFFFFFFFF, "-1.7976931348623157e+308"),
    (0x4340000000000000, "9007199254740992"),
    (0xC340000000000000, "-9007199254740992"),
    (0x4430000000000000, "295147905179352830000"),
    (0x44B52D02C7E14AF5, "9.999999999999997e+22"),
    (0x44B52D02C7E14AF6, "1e+23"),
    (0x44B52D02C7E14AF7, "1.0000000000000001e+23"),
    (0x444B1AE4D6E2EF4E, "999999999999999700000"),
    (0x444B1AE4D6E2EF4F, "999999999999999900000"),
    (0x444B1AE4D6E2EF50, "1e+21"),
    (0x3EB0C6F7A0B5ED8C, "9.999999999999997e-7"),
    (0x3EB0C6F7A0B5ED8D, "0.000001"),
    (0x41B3DE4355555553, "333333333.3333332"),
    (0x41B3DE4355555554, "333333333.33333325"),
    (0x41B3DE4355555555, "333333333.3333333"),
    (0x41B3DE4355555556, "333333333.3333334"),
    (0x41B3DE4355555557, "333333333.33333343"),
    (0xBECBF647612F3696, "-0.0000033333333333333333"),
    (0x43143FF3C1CB0959, "1424953923781206.2"),
]


class NumberTests(unittest.TestCase):
    def test_rfc8785_appendix_b_table(self):
        for bits, expected in RFC8785_NUMBERS:
            with self.subTest(bits=hex(bits)):
                self.assertEqual(jcs(f64(bits)), expected)

    def test_rfc8785_appendix_b_rejects_nan_and_infinity(self):
        for bits in (0x7FFFFFFFFFFFFFFF, 0x7FF0000000000000, 0xFFF0000000000000):
            with self.subTest(bits=hex(bits)), self.assertRaises(CanonicalizationError):
                canonical_bytes(f64(bits))
        for value in (math.nan, math.inf, -math.inf, [1, math.nan], {"a": math.inf}):
            with self.subTest(value=value), self.assertRaises(CanonicalizationError):
                canonical_bytes(value)

    def test_integral_floats_have_no_fraction(self):
        self.assertEqual(jcs(4.0), "4")
        self.assertEqual(jcs(-0.0), "0")
        self.assertEqual(jcs(1e21), "1e+21")
        self.assertEqual(jcs(1e20), "100000000000000000000")
        self.assertEqual(jcs(1e-7), "1e-7")
        self.assertEqual(jcs(0.5), "0.5")

    def test_python_ints_within_ieee_exact_range(self):
        self.assertEqual(jcs(0), "0")
        self.assertEqual(jcs(-7), "-7")
        self.assertEqual(jcs(4294967295), "4294967295")
        self.assertEqual(jcs(9007199254740992), "9007199254740992")
        self.assertEqual(jcs(-9007199254740992), "-9007199254740992")

    def test_python_ints_beyond_ieee_exact_range_rejected(self):
        for value in (9007199254740993, -9007199254740993, 10**30):
            with self.subTest(value=value), self.assertRaises(CanonicalizationError):
                canonical_bytes(value)

    def test_booleans_are_literals_not_numbers(self):
        self.assertEqual(jcs([True, False, None]), "[true,false,null]")


class StringTests(unittest.TestCase):
    def test_short_escapes_and_lowercase_hex(self):
        self.assertEqual(jcs("\b\t\n\f\r"), '"\\b\\t\\n\\f\\r"')
        self.assertEqual(jcs("\x00\x01\x0b\x0e\x1f"), '"\\u0000\\u0001\\u000b\\u000e\\u001f"')
        self.assertEqual(jcs('"\\'), '"\\"\\\\"')

    def test_no_escaping_outside_required_set(self):
        # Solidus, DEL, C1 controls, line/paragraph separators and non-ASCII are literal.
        value = "/\x7f\x80\u2028\u2029\u20ac\U0001F600"
        self.assertEqual(jcs(value), '"' + value + '"')
        self.assertEqual(canonical_bytes("\u20ac"), b'"\xe2\x82\xac"')
        self.assertEqual(canonical_bytes("\U0001F600"), b'"\xf0\x9f\x98\x80"')

    def test_lone_surrogates_rejected(self):
        for value in ("\ud800", "\udfff", "a\ud83d", "\ude00\ud83d", "\ud83d\ude00"):
            with self.subTest(value=ascii(value)), self.assertRaises(CanonicalizationError):
                canonical_bytes(value)
        with self.assertRaises(CanonicalizationError):
            canonical_bytes({"\udc00": 1})


class StructureTests(unittest.TestCase):
    def test_rfc8785_section_3_2_2_example(self):
        value = {
            "numbers": [333333333.33333329, 1e30, 4.50, 2e-3, 0.000000000000000000000000001],
            "string": "\u20ac$\u000f\u000aA'\u0042\u0022\u005c\\\"/",
            "literals": [None, True, False],
        }
        expected = (
            '{"literals":[null,true,false],'
            '"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],'
            '"string":"\u20ac$\\u000f\\nA\'B\\"\\\\\\\\\\"/"}'
        )
        self.assertEqual(jcs(value), expected)

    def test_rfc8785_section_3_2_3_utf16_key_ordering(self):
        value = {
            "\u20ac": "Euro Sign",
            "\r": "Carriage Return",
            "\ufb33": "Hebrew Letter Dalet With Dagesh",
            "1": "One",
            "\U0001F600": "Emoji: Grinning Face",
            "\u0080": "Control",
            "\u00f6": "Latin Small Letter O With Diaeresis",
        }
        expected = (
            '{"\\r":"Carriage Return","1":"One","\u0080":"Control",'
            '"\u00f6":"Latin Small Letter O With Diaeresis","\u20ac":"Euro Sign",'
            '"\U0001F600":"Emoji: Grinning Face","\ufb33":"Hebrew Letter Dalet With Dagesh"}'
        )
        self.assertEqual(jcs(value), expected)

    def test_utf16_order_differs_from_code_point_order(self):
        # U+1F600 (UTF-16 D83D DE00) sorts before U+FFFD; code-point order would invert.
        self.assertEqual(jcs({"\ufffd": 1, "\U0001F600": 2}), '{"\U0001F600":2,"\ufffd":1}')

    def test_nested_and_empty(self):
        self.assertEqual(jcs({}), "{}")
        self.assertEqual(jcs([]), "[]")
        self.assertEqual(jcs({"b": [{"d": 1, "c": None}], "a": {}}), '{"a":{},"b":[{"c":null,"d":1}]}')

    def test_unsupported_types_rejected(self):
        for value in ((1, 2), {1: "a"}, b"x", object(), {1.5}, lambda: None, {"a": (1,)}):
            with self.subTest(value=type(value).__name__), self.assertRaises(CanonicalizationError):
                canonical_bytes(value)

    def test_deep_nesting_rejected_without_recursion_error(self):
        value = []
        for _ in range(100000):
            value = [value]
        with self.assertRaises(CanonicalizationError):
            canonical_bytes(value)


class StrictDecoderTests(unittest.TestCase):
    def assertRejected(self, data):
        with self.assertRaises(SyncError) as caught:
            decode_strict(data)
        self.assertEqual(caught.exception.code, "invalid_request")

    def test_decodes_valid_json(self):
        self.assertEqual(decode_strict(b' {"a":[1,2.5,"\\u20ac",null,true]} '), {"a": [1, 2.5, "\u20ac", None, True]})
        self.assertEqual(decode_strict('"\\ud83d\\ude00"'), "\U0001F600")

    def test_rejects_duplicate_keys(self):
        self.assertRejected(b'{"a":1,"a":1}')
        self.assertRejected(b'{"a":1,"\\u0061":2}')
        self.assertRejected(b'{"x":{"b":1,"b":2}}')
        self.assertRejected(b'[{"k":1},{"k":1,"k":1}]')

    def test_rejects_non_finite_numbers(self):
        for data in (b"NaN", b"Infinity", b"-Infinity", b'{"a":NaN}', b"1e400", b"-1e400"):
            with self.subTest(data=data):
                self.assertRejected(data)

    def test_rejects_lone_surrogates(self):
        for data in (b'"\\ud800"', b'"\\udc00"', b'"\\ude00\\ud83d"', b'{"\\ud800":1}', b'["a\\ud83d"]'):
            with self.subTest(data=data):
                self.assertRejected(data)

    def test_rejects_invalid_utf8_and_bom(self):
        for data in (b'"\xff"', b'"\xed\xa0\x80"', b'"\xc0\xaf"', b"\xef\xbb\xbf{}", '{}'.encode("utf-16")):
            with self.subTest(data=data):
                self.assertRejected(data)

    def test_rejects_malformed_and_trailing_data(self):
        for data in (b"", b"{", b"{} {}", b"{'a':1}", b"[1,]", b"01"):
            with self.subTest(data=data):
                self.assertRejected(data)

    def test_rejects_deep_nesting_and_huge_integers(self):
        self.assertRejected(b"[" * 100000 + b"]" * 100000)
        self.assertRejected(b"1" * 5000)
        self.assertRejected(b"9007199254740993")  # not exactly representable
        self.assertRejected(b"1" + b"0" * 309)  # overflows double

    def test_large_exact_integers_decode_as_doubles(self):
        value = decode_strict(b"100000000000000000000")
        self.assertIs(type(value), float)
        self.assertEqual(canonical_bytes(value), b"100000000000000000000")
        self.assertIs(type(decode_strict(b"9007199254740992")), int)

    def test_rejects_non_bytes_input(self):
        for data in (None, 1, ["{}"]):
            with self.subTest(data=data):
                self.assertRejected(data)

    def test_error_never_echoes_input(self):
        with self.assertRaises(SyncError) as caught:
            decode_strict(b'{"secret":"sk-live-SENTINEL","secret":1}')
        self.assertNotIn("SENTINEL", str(caught.exception))
        self.assertNotIn("SENTINEL", json.dumps(caught.exception.to_wire()))


class SharedVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(VECTORS_PATH.read_text(encoding="utf-8"))

    def test_fixture_schema_is_exact(self):
        self.assertEqual(set(self.document), {"vectors"})
        names = set()
        for vector in self.document["vectors"]:
            self.assertEqual(set(vector), {"name", "input", "canonical"})
            self.assertIsInstance(vector["name"], str)
            self.assertIsInstance(vector["canonical"], str)
            self.assertNotIn(vector["name"], names)
            names.add(vector["name"])
        self.assertGreaterEqual(len(names), 20)

    def test_vectors_match_exact_canonical_strings(self):
        for vector in self.document["vectors"]:
            with self.subTest(name=vector["name"]):
                self.assertEqual(canonical_bytes(vector["input"]), vector["canonical"].encode("utf-8"))

    def test_canonical_outputs_are_fixed_points(self):
        for vector in self.document["vectors"]:
            with self.subTest(name=vector["name"]):
                encoded = vector["canonical"].encode("utf-8")
                self.assertEqual(canonical_bytes(decode_strict(encoded)), encoded)

    def test_fixture_covers_required_categories(self):
        names = {vector["name"] for vector in self.document["vectors"]}
        for prefix in ("keys.", "numbers.", "strings.", "nested.", "record.upload.transcript",
                       "record.upload.providerMetadata", "record.upload.usage",
                       "record.upload.activity", "record.upload.tombstone", "record.replay."):
            with self.subTest(prefix=prefix):
                self.assertTrue(any(name.startswith(prefix) for name in names))


if __name__ == "__main__":
    unittest.main()
