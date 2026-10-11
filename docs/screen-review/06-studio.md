# 06 — Studio (code workspace)

## Scope
`lib/ui/studio_screen.dart`, `studio_editor.dart`, `studio_file_tree.dart`,
`studio_terminal_tabs.dart`, `studio_layout.dart`, `studio_errors.dart`,
`sandbox_setup.dart` (SandboxSetupScreen, `openStudio`), `github_login_sheet.dart`.
Related core followed for confirmation: `lib/core/sandbox_service.dart`,
`lib/core/github_service.dart`, `lib/core/pty_service.dart`,
`lib/core/studio_terminal.dart`, `lib/core/studio_setup_coordinator.dart`.

## Goal
Read every Studio screen, sheet and dialog in full and produce a ranked, actionable
fix list (see README). Focus: sync IO on UI isolate, unsaved-changes loss,
large-file handling, terminal lifecycle, credential handling, mobile ergonomics.

## Status
complete — sections 1–10 + group summary (2026-10-11)

---

## 1. StudioScreen (shell, repo bar, banners, app bar) — `studio_screen.dart`

**What it is / how reached:** the code workspace. Reached via `openStudio()`
(`sandbox_setup.dart`) from the chat composer's folder chip / sidebar, and from
the sandbox-missing banner. Hosts the repo bar, approval / sync / clone banners,
the file tree, editor and terminal panes (`StudioPaneViewport`), the app-bar
account chip and auth badge, and drives the repo picker, branch picker,
clone-target sheet, working-folder sheet and the commit dialog (sections 2–4).

**Findings**

- **P1 · functional / data truth · `studio_screen.dart:306-313`** — `_autoSync` awaits
  `RepoCache.sync()` and throws away the returned `SyncReport`. `RepoCache.sync`
  documents (`repo_cache.dart:592-594`) that a PARTIAL sync does **not** throw and the
  caller must surface `report.partial` / `report.summary`; nothing in `lib/ui` reads
  `lastSyncReport` (grep). A repo over the 2000-file cap, a truncated tree, files over
  2 MB, per-file fetch failures or a deadline overrun all render as a clean, complete
  tree. **Impact:** the user (and the agent) edits/commits against a silently
  incomplete working copy and believes files are missing from the repo. **Fix:** keep
  the report: `final report = await syncing; if (report.partial) setState(() =>
  _syncWarning = report.summary)` and render it as a dismissible amber banner (reuse
  `_SyncErrorBanner` with a non-error style) with "N files not loaded — Retry".
  Change `_runSync` to return `Future<SyncReport?>`.
