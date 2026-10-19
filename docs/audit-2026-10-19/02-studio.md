# 02 — Studio audit (feat/ovid-cloud @ fdf2c5f, release APK in /root/ovid-audit/apk)

Scope: lib/ui/studio_*.dart, lib/core/studio_drafts.dart, lib/core/cloud/studio_files.dart,
lib/core/cloud/studio_remote_client.dart, entry points (chat_screen/shell/sidebar/app_router),
gateway `cloud/apps/gateway/src/routes/workspace.ts`, worker `cloud/apps/worker/src/fileService.ts`,
wire types `cloud/packages/shared/src/workspace.ts`.

Severity: P0 = crash/blocks screen/data loss/security, P1 = feature broken or misleading, P2 = polish.
"Suspected" = inferred from code, not reproduced.

---

## Root cause: "Studio does not open at all"

**Answer: Studio is not broken at runtime. Nothing navigates to it.** Every entry point was swapped
for a SnackBar in commit `83520411` ("remove sandbox/Termux…", P8 Task 13). Studio was then rebuilt on
the cloud API in `5e701324`, but nobody wired the entry points back. `StudioScreen` is never built
anywhere in `lib/`. `grep -rn "StudioScreen(" lib` only finds the class itself.
The AOT compiler then tree-shook the whole Studio UI out of the release binary.

### ST-001 — P0 — Every Studio entry point shows a SnackBar instead of opening Studio
- **Files:**
  - `lib/ui/chat_screen.dart:1590-1600`: chat header `chat-header-studio` button. `onPressed` shows SnackBar `'Studio moves to the cloud in this build.'`.
  - `lib/ui/chat_screen.dart:9178-9187` + `9223-9230`: the "Open Studio" row in the working-folder sheet returns `'studio'` and shows the same SnackBar.
  - `lib/ui/app_router.dart`: there is no Studio `AppRoute`, so no deep link reaches it either.
  - `lib/ui/sidebar.dart`: no Studio row. The comment at :537 says "the header keeps … studio", and the header button is the dead one above.
- **Evidence:**
  - `git show 83520411 -- lib` has `-  onPressed: () => openStudio(context),` replaced by the SnackBar in chat_screen.dart. In the same commit `openStudio`/`StudioScreen` pushes were deleted from sandbox_setup.dart (diff lines with `-).push(MaterialPageRoute(builder: (_) => const StudioScreen()))`).
  - **Release APK proof:** `unzip -p app-release.apk lib/arm64-v8a/libapp.so | strings`:
    - Found: `Studio moves to the cloud in this build.` and `Sandbox folder (Studio)`.
    - Not found (0 matches): every StudioScreen-only string: `Open a chat to use Studio.`, `Could not load the workspace tree`, `Toggle files`, `Loading cloud workspace`, `No open files`, `Binary file`, `Copy terminal command`.
    - So the Studio UI is not in the shipped binary at all. Dart AOT dropped it as unreachable.
  - Tests did not catch this: `test/chat_screen_distribution_gates_test.dart:189` and `test/claude_style_chat_test.dart:117` only assert the button *exists*. The Studio widget tests (`studio_responsive_test`, `studio_a11y_test`, `studio_drafts_safety_test`) build `StudioScreen` directly.
- **Ruled out** (I checked these as alternative causes):
  - No initState/build exception path. `build` returns `_NoSessionStudio` for an empty sid (studio_screen.dart:213).
  - `StudioMetrics` clamps guard against inverted bounds (studio_layout.dart:184-282).
  - `StudioPaneViewport` gives its child a bounded `SizedBox` height (studio_layout.dart:84-103).
  - No `OVID_PLAY_BUILD`/`OVID_ACCOUNT_ENABLED` gate on the button.
  - None of these matter while the screen is unreachable anyway.
- **Fix:**
  1. Header button: `onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const StudioScreen()))`.
  2. Same push for the sheet's `'studio'` choice.
  3. Delete the dead const `kStudioMovesToCloudMessage` (`lib/ui/artifact_preview.dart:19-20`, zero references).
  4. Optional: add a `StudioRoute` to `AppRouter._pageFor`.
  5. Add a widget test that taps `chat-header-studio` and expects `find.byType(StudioScreen)`.
  6. Before shipping, also fix ST-002, ST-003 and ST-004, or the first open will show an error banner plus a GitHub sign-in sheet.
