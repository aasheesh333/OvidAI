# Task 2 report: app/web deep-link resolver

## Status

Implemented and corrected the focused app/web share continuation flow after
reviewer reproduction, including startup race/error handling and repeat
continuation behavior.

### Changes

- Added strict `https://ovidsi.com/s/<43-character-token>` parsing in
  `lib/core/share_link_resolver.dart`.
- Added redacted route representation and one-shot deferred-token storage.
- Added Play Store install-referrer URL generation for the web fallback.
- Added Flutter startup handling for initial and subsequent Android App Links.
- Routed share navigation through the `MaterialApp` navigator key rather than
  the `OvidApp` state context, which is above `MaterialApp`.
- Subscribed to the link stream before startup lookups, isolated unsupported
  platform/referrer failures, and deduplicated initial, stream, and deferred
  deliveries by validated token.
- Added `SharedConversationScreen`, which loads the public immutable snapshot
  and exposes `Continue in Ovid Si` only after authentication; continuation
  calls the existing authenticated/idempotent fork API from Task 1.
- Added an Android verified App Link intent filter for `/s/`.
- Added a no-store-compatible JSON snapshot endpoint at `/s/<token>.json` and
  retained the existing HTML viewer, expiry, revocation, escaping, and no-index
  behavior. The HTML fallback includes a Play Store link carrying the validated
  token as an install referrer.
- The JSON contract now includes `session_id`; imported forks persist a new
  local `ChatSession`, select it, and contain only validated user/assistant
  text. Existing matching local sessions are preserved and repeated imports
  do not duplicate messages. The flow fences both the Firebase UID and the
  AppState account epoch before and after asynchronous continuation work.
- Continuation retries from one viewer keep the same fork request ID, allowing
  the server's idempotency key to resolve uncertain retries safely.
- Added actual Android Play Install Referrer retrieval through the existing
  `ovid/native` channel; malformed referrers are ignored and consumption is
  one-shot.
- Public share origin is separately configurable from the authenticated API
  base using `OVID_PUBLIC_SHARE_ORIGIN`.
- Added `/.well-known/assetlinks.json`, generated only from the configured real
  `OVID_ANDROID_RELEASE_CERT_SHA256` value; it returns 503 when deployment has
  not supplied the production certificate.
- Added focused tests for valid parsing, malformed URL rejection, installed
  routing, deferred restoration, Install Referrer extraction, JSON contract,
  safe imports, HTML fallback, and asset-links configuration.

## Verification

- `/root/flutter/bin/flutter analyze` — passed with no issues.
- `/root/flutter/bin/flutter test test/share_link_resolver_test.dart test/shared_snapshot_contract_test.dart` — 10 tests passed.
- `/tmp/opencode/images-venv/bin/python -m unittest server.shares.tests.test_shares` — 16 tests passed.
- `python3 -m py_compile server/shares/api.py` — passed.
- `git diff --check` — passed.

## Concerns / follow-up

- Android Digital Asset Links still requires deployment to set the real release
  certificate fingerprint. The endpoint intentionally remains 503 until that
  deployment value exists; no fingerprint was invented.
- Play Store deferred restoration depends on Play providing the install
  referrer. The web fallback offers an explicit Open in Ovid Si/Install action
  and does not claim reliable automatic install detection.
- The requested DNS changes and broad UI work were intentionally left outside
  this task.

## Transport accounting review follow-up — 2026-10-08

- Queued `markTransmitted` and coalesced usage journal writes so outbound HTTP
  and SSE processing never await storage.
- Kept terminal reconciliation as the bounded post-transport barrier and passed
  the final provider usage snapshot into the terminal record.
- Started transport timing immediately before request body dispatch for both
  OpenAI-compatible and Anthropic transports; journal latency is excluded.
- Terminal capture failures remain redacted and surface through the existing
  generic usage-accounting diagnostic path without retaining raw errors.
- Added a regression covering non-blocking transmission marking and final usage
  retention in `test/agent_attempt_accounting_test.dart`.

### Verification

- `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/agent_attempt_accounting_test.dart` — 6 tests passed.
- `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/agent_attempt_accounting_test.dart test/agent_usage_attribution_test.dart` — 8 tests passed.
- `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter analyze lib/core/agent_service.dart lib/core/usage_attempt_recorder.dart test/agent_attempt_accounting_test.dart` — no issues.
- Source search found no awaited `markTransmitted` or `updateUsage` call in the stream/transport paths.
