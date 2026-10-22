# Production runbook — Ovid Si (Google Play)

**App:** `com.dhanuk.ovidai` · `Ovid Si` · `pubspec.yaml` version `1.0.0+3` · targetSdk 36
**Audience:** whoever is on call when the launched app misbehaves.
**Verified against the repo on 2026-10-22.** Every file reference and artifact
name below was checked against this repository; console steps are grounded in
the repo's own Play/ops documents where they exist. Steps that could not be
verified from the repo are marked **`[NOT VERIFIED FROM REPO]`** and listed
again in Appendix B.

Companions: `docs/play/RELEASE-CHECKLIST.md` (how a build gets here),
`cloud/deploy/RUNBOOKS.md` (server incidents I-1…I-15),
`docs/ops/M1_RUNBOOK.md` (spend gate), `cloud/deploy/ROLLOUT.md` (R5 rollout
rules), `cloud/deploy/R2-PROVISIONING.md` (storage activation).

---

## 0. Before anything else — five-minute triage

### 0.1 Golden rules

1. **Read-only first.** Every command under *Diagnose* is safe. Commands that
   change the live stack are marked `[OWNER]`, the same gate used by
   `cloud/deploy/RUNBOOKS.md` §0.1.
2. **Never weaken a threshold to silence an alert.** Fix the condition or record
   a dated owner decision (`cloud/deploy/RUNBOOKS.md` §0.1).
3. **The app is a thin client.** Chat runs execute on the cloud gateway
   (`lib/main.dart:214-217`). A client bug cannot be fixed by a server change,
   and a server rollback changes behaviour for *every* installed client at once.
4. **Never paste a `<placeholder>` into a shell.** The shell reads `<x>` as a
   redirect. Commands below use `"${VAR:?}"` so an unset variable aborts loudly
   (`cloud/deploy/RUNBOOKS.md` §0.1).
5. **Never print a secret.** Redact with `sed 's/=.*/=<set>/'` as shown.

### 0.2 Identify the build

| Where | What you get |
|---|---|
| App → **Settings → About → Copy version** | `kAppVersionLabel`, e.g. `1.0.0 (build 3, 1a2b3c4)` — version, build number and the **short commit** (`lib/core/app_info.dart:21-28`, `lib/ui/v2/app/v2_settings_actions.dart:645`) |
| Play Console → **App bundle explorer** → version | `versionCode` ↔ `versionName` for the artifact that was uploaded (`docs/play/RELEASE-CHECKLIST.md` §2) |
| App → **Settings → Service status → Copy diagnostics** | version, `Distribution: play\|sideload`, cloud check summary, account/push state, and the last 20 scrubbed `Diag` entries (`lib/ui/settings_health_screen.dart:135-153`) |

`Diag` is a 200-entry ring buffer of swallowed errors, tagged by context
(`lib/core/diag.dart:20-50`). Tags you will meet in this runbook:
`history.open`, `history.migrate`, `history.migrate.quarantine`,
`main.warmCloud`, `deeplink.stream`, `account.*`.

### 0.3 Is the server up?

```bash
curl -sf https://api.ovidsi.com/cloud/v1/health
# expected: {"status":"ok","checks":{"db":true,"redisQ":true}}
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.ovidsi.com/account/login
# expected: 401 (missing_authentication) — route reachable, no token sent
```

On the box, the same two checks:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud ps
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

### 0.4 Severity scale

The numbers are the repo's own SLOs; the SEV mapping is this document's
convention (there is no severity config in the repo).

| SEV | Definition | Response |
|---|---|---|
| **SEV1** | Crash-free sessions < **99.5 %** or ANR > **0.5 %** on the live versionCode; boot crash; sign-in broken for everyone; data loss; spend above the hard ceiling | Halt the Play rollout now (§6.1); page platform on-call |
| **SEV2** | One issue inside the error budget; storage/mint degradation; a single account burning budget | Investigate now; halt only if it grows |
| **SEV3** | One user, one artifact, cosmetic | Ticket; no rollout action |

---

## 1. Crash spike

### 1.1 Where to look

**Primary — Play Console → Android vitals → Crashes and ANRs.**
The repo refers to this page as *Monitor → Android vitals*
(`docs/play/RELEASE-CHECKLIST.md:327`) and as *Android vitals*
(`docs/play/PLAY_COMPLIANCE_AUDIT.md:583`). On consoles that group the left
nav, the group is labelled **Quality**; the page itself is **Crashes and ANRs**
**`[NOT VERIFIED FROM REPO]`** (nav grouping is console-version dependent — the
page name is what is stable).

Read, in this order:

1. **Filter by app version** = the versionCode you are on call about. A cluster
   that exists only on the previous version is not this incident.
2. **Crash-free sessions** for that version, and the same number for the
   previous version (the comparison is the signal, not the absolute).
3. **Crash clusters**, sorted by affected sessions. Open one: it shows the
   stack trace, device models, Android versions, app version and ABI.
4. **App bundle explorer** for the same version if you need the ABI or the
   signing certificate.

**Secondary — Firebase Crashlytics:** `console.firebase.google.com` → project
**`ovid-ai`** (`docs/play/RELEASE-CHECKLIST.md:49-51`, package
`com.dhanuk.ovidai`) → **Crashlytics**.

> **Crashlytics only contains opted-in users.** The manifest ships
> `firebase_crashlytics_collection_enabled=false`
> (`android/app/src/main/AndroidManifest.xml:26-31`) and collection starts only
> after the user consents (`lib/core/firebase_service.dart:577-589`). Play
> vitals sees every install; Crashlytics does not. When the two disagree, Play
> is right.

**Single device:** `Settings → Service status → Copy diagnostics` (§0.2), or,
with the device attached:

```bash
adb logcat -b events -d | grep -E 'am_crash|am_anr'
```

### 1.2 What "spike" means numerically

| Signal | Number | Source |
|---|---|---|
| Crash-free sessions (SLO) | **≥ 99.5 %** | `docs/architecture/SCALE_PLAN.md:862`, product spec §17 (`docs/superpowers/specs/2026-10-21-ovid-si-product-spec.md:276`) |
| ANR rate (SLO) | **≤ 0.5 %** | product spec §17 (same line) |
| Staged-rollout abort — crash rate | **threshold not set** (Q2 is an open owner input) | `cloud/deploy/OWNER-GATES.md:120-140` |
| Staged-rollout abort — `run_failed` | **> 1 % of runs** over a rolling window | `cloud/deploy/ROLLOUT.md:365-371` |

