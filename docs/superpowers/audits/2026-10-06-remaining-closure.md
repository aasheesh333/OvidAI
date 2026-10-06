# Ovid remaining-work closure report — 2026-10-06

**Scope:** Read-only reconciliation of the remaining work between the master plan,
the current git state, and the 2026-10-06 execution reports. This report does **not**
mark any new task complete. The only verified canonical task remains **W12.01**;
**76 of 77** acceptance scopes are open, plus every external gate.

**Sources compiled**
- Master plan: `docs/superpowers/plans/2026-10-03-ovid-master-repair-plan.md`
- Ledger: `docs/superpowers/audits/2026-10-03-ovid-progress.md`
- Master audit / feature matrix: `docs/superpowers/audits/2026-10-03-ovid-master-audit.md`, `...-feature-matrix.md`
- Signing runbook: `docs/superpowers/audits/2026-10-06-production-signing-runbook.md`
- Screenshot audit: `docs/superpowers/audits/2026-10-06-ui-screenshot-review.md`
- `/tmp/opencode/push-release-apk-aab.md`
- `/tmp/opencode/fix-*.md` (14 reports) and `/tmp/opencode/ui-finish-0*.md` (8 reports)
- Logs: `/tmp/opencode/fix-misc-verify.log`, `full-suite-*.log`, `prev-fail-rerun.log`, `traj-stress.log`

**Source availability (no fabrication)**
- `/tmp/opencode/final-*.md` — **absent.**
- `/tmp/opencode/integrate-*.md` — **absent.**
- `/tmp/opencode/finish-*.md` — **absent** (the only `finish`-named artifact is the log
  `/tmp/opencode/ui-finish-final.log`; the screenshot audit also names
  `/tmp/opencode/finish-screenshot-review.md`, which is **not present**).
- Consequently, the 2026-10-06 UI/fix reports and the two 2026-10-06 audits are the
  freshest first-hand sources. Nothing below infers content from missing files.

**Current git state (authoritative)**
- Branch `hoplite/gortyn-77773150`; HEAD `0171ea9`; `0` ahead / `0` behind
  `origin/hoplite/gortyn-77773150` (pushed).
- Working tree at first capture was clean except three untracked files
  (`2026-10-06-production-signing-runbook.md`, `2026-10-06-ui-screenshot-review.md`,
  `tool/ui_screenshot_review.py`). **During compilation, concurrent edits appeared**
  (not made by this report): modified `.github/workflows/device-test.yml`,
  `lib/core/settings_backup_service.dart`, `test/wave2_settings_backup_test.dart`; new
  untracked `2026-10-06-release-inventory-triage.md`, `lib/core/mcp_catalog_tools.dart`,
  `lib/core/reset_coordinator.dart`, `test/reset_coordinator_test.dart`,
  `test/wave2_mcp_catalog_tools_test.dart`, `test/wave2_mcp_oauth_ui_test.dart`.
  This is a point-in-time snapshot; re-check `git status` before relying on it.
- The plan/ledger statement “batch uncommitted, baseline `29c14e4`” is **stale**. The
  wave2 batch is now committed at `8b7a733` and pushed through `0171ea9`
  (`cf43693` style braces, `240038b`/`4171930`/`0171ea9` CI+tool).
- Stale/prunable worktrees remain registered (`wip/*`, `integration-regressions-baseline`);
  their directories are gone. No prune/reset/stash was performed.
- **Verification skew:** the “3987 passed / 4 skipped” full-Flutter result and the fresh
  analyzer/whitespace/backend passes were recorded against the **pre-commit** batch.
  HEAD adds `cf43693` (touches `lib/core/agent_service.dart`) plus CI/tool commits, so
  those results do not certify HEAD. Re-run is pending (section C).

---

## (A) EXTERNAL / BLOCKED — owner + exact action

These cannot be closed by repository edits. Owners are the roles named in the ledger’s
external-gate register; substitute the actual named operator before executing.

### A1. GPT-6 real upstream credentials — `EXT-PROVIDERS` (W00.03, W11.01, W14.04)
- **Owner:** gateway/provider operator (owner of the LiteLLM host and the upstream provider accounts).
- **Why blocked:** the app catalogues GPT-6 routes in
  `lib/core/model_limits.dart` (`cb/gpt-6-astra` :62; `cx/gpt-6-astra|luna|sol` :133-135;
  bare `gpt-6-astra|luna|sol` :154-156, :241-243, :252-253, :270), but real upstream base
  URLs + API keys for those routes are not confirmed present in LiteLLM.
