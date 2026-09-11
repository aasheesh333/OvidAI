# Chat Shell, DSH Parity, and Large-History Reliability Design

**Date:** 2026-09-10
**Status:** Approved by product direction (user: "100% same like DSH web" home chat flow; engineering-best defaults, no further option prompts).

## 1. Goal

Make the Ovid home chat flow structurally match the installed DeepSeek DSH web reference — one centered, capped transcript column; borderless assistant prose; compact collapsed reasoning/tool disclosures; a composer whose width is tied to the transcript — while making very large conversations (~1M-token context) open and stream without hanging. Also clean up composer modes: the folder picker becomes Studio-only, Read-Only is removed from the direct mode pickers, and `/preset plan` becomes the read-only Plan policy.

## 2. User Outcomes

1. Assistant prose and user bubbles share one centered readable column (DSH-like), not a viewport-relative 82% width.
2. Reasoning and tool output render as compact, default-collapsed disclosure rows, not large bordered cards.
3. The composer aligns to and is only slightly wider than the transcript column.
4. Opening a huge conversation is bounded and does not freeze the UI; streaming a long response does not re-scan the entire history on every token.
5. Scrolling stays anchored: loading older messages does not jump the viewport; following the tip still works.
6. The folder picker is reachable only from Studio; the chat composer workspace chip opens Studio.
7. Read-Only is not a direct mode option; `/preset plan` selects a persisted read-only Plan policy.
8. Existing behavior (per-session stop/queue, session-scoped skills, startup dashboard) is preserved.

## 3. Non-Goals

- Copying DSH branding, assets, icons, product copy, or CSS token names. Structural/behavioral patterns only; independent Flutter reimplementation.
- Replacing the agent loop, providers, tools, or plugin runtime.
- Full database transcript migration (a bounded persistence improvement is in scope; a full store swap is not required).
- Studio terminal/Git, browser, plugins UI, control overlay (Projects 3-6).

## 4. Current Failure Model (evidence)

### 4.1 Viewport-relative layout, not a shared column
`_MessageView` caps rows at `MediaQuery.size.width * 0.82` (`lib/ui/chat_screen.dart:2930-2931`); the transcript list pads 16px (`:1024-1029`); the composer card spans the viewport minus 24px (`:4113-4126`). There is no shared content-width axis between transcript, docks, and composer. DSH uses `--dsh-chat-content-width: clamp(680px, 64%, 920px)` and composer `= W + 32px` (`ConversationRoot.module.css:28-35`, `InputBar.module.css:2-63`).

### 4.2 Heavy per-token work
`ChatScreen.build` wraps the whole Scaffold in `AnimatedBuilder(animation: app)` (`:783-787`). Every streaming token calls `AppState.refresh()` (`lib/core/agent_service.dart:6689-6709`), rebuilding the scaffold and re-running `_foldMessages(s.messages)` over the entire message list (`chat_screen.dart:995`) before slicing the 40-row window (`:1002-1009`). Cost is O(total messages) per token. `ChatTranscript` (subagents) is unpaged.

### 4.3 Persistence rewrites everything
`persistSessions()` re-encodes every session's every message to one `StringList` (`lib/core/state.dart:2838-2916`), invoked from many sites, at least once per turn. A large history makes each write expensive.

### 4.4 Composer modes
`_WorkspaceChip` opens the in-chat folder picker (`:5443-5643`); `_ModeChip`/`_showModeSheet`/`_showModeSheetFromCommand`/`/permission` all expose `AgentMode.safe` (Read-Only) (`:5692-5783`, `:1267-1309`, `commands.dart:255-301`). No `plan` preset exists (`presets.dart:75-160`).

### 4.5 Unanchored paging
Paging up uses extent-delta compensation (`:761-767`) and tip-follow uses post-frame `jumpTo(maxScrollExtent)` (`:773-780`); variable-height markdown makes this fragile.

## 5. Architecture

### 5.1 Shared content-width axis
Add a pure layout model, mirroring DSH semantics without its tokens:

```dart
class ChatLayout {
  final double viewportWidth;
  final double sidebarWidth;
  const ChatLayout({required this.viewportWidth, this.sidebarWidth = 0});

  /// The single readable column width for transcript rows, docks, and the
  /// composer card. Mirrors DSH clamp(680, 64% of chat pane, 920).
  double get contentWidth {
    final pane = (viewportWidth - sidebarWidth).clamp(0, double.infinity);
    return (pane * 0.64).clamp(680.0, 920.0).clamp(0.0, pane);
  }

  /// Composer card is slightly wider than the transcript column.
  double get composerWidth => (contentWidth + 32).clamp(0.0, viewportWidth);

  /// User bubble is a compact fraction of the column.
  double get userBubbleMaxWidth => (contentWidth * 0.75).clamp(0.0, contentWidth);
}
```