Treat it as a **spike** when any one of these is true:

1. Crash-free sessions for the live versionCode are **below 99.5 %**.
2. A **single** new cluster accounts for **≥ 0.5 % of sessions** on that
   version — the entire error budget, even if the aggregate still looks fine on
   a small install base.
3. Any fatal crash happens **before the first frame** (app closes on launch) at
   any rate — that path is hit by every launch for the affected users.

Rules 1 and 2 are derived from the two SLOs above; there is no separate
"spike" constant in the repo. Because the R5 crash threshold (Q2) was never
answered, **99.5 % is the operative halt number**
(`cloud/deploy/OWNER-GATES.md:140`).

> Play shows *not enough data* below a minimum session count. A 2-crash cluster
> on 100 sessions is 2 % — read the stack trace anyway; do not dismiss it
> because the aggregate is noise **`[NOT VERIFIED FROM REPO]`** (console
> behaviour).

### 1.3 Reading a stack trace from the obfuscated release build

The release build is obfuscated twice:

* Dart: `flutter build ... --obfuscate --split-debug-info=build/symbols`
  (`.github/workflows/build.yml:212-213`).
* Java/Kotlin: `isMinifyEnabled = true`, R8 with `-repackageclasses` for plugin
  code (`android/app/build.gradle.kts:145-155`).

Crashlytics does **not** symbolicate: both uploads are disabled
(`android/app/build.gradle.kts:157-170`). The symbols are archived by CI
instead (CT-021):

| Artifact | Contents | Retention | Workflow step |
|---|---|---|---|
| `Ovid-symbols-dart-<full-sha>` | `build/symbols/` (Dart symbols) | **90 days** | `Upload Dart symbols (split-debug-info)` (`build.yml:261-268`) |
| `Ovid-symbols-r8-mapping-<full-sha>` | `build/app/outputs/mapping/release/` (`mapping.txt`) | **90 days** | `Upload R8 mapping` (`build.yml:270-277`) |

Both steps are `if: env.release_signing == 'true'` and `if-no-files-found:
error`, so a signed release always has them. They are **private workflow
artifacts** — you need read access to the repository (`build.yml:255-260`).

#### Step 1 — map the crash to a commit

```bash
gh run list --repo aasheesh333/OvidAI --workflow build.yml --limit 30 \
  --json databaseId,headSha,createdAt,conclusion
```

Take the run whose `headSha` starts with the short sha shown in **About**
(§0.2). If the app shows no sha (`kAppBuildSha` is empty), the build was not
made by CI — stop and escalate, it is not a Play artifact.

#### Step 2 — download both symbol archives

```bash
RUN="${RUN:?set RUN to the databaseId from step 1}"
SHA="${SHA:?set SHA to the full 40-char headSha}"
gh run download "$RUN" --repo aasheesh333/OvidAI \
  -n "Ovid-symbols-dart-$SHA" -D /tmp/ovid-symbols
gh run download "$RUN" --repo aasheesh333/OvidAI \
  -n "Ovid-symbols-r8-mapping-$SHA" -D /tmp/ovid-r8
ls -1 /tmp/ovid-symbols /tmp/ovid-r8
```

The upload paths have no wildcard, so the **contents** of each directory land at
the artifact root (`tool/release_workflow_test.py:189-205` asserts the paths).
`ls` confirms: expect `app.android-arm64.symbols`, `app.android-arm.symbols`,
`app.android-x64.symbols` (Dart) and `mapping.txt` (R8) **`[NOT VERIFIED FROM
REPO]`** — the file *names* are produced by Flutter/AGP, not by this repo;
verify with `ls` before using them.

#### Step 3 — symbolicate the Dart frames

Copy the stack trace out of Crashlytics (issue → stack trace) into
`/tmp/crash-dart.txt`. Then, using the Flutter version CI pins (**3.47.4**,
`build.yml:107`):

```bash
flutter symbolize --input /tmp/crash-dart.txt \
  --debug-info /tmp/ovid-symbols/app.android-arm64.symbols \
  --output /tmp/crash-dart.sym.txt
cat /tmp/crash-dart.sym.txt
```

* Pick the symbols file for the **ABI named in the crash report**; arm64-v8a
  (physical devices) is the common case.
* If the trace is not pure `#N` Dart frames (it has a header line from
  Crashlytics), keep only the numbered frames before symbolizing.
* `flutter symbolize --help` is authoritative for the flag spelling in your
  installed SDK **`[NOT VERIFIED FROM REPO]`** (no Flutter SDK in this
  workspace; the `--input/--debug-info/--output` form is Flutter's documented
  CLI).

#### Step 4 — retrace the Java/Kotlin frames

Frames that look like `com.dhanuk.ovidai.a.b(SourceFile:3)` come from R8.
Locate `r8.jar` and retrace:

```bash
find "${ANDROID_HOME:-$HOME/Android/Sdk}" "$HOME/.gradle/caches" \
  -name 'r8.jar' 2>/dev/null | head -3

java -cp "${R8_JAR:?set R8_JAR to the path printed above}" \
  com.android.tools.r8.retrace.Retrace \
  /tmp/ovid-r8/mapping.txt /tmp/crash-java.txt
```

**`[NOT VERIFIED FROM REPO]`** — the repo archives `mapping.txt` but never runs
retrace; the `r8.jar` location depends on the workstation.

#### Step 5 — native crashes

`nativeSymbolUploadEnabled = false` and CI archives only Dart symbols + the R8
mapping (`android/app/build.gradle.kts:157-163`, `build.yml:261-277`). A crash
whose trace is `*** *** ***` / `#00 pc 0000000000…` is a **native (NDK)**
crash and **cannot be symbolicated from this repo's artifacts**. Record the
ABI, build id and offset, and escalate — do not guess.

#### After 90 days

Both artifacts expire (`retention-days: 90`). Re-running the workflow on the
same commit with the same pinned Flutter version is the only fallback and is
**not guaranteed to reproduce identical symbols** **`[NOT VERIFIED FROM
REPO]`**. Treat symbolication older than 90 days as unavailable.

