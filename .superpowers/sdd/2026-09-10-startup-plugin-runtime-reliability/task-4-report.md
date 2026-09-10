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

## Fix Round 1

### RED Evidence

- A production refresh could wait on workspace/runtime input collection before
  obtaining its generation. An older refresh therefore reserved after a newer
  refresh and overwrote the newer session snapshot.
- Runtime notifications invalidated every session, while agent install rebuilt
  only the installing session. A background install could erase the foreground
  session's user/workspace catalog.
- A stale same-plugin snapshot continued loading a contribution removed by an
  upgrade because invocation rechecked only owner visibility.
- A registered runtime's legacy `plugin_<display>` tool could execute an
  unrelated workspace skill selected by a global/bare lookup.
- `session.restore` became Ready after a timed-out `skill.mount` because restore
  readiness had no skill-mount settlement barrier.
- Composer plugin suggestions included session-scoped runtime rows that were not
  visible to the rendered session.
- `Skill` retained caller-owned mutable lists and maps.

### Fixes

- Added synchronous `SkillCatalogReservation` acquisition before any async
  input collection. Publication accepts the reservation; invalidation or a
  newer refresh makes the older candidate ineligible to publish.
- Replaced process-wide runtime notification invalidation with awaited lifecycle
  rebuilds through `AppState`. The affected plugin is removed atomically from
  every snapshot while user/workspace and unrelated entries remain, then every
  extant session is rebuilt. Install/upgrade, enable, disable, uninstall, and
  the Plugins-screen retry path use this flow.
- Invocation now requires the exact canonical contribution, kind, declaration
  path, runtime root, and session visibility still present in the current
  registry. Removed same-ID upgrade contributions cannot execute from stale
  snapshots.
- Registered `plugin_<display>` calls now return canonical contribution guidance
  and execute nothing. Legacy runtimeId-null calls resolve only content under
  that legacy plugin's own cache roots.
- Added a dedicated skill-mount startup task with settled/succeeded state.
  Session restore remains degraded while a timed-out raw mount is running and
  fires only after successful settlement.
- Filtered generic composer plugin suggestions through exact rendered-session
  registry visibility; migration-unsafe legacy rows remain excluded.
- `Skill`, catalog input, and snapshot collections now defensively copy into
  unmodifiable lists/maps.

### Added Coverage

- Production refresh race before input collection, invalidation, and newer
  publication.
- Background session install while another session is foreground, preserving
  both workspace catalogs and enforcing plugin scope.
- Retry-driven all-session remount.
- Same-ID upgrade removal and registered generic-tool isolation.
- Timed-out skill mount versus restored-session callback ordering.
- Rendered-session composer plugin filtering.
- Deep collection immutability.

### Verification

- `flutter test test/plugin_runtime_skills_test.dart`: 17/17 passed.
- `flutter test test/plugin_runtime_migration_test.dart`: 34/34 passed.
- `flutter test test/core_regression_test.dart --name "PLUGIN4|PLUGIN7|PLUGIN11"`:
  31/31 passed.
- `flutter test test/startup_first_frame_test.dart`: 33/33 passed.
- `flutter test test/session_stop_isolation_test.dart`: 16/16 passed.
- `flutter test test/core_regression_test.dart`: 552/552 passed.
- `flutter analyze --no-pub`: no issues.
- `git diff --check`: clean.

### Remaining Concerns

- Nullable/global refresh remains a compatibility-only Settings/test seam. It
  does not participate in runtime lifecycle rebuilding or production dispatch.
- Task 5 remains responsible for exactly-once session lifecycle semantics; the
  restored-session callback is now correctly blocked on successful skill-mount
  settlement.