- **Verify on emulator:**
  - Today: tap the `</>` icon in the chat header. A SnackBar "Studio moves to the cloud in this build." appears. Logcat shows no exception (`adb logcat -s flutter` is silent). That rules out a crash.
  - After the fix: the Studio app bar "Studio" plus a "Cloud workspace…" bar appears.
  - Rebuild and re-run the `strings` check. `Could not load the workspace tree` should now be present in libapp.so.

---

## Blockers you hit right after re-wiring

### ST-002 — P1 — Chats never sent to the server get a 404 tree (local id sent as the server id)
- **Files:**
  - `lib/core/cloud/studio_files.dart:207-217`: `_serverSessionId` → `CloudSessionStore.resolveServerSessionIdAsync`.
  - `lib/core/cloud/cloud_session_store.dart:291-297`: `serverIdFor(id) ?? id` passes unknown ids through unchanged.
  - `lib/core/state.dart:4085/4177/4221`: local ids are `microsecondsSinceEpoch`, not UUIDs.
  - `cloud/apps/gateway/src/routes/workspace.ts:150,210,283`: `if (!isUuid(sessionId)) return notFound(reply)`.
- **Problem:** Open Studio on a new chat (or any chat whose first send has not synced). `GET /sessions/<1739…>/workspace/tree` gets a 404, and Studio shows the error banner, an error toast and the tree empty-state error.
- **Fix:**
  - In Studio, use `CloudSessionStore.knownServerIdFor(id)`.
  - When it is null, render an explicit empty state: "Send a message in this chat to create its cloud workspace". Do not issue the request.
  - Optionally offer `ensureServerSession`.
- **Verify:** New chat, open Studio before sending anything. Logcat/toast shows `CloudApiException: 404 not_found`.

### ST-003 — P1 — A session the agent never ran in has no workspace dir, so the tree errors instead of showing empty
- **Files:**
  - `cloud/apps/worker/src/fileService.ts:183-184`: `if (!(await isDirectory(dir))) return fail(reply, 404, "not_found", "workspace … is not warm")`.
  - The gateway relays that 404 (`workspace.ts:190-192`, `relayWorkerError`).
  - The client maps it to `treeError` (`studio_remote_client.dart:237-239`).
- **Problem:** A synced chat where no tool ever ran (a pure Q&A chat) shows "Could not load the workspace tree" with a Retry that can never succeed. The empty state "No files yet — the cloud workspace appears here." (studio_file_tree.dart:427-429) is unreachable in practice.
- **Fix:**
  - Server: answer 200 with an empty `UiManifest` (`roots: []`, totals 0) when the dir is missing and there is no manifest row.
  - Alternatively, client: treat tree `not_found` as an empty workspace.
- **Verify:** Sync a chat with one plain text message, then open Studio. You get the error banner, not the empty state.

### ST-004 — P1 — Studio auto-opens a GitHub device-flow sheet that does nothing in the cloud architecture
- **Files:**
  - `lib/ui/studio_screen.dart:89-98, 163-185`: post-frame `_handleInitialAuth()` calls `showGithubLoginSheet` when not signed in.
  - `lib/core/github_service.dart:33-41, 52-70`: the token is memory-only ("a process restart signs the user out"), and nothing sends it to the cloud. `grep -rni github cloud/apps/gateway/src/routes/*.ts` finds only plugins/MCP tests, and no client code reads `GitHubService.I.token` outside the service.
- **Problem:** After every app restart, the first Studio open pops a GitHub sign-in sheet. Signing in grants nothing: the workspace, git and agent are server-side. The app-bar account chip and auth badge (studio_screen.dart:309-310, 595-793) then show a GitHub state that does not matter.
  - The sign-out dialog is also misleading: "The repo connection will be cleared. Your GitHub access token is removed from this device only." (:763).
- **Fix:** Remove the auth gate, `_AccountChip` and `_AuthBadge` from Studio, plus `postInstallGithubPrompt`/`studioLoginPromptOverrideForTest`. Move GitHub to Settings → Connections once a server-side GitHub token route exists.
- **Verify:** Force-stop the app, reopen it, open Studio. The "Sign in to GitHub" bottom sheet appears immediately.

---

## Feature audit vs. server

Client → server route map (all under `/cloud/v1`, authed scope, `app.ts:323`):

