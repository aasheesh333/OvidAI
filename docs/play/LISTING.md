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

UP TO 50 HELPERS IN ONE CHAT
Give a big job to one agent, then let it split the work. Up to 50 subagents can run in a single session. Each helper keeps a full log you can open, so you can see what it did. Helpers cannot start more helpers.

MEMORY THAT STAYS WITH THE WORK
Each chat writes and maintains its own memory file. There is also a global memory and one memory for each project. You can edit, export, or clear memory whenever you want.

EACH CHAT IS ISOLATED
Your chats do not run into each other. Type @ and pick another chat to let this one read or continue it. Nothing is shared with other people unless you choose to share it.

STUDIO: GITHUB IN THE CLOUD
Connect GitHub, pick a repository and branch, and Ovid copies it into a private cloud workspace. Ovid checks for newer changes before a task and shows a Sync chip when you are behind. Review the diff, commit, push, and open a live preview. Your GitHub token is never written into the repository config.

A BROWSER THAT WORKS WITH YOU
Ovid opens the page and you watch live. Take control for clicks, typing, uploads, and downloads.

MAKE SOMETHING
Create images, documents, code, and data, then find them in one library. Schedule a task to run once, daily, or weekly. Group related chats into projects and search across your work.

SHARE OR WORK TOGETHER
Send a read-only link, or open a Collab room for up to 50 people. One person sends at a time, and the creator pays for storage. A viewer of a read-only link can copy the chat into their own account.

CONNECT YOUR TOOLS
Add the services you already use. Free includes no custom connectors, Go includes 5, and Plus and Pro include 20. Ovid never installs a connector or plugin from a chat message.

YOUR ACCOUNT, YOUR CHOICE
Sign in with Google or your phone number. Delete your account in Settings. There is a 24-hour grace period, and signing back in restores it.

PLANS
Free — $0, 3 GB storage, Auto model only, 50M tokens per 24 hours and 1.5B per 30 days.
Go — $5 or ₹499, 5 GB storage, Auto model only.
Plus — $18 or ₹1,799, 15 GB storage, manual model choice.
Pro — $99 or ₹9,999, 75 GB storage, manual model choice.

Manual model choice is not available on Free or Go. The app shows your remaining tokens and storage at any time.

LIGHT AND DARK
Ovid follows your device theme. Light and dark are both fully supported.

Ovid Si is intended for adults (18 and over). Ovid Si can make mistakes. Check important answers. Use the Report button on a reply, image, or artifact that breaks the rules.

Not affiliated with Anthropic, [OI], or Google. Model and company names belong to their owners.
```

**Count:** 3,037 / 4,000 characters (including line breaks).

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

• One agent for chat, code, browsing, and creating
• Up to 50 helpers in a single chat, each with a full log
• A cloud Studio for GitHub repos, diffs, commits, and live preview
• Memory for each chat, each project, and your account
• Read-only sharing, or live Collab for up to 50 people
• Light and dark themes, plus account deletion in Settings
```

**Count:** 373 / 500 characters.

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
| 2 | **Up to 50 helpers. Every step in view.** | Live chat with a running subagent (`chat/live_chat_page.dart` + `runs/subagent_page.dart`) | Tool progress card, the helper name/status, "View full log", and the Stop control |
| 3 | **Your repo, in a cloud workspace.** | Studio workspace (`studio/studio_workspace_page.dart`) | Repo and branch chips, file tree, editor, and the Saved status |
| 4 | **Review every change before you push.** | Changes/diff (`studio/changes_page.dart`) | "3 changed · +48 −12", the diff, and Commit & push |
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
| **Does the app allow digital purchases?** | **Yes** | Go/Plus/Pro subscriptions through Google Play Billing. If billing is disabled in the submitted build, answer **No** and update this answer before enabling purchases. |
| **Does the app provide unrestricted access to the internet?** | **Yes** | The agent browser can open web pages. |
| **Does the app contain advertising?** | **No** | No ads and no ad ID. |
| **Does the app generate content using AI?** | **Yes** | The core product. Describe the in-app Report flow when IARC asks for safeguards. |
| **Does the app allow users to report objectionable content?** | **Yes** | Report on assistant replies, generated images and artifacts; Collab owners can remove members; members can leave. |
| **Does the app link to external purchase options?** | **No** | Play Billing only; no external checkout link. |
| **Does the app collect or share location?** | **No** | No location permission and no location data sent to Ovid. |