- **Exact action:**
  1. Add the real upstream base URL and API key for each GPT-6 route to LiteLLM
     (`config.yaml`, dashboard, or LiteLLM Postgres), matching the prefix→backend mapping.
  2. Confirm `GET /v1/models` / `/model/info` lists the GPT-6 IDs and that `gpt-image-2`
     and the three image backends resolve.
  3. Run one bounded paid smoke per route and retain redacted receipts.
- **Closure evidence:** redacted `model/info` listing + one bounded paid response per route.
- **Note:** the image fallbacks `cb/gemini-2.5-flash-image`, `cb/gemini-3.1-flash-image`,
  `cb/gpt-image-2` (`server/images/config.json`) are covered by A2; they have never been
  exercised on a paid job (`server/images/README.md`).

### A2. Image gateway deploy + LiteLLM DB entries + AppCheck/admission — `EXT-AUTHORITY`, `EXT-HOSTING` (W03.03, W11.02–W11.05, W12.02–W12.03, W13.05, W16.06)
- **Owner:** cloud/gateway operator (mint host, e.g. `/opt/ovid-gateway`, + Postgres/Redis + Firebase project).
- **Why blocked:** `server/images/` and `server/shares/` are implemented but **not deployed**;
  the image router stays 503 until all host-supplied objects exist
  (`server/account/DEPLOYMENT.md` §3). The shared spend authority is explicitly external.
- **Exact action (from `server/account/DEPLOYMENT.md`):**
  1. Provision authoritative local stores: set `ACCOUNT_STORE_CONFIG` (distinct store UUIDs),
     run `python -m server.account.stores --provision`, apply
     `server/account/migrations/002_retry_schedule.sql`.
  2. **LiteLLM DB entries:** register the three image backends from `server/images/config.json`
     and the text model deployments in LiteLLM Postgres/config with real provider keys
     (provider keys are encrypted in LiteLLM Postgres, added via dashboard per the cloud-gateway design).
  3. Deploy the image router on the mint host:
     `mount_configured_images(mint, lifecycle, admin, stores, image_config_path, transport=InferHub, admission=shared_atomic_budget_admission, enforced_max_upstream_cost=...)`.
  4. **AppCheck/admission:** production Firebase App Check (client `lib/core/cloud_app_check.dart`,
     `firebase_service.dart`; server `VerifierAuth.verify_identity`) + the atomic text/image
     budget bridge; routes remain unavailable until the bridge and cost ceiling exist.
  5. Deploy shares viewer/API with `SHARE_BASE_URL`; install
     `server/account/deploy/ovid-account-worker.{service,timer}` and `ovid-retention.{service,timer}`.
- **Closure evidence:** real create/view/revoke, exact `/usage` settlement, deleting-account
  rejection, and `LiteLLM/Redis` reconciliation — not local SQLite confirmation.

### A3. Play signing + submission + devices — `EXT-RELEASE`, `EXT-PLAY` (W16.04–W16.07, W06.05, W10.01–W10.04, W16.01–W16.03)
- **Owner:** release owner (Play Console + signing keystore + device/emulator inventory).
- **Blockers / exact action (per `2026-10-06-production-signing-runbook.md`):**
  1. **Signing variable missing:** set repository variable `ANDROID_SIGNING_CERT_SHA256`
     (64-hex; derive per runbook §3; `gh variable set ... --repo aasheesh333/OvidAI`).
  2. **API 36 architecture (blocker 2, not yet code-resolved):** production requires
     targetSdk ≥ 36, but `android/app/build.gradle.kts:119` is target 28 because app-data
     `exec`/`dlopen` is blocked for API 29+ (`:111-127`). A target-only bump cannot pass.
     Requires the packaged-native-code architecture decision + real modern-target exec/dlopen probes (W16.04).
  3. **Submission:** after 1–2, dispatch
     `gh workflow run "Validate and Build Android" --ref main -f production_release=true`;
     upload to Play internal track and run the pre-launch report.
  4. **Console declarations:** target API, dynamic code, accessibility/AI automation,
     sensitive permissions, foreground service, data safety/deletion, billing, 16 KB page size.
  5. **Devices:** install delivered splits on API 23/24/26, modern ARM, and a 16 KB device;
     Billing Library 8 timeline remains independently unconfirmed.
