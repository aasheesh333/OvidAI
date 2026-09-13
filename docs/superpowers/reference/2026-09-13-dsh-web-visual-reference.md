# DSH Web Visual Reference (captured 2026-09-13)

**Source:** `@deepseek-ai/dsh` v0.1.5-rc.1, `dsh web` at `http://127.0.0.1:3080`,
opened in the VNC Chrome (CDP `127.0.0.1:9222`), model `deepseek-v4.1-flash`
via InferHub (`https://api.inferhub.dev/v1`), dark theme.

**Capture method:** computed CSS/DOM measurements (the capturing model has no
image input), from a real session with 20+ vibe-coder exchanges exercising
empty state, user message, streaming/completed assistant prose, reasoning/tool
disclosures, fenced code, markdown tables, file links, error state, and usage
stats. Values are exact `getComputedStyle` reads.

This document is a **measurement reference for reimplementation** in Ovid's
`Aether` theme. It intentionally records DSH's raw values; Ovid code must not
contain DSH identifiers, brand names, or token names.

---

## 1. Design tokens — dark theme (resolved)

| Role | Value |
|---|---|
| bg base | `#151517` |
| bg layer 1 | `#232324` |
| bg layer 2 | `#2c2c2e` |
| bg layer 3 | `#353638` |
| border l1 | `#ffffff0f` (≈ 6% white) |
| border l2 | `#ffffff1f` (≈ 12%) |
| border l3 | `#ffffff29` (≈ 16%) |
| label primary | `#f9fafb` |
| label secondary | `#cfd3d6` |
| label tertiary | `#adb2b8` |
| label caption | `#81858c` |
| brand primary | `#f9fafb` (white; not blue) |
| link / accent | `#679efe` |
| accent strong (deepseek-450) | `#5686fe` |
| code block bg | `#1b1b1c` |
| inline code bg | `#292929` |
| code banner bg | `#2c2c2e` |
| user bubble | `#2c2c2e` |
| sidebar fill | `#1b1b1c` |
| input major | `#2c2c2e` |
| error | `#f25a5a` |
| success | `#22c55e` |
| warn | `#f59e0b` |
| selection/preview badge bg | `#34415b` |

Neutral scale (dark-relevant): neutral-800 `#292929`, 850 `#212123`,
900 `#0f0f0f`; bluish-850 `#2c2c2e`, 875 `#232324`, 900 `#1b1b1c`,
950 `#151517`.

Shadows: lv1 `0 2px 4px #0000000d`; lv2 `0 4px 12px #00000005, 0 2px 8px #0000000a`;
lv3 `0 0 1px #0003, 0 0 4px #00000005, 0 12px 32px #00000014`.
Elevation stroke `0 0 0 .5px` of a 6% white line.

Scrollbar width 8px.

## 2. Typography

- **UI family:** `-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Helvetica Neue", Helvetica, Arial, sans-serif`
- **Code family:** `"SF Mono", "JetBrains Mono", "Fira Code", Consolas, "Liberation Mono", Menlo, Courier, "PingFang SC", "Microsoft YaHei"`
- Easing `cubic-bezier(.4, 0, .2, 1)`; durations fast `.1s`, base `.2s`, slow `.3s`.

Scale (size/line-height/weight):

| Token | Value |
|---|---|
| markdown base | 14 / 24 / 400 |
| markdown base strong | 14 / 24 / 600 |
| markdown small | 12 / 20 / 400 |
| markdown code | 12 / 19 |
| markdown code-block | 11 / 19 |
| markdown code-block-small | 11 / 16 |
| markdown table | 13 / 22 |
| markdown table head | 13 / 22 / 500 |
| markdown h1 | 21 / 30 / 700 |
| markdown h2 | 19 / 28 / 700 |
| markdown h3 | 18 / 26 / 700 |
| markdown h4 | 14 / 24 / 600 |
| xl-24 | 24 / 32 / 600 |
| l-20 | 20 / 28 / 500 |
| m-18 | 16 / 28 / 500 |
| base-16 | 16 / 24 / 400 |
| s-14 | 14 / 22 / 400 |
| xs-13 | 13 / 20 / 400 |
| xxs-12 | 12 / 18 / 400 |
| xxxs-11 | 11 / 14 / 400 |

Conversation font size is user-configurable (default **14px**); markdown sizes
are expressed as `calc(size + (content-font-size - 14px))`.

## 3. Layout

- Conversation content column: `clamp(680px, 64% of conversation width, 920px)`.
  Observed at 1000px pane → **680px**.
