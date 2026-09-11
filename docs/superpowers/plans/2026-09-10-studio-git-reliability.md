# Studio Terminal, Git Auth, and Repo-Branch Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-time GitHub login persists; new sessions inherit last repo/branch/folder; Studio terminal is a persistent streaming per-tab shell; `apt update/upgrade` behave honestly; repo binding is `(repo, branch)`; terminal git uses a host-scoped non-persisted credential.

**Architecture:** Fix the `GitHubService` login state machine; persist last selection and seed `newSession`; extend `PtyShell`/`PtyPool` with streaming + stdin and per-tab keys; thread branch through `RepoCache`/`GitHubService`; make `ovid-pkg` honest; inject host-scoped git credentials in `_sandboxEnv`.

**Tech Stack:** Flutter/Dart, `PtyShell`/`PtyPool`, `SandboxService`, `RepoCache`, `GitHubService`, `SharedPreferences`, `FlutterSecureStorage`.

**Spec:** `docs/superpowers/specs/2026-09-10-studio-git-reliability-design.md`

## Global Constraints

- After one successful login, Studio must not re-prompt login on a transient profile failure; only a 401 clears the token.
- A new session must not force fresh repo/folder selection when logged in.
- Studio terminal must persist shell state across commands, stream output before exit, and accept stdin; each tab is an independent shell.
- `apt update` works; `apt upgrade` works or exits non-zero (never silent success); `-y` is not a package; native failures surface non-zero; arch matches the Dart ABI map.
- Repo binding is `(repo, branch)`; `?ref=`/commit branch threaded end-to-end.
- Git credentials are host-scoped (github.com) and process-env only, never persisted; cleared on sign-out.
- Preserve all currently green tests (full `flutter test` 876/876 at baseline `e3482f4`), including agent PTY isolation and RepoCache rebind cancellation.
- Flutter binary is `/home/ubuntu/sdk/flutter/bin/flutter`.

---

### Task 1: One-time GitHub login persistence

**Files:**
- Modify: `lib/core/github_service.dart`
- Modify: `lib/ui/studio_screen.dart`
- Modify: `test/core_regression_test.dart` (login-state test)
- Create: `test/github_login_persistence_test.dart`

**Interfaces:**
- `initialize()` sets `_token` from storage before `_fetchUser`; transient failures keep the token and schedule a background profile retry; 401 clears. `isLoggedIn` true after stored-token read.

- [ ] **Step 1: Write failing tests**

Stored token + 503 profile => `isLoggedIn` true, token retained, background retry runs; stored token + 401 => logged out + token deleted; stored token + 200 => profile loaded.

- [ ] **Step 2: Run RED** — `flutter test test/github_login_persistence_test.dart`

- [ ] **Step 3: Implement the state machine** — assign `_token` before profile fetch; on non-401 keep + retry; only 401 clears; guard retries with `_authGeneration`.

- [ ] **Step 4: Update the existing login test** in `core_regression_test.dart:291-307` to expect logged-in on transient failure.

- [ ] **Step 5: Run GREEN + regressions** — focused, core auth tests, analyze.

- [ ] **Step 6: Commit** `feat: persist github login across sessions`

---

### Task 2: Persist last repo/branch/folder and seed new sessions

**Files:**
- Modify: `lib/core/state.dart`
- Create: `test/last_selection_test.dart`

**Interfaces:**
- Adds `lastRepoFull`, `lastBranch`, `lastWorkspaceFolder` loaded in `_loadLastSelection`, written on set; `newSession()` seeds them; `getRepoForSession` falls back to `lastRepoFull`.

- [ ] **Step 1: Write failing tests** — set last repo/branch/folder, call `newSession()`, assert the new session inherits them; round-trip prefs; fallback after simulated restart.

- [ ] **Step 2: Run RED**

- [ ] **Step 3: Implement globals + load/persist + seed + fallback** (backfill from active session for upgrades).

- [ ] **Step 4: Run GREEN + session persistence/startup regressions, analyze.**

- [ ] **Step 5: Commit** `feat: persist last repo branch and folder`

---

### Task 3: Per-tab streaming terminal

**Files:**
- Modify: `lib/core/pty_service.dart`
- Modify: `lib/ui/studio_screen.dart`
- Modify: `test/session_stop_isolation_test.dart` (pool keys)
- Create: `test/studio_terminal_test.dart`

**Interfaces:**
- `PtyShell.output` broadcast stream + `writeStdin`; `PtyPool.getOrCreate(sessionId, spawner, {String tab})` keyed by `(sessionId, tab)`; `discardFor` closes all keys for a session. Studio tabs own a shell, stream output, send stdin; one-shot `exec` fallback when no sandbox.

