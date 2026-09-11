# Studio Terminal, Git Auth, and Repo-Branch Reliability Design

**Date:** 2026-09-10
**Status:** Approved by product direction (one-time login persists; new session must not force fresh folder/repo selection; apt/pkg must work; engineering-best defaults).

## 1. Goal

Make Studio trustworthy: log in to GitHub once and stay logged in across sessions/restarts; a new session must not force re-selecting a repo or working folder when the user is already logged in; the Studio terminal must be a persistent, streaming, per-tab shell; `apt update` must work and `apt upgrade` must not falsely succeed; and repo selection must include a branch and bind per session.

## 2. User Outcomes

1. After one successful GitHub login, Studio never re-prompts login on a later launch just because a transient profile fetch failed.
2. Creating a new chat does not force a fresh repo or folder selection; it inherits the last-used repo/branch/folder when logged in.
3. The Studio terminal keeps shell state (`cd`, exports) across commands, streams output as it happens, and supports stdin; each tab is an independent shell.
4. `apt update` works; `apt upgrade` either works or fails loudly (never a silent false success); `apt install -y pkg` does not treat `-y` as a package; native install failures surface non-zero.
5. Repo binding is `(repo, branch)`; a branch can be selected and is used consistently for tree/read/SHA/commit.
6. `git clone/pull/push` against github.com works using a host-scoped, non-persisted credential channel.

## 3. Non-Goals

- A full terminal emulator with full TTY/job control (a persistent pipe shell is acceptable; disclose TTY limits).
- Replacing the GitHub Contents API with a local git working copy.
- Play-policy changes or the control overlay (Project 6).
- Multi-provider Git hosts (github.com only).

## 4. Current Failure Model (evidence)

### 4.1 Login re-prompt
`GitHubService.isLoggedIn` is `_token != null` (`github_service.dart:59`). `initialize()` assigns `_token` only after `_fetchUser` succeeds (`:84-92`); a transient 5xx/network leaves the token on disk but `_token == null`, so Studio re-prompts (`studio_screen.dart:43-52`). Locked by a test at `core_regression_test.dart:291-307`.

### 4.2 New session forces fresh selection
`newSession()` sets `s.repo = null` (`state.dart:3767`); the global repo is in-memory only (`agent_service.dart:1789`) and never persisted, so after restart Studio shows "Connect a repo" and then prompts for a folder (`studio_screen.dart:254`, `67-71`).

### 4.3 Terminal is one-shot
Studio runs `SandboxService.exec(['bash','-c',c])` (`studio_screen.dart:1059-1091`), which buffers all output until exit (`sandbox_service.dart:2048-2063`). No stdin, no persistence. `PtyShell`/`PtyPool` (persistent pipe shell) is agent-only (`pty_service.dart:14-144`; `agent_service.dart:6917-6933`).

### 4.4 Package manager
`ovid-pkg` supports only update/search/install/list (`sandbox_pkg.dart:83-141`); unknown verbs exit 0 (`:141`). `install` pipes dpkg to `tail` masking failures (`:135-136`); `-y` is treated as a package (`:104-132`); `uname -m` disagrees with the Dart ABI map (`:75` vs `sandbox_service.dart:83-92`).

### 4.5 Branch absent
`RepoCache` is a global singleton (`repo_cache.dart:15-31`); branch defaults to `main` and is not threaded into `_fetchRaw`/`_shaOf`/`_putFile` (`:173-345`); `GitHubService` has no `listBranches`; `ChatSession` stores only `repo` (`state.dart:816-819`).

### 4.6 No Git CLI credentials
`_sandboxEnv` sets no `GIT_ASKPASS`/credential helper (`sandbox_service.dart:1631-1696`), so terminal git against private repos hangs.

## 5. Architecture

### 5.1 One-time login
In `GitHubService.initialize`, set `_token` from secure storage before `_fetchUser`; on transient failure keep `_token` and schedule a background profile retry; only a 401 clears the token. `isLoggedIn` becomes true immediately after a stored token is read.

### 5.2 Persisted last selection
Add persisted globals `lastRepoFull`, `lastBranch`, `lastWorkspaceFolder`, loaded in `_loadLastSelection` and written on `setRepoForSession`/`setSessionWorkspaceFolder`. `newSession()` seeds from them instead of nulling. `getRepoForSession` falls back to `lastRepoFull` so agent tools resolve after restart.

### 5.3 Per-tab streaming terminal
Extend `PtyShell` with a broadcast `output` stream and `writeStdin`. Key `PtyPool` by `(sessionId, tabId)`; Studio terminal tabs own a shell, subscribe to output, and send commands via stdin; keep the one-shot `exec` fallback when the sandbox is unavailable. Marker lines are filtered from the UI sink.

### 5.4 Repo + branch
Add `branch` to `ChatSession` and a global `lastBranch`; add `GitHubService.listBranches`; thread `branch` through `RepoCache.sync/_getTree/_fetchRaw/_shaOf/_putFile` and `GitHubService.listRepoContent` (`?ref=`) and `writeFile`; add a Studio branch picker. Add a `_boundSessionId` guard to reduce cross-session cache bleed.

### 5.5 ovid-pkg correctness
Add `upgrade`/`full-upgrade` (real or explicit non-zero failure), parse `-y`/`--yes`, propagate the real dpkg exit code, validate index freshness, bake the correct arch from the Dart ABI map, and read the app's mirror list.

### 5.6 Git credential channel
Set host-scoped, process-env-only credentials in `_sandboxEnv` when a token is present: `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_COUNT/KEY_0/VALUE_0` for `credential.https://github.com.helper` returning the token; never write `.git-credentials`/global config; clear on sign-out.

## 6. Error Handling

- Login: transient profile failure is authenticated-but-unknown; a later API 401 triggers a global sign-out.
- Terminal: shell death surfaces in the tab; sandbox absence falls back to one-shot exec.
- Package manager: unsupported verbs exit non-zero with an actionable message; index/download failures are visible.
- Branch: a missing branch ref surfaces as an explicit error, never a silent default-branch read/commit.
- Git credentials: never persisted; cleared on sign-out and app exit.

## 7. Testing

- Unit: login state machine (stored token → logged in; transient keeps; 401 clears); last-selection round-trip and `newSession` seeding; `listBranches`; branch `?ref=`/commit-body threading; `PtyShell` streaming/stdin and pool `(session, tab)` isolation; `ovid-pkg` script contracts (upgrade/-y/exit/arch/mirrors); `_sandboxEnv` credential scoping (github.com only, no store).
- Widget: Studio never re-prompts after one login; new session shows the inherited repo/folder; terminal tab streams output and persists `cd`; branch picker updates binding.
- Regression: PTY agent isolation, RepoCache rebind cancellation, existing Studio tests.

## 8. Migration

- Existing sessions keep `repo`; `branch` defaults to `main`; `lastRepoFull`/`lastBranch`/`lastWorkspaceFolder` backfill from the active session on first load.
- The login test that asserts "transient failure logs out" is updated to "transient failure stays logged in".

## 9. Decisions

- Login persists across sessions after one success; transient failures do not sign out.
- New sessions inherit last `(repo, branch, folder)` when logged in.
- Studio terminal is a persistent per-tab pipe shell with streaming + stdin; no full TTY.
- `apt upgrade` never silently succeeds; unsupported verbs exit non-zero.
- Repo binding is `(repo, branch)`, threaded end-to-end.
- Git credentials are host-scoped and process-env only.
