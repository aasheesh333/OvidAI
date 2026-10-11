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
in progress

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

