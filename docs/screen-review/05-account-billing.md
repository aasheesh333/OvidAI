# 05 — Login, account, model providers, billing, usage

## Scope
`lib/ui/login_gate.dart`, `lib/ui/auth_methods.dart`, `lib/ui/auth_screen.dart`,
`lib/ui/account_deletion_panel.dart`, `lib/ui/billing_screen.dart`,
`lib/ui/usage_screen.dart`, `lib/ui/cloud_usage_status.dart`,
`lib/ui/image_receipt_panel.dart`, `lib/ui/providers_screen.dart`,
`lib/ui/profile_avatar.dart`; core follow-through into
`lib/core/ovid_cloud_service.dart`, `lib/core/account_service.dart`,
`lib/core/firebase_service.dart` (and `lib/core/state.dart` where the flow lands).
Reviewed at HEAD `2ac8936`, cross-checked against `fix/model-catalog-recovery` (`8921228`).

## Goal
Full read of every screen/sheet/dialog in the group; verify the
login → token mint → model catalog → model selection path end to end (P0
"Ovid Cloud Auto and manual models not loading"), and verify Google Play
in-app account deletion works in release builds.

## Status
complete

## Cross-cutting: release build flags (read first)
- **P0 · Play policy / broken flow · `lib/core/account_service.dart:58` + `.github/workflows/build.yml:221-222`** —
  `AccountService.enabled` is `bool.fromEnvironment('OVID_ACCOUNT_ENABLED')`, and neither release
  command (`flutter build apk --release …`, `flutter build appbundle --release …`) passes
  `--dart-define=OVID_ACCOUNT_ENABLED=true`. In the Play build every account call throws
  *"Account deletion is not yet activated on the server. No request has been submitted."*
  (`account_service.dart:96-100`), so **in-app account deletion cannot succeed in release** — a
  Google Play User Data policy violation (apps with account creation must offer in-app deletion).
  The same flag also skips the server login acknowledgement / deletion-state check
  (`firebase_service.dart:72-76,228`), so a release user whose deletion is pending on the server
  is admitted anyway (App Check is still activated lazily by `cloud_app_check.dart:17-21`).
  **Fix:** (1) finish `server/account/README.md` §8 activation on the VPS, (2) add
  `--dart-define=OVID_ACCOUNT_ENABLED=true` to both release lines, (3) add a CI guard step that
  fails the release job if the define is missing (e.g. `grep -q OVID_ACCOUNT_ENABLED=true` on the
  build command, or a `test/release_flags_test.dart` run with the same defines), (4) until the
  server is live, ship the Play-accepted fallback: a "Request deletion" web link
  (Play Console "Delete account URL") shown in the panel instead of a dead button.

## End-to-end: login → mint → catalog → model selection
Path traced: `LoginGate._onAuth` (`login_gate.dart:90-108`) → `OvidCloudService.ensureConnected`
(`ovid_cloud_service.dart:112-166`) → `_mint` → `_requestMint` (POST `/mint`, `:391-466`) →
`_bind` (`:468-517`, writes key via `AppState.updateProviderApiKey`) → `_refreshModels`
(`:521-612`, GET `{base}/models`) → `reconcileProviderModels` (`state.dart:6666`) → picker
(`chat_screen.dart:2404-2460, 2634-2690`). Branch `fix/model-catalog-recovery` (`8921228`) adds:
503 `catalog_unavailable` and 401/403 clear `_keyIdentity`; a Retry on a bound key that the catalog
rejects re-mints once in the same flight; mint `base_url` is normalized; server returns
401 `key_invalid` / 402 / 429 instead of a blanket 503. Remaining gaps:

