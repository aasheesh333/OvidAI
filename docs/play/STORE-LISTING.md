# Ovid Si — Play Store listing copy (production)

- **Package:** `com.dhanuk.ovidai`
- **App name:** `Ovid Si`
- **Version this copy was verified against:** `1.0.0+3` (`pubspec.yaml`)
- **Prepared / verified:** 2026-10-22 from the shipped code (`lib/ui/v2/**`,
  `lib/core/**`, `android/app/src/main/AndroidManifest.xml`) and
  `docs/audit/FEATURE_GAPS.md`. No build was run.
- **Status:** READY TO PASTE. Nothing here is submitted automatically.
- **Supersedes:** `docs/play/LISTING.md` (an earlier draft that claims features
  the current build does not ship).

Character limits enforced by Play: title 30, short description 80, full
description 4,000, "What's new" 500.

---

## 1. Store identity

| Field | Value | Notes |
|---|---|---|
| **App name** | `Ovid Si` | 7 characters. The launcher label is `Ovid Si` (`AndroidManifest.xml`). Do not add model or company names. |
| **Store title (optional prefix)** | `Ovid Si: AI Assistant` | 21 / 30. Use this if the Console requires a descriptor; keep `Ovid Si` first. |
| **Short description** | `AI assistant for chat, images, browsing and long tasks.` | 61 / 80. See §2. |
| **Category** | **Productivity** | Closest Play category. The app is not a game, social app or health app. |
| **Tags** | `Personal assistant`, `Productivity`, `Business`, `Communication`, `Tools` | Play's fixed tag list; drop any tag the Console does not offer. |
| **Contact email** | `support@ovidsi.com` | Monitored; also the privacy contact in `docs/legal/PRIVACY.md`. |
| **Privacy policy URL** | `https://ovidsi.com/privacy` | Must return plain HTML over valid TLS before submission. |
| **Account deletion URL** | `https://ovidsi.com/delete-account` | Required by Play even though in-app deletion exists. |
| **Website** | `https://ovidsi.com` | Optional. Do not link a checkout or pricing page. |
| **Default language** | English (United States) | The UI is English-only today (`FEATURE_GAPS.md` C1). Do not list other languages. |
| **Contains ads** | **No** | No ad SDK, no Ad ID; the Play manifest removes `AD_ID`. |
| **In-app purchases** | **No for this build** | No Play subscription exists yet (`FEATURE_GAPS.md` D1/D2). Flip to Yes only after a subscription is live and verified. |

---

## 2. Short description (80 character limit)

```text
AI assistant for chat, images, browsing and long tasks.
```

**Count: 55 / 80 characters.**

Alternates, all under 80 and all supportable:

```text
Chat, make images and browse with an AI assistant.
```

```text
An AI assistant that keeps working on long tasks.
```

Do not use "super intelligent", "unlimited", "best", "fastest", "GPT", "Claude"
or "Gemini" in this field.

---

## 3. Full description (4,000 character limit)

```text
Ovid Si is an AI assistant for chat, images, browsing and long-running tasks. Sign in and ask in your own words.

CHAT THAT KEEPS WORKING
Ovid runs your request in the cloud, so a long task can keep going after you leave the app. It shows its steps and its results. If you send another message while it is working, the message waits in the queue; press Stop to send it next.

MEMORY AND PROJECTS
Each chat keeps its own memory. There is also a global memory and one memory for each project. Group related chats into projects and search across your own messages on the device.

IMAGES AND FILES
Attach a file or a photo through the system picker, or ask Ovid to generate an image. Results land in your library, where you can filter by source and type, then open or download them.

SCHEDULES
Run a task once, daily or weekly. Ovid shows the next run and the run history.

BROWSE WITH THE AGENT
Ovid opens pages in a cloud browser. Watch the page live and take control for clicks and typing when you need to.

GITHUB WORKSPACE
Connect GitHub, choose a repository and branch, and edit its files in a private cloud workspace.

CONNECT YOUR TOOLS
Add the connectors you already use. Ovid never installs a connector from a chat message.

SHARE OR WORK TOGETHER
Send a read-only link to a chat, or open a Collab room for up to 50 people. One person sends at a time, and the creator's plan pays for storage.

YOUR ACCOUNT
Sign in with Google or your phone number. You can delete a chat, export your data, and delete your account in Settings. Account deletion has a 24-hour grace period; signing in again during that window cancels it.

PRIVACY
No ads and no advertising ID. Crash reports and usage analytics are off unless you turn them on. Your chats and files are not used to train Ovid's own models. Read the privacy policy at https://ovidsi.com/privacy.

Ovid Si is for adults (18 and over). AI can make mistakes, so check important answers.

Not affiliated with Anthropic, [OI] or Google. Model and company names belong to their owners.
```