- **Closure evidence:** signed APK/AAB identity, `release_inventory.py` `"passed": true` for
  both artifacts, device records, Play internal/pre-launch results.
- **Current build state:** the push release-candidate path (target 28, not Play-qualified)
  is implemented and committed (`240038b`, `/tmp/opencode/push-release-apk-aab.md`); the
  16 KB alignment/RELRO gate currently **records, not enforces** (`0171ea9`).

### A4. Firebase console — `EXT-FIREBASE`, `EXT-SMS` (W13.01–W13.04, W16.06)
- **Owner:** account owner — Firebase project `ovid-ai`, account `aasheeshkatheriya@gmail.com`.
- **Why blocked:** console operations need interactive owner authentication and credentials.
- **Exact action:**
  1. Register the actual Android app and **all SHA fingerprints including Play app signing**.
  2. Configure selected social providers: client IDs/secrets/redirects/authorized domains.
  3. Phone: confirm SMS billing/regions/quota (console currently shows 10 SMS/day, no billing change).
  4. Enable **production App Check**.
  5. Complete legacy email/password linking migration to the same UID, **then disable
     email/password** in console (still enabled pending migration).
  6. Execute real debug/release Google / social / phone OTP / link / reauth journeys.
- **Closure evidence:** redacted setup checklist with date/project/app identity and real
  same-UID provider journeys (no secret values recorded).

### A5. Other external provider credentials — `EXT-PROVIDERS` (W08.03, W09.05, W14.04)
- **Owner:** provider owners. **Action:** supply a designated GitHub test repository
  (`github_service.dart` flows), a real OAuth/MCP redirect/consent server (`mcp_service.dart`),
  and credentialed REST-provider smoke accounts. Closure: redacted smoke results.

---

## (B) CODE-ACTIONABLE — file-level next steps (no external dependency)

All rows are **open** unless marked. “Verified” means canonical acceptance closed.

