Plan: `docs/superpowers/plans/2026-10-03-ovid-master-repair-plan.md`
# Ovid master progress ledger — 2026-10-03

**Audit:** [Master audit](2026-10-03-ovid-master-audit.md). **Coverage:** [Feature matrix](2026-10-03-ovid-feature-matrix.md).

## Current status and authorization

- Documentation: current-tree reconciliation supersedes stale status/authorization statements in the explicitly historical evidence below; original acceptance scopes and run history are preserved.
- Implementation: **77 canonical tasks: W12.01 verified; 76 remain open**. W06.01 and W14.02 have bounded implementations awaiting full acceptance; W16.02 native guards were reviewed and accepted but devices remain pending. Usage reactivity, hooks, fullscreen, hosted snapshots, worker fairness and overlay stop now have partial implementations. Grants/root/search/ledger and wider integration remain partial.
- Current register counts: **1 verified, 37 partial/in progress, 2 implemented/awaiting review, 1 reviewed/device-pending, 1 architecture-blocked, 35 pending**. The 76 open tasks include every status except verified; DOC checkboxes are not part of the 77-task denominator.
- Historical baseline: clean `/root/OvidAI` checkout, feature branch `hoplite/gortyn-77773150`, HEAD `afe3fc149dc774d999148c971397df45feb8e72c` (`afe3fc1`). Continue in that existing feature-branch checkout, now dirty with concurrent implementation/test edits. This update owns only the four documentation files below; implementation outcomes are attributed to the supplied handoff, not rerun by this author.
- Authorization: **latest direct user instruction authorizes a checkpoint commit and push of completed work**, superseding the earlier no-commit/no-push restriction. Implementation, Firebase console and final Play work remain authorized. The controller owns backend/native verification and checkpoint commit/push; this reconciliation owns only the four documents. Exclusive file ownership and serialized shared-file integration apply. No worker-model selection is claimed.
- Corrections retained: ignored bootstrap payloads are tracked; artifact data-URL 403 is an unreproduced hypothesis; previous static source statuses do not establish runtime success; target28 app-data execution needs architectural resolution before Play target uplift.
- Latest integration checkpoint: see **Current-tree reconciliation** and **Review follow-up and integrated verification** below. Recorded full Flutter suite: **3,468 passed, 4 skipped**, raw log independently inspected; analyzer passed freshly in the controller's current turn. The earlier four auth expectation failures are resolved. Deployment, device and remaining W-task acceptance gates stay open.
- Product decision: user explicitly requires retaining permission-based autonomous Control as Ovid's core differentiator. The proposed static-workflow redesign was not approved. Preserve Control while resolving distribution/runtime requirements; permission alone has not established Play eligibility.

## Ownership

| Owner | Files | Scope/status |
|---|---|---|
| Current documentation author | `docs/superpowers/audits/2026-10-03-ovid-master-audit.md` | Evidence, corrections, preserved promises — documentation verified |
| Current documentation author | `docs/superpowers/plans/2026-10-03-ovid-master-repair-plan.md` | Canonical W00–W16 tasks and gates — documentation verified |
| Current documentation author | `docs/superpowers/audits/2026-10-03-ovid-feature-matrix.md` | Feature-to-task coverage and required release matrix — documentation verified |
| Current documentation author | `docs/superpowers/audits/2026-10-03-ovid-progress.md` | Durable status/ownership/evidence — documentation verified |
| Implementation owners / integration controller | Existing source/test edits for B01–B09 in this feature-branch checkout | Preserve current checkout ownership; bounded handoffs below identify subsystem boundaries. Exact worker names/claim logs were not supplied; do not infer or reassign ownership. |

Parallel rule: one writer per file. `state.dart`, `agent_service.dart`, `MainActivity.kt`, sandbox service and shared server authority require a named integration owner; subsystem workers submit bounded handoffs and tests instead of simultaneous edits to these files. Retain existing checkout claims and serialize integration. Read-only evidence collection can proceed independently. B01–B09 are evidence identifiers under existing tasks, not additional or replacement W tasks. Any genuinely new task gets an ID in the master plan and a row here before work starts.

## Documentation checklist

- [x] **DOC.01 — Verified:** read baseline/core evidence and retain corrections, historical promises and external gates with concrete source anchors.
- [x] **DOC.02 — Verified:** write canonical actionable W00–W16 checkboxes, dependencies, file ownership and acceptance evidence in the master plan.
- [x] **DOC.03 — Verified:** map every approved feature/workstream into the feature matrix and mirror every task in this ledger.
- [x] **DOC.04 — Verified (historical):** initial links, task-ID/count/status consistency, coverage and four owned documentation additions checked; original results retained below. Fresh update validation is recorded separately; application results come from implementation handoffs.

## Implementation task register

Canonical deliverables and acceptance experiments live in the plan. These rows mirror all 77 tasks and track execution. Bounded evidence moves a task to in progress, implemented/awaiting review, or reviewed/device-pending as appropriate; only full acceptance closes its plan checkbox. No test-file existence, old test result or source comment changes a status.

