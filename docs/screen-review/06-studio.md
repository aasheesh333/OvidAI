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
in progress

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

