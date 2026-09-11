# Studio Terminal, Git Auth, and Repo-Branch Reliability — Task 7 Release Gate Audit

Date: 2026-09-11 · Branch `hoplite/gortyn-77773150` · Baseline `e9338db` · Task 7 verification commit (this commit)

This audit is the release gate for the Studio Terminal / Git Auth / Repo-Branch
Reliability project (spec
`docs/superpowers/specs/2026-09-10-studio-git-reliability-design.md`, plan
`docs/superpowers/plans/2026-09-10-studio-git-reliability.md`). It records the
automated verification matrix and the per-outcome evidence for the six promised
behaviors, then the device-only checklist with its execution status.

**Device checks were NOT executed.** No Android device or emulator is attached
to this environment. Every on-device row in §8 is marked `NOT EXECUTED`, not
`passed`. Nothing on-device was run and nothing on-device is claimed.

This is a test/docs-only task. No production behavior was changed. The new
end-to-end gate surfaced no defect, so no RED-first fix was required.

## 1. Verification matrix (exact counts)

All commands run with `/home/ubuntu/sdk/flutter/bin/flutter` on 2026-09-11,
working tree at baseline `e9338db` plus the Task 7 test/docs changes.

| Command | Result |
|---|---|
| `flutter test test/studio_git_reliability_test.dart` | 11/11 passed (new) |
| `flutter test` (11 focused Studio/Git suites, incl. the new one) | 79/79 passed |
| `flutter test` (all files) | 955/955 passed (944 baseline + 11 new) |
| `flutter analyze --no-pub` | No issues found (ran in 10.1 s) |
| `flutter build apk --debug` | Built `build/app/outputs/flutter-apk/app-debug.apk` (149.2 s) |
| `git diff --check` | clean |

The focused set is `studio_git_reliability`, `github_login_persistence`,
`last_selection`, `repo_branch`, `studio_branch`, `studio_login_prompt`,
`studio_terminal`, `studio_terminal_session`, `studio_terminal_widget`,
`ovid_pkg`, and `git_credentials`.

The build emits non-fatal toolchain warnings (Kotlin Gradle Plugin applied by
`firebase_analytics`/`shared_preferences_android`; minimum Android SDK 23 will
soon be dropped). The APK still builds and is produced; these are pre-existing
toolchain warnings, not gate failures. They are recorded here rather than
hidden.

## 2. One-time login persistence (spec §5.1)

`GitHubService.initialize` reads the stored token and assigns it *before* the
profile fetch, so `isLoggedIn` is true immediately across restarts
(`lib/core/github_service.dart:104`). A transient profile failure (5xx /
network / decode) keeps the token and schedules a background retry
(`_scheduleProfileRetry`, `:152`); only `invalid_token` (401) clears it and
deletes secure storage (`:126`, `:166`). Studio's auth gate returns while
`isInitializing` is true and only prompts once initialization has settled
signed-out (`lib/ui/studio_screen.dart:84`), so a momentary logged-in state
during a restore cannot consume the one prompt.

The new gate pins the user outcome end-to-end: after one successful login,
mounting Studio then restoring through a transient `503` leaves
`isLoggedIn == true`, the token on disk, and the login prompt **not** called.
A second service-level case pins that the sandbox git credential survives the
same transient failure (cross-checked in §7).

## 3. Last-selection inheritance (spec §5.2)

`AppState` persists `lastRepoFull`, `lastBranch`, and `lastWorkspaceFolder`
(`lib/core/state.dart:2498`), loads them in `_loadLastSelection` (`:2502`) with
a backfill from the restored active session for the upgrade path, and
`newSession()` seeds the new session's `repo`, `branch`, and
`workspaceFolder` (`:3909`). A vanished workspace folder falls back to the
per-session sandbox via `_resolvedLastWorkspaceFolder` (`:2567`).
`getRepoForSession`/`getBranchForSession` fall back to the persisted globals
after a restart (`:5847`, `:5866`).

