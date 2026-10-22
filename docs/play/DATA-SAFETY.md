# Google Play — Data Safety declaration (owner-facing worksheet)

- **Package:** `com.dhanuk.ovidai`
- **App version:** `1.0.0+3` (`pubspec.yaml`). The internal-test build number
  actually on the track is console state and is **unverified** here.
- **Prepared:** 2026-10-18, from the shipped code and the production schema
  (`cloud/packages/db/src/schema.ts`, `cloud/apps/gateway/src/routes/*`,
  `lib/core/**`). **Revised 2026-10-22**, re-verified against the Android
  manifest, `lib/ui/v2/app/v2_settings_routes.dart`, `server/account/*` and the
  current client. Method: file reading and `grep`; no build was run.
- **Status:** WORKSHEET. The Play Console form is filled by the owner (R4).
  Nothing here is submitted automatically.

This is the answer set for Play Console → **App content → Data safety**. Every
row is derived from a real table/route; if a feature is removed later, the row
must be removed with it. The Generative-AI and UGC answers live in
`PLAY_COMPLIANCE_AUDIT.md` §5–§6. The public privacy policy
(`docs/legal/PRIVACY.md`) is the wording of record where the two overlap.

---

## 1. Does your app collect or share any of the required user data types?

**Yes.** The app is an account-based AI assistant: without an account it cannot
run a prompt, because model execution happens on Ovid's servers.

## 2. Data types

| Play category | Collected? | Shared with third parties? | Purpose | Optional? | Encrypted in transit? | Deletable? |
|---|---|---|---|---|---|---|
| **Personal info → Email address** | Yes (Google sign-in) | No (see §4) | Account creation, sign-in, support | Required for Google sign-in; phone is the alternative | Yes (TLS) | Yes — in-app deletion + `/account/deletion` |
| **Personal info → Phone number** | Yes (phone sign-in) | No | Account creation, sign-in, security | Optional — only if phone sign-in is used | Yes | Yes |
| **Personal info → Name** | Yes (Google account display name) | No | Account identity and profile; shown to people in a Collab room, and on a share link only when the user enables "Show my name" | Optional — only with Google sign-in | Yes | Yes |
| **Personal info → User IDs** | Yes | No | Account identity, per-user sandbox/workspace isolation | Required | Yes | Yes |
| **Messages → Other in-app messages** (chat transcripts, prompts, model replies) | Yes | No (sent only to the model provider, see §4) | The core feature: running the assistant | Required for the feature | Yes | Yes — delete a chat or the account |
| **Files and docs** (attachments, generated images, Studio workspace files) | Yes | No | The user's own work; stored in Ovid's object storage (R2) | Optional (only if attached) | Yes | Yes — R2 prefix `users/{uid}/` is deleted with the account |
| **Photos and videos → Photos** (an image the user attaches, or one Ovid generates) | Yes | No | The user's own work; stored with the chat/artifact | Optional | Yes | Yes |
| **App activity → Other user-generated content** (tool calls, plans, schedules the user creates) | Yes | No | Running the agent and showing history | Required for the feature | Yes | Yes |
| **App activity → In-app search history** | **No.** Chat search runs on the device: an on-device SQLite FTS5 index over the user's own messages (`lib/core/session_search.dart`) and the v2 drawer filter (`lib/ui/v2/sidebar/sidebar.dart`, `_searchResults`). No search query is sent to a server or retained as a history. Artifact name search is a per-request query parameter on the vault list (`cloud/apps/gateway/src/routes/artifactVault.ts`) and is not stored. | — | — | — | — | — |
| **App activity → App interactions** (product events) | Yes, **only after consent** | No | Reliability and product analytics | Optional (consent toggle, default off) | Yes | On request / retention window |
| **Web browsing history** (pages the agent opens in the cloud browser) | Yes | No | The browser feature: showing what the agent did | Optional — only when the browser is used | Yes | Yes — delete the chat or the account |
| **App info and performance → Crash logs** | Yes, **only after consent** | No | Diagnosing crashes | Optional (consent toggle, default off) | Yes | On request / up to 90 days |
| **App info and performance → Diagnostics** (performance, error traces) | Yes, only after consent | No | Reliability | Optional (default off) | Yes | On request / up to 90 days |
| **Device or other IDs → Device or other IDs** (FCM registration token) | Yes | No | Push notifications for finished runs | Optional (notifications can be denied) | Yes | On sign-out / deletion |
| **Financial info → Purchase history** | **No today.** No Play subscription exists yet (monthly or yearly), so the submitted build cannot purchase; the server still verifies any token that arrives. Change this to **Yes** the day the first subscription is live. | No | Entitlements and billing | Required for paid plans | Yes | Per Play policy (tax/accounting records are retained) |
| **Location** | **No** | — | — | — | — | — |
| **Contacts / Calendar / SMS / Phone / Health** | **No** | — | — | — | — | — |
| **Photos and videos (library access)** | **No** — files are chosen through the system picker and only the chosen file is uploaded | — | — | — | — | — |
| **Audio (voice input)** | **No audio is collected or stored by Ovid.** The device's speech recognizer converts speech to text; only the resulting text is sent | — | Voice-to-text | Optional (mic permission) | — | — |
| **Advertising / Ad ID** | **No** — no ads, and `google_analytics_adid_collection_enabled=false` | — | — | — | — | — |

