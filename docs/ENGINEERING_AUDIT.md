# Ovid — Engineering Audit

**Bugs · Issues · UI/UX · Production Readiness**

- **Branch:** `hoplite/gortyn-77773150` @ `f817418` (working tree clean)
- **Scope:** 80 Dart files / **92,392 LOC** in `lib/`, 181 test files / **74,389 LOC** in `test/`, Android native (5,316 LOC Kotlin), CI workflows, build config, assets.
- **Method:** static analysis (`grep`-driven pattern audit), config review, WCAG contrast computation, manual reading of the hot paths.

> **Limitation (honest):** `flutter analyze` and `flutter test` were **not executed** here — the on-device sandbox has no Dart/Flutter toolchain (node/python3/git/curl only; Flutter requires the proot-Ubuntu userland). CI runs both. All findings below are from static evidence, and each one names the file:line so it can be verified.

---

## 1. Verdict

| Area | Rating | Note |
|---|---|---|
| Architecture | **Good** | Real separation of concerns; ~12 focused services |
| Testing | **Very good** | ~2,540 tests, CI-enforced, 3m timeout rationale documented |
| Security | **Good** | Hardened storage, consent-gated telemetry, clean git history |
| Correctness | **Fair** | 327 silent `catch (_) {}`; ~10 unguarded `firstWhere`; **silent session-persist failure** |
| UI/UX | **Needs work** | Light theme fails WCAG broadly; system font scale ignored |
| **Store readiness** | **Not ready** | targetSdk 28 + no privacy policy + debug-keystore fallback |

The codebase is **far more mature than typical solo Flutter projects** — it has a hardening tracker, security tests, obfuscated release builds and pinned CI actions. The blockers below are mostly *policy/configuration*, not broken engineering.

---

## 2. P0 — Production blockers

### P0-1 · Light theme is unusable (measured, 20 failing contrast pairs)
`lib/core/theme.dart` defines a light palette but only overrides *some* semantic colors via the `*C` getters (`accentC`, `successC`, `dangerC`, `successLight`, `warnLight`). Any call site that reads `Aether.success` / `Aether.warn` / `Aether.accent` directly on a light background renders **unreadable** text.

| Token | on `bg` | on `surface` | Verdict |
|---|---|---|---|
| `accent` #679EFE | **2.55** | **2.66** | fails (needs 4.5) |
| `success` #22C55E | **2.18** | **2.28** | fails |
| `warn` #F59E0B | **2.06** | **2.15** | fails |
| `danger` #F25A5A | **3.15** | 3.29 | fails |
| `successC` #1FA05F | 3.22 | 3.36 | still fails |
| `accentC` #2563EB | 4.95 | 5.17 | ✅ the only correct one |

Dark mode is largely fine (**5 failing pairs**, all `textFaint`/`danger` on raised surfaces — see P2-2).
**Fix:** apply the `C`/`Light` variants at *every* semantic-color call site (or bake light-mode values into the getters), darken `success` to ≥4.5:1, and add a golden/contrast test so it can't regress. **Or** ship dark-only and delete the toggle.

### P0-2 · No privacy policy / Play Data Safety declaration
The manifest requests `READ_CONTACTS`, `ACCESS_FINE_LOCATION`, `SEND_SMS`, `CALL_PHONE`, `READ_CALENDAR`, `RECORD_AUDIO`, `CAMERA`, `READ_MEDIA_*`, `MANAGE_EXTERNAL_STORAGE`, plus Firebase Analytics + Crashlytics. There is **no `fastlane/` or `store/` directory, no privacy policy file, and zero "privacy" mentions in `README.md`/`SECURITY.md`**.
**Impact:** Play will reject; `MANAGE_EXTERNAL_STORAGE` and `SEND_SMS` require written justification forms; GDPR/DPDP obligations unmet.
**Fix:** publish a privacy policy URL, complete Data Safety, and prepare the All-Files-Access + SMS declaration narratives (the in-app consent gates are already a strong supporting argument).