- **P0 · broken flow · `ovid_cloud_service.dart:400-404` (fix branch unchanged)** — re-mint sends an
  empty POST to `/mint`; per the master plan, `/mint` returns the **same Redis-cached key**, so the
  client "re-mint" gets the dead key back and the user loops Retry → 503/401 → Retry forever until
  the VPS-side `/mint` validates the stored key (Phase 1B). The client gives the server no signal that
  the key was just rejected. **Fix:** after a catalog 401/`key_invalid`/`catalog_unavailable`, send
  `{"reason":"key_rejected","key_id":<last 8 chars or hash of rejected key>}` in the mint body and have
  `mint.py` rotate when the hash matches the cached key; client-side, if the freshly minted key equals
  `_boundKey` that was just rejected, publish a distinct failed state ("Ovid Cloud is being repaired —
  try again in a few minutes") instead of re-looping. Ship together with VPS fix 1B.
- **P0 · broken flow (cross-ref group 01) · `chat_screen.dart:2412-2414, 2455-2458, 2681`** — the picker
  hides every Ovid Cloud model **including the seeded `auto`** unless status is `ready`; recents for
  Ovid Cloud are also filtered out. Any catalog hiccup = "no models" even though `auto` is a
  server-side alias that works without the catalog. **Fix:** always render `auto` (and the
  last-good persisted `managed.models`) with a "Catalog may be out of date · Retry" subtitle when
  `status == failed`; only disable selection while `connecting`.
- **P2 · resilience · `ovid_cloud_service.dart:594-597`, `state.dart:268, 4113-4122`** — the last-good
  catalog *is* persisted (provider `models` round-trips through prefs), but with no `fetchedAt` and no
  owner/tier, so (a) the picker cannot say how stale it is and (b) after an account switch B briefly sees
  A's tier-specific model list. **Fix:** persist `ovidCloudCatalogFetchedAt` + owning uid next to the
  list; on uid change reset to `['auto']`; show "Updated <relative time>" in the card when not `ready`.
- **P1 · load / 10M DAU · `login_gate.dart:110-118` + fix branch `ovid_cloud_service.dart:146-148,581-586`** —
  every app resume calls `ensureConnected()`; when state is `failed` this does a full catalog GET and,
  on the fix branch, treats **any** 503 `catalog_unavailable` (which after the server fix means a real
  upstream outage) as a dead key → immediate re-mint → second catalog GET. During a LiteLLM outage every
  resume of every client = 1 mint + 2 catalog calls, with no backoff — a thundering herd on the
  recovering gateway. **Fix:** (a) exponential backoff with jitter on resume-triggered recovery
  (e.g. 30 s → 10 min cap, reset on success or explicit Retry), (b) once the server ships `key_invalid`,
  only treat 503 `catalog_unavailable` as a key failure when the response lacks a gateway-version header
  (add `X-Ovid-Gateway: 2` server-side).
- **P1 · security / billing · no clear of the managed key on sign-out — `firebase_service.dart:473-493`,
  `state.dart:2776-2840`, `agent_service.dart:12469-12472`** — `signOut()` / `transitionSessionAccount`
  never clear the `ovid-cloud` provider's API key. After user A signs out and user B signs in on the same
  device, the provider still holds **A's virtual key**; chat requests send `p.cleanApiKey` with no
  ownership check, so until B's mint succeeds — and indefinitely if B's mint fails (offline, App Check,
  **402 free limit reached**) — B's chats are billed to A's quota and a limit-reached user keeps chatting.
  **Fix:** in `OvidCloudService._authChanged` (uid changed) and in `FirebaseService.signOut/signOutLocal`,
  call `AppState.updateProviderApiKey(ovidCloud, '')`, clear `_boundKey/_keyIdentity`, and reset
  `ovidCloudTier`; in `agent_service` refuse to send to `ovid-cloud` unless
  `OvidCloudService.I._keyIdentity == accountIdentity` (expose a `keyOwnedByCurrentAccount` getter).
- **P1 · recovery · `ovid_cloud_service.dart:413-418, 263-266`** — mint 401/403 returns
  "Sign-in could not be verified (401)." and never retries with `getIdToken(forceRefresh: true)`;
  a revoked/clock-skewed ID token or a transient App Check 403 needs the user to sign out and back in.
  **Fix:** on 401 from `/mint`, retry once with a force-refreshed ID token (and a fresh App Check token);
  only then publish `rejected`. Split copy: 401 → "Your session expired. Sign in again" + Sign-out CTA;
  403 → "This device could not be verified (App Check). Update the app from Google Play."
- **P1 · model selection · `ovid_cloud_service.dart:509-516`, `state.dart:6666-6684`** — Auto is selected
  only when `lastSelectedModel` is empty. If the remembered Ovid Cloud model disappears from the catalog,
  `reconcileProviderModels` resets sessions to `'Select a provider'` but `lastSelectedModel` keeps the
  dead id, so every new chat starts on a removed model. **Fix:** in `reconcileProviderModels` for
  `ovid-cloud`, rewrite orphaned sessions and `lastSelectedModel` to `'auto'` (not
  `'Select a provider'`) and show a one-time snackbar "<model> is no longer available — switched to Auto".
- **P2 · copy · `ovid_cloud_service.dart:567-569, 420-423`** — status codes leak into user copy
  ("(503)", "(401)"). Keep codes in `Diag`, show plain language + Retry.
- **P2 · dead code · `state.dart:6622-6664`** — `refreshOvidCloudModels` has no ownership fence and no
  caller; delete it so nobody wires it back in.

**Tests to add:** (1) widget: picker shows `auto` + persisted models when
`setConnectionForTest(failed)`; (2) unit: sign-out then sign-in as B with `/mint` → 402 leaves the
`ovid-cloud` key empty; (3) unit: `/mint` 401 retries once with `forceRefresh`; (4) unit: resume during
catalog 503 storm makes ≤ 1 network call per backoff window; (5) unit: re-mint returning the same
rejected key publishes the "repairing" state, not `ready`.

## LoginGate (`login_gate.dart:28-150`)
**What it is / how reached:** root wrapper around the app; picks splash / unavailable /
account-not-ready / login / app (+ welcome overlay) from `FirebaseService` state, and starts the
Ovid Cloud bind on the first `accountReady` frame and on every resume.

**Findings**
- P1 · perf / startup · `login_gate.dart:65-81` → `firebase_service.dart:173` → `:206-213` →
  `state.dart:2884-2897` — the splash is held until `FirebaseService.initialize()` returns, which awaits
  `_onUser` → `AppState.transitionSessionAccount`, which hydrates the **entire session history from
  SharedPreferences** (`_hydrateDeferredSessions`) plus usage log and FTS account switch. Cold-start time
  therefore grows with chat history. · users with long histories stare at the splash for seconds.
  · **Fix:** have `initialize()` return once `Firebase.initializeApp` + the first `userChanges` event are
  known, and let `_AccountNotReadyScreen`/a skeleton cover hydration; long-term, the SQLite history move
  (master plan Phase 4.3).
- P1 · robustness · `login_gate.dart:110-118` — resume triggers `ensureConnected` with no throttle; see
  E2E section (backoff).
- P2 · perf · `login_gate.dart:90-108, 127-148` — `_onAuth` calls `setState` on every
  `FirebaseService` notification while the `AnimatedBuilder` already listens to the same notifier → two
  builds per auth event. · **Fix:** drop the `setState(() {})` at `:107` (keep the bind side-effect).
- P2 · test seam in prod · `login_gate.dart:41,122` — `static bool disabledForTest` is a mutable global in
  release code. · **Fix:** wrap in `assert(() { … }())` or inject via constructor only.

**Missing features:** no "Continue offline / use my own API key" path when Firebase is unavailable
(ChatGPT/Claude also require login, so acceptable); no deep-link return after sign-in.
**Test to add:** golden-path widget test that `LoginGate` leaves the splash before session hydration
completes (fake `transitionSessionAccount` that never resolves).

## Splash screen (`login_gate.dart:156-243`)
**What it is:** brand animation + spinner during Firebase init.
**Findings**
- P2 · a11y · `login_gate.dart:227-236` — spinner has no `semanticsLabel` (the comment says "semantic
  spinner" but none is set); TalkBack announces nothing. · **Fix:** `semanticsLabel: 'Starting Ovid'`.
- P2 · perf · `login_gate.dart:179` — `_anim.repeat()` runs even when `disableAnimations` is on.
  · **Fix:** skip `repeat()` when `MediaQuery.disableAnimationsOf` is true (start in `didChangeDependencies`).
- P2 · UX · no timeout: if init hangs (see P1 above) there is no "Still starting… / Retry" affordance
  after ~10 s. · **Fix:** after 10 s show a muted "Taking longer than usual" + Retry.
**Missing features:** none beyond the above. **Test:** semantics label present.

## Unavailable screen (`login_gate.dart:252-306`)
**What it is:** shown when `Firebase.initializeApp`, consent restore (SharedPreferences), App Check
activation or the `userChanges` subscription throws (`firebase_service.dart:134-182`).
**Findings**
- P2 · copy / diagnosis · `login_gate.dart:278-288`, `firebase_service.dart:178-181` — any init failure
  (including a transient App Check `activate` or SharedPreferences error) flips
  `_available = false` and shows "Sign-in is unavailable **in this build**", which tells users the app is
  broken and to reinstall. · **Fix:** distinguish "not configured" (missing google-services) from
  "temporarily failed" and only use the build wording for the former; log the cause via `Diag`.
- P2 · UX · no support/contact link. · **Fix:** add "Contact support" (mailto / help URL).
**Test:** unavailable → Retry → available transitions to login.

## Account-not-ready screen (`login_gate.dart:313-439`)
**What it is / how reached:** signed in but `accountReady` false: local namespace still hydrating,
server `/account/login` pending/failed, or deletion pending.
**Findings**
- **P1 · dead end · `login_gate.dart:376-389`** — Retry / Sign out render only when
  `accountError != null`. `accountError` is only set by the server acknowledgement
  (`account_session.dart:57`); when the *local* transition fails (`state.dart:2899-2904` sets
  `lastSessionPersistFailed` and leaves `_sessionAccountReady=false`; `_onUser` swallows it at
  `firebase_service.dart:209-213`) the screen shows an **infinite spinner with no way out**, not even
  Sign out. In release builds (account feature off, see cross-cutting P0) nothing ever sets
  `accountError`, so this screen can never offer Retry at all. · **Fix:** also show Retry + Sign out when `AppState.I.lastSessionPersistFailed` or after a
  15 s timer; Retry should call `AppState.I.transitionSessionAccount('firebase:$uid')` when the server
  feature is off.
- **P1 · unhandled error · `login_gate.dart:392-405, 409-423`** — `restoreAccount()` and
  `retryAccountLogin()` are awaited in `try/finally` with **no catch**. `restoreAccount` throws
  `AccountException` on network/409/"server did not confirm" (`firebase_service.dart:282-286`,
  `account_service.dart:140-159`) and `_retryAccountLogin` can throw from `transitionSessionAccount`
  (`firebase_service.dart:243`). Result: the button re-enables silently, nothing is shown, and the error
  reaches `PlatformDispatcher.onError`, which Crashlytics records as **fatal**
  (`firebase_service.dart:428-431`). · **Fix:** catch, store into a local `_actionError`, render it under
  the buttons (liveRegion), and keep fatal reporting for genuine crashes only.
- P2 · stale state · `login_gate.dart:329-335` + `firebase_service.dart:83` — `lastDeletionReceipt` is a
  single global, never cleared on uid change. After A requests deletion and B signs in, B's pending
  screen reads "Signing in did not cancel deletion. Restore the account…" with A's deadline.
  · **Fix:** store `(uid, receipt)` and ignore when uid differs; clear in `_onUser` when `changed`.
- P2 · i18n · `login_gate.dart:330-334` — deadline rendered as raw ISO
  (`2026-11-10\n12:00:00.000 UTC`). · **Fix:** `DateFormat.yMMMMd().add_jm()` in local time + relative
  ("in 29 days").
- P2 · copy · `login_gate.dart:364-365` — "Checking your account with the Ovid service" is shown during
  purely local hydration. · **Fix:** "Loading your chats…" when the account feature is disabled.
- P2 · consistency · `login_gate.dart:426-428` — Sign out is a no-op while an auth SDK call is in flight
  (`firebase_service.dart:475`), with no feedback. · **Fix:** disable the button with a tooltip while
  `_identity.busy`.
**Missing features:** "Contact support" for fenced/deleting accounts (state `fenced`/`deleting` gives
only a generic error).
**Test to add:** widget test: restore throwing `AccountException` shows the message and does not
reach `FlutterError.onError`; local transition failure shows Retry + Sign out.

## Post-login welcome overlay (`login_gate.dart:446-641`)
**What it is:** one-time bottom banner after first sign-in per install.
**Findings**
- P2 · a11y · `login_gate.dart:610-621` — nested `liveRegion` (outer card + header) makes TalkBack
  announce twice. · **Fix:** keep `liveRegion` on the outer `Semantics` only.
- P2 · logic · `login_gate.dart:489-490` — the flag is written before the overlay is shown; a crash/kill
  in between loses the welcome. Low impact; acceptable. Also it is per install, not per account — a
  second account on the same device never sees it (fine).
- P2 · dead code · `login_gate.dart:521-525` — `if (!_checked) return widget.child; return widget.child;`
  is redundant; `_checked` is unused. · **Fix:** remove `_checked`.
**Missing features:** the banner says "Explore your available models" but offers no CTA to the model
picker or a starter prompt (ChatGPT/Claude onboarding shows example prompts).

## Login screen (`login_gate.dart:660-771`)
**What it is:** sign-in card hosting `AuthMethods` (Google / phone) + pending-deletion notice.
**Findings**
- **P1 · compliance · `login_gate.dart:753-763`** — the only legal copy is "By continuing you agree to
  use Ovid responsibly…"; no Terms of Service or Privacy Policy links before account creation (privacy
  policy is reachable only from Settings after login, `settings_screen.dart:543-555`). Play's User Data
  policy requires the privacy policy to be available in-app, and sign-up consent should reference ToS.
  · **Fix:** "By continuing you agree to the [Terms] and [Privacy Policy]" with tappable links
  (`url_launcher`, ≥48dp targets).
- P2 · a11y · `login_gate.dart:739-743` — `liveRegion: true` on the static card title re-announces on
  every rebuild. · **Fix:** drop `liveRegion`.
- P2 · stale state · `login_gate.dart:666-736` — pending-deletion card is shown to whoever opens the
  login screen next (receipt not keyed by uid; see above).
- P2 · typography · `login_gate.dart:695-699, 758-762` — hard-coded `TextStyle(fontSize: 14/13)` instead of
  `AetherType.*`. · **Fix:** use theme styles so text scaling/contrast tokens apply uniformly.
**Missing features:** Sign in with Apple is irrelevant on Android, but there is no email/password or
email-link option — users without Google and unable to receive SMS cannot sign up.
**Test to add:** login screen exposes Terms/Privacy links with `Semantics(link: true)`.

## AuthMethods picker (`auth_methods.dart:18-235`)
**What it is / how reached:** shared provider list used by the login screen
(`login_gate.dart:744`), Account → Link / Verify (`auth_screen.dart:50, 284, 415`) and Private Sync
(`private_sync_settings_screen.dart:50`). Google via `google_sign_in` 6.x + Firebase credential;
other providers via `signInWithProvider`; phone via `AuthPhoneDialog`.

**Findings**
- P1 · i18n / conversion · `auth_methods.dart:304-311`, `auth_phone_flow.dart:74-79`,
  `auth_providers.dart:116-117` — phone sign-in **requires a leading `+country code`** (regex
  `^\+[1-9]\d{7,14}$`); a user typing `98765 43210` gets "Enter a valid phone number with country code,
  such as +14155550100". There is no country selector or default region, and the example is a US number
  for an India-based product. · high drop-off on the phone path. · **Fix:** add a country-code prefix
  dropdown defaulting to the device locale/SIM region (`+91` fallback), prepend it when the input has no
  `+`, and change the hint/example to the user's region.
- P2 · state leak · `auth_methods.dart:93, 128` — when the widget unmounts mid-flow `_run` returns without
  calling `widget.onBusyChanged?.call(false)`; parents that track `busy` (e.g. `auth_screen.dart:58` sheet
  with `PopScope`) can stay locked if they outlive this child. · **Fix:** call `onBusyChanged(false)` in a
  `finally` regardless of `mounted`.
- P2 · copy · `auth_methods.dart:157-160` — "Sign in with a configured social provider or phone" is
  developer wording. · **Fix:** "Sign in with Google or your phone number. New here? An account is
  created automatically."
- P2 · copy · `auth_providers.dart:94, 127, 133-134` — errors surface "Firebase project", "this build" and
  raw codes (`Authentication failed (internal-error)`). · **Fix:** user-facing text without vendor/build
  terms; log `error.code` to `Diag`.
- P2 · branding · `auth_methods.dart:69-70` — Google button uses `Icons.account_circle` instead of the
  Google "G" mark required by Google's sign-in branding guidelines. · **Fix:** bundle the official
  G logo asset for `google.com`.
- P2 · a11y · `auth_methods.dart:187-195` — "Complete the authentication prompt to continue." is not a
  live region; screen-reader users get no cue that a system sheet opened. · **Fix:** wrap in
  `Semantics(liveRegion: true)`.

**Missing features:** email-link / passwordless sign-in for users without Google or SMS; Google One Tap /
Credential Manager (`google_sign_in` 7 + Credential Manager is the current Android recommendation).
**Test to add:** phone number `9876543210` with region IN normalizes to `+919876543210` and reaches `verify`.

## Phone verification dialog (`auth_methods.dart:240-576`)
**What it is:** modal OTP flow (send → 6-cell code → verify / resend / change number / cancel) backed
by `PhoneAuthFlow` (`auth_phone_flow.dart`).

**Findings**
- P2 · UX · `auth_methods.dart:451-457, 492-520` — entering/pasting the 6th digit does not submit; user
  must find "Verify code" (often under the keyboard). · **Fix:** call `widget.onSubmitted()` when all six
  cells are filled.
- P2 · UX · `auth_phone_flow.dart:99-103` — after 5 sends the only message is "Close this flow and try
  later" — but `_sends` lives in the flow, so re-opening the dialog resets it; the limit is cosmetic and the
  copy is misleading. · **Fix:** either persist a per-number send counter with a timestamp or reword to
  "Too many codes requested. Wait a few minutes."
- P2 · a11y · `auth_methods.dart:539-565` — each OTP cell is wrapped in `Semantics(label: …)` **and**
  passes the same label to `AetherField` → TalkBack reads the label twice. · **Fix:** keep one.
- P2 · layout · `auth_methods.dart:524, 533` — with large text the cells wrap to 3 columns (fine), but
  `cellWidth` uses `scale(14)+24`, which at 200% scaling still allows 6 columns on 360dp; verify with a
  golden at 2.0× on 320dp width.
- P2 · formatting · `auth_methods.dart:366-369, 383-385` — odd indentation (`_clearCode()` lines);
  run `dart format`.

**Missing features:** SMS User Consent / Retriever auto-fill hint is only `AutofillHints.oneTimeCode`
on cell 0 — fine with Firebase auto-verification; consider showing "Code detected automatically" state.
**Test to add:** paste "123456" into cell 3 fills all cells and auto-submits once.

## Account screen (`auth_screen.dart:22-425`)
**What it is / how reached:** Settings → profile row (`settings_screen.dart:409`) or shared-conversation
sign-in (`shared_conversation_screen.dart:33`). Profile header, plan card, account details, linked
methods (+ link more), legacy-password warning, danger zone (deletion panel + sign out).

**Findings**
- P1 · Play policy fallback · `auth_screen.dart:37-38` + `account_deletion_panel.dart:130-133` — deletion
  requires re-auth with a provider that is both linked **and enabled in this build**; a user whose only
  linked method is legacy `password` (or a provider later disabled via `OVID_AUTH_*`) gets the migration
  help text and **cannot delete in-app**, with no alternative path. · **Fix:** when `reauthProviders` is
  empty, show "Request deletion by email / web form" with the Play Console deletion URL and a
  pre-filled `mailto:` including the UID.
- P2 · broken affordance · `auth_screen.dart:117-131` + `firebase_service.dart:475` — `signOut()` silently
  returns while an auth SDK call is busy; the button flips to "Signing out…" and back with the user still
  signed in and no message. · **Fix:** have `signOut` return a bool / throw `auth-busy` and show
  "Finish the open sign-in prompt first".
- P2 · raw error · `auth_screen.dart:127` (`'Could not sign out: $error'`) and
  `firebase_service.dart:462` (`'Could not update name: $e'`, rendered in the edit dialog
  `auth_screen.dart:470`) leak exception text. · **Fix:** fixed friendly copy + `Diag.swallow`.
- P2 · UX · `auth_screen.dart:314-319` — Sign out has no confirmation even though in-flight runs and
  unsynced work stop. · **Fix:** confirm dialog when `AgentService` has an active run.
- P2 · dead code · `auth_screen.dart:382-424` — `_signedOut` is unreachable in the app: `LoginGate`
  replaces the whole navigator with `_LoginScreen` when signed out (`login_gate.dart:139-146`), unmounting
  this route. It duplicates the login UI and the pending-deletion card with a raw ISO date (`:406-408`).
  · **Fix:** delete it (pop to root on sign-out instead).
- P2 · perf · `auth_screen.dart:89-95` — the whole screen (`ListView` + `AuthMethods` with
  `TextPainter` measurement per button) rebuilds on **every** `AppState` notification, including streaming
  token updates of a background run, only to read `ovidCloudTier`. · **Fix:** listen to `fb` only and wrap
  the plan card in a `ListenableBuilder` with a tier selector (or `ValueNotifier<String> tier`).
- P2 · validation · `auth_screen.dart:455-460, 482-492` — edit-name has no max length (Firebase allows
  long names that overflow the sidebar). · **Fix:** `maxLength: 60`, trim, and reject control characters.
- P2 · consistency · `auth_screen.dart:358-366` vs billing plan names — verify the PLUS/PRO/MAX labels
  match `billing_screen.dart` (see below).
- P2 · i18n · `auth_screen.dart:370` — Google shown with `Icons.g_mobiledata` (a "G mobile data" glyph).
  · **Fix:** official Google mark asset.

**Missing features:** data export ("Download my data" — ChatGPT/Claude both offer it); active sessions /
devices list; marketing/analytics consent toggle next to account (currently only the shell prompt).
**Test to add:** account screen does not rebuild when `AppState.notifyListeners()` fires without a tier
change (rebuild counter).

## Account deletion panel (`account_deletion_panel.dart:7-326`)
**What it is / how reached:** Account → Danger zone. Confirm dialog → re-auth (`_verifyIdentity`) →
`FirebaseService.requestAccountDeletion` → server `/account/deletion` → sign-out → login screen shows
pending notice; restore via re-auth + `/account/deletion/cancel`.

**Findings**
- **P0 · Play policy · `account_deletion_panel.dart:186-201, 313`** — in every release build the panel
  shows "Account deletion is not yet activated on the server. No request has been submitted." and the
  delete button is disabled (`enabled` is false, see cross-cutting P0). **Fix:** cross-cutting P0; plus,
  until the server is live, replace the disabled button with a working "Request deletion" link
  (web form / support mail) so the Play requirement is met.
- P1 · state · `account_deletion_panel.dart:146-164` — panel-level Restore calls
  `service.cancelDeletion()` directly, bypassing `FirebaseService.restoreAccount` (`firebase_service.dart:274-289`),
  so `lastDeletionReceipt` keeps the stale `pending` receipt and the login/not-ready screens keep warning
  about deletion after a successful restore. · **Fix:** inject `restore: fb.restoreAccount` and use it.
- P1 · cross-device · `firebase_service.dart:228-230` — deletion requested on device B is only noticed on
  device A at the next cold start / user change (`acknowledgeLogin` runs only from `_onUser`); A keeps
  using the account locally during the grace period. · **Fix:** re-run `acknowledgeLogin` on resume
  (throttled, e.g. every 15 min) and whenever `/mint` returns 401/403.
- P2 · stale UI · `account_deletion_panel.dart:166-174` — countdown is computed once per build; there is
  no ticker, so "23h 59m remaining" never changes while open. · **Fix:** `Timer.periodic(1 min)` while
  pending.
- P2 · i18n · `account_deletion_panel.dart:243` — raw ISO UTC timestamp. · **Fix:** localized local time.
- P2 · UX/data · `account_deletion_panel.dart:108` — "Local workspaces … are not erased by this action"
  with no option to erase them. · **Fix:** checkbox "Also erase chats and files on this device" wired to the
  existing reset coordinator after the server accepts.
- P2 · UX · `account_deletion_panel.dart:315-322` — "Refresh deletion status" is always visible to every
  user even with no request. · **Fix:** show only when `_status` is non-active or after an error.
- P2 · a11y · `account_deletion_panel.dart:274-292` — error card is not a live region. · **Fix:**
  `Semantics(liveRegion: true)`.

**Missing features:** confirmation by typing "DELETE" (ChatGPT pattern) is not required — acceptable given
re-auth; an emailed receipt of the deletion request.
**Test to add:** release-flag test asserting `AccountService().enabled == true` when built with the
production defines; widget test that restoring from the panel clears `lastDeletionReceipt`.


## Plans & Billing screen (`billing_screen.dart:16-604`)
**What it is / how reached:** Settings → Plans & Billing (`settings_screen.dart:364`), Account → plan card
(`auth_screen.dart:340`), Providers → Ovid Cloud "Plans" (`providers_screen.dart:166`). Gradient
current-plan header (tier pill, blurb, allowance bar, `CloudUsageStatus`, "Upgrade" to next tier),
four hard-coded plan cards (Free / Plus ₹499 / Pro ₹899 / Max ₹1699), and an upgrade bottom sheet whose
"Pay now" calls `OvidCloudService.upgrade` → POST `https://api.ovidsi.com/upgrade` (server-gated by
`ALLOW_TEST_UPGRADE`, `ovid_cloud_service.dart:289-291, 657-711`).

**Findings**
- **P0 · Play policy / revenue · `billing_screen.dart:450-471` + `ovid_cloud_service.dart:289-291`** — the
  only purchase path is a TEST endpoint that grants a tier with no payment; there is no Google Play
  Billing integration (`pubspec.yaml` has no `in_app_purchase`). Play Payments policy requires Play
  Billing for digital subscriptions sold in an Android app; shipping this sheet with
  `ALLOW_TEST_UPGRADE` on gives paid tiers away free, and with it off every "Pay now" ends in
  "Could not complete the upgrade. Try again." — a dead CTA on the revenue screen. · **User impact:**
  either free paid plans or a broken purchase flow that invites 1-star reviews; app rejection risk.
  · **Fix:** integrate `in_app_purchase` (Play Billing v7) with server-side purchase-token verification
  (`/billing/verify` + RTDN webhook) that sets the tier; until then hide the plan CTAs in release builds
  (`kReleaseMode` / a server flag `billing_enabled`) and show "Paid plans coming soon".
- P1 · broken flow · `billing_screen.dart:391-398` — a paid user has no way to cancel or downgrade to
  Free (the Free card just says "Included with your account"), and "Change plan" to a lower paid tier
  calls the same `upgrade()` with no proration / period-end semantics. · **Fix:** with Play Billing,
  open the Play subscription centre (`https://play.google.com/store/account/subscriptions?sku=…&package=…`)
  for cancel/downgrade, and show "Renews on / Ends on <date>" in the header.
- P1 · copy / pricing transparency · `billing_screen.dart:57, 67, 77, 510` — prices show no billing
  period ("₹499" — per month? one-off?), no tax note, and "Pay now · ₹499" gives no renewal terms.
  Play requires clear subscription terms before purchase. · **Fix:** "₹499 / month", auto-renew line,
  cancel-anytime line, links to Terms and Privacy in the sheet; take price strings from
  `ProductDetails.price` (localised by Play, not hard-coded INR, so non-India users see their currency).
- P1 · UX · `billing_screen.dart:58-82` — plan cards describe value only as "3×/7×/15× the Free base
  allowance"; users cannot tell what that means (messages/day? which models? image generation?). ·
  **Fix:** server-provided feature list per tier (models included, approximate messages, image quota,
  priority), rendered from `/usage` or a `/plans` endpoint so copy and limits never drift.
- P1 · state · `billing_screen.dart:456-470` — the sheet is dismissible (swipe / back / scrim) while
  `_busy`; the request keeps running and the snackbar may appear later on a different screen, and if the
  button was disposed meanwhile `_busy` stays true for a re-opened sheet of a re-used state. Failure
  also pops the sheet, so the user loses context to retry. · **Fix:** `isDismissible: !_busy`,
  `enableDrag: !_busy`, `PopScope(canPop: !_busy)`; on failure keep the sheet open and show the error
  inline with a Retry.
- P1 · error copy · `billing_screen.dart:465-467` + `ovid_cloud_service.dart:690-708` — every failure
  (network, 403 test-upgrade disabled, 402, timeout, App Check) collapses into "Could not complete the
  upgrade. Try again." · **Fix:** have `upgrade()` return a result enum (`ok / offline / notAvailable /
  rejected / unknown`) and map each to specific copy; never suggest retrying when the server said the
  feature is disabled.
- P2 · perf · `billing_screen.dart:119-121` — the whole `ListView` (header + 4 cards) rebuilds on every
  `AppState` notification (streaming tokens of a background run) although it only reads the tier. ·
  **Fix:** drop `app` from the merge; listen to `OvidCloudService.I` + `_store` (tier changes already go
  through `setOvidCloudTier` → store configuration).
- P2 · duplicate loading UI · `billing_screen.dart:249-257` — while loading, the header shows its own
  16dp spinner **and** `CloudUsageStatus` shows a REFRESHING pill, a second spinner and "Refreshing
  allowance…". · **Fix:** let `CloudUsageStatus` own the loading state; header shows a skeleton bar.
- P2 · unknown-tier state · `billing_screen.dart:122, 392, 399-400` — before `/usage` returns (or when
  it fails) tier is `''`: header says "Plan unavailable", paid cards say "Plan status unavailable", but
  the Free card still says "Included with your account", and there is no full-screen error/Retry if the
  device is offline. · **Fix:** one top-level error state with Retry when `tier` is unknown and
  `store.error != null`; skeleton cards while loading.
- P2 · consistency · `billing_screen.dart:42-84` vs `auth_screen.dart:358-366` — tier → name mapping
  ('3x'→Plus etc.) is duplicated in two files plus `ovidPlanMultipliers`. · **Fix:** one
  `OvidPlan` enum in core with `title`, `multiplier`, `rank`; both screens read it.
- P2 · a11y · `billing_screen.dart:300-317` — `LinearProgressIndicator` has no semantics label/value;
  TalkBack reads nothing meaningful. Plan cards are not grouped (`MergeSemantics`) so a card reads as 5
  disconnected nodes; the current plan is indicated only by a coloured border. · **Fix:**
  `Semantics(label: 'Allowance', value: '62% remaining')`, `MergeSemantics` per card, and a visible
  "Current" pill/`selected: true` semantics on the active card.
- P2 · layout · `billing_screen.dart:278-286` — the decorative `AetherGradientHeader(height: 110)` sits
  behind a card that is taller than 110dp, so the wash ends mid-card at a hard edge on tall text scales.
  · **Fix:** `Positioned.fill` gradient behind only the top inset, or drop the Stack.
- P2 · dead code · `billing_screen.dart:103-107` — `_tierRank` returns `-1` for unknown tiers and the
  local `i` adds nothing; `isBelow` (`:340`) is true for every plan when `currentRank == -1` is not
  checked first in all branches. Works by branch order only. · **Fix:** fold into the `OvidPlan` enum.

**Missing features:** Play Billing purchase / restore purchases / manage subscription; renewal date and
billing history (ChatGPT and Claude both show plan, renewal date and "Manage subscription"); an
annual-plan option; a comparison table; a "usage resets in …" line in the header (the server sends
`budget_window` but it is never shown here); promo codes.
**Test to add:** widget test that with `kReleaseMode`-equivalent flag and no billing backend the
"Pay now" CTA is hidden; test that the upgrade sheet cannot be dismissed while busy and keeps the sheet
open with an inline error on failure; rebuild-count test that `AppState.notifyListeners()` does not
rebuild `_PlanCard`.

## Cloud usage status (`cloud_usage_status.dart:13-103`)
**What it is / how reached:** Shared freshness/error block embedded in the billing header
(`billing_screen.dart:257`) and the Usage screen Ovid Cloud card (`usage_screen.dart:706`). Driven by
`CloudUsageStore` (`lib/core/cloud_usage_store.dart`): pill UNAVAILABLE / REFRESHING / STALE, caption,
Retry.

**Findings**
- P2 · raw error · `cloud_usage_store.dart:139-141` + `ovid_cloud_service.dart:636-638` — the error
  caption shows "Cloud allowance unavailable (503). Retry to refresh." — HTTP status codes in user copy,
  and 401/402/429 get the same text. · **Fix:** map status → copy ("You're offline", "Sign in again",
  "Daily allowance used up — resets in 3h", "Service busy, try again shortly"); keep the code in Diag.
- P2 · flicker · `cloud_usage_store.dart:83-89, 108-111` — `refresh()` sets `stale = true` before the
  fetch starts and resume/refresh during the 2 s cooldown leaves the block showing a yellow STALE pill
  with no explanation and no spinner; on every screen open the pill flashes STALE → REFRESHING. ·
  **Fix:** treat "pending, not yet in flight" as loading for display, or only show STALE when
  `usage != null && age > N min`.
- P2 · UX · `cloud_usage_status.dart:22-39` — when there is no usage yet, not loading and no error (e.g.
  between cooldown ticks) the block is a lone STALE pill — meaningless to users. · **Fix:** render
  nothing in that state.
- P2 · a11y · `cloud_usage_status.dart:70-90` — error caption is not a live region, so TalkBack users
  are not told the allowance failed to load; the pill text is all-caps abbreviations read letter by
  letter on some engines. · **Fix:** `Semantics(liveRegion: true)` around the error row; sentence-case
  semantic label on the pill.
- P2 · freshness · `cloud_usage_status.dart:65` — "Last known allowance · may be out of date" gives no
  timestamp. · **Fix:** store `fetchedAt` in `CloudUsageStore` and show "Updated 5 min ago".

**Missing features:** "resets at <local time>" from `budget_window`; offline detection (connectivity)
instead of a generic error.
**Test to add:** widget test that a 503 shows friendly copy without the status code, and that no STALE
pill renders on first open while the initial fetch is pending.

## Usage screen (`usage_screen.dart:138-408`, hero `:612-816`, provider card `:825-1017`)
**What it is / how reached:** Settings → Usage (`settings_screen.dart:372`). Ovid Cloud hero
(server-authoritative plan pill, "% remaining", per-model remaining rows, `CloudUsageStatus`), a local
"Retained observed history" strip (today's provider-reported tokens, in/out totals), "By provider"
cards aggregated from `AppState.usageAttempts` (tap → `ProviderUsageScreen`, inline "Show N models"),
overflow menu → Image receipts.

**Findings**
- P1 · perf · `usage_screen.dart:308-313` — `_aggregate(app)` (full pass over the attempt journal, up to
  500 records, with a linear `p.models.where(...)` per record, `:231`) plus the "today" filters run inside
  an `AnimatedBuilder(animation: app)`, i.e. on **every** `AppState` notification — on HEAD that includes
  every streamed token of a background run. Opening Usage during a long run causes visible jank on
  low-end Android. · **Fix:** listen to a `ValueListenable<int> usageRevision` (or select on
  `app.usageRevision`) and memoise the aggregate by revision; use a `Map<String, UsageModelUsage>` per
  provider. (`perf/streaming-rebuilds` reduces but does not remove the problem — any other `refresh()`
  still re-aggregates.)
- P1 · data correctness / copy · `usage_screen.dart:316-330, 535` + `usage_attempt_store.dart:60` — the
  journal keeps only the last 500 terminal attempts / 1 MiB, but the UI labels figures as "Today" and
  "Last 14 days" with no hint of truncation; heavy users (agent runs make many attempts) see today's
  count silently undercounted. `AppState.usageHistoryTruncated` and `usageStorageError` exist but are
  never rendered anywhere in `lib/ui`. · **Fix:** show "History limited to the last 500 requests" when
  `usageHistoryTruncated`, and an error banner when `usageStorageError != null`; consider daily roll-up
  buckets so per-day totals survive truncation.
- P1 · UX / product · whole screen — the screen answers "how many tokens did my device observe" but not
  the questions users have: "how much can I still use, when does it reset, what costs most". The server
  sends `budget_window` and `requests_today` (`ovid_cloud_service.dart:818-823`) but neither is shown; no
  reset time, no upgrade CTA from the hero when `pct < 0.1`. · **Fix:** hero shows "Resets in 4h 12m" from
  `budget_window`, today's request count, and an "Upgrade" button (→ `BillingScreen`) when low or empty.
- P2 · copy · `usage_screen.dart:571-581` — when some values are unknown the strip renders
  "Input · output · some values unavailable" **and** a separate "Unavailable" word **and** the numbers
  ("1.2K in · Unavailable out") — reads as a glitch. Elsewhere jargon such as "Token provenance ·
  Derived · Legacy · Reported", "Measured · …", "Estimated/legacy · …", "ACTIVITY SCOPE",
  "Server-authoritative" is engineering vocabulary, not user copy. · **Fix:** drop the stray
  "Unavailable" Text; collapse provenance details behind an (i) info sheet; plain labels
  ("Tokens used today", "Includes estimates").
- P2 · dead code · `usage_screen.dart:22-73, 96-97, 224-229` — the `_Pricing` table (stale list prices)
  and `costUsd` / `hasPricedModel` are computed for every record but never rendered ("Internal only").
  · **Fix:** delete, or actually show "≈ $0.42 estimated" for BYOK providers (a real ChatGPT/Claude-Code
  parity feature: Claude Code's `/cost` shows session cost) behind a toggle.
- P2 · UX / interaction · `usage_screen.dart:843-986` — whole card is an `InkWell` under an opaque
  `AetherCard` (ripple is painted underneath, so no visible feedback), and a second overlapping
  `open_in_new` InkWell (`:962-983`, 34×34dp, below 48dp) navigates to the same place; the "Show models"
  button sits inside the tappable card, so mis-taps navigate away. · **Fix:** single explicit chevron
  `IconButton` (48dp) or make the card `Material`+`InkWell` on top; remove the duplicate icon.
- P2 · a11y · `usage_screen.dart:1370-1376` — chart bars expose `onTap` only through `Semantics`, so
  sighted users cannot tap a bar to see its value, while TalkBack announces 14 "buttons" with ISO dates
  ("2026-10-11: 0 tokens"). · **Fix:** `GestureDetector`/tooltip on bars for touch users, localised
  date in the label, and merge zero days ("No activity").
- P2 · perf · `usage_screen.dart:1047-1098` — `ProviderUsageScreen` re-runs the whole-journal
  `_aggregate` and a second full pass for the 14-day buckets on every `AppState` **and**
  `OvidCloudService` notification. · **Fix:** same memoisation by `usageRevision`.
- P2 · a11y / text scale · `usage_screen.dart:444, 1259-1268, 1328, 1343` — fixed 9.5–10.5 sp labels in
  `textFaint` on `surface` (likely < 4.5:1 contrast; see 08 theme review). · **Fix:** minimum 12 sp and
  `textMuted` for informative labels.
- P2 · empty state · `usage_screen.dart:379-384` — "No usage yet" is shown even when
  `usageStorageError` means history could not be read. · **Fix:** distinguish load error from empty.
- P2 · discoverability · `usage_screen.dart:287-305` — Image receipts (a recovery path for paid image
  jobs) is hidden in an unlabeled overflow menu. · **Fix:** a visible "Image receipts" list tile under the
  hero when the account has any receipts.

**Missing features:** reset countdown; usage per conversation / per agent run (Claude Code `/cost`,
`/usage` parity); export CSV; date-range picker (7/30 days); "Clear local usage history" action;
cross-device usage (server totals rather than per-device journal).
**Test to add:** widget test that the aggregate is not recomputed when `AppState.notifyListeners()`
fires without a `usageRevision` change; test that `usageHistoryTruncated == true` renders the
truncation notice; golden at 2.0× text scale for the provider card.

## Image receipts screen + panel (`usage_screen.dart:414-436`, `image_receipt_panel.dart:10-339`)
**What it is / how reached:** Usage → ⋮ → "Image receipts" (`usage_screen.dart:287-305`) pushes
`ImageReceiptsScreen`, which hosts `ImageReceiptPanel` bound to `ImageStudio.I` and
`OvidCloudService.I.imageHeaders`. One card per saved image request (state pill, "Exact charge",
request ID + copy, result notice, "Recover image" / "Check status" → `ImageStudio.recover`, GET-only).
Receipts are loaded at sign-in by `firebase_service.dart:221,265`.

**Findings**
- P1 · UX · `image_receipt_panel.dart:178-301` + `image_receipt_store.dart:83-96` — a receipt has no
  timestamp, prompt, thumbnail or conversation link; each card is identified only by an opaque
  `image-<32 base64 chars>` ID. With more than one or two receipts the user cannot tell which image a
  card is for. · **Fix:** persist `createdAt` and a truncated prompt (or conversation id) in
  `ImageRequestRecord` at submission time; show "Oct 11, 14:02 · 'a red fox in…'" as the card title,
  newest first, with the request ID collapsed under "Details".
- P1 · broken flow · `image_receipt_panel.dart:257-267` — after a successful "Recover image" the bytes are
  only previewed at 180dp; there is no Save to gallery / Share / Open-in-chat action, so the recovery path
  cannot actually give the user their (paid) image. Bytes live only in widget state and vanish on back.
  · **Fix:** add Save (MediaStore via `image_gallery_saver`/`gal`) and Share (`share_plus` XFile.fromData)
  buttons; tap to open the shared image viewer; persist recovered bytes into the originating conversation.
- P1 · copy / currency · `image_receipt_panel.dart:195-197` + `image_receipt_store.dart:56-64` —
  "Exact charge: 0.04" renders the server's decimal string with no unit (and the validator also admits
  scientific notation like `4E-2`). It is an internal USD amount, contradicting the billing screen's
  "never surface USD" rule and meaningless to a plan user whose allowance is a percentage. · **Fix:** show
  allowance impact ("Used ~1% of today's allowance") or hide the amount; if money is shown, format with
  currency via `NumberFormat.simpleCurrency` and never raw strings.
- P2 · loading state · `image_receipt_panel.dart:32-37, 168-177` — the panel never triggers
  `loadReceipts()` on open; it relies on the sign-in load. If that load silently produced an empty list
  (e.g. journal still being written) the user sees "No loaded image receipts for this account." with no
  refresh affordance (Retry only appears on error). "No loaded" is also odd copy. · **Fix:** call
  `loadReceipts()` in `initState` (or add pull-to-refresh / app-bar refresh) and use "No image
  receipts yet — images you generate with Ovid Cloud appear here."
- P2 · perf / memory · `image_receipt_panel.dart:145-147, 258-263` + `usage_screen.dart:425-432` — a
  `SingleChildScrollView` nested inside the host `ListView` builds every card eagerly, and
  `Image.memory` decodes recovered images at full resolution (multi-MP PNGs) without `cacheHeight`. ·
  **Fix:** let the host own scrolling (`ListView.builder` over receipts), `cacheHeight: (180 * dpr).round()`.
- P2 · redundancy / copy · `image_receipt_panel.dart:188-204, 252-255, 269-271` — state is shown twice
  (uppercase pill and "Status: …"), and each card carries two long disclaimers about "paid jobs" and
  "accounting, not image availability" — internal engineering wording repeated N times. · **Fix:** one
  explanatory line at the top of the screen; per card only the pill + friendly state text.
- P2 · UX · `image_receipt_panel.dart:97-103` — any failure (offline, 401 expired key, 404 expired result)
  shows the same "Receipt could not be checked. Keep this request ID; do not submit a replacement." ·
  **Fix:** map `ImageStudioError` kinds to specific copy; offer "Contact support" with the request ID
  pre-filled for terminal failures.
- P2 · a11y · `image_receipt_panel.dart:232-250` — outcome/notice updates after a check are not live
  regions; the "Request ID copied" state never resets and gives no snackbar/announcement. · **Fix:**
  `Semantics(liveRegion: true)` on the result block; snackbar "Request ID copied"; reset after 2 s.
- P2 · layout · `image_receipt_panel.dart:272-296` — "Recover image" is full-width while "Check status" is
  left-aligned below it; inconsistent button alignment. · **Fix:** a `Wrap` / `OverflowBar` with both.

**Missing features:** filter by state (pending / failed); "Request refund / report a problem" for failed
charged jobs; a receipt link from the image bubble in chat.
**Test to add:** widget test that a recovered image shows Save and Share actions; test that the panel
calls `loadReceipts()` on open; test that `charged` is never rendered as a bare number.

## Providers screen + sheets (`providers_screen.dart:43-1133`)
**What it is / how reached:** Settings → Providers (`settings_screen.dart:123`). Ovid Cloud tile
(plan pill, "Signed in", model count, "Manage plan" → `BillingScreen`), BYOK provider tiles (status,
model count, expand to cached model chips, "Fetch models", "API key", ⋮ Edit / Remove), and three bottom
sheets: API key (`_ApiKeySheet :536-658`), Edit provider (`_EditProviderSheet :662-822`: base URL, API
format, add/remove models), Add custom provider (`_AddProviderSheet :1028-1133`).

**Findings**
- **P1 · broken copy (shipped placeholder) · `providers_screen.dart:86, 773, 1087, 1117`** — user-visible
  strings read "Add an **[OI]**-compatible endpoint", "**[OI]**-compatible" (API format chip, twice) and
  "Connect an **[OI]**-compatible or Anthropic endpoint." — a redaction placeholder for "OpenAI" leaked
  into UI copy. · **User impact:** looks broken/unprofessional on a core setup screen; users cannot tell
  which format to pick. · **Fix:** replace with "OpenAI-compatible" (all 4 sites); add a lint/test that
  greps `lib/` for `\[OI\]`.
- **P1 · broken flow (P0 follow-through) · `providers_screen.dart:119-172`** — the Ovid Cloud tile derives
  "Signed in" from `provider.hasKey` and shows "N models" but ignores
  `OvidCloudService.connectionFor(...)`; when mint or the catalog fails (the "models not loading" P0) it
  still says "Signed in · 0 models" with no error and no Retry. This is the screen users open to fix it. ·
  **Fix:** listen to `OvidCloudService.I`; show `connecting / failed (reason) / ready` with a
  "Retry connection" button calling `OvidCloudService.I.ensureConnected()` (it already re-mints when not ready), and "Refresh models" when ready.
- P1 · state / persistence · `providers_screen.dart:289-298` — "Fetch models" mutates
  `provider.models.add(id)` directly on the config object (bypassing the `AppState` mutation API the class
  doc promises, `:36-40`), relying on `reconcileProviderModels` to persist; it only ever merges, so models
  the provider retired stay forever and fail at send time. · **Fix:** add
  `AppState.replaceProviderModels(provider, ids, {keepManual: true})` that tracks manual vs fetched ids,
  removes stale fetched ones, and persists once.
- P1 · raw error · `providers_screen.dart:309, 319` — "Failed: HTTP 401 — check key/URL" and
  `'Fetch failed: $e'` (e.g. `ClientException with SocketConnection failed…`, `type 'List<dynamic>' is not
  a subtype…` when the body is a JSON array or HTML, `:283-284`) are shown verbatim. · **Fix:** map
  401/403 → "Key rejected by provider", 404 → "No /models endpoint at this URL — check the base URL",
  timeout/socket → "Couldn't reach provider", parse errors → "Unexpected response"; guard `j is Map`.
- P1 · missing verification · `providers_screen.dart:200-205, 561-585` — saving a key never tests it;
  tiles stay "Key saved · not verified" indefinitely and users discover a bad key only when a chat fails.
  · **Fix:** after Save, run a lightweight `/models` probe and show "Key verified ✓ · 42 models" or the
  mapped error in the sheet before closing; store `verifiedAt` for the status label.
- P2 · security · `state.dart:6781-6793` (called from `providers_screen.dart:686-693`) + `:265-280` — base
  URL validation accepts `http://`, so a BYOK key can be sent in cleartext (and a built-in provider's URL
  can be repointed to any host while keeping its saved key). · **Fix:** require `https` except for
  loopback / RFC1918 hosts (local gateways), and warn + confirm "Your saved key will be sent to <host>"
  when a built-in provider's host changes.