- Composer card max-width: content column **+ 32px** (712px observed).
- Composer side clearance 16px; dock inset 8px; stack gap 6px.
- Composer text max-height 336px.
- Chat flow gap **8px**.
- User bubble max-width `min(477.36px, 82%)`; bubble itself 445px.
- Sidebar inline padding 12px; session-list scrollbar 8px, offset 2px.

## 4. Transcript elements (computed)

### 4.1 User message
- Row: flex, `align-items: flex-end`, gap 6px, full 680px column.
- Stack: `align-items: flex-end`, gap 8px, `max-width: min(477px, 82%)`.
- Bubble: bg `#2c2c2e`, radius **22px**, padding **10px 16px**,
  font **14/22/400**, color `#f9fafb`, **no border**.

### 4.2 Assistant prose
- Markdown root: 680px, font 14/24/400, color `#f9fafb`, transparent, **no
  border/box**.
- Plain run: inline, 14/22.
- Paragraph: 14/24, no margin.
- Strong: 600. Inline code: code font, bg `#292929`.
- h2 19/28/700, h3 18/26/700, h4 14/24/600.
- Table: 13/22; `th` 500 with 1px bottom border `rgba(255,255,255,.16)`;
  `td` padding `10px 16px 10px 0`; wrapper is horizontally scrollable.
- File mention link: accent `#679efe`, 13/22/500.

### 4.3 Fenced code block
- Container: bg `#1b1b1c`, radius **12px**, margin `16px 0 11px`, no border.
- Banner: bg `#2c2c2e`, radius `12px 12px 0 0`, padding `9px 14px`, gap 12px,
  font **11/18**, infostring uses code font.
- Body `pre`: padding **16px**, font **11/19**, code font, radius bottom 12px.
- Copy button lives in the banner.

### 4.4 Reasoning / process disclosures
- Root/row: flex, `align-items: center`, full 680px, font 14/24.
- Leading glyph color `#adb2b8`, margin-right 6px.
- Title: 13/24, color `#cfd3d6`.
- Summary: 13/20, color `#adb2b8`.
- Separator: 1px, `#81858c`, margins `0 8px`.
- Process summary ("4 tool calls"): button, 13.33px effective, color
  `#cfd3d6`, padding-bottom 8px, transparent, no border.
- These are **collapsed rows**, not bordered cards.

#### 4.4.1 Reasoning disclosure geometry (measured)
- Collapsed trigger: `height: 33px`, `border-bottom: .5px solid #ffffff1f`,
  `color: #cfd3d6`, `cursor: pointer`, `padding: 0 0 8px`, transparent bg.
- Label: `14px/24px`, ellipsis.
- Chevron: `16×16`, color `#adb2b8`, `margin-left: 6px`,
  `transition: transform .1s`, `rotate(-90deg)` collapsed → `0deg` expanded.
- **Expand/collapse is instant** (content swaps in place); only the chevron
  rotates over `.1s`. No height animation.
- Expanded body (`hWmORq_root`): flex column, `14px/24px`,
  `color: #f9fafb` (primary — NOT muted), borderless, full 680px column.
- Reasoning text is regular markdown at full size, not a smaller muted font.

#### 4.4.2 Tool / process row geometry (measured)
- Row (`_row_luwio_16`): `height: 24px`, `overflow: hidden`, flex,
  align-items center.
- Leading glyph: `16×16`, color `#adb2b8`, `margin-right: 6px`.
- Title: `13px/24px`, color `#cfd3d6`.
- Summary: `13px/20px`, color `#adb2b8`, ellipsis.
- Separator dot: `2×2px`, color `#81858c`, `margin: 0 8px`, radius 1px.
- Tool kinds render as short rows: `Write`, `Bash`, `Think`, each with a
  trailing summary (e.g. `Write package.json +18 -0`).
- Diff stat: code font, `11px`, color `#81858c`, `margin-left: 10px`.

### 4.5 Turn error
- Row: grid `10px minmax(0,1fr) auto`, `align-items: start`, gap 8px,
  padding `2px 0`, 680px, `13px/20px`.
- Message: color `#cfd3d6`, inline.
- Title ("This turn failed") + code (e.g. `MISSING_CREDENTIAL`) with a state
  dot (error color `#f25a5a`).

### 4.6 Usage / stats
- Message action row: flex, gap 8px, 16px effective.
- Footer stats are compact chips: `Usage 44.1K tok`, `Ran for 16s`,
  `2 turns 6 steps · 194 tok/s`, `44.1K tok · Cache hit 82%`,
  `4% of context used`.
- Numbers use compact K/M/B suffixes.
- To-dos block: `5 completed` / `1 in progress · 4 pending`.