### 1.4 Act

1. Spike confirmed → **halt the staged rollout** (§6.1).
2. Fix forward: a new `versionCode` is mandatory (`docs/play/RELEASE-CHECKLIST.md`
   §1 — Play rejects a reused code).
3. If the crash is in the boot path, ask for `Service status → Copy diagnostics`
   from one affected user *before* they update; the `Diag` ring is the only
   client-side record you will get.

**Verify:** Play → Crashes and ANRs, filtered to the new versionCode, shows
crash-free sessions recovering above 99.5 %; the old cluster's affected-session
count stops growing.

---

## 2. ANR spike

### 2.1 What an ANR means here

Android declares an **ANR** when the app's main thread stops responding — most
commonly *Input dispatching timed out* (5 s) or a broadcast/service timeout
**`[NOT VERIFIED FROM REPO]`** (platform behaviour, not app config). Play counts
**user-perceived** ANRs and reports an **ANR rate**; the app's SLO is **≤ 0.5 %**
(product spec §17).

An ANR is *not* a crash: it produces no Dart exception and no Crashlytics issue.
It will **never** appear in Crashlytics. Play Console is the only source.

In this app the two most likely main-thread blockers are both in the
boot/storage path.

### 2.2 Cause A — blocking work before `runApp`

`lib/main.dart:148-221`:

```
runZonedGuarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  ...
  await _boot();                    // <- nothing is drawn until this returns
}, ...)

_boot():
  await FirebaseService.I.initializeCrashReporting();   // Firebase.initializeApp
  installReleaseErrorWidget();
  installOvidCertificatePinning();
  AppState.I.registerProductionAccountFeatures();
  SessionHistoryRepository.I.enableSqlite();            // opens lazily
  StudioDraftStore.I.enable();
  await AppState.I.initializeForFirstFrame();           // <- loads chat history
  ...
  runApp(const OvidApp());
```

`initializeForFirstFrame()` (`lib/core/state.dart:1823-1832`) calls
`_loadSessionsForFirstFrame()` (`state.dart:2525`), which calls
`SessionHistoryRepository.I.readRows(...)`. On the **first launch after an
upgrade**, `readRows` triggers the one-time SQLite migration
(`lib/core/session_history_store.dart:498-536`):

* `_open()` runs `applyWorkaroundToOpenSqlite3OnOldAndroidVersions()`,
  `sqlite3.open`, `PRAGMA journal_mode=WAL`, `PRAGMA synchronous=FULL`,
  `PRAGMA busy_timeout=3000` and the schema DDL (lines 145-230);
* `_migrate()` does `BEGIN IMMEDIATE`, inserts **every** session row plus one
  FTS row per message, commits, then **reads every row back** and computes a
  SHA-256 over all of them to verify (lines 571-675).

All of that is synchronous native SQLite on the **UI isolate**. A history with
thousands of messages can take seconds — the window is blank and Android shows
"isn't responding".

### 2.3 Cause B — a long synchronous write on the main isolate

`SessionHistoryRepository.writeRows` → `_serial` → `_writeSqlite`
(`session_history_store.dart:282-296`, `810-858`) executes, on the caller's
isolate:

* a full re-encode/diff of every session (`AppState._writeSessionsNow`,
  `state.dart:3199-3259`),
* `BEGIN IMMEDIATE` + one upsert per changed row + FTS row insert/delete per
  changed message,
* with `synchronous = FULL` (line 171) and `busy_timeout = 3000` (line 172) —
  a competing writer/checkpointer can block each statement for up to 3 s.

Triggers:

* the production trailing debounce — **200 ms**, plus a **1 s max-wait** so a
  streaming turn still lands (`state.dart:1328-1332`, `1762`, `3082-3099`);
* `flushSessionPersistence()` on **pause/inactive/hidden**
  (`lib/main.dart:444-457`) — the worst case, because Android is about to freeze
  the process.

Only FTS **search** runs on a background isolate (`Isolate.run`,
`session_history_store.dart:400-420`); writes never do.

### 2.4 The first two things to check

1. **Which shape is it?** Open the ANR cluster in Play Console → **Crashes and
   ANRs → ANRs** and read the **main-thread stack**:
   * cold start, `bindApplication` / `initializeForFirstFrame` /
     `sqlite3` / `SessionHistoryRepository._open` → **Cause A**;
   * after a turn or on backgrounding, `_writeSqlite` / `Fts5` / `writeRows`
     → **Cause B**.
   Also note the ANR type in the cluster header ("Input dispatching timed out"
   vs a broadcast/service ANR) and the app version.
2. **How big is the history, and did the migration run?** On the affected
   device: `Settings → Service status → Copy diagnostics` and read the `Diag`
   entries — `history.migrate`, `history.open`,
   `history.migrate.quarantine` mean the SQLite path is active or failing. For a
   **debug** build only, size the DB:

   ```bash
   adb shell run-as com.dhanuk.ovidai ls -l files/chat-history.db
   ```

   Play builds are not debuggable, so `run-as` fails there; reproduce on a debug
   build seeded with a large history instead.

Device-side capture while it hangs:

```bash
adb logcat -b events -d | grep -E 'am_anr|am_crash'
adb shell dumpsys dropbox --print data_app_anr | head -200
```

### 2.5 Act

There is **no server-side fix for an ANR.** The two code-level levers both
require a new build:

* `SessionHistoryRepository.disableSqlite()` — the documented kill switch that
  copies migrated namespaces back to SharedPreferences
  (`session_history_store.dart:44-45`, `111-118`; wired at
  `lib/main.dart:191-193`);
* move the migration and the write path off the UI isolate (the only shipped
  precedent is `Isolate.run` for search, `session_history_store.dart:400-420`).

So: **halt the rollout** (§6.1), ship a new `versionCode`, then verify.

**Verify:** on a device with the same history size,
`adb shell am start -W -n com.dhanuk.ovidai/.MainActivity` reports a `TotalTime`
within the previous build's range, and Play's ANR rate for the new version falls
below 0.5 %.

---

## 3. Sign-in failure

### 3.1 The exact path a sign-in takes