- P2 · security / UX · `providers_screen.dart:552, 637-643` — the API key sheet pre-fills the full stored
  secret into the TextField (obscured, but in widget memory and accessible to a11y/IME); there is no
  reveal toggle or masked preview. · **Fix:** start empty with a masked hint "sk-…a1b2 saved — paste to
  replace"; keep Clear for removal.
- P2 · UX · `providers_screen.dart:1063-1078` — Add-provider has no inline validation or busy state;
  errors go to a snackbar on the root Scaffold **behind** the modal sheet (same for `_addModel :722-725`,
  format chips `:781-789`, model remove `:998-1004`), so users often never see them, and a double tap on
  "Add" submits twice. · **Fix:** inline `errorText` under the offending field, `_saving` flag disabling
  Add, and no snackbars from inside sheets.
- P2 · consistency · `providers_screen.dart:129` — Ovid Cloud pill shows `tier.toUpperCase()` → "3X" /
  "7X" / "15X", while Account/Billing/Usage show PLUS/PRO/MAX. · **Fix:** shared `OvidPlan.title` (see
  billing).
- P2 · copy · `providers_screen.dart:163-164, 116-117` — "Manage plan" uses an `open_in_new` (external)
  icon for an in-app route; tile doc mentions "mint/revoke the gateway token" which BillingScreen does not
  offer. · **Fix:** chevron icon; fix the doc comment.
