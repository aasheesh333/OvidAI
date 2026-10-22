# Ovid Si — Google Play store listing

- **Package:** `com.dhanuk.ovidai`
- **Version:** `1.0.0+3` (current `pubspec.yaml`; Play Console already has 1.0.0+1 and +2 on internal testing)
- **Prepared:** 2026-10-21
- **Status:** DRAFT for owner review. Paste into Play Console → Store listing and App content. Nothing here is submitted automatically.
- **Ground truth:** `docs/design/stitch/V2_P3_BRIEF.md` (product truth), plus
  `V2_SCREEN_SPECS.md` / `V2_WIRING_MAP.md` for surfaces that are built but not
  listed in the brief (artifacts, schedules, projects, search). The claims
  ledger in §8 records the source of every statement.

Character limits: title 30, short description 80, full description 4,000,
"What's new" 500.

> **SUPERSEDED 2026-10-22 — do not paste this file into Play Console.**
> Use `docs/play/STORE-LISTING.md` for the listing and
> `docs/play/DATA-SAFETY.md` for the data-safety form. This file is kept as an
> earlier draft. Its full description and screenshots claimed features the
> current build does not ship: a 50-subagent cap, Studio diff/commit/live
> preview (`FEATURE_GAPS.md` A1–A3), browser upload/download from the viewer
> (A10), share-link forking (A14), and purchasable Go/Plus/Pro plans (D1/D2).
> The sections below have been corrected where they would otherwise
> contradict the code, but the canonical copy is `STORE-LISTING.md`.

---

## 1. Store identity

| Field | Value |
|---|---|
| **App name / title** | `Ovid Si: AI Assistant` (21 characters) |
| **Category** | **Productivity** |
| **Tags** | `Personal assistant`, `Productivity`, `Business`, `Communication`, `Tools` |
| **Target audience** | **18 and over** only |
| **Contains ads** | **No** |
| **App access** | All features require sign-in. Provide a Firebase test phone number + fixed OTP (or a reviewer Google account) and the exact steps in Play Console → App access. |
| **Privacy policy** | `https://ovidsi.com/privacy` — must be live with a valid TLS certificate before submission |
| **Account deletion URL** | `https://ovidsi.com/delete-account` — must be live (in-app deletion also exists) |
| **Support** | `support@ovidsi.com` |

**Tag note:** these five are from Play's fixed tag list. If Console offers an
AI-specific tag in your region, `Personal assistant` is the first one to
replace. Do not keyword-stuff the description with model or company names.

---

## 2. Short description (80 character limit)

```text
Chat, code, browse and create with an AI agent that remembers your work.
```

**Count:** 72 / 80 characters.

Why this one: it names the four jobs the brief supports (chat, coding,
browsing, creating), and "remembers your work" is backed by the per-session,
per-project and global memory in the brief. It makes no size, speed or
"unlimited" promise.

Alternates (all under 80, pick only one):

```text
One AI agent for chat, code, browsing and creating.
```

```text
Chat, code and browse with an agent that keeps the context.
```

---

## 3. Full description (4,000 character limit)