1. **Provider** — Google (`GoogleSignIn().signIn()` → `GoogleAuthProvider.credential`
   → `signInWithCredential`) or phone (`verifyPhoneNumber` →
   `signInWithCredential`). Both live in `lib/core/auth_identity.dart:115-194`;
   the Google credential is built in `lib/core/firebase_service.dart:131-140`.
2. **Firebase Auth** returns a `User`; `_onUser` admits the account
   (`firebase_service.dart:330-338`).
3. **Account service** — `_retryAccountLogin` posts to
   `https://api.ovidsi.com/account/login` with
   `Authorization: Bearer <Firebase ID token>` (+ `X-Firebase-AppCheck` only in
   builds compiled with `OVID_APPCHECK=true`), body `{}`
   (`lib/core/account_service.dart:69`, `74-76`, `128-146`).
4. **Routing** — Caddy matches `/account/login`, `/account/deletion`,
   `/account/deletion/cancel` and proxies to the Python account API on
   `127.0.0.1:8080` (`server/account/deploy/Caddyfile:3-27`;
   `server/account/DEPLOYMENT.md:385-428`). The duplicate Fastify routes in
   `cloud/apps/gateway/src/routes/account.ts` are **unreachable in production**
   (`docs/audit-2026-10-19/06-contract-leftovers.md:47`, CT-016).
5. **Admission** — a 200 whose `state` allows login makes
   `FirebaseService.accountReady` true and `LoginGate` opens the shell
   (`firebase_service.dart:88-93`, `408-442`).
6. **While waiting** the user sees **"Confirming your account"**; after **15 s**
   the screen offers **Retry / Sign out** even with no error
   (`lib/ui/login_gate.dart:392`, `477-495`).

### 3.2 What each failure code means

**Firebase / provider** (copy from `lib/core/auth_providers.dart:75-136`):

| Code | Meaning | Owner action |
|---|---|---|
| `app-not-authorized`, `invalid-app-credential`, `missing-client-identifier`, `captcha-check-failed` | The signing certificate is not registered for this Firebase Android app, or Play Integrity/App Check rejected the build | **Fix the SHA-1/SHA-256 (§3.3)** |
| `operation-not-allowed`, `provider-disabled`, `admin-restricted-operation` | Provider disabled in Firebase Authentication → Sign-in method | Enable the provider |
| `network-request-failed`, `network_error` | Connectivity (device or egress) | Check the network; not a console issue |
| `quota-exceeded`, `too-many-requests` | SMS quota exhausted / abuse throttle | Wait or raise quota; not a code bug |
| `account-changed`, `user-mismatch`, `trusted-migration-required`, `identity-proof-required`, `auth-busy` | Local identity state (a different account signed in mid-flow, or a link/re-auth proof expired) | Ask the user to retry from a clean sign-in; not a server fault |

**Account service** (the client maps **status codes only**,
`lib/core/account_service.dart:147-156`; server codes are in
`server/account/domain.py`):

| HTTP | Client message | Server `detail` you will see in logs | Meaning |
|---|---|---|---|
| 401 | "Please sign in again to verify your identity." | `missing_authentication`, `invalid_identity`, `reauthentication_required`, `invalid_auth_time` | Token missing/expired, or `auth_time` unusable |
| 403 | "This account or app could not be verified." | `unsupported_identity` (anonymous/unsupported `sign_in_provider`), `account_unavailable` (disabled or fenced) | Not a token problem — the account state is wrong |
| 409 | "Deletion is pending or already in progress…" | `deletion_in_progress` | The user must **Restore account** explicitly |
| 422 | (client shows the generic unavailable message) | `invalid_request` | The client sent an unexpected body field — a **client regression**, not a config issue |
| 5xx / timeout (20 s) | "The account server is unavailable…" | — | Caddy or the account API is down (§3.4) |

If the build was compiled with `OVID_ACCOUNT_ENABLED=false`, the account calls
are skipped entirely (`account_service.dart:58`, `98-102`;
`firebase_service.dart:92`). Sign-in still works; **account deletion is
web-only** (`docs/play/RELEASE-CHECKLIST.md:55-59`). Do not diagnose a sign-in
failure as "account service down" without checking this build flag.

### 3.3 The console setting that most often breaks it

**Firebase → Project settings → Your apps → Android `com.dhanuk.ovidai` →
SHA certificate fingerprints.**

You must register the **Play app-signing** SHA-1 **and** SHA-256 — not just the
upload key's. Once Play re-signs the app, the upload-key fingerprint no longer
identifies the installed binary, and Google sign-in fails with the
`app-not-authorized` / `invalid-app-credential` class of error even though the
same build works when sideloaded. This is a release precondition in
`docs/play/RELEASE-CHECKLIST.md:41-48`:

> "Register the **Play app-signing** SHA-1 and SHA-256 in Firebase
> Authentication (the Android OAuth client for Google Sign-In). … The upload
> key's fingerprint is not enough once Play re-signs the app."

Same rule for **App Check**: the Play app-signing SHA-256 must be registered
with the Play Integrity provider, and the gateway must run
`OVID_APPCHECK_MODE=required` only for a build compiled with
`--dart-define=OVID_APPCHECK=true`; otherwise signed-in calls fail at `/mint`
with 401 (`docs/play/RELEASE-CHECKLIST.md:72-77`,
`cloud/deploy/RUNBOOKS.md` I-13).

**Authorized domains** (Firebase Authentication → Settings → Authorized domains)
is the equivalent switch for the **web/OAuth** flow used by non-Google
providers (`signInWithProvider`, `auth_identity.dart:138-147`). It is **not**
the Android Google Sign-In path **`[NOT VERIFIED FROM REPO]`** — the repo only
documents the SHA fingerprint requirement.

### 3.4 Diagnose

```bash
# Route + service reachable? (no token -> 401 missing_authentication is healthy)
curl -s -i -X POST https://api.ovidsi.com/account/login | head -20

# Account API on the box
systemctl status ovid-account-api --no-pager
journalctl -u ovid-account-api -n 80 --no-pager

# Caddy config still routes /account/*
docker exec ovid-gateway-caddy-1 caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile
```

Interpretation:

| Observation | Conclusion |
|---|---|
| `curl` returns 401 `missing_authentication` | Server is fine; the failure is Firebase/provider or the device |
| `curl` returns 502/503/connection error | Caddy or `ovid-account-api` is down → platform on-call |
| `curl` returns 404 | The `/account/*` matcher was dropped from the Caddyfile |
| Server fine **and** the app shows an `app-not-authorized`-class message | **SHA-1 / App Check** (§3.3) |
| Server fine **and** the app shows a 401/403 message | Token/account state — check `deletion` state for that uid |

Do **not**, during an incident: disable App Check to "get users in", rotate the
Firebase service-account key, or change `OVID_INTERNAL_*` secrets. Each of those
has a documented blast radius (`cloud/deploy/RUNBOOKS.md` I-13) and none of them
fixes a fingerprint mismatch.

---

## 4. Model spend runaway

### 4.1 Where spend is metered

Two processes, one counter:

| Layer | File | What it does |
|---|---|---|
| **LiteLLM hook** (request path) | `server/mint/litellm_hook/ovid_pools.py` | Pre-call: rejects when the user's allowance is exhausted (429 `daily_limit_reached`, or `free_daily_cap` / `free_monthly_cap`), or denies everything when the kill switch is on (503 `paid_models_disabled`). Post-call (`async_log_success_event`, lines 325-359): adds LiteLLM's `response_cost` to **`pool:{uid}:spend`** (TTL = window end), records tokens and `auto` rewrites, and queues the M1 alert. |
| **mint** | `server/mint/mint.py` | Owns windows, budgets, resets, `/usage`, `/plans`, the `/admin` console, and the global spend monitor (`_spend_monitor`, lines 567-582). |

**The hook fails open.** Every accounting and pre-call Redis error is swallowed
(`ovid_pools.py:244`, `358-359`) so a Redis outage cannot break chat — which
also means **a Redis outage does not stop spend**. The backstops are the LiteLLM
per-key and per-user budgets (`server/mint/README.md:80-88`).

### 4.2 Caps

Seed values (all are live Redis settings, editable in `/admin` — the table is
only the first-run seed; `server/mint/README.md:28-47`,
`server/mint/ovid_plans.py:75-109`):

| Plan (aliases) | Allowance per 24 h | Notes |
|---|---|---|
| `free` | **$0.15** (`config:base_daily_usd`; the live install keeps $0.50) | plus **$10 / 30 d** monthly backstop (`free_monthly_cap_usd`) |
| `starter` (`3x`) | free × 3 = **$0.45** | |
| `pro` (`7x`) | free × 23 = **$3.45** | hidden `auto` routing on |
| `max` (`15x`) | free × 43 = **$6.45** | hidden `auto` routing on |

* Window: `window_hours` per plan (24 h seed; existing installs seed **720 h** —
  `server/mint/README.md:43-47`).
* Slow-mode plans may continue past the allowance up to
  `hard_ceiling_mult` × allowance (seed **3×**) — that is the real worst case
  (`ovid_plans.py:284-290`).
* Free-plan token ceilings: **50 M / 24 h** and **1.5 B / 30 d**
  (`ovid_plans.py:59-60`).
* Alerts: per-user **$0.50 / UTC day** (`user_daily_spend_alert_usd`), global
  **$20 / day** (`DAILY_SPEND_ALERT_USD`) — `docs/ops/M1_RUNBOOK.md:16-31`.

Read the live values, not the seeds:

```bash
set -a; . /opt/ovid-gateway/.env; set +a
export MK="${OVID_ADMIN_KEY:-$LITELLM_MASTER_KEY}"

curl -sS -H "Authorization: Bearer $MK" http://127.0.0.1:8090/admin/settings | jq
curl -sS -H "Authorization: Bearer $MK" http://127.0.0.1:8090/admin/plans    | jq
```

`/admin/*` is **not routed publicly**; reach it over an SSH tunnel to mint's
loopback port (`server/mint/README.md:155-160`, `mint.py:2868-2873`):

```bash
ssh -N -L 8090:127.0.0.1:8090 "${VPS:?set VPS to the owner host}"
# then http://127.0.0.1:8090/admin (paste the master key into the tab)
```

### 4.3 Identify a single account burning the budget

1. **Alerts.** M1 delivers one alert per free user per UTC day above $0.50.
   Payload carries **`uid_hash`**, never the uid
   (`docs/ops/M1_RUNBOOK.md:50-73`):

   ```bash
   curl -sS -H "Authorization: Bearer $MK" \
     'http://127.0.0.1:8090/admin/alerts?limit=50' | jq
   ```

2. **Rank every account by spend.** `pool:{uid}:spend` is the hook's counter
   (one per user across android + web). The uid list is mint's `ovid:uids` set,
   and mint's Redis is **db 2** of the live redis container
   (`server/mint/README.md:121-130`, `cloud/deploy/RUNBOOKS.md` I-11):

   ```bash
   set -a; . /opt/ovid-gateway/.env; set +a
   docker exec -e RP="$REDIS_PASSWORD" -i ovid-gateway-redis-1 sh -c '
     for uid in $(redis-cli --no-auth-warning -a "$RP" -n 2 SMEMBERS ovid:uids); do
       v=$(redis-cli --no-auth-warning -a "$RP" -n 2 GET "pool:$uid:spend")
       [ -n "$v" ] && printf "%s %s\n" "$v" "$uid"
     done' | sort -rn | head -20
   ```

3. **Map an alert's `uid_hash` back to a uid** (SHA-256 of the uid,
   `server/mint/m1_alerts.py:28`):

   ```bash
   HASH="${HASH:?set HASH to uid_hash from the alert}"
   docker exec -e RP="$REDIS_PASSWORD" -i ovid-gateway-redis-1 \
     sh -c 'redis-cli --no-auth-warning -a "$RP" -n 2 SMEMBERS ovid:uids' \
   | while read -r uid; do
       [ "$(printf %s "$uid" | sha256sum | cut -d' ' -f1)" = "$HASH" ] && echo "$uid"
     done
   ```

4. **Inspect one account** (plan, overrides, window spend, per-model table,
   remaining):

   ```bash
   curl -sS -H "Authorization: Bearer $MK" \
     "http://127.0.0.1:8090/admin/user?q=${UID:?set UID or email}" | jq
   ```