| Task | Bounded deliverable | Status | Evidence / gate |
|---|---|---|---|
| W00.01 | Reproducible baseline/toolchain/suite inventory | In progress — partial | Historical clean baseline and current dirty checkout recorded; B01–B09 handoff evidence available, complete reproducible inventory pending |
| W00.02 | Distribution inputs/payload provenance/signing inventory | Pending | Tracked payload observation recorded; artifact comparison not executed |
| W00.03 | Exact model/provider IDs and source ownership | In progress — partial | Existing feature-branch ownership retained; B05 bounded routing evidence, full provider/model inventory and probes pending |
| W01.01 | Hydration/live-edit generation safety | In progress — partial | Live identity and partial-history preservation reviewed; state follow-up136 passes. Account-generation acceptance remains open |
| W01.02 | Complete failure-aware persistence | In progress — partial | Nested signatures, pending deletion/write reconciliation and bounded saves reviewed; state follow-up136 passes. Full ownership/device acceptance remains open |
| W01.03 | Session deletion barrier/all owned stores | Pending | Late append/write/reconnect cleanup cases required |
| W01.04 | Ledger sequence/replay/close/delete integrity | In progress — partial | B01: 66 combined tests passed; async serialization + isolate recovery fixed after review. Full ledger/integration acceptance remains pending |
| W01.05 | Recoverable account-scoped FTS | In progress — partial | B01: included in 66 combined passes; full search/account/deletion integration pending |
| W01.06 | Truthful startup timeout/retry/disable | Pending | Hung and late obsolete item fixtures required |
| W02.01 | Immutable provider/model admission | In progress — partial | B05 agent 148 passes; full admission/provider identity acceptance pending |
| W02.02 | Unified queue/run admission and row IDs | In progress — partial | B05 queue 38 passes and B09 chat 57; full concurrent admission/integration acceptance pending |
| W02.03 | Attachment/voice draft ownership | In progress — partial | B09 bounded chat evidence; full delayed input/session/voice/device cases pending |
| W02.04 | Preset policy and child UI/action ownership | Pending | Model/policy migration and stale child cases required |
| W03.01 | All-transport/helper attempt metering | Pending | Real protocol fixtures including retry/cancel required |
| W03.02 | Reactive account-scoped usage persistence | In progress — partial | CloudUsageStore shares reactive usage/billing refresh with account/key generation fences; focused cloud58 and integrated Flutter evidence. Local usage-log delayed hydration, serialized persistence and complete account partitioning remain open |
| W03.03 | Exact authoritative cloud receipts | Pending | Shared authority integration and deployed reconciliation required |
| W04.01 | Use-time filesystem canonicalization | In progress — partial | B01 grants/root evidence within combined 66 passes; complete use-time/path/race acceptance pending |
| W04.02 | Read-only shell semantics | Pending | Flags/substitution/redirection/config/PTY cases required |
| W04.03 | Native/plugin/MCP permission parity | In progress — partial | B03 grant65/UI8 plus plugin persistence11 and full Flutter; confirmed authority and immediate revoke-before-write/Retry fixed. Full dispatch/alias/redirect parity pending |
| W04.04 | Parent-child permission intersection/revocation | Pending | Late child and revoked grant cases required |
| W05.01 | Process trees and late spawn cancellation | Pending | Parent/grandchild/paused-spawn fixtures required |
| W05.02 | Workflow/network resource cancellation | Pending | Pending step/network/approval and unknown outcome cases required |
| W05.03 | Lifecycle-persistent global stop | In progress — partial | Overlay Stop now routes through persistent background stop; queued-run and idle regressions included in full Flutter suite. Complete boot/resume/service/schedule/owner and device acceptance pending |
| W06.01 | Approved nonblocking Studio setup | Implemented — awaiting review | Initial B06 setup30 superseded by focused setup40 and full Flutter evidence; approval/navigation/retry/persistence fixes present. Full acceptance review pending; broader installer/runtime tasks remain open |
| W06.02 | Single-flight staged installer | Pending | Multi-caller/cancel/restart/failure publication cases required |
| W06.03 | Signed metadata/package integrity/exit code | In progress — partial | B02 pkg39 passed; all installation routes and supply-chain acceptance pending |
| W06.04 | Complete bounded dependency graph | In progress — partial | B02 bounded package evidence; full graph/ABI/closure acceptance pending |
| W06.05 | Runtime relocation/ARM/ABI proof | In progress — partial | B02 pkg39 includes relocation-failure fixes; actual supported split/runtime devices pending |
| W07.01 | Transactional plugin generations | In progress — partial | B03 grant65/UI8 plus plugin persistence11 and full Flutter; immediate unregister/disable before fallible revoke and retry UI fixed. Full transactional generation acceptance pending |
| W07.02 | Aggregated hook context and restart env | In progress — partial | Per-plugin context aggregation, encrypted explicit-context restart store, descriptor reconciliation and retryable session activation implemented; hook_w07/hook_context_restart/session lifecycle fixtures included in full Flutter suite. Complete lifecycle/environment acceptance pending |
| W07.03 | [CC] event/input/output/env translation | In progress — partial | Hook event/tool translation, stdin/env/root execution scope and output-context handling repaired with hook_w07 fixtures in full Flutter suite. Full command/prompt/agent compatibility and secret-output audit remain open |
| W07.04 | Native dependency configuration/readiness | Pending | Denied/missing/configured/removed/restart cases required |
| W08.01 | MCP reserve/connect/cancel/reconnect | Pending | Concurrent handshake/late transport/obsolete retry cases required |
| W08.02 | SSE endpoint/redirect origin constraints | In progress — partial | Origin/redirect constraints and live policy-refusal propagation reviewed;86 focused passes. Canonical integration closure pending |
| W08.03 | OAuth/PKCE/refresh/token removal | Pending | Cancel/wrong-state/late-refresh fixtures and real provider required |
| W08.04 | MCP imports/resources/protocol pagination | Pending | All transport fixtures and real configured server checks required |
| W09.01 | Per-file/binding Studio drafts | Pending | Multi-tab/external-write/conflict/save cases required |
| W09.02 | Immutable approved commit snapshot | In progress — partial | Frozen binding/base/bytes/message/selection plus explicit executable-mode and missing-checkout deletion staging reviewed;319 covering tests,90 fresh controller tests; full acceptance closure pending |
| W09.03 | Upstream conflict/unknown result/fallback | In progress — partial | Single-send nonforce publication and mode-aware durable unknown recovery reviewed, including legacy intents and later-edit retention; full acceptance closure pending |
| W09.04 | Sync/save/fetch ordering | Pending | Reversed responses/concurrent edit/cancel cases required |
| W09.05 | Clone collision and GitHub auth restore | Pending | Folder/auth races and real GitHub test repository required |
| W10.01 | Artifact 403 reproduction/isolation | Pending | HYPOTHESIS; real failing WebView trace absent |
| W10.02 | True fullscreen and standalone previews | In progress — partial | Real fullscreen route and generation/route/collapse cancellation implemented; artifact8 focused Flutter passes plus full suite. Standalone asset/encoding and actual renderer/device lifecycle acceptance pending |
| W10.03 | JS argument encoding and empty find | In progress — partial | B05 agent/browser bounded evidence; complete adversarial string/stale-query integration pending |
| W10.04 | Browser controller/handler/capture/cookie ownership | In progress — partial | B04 native guards accepted; complete concurrent controller/cookie/device capture acceptance pending |
| W11.01 | Verify three configured image fallbacks | Pending | Real provider operation/size/nonbillable refusal receipts required |
| W11.02 | Attested shared text/image admission | Pending | External authority and production App Check required |
| W11.03 | Durable request receipts/exact money | Pending | Decimal/replay/settlement/restart cases required |
| W11.04 | No ambiguous paid resubmission | Pending | Accepted/lost/malformed/crash reconciliation cases required |
| W11.05 | Image retention/replay/delete/account fences | Pending | Cross-account/expiry/pending cleanup and adapters required |
| W12.01 | Remove chat-header share | Verified | Source/header review plus chat_screen_bounded/native_share checks in full Flutter run; Share Ovid and image/file dispatch preserved. See current-tree evidence for exact scope |
| W12.02 | Approved immutable hosted snapshots | In progress — partial | Account-bound frozen text preview/service/sidebar and server API/repository implemented; sharing14 Flutter +10 Python and full Flutter evidence. Actual deployment/admission/privacy acceptance remains open; assets are explicitly excluded |
| W12.03 | Safe viewer/revoke/expiry/account cleanup | In progress — partial | Escaped text viewer, owner revoke, no-store responses, expiry/quota and cleanup primitive implemented; sharing14 Flutter +10 Python. Live URL/cache behavior, cleanup wiring and expiry scheduling pending |
| W13.01 | Social/phone-only auth/linking/reauth | In progress — partial | Social/phone auth and same-UID flows implemented; full Flutter suite resolves all four earlier stale Forgot password expectations. Legacy console migration and real provider journeys pending |
| W13.02 | Phone OTP callback/resend/expiry lifecycle | In progress — partial | B07 auth evidence; Phone enabled/saved in real console. Real SMS/lifecycle/release journeys pending |
| W13.03 | All account-owned producer fences | In progress — partial | Auth/cloud/share account-bound response and key checks present; focused cloud58/sharing14 plus full Flutter evidence. Complete run/image/plugin/browser/store producer inventory and A→B acceptance pending |
| W13.04 | Real Firebase/social/SMS console activation | In progress — partial | Chrome account/project verified; Google preenabled, Phone saved enabled. SMS10/day; no billing change. Email/password enabled pending migration; remaining provider/signing/App Check/live gates open |
| W13.05 | Idempotent deletion and fair worker | In progress — partial | Durable request aliases, locked retry checkpoints/backoff and fair PostgreSQL due ordering implemented; poison-first100, concurrent-worker, restart/cancel and migration tests inspected. Controller verifying backend; production adapters/cleanup/deployment remain open |
| W14.01 | Inventory 87 capabilities/19 prompt helpers | Pending | Explicit registry/per-tool reconciliation and evidence required |
| W14.02 | Normalized helper response and exact model fanout | Implemented — awaiting review | B05: helper route implemented; agent148 + queue38 passed. Review and full integration/accounting/cancellation acceptance pending |
| W14.03 | Transactional native config/secret outputs | In progress — partial | B03 masked-secret preservation/confirmed config fixed; grant65/UI8 and full Flutter evidence. Full native transactional config/output audit pending |
| W14.04 | Per-tool real REST contracts | Pending | Descriptor fixtures plus actual provider credentials required |
| W14.05 | CSV/SQL/cron/DDL correctness | Pending | Grammar/round-trip/DST/dialect execution corpus required |
| W14.06 | Regex/utility resource bounds | Pending | Adversarial CPU/memory/output cancellation cases required |
| W15.01 | Native telemetry default off/consent lifecycle | In progress — partial | B04 initial native evidence; merged release manifest and actual pre-Dart consent lifecycle verification pending |
| W15.02 | All-store reset stop barrier | Pending | Seeded cleanup manifest/partial failure/late producer cases required |
| W15.03 | Versioned portable export/restore | Pending | Round-trip/collision/secret/archive/atomic-failure cases required |
| W15.04 | Truthful settings/permission/health controls | Pending | Every control store/effect/restart/revoke/repair case required |
| W15.05 | Voice/schedule/memory complete lifecycle | Pending | Fake-clock/scope/revision fixtures and mic/alarm devices required |
| W15.06 | Full UI polish/accessibility/token efficiency | In progress — partial | B03/B06/B09 bounded UI results; complete feature journeys/layout/device acceptance pending |
| W16.01 | Minimized overlay and global stop | In progress — partial | Native overlay/voice/question routing and Dart persistent global-stop changes present; B08 scoped33 followed by full Flutter suite including queued/idle stop fixtures. Real home/recents/rotation/service-loss/permission/mic journeys pending |
| W16.02 | API23 teardown/API24/26 capture guards | Reviewed/accepted — devices pending | B04: native guards reviewed and accepted with initial81 passes; required devices and integrated release acceptance still pending |
| W16.03 | Process-ABI payload delivery | Pending | Actual APK-set splits/install/update/runtime evidence required |
| W16.04 | Modern-target runtime architecture/current Play policy | In progress — architecture blocked | Play audit reports fetched API36 / August 31, 2026; official links and independent-confirmation gates below. Modern-target exec/dlopen architecture proof pending |
| W16.05 | Signed APK/AAB/ELF/16 KB inspection | Pending | Real signing/Firebase inputs, builds and 16 KB device required |
| W16.06 | Production services/providers/console gates | Pending | Deployed auth/budget/deletion/share/provider journeys required |
| W16.07 | Integrated release qualification | In progress — partial | Full Flutter3468 passed/4 skipped and fresh analyzer passed; controller owns current backend/native verification. Signed artifacts, complete device/provider matrix, Play internal results and remaining acceptance gates required |