The new gate pins: a logged-in `newSession()` inherits `(repo, branch, folder)`;
the selection round-trips through a simulated restart; and a mounted Studio
shows the inherited repo rather than the `Connect a repo` empty state.

## 4. Terminal streaming and persistence (spec §5.3)

`PtyShell` exposes a broadcast `output` stream and a `writeStdin` that avoids
`flush()` (a pending flush binds the `IOSink` and breaks back-to-back writes)
(`lib/core/pty_service.dart:56`, `:82`). `StudioShellSession` owns one tab's
scrollback, busy state, and shell-death recovery
(`lib/core/studio_terminal.dart:17`). `PtyPool` keys shells by
`owner \0 sessionId \0 tab` so agent Stop cannot kill Studio tabs
(`lib/core/pty_service.dart:190`). Studio's `_run` uses the persistent shell
with a one-shot `exec` fallback (`lib/ui/studio_screen.dart:1373`).

The new gate pins the user outcome on a real host `bash` through the injected
`PtySpawner`: the first output line arrives while the command is still running
(busy), and `cd <dir>` persists so a later `pwd` prints that directory.

## 5. Repo + branch binding (spec §5.4)

The binding is the pair `(repo, branch)`. `ChatSession.branch` is persisted and
seeded; `GitHubService.listBranches` lists refs and `listRepoContent` appends
`?ref=<branch>`; `RepoCache.sync` reads the tree at `git/trees/<branch>` and raw
content at `?ref=<branch>`, and `commitAll` reads the blob SHA at `?ref=` (the
part that prevents a non-default-branch 409) and commits with `branch` in the
body (`lib/core/repo_cache.dart:80`, `:178`, `:205`, `:296`, `:335`). The
`_boundSessionId` guard rebinds a cache that belongs to another session
(`lib/ui/studio_screen.dart:84`).

The new gate pins: `sync` targets `/git/trees/develop` and fetches content with
`ref=develop`; `commitAll` reads the SHA with `ref=feature/x` and PUTs
`branch=feature/x`; and `listRepoContent` carries `ref=develop`.

**Honest note:** the commit side uses the GitHub Contents API's JSON `branch`
field, not a `?ref=` query parameter (the API does not document `ref` on PUT).
The read/SHA side uses `?ref=`. This matches the plan's "`?ref=`/commit branch"
shorthand.

## 6. ovid-pkg honesty (spec §5.5)

`upgrade`/`full-upgrade` print an actionable `not supported` message to stderr
and exit `2` (`lib/core/sandbox_pkg.dart:219`). `install` strips
`-y`/`--yes`/`-q`/`--quiet` before resolving packages (`:164`); dpkg runs to a
log and its real exit code is propagated (`:216`); index freshness is enforced
in update/search/install (`:138`, `:149`, `:154`, `:171`); and the payload arch
is baked from the Dart ABI map (`lib/core/sandbox_service.dart:83`, `:680`,
`:1853`).

The new gate executes the generated script against a temp `PREFIX` and asserts
`upgrade` and `full-upgrade` both exit non-zero with `not supported` on stderr
— never a silent success.

## 7. Git credential scoping (spec §5.6)

`SandboxService._sandboxEnv` adds, only when a token is present,
`GIT_TERMINAL_PROMPT=0` and a `GIT_CONFIG_*` credential helper keyed
explicitly to `credential.https://github.com.helper`; no unscoped
`credential.helper`, no `GIT_ASKPASS`, and no `.git-credentials` file are
written (`lib/core/sandbox_service.dart:1705`). `GitHubService._setToken` is
the single write point that mirrors the token into
`SandboxService.I.gitCredentialToken`, and `signOut()` / a 401 clear it
(`lib/core/github_service.dart:76`, `:82`).

The new gate pins the host-scoped helper and `password=<token>`, the absence of
an unscoped helper / askpass / on-disk store, and that `signOut()` removes the
credential env.