| Task | Status | File-level next step |
|---|---|---|
| W12.01 | **Verified** | Do not reopen without contrary evidence. |
| W00.01 / W00.02 | Partial | `tool/release_inventory.py`: finish deterministic provenance/license + current signed-artifact/split inventory; reconcile payloads with git index. |
| W00.03 | Partial | Freeze provider/model ID pairs and duplicate-bare-ID routing cases; only the real capability probes are external (A1). |
| W01.03 | Pending | `lib/core/state.dart` (`_scheduleSessionDeletion`, `_pendingWorkspaceDeletions`, `awaitSessionDeletions`): add late append/write/reconnect + repeat-delete cases; close all session-owned stores under the barrier. |
| W01.05 | Partial | `lib/core/session_search.dart`: wire agent/account/startup/deletion callers and generation-bearing pagination. |
| W01.06 | Pending | `lib/core/startup_coordinator.dart`: bound each readiness item; hung marketplace/plugin/MCP/Firebase fixtures; late results only for current generation. |
| W02.01/.04 | Partial/Pending | `lib/core/agent_service.dart` admission; `lib/core/presets.dart`; `lib/ui/subagent_screen.dart`: snapshot provider/model/preset, child permission intersection, deny child-of-child. |
| W02.03 | Partial | `lib/core/agent_service.dart`, `lib/core/voice_input_service.dart`, `lib/ui/chat_screen.dart`: per-queued-turn attachment/voice snapshot; keep drafts on cancel/failure. |
| W03.01 | Pending | `lib/core/agent_service.dart` (transport boundaries `10387-10448,11163-11314,11918-11929,12436-12447`), `lib/core/state.dart:5873`, `lib/ui/usage_screen.dart`: stable attempt receipts for every transport/helper. |
| W04.01/.02/.04 | Partial/Pending | `lib/core/grant_store.dart:348-385`, `lib/core/workspace_files.dart`, `lib/core/native_plugins/rest_engine.dart`, `lib/core/native_mcp.dart`: use-time canonicalization, read-only shell denial, native/MCP parity, child intersection. |
| W05.01/.02 | Pending | `lib/core/pty_service.dart` (`OwnedProcessTree`), `lib/core/sandbox_service.dart:2503`, `lib/core/agent_service.dart:1513,1928,12020`: process-tree registration before spawn; propagate cancel to HTTP/MCP/hooks/fanout. |
| W06.01 | Awaiting review | `lib/ui/sandbox_setup.dart`, `lib/core/studio_setup_coordinator.dart`: close full acceptance review. |
| W06.02 | Pending | `lib/core/sandbox_service.dart`, `lib/core/sandbox_pkg.dart`, `lib/core/plugin_dependency_service.dart`: single-flight generation-owned installer; atomic publish; clean owned staging on cancel/failure. |
| W06.03/.04/.05 | Partial | `lib/core/sandbox_pkg.dart`: signed index metadata/native/bootstrap/manual routes, atomic publication/rollback; real split/runtime device proof (device gate in C). |
| W07.04 | Pending | `lib/core/plugin_runtime.dart`, `lib/core/plugin_dependency_service.dart:201`: native dependency config/readiness/restart rosters. |
| W08.03 | Pending | `lib/core/mcp_service.dart:213-247,646-753,939-1139`, `lib/core/mcp_config_parse.dart`: OAuth state/PKCE/redirect matching, single-flight refresh, generation-bound token removal (real provider in A5). |
| W08.04 | Partial | `lib/core/mcp_service.dart`: prompts/resources/templates/read + pagination/list-change invalidation + native validation. |
| W09.01/.04/.05 | Partial/Pending | `lib/ui/studio_editor.dart`, `lib/core/repo_cache.dart`, `lib/core/global_repo_registry.dart`, `lib/core/github_service.dart:462-476`: durable restart/screen-disposal drafts, mutable-buffer ABA, clone-collision/auth-restore races. |
| W10.01 | Pending | `lib/core/html_artifact.dart:121-149`, `lib/ui/html_artifact_view.dart`, `android/.../HtmlArtifactViewFactory.kt`, `OvidWebViewHandler.kt`: reproduce the 403 with a real failing trace before any policy change (remains HYPOTHESIS). |
| W10.03/.04 | Partial | `lib/core/html_artifact.dart`, `lib/ui/html_artifact_view.dart`, `OvidWebViewHandler.kt:410-431`: JS argument JSON-encoding, empty-find cancellation, per-view channel/capture/cookie ownership. |
| W11.03/.04 (client) | Partial | `lib/core/image_studio.dart`, `lib/core/image_receipt_store.dart`, `lib/ui/image_receipt_panel.dart`, and `_imageTool` in `lib/core/agent_service.dart`: client durable IDs/receipts/restart; **fix the leading-space regression** in `_imageTool` accounting prefix (wave2-images-report handoff). |
| W11.05 (client) | Partial | `lib/core/image_studio.dart`: account adapters, retention scheduling, local reset preserving `image_request_journal_v1.json`. |
| W12.02/.03 | Partial | `lib/core/conversation_share_service.dart` + `server/shares/`: wire verified admission/App Check and account-cleanup; deploy is external (A2). |
| W13.01/.03 | Partial | `lib/core/firebase_service.dart:128-177`, `lib/ui/auth_screen.dart`, `lib/ui/login_gate.dart`, `lib/ui/account_deletion_panel.dart`, `lib/core/account_service.dart`: provider-bound identity, legacy linking migration, complete account producer fences. |
| W13.05 | Partial | `server/account/{domain,postgres,worker,adapters}.py`: image/share composition, PostgreSQL locks/migration/multi-process; deployed authority is external (A2). |
| W14.01 | Pending | `lib/core/state.dart:1652-1665`, `lib/core/native_plugin.dart:70-139`: reconcile 87 capabilities / 19 prompt helpers against actual registry with per-tool evidence. |
| W14.02 | Awaiting review | `lib/core/native_plugins/prompt_framework.dart`, `lib/core/agent_service.dart:11163-11314`: close full review of normalized helper result + fanout. |
| W14.04/.05/.06 | Pending/Partial | `lib/core/native_plugins/rest_descriptors_*.dart`, `data_utilities.dart`, `web_and_db_utilities.dart`, `utility_sql.dart`, `utility_limits.dart`: per-service REST contracts, SQL/cron/DDL semantics, aggregate/heap quotas. |
| W15.02–W15.06 | Pending/Partial | `lib/core/settings_backup_service.dart`, `lib/core/settings_state_integration.dart`, `lib/core/state.dart`, `lib/ui/settings_*.dart`, `lib/core/memory_store.dart`, `lib/core/schedule_coordinator.dart`, `lib/core/voice_input_service.dart`, `lib/core/session_browser_profiles.dart`: all-store reset barrier, versioned export/restore, truthful controls, voice/schedule/memory lifecycle, UI polish. |
| W16.01 | Partial | `android/app/src/main/kotlin/com/dhanuk/ovidai/{AgentForegroundService,OvidAccessibilityService,ControlCornerGlow,MainActivity}.kt`: minimized-overlay/global-stop completion; device journeys in C. |
| W16.02 | Reviewed/device-pending | `OvidWebViewHandler.kt:410-431`, `MainActivity.kt:1487`: API23 teardown / API26 window-capture guard; device acceptance in C. |
| W16.03 | Partial | `android/app/src/main/jniLibs/*/libovid_bootstrap.so`, `tool/release_inventory.py`: current APK-set split/process-ABI delivery; device proof in C. |
| W16.04 | **Architecture-blocked** | `android/app/build.gradle.kts:111-127`: packaged-native-code architecture for API 29+ exec; only then the API 36 target. External Play policy decisions in A3. |
| W16.05 | Partial | `tool/release_inventory.py`: enforce (not merely record) 16 KB LOAD/RELRO; produce current signed artifacts; 78 ARM64 / 75 x86_64 bootstrap RELRO failures remain. |
| W16.06/.07 | Pending/Partial | Release qualification after A1–A4 and all W scopes; blocked gate stays pending, never relabeled done. |

