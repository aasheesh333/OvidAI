# Ovid Si: Google Play pre-launch compliance audit

> **STATUS 2026-10-22 — historical audit, not the release runbook.**
> The code has moved on since 2026-10-11. Several findings below are fixed and
> several instructions are stale: every build now targets API 36 (there is no
> target-28 sideload profile), the Play overlay removes the broad permissions,
> the foreground-service/`dataSync` path and the on-device sandbox are gone,
> the Report flow exists but is wired only in the legacy v1 chat screen (the
> default v2 shell still needs it — a release blocker), and Play Billing +
> RevenueCat exist (but no Play subscription has been created yet). For the
> current answers use `DATA-SAFETY.md`; for the listing use
> `STORE-LISTING.md`; for the ordered release steps use
> `RELEASE-CHECKLIST.md`. Keep this file for policy rationale and the IARC/AI/
> UGC reasoning, not for build commands.

- Date: 2026-10-11. Policies were re-checked that day on support.google.com and developer.android.com.
- Package: `com.dhanuk.ovidai`. The app is not on Play yet; this is the first submission.
- Code audited: `integration/production-hardening` @ `cdd8fb9`, the most complete merge. Also read: `feat/session-link-collab` (share/collab), `release/play-policy-blockers` (PR-1b) and `feat/play-billing-usage` (PR-8).
- Fixes live on `release/play-compliance`, which is based on `hoplite/gortyn-77773150`. It merges with no conflicts into integration, collab, PR-1b and PR-8 (checked with `git merge-tree`). The merge with integration was also checked: `flutter analyze` is clean and the new tests pass.

Unless marked otherwise, line numbers point to the integration worktree.

---

## 0. Overall verdict

**The current integration build cannot be submitted.** Play rejects it at upload, before any human review, because it targets API 28.

**With `release/play-compliance` merged and the owner actions in §13 done, a single-pass review is realistic** for a reduced Play scope:
- chat with BYOK and Ovid Cloud models
- the browser
- image generation
- share links and Collab

That scope excludes:
- Control mode
- the on-device Linux terminal and Studio shell
- stdio MCP servers and plugin hooks

These excluded features cannot be made Play-compliant in their current form. No disclosure wording fixes them.

### Hard blockers

| # | Blocker | Status |
|---|---|---|
| B1 | `targetSdk = 28`. Play has required API 36 for new apps since 2026-08-31. | **Fixed in code.** The Play build profile targets 36. CI must pass the define (§13.1). |
| B2 | The on-device sandbox execs downloaded Termux binaries. This is impossible at target ≥ 29 and violates Device and Network Abuse. | **Fixed in code.** The Play build ships no payload and refuses the sandbox. |
| B3 | Control mode drives other apps through an AccessibilityService. Play now bans the Accessibility API for apps that "autonomously initiate, plan, and execute actions". | **Fixed in code.** The service and Control mode are removed from the Play build. |
| B4 | Restricted or unjustified permissions: SEND_SMS, MANAGE_EXTERNAL_STORAGE, READ_MEDIA_IMAGES/VIDEO, BODY_SENSORS, and others. | **Fixed in code.** The Play manifest overlay removes them. |
| B5 | No in-app reporting of AI output (Generative AI policy). | **Fixed in code.** Report button, sheet and service, plus a `server/reports` queue. The server must be deployed (§13.2). |
| B6 | UGC (share links and Collab) has no report or block flow. | **Partly fixed.** The report sheet is ready. Wiring into the share and collab screens goes in after the collab merge (§6). The owner already has "Remove". |
| B7 | `https://ovidsi.com/*` fails the TLS handshake. Privacy policy, terms, deletion page and `assetlinks.json` are all unreachable. | **Owner action.** |
| B8 | The app can't be used without signing in, so Play reviewers need access instructions. | **Owner action** (App access, §13.3). |

---

## 1. Target SDK, 16 KB pages, App Signing, AAB

**Verdict:** Blocker, now fixed in code, plus owner actions for CI and signing.

### Policy

