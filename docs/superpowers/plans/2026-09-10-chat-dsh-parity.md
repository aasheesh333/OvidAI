# Chat Shell, DSH Parity, and Large-History Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the home chat flow structurally match the installed DeepSeek DSH web reference (centered capped transcript, borderless prose, compact disclosures, composer tied to the transcript) while making huge conversations open/stream without hanging, and clean up composer modes (folder Studio-only, Read-Only via `/preset plan`).

**Architecture:** Introduce a pure `ChatLayout` width axis and a pure `foldMessages`/`TranscriptWindow` model used by both chat and subagent transcripts; restyle reasoning/tool to compact disclosures; isolate streaming so the transcript is not re-folded per token; coalesce per-session persistence; hide Read-Only and add a `plan` preset; key scroll anchoring.

**Tech Stack:** Flutter/Dart, existing `AppState`/`AgentService`/`PresetRegistry`, `SharedPreferences`, widget/unit tests.

**Spec:** `docs/superpowers/specs/2026-09-10-chat-dsh-parity-design.md`

## Global Constraints

- Structural parity only: never copy DSH branding, assets, icons, product copy, or CSS token names; use Ovid's `Aether` theme.
- One centered capped transcript column; composer = column + 32px; user bubble compact.
- Reasoning/tool output compact and collapsed by default.
- Opening a synthetic 5,000-message session must not perform an O(N) full-history fold on the UI isolate beyond the visible window.
- Streaming must not re-fold the full history per token.
- At most one coalesced persistence encode of changed sessions per turn.
- Folder picker is Studio-only; Read-Only is not a direct mode option; `/preset plan` selects read-only Plan.
- Preserve per-session stop/queue, session-scoped skills, startup dashboard, and all currently green tests (full `flutter test` 799/799 at baseline `2e37324`).
- Flutter binary is `/home/ubuntu/sdk/flutter/bin/flutter`.
- No new app-wide listener on `ChatScreen`; keep the startup panel and composer listeners isolated.

---

### Task 1: Pure chat layout axis and fold/window model

**Files:**
- Create: `lib/ui/chat_layout.dart`
- Create: `lib/ui/transcript_model.dart`
- Create: `test/chat_layout_test.dart`
- Create: `test/transcript_model_test.dart`

**Interfaces:**
- Produces `ChatLayout` with `contentWidth`, `composerWidth`, `userBubbleMaxWidth` per spec §5.1.
- Produces `ChatItem` (`_SingleItem`/`_FoldedGroup` equivalents), `foldMessages(List<Message>, {required bool showReasoning})`, and `TranscriptWindow windowFor(...)` per spec §5.3.
- Moves the current private `_foldMessages` logic out of `chat_screen.dart` without changing behavior.

- [ ] **Step 1: Write failing layout tests**

```dart
test('content width is centered and capped', () {
  expect(const ChatLayout(viewportWidth: 1400).contentWidth, 896); // 64% = 896
  expect(const ChatLayout(viewportWidth: 2000).contentWidth, 920); // capped
  expect(const ChatLayout(viewportWidth: 400).contentWidth, 400);  // pane-bound
  expect(const ChatLayout(viewportWidth: 400).composerWidth, 432);
});
```

- [ ] **Step 2: Write failing fold/window tests**

```dart
test('window folds only the requested tail', () {
  final messages = List.generate(5000, (i) => msg('m$i'));
  final w = windowFor(messages, pageSize: 40, visibleCount: 40, showReasoning: false);
  expect(w.visible.length, lessThanOrEqualTo(40));
  expect(w.hiddenCount, greaterThan(0));
});
```

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/chat_layout_test.dart test/transcript_model_test.dart`
Expected: compile failure for missing files.

- [ ] **Step 4: Implement `ChatLayout` and the pure transcript model**

Move `_foldMessages` (`chat_screen.dart:48-95`) into `foldMessages(messages, {required showReasoning})`; `ChatScreen` keeps behavior by delegating. `windowFor` computes folded items once and returns the tail slice plus hidden count.

- [ ] **Step 5: Run GREEN and analyze**

Run:
```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_layout_test.dart test/transcript_model_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 6: Commit**

```bash
git add lib/ui/chat_layout.dart lib/ui/transcript_model.dart test/chat_layout_test.dart test/transcript_model_test.dart
git commit -m "feat: pure chat layout axis and transcript window model"
```

---

### Task 2: Apply the shared content axis to transcript, docks, and composer

**Files:**
- Modify: `lib/ui/chat_screen.dart`
- Create: `test/chat_layout_widget_test.dart`

**Interfaces:**
- Consumes `ChatLayout` from Task 1.
- Transcript list padding, `_MessageView` row constraints, dock widths, and `_InputBar` card width all derive from `ChatLayout.contentWidth`/`composerWidth`.

- [ ] **Step 1: Write failing widget tests**

