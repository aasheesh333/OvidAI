# Task 4 Report: Runtime-Managed Session Skill Catalogs

## Status

Implemented immutable, generation-guarded skill catalog snapshots per session.
Production mounting now consumes only active normalized runtimes visible through
the contribution registry for the exact session. The process-global
`SkillService` root/catalog API remains available only as a compatibility seam.

## RED Evidence

- The dedicated test initially failed to compile because
  `SkillContributionKind`, `PluginCatalogMount`, `SkillCatalogSnapshot`,
  `publishSessionCatalog`, `skillsForSession`, `resolveForSession`, and
  `dropSession` did not exist.
- The production integration test then failed because `AgentService.refreshSkills`
  did not accept an explicit session ID and runtime manifests were not mounted
  into a session catalog.
- Existing PLUGIN4 coverage exposed the old test seam's dependence on global
  legacy roots; the tests were narrowed to distinguish compatibility behavior
  from production session snapshots.

## Implementation

- Added immutable `SkillCatalogSnapshot`s keyed by session ID, with independent
  monotonically increasing generations. Stale same-session completions and
  invalidated scans cannot republish; different sessions publish independently.
- Added `SkillContributionKind.command`, `.skill`, and `.agent`, producing
  kind-correct canonical IDs such as
  `plugin:acme/research-kit/command:research`.
- Added `PluginCatalogMount`, carrying the committed content directory and
  normalized manifest. Runtime mounting reads only manifest-declared commands,
  skills, and agents.
- Enforced canonical owner identity, strict relative paths with no traversal,
  realpath containment, no symlink path components, regular-file type, expected
  kind directory/file shape, contained declared supporting files, and duplicate
  canonical-ID rejection. Undeclared markdown and README files are ignored.
- Changed production skill refresh to require and derive workspace roots from an
  exact session. Explicit unknown sessions fail closed with an empty snapshot;
  nullable refresh remains for Settings and legacy tests only.
- Mounted active runtimes only when `activeRuntimes()` validates them and the
  registry says they are visible to the target session. Production snapshots do
  not scan legacy plugin caches.
- Routed prompt catalog rendering, skill-tool lookup, canonical plugin dispatch,
  capability checks, composer suggestions, and direct slash invocation through
  the session snapshot. Execution rechecks registry visibility.
- Added a punctuation-preserving slash token parser. Built-in commands still run
  before skill resolution. Ambiguous aliases list exact canonical options and
  execute nothing.
- Added lifecycle invalidation for runtime changes, targeted remount after an
  agent install, all-session remount after enable/disable/uninstall, and snapshot
  removal on session deletion.
- Inserted the `skill.mount` readiness task directly between `plugin.activate`
  and `session.restore`.

## Tests

- `flutter test test/plugin_runtime_skills_test.dart`: 11/11 passed.
- `flutter test test/plugin_runtime_migration_test.dart`: 34/34 passed.
- `flutter test test/core_regression_test.dart --plain-name "skill"`: 57/57 passed.
- `flutter test test/core_regression_test.dart --name "PLUGIN4|PLUGIN7|PLUGIN11"`: 31/31 passed.
- `flutter test test/startup_first_frame_test.dart`: 32/32 passed.
- `flutter test test/core_regression_test.dart`: 552/552 passed.
- `flutter analyze --no-pub`: no issues.
- `git diff --check`: clean.

## Coverage

The dedicated suite covers immediate session-A visibility, pre-promotion
session-B isolation, post-boot promotion, parallel A/B publication,
same-session stale completion, invalidation, command/skill/agent canonical IDs,
ambiguous no-execution behavior, unknown-session fail-closed behavior, startup
ordering, stale pending-runtime cache exclusion, undeclared files, traversal,
absolute paths, symlinks, wrong owners, missing files, wrong kinds, supporting
file containment, and duplicate canonical IDs.

## Concerns

- The nullable/global `refreshSkills()` and mutable root API intentionally remain
  for Settings and legacy tests. Production run, startup, lifecycle, composer,
  and dispatch paths use explicit session snapshots.
- Task 5 still owns exactly-once `session_start` dispatch. Task 4 establishes its
  required ordering by completing `skill.mount` before `session.restore`.
