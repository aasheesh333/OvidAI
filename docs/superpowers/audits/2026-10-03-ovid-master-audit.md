# Ovid master audit — 2026-10-03

**Execution plan:** [Ovid master repair plan](../plans/2026-10-03-ovid-master-repair-plan.md)

**Task ledger:** [Ovid progress](2026-10-03-ovid-progress.md)

**Coverage:** [Feature matrix](2026-10-03-ovid-feature-matrix.md)

## Mandate and evidence boundary

The user approved the entire audit/master plan, requested durable tracking of every task, and set Google Play production as the goal. Authentication must become **Google + configured social providers + phone OTP only**, managed through the real Firebase console; email/password sign-in, registration, reset, and password-based reauthentication must be removed. Studio setup must become approved, nonblocking work. Preserve the existing product promises while repairing their implementation.

This **2026-10-04** reconciliation owns the four master documents and its report. **The user currently authorizes commit/push; the integration controller will perform the next checkpoint.** This worker's documentation-only/no-Git scope does not restrict that authorization. Approved implementation, real Firebase console and final Play goals remain in force. Ten-worker baseline **29c14e4**, batch **uncommitted**. Per-task reviews/round fixes and final integration review accepted bounded work, not full canonical acceptance. **Final full Flutter verified3987 passed/4 skipped**; controller reports fresh full analyzer **No issues found (6.5s)**, `git diff --check` clean and backend **account56 +16 subtests, images35, shares30** passing. Earlier **3970/10fail/4skip**, then **3986/1fail/4skip** twice remain failed-run history; actual completion fixtures were repaired. Historical3468/4skip is not the latest result. Whitespace-clean does not imply a clean checkout. A source path, old checkbox/report or static `ready` label never establishes current runtime success.

Historical baseline observed2026-10-03 with `git status --short --branch`, `git rev-parse HEAD`, and `git branch --show-current`: clean `/root/OvidAI`, branch `hoplite/gortyn-77773150`, HEAD `afe3fc149dc774d999148c971397df45feb8e72c` (`afe3fc1`). Subsequent concurrent edits and authorized checkpoint pushes are preserved in the ledger as history; the current batch uses29c14e4 and remains uncommitted. Retain exclusive ownership and separately authorized shared-file integration. Record an actual worker model identifier only when supplied by the executing runtime, never infer one from preference or application catalog.

### Evidence vocabulary

- **SOURCE:** inspected behavior, data shape, or configuration in this checkout. Can establish a contract mismatch without establishing its frequency on devices.
- **HYPOTHESIS:** plausible incident mechanism requiring a reproduction; not a diagnosed cause.
- **REQUIRED VERIFICATION:** acceptance case retained from the approved scope; a task, not a finding that it currently fails.
- **EXTERNAL GATE:** needs credentials, interactive owner action, deployed service access, current policy review, or a device/release artifact.
- **HISTORICAL:** earlier plans/audits explain promises and past observations; results are not rerun or inherited here.

Source anchors in the findings below use historical baseline line numbers and symbols. They retain the original observations and acceptance obligations rather than describing every current defect. All repair tasks began pending; current reconciliation verifies W12.01 and keeps the other 76 scopes open.

Concurrent source/test edits appeared after the clean baseline during initial document verification. That historical observation remains in the ledger; this update appends the user-supplied execution handoff. These anchors capture the inspected baseline-era code rather than claiming the concurrently changing checkout still matches every line or still has every original defect.

### Bounded execution evidence — initial handoff (historical, 2026-10-03)

Evidence provenance: initial implementation/review/controller handoff. The following table preserves then-current failures and review boundaries; the current summary below supersedes them. Application suites were not rerun for prose. Exact commands or raw logs not supplied are not reconstructed. Counts are per run, **not an additive unique test total**.

| Batch | Actual reported result | Remaining boundary |
|---|---|---|
| B01 ledger/grants/search | 66 tests passed; ledger async serialization and isolate recovery corrected after review | Grants/root/search/ledger partial; full W01/W04 integration pending |
| B02 pkg | 39 passed, including fixes for relocation failures | Full supply-chain, runtime and ABI/device acceptance pending |
| B03 plugins UI | Grant 65 + UI 8 passed; confirmed-snapshot authority and masked-secret preservation corrected | Broader transactional plugin/config/permission obligations pending |
| B04 native guards | Initial 81 passed; native guards reviewed and accepted | W16.02 devices pending; full task remains unverified |
| B05 agent | 148 + queue 38 passed; helper route implemented | W14.02 awaiting review; agent/root integration remains partial |
| B06 setup | Studio setup 30 passed; W06.01 implemented | Awaiting review and remaining integration/runtime acceptance |
| B07 auth | 46 targeted passed; broader 93 passed / 4 stale `Forgot password` expectations failed | Stale expectations pending fix; integrated auth and real journeys pending |
| B08 overlay | 33 scoped passed | Flutter compile excluded due to concurrent edits; integration/devices pending |
| B09 chat | 57 passed; W12.01 header removal implemented | Awaiting review; hosted snapshots/viewer still pending |

At that historical checkpoint, analysis had passed before the latest auth/chat merges and the integrated full suite had not yet run. Those limitations are superseded by the following record.

