"""Provider endpoint validation/canonicalization tests (stdlib unittest only)."""

import unittest

from server.sync.endpoints import DEFAULT_POLICY, EndpointPolicy, validate_endpoint
from server.sync.errors import SyncError

HTTP_POLICY = EndpointPolicy(allowed_schemes=frozenset({"https", "http"}))


def ok(value, provider_id="openai", **kwargs):
    return validate_endpoint(value, provider_id, **kwargs)


class AcceptedEndpointTests(unittest.TestCase):
    def test_canonical_forms(self):
        cases = {
            "https://api.openai.com/v1": "https://api.openai.com/v1",
            "HTTPS://API.Example.COM:443/v1/": "https://api.example.com/v1/",
            "https://api.example.com": "https://api.example.com/",
            "https://api.example.com:8443/v1": "https://api.example.com:8443/v1",
            "https://api.example.com:00443/v1": "https://api.example.com/v1",
            "https://example.com/a/./b/../c": "https://example.com/a/c",
            "https://example.com/../../x": "https://example.com/x",
            "https://example.com/%7euser/%2f%41": "https://example.com/~user/%2FA",
            "https://example.com/v1/models/gpt:generate": "https://example.com/v1/models/gpt:generate",
            "https://example.com/v1?api-version=2024-01-01": "https://example.com/v1?api-version=2024-01-01",
            "https://example.com/v1?b=2&a=1": "https://example.com/v1?b=2&a=1",
            "https://example.com/v1?": "https://example.com/v1",
            "https://example.com/v1?&&a=%7e&": "https://example.com/v1?a=~",
            "https://127.0.0.1/v1": "https://127.0.0.1/v1",
            "https://[2001:DB8::1]:443/": "https://[2001:db8::1]/",
            "https://xn--bcher-kva.example/": "https://xn--bcher-kva.example/",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(ok(value), expected)

    def test_canonicalization_is_idempotent(self):
        for value in ("HTTPS://API.Example.COM:443/a/./b/../%7e?x=%2f", "https://[2001:DB8::1]/"):
            with self.subTest(value=value):
                once = ok(value)
                self.assertEqual(ok(once), once)

    def test_max_length_inclusive(self):
        prefix = "https://a.example/"
        value = prefix + "a" * (2048 - len(prefix))
        self.assertEqual(ok(value), value)
        with self.assertRaises(SyncError):
            ok(value + "a")

    def test_non_https_requires_explicit_policy(self):
        with self.assertRaises(SyncError):
            ok("http://localhost:11434/v1")
        self.assertEqual(ok("http://LOCALHOST:11434/v1", policy=HTTP_POLICY), "http://localhost:11434/v1")
        self.assertEqual(ok("http://example.com:80/", policy=HTTP_POLICY), "http://example.com/")

    def test_provider_policy_lookup(self):
        policies = {"azure": EndpointPolicy(non_secret_query_keys=frozenset({"deployment-key"}))}
        url = "https://x.example/v1?deployment-key=eastus"
        self.assertEqual(validate_endpoint(url, "azure", policies=policies), url)
        with self.assertRaises(SyncError):
            validate_endpoint(url, "openai", policies=policies)

    def test_default_policy_is_https_only(self):
        self.assertEqual(DEFAULT_POLICY.allowed_schemes, frozenset({"https"}))


class RejectedEndpointTests(unittest.TestCase):
    def assertRejected(self, value, provider_id="openai", **kwargs):
        with self.assertRaises(SyncError) as caught:
            validate_endpoint(value, provider_id, **kwargs)
        self.assertEqual(caught.exception.code, "endpoint_rejected")
        self.assertEqual(caught.exception.to_wire()["message"], SyncError("endpoint_rejected").message)
        return caught.exception

    def test_non_string_and_empty(self):
        for value in (None, 1, b"https://example.com/", ["https://example.com/"], ""):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_userinfo(self):
        for value in (
            "https://user:pass@api.example.com/",
            "https://user@api.example.com/",
            "https://:@api.example.com/",
            "https://api.example.com@evil.example/",
            "https://sk-123%40api.example.com/",
        ):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_fragment(self):
        for value in ("https://api.example.com/#x", "https://api.example.com/#", "https://a.example/v1?q=1#key=s"):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_control_whitespace_and_non_ascii(self):
        for char in ("\n", "\r", "\t", "\x00", "\x1b", "\x7f", " ", "\x85", "\u200b", "\u3002", "\ufeff", "\ud800"):
            with self.subTest(char=ascii(char)):
                self.assertRejected("https://api.example.com/v1" + char)
                self.assertRejected("https://api.exa" + char + "mple.com/")

    def test_parser_confusion(self):
        for value in (
            "https://api.example.com\\@evil.example/",
            "https:\\\\evil.example/",
            "https:/evil.example/",
            "https:evil.example",
            "https://api.example.com/<script>",
            "https://api.example.com/\"x\"",
            "https://api.example.com/{a}",
        ):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_not_absolute(self):
        for value in ("/v1/chat", "api.example.com/v1", "//api.example.com/v1", "https://", "https:///v1"):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_schemes(self):
        for value in (
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/plain,hi",
            "ftp://example.com/",
            "ws://example.com/",
            "wss://example.com/",
            "http://example.com/",
            "gopher://example.com/",
        ):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_bad_hosts_and_ports(self):
        for value in (
            "https://-bad.example/",
            "https://bad-.example/",
            "https://exa_mple.com/",
            "https://%65xample.com/",
            "https://example..com/",
            "https://example.com./",
            "https://" + "a" * 64 + ".example/",
            "https://0x7f.0.0.1/",
            "https://127.1/",
            "https://2130706433/",
            "https://127.000.000.001/",
            "https://[::1/",
            "https://[zz::1]/",
            "https://[127.0.0.1]/",
            "https://example.com:0/",
            "https://example.com:65536/",
            "https://example.com:/",
            "https://example.com:12a/",
            "https://example.com:-1/",
        ):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_malformed_percent_encoding(self):
        for value in ("https://example.com/%zz", "https://example.com/%4", "https://example.com/v1?a=%"):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_credential_shaped_query_keys(self):
        keys = [
            "key", "KEY", "Key", "api_key", "api-key", "apikey", "ApiKey", "API_KEY", "api.key",
            "API%5FKEY", "%6Bey", "%256Bey", "%25256bey", "ap%69key", "api+key",
            "token", "access_token", "accessToken", "id_token", "refresh_token", "session_token",
            "secret", "client_secret", "password", "passwd", "pwd", "auth", "authorization", "oauth",
            "signature", "sig", "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token",
            "x-goog-api-key", "subscription-key", "Ocp-Apim-Subscription-Key", "private_key",
            "credential", "credentials", "bearer", "jwt",
        ]
        for key in keys:
            for query in (f"{key}=x", f"{key}=", key, f"a=1&{key}=x"):
                with self.subTest(query=query):
                    self.assertRejected("https://api.example.com/v1?" + query)

    def test_credential_shaped_matrix_params(self):
        self.assertRejected("https://api.example.com/v1;api_key=abc/chat")
        self.assertRejected("https://api.example.com/v1;token=abc")

    def test_layered_controls_and_credentials_are_rejected(self):
        for text in ("%00", "%0a", "%7F", "%FF", "%250a", "%25250a"):
            self.assertRejected("https://api.example.com/" + text)
            self.assertRejected("https://api.example.com/?q=" + text)
        for key in ("pass", "otp", "somepwd", "jwtvalue", "design"):
            self.assertRejected("https://api.example.com/?" + key + "=x")
        self.assertRejected("https://api.example.com/?code=x", provider_id="azure")
        self.assertRejected("https://api.example.com/v1%3Btoken%3Dx")

    def test_secret_shaped_values(self):
        for value in (
            "https://api.example.com/v1?q=sk-abcdefghijklmnopqrstuvwx",
            "https://api.example.com/v1/sk-proj-abcdefghijklmnopqrst/chat",
            "https://api.example.com/AKIAIOSFODNN7EXAMPLE/",
            "https://api.example.com/v1?x=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "https://api.example.com/v1?x=AIzaSyA-abcdefghijklmnopqrstuvwxyz012345",
            "https://api.example.com/v1?x=xoxb-1234567890-abcdefghij",
            "https://api.example.com/v1?x=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXZhbHVl",
            "https://api.example.com/v1?x=Bearer%20abcdef",
        ):
            with self.subTest(value=value):
                self.assertRejected(value)

    def test_explicit_policy_still_rejects_userinfo(self):
        self.assertRejected("http://user:pw@localhost/", policy=HTTP_POLICY)

    def test_error_never_echoes_input(self):
        error = self.assertRejected("https://user:SENTINEL-secret@api.example.com/")
        self.assertNotIn("SENTINEL", str(error))
        self.assertNotIn("SENTINEL", repr(error))
        self.assertNotIn("SENTINEL", repr(error.args))
        self.assertIsNone(error.__cause__)


if __name__ == "__main__":
    unittest.main()
