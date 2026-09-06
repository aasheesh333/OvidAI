# Task 8 Report: Control Mode Rank and Cold-Start Fallback

## Status

Complete. `AgentMode.control` is the strongest top-level mode at rank 4. Subagents are capped at `AgentMode.drive`, and persisted Control sessions deserialize as Full Access after a cold start instead of silently re-arming Control.

## Implementation

- Added the Control label, safety-focused hint, icon, and danger color to the existing mode UI model.
- Added Control to the `dispatch_agent` mode schema while routing both inherited and explicit child mode selection through one resolver that caps Control at Full Access.
- Added the minimal `AgentService.modeRankForTest` seam. The existing active-session `childModeForTest` seam now exercises the same resolver as production dispatch; no artificial `parentModeOverride` API was introduced.
- Required explicit confirmation for `/permission control`, following the Full Access command pattern.
- Added `AppState.sanitizeColdStartMode` and applied it during `ChatSession.fromJson` deserialization so `control` falls back to `drive`; other persisted modes remain unchanged.
- Updated the existing mode inventory regression and added `CTRL1` coverage for rank, command confirmation, child cap, tool schema, and cold-start restoration.
- Did not implement native accessibility behavior; that remains Task 9.

## TDD Evidence

RED:

`/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL1"`

The test failed to compile because `AgentMode.control`, `AgentService.modeRankForTest`, and `AppState.sanitizeColdStartMode` did not exist.

GREEN:

`/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "CTRL1"`

Result: 1 test passed.

## Verification

- `/home/ubuntu/sdk/flutter/bin/flutter test`: 398 tests passed.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze`: no issues found.
- `git diff --check`: passed.

## Concerns

None for Task 8. Control currently shares Full Access tool-approval behavior; Task 9 is responsible for adding the native accessibility implementation that gives Control its device-control capabilities.

## Commit

`feat: AgentMode.control with rank 4 and cold-start fallback`
