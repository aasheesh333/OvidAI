import { describe, expect, it } from "vitest";
import {
  DEFAULT_ENDPOINT_POLICY,
  EndpointRejectedError,
  MAX_ENDPOINT_LENGTH,
  validateEndpoint,
  type EndpointPolicy,
} from "./endpoints.js";

// ---------------------------------------------------------------------------
// Provider endpoint validation/canonicalization — verbatim port of
// server/sync/tests/test_endpoints.py. The vectors ARE the wire contract:
// every case below must canonicalize or reject exactly as the Python service
// did (D3 parity), including the parser-confusion and layered-encoding cases.
// ---------------------------------------------------------------------------

const HTTP_POLICY: EndpointPolicy = {
  allowedSchemes: new Set<"https" | "http">(["https", "http"]),
  nonSecretQueryKeys: new Set<string>(),
};

function ok(value: unknown, providerId = "openai", opts?: Parameters<typeof validateEndpoint>[2]): string {
  return validateEndpoint(value, providerId, opts);
}

function rejected(
  value: unknown,
  providerId = "openai",
  opts?: Parameters<typeof validateEndpoint>[2],
): EndpointRejectedError {
  let caught: unknown;
  try {
    validateEndpoint(value, providerId, opts);
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(EndpointRejectedError);
  const error = caught as EndpointRejectedError;
  expect(error.code).toBe("endpoint_rejected");
  // Fixed non-sensitive message, identical to SyncError("endpoint_rejected").
  expect(error.message).toBe("The provider endpoint is not an allowed endpoint identity.");
  return error;
}

describe("validateEndpoint — accepted canonical forms", () => {
  it("canonicalizes every pinned vector", () => {
    const cases: Record<string, string> = {
      "https://api.openai.com/v1": "https://api.openai.com/v1",
      "HTTPS://API.Example.COM:443/v1/": "https://api.example.com/v1/",
      "https://api.example.com": "https://api.example.com/",
      "https://api.example.com:8443/v1": "https://api.example.com:8443/v1",
      "https://api.example.com:00443/v1": "https://api.example.com/v1",
      "https://example.com/a/./b/../c": "https://example.com/a/c",
      "https://example.com/../../x": "https://example.com/x",
      "https://example.com/%7euser/%2f%41": "https://example.com/~user/%2FA",
      "https://example.com/v1/models/gpt:generate": "https://example.com/v1/models/gpt:generate",
      "https://example.com/v1?api-version=2024-01-01":
        "https://example.com/v1?api-version=2024-01-01",
      "https://example.com/v1?b=2&a=1": "https://example.com/v1?b=2&a=1",
      "https://example.com/v1?": "https://example.com/v1",
      "https://example.com/v1?&&a=%7e&": "https://example.com/v1?a=~",
      "https://127.0.0.1/v1": "https://127.0.0.1/v1",
      "https://[2001:DB8::1]:443/": "https://[2001:db8::1]/",
      "https://xn--bcher-kva.example/": "https://xn--bcher-kva.example/",
    };
    for (const [value, expected] of Object.entries(cases)) {
      expect(ok(value), value).toBe(expected);
    }
  });

  it("is idempotent", () => {
    for (const value of [
      "HTTPS://API.Example.COM:443/a/./b/../%7e?x=%2f",
      "https://[2001:DB8::1]/",
    ]) {
      const once = ok(value);
      expect(ok(once), value).toBe(once);
    }
  });

  it("accepts the maximum length inclusively and rejects 2049", () => {
    const prefix = "https://a.example/";
    const value = prefix + "a".repeat(MAX_ENDPOINT_LENGTH - prefix.length);
    expect(value.length).toBe(MAX_ENDPOINT_LENGTH);
    expect(ok(value)).toBe(value);
    rejected(value + "a");
  });

  it("requires an explicit policy to widen https to http", () => {
    rejected("http://localhost:11434/v1");
    expect(ok("http://LOCALHOST:11434/v1", "openai", { policy: HTTP_POLICY })).toBe(
      "http://localhost:11434/v1",
    );
    expect(ok("http://example.com:80/", "openai", { policy: HTTP_POLICY })).toBe(
      "http://example.com/",
    );
  });

  it("looks policies up by provider, explicit policy winning", () => {
    const policies: Record<string, EndpointPolicy> = {
      azure: {
        allowedSchemes: new Set<"https" | "http">(["https"]),
        nonSecretQueryKeys: new Set(["deployment-key"]),
      },
    };
    const url = "https://x.example/v1?deployment-key=eastus";
    expect(validateEndpoint(url, "azure", { policies })).toBe(url);
    rejected(url, "openai", { policies });
  });

  it("default policy is https-only", () => {
    expect([...DEFAULT_ENDPOINT_POLICY.allowedSchemes]).toEqual(["https"]);
    expect([...DEFAULT_ENDPOINT_POLICY.nonSecretQueryKeys]).toEqual([]);
  });
});

describe("validateEndpoint — rejected inputs", () => {
  it("rejects non-strings and empty values", () => {
    for (const value of [null, 1, Buffer.from("https://example.com/"), ["https://example.com/"], ""]) {
      rejected(value);
    }
  });

  it("rejects userinfo", () => {
    for (const value of [
      "https://user:pass@api.example.com/",
      "https://user@api.example.com/",
      "https://:@api.example.com/",
      "https://api.example.com@evil.example/",
      "https://sk-123%40api.example.com/",
    ]) {
      rejected(value);
    }
  });

  it("rejects fragments", () => {
    for (const value of [
      "https://api.example.com/#x",
      "https://api.example.com/#",
      "https://a.example/v1?q=1#key=s",
    ]) {
      rejected(value);
    }
  });

  it("rejects control characters, whitespace and non-ASCII", () => {
    for (const char of [
      "\n",
      "\r",
      "\t",
      "\x00",
      "\x1b",
      "\x7f",
      " ",
      "\x85",
      "​",
      "。",
      "﻿",
      "\ud800",
    ]) {
      rejected("https://api.example.com/v1" + char);
      rejected("https://api.exa" + char + "mple.com/");
    }
  });

  it("rejects parser-confusion shapes", () => {
    for (const value of [
      "https://api.example.com\\@evil.example/",
      "https:\\\\evil.example/",
      "https:/evil.example/",
      "https:evil.example",
      "https://api.example.com/<script>",
      'https://api.example.com/"x"',
      "https://api.example.com/{a}",
    ]) {
      rejected(value);
    }
  });

  it("rejects non-absolute values", () => {
    for (const value of [
      "/v1/chat",
      "api.example.com/v1",
      "//api.example.com/v1",
      "https://",
      "https:///v1",
    ]) {
      rejected(value);
    }
  });

  it("rejects unsupported schemes", () => {
    for (const value of [
      "javascript:alert(1)",
      "file:///etc/passwd",
      "data:text/plain,hi",
      "ftp://example.com/",
      "ws://example.com/",
      "wss://example.com/",
      "http://example.com/",
      "gopher://example.com/",
    ]) {
      rejected(value);
    }
  });

  it("rejects bad hosts and ports (no octal/hex/short/int IPv4 forms)", () => {
    for (const value of [
      "https://-bad.example/",
      "https://bad-.example/",
      "https://exa_mple.com/",
      "https://%65xample.com/",
      "https://example..com/",
      "https://example.com./",
      "https://" + "a".repeat(64) + ".example/",
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
    ]) {
      rejected(value);
    }
  });

  it("rejects malformed percent-encoding", () => {
    for (const value of [
      "https://example.com/%zz",
      "https://example.com/%4",
      "https://example.com/v1?a=%",
    ]) {
      rejected(value);
    }
  });

  it("rejects credential-shaped query keys (including layered encodings)", () => {
    const keys = [
      "key", "KEY", "Key", "api_key", "api-key", "apikey", "ApiKey", "API_KEY", "api.key",
      "API%5FKEY", "%6Bey", "%256Bey", "%25256bey", "ap%69key", "api+key",
      "token", "access_token", "accessToken", "id_token", "refresh_token", "session_token",
      "secret", "client_secret", "password", "passwd", "pwd", "auth", "authorization", "oauth",
      "signature", "sig", "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token",
      "x-goog-api-key", "subscription-key", "Ocp-Apim-Subscription-Key", "private_key",
      "credential", "credentials", "bearer", "jwt",
    ];
    for (const key of keys) {
      for (const query of [`${key}=x`, `${key}=`, key, `a=1&${key}=x`]) {
        rejected("https://api.example.com/v1?" + query);
      }
    }
  });

  it("rejects credential-shaped matrix params", () => {
    rejected("https://api.example.com/v1;api_key=abc/chat");
    rejected("https://api.example.com/v1;token=abc");
  });

  it("rejects layered controls and credentials", () => {
    for (const text of ["%00", "%0a", "%7F", "%FF", "%250a", "%25250a"]) {
      rejected("https://api.example.com/" + text);
      rejected("https://api.example.com/?q=" + text);
    }
    for (const key of ["pass", "otp", "somepwd", "jwtvalue", "design"]) {
      rejected("https://api.example.com/?" + key + "=x");
    }
    rejected("https://api.example.com/?code=x", "azure");
    rejected("https://api.example.com/v1%3Btoken%3Dx");
  });

  it("rejects secret-shaped values", () => {
    for (const value of [
      "https://api.example.com/v1?q=sk-abcdefghijklmnopqrstuvwx",
      "https://api.example.com/v1/sk-proj-abcdefghijklmnopqrst/chat",
      "https://api.example.com/AKIAIOSFODNN7EXAMPLE/",
      "https://api.example.com/v1?x=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
      "https://api.example.com/v1?x=AIzaSyA-abcdefghijklmnopqrstuvwxyz012345",
      "https://api.example.com/v1?x=xoxb-1234567890-abcdefghij",
      "https://api.example.com/v1?x=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXZhbHVl",
      "https://api.example.com/v1?x=Bearer%20abcdef",
    ]) {
      rejected(value);
    }
  });

  it("explicit policy still rejects userinfo", () => {
    rejected("http://user:pw@localhost/", "openai", { policy: HTTP_POLICY });
  });

  it("error never echoes the input", () => {
    const error = rejected("https://user:SENTINEL-secret@api.example.com/");
    expect(String(error)).not.toContain("SENTINEL");
    expect(error.message).not.toContain("SENTINEL");
    expect(error.stack ?? "").not.toContain("SENTINEL");
    expect(error.cause).toBeUndefined();
  });
});
