import { describe, expect, it, vi } from "vitest";
import { verifyInternalRequest } from "@ovid/shared";

import { mintCdnUrl, type CdnConfig } from "./cdn.js";
import {
  handleRequest,
  parseRange,
  type CdnCache,
  type CdnEnv,
  type CdnR2Bucket,
  type CdnR2Object,
} from "../../../deploy/cdn/worker.js";

const SECRET = "w12-worker-test-secret-at-least-32-bytes!!";
const NOW = 1_700_000_000;
const CONFIG: CdnConfig = { baseUrl: "https://cdn.ovidsi.test", secret: SECRET, ttlSeconds: 900 };
const ARTIFACT_KEY =
  "users/u1/artifacts/s1/0192c0de-0000-7000-8000-000000000001-aaaaaaaaaaaaaaaa-shot.png";
const UPLOAD_KEY = "users/u1/sessions/s1/uploads/a1";
const GRANT_ID = "grant-worker-1";
const VERSION_HASH = "a".repeat(64);
const GRANT_SECRET = "worker-grant-internal-secret-32-bytes!!";

interface StoredObject {
  bytes: Uint8Array;
  contentType?: string;
  etag?: string;
}

function streamOf(bytes: Uint8Array): ReadableStream<Uint8Array> {
  // Node's Uint8Array<ArrayBufferLike> is accepted by Response at runtime;
  // the DOM lib's BlobPart narrowing needs the cast.
  return new Response(bytes as unknown as BodyInit).body as ReadableStream<Uint8Array>;
}

class FakeBucket implements CdnR2Bucket {
  readonly objects = new Map<string, StoredObject>();
  gets = 0;
  heads = 0;

  seed(key: string, text: string, contentType = "text/plain", etag = "etag-1"): void {
    this.objects.set(key, {
      bytes: new TextEncoder().encode(text),
      contentType,
      etag,
    });
  }

  async get(
    key: string,
    options?: { range?: { offset: number; length: number } },
  ): Promise<CdnR2Object | null> {
    this.gets += 1;
    const stored = this.objects.get(key);
    if (stored === undefined) return null;
    const range = options?.range;
    const bytes =
      range === undefined
        ? stored.bytes
        : stored.bytes.slice(range.offset, range.offset + range.length);
    return {
      body: streamOf(bytes),
      size: stored.bytes.length,
      etag: stored.etag,
      httpEtag: `"${stored.etag}"`,
      httpMetadata: { contentType: stored.contentType },
      ...(range !== undefined ? { range } : {}),
    };
  }

  async head(key: string): Promise<CdnR2Object | null> {
    this.heads += 1;
    const stored = this.objects.get(key);
    if (stored === undefined) return null;
    return {
      body: streamOf(new Uint8Array()),
      size: stored.bytes.length,
      etag: stored.etag,
      httpEtag: `"${stored.etag}"`,
      httpMetadata: { contentType: stored.contentType },
    };
  }
}

class FakeCache implements CdnCache {
  readonly store = new Map<string, Response>();
  matches = 0;
  puts = 0;

  async match(request: Request): Promise<Response | undefined> {
    this.matches += 1;
    return this.store.get(request.url)?.clone();
  }

  async put(request: Request, response: Response): Promise<void> {
    this.puts += 1;
    this.store.set(request.url, response.clone());
  }
}

class ThrowingCache extends FakeCache {
  override async put(): Promise<void> {
    this.puts += 1;
    throw new Error("cache write failed");
  }
}

function mint(overrides: Partial<Parameters<typeof mintCdnUrl>[1]> = {}): string {
  return mintCdnUrl(CONFIG, {
    key: ARTIFACT_KEY,
    filename: "shot.png",
    contentType: "image/png",
    grantId: GRANT_ID,
    versionHash: VERSION_HASH,
    now: new Date(NOW * 1000),
    ...overrides,
  }).url;
}

function env(bucket: FakeBucket, extra: Partial<CdnEnv> = {}): CdnEnv {
  return {
    BUCKET: bucket,
    OVID_CDN_SIGNING_SECRET: SECRET,
    OVID_CDN_GRANT_CHECK_URL: "http://gateway.internal/internal/cdn-grants/assert-active",
    OVID_CDN_GRANT_INTERNAL_SECRET: GRANT_SECRET,
    ...extra,
  } as CdnEnv;
}

