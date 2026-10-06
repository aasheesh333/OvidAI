# Firebase App Check + social/phone auth gates — 2026-10-06

**Scope:** Verify the app-side App Check token provider is wired to the Ovid
Cloud mint path, verify the social+phone-only auth config, and record the exact
**external console/operator gates** that block production activation. The gates
are blockers, not code. No production code was changed by this audit.

**Repository:** `OvidAI` (default branch `main`).
**Evidence:** `test/firebase_appcheck_wiring_test.dart` (new, 6 tests) plus the
existing focused suites named in §5.

---

## 1. App-side App Check wiring (verified)

The mint path sends `X-Firebase-AppCheck` on every authenticated cloud request:

| Step | Location | Behavior |
|---|---|---|
| Token provider seam | `lib/core/ovid_cloud_service.dart:320-321` | `appCheckTokenProvider` (test seam, `@visibleForTesting`) |
| Production provider | `lib/core/ovid_cloud_service.dart:239-242` | `CloudAppCheck(initializeFirebase: () => FirebaseService.I.initialize(), activatedByFirebase: () => FirebaseService.I.accountService.enabled)` |
| Token resolution | `lib/core/ovid_cloud_service.dart:244-264` | override wins; else `CloudAppCheck.getToken()`; empty/blank throws `CloudUsageException` |
| Header attach | `lib/core/ovid_cloud_service.dart:266-280` | `X-Firebase-AppCheck` added to `/mint`, `/usage`, `/upgrade`, image headers |
| SDK activation/token | `lib/core/cloud_app_check.dart:15-40` | waits for Firebase boot; self-activates `AndroidProvider.playIntegrity` unless Firebase already owns activation; rejects empty SDK token |
| Firebase-owned activation | `lib/core/firebase_service.dart:163-167` | activates Play Integrity only when `accountService.enabled` |
| Account-service attestation | `lib/core/firebase_service.dart:78-82` | `appCheck: () => FirebaseAppCheck.instance.getToken()` |

**Wiring result:** the production default provider is `CloudAppCheck`. Because
the account feature is off by default (`OVID_ACCOUNT_ENABLED` unset →
`accountService.enabled == false`), `CloudAppCheck` boots Firebase and
self-activates Play Integrity before returning the token. When the account
feature is enabled, `FirebaseService` owns activation and `CloudAppCheck` reuses
it (no double activation). The SDK-free tests that only inject
`idTokenOverrideForTest` keep sending **no** App Check header, preserving the
existing test contract.

## 2. Social + phone-only auth config (verified)

`AuthProviders` (`lib/core/auth_providers.dart:14-44`):

- Default build (`OVID_AUTH_SOCIAL_PROVIDERS` empty, `OVID_AUTH_GOOGLE=true`,
  `OVID_AUTH_PHONE=true`) exposes exactly **`google.com` + `phone`**.
- Social providers are opt-in via the `OVID_AUTH_SOCIAL_PROVIDERS` allowlist
  (`github.com`, `apple.com`, `microsoft.com`, `facebook.com`, `twitter.com`,
  `yahoo.com`).
- Unknown IDs — including `password` — are **always excluded**; `password` is
  not a configurable social provider.
- Phone OTP failures map to the expected guidance, including
  `quota-exceeded` → "SMS quota is currently exhausted" and
  `app-not-authorized` / `invalid-app-credential` / `missing-client-identifier`
  / `captcha-check-failed` → App verification failure
  (`lib/core/auth_providers.dart:119-127`).

## 3. Gateway config note: `APPCHECK_ENABLED=false`

The image-serving mount is gated by the **external mint module's**
`APPCHECK_ENABLED` attribute:

- `server/images/runtime.py:35-40` — `active = getattr(mint, 'APPCHECK_ENABLED', False) is True and ...`; when inactive, image routes mount with `auth=lambda headers: None` and no admission bridge.
- `server/images/verifier.py:45-48` — `if mint.APPCHECK_ENABLED and not appcheck: raise ImageError(401, ...)`; then `mint.verify_app_check(appcheck)`.
- `server/account/adapters.py:11-21` — `FirebaseAdmin` refuses to construct without an App Check app-ID allowlist (`ACCOUNT_FIREBASE_APP_IDS`).

