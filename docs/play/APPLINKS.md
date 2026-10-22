# App Links: `/.well-known/assetlinks.json`

Android verifies the `autoVerify` intent filters in
`android/app/src/main/AndroidManifest.xml` against
`https://ovidsi.com/.well-known/assetlinks.json` at install time. If that
document is missing, returns 503, or does not list the certificate that
**signed the installed APK**, every `https://ovidsi.com/s/…`, `/c/…` and
`/schedule/…` link opens in the browser (or the disambiguation chooser)
instead of the app.

Package name: `com.dhanuk.ovidai` (`applicationId`, `android/app/build.gradle.kts`).
Host: `ovidsi.com` (`ovidShareHost` Gradle property, default `ovidsi.com`).

## Current state (checked 2026-10-22)

- The endpoint is **live**: `GET https://ovidsi.com/.well-known/assetlinks.json`
  → `200 application/json`.
- It lists **exactly one** fingerprint,
  `96:D7:6A:02:DC:7D:A1:79:07:06:BD:32:48:68:27:38:63:C8:BF:01:D3:D3:FB:F7:20:48:48:3C:13:3F:77:55`,
  which is the **upload / sideload key**, not the Play App Signing key.
- Consequence: a Play-installed build is re-signed by Play, its signer is not in
  the list, and App Links stay **unverified** for that build. Sharing works, but
  the link opens the web page instead of the app.

There is **no static `assetlinks.json` in this repo** (`web/`, `docs/` and any
`.well-known/` directory contain none). The file is generated at request time by
the account/share service:

- `server/shares/api.py` → `GET /.well-known/assetlinks.json`
- `cloud/apps/gateway/src/shares/routes.ts` → same route (current owner)

Both read `OVID_ANDROID_RELEASE_CERT_SHA256` (comma-separated, upper-cased) and
return `503 android_release_fingerprint_not_configured` when it is unset or
malformed. So the fix is configuration, not a new file — but the exact content
that must be served is below.

## Exact content that must be served

`https://ovidsi.com/.well-known/assetlinks.json`, `200`, `Content-Type: application/json`:

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.dhanuk.ovidai",
      "sha256_cert_fingerprints": [
        "REPLACE_WITH_PLAY_APP_SIGNING_SHA256"
      ]
    }
  }
]
```

`REPLACE_WITH_PLAY_APP_SIGNING_SHA256` must be replaced by the **Play App
Signing** certificate SHA-256: Play Console → *Test and release* → *App
integrity* → *App signing key certificate* → *SHA-256 certificate fingerprint*.
It is 32 colon-separated uppercase hex pairs, e.g.
`AB:CD:EF:01:…:9F` (32 pairs, 95 characters). The upload key may be added as a
second array entry so sideloaded release builds verify too:

```json
"sha256_cert_fingerprints": [
  "REPLACE_WITH_PLAY_APP_SIGNING_SHA256",
  "96:D7:6A:02:DC:7D:A1:79:07:06:BD:32:48:68:27:38:63:C8:BF:01:D3:D3:FB:F7:20:48:48:3C:13:3F:77:55"
]
```

Rules the verifier enforces (getting any of these wrong silently disables App
Links):

- The document is served from the **exact host** in the manifest, over valid
  TLS, with **no redirect** and **no Cloudflare challenge**.
- `package_name` matches `applicationId` exactly.
- Every fingerprint is 32 colon-separated hex pairs; uppercase is what both
  implementations emit.
- It must stay reachable at all times. Google re-checks periodically; a 503
  after install can drop verification.

## How to publish it

1. Get the Play App Signing SHA-256 (above).
2. Set the fingerprint on the service that owns the route, in the production
   env file:
   ```sh
   # /opt/ovid-cloud/.env  (or /etc/ovid-account/api.env for the Python owner)
   OVID_ANDROID_RELEASE_CERT_SHA256=AA:BB:…:FF
   OVID_ANDROID_PACKAGE_NAME=com.dhanuk.ovidai
   ```
   Comma-separate to list both the Play key and the upload key.
3. Make sure the **`ovidsi.com`** Caddy site block proxies the route (the
   `api.ovidsi.com` block alone is not enough — the manifest host is
   `ovidsi.com`):
   ```
   handle /.well-known/assetlinks.json {
       reverse_proxy 127.0.0.1:8082
   }
   ```
   `handle /s/*` must be present on the same site block for the fallback pages.
4. Restart the service, reload Caddy, then verify:
   ```sh
   curl -sS https://ovidsi.com/.well-known/assetlinks.json | jq .
   # → 200, package_name com.dhanuk.ovidai, fingerprints include the Play key
   adb shell pm get-app-links com.dhanuk.ovidai
   # → ovidsi.com: verified
   adb shell pm verify-app-links --re-verify com.dhanuk.ovidai   # force a re-check
   ```
   Test on a **Play-installed** build, not a local release build: the local one
   is signed with the upload key and will verify even when the Play build does
   not.

## Related gap: `/c/` has no web fallback

`https://ovidsi.com/s/<token>` serves a real page when the app is not installed
(read-only transcript, `intent://` launch, Play button; unknown/revoked tokens
get a "Link unavailable" page — not a bare 404).

`https://ovidsi.com/c/<id>` has **no route**: it currently returns the generic
site 404. Chat links are account-scoped, so a public page cannot show the chat,
but the URL should still land somewhere useful (an "open in the app / get the
app" page, or sign-in) rather than a 404. Add a `/c/*` handler that serves the
same landing-page shell without content, or stop emitting `/c/` links.