async function run(
  url: string,
  bucket: FakeBucket,
  opts: {
    method?: string;
    headers?: Record<string, string>;
    cache?: FakeCache;
    nowSeconds?: number;
    env?: Partial<CdnEnv>;
    grantActive?: boolean;
    fetchImpl?: typeof fetch;
  } = {},
): Promise<Response> {
  const fetchImpl = opts.fetchImpl ?? (async () => new Response(
    JSON.stringify({ active: opts.grantActive ?? true }),
    { status: 200, headers: { "content-type": "application/json" } },
  ));
  return handleRequest(
    new Request(url, { method: opts.method ?? "GET", headers: opts.headers }),
    env(bucket, opts.env),
    {
      nowSeconds: opts.nowSeconds ?? NOW,
      fetchImpl: fetchImpl as typeof fetch,
      ...(opts.cache !== undefined ? { cache: opts.cache } : {}),
    } as Parameters<typeof handleRequest>[2],
  );
}

describe("CDN Worker handler", () => {
  it("serves a valid token with immutable cache headers and signed content type", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "png-bytes", "image/png");
    const res = await run(mint(), bucket);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("png-bytes");
    expect(res.headers.get("content-type")).toBe("image/png");
    expect(res.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
    expect(res.headers.get("content-disposition")).toContain("inline");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("etag")).toBe('"etag-1"');
  });

  it("refuses mutable uploads instead of permitting a CDN cache-class upgrade", async () => {
    const bucket = new FakeBucket();
    bucket.seed(UPLOAD_KEY, "photo-bytes", "application/octet-stream");
    const cache = new FakeCache();
    const res = await run(
      mint({ key: UPLOAD_KEY, filename: "photo.png", contentType: "image/png" }),
      bucket,
      { cache },
    );
    expect(res.status).toBe(403);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(bucket.gets).toBe(0);
    expect(cache.matches).toBe(0);
  });

  it("sets Content-Disposition attachment with a sanitized filename", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const res = await run(mint({ disposition: "attachment", filename: "my shot.png" }), bucket);
    expect(res.headers.get("content-disposition")).toBe(
      `attachment; filename="my shot.png"; filename*=UTF-8''my%20shot.png`,
    );
  });

  it("rejects a tampered token, a tampered claim, and an expired token — never touching R2 or the cache", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const cache = new FakeCache();
    const good = mint();

    const tampered = good.replace(/t=[^&]+/, "t=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    expect((await run(tampered, bucket, { cache })).status).toBe(403);

    const url = new URL(good);
    url.searchParams.set("fn", "evil.html");
    expect((await run(url.toString(), bucket, { cache })).status).toBe(403);

    expect((await run(good, bucket, { cache, nowSeconds: NOW + 900 })).status).toBe(403);
    expect(bucket.gets).toBe(0);
    expect(cache.matches).toBe(0);
  });

  it("rejects a token whose lifetime exceeds the Worker's max TTL", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const res = await run(mint(), bucket, { env: { OVID_CDN_MAX_TTL_SECONDS: "60" } });
    expect(res.status).toBe(403);
  });

  it("returns 403 for an unsafe/traversal key and 404 for an unknown object", async () => {
    const bucket = new FakeBucket();
    const traversal = Buffer.from("../etc/passwd", "utf8").toString("base64url");
    expect(
      (
        await run(
          `https://cdn.ovidsi.test/o/${traversal}?t=x&e=${NOW + 900}&c=short`,
          bucket,
        )
      ).status,
    ).toBe(403);

    const missing = await run(mint({ key: ARTIFACT_KEY.replace("shot.png", "missing.png") }), bucket);
    expect(missing.status).toBe(404);
    expect(missing.headers.get("cache-control")).toBe("no-store");
  });

  it("returns 404/403/405 cleanly and never caches errors", async () => {
    const bucket = new FakeBucket();
    const cache = new FakeCache();
    expect((await run("https://cdn.ovidsi.test/nope", bucket, { cache })).status).toBe(404);
    expect(
      (await run("https://cdn.ovidsi.test/o/not-base64!?t=x&e=1", bucket, { cache })).status,
    ).toBe(403);
    expect((await run(mint(), bucket, { method: "POST", cache })).status).toBe(405);
    expect(cache.puts).toBe(0);
  });

  it("supports HEAD without a body and reports Content-Length", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "0123456789", "image/png");
    const res = await run(mint(), bucket, { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-length")).toBe("10");
    expect(await res.text()).toBe("");
    expect(bucket.gets).toBe(0);
    expect(bucket.heads).toBe(1);
  });

  it("supports a single byte range and rejects an unsatisfiable one", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "0123456789", "image/png");
    const res = await run(mint(), bucket, { headers: { range: "bytes=2-5" } });
    expect(res.status).toBe(206);
    expect(await res.text()).toBe("2345");
    expect(res.headers.get("content-range")).toBe("bytes 2-5/10");
    expect(res.headers.get("content-length")).toBe("4");

    const bad = await run(mint(), bucket, { headers: { range: "bytes=99-100" } });
    expect(bad.status).toBe(416);
    expect(bad.headers.get("content-range")).toBe("bytes */10");
  });

  it("answers 304 on If-None-Match and keeps the cache headers", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const res = await run(mint(), bucket, { headers: { "if-none-match": '"etag-1"' } });
    expect(res.status).toBe(304);
    expect(await res.text()).toBe("");
    expect(res.headers.get("etag")).toBe('"etag-1"');
    expect(res.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");

    const star = await run(mint(), bucket, { headers: { "if-none-match": "*" } });
    expect(star.status).toBe(304);
  });

  it("caches by object identity, not by the per-mint token, but validates the token first", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "cached-bytes", "image/png");
    const cache = new FakeCache();

    const first = await run(mint(), bucket, { cache });
    expect(first.status).toBe(200);
    expect(bucket.gets).toBe(1);
    expect(cache.puts).toBe(1);

    // A DIFFERENT (later) mint of the same object is a cache hit.
    const later = await run(mint({ now: new Date((NOW + 10) * 1000) }), bucket, { cache });
    expect(later.status).toBe(200);
    expect(await later.text()).toBe("cached-bytes");
    expect(bucket.gets).toBe(1);
    expect(cache.matches).toBeGreaterThanOrEqual(1);

    // An invalid token for the same path must NOT consult the cache.
    const before = cache.matches;
    const tampered = mint().replace(/t=[^&]+/, "t=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    expect((await run(tampered, bucket, { cache })).status).toBe(403);
    expect(cache.matches).toBe(before);
  });

  it("rechecks the grant before a warm cache hit, 304, HEAD and R2 after revocation", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "cached-secret", "image/png");
    const cache = new FakeCache();
    const url = mint();
    expect((await run(url, bucket, { cache })).status).toBe(200);
    expect((await run(url, bucket, { cache })).status).toBe(200);
    expect(bucket.gets).toBe(1);
    const matches = cache.matches;

    const deniedReads: Array<{
      cache: FakeCache;
      method?: string;
      headers?: Record<string, string>;
    }> = [
      { cache },
      { cache, headers: { "if-none-match": '"etag-1"' } },
      { cache, method: "HEAD" },
      { cache, headers: { range: "bytes=0-1" } },
    ];
    for (const options of deniedReads) {
      expect((await run(url, bucket, { ...options, grantActive: false })).status).toBe(403);
    }
    expect(cache.matches).toBe(matches);
    expect(bucket.gets).toBe(1);
    expect(bucket.heads).toBe(0);

    let active = false;
    expect((await run(url, bucket, { cache, grantActive: active })).status).toBe(403);
    active = true;
    expect((await run(url, bucket, { cache, grantActive: active })).status).toBe(200);
  });

  it("denies legacy grantless v1 URLs before any cache or storage access", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "legacy", "image/png");
    const cache = new FakeCache();
    const legacy = mintCdnUrl(CONFIG, {
      key: ARTIFACT_KEY,
      contentType: "image/png",
      now: new Date(NOW * 1000),
    }).url;
    expect((await run(legacy, bucket, { cache })).status).toBe(403);
    expect(cache.matches).toBe(0);
    expect(bucket.gets).toBe(0);
  });

  it("fails closed when the grant service is absent or unavailable", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "private", "image/png");
    const cache = new FakeCache();
    expect((await run(mint(), bucket, {
      cache,
      env: { OVID_CDN_GRANT_CHECK_URL: "" } as Partial<CdnEnv>,
    })).status).toBe(503);
    expect((await run(mint(), bucket, {
      cache,
      fetchImpl: async () => { throw new Error("grant service down"); },
    })).status).toBe(503);
    expect(cache.matches).toBe(0);
    expect(bucket.gets).toBe(0);
  });

  // UNEXECUTED under the 2026-10-25 heavy-verification pause.
  it("signs the internal check with both grant and frozen version", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "signed-grant", "image/png");
    const fetchImpl = vi.fn(async () => new Response(JSON.stringify({ active: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    }));
    const res = await run(mint(), bucket, { fetchImpl: fetchImpl as unknown as typeof fetch });
    expect(res.status).toBe(200);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://gateway.internal/internal/cdn-grants/assert-active");
    expect(JSON.parse(String(init.body))).toEqual({ grantId: GRANT_ID, versionHash: VERSION_HASH });
    const headers = init.headers as Record<string, string>;
    expect(verifyInternalRequest(
      GRANT_SECRET,
      "POST",
      "/internal/cdn-grants/assert-active",
      `${GRANT_ID}:${VERSION_HASH}`,
      headers["X-Ovid-Timestamp"]!,
      headers["X-Ovid-Signature"]!,
      NOW,
    )).toBe(true);
    expect(verifyInternalRequest(
      GRANT_SECRET,
      "POST",
      "/internal/cdn-grants/assert-active",
      GRANT_ID,
      headers["X-Ovid-Timestamp"]!,
      headers["X-Ovid-Signature"]!,
      NOW,
    )).toBe(false);
  });

  it("still serves the object when the cache write fails", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "survives-cache-failure", "image/png");
    const cache = new ThrowingCache();
    const res = await run(mint(), bucket, { cache });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("survives-cache-failure");
    expect(cache.puts).toBe(1);
  });

  it("echoes an allowed Origin and sets Vary; ignores a foreign Origin", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const res = await run(mint(), bucket, {
      headers: { origin: "https://app.ovidsi.com" },
      env: { OVID_CDN_ALLOWED_ORIGINS: "https://app.ovidsi.com,https://ovidsi.com" },
    });
    expect(res.headers.get("access-control-allow-origin")).toBe("https://app.ovidsi.com");
    expect(res.headers.get("vary")).toContain("Origin");

    const foreign = await run(mint(), bucket, {
      headers: { origin: "https://evil.test" },
      env: { OVID_CDN_ALLOWED_ORIGINS: "https://app.ovidsi.com" },
    });
    expect(foreign.headers.get("access-control-allow-origin")).toBeNull();
  });

  it("sandboxes active content (HTML/SVG)", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "<h1>x</h1>", "text/html");
    const res = await run(mint({ contentType: "text/html" }), bucket);
    expect(res.headers.get("content-security-policy")).toContain("sandbox");
    expect(res.headers.get("content-disposition")).toContain("attachment");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("returns 503 when the Worker has no secret or binding", async () => {
    const bucket = new FakeBucket();
    bucket.seed(ARTIFACT_KEY, "x", "image/png");
    const noSecret = await handleRequest(
      new Request(mint()),
      {
        BUCKET: bucket,
        OVID_CDN_SIGNING_SECRET: "",
      },
      { nowSeconds: NOW },
    );
    expect(noSecret.status).toBe(503);
    const noBucket = await handleRequest(
      new Request(mint()),
      {
        BUCKET: undefined as unknown as FakeBucket,
        OVID_CDN_SIGNING_SECRET: SECRET,
      },
      { nowSeconds: NOW },
    );
    expect(noBucket.status).toBe(503);
  });
});

describe("parseRange", () => {
  it("parses closed, open-ended and suffix ranges", () => {
    expect(parseRange("bytes=0-9", 100)).toEqual({ offset: 0, length: 10 });
    expect(parseRange("bytes=90-", 100)).toEqual({ offset: 90, length: 10 });
    expect(parseRange("bytes=-10", 100)).toEqual({ offset: 90, length: 10 });
    expect(parseRange("bytes=0-999", 100)).toEqual({ offset: 0, length: 100 });
  });

  it("rejects malformed, multi-range and unsatisfiable ranges", () => {
    for (const bad of ["", "items=0-1", "bytes=0-1,3-4", "bytes=5-1", "bytes=100-", "bytes=-0"]) {
      expect(parseRange(bad, 100)).toBeNull();
    }
    expect(parseRange(null, 100)).toBeNull();
  });
});