## External gate register

All gates remain open; Firebase/Phone activation has partial operational evidence. Dependencies can be worked on locally while remaining owner actions are arranged; do not substitute fake production config or mark dependent end-to-end tasks verified.

| Gate | Owner/action needed | Evidence required before closure | Affected tasks |
|---|---|---|---|
| EXT-FIREBASE | Account/project verified in Chrome; Google preenabled, Phone saved enabled. Complete remaining app/signing/provider/App Check configuration and legacy linking migration before disabling email/password | Actual package and signing fingerprints, configured provider credentials/redirects, release App Check and same-UID journeys; no secret values in ledger | W13.01, W13.03, W13.04, W16.06 |
| EXT-SMS | Phone enabled/saved; console shows 10 SMS/day with add-billing option. No billing change made; remaining regions/quota/abuse and billing decisions as applicable | Real-device OTP auto/manual, resend/expiry/rate-limit/link/reauth under release signing | W13.02, W13.04, W16.06 |
| EXT-AUTHORITY | Cloud operator provides actual mint/shared text-image budget authority and deployment/cleanup integration | Atomic concurrency/receipt/replay/reconciliation and deleting-account rejection; no synthetic read-modify-write budget substitute | W03.03, W11.02–W11.05, W13.05 |
| EXT-PROVIDERS | Owners provide configured MCP/API/GitHub/image test accounts and bounded paid-probe authorization | Redacted actual contract/size/fallback receipts and OAuth/API/GitHub smoke results | W00.03, W08.03, W08.04, W09.05, W11.01, W14.04 |
| EXT-HOSTING | Service owner deploys snapshot viewer/API and account cleanup worker/adapters | Real create/view/revoke/cache/expiry/deletion evidence and fair durable cleanup operation | W12.02, W12.03, W13.05 |
| EXT-PLAY | Release owner reviews then-current official Play policies and completes applicable console declarations | Dated target/dynamic-code/accessibility/AI automation/sensitive permission/service/data safety/deletion/billing/page-size decisions and modern-target architecture evidence | W16.04, W16.06, W16.07 |
| EXT-RELEASE | Release owner supplies actual signing/Firebase inputs and device/Play internal-track access | Signed APK/AAB identity, delivered split installs, API23/24/26/modern ARM/16 KB/WebView/provider checks and pre-launch report | W06.05, W10.01–W10.04, W16.01–W16.07 |