- P2 · UX · `providers_screen.dart:207-226` — dialog title "Remove X?" but destructive button "Delete";
  removing a provider whose model is selected in an open chat gives no warning. · **Fix:** consistent
  "Remove"; mention "Chats using this provider will switch to Ovid Cloud Auto".
- P2 · perf · `providers_screen.dart:55-57, 731-733` — screen and Edit sheet rebuild on every `AppState`
  notification (streaming); each `_ModelChip` calls `ModelLimits.compactLabel` per build. · **Fix:**
  narrower listenable (provider revision) or `Selector`-style rebuild.
- P2 · a11y · `providers_screen.dart:981-988` — model chip text 11 sp `textMuted` mono; the remove
  `IconButton` inside a 7-radius chip makes each chip ~48dp tall but chips wrap tightly so adjacent "×"
  targets abut. · **Fix:** `InputChip` with `onDeleted` (built-in semantics and spacing).
- P2 · i18n/design · `providers_screen.dart:330-332, 139` — monogram uses `substring(0,1)` (breaks on
  emoji/surrogate pairs) and providers have no logos. · **Fix:** `characters.first`; ship logo assets for
  built-ins.

**Missing features:** "Test connection" button; per-provider default model; model search/filter in long
lists (OpenRouter returns 300+ ids, paged 10 at a time with "More"); enable/disable a model without
deleting it (the class doc claims "enable or disable models" but only add/remove exist); import provider
from a config URL/QR; per-provider usage link to `ProviderUsageScreen`.
**Test to add:** golden/grep test that no user-visible string in `lib/ui` contains `[OI]`; widget test
that the Ovid Cloud tile shows a Retry when `setConnectionForTest(failed)`; test that fetch with a JSON
array body shows "Unexpected response", not a type error.