| Client call | Server route | Shape match |
|---|---|---|
| `GET /sessions/:id/workspace/tree` (studio_files.dart:217) | workspace.ts:146 | OK. Client reads `tree.roots/totals/truncated`, `state`, `source`, `generation`; node `type`/`sizeBytes`/`mtime`/`omitted`/rollups match `fileTreeNodeSchema`. |
| `GET /sessions/:id/workspace/file?path=` (studio_files.dart:268) | workspace.ts:206 | OK. Inline utf8/base64 and redirect `downloadUrl` both handled. |
| `PUT /sessions/:id/workspace/file` `{path, contentUtf8}` (studio_files.dart:383-386) | workspace.ts:276 (strict schema) | OK. 202 `{status:'hydrating'}` handled (:387-389). |
| — (no client) | `POST …/workspace/hydrate`, `POST …/workspace/hibernate` | Unused by Studio |
| rename / delete / mkdir / move | **none on either side** | Missing |
| run / preview | **none in Studio** | Missing (agent-only by owner directive) |
| WS file-change events | none subscribed by Studio | Missing (see ST-006) |

### ST-005 — P1 (data loss) — "New file" with an existing path wipes the draft and overwrites the server file with no conflict check
- **Files:**
  - `lib/ui/studio_editor.dart:54-91`: the `_askNewFile` dialog does no validation.
  - `lib/core/cloud/studio_remote_client.dart:296-305` `newStudioFile`: sets `fileBuffer[path] = ''`, removes `savedContent` and `baselines`.
  - `studio_files.dart:366`: the conflict pre-check only runs when `baselineHash != null`.
- **Problem:**
  - (a) A path that is already open with unsaved edits is silently replaced by an empty buffer.
  - (b) A path that exists on the server opens as empty. Save then PUTs over the real file, because no baseline means no pre-read and no conflict.
- **Fix:** In `newStudioFile`, refuse if `fileBuffer.containsKey(path)`, and check the snapshot tree or `GET file` for existence. If the file exists, open it instead (or ask "Replace?"). Normalise and validate the path: no leading `/`, no `..`, no trailing `/`, not empty.
- **Verify:** Open `README.md`, type something, then tap + and enter `README.md`. The draft is gone. Or: + with an existing path, type "x", Save. The server file is now "x".

### ST-006 — P1 — Open/closed files never refresh from the server; agent edits never show up
- **Files:**
  - `studio_remote_client.dart:251-256`: `openStudioFile` returns early if `fileBuffer.containsKey(path)`.
  - `:426-434`: `closeStudioFile` only removes the path from `openFiles` and keeps the buffer.
  - `:228-244`: `syncStudioTabs` reloads the tree only.
  - No listener anywhere connects agent `tool_completed`/file events to `StudioRemoteClient` (grep finds no reference outside studio files and the reset paths).
- **Problem:**
  - Once a file has been opened in this process, Studio shows that snapshot forever, even after close/reopen and Refresh.
  - The empty-editor copy promises "Ask the AI in chat to read/edit files — they open here as tabs" (studio_editor.dart:1192). That never happens.
  - The editor comments about adopting "agent file_write" (studio_editor.dart:519-526) describe a path that is never triggered.
  - Editing a stale buffer then produces a confusing "changed externally" conflict on save.
- **Fix:**
  - On tree refresh, compare each clean open buffer's mtime/size with the manifest, or re-GET it, and refresh it.
  - On close of a clean tab, drop the buffer.
  - Subscribe to the session's projected `tool_completed` (write/edit tools) events and re-fetch affected clean paths.
- **Verify:** Open a file in Studio, go back, ask the agent to edit that file, return, tap Refresh. The old content is still shown.

### ST-007 — P1 (data loss, narrow window) — Save is not atomic; it can silently overwrite a concurrent agent write
- **File:** `lib/core/cloud/studio_files.dart:26-39, 359-386`. The code documents this as a "KNOWN RACE": client-side GET→compare→PUT. The server PUT schema is `.strict()` with no precondition (`packages/shared/src/workspace.ts:172-183`, gateway `workspace.ts:288`).
- **Fix:** Add `ifMatchSha256` to `putWorkspaceFileBodySchema`. Have the worker compare it inside the temp+rename write and return 409 `baseline_mismatch`. The gateway must relay that 409 instead of collapsing it to 503 (`relayWorkerError`, workspace.ts:131-141, and the PUT 409 retry path at :352-372 currently treats any 409 as `not_warm`).
- **Verify:** Hard to hit by hand. Write a gateway test that PUTs between the pre-read and the write.

