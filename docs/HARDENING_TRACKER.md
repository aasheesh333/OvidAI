# Ovid Hardening & Capability Tracker

> Owner: build session 2026-09-18. Branch: `hoplite/gortyn-77773150`.
> Rule: every item ends with evidence (test name / commit / CI run). No "done" without evidence.

## Goal
1. Make the repo **private** (done) and stop publishing deobfuscation symbols.
2. Let the **AI agent do everything** on Ovid: add/remove/update providers, set keys, set base URL,
   set API format, add/remove models, select model, manage MCP/plugins, and read back state.
3. **Anthropic native API** support alongside OpenAI-compatible for every provider (base URL + format).
4. Security hardening: secure storage, apt TLS, FLAG_SECURE, tamper detection, CI artifacts.

---

## P0 — Security (must land first)

| # | Item | File | Status | Evidence |
|---|------|------|--------|----------|
| S1 | Repo private | GitHub | DONE | `gh repo view` → `isPrivate:true` |
| S2 | Stop publishing symbols artifact | `.github/workflows/build.yml` | DONE | grep: no upload step; YAML valid |
| S3 | Remove permanent apt TLS loosening | `lib/core/sandbox_service.dart` | DONE | grep Verify-Peer → none; 49 tests pass |
| S4 | Harden FlutterSecureStorage AndroidOptions | `lib/core/secure_store.dart` + 6 call sites | DONE | grep `const FlutterSecureStorage()` → none |
| S5 | FLAG_SECURE toggle (block recents/screenshot) | `MainActivity.kt`, `security_service.dart`, `state.dart`, `settings_screen.dart` | DONE | Kotlin BUILD SUCCESSFUL; Settings row added |
| S6 | Wire SecurityCheck (root/Frida/debugger) to Dart | `security_service.dart` | DONE | `SecurityService.I.status()` + cached getters |
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
| U1 | Light-theme contrast + `onPrimary` | DONE | p1_visual_parity pass; ratios logged |
| U2 | Respect system text scale in chat | TODO (follow-up) | |
| U3 | Confirm/undo on destructive actions | TODO (follow-up) | |
| U4 | 48dp tap targets + Semantics labels | TODO (follow-up) | |


---

## Verification log
- `dart analyze lib test` → 0 issues
- `flutter test` → 1893 pass (1 known-flaky apt test, passes in isolation)
- `./gradlew :app:compileDebugKotlin` → BUILD SUCCESSFUL
- `flutter build apk --release --obfuscate` → BUILT (115.9MB), no strip errors
- CI run `35388447094` → success (analyze, test, debug APK, signed release APK + AAB)
- Repo `aasheesh333/OvidAI` → `isPrivate: true`

## Session summary (2026-09-18)
Commits: `b1a5303` (security + agent control + Anthropic), `23d4a4d` (release strip fix).
Dispensed 7 parallel agents for independent files + core work in main session.
Follow-ups remaining: B1 (background approval deadlock), U2 (system text scale),
U3 (confirm/undo destructive), U4 (tap targets/Semantics), plus the full
network chokepoint (`OvidHttpClient`) and SSRF guard from the audit.