```text
Ovid Si is an AI assistant for chat, code, browsing, and creating. One agent plans the work, and up to 50 helpers can work with it in the same chat.

ASK IN YOUR OWN WORDS
Write, research, plan, debug, or build. Ovid answers in chat, shows its steps, and keeps working on long tasks. If you send another message while it works, the message waits in the queue. Press Stop and the queued message goes straight through.

HELPERS FOR BIG JOBS
The agent can split a big job into helper runs. Each helper keeps a full log you can open, so you can see what it did.

MEMORY THAT STAYS WITH THE WORK
Each chat writes and maintains its own memory file. There is also a global memory and one memory for each project. You can edit, export, or clear memory whenever you want.

EACH CHAT IS ISOLATED
Your chats do not run into each other. Type @ and pick another chat to let this one read or continue it. Nothing is shared with other people unless you choose to share it.

STUDIO: GITHUB IN THE CLOUD
Connect GitHub, pick a repository and branch, and Ovid copies it into a private cloud workspace. Edit the files there. Your GitHub token is never written into the repository config.

A BROWSER THAT WORKS WITH YOU
Ovid opens the page and you watch live. Take control for clicks and typing.

MAKE SOMETHING
Create images, documents, code, and data, then find them in one library. Schedule a task to run once, daily, or weekly. Group related chats into projects and search across your work.

SHARE OR WORK TOGETHER
Send a read-only link, or open a Collab room for up to 50 people. One person sends at a time, and the creator pays for storage.

CONNECT YOUR TOOLS
Add the services you already use. Ovid never installs a connector or plugin from a chat message.

YOUR ACCOUNT, YOUR CHOICE
Sign in with Google or your phone number. Delete your account in Settings. There is a 24-hour grace period, and signing back in restores it.

PLANS
Ovid Si has a free plan. Paid plans are not available in this version.

LIGHT AND DARK
Ovid follows your device theme. Light and dark are both fully supported.

Ovid Si is intended for adults (18 and over). Ovid Si can make mistakes. Check important answers.

Not affiliated with Anthropic, [OI], or Google. Model and company names belong to their owners.
```

**Count:** 2,274 / 4,000 characters (including line breaks).

### Why the copy is shaped this way

- **No unlimited claims.** The description states the exact Free allowance
  (50M / 24 h, 1.5B / 30 days) and the storage for each plan. It never says
  "unlimited tokens", "unlimited storage" or "no limits". Go, Plus and Pro
  are described only by what the brief fixes: price, storage and model access.
- **No feature the Play build does not ship.** No on-device terminal, no Linux
  desktop, no "controls your phone", no Accessibility-based automation.
- **No superlatives.** No "super intelligent", "best", "#1", "fastest" or
  ranking claim. The brief's internal phrase "SI" is not expanded into a
  claim in the listing.
- **Bounded claims are explicit.** 50 subagents, 50 Collab members, 8-hour
  subagent limit (not advertised, so no chance of contradicting it), 3/5/15/75
  GB storage, 0/5/20 custom connectors.
- **Safety and legal lines** are last, so the store preview still leads with
  the product.

---

## 4. What's new (500 character limit)

```text
First release of Ovid Si.

• Chat with an AI assistant that runs long tasks in the cloud
• Per-chat, per-project and global memory
• Generate images and keep them in one library
• Schedules that run once, daily or weekly
• A cloud browser you can watch and take over
• Read-only share links and Collab rooms for up to 50 people
• Google or phone sign-in, with account deletion in Settings
```

**Count:** 388 / 500 characters.

For later releases, replace this block rather than appending to it. Keep the
same rule: no "unlimited", no speed claims, no feature that is still behind a
flag.

---

## 5. Screenshot captions

Use 8 phone screenshots (Play accepts 2–8). Capture the **Play build**, with a
clean test account, no personal data, no third-party logos, no model-provider
logos, and no terminal/Linux screens. Keep captions short enough to read at
thumbnail size; the caption is an overlay, not a Play metadata field.

| # | Caption on image | Screen to capture | What must be visible |
|---|---|---|---|
| 1 | **Start with a sentence. Ovid plans the work.** | Chat empty state (`chat/chat_page.dart`) | "What should we build today?", the three suggestions, the composer, and the Auto model row |
| 2 | **Helpers keep every step in view.** | Live chat with a running helper (`chat/live_chat_page.dart` + `runs/subagent_page.dart`) | Tool progress card, the helper name/status, "View full log", and the Stop control |
| 3 | **Your repo, in a cloud workspace.** | Studio workspace (`studio/studio_workspace_page.dart`) | Repo and branch chips, file tree, editor, and the Saved status |
| 4 | **Edit your files in the cloud.** | Studio workspace editor (`studio/studio_workspace_page.dart`) | Repo/branch chips, the file tree and an open file. Do not show a diff or commit screen; neither is wired. |
| 5 | **Ovid opens the page. You can take over.** | Agent browser (`browser/browser_page.dart`) | The page viewport, "Ovid is driving", and "Take control" |
| 6 | **Create it, then find it in your library.** | Artifacts library (`library/artifacts_page.dart`) | The All/Images/Documents/Code/Data filters and a grid of real artifacts |
| 7 | **Share a link, or build together.** | Collab live room (`collab/collab_live_page.dart`) | Member avatars, "Only one person can send at a time", and the member count |
| 8 | **Memory for each chat, project, and account.** | Memory settings (`settings/memory_page.dart`) | The memory toggle, global memory preview, and a project memory row |