### ST-008 — P1 — No rename, delete, new folder, or run/preview, and no UI that says so
- **Files:** The tree rows have only a tap action (studio_file_tree.dart:142-170, 311-364): no long-press, context menu or swipe. The client has no API for these (studio_files.dart), and the gateway has no route (workspace.ts lists tree/file GET, file PUT, hydrate, hibernate).
- **Problem:** Basic file management is impossible from Studio. Create works only as "new unsaved buffer + save", and the new file does not appear in the tree until a manual refresh (no `_refreshTree` after save; studio_editor.dart:669-688).
- **Fix:**
  - Server: add `DELETE …/workspace/file?path=` and `POST …/workspace/move {from,to}`, plus a worker implementation.
  - Client: a long-press menu on tree rows (Rename / Delete with confirm / New file here).
  - Refresh the tree after save/create.
  - If run/preview stays agent-only, add a "Run with agent" action that pre-fills the chat. For `.html`, offer a preview through the existing `html_artifact_view.dart`.

### ST-009 — P1 — Tree error copy is wrong or empty; raw exception text reaches users
- **Files:**
  - `studio_remote_client.dart:238`: `state.treeError = error.toString()`, which loses the typed `CloudApiException`.
  - `studio_screen.dart:529`: `StudioFailure.of(StateError(detail!)).message` runs the string heuristic, so almost every cloud error becomes "Something went wrong. The details are below." The banner then shows **no** details below.
  - `studio_screen.dart:195-200`: the toast shows the raw `CloudApiException: 404 not_found: …` as detail, without `StudioFailure.redact`.
  - `studio_errors.dart:90-91,103-104`: tree 404 copy would read "That file no longer exists in the workspace." (wrong subject).
- **Fix:**
  - Store the error object (`Object? treeErrorObject`) and map it with `StudioFailure.of(err)`.
  - Add a tree-specific mapping: not_found → "This chat has no cloud workspace yet."; unauthenticated → "Sign in to use Studio."; status 0 → offline.
  - Never show `toString()` as user text.

### ST-010 — P1 — One failure produces three or four simultaneous error surfaces on open
- **Files:** studio_screen.dart:194-201 (toast), :265-269 (`_TreeErrorBanner`), studio_file_tree.dart:192-199 (`_TreeEmpty` error + Retry), plus the GitHub sheet (ST-004) fired in the same post-frame.
- **Fix:** Show one surface: the inline tree/banner state. Drop the toast for tree loads and keep toasts for user-initiated actions.

### ST-011 — P1 — Copy still describes the deleted on-device terminal, sandbox and repo model
- **Files:**
  - `lib/l10n/app_en.arb:512-513`: tooltip "Studio — code & terminal".
  - `lib/ui/studio_editor.dart:1191-1193`: "• Terminal below runs inside the native Linux sandbox".
  - `lib/ui/studio_editor.dart:1405-1421`: `_TooLargeView` "Too large to open on device … Open it in the terminal instead: less '…'" plus a "Copy terminal command" button. There is no terminal.
  - `lib/ui/chat_screen.dart:9162,9184`: "Sandbox folder (Studio)", "Connect a repo, browse and edit files".
  - `studio_screen.dart:763`: "repo connection will be cleared".
- **Fix:**
  - Tooltip → "Studio — cloud files".
  - Empty state → "Pick a file, or ask the agent in chat to create one".
  - Too-large view → "Too large to edit in Studio (max 1 MB). Ask the agent to work with it." Remove the copy-command button.
  - Rewrite the sheet copy.

### ST-012 — P1 — The working-folder chip and "Select working folder" pick a local device folder the cloud never sees
- **Files:**
  - `lib/ui/chat_screen.dart:9044-9135` (`_StudioFolderChip`), `9141-9300` (`_manageWorkspaceFolder` → `FilePicker.getDirectoryPath`, write probe, `setSessionWorkspaceFolder`).
  - `grep -rn workspaceFolder lib/core/cloud` finds nothing: the value is never sent to the gateway.
- **Problem:** In Studio mode the composer offers a feature that has no effect on cloud execution. It also prompts Android folder access for nothing.
- **Fix:** Remove the chip and sheet, or replace them with a single "Open Studio" chip.

### ST-013 — P2 — Cold/hydrating workspace: no progress, no auto-refresh, no hydrate action; a 202 save is just a toast
- **Files:**
  - `studio_file_tree.dart:484-495`: footer state icon.
  - `studio_files.dart:387-389` → `StudioFileHydratingException` → toast "still warming up" (studio_errors.dart:86-87). There is no retry.
  - `POST /workspace/hydrate` (workspace.ts:395) is never called.