## Profile avatar (`profile_avatar.dart:12-96`)
**What it is / how reached:** Shared widget used by the sidebar header (`sidebar.dart:401`), Settings
profile row (`settings_screen.dart:419`) and Account header (`auth_screen.dart:554`). Circle with
`Image.network(photoUrl)` (https only) and an initial/person-icon fallback.

**Findings**
- P2 · perf / offline · `profile_avatar.dart:54-60` — plain `Image.network` with no disk cache and no
  `cacheWidth`: the photo re-downloads on every cold start, shows the fallback while offline, and the
  sidebar (rebuilt often) relies on the in-memory `ImageCache` only. · **Fix:** `cached_network_image`
  (or `Image(image: ResizeImage(NetworkImage(url), width: (radius*2*dpr).round()))`) and request a
  size-appropriate Google photo (`=s${px}-c`).
- P2 · consistency · `settings_screen.dart:419` — Settings passes no `displayName`, so it shows the
  generic person icon while Account shows the initial for the same user. · **Fix:** pass
  `displayName: fb.displayName` at every call site (or make it required).
- P2 · i18n · `profile_avatar.dart:86-95` — the "first cased letter" rule skips caseless scripts, so
  "राम Kumar" renders "K" and "李 Wei" renders "W" — wrong initial for the primary (India) market. ·
  **Fix:** use the first grapheme of the first word (`name.characters.first`), uppercased when cased.