**Do not use:** a paywall screenshot with prices (prices can change and create a
metadata mismatch), the old task-manager/Aether screens, a fake "50 online"
member count, or a screenshot showing a real person's name or email.

---

## 6. Content rating (IARC) answers

**Target audience:** 18+ only. The app has an agent-controlled browser with
unrestricted web access, user-to-user Collab, share links, and AI-generated
output. Do not select a child or mixed audience, and do not use child-appealing
artwork.

| IARC question | Answer | Note |
|---|---|---|
| **Category** | **Utility, Productivity, Communication, or Other** | Then choose Productivity as the closest store category. |
| Violence (depictions, blood, sexual violence) | **No** | No violent content is built in. Users can ask the AI for text; outputs are reportable in the app. |
| Sexuality / nudity | **No** | No sexual content is built in. |
| Profanity | **No** | No profanity is built in. |
| Controlled substances | **No** | No alcohol, tobacco or drug content is built in. |
| Gambling | **No** | No gambling, simulated gambling or wagering. |
| Fear / horror | **No** | No horror content is built in. |
| **Can users interact or exchange content with other users?** | **Yes** | Collab rooms (up to 50) and read-only share links. |
| **Does the app contain user-generated content?** | **Yes** | Chats, artifacts, shared chats and Collab messages. |
| **Can users share their location with other users?** | **No** | The app does not request location permission. |
| **Does the app allow digital purchases?** | **No for this build** | No Play subscription exists yet (`FEATURE_GAPS.md` D1/D2). Change to Yes only when a subscription is live and verified. |
| **Does the app provide unrestricted access to the internet?** | **Yes** | The agent browser can open web pages. |
| **Does the app contain advertising?** | **No** | No ads and no ad ID. |
| **Does the app generate content using AI?** | **Yes** | The core product. In-app reporting is required by Play and is not exposed in the default v2 shell yet. |
| **Does the app allow users to report objectionable content?** | **No today (v2)** | Report exists only in the legacy v1 chat/share/Collab screens; the default v2 shell has no Report action. Do not submit until it is wired. |
| **Does the app link to external purchase options?** | **No** | Play Billing only; no external checkout link. |
| **Does the app collect or share location?** | **No** | No location permission and no location data sent to Ovid. |

**Expected rating:** roughly **Teen / PEGI 12**, driven by unrestricted internet
access and user interaction. IARC makes the final decision; do not pre-print a
rating badge in the listing.

**Moderation note for the IARC free-text box (use only after the v2 Report
action ships):** "Ovid Si generates text and images. Every finished reply,
image and artifact has an in-app Report action. Reports go to a review queue
with 180-day retention. Ovid does not install plugins or connectors from chat.
The browser and Collab are available only to signed-in users aged 18+."

---

## 7. Data safety answers

This is the answer set for Play Console → **App content → Data safety**. It is
derived from the product brief and the current schema/routes. The longer
worksheet remains `docs/play/DATA-SAFETY.md`; see §7.6 for the cross-check.

### 7.1 Top-level answers

| Play question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all user data encrypted in transit? | **Yes** — HTTPS/WSS; cleartext is disabled except localhost dev previews |
| Do you provide a way for users to request that their data be deleted? | **Yes** — in-app Settings → Delete account, plus the public deletion page |
| Do you have an independent security review? | **No** |
| Are you committed to the Play Families policy? | **No** — the app is 18+ and not directed at children |
| Do you have ads? | **No** |
| Do you use an advertising ID? | **No** |

