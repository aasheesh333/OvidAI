# Google Play — Data Safety declaration (owner-facing worksheet)

- **Package:** `com.dhanuk.ovidai`
- **App version:** the first Ovid Cloud (thin-client) release
- **Prepared:** 2026-10-18, from the shipped code and the production schema
  (`cloud/packages/db/src/schema.ts`, `cloud/apps/gateway/src/routes/*`,
  `lib/core/**`)
- **Status:** WORKSHEET. The Play Console form is filled by the owner (R4).
  Nothing here is submitted automatically.

This is the answer set for Play Console → **App content → Data safety**. Every
row is derived from a real table/route; if a feature is removed later, the row
must be removed with it. The Generative-AI and UGC answers live in
`PLAY_COMPLIANCE_AUDIT.md` §5–§6.

---

## 1. Does your app collect or share any of the required user data types?

**Yes.** The app is an account-based AI assistant: without an account it cannot
run a prompt, because model execution happens on Ovid's servers.

## 2. Data types

| Play category | Collected? | Shared with third parties? | Purpose | Optional? | Encrypted in transit? | Deletable? |
|---|---|---|---|---|---|---|
| **Personal info → Email address** | Yes | No (see §4) | Account creation, sign-in, support | Required (account) | Yes (TLS) | Yes — in-app deletion + `/account/deletion` |
| **Personal info → User IDs** | Yes | No | Account identity, per-user sandbox/workspace isolation | Required | Yes | Yes |
| **Personal info → Name** | No (only what the user types into a prompt) | No | — | — | — | — |
| **Messages → Other in-app messages** (chat transcripts, prompts, model replies) | Yes | No (sent only to the model provider, see §4) | The core feature: running the assistant | Required for the feature | Yes | Yes — delete a chat or the account |
| **Files and docs** (attachments, generated images, Studio workspace files) | Yes | No | The user's own work; stored in Ovid's object storage | Optional (only if attached) | Yes | Yes |
| **App activity → Other user-generated content** (tool calls, plans, schedules the user creates) | Yes | No | Running the agent and showing history | Required for the feature | Yes | Yes |
| **App activity → In-app search history** | Yes (chat search index, server-side) | No | Finding past chats | Optional | Yes | Yes |
| **App info and performance → Crash logs** | Yes, **only after consent** | No | Diagnosing crashes | Optional (consent toggle, default off) | Yes | On request / retention window |
| **App info and performance → Diagnostics** (performance, error traces) | Yes, only after consent | No | Reliability | Optional (default off) | Yes | On request |
| **Device or other IDs → Device or other IDs** (FCM registration token) | Yes | No | Push notifications for finished runs | Optional (notifications can be denied) | Yes | On sign-out / deletion |
| **Financial info → Purchase history** | Yes (Play purchases; token verified server-side) | No | Entitlements and billing | Required for paid plans | Yes | Per Play policy |
| **Location** | **No** | — | — | — | — | — |
| **Contacts / Calendar / SMS / Phone / Health** | **No** | — | — | — | — | — |
| **Photos and videos (library access)** | **No** — files are chosen through the system picker and only the chosen file is uploaded | — | — | — | — | — |
| **Audio (voice input)** | **Processed on the device**, not collected by the server | — | Voice-to-text | Optional (mic permission) | — | — |
| **Advertising / Ad ID** | **No** — no ads, and `google_analytics_adid_collection_enabled=false` | — | — | — | — | — |

### 2.1 What the manifest declares today

`android/app/src/main/AndroidManifest.xml` declares exactly **three**
permissions: `INTERNET`, `POST_NOTIFICATIONS`, `RECORD_AUDIO`. Every broad
permission the old on-device agent needed (contacts, calendar, SMS, phone,
location, camera, all-files access, battery exemption) was removed with that
agent; `test/play_distribution_test.dart` parses the manifest and fails if any
of them returns.

## 3. Data handling

- **Encrypted in transit:** yes — HTTPS/WSS everywhere; cleartext is disabled
  (`usesCleartextTraffic="false"` + a network security config). The gateway is
  fronted by Cloudflare with a pinned TLS certificate on the client.
- **Data deletion request:** in-app **Settings → Delete account**, which starts
  the server-side deletion lifecycle (7-day grace, cancellable), plus the
  public deletion page. The lifecycle removes: sessions, messages, workspace
  objects (R2 prefix), attachments, browser state, BYOK keys, schedules,
  shares/reports, and the LiteLLM key.
- **Data retention:** account data lives until deletion; event logs keep
  24 hours hot and 30 days archived (founder decision 2026-10-18); backups
  follow the documented retention window.
- **Children:** the app is not directed at children; no age-gated content.

## 4. Third parties

Ovid runs the models through its own gateway (LiteLLM) and a model provider.
Prompts and replies are transmitted to the model provider **to produce the
answer** — Play treats that as service-provider processing, not "sharing for
advertising". No data is sold. The full list is maintained in the privacy
policy (`docs/play/` → the public policy page).

If the owner enables BYOK (user-supplied provider keys), the user's key and
prompts go to **the provider the user chose** — that is the user's own
instruction, and it must be stated in the policy.

## 5. Play Console wording (copy-paste)

**Data collected:** Email address; User IDs; Other in-app messages; Files and
docs; Other user-generated content; In-app search history; Crash logs
(optional); Diagnostics (optional); Device or other IDs (push token); Purchase
history.

**Data shared:** none for advertising; service providers process data only to
run the requested feature.

**Security practices:** data encrypted in transit; users can request deletion;
the app follows the Play Families policy (not directed at children).

**Data deletion:** users can delete individual chats in-app and delete the
whole account in-app (Settings → Delete account) and via the public deletion
page.

---

## 6. Owner checklist before submitting the form

- [ ] Confirm the public privacy-policy URL is live and matches §3–§4.
- [ ] Confirm the account-deletion URL is live (Play requires a web URL even
      when in-app deletion exists).
- [ ] Confirm the Data safety answers match the privacy policy word-for-word
      where they overlap.
- [ ] If Crashlytics/Analytics consent defaults change, update §2 first.
- [ ] Re-run `flutter test test/play_distribution_test.dart` after any
      manifest change (it fails if the declared permission set drifts).