## 8. Device-only checks (spec §8)

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: no Android device/emulator is attached to this environment.
Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | GitHub login persists across a real app restart; no re-prompt on a transient network failure | NOT EXECUTED | No device. Automated widget + service pins in `studio_git_reliability_test.dart` / `github_login_persistence_test.dart`. |
| 2 | Creating a new chat inherits the last repo/branch/folder | NOT EXECUTED | No device. Automated state + widget pins in `studio_git_reliability_test.dart` / `last_selection_test.dart`. |
| 3 | Studio terminal streams output, accepts stdin, and keeps `cd`/exports across commands; tabs are independent | NOT EXECUTED | No device. Automated host-`bash` pins in `studio_git_reliability_test.dart` / `studio_terminal*_test.dart`. |
| 4 | Branch picker lists real GitHub branches and the binding uses the chosen ref for tree/read/commit | NOT EXECUTED | No device. Automated mock-HTTP pins in `studio_git_reliability_test.dart` / `repo_branch_test.dart` / `studio_branch_test.dart`. |
| 5 | `apt update` works and `apt upgrade` fails loudly inside the on-device sandbox | NOT EXECUTED | No device. Automated generated-script pins in `studio_git_reliability_test.dart` / `ovid_pkg_test.dart` (host `/bin/sh`, no device sandbox). |
| 6 | `git clone/pull/push` against a private github.com repo authenticates without a prompt | NOT EXECUTED | No device. Automated env-scoping pins in `studio_git_reliability_test.dart` / `git_credentials_test.dart`; no real git transport was run. |
| 7 | APK installs and launches on-device | NOT EXECUTED | No device; APK built and SHA-pinned in §9. |

## 9. Debug APK artifact

| Field | Value |
|---|---|
| Path | `build/app/outputs/flutter-apk/app-debug.apk` |
| Size (bytes) | 238,004,806 |
| Size (human) | ~227 MiB |
| SHA-256 | `59f8b99476b5e007f13b8c03bd3f0bd5c628dad559c3b1afac642bae07c738d0` |
| Build command | `flutter build apk --debug` |
| Build time | 149.2 s |
| Built from | baseline `e9338db` working tree + Task 7 test/docs changes |

This is a debug build; it is an artifact-integrity and buildability gate, not a
release-signed artifact. The APK is **workspace-bound and gitignored** (it lives
under `/build/`, which `.gitignore` excludes): a debug build is not
byte-reproducible across machines, and the SHA-256 above pins this specific
workspace artifact only.

## 10. Concerns and limitations

1. **No on-device verification.** Real touch/keyboard terminal behavior, real
   GitHub branch listing, real private-repo git transport, and the on-device
   sandbox apt path remain unverified until a release owner runs §8.
2. **Pipe shell, not a full TTY.** The Studio terminal has no job control or
   terminal escape handling; an interactive command that consumes stdin can
   swallow the completion sentinel and leave the tab busy until the shell dies
   (spec §3 non-goal, disclosed).
3. **Single background profile retry.** If the retry also fails transiently the
   profile stays authenticated-but-unknown until the next start or a manual
   fetch; spec §6 only requires a later 401 to sign out.
4. **`ovid-pkg upgrade` is an explicit non-zero**, not a real reinstall
   closure. This satisfies "never falsely succeed"; a future task can add a
   real closure without touching the install path.
5. **`RepoCache` is still a singleton.** `_boundSessionId` rebinds across
   sessions; it is not a per-session working copy (spec §3 non-goal).
6. **`listBranches` caps at GitHub's 100-per-page** with no pagination.
7. **Token in process env.** The git credential is process-env-only by design;
   it is visible to the spawned process and never written to disk.
8. **Debug APK size.** ~227 MiB is a debug artifact; not representative of a
   release build.

## 11. Gate decision

Automated gates are green: the new end-to-end suite (11/11), the focused
Studio/Git set (79/79), the full Flutter suite (955/955), `flutter analyze`
(no issues), the debug APK build, and `git diff --check`. The on-device
checklist (§8) is `NOT EXECUTED` because no Android device/emulator is
attached; on-device release sign-off must therefore remain open until a release
owner completes it.