Assert at 1400px and 400px widths that (a) the transcript column is centered/capped, (b) the composer card width equals `composerWidth`, and (c) user bubbles are at most `userBubbleMaxWidth`.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/chat_layout_widget_test.dart`

- [ ] **Step 3: Replace viewport-relative widths**

Replace `MediaQuery.size.width * 0.82` (`chat_screen.dart:2930-2931`) with `ChatLayout.userBubbleMaxWidth`; wrap transcript rows/docks in a centered `ConstrainedBox(maxWidth: contentWidth)`; cap the composer card at `composerWidth`.

- [ ] **Step 4: Preserve stop/queue/skill listeners**

Do not change `_InputBar.sessionId`, `busyFor(sessionId)`, `queuedMessagesFor(sessionId)`, `stopRequested(sessionId:)`, `locked`, or the `skill.mount` listener.

- [ ] **Step 5: Run GREEN, focused regressions, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_layout_widget_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_progress_widget_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/session_stop_isolation_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 6: Commit**

```bash
git add lib/ui/chat_screen.dart test/chat_layout_widget_test.dart
git commit -m "feat: share one centered chat content axis"
```

---

### Task 3: Compact reasoning and tool disclosures

**Files:**
- Modify: `lib/ui/chat_screen.dart`
- Create: `test/chat_disclosure_widget_test.dart`

**Interfaces:**
- `_ReasoningCard`/`_ToolCard` render a compact collapsed summary (24-33px) with rotating chevron and a hairline-separated expanded body; default collapsed.

- [ ] **Step 1: Write failing disclosure tests**

Assert reasoning and tool rows are collapsed by default, show a truncated summary, expand on tap, and collapse again; no heavy border/background on the collapsed summary.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/chat_disclosure_widget_test.dart`

- [ ] **Step 3: Restyle to compact disclosure geometry**

Apply spec §5.2 to `_ReasoningCard` (`:1984-2078`) and `_ToolCard` (`:2090-2322`); keep `_DetailBody` content. Preserve streaming behavior (running sweep).

- [ ] **Step 4: Run GREEN and existing transcript tests, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_disclosure_widget_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "PR25"
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 5: Commit**

```bash
git add lib/ui/chat_screen.dart test/chat_disclosure_widget_test.dart
git commit -m "feat: compact collapsed reasoning and tool disclosures"
```

---

### Task 4: Windowed transcript rendering and streaming isolation

**Files:**
- Modify: `lib/ui/chat_screen.dart`
- Create: `test/chat_large_history_test.dart`

**Interfaces:**
- Consumes `windowFor`/`foldMessages` from Task 1.
- The transcript caches the folded window and recomputes only when message count/identity or `showReasoning` changes; streaming text updates render via a dedicated live-bubble notifier without re-folding history.

- [ ] **Step 1: Write a failing large-history test**

Seed 5,000 messages; open `ChatScreen`; assert it renders the tail window, does not exceed a bounded fold count (via a counting seam on `foldMessages`), and stays responsive.

- [ ] **Step 2: Write a failing streaming test**

Simulate token appends to the live message; assert the transcript fold count does not grow with each token.

- [ ] **Step 3: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/chat_large_history_test.dart`

- [ ] **Step 4: Implement windowed fold cache + live-bubble notifier**

Replace the per-build `_foldMessages(s.messages)` (`chat_screen.dart:995`) with the cached window; isolate the streaming bubble so the list does not rebuild per token. Keep `ChatTranscript` using the same window.

- [ ] **Step 5: Run GREEN, startup/stop/skills regressions, full core, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_large_history_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_progress_widget_test.dart test/session_stop_isolation_test.dart test/plugin_runtime_skills_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 6: Commit**

```bash
git add lib/ui/chat_screen.dart test/chat_large_history_test.dart
git commit -m "feat: window transcript folding and isolate streaming"
```

---

### Task 5: Coalesced per-session persistence

**Files:**
- Modify: `lib/core/state.dart`
- Create: `test/session_persistence_test.dart`

**Interfaces:**
- `AppState.persistSessions()` coalesces rapid calls and encodes only changed sessions; a pending write flushes on session switch and lifecycle pause.
- Preserves `ovid_session_bootstrap_v1` tail-50 and deferred-hydration merge semantics.

- [ ] **Step 1: Write failing coalescing tests**

Assert N rapid `persistSessions()` calls within a window produce one encode; a changed session is re-encoded and an unchanged one is not; a final flush writes the last state.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/session_persistence_test.dart`

- [ ] **Step 3: Implement the dirty-set + debounced write queue**

Add a per-session dirty marker set on mutation; coalesce encodes; flush on switch/pause. Keep fingerprint/bootstrap envelope intact.

- [ ] **Step 4: Run GREEN, startup/migration/lifecycle regressions, full core, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/session_persistence_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/startup_first_frame_test.dart test/plugin_runtime_migration_test.dart test/session_plugin_lifecycle_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 5: Commit**