### 4.4 Act

| Lever | Command / console | Effect |
|---|---|---|
| Custom daily limit for one user | `POST /admin/user/update` `{"uid":"…","daily_usd":0.5}` (or the User panel in `/admin`) | Scales that user's allowance immediately |
| Ban / unban | `POST /admin/ban` · `/admin/unban` | Blocks the user's keys |
| Reset one window | `POST /admin/reset-window` `{"uid":"…"}` | Clears `pool:{uid}:spend`, re-arms budgets |
| **Stop everything** | `POST /admin/kill-switch` `{"enabled":true}` | Every model call → 503 `paid_models_disabled` |

Kill-switch procedure, verification and the env-override caveat are in
`docs/ops/M1_RUNBOOK.md` §3-4. The runtime flag is Redis `config:kill_switch`;
the env flag `OVID_PAID_MODELS_KILL_SWITCH` on **mint and LiteLLM** is the hard
override and needs a restart.

**Verify:** re-run the ranking in §4.3 — the account's `pool:{uid}:spend` stops
growing; `/admin/alerts` shows no new entry for the same uid/day; `/usage` from
the app shows the new remaining percentage.

---

## 5. Storage / R2 errors

Storage is R2-only in production: the storage layer **refuses `fs`** when
`NODE_ENV=production` (`cloud/packages/storage/src/storageEnv.ts:50-52`), the
same rule `cloud/deploy/RUNBOOKS.md` I-10 restates. Provisioning, credentials,
lifecycle rules and the activation gates are in
**`cloud/deploy/R2-PROVISIONING.md`** — read it before touching anything here.

### 5.1 The three codes

| Code | Where it comes from | What it means operationally |
|---|---|---|
| **`r2_short_read`** | `cloud/packages/storage/src/rangeReader.ts:143-160` — a range `GET` returned **fewer bytes than requested** (or no body) | The object is **truncated/incomplete**, or the read was cut short. Not a client bug. Retry once; if it repeats for the same key, the object is bad — re-upload/re-hydrate, and run `verify-r2.mjs`. When it happens while reading a backup frame it is converted to **`archive_truncated`** (`cloud/packages/storage/src/archive/extract.ts:207-227`), which is what the user sees ("That backup could not be read"). The file service logs the StorageError and answers 500 `internal` (`cloud/apps/worker/src/fileService.ts:171-173`) |
| **`storage_not_configured`** | Gateway routes when `GatewayDeps.storage` is absent: artifacts (`cloud/apps/gateway/src/routes/artifacts.ts:93-101`), CDN URLs (`artifactCdn.ts:99-108`), artifact vault (`artifactVault.ts:163`); rationale in `app.ts:129-136` | **The deployment lost its storage adapter** — i.e. `OVID_STORAGE_BACKEND` / `OVID_R2_*` are missing from the env the process was started with. It is a 503 and it is loud by design. The app falls back from the CDN route to the canonical presign on this code (`lib/core/cloud/artifact_vault.dart:237-244`); if the canonical route also answers it, the user sees "File storage is unavailable right now." (`lib/core/cloud/cloud_errors.dart:601-607`) |
| **`disk_pressure`** | `cloud/packages/sandbox/src/manager.ts:337-345` (capacity guard: `freeGb < 2` **or** warm cache ≥ `OVID_MAX_WARM_GB`) and `cloud/packages/storage/src/warmLru.ts:649-657` (one `system_note {code:"disk_pressure", usedPct}` on the first crossing of `OVID_DISK_ALERT_PCT`) | **The box is out of room.** Sandbox attach is refused; the app renders "The workspace is out of space. Remove a file and try again." (`cloud_errors.dart:291-296`). Note the wire code for a refused attach is `sandbox_unavailable` (`cloud/apps/worker/src/runProcessor.ts:1194-1201`, `ptyBridge.ts:109-110`) — `disk_pressure` is the underlying reason, and the client copy exists for both |

`minFreeGb` is fixed at **2** and `OVID_MAX_WARM_GB` defaults to **8**
(`cloud/packages/sandbox/src/config.ts:169-170`); `OVID_DISK_ALERT_PCT`
defaults to **80** (`cloud/deploy/R2-PROVISIONING.md:107`).

### 5.2 Diagnose

```bash
# Are the credentials and backend actually in the env the process sees?
# (prints names only — never values)
grep -E '^OVID_STORAGE_BACKEND=|^OVID_R2_' \
  /opt/ovid-cloud/repo/cloud/deploy/.env | sed 's/=.*/=<set>/'
grep -E '^OVID_STORAGE_BACKEND=|^OVID_R2_' \
  /opt/ovid-cloud/worker.env | sed 's/=.*/=<set>/'

# Least-privilege probe: put/head/get/presign/delete. [OWNER] — uses live creds.
cd /opt/ovid-cloud/repo
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a
node cloud/scripts/verify-r2.mjs
# expected: seven [ok] lines (config, put, head, get, presign, delete, gone), exit 0

# Which layer is complaining?
journalctl -u ovid-worker -n 120 --no-pager | grep -iE 'r2|storage|hibernate|hydrate|attachment'
docker logs --tail=120 ovid-cloud-gateway-1 | grep -iE 'storage|artifact|r2'
docker compose -p ovid-cloud ps
```

Disk pressure (`cloud/deploy/RUNBOOKS.md` I-6):

```bash
df -h / /workspaces
du -xhd1 /workspaces/users 2>/dev/null | sort -h | tail -10
journalctl -u ovid-worker -n 60 --no-pager | grep -E 'warm sweep|disk usage'
```

### 5.3 Act

* **`r2_short_read` / `archive_truncated`:** retry (storage queues use BullMQ
  `attempts: 3` with backoff). If it persists for one key, treat the object as
  corrupt and re-derive it (re-upload, re-hydrate). Then `verify-r2.mjs`.
* **`storage_not_configured`:** fix the **env**, not the code. Confirm the
  storage block exists in **both** `/opt/ovid-cloud/repo/cloud/deploy/.env` and
  `/opt/ovid-cloud/worker.env` (`R2-PROVISIONING.md` §4.1-4.2), then:

  ```bash
  cd /opt/ovid-cloud/repo/cloud/deploy
  docker compose -p ovid-cloud config -q
  docker compose -p ovid-cloud up -d gateway          # [OWNER]
  sudo systemctl restart ovid-worker                  # [OWNER]
  ```