### P0-3 · `targetSdk = 28` → sideload-only by design
`android/app/build.gradle.kts` pins `targetSdk = 28` and disables the `ExpiredTargetSdkVersion` lint. The in-file comment explains *why*: Android 10+ blocks `execve()` of app-private-dir binaries (SELinux `neverallow` on `app_data_file`), which kills the proot sandbox. Play's floor is 34/35.
**Impact:** **cannot be distributed on Play in its current form.** This is the single biggest product-level constraint.
**Fix (only real path):** relocate every exec'd binary + `dlopen`'d lib into `jniLibs` (`nativeLibraryDir` is the only exec-allowed path for targetSdk 29+), then bump. That is a large, risky change — decide explicitly whether Ovid is a sideload product or a Play product.

### P0-4 · Release signing falls back to the debug keystore
`build.gradle.kts`: `signingConfig = if (hasReleaseKeys) release else debug`. The gate is correct, but `android/keystore.properties` is gitignored, so **any build without CI secrets ships debug-signed** (unshippable, and re-signing later breaks update continuity).
**Fix:** fail the release build when `hasReleaseKeys == false` for `--release`/`appbundle` (currently it silently proceeds).

---

## 3. P1 — Correctness / robustness bugs

1. **`state.dart:5091` — `renameSession` crashes on a missing session**
   ```dart
   sessions.firstWhere((s) => s.id == id).title = title;   // no orElse → StateError
   ```
   Reachable when a rename arrives for a session deleted in the same frame (search results, ledger replay, queued rename). **Fix:** `final s = sessionById(id); if (s == null) return;`
2. **`firstWhere` without `orElse` — 48 sites, only 13 guarded.** Confirmed risky:
   - `state.dart:5091` (above)
   - `native_plugins/rest_descriptors_backend.dart:1106, 1158, 1223, 1247, 1352, 1396, 1680, 1784` — `backendDescriptors.firstWhere((d) => d.pluginName == 'Firebase MCP')` etc. A renamed/removed descriptor throws `StateError` during plugin construction.
   - `native_plugins/rest_descriptors_aimedia.dart:401, 466, 551, 677, 795, 838`, `rest_descriptors_dev.dart:670, 681, 693, 736`, `rest_descriptors_infra.dart:705` — same pattern.
   - `state.dart:6651` — double lookup in marketplace dedup (safe today, fragile).
   **Fix:** add a `firstWhereOrNull`-style helper and use it, or add `orElse` returning a typed sentinel + a logged error.
3. **327 empty `catch (_) {}` blocks.** Distribution: `state.dart` 116, `agent_service.dart` 110, `sandbox_service.dart` 77, `hook_service.dart` 38, `mcp_service.dart` 34. Most are legitimate best-effort paths, but there is **no logging seam**, so field failures are invisible and undiagnosable.
   **Fix:** route through a `Log.d/.w` wrapper (debug-only, R8-strippable) — a mechanical, low-risk change that instantly makes bug reports actionable.
4. **`print()` in production code** — `sandbox_service.dart:1827` (`// ignore: avoid_print`), plus 5 more in `native_plugins/sandbox_utilities.dart` (those are Python source strings — fine). **Fix:** use the logger from P1-3.
5. **`lastSessionPersistFailed` is write-only → silent chat-history loss** (verified)
   `state.dart:3943` / `3952` set the flag when a session write fails, and `_writeSessionsNow()` returns `false` — but a repo-wide grep finds **zero readers**: no UI banner, no retry, no telemetry, and **no test**. The B4 fix (whose own comment says *"record the failure so callers/UI can tell chat history is not durable"*) was only half-landed: the signal exists, nothing consumes it.
   Compounding it, `persistSessions()` completes its awaited completer via `_completeScheduledPersistence()` **before** the write result is known, so `await persistSessions()` reports success regardless of outcome.
   **Impact:** on a failed write (storage full, prefs corruption) the user keeps chatting on top of non-durable state and loses history on restart, with no warning.
   **Fix:** surface a persistent "chat history isn't being saved" banner from `lastSessionPersistFailed`, add a retry, and add the missing test.