**Expected rating:** roughly **Teen / PEGI 12**, driven by unrestricted internet
access and user interaction. IARC makes the final decision; do not pre-print a
rating badge in the listing.

**Moderation note for the IARC free-text box:** "Ovid Si generates text and
images. Every finished reply, image and artifact has an in-app Report action.
Reports go to a review queue with 180-day retention. Ovid does not
install plugins or connectors from chat. The browser and Collab are available
only to signed-in users aged 18+."

---

## 7. Data safety answers

This is the answer set for Play Console → **App content → Data safety**. It is
derived from the product brief and the current schema/routes. The longer
worksheet remains `docs/play/DATA-SAFETY.md`; this section corrects the points
where that worksheet is stale (see §7.6).

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
| **Personal info → Name** | **Yes** (Google account display name) | No | Optional — only with Google sign-in | Account management; app functionality | Display name from Google sign-in; visible to people in a Collab room, and on a share link only when the user turns on "Show my name" |
| **Personal info → Email address** | **Yes** | No | Required if signing in with Google; phone is the alternative | Account management; app functionality | Google account email stored on the user row; deleted with the account |
| **Personal info → Phone number** | **Yes** | No | Optional — only if phone sign-in is used | Account management; fraud prevention and security | Firebase phone auth; not shown to other users |
| **Personal info → User IDs** | **Yes** | No | Required | Account management; app functionality; fraud prevention and security | Firebase UID, used for per-user workspace isolation and App Check |
| **Financial info → Purchase history** | **Yes** (when a paid plan is bought) | No | Required for paid plans | Account management; app functionality | Play Billing / RevenueCat entitlement, not card data |
| **Messages → Other in-app messages** | **Yes** | No | Required for chat (the core feature) | App functionality | Prompts, replies, tool events and memory; sent to the model provider only to produce the answer |
| **Files and docs** | **Yes** | No | Optional — only files the user attaches or Studio reads | App functionality | Attachments, generated images and artifacts, Studio workspace files in object storage |
| **Photos and videos → Photos** | **Yes** | No | Optional — only images the user attaches or Ovid generates | App functionality | Chosen through the system picker or created by Ovid; stored with the chat/artifact. No photo-library permission. |
| **App activity → Other user-generated content** | **Yes** | No | Optional — only for the features used | App functionality; safety | Projects, scheduled tasks, shared chats, Collab messages, reports |
| **App activity → In-app search history** | **Yes** | No | Optional — only when search is used | App functionality | Server-side chat search index; deleted with the chat/account |
| **App activity → App interactions** | **Yes** | No | Optional — analytics consent, default off | Analytics | Product events, only after consent |
| **Web browsing history** | **Yes** | No | Optional — only when the browser is used | App functionality | Pages Ovid opens and the live-view state; kept with the run/chat so the user can see what happened |
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
  archived; share snapshots 30 days; content reports 180 days; backups follow
  the documented window.
- **Children:** not directed at children; 18+ target audience; no age-gated
  content.

### 7.5 Play Console copy-paste

**Data collected:** Name; Email address; Phone number; User IDs; Purchase
history; Other in-app messages; Files and docs; Photos; Other user-generated
content; In-app search history; App interactions (optional); Web browsing
history; Crash logs (optional); Diagnostics (optional); Device or other IDs.

**Data shared:** None. Service providers process data only to run the feature
the user requested. No advertising, no sale.

**Security practices:** Data is encrypted in transit; users can request
deletion; the app is not directed at children.

**Deletion:** Users can delete individual chats in the app and delete the whole
account in Settings → Delete account, or use the public deletion page.

### 7.6 Consistency fixes required in `docs/play/DATA-SAFETY.md`

That worksheet was prepared before the v2/cloud migration. Before the owner
copies the Play form, it needs these corrections (this listing uses the brief
and current code):

1. **Deletion grace is 24 hours, not 7 days.** `server/account/domain.py`
   sets `GRACE_SECONDS = 24 * 60 * 60`; the brief says 24 hours. The worksheet
   still says "7-day grace".
2. **Add Phone number.** Phone sign-in is a supported path; the worksheet
   lacks the row.
3. **Add Web browsing history.** The cloud browser records the pages Ovid opens
   with the run; the old worksheet assumed an on-device browser.
4. **Declare Photos as well as Files and docs.** There is no photo-library
   permission: a chosen image is uploaded and stored like any other file. The
   old worksheet only had Files and docs; Play's Photos type covers an image
   the user attaches or Ovid generates.