* **`disk_pressure`:** let the warm LRU evict; if it cannot keep up, lower
  `OVID_MAX_WARM_GB` and restart the worker, or prune backups past retention —
  **never** delete `/workspaces/users/<uid>` (`cloud/deploy/RUNBOOKS.md` I-6).

**Never flip `OVID_STORAGE_BACKEND=fs` in production.** Boot refuses it by
design, and once workspaces have been hibernated R2 is the only copy
(`R2-PROVISIONING.md` §"Rollback", `cloud/deploy/RUNBOOKS.md` I-10).

**Verify:** `verify-r2.mjs` seven `[ok]`; a cold file read on a scratch session;
`df -h / /workspaces` below 80 %.

---

## 6. Rollback

Two different operations share the word. Decide which one you need **before**
acting.

### 6.1 Halt a staged Play rollout (client side)

Play Console → **Test and release → Production → Releases** → the active
release → **Halt rollout** (set the new release to **0 %** and resume the
previous release). This is the documented rollback for the store side
(`cloud/deploy/ROLLOUT.md:376-379`).

* Halting stops **new** deliveries. It does **not** uninstall or downgrade
  anything already updated.
* Play **never accepts a lower `versionCode`** **`[NOT VERIFIED FROM REPO]`**
  (platform rule). The repo's rule is that every upload bumps `+N` — Play
  rejects a reused code (`docs/play/RELEASE-CHECKLIST.md` §1). The only real
  "rollback" for installed users is a **forward fix** with a bumped build
  number.
* Do not advance a rollout stage with an open abort signal — crash rate above
  the (unset) Q2 threshold, `run_failed` > 1 %, queue/worker alerts for > 2
  consecutive watch windows, any `lostEvents > 0`, or a security/privacy
  regression (`cloud/deploy/ROLLOUT.md:365-371`,
  `cloud/deploy/OWNER-GATES.md:1054-1059`).

### 6.2 Server-side rollback (shared gateway)

The cloud stack is shared by every installed client. A server rollback changes
behaviour for **all** of them at once, including builds you are not rolling
back.

```bash
cd /opt/ovid-cloud/repo
git log --oneline -10                       # pick the last known-good commit
git checkout "${GOOD_SHA:?set GOOD_SHA}"    # detached HEAD: record it in the incident
cd cloud && pnpm install --frozen-lockfile && pnpm -r build
cd deploy && ./provision.sh                 # applies only PENDING migrations; it cannot undo newer ones
docker compose -p ovid-cloud up -d --build  # [OWNER]
sudo systemctl restart ovid-worker          # [OWNER]
```

(`cloud/deploy/DEPLOY.md:313-326` for the deploy path, `RUNBOOKS.md` §0.1 for
the backup/validate rules.)

**What a server rollback does affect**

* Every client that talks to the services you rolled back — gateway, worker,
  and (via their own procedure) mint/LiteLLM.
* Route availability: a reverted route disappears for builds that call it. Check
  the per-client contract table before reverting a route
  (`docs/audit-2026-10-19/06-contract-leftovers.md`).
* Long-running work: a worker restart re-arms schedules and runs the stale-run
  sweeper (`cloud/deploy/RUNBOOKS.md` I-14, I-15).

**What it does not affect**

* The installed APK/AAB, its `versionCode`, or the Play rollout percentage.
* A client-side crash or ANR — the binary on the device is unchanged.
* Local chat history (`chat-history.db` in app storage).
* The database schema: migrations are applied by `provision.sh` / the migrate
  CLI, and the journal is authoritative — it applies every **pending** entry
  and has no down path (`cloud/deploy/R2-PROVISIONING.md:231-242`,
  `cloud/deploy/RUNBOOKS.md` I-12 "forward-only migrations"). Reverting code
  does not revert the schema.

Mint/LiteLLM have their own, smaller rollback: restore the step-1 backups and
restart both (`server/mint/README.md:414-440`); the hook can be disabled alone by
removing the `callbacks:` line.

### 6.3 Client-side levers that require a new build

| Lever | Where | Use |
|---|---|---|
| `--dart-define=OVID_UI_V1=true` | `lib/main.dart:47-53` | Ship the legacy shell instead of the v2 shell |
| `SessionHistoryRepository.disableSqlite()` | `lib/main.dart:191-193`, `session_history_store.dart:111-118` | Roll chat history back to SharedPreferences (ANR/migration escape hatch) |
| `OVID_ACCOUNT_ENABLED=false` (repo variable) | `.github/workflows/build.yml:85`, `docs/play/RELEASE-CHECKLIST.md:55-59` | Ship without in-app account deletion (web/email only) |

None of these take effect until users install the new build. They are not
incident levers; they are release decisions.

### 6.4 Order of operations

1. Confirm the defect is **client-side** (crash/ANR) or **server-side**
   (§0.3, §5.2).
2. Client-side → **halt the rollout**, then fix forward.
3. Server-side → roll the **specific service** back (mint/LiteLLM first if
   spend or model calls are involved), verify health, and only then consider
   the rollout.
4. Never do both at once: you lose the ability to attribute the change.

---

## 7. Escalation table