**Count: 2,032 / 4,000 characters** (including line breaks; verified with a
character count on the block above).

### Why the copy is shaped this way

- **Only shipped behaviour is described.** Deliberately absent:
  - the in-app **Report** action on replies, images and artifacts, and
    **Report/Block** in Collab. They exist in the legacy v1 chat, share and
    Collab screens (`lib/ui/chat_screen.dart` → `reportAiMessage`;
    `lib/ui/collab_session_screen.dart`) but the default **v2** shell
    (`V2AppShell`, `kOvidUiV1=false`) exposes only Copy, Branch and Regenerate
    on an answer, and v2 Collab has no Report/Block. Play's Generative-AI and
    UGC policies require in-app reporting, so this is a **release blocker**
    (`RELEASE-CHECKLIST.md` §0), not a listing choice. Re-add the Report line to
    the full description only after the v2 action ships;
  - live preview, diff/commit/push in Studio (`FEATURE_GAPS.md` A1–A3);
  - browser upload/download/history/close-tab from the viewer (`A10`);
  - a 50-subagent cap (the code has subagents, but no 50 cap to advertise);
  - reading or forking someone else's share link (`A14` is conditional on the
    share service being deployed);
  - prices, plans, storage allowances and purchase claims (no Play product
    exists — D1/D2);
  - a device terminal, Linux, "controls your phone", or on-device execution
    (removed from every build).
- **No superlatives and no rank claims.** "AI assistant" is the product
  category, not a performance claim.
- **18+ and safety lines are explicit.** Play requires the age statement for an
  app with unrestricted web access and user-to-user Collab.
- **The disclaimer is text only.** No third-party logos or provider names in
  the title, icon, screenshots or feature graphic.

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

**Count: 388 / 500 characters.**

Replace this block for later releases; do not append to it. Every bullet must
be a feature in the uploaded build.

---

## 5. Graphics and screenshots

| Asset | Requirement |
|---|---|
| **App icon** | 512 × 512 PNG, 32-bit, no transparency, no third-party logo. |
| **Feature graphic** | 1024 × 500 PNG/JPEG, no text smaller than legible at thumbnail size, no device frame required. |
| **Phone screenshots** | 2–8 images, 16:9 or 9:16, min 320 px, max 3840 px. Capture the **Play build** (`OVID_PLAY_BUILD=true`) with a clean test account. |

Suggested captures (only use screens that exist today):

1. Chat empty state — "What should we build today?"
2. A finished answer with its **Actions** menu visible (Copy, Branch, Regenerate).
3. Live chat with a running task and the Stop control.
4. Library with real generated images and the source/type filters.
5. Schedules list with a next-run line.
6. Cloud browser with "Take control" visible.
7. Collab room with the member count and the one-sender note.
8. Settings → Delete account, showing the 24-hour grace copy.

Do **not** use: paywall or price screens, diff/commit/live-preview screens,
browser upload/download controls, the old terminal/Linux surfaces, real
personal data, or third-party logos.

---

## 6. Content rating notes (IARC questionnaire)

**Target audience (separate Console declaration): 18+ only.** The app has
unrestricted web access, AI-generated output and user-to-user Collab. It is not
directed at children and does not opt in to the Play Families policy.

| IARC question | Answer | Why |
|---|---|---|
| **Category** | **Utility / Productivity** | Not a game. |
| Violence, blood, sexual violence | **No** | None built in. |
| Sexuality / nudity | **No** | None built in. |
| Profanity | **No** | None built in. |
| Controlled substances | **No** | None built in. |
| Gambling / simulated gambling | **No** | None built in. |
| Fear / horror | **No** | None built in. |
| **Users can interact or exchange content** | **Yes** | Collab rooms (up to 50) and read-only share links. |
| **User-generated content** | **Yes** | Chats, generated images, artifacts, shared chats, Collab messages. |
| **Users can share their location** | **No** | No location permission; no location is sent to Ovid. |
| **Digital purchases** | **No for this build** | No Play subscription exists yet. Change to Yes only when one is live. |
| **Unrestricted internet access** | **Yes** | The agent browser can open arbitrary pages. |
| **Advertising** | **No** | No ads, no Ad ID. |
| **Generative AI** | **Yes** | Core product. Play also requires in-app reporting; the v2 shell does not expose it yet (release blocker). |
| **Users can report objectionable content** | **No today (v2)** | The legacy v1 chat, share and Collab screens have Report actions; the default v2 shell exposes only Copy, Branch and Regenerate on an answer, and v2 Collab has no Report action (owner Remove and Leave exist). Do not submit until Report is wired. |
| **External purchase links** | **No** | No checkout or pricing link; Play Billing only when subscriptions ship. |

