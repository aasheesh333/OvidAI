# Release checklist — code green → live on the production track

- **Package:** `com.dhanuk.ovidai`
- **Verified against:** `1.0.0+3` (`pubspec.yaml`), the Play build profile
  (`OVID_PLAY_BUILD=true`) and `.github/workflows/build.yml`, on 2026-10-22.
- **Scope:** Google Play Android only. Nothing here uploads automatically; every
  Console action is the owner's.
- **Companion documents:** `STORE-LISTING.md` (listing copy),
  `DATA-SAFETY.md` (form answers), `REVENUECAT_SETUP.md` (billing, only when
  subscriptions ship).

Legend: **[owner]** needs a Console/secret/infrastructure action;
**[CI]** is automated by `.github/workflows/build.yml`; **[verify]** is a
manual check with a stated pass condition.

---

## 0. Preconditions (do these before freezing the release commit)

> **P0 RELEASE BLOCKER — in-app reporting is missing from the default UI.**
> Play's Generative-AI and UGC policies require a way to report generated
> content and objectionable users/messages without leaving the app. The Report
> flow exists (`lib/ui/content_report_sheet.dart`, `reportAiMessage`) and is
> wired in the legacy v1 `ChatScreen` (`lib/ui/chat_screen.dart:6114`) and the
> legacy `CollabSessionScreen`/`SharedConversationScreen`, but the default v2
> shell (`V2AppShell`, `kOvidUiV1=false`) exposes only Copy, Branch and
> Regenerate on an assistant message (`lib/ui/v2/chat/live_chat_page.dart`,
> `_openMessageActions`), and the v2 Collab pages have no Report action (owner
> Remove and Leave exist, which covers blocking). Wire Report into the v2
> message, artifact and Collab surfaces before submitting, or do not submit.
> See `STORE-LISTING.md` §6 for the IARC answers to use until it is fixed.

- [ ] **[owner]** Valid TLS on `ovidsi.com`. `https://ovidsi.com/privacy`,
      `https://ovidsi.com/terms` and `https://ovidsi.com/delete-account` return
      plain HTML (no JavaScript challenge) with HTTP 200.
- [ ] **[owner]** `support@ovidsi.com` is monitored.
- [ ] **[owner]** `android/keystore.properties` and the upload keystore exist,
      and the certificate SHA-256 in `certSha256` matches the key. The Gradle
      `validateProductionReleaseSigning` task refuses a debug, expired or
      mismatched key, so a wrong keystore fails the build instead of shipping.
- [ ] **[owner]** Play App Signing is enabled for the app. Keep the upload key
      separate from the Play app-signing key.
- [ ] **[owner]** Register the **Play app-signing** SHA-1 and SHA-256 in
      Firebase Authentication (the Android OAuth client for Google Sign-In).
      Register the same SHA-256 in Firebase App Check if it is enabled, and in
      `OVID_ANDROID_RELEASE_CERT_SHA256` so `/.well-known/assetlinks.json`
      verifies the `/s/`, `/c/` and `/schedule/` App Links. The upload key's
      fingerprint is not enough once Play re-signs the app.
- [ ] **[owner]** `android/app/google-services.json` is present for the release
      build (project `ovid-ai`, package `com.dhanuk.ovidai`). It is gitignored;
      CI injects it from secrets.
- [ ] **[owner]** Play Console → **App content → App access** has a reviewer
      Google account or a Firebase test phone number + fixed OTP. Without it,
      review cannot exercise any feature.
- [ ] **[owner]** Decide the account-service flag. Production must set the
      repository variable **`OVID_ACCOUNT_ENABLED=true`** so Settings → Delete
      account performs in-app deletion. With `false`, the panel offers only the
      web/email request, which does not satisfy Play's in-app deletion
      requirement.
- [ ] **[owner]** Decide billing for this release:
      - No Play subscription exists yet (`FEATURE_GAPS.md` D1/D2) → ship
        without `OVID_REVENUECAT_GOOGLE_KEY`; RevenueCat stays disabled and the
        Data safety "Purchase history" answer is **No**.
      - Subscriptions are live → complete `REVENUECAT_SETUP.md` steps 1–6,
        pass the public Play SDK key at build time, and change Purchase history
        to **Yes** before submitting. **Do not enable the RevenueCat key until
        the server-confirmation blocker at the top of `REVENUECAT_SETUP.md` is
        closed**: a RevenueCat purchase does not reach `/billing/verify` or
        `/billing/rtdn`, so it would charge the card and never unlock the plan.
        The safe path today is no RevenueCat key + the server-verified
        `PlayBillingService` path.
