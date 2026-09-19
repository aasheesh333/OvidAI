# Ovid Hardening & Capability Tracker

> Owner: build session 2026-09-18. Branch: `hoplite/gortyn-77773150`.
> Rule: every item ends with evidence (test name / commit / CI run). No "done" without evidence.

## Goal
1. Stop publishing deobfuscation symbols. (Repo visibility was later flipped
   to PUBLIC at the owner's request — see the public-repo checklist below.)
2. Let the **AI agent do everything** on Ovid: add/remove/update providers, set keys, set base URL,
   set API format, add/remove models, select model, manage MCP/plugins, and read back state.
3. **Anthropic native API** support alongside OpenAI-compatible for every provider (base URL + format).
4. Security hardening: secure storage, apt TLS, FLAG_SECURE, tamper detection, CI artifacts.

---

## P0 — Security (must land first)

| # | Item | File | Status | Evidence |
|---|------|------|--------|----------|
| S1 | Repo visibility | GitHub | PUBLIC (owner request) | branch protection on `main`; actions pinned to SHAs + allowlisted; secrets never committed |
| S2 | Stop publishing symbols artifact | `.github/workflows/build.yml` | DONE | grep: no upload step; YAML valid |
| S3 | Remove permanent apt TLS loosening | `lib/core/sandbox_service.dart` | DONE | grep Verify-Peer → none; 49 tests pass |
| S4 | Harden FlutterSecureStorage AndroidOptions | `lib/core/secure_store.dart` + 6 call sites | DONE | grep `const FlutterSecureStorage()` → none |
| S5 | FLAG_SECURE toggle (block recents/screenshot) | `MainActivity.kt`, `security_service.dart`, `state.dart`, `settings_screen.dart` | DONE | Kotlin BUILD SUCCESSFUL; Settings row added |
| S6 | Wire SecurityCheck (root/Frida/debugger) to Dart | `security_service.dart` + `state.dart` + `settings_screen.dart` | DONE (verified) | `_initializeReadiness` → `refreshDeviceSecurity()`; Settings "Device integrity" row; `test/security_device_integrity_test.dart` (5) |
| S7 | ProGuard/R8 hardening + no debug info in release | `proguard-rules.pro` | DONE | `minifyReleaseWithR8` BUILD SUCCESSFUL |
| S8 | FileProvider narrowed (root-path removed) | `file_provider_paths.xml` | DONE | XML valid |
| S9 | `usesCleartextTraffic=false` | `AndroidManifest.xml` | DONE | XML valid |

## P1 — Agent full-control (catalog tools)

| # | Tool | Status | Evidence |
|---|------|--------|----------|
| T1 | `catalog_get_provider` | DONE | test: tool surface |
| T2 | `catalog_update_provider` | DONE | test: add->get->update flow |
| T3 | `catalog_set_provider_key` | DONE | test |
| T4 | `catalog_clear_provider_key` | DONE | test |
| T5 | `catalog_add_provider_model` | DONE | test |
| T6 | `catalog_remove_provider_model` | DONE | test |
| T7 | `catalog_select_model` | DONE | test |
| T8 | `catalog_list_models` | DONE | test |
| T9 | `catalog_add_provider` accepts `api_format` | DONE | test: enum pinned |
| T10 | `catalog_remove_provider` (built-ins key-clear) | DONE | test |
| T11 | `catalog_remove_mcp` / add MCP | ALREADY PRESENT | existing |
| T12 | plugin toggle tools | ALREADY PRESENT | existing |
| T13 | Read-only gate covers new tools | DONE | test: RO gate pins |
| T14 | System-prompt tool docs updated | DONE | source |

## P2 — Anthropic native API

| # | Item | Status | Evidence |
|---|------|--------|----------|
| A1 | `ProviderConfig.apiFormat`, persisted | DONE | round-trip test |
| A2 | Request builder `/v1/messages`, `x-api-key`, `anthropic-version`, system split | DONE | conversion tests |
| A3 | SSE parser (`content_block_delta`, `text_delta`, `input_json_delta`, `thinking_delta`, `message_delta`) | DONE | implemented in `_callAnthropicOnce` |
| A4 | Tool schema conversion → `input_schema` | DONE | test |
| A5 | Tool-call accumulation → unified internal shape | DONE | conversion tests |
| A6 | Auto-detect Anthropic by host | DONE | test |
| A7 | Provider UI: API format selector + editable base URL | DONE | providers_screen |
| A8 | Tests | DONE | `test/anthropic_provider_control_test.dart` (16) |

## P3 — Reliability bugs

| # | Item | Status | Evidence |
|---|------|--------|----------|
| B2 | `jsonDecode(tool args)` guarded | DONE | test: B2 guard present |
| B4 | `persistSessions` failure recorded (`lastSessionPersistFailed`) | DONE | state.dart |
| B1 | Background-run approval deadlock (zone mismatch) | TODO (follow-up) | |

## P4 — UI/UX

| # | Item | Status | Evidence |
|---|------|--------|----------|
| U1 | Light-theme contrast + `onPrimary` | DONE (verified) | textFaint `#5B5F66`; accentC/successLight/warnLight applied at 87 UI call sites; onPrimary set; p1_visual_parity pass |
| U2 | Respect system text scale in chat | TODO (follow-up) | |
| U3 | Confirm/undo on destructive actions | TODO (follow-up) | |
| U4 | 48dp tap targets + Semantics labels | TODO (follow-up) | |

## P5 — Browser desktop-mode regression (reported)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| BR1 | Desktop UA re-asserted on every navigation (was first-load only) | DONE | `onPageStarted`/`onPageFinished`/`controllerForTab` pass `userAgent`; native sets `userAgentString` |
| BR2 | Forced viewport is a document-start script, not a post-load DOM mutation | DONE | `applyLogicalViewport` uses `addDocumentStartJavaScript` + `DOCUMENT_START_SCRIPT`; re-asserts on DOMContentLoaded/load |
| BR3 | Per-tab viewport script replaced (never stacked); mobile clears the force | DONE | `viewportHandlers` WeakHashMap; `clearViewportScript` |
| BR4 | Tests | DONE | `test/browser_desktop_navigation_test.dart` (10) |

Root cause: desktop mode was applied as a post-load DOM mutation at `onPageFinished`
and the UA only once at first load, so every navigation/reload produced a fresh
document that laid out at device width and tripped the site's mobile gate before
the fix ran. Now both are re-asserted per navigation and window.innerWidth is
forced at document start.



---

## Verification log
- `dart analyze lib test` → 0 issues
- `flutter test` → 1899 pass, all green
- `./gradlew :app:compileDebugKotlin` → BUILD SUCCESSFUL
- `flutter build apk --release --obfuscate` → BUILT (115.9MB), no strip errors
- CI runs `35388447094` and `35390511950` → success
- Repo `aasheesh333/OvidAI` → `visibility: PUBLIC` (owner request); confidential
docs removed from HEAD; signing key + Firebase config should be treated as
exposed and rotated; git-history purge still pending.

## Independent verification pass (2026-09-18, post-claim)
Re-checked every tracker item against source. Found and fixed 2 overclaims:
1. S6 "wired" was false — `SecurityService.status()` was never called (dead code
   moved from Kotlin to Dart). Now consumed in `_initializeReadiness` and shown
   in Settings; covered by `test/security_device_integrity_test.dart`.
2. U1 "successLight/warnLight added" but unused — the light-mode success/warn
   contrast failures remained at call sites. Now applied across 87 UI sites
   (dark values unchanged, so dark mode is pixel-identical).


## Session summary (2026-09-18)
Commits: `b1a5303` (security + agent control + Anthropic), `23d4a4d` (release strip fix).
Dispensed 7 parallel agents for independent files + core work in main session.
Follow-ups remaining: B1 (background approval deadlock), U2 (system text scale),
U3 (confirm/undo destructive), U4 (tap targets/Semantics), plus the full
network chokepoint (`OvidHttpClient`) and SSRF guard from the audit.

## P6 — Session analytics (reported)

| # | Item | Status | Evidence |
|---|------|--------|----------|
| AN1 | Replace global composer totals with current-session totals | DONE | `_StatsLine` reads `ChatSession.analytics` |
| AN2 | Persist analytics with each session | DONE | `ChatSession.toJson/fromJson`; round-trip test |
| AN3 | Advanced metrics and approximate pricing | DONE | input/output/context/turns/tools/latency/TTFT/decode/cache/cost |
| AN4 | Expandable analytics sheet above composer | DONE | tap the stats line → Session analytics |
| AN5 | Session isolation and pricing tests | DONE | `test/session_analytics_test.dart` |