### Historical implementation and verification summary — 2026-10-03

At that checkpoint: **77 canonical tasks: 1 verified (W12.01), 76 open.** The full Flutter log `/root/.local/share/opencode/tool-output/tool_102382fee001oEy10woyoMjN9N` was independently inspected and ends with `+3468 ~4: All tests passed!`; the controller then reported fresh analysis. The four old auth expectation failures and B08's excluded-Flutter-compile caveat were resolved. Focused setup **40**, cloud **58**, sharing **14 Flutter /10 Python**, artifact **8 Flutter** and plugin persistence **11** overlap that run. This is historical evidence, superseded as current integration status by the ten-worker record below.

| Tasks | Current-tree implementation inspected | Remaining acceptance |
|---|---|---|
| W12.01 | Chat header has no `ChatShareButton`; `share_actions.dart` remains a used import for image/file sharing; Settings retains Share Ovid. `chat_screen_bounded_test.dart` and `native_share_test.dart` are covered by the green full suite | Narrow header-removal scope verified; hosted links remain separate |
| W06.01 | `studio_setup_coordinator.dart` / `sandbox_setup.dart`: approved, nonblocking setup with navigation, retry and persisted operation state; focused40 | Full task review and separate installer/runtime acceptance |
| W03.02, W13.03 | `cloud_usage_store.dart`, `ovid_cloud_service.dart`, `cloud_app_check.dart`, usage/billing screens: shared reactive refresh, account/key fences and attestation; focused58 | Local usage persistence/hydration, all-account-producer coverage and exact deployed authority |
| W07.02, W07.03 | `hook_service.dart`, encrypted `hook_context_store.dart`, `hook_execution_scope.dart`, retryable `session_lifecycle_service.dart`; aggregation/restart/translation/env fixtures in full suite | Complete lifecycle/env/command/prompt/agent compatibility and secret-output acceptance |
| W10.02 | `html_artifact_view.dart`: true fullscreen route, native ownership and cancelled entry after collapse/navigation; focused8 | Standalone assets/encoding and real renderer/device lifecycle; 403 remains unproven |
| W12.02, W12.03 | `conversation_share_service.dart`, share sheet/sidebar and `server/shares/`: frozen text-only preview, owner-bound create/reconcile/revoke, escaped viewer, expiry/quota and cleanup primitive; focused14/10 | Not mounted/deployed; verified admission, worker cleanup wiring, expiry maintenance and live URL/cache checks |
| W13.01, W13.02 | Social/phone-only client auth, same-UID reauth and OTP lifecycle changes; full suite resolves earlier failed expectations | Legacy migration and actual signed Google/social/SMS/link/reauth journeys |
| W13.05 | `server/account/{domain,postgres,worker}.py`: durable request aliases, locked retry/backoff and fair due ordering; poison-first100/restart/cancel/concurrent-worker/migration fixtures inspected | Controller backend verification; complete production cleanup adapters and deployment |
| W05.03, W16.01 | `agent_service.dart` persistent global overlay Stop, queued/idle regressions and native overlay routing fixes; full Flutter suite follows B08 | All-owner lifecycle and actual native/overlay/mic/service/permission journeys |
| W04.03, W07.01, W14.03 | Plugin authority revoked before fallible persistence; retry UI and confirmed permission/config snapshots; focused11 | Full permission parity, transactional generations and secret/config audit |

Source fixes are bounded evidence, not closure of broader scopes. The [progress ledger](2026-10-03-ovid-progress.md) records the exact current statuses, full-run revision caveat and remaining gates. Preserve **permission-based autonomous Control** as explicitly required; the proposed static-workflow redesign was not approved. Modern-target architecture and Play eligibility still require evidence.

### Firebase operational evidence — 2026-10-03

Chrome verified account `aasheeshkatheriya@gmail.com` and project `ovid-ai`. Google was already enabled. Phone was enabled and **saved**, and the provider list confirmed it enabled. The console displayed **10 SMS/day** and an add-billing option to raise the limit; no billing change was made. Email/password remains enabled in the console pending verified legacy-account linking migration. See the progress operational log for remaining signing, provider, real OTP, App Check and release gates; W13.04 is partial, not verified.

### Play architecture blocker and official-source record — 2026-10-03

The Play audit reports fetching a requirement of **target API 36 from August 31, 2026**. Record that as the audit's fetched finding, pending independent confirmation of the current official text and applicability. The baseline target28 app-data executable/runtime design remains an architecture blocker; a target-only edit does not resolve it. Policy applicability and console decisions remain open.