- [ ] **[owner]** Decide App Check. The release builds do **not** set
      `OVID_APPCHECK` (`test/release_flags_test.dart` forbids enabling it by
      accident). If you turn it on, do it together with Firebase App Check
      (Play Integrity provider), the Play app-signing SHA-256, and the gateway
      `OVID_APPCHECK_MODE=required`; otherwise signed-in calls can fail with
      `/mint` 401.

---

## 1. Code is green

- [ ] **[verify]** The release commit is on the integration branch, not a
      feature branch. No uncommitted changes in `android/` or `lib/`.
- [ ] **[verify]** `pubspec.yaml` `version:` is **greater** than the last
      uploaded `versionCode`. Play rejects a reused code. Bump the `+N` for
      every upload, even a rebuild of the same content.
- [ ] **[verify]** Run the full gate locally or confirm the same commit is green
      in CI:
      ```bash
      export PATH=/root/flutter/bin:$PATH
      tool/verify_v2.sh
      ```
      Pass condition: analyze clean, all tests pass, design/v2 ratchets green.
- [ ] **[verify]** The Play-distribution invariants still pass:
      ```bash
      flutter test test/play_distribution_test.dart test/release_flags_test.dart
      ```
      Pass condition: the manifest declares exactly
      `INTERNET`, `POST_NOTIFICATIONS`, `RECORD_AUDIO`; the overlay removes
      `AD_ID` and the broad permissions; every release command passes
      `OVID_ACCOUNT_ENABLED`.
- [ ] **[verify]** Play's in-app reporting gate: open a finished assistant
      answer in the **default v2 shell** and confirm the Actions menu has a
      **Report** entry (and that generated images/artifacts do too). Today it
      does not; `reportAiMessage` is wired only in the legacy v1 `ChatScreen`.
      A build without this must not be promoted (see §0).
- [ ] **[verify]** `docs/play/DATA-SAFETY.md`, `STORE-LISTING.md` and
      `REVENUECAT_SETUP.md` still match the code you are about to ship. If a
      permission, consent default, deletion step or data type changed, update
      them in this commit.

---

## 2. Build the production AAB

- [ ] **[CI]** Run the **`production_release`** workflow dispatch
      (`.github/workflows/build.yml`) on the release commit. It:
      - decodes `ANDROID_KEYSTORE_BASE64`, writes `keystore.properties`, and
        derives `ANDROID_SIGNING_CERT_SHA256`;
      - runs `:app:validateProductionReleaseSigning`;
      - runs `test/release_flags_test.dart` with the release defines;
      - builds the APK **and** the AAB with
        `--dart-define=OVID_PLAY_BUILD=true` and
        `--dart-define=OVID_ACCOUNT_ENABLED="$OVID_ACCOUNT_ENABLED"`;
      - runs `tool/release_inventory.py` with `--mode production
        --expected-target 36 --profile play`;
      - uploads the AAB, APK, Dart symbols and R8 mapping as private workflow
        artifacts.
- [ ] **[verify]** Do **not** build the Play AAB with a Test Store define.
      The release command must contain **no**
      `--dart-define=OVID_REVENUECAT_TEST_STORE=true` and no
      `OVID_REVENUECAT_TEST_STORE_KEY`. `resolveRevenueCatConfig` refuses the
      Test Store in a release build (`lib/core/revenuecat_billing.dart`), but a
      define in the command still means the build was misconfigured: rebuild
      clean.
- [ ] **[verify]** Download `app-release.aab` from the workflow and confirm:
      - `versionCode` and `versionName` match `pubspec.yaml`;
      - `targetSdkVersion` is **36**;
      - the Play manifest overlay applied (no `AD_ID`, no
        `MANAGE_EXTERNAL_STORAGE`, no SMS/contacts/calendar/media permissions);
      - only the three permissions from §1 are present;
      - the 16 KB page-size result in **App bundle explorer** is clean;
      - the artifact is signed with the upload key (Play App Signing will
        re-sign it).
- [ ] **[verify]** The workflow's `release_inventory` report says
      `profile: play`, `mode: production`, `target: 36`. If it says
      `sideload`, the dispatch input was wrong; do not upload that file.

---

## 3. Play Console — App content (complete before the first upload)

Open **Play Console → Policy → App content**. Complete every row; an incomplete
declaration blocks review.

- [ ] **Privacy policy:** `https://ovidsi.com/privacy`.
- [ ] **App access:** "All or some functionality is restricted"; add the
      reviewer credentials from §0 and the exact steps (sign in → send a
      prompt → open Settings → Delete account).
- [ ] **Ads:** **No**, the app contains no ads.
- [ ] **Advertising ID:** **No**. The Play manifest removes
      `com.google.android.gms.permission.AD_ID` and Analytics ad-ID collection
      is disabled.