- P2 · a11y / text scale · `profile_avatar.dart:74-82` — the initial's font scales with system text size,
  so at 2.0× a 22-radius avatar's glyph overflows/clips the circle. · **Fix:**
  `textScaler: TextScaler.noScaling` (the avatar is a fixed-size graphic) or `FittedBox`.
- P2 · a11y · `profile_avatar.dart:33-36` — semantics label is always "Profile image" with no name; in
  the sidebar header TalkBack reads "Profile image" without saying whose account is active. · **Fix:**
  label "Profile picture for <name>" (or exclude it when the adjacent name text is already read).
- P2 · polish · `profile_avatar.dart:58-59` — image pops in with no fade, and on the error path there is
  no retry once connectivity returns (error is cached for the URL). · **Fix:** `frameBuilder` fade-in;
  evict the URL from `imageCache` on resume after an error.

**Missing features:** change/upload profile photo (Account only edits the name); deterministic
background colour per user for the fallback (helps distinguish accounts when switching).
**Test to add:** widget test at `textScaleFactor 2.0` that the initial stays within the circle; test
that "राम Kumar" yields "र".

## Group summary
**Totals for this file:** 5 × P0, 29 × P1, 84 × P2 (all sections, including the earlier login/auth/
account/deletion work). The two release-blocking themes are **Play policy** (in-app deletion is dead in
release; paid plans are sold through a test endpoint with no Play Billing) and the **Ovid Cloud
connection/catalog path** (users see "no models" with no way to recover from the screens they open).

