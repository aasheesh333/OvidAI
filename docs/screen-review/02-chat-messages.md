# 02 — Chat screen part 2 (messages, composer, sheets, artifacts)

## Scope
- `lib/ui/chat_screen.dart` L4500–8970 (message bubbles + actions, markdown, image messages + full-screen viewer, attach sheet, image-prompt dialog, `_InputBar` composer, @-mentions, goal editor, working-folder sheet, inline approval/question cards, control-mode consent dialogs)
- `lib/ui/html_artifact_view.dart` (artifact view)
- Calls followed into `lib/core/` where needed to confirm a bug.

## Goal
Actionable fix plan for a ~10M DAU Android app: bugs, missing states, UX/a11y/perf, security, missing must-have features vs ChatGPT/Claude mobile, and Claude Code MCP/plugin parity gaps visible here. Known context not re-reported: per-token streaming rebuild storm (branch `perf/streaming-rebuilds`).

## Status
in progress

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