| Official source | Required follow-up |
|---|---|
| [Target API policy — 11926878](https://support.google.com/googleplay/android-developer/answer/11926878) | Independently confirm reported API36 / August 31, 2026 deadline and applicable release rules |
| [Accessibility API policy — 10964491](https://support.google.com/googleplay/android-developer/answer/10964491) | Assess actual AI automation/accessibility behavior and required declarations |
| [Device/network abuse and dynamic code — 9888379](https://support.google.com/googleplay/android-developer/answer/9888379) | Resolve downloaded/extracted executable code and modern-target runtime architecture |
| [Payments policy — 9858738](https://support.google.com/googleplay/android-developer/answer/9858738) | Confirm applicable billing requirements for actual paid features |
| [Play Billing Library deprecation timeline](https://developer.android.com/google/play/billing/deprecation-faq) | Independently confirm Billing Library 8 timeline and applicability; no deadline inferred here |

No production-ready or Play-compliant conclusion follows from a policy fetch, local tests or provider enablement.

### Accepted bounded ten-worker evidence — 2026-10-04

Provenance: latest sections of `.superpowers/sdd/2026-10-03-ovid-master-repair-plan/parallel-*-report.md`, the batch contract and controller handoff. Reviews and round fixes were accepted; counts are overlapping run results, not additive unique totals. **77 canonical tasks:1 verified,49 partial,2 implemented/awaiting review,1 reviewed/device-pending,1 architecture-blocked,23 pending;76 open.** Full acceptance scopes below remain intact.

| Scope | Bounded evidence now accepted | Remaining acceptance |
|---|---|---|
| Studio W09.01/.04 | Per-binding/file mounted draft/undo/caret/conflict state; revision-checked saves, fetch/sync identities, failed-read retention and authorized AgentService save/reload lifetime fences.247 covering tests across compatibility+corrected audit runs;28 parallel regressions | Durable restart/screen-disposal drafts, mutable-buffer change-and-change-back revision contract, explicit cancel UI and full W09 acceptance |
| MCP W08.01/.04 | Shared reservation/deadline, late transport teardown, reconnect backoff/identity, terminal auth refusal; bounded validated tools catalogs/refresh and atomic ambiguous-import rejection.196 unfiltered passes after required-array/timeout-alias review fixes | Prompts/resources/templates/read, native catalog and wire-memory bounds, SSE invalidation, durable app status, process trees, full imports and live providers/devices |
| Search W01.05 | Standalone open/rebuild recovery, account/generation/tombstone fences, literal/advanced MATCH and bounded stable ordering.31 passes plus2 caller access tests | Agent snapshot/search generations, account/startup binding, deletion barrier and cross-call generation-bearing pagination **unwired**; device/storage integration |
| Packages W06.03/.04 | Bounded Debian version/alternative/virtual/ABI dependency closure; metadata-relative hashes, identity/extraction/combined-link graph validation and exact exits.128 covering passes after three link/readlink rounds | **No signed repository chain**, native/bootstrap/manual proof, atomic publication/rollback/concurrent-writer guarantee, app dependency health or shipped-tool/device proof |
| Utilities W14.05/.06 | CSV record scanner/roundtrip/rejection and regex isolate deadline/input/match/capture/output limits;92 passes | SQL lexer/validation, cron timezone/DST/horizon and DDL unchanged; CSV quotas, hard heap/concurrency limits, caller cancellation and other utility/device families |
| Hooks W07.02/.03 | Epoch-owned context/env, repeated start/end fixes, actual post-tool failure dispatch, operational decisions/credential rewrites parsed before separately redacted publication; broad109 then67 and diagnostic40 passes | Registry same-object ABA/immediate runtime invalidation, tool-capable agent hooks, orphan GC, global secret/descendant cancellation and full compatibility |
| Images W11.03–.05 | Exact durable Decimal/string receipts, quota-independent authenticated status reads, unknown reservations, typed verified nonacceptance only, finite retention/UID deletion fences; controller35 passes | Client durable IDs/receipts/restart/account fences, production nonacceptance verifier, shared text/image authority, account adapters, purge/WAL/backups/provider erasure |
| Shares W12.02/.03 | Snapshot revalidation, lock-time expiry, finite TTL, terminal purged receipts, real local contention/viewer/cache-origin coverage; controller30 passes | Real hosting/admission, cleanup composition, expiry scheduling, external cache/backups and live URLs; text-only scope unchanged |
| Account W13.05 | Acknowledged gateway/SQL/Redis cleanup substages persist across partial failure/restart; controller56 +16 subtests pass | Actual image/share adapters, PostgreSQL locks/migration/multi-process proof, deployed authority/Firebase and unacknowledged remote-effect windows |
| Release W00.02/W16.03–.05 | Actual payload/old APK/ELF/tool inventory and dated official policy observations below | Current production-signed artifacts, installed splits, devices, runtime/API/distribution decision and every external gate |

Integration fixtures now use valid MCP catalogs/actionable messages, a real temporary personal-memory/ledger cleanup fixture and actual session-end/composer-approval completion. Core+plugin573, subsequent core568, composer/policy55 and core-selector18 passed. The two earlier3986/1/4 runs remain historical failures. **Final full Flutter verified3987 passed/4 skipped** using `/root/flutter/bin/flutter test --no-pub --concurrency=2 --reporter expanded`; independently inspected `/tmp/opencode/parallel-integrated-flutter-complete.log:6448` ends `22:19 +3987 ~4: All tests passed!`. Controller freshly repeated full analysis (**No issues found,6.5s**) and `git diff --check` (clean). See the ledger for chronology; no application tests were rerun for prose and no full W/release closure follows.

### Release inventory and official policy reconciliation — 2026-10-04

Evidence was collected read-only by the release worker on2026-10-03 at29c14e4. It inspected actual bytes, not just source scripts. Three tracked ZIP-in-.so payloads total **45,040,718 bytes** and each contain102 real ELFs (**306 total**). Source/index/old APK bytes match. ARM64 includes9 keys,40 terminfo files and83 dpkg stanzas; ARM32/x86_64 lack those in-archive assets. Separate key assets exist and code seeds them, so absence inside a ZIP is not proof apt fails. No archive includes Node/Python/git/proot; notices describing bundled Node/Python need provenance reconciliation. Upstream tag metadata was fetched, but no verified deterministic derivation or complete source/license manifest exists.

The inspected universal APK is **115,854,915 bytes**, SHA-256 `b9a758fe3d65c45e5a7e492cb6fe6d34f55af21c481936e1261011cd503fadfd`, mtime2026-09-18, package `com.dhanuk.ovidai`, version1.0.0+1, min23/target28, **Android Debug signer**. It is not the current batch artifact. No AAB/APKS was found in the checked build roots; this does not negate the ledger's historical remote CI build/upload. ZIP16KB alignment passes; all204 64-bit bootstrap ELFs pass PT_LOAD, but **78/102 ARM64 and75/102 x86_64 fail GNU_RELRO end alignment** against the fetched guide criterion. Several outer APK libraries also fail. Static dependency-name closure is not Android linker/runtime proof. ARM32 alignment inventory is not a claim that Play requires ARM32 on a16KB kernel.

No device was connected; no actual app-process ELF exec/dlopen, split install or16KB runtime test occurred. Current `/system/bin/sh <data-script>` preflight only proves the system interpreter can read a script. The report proposes a separate target36 packaged-PIE/JNI exec/dlopen experiment; it was **not performed** and does not itself resolve autonomous Control's independent distribution gate. Release signing inputs/bundletool/emulator were absent in the checked locations; the existing Firebase injection file's validity was not established. Actual CI signing availability is not inferred from those local checks.

Exact official URLs below are from the release report, accessed2026-10-03; this documentation pass did not refetch them. Fetched policy text is evidence requiring release-owner applicability/console decisions, not approval.

| Official source | Reported observation and remaining gate |
|---|---|
| [Target API](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en) | New apps/updates API36 from August31,2026; existing availability floor35; extension requests to November1,2026. No app-specific extension established |
| [Android10 execution](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission) | Page updated October1,2026; target29+ writable app-home exec restrictions and executable mapping constraints. Script interpretation does not prove binary execution |
| [16KB guide](https://developer.android.com/guide/practices/page-sizes) | Updated September16,2026; target35+64-bit support and unsupported-update blocking February1,2027 reported. Retain LOAD/RELRO/ZIP and actual16384-page runtime requirements; recheck current release applicability |
| [Device/network abuse and FGS policy](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en) | Native-code downloads outside Play restricted; interpreter exception is bounded. FGS types/declarations must match perceptible, stoppable user-beneficial work. Hashes/specialUse do not create exemptions |
| [Accessibility API](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en) | Autonomous initiation/planning/execution prohibited except verified disability-primary tools; general assistants do not qualify merely through incidental assistance. November3,2021 dates declaration requirements, not a newly inferred automation effective date. Preserve Control; obtain actual distribution/API decision |
| [Sensitive permissions](https://support.google.com/googleplay/android-developer/answer/16558241?hl=en) | Contextual/minimum access, media declarations and Android16 sensor scope; contacts/location changes January27,2027 are future-dated |
| [All-files access](https://support.google.com/googleplay/android-developer/answer/10467955?hl=en) | Core permitted purpose and scoped-storage inadequacy/approval required; user folder selection alone is not eligibility proof |
| [SMS/call logs](https://support.google.com/googleplay/android-developer/answer/10208820?hl=en) | Default-role or reviewed conditional exception/declaration; device automation is not automatic entitlement. Future READ_CALL_LOG verification exception removal January27,2027; no such permission observed in old APK |
| [FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout) | Updated October1,2026; target35+ background dataSync6h/24h and prompt timeout stop. Modern-target lifecycle proof pending |
| [User Data](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en) and [account deletion](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en) | Real privacy/Data Safety including SDK/AI processing, public and in-app deletion plus service-provider cleanup; source/local tests do not establish deployed compliance |
| [Payments](https://support.google.com/googleplay/android-developer/answer/9858738?hl=en) | Actual paid digital-feature/region/program eligibility determination required; no blanket BYOK exemption inferred |
| [Policy deadlines](https://support.google.com/googleplay/android-developer/table/12921780?hl=en) | App registration/developer verification September30,2026 and future January27,2027 changes reported; owner-console status uninspected |

The [Billing Library deprecation timeline](https://developer.android.com/google/play/billing/deprecation-faq) remains an independent confirmation gate; this release report supplies no new Library8 proof. Preserve permission-based autonomous Control as instructed; consent, a metadata flag, packaged runtime or remote Studio alone does not resolve the observed Accessibility conflict. No device, exemption, console acceptance or production readiness is claimed.

## Corrections that must survive future handoffs

1. **Bootstrap payloads are tracked despite the ignore rule.** `.gitignore:70` ignores new matching files, but `git ls-files "android/app/src/main/jniLibs/*/libovid_bootstrap.so"` lists `arm64-v8a`, `armeabi-v7a`, and `x86_64` payloads. Do not report them absent/untracked because of `.gitignore`, and do not delete them as generated scratch. Packaging contents still need actual APK/AAB verification.
2. **Artifact data-URL 403 attribution is a HYPOTHESIS.** Native interception returns denied responses; the wrapper uses an opaque data origin and srcdoc. No failing device trace was captured here. Do not weaken network isolation on an assumed cause.
3. **No previous static source status means runtime working.** Historical `DONE`, durable startup states, catalog installation badges, comments, and test-file existence are separate from current verified end-to-end behavior.
4. **A target SDK bump alone cannot make this architecture Play-ready.** `android/app/build.gradle.kts:52-70` deliberately targets 28 because the sandbox executes extracted programs and loads libraries from app data. Modern target enforcement changes that execution model. A zip renamed `.so` is not a relocated executable runtime.
5. **Existing tests and fixes are real source assets, not new verification.** The prior polish audit records selected test results and a temporary debug Firebase fixture in another worktree. Those results/configuration are not evidence of this checkout's production Firebase or release readiness.

## Historical baseline findings and retained verification obligations

### W00 — Baseline, evidence, identifiers, and ownership

**SOURCE:** baseline above; `lib/core/state.dart:1645-1665` registers native capability groups; `server/images/config.json:1-9` names image backends. These identifiers are application routing data, not execution-worker identity.

**REQUIRED VERIFICATION:** inventory toolchains, suites, native payload provenance, real release requirements, and current application provider/model pairs. Preserve a command/result/environment record for each future gate. Shared hot files (`state.dart`, `agent_service.dart`, `MainActivity.kt`) need one writer at a time even if separate workstreams run concurrently.

### W01 — Hydration, persistence, startup, grants, deletion, ledger, FTS

**SOURCE:** `lib/main.dart:11-35` awaits first-frame state then starts readiness after rendering. `state.dart:2484-2492,2957-3035` splits shell and remaining hydration; `3817-3891` merges deferred sessions; `3916-3985` fingerprints and debounces persistence; `5397` is `deleteSession`. `grant_store.dart:281-317` delegates persistence to owners. `session_ledger.dart:106-149` increments in-memory sequence numbers, appends best-effort, and skips malformed replay lines. `session_search.dart:26-69` caches an opening future and rebuilds within a transaction without a rollback branch; `74-95` submits raw FTS MATCH input.

**REQUIRED VERIFICATION:** early user edits must survive deferred hydration, all mutable persisted fields including grants/artifacts must participate in dirty detection, failed writes must be visible/retryable, and deletion must fence late producers across all stores. Restore ledger sequence continuity before new append; protect reserved event fields and filename collisions; recover opening failures and failed FTS transactions. Search is derived account/session-scoped data, not a second authority. Startup timeouts must not allow stale readiness completion to resurrect removed plugins or sessions.

### W02 — Model, queue, admission, attachments, voice, presets, child actions

**SOURCE:** `agent_service.dart:5316-5356` owns preset policy; `5836-6077` builds/gates tool rosters; `9592-9739` admits runs and snapshots settings. `ui/chat_screen.dart:819-879` keeps session drafts; `core/presets.dart` defines model/policy presets; `core/voice_input_service.dart` owns speech input.

**REQUIRED VERIFICATION:** bind each admitted turn and queued item to account/session, exact provider/model, preset policy, attachments, and cancellation generation. Prevent duplicate sends and stale queue-row actions; retain attachments and voice transcripts through busy/interrupt/failure paths. Enforce child ownership and parent policy for all public child entry points, including UI actions and scheduled/invisible helpers.

### W03 — Complete, reactive, account-scoped usage

**SOURCE:** `agent_service.dart:10387-10448` handles turn usage and calls `appendUsage`; normalized transport results carry `usage` at `11918-11929,12436-12447`. Helpers at `11163-11314` call the model outside the main turn-accounting block. `state.dart:5873-5918` uses one preferences key, replacing the in-memory list during load and persisting asynchronously. `ui/usage_screen.dart:102-139` aggregates local BYOK/free rows while cloud usage is server-authoritative.

**REQUIRED VERIFICATION:** account for every actual request (all transports, retries, tools, titles, summaries, prompt helpers, fanout, children, image receipts), distinguish measured from estimated tokens, and deduplicate accounting without losing billable failed/cancelled attempts. Account changes must invalidate late responses and usage caches. Updating an open usage view must not require navigation to refresh. Do not invent prices from token estimates.

### W04 — Permissions at execution boundaries

**SOURCE:** `grant_store.dart:348-385` gives explicit denial precedence; `agent_service.dart:12690` calls `_readOnlyBlock`; `15662-15871,16444` contain shell/path/read-only checks. `workspace_files.dart:23` resolves a workspace symlink. Native capabilities, MCP, PTYs, hooks, and direct network/filesystem calls are additional dispatch surfaces.

**REQUIRED VERIFICATION:** canonicalize an existing ancestor plus nonexistent suffix and revalidate at use; reject traversal, symlink escape, and substitution races. Do not treat a command-name allowlist as proof of read-only execution: flags, redirection, substitutions, interpreters, pipelines, and executable config matter. Apply equivalent access checks to native REST/file/db tools, MCP, hooks, and shell paths. Child effective permission is the intersection of parent permission, child preset, session grants, and current revocations; aliases must not bypass it.

### W05 — Cancellation and lifecycle ownership

**SOURCE:** `agent_service.dart:1513` is `cancelAllRuns`; run checkpoints at `1928-1939`; late stream suppression at `12020-12035`. `sandbox_service.dart:2503` owns `_trackedRun`; `pty_service.dart` owns persistent shells. `agent_notification_service.dart`, `schedule_coordinator.dart`, and native stop receivers add independent entry points.

**REQUIRED VERIFICATION:** stop process trees, not just parent handles; cover a process spawned after cancellation begins. Abort HTTP/SSE/MCP requests, workflow steps, timers, pending approvals, voice, and schedule continuations, and prevent late callbacks from mutating a replacement run. Global stop must cover foreground/background/overlay actions and survive delayed initialization. Cancellation does not prove an upstream side effect was undone; preserve unknown-outcome receipts.

### W06 — Nonblocking Studio setup and runtime supply chain

**SOURCE:** `ui/sandbox_setup.dart:11-25,48-60,115-121` routes first-open Studio into an automatic non-dismissible full install. `sandbox_service.dart:615-639` starts installation; `1558-1695` selects payload ABI, computes dependency closure, and uses available SHA-256 metadata; `1798` patches shebangs; `2083-2110` reads payloads; `2873-2912` provides exit-checked execution. `sandbox_pkg.dart` has another package installation route.

**REQUIRED VERIFICATION:** replace the blocking gate with approved background setup, resumable truthful status, cancel/retry, and one installer per runtime generation. Validate signed index/package integrity on every installation path; fail missing hashes, unresolved dependency alternatives/cycles, architecture mismatch, extraction traversal, and partial install. Preserve nonzero exit failures even when output looks successful. Verify ARM payload/runtime availability, linker dependencies, prefix relocation, shebangs, ELF interpreter/RPATH, and API/ABI compatibility on device. W16 must resolve the production execution architecture.

### W07 — Transactional plugins and hook compatibility

**SOURCE:** `plugin_runtime.dart:1595-1627,1950,2332` exposes install/boot/uninstall; `plugin_dependency_service.dart:201-222` installs dependencies. `hook_service.dart:312-323` stores session context; `899-1018` constructs per-session environment files; `1236-1279` resolves hooks and replaces session context. `plugin_adapters.dart` translates plugin formats and environment/config metadata.

**REQUIRED VERIFICATION:** stage, validate, then atomically publish a plugin generation; on failure retain last working generation and clean only owned staging. Install/disable/uninstall/restart must fence stale hooks, tools, skills, MCP connections, and dependency callbacks. Aggregate hook contexts in stable plugin order with bounded lifetime; rebuild after restart and remove on disable. Translate [CC] events, matchers, result semantics, stdin, environment, and `${CLAUDE_PLUGIN_ROOT}` consistently. Native dependencies need the same approved install/configuration path and truthful readiness.

### W08 — MCP lifecycle, origins, OAuth, imports, resources

**SOURCE:** `mcp_service.dart:646-753` reserves a handshake slot under a budget; `213-247` accepts a scheme-bearing SSE endpoint and posts supplied headers to it. Relative endpoint resolution and origin policy need repair. `939-1013,1060-1139` store OAuth configuration/tokens and exchange/refresh tokens. `mcp_config_parse.dart:14-95` parses OAuth config. Native handler registration is at `mcp_service.dart:514-522`.

**REQUIRED VERIFICATION:** reserve before awaits, share intended connection work, close late-created transports on cancel/remove, bound reconnect, and ignore obsolete generations. Resolve relative SSE endpoints against the configured URL, validate scheme/origin/redirects, and never forward credentials across an unapproved origin. Complete real browser OAuth with PKCE/state and refresh ownership; token/config removal must survive late refresh. Import parsing must preserve command/args/env/headers/transport and reject ambiguous shapes without exposing secrets. Implement/verify tools, prompts, resources, templates, pagination and repeated-cursor bounds across stdio, HTTP, SSE, and native handlers.

### W09 — Studio data safety and GitHub reliability

**SOURCE:** `studio_editor.dart:279-331` writes editor changes into agent file buffers and accepts external updates; `studio_screen.dart:758-775` commits immediately with a fixed message. `repo_cache.dart:962-1016` snapshots dirty files but broadly falls back after atomic errors; `1047-1182` builds and updates a remote commit; `1189-1218` performs per-file fallback. `studio_screen.dart:338,478-522` chooses clone targets/rebinds; `github_service.dart:462-476` serializes credential persistence.

**REQUIRED VERIFICATION:** per-file/per-binding drafts and dirty state; immutable preview/approval of exact repository, branch, base SHA, paths, content/deletions, and message before commit. Do not overwrite upstream changes or silently broaden approved content. A lost response after ref update is unknown, not proof nothing was pushed; reconcile before fallback and prohibit duplicate writes. Serialize sync/fetch/save against generation changes. Detect clone-folder collisions and restore GitHub login without obsolete auth writes winning.

### W10 — Artifacts, previews, browser, native WebView

**SOURCE:** `html_artifact.dart:121-149` wraps user HTML in opaque srcdoc/CSP; `HtmlArtifactViewFactory.kt:88-94,138-145` uses data loading and denies intercepted resources. **HYPOTHESIS:** data-origin interception might explain reported 403; no reproduction here. `ui/html_artifact_view.dart:92-98,145-150` expands to 75% height rather than a full-screen route. `OvidWebViewHandler.kt:89,181,410-431` owns a method handler, injected JS, and PixelCopy. `repo_cache.dart:1293` exports previews.

**REQUIRED VERIFICATION:** reproduce with actual artifact/WebView version before changing policy; support true fullscreen and safe standalone previews. Encode JS arguments rather than interpolating arbitrary strings; empty find must clear results without stale callbacks. Register/dispose controllers and method handlers by owner; validate screenshot visibility/geometry and async teardown. Maintain intended shared browser login data with fresh session tabs and isolate artifacts; never globally clear cookies to clean up one artifact.

### W11 — Images, attestation, shared budget, exact receipts

**SOURCE:** `server/images/config.json:5-8` already configures **three** models: `cb/gemini-2.5-flash-image`, `cb/gemini-3.1-flash-image`, `cb/gpt-image-2`. Public alias remains `ovid-image`. `service.py:80-131,151-203` has durable idempotency/reservations and Decimal accounting with `MULTIPLIER = Decimal('0.30')`; it falls back on explicit 429/503, leaves ambiguous failures pending, and stores responses. `verifier.py:27-74` checks Firebase/App Check/key ownership; `77-85` explicitly requires an external atomic text/image admission bridge. `image_studio.dart:132-181` returns bytes and discards other response fields.

**REQUIRED VERIFICATION:** do not replace existing models with guessed alternatives. Confirm generation/edit/size support and nonbillable fallback semantics against actual providers. Integrate the real shared authority, enforce attestation in production, carry stable request IDs and server receipts through app restarts, and serialize exact money without floating-point conversion. No retry/new paid request after an ambiguous submission. Account/generation-bind capability refresh and results; define replay access, retention, expired replay behavior, and deletion cleanup while retaining minimal non-replay tombstones where needed to prevent duplicate charging.

### W12 — Sharing product contract

**SOURCE:** `ui/chat_screen.dart:1191` inserts `ChatShareButton`; `ui/share_actions.dart:26-52` offers transcript/file shares. Prior `2026-10-03-polish-errors-sharing-search.md:27-34` explicitly says no public chat-link backend exists.

**REQUIRED VERIFICATION:** remove the chat-header share action as requested; retain appropriate app/file/image sharing surfaces. Deliver an actual hosted immutable snapshot viewer, with explicit creation preview, unguessable identifier, owner-bound revoke/delete, safe rendering, size limits, and real URLs only. A local transcript file is not the promised hosted viewer. Coordinate snapshot account deletion/retention with W13/W15.

### W13 — Social/phone-only authentication and deletion

**SOURCE:** `firebase_service.dart:149-177` still accepts password reauthentication; `ui/auth_screen.dart` contains the present authentication UI. `firebase_service.dart:128-145` reacts to user changes using `account_session.dart`. `server/account/worker.py:7-15` processes due users sequentially; `postgres.py:46-53` takes the first 100 ordered rows. The old account plan's Google/email constraint is superseded by this approved social/phone-only requirement; its 24-hour cancellable server-owned deletion promise remains.

**REQUIRED VERIFICATION:** Google/social/phone enrollment, linking, collision recovery, same-UID reauthentication, OTP expiry/resend/rate limits, cancellation, and no email/password UI/service entry points. Fence every account-owned asynchronous result on logout/switch/deletion. Preserve deletion request idempotency/deadlines across restart, grace cancellation, partial adapter failures, and retries. A failing first batch must not starve later due accounts. Real Firebase interactive authentication, console provider setup, signing fingerprints, redirect credentials, phone regions/SMS billing, and release App Check are external gates.

### W14 — All built-in capabilities and real external contracts

**SOURCE:** `state.dart:1652-1665` registers the native families. Approved audit inventory is **87 built-in capabilities, including 19 prompt helpers**; W14 must reconcile an explicit per-capability/per-tool inventory, not infer completion from the count. `runPromptTool` and fanout read `choices[0].message.content` at `agent_service.dart:11200-11204,11303-11306`, while both real transports normalize to top-level `content` at `11918-11925,12436-12443`: a direct source-contract mismatch. Fanout resolves providers at `11244-11295` without preserving an explicit target model in its target tuple.

**SOURCE / REQUIRED VERIFICATION:** `native_plugin.dart:70-92` writes configuration field-by-field; `rest_engine.dart:11-44` supplies one REST abstraction for multiple contracts and returns upstream errors. Verify config transaction/migration and secret-value outputs, URL/query redaction, authenticated origin policy, service-specific errors in HTTP 200, path/body encoding, version headers, pagination, binary/multipart responses, and cancellation. CSV in `dev_utilities.dart:143` splits input by line, so quoted multiline fields need real parsing. SQL formatter/validator, cron, regex, and DDL builders in `data_utilities.dart:234,474,718` and `web_and_db_utilities.dart:788` need explicit supported grammar, semantic fixtures, and resource limits; don't label a heuristic validator a full SQL parser.

### W15 — Settings, telemetry, reset/restore, health, voice, schedule, memory, UI

**SOURCE:** `firebase_service.dart:83-120` initializes Firebase before restoring Dart consent. `AndroidManifest.xml:47-54,129-133` does not declare collection-off metadata for Analytics/Crashlytics. `settings_screen.dart:1167-1256` exports sessions and offers delete-all-data; `health_service.dart`, `voice_input_service.dart`, `schedule_coordinator.dart`, `memory_store.dart` implement additional stores/lifecycles.

**REQUIRED VERIFICATION:** native telemetry defaults off before SDK initialization and consent survives restart/revocation. Reset must stop producers and cover preferences, secure storage, sessions, ledgers, FTS, grants, plugin/MCP config, memory, schedules, browser profiles, images/previews/shares, and cloud identity state. Export/restore needs a versioned schema, explicit secret exclusions, corrupt-file handling, collision rules, and safe schedule/grant restoration. Each visible settings control needs persisted behavior and an honest health action. Verify voice interruption/language/errors, schedule timezone/DST/reboot/global-stop behavior, memory ownership/conflicts, and small-screen/keyboard/accessibility layouts.

### W16 — Control overlay, native compatibility, Play release

**SOURCE:** `AgentForegroundService.kt:90,99,158-163` calls `stopForeground(STOP_FOREGROUND_REMOVE)` despite min SDK 23; that overload requires API 24. `OvidWebViewHandler.kt:410-431` uses a PixelCopy window-source request beneath an API N check; validate the exact overload's API floor (window overload requires API 26). `MainActivity.kt:1487-1494` tears down control; `OvidAccessibilityService.kt:533-539,919` owns stop/destroy. `build.gradle.kts:3,35-44,52-70,88-99` defines min23, zip payload packaging, target28 and debug-sign fallback. The manifest declares broad accessibility, overlay-related service, all-files, SMS, and foreground service surfaces.

**REQUIRED VERIFICATION:** overlay only when minimized and Control is active, with steer/voice/question/minimize affordances and a global stop that reaches every owner. Guard API23 teardown/API24 capture paths correctly; no lifecycle crash or screenshot from another surface. Inspect delivered ABI splits, actual ELF dependencies and 16 KB page compatibility, release signing, manifests, and payload installation under the chosen modern target architecture. Check **current** Play target/API, code-download/execution, accessibility/AI automation, sensitive permissions, foreground-service, account deletion/data safety, payments and native-page-size policies against official sources and Play console decisions. No current policy compliance is claimed by this static audit.

## Preserved promises and precedence

- Earlier roadmap/specs remain historical scope: visual polish with Ovid branding, smooth streaming, compact numbers, ten recent model choices, scrollable AI questions, presets, queue/interrupt, child sessions, trajectory, search, memory, schedules, control disclosure, minimized overlay, voice, Studio/browser/GitHub, plugins/MCP and token efficiency.
- Best-effort background work until explicit stop remains a goal subject to actual OS/service limits; do not advertise guaranteed 24/7 execution or bypass force-stop.
- Current requested chat-header share removal, nonblocking approved Studio setup, social/phone-only auth and Play production take precedence over older contradictory product constraints. Existing app/file/image share and server-owned 24-hour deletion grace remain in scope.
- **Current user authorization permits commit/push; the controller owns the next checkpoint.** Baseline29c14e4 batch remains uncommitted until its actual revision is recorded. The documentation worker's narrower scope is not a user-wide Git prohibition. Preserve per-task ownership, bounded evidence and separately authorized serialized integration.
- Permission-based autonomous Control remains a core product requirement; a static-workflow replacement was not approved. Resolve runtime/distribution constraints while preserving that decision.

## External release gates

| Gate | Required action / evidence | Tasks |
|---|---|---|
| Firebase and social providers | Chrome account/project verified; Google preenabled and Phone saved enabled. Remaining: actual Android app config and debug/upload/Play signing SHA fingerprints, other configured provider credentials/redirects, real linking/reauth and legacy password migration | W13.01–W13.04 |
| Phone OTP | Provider enabled/saved; console shows 10 SMS/day, no billing change. Remaining: regions/quota/abuse setup as applicable, real automatic/manual OTP, resend, expiry and release signing/App Check cases | W13.02, W13.04 |
| Cloud authority | Access to deployed mint/budget authority absent from this repository; atomic shared text/image reservations, receipts, attestation, deletion adapters and reconciliation operations | W03.03, W11.02–W11.05, W13.05 |
| Provider/API credentials | Confirm each supported model/API operation using approved test accounts, redacted receipts and bounded spend; sandbox fixtures alone cannot pass this gate | W00.03, W08.04, W11.01, W14.04 |
| Play architecture/policy | Dated official requirements and console declarations; decision resolving target28 app-data execution before target uplift; policy outcome for accessibility, dynamic code, permissions/services, billing and deletion | W16.04–W16.06 |
| Actual release/device | Signed APK/AAB, bundletool-delivered splits, API23/24 and modern-target devices, ARM32/ARM64 and supported emulator ABI, 16 KB device, provider journeys, Play internal testing/pre-launch report | W16.03, W16.05–W16.07 |

**Release conclusion:** production readiness is not established. The linked plan turns every retained obligation into tracked work with concrete initial tasks and evidence gates.