### 4.8 Live streaming / thinking animations (measured)
- **State dot chase** (`_dsh-state-dot-chase`): SVG cells, base
  `opacity: .15`, `animation: 1s ease infinite`, keyframes
  `0%/12.4% → 1`, `12.5%/24.9% → .6`, `25%/37.4% → .35`,
  `37.5%/100% → .15`. This is the pulsing "three dots" chase.
- **Turn-status shimmer** (`EvIC1a_turnStatus`): height 26px, `14px/22px`,
  `background-clip: text`, `-webkit-text-fill-color: transparent`,
  `background-size: 250% 100%`, `background-position: 100% 0`,
  `animation: 1.8s linear infinite` (`background-position → 0 0`).
  Gradient (exact):
  `linear-gradient(90deg, #4176e6 0%, #4176e6 40%, #d3e2ff 50%, #4176e6 60%, #4176e6 100%)`.
  The status text is a rotating phrase (e.g. "Deep diving…"), shimmering
  blue with a light `#d3e2ff` highlight sweeping left.
- **Retry shimmer** (`Sixlwa_retry-shimmer`): `1.6s ease-in-out infinite`,
  `background-position: 100% center → 0 center`.
- Clock next to status: `13px/20px`, `font-variant-numeric: tabular-nums`,
  color `#81858c`, `margin-left: 8px`.
- Entrance animations: session rows `.15s`, turn marks `.15s`, sidebar
  reveals `.2s`, all `cubic-bezier(.4,0,.2,1)`.

### 4.9 Subagents
- Rendered inline in the assistant turn as `1 message · 2 subagents`.
- Each subagent is a markdown list item with a short hex id in inline code
  (e.g. `` `4785ea0d` ``) plus a one-line description.
- Inline code chip: code font, bg `#292929`, radius 6px, padding `0 5px`,
  `border: 1px solid #ffffff0f`.
- The session title bar shows a `N subagents running` indicator and the
  breadcrumb shows `/ 2 subagents`.
- Tool rows for subagents carry a `Deep diving…` status shimmer.

### 4.10 Files changed card
- Section label `Files changed` (`13px/22px`, color `#adb2b8`).
- Each file row: file link `13px/24px` color `#cfd3d6` + description +
  an `Open` action; `Open`/preview actions appear on hover.
- Empty case: `No files were created — this was a direct response.`
  (`14px/24px`, margin-top 16px).

### 4.11 Empty / new-session state
- Headline: **26/32/500**, color `#f9fafb` (e.g. "Into the Unknown").
- Preview badge: code font **12/18/500**, bg `#34415b`, radius **24px**,
  padding `1px 7px 0`, margin-top 2px, color `#f9fafb`.
- Workspace button: 13/20/500, radius 16px, padding `0 8px`,
  max-width `min(100%, 360px)`.
- Hero block bottom padding 32px; hero workspace row padding `0 16px 0 20px`.
- Composer hero centered; input placeholder color is a muted tertiary.

## 5. Motion

- Entrance animations are short fades/slides: `0.15s`–`0.2s`,
  `cubic-bezier(.4, 0, .2, 1)`.
- Session row enter 0.15s; turn marks 0.15s; sidebar/label reveals 0.2s.
- Thinking/ongoing uses a vertical fade gradient
  (`linear-gradient(180deg, #151517 20.19%, #15151700 100%)`) and the accent
  `#5686fe` as the ongoing/decoding color.
- Streaming text decodes with the accent gradient; there is no bordered
  "thinking card".

## 6. DSH features vs Ovid (gap list)

Ovid already has: user/assistant rows, reasoning disclosure, tool cards,
markdown + code, copy/edit/revert/like, per-session stop/queue, model picker,
attachments, commands, `/` and `@` triggers, usage screen, subagents.

DSH features Ovid lacks (candidates for P1 Task 8):

1. **Trajectory tab** with a turn-navigation rail (jump-to-turn marks).
2. **Context-usage ring** ("4% of context used") in the composer.
3. **Cache-hit %** and **tok/s** live stats.
4. **Files-changed card** with preview/open-in-sidebar and per-file actions.
5. **Branch into a new conversation** from a message.
6. **System-prompt injection** disclosure row per turn.
7. **Good/Bad response** feedback buttons (Ovid has like/dislike — verify parity).
8. **Conversation display: Compact** mode (collapse process content in completed
   turns).
9. **Send-while-busy behavior** selector (Queue vs other).
10. **Workspaces** sidebar grouping + workspace hero row.
11. **Agent presets** ("Standard mode") selector.

Items 1, 4, 6, 8, 9, 10, 11 are the strongest parity gaps; 2, 3, 5 are
nice-to-have. Final scope is set by the P1 spec's Task 8.