- [ ] **Content rating:** start the IARC questionnaire. Use the answers in
      `STORE-LISTING.md` §6. Key answers: Productivity; no violence/sex/
      profanity/drugs/gambling/horror; users can interact (**Yes**); UGC
      (**Yes**); unrestricted internet (**Yes**); AI-generated content
      (**Yes**); in-app reporting (**Yes**); digital purchases **No** for this
      build; location sharing **No**; ads **No**. Submit and keep the
      certificate. Retake it if purchases or audience change.
- [ ] **Target audience:** **18 and over only**. Do not select child age
      bands. Answer "No" to "Is your app designed for children?" and do not
      opt in to the Families policy.
- [ ] **Data safety:** complete the form from `DATA-SAFETY.md` §2 and §5.
      The form has four screens: data collection and security, data types,
      data usage and handling, data sharing. Declare the data types in the
      worksheet; mark analytics, crash logs and diagnostics **optional /
      collected only with consent**; answer **encrypted in transit: Yes**;
      **users can request deletion: Yes**; **independent security review:
      No**; **no data sold**; **no data shared for advertising**. Purchase
      history is **No** until a Play subscription is live.
- [ ] **Account deletion URL:** `https://ovidsi.com/delete-account`.
- [ ] **News app:** No. **Health app:** No. **Financial features:** None (the
      app sells no loans, crypto or banking). **Government app:** No.
- [ ] **Data safety / privacy consistency:** every data type in the form also
      appears in `docs/legal/PRIVACY.md`, and the 24-hour grace, 90-day
      crash/diagnostic retention and 14-day backup window agree in both. If
      they do not, fix the policy or the form before submitting.

---

## 4. Play Console — Store presence

Open **Grow → Store presence → Main store listing**.

- [ ] **App name:** `Ovid Si` (or `Ovid Si: AI Assistant`).
- [ ] **Short description:** paste `STORE-LISTING.md` §2 (55 characters).
- [ ] **Full description:** paste `STORE-LISTING.md` §3 (2,032 characters).
      Do not paste `docs/play/LISTING.md`; it is a superseded draft.
- [ ] **App icon:** 512 × 512, 32-bit PNG, no transparency, no third-party
      logo.
- [ ] **Feature graphic:** 1024 × 500.
- [ ] **Phone screenshots:** 2–8 from the Play build, clean account, no
      personal data, no provider logos, no paywall/prices, no diff/preview
      screens. See `STORE-LISTING.md` §5.
- [ ] **Category:** Productivity. **Tags:** the five in `STORE-LISTING.md` §1
      that the Console offers.
- [ ] **Contact details:** `support@ovidsi.com`; website `https://ovidsi.com`.
- [ ] **Default language:** English (United States). Do not add translations
      the app does not ship.
- [ ] **Store settings:** confirm the app is free, contains no ads, and has no
      external purchase link. Do not enable "external offers" programs.

---

## 5. Internal testing track (first gate)

Open **Test and release → Testing → Internal testing**.

- [ ] Create a release, upload the production AAB from §2, add release notes
      from `STORE-LISTING.md` §4.
- [ ] Add the "Ovid internal" tester list (4 addresses) and copy the opt-in
      link.
- [ ] Roll out. Internal testing releases are available without a full review
      (typically minutes).
- [ ] **[verify]** Install from the opt-in link on a physical Android 15/16
      device and run the smoke test:
      - Google sign-in and phone sign-in (test number);
      - send a prompt, stop a run, queue a second message;
      - generate an image and open it from the library;
      - attach a photo through the system picker;
      - open the cloud browser and take control;
      - create a share link and a Collab room;
      - submit a Report on a reply (this is a **hard gate**: the v2 shell does
        not expose Report today, so a build without it must not be promoted);
      - Settings → Permissions shows only Microphone and Notifications;
      - Settings → Delete account shows the 24-hour grace copy (use a
        disposable account to complete it, and confirm the account is gone);
      - no "Test mode: purchases are simulated" banner. If it appears, the
        build used the Test Store and must be rebuilt.
- [ ] **[verify]** Check **App bundle explorer** for the uploaded version:
      target 36, 16 KB page size, permissions, and the Play signing
      certificate.
- [ ] **[verify]** Read the **Pre-launch report** (Test and release → Testing →
      Pre-launch report). Fix crashes, ANRs, accessibility failures and
      broken sign-in before promoting.
- [ ] **[owner]** If Play Integrity / App Check is enabled, confirm a
      Play-installed build gets a `/mint` 200. A sideloaded build will fail
      App Check by design; do not use one to judge the Play build.

**Gate to leave internal:** the smoke test passes, the pre-launch report has no
P0 crash/ANR, and the Data safety/listing answers are saved.