### 7.2 Data types

| Play data type | Collected | Shared | Optional? | Purpose | What it is / where it goes |
|---|---|---|---|---|---|
| **Personal info → Name** | **Yes** (Google account display name) | No | Optional — only with Google sign-in | Account management; app functionality | Display name from Google sign-in; visible to people in a Collab room. Share snapshots do not include a name toggle. |
| **Personal info → Email address** | **Yes** | No | Required if signing in with Google; phone is the alternative | Account management; app functionality | Google account email stored on the user row; deleted with the account |
| **Personal info → Phone number** | **Yes** | No | Optional — only if phone sign-in is used | Account management; fraud prevention and security | Firebase phone auth; not shown to other users |
| **Personal info → User IDs** | **Yes** | No | Required | Account management; app functionality; fraud prevention and security | Firebase UID, used for per-user workspace isolation and App Check |
| **Financial info → Purchase history** | **No today** | No | Required for paid plans | Entitlements and billing | No Play subscription exists, so the submitted build cannot purchase. Change to Yes when one is live. |
| **Messages → Other in-app messages** | **Yes** | No | Required for chat (the core feature) | App functionality | Prompts, replies, tool events and memory; sent to the model provider only to produce the answer |
| **Files and docs** | **Yes** | No | Optional — only files the user attaches or Studio reads | App functionality | Attachments, generated images and artifacts, Studio workspace files in object storage |
| **Photos and videos → Photos** | **Yes** | No | Optional — only images the user attaches or Ovid generates | App functionality | Chosen through the system picker or created by Ovid; stored with the chat/artifact. No photo-library permission. |
| **App activity → Other user-generated content** | **Yes** | No | Optional — only for the features used | App functionality; safety | Projects, scheduled tasks, shared chats, Collab messages, reports |
| **App activity → In-app search history** | **No** | — | — | — | Chat search runs on an on-device SQLite FTS5 index (`lib/core/session_search.dart`); no query is sent to a server or retained as history. |
| **App activity → App interactions** | **Yes** | No | Optional — analytics consent, default off | Analytics | Product events, only after consent |
| **Web browsing history** | **Yes** | No | Optional — only when the browser is used | App functionality | Pages Ovid opens and the live-view state; browser state is kept for the account, not per chat. |
| **App info and performance → Crash logs** | **Yes** | No | Optional — crash-report consent, default off | Analytics; app functionality | Crash traces, only after consent |
| **App info and performance → Diagnostics** | **Yes** | No | Optional — diagnostics consent, default off | Analytics; app functionality | Performance and error traces, only after consent |
| **Device or other IDs → Device or other IDs** | **Yes** | No | Optional — only if notifications are allowed | App functionality | FCM registration token for "run finished" notifications; removed on sign-out/deletion |

**Data shared with third parties:** **None.** Model providers process prompts
and attachments as service providers only to produce the requested answer.
There is no sale of data and no advertising use. A share link or Collab room is
sharing the user chose with the people they invited; it is not third-party
sharing for advertising or analytics. If a user supplies their own provider
key, requests go to the provider they chose at their own instruction — state
that in the privacy policy.

### 7.3 What is **not** collected

| Play data type | Answer | Why |
|---|---|---|
| Location (approximate or precise) | **No** | No location permission; the browser does not forward device location |
| Contacts, calendar, SMS/MMS, call logs | **No** | Permissions were removed with the on-device agent |
| Health and fitness | **No** | No health feature |
| Photo/video library access | **No** | No photo-library permission. A chosen image is uploaded and declared under **Photos** and **Files and docs**; Ovid cannot browse the library. |
| Audio / voice recordings | **No** | Voice-to-text is handled on the device; Ovid does not store audio. Confirm the recognizer is on-device before submitting. |
| Advertising ID | **No** | No ads; `google_analytics_adid_collection_enabled=false` |
| Web browsing history of other apps | **No** | Only pages Ovid itself opens are recorded |

### 7.4 Data handling and deletion