### 2.1 What the manifest declares today

`android/app/src/main/AndroidManifest.xml` declares exactly **three**
permissions: `INTERNET`, `POST_NOTIFICATIONS`, `RECORD_AUDIO`. Every broad
permission the old on-device agent needed (contacts, calendar, SMS, phone,
location, camera, all-files access, battery exemption) was removed with that
agent; `test/play_distribution_test.dart` parses the manifest and fails if the
declared set drifts from those three.

The `RECORD_AUDIO` permission is used only by the speech recognizer
(`speech_to_text`). Ovid never records or uploads audio.

**The in-app Permissions screen lists only those two user-facing permissions**
— microphone and notifications (`lib/ui/v2/app/v2_settings_routes.dart`,
`_permissionItems`: `ids = ['microphone', 'notifications']`). Camera, photos and
storage are deliberately absent because this build never requests them, so
listing them would send the user to an OS page with no Ovid entry. The screen's
own doc comment in `lib/ui/v2/settings_extra/permissions_page.dart` still names
"camera, microphone, photos, notifications and files" — that comment is stale
and should be corrected; the rendered list is the two ids above.

## 3. Data handling

- **Encrypted in transit:** yes — HTTPS/WSS everywhere; cleartext is disabled
  (`android:usesCleartextTraffic="false"` plus
  `android/app/src/main/res/xml/network_security_config.xml`). The gateway is
  fronted by Cloudflare. Certificate pinning is implemented
  (`lib/core/cert_pinning.dart`) but **ships disabled** (`kCertPinningEnabled =
  false`, `kOvidSpkiPins` empty) until the owner supplies the real SPKI pins, so
  it is not a security practice to declare yet.
- **Data deletion request:** in-app **Settings → Delete account**. The action is
  wired to the server (`lib/ui/v2/app/v2_settings_actions.dart` →
  `FirebaseService.requestAccountDeletion`) and starts the server-side deletion
  lifecycle (**24-hour grace, cancellable**; the deadline is
  `GRACE_SECONDS = 24 * 60 * 60` in `server/account/domain.py`). Signing in
  again during the grace window cancels the deletion
  (`server/account/domain.py`, `_grace_login`). The lifecycle then removes:
  the deployment-configured SQL table scopes (sessions, messages, memory,
  schedules, devices and related rows) via `server/account/adapters.py`; the
  user's object-storage prefix `users/{uid}/` via the R2 prefix deleter
  (`cloud/apps/worker/src/main.ts`, `createCloudCleanup`); images, shares,
  BYOK keys, private-sync data and collaboration data
  (`cloud/apps/worker/src/main.ts`, `createCloudCleanup`;
  `server/account/composition.py`); and the LiteLLM key
  (`cloud/apps/worker/src/main.ts`, `createCloudCleanup`).
  If `OVID_R2_*` is unset, the worker logs that workspace/browser objects will
  **not** be deleted — deletion must not be enabled in production without R2.