6. **Silent keyring/asset failures** — `sandbox_service.dart` loads apt keyrings in a loop with a bare `catch (_) {}`; a missing asset degrades the sandbox with no user-visible signal.

---

## 4. P2 — UI/UX problems (quantified)

1. **The system font scale is ignored in the chat transcript** — `lib/ui/chat_screen.dart:105`:
   ```dart
   data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(AppState.I.chatFontScale))
   ```
   This **replaces** the OS text scale with the in-app slider (0.75–1.8). A user who sets Android font size to 200% sees **no change** in the app's primary surface. Only 2 `textScaler` references exist repo-wide.
   **Fix:** `TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * chatFontScale)` — compose, don't replace. (Tracker item **U2**, still open.)
2. **`Aether.hairline` is invisible in dark mode** — `_hairlineD = 0xFF232324` is *byte-identical* to `_surfaceD`. Every `Border.all(color: Aether.hairline)` on a surface card draws a 1px line at **1.00:1** contrast. 82 `Aether.hairline` usages, 65 `Border.all`. Even `hairlineStrong` is only 1.075:1 on `surfaceAlt`. Cards, inputs and sheets have **no visible edge**.
   **Fix:** set `hairline` to a value ~1.3–1.5:1 against `surface` (e.g. `#2E2E31`) and `hairlineStrong` ~1.8:1.
3. **Tiny type is systemic** — **198** uses of `fontSize: 10`/`11`, many with `textFaint` (221 usages). `textFaint` measures **4.24 / 3.76 / 3.26** on `surface` / `surfaceAlt` / `surfaceRaised` in dark — below AA for the body text it is used for.
   **Fix:** raise the floor to 12sp and reserve `textFaint` for ≥13px or non-essential chrome.
4. **Accessibility labelling is thin** — only **7 `Semantics(`** in all of `lib/ui` vs **59 `IconButton`** (53 carry tooltips → 6 unlabeled). Custom-painted widgets have no semantic labels. (Tracker item **U4**, open.)
5. **Destructive actions: guarded, but there is no undo layer** (tracker **U3**). 23 `showDialog` / 23 `AlertDialog` confirm sites exist, and session deletion is properly guarded on **both** paths — swipe (`sidebar.dart:350 confirmDismiss: _askDeleteConfirmed`) and button (`sidebar.dart:510`) — with the "accidental swipe deleted the chat" regression already fixed in code.
   **Still missing:** there is **no undo affordance anywhere** in the app — exactly **one `SnackBarAction`** exists in all of `lib/` (`chat_screen.dart:1867`) and it is not an undo. Destructive actions are confirm-or-nothing, so a mis-tapped confirm is unrecoverable.
6. **Android-only page transitions** — `theme.dart:116` registers only `TargetPlatform.android`; on any other platform the Material default applies. Latent inconsistency (harmless while only Android is scaffolded — there is no `ios/`, `web/`, `linux/`, `macos/` or `windows/` directory).
7. **No illustration/empty-state assets** — `pubspec.yaml` has no `assets:` block (only fonts are declared); first-run and empty states are text-only.
8. **Thin screen-level UI test coverage** — 14 UI/widget tests for ~12 screens; visual regressions surface late.

---

## 5. Architecture & maintainability

| File | LOC | Concern |
|---|---|---|
| `lib/core/agent_service.dart` | **19,951** | 18 classes in one file; the agent loop, approvals, queue, browser, tools |
| `lib/core/state.dart` | **8,708** | App-wide store + provider catalog + persistence |
| `lib/ui/chat_screen.dart` | **8,034** | Screen + layout + composer + markdown |
| `lib/core/sandbox_service.dart` | 3,810 | proot install, apt, keyring |
| `lib/ui/plugins_screen.dart` | 3,599 | |
| `lib/core/mcp_service.dart` | 2,816 | |
| `test/core_regression_test.dart` | **22,500** | single-file regression suite |

