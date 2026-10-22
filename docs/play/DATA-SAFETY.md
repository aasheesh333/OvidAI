# Google Play — Data Safety declaration (owner-facing worksheet)

- **Package:** `com.dhanuk.ovidai`
- **App version:** the first Ovid Cloud (thin-client) release
- **Prepared:** 2026-10-18, from the shipped code and the production schema
  (`cloud/packages/db/src/schema.ts`, `cloud/apps/gateway/src/routes/*`,
  `lib/core/**`). **Revised 2026-10-22** against `server/account/domain.py`,
  the Android manifest and the current client.
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
| **Files and docs** (attachments, generated images, Studio workspace files) | Yes | No | The user's own work; stored in Ovid's object storage | Optional (only if attached) | Yes | Yes |
| **Photos and videos → Photos** (an image the user attaches, or one Ovid generates) | Yes | No | The user's own work; stored with the chat/artifact | Optional | Yes | Yes |
| **App activity → Other user-generated content** (tool calls, plans, schedules the user creates) | Yes | No | Running the agent and showing history | Required for the feature | Yes | Yes |
| **App activity → In-app search history** | Yes (chat search index, server-side) | No | Finding past chats | Optional | Yes | Yes |
| **App activity → App interactions** (product events) | Yes, **only after consent** | No | Reliability and product analytics | Optional (consent toggle, default off) | Yes | On request / retention window |
| **Web browsing history** (pages the agent opens in the cloud browser) | Yes | No | The browser feature: showing what the agent did | Optional — only when the browser is used | Yes | Yes — delete the chat or the account |
| **App info and performance → Crash logs** | Yes, **only after consent** | No | Diagnosing crashes | Optional (consent toggle, default off) | Yes | On request / up to 90 days |
| **App info and performance → Diagnostics** (performance, error traces) | Yes, only after consent | No | Reliability | Optional (default off) | Yes | On request / up to 90 days |
| **Device or other IDs → Device or other IDs** (FCM registration token) | Yes | No | Push notifications for finished runs | Optional (notifications can be denied) | Yes | On sign-out / deletion |
| **Financial info → Purchase history** | Yes when paid plans are purchasable (Play purchases; token verified server-side) | No | Entitlements and billing | Required for paid plans | Yes | Per Play policy (tax/accounting records are retained) |
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
agent; `test/play_distribution_test.dart` parses the manifest and fails if any
of them returns.

The `RECORD_AUDIO` permission is used only by the speech recognizer
(`speech_to_text`). Ovid never records or uploads audio.

## 3. Data handling

- **Encrypted in transit:** yes — HTTPS/WSS everywhere; cleartext is disabled
  (`usesCleartextTraffic="false"` + a network security config). The gateway is
  fronted by Cloudflare. Certificate pinning is implemented
  (`lib/core/cert_pinning.dart`) but **ships disabled** (`kCertPinningEnabled =
  false`, empty pin set) until the owner supplies the real SPKI pins, so it is
  not a security practice to declare yet.
- **Data deletion request:** in-app **Settings → Delete account**, which starts
  the server-side deletion lifecycle (**24-hour grace, cancellable**; the
  deadline is `GRACE_SECONDS = 24 * 60 * 60` in
  `server/account/domain.py`), plus the public deletion page. Signing in again
  during the grace window cancels the deletion. The lifecycle removes:
  sessions, messages, workspace objects (R2 prefix), attachments, browser
  state, BYOK keys, schedules, devices/push tokens, shares/reports, plugins and
  add-ons, and the LiteLLM key.
- **Data retention:** account data lives until deletion, plus the 24-hour grace.
  Live run events keep 24 hours hot and up to 30 days archived (founder
  decision 2026-10-18); share snapshots 30 days; content reports 180 days;
  crash/diagnostic data up to 90 days; backups rotate out after 14 days.
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
messages; Files and docs; Photos; Other user-generated content; In-app search
history; App interactions (optional); Web browsing history; Crash logs
(optional); Diagnostics (optional); Device or other IDs (push token); Purchase
history (when billing is live).

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
- [ ] Confirm whether the submitted build can actually purchase a plan; if
      billing is disabled, answer **No** for Purchase history until it is live.
- [ ] Confirm the shipped speech recognizer's data path. Ovid never records or
      stores audio, but if the OS recognizer is cloud-backed, declare Audio and
      update the privacy policy.
- [ ] Do not declare certificate pinning until `kCertPinningEnabled` is true
      and the pin set is populated.
- [ ] If Crashlytics/Analytics consent defaults change, update §2 first.
- [ ] Re-run `flutter test test/play_distribution_test.dart` after any
      manifest change (it fails if the declared permission set drifts).