- **Data retention:** account data lives until deletion, plus the 24-hour grace.
  Live run events keep 24 hours hot and up to 30 days archived (founder
  decision 2026-10-18); share snapshots 30 days; content reports 180 days
  (`server/reports/repository.py`, `retention_seconds=180 * 86400`); crash and
  diagnostic data up to 90 days; backups rotate out after 14 days. The 90-day
  and 14-day figures are **policy statements in `docs/legal/PRIVACY.md`**;
  Firebase Crashlytics retention and the backup rotation are configured in the
  console and are **unverified** from this repo.
- **Children:** the app is not directed at children; no age-gated content. It
  is an 18+ product and does **not** opt in to the Play Families policy.

## 4. Third parties

Ovid runs the models through its own gateway (LiteLLM) and a model provider.
Prompts and replies are transmitted to the model provider **to produce the
answer** — Play treats that as service-provider processing, not "sharing for
advertising". Firebase (Authentication, Cloud Messaging, Crashlytics,
Analytics, App Check / Play Integrity) processes account identifiers, the push
token and — only with consent — crash, diagnostic and usage data. No data is
sold. The full list is maintained in the privacy policy
(`docs/legal/PRIVACY.md`).

If the owner enables BYOK (user-supplied provider keys), the user's key and
prompts go to **the provider the user chose** — that is the user's own
instruction, and it is stated in the policy.

## 5. Play Console wording (copy-paste)

**Data collected:** Name; Email address; Phone number; User IDs; Other in-app
messages; Files and docs; Photos; Other user-generated content; App interactions
(optional); Web browsing history; Crash logs (optional); Diagnostics (optional);
Device or other IDs (push token).

**Not collected:** location, contacts, calendar, SMS, phone, health, audio,
photo-library access, in-app search history, ad ID, and purchase history (until
a subscription is live).

**Data shared:** none for advertising; service providers process data only to
run the requested feature. No sale of data.

**Security practices:** data encrypted in transit; users can request deletion;
the app is not directed at children.

**Data deletion:** users can delete individual chats in-app and delete the
whole account in-app (Settings → Delete account) and via the public deletion
page. Account deletion has a 24-hour grace period and can be cancelled by
signing in again during that window.

---

## 6. Owner checklist before submitting the form

- [ ] Confirm the public privacy-policy URL is live and matches §3–§4.
- [ ] Confirm the account-deletion URL is live (Play requires a web URL even
      when in-app deletion exists).
- [ ] Confirm the Data safety answers match the privacy policy word-for-word
      where they overlap.
- [ ] Answer **No** for Purchase history until the first Play subscription is
      live and verified in an internal-test purchase (see
      `REVENUECAT_SETUP.md`).
- [ ] Confirm the shipped speech recognizer's data path. Ovid never records or
      stores audio, but if the OS recognizer is cloud-backed, declare Audio and
      update the privacy policy.
- [ ] Do not declare certificate pinning until `kCertPinningEnabled` is true
      and `kOvidSpkiPins` is populated.
- [ ] If Crashlytics/Analytics consent defaults change, update §2 first.
- [ ] Confirm the 90-day crash retention in the Firebase console and the
      14-day backup rotation with the infrastructure owner; both are policy
      text today, not code.
- [ ] Re-run `flutter test test/play_distribution_test.dart` after any manifest
      change (it fails if the declared permission set drifts).