- **Fix:**
  - When `state` is `cold`/`hydrating`, show a "Waking workspace…" banner and call `/hydrate`.
  - Poll the tree (or listen for the `workspace_hydrated` event, already projected in trajectory_screen.dart:186-187) until warm.
  - Auto-retry a pending save once warm.

### ST-014 — P2 (suspected false conflict) — Save has no in-flight state; a double tap sends two PUTs
- **Files:** `studio_editor.dart:669-688, 961-963`. The Save button stays enabled while `_dirty` is true, and `_dirty` stays true until the PUT returns. There is also no Ctrl/Cmd+S binding (the shortcuts at :731-743 cover Find/Escape only).
- **Problem:** A second tap pre-reads the file after the first PUT has landed. The hash no longer matches the old baseline, so the client raises a 409 `baseline_mismatch`, and a CONFLICT bar may flash on a successful save (order dependent).
- **Fix:** Add a per-path `saving` flag in `StudioRemoteClient`. Disable Save and show a spinner while it is set. Add `SingleActivator(LogicalKeyboardKey.keyS, control: true)`.

### ST-015 — P2 — Pruned manifest directories expand to nothing, with no hint
- **Files:** `studio_files.dart:67-73` parses `omitted`/`files`/`dirs` rollups. `studio_file_tree.dart:61-79` (`flattenStudioTree`) ignores them. The `UiManifest` is capped at 5 KB (`UI_MANIFEST_MAX_BYTES`).
- **Problem:** In medium-sized repos many folders open empty. The only hint is "· pruned" in the footer.
- **Fix:** Render a "+N more (tap to load)" row. Back it with a `?path=` subtree query on the tree route (server change), or fetch the live tree when warm.

### ST-016 — P2 (suspected) — Editor, tabs and tree do not handle a session switch while Studio is open
- **Files:**
  - `studio_editor.dart:388-395`: `initState` listens to `tabsFor(_sid)`, and there is no `didUpdateWidget`.
  - `studio_file_tree.dart:127-139`: the same pattern.
  - `StudioScreen._onWorkspaceChanged` (studio_screen.dart:153-161) does pass the new sid down.
- **Problem:** After a switch (notification tap or deep link while Studio is on top), the editor keeps its listener on the old bucket. Files opened from the tree may not render. `dispose` also removes a listener from the wrong notifier.
- **Fix:** Implement `didUpdateWidget` to move the listeners, or key the panes with `ValueKey(_sid)`.

### ST-017 — P2 — Draft store: orphan records and a restore race
- **Files:**
  - `studio_remote_client.dart:150-157, 558-590`: restore runs async on the first `_stateFor`. It writes `fileBuffer[path] = draft` unconditionally, so it can clobber text typed or fetched before it finishes (suspected).
  - Drafts are deleted only on a full reset (`state.dart:3323-3324`, `settings_state_integration.dart:234-238`), never when a chat is deleted.
- **Fix:**
  - Await the restore before the first open, or skip paths already present.
  - Delete `StudioDraftStore.recordName('editor', sid)` in the chat-delete path.

### ST-018 — P2 — Dead code from the old architecture
- **Unused symbols:**
  - `lib/ui/studio_layout.dart`: all terminal geometry (`terminalHeight`, `terminalFits`, `clamp/expanded/resolveTerminalHeight`, `studioTerminalPaneKey`, `studioTerminalHandleKey`, `commandRowHeight`, …). Zero references outside the file.
  - `lib/ui/artifact_preview.dart:19` `kStudioMovesToCloudMessage` (unused).
  - `StudioScreen.postInstallGithubPrompt` (the setup flow was deleted).
  - `kStudioDecodeInIsolate` (definition only).
- **Misleading names:** `studioRepoBarKey`, `syncStudioTabs` (it only reloads the tree).
- **Stale docs:** the class docs describe "terminal collapses" (studio_screen.dart:44-45), and studio_drafts.dart:21-22 says "open in terminal".
- **Fix:** Delete or rename these.