| Symptom | First check | Owner | Severity |
|---|---|---|---|
| Crash-free sessions < 99.5 % on the live version | Play → Crashes and ANRs, filtered to that versionCode (§1.1) | Owner (Play Console) + platform on-call | **SEV1** |
| App closes on launch for many users (boot crash) | Same page; Crashlytics for a `_boot` / `initializeCrashReporting` frame | Owner (Play Console) + platform on-call | **SEV1** |
| ANR rate > 0.5 % | Play → ANRs, main-thread stack (§2.4) | Owner (Play Console) | **SEV1** |
| Every sign-in fails | `curl -X POST https://api.ovidsi.com/account/login` → 5xx (§3.4) | Platform on-call | **SEV1** |
| Sign-in fails on Play installs, works sideloaded | Firebase SHA-1/SHA-256 for Play app signing (§3.3) | Owner (Play Console / Firebase) | **SEV1** |
| Global spend ≥ $20/day, or one uid far above its cap | `/admin/alerts`, then the spend ranking (§4.3) | Platform on-call | **SEV2** (SEV1 if the cause is unknown) |
| One account over its allowance / abusive | `/admin/user?q=…` | Platform on-call | **SEV3** |
| `storage_not_configured` (503) on artifacts | Env check + `verify-r2.mjs` (§5.2) | Infra owner | **SEV2** |
| `r2_short_read` / `archive_truncated` on one artifact | Retry, then `verify-r2.mjs` | Infra owner | **SEV3** |
| `disk_pressure` / rising `sandbox_unavailable` | `df -h`, warm-sweep logs (§5.2) | Infra owner | **SEV2** |
| Runs stuck / `run_lost` | `cloud/deploy/RUNBOOKS.md` I-14 | Platform on-call | **SEV2** |
| `key_not_minted` (409), `/usage` failing | `cloud/deploy/RUNBOOKS.md` I-11 (mint) | Platform on-call | **SEV1** |
| Runs fail `model_transient_exhausted` | `cloud/deploy/RUNBOOKS.md` I-12 (LiteLLM) | Platform on-call | **SEV2** |
| Suspected key/credential abuse | `cloud/deploy/RUNBOOKS.md` I-13 | Security on-call, then platform on-call | **SEV1** |
| Payment / plan not unlocking | Billing owner; `docs/play/REVENUECAT_SETUP.md` | Billing owner | **SEV2** |

Escalation rule from the spend gate: if the primary does not acknowledge within
**15 minutes**, page the infra owner (`docs/ops/M1_RUNBOOK.md:233-237`).

Never post raw uids, prompts, API keys or tokens in the incident channel — use
the `uid_hash` from the alert and look the user up with `/admin/user?q=`
(`docs/ops/M1_RUNBOOK.md:236-237`).

---

## Appendix A — command index

```bash
# Public health
curl -sf https://api.ovidsi.com/cloud/v1/health
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.ovidsi.com/account/login

# Box health
cd /opt/ovid-cloud/repo/cloud/deploy && docker compose -p ovid-cloud ps
curl -sf http://127.0.0.1:8082/cloud/v1/health

# Symbols
gh run list --repo aasheesh333/OvidAI --workflow build.yml --limit 30 \
  --json databaseId,headSha,createdAt,conclusion
gh run download "$RUN" --repo aasheesh333/OvidAI -n "Ovid-symbols-dart-$SHA" -D /tmp/ovid-symbols
gh run download "$RUN" --repo aasheesh333/OvidAI -n "Ovid-symbols-r8-mapping-$SHA" -D /tmp/ovid-r8
flutter symbolize --input /tmp/crash-dart.txt \
  --debug-info /tmp/ovid-symbols/app.android-arm64.symbols -o /tmp/crash-dart.sym.txt

# ANR / device
adb logcat -b events -d | grep -E 'am_anr|am_crash'
adb shell dumpsys dropbox --print data_app_anr | head -200
adb shell am start -W -n com.dhanuk.ovidai/.MainActivity

# Spend
set -a; . /opt/ovid-gateway/.env; set +a
export MK="${OVID_ADMIN_KEY:-$LITELLM_MASTER_KEY}"
curl -sS -H "Authorization: Bearer $MK" http://127.0.0.1:8090/admin/alerts?limit=50 | jq
curl -sS -H "Authorization: Bearer $MK" "http://127.0.0.1:8090/admin/user?q=$UID" | jq
docker exec -e RP="$REDIS_PASSWORD" -i ovid-gateway-redis-1 sh -c '
  for uid in $(redis-cli --no-auth-warning -a "$RP" -n 2 SMEMBERS ovid:uids); do
    v=$(redis-cli --no-auth-warning -a "$RP" -n 2 GET "pool:$uid:spend")
    [ -n "$v" ] && printf "%s %s\n" "$v" "$uid"
  done' | sort -rn | head -20

# Storage
cd /opt/ovid-cloud/repo
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a
node cloud/scripts/verify-r2.mjs
```

## Appendix B — not verifiable from this repo

These are marked in-line above; collected here so nobody mistakes them for
repo-backed facts.

1. **Console navigation grouping and button labels** — Play Console
   (`Quality` vs `Monitor` grouping, the "Halt rollout" button label) and the
   Firebase Crashlytics nav. The *page names* (`Android vitals`,
   `App bundle explorer`) are cited from repo docs; the grouping and button
   labels are console-version dependent.
2. **Play's own crash/ANR bad-behaviour thresholds** (the numbers Google uses to
   flag an app). The repo's numbers are the SLOs in
   `docs/architecture/SCALE_PLAN.md:862` and product spec §17 — not Play's.
3. **Play's "not enough data" cut-off** for vitals.
4. **Crashlytics retention** — the repo states the 90-day figure is a policy
   statement in `docs/legal/PRIVACY.md` and is **unverified** from the repo
   (`docs/play/DATA-SAFETY.md:126-130`).
5. **`flutter symbolize` flag spelling and symbol file names for Flutter
   3.47.4** — no Flutter SDK in this workspace; run `flutter symbolize --help`
   and `ls` on the downloaded artifact.
6. **`r8.jar` location and the Retrace invocation** — depends on the
   workstation; the repo only archives `mapping.txt`.
7. **Native (NDK) crash symbolication** — not possible from the archived
   artifacts (`android/app/build.gradle.kts:157-163`, `build.yml:261-277`).
   Verified as a *gap*, not as a procedure.
8. **`gh` artifact download requires repo read access** — the artifacts are
   private by design (`build.yml:255-260`).
9. **The R5 crash-rate abort threshold (Q2)** — never supplied; still an open
   owner input (`cloud/deploy/OWNER-GATES.md:120-140`). This runbook uses the
   99.5 % SLO as the halt number instead.
10. **`adb` commands** require a device/emulator with USB debugging; Play
    builds are not debuggable, so `run-as` (used to size `chat-history.db`) only
    works on a debug build.
11. **"Play never accepts a lower `versionCode`"** — platform rule, not stated
    in the repo; the repo only states that a reused code is rejected and every
    upload must bump `+N` (`docs/play/RELEASE-CHECKLIST.md` §1).