## Evidence log — initial documentation pass (historical)

The entries below preserve the initial documentation pass as recorded, including its then-pending implementation boundary. Current authorization and appended execution evidence supersede that boundary without rewriting the historical observations.

| Date | Scope | Action and observed result | Meaning / limitation |
|---|---|---|---|
| 2026-10-03 | Documentation baseline | `git status --short --branch` showed `## hoplite/gortyn-77773150...origin/hoplite/gortyn-77773150` with no changes; `git rev-parse HEAD` returned `afe3fc149dc774d999148c971397df45feb8e72c`; `git branch --show-current` returned `hoplite/gortyn-77773150` | Confirms clean starting checkout and branch; not a test/build |
| 2026-10-03 | Documentation correction | `git ls-files "android/app/src/main/jniLibs/*/libovid_bootstrap.so"` listed arm64-v8a, armeabi-v7a and x86_64 payloads | Tracked despite `.gitignore:70`; packaging/runtime still pending |
| 2026-10-03 | Source review | Read core startup/state/ledger/FTS, agent/helper/model, grants/cancellation, sandbox/setup, plugin/hooks/MCP, Studio/repo/GitHub, artifact/native WebView, image/account services, settings/native manifests and historical plans | Anchors and observations recorded in master audit; no runtime success implied |
| 2026-10-03 | Documentation authoring | Four master files created with `apply_patch`; W00–W16 tasks, coverage, ownership, corrections and external gates recorded | Documentation in progress until consistency review; all implementation tasks pending |
| 2026-10-03 | Concurrent checkout activity | Later `git status --short --branch` showed changes in grants/plugin permissions/package/ledger/FTS and plugin UI, new Dart/native tests and `android/.kotlin/`, in addition to the four owned documents | Starting clean baseline remains factual; source anchors describe inspected baseline-era code, so implementation owners must re-anchor against concurrent edits. No outside changes were edited or verified by this author |
| 2026-10-03 | Documentation check tooling | Two `rg -c` count commands could not run: `rg: command not found` (exit 127). `git diff --check` exited 0 but excludes untracked documentation | Use a read-only Python document validator and `git diff --no-index --check /dev/null <document>` to include new files; no application test failure or pass implied |
| 2026-10-03 | Documentation verification corrections | Initial read-only `python3 -c` validator found Markdown trailing spaces via no-index diff (exit 3); removed them with `apply_patch`. The next validator incorrectly required exit 0 for differing no-index files; corrected it to accept exit 1 only with empty diagnostics | Documentation/checker issues only; original draft task count corrected from 83 to the actual 77 |
| 2026-10-03 | Documentation verification | Read-only `python3 -c` using `pathlib`, `re`, and `subprocess` exited 0: **77 unique pending tasks; identical ordered ledger; 17 workstreams; complete task coverage in feature matrix; valid task references; 11 existing local links; required plan-identifying first line; no placeholder markers; four new-file whitespace checks** | Each owned file checked with `git diff --no-index --check /dev/null <document>`; no application tests/builds or runtime verification performed |