### ST-019 — P2 — Redundant controls and a crowded compact layout
- **Redundant refresh:** four refresh affordances (app-bar sync :302-308, workspace-bar refresh :478-483, tree footer :504-509, error banner retry :539-544).
- **Unguarded refresh:** the tree's own refresh calls `syncStudioTabs` directly (studio_file_tree.dart:197,212) and bypasses the screen's `_refreshing` guard. That allows concurrent GETs, and whichever finishes last wins.
- **Compact app bar:** at under 600 dp the app bar holds back, title, files, sync, avatar and badge. The editor header wraps into two rows (studio_editor.dart:938-983).
- **Keyboard (suspected):** with the soft keyboard up, the nested `StudioPaneViewport`s (outer at studio_screen.dart:240, inner at studio_editor.dart:750) leave a scrolled region of about 120 dp for the field.
- **Fix:**
  - Keep one refresh in the app bar and route all refreshes through the screen.
  - Drop the account chip and badge (ST-004).
  - Put undo/redo/find into an overflow on compact widths.
  - Check the layout with the keyboard up on a 360×640 device.

### ST-020 — P2 — Accessibility nits
- **Live regions:** `_AuthBadge` is a live region (studio_screen.dart:624-626) and re-announces on every GitHub notify. The tree footer is also a live region (studio_file_tree.dart:479-481) and announces on every refresh.
- **Small text:** tree rows use 12 px mono (studio_file_tree.dart:339-343).
- **Tab semantics:** tabs lack an index ("tab 2 of 5").
- **Fix:** Make only error states live regions. Allow 13 px+ for tree rows, and add positional semantics to tabs.

### ST-021 — P2 — Test gap that let ST-001 ship
- **Problem:** No test navigates to Studio from the app. All Studio tests construct `StudioScreen` directly.
- **Fix:** Add a navigation test (header tap → `StudioScreen`). Add a release-size or `strings` smoke check in CI that asserts a Studio-only string is present in libapp.so.

---

## Emulator verification cheat-sheet
- `adb logcat -s flutter:V` while tapping the header `</>` icon. Expect no exception, just the SnackBar. That confirms ST-001 (navigation, not a crash).
- `adb shell uiautomator dump /sdcard/u.xml && adb pull /sdcard/u.xml` and look for `Studio moves to the cloud in this build.`
- After re-wiring, look in logcat/toasts for:
  - `CloudApiException: 404 not_found` (ST-002/ST-003)
  - the GitHub device-flow sheet (ST-004)
  - `hydrating` toasts on save (ST-013)

---

## What breaks once StudioScreen is wired, and the order to fix it for end-to-end cloud Studio
(Coordinator confirmed ST-001 on the emulator. The SnackBar itself is not visibly shown there either. That does not matter once navigation is restored.)

1. **Session binding (ST-002).** Studio keys its state by the LOCAL session id. `StudioFilesClient` maps it to the server UUID on each call (`studio_files.dart:207-209`). For a chat with no server row, the local id passes through and the gateway 404s on `isUuid`.
   - Gate on `CloudSessionStore.I.knownServerIdFor(localId)`.
   - When it is null, show a "send a message first" empty state, or call `ensureServerSession(localId)` behind a "Create workspace" button.
   - Keep local ids as Studio keys: the draft records already use them.
2. **Empty workspace (ST-003).** Make the worker or gateway return an empty manifest (200) when the session dir does not exist yet. Otherwise every chat without tool runs shows an error.
3. **Cloud auth.** `CloudRestClient` needs a signed-in Firebase ID token and App Check. If that fails, show "Sign in to use Studio" (`code unauthenticated`, studio_errors.dart:97-98) as an inline state, not a toast. That depends on ST-009, because the error object is currently stringified.
4. **GitHub prompt (ST-004).** Delete the auto sheet, chip and badge. They are unrelated to cloud access.
5. **Remote client init.** `StudioRemoteClient.I` is lazy and needs no init. `StudioDraftStore.I.enable()` runs in main.dart:132. No change needed. Watch the async restore race (ST-017).
6. **Server routes.** tree/file GET and file PUT already match the client shapes exactly (see the table above). To reach feature parity, add:
   - an `ifMatchSha256` precondition on PUT (ST-007)
   - DELETE file and POST move/rename (ST-008)
   - optional subtree fetch for pruned dirs (ST-015)
   - calls to the existing `/hydrate` for cold workspaces (ST-013)
7. **Freshness (ST-006).** Re-fetch clean open buffers on refresh and on agent write events. Drop buffers when a tab closes.
8. **Copy and leftovers (ST-011, ST-012, ST-018).** Fix these before release so users are not told about a terminal, sandbox or repo that do not exist.