1. **God files.** `agent_service.dart` alone is 21% of `lib/`. Reviewability, merge conflicts and cold-start comprehension all suffer. Splitting the approval/queue/browser concerns out would be high-value, mechanical work.
2. **No network chokepoint.** The hardening tracker planned `OvidHttpClient` as a single egress point — **it does not exist**; there are **33 separate `http.Client()` instantiations** across `mcp_service.dart`, `native_mcp.dart`, `github_service.dart`, etc. SSRF defence is hand-rolled per call site (`agent_service.dart:14494+` blocks 169.254.169.254 / link-local / hex-encoded forms). A chokepoint is the only way to make timeouts, retries, redirect policy, TLS pinning and SSRF non-bypassable.
3. **Duplicated app chrome.** `chat_screen.dart` builds its own `Scaffold` + drawer in parallel with `lib/ui/shell.dart`'s `OvidShell` — two sources of truth for navigation, drawer state and the app bar.
4. **Empty-catch culture** (§3.3) is the dominant maintainability smell.
5. **One 22.5k-line test file** makes triage and parallelism worse than several themed files.

---

## 6. Security review — mostly strong

**Verified good:**
- Hardened `FlutterSecureStorage`: `encryptedSharedPreferences`, `resetOnError: false`, `AES_GCM_NoPadding`, `RSA_ECB_OAEPwithSHA_256andMGF1Padding` (`lib/core/secure_store.dart`); no bare `const FlutterSecureStorage()` remains.
- Telemetry (Analytics + Crashlytics) is **consent-gated**; Firebase init is guarded so the app runs without `google-services.json`.
- Per-session permission grants; device permissions sit behind an in-chat consent gate.
- `android:allowBackup="false"`, `usesCleartextTraffic="false"` + `network_security_config.xml` allowing cleartext **only** to `localhost` / `127.0.0.1` / `::1` (deliberate: the agent's dev-server preview).
- R8 `isMinifyEnabled` + `isShrinkResources` + `-renamesourcefileattribute` + `-assumenosideeffects` on `android.util.Log`; **no symbols artifact published** (tracker S2 genuinely done).
- **Git history is clean** — `google-services.json`, `*.jks`, `key.properties` were *never* committed (`git log --all --name-only` returns nothing), and `.gitignore` covers all of them.
- Root / hooking-framework / debugger detection (`SecurityCheck.kt`) with tests.
- SSRF: cloud-metadata and link-local endpoints refused, including hex-encoded IPv6 forms.
- CI: every action pinned to a commit SHA, `flutter pub get --enforce-lockfile`, `permissions: contents: read`.

**Gaps:**
- **`FLAG_SECURE` is deliberately absent** — enforced by `test/control_gestures_overlay_test.dart:396` ("FLAG_SECURE is gone from every layer"). Screenshot/Recents protection was intentionally dropped. Worth re-confirming now that the app stores API keys and OAuth tokens in-app: the trade-off (screen-sharing/accessibility overlay) is defensible, but it should be a conscious decision, not an inherited one.
- **`WebView` runs `JavaScriptMode.unrestricted`** (`agent_service.dart:3151`). Expected for a browser panel, but combined with per-session cookie jars, `OvidWebViewHandler` JS bridges and the accessibility overlay it deserves an explicit origin allowlist for injected-JS paths.
- **No privacy policy** (P0-2).
- `MANAGE_EXTERNAL_STORAGE` + `SEND_SMS` + `CALL_PHONE` are the highest-scrutiny permissions on Play; each needs a declaration form.

---

## 7. Testing & CI

**Strong:** ~**2,540 tests** (2,424 `test(` + 116 `testWidgets(`) across 181 files. `dart_test.yaml` raises the timeout to 3m with an excellent written rationale (parallel runs + real git ops). CI (`build.yml`) runs `flutter analyze` → `flutter test` → debug APK → signed release APK + AAB, with `--obfuscate --split-debug-info`, secret injection for Firebase/keystore, and a disk-space workaround documented inline. A second workflow (`device-test.yml`) boots an emulator with KVM for real device smoke tests. Test seams are thoughtful (`writeSessionsOnceForTest`, `awaitPendingSessionWritesForTest`, `suspendCoalescedPersistenceForTest`).

**Gaps:**
- Analyzer runs with **stock `flutter_lints` and no custom rules** — no `strict-raw-types`, `unawaited_futures`, `discarded_futures`, `use_build_context_synchronously` promotion, or `prefer_final_locals`. Given the fire-and-forget `persistSessions()` pattern, `discarded_futures` alone would catch real bugs.
- **No coverage gate**, no golden/screenshot tests, no integration tests in CI.
- Screen-level UI coverage is thin (§4.8).
- `device-test.yml` triggers on `ci/verified-android-build-20260827` only — the agent's `hoplite/**` branches don't get the emulator run.

---

## 8. Recommended fix order

| # | Fix | Effort | Payoff |
|---|---|---|---|
| 1 | Guard `renameSession` + add `firstWhereOrNull` helper across the ~10 risky sites | 1h | Removes a class of crashes |
| 2 | Surface `lastSessionPersistFailed` (banner + retry + test) | 2h | **Stops silent chat-history loss** |
| 3 | `hairline` / `hairlineStrong` dark values | 15m | Cards/inputs become visible |
| 4 | Compose (not replace) system `textScaler` in chat | 30m | Real a11y fix (U2) |
| 5 | Logger seam to replace 327 silent catches + `print()` | 3h | Field-diagnosable |
| 6 | Light-theme contrast pass + contrast regression test | 4h | Light mode usable |
| 7 | Fail release build when unsigned | 15m | No debug-signed releases |
| 8 | Raise 10/11px type floor | 2h | Legibility |
| 9 | `Semantics` labels + 48dp targets (U4) | 4h | A11y |
| 10 | Add an **undo** layer for destructive actions (U3 — confirms already exist) | 3h | Recoverable mistakes |
| 11 | `OvidHttpClient` chokepoint (33 call sites) | 2–3d | Security + reliability |
| 12 | Privacy policy + Data Safety + permission declarations | 1d | **Unblocks Play** |
| 13 | Split `agent_service.dart` / `core_regression_test.dart` | 2–3d | Maintainability |
| 14 | Decide sideload vs Play; if Play → jniLibs exec migration + targetSdk bump | weeks | **Strategic** |

---

## 9. Verified as deliberate — do NOT "fix" these

These look like bugs from a distance but are **intentional and documented**:

- **`targetSdk = 28`** — required for app-private-dir `exec()` (the sandbox). Documented in `build.gradle.kts` with the Play trade-off spelled out.
- **`FLAG_SECURE` absent** — enforced by a regression test (deliberate).
- **Cleartext allowed to localhost only** — for agent-run dev servers in the preview tab.
- **No `assets:` images** — fonts are declared via the `fonts:` block; there simply are no raster assets.
- **`defaultProvider => providers.first`** (`state.dart:4812`) — has **zero call sites** in `lib/` or `test/`, and `_seed()` (`state.dart:7742`) always populates the catalog, so it cannot throw today. Latent only; make it `providers.firstOrNull` opportunistically.
- **`catch (_)` in `_writeSessionsNow`** — not silent: it sets `lastSessionPersistFailed` and notifies listeners (B4 fix).
- **`persistSessions()` returning a future nobody awaits** — safe: `_ensureSessionWrite` + dirty-tracker + debounce flush on session switch/lifecycle pause.
- **"Select a provider" as a model value** — a deliberate sentinel, guarded at 10+ sites including the send path (`agent_service.dart:8481`, `chat_screen.dart:1863`).
- **Approval deadlock (tracker B1)** — **fixed**: approvals auto-deny after 120s (`agent_service.dart:14949`), with distinct messaging for "no approval UI" vs "unanswered".
- **~2,540 tests** — the "2400+" claim in `dart_test.yaml` is accurate.

---

## 10. Fix status — patches applied (2026-09-27)

Four fixes are **applied to the working tree** (uncommitted). They target the
issues that are both high-impact and provably safe to change in isolation.

| # | Issue | File | Change |
|---|---|---|---|
| 1 | `renameSession` threw `StateError` | `lib/core/state.dart:5090` | Replaced the unguarded `sessions.firstWhere(...)` with the existing `sessionById(id)` + null-return guard |
| 2 | Invisible card borders in dark mode (1.00:1) | `lib/core/theme.dart:21` | `_hairlineD` `0x232324` → `0x3A3A40`; `_hairlineStrongD` `0x313134` → `0x4A4A54` |
| 3 | System font scale ignored in chat (U2) | `lib/ui/chat_screen.dart:102` | Now **composes** `MediaQuery.textScalerOf(context).scale(1) * chatFontScale` instead of replacing it |
| 4 | `lastSessionPersistFailed` was write-only | `lib/ui/shell.dart` | Added a 3s watchdog + non-dismissible `_PersistWarningBanner`; the flag now has a reader |

**Measured contrast improvement (fix 2):**

| Border | on `surface` | on `surfaceRaised` | on `bg` |
|---|---|---|---|
| `hairline` before | **1.00** | 1.30 | — |
| `hairline` after | **1.39** | 1.07 | 1.61 |
| `hairlineStrong` before | — | 1.07 | — |
| `hairlineStrong` after | 1.79 | 1.38 | 2.08 |

**How these were verified (no Dart toolchain available):**
- Every patch was applied to the **live bytes** with an exact-match assertion
  (each pattern had to occur exactly once, else the script aborted).
- A comment/string-stripping delimiter-balance check compared the working tree
  against `git HEAD` for all four files: **all four balance identically**, so
  no stray `{`/`(`/`[` was introduced.
- Each change was re-read from the file after writing.

**Not verified:** `flutter analyze` / `flutter test` have **not** run. Treat
these as *unverified until CI is green*.

### Deliberately NOT changed (would be unsafe to do blind)

| Issue | Why deferred |
|---|---|
| Light-theme contrast (20 failing pairs) | The clean fix is making `accent`/`success`/`warn`/`danger` context-aware getters, but they appear in **~22 `const` expressions** across `lib/ui` (`const TextStyle(color: Aether.danger)`, `const _ChaseDot(Aether.accent)`, …). `const` requires compile-time constants, so this is a **compile-breaking** refactor that cannot be validated without `flutter analyze`. |
| `firstWhere` without `orElse` in `rest_descriptors_*.dart` (~11 sites) | Each capability needs a null/descriptor-missing fallback designed per plugin; a blind `orElse` risks a `LateInitializationError` or a wrong descriptor. |
| Splitting `agent_service.dart` (19,951 LOC) | Large mechanical refactor; needs the analyzer and the full test suite at every step. |

### Tooling hazard discovered (important for future edits)

`file_read` / `fs_edit view` serve a **stale snapshot** for this repo — e.g.
`chat_screen.dart` reads as **1,107 lines** when the live file is **8,034**,
and `state.dart` reads as 1,073 lines vs 8,708 live. Editing through those
tools can silently clobber thousands of lines. All patches above were applied
against the live bytes via shell with exact-match assertions. **Always confirm
a file's live line count (`wc -l`) before editing it in this repo.**

---

*Audit generated from branch `hoplite/gortyn-77773150` @ `f817418`.
`flutter analyze` / `flutter test` were not run in this environment — run them
in CI or a Flutter-enabled sandbox before treating any finding as closed.*

---

_Verification status (2026-09-27): the four patches and this document are committed locally as a611c53. Static verification only: exact-match assertions plus a delimiter-balance diff against HEAD. flutter analyze and flutter test were NOT run locally because no aarch64 host SDK exists; CI is the verifier._