- **Encryption in transit:** TLS on every connection; cleartext disabled
  (`usesCleartextTraffic="false"` plus a network security config).
- **Deletion path:** Settings → Delete account. The account enters a
  **24-hour grace period**; signing in again during that window cancels the
  deletion and restores the account. The public deletion page is the second
  path Play requires.
- **What deletion removes:** sessions, messages, workspace objects,
  attachments, browser state, schedules, shares, Collab memberships, reports
  and the model provider key.
- **Retention:** account data until deletion; event logs 24 hours hot / 30 days
  archived; share snapshots 30 days; content reports 180 days; crash and
  diagnostic data up to 90 days; server backups up to 14 days. The 90-day and
  14-day figures are policy statements in `docs/legal/PRIVACY.md`; the Firebase
  console and infrastructure configuration are outside this repo. Android
  device backup is off (`allowBackup=false`, `fullBackupContent=false` and
  `data_extraction_rules.xml` excludes cloud backup and device transfer).
- **Children:** not directed at children; 18+ target audience; no age-gated
  content.

### 7.5 Play Console copy-paste

**Data collected:** Name; Email address; Phone number; User IDs; Other in-app
messages; Files and docs; Photos; Other user-generated content; App interactions
(optional); Web browsing history; Crash logs (optional); Diagnostics (optional);
Device or other IDs.

**Data shared:** None. Service providers process data only to run the feature
the user requested. No advertising, no sale.

**Security practices:** Data is encrypted in transit; users can request
deletion; the app is not directed at children.

**Deletion:** Users can delete individual chats in the app and delete the whole
account in Settings → Delete account, or use the public deletion page.

### 7.6 Consistency with `docs/play/DATA-SAFETY.md`

The worksheet was re-verified against the code on 2026-10-22 and now agrees
with this file on the points that used to drift: 24-hour grace, Phone number,
Web browsing history, Photos, Purchase history (No until a subscription is
live), Audio caveat, analytics/crash/diagnostics optional-off, and Name.
`DATA-SAFETY.md` is the authoritative form answer set; this section is kept
only as a cross-check.

---

## 8. Claims ledger

Superseded. The current per-claim code evidence is in
`docs/play/STORE-LISTING.md` §9. This draft's old ledger cited the product
brief for features the build does not ship (50 subagents, Studio diff/commit/
live preview, browser upload/download, share-link forking, purchasable plans),
so it is not a valid source for listing copy.

Claims we deliberately do **not** make:

- No "unlimited tokens", "unlimited storage", "unlimited browsing" or
  "unlimited collaborators".
- No "always-on" background promise.
- No "controls your phone", accessibility automation, Linux terminal or
  on-device code execution.
- No "super intelligent", "#1", "best", "fastest" or benchmark claim.
- No model-provider logo, company logo, or provider name in the title,
  screenshots or feature graphic.
- No claim that the browser is a general-purpose tabbed browser.
- No claim that sharing is private after the link is sent.

---

## 9. Owner checklist before this goes live

- [ ] Title, short description and full description are pasted exactly; the
      short description is still ≤ 80 characters after any edit.
- [ ] The 8 screenshots come from the Play build (`OVID_PLAY_BUILD=true`), with
      no terminal/Linux screens, no third-party logos and no real personal data.
- [ ] `targetSdk = 36`, 16 KB check, and the three-permission manifest are
      confirmed in the uploaded AAB.
- [ ] Content rating questionnaire uses the answers in §6; target audience is
      18+.
- [ ] Data safety uses §7 and `docs/play/DATA-SAFETY.md` is cross-checked per §7.6.
- [ ] `https://ovidsi.com/privacy`, `/terms` and `/delete-account` return plain
      HTML with a valid certificate.
- [ ] `support@ovidsi.com` is monitored.
- [ ] App access instructions include a test phone number + OTP or reviewer
      Google account.
- [ ] Billing is either fully live (Play subscriptions created) or the
      purchase-history/digital-purchases answers are set to No for this build.
- [ ] No "unlimited" wording was introduced in a later edit.