## Bounded batch evidence — initial handoff (historical, 2026-10-03)

Provenance: the initial user handoff supplied these implementation/review/controller results. The table preserves what was known then, including failed expectations, excluded compile checks and awaiting-review labels; current status above and later evidence supersede them. Exact invocations, raw log paths and worker names absent from that handoff are not invented. Counts are per reported suite/run and **not additive unique totals**; overlap between batches and reruns is possible.

| Batch | Subsystem boundary / related tasks | Reported outcome | Review / remaining gate |
|---|---|---|---|
| B01 | Ledger/grants/search; W01.04, W01.05, W04.01 | First combined run: **66 tests passed**. Ledger async operations serialized and isolate recovery fixed after review | Grants/root/search/ledger remain partial; full store/account/deletion and shared-root integration pending |
| B02 | pkg / `sandbox_pkg.dart`; W06.03–W06.05 | **39 tests passed**, including relocation-failure fixes | Full package-route integrity/dependency/runtime and device proof pending |
| B03 | Plugins UI/grants/config; W04.03, W07.01, W14.03 | **65 grant + 8 UI tests passed**. Confirmed-snapshot authority and masked-secret preservation fixed | Broader permission/transactional plugin/native-config acceptance pending |
| B04 | Native guards; W16.02 and related native evidence | Initial **81 native tests passed** | Native guards reviewed and accepted; W16.02 required devices pending, full task not verified |
| B05 | Agent service/helper routing and queue; W02, W14.02 | **148 agent + 38 queue tests passed** | W14.02 helper route implemented, awaiting review; full agent/root/accounting/cancellation integration pending |
| B06 | Studio setup/coordinator/UI; W06.01 | **30 Studio setup tests passed** | W06.01 implemented, awaiting review; broader installer/runtime requirements remain open |
| B07 | Auth/provider/phone/deletion UI; W13.01–W13.02 | **46 targeted passed**; broader run **93 passed / 4 failed**, failures described as stale `Forgot password` expectations | Four expectations pending fix; broader run is not green. Integration, legacy migration and real auth journeys pending |
| B08 | Native overlay; W16.01 | **33 scoped tests passed** | Flutter compile excluded due to concurrent edits; integrated compile/global-stop and devices pending |
| B09 | Chat UI; W12.01 and bounded chat behavior | **57 tests passed**; chat-header share removal implemented | W12.01 awaiting review; full chat integration and hosted sharing W12.02–W12.03 pending |

| Date | Controller check | Result / revision boundary |
|---|---|---|
| 2026-10-03 | `flutter analyze --no-pub` | Passed once **before latest auth/chat merges**; not a final analysis result for the current integrated tree |
| 2026-10-03 | Final integrated full suite | **Not yet run**; no final full-suite, release artifact, device or production-ready result is claimed |

## Operational log — appended 2026-10-03

Console evidence below is supplied by the authorized Chrome/Firebase handoff; no credentials, OTPs or secret values are recorded.

| Date | Operation / identity | Observed result | Remaining gate |
|---|---|---|---|
| 2026-10-03 | Chrome Firebase account/project verification | Account `aasheeshkatheriya@gmail.com`, project `ovid-ai` verified | Android app/signing fingerprints, configured provider credentials and production App Check/live journeys still require evidence |
| 2026-10-03 | Google provider inspection | **Already enabled** before this operation | Real debug/release Google login/link/reauth pending |
| 2026-10-03 | Phone provider enablement | **Enabled and SAVED**; provider list confirms enabled | Real-device OTP auto/manual, resend/expiry/quota/link/reauth pending |
| 2026-10-03 | SMS quota/billing inspection | Console shows **10 SMS/day**, with add-billing option to raise quota; **no billing change made** | Applicable regions, quota/abuse and billing decisions remain open; enablement does not establish SMS delivery |
| 2026-10-03 | Legacy email/password provider inspection | **Still enabled in console**, pending legacy-account linking migration | Verify same-UID migration before disabling; social/phone-only product requirement remains active |

### Play architecture and official-source log

The Play audit reports fetching **target API 36 / August 31, 2026**. This is attributed audit evidence, not an independently reconfirmed policy conclusion in this documentation update. Independently confirm target-policy applicability and the **Billing Library 8 timeline**. The target28 app-data execution architecture remains a blocker requiring actual modern-target execution/design evidence, not just a target edit.