```bash
git add lib/core/state.dart test/session_persistence_test.dart
git commit -m "feat: coalesce per-session persistence writes"
```

---

### Task 6: Composer modes — Studio-only folder, hide Read-Only, `/preset plan`

**Files:**
- Modify: `lib/core/presets.dart`
- Modify: `lib/core/commands.dart`
- Modify: `lib/ui/chat_screen.dart`
- Modify: `lib/core/agent_service.dart` (preset application only)
- Create: `test/composer_modes_test.dart`
- Modify: `test/core_regression_test.dart` (mode/preset assertions only)

**Interfaces:**
- Produces `modeOptionsForPicker()` excluding `AgentMode.safe`; used by `_showModeSheet`, `_showModeSheetFromCommand`, and `/permission`.
- Adds a `plan` preset that sets `planMode = true` + read-only policy; other presets clear plan mode.
- `_WorkspaceChip` opens Studio; no in-chat folder picker.

- [ ] **Step 1: Write failing mode/preset tests**

Assert pickers exclude Read-Only; `/preset plan` sets plan mode and denies mutating tools; another preset clears plan mode; the workspace chip opens Studio and never the folder picker.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/composer_modes_test.dart`

- [ ] **Step 3: Implement mode filter, `plan` preset, and Studio-only folder**

Add `modeOptionsForPicker`; add `plan` to `PresetRegistry`; wire preset application to plan/read-only; make `_WorkspaceChip` open Studio. Keep `/permission read-only` functional for compatibility but unadvertised.

- [ ] **Step 4: Update existing mode/preset tests deliberately**

Update `core_regression_test.dart` assertions that enumerate all modes/presets.

- [ ] **Step 5: Run GREEN, focused, full core, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/composer_modes_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 6: Commit**

```bash
git add lib/core/presets.dart lib/core/commands.dart lib/ui/chat_screen.dart lib/core/agent_service.dart test/composer_modes_test.dart test/core_regression_test.dart
git commit -m "feat: studio-only folder, hidden read-only, plan preset"
```

---

### Task 7: Keyed scroll anchoring

**Files:**
- Modify: `lib/ui/chat_screen.dart`
- Create: `test/chat_scroll_anchor_test.dart`

**Interfaces:**
- Paging older messages restores the top item's key/offset; tip-follow uses a signature so it auto-scrolls only when already at the bottom.

- [ ] **Step 1: Write failing anchor tests**

Assert that after prepending older items the previously top item keeps its offset, and that a new streaming item does not force-scroll when the user has scrolled up.

- [ ] **Step 2: Run RED**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/chat_scroll_anchor_test.dart`

- [ ] **Step 3: Implement keyed anchoring**

Replace extent-delta compensation (`:761-767`) and post-frame `jumpTo(maxScrollExtent)` (`:773-780`) with keyed anchor restore and tip-follow signature.

- [ ] **Step 4: Run GREEN, large-history/widget regressions, analyze**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_scroll_anchor_test.dart
/home/ubuntu/sdk/flutter/bin/flutter test test/chat_large_history_test.dart test/chat_layout_widget_test.dart
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
```

- [ ] **Step 5: Commit**

```bash
git add lib/ui/chat_screen.dart test/chat_scroll_anchor_test.dart
git commit -m "feat: keyed transcript scroll anchoring"
```

---

### Task 8: Verification, audit, and README contract

**Files:**
- Create: `test/chat_dsh_parity_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-chat-dsh-parity.md`
- Modify: `README.md`

**Interfaces:**
- Verifies all interfaces from Tasks 1-7; documents structural parity and large-history budgets; discloses any device-only checks.

- [ ] **Step 1: Add end-to-end parity + large-history tests**

A single test asserting: centered capped column at wide/narrow; compact collapsed disclosures; 5,000-message session bounded fold; `/preset plan` read-only; folder chip opens Studio.

- [ ] **Step 2: Run full verification**

```bash
/home/ubuntu/sdk/flutter/bin/flutter test
/home/ubuntu/sdk/flutter/bin/flutter analyze --no-pub
/home/ubuntu/sdk/flutter/bin/flutter build apk --debug
git diff --check
```

- [ ] **Step 3: Write the audit and README contract**

Document the layout axis, disclosure geometry, large-history budgets, mode/preset changes, and any device-only checks; state plainly what was not executed.

- [ ] **Step 4: Commit**

```bash
git add test/chat_dsh_parity_test.dart docs/superpowers/audits/2026-09-10-chat-dsh-parity.md README.md
git commit -m "docs: verify chat DSH parity and large-history reliability"
```

---

## Execution Order

```text
1 layout+model -> 2 apply axis -> 3 disclosures -> 4 windowed+streaming
-> 5 persistence -> 6 modes/preset -> 7 scroll anchor -> 8 verification
```

Tasks are sequential because they share `lib/ui/chat_screen.dart` and `lib/core/state.dart`. Read-only scouts/reviewers may run in parallel.
