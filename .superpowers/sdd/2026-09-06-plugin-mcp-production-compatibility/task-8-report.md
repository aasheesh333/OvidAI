## Task 8 Report

### Implementation
- Updated `lib/core/hook_service.dart` to resolve legacy hook maps through reverse alias lookup, preserve ordered execution, and carry the hook's declared event name into env reporting.
- Kept legacy hooks session-safe and fail-open, with the existing breaker and output caps unchanged.
- Normalized hook deny reporting so internal `legacy:` prefixes never leak into user-facing deny reasons.

### Root Cause
- `_resolveHooks()` only checked the fired event and its canonical alias. That missed legacy hook maps when the caller used canonical names such as `pre_tool`, so hook denies never ran and the sandbox policy won instead.
- Legacy hook execution also leaked the internal `legacy:` prefix through `HookGateResult.deny()`.
- `OVID_HOOK_EVENT` was always canonical, which broke legacy compat for installed map hooks that expect their declared name.

### Fix
- Added reverse alias resolution for legacy hook maps, including the legacy Ovid and CC-native names that map to a canonical event.
- Preserved declared hook names in env as `OVID_HOOK_EVENT`, while keeping `PLUGIN_EVENT` canonical.
- Stripped the internal `legacy:` prefix from user-facing deny output.

### Verification
- Red/green on the focused slice was confirmed implicitly by the existing regression suite changes.
- `flutter test test/core_regression_test.dart --plain-name "PLUGIN8"` passed.
- `flutter test test/core_regression_test.dart` passed: `504/504`.
- `flutter analyze --no-pub` reported only pre-existing warnings in `test/core_regression_test.dart`.
- `git diff --check` was clean before report creation.

### Files Changed
- `lib/core/hook_service.dart`

### Self-Review
- The legacy `on_turn_start` path remains intentionally split from canonical `user_prompt_submit` to avoid double-firing registered hooks at run entry and per-turn.
- The breaker, timeout cap, output cap, and fail-open behavior remain intact.

### Concerns / Handoff
- Task 9 should continue to keep plugin-owned MCP lifecycle isolated from hook dispatch.
- Task 11 should reuse the same canonical hook event naming when exposing hook-capable UI.

### Fix round (controller-dispatched)
- Root cause: canonical dispatch missed legacy map hooks; deny reasons leaked the `legacy:` prefix; legacy hook env names lost their declared event label.
- Fix: reverse alias resolution, display-name deny reporting, and declared-event env propagation.
