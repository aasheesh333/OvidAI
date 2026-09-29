# Ovid 78 → 100+ Roadmap — Design Spec

**Status:** draft · 2026-09-25
**Plan:** `docs/superpowers/plans/2026-09-25-ovid-100-plus-roadmap.md`

## 1. Scope

Take Ovid from an honest 78/100 (as a free, Android, agentic vibe-coding tool
and a Claude Code / opencode alternative) to a genuine daily-driver that a
senior developer would reach for on mobile — and, in its home turf, do things a
desktop CLI structurally cannot.

This spec covers six independent subsystems. Each produces working, testable
software on its own and has its own release gate. They are sequenced by
dependency, not by size.

## 2. Why 78 and not higher — grounded findings

Evidence gathered by reading the codebase (not the README):

- **Zero on-device verification, ever.** Every audit under
  `docs/superpowers/audits/*` carries a §8 device checklist where every row is
  `NOT EXECUTED`. The convention is explicitly "`NOT EXECUTED` = no
  device/emulator attached" (`master-roadmap.md:19-20`). Nothing has run on real
  Android hardware. This is the single biggest trust blocker.
- **Reliability is bound inside a god class.** `lib/core/agent_service.dart` is
  21,245 lines: one `ChangeNotifier` owning the run loop, HTTP transport, SSE
  parsing, a 206-case `_dispatchInner` switch (~2,800-line method), tool
  schemas, approvals, subagents, browser control, and device control. The
  concurrency primitives (`AgentRun`, `_RunCtx`, Zone-per-run + epoch/generation)
  are genuinely well-designed — the *organisation* around them is the debt.
- **Correctness debt.** `docs/ENGINEERING_AUDIT.md`: 327 empty `catch (_) {}`
  blocks with no logging seam, ~48 unguarded `firstWhere` (only 13 guarded), a
  known silent session-persist failure.
- **Phone-coding ergonomics.** Editing/reviewing non-trivial code on a phone is
  slow versus a laptop CLI — the real reason it stays a "second tool".
- **Not distributable.** `targetSdk = 28` by design (SELinux blocks exec of
  app-private sandbox binaries — `ENGINEERING_AUDIT.md:50-53`); no privacy
  policy / Data Safety despite `SEND_SMS`, `MANAGE_EXTERNAL_STORAGE`, location,
  contacts permissions; release signing silently falls back to the debug
  keystore and CI does not block it.

## 3. What already works (do not rebuild)

Verified in code, so the roadmap builds on these rather than replacing them:

- Zone-per-run concurrency with epoch/generation staleness
  (`agent_service.dart` `_runResolved:1009`, `_runChainStale:1222`).
- Sandbox policy: CWD+target jail, denied-command blocklist, symlink
  canonicalization, token-on-disk-not-in-env
  (`sandbox_service.dart:2632`, `agent_service.dart:15362`).
- Device control: delta node reader with stable handles + IME-window merge,
  single-`GestureDescription` multi-gestures, cancellation-generation contract
  (`OvidAccessibilityService.kt:1149`, `device_control_service.dart:140`).
- Plugin/MCP transaction with real rollback and honest status enums
  (`plugin_runtime.dart:1622`, `mcp_service.dart:645`).
- 188 test files with real-subprocess and real-checkout E2E; mature CI
  (`.github/workflows/build.yml`).
- `voice_input_service.dart`, `agent_notification_service.dart` foreground
  keep-alive, `pendingApprovalsElsewhere`, browser screenshot→vision — all
  present and reusable for later phases.

## 4. Locked decisions

- Sequence is **0 → 1 → 2 → 3 → 5 → 4**. Trust foundation (0–2) precedes
  feature/ergonomics work (3, 5); distribution (4) is last because it depends on
  a verified, trustworthy build.
- Every phase follows the repo's existing mandate: spec → RED test → implement →
  audit (`master-roadmap.md:5-21`).
- Every phase's release gate: `flutter analyze` 0 issues + full Flutter suite
  green. **From Phase 0 onward, the device-lab job must also be green.**
- Behaviour-preserving refactors (Phase 2) must prove byte-identical behaviour
  via characterization tests before and after each extraction.
- No new network egress of code/secrets to third parties beyond the user's own
  configured providers.

## 5. Phases

### Phase 0 — Real-device verification
Move `device-test.yml` onto a real ARM64 device (Firebase Test Lab / BrowserStack),
script every audit's §8 checklist, and flip `NOT EXECUTED` → `PASS` (or fix real
`FAILED`). **DoD:** ≥2 Android versions full checklist PASS, pinned in CI, APK
SHA recorded. **Score:** +6 → 84.

### Phase 1 — Correctness debt
`Diag.swallow(context, e)` logging seam replaces empty catches; unguarded
`firstWhere` → `firstWhereOrNull` + explicit handling; session-persist failure
surfaced to the user. **DoD:** empty-catch ≈0, unguarded `firstWhere` = 0,
persist-failure visible. **Score:** +3 → 87.

### Phase 2 — God-class refactor
Extract `ToolRegistry` (self-describing handlers; retire the 206-case switch and
the schema/gate/approval triplication), `LlmTransport` (OpenAI + Anthropic
strategies), `SubagentManager`, `RunLoop`. `AgentService` becomes a thin
coordinator over the existing `AgentRun`/`_RunCtx`/Zone primitives. **DoD:**
`agent_service.dart` < ~4k lines, no mega-switch, a new tool = one file, suite +
device-lab green. **Score:** +5 → 92.

### Phase 3 — Phone-coding ergonomics
Voice-first composer (push-to-talk, voice→task, hands-free approval),
per-hunk swipeable diff-review, quick-action chips, checkpoint/restore UI over
the session ledger, code-aware composer input. **DoD:** ship a non-trivial
feature with no keyboard typing. **Score:** +4 → 96.

### Phase 5 — Moat features
Build→install→drive→fix loop (agent installs its own app on the device, drives
it via Control mode, reads failures via screenshot→vision, fixes); background
agents that keep running while locked with push-notification completion;
notification-driven approvals; on-device screenshot debugging. **DoD:** an
end-to-end "build this repo, run it on my phone, fix the crash" demo.
**Score:** +5 → 101+.

### Phase 4 — Distribution + privacy
`targetSdk` uplift (scoped storage + exec-free sandbox path) or a documented
F-Droid/sideload story with privacy policy + Data Safety; permissions diet;
CI signing gate that fails release builds when secrets are absent. **DoD:**
uploadable AAB or clean F-Droid release with privacy policy; signing gate
enforced. **Score:** +3 buffer → 104.

## 6. Success metric

`78 → ~104`. Phases 0–2 make the product *trustable* (without them, features are
noise). Phases 3 and 5 make it *worth using instead of the CLI* on mobile.
Phase 4 gets it into people's hands.

## 7. Status tracker

| Phase | Status | Notes |
|---|---|---|
| 0 — Real-device verification | not started | trust foundation |
| 1 — Correctness debt | not started | |
| 2 — God-class refactor | not started | behaviour-preserving |
| 3 — Phone-coding ergonomics | not started | |
| 5 — Moat features | not started | |
| 4 — Distribution + privacy | not started | ship gate |