- [ ] **Step 1: Write failing tests** — output arrives before command completion; `cd` persists across two commands in one tab; two tabs same session are independent; marker lines not surfaced; `discardFor` closes all tab shells.

- [ ] **Step 2: Run RED**

- [ ] **Step 3: Implement streaming sink + stdin + pool keys + Studio wiring** (keep agent call sites compiling with a default tab).

- [ ] **Step 4: Run GREEN + PTY/stop regressions, full core, analyze.**

- [ ] **Step 5: Commit** `feat: persistent streaming studio terminal`

---

### Task 4: Repo + branch binding

**Files:**
- Modify: `lib/core/state.dart` (`ChatSession.branch`)
- Modify: `lib/core/repo_cache.dart`
- Modify: `lib/core/github_service.dart`
- Modify: `lib/core/agent_service.dart` (`sessionBranch`, bind)
- Modify: `lib/ui/studio_screen.dart` (branch picker)
- Create: `test/repo_branch_test.dart`

**Interfaces:**
- `ChatSession.branch`; `GitHubService.listBranches`; branch threaded through `RepoCache.sync/_getTree/_fetchRaw/_shaOf/_putFile` and `listRepoContent`; Studio branch picker; `_boundSessionId` guard.

- [ ] **Step 1: Write failing tests** — `branch` JSON round-trip; `listBranches`; `?ref=` present in tree/raw/SHA and `branch` in commit body; non-default branch reads/commits the right ref.

- [ ] **Step 2: Run RED**

- [ ] **Step 3: Implement model + threading + picker.**

- [ ] **Step 4: Run GREEN + RepoCache/Studio regressions, full core, analyze.**

- [ ] **Step 5: Commit** `feat: repo and branch binding`

---

### Task 5: ovid-pkg correctness

**Files:**
- Modify: `lib/core/sandbox_pkg.dart`
- Modify: `lib/core/sandbox_service.dart`
- Modify: `test/core_regression_test.dart` (wrapper contract)
- Create: `test/ovid_pkg_test.dart`

**Interfaces:**
- `upgrade`/`full-upgrade` real or explicit non-zero; `-y` parsed; dpkg exit propagated; index freshness; baked arch; mirror list read.

- [ ] **Step 1: Write failing tests** — generated script contains upgrade handling, `-y` stripping, pipefail/exit capture, mirror read, baked arch; `apt install -y pkg` does not resolve `-y`; failure returns non-zero.

- [ ] **Step 2: Run RED**

- [ ] **Step 3: Implement script + `writeAll(arch:, mirrors:)` + call sites.**

- [ ] **Step 4: Run GREEN + wrapper tests + plugin-dep runner, full core, analyze.**

- [ ] **Step 5: Commit** `feat: honest ovid package manager`

---

### Task 6: Host-scoped git credentials

**Files:**
- Modify: `lib/core/sandbox_service.dart`
- Modify: `lib/core/github_service.dart`
- Create: `test/git_credentials_test.dart`

**Interfaces:**
- `SandboxService.gitCredentialToken` set by `GitHubService` on login/initialize, cleared on sign-out; `_sandboxEnv` adds `GIT_TERMINAL_PROMPT=0` and github.com-scoped `GIT_CONFIG_*` credential helper; never persists.

- [ ] **Step 1: Write failing tests** — env contains github.com-scoped helper and no `store`/`.git-credentials`; cleared on sign-out.

- [ ] **Step 2: Run RED**

- [ ] **Step 3: Implement token hook + env injection + sign-out clear.**

- [ ] **Step 4: Run GREEN + sandbox env regressions, analyze.**

- [ ] **Step 5: Commit** `feat: host-scoped git credentials`

---

### Task 7: Verification, audit, and README

**Files:**
- Create: `test/studio_git_reliability_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-studio-git-reliability.md`
- Modify: `README.md`

**Interfaces:**
- End-to-end: one login no re-prompt; new session inherits repo/folder; terminal streams and persists `cd`; branch binding; apt upgrade honest; git env scoped.

- [ ] **Step 1: Add end-to-end tests.**

- [ ] **Step 2: Run full verification** (`flutter test`, analyze, `build apk --debug`, `git diff --check`).

- [ ] **Step 3: Write audit + README contract; mark device-only checks NOT EXECUTED.**

- [ ] **Step 4: Commit** `docs: verify studio and git reliability`

---

## Execution Order

```text
1 login -> 2 last selection -> 3 terminal -> 4 branch -> 5 ovid-pkg -> 6 git creds -> 7 verification
```

Tasks 5 and 6 are independent of 3/4 and may be reordered; 1→2 must precede 4's UI. Sequential implementers (shared files).