---

## 6. Closed testing track (production-access gate)

Open **Test and release → Testing → Closed testing**.

- [ ] Create a closed track (alpha), upload the **same or a higher** versionCode,
      and add testers by email list or Google Group. Target **15+** testers.
- [ ] Roll out. The first closed release goes through Play review.
- [ ] **Personal developer accounts created after 2023-11-13** must keep at
      least **12 testers opted in continuously for 14 days** before applying for
      production access. Organization accounts are exempt. Recruit 15+ for
      margin; removed or opted-out testers reset the count.
- [ ] Collect feedback for the full window; fix P0/P1 issues with a new
      versionCode. Do not change the package or the signing key.
- [ ] **[verify]** Re-run the §5 smoke test on the closed build and re-check
      Android vitals (crash-free sessions, ANR rate).

**Gate to production:** the closed test window is satisfied (if required), no
open P0, and the production-access questionnaire can name real testers and
feedback.

---

## 7. Open testing track (optional, but part of the requested path)

Open **Test and release → Testing → Open testing**.

- [ ] Promote the closed build to open testing (or upload the same AAB with a
      higher versionCode), set a tester cap if desired, and roll out.
- [ ] The release goes through Play review. Use this track for a wider device
      mix if the closed group is small.
- [ ] **[verify]** Monitor vitals and support mail for 3–7 days. Fix with a new
      versionCode; never reuse one.
- [ ] If you do not need open testing, skip to §8. Production access does not
      require an open track; it requires the closed-test window for personal
      accounts.

---

## 8. Apply for production access

- [ ] **[owner]** **Play Console → Dashboard → Apply for production access**
      (the button appears after the closed-test requirement is met).
- [ ] Answer the questionnaire honestly: who tested, on which devices, what
      feedback you received, what you changed. Attach the closed-track
      feedback if asked.
- [ ] Wait for Google's decision (typically days, not minutes). A rejection
      states the reason; fix it and re-apply. Do not upload a production
      release while the application is pending.

**Gate:** production access is granted.

---

## 9. Production track

Open **Test and release → Production → Releases → Create new release**.

- [ ] Upload the production AAB (same signing key; new versionCode if the
      previous one was used on any track).
- [ ] Paste the release notes from `STORE-LISTING.md` §4.
- [ ] Choose a **staged rollout**: 10% → 50% → 100% (or 20% → 50% → 100%).
      Do not start at 100% for a first release.
- [ ] Confirm the release summary shows: target SDK 36, the three permissions,
      no ads, no purchase claims (unless subscriptions are live), and the
      Data safety form as completed.
- [ ] Submit for review. First production review is the longest gate; a policy
      rejection returns the release to you and does not publish it.
- [ ] **[verify]** After approval, install from the public listing on a clean
      device and repeat the §5 smoke test (sign-in, prompt, image, share,
      report, delete-account copy).
- [ ] **[verify]** Watch **Monitor → Android vitals** and crash-free sessions
      during each rollout stage. Halt the rollout if crash-free sessions fall
      below your threshold or a P0 appears.
- [ ] Increase the rollout percentage only after the previous stage is stable.
- [ ] At 100%, confirm the public listing shows the correct title, short
      description, full description, icon, screenshots, category, contact email
      and privacy URL.

---

## 10. After launch

- [ ] **[owner]** Keep the upload key and `keystore.properties` backed up. A
      lost upload key with Play App Signing can be reset through Play Support;
      a lost app-signing key cannot.
- [ ] **[owner]** Update the Data safety form the day the first Play
      subscription goes live: Purchase history → **Yes**; retake the content
      rating if the digital-purchases answer changes.
- [ ] **[owner]** Re-check `REVENUECAT_SETUP.md` steps 1–7 and validate a real
      purchase with a license tester before advertising paid plans.
- [ ] **[verify]** For every later release, repeat §1–§2, bump the
      versionCode, and re-read `DATA-SAFETY.md` if a permission, consent
      default or data flow changed.
- [ ] **[verify]** Never ship a build made with
      `--dart-define=OVID_REVENUECAT_TEST_STORE=true`. The release resolver
      refuses the Test Store, but the define must not be in a production
      command at all.

---

## Quick reference — the three review gates

| Track | Review? | Typical wait | What must be true to promote |
|---|---|---|---|
| Internal testing | No full review | Minutes | Smoke test passes; pre-launch report clean |
| Closed testing | Yes (first release and updates) | Hours–days | 12+ testers / 14 continuous days for personal accounts; no open P0 |
| Open testing | Yes | Hours–days | Stable vitals; optional |
| Production | Yes | Days (first review longest) | Production access granted; staged rollout configured |