Transcript list padding, `_MessageView` row constraints, dock widths, and the composer card all read `ChatLayout`. On narrow phones the column collapses to the pane width (readable), never a tiny desktop canvas.

### 5.2 Compact disclosure geometry
Reasoning and tool output become compact disclosure rows by default:
- 24-33px collapsed summary line with a leading glyph, a truncating title, and a trailing chevron that rotates when expanded.
- Expanded body is full column width, muted, no heavy border; a single hairline separates the summary from the body.
- The existing `_ToolCard`/`_ReasoningCard` are restyled to this geometry; the detailed body widgets (`_DetailBody`) are preserved.

### 5.3 Pure fold + windowed transcript
Extract folding into a pure function:

```dart
List<ChatItem> foldMessages(List<Message> messages, {required bool showReasoning});
```

Add a bounded transcript view model:

```dart
class TranscriptWindow {
  final List<ChatItem> visible; // at most pageSize folded items
  final int hiddenCount;
  final int totalFolded;
}
TranscriptWindow windowFor(List<Message> messages, {required int pageSize, required int visibleCount, required bool showReasoning});
```

The chat rebuild folds only the tail window needed for display, not the entire history. Streaming appends update only the live tail item; the rest of the transcript is not re-folded. `ChatTranscript` (subagents) uses the same window with a larger page.

To bound per-token work without a full store rewrite: keep the folded window cached and recompute only when the message count or last message identity changes, plus when `showReasoning` toggles. Streaming text changes to the live bubble are rendered by a small dedicated notifier so the transcript list itself does not rebuild per token.

### 5.4 Bounded persistence
Introduce a serialized, per-session write queue in `AppState`:
- Coalesce rapid `persistSessions()` calls (debounce) so one turn does not trigger many full encodes.
- Encode only sessions whose content changed since the last write, using a per-session dirty flag.
- Keep the `ovid_session_bootstrap_v1` tail-50 envelope and the deferred-hydration merge semantics unchanged.

This is a bounded improvement, not a storage-engine swap.

### 5.5 Composer modes and Plan preset
- `modeOptionsForPicker()` returns `AgentMode.values` minus `safe`; all three pickers use it.
- Add a `plan` preset to `PresetRegistry` that selects plan mode + read-only policy. Selecting `/preset plan` sets `planMode = true` and applies the read-only tool gate; selecting any other preset clears plan mode.
- `_WorkspaceChip` no longer opens a folder picker; it opens Studio (or shows the pinned folder read-only). Folder selection lives only in Studio.
- The Read-Only mode remains reachable internally (existing sessions persisted as `safe` keep working; `/permission read-only` may remain for compatibility but is not advertised).

### 5.6 Anchored scroll
Replace extent-delta compensation with a keyed anchor: record the top visible item key and its offset before prepend; after prepend, restore that item to the same offset. Tip-follow uses a signature (last item key + length) so it only auto-scrolls when the user is already at the bottom.

## 6. Error Handling

- Folding/paging never throws on malformed messages; unknown kinds render as plain text.
- Persistence coalescing never drops a final write; a pending write flushes on lifecycle pause and on session switch.
- Layout clamps are defensive against zero/negative viewport widths.
- Missing DSH reference never blocks; patterns are reimplemented, not imported.

## 7. Performance Budgets

- Opening a synthetic 5,000-message session renders its tail window without an O(N) fold on the UI isolate beyond the window.
- Streaming a response does not re-fold the full history per token.
- A turn triggers at most one coalesced persistence encode of changed sessions.
- No new app-wide listener is added to `ChatScreen`; the startup panel and composer keep their isolated listeners.

## 8. Testing

- Unit: `ChatLayout` width clamps; `foldMessages` purity (including `showReasoning`); `TranscriptWindow` bounds and hidden counts; persistence coalescing/dirty-set.
- Widget: transcript column and composer share the axis at narrow/wide; reasoning/tool collapsed by default and expand; 5,000-message session opens with bounded work; paging-up keeps the anchor; `/preset plan` sets read-only Plan; mode pickers exclude Read-Only; folder chip opens Studio.
- Regression: per-session stop/queue, session-scoped skills, startup dashboard, existing preset/mode tests updated deliberately.

## 9. Migration

- Existing sessions with `mode == safe` continue to behave read-only; they are not auto-migrated, but Read-Only is no longer offered directly.
- Existing `presetId` values are unchanged; the new `plan` preset is additive.
- No persisted transcript format change; only write frequency and per-session dirty tracking change.

## 10. Decisions

- Layout parity is structural only; no DSH branding/assets/copy/token names.
- The transcript uses one centered capped column; composer is column + 32px.
- Reasoning/tool disclosures are compact and collapsed by default.
- Large history is handled by windowed folding + per-token streaming isolation + coalesced persistence, not a storage-engine rewrite.
- Folder selection is Studio-only; Read-Only is via `/preset plan`.
- Scroll anchoring is keyed, not extent-delta.