**Expected rating:** IARC decides, but expect roughly **Teen / PEGI 12** because
of unrestricted internet access and user interaction. Do not print a rating
badge in the listing before IARC returns one.

**Free-text moderation note for IARC (use only after the v2 Report action
ships):** "Ovid Si generates text and images. Every finished reply, image and
artifact has an in-app Report action. Reports go to a review queue with 180-day
retention. Ovid never installs a connector from chat. The browser and Collab
are available only to signed-in users aged 18+."

---

## 7. Data safety and privacy answers

The authoritative answer set is `docs/play/DATA-SAFETY.md`. The short version
for the Console form:

- Collects data: **Yes**.
- Encrypted in transit: **Yes** (remote hosts; cleartext is allowed only to
  localhost for local previews).
- Users can request deletion: **Yes** (in-app Settings → Delete account, plus
  `https://ovidsi.com/delete-account`).
- Independent security review: **No**.
- Families policy: **No** (18+).
- Ads / Ad ID: **No**.
- Purchase history: **No today** (no Play subscription exists).

---

## 8. App access (reviewer instructions)

All features require an account. In Play Console → **App content → App
access**, choose "All or some functionality is restricted" and provide **both**:

1. A reviewer Google account (email + password), or a Firebase **test phone
   number with a fixed OTP** configured in Firebase Authentication → Phone.
2. The exact steps: launch → sign in → send "Hello" → open the drawer →
   Settings → Delete account (do not confirm on the reviewer account unless the
   account is disposable).

Do not require the reviewer to receive an SMS on a real phone; use a Firebase
test number.

---

## 9. Claims ledger

| Claim in this file | Code evidence |
|---|---|
| Cloud execution; long tasks continue after leaving the app | `lib/core/distribution.dart` (`cloudExecution = true`); `lib/core/cloud/cloud_agent_facade.dart` |
| Queue while busy; Stop sends the queued message | `cloud_agent_facade.dart` (`_queues`, CH-023 persistence); composer Stop path |
| Per-chat, global and per-project memory | `lib/ui/v2/app/v2_app_shell.dart` (`_projectMemoryFiles`, "Global and project memory"); `lib/core/session_search.dart` for on-device search |
| Attach through the system picker; generate images; library filters | `lib/ui/v2/library/artifact_filters.dart`; image generation message kind (`MsgKind.imageGen`); no `READ_MEDIA_*` in the manifest |
| Schedules once/daily/weekly; next run and history | `lib/ui/v2/schedules/cadence_picker.dart` (`V2CadenceFrequency`); `schedule_client.dart` (`daily_at`, cron) |
| Cloud browser live view and takeover (clicks/typing) | `lib/ui/v2/browser/browser_live_page.dart`; viewer ops `browser_attach`/`browser_input`/`browser_takeover` |
| GitHub connect, repo/branch, edit files in a cloud workspace | `lib/ui/v2/app/v2_studio_routes.dart` (workspace + branch picker); `lib/core/cloud/studio_files.dart` |
| Connectors can be added; never installed from chat | `lib/ui/v2/connectors/add_connector_page.dart` (`'Ovid never installs connectors from chat.'`) |
| Read-only share link; Collab up to 50; one sender; creator pays storage | `server/collaboration/repository.py` (`MAX_ACTIVE_MEMBERS = 50`); `lib/ui/v2/share/share_sheet.dart` |
| Google/phone sign-in; delete chat; export data; delete account with 24 h grace | `lib/core/firebase_service.dart`; `server/account/domain.py` (`GRACE_SECONDS = 24 * 60 * 60`); `lib/ui/v2/settings/data_control_page.dart` |
| Analytics/crash off by default | `AndroidManifest.xml` (`firebase_*_collection_enabled=false`); `firebase_service.dart` (`_consentGiven`, persisted `ovid_telemetry_consent`) |
| Report flow exists in v1 only; server queue retains 180 days | `lib/ui/content_report_sheet.dart`; `lib/ui/chat_screen.dart:6114`; `server/reports/repository.py` (`retention_seconds=180 * 86400`). **Not reachable in the default v2 shell — release blocker.** |
| No ads / no Ad ID | `android/app/src/play/AndroidManifest.xml` (`AD_ID` removed); `google_analytics_adid_collection_enabled=false` |
| No location, contacts, calendar, SMS, phone, health, camera, photo-library permission | `AndroidManifest.xml` declares only `INTERNET`, `POST_NOTIFICATIONS`, `RECORD_AUDIO`; `test/play_distribution_test.dart` pins the set |
| 18+ only | `docs/legal/PRIVACY.md` ("18+"), `docs/play/PLAY_COMPLIANCE_AUDIT.md` §9 |
