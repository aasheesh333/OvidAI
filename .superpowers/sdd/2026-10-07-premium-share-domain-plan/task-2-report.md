# Task 2 report: app/web deep-link resolver

## Status

Implemented the focused app/web share continuation flow.

### Changes

- Added strict `https://ovidsi.com/s/<43-character-token>` parsing in
  `lib/core/share_link_resolver.dart`.
- Added redacted route representation and one-shot deferred-token storage.
- Added Play Store install-referrer URL generation for the web fallback.
- Added Flutter startup handling for initial and subsequent Android App Links.
- Added `SharedConversationScreen`, which loads the public immutable snapshot
  and exposes `Continue in Ovid Si` only after authentication; continuation
  calls the existing authenticated/idempotent fork API from Task 1.
- Added an Android verified App Link intent filter for `/s/`.
- Added a no-store-compatible JSON snapshot endpoint at `/s/<token>.json` and
  retained the existing HTML viewer, expiry, revocation, escaping, and no-index
  behavior. The HTML fallback includes a Play Store link carrying the validated
  token as an install referrer.
- Added focused tests for valid parsing, malformed URL rejection, installed
  routing, deferred restoration, and Play Store referrer construction.

## Verification

- `flutter test test/share_link_resolver_test.dart` — blocked: Flutter is not
  installed in the environment (`flutter: command not found`).
- `python3 -m unittest server.shares.tests.test_shares` — blocked during import:
  Python environment does not have `fastapi` installed.
- `dart --version` — blocked: Dart is not installed.
- `git diff --check` — passed.

## Concerns / follow-up

- Android Digital Asset Links hosting requires the release package fingerprint
  and deployment ownership; no `assetlinks.json` was added without those
  production values.
- Play Store deferred install restoration depends on the Play install-referrer
  being delivered by the installed-app environment. The validated token is
  preserved in the referrer URL and the resolver provides one-shot storage for
  the platform callback when available.
- The requested DNS changes and broad UI work were intentionally left outside
  this task.