- Target API: [answer/11926878](https://support.google.com/googleplay/android-developer/answer/11926878) and [target-sdk](https://developer.android.com/google/play/requirements/target-sdk).
  - "Starting August 31, 2026: New apps and app updates must target Android 16 (API level 36) or higher."
  - An extension to 2026-11-01 can only be requested for existing apps. A new app gets no grace period.
- 16 KB pages: [page-sizes](https://developer.android.com/guide/practices/page-sizes).
  - "All apps targeting Android 15 (API level 35) and higher must support 16 KB memory page sizes on 64-bit devices."
  - Updates that don't support 16 KB are blocked from 2027-02-01.

### Evidence

- `android/app/build.gradle.kts:119` sets `targetSdk = 28` on purpose. `:121-127` turns off the `ExpiredTargetSdkVersion` lint.
- The comment at `:111-118` explains why: the sandbox execs from the app's files directory.
- The app also runs on target-28 legacy behaviour everywhere else: storage, FGS, notifications and package visibility are untested at a modern target.

### Fix

Done: `79f8eb9`. One switch, `--dart-define=OVID_PLAY_BUILD=true`, controls both sides. Gradle decodes Flutter's forwarded `dart-defines`, so the Dart gates and native packaging always match.

In a Play build:
- `targetSdk = 36`. Sideload builds stay on 28.
- `libovid_bootstrap.so` is excluded from packaging.
- `src/play/AndroidManifest.xml` is merged on top (§2).

Verified with `./gradlew :app:processDebugMainManifest`:
- Play define: merged `targetSdkVersion="36"`, no AccessibilityService, 16 permissions (including library permissions).
- No define: `targetSdkVersion="28"`, unchanged, 36 permissions.

### Behaviour changes when moving 28 → 36, as they apply to the Play build

| Android change | Impact | Status |
|---|---|---|
| 10: W^X, no exec from app data | Sandbox | Sandbox is off in the Play build (§4). |
| 11: scoped storage, package visibility | Working-folder picker; `url_launcher` | PR-1b already reports unwritable folders and no longer asks for All Files Access (`chat_screen.dart:8710`). `<queries>` is present (`AndroidManifest.xml:187-228`). Expect most shared-storage folders to be read-only. |
| 12: exported flag, PendingIntent mutability, FGS start from background | Receivers and notifications | All components declare `exported`. Every PendingIntent uses `FLAG_IMMUTABLE`. `FGS_BACKGROUND_DENIED` is handled (`MainActivity.kt:718`). |
| 13: POST_NOTIFICATIONS | Agent notification | The prompt is lazy (`agent_notification_service.dart:303`). |
| 14: FGS type required; implicit intents; `registerReceiver` flags | AgentForegroundService | The type is declared. Plugins use `ContextCompat.registerReceiver`. |
| 15: 6-hour cap on dataSync with `onTimeout`; edge-to-edge enforced | FGS; layout | `onTimeout` was added and stops the service (`AgentForegroundService.kt`). Flutter 3.47 handles edge-to-edge. Check insets in the pre-launch screenshots. |
| 16: predictive back on by default; large-screen orientation lock ignored | Navigation | No `onBackPressed` overrides. The app uses `PopScope`. |
| Exact alarms | Schedules | Uses inexact `setAndAllowWhileIdle` (`ScheduleAlarmReceiver.kt:79`). No exact-alarm permission. **Pass.** |

### 16 KB

- The 158 findings in `docs/superpowers/audits/2026-10-06-release-inventory-triage.md` are all `GNU_RELRO end` remainders, with zero PT_LOAD failures. 153 of them are inside the bootstrap ZIP, which the Play build no longer ships.
- Play's published check is LOAD-segment alignment, so the remaining outer libraries (`libflutter.so`, `libsqlite3.so`) are expected to pass.
- Owner action: after the first AAB upload, read the Play Console "App bundle explorer → 16 KB" result. `tool/release_inventory.py --mode production` is stricter than Play (it also checks RELRO end). It may need a Play-specific allowance for those two libraries.

### Play App Signing and AAB

- Upload an AAB (`flutter build appbundle`) and enrol in Play App Signing, which is the default for new apps.
- The keystore in `keystore.properties` becomes the **upload key**.
- Then register the **Play app-signing certificate SHA-256** (Play Console → App integrity) in all of these:
  - Firebase (Auth / Google Sign-In OAuth client, App Check)
  - `OVID_ANDROID_RELEASE_CERT_SHA256`, which feeds `assetlinks.json` (`server/shares/api.py:76-89`). That code emits only one fingerprint, so use the Play key.

---

## 2. Permissions in the merged manifest

**Verdict:** Blocker, now fixed in code.

### Policy

- Permissions policy: [answer/9888170](https://support.google.com/googleplay/android-developer/answer/9888170)
- All files access: [answer/10467955](https://support.google.com/googleplay/android-developer/answer/10467955)
- Photo and video permissions: [answer/14115180](https://support.google.com/googleplay/android-developer/answer/14115180)
- SMS / Call Log: [answer/10208820](https://support.google.com/googleplay/android-developer/answer/10208820)
- FGS types: [answer/13392821](https://support.google.com/googleplay/android-developer/answer/13392821)
- Advertising ID: [answer/6048248](https://support.google.com/googleplay/android-developer/answer/6048248)

### Evidence

> **UPDATE 2026-10-18 (P8 cloud migration).** This section describes the
> pre-migration manifest (29 declared permissions, with the Play overlay
> removing the risky ones). The migration deleted every on-device capability
> that needed them — the Linux sandbox and device control (P8 T13), the
> background agent (T12) and the on-device WebView browser (T16) — so
> `android/app/src/main/AndroidManifest.xml` now declares exactly **three**
> permissions: `INTERNET`, `POST_NOTIFICATIONS`, `RECORD_AUDIO`. The Play
> overlay keeps its removals as defense in depth against a transitive library
> manifest re-introducing one. `Distribution.agentPermissions` no longer
> exists (the agent roster it mirrored is gone); the invariant is now pinned
> by `test/play_distribution_test.dart`, which parses the manifest and fails
> if the declared set changes or a restricted permission returns.
>
> The table below is retained as the historical analysis of *why* each
> permission is unacceptable; the "Play build" column still holds.

The pre-migration integration manifest declared 29 permissions (`AndroidManifest.xml:3-46`). Library manifests add `AD_ID`, `ACCESS_ADSERVICES_ATTRIBUTION`, `ACCESS_ADSERVICES_AD_ID`, `READ_GSERVICES` and the install-referrer permission. None of these is needed for the app to work.

The dangerous ones are only:
- requested by the generic agent tool `request_permission` (`agent_service.dart:24129-24180`), or
- used through the sandbox shell (`content`/`am`).

| Permission | Play rule | Play build |
|---|---|---|
| `SEND_SMS` (`:42`) | Restricted: default SMS handler only | **Removed** |
| `CALL_PHONE`, `READ_PHONE_STATE` | No core use | **Removed** |
| `MANAGE_EXTERNAL_STORAGE` (`:36`) | File managers, backup and antivirus apps only | **Removed** |
| `READ_MEDIA_IMAGES/VIDEO/AUDIO` (`:28-30`) | Gallery-type apps only; use the Photo Picker | **Removed**. File picking uses SAF via `file_picker`. |
| `READ/WRITE_CONTACTS`, `READ/WRITE_CALENDAR` | Personal and sensitive data; no feature uses it | **Removed** |
| `BODY_SENSORS`, `ACTIVITY_RECOGNITION` | Health declaration; no feature uses it | **Removed** |
| `BLUETOOTH_SCAN/CONNECT` | SCAN without `neverForLocation` counts as a location use | **Removed** |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (`:18`) | Acceptable-use list only | **Removed**. Kotlin falls back to the battery-optimization settings list. |
| `FOREGROUND_SERVICE_SPECIAL_USE` and the `specialUse` type (`:13`, `:116`) | Needs Play review. The idle "Ready & Listening" presence isn't an approvable use. | **Removed.** Idle keep-alive is off in the Play build. Agent runs keep `dataSync`. |
| `AD_ID`, ad-services (from firebase-analytics) | Ad ID declaration | **Removed**, plus `google_analytics_adid_collection_enabled=false`. Declare "No advertising ID". |
| CAMERA, RECORD_AUDIO, FINE/COARSE location | Browser `getUserMedia` (`agent_service.dart:2851`), voice input, page geolocation | Kept. Each runtime prompt is triggered by the user. |
| `QUERY_ALL_PACKAGES`, `SYSTEM_ALERT_WINDOW`, `REQUEST_INSTALL_PACKAGES`, `USE_EXACT_ALARM`, `SCHEDULE_EXACT_ALARM`, background location | (not declared) | **Pass** |

The pre-migration agent's `request_permission` tool refused permissions that a Play build did not declare (`Distribution.agentPermissions`). Both the tool and that list were deleted with the on-device agent (P8 T17–T19); `Distribution.declaredPermissions` now mirrors the three-permission manifest.

**Owner action:** complete the FGS declaration for **dataSync** in Play Console. It needs a description, the impact if interrupted, and a video (§13.4).

---

## 3. AccessibilityService and Control mode

**Verdict:** Blocker. The fix is to ship v1 without it, which is done.

### Policy

[answer/10964491](https://support.google.com/googleplay/android-developer/answer/10964491) and the policy page [answer/16558241](https://support.google.com/googleplay/android-developer/answer/16558241). Announced 2025-10-30 in [answer/16550159](https://support.google.com/googleplay/android-developer/answer/16550159); compliance date 2026-01-28.

- "Any use of the Accessibility API that enables an app to autonomously initiate, plan, and execute actions or decisions is strictly prohibited."
- Only "deterministic, rule-based automation" is allowed.
- `isAccessibilityTool` is only for apps whose primary purpose is helping people with disabilities.

### Evidence

- `OvidAccessibilityService` (`AndroidManifest.xml:121-130`; `res/xml/ovid_accessibility_service.xml`) uses:
  - `canPerformGestures`
  - `canTakeScreenshot`
  - `flagRetrieveInteractiveWindows`
- An LLM plans and executes the taps, typing and swipes in other apps (`device_*` tools, `agent_service.dart:6678+`).
- The disclosure `kControlModeDisclosure` (`state.dart:253-268`) and its consent dialog (`chat_screen.dart:8988-9010`) are good: in-app, affirmative and specific. But **no disclosure can cure the prohibited use itself.** Requesting the declaration would end in rejection, and could lead to an account strike.

### Fix

Done: `79f8eb9` and `93329fe`. The Play build:
- removes the service from the manifest (`src/play/AndroidManifest.xml`), so Play Console won't ask for the Accessibility declaration;
- hides Control in the mode pickers (`modeOptionsForPicker`);
- makes `/permission control` reply "not available";
- shows a notice at the `_enableControlMode` entry instead of opening it;
- treats persisted Control sessions as General;
- keeps `device_*` tools out of the tool roster.

A remote flag is not enough. The service declaration in the manifest is what Play reviews.

### Later options for keeping the capability

- **Sideload or other stores only.** The `targetSdk 28` build still has Control. Android developer verification starts in 2026, so the APK needs a verified developer identity.
- **Narrow, user-scripted automation.** Deterministic macros that the user records, with no LLM planning. That is "rule-based automation" and needs the declaration plus a disclosure video.
- **On-device intents and App Functions** for actions inside apps, instead of accessibility.

---

## 4. On-device sandbox and downloaded or executed code

**Verdict:** Blocker. The fix is to remove it from the Play build, which is done.

### Policy

- Device and Network Abuse, [answer/9888379](https://support.google.com/googleplay/android-developer/answer/9888379): "an app may not download executable code (such as dex, JAR, .so files) from a source other than Google Play." The exception covers only code running "in a virtual machine or an interpreter where either provides indirect access to Android APIs".
- Android 10 W^X: [behavior-changes-10](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission).

### How execution works today

1. `jniLibs/<abi>/libovid_bootstrap.so` is not an ELF file. It is a zip of the Termux userland (`build.gradle.kts:94-104`).
2. On first Studio open it is unzipped to `<files>/sandbox`, marked `chmod +x`, and run as `$PREFIX/bin/bash -lc …` with an `LD_PRELOAD` shim (`sandbox_service.dart:676-1000`, `_sandboxEnv`).
3. More executables are then **downloaded** from outside Play:
   - Termux `.deb` packages via apt and `ovid-pkg` (`sandbox_service.dart:1163-1232`; mirrors at `:1806-1812`)
   - nodejs, python, git, a JDK, Kotlin, a proot Ubuntu rootfs and the Flutter SDK (`ensureRuntime` `:3301`, `ensureJdk` `:3570`, `ensureProotUbuntu`, `ensureFlutter`)
   - npm and pip packages, including native addons
   - stdio MCP servers (`npx`/`uvx`) and plugin hooks, all run through that shell

Two separate problems:
- At target ≥ 29, SELinux blocks `execve` and exec-mmap of `app_data_file`, so the sandbox can't work at target 36 at all.
- Even at target 28, downloading `.deb` ELFs breaks the policy. The interpreter exception doesn't cover downloading the interpreter binaries themselves.

### Fix

Done: `79f8eb9`. In the Play build:
- `sandboxPreflightGate` returns a permanent `SandboxUnsupportedException`, with an honest message, **before** any payload read or download;
- `checkExisting()` reports "not installed";
- Gradle excludes the payload.

Everything that depends on the shell stops with the existing "continue without sandbox" path: terminal, Studio shell, stdio MCP and plugin hooks. Remote (HTTP) MCP servers, REST native plugins, the browser and chat are unaffected.

### Compliant way back, for a later release

From `docs/superpowers/specs/2026-10-06-targetsdk36-runtime-architecture.md`:

1. **Packaged runtime.** Ship every executable as `lib<name>.so` in `jniLibs`, set `extractNativeLibs=true`, and exec from `nativeLibraryDir`. Bundle node, python and git at build time. Allow **no** apt, npm-native or prebuilt-binary downloads. Interpreted scripts are allowed under the interpreter exception, but the policy still applies to whatever they do. Run the on-device spike (H1) first.
2. **Server-side execution:** remote Studio.
3. Keep the full Termux experience in the sideload build only.

Owner action: describe the Play app as "AI chat, browser and image assistant". Don't advertise an on-device terminal or Linux in the listing.

---

## 5. Generative AI policy

**Verdict:** Fix needed. The code part is done; the server and owner parts remain.

### Policy

[answer/13985936](https://support.google.com/googleplay/android-developer/answer/13985936):
- Apps "must contain in-app user reporting or flagging features" so users can report "without needing to exit the app".
- Developers must use those reports to inform filtering and moderation.
- Apps must prevent generation of restricted content: CSAM, sexual content involving non-consenting people, and so on. See [Inappropriate content](https://support.google.com/googleplay/android-developer/answer/9878810).

### Evidence

- The thumbs up/down feedback (`chat_screen.dart:4918-4960`) is stored **locally only** (`AppState.persistSessions`). The developer never sees it, so it doesn't satisfy the rule.
- Image generation (`server/images/config.json`: gemini-2.5/3.1-flash-image, gpt-image-2) relies only on the upstream providers' filters. There is no Ovid prompt moderation.
- BYOK lets users point the app at any OpenAI-compatible endpoint.

### Fix

Done: `93329fe`, but **only in the legacy v1 `ChatScreen`** (`lib/ui/chat_screen.dart:6114`). The default v2 shell does not expose it yet, so this remains a Play blocker.
- A **Report** (flag) action on every finished assistant reply, generated image and HTML artifact.
- `ContentReportSheet` offers reasons that match Play's restricted categories, an optional note, and shows a confirmation. Nothing leaves the app.
- `ContentReportService` POSTs `{base}/v1/reports` with the Firebase ID token and App Check. Reports are idempotent and capped at a 4,000-character excerpt.
- `server/reports` is a SQLite queue:
  - 50 reports per user per day
  - 180-day retention
  - `delete_account` erase
  - `open_reports`/`resolve` for triage
- It is mounted on the account app when `CONTENT_REPORTS_DB` is set (`server/account/runtime.py`).

### Owner and back-end actions

1. Deploy `server/reports`: set `CONTENT_REPORTS_DB` to a persistent volume path, and add it to `.env.example` and the Caddy route for the share base.
2. Call `ReportRepository.delete_account` from the account-deletion cleanup.
3. Add `server/reports` to the CI pytest line. It was left out to avoid a conflict with the PR-8 `server/billing` edit.
4. Check the queue daily. Write a short moderation procedure into the ToS.
5. Add **server-side safety** to Ovid Cloud chat and images:
   - an input moderation call (for example the provider's moderation endpoint or Gemini safety settings at `BLOCK_MEDIUM_AND_ABOVE`)
   - a refusal for sexual content involving minors and non-consensual imagery
6. Add a system-prompt safety preamble.
7. For BYOK: the ToS must forbid generating prohibited content, and the provider's policy applies. Optionally, apply the same moderation to image prompts before they are sent.
8. Recommended, not required: a short "AI can make mistakes" line under the composer.

---

## 6. User-generated content: share links and Collab

**Verdict:** Fix needed.

### Policy

[answer/9876937](https://support.google.com/googleplay/android-developer/answer/9876937):
- Users must accept terms that define objectionable content before creating UGC.
- "An in-app system for reporting and blocking objectionable UGC and users."
- Moderation must be reasonable and consistent with the type of UGC.

### Evidence

- **Share links:** immutable 30-day snapshots, public at `/s/{token}` (`server/shares/api.py`, `repository.py` with a 30-day TTL). Viewing them in-app happens in `shared_conversation_screen.dart`. There is no report action.
- **Collab** (collab branch):
  - up to 10 members (`server/collaboration/repository.py:31`)
  - names come from Firebase claims (`api.py:210`)
  - the owner can **Remove** members (`collab_session_screen.dart:545-553`, `revoke_member`)
  - anyone can **Leave**
  - there is no report action and no way for a participant to block another
- **Terms:** PR-1b shows "By continuing you agree to the Ovid Terms of Service…" before sign-up (`login_gate.dart:844-880`). That counts as acceptance only if the published Terms define and prohibit objectionable content.

### Fix

- **Done:** the reusable `showContentReportSheet(kind: sharedConversation | collabMessage | collabParticipant, …)` and the server kinds.
- **To wire after the collab merge.** These were left out of this branch because those files conflict with `feat/session-link-collab`:
  1. `shared_conversation_screen.dart` AppBar `actions:` — add `IconButton(tooltip: 'Report', icon: const Icon(Icons.flag_outlined), onPressed: () => showContentReportSheet(context, kind: ContentReportKind.sharedConversation, targetId: widget.token))`.
  2. `collab_session_screen.dart`, in each other-author message's menu: **Report message** (`collabMessage`, the message id and text).
  3. In the member list: **Report participant** (`collabParticipant`) and **Block**. Block means hide that participant's messages locally and leave the session if they are the owner. The owner keeps **Remove**.
- **Back end:** add an admin takedown that revokes a share token or ends a collab session regardless of owner (the repositories only offer owner revoke today). Process reports within 24-48 hours.
- **Minimum age:** set the target audience to 18+. The ToS should state 18+ (or 16+ in the EEA, if you prefer). No in-app age gate is required when you don't target children.

---

## 7. Account deletion, privacy policy, Data safety

**Verdict:** Blocker for the URLs. The rest needs owner action.

### Policy

- Account deletion: [answer/13327111](https://support.google.com/googleplay/android-developer/answer/13327111). Requires an in-app path and a web URL.
- Data safety: [answer/10787469](https://support.google.com/googleplay/android-developer/answer/10787469).
- User Data / privacy policy: [answer/10144311](https://support.google.com/googleplay/android-developer/answer/10144311).

### Evidence

- In-app deletion: `account_deletion_panel.dart` (PR-1b). It does real deletion when `OVID_ACCOUNT_ENABLED=true`; otherwise it opens the web form (`:380`) or a prefilled email (`:388`).
- URLs: `legal_links.dart:15-39` (privacy, terms, delete-account, support@ovidsi.com).
- **On 2026-10-11 from this host:**
  - `http://ovidsi.com/privacy` returns `308` to https.
  - `https://ovidsi.com/*` fails with `tlsv1 alert internal error`: no certificate is served for that name.
  - Play's crawler and the App Links verifier will therefore fail.
  - The website default `https://dhanuk.page.gd/ovid` returns an empty reply.

### Owner actions

1. Put a valid TLS certificate on `ovidsi.com`.
2. Serve **plain HTML** (no JavaScript challenge) at `/privacy`, `/terms` and `/delete-account`, and `assetlinks.json` at `/.well-known/`.
3. Enter the privacy URL and the "Delete account URL" in Play Console.
4. Ship with `OVID_ACCOUNT_ENABLED=true` once the account service is live. The web form fallback is acceptable, but in-app deletion is better.
5. The deletion must cover:
   - the Firebase user
   - Ovid Cloud keys and usage
   - shares
   - collab memberships
   - image receipts
   - reports

### Encryption in transit

- `usesCleartextTraffic=false` with `network_security_config.xml`: cleartext is only allowed to `localhost`, `127.0.0.1` and `::1`, for dev-server previews.
- Answer **"Data is encrypted in transit: Yes."**

### Data safety draft (Play build)

| Data type (Play category) | Collected | Shared | Purpose | Optional | Source |
|---|---|---|---|---|---|
| Name, Email address, Phone number (Personal info) | Yes | No | Account management, app functionality | Required for sign-in | Firebase Auth (Google / phone) |
| User IDs (Firebase UID) | Yes | No | Account, fraud prevention / security (App Check), app functionality | Required | Firebase, Ovid server |
| Other in-app messages (chat prompts and replies, files you attach) | Yes, when using Ovid Cloud, share links or Collab | No. Model processing by Ovid Cloud's upstream providers is a service provider. BYOK requests go straight from the device to the provider the user chose, which is a user-initiated transfer. | App functionality | Yes (BYOK only = not collected) | Ovid Cloud gateway, shares (30 days), collab |
| Photos / Files and docs | Yes, when attached to an Ovid Cloud request or used for image edits | No | App functionality | Yes | Image server, gateway |
| Other user-generated content (shared conversations, Collab messages, reports) | Yes | No (shares are public to link holders by the user's choice) | App functionality, safety | Yes | shares, collab, reports |
| App interactions; Diagnostics; Crash logs | Yes | No | Analytics, app performance | **Yes** (consent toggle, off by default: `AndroidManifest.xml:56-61`, `firebase_service.dart:497-519`) | Firebase Analytics / Crashlytics |
| Device or other IDs (Firebase installation ID, App Check / Play Integrity) | Yes | No | Analytics (if consented), security | Partly | Firebase |
| Purchase history | Not yet. Answer "Yes" once Play Billing ships (PR-8). | No | | | |
| Approximate/precise location | **No.** The browser passes it to the page the user opened, after a prompt. Ovid does not transmit it. | No | | | |
| Audio | **No.** Voice input uses the on-device system recognizer and sends text. | | | | |
| Contacts, Calendar, SMS, Health, Web browsing history | No (removed in the Play build). The browser history stays on the device. | | | | |

Security answers:
- Encrypted in transit: Yes.
- Users can request deletion: Yes (in-app path and URL).
- Independent security review: No.

---

## 8. Payments

**Verdict:** Pass for the first submission, with conditions.

### Policy

[answer/9858738](https://support.google.com/googleplay/android-developer/answer/9858738). US programs (external links and alternative billing) exist since 2025-10-29 / 2025-12-09 ([answer/15582165](https://support.google.com/googleplay/android-developer/answer/15582165)), but require enrolment. Don't link out.

### Evidence

- `billing_screen.dart:137-140`: `canPurchase` requires `billingEnabled` from the server, or a debug build. PR-1b hides the purchase call-to-action in release when no backend exists.
- Plan tiles still show prices: Plus ₹499, Pro ₹899, Max ₹1699 (`:66-86`).
- "Pay now" calls `OvidCloudService.upgrade`. That is the **server** test-upgrade, not Play Billing.

### Conditions

1. The server must keep `billingEnabled=false` until PR-8's Play Billing client is live. If the server flips it early, release builds would offer a non-Play purchase of digital goods, which is a payments violation.
2. Recommended: hide the prices until Play Billing returns localized `ProductDetails` prices. Show "Plans coming soon" instead.
3. No external purchase links. Settings shows only Terms, Privacy and the marketing site. Keep `dhanuk.page.gd/ovid` free of pricing and checkout.
4. When billing ships: use Play Billing for subscriptions, give Data safety "Purchase history: Yes", and add a subscription cancellation link.

---

## 9. Families, content rating, deception, trademarks

**Verdict:** Owner action.

### Target audience

Set **18+ only**. Reasons:
- The app has unrestricted web access and BYOK models.
- 18+ keeps you out of the Families policy ([answer/9893335](https://support.google.com/googleplay/android-developer/answer/9893335)).
- Don't use child-appealing artwork.

### Content rating (IARC) hints

| Question | Answer |
|---|---|
| Category | Utility / Productivity (not Game) |
| Violence, sexuality, language, controlled substances, gambling | No (none built in) |
| Users can interact or exchange content | **Yes** (Collab, share links) |
| Shares the user's location with other users | No |
| Digital purchases | No (Yes once billing ships) |
| Unrestricted internet access (browser) | **Yes** |
| Generates content with AI | Answer **Yes** if asked; describe the safeguards and the reporting flow |

Expect roughly a Teen / PEGI 12 rating because of the unrestricted internet access and user interaction.

### Metadata and impersonation

Policies: [answer/9898842](https://support.google.com/googleplay/android-developer/answer/9898842), [answer/9888374](https://support.google.com/googleplay/android-developer/answer/9888374).

- `pubspec.yaml:2` "Super Intelligent AI agent" is an unverifiable superlative. Don't use it in the listing. Prefer "AI assistant for chat, code and images".
- The app name "Ovid Si" is fine.
- Model names (Claude, GPT, Gemini) appear as selectable providers and "Claude Code" as a plugin format (`plugins_screen.dart:2092`). Nominative use is fine.
- Don't use their logos in the icon or screenshots, and don't put them in the title. Add the line "Not affiliated with Anthropic, OpenAI or Google" to the description.

---

## 10. Release build configuration

**Verdict:** Mostly pass.

| Item | Evidence | Verdict |
|---|---|---|
| debuggable | release buildType has no `isDebuggable` (default false) | Pass |
| minify / shrink / obfuscation | `isMinifyEnabled`/`isShrinkResources = true`; CI uses `--obfuscate --split-debug-info` | Pass |
| Release signing guard | `validateProductionSigning` refuses debug or mismatched keys (`build.gradle.kts:23-80`) | Pass. With Play App Signing this is the upload key. |
| Cleartext | `usesCleartextTraffic=false`; localhost-only exception | Pass |
| allowBackup | `false` | Pass |
| Exported components | MainActivity (launcher, App Links), OAuthCallbackActivity (custom scheme, `noHistory`), BootReceiver (system broadcasts only), AccessibilityService (removed in Play). Everything else is `exported=false`. | Pass |
| App Links | `autoVerify` for `https://ovidsi.com/s/*` (`AndroidManifest.xml:85-91`) | **Owner action:** TLS on ovidsi.com, plus the Play signing SHA-256 in `assetlinks.json`. Without them links open the disambiguation chooser. That isn't a rejection, but it is broken UX. |
| WebView | Agent browser: JavaScript on, with `JavascriptChannel`s `OvidConsole`/`OvidPopup`/`OvidGeolocation` (`agent_service.dart:4517-4551`). They only post capped strings to Dart and expose no privileged methods. Artifact WebView: no JS interface, file access off, SSL errors cancelled (`HtmlArtifactViewFactory.kt:144-161, 246`). | Pass. Keep it this way. Never `proceed()` on SSL errors. |
| Root check | `SecurityCheck.kt:51` runs `which su` | Pass (informational only) |
| CI | `.github/workflows/build.yml:239-240` release commands lack `OVID_PLAY_BUILD` | **Fix:** add `--dart-define=OVID_PLAY_BUILD=true` to the `production_release` AAB command (§13.1) |

### App Check, Play Integrity and sideloaded builds (`/mint` 401)

- `CloudAppCheck` activates `AndroidProvider.playIntegrity` (`cloud_app_check.dart:15-22`).
- Play Integrity only gives an "app recognized" verdict to installs that come from Play and are signed with the **Play app-signing key**.
- A sideloaded APK, or a locally built release, therefore gets an App Check failure. The server returns `/mint` 401, so Ovid Cloud, shares, collab and reports refuse.

To test in a Play-recognized setup:
1. In Play Console, link the Google Cloud project under App integrity → Play Integrity API.
2. In Firebase App Check, register the Android app with the Play Integrity provider and add the **Play app-signing** SHA-256.
3. Upload the AAB to the **Internal testing** track, or Internal app sharing.
4. Testers install from the Play opt-in link.
5. For local development, use the App Check **debug provider** with a registered debug token. Never ship it.
6. Make sure an App Check failure shows the existing "App verification is unavailable" message rather than crashing. The pre-launch devices install from Play, so they should pass.

---

## 11. Pre-launch report risks

| Risk | Mitigation |
|---|---|
| Robo can't get past login | Provide credentials under App access (§13.3). Robo also accepts a Firebase test phone number. |
| Studio or terminal screens show the "not part of Google Play version" state | This is expected and not a crash. Better: hide the Studio terminal entry points in Play builds (follow-up). |
| Target-36 runtime differences (edge-to-edge insets, FGS start while backgrounded) | Run the internal-test build on Android 15 and 16 devices. `FGS_BACKGROUND_DENIED` is already handled. |
| dataSync 6-hour cap | `onTimeout` now stops cleanly. Before this fix it would have crashed with `ForegroundServiceDidNotStopInTimeException`. |
| Accessibility warnings (touch targets, contrast) | The integration action rows use 48 dp targets (`chat_screen.dart:4859-4870`) and PR-6b contrast. The new Report action uses the same `add()` helper. |
| ANR at startup | `checkExisting` is now a constant `false` in Play builds, so there is no disk probe. Startup work is already deferred. |
| Undeclared permission requests | Not possible: the on-device agent that requested them is gone, and the manifest declares only INTERNET/POST_NOTIFICATIONS/RECORD_AUDIO (pinned by `play_distribution_test`). |

---

## 12. Code changes on `release/play-compliance`

| Commit | Change |
|---|---|
| `79f8eb9` | Play build profile: `ovidPlayBuild` (dart-define decoding), `targetSdk 36`, payload exclusion, `src/play/AndroidManifest.xml` overlay; `lib/core/distribution.dart`; Control, sandbox, keep-alive and permission gates; `AgentForegroundService.onTimeout`; battery-settings fallback; tests `test/play_distribution_test.dart`; PR36 regression test updated (sideload target stays 28) |
| `93329fe` | AI/UGC reporting: `lib/core/content_report_service.dart`, `lib/ui/content_report_sheet.dart`, Report action in the chat message row, `server/reports/*` with tests, account runtime mount; tests `test/content_report_test.dart` |
| `d029d96` | Control coercion kept on the read path only, so the merge stays conflict-free with integration's refactored `_writeMode` |

**Test results:**
- `flutter analyze`: clean, both standalone and on a trial merge with integration.
- Flutter tests: new tests pass (11 standalone; play_distribution, content_report, composer_modes and control_presence pass on the trial merge).
- Existing related suites pass: control_presence, composer_modes, device_overlay, session_stop_isolation, schedule_background, wake_lock_contract, sandbox_*, core_regression (PR36 updated).
- `pytest server/reports`: 5 passed.
- Gradle manifest merge checked for the Play define, `-Pdart-defines` and the default build.

---

## 13. Launch checklist

### 13.1 Code and CI (before the first upload)

- [ ] Merge `release/play-compliance` into integration.
- [ ] In `.github/workflows/build.yml`, make the `production_release` AAB command pass `--dart-define=OVID_PLAY_BUILD=true`.
- [ ] Keep `release_inventory.py --expected-target 36` for that job. Set the sideload APK to `--expected-target 28`.
- [ ] Add `server/reports` to the pytest line.
- [ ] Wire Report into `shared_conversation_screen.dart` and `collab_session_screen.dart`, and add participant Block (§6).
- [ ] Server: deploy reports (`CONTENT_REPORTS_DB`), hook account-deletion erase, add admin takedown for shares and collab, and add moderation on Ovid Cloud chat and image prompts (§5).
- [ ] Keep server `billingEnabled=false` until Play Billing ships. Consider hiding the ₹ prices.
- [ ] Optional: hide Studio terminal entry points in Play builds; add the "AI can make mistakes" hint.

### 13.2 Infrastructure

- [ ] Valid TLS on `ovidsi.com`, with plain-HTML `/privacy`, `/terms`, `/delete-account` and `/.well-known/assetlinks.json` carrying the Play signing SHA-256.
- [ ] Monitored `support@ovidsi.com`.
- [ ] Firebase: Play signing SHA-1 and SHA-256 for Google Sign-In; App Check with Play Integrity; Play Integrity API linked to the Cloud project.

### 13.3 Play Console declarations

- [ ] **App access:** "All features need login". Provide a Firebase **test phone number + fixed OTP** (Auth → Phone → test numbers), or a reviewer Google account, plus steps.
- [ ] **Ads:** No.
- [ ] **Advertising ID:** No (AD_ID removed).
- [ ] **Content rating:** answers in §9.
- [ ] **Target audience:** 18+.
- [ ] **Data safety:** table in §7.
- [ ] **Privacy policy URL** and **Delete account URL**.
- [ ] **Foreground service:** `dataSync`. Use: "keeps a user-started AI agent task (network requests to model providers, file processing) running when the user leaves the app; shows a notification with Stop". Impact if deferred: "the user's task is aborted mid-way". Provide the video.
- [ ] **Accessibility, All files access, Photo/video, SMS/Call log, exact alarm:** none should appear. If any does, the Play define was not applied.
- [ ] **Health apps declaration:** not a health app. **Financial features:** none. **Government:** No. **News:** No.
- [ ] **Generative AI:** confirm in-app reporting exists (Report button).

### 13.4 Store listing

- **Title:** `Ovid Si: AI Assistant`
- **Short description:** "Chat with top AI models, browse, and create images."
- **Full description:**
  - Describe chat, BYOK providers, Ovid Cloud, the in-app browser, image generation, share links and live Collab.
  - **Don't** mention an on-device terminal, Linux or "controls your phone".
  - Avoid "super intelligent" and rank claims.
  - Add: "Not affiliated with Anthropic, OpenAI or Google."
  - Add: "AI responses may be inaccurate; report offensive output with the flag button."
- **Screenshots:** Play build only, with no third-party logos.
- **Videos (unlisted YouTube):**
  - FGS dataSync: start a long agent task, background the app, show the notification and the Stop action.

### 13.5 Testing tracks

1. **Internal testing** (up to 100 testers, no review wait). Upload the AAB with `OVID_PLAY_BUILD=true` and verify:
   - Play Integrity / App Check: `/mint` 200
   - sign-in
   - share and collab
   - Report reaches the queue
   - the 16 KB result in App bundle explorer
   - the pre-launch report: crashes, ANRs, accessibility
2. **Closed testing.** For a **personal developer account created after 2023-11-13**, you need **at least 12 testers opted in continuously for 14 days** before you can apply for production access ([answer/14151465](https://support.google.com/googleplay/android-developer/answer/14151465)). Recruit around 15 for margin and collect feedback, because the production application asks about it. Organization accounts are exempt.
3. **Production.** Apply for access from the Dashboard, then roll out in stages (for example 10% → 50% → 100%), watching Android vitals.

### 13.6 Sideload build

The sideload build keeps Control, the sandbox and target 28. It is no longer Play-eligible, and it must use a different upload/signing identity, or at least a separate distribution, from the Play app. Android developer verification (2026–2027) will require registering it ([developer-verification](https://developer.android.com/developer-verification)).