So the repository's image/account routes stay private/unavailable until the
**external** mint module sets `APPCHECK_ENABLED=true` and supplies the app-ID
allowlist. This is a server-operator gate, not an app-code change.

## 4. External console/operator gates (blockers — NOT code)

All of the following require the Firebase Console, Google Play, the VPS mint
module, or release-signing credentials. None can be satisfied by editing this
repository. Evidence must be produced by the release owner before these close.

### G1 — Enable App Check (Firebase Console)
- Register the Android app and select the **Play Integrity** provider for App Check.
- Record the Firebase **app ID** for the server allowlist (`ACCOUNT_FIREBASE_APP_IDS`).
- Blocked by: no App Check registration/attestation evidence for the signed build.

### G2 — Provider configuration (Firebase Console)
- Google: already enabled; still needs real debug/release sign-in, link and reauth journeys.
- Phone: enabled/saved; still needs real-device OTP journeys.
- Social allowlist: any non-Google social provider must be explicitly enabled **and** supplied via `OVID_AUTH_SOCIAL_PROVIDERS`.
- Email/password is still enabled in the console pending legacy-account linking migration; it must be retired only after same-UID migration is verified. The app config already excludes `password`.
- Android signing fingerprints and OAuth redirect/platform credentials are required.

### G3 — SMS quota (Firebase Console / billing)
- Console shows **10 SMS/day** with an add-billing option; **no billing change was made**.
- Applicable regions, abuse controls and quota/billing decisions remain open.
- Real-device OTP auto/manual, resend, expiry and rate-limit journeys are unverified.

### G4 — Play Integrity + release signing
- Play Integrity App Check must be registered for the **signed** Android build; the server must know the allowed app ID.
- `ANDROID_SIGNING_CERT_SHA256` is absent at repository scope (see `2026-10-06-production-signing-runbook.md` §2, §6).
- Production also fails the API 36 gate while `targetSdk = 28`; production still fails until the targetSdk/packaged-code work lands.

### G5 — Server authority + deployment
- The external mint module must set `APPCHECK_ENABLED=true` and provide the shared text/image admission bridge; without it image routes stay inactive.
- `ACCOUNT_FIREBASE_APP_IDS` and Firebase Admin ADC must be supplied; the account service stays disabled until then.
- Account activation additionally requires Postgres/schema, cleanup manifest and LiteLLM integration (`server/account/README.md:180-206`).

## 5. Test evidence

New focused test — `test/firebase_appcheck_wiring_test.dart` (6 tests):

1. mint sends the app-side App Check provider token;
2. a blank provider token blocks the mint before transport;
3. an explicit provider wins over the legacy id-token-only seam;
4. the legacy id-token-only seam still sends no App Check header;
5. production `CloudAppCheck` follows the Firebase account-ownership flag and self-activates Play Integrity when the account feature is off;
6. auth config is social+phone only and `password` can never be enabled.

Pre-existing related coverage (not duplicated): `test/cloud_app_check_test.dart`
(SDK activation, reuse, empty-token rejection), `test/usage_reactivity_test.dart`
("attestation reaches all authenticated cloud endpoints", "missing App Check
fails clearly before mint transport"), `test/auth_build_config_test.dart`
(picker shows Google + Phone, no social/password).

## 6. Verification commands (2026-10-06)

```
/root/flutter/bin/flutter test test/firebase_appcheck_wiring_test.dart
  → 00:00 +6: All tests passed!

/root/flutter/bin/flutter analyze test/firebase_appcheck_wiring_test.dart
  → No issues found! (ran in 4.4s)
```

## 7. What this audit does NOT claim

- No real Firebase project, Play Integrity attestation, SMS delivery or console
  change was performed.
- No production/server deployment was made; `APPCHECK_ENABLED` remains the
  external mint module's default (`False`).
- The app-side wiring and auth config are verified in code and tests only; the
  gates in §4 remain open until the release owner produces external evidence.