- **P1 · unsaved-changes loss · `studio_screen.dart:2112-2153` + `github_service.dart:115-124`**
  — Sign-out calls `RepoCache.I.unbind()`, which clears `files`, `_dirty`,
  `_unsaved` and every stashed `_workingCopies` entry (`repo_cache.dart:552-575`). In API
  mode (no workspace folder) uncommitted edits live **only** in that in-memory map, so
  sign-out silently destroys them; the dialog copy ("The repo connection will be
  cleared") does not mention it. **Fix:** in `_confirmSignOut` read
  `RepoCache.I.dirtyCount`; when > 0 show "You have N uncommitted file(s). Commit them
  first or they will be discarded." with *Commit first* / *Discard and sign out*.
- **P1 · unsaved-changes loss · `repo_cache.dart:1135-1142`, `:467-475`** — API-mode
  edits (`RepoCache.write`) are never persisted (only commit *intent* goes to
  SharedPreferences, `repo_cache.dart:280-356`). Android process death (very common
  when the user switches to a browser to sign in to GitHub, or to the file picker) loses
  every pending edit. Studio gives no indication that edits are volatile. **Fix:**
  persist dirty buffers (path → content + revision) per `_copyKey` under
  `getApplicationSupportDirectory()/studio_drafts/` with a debounced async write on
  `write()`, restore in `bind()`; until then show an "Unsaved — kept in memory only"
  chip next to the commit count.
- **P2 · error copy · `studio_errors.dart:46-66`** — `StudioFailure._messageFor` matches
  bare substrings `'401'`, `'403'`, `'404'`, `'network'`, `'not found'` anywhere in
  the raw text. A 403 *rate-limit* abort (`repo_cache.dart:663-666` says
  "authorization failed or rate-limited (403)") tells the user to sign in again; a
  folder path or SHA containing `404` becomes "GitHub could not find that repository";
  `git: command not found` becomes a GitHub 404. **Fix:** match status codes with a
  word-boundary regex tied to context (`RegExp(r'\b(HTTP |status |\()40[134]\b')`),
  give rate-limit (`rate limit`, `403` + `x-ratelimit-remaining: 0`) its own message
  ("GitHub rate limit reached — try again in N minutes"), and have core throw typed
  exceptions (`GitHubAuthException`, `RateLimitException`) instead of string parsing.
- **P2 · error copy · `studio_errors.dart:67-78` vs `studio_screen.dart:440-443`** — the
  `clone` rule is checked before the `sandbox not installed` rule, so
  `_sandboxGitClone`'s "Linux sandbox not installed — … retry the clone" always shows
  the generic "could not be cloned" headline. The sandbox copy also says "Open Studio
  once to install it" while the user is already in Studio. **Fix:** move the sandbox
  rule above `clone`; change copy to "Install the Linux sandbox (banner above), then
  try again." and attach an *Install* action to the toast.
- **P2 · sync IO on UI isolate · `studio_screen.dart:639`, `:659-668`, `:384`** —
  `_pickWritableFolder` does `Directory.existsSync`, `writeAsStringSync`, `deleteSync`
  on the UI isolate; `_offerCloneTarget` calls `GlobalRepoRegistry.checkoutMatches`
  (`global_repo_registry.dart:329-350`, several `readAsStringSync`). On SAF/FUSE-backed
  external storage these can stall for 100+ ms. **Fix:** use the async variants
  (`await Directory(path).exists()`, `await probe.writeAsString(...)`) and add an async
  `checkoutMatchesAsync`.
- **P2 · flow / copy · `studio_screen.dart:353-355` vs `:722`** — the doc comment says
  dismissing the clone-target sheet "keeps the default session-sandbox workspace", but
  `_pickRepo` returns early on `false`, so dismissing (or a failed clone) silently
  discards the repo pick; the repo bar keeps the old repo with no message. **Fix:** on
  dismissal toast "Repository not changed", or bind the repo in API mode (no working
  copy) as the comment promises.
- **P2 · long-running work · `studio_screen.dart:472-485`, `:520`, `:551`** — clones run
  up to 10 minutes behind a static "Cloning repo@branch …" banner: no progress, no
  cancel, and leaving Studio does not stop it. **Fix:** pass `--progress` and stream
  stderr lines (`Receiving objects: 43%`) into `_StatusBanner` via the same
  fraction parser as sync; add a Cancel action that kills the sandbox process and
  removes the partial dest (registry already deletes partials on failure).
- **P2 · ergonomics · `studio_screen.dart:2254-2279`** — the approval banner renders
  `a.detail` (full command / file body) with no line cap inside the chrome stack;
  a long `write_file` approval pushes the editor and terminal off a phone screen.
  **Fix:** `maxLines: 6, overflow: fade` with a "Show all" toggle that opens the detail
  in a scrollable bottom sheet.
- **P2 · UX / copy · `studio_screen.dart:404`** — "Session clone … reused by future
  sessions" hides that every chat bound to the same repo+branch shares **one** folder
  (`global_repo_registry.dart:390-397`), so two concurrent agents edit the same files.
  **Fix:** subtitle "Shared with other chats on this repo + branch"; show a warning
  chip in the repo bar when another active session is bound to the same path.
- **P2 · state · `studio_screen.dart:757`** — `setState` after awaiting the branch sheet
  without a `mounted` check (route can be popped by a system back while the sheet
  animates out). **Fix:** `if (!mounted) return;` before the `setState`.

**Missing features**
- Partial-sync / "N files not loaded" indicator and a way to load a skipped file on demand.
- "Pull" vs "Push" distinction and ahead/behind counts in the repo bar (ChatGPT Codex /
  Claude Code web both show branch status); currently "Sync" is a full re-download.
- Create-branch / open-PR actions from the branch sheet (Claude Code web parity: work on a
  new branch, then open a PR).
- Cancel for clone and sync.

**Test to add**
- Widget test: override `studioRepoSyncProgressOverrideForTest` to complete with a
  `SyncReport(partial: true, droppedByCap: 10)` → expect a visible "10 files not loaded" banner.
- Widget test: `RepoCache.I.write('a.txt','x')` then sign out via the account chip →
  expect the "uncommitted file(s)" warning dialog before `signOut` runs.
- Unit test for `StudioFailure.of`: `'authorization failed or rate-limited (403)'`
  must not map to the sign-in message; `'Linux sandbox not installed … retry the clone'`
  must map to the sandbox message; `'/sdcard/p404/x: Permission denied'` must map to
  the permission message.

---

## 2. StudioCommitDialog (review / stage / commit) — `studio_screen.dart:1164-1346`

**What it is / how reached:** app-bar "Commit N pending file(s)" (overflow menu below
600dp). Lists `RepoCache.pendingPaths` with checkboxes and a staging menu, "Review
changes" builds a `CommitApproval` (`RepoCache.prepareCommit`), "Approve and commit"
publishes via the GitHub Git Data API; "Reconcile pending commit" recovers a
crashed publication; "Stage missing file deletion" opens a nested path dialog.

**Findings**

- **P1 · functional / review quality · `studio_screen.dart:1330` + `repo_cache.dart:185-214`**
  — the "diff" is not a diff: `CommitApproval.diff` writes every old line with `-` and
  every new line with `+` for each file (a whole-file replacement, one `@@` hunk). A
  one-line change to a 2 000-line file shows 4 000 lines, and the reviewer cannot find
  what changed — the approval step exists to stop bad agent edits, and it is not
  usable. **Fix:** compute a real line diff (Myers; e.g. `package:diff_match_patch`
  line mode) in `Isolate.run`, emit unified hunks with 3 lines of context, cache it on
  the approval (it is a getter today — recomputed on every dialog rebuild).
- **P1 · large-content / perf · `studio_screen.dart:1304-1331`** — the whole diff string
  is rendered as one `SelectableText` inside `AlertDialog(scrollable: true)` +
  another `SingleChildScrollView`, together with a non-lazy `for` of
  `CheckboxListTile`s. A large generated file (lockfile, minified JS) produces a
  multi-MB single text layout → multi-second jank or OOM on low-end phones.
  **Fix:** replace the dialog with a full-screen route (`MaterialPageRoute(fullscreenDialog:
  true)`); per-file collapsible sections in a `ListView.builder`; cap each file's
  rendered hunk lines (e.g. 400) with "Show full diff"; drop the nested scroll view.
- **P1 · sync IO on UI isolate · `studio_screen.dart:1192-1210` → `repo_cache.dart:1397-1404`,
  `:1144-1160`, `:1310-1345`** — `_cacheChanged` runs on **every** `RepoCache`
  notification (each agent `write`, each sync publish) and calls `validateApproval`,
  which for every approved path calls `_commitContent` → `_stagingPath`
  (`resolveSymbolicLinksSync`, a `typeSync` per parent directory) → `read()`
  (`readAsBytesSync` + UTF-8 decode of the whole file, no size cap). With the dialog
  open while the agent is writing, the UI isolate re-reads every selected file from disk
  per notification. **Fix:** only revalidate on explicit "Approve" (validation already
  runs inside `_commit`), or debounce `_cacheChanged` 300 ms and run the file reads via
  an async `readAsBytes`; mark the approval stale by comparing `_revisions`/generation
  (in-memory, cheap) instead of re-reading bytes.
- **P1 · raw errors · `studio_screen.dart:1209`, `:1221`, `:1235`, `:1252`, `:1283`** —
  `_error = '$e'` shows raw exception text: "Exception: commit preview fetch failed:
  409 — no non-atomic fallback; per-file commits require explicit approval",
  "Bad state: repo not bound", the multi-clause "commit outcome unknown … intended
  commit <sha>; observed ref …" (`repo_cache.dart:1798-1805`). This is the one Studio
  surface that bypasses `StudioFailure`. **Fix:** map `CommitFailure.kind` to copy
  (`staleApproval` → "Files changed since you reviewed. Review again.",
  `upstreamConflict` → "The branch moved on GitHub. Sync, then review again.",
  `unknown` → "We could not confirm the commit. Tap *Check status* before retrying."
  with the SHA in a copyable secondary line); everything else through `StudioFailure`.
- **P2 · UX / auto-selection · `studio_screen.dart:1195-1197`** — any path the agent
  dirties while the dialog is open is appended **and auto-selected**, which silently
  invalidates the review and adds a file the user never looked at. **Fix:** append new
  paths unchecked with a "New since review" label.
- **P2 · copy / jargon · `studio_screen.dart:1338`, `:1258-1288`, `:1313-1317`, `:1327`** —
  "Reconcile pending commit" is always shown (even with no intent; it then errors
  "No unresolved commit intent"), "Stage missing file deletion" needs the user to type
  a repo-relative path from memory, and subtitles say "Content · review exact diff" /
  "Staged Git mode 100755". **Fix:** show *Check last commit* only when
  `RepoCache` has a persisted intent for this repo/branch (expose `hasPendingIntent`);
  replace the free-text deletion dialog with a picker over `treePaths` that are
  missing on disk; subtitles "Modified" / "Deleted" / "Made executable".
- **P2 · validation · `studio_screen.dart:1340`** — "Review changes" is enabled with an
  empty message; the user gets a raw `Commit message is empty` error after a tap.
  **Fix:** disable while `_message.text.trim().isEmpty` and add `maxLength`/helper text.
- **P2 · info shown · `studio_screen.dart:1308`** — header shows
  `RepoCache.I.defaultBranch`, which is actually the *bound* branch; fine, but the
  approval block (`:1329`) prints the full 40-char base SHA and a comma-joined path list
  as one `Text`. **Fix:** short SHA (7), one path per line, `SelectableText` for the SHA.
- **P2 · keyboard / small screen · `studio_screen.dart:1301-1344`** — `AlertDialog` with a
  `SizedBox(width: 640)` content and three actions; with the IME up on a 360×640 phone
  the message field, the list and the action bar compete for ~250dp. **Fix:** the
  full-screen route above, message field pinned at the bottom with the primary button.

**Missing features**
- Per-file "Discard changes" (revert to upstream) from the commit list — today the only way
  to drop an agent edit is to re-type the original.
- "Commit to new branch + open PR" (Claude Code web parity).
- Commit message suggestion from the agent (ChatGPT Codex / Claude Code both draft one).

**Test to add**
- Unit test on `CommitApproval.diff` (after fix): one changed line in a 100-line file
  yields one hunk with ≤ 7 lines.
- Widget test: open the dialog with an approval, then fire 50 `RepoCache.notifyListeners()`
  and assert no `File.readAsBytesSync` (inject an `IOOverrides` counter).
- Widget test: `prepareCommit` throws `CommitFailure(staleApproval, …)` → dialog shows the
  mapped copy, not the raw message.

---

## 3. Repo picker / branch picker / clone-target / working-folder sheets — `studio_screen.dart:356-423, 571-609, 688-767, 1795-1995`

**What it is / how reached:** repo bar *Connect/Change* → `StudioRepoSheet`
(`_AsyncPickerSheet` over `GitHubService.listRepos`) → "Where should repo live?" sheet
(Session clone / Local folder clone) → clone. Branch chip → `StudioBranchSheet`.
App-bar folder icon → "Working folder" sheet (Change folder / Use session sandbox).

**Findings**

- **P1 · broken flow · `github_service.dart:718-735` (called from `studio_screen.dart:702`)**
  — `listRepos` requests `per_page=30&sort=updated` and never paginates; the sheet has no
  search box. Any user with more than 30 repos (most professional developers, every org
  member) **cannot pick an older or org repo at all**. **Fix:** add a search field at the
  top of `_AsyncPickerSheet`; back it with `GET /user/repos?per_page=100&page=n`
  (infinite scroll) and, when a query is typed, `GET /search/repositories?q=<q>+user:<login>`
  plus `affiliation=owner,collaborator,organization_member`.
- **P2 · branch cap · `github_service.dart:750-789`** — branches capped at the first 100
  with no search and no hint; repos with many feature branches cannot switch to most
  of them. **Fix:** follow the `Link: rel="next"` header (or `/git/matching-refs/heads/<q>`
  for search) and add the same search field.
- **P2 · perf · `studio_screen.dart:1956-1993`, `:1816-1824`, `:1873-1888`** — every picker
  is `ListView(shrinkWrap: true, children: [for …])`: all tiles are built eagerly and
  laid out twice. Fine at 30, not at 100+ after pagination. **Fix:** `ListView.builder`
  inside a `DraggableScrollableSheet` (no `shrinkWrap`).
- **P2 · UX · `studio_screen.dart:1840-1841`** — repo tile subtitle is language + star
  count; private/fork/archived status and owner (personal vs org) are not shown, and
  archived repos are pickable even though commits will fail. **Fix:** show a lock icon
  for `private`, an "Archived · read-only" label, disable commit for archived repos.
- **P2 · data safety copy · `studio_screen.dart:496-512`** — switching branch on a cloned
  workspace clones a *second* folder and rebinds; uncommitted edits stay in the old
  folder, but nothing tells the user. **Fix:** if `RepoCache.I.dirtyCount > 0` before
  the switch, confirm "N uncommitted changes stay on <old branch>. Switch anyway?".
- **P2 · picker error copy · `studio_screen.dart:1972`** — every failure reads "Check your
  connection"; a 401 (dead token) loops the user through retries. **Fix:** route `_error`
  through `StudioFailure.of(_error).message` and offer *Sign in* on auth failures.

**Missing features**
- Repo search, org filter, "Recently used" section (from `GlobalRepoRegistry.branchFor`).
- Create a new repository / new branch from the picker.

**Test to add**
- Widget test: loader returns 120 repos → a search for the 110th name finds it; sheet uses a
  lazy builder (assert only visible tiles are built).
- Widget test: switching branch with `dirtyCount == 2` shows the confirmation.

---

## 4. StudioEditorTabs + StudioEditor (+ New-file dialog, conflict banner, find bar) — `studio_editor.dart`

**What it is / how reached:** the centre pane of Studio. Tabs come from
`AgentService.studioOpenFiles` (per-session bucket); opening a tree row or an agent
`file_read/write` adds a tab. The editor keeps one `TextEditingController` per
`(fileBuffer map, path)`, shows SAVED / UNSAVED / CONFLICT, has find, undo/redo and
a manual Save that writes to the workspace and marks the file pending in `RepoCache`.

**Findings**

- **P0 · unsaved-changes loss · `studio_editor.dart:218-231`, `:295-309`, `:326-332`,
  `:372-387`; `studio_screen.dart:856-862`; `agent_service.dart:4899-4907`** — the dirty
  flag, baselines and controllers live only in `_StudioEditorState`, while every
  keystroke is also written into `AgentService.fileBuffer` (`:299`). Studio's only
  `PopScope` (`studio_screen.dart:856`) guards the tree overlay, not drafts, and
  there is no autosave. Consequences after the user edits and presses Android back:
  (a) on return, `_bind` builds a fresh controller from the draft in `fileBuffer`,
  sets `_baselines` = draft and the tab reads **SAVED** with Save disabled, although the
  text was never written to disk; (b) tapping the file in the tree calls
  `openStudioFile(path, <disk bytes>)` (`studio_file_tree.dart:167-170`), which
  overwrites `fileBuffer[path]`; the non-dirty controller then takes the disk text
  (`studio_editor.dart:360-366`) and the draft is gone with no prompt. Closing a tab
  (`:175` → `agent_service.dart:5093-5100`) also has no dirty check. **Impact:** silent
  loss of hand-written code on the most common Android gesture. **Fix:** move the dirty
  set + baseline into `_SessionStudio` (core, survives the widget); add
  `PopScope(canPop: !hasDirtyBuffers)` on `StudioScreen` with a Save all / Discard /
  Cancel dialog; confirm on tab close when dirty; add a 2 s debounced autosave of drafts
  to an app-private drafts dir (restore on open) and save-on-`AppLifecycleState.paused`.
- **P1 · perf (rebuild scope) · `studio_editor.dart:248-250`, `:537-539`, `:288-291`;
  `studio_file_tree.dart:220-227`** — the editor listens to `AgentService` twice
  (listener → `_bind` → `setState`, **and** an `AnimatedBuilder(AgentService.I)` around
  the whole build), and the tree rebuilds on every `AgentService` notification.
  `AgentService` notifies on every streamed token, so while the agent is answering,
  each token re-runs `_bind`, `_positionOf` (two full-text `allMatches('\n')` scans +
  a `substring` of the prefix, `:888-899`), `_recomputeMatches` (full `toLowerCase`
  copy when find is open) and `buildStudioTree` over up to 2 000+ paths
  (`studio_file_tree.dart:226-227`, also sorts a copy of `pendingPaths`). **Fix:** expose
  a narrow `ValueListenable<StudioTabsState>` from `AgentService` (open files, active
  path, buffer revision) and listen to that only; drop the outer `AnimatedBuilder`;
  cache line count per controller revision and compute line/col incrementally from
  the selection; memoize `buildStudioTree` on `(RepoCache treeRevision, _expanded)`.
- **P1 · large-file handling · `studio_editor.dart:847-886`, `studio_file_tree.dart:167`,
  `repo_cache.dart:1144-1160`, `:1040-1062`** — any file opens into a single
  `TextField(maxLines: null, expands: true)`. Flutter lays out the whole text as one
  paragraph; a 1–2 MB file (lockfile, bundle, generated code) costs seconds per layout
  and every keystroke re-lays it out → ANR. Workspace `read()` has **no size cap** and
  runs `readAsBytesSync` on the UI isolate on tree tap; API mode `_fetchRaw` has no cap
  either. **Fix:** stat first (async); > 256 KB → open a read-only virtualised viewer
  (`ListView.builder` over lines, `SelectableText` per line) with an "Edit anyway"
  escape hatch up to a hard cap (e.g. 1 MB); > hard cap → "Too large to open on device"
  with *Open in terminal* (`less`). Do the read with `await File.readAsBytes()` and
  decode in `compute` above ~200 KB.
- **P1 · data corruption (binary files) · `repo_cache.dart:1061`, `:944-961`;
  `studio_editor.dart:482-532`** — API-mode fetches decode with `allowMalformed: true`,
  and the skip list misses many binary types (`.gz`, `.tar`, `.7z`, `.otf`, `.mp3`,
  `.db`/`.sqlite`, `.jks`/`.keystore`, `.class`, `.dex`, `.heic`, `.wasm`). Such a file
  opens as U+FFFD soup; any edit + Save writes the mangled text and marks it pending, so
  a commit replaces the binary in the repo with garbage. **Fix:** classify by content
  (NUL byte in the first 8 KB or > 10 % U+FFFD after decode) → open a "Binary file —
  not editable" placeholder, never mark it writable; make `RepoCache.write` refuse
  paths flagged binary.
- **P1 · memory / leak · `studio_editor.dart:221-228`, `:566-571`** — controllers,
  undo histories and listeners are added per `(fileBuffer, path)` and **never removed**
  when a tab is closed or the session/branch bucket changes; `IndexedStack` keeps every
  one of them mounted and **laid out** (IndexedStack lays out all children). Ten opened
  files = ten full-text paragraphs re-laid out on each resize/keyboard animation, and
  the text of closed files stays in memory until Studio is popped. **Fix:** prune
  `_buffers`/`_undoControllers`/`_baselines`/… for keys whose path is not in
  `studioOpenFiles` (or whose map is not the current `fileBuffer`) in `_bind`, and
  render only the active field (keep `ScrollController` offsets in a map to restore
  scroll on tab switch) instead of `IndexedStack`.
- **P2 · sync IO on UI isolate · `studio_editor.dart:496`, `:508-510`** — Save uses
  `existsSync`, `createSync`, `writeAsStringSync` on the UI isolate; it also duplicates
  `AgentService.saveStudioFile` (`agent_service.dart:4910-4954`), which has the same
  sync writes. **Fix:** one async save path in `AgentService.saveStudioFile` using
  `await file.parent.create(recursive: true)` + `await file.writeAsString(text,
  flush: true)` (write to `*.tmp` then `rename` for atomicity); call it from the editor.
- **P2 · keyboard ergonomics · `studio_editor.dart:543-553`, `:847-886`** — no
  Ctrl/Cmd+S binding (only find), hardware Tab moves focus instead of indenting, no
  auto-indent on Enter, and no accessory row for `Tab { } ( ) [ ] ; : " ' < > / | ←
  →` above the soft keyboard — typing code on a phone keyboard is impractical.
  **Fix:** add `SingleActivator(keyS, control/meta)` → `_save`; intercept Tab/Shift+Tab
  via `Shortcuts`+`Actions` on the field to insert/remove indent; keep current-line
  indentation on newline; add a `KeyboardAccessoryBar` shown while the field has focus
  and `MediaQuery.viewInsets.bottom > 0`.
- **P2 · find correctness · `studio_editor.dart:904-917`** — matches are found in
  `haystack.toLowerCase()` but ranges are applied to the original text; for characters
  whose lowercase changes length (`İ` → `i̇`), every later range is shifted and
  `ctrl.selection` can exceed `text.length` (assertion/RangeError). **Fix:** use
  `RegExp(RegExp.escape(needle), caseSensitive: false).allMatches(haystack)`.
- **P2 · conflict UX · `studio_editor.dart:581-598`** — "This file changed externally"
  offers *Keep draft* / *Use external* with no way to see the difference; the agent's
  edit and the user's draft are both full files. **Fix:** add *Compare* opening a
  two-pane/line diff (reuse the commit diff once it is a real diff).
- **P2 · new-file validation · `studio_editor.dart:50-86`, `agent_service.dart:5086-5091`**
  — the path is not validated (`../x`, `/abs`, empty segments, an existing file);
  `RepoCache.create` / save later throws a raw StateError toast. Creating an existing
  path silently opens an empty buffer over it (`openStudioFile(path, '')`), and Save then
  truncates the real file. **Fix:** validate in the dialog (`errorText`), reject paths
  already in `treePaths`/on disk ("Already exists — open it instead"), pre-fill the
  currently selected directory.
- **P2 · small-screen chrome · `studio_editor.dart:600-755`** — below 760dp the header is
  two rows (identity + 4 icon buttons) on top of the 46dp tab strip; with the keyboard
  up on a 640dp phone, the editable area drops to ~150dp. **Fix:** when
  `viewInsets.bottom > 0` collapse header to one 36dp row (name + pill + overflow menu)
  and hide the terminal pane (see §6).

**Missing features**
- Line numbers + gutter, syntax highlighting (`re_editor`/`flutter_code_editor`), go-to-line,
  find & replace, word-wrap toggle, font-size pinch.
- "Save all", autosave setting, unsaved dot on tab chips (tabs show no dirty state today:
  `_tab` renders name only, `studio_editor.dart:134-181`).
- Markdown/HTML preview (`RepoCache.exportPreview` exists but is not reachable from the editor).
- "Ask AI about selection" / "Explain this file" from the editor (Claude Code / ChatGPT canvas parity).

**Test to add**
- Widget test: type into a buffer, pop `StudioScreen` → expect the unsaved-changes dialog;
  choose Discard, reopen Studio → tab shows disk content and SAVED.
- Widget test: pump `StudioEditor`, then call `AgentService.I.notifyListeners()` 100× →
  assert `buildStudioTree`/`_positionOf` invoked ≤ 1× (inject counters) after the fix.
- Unit test: open a 3 MB file path → read-only viewer is shown, no `TextField`.
- Unit test: `_findAll('İx İx', 'x')` returns ranges within `text.length`.

---

## 5. StudioFileTree (+ staging menu) — `studio_file_tree.dart`

**What it is / how reached:** left pane (docked ≥ 840dp, overlay < 600dp via the
app-bar folder toggle). Flattened tree from `RepoCache.treePaths ∪ files ∪ pending`,
tap to open, per-file "⋮" staging menu (mode 100755/100644, stage deletion).

**Findings**

- **P1 · sync IO on UI isolate · `studio_file_tree.dart:167`** — `RepoCache.read()` in
  workspace mode does `typeSync` + `readAsBytesSync` + full UTF-8 decode on the UI
  isolate with no size limit (`repo_cache.dart:1144-1160`). On external storage via
  All-Files-Access this is FUSE-backed and slow. **Fix:** add
  `Future<String?> RepoCache.readAsync(path, {int maxBytes})` using `await
  file.length()` + `openRead`, decode in `compute` when large; show the row's
  `_loading` state while it runs (already supported).
- **P2 · state truth · `studio_file_tree.dart:482-540`** — the footer says
  "Synced · N files" whenever `repoFull != null && files.isNotEmpty`, including after a
  partial sync; in local-folder mode with no repo it says "Not connected" although the
  folder is loaded; the empty state always says "Connect a repo" even while a sync is
  running or after it failed. **Fix:** drive the footer from `lastSyncReport`
  ("Synced 1 940 of 2 300 files · 2 min ago" / "Local folder · N files"); the empty
  state should say "Syncing…" / "Sync failed — Retry" / "Connect a repo" by state.
- **P2 · jargon / clutter · `studio_file_tree.dart:396-452`** — every file row carries a
  "⋮" with "Stage executable (100755)" / "Stage regular (100644)" / "Stage deletion
  (already missing)"; in the 260dp overlay this costs ~40 % of the row width; errors show
  raw `'$e'` (`:443`). **Fix:** move staging into a long-press sheet with plain labels
  ("Make executable", "Delete from repository"), add Rename / Delete / New file here /
  Copy path, route errors through `StudioFailure`.
- **P2 · perf · `studio_file_tree.dart:60-116`, `:226`** — `buildStudioTree` is
  `O(n·depth)` string joins and runs on each rebuild (see §4 rebuild finding). With the
  2 000-file cap and 20 000-entry walk this is a measurable per-token cost. **Fix:**
  memoize as noted in §4.
- **P2 · a11y · `studio_file_tree.dart:347-350`** — the row's `MouseRegion` sets
  `SystemMouseCursors.click`; fine on desktop, but directory rows report only
  "folder, collapsed" — no depth / position ("level 3"). **Fix:** add
  `Semantics(… value: 'level ${depth+1}')` (minor).

**Missing features**
- Filter / quick-open (fuzzy file search) — essential on a phone where the tree is an overlay.
- Changed-file indicators in the tree (M / A / D badges from `pendingPaths`, staged state).
- Collapse-all, reveal active file.

**Test to add**
- Widget test: `RepoCache` with 3 dirty paths → rows show an "M" badge.
- Widget test: tapping a 5 MB workspace file does not call `readAsBytesSync` (IOOverrides)
  and shows the large-file viewer.


---

## 6. StudioTerminalTabs (multi-terminal pane) — `studio_terminal_tabs.dart` (+ `core/studio_terminal.dart`)

**What it is / how reached:** bottom pane of `StudioScreen` (`studio_screen.dart:1139-1155`),
always mounted; collapses to its 44dp header strip on short viewports. The strip is a
segmented control ("bash 1", "bash 2", …) plus Close / New / Collapse buttons and doubles
as the vertical resize handle. Each tab owns a `StudioShellSession` (persistent piped
`bash` in the sandbox via `PtyPool`, owner-scoped so agent Stop never kills it) with a
5 000-line scrollback, a one-line command field and a Stop / Clear affordance. Falls back
to one-shot `SandboxService.exec` when no persistent shell can be spawned.

**Findings**

- **P1 · functional (dead control) · `studio_terminal_tabs.dart:423-435`** — the Stop
  button is the field's `suffixIcon`, but the same `TextField` is `enabled: !s.busy`.
  A disabled `TextField` wraps its whole `InputDecorator` (suffix included) in
  `IgnorePointer(ignoring: !_isEnabled)` (`flutter/.../material/text_field.dart:1802-1803`),
  so the Stop button is drawn exactly when it cannot receive taps. **Impact:** a hung
  command (`npm start`, `tail -f`, a dev server, a prompt) wedges the tab for the full
  5-minute watchdog (`studio_terminal.dart:39`); the only escape is closing the tab and
  losing its scrollback. No test taps Stop (neither `test/studio_terminal_widget_test.dart` nor
  `test/ui_finish_06_studio_test.dart` references it). **Fix:** keep the field enabled and use `readOnly: s.busy`, or
  move Stop out of the decoration into the trailing `Row` slot next to Clear; add a
  widget test that taps Stop while busy and asserts `busy == false`.
- **P1 · functional (interactive commands) · `studio_terminal.dart:111-114`;
  `studio_terminal_tabs.dart:435`** — commands are written to bash stdin followed by
  `echo "<token>"`; the input is disabled while busy and there is no way to send stdin
  or Ctrl-C. Anything that reads stdin (`read`, `npm init`, `apt install` y/N, `python`
  without args, `git commit` without `-m` opening an editor, `ssh` host-key prompt)
  either **swallows the token line as its input** or blocks until the 5-minute watchdog,
  which then kills the shell (losing `cd`/exports). An unbalanced quote or heredoc
  (`echo "foo`) also consumes the token. **Impact:** the most common first commands a
  developer types on a fresh project hang silently for 5 minutes. **Fix:** (a) while
  busy, keep the field enabled and route submissions to `shell.writeStdin` (label the
  hint "stdin for running command…"); (b) add a Ctrl-C action that signals the
  foreground process group instead of discarding the shell; (c) export
  `GIT_EDITOR=true PAGER=cat GIT_PAGER=cat DEBIAN_FRONTEND=noninteractive CI=1
  NPM_CONFIG_YES=true` in the spawned shell; (d) refuse to dispatch commands with
  unbalanced quotes ("Unclosed quote"); (e) replace the hard 5-minute kill with an
  "idle 60 s without output — Still running · Stop" notice.
- **P2 · bug (stale state) · `studio_terminal_tabs.dart:119-126` vs `:162-174`** — the
  segmented `options` (with the busy `Icons.sync` / idle chevron) are computed in
  `_strip` *outside* the `AnimatedBuilder` that is supposed to refresh them, so the
  builder rebuilds with the captured list and the busy icon only changes when the parent
  happens to `setState`. **Impact:** a background tab running a build looks idle.
  **Fix:** build `options` inside the `AnimatedBuilder` builder.
- **P2 · UX / destructive · `studio_terminal_tabs.dart:68-80`, `:123`, `:183-188`** —
  "Close terminal" on a busy tab kills the running process with no confirmation, and tab
  labels are derived from the list index, so closing "bash 1" silently renames "bash 2"
  to "bash 1" (the tooltip "Close terminal N" also shifts). **Impact:** users close the
  wrong shell / kill a long build. **Fix:** stable labels from the session sequence
  number (or the shell's cwd basename), confirm "Stop the running command and close?"
  when `shell.busy`.
- **P2 · lifecycle / data loss · `studio_terminal_tabs.dart:82-88`** — terminals are owned
  by the widget; leaving Studio (Android back, or `openStudio` → setup) disposes every
  `_TerminalSession`, discarding the shell (`studio_terminal.dart:202-215`) and its
  scrollback. **Impact:** a 3-minute `npm install` dies the moment the user goes back to
  chat to ask a question. **Fix:** hoist sessions into a core `StudioTerminalRegistry`
  keyed by chat/sandbox session that outlives `StudioScreen`; dispose only on explicit
  close, session delete or app teardown; show a "1 terminal running" chip in the chat
  header/Studio entry point.
- **P2 · output fidelity · `studio_terminal_tabs.dart:361-377`; `pty_service.dart:87-98`** —
  output is a pipe, not a PTY, and lines are rendered verbatim: ANSI SGR/cursor escapes
  from tools that force colour show as `[0;32m` garbage, `\r` progress frames from
  `pip`/`git clone`/`curl` are not collapsed, stderr arrives as `[stderr] …` in the muted
  colour, the exit status is never shown, and *any* output line starting with `$` is
  coloured as a prompt. **Fix:** strip (or render) SGR codes, keep only the text after
  the last `\r` per line, colour `[stderr]` lines as warnings, change the sentinel to
  `echo "<token> $?"` and print a trailing "exit 1" chip in danger colour for non-zero.
- **P2 · perf · `studio_terminal_tabs.dart:333-381`; `studio_terminal.dart:47-52`,
  `:154-166`, `:192-199`** — every output line calls `notifyListeners`, which rebuilds the
  entire pane (ListView + input row) and queues a post-frame scroll; each visible line is
  its own `SelectableText` (own gesture recognisers + focus node). A verbose build can
  emit hundreds of lines per second → hundreds of rebuilds per second on the UI isolate.
  **Fix:** coalesce notifications to one per frame inside `StudioShellSession`
  (`SchedulerBinding.scheduleFrameCallback` guard), render plain `Text` rows under one
  `SelectionArea`, and give rows `itemExtent`/`prototypeItem` for cheap scrolling.
- **P2 · a11y / copy · `studio_terminal_tabs.dart:340-343`, `:362`** — selection is per
  line (cannot select a multi-line stack trace), there is no "Copy all output", and
  command completion is never announced to TalkBack users (output just grows silently).
  **Fix:** `SelectionArea` over the list, a "Copy output" action in the strip overflow,
  `SemanticsService.announce('Command finished, exit 0')` on busy→idle.
- **P2 · error copy · `studio_terminal_tabs.dart:309-311`, `:321-324`** — any spawn
  failure is swallowed and retried via one-shot exec; when that also fails the user sees
  only the raw first line of the exception (Dart type + message) with no route to fix
  it. **Fix:** when the failure is "sandbox missing", print the human message plus an
  inline "Set up sandbox" action that calls `openStudio`.

**Missing features**
- Command history (↑/↓ recall, persisted per repo) and Tab completion of paths.
- Extra-keys row above the soft keyboard (Esc, Tab, Ctrl, ←↑↓→, `|`, `~`, `/`, `-`) as in
  Termux — essential on Android keyboards.
- Real PTY (`forkpty`) so `top`, `less`, `vim`, `git log` pager and colour work; until then
  a clear "non-interactive terminal" notice.
- Rename tab / show cwd in tab label; "Run in terminal" from the editor (run current file,
  `npm test`); link-detection for `localhost:PORT` that opens the in-app browser.
- Background-running indicator and notification when a long command finishes while the
  user is in chat.

**Test to add**
- Widget test: spawner override that runs `sleep 30`; tap the Stop button → `busy` is
  false and the field is enabled (fails today because of `IgnorePointer`).
- Unit test: `StudioShellSession.runPersistent('read x')` with a fake shell → the
  completion token must not be consumed as stdin (or a stdin path exists to answer it).
- Widget test: two tabs, tab 2 busy → its segment shows `Icons.sync` without a parent
  rebuild.
- Perf test: push 10 000 lines in one burst → ≤ 2 pane rebuilds per frame.

---

## 7. Studio layout + shared chrome — `studio_layout.dart` (+ `_workspace` split, `studio_screen.dart:1043-1158`)

**What it is / how reached:** not a screen of its own; the geometry and primitives every
Studio surface uses: `StudioMetrics` (compact < 600 / medium < 840 / expanded window
classes, tree width, terminal height and text-scale-aware minimums),
`StudioPaneViewport` (scrolls banners above a min-height pane), `StudioIconButton`,
`StudioTapTarget`, `StudioPaneDivider`, `showStudioSheet` + `StudioSheetHeader` +
`StudioSheetTile`, `showStudioToast`, and the sync-progress parsers. Reviewed together
with the split that consumes it in `StudioScreen._workspace`.

**Findings**

- **P1 · state loss (layout) · `studio_screen.dart:1102-1135`** — on compact widths,
  opening the file panel swaps the `Expanded` child from `split` (a `Row`) to
  `Stack([split, scrim, panel])`. Different widget type at the same slot → Flutter
  unmounts the whole `Row` subtree, so `StudioEditorTabs` / `StudioEditor` state is
  disposed and rebuilt every time the panel is opened **and** closed. **Impact:** on a
  phone (the primary form factor) each tap on the folder icon discards undo history,
  find-bar state, scroll position and the in-widget dirty flags — which, combined with
  the §4 P0, makes an unsaved draft re-appear as **SAVED**. **Fix:** always build
  `Stack(children: [split, if (overlay) scrim, if (overlay) panel])` (stable first child),
  or give the editor column a `GlobalKey`; add a widget test (below).
- **P2 · a11y (double announce) · `studio_layout.dart:376-399`** — `StudioIconButton` wraps
  an `IconButton` in `Semantics(button, label)` **and** `Tooltip(message)` (which adds
  its own semantics label), so TalkBack reads e.g. "New terminal, New terminal, button".
  Same pattern in `_CopyChip` and `StudioTapTarget` users that also pass a `Tooltip`.
  **Fix:** `IconButton(tooltip: tooltip, …)` alone (it supplies label + tooltip), drop the
  outer `Semantics`/`Tooltip`; run `meetsGuideline(labeledTapTargetGuideline)` plus a
  semantics-tree snapshot in `test/studio_a11y_test.dart`.
- **P2 · a11y (tap target) · `studio_layout.dart:20`, `:384-391`, `:414-415`** —
  `kStudioTapTarget = 44`, while Android / Material require 48dp
  (`androidTapTargetGuideline`); `StudioSheetTile` already uses 48 (`:597`), so Studio
  ships two standards. Every Studio icon button, tree row and tab close fails Google's
  Accessibility Scanner. **Fix:** set the constant to 48 (layout code already derives
  from it) and switch the test pin to `androidTapTargetGuideline`.
- **P2 · a11y (gesture-only) · `studio_layout.dart:466-513`;
  `studio_terminal_tabs.dart:130-134`** — the tree divider and terminal header resize only
  by drag; the semantics hint says "Drag to resize" but exposes no `onIncrease` /
  `onDecrease`, so TalkBack / Switch Access / keyboard users cannot resize at all, and the
  double-tap reset is undiscoverable. **Fix:** add `Semantics(onIncrease:, onDecrease:)`
  stepping 24dp, a `value` ("File panel 260 of 340"), and arrow-key shortcuts via
  `FocusableActionDetector`.
- **P2 · UX consistency · `studio_layout.dart:518-532`** — `showStudioSheet` has no drag
  handle (`showDragHandle`), defaults `isScrollControlled: false` (sheet capped at
  9⁄16 of the height, so the repo picker at large text shows ~3 rows), and does not use
  `useSafeArea`/`AetherSheet` like the GitHub sheet does — Studio sheets look and behave
  differently from every other sheet in the app. **Fix:** build it on `AetherSheet`, set
  `showDragHandle: true, useSafeArea: true, isScrollControlled: true` with a
  `DraggableScrollableSheet(maxChildSize: .9)` for list sheets.
- **P2 · error UX · `studio_layout.dart:627-666`** — `showStudioToast` has no action slot
  (no Retry / Copy details / Sign in), uses the default 4 s duration even for two-line
  error toasts (too short at 2× text or with TalkBack), and `hideCurrentSnackBar` drops an
  earlier error unseen when two arrive back-to-back. **Fix:** add `action` and
  `duration` params (errors ≥ 8 s or until dismissed), queue instead of hide for errors.
- **P2 · design-system drift · `studio_layout.dart:552`, `:561`, `:608`, `:613`, `:647`,
  `:659`** — hard-coded `fontSize: 15 / 13.5 / 12 / 13` and `Colors.white70` instead of
  `AetherType.*` / `Aether.*` tokens; also the `textScale` doc comment is duplicated
  (`:170-177`). **Fix:** use the theme tokens so light/dark and future type changes
  apply to Studio too.

**Missing features**
- Persist the user's tree width / terminal height / collapsed state per device
  (`_treeWidthOverride` etc. reset on every Studio open).
- Tablet / foldable: a "focus editor" mode that hides tree + terminal with one tap, and
  hinge-aware split on foldables (`DisplayFeature`).
- Landscape phone: auto-collapse the terminal when the IME is open (today the
  `StudioPaneViewport` min-height of 120 dp is all the editor gets).

**Test to add**
- Widget test (360×740): open a file, type, tap the folder toggle twice → the
  `EditableTextState` is the same instance and the tab still reads UNSAVED.
- `meetsGuideline(androidTapTargetGuideline)` and `labeledTapTargetGuideline` over a
  pumped `StudioScreen` at 1.0× and 2.0× text scale.
- Semantics test: the tree divider exposes `SemanticsAction.increase/decrease`.

---

## 8. StudioFailure (error copy mapper) — `studio_errors.dart`

**What it is / how reached:** not a screen; the single mapper that turns exceptions into
Studio's user-facing copy (`message`) + a secondary raw first line (`detail`). Used by
the sync banner (`studio_screen.dart:315`, `:679`), toasts (`studio_editor.dart:524`,
`studio_file_tree.dart:186`, `studio_screen.dart:839`), sign-out (`:2140`) and the
terminal fallback (`studio_terminal_tabs.dart:324`).

**Findings**

- **P1 · wrong copy / misdirection · `studio_errors.dart:46-47`, `:64`** — classification is
  a substring test on the whole raw string: `has('401') || has('403')` and `has('404')`
  match any commit SHA, byte count, line number, port or path containing those digits
  (`"a403f1c"`, `"line 1401"`, `"/tmp/x4040"`). GitHub's **rate-limit** response is also
  HTTP 403, so "API rate limit exceeded" becomes "GitHub rejected your sign-in. Please
  sign in to GitHub again." **Impact:** users are sent to re-authenticate (which does not
  help and burns another device flow) for unrelated or rate-limit failures. **Fix:**
  classify typed errors first (introduce a `GitHubHttpException(status)` — today only
  `GitHubAuthException` / `CommitFailure` exist — plus the existing
  `FetchFailure` enum used in `studio_file_tree.dart:198-205`, `SocketException`,
  `TimeoutException`, `FileSystemException`), fall back to word-bounded patterns
  (`\b(HTTP|status)\s*40[134]\b`), and add a rate-limit case: "GitHub's hourly limit is
  reached. Try again after HH:MM." using `X-RateLimit-Reset`.
- **P1 · wrong copy (domain) · `studio_errors.dart:50-66`** — local and sandbox failures
  are attributed to GitHub: `OS Error: No such file or directory` (local-folder mode, no
  GitHub involved) → "GitHub could not find that repository, branch or file."; a sandbox
  command `timeout` → "GitHub took too long to respond."; any message containing
  "network" → "Ovid could not reach GitHub." **Impact:** local-folder users who never
  connected GitHub are told GitHub is broken, and real file-system problems are hidden.
  **Fix:** check `FileSystemException` / `ProcessException` / sandbox errors before the
  HTTP rules and give them their own copy ("That file no longer exists in the folder.",
  "The command took too long and was stopped.").
- **P2 · copy contradiction · `studio_errors.dart:79` with `studio_editor.dart:524`,
  `studio_file_tree.dart:186`, `studio_screen.dart:839`** — the fallback says "Something
  went wrong. The details are below." but these three call sites pass only `.message`
  to `showStudioToast` (no `detail`), so nothing is below. **Fix:** pass
  `detail: f.detail` at every toast site (or make `showStudioToast` accept a
  `StudioFailure`), and use "Something went wrong. Try again." when detail is empty.
- **P2 · missing mappings · `studio_errors.dart:34-80`** — no copy for the failures
  developers actually hit: `No space left on device` (ENOSPC), push rejected / non-fast-
  forward (HTTP 409/422, `[rejected]`), protected branch, file > 100 MB, `index.lock`
  exists, merge conflict, SSO-enforced org (`Resource protected by organization SAML
  enforcement`). All fall to the generic line. **Fix:** add these cases with an action
  hint each (Free space / Pull first / Create a branch / Authorize SSO).
- **P2 · privacy (defensive) · `studio_errors.dart:29-32`; `sandbox_service.dart:179`** —
  `detail` is shown verbatim in banners, toasts and the terminal and is the thing users
  screenshot for support. The sandbox writes a `https://x-access-token:<token>@github.com`
  credential line; any git/curl error that echoes a remote URL or that file would surface
  the token. **Fix:** redact `ghp_|gho_|ghu_|github_pat_[A-Za-z0-9_]+` and
  `//user:secret@` in `_firstLine` before it leaves the mapper.
- **P2 · l10n · whole file** — copy is matched and produced as English literals; an
  `Intl`-based app cannot translate it and non-English OS error text (localized
  `OS Error:` strings) will not match. **Fix:** map to an enum + ARB keys.

**Missing features**
- A "Copy error details" / "Report a problem" affordance attached to every Studio failure
  (detail + app version + repo binding, token-redacted).

**Test to add**
- Unit (extend `test/studio_errors_test.dart`): `"commit a403f1c failed"` must **not** map
  to the sign-in message; `"API rate limit exceeded"` (403) maps to the rate-limit copy;
  `FileSystemException('x', 'p', OSError('No such file or directory', 2))` must not mention
  GitHub; `detail` of `"https://x-access-token:ghp_abc@github.com"` is redacted.

---

## 9. SandboxSetupScreen + `openStudio()` — `sandbox_setup.dart`

**What it is / how reached:** `openStudio(context)` is the single Studio entry point
(composer folder chip, sidebar, sandbox banner). First open — or any time
`StudioSetupCoordinator.needsAttention` (running / partial / failed / unsupported) —
pushes `SandboxSetupScreen`; otherwise it probes `SandboxService.checkExisting()` and
pushes `StudioScreen`. The setup screen has four views: **approval** ("Set up Studio" /
Install sandbox / Not now), **progress** (overall bar + %, elapsed, 7 or 9 step cards each
with a "Repair" button, a 220 dp live log), **error** (raw error box, step cards, log,
Retry / Continue without sandbox / Close) and **done** (Sandbox ready or "core ready"
partial, badges, Open Studio / Retry runtime setup / Back to chat). `gateMode: true` is
pushed by Health → hard reset (`health_screen.dart:78-83`): core-only install, no Back,
auto-hand-off to `OvidShell`.

**Findings**

- **P1 · dead end · `sandbox_setup.dart:220-221`, `:601-614`** — in `gateMode` the route
  has `PopScope(canPop: false)` and the error view offers only "Retry install" (the
  "Close" button and the "Continue without sandbox" escape exist only for
  `!gateMode` / `_unsupported`). If the core reinstall fails for any reason other than
  "unsupported" (storage full, corrupt bundled asset, `_SetupPersistenceException`), the
  user — who already **deleted** the sandbox from Health — is trapped on this screen with
  no route to chat; the only exit is force-stopping the app. **Impact:** chat (which does
  not need the sandbox) becomes unreachable from this route. **Fix:** in the error view
  always offer "Continue to chat without sandbox" (same hand-off as `:582-590`) and a
  "Copy log" action; keep Retry primary.
- **P1 · raw errors · `sandbox_setup.dart:555-563`, `:665`;
  `studio_setup_coordinator.dart:227`** — the coordinator stores `_error = '$e'`, and the
  screen renders it verbatim in a monospace box as the main content of the error view,
  and prefixes it to the partial-success sentence (`'${_error!} Runtime verification is
  incomplete.'`). Users see e.g. "FileSystemException: Cannot create file, path = '/data/
  user/0/…/usr/bin/node' (OS Error: No space left on device, errno = 28) Runtime
  verification is incomplete." **Fix:** map to a human headline + action ("Not enough
  storage — free ~600 MB and retry", "Download interrupted — retry on Wi-Fi", "This
  device is not supported"), keep the raw line collapsed under "Details"; for `partial`
  always use the coordinator's friendly sentence, never the raw `$e`.
- **P2 · UX (misleading controls) · `sandbox_setup.dart:262-311`** — every step card (7–9
  of them) carries its own "Repair" button, but all of them call the same full
  `_runInstall()`; on a successful/queued step "Repair" is meaningless, and the list
  reads like nine separate fix actions. **Fix:** remove per-step Repair; show one
  "Repair setup" button in the error/partial views only; mark the failed step with the
  reason instead.
- **P2 · UX (back affordance that does nothing) · `sandbox_setup.dart:224-231`** — in
  gate mode `leading: null` lets `AppBar` imply a Back arrow (the route can pop), which
  `PopScope(canPop: false)` then silently swallows. **Fix:** `automaticallyImplyLeading:
  !widget.gateMode`; add `onPopInvokedWithResult` that shows "Setup must finish before
  continuing" if back is pressed.
- **P2 · re-entrancy · `sandbox_setup.dart:30-47`** — `openStudio` awaits
  `checkExisting()` with no busy state, no `catchError`, and no guard: double-tapping the
  entry point pushes two `StudioScreen`s, and a thrown probe makes the tap silently do
  nothing. **Fix:** a static `_opening` flag (or `Completer`) around the probe, a toast on
  failure ("Could not check the sandbox. Try again."), and show a small inline spinner on
  the entry chip while probing.
- **P2 · data / consent · `sandbox_setup.dart:319-367`** — the approval card says "uses
  network data and device storage and may take several minutes" but gives no size, does
  not check free space up front, and does not warn on metered/cellular connections.
  **Impact:** a multi-hundred-MB Node + Python download over mobile data without a
  number; failures from a full disk only surface mid-install as raw errors. **Fix:** show
  "≈ N MB download · ≈ M MB on device" from the installer manifest, pre-check
  `StatFs` free space, and if on a metered network show "Wait for Wi-Fi / Use mobile data".
- **P2 · readability / a11y · `sandbox_setup.dart:482-489`, `:498-513`, `:423-426`** — the log
  uses `fontSize: 11` / `10.5` / `11.5` (below the 12sp floor Studio itself enforces in
  `kStudioMinFontSize`), `fontFamily: Aether.mono` **without** the `monospace` fallback
  (so it renders proportional — the exact bug `studio_layout.dart:31-40` documents),
  plain `Text` (not selectable / copyable), and `_lineColor` paints any line containing
  "error" red (e.g. "0 errors"). **Fix:** reuse the Studio terminal row style
  (`kStudioMinFontSize`, `kStudioMonoFallback`), wrap in `SelectionArea`, add "Copy log",
  colour only `⚠`/`ERROR:` prefixes.
- **P2 · perf · `sandbox_setup.dart:128-130`, `:146-154`** — a 1 s `Timer.periodic` rebuilds
  the whole screen (all step cards, the log list) just to update the elapsed label, and
  every coordinator log line triggers another full rebuild + post-frame jump. **Fix:**
  isolate the elapsed label in its own `StreamBuilder`/`ValueListenableBuilder`, and
  rebuild only the log list on log changes.
- **P2 · copy / jargon · `sandbox_setup.dart:86-106`, `:688-703`** — step names
  ("Setting exec bits", "Linking tool aliases", "Configuring prefix", "Verifying native
  exec") and badges ("NATIVE BIONIC", "NO ROOT") are engineering vocabulary; the
  percentage shows one decimal ("43.7%") that jitters. **Fix:** user-level steps
  ("Preparing", "Unpacking tools", "Checking it works", "Installing Node.js", "Installing
  Python"), drop the badges or explain them, whole-number percent.
- **P2 · state truth · `sandbox_setup.dart:171-178`, `:402`** — phases are equal-weighted,
  so the bar sits near 78 % (7 of 9 done) while the two runtime downloads — the bulk of
  the time and data — have not started; "Step 8 of 9" then sits for minutes. **Fix:**
  weight phases by expected duration/bytes (or show runtime download bytes as
  "Node.js 34 / 52 MB").

**Missing features**
- Notification (foreground service) while installing, so the user can leave the app and
  Android does not kill the install; "Studio is ready" notification/toast when it
  finishes while the user is in chat.
- Pause / cancel install; resume an interrupted download instead of restarting.
- "Copy / share setup log" for support; "Free up space" link to storage settings.
- Optional runtime choice (Node only / Python only) to cut download size.

**Test to add**
- Widget test: `SandboxSetupScreen(gateMode: true)` with the coordinator in `failed`
  (non-unsupported) → a "Continue to chat" button exists and pushes `OvidShell`.
- Widget test: coordinator error `'FileSystemException: … errno = 28'` → no text containing
  `FileSystemException` is visible; storage copy is.
- Widget test: double-tap the Studio entry with a delayed `checkExisting` → exactly one
  `StudioScreen` route is pushed.

---

## 10. GithubLoginSheet (OAuth device flow) — `github_login_sheet.dart`

**What it is / how reached:** `showGithubLoginSheet` — a non-dismissible (`isDismissible:
false`) scroll-controlled `AetherSheet` "Connect GitHub". Opened automatically by
`StudioScreen` when the user is signed out (`studio_screen.dart:215`, `:252`), from the
account chip's "Sign in" action (`:799`) and from the plugins screen
(`plugins_screen.dart:2806`). Flow: starting spinner → one-time code (disabled
`AetherField`), verification URL with Copy URL, Copy code chip, "Sign in" (opens the
external browser), "Waiting for sign-in · mm:ss remaining" → done ("GitHub connected",
Continue) / expired (Retry) / error (Retry). Pinned Cancel. Requests scope
`repo read:user` (`github_service.dart:504`).

**Findings**

- **P1 · a11y (announcement flood) · `github_login_sheet.dart:80-82`, `:240-247`** — the
  status `Semantics` is a `liveRegion` whose label contains the countdown
  (`"… waiting, 14:59 remaining"`) and the whole sheet `setState`s every second. Each
  label change of a live region is announced, so TalkBack speaks a new sentence **every
  second for up to 15 minutes**, talking over the code the user is trying to hear and
  over the browser after they switch apps (announcements continue while the sheet is
  mounted). **Fix:** keep `liveRegion` on a label that changes only on state transitions
  ("Waiting for you to approve in the browser"); render the countdown in a separate
  `ExcludeSemantics` text (optionally announce at 5 / 1 minute remaining); drive the
  countdown with a small `StreamBuilder` instead of rebuilding the whole sheet.
- **P1 · fragile flow (mobile network) · `github_service.dart:589-603` via
  `github_login_sheet.dart:93-124`** — any single transport error while polling
  (`SocketException`, the 20 s `TimeoutException`, a 5xx) throws out of `pollForToken`
  and the sheet switches to the error state, abandoning a still-valid device code. On
  Android this is the normal case: the user switches to the browser, the app is
  backgrounded, network access is restricted / Wi-Fi hands over to LTE, and the next poll
  fails. **Impact:** user approves in the browser, returns to Ovid, and sees "Something
  went wrong" with a raw exception and must start over with a new code (and the browser
  approval was wasted). **Fix:** treat transport errors and 5xx as `authorization_pending`
  with backoff until the code's `expiresIn`; pause polling on `AppLifecycleState.paused`
  and poll immediately on `resumed`; only surface an error for OAuth errors.
- **P1 · raw errors · `github_login_sheet.dart:84-88`, `:116-121`, `:316-322`** — non-auth
  failures are shown as `'$e'` under "Something went wrong" (e.g. "ClientException with
  SocketException: Failed host lookup: 'github.com' (OS Error: No address associated with
  hostname, errno = 7), uri=https://github.com/login/device/code"). **Fix:** route through
  `StudioFailure.of(e)` (after the §8 fixes) — "Ovid could not reach GitHub. Check your
  connection and try again." — with the raw line collapsed under Details.
- **P2 · functional (lost success callback) · `github_login_sheet.dart:18-27`, `:154-159`,
  `:168-169`** — `onConnected` fires only for `pop(true)` from "Continue". The pinned
  "Cancel" stays visible in the done state, and Android back / drag-down also pop with
  `null`, so a user who is already connected but dismisses the success view (very common)
  never triggers `onConnected` — the plugins-screen caller (`plugins_screen.dart:2806-2809`)
  then never enables the GitHub MCP server it was connecting. Cancel in the done state also reads as "undo".
  **Fix:** compute the result from `GitHubService.I.isLoggedIn` in the `.then` (not the
  pop value); hide Cancel (or relabel "Close") once `_state == done`; auto-close after
  ~1 s on success.
- **P2 · UX (extra steps / clarity) · `github_login_sheet.dart:205-225`** — the code — the
  one thing the user must carry to the browser — is rendered in a **disabled** text field
  (reduced-contrast disabled styling, proportional font, normal size), and "Sign in" does
  not copy it, so the user must tap Copy code, then Sign in, then paste. GitHub CLI and
  every TV-login flow show the code large and copy it automatically. **Fix:** render the
  code as large monospace selectable text (`AetherType.mono`, ~28sp, letter-spaced) with
  `Semantics(label: spelled-out characters)`; make "Sign in" copy the code and show
  "Code copied — paste it on GitHub"; open
  `verification_uri_complete` when GitHub returns it.
- **P2 · UX (unwanted auto-prompt) · `studio_screen.dart:243-252`** — every Studio open by
  a signed-out user immediately starts a device flow and pushes this non-dismissible sheet,
  including users who only use a local folder and never want GitHub; each open mints a new
  device code (GitHub rate-limits device-code creation). **Fix:** show a "Connect GitHub"
  card in the repo bar instead of auto-opening, or auto-open only when the session has a
  bound repo; remember "Not now".
- **P2 · security transparency · `github_service.dart:504`; `sandbox_service.dart:170-185`** —
  scope `repo` grants read/write to **all** of the user's public and private repos, and the
  token is written to `$PREFIX/.ovid-git-credentials`, readable by any command in the
  sandbox — including commands the AI agent runs (prompt-injection exfiltration path).
  The sheet says nothing about what is granted. **Fix:** state the access in the sheet
  ("Ovid will be able to read and push to your repositories"), link to GitHub's
  "Authorized OAuth Apps" page to revoke, and longer term move to a GitHub App with
  per-repo installation + short-lived tokens, served to git through a credential helper
  that refuses agent-initiated reads.
- **P2 · a11y · `github_login_sheet.dart:387-437`, `:360-362`** — `_CopyChip` puts
  `Semantics(button: true)` on the inner `Text`, not on the `InkWell`, so the focusable
  node and the labelled node differ (TalkBack can land on an unlabeled tappable); the
  "Copied" state is not announced; the URL is labelled "Verification URL. Selectable
  text." which reads the implementation, not the content. **Fix:** `Semantics(button:
  true, label:…, child: InkWell)` with `SemanticsService.announce('Code copied')`; label
  the URL row "GitHub sign-in address, github.com/login/device".

**Missing features**
- Personal access token / fine-grained token entry as an alternative (enterprise users,
  devices without a browser profile), and GitHub Enterprise Server host.
- Account switcher / sign-out from inside the sheet; show the signed-in avatar before
  Continue.
- "I approved it" manual check button (poll now) for when the user returns before the
  next interval.

**Test to add**
- Widget test with a mock client: the first poll throws `SocketException`, the second
  returns a token → state reaches `done` (fails today).
- Semantics test: pump 5 s in the code state → the live-region label is unchanged.
- Widget test: reach `done`, then tap Cancel / system back → `onConnected` is still
  invoked.

---

## Group summary

**Counts (sections 1–10):** see tally line at the end. Studio's biggest risks are, in
order: silent loss of user code (editor drafts, API-mode edits, layout remounts), a
terminal that wedges on the commonest commands, UI-isolate file IO / whole-file layout
on large or binary files, and error copy that is either raw or points at the wrong cause.

**Top 10 fixes, in the order to do them**

| # | Fix | Sections | Sev | Effort |
|---|---|---|---|---|
| 1 | **Never lose a draft:** move dirty/baseline state into core `_SessionStudio`; `PopScope` with Save all / Discard / Cancel; dirty check on tab close; 2 s debounced draft autosave + save on `paused`; keep the editor mounted when the compact file panel opens (stable `Stack` child). | §4 P0, §7 P1 | P0 | M |
| 2 | **Persist API-mode working copies** (app-private drafts dir) and stop `unbind()`/sign-out from discarding uncommitted edits without a confirm. | §1 P1 ×2 | P1 | M |
| 3 | **Terminal unwedge:** make Stop tappable (`readOnly` instead of `enabled:false`), add stdin-while-busy + Ctrl-C, non-interactive env (`GIT_EDITOR`, `PAGER`, `DEBIAN_FRONTEND`, `CI`), idle notice instead of the 5-min kill. | §6 P1 ×2 | P1 | S (Stop) + M |
| 4 | **Get file IO off the UI isolate:** async `RepoCache.readAsync` with size cap; move `validateApproval` / `_commitContent` staging reads off `_cacheChanged`; debounce. | §2 P1, §5 P1 | P1 | M |
| 5 | **Large / binary files:** read-only virtualised viewer above ~256 KB, binary detection by NUL-byte sniff (not extension list) so binaries are never decoded/re-encoded; prune per-tab controllers and replace `IndexedStack`. | §4 P1 ×3 | P1 | M |
| 6 | **Commit review that is reviewable:** real line diff (Myers, `package:diff_match_patch`) with hunks, lazy `ListView` rendering, per-file collapse; human error copy in the dialog. | §2 P1 ×3 | P1 | M |
| 7 | **Error copy overhaul:** typed classification in `StudioFailure` (no digit substrings, rate-limit case, FS vs GitHub domains, token redaction); route setup-screen and GitHub-sheet errors through it; pass `detail` to every toast. | §8 P1 ×2, §9 P1, §10 P1, §2 P1 | P1 | M |
| 8 | **GitHub sign-in that survives Android:** poll through transient network errors, pause/resume with lifecycle, stop the per-second live-region announcement, auto-copy the code, honour success on any dismissal; repo picker pagination + search so >30-repo users can pick a repo. | §10 P1 ×2, §3 P1 | P1 | S–M |
| 9 | **Surface partial sync** (`SyncReport.partial/summary`) in the banner + file-tree footer with Retry. | §1 P1, §5 P2 | P1 | S |
| 10 | **Setup gate escape + honest setup UX:** "Continue to chat" in the gate-mode error view, no phantom Back arrow, single Repair, size/metered-network notice, selectable log with mono fallback; rebuild-scope fixes for the editor/tree (`AgentService` listeners) and terminal (coalesce per frame). | §9 P1, §4 P1, §6 P2 | P1 | S + M |

**Suggested PR grouping**
1. `studio-drafts-safety` (#1, #2) — highest user-trust impact; needs core + UI.
2. `studio-terminal-input` (#3) — Stop fix is a one-liner and can ship first on its own.
3. `studio-io-and-large-files` (#4, #5).
4. `studio-commit-diff` (#6).
5. `studio-errors-and-github-auth` (#7, #8, #9).
6. `studio-setup-polish` (#10) + the P2 a11y batch (48dp targets, double announcements,
   resize semantics actions, sheet drag handles).

**Cross-group notes**
- The 44 vs 48 dp tap-target constant (§7) and the hard-coded font sizes should be
  decided once in the design-system group (08) and applied here.
- Token exposure to agent-run sandbox commands (§10) belongs in the security PR of the
  master plan, not in a Studio UI PR.

**Tally (all 10 sections):** P0 = 1 · P1 = 23 · P2 = 58. Sections 6–10 (this pass) add P1 = 10, P2 = 30.