| Official source | Recorded follow-up / gate |
|---|---|
| [Target API policy (11926878)](https://support.google.com/googleplay/android-developer/answer/11926878) | Confirm audit-reported API36 / August 31, 2026 and applicable release requirements |
| [Accessibility policy (10964491)](https://support.google.com/googleplay/android-developer/answer/10964491) | Review actual accessibility/AI automation behavior and declarations |
| [Dynamic code / device and network abuse (9888379)](https://support.google.com/googleplay/android-developer/answer/9888379) | Resolve extracted/downloaded code and compliant runtime architecture |
| [Payments policy (9858738)](https://support.google.com/googleplay/android-developer/answer/9858738) | Determine requirements for actual app purchases/services |
| [Billing Library deprecation timeline](https://developer.android.com/google/play/billing/deprecation-faq) | Independently confirm Library 8 deadlines and applicability; no unconfirmed date promoted to a requirement |

Other W16.04–W16.07 policy, signing, 16 KB, provider, artifact, device and Play console gates remain open. Firebase enablement and bounded local passes do not establish production readiness.

## Documentation update validation — historical, 2026-10-03

Read-only `python3 -c` validation using `pathlib`, `re` and `subprocess` passed (exit 0): **77 unique open canonical tasks**, identical ordered ledger, **17 workstreams**, complete matrix task coverage, valid W references, B01–B09 present in all four documents, requested awaiting-review/device-pending status guards, **12 existing local links**, required ledger first line, no placeholder markers, and non-additive count boundaries. All four files passed `git diff --no-index --check /dev/null <document>` with no whitespace diagnostics, including untracked documents. Five official-source URLs were recorded, not fetched or independently policy-verified by this update.

The first validator attempt rejected the valid wording “not an additive unique test total”; its overly exact string assertion was corrected to accept the optional article, then the validator passed. This was a documentation-checker failure, not an application test result. Application tests were not rerun for this documentation update; the execution and console evidence above is attributed to the supplied handoff. Historical documentation evidence remains preserved, and no full W task is marked verified.

## Review follow-up and integrated verification — 2026-10-03

Historical follow-up record: the integration controller worked in the existing dirty feature checkout, preserving
earlier implementation changes. These are bounded fixes under W04.03, W07.01,
W10.02 and W12.02–W12.03; no full canonical task is closed by local verification.

| Scope | Current result | Verification |
|---|---|---|
| Plugin revocation | `AppState.revokePluginGrant` immediately disables the row and unregisters contributions before persistence. Teardown also runs after a failed revoke. Permission dialog shows a handled failure and Retry. | Two new regressions failed before the fix; `test/plugin_permission_persistence_test.dart`: **11 passed**, including active authority during a pending failed write and UI retry. |
| Share identity/recovery | Modal and sheet state retain the original account-bound service for the frozen preview. Owner-only request IDs reconcile lost create responses on Refresh, permitting a fresh creation after revoke. | Two widget regressions failed before the fix. Service/sheet/sidebar group: **14 passed**. |
| Share durable quota | Owner storage is limited to 1,000 receipts including expired/revoked rows, in addition to 100 active links. Replay receipts remain retained; public viewer excludes request IDs. README documents the limit and integration contract. | Receipt reconciliation and revoked/expired quota regressions failed before the fix. Python shares suite: **10 passed**. |
| Artifact fullscreen cancellation | Pending entry captures generation and originating route, then rechecks collapse/source/lifecycle/route state after native teardown. Cancelled entry resets inline state. | Collapse and transparent-navigation regressions failed before the fix. `test/html_artifact_w10_test.dart`: **8 passed**. Actual device renderer/403 proof remains open. |

Changed paths in this follow-up: `lib/core/state.dart` (revoke method only),
`lib/ui/plugins_screen.dart` (permission dialog),
`lib/core/conversation_share_service.dart`,
`lib/ui/conversation_share_sheet.dart`, `lib/ui/html_artifact_view.dart`,
`server/shares/repository.py`, `server/shares/README.md`,
`server/shares/tests/test_shares.py`,
`test/plugin_permission_persistence_test.dart`,
`test/conversation_share_sheet_test.dart`, `test/html_artifact_w10_test.dart`,
and this ledger. Dart formatter also normalized layout in the selected Dart files.

Commands ran from `/root/OvidAI`:

```sh
/tmp/opencode/images-venv/bin/python -m unittest discover -s server/shares/tests -v
/root/flutter/bin/flutter test --no-pub test/conversation_share_service_test.dart test/conversation_share_sheet_test.dart test/conversation_share_sidebar_test.dart
/root/flutter/bin/flutter test --no-pub test/html_artifact_w10_test.dart
/root/flutter/bin/flutter test --no-pub --reporter expanded
/root/flutter/bin/flutter analyze --no-pub
git diff --check
/root/flutter/bin/flutter test --no-pub test/plugin_permission_persistence_test.dart
```

- First full-suite attempt hit the tool's 600-second timeout: 2,291 passed and
  one skipped before termination; shutdown generated sink/SIGTERM errors. This
  incomplete run is not a suite result. Raw log:
  `/root/.local/share/opencode/tool-output/tool_1022f6b54001zUG9MGezhfScQ7`.
- Repeated full suite with a 1,800-second allowance completed successfully:
  **3,468 passed, 4 skipped**, exit 0. Raw log:
  `/root/.local/share/opencode/tool-output/tool_102382fee001oEy10woyoMjN9N`.
- Analyzer initially found one missing-braces style issue in the new dialog.
  After adding braces, analysis reported **No issues found**, whitespace check
  passed and the 11 plugin tests passed again. The only post-full-suite code
  change was that brace-only correction.
- Read-only follow-up reviewer inspected the five findings and relevant callers:
  **scoped pass**, no important remaining regression identified. Reviewer did not
  rerun tests. Counts above overlap and are not additive unique totals.
- Hosted shares still require real deployment, verified admission/account-cleanup
  wiring, expiry scheduling and public create/view/revoke checks. Device renderer,
  signed release, Firebase journeys and Play/runtime architecture gates remain
  open. No deploy, commit or push was performed in this follow-up.

## Current-tree reconciliation — 2026-10-03

This section supersedes the historical no-full-suite, four-auth-failures, excluded-Flutter-compile and no-commit authorization statements. Source/tests/current diff were inspected without rerunning application tests for prose. The full-run log `/root/.local/share/opencode/tool-output/tool_102382fee001oEy10woyoMjN9N` ends at line 5855 with `08:56 +3468 ~4: All tests passed!`. The controller reports a fresh analyzer pass this turn. The earlier brace-only post-suite correction and focused plugin rerun remain documented above; later backend/native results belong to the controller's evidence record.

| Scope | Current source/test evidence | Acceptance still open |
|---|---|---|
| W12.01 — verified | `lib/ui/chat_screen.dart` no longer instantiates `ChatShareButton`; its `share_actions.dart` import remains used by generated-image `NativeShare.file` dispatch. `lib/ui/settings_screen.dart` retains Share Ovid. `test/chat_screen_bounded_test.dart` checks header absence and retained image sharing; `test/native_share_test.dart` checks app/file/transcript platform dispatch. The full run includes header/native-share regressions and completes green | None for this narrow header-removal scope; hosted sharing and native release qualification have separate open tasks |
| W06.01 | `studio_setup_coordinator.dart`, `sandbox_setup.dart` and setup navigation/banner/persistence fixtures implement approval, continued navigation, attached progress, failure/retry and durable setup-state behavior; latest supplied focused result **40 passed**, followed by full Flutter suite | Full acceptance review; W06.02–W06.05 installer/supply-chain/runtime scopes |
| W03.02 / W13.03 | `cloud_usage_store.dart`, `ovid_cloud_service.dart`, `cloud_app_check.dart`, usage/billing UI and `usage_reactivity_test.dart` implement shared refresh, generation/key fences, attestation and truthful error/retry display; latest supplied focused cloud result **58 passed**, followed by full Flutter suite | Local usage-log load/write/account partitioning, all producer fences and deployed exact receipt authority |
| W07.02 / W07.03 | `hook_service.dart`, `hook_context_store.dart`, `hook_execution_scope.dart`, `session_lifecycle_service.dart`; `hook_w07_test.dart`, `hook_context_restart_test.dart`, `session_plugin_lifecycle_test.dart` cover aggregation, explicit encrypted restart context, removal/reconciliation, session isolation and retry/event/env boundaries in the full Flutter suite | Complete hook compatibility, environment lifecycle and secret-output acceptance; no separate focused count inferred |
| W10.02 | `html_artifact_view.dart` owns a real fullscreen route and cancels entry after collapse/navigation/owner changes; **8 focused Flutter passes** and full suite | Standalone preview assets/encoding, renderer/rotation/background/device proof; W10.01 403 remains a hypothesis |
| W12.02 / W12.03 | `conversation_share_service.dart`, `conversation_share_sheet.dart`, sidebar and `server/shares/` implement frozen text-only snapshots, account-bound create/reconcile/revoke, escaped viewer, bounded receipts/expiry and delete-account primitive; **14 Flutter + 10 Python passes**, plus full Flutter suite | Router is not mounted/deployed; verified admission/App Check wiring, account worker integration, expiry maintenance and actual public URL/cache/revoke checks |
| W13.05 | `server/account/{domain,postgres,worker}.py` and migration implement durable aliases, acceptance-time reauth, locked retry intent/backoff and stable due ordering. `test_worker.py`, `test_lifecycle.py`, `test_postgres.py` include poison-first100, concurrent workers, restart/cancel and schema cases | Current backend verification owned by controller; full production cleanup adapters, migration/deployment and live lifecycle evidence |
| W05.03 / W16.01 | `agent_service.dart` overlay Stop routes through persistent global background stop; `agent_overlay_global_stop_test.dart` checks queued runs and idle stop, and updated overlay/control Flutter fixtures are included in the full suite. Native overlay interaction changes are present | Controller native verification; all-owner boot/resume and actual overlay/mic/service/permission device journeys |
| W04.03 / W07.01 / W14.03 | Review fixes remove plugin authority before fallible revoke persistence, retain handled Retry and confirmed permission/config snapshots; **11 focused plugin persistence passes**, plus full Flutter suite | Full dispatch parity, transactional generations and native secret/config audit |

Counts above are overlapping run results, not additive unique totals. Only W12.01 closes; the other bounded fixes advance status without shrinking the original acceptance scopes. Permission-based autonomous Control remains the explicit product decision; the proposed static-workflow redesign was not approved.

### Reconciliation documentation validation

Read-only validation confirmed 77 unique canonical tasks, identical ordered task register, 17 workstreams, complete matrix task coverage, one checked/verified W12.01, 76 open scopes and the status totals above. All local Markdown links exist; all four documents passed no-index whitespace checks, including these untracked files. An initial checker incorrectly included later evidence-table rows as task-register rows; restricting it to the canonical register corrected the checker and the validation passed. Application tests were not rerun for this prose update.

## Recording future execution

### Post-push continuation

Checkpoint **9b5f78dcc30052521bda0b316e59896715471862** was pushed to
`origin/hoplite/gortyn-77773150`; remote SHA matched and checkout was clean.
[GitHub run 37134798715](https://github.com/aasheesh333/OvidAI/actions/runs/37134798715)
completed successfully, including analysis/tests, debug APK, signed release
APK/AAB, and all three artifact uploads. This proves build/upload, not Play
acceptance or device behavior. Follow-up source work is continuing under the
user's instruction; the next checkpoint will include its separate evidence.

W01.04 follow-up now has protected envelope fields, collision-resistant paths,
conservative legacy migration, optional bounded replay and durable deletion
tombstones. AppState schedules ledger cleanup for root/deferred children before
callbacks, retains failures for explicit retry, and agent hooks resolve the
authoritative transcript path. Final close-failure review finding was fixed and
re-reviewed successfully; **38 focused ledger/integration tests passed** after
the fix, with scoped analysis clean. Full all-store deletion and a durable failed
cleanup journal remain W01.03 work. Controller integration verification and
canonical status update follow this review; changes are currently uncommitted.

### Recovered Studio/Git follow-up

The interrupted approval integration was resumed from the existing working tree.
`RepoCache` now freezes the approved repository/branch/base, selected bytes and
message; Studio presents the artifact before publication, and agent commits use
the existing permission policy with a fully scrollable review. Durable pending
intent blocks fresh mutations after an unknown result and supports read-only
restart reconciliation. Repository casing aliases share the same admission and
recovery identity; BOM bytes are preserved and corrupt intent errors omit payloads.

Independent task review identified four issues above; all were corrected and
scoped re-review found no new important regressions. The worker records **198
passing covering tests**. Controller verification on the final source:

```sh
/root/flutter/bin/flutter test --no-pub test/repo_cache_approval_test.dart test/studio_commit_approval_test.dart test/agent_commit_approval_test.dart test/chat_commit_approval_test.dart --reporter expanded
/root/flutter/bin/dart analyze lib/core/repo_cache.dart lib/ui/studio_screen.dart lib/ui/chat_screen.dart lib/core/agent_service.dart test/repo_cache_approval_test.dart test/studio_commit_approval_test.dart test/agent_commit_approval_test.dart test/chat_commit_approval_test.dart
git diff --check
```

Results: **44 passed**, analyzer **No issues found**, whitespace clean. Counts
overlap the worker suite. HEAD remains `9b5f78d`; follow-up changes are uncommitted.
W09.02/.03 remain partial: mode-only changes and checkout deletions need explicit
staging and review. Recovery proves exact tip only; an advanced/unmatched ref
remains durably unknown. No live GitHub or device acceptance is claimed.

### Follow-up checkpoint verification

The attempted full Flutter run exceeded the 10-minute command limit. Its log
identified two plan-policy regressions: empty, unbound commit calls tried to
reconcile a nonexistent repository. Both were reproduced in isolation and fixed
with an unbound-empty guard; bound sessions still reconcile without local drafts.

Fresh verification before checkpoint: **312 tests passed** across the plan-policy,
agent/chat/Studio approval, repository safety/audit/branch, session ledger/state
acceptance and MCP SSE origin suites. `flutter analyze --no-pub` reported **No
issues found**; `git diff --check` passed. The interrupted full run is not counted
as a passing suite.

### Explicit Studio staging follow-up

Checkpoint `a9caf70` was committed and pushed to
`origin/hoplite/gortyn-77773150`. The subsequent W09 staging implementation adds
real Studio actions for executable/regular Git modes and explicit deletion of an
already-missing checkout path. Staging changes neither disk contents nor disk
permissions. Review includes mode transitions and deleted content, and operation
identities preserve later edits across publication and reconciliation. Legacy
pending intents remain recoverable.

Task review found that Dart filesystem type lookup conflates absence with lookup
errors. The correction requires confirmed ENOENT and rejects access/lookup failures
in staging, review validation and active/saved-owner accounting. Five access-denial
regressions failed before the fix. Scoped re-review accepted the correction with
no new important findings.

Worker verification: **319 tests passed** across 19 repo/Studio/workspace suites.
Fresh controller verification: **90 tests passed** via:

```sh
/root/flutter/bin/flutter test --no-pub test/repo_cache_staging_test.dart test/studio_staging_test.dart test/repo_cache_approval_test.dart test/agent_commit_approval_test.dart --reporter expanded
/root/flutter/bin/flutter analyze --no-pub
git diff --check
```

Full analyzer reported **No issues found**; whitespace passed. The previous
mode/deletion implementation gaps are closed for this bounded deliverable. Full
W09 acceptance and live/device evidence remain separate. Ordinary working-copy
drafts remain in-process; unknown publication records remain restart-durable.

### Checkpoint pre-commit checks

The user explicitly requested committing/pushing completed work, then continuing
the remaining tasks. Controller review found 123 intended source/test/document
files in this checkpoint; ignored Firebase/signing inputs remain outside it.
Fresh checks: `flutter analyze --no-pub` and staged whitespace checks passed;
`/tmp/opencode/images-venv/bin/python -m unittest discover -s server/account/tests -v`
passed **48 tests**, and the equivalent `server/shares/tests` command passed
**10 tests**. The initial pytest invocation was unavailable in that environment;
the suites use unittest and were run successfully with its native runner.
`./gradlew :app:testDebugUnitTest` from `android/` completed **BUILD SUCCESSFUL**.
An initial invocation excluding `processDebugGoogleServices` failed Gradle's
generated-resource dependency check; the normal invocation above passed without
source changes. These native host tests do not establish device/production
Firebase behavior. The latest full Flutter result remains 3,468 passed / 4 skipped
on the same production code (apart from the already rechecked brace-only lint fix).

For every task transition record: date; task ID; owner; exact claimed files; baseline/revision and dirty-tree context; reproduction input; command/workdir/environment; expected and actual outcome/exit status; evidence path; remaining external/device conditions; next bounded action. Redact tokens, OTPs, private payloads and signing credentials. A failed test/build gets its actual failure, not a success summary from an older run.

Status transitions: **Pending → In progress → Implemented/awaiting review → Reviewed/remaining gates → Verified**, or **In progress → Blocked** with explicit gate and next action. Partial implementation stays in progress; a local fixture pass with an outstanding required live check does not verify the task. Any reopened task must say which evidence invalidated the prior closure. Update canonical checkboxes and this ledger together.

## Immediate handoff

Continue from the integrated Flutter3468/4skip and fresh analyzer checkpoint; the four stale auth expectations are resolved and W12.01 is verified. The controller is completing backend/native verification and owns the explicitly authorized checkpoint commit/push; record its actual results and revision when available. Review full W06.01/W14.02 acceptance, then advance remaining ownership/persistence/permission/installer/hooks/MCP/Studio/receipt/cleanup scopes using the current partial implementations. Deploy and wire shares before live acceptance; complete Firebase migration/provider/SMS journeys and device/release evidence. Preserve autonomous Control, resolve W16.04 modern-target runtime architecture and independently confirm policy timelines. Keep all 76 open acceptance scopes and external gates visible; production readiness remains unestablished.
