# Studio 100+ · Hooks · Cross-session logins — tracking plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** take the Studio screen to a genuinely advanced, fully responsive, bug-free surface; make plugin/MCP hooks fire automatically and explain themselves when they cannot; and make platform logins shared across all sessions after restart while every session keeps its own data.

**Architecture:** three independent subsystems, executed in parallel by disjoint file ownership, then integrated. Studio = `lib/ui/studio_*`; repo data integrity = `lib/core/repo_cache.dart`; browser login sharing = `lib/ui/browser_screen.dart` + `lib/core/session_browser_profiles.dart` + `android/.../OvidBrowserProfiles.kt`; hooks = `lib/core/hook_service.dart` + fire sites in `lib/core/agent_service.dart`.

**Tech Stack:** Flutter/Dart, Kotlin (WebView profiles / cookie merge), GitHub Actions CI, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-25-ovid-parity-hardening.md` (parent roadmap), `docs/superpowers/specs/2026-09-25-ovid-100-plus-roadmap-design.md`.

## Global Constraints
- Release gate per workstream: `flutter analyze lib test` = **0 issues**, targeted suites green, and CI green on the pushed commit.
- Never report success for a partial or failed operation — this repo's standing rule is "accurate detection, never a fake success".
- Behaviour-preserving refactors must be proven by tests before and after.
- No new dependencies (`pubspec.yaml` / `build.gradle.kts` changes are out of scope; report them instead).
- Commit style `type(scope): summary`, rationale comments cite the audit date.

---

## Workstream A — Studio screen (DONE)

- [x] **Responsive layout.** `StudioMetrics` with the repo's existing 840px breakpoint + Material's 600: compact hides the tree behind an 80% overlay + scrim, medium docks on demand, expanded docks by default. Both panes draggable (44dp gutter, double-tap resets), sizes re-clamped every layout pass so rotation can never starve a pane, terminal auto-collapses when too short. Editor keeps a 320×200 minimum at every size (a 640dp phone went ~250px → ~375px of editor). AppBar actions fold below 600dp; Android back closes the overlay first.
- [x] **Accessibility.** No `Semantics` existed and auth state was a colour-only 9×9px dot. Now distinct silhouettes per state + Semantics live regions; every control meets the repo's 44dp minimum (tab-close was ~20dp, terminal-close an 11px icon with no padding, Save unpadded 11.5px text, tree rows ~25dp); a 12px font floor (there was 9.5px text); bar heights scale with OS text scale; all 12 mono styles carry a real monospace fallback — `Aether.mono` names `JetBrainsMono`, which is not in `pubspec.yaml`, so code was rendering proportionally.
- [x] **Editor.** autocorrect + suggestions were ON for a code editor (the keyboard would rewrite identifiers); smart quotes/dashes now disabled. Caret was dumped at EOF on open and the controller was mutated inside `build`; binding moved to listeners, fresh opens start at offset 0, background rewrites preserve the caret. Added in-file find (count, next/prev, wrap, Ctrl/Cmd+F, Escape), Undo/Redo via `UndoHistoryController`, Ln/Col readout.
- [x] **Crash + data-loss bugs.** Repo tile did `r['full_name'] as String` in `onTap` while its own title tolerated null → crash on tap (reproduced RED). Repo bar keyed on the literal `'Connect a repo'` at three sites → nullable now. Top-level build read `sessionRepoFull`/`sessionBranch` **unsubscribed** → stale bar; now listens. Directory-ness inferred from sorted-path adjacency, so a fully-skip-listed directory rendered as a file and tapping it opened an empty buffer indistinguishable from a real empty file (savable over the real file) → directories derived from the path set, failed fetch shows an error row with retry.
- [x] **De-duplication + honesty.** Folder-pick/probe/All-Files-Access was copy-pasted twice; four hand-rolled sheets had inconsistent radii (18 vs 20); `_toast` was bypassed by inline `ScaffoldMessenger`; raw `'$e'` was shown to users; sync progress was invisible behind an 11px spinner while up to 400 files fetched serially (now a determinate banner via the previously-unused `onLine` callback); class doc promised a "Sandbox ready" indicator that does not exist; the login sheet showed users "poll #N".
- [x] Extracted into `studio_layout` / `studio_editor` / `studio_file_tree` / `studio_terminal_tabs` / `studio_errors`; `studio_screen.dart` re-exports public symbols. 2071 → 1726 lines. 104 new tests.

## Workstream B — RepoCache data integrity (DONE)

- [x] **Re-sync destroyed uncommitted edits** (`_dirty.clear()` unconditional, no `hasPending` check at either call site). Sync now snapshots and re-applies local edits over refreshed content.
- [x] **Silently partial repos**: swallowed per-file failures still reported "repo synced ✓", the Trees `truncated` flag was ignored, the 400-file cap truncated silently. `sync()` now returns a `SyncReport`; mid-sync 401/403 aborts loudly.
- [x] **Skip-list ate real files** (`contains` matching: `.bin` ate `lib/foo.binding.dart`, `build/` ate `src/rebuild/`, `.png` ate `notes.png.md`, `.PNG` slipped through) → segment-boundary + case-insensitive exact suffix.
- [x] **`commitAll` was not a commit** (N files = N GitHub commits, non-atomic, partial push on failure) → one atomic Git-Data commit (blobs → tree from `base_tree` preserving `100755` → commit → one non-force ref update); fallback recorded in `lastCommit.mode`; a mid-fallback failure throws naming how many files landed.
- [x] Per-segment path encoding (was `%2F`); `fetchFile` actually caches and distinguishes `noToken`/`unauthorized`/`notFound`/… ; `bind()` notifies; bounded concurrency + retry/backoff honouring `Retry-After` + a 120s deadline whose unattempted files are reported.
- [x] Callers made honest: `repo_sync` warns that absence proves nothing on a partial copy; the `commit` tool reports when it fell back to N separate commits.
- [x] 32 new tests (RED-first), including exact HTTP-sequence assertions for the atomic commit.

## Workstream C — Cross-session logins + the Google dead end (DONE)

- [x] **Restart login-sharing never ran.** The pipeline existed end to end but the gate was dead: `shareBrowserOnRestart` defaulted **false** and its setter had **zero callers** (the Settings rows that could enable it were removed earlier). Now default ON — each session keeps its own tabs/history/data, only logins are shared, once per launch; the opt-out seam is preserved.
- [x] **Receivers were skipped**: `getProfile(name) ?: continue` meant a session that never opened a tab had no profile, so in the owner's exact scenario (log in on X; Y/Z never browsed) it performed **0 copies and still reported success**. Now `getOrCreateProfile`, so every current session has a jar to receive into (safe: runs at startup before any WebView binds).
- [x] **It clobbered each session's OWN login** (replayed the first profile's header over every jar; `setCookie` replaces by name) → union merge, own-value-wins, idempotent (`CookieMerge.missingPairs` is the unit-tested spec of the native rule). Platform failures now return null → honest `applied: false` instead of a fake success. Only `{profiles, urls}` cross the channel — never tabs or history (pinned by a test).
- [x] **The Google notice was a guaranteed dead end.** Its "Reload — I signed in" button and its own doc comment claimed a reload was worth trying, but Android has **no API, public or private, to read another browser's cookie store**, so an external sign-in can never be imported into the tab. The owner followed exactly that flow and stayed logged out because it cannot work. Reload is gone; the notice now says plainly that the sign-in cannot be brought back and offers what IS real (continue in the real browser; app password / API key / device-code where offered; and for path-gated hosts — Facebook/LinkedIn/X, not the always-external Google/Microsoft/Apple — try the form in this tab, where a login can genuinely complete).
- [x] Custom Tabs **evaluated and rejected, not skipped**: `androidx.browser` is not on the compile classpath (only `androidx.webkit`), so it needs a new dependency — and it would add nothing, since Custom Tabs shares the Chrome profile exactly like the `externalApplication` launch already used.
- [x] Honest limitation recorded in code and tests: `CookieManager.getCookie` returns only `name=value` (no Domain/Path/Secure/expiry) and a jar cannot be enumerated, so the merge replays recorded origins — real logins are covered, but it is not a byte-identical clone, and two sessions on different accounts of one site cannot both win a cookie name.

## Workstream D — Plugin/MCP hooks fire automatically (DONE)

Owner report: hooks still not triggering. A runtime trace found four independent causes, three of them silent.

- [x] **MCP server-prefix matchers were dead** — a regression from this session's matcher anchoring. CC's `mcp__server` matcher must catch every tool of that server (`mcp__<server>__<tool>`); `^(?:mcp__github)$` never matched `mcp__github__create_issue`, and the per-hook skip left no ledger entry. Literal `mcp__` branches now also match as a boundary-exact server prefix; real regexes keep the anchored path.
- [x] **Wrong matcher subject** for every non-tool, non-session event (compared against `''` → permanently dead). Compaction reads `trigger` (both fire sites now pass it); events with no CC matcher vocabulary ignore the matcher instead of never firing.
- [x] **`session_end` had no `reason`**, so CC SessionEnd matchers never matched. Chat deletion now reports `clear`.
- [x] **"The hook never fires" was silent.** `HookService.hookBlockers` now records a human reason per plugin — screen install awaiting restart, session-scoped install, missing sandbox (hook commands execute inside the Studio sandbox, which installs on first Studio open), or a tripped circuit breaker — cleared as soon as one of its hooks runs again, and surfaced as a warning row in the Plugins-screen diagnostics.
- [x] **Deliberately NOT changed:** the `pendingGlobal`-until-restart activation scope. It is an explicit spec §7 decision (a screen install must not mutate an already-running session mid-flight), so it is made visible rather than quietly breaking the isolation contract `session_plugin_lifecycle_test.dart` pins.
- [x] 21 new/extended tests (matcher parity 5 → 13, blocker diagnostics 8).

---

## Remaining (tracked, not started)

- [ ] **Studio editor Save still only marks the in-memory copy dirty** — nothing reaches GitHub until the agent's `commit` tool runs, and there is no push affordance in the screen. Needs a Save/Commit UI wired to `commitAll` plus `hasPending`/`dirtyCount` surfacing. (Owner: `lib/ui/studio_*` — safe now that Workstream A landed.)
- [ ] **`studio_file_tree` should use the richer `fetchFileResult`** so a 401/404/timeout is distinguishable from an empty file at the call site (the empty-buffer data-loss path is already closed; this makes the message precise).
- [ ] **`RepoCache.sync` is still serial-ish for the progress bar** — `onLine` fires every 25 files; emit per completion for smooth progress. Also consider exposing tree `type == 'tree'` entries so the UI need not re-derive directories, and a `fetchFileOverrideForTest` seam.
- [ ] **Legacy (runtimeId-null) plugin hooks**: `_collectHookDefs` (`state.dart:6441`) drops the real CC `hooks.json` shape `{"Event": [{matcher, hooks:[…]}]}` because the value is a List, and `_resolveHooks` reads only the one-command-per-event map, never `pluginHooks`. Legacy rows are fail-closed until re-approved anyway, so this is lower priority — but it means a migrated plugin can lose multi-hook events.
- [ ] **A single transient grant-check failure persists `disabled: true`** (`plugin_runtime.dart:1117`) and `_runBootActivation` then skips it forever — a secure-store hiccup can permanently and silently disable a plugin's hooks.
- [ ] **`git credential fill` is not in the denied-command list**, so one approved command can print the raw `repo`-scoped token into the transcript; and `pollForToken` persists the token *after* fetching the profile (`github_service.dart:611`), so a transient `/user` failure discards an unrecoverable device-flow token.
- [ ] **`listRepos`/`listBranches` have no pagination** (30 / 100 caps) — users with more repos or branches cannot pick them.
- [ ] **Sign-out leaves private-repo source on disk** (unbounded clones under `<appSupport>/global/repos/`).
- [ ] **No Settings toggle for `shareBrowserOnRestart`** (now default ON; the opt-out is programmatic only) and `lastBrowserReport` has no UI surface.
- [ ] **`pubspec.yaml` has no `fonts:` section**, so `Aether.mono` (`JetBrainsMono`) is unbundled app-wide — Studio now falls back to generic monospace; bundling the font would fix every screen.
- [ ] Parent-roadmap items still open: real-device verification (Phase 0), god-class refactor (Phase 2), distribution/privacy (Phase 4).

## Progress tracker

| Workstream | Status |
|---|---|
| A — Studio responsive + a11y + editor + bugs | **done** |
| B — RepoCache data integrity | **done** |
| C — Cross-session logins + Google notice | **done** |
| D — Hooks fire automatically + diagnostics | **done** |
| Remaining items above | tracked, not started |