---

## (C) VERIFICATION PENDING — sign-off / acceptance still owed

### C1. Screenshot visual sign-off (required)
- Artifacts: `/tmp/opencode/ui-finish-01.png` … `ui-finish-15.png`.
- Automated metrics exist only (`2026-10-06-ui-screenshot-review.md`); the audit
  **explicitly does not certify visual quality** and its author had no vision capability.
- **Owner:** a human or vision-capable reviewer. **Action:** open
  `/tmp/opencode/ui-review/index.html`, confirm per screen layout/spacing/alignment/
  text wrapping/contrast/touch targets/theming, and explicitly confirm or dismiss the
  edge/overflow heuristic flags on **02, 06, 07, 09, 10, 11, 15**.
- Note: the referenced `/tmp/opencode/finish-screenshot-review.md` is not present; the
  metrics HTML/JSON are the reviewer inputs.

### C2. Device acceptance (no adb devices were attached; none observed)
- W16.02: API 23/24/26 capture/teardown, no `NoSuchMethodError`/double-result/leaked surface.
- W16.01: home/recents/rotation/service-loss/permission-revoke overlay + global stop + mic.
- W06.05: real split installs and runtime version commands on ARM32/ARM64/x86_64.
- W10.01/.02: real WebView renderer trace (403) and fullscreen/rotation/background lifecycle.
- W16.03: bundletool APK-set installs and process-ABI comparison; upgrade/missing-split/reinstall.
- W16.05: 16 KB device installation/execution; Billing Library 8 confirmation.
- SMS: real-device OTP auto/manual/resend/expiry/rate-limit/link/reauth under release signing.
- Scheduler native: Doze/swipe/force-stop/reboot validation (not run in this environment).
- W16.07: Play internal-track + pre-launch report on delivered signed splits.

### C3. Re-verification on HEAD `0171ea9` (stale evidence)
- The verified full-Flutter result (3987 passed / 4 skipped), fresh analyzer, whitespace,
  and backend passes were produced against the **pre-commit** batch. HEAD includes
  `cf43693` (changes `lib/core/agent_service.dart`) and three CI/tool commits.
- **Action:** re-run on HEAD and record exact command/result:
  `/root/flutter/bin/flutter analyze`, the full `flutter test --no-pub --concurrency=2`,
  backend `server/{account,images,shares}/tests`, and `./gradlew :app:testDebugUnitTest`.
- The three untracked 2026-10-06 files (two audits + `tool/ui_screenshot_review.py`) are
  not in any commit; decide tracking separately (out of this report’s scope).

---

## Bottom line
- **Code-complete for the bounded batch:** yes — committed and pushed (`0171ea9`).
- **Production-ready:** **no.** Every external gate (A1–A5) is open, 76/77 acceptance
  scopes remain, the full-suite evidence predates HEAD, and no device/visual sign-off exists.
- **No completion is fabricated:** W12.01 is the only verified canonical task.