**Top 10 fixes, in order**
| # | Fix | Where | Sev | Effort |
|---|---|---|---|---|
| 1 | Add `--dart-define=OVID_ACCOUNT_ENABLED=true` to both release builds + CI guard; until the server is live, show a working "Request deletion" web/mail link instead of the disabled button; route panel Restore through `fb.restoreAccount` | `build.yml:221-222`, `account_service.dart:58`, `account_deletion_panel.dart:146-201,313` | P0 | S (client) + M (server §8) |
| 2 | Hide "Pay now"/Upgrade CTAs in release (server `billing_enabled` flag) now; then integrate Play Billing (`in_app_purchase` + server token verification + RTDN), manage/cancel via Play subscription centre, show "/ month" and renewal terms | `billing_screen.dart:383-406,450-531`, `ovid_cloud_service.dart:289-291,657-711` | P0 | S now / L full |
| 3 | Picker always shows `auto` + last-good Ovid Cloud models when status is `failed`, with "Retry" subtitle | `chat_screen.dart:2412-2414,2455-2458,2681` | P0 | S |
| 4 | Re-mint after catalog rejection must rotate the key (client sends `reason:key_rejected` + key hash; VPS `/mint` rotates); publish a distinct "repairing" state if the same key comes back | `ovid_cloud_service.dart:400-404`, server `mint.py` | P0 | M |
| 5 | Clear the `ovid-cloud` key, bound identity and tier on sign-out / uid change; refuse to send with a key not owned by the current account | `firebase_service.dart:473-493`, `ovid_cloud_service.dart` `_authChanged`, `agent_service.dart:12469` | P1 | S |
| 6 | Providers → Ovid Cloud tile shows real connection state (connecting / failed + reason / ready) with "Retry connection" and "Refresh models" | `providers_screen.dart:119-172` | P1 | S |
| 7 | Replace leaked "[OI]-compatible" placeholder copy (4 sites) with "OpenAI-compatible" and add a grep test | `providers_screen.dart:86,773,1087,1117` | P1 | S |
| 8 | Mint 401 → retry once with force-refreshed ID/App Check token; resume-triggered recovery with exponential backoff + jitter; map mint/catalog/usage/upgrade/fetch-models errors to friendly copy (no HTTP codes, no `$e`) | `ovid_cloud_service.dart:413-423,567-569,636-638`, `login_gate.dart:110-118`, `providers_screen.dart:309,319`, `billing_screen.dart:465-467` | P1 | M |
| 9 | Usage & Billing: stop re-aggregating on every `AppState` notify (memoise by `usageRevision`, drop `app` from billing merge); render `usageHistoryTruncated` / `usageStorageError`; show reset countdown from `budget_window` + Upgrade CTA when low | `usage_screen.dart:308-346,1047-1098`, `billing_screen.dart:119-121` | P1 | M |
| 10 | Image receipts: add timestamp/prompt to records, Save/Share for recovered images, never show bare `charged` amount, load on open | `image_receipt_panel.dart:178-271`, `image_receipt_store.dart:83-96` | P1 | M |

**Next tier (do alongside related work):** upgrade sheet non-dismissible while busy + inline error
(`billing_screen.dart:456-531`, S); verify BYOK key on save and https-only base URLs except
loopback/LAN (`providers_screen.dart:561-585`, `state.dart:6781-6793`, S); "Fetch models" replaces stale
ids via an `AppState` API instead of mutating `provider.models` (`providers_screen.dart:289-298`, S);
single `OvidPlan` enum for PLUS/PRO/MAX naming across Account/Billing/Usage/Providers (S);
legal links (Terms/Privacy) on login and in the purchase sheet (S); avatar caching, i18n initials and
non-scaling glyph (`profile_avatar.dart`, S).

**Suggested order:** 1 → 2 (hide CTAs) → 3 → 5 → 7 → 6 ship as one small release-hardening PR; 4 + 8 with
VPS Phase 1B; 9 + 10 in the usage/billing UX PR; full Play Billing (2) as its own project.

**Parity notes (ChatGPT / Claude apps, Claude Code):** missing data export, active-sessions list,
subscription management/renewal date, usage reset countdown, per-conversation cost/usage (Claude Code
`/cost`, `/usage`), "Test connection" for BYOK providers, and profile photo change.