5. **Purchase history depends on billing being live.** If the submitted build
   has billing disabled, answer No and flip it to Yes only when the Play
   subscriptions are purchasable.
6. **Audio depends on the recognizer.** The worksheet says on-device
   voice-to-text. If the shipped recognizer uses a cloud service, declare Audio
   and update the privacy policy.
7. **Analytics, crash logs and diagnostics stay "optional / default off"**
   until the consent defaults change.
8. **Name is declared from Google sign-in.** The worksheet says No, while the
   audit table says Yes. This listing declares it; remove the row only if the
   app truly never stores or transmits a display name.

---

## 8. Claims ledger (why we are allowed to say it)

| Listing claim | Source |
|---|---|
| Main agent plus up to 50 subagents per session; subagents cannot dispatch subagents | `V2_P3_BRIEF.md` product truth, lines 10–11 |
| Each session is isolated; `@` mentions another session; sharing is opt-in | Brief lines 12–13 |
| Per-session memory file, plus global and per-project memory | Brief lines 13–14 |
| Studio: connect GitHub, pick repo/branch, clone to cloud workspace; token never in `.git/config`; fetch/status before a task; Sync chip | Brief lines 15–19 |
| Browser: agent opens the page; live view; Take control for mouse/typing; upload/download | Brief lines 20–22 |
| Subagent full log; main agent can `@subagent_id`; 8 h max per subagent | Brief lines 23–26. The 8 h limit is intentionally **not** advertised. |
| Queue while the main agent works; Stop sends the queued message; dispatched subagents keep running | Brief lines 27–28 |
| Plan prices, storage, Auto-only vs manual, 50M / 1.5B Free allowance | Brief lines 29–32 |
| Manual models greyed out on Free/Go; custom connectors 0/5/20; Ovid never installs plugins/MCP from chat | Brief lines 31–33 |
| Share: read-only or Collab up to 50, one sender at a time, creator pays storage, viewer can fork | Brief lines 34–35 |
| Google or phone sign-in; delete account with 24 h grace and restore by signing in | Brief lines 36–37 |
| Theme follows the device; light and dark both first-class | Brief line 38 |
| "Create images, documents, code, and data"; library filters | `V2_SCREEN_SPECS.md` rows 34–35; `V2_WIRING_MAP.md` artifacts rows |
| Schedules: once/daily/weekly | `V2_SCREEN_SPECS.md` rows 36–38 |
| Projects and search | `V2_SCREEN_SPECS.md` rows 10–13 |
| Report button on replies, images and artifacts | `PLAY_COMPLIANCE_AUDIT.md` §5; Report flow |
| 18+ audience; no children | `PLAY_COMPLIANCE_AUDIT.md` §6 and §9 |
| "Not affiliated with Anthropic, [OI] or Google" | `PLAY_COMPLIANCE_AUDIT.md` §9 (metadata and impersonation) |
| "AI can make mistakes" and report guidance | `PLAY_COMPLIANCE_AUDIT.md` §5 and §13.4 |

### Claims we deliberately do **not** make

- No "unlimited tokens", "unlimited storage", "unlimited browsing" or
  "unlimited collaborators". The plans in the brief have explicit caps.
- No "always-on" background promise. Long tasks continue with a notification
  and a Stop action; that is the supportable wording.
- No "controls your phone", accessibility automation, Linux terminal or
  on-device code execution. Those are not in the Play build.
- No "super intelligent", "#1", "best", "fastest" or benchmark claim.
- No model-provider logo, company logo, or provider name in the title,
  screenshots or feature graphic. The disclaimer is text only.
- No claim that the browser is a general-purpose tabbed browser; the agent
  opens the page and the user can take control.
- No claim that sharing is private after the link is sent; the copy says
  "anyone with the link can view" in the share UI. The listing only says
  "read-only link".

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
- [ ] Data safety uses §7 and `docs/play/DATA-SAFETY.md` is corrected per §7.6.
- [ ] `https://ovidsi.com/privacy`, `/terms` and `/delete-account` return plain
      HTML with a valid certificate.
- [ ] `support@ovidsi.com` is monitored.
- [ ] App access instructions include a test phone number + OTP or reviewer
      Google account.
- [ ] Billing is either fully live (Play subscriptions created) or the
      purchase-history/digital-purchases answers are set to No for this build.
- [ ] No "unlimited" wording was introduced in a later edit.
