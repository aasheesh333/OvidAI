# DSH Web Visual Parity (Home + Chat + Theme) — Design

**Date:** 2026-09-13
**Status:** Approved by product direction. Reference capture pending (Phase 0);
this spec is finalized against the captured reference before implementation.

## 1. Goal

Make Ovid's **home/empty state and chat transcript** look and feel like the
DeepSeek Harness (DSH) web UI — same theme palette, typography, spacing, message
send/receive layout, thinking animation, and output rendering — while keeping
Ovid's existing features and **keeping Ovid's own AppBar and composer unchanged**.
Add the DSH features Ovid is missing. This is a visual reimplementation with
Ovid's own code and `Aether` tokens; no DSH branding/assets/copy/CSS names.

## 2. User Outcomes

1. The chat transcript (user message, assistant prose, reasoning/thinking, tool
   output, code, markdown) matches the captured DSH reference in font, size,
   color, spacing, and animation.
2. The home/empty state matches the reference; the blue `preview` pill is gone.
3. The theme palette matches the reference (dark first).
4. Long numbers are shortened everywhere they appear (`25708k` → `2.5M`/`2.5B`):
   usage screen, time displays, chat box stats.
5. Composer hint text is visibly faint.
6. The AI question box is scrollable and never overflows the viewport.
7. The model picker shows up to 10 recently selected models.
8. Ovid's existing features are preserved; DSH features Ovid lacks are added
   (list finalized from Phase 0).
9. The AppBar and composer keep Ovid's current structure.

## 3. Non-Goals

- Copying DSH branding, assets, icons, product copy, or CSS token names.
- Changing the AppBar or the composer's structure/behavior.
- Replacing the agent loop, providers, tools, or plugin runtime.
- A full theme-engine rewrite; the palette is updated in `Aether`.

## 4. Phase 0 — Reference capture (before implementation)

DSH = `@deepseek-ai/dsh`. `npx @deepseek-ai/dsh web --no-open --port 3080`
serves the Web UI at `http://127.0.0.1:3080` (launch URL carries a token).
Credentials: InferHub (`https://api.inferhub.dev/v1`, [OI]-compatible,
model `deepseek-v4.1-flash`) configured as a pi-ai provider.

Capture procedure:
1. Install/run DSH; configure InferHub; verify with one message.
2. Open in the VNC Chrome (CDP `127.0.0.1:9222`).
3. Send **20+ realistic vibe-coder messages** exercising: short/long user
   messages, streaming assistant prose, reasoning/thinking, tool calls, tool
   errors, long output, fenced code, markdown (lists/tables/links), an AI
   question prompt, and a fresh/empty session.
4. For every state: screenshot + measured CSS (font family/size/weight/line-
   height/color, spacing, radii, borders, animation durations/easing).
5. Write `docs/superpowers/reference/2026-09-13-dsh-web-visual-reference.md`
   with the measurements and a state-by-state gap list vs Ovid.

## 5. Current Failure Model (evidence)

- No separate home screen: `OvidShell` always renders `ChatScreen`; empty state
  is `_EmptyState` (`chat_screen.dart:2146-2240`), which contains the blue
  `preview` pill (`:2201-2220`).
- Assistant prose is already borderless (`_text` `:3457-3477`), but code blocks
  (`_OvidCodeBox` `:6271-6339`), inline code (`:6381-6408`), reasoning card
  (`_ReasoningCard` `:2246-2351`), tool card (`_ToolCard` `:2363-2606`), and
  several cards still carry bordered boxes.
- Reasoning is collapsed by default; streaming uses `_ChaseDot`/`_ShimmerText`
  (`:2278-2297`).
- Number formatters stop at `K`: `usage_screen.dart:382`, `:562`,
  `chat_screen.dart:277-280`, `_MeterBreakdownBar` `:521-524`,
  `agent_service.dart:172`.
- Composer hint has no color, overriding the faint theme default
  (`chat_screen.dart:4545`).
- `_QuestionsCard` (`:5535-5759`) has no scroll wrapper and overflows.
- Model picker (`_ModelPickerSheet` `:1825-2028`) has no recent list; only a
  single `lastSelectedModel`/`lastSelectedProviderId` (`state.dart:2580-2581`).

## 6. Design

### 6.1 Theme
Update `lib/core/theme.dart` (`Aether`) to the captured palette (background,
surface, hairline, text/textMuted/textFaint, accent, success/warn/danger), dark
first. Keep token **names**; only values change. No DSH naming.

### 6.2 Transcript geometry + typography
Match captured values for: content column width, row alignment, user bubble
fill/radius/padding, assistant prose font/size/line-height/color, inter-row
spacing, reasoning summary/body, tool summary/body, code box, markdown elements.
Remove residual heavy borders where the reference is borderless.

### 6.3 Streaming + thinking animation
Match the captured send/receive motion and thinking indicator (timing/easing),
using Ovid's existing animation primitives.

### 6.4 Home/empty state
Match the reference; remove the `preview` pill; keep Ovid's brand mark unless
the reference dictates otherwise.

### 6.5 Number shortening
Add one shared formatter (`formatCompactCount`) used by usage screen, time
displays, and chat stats: `<1000` raw; `K`/`M`/`B` with 1 decimal, trimming
`.0`.

### 6.6 Hint + question box
Give the composer hint an explicit faint color. Wrap `_QuestionsCard` body in a
bounded `ConstrainedBox` + `SingleChildScrollView` (mirroring `_PlanReviewCard`
`:5463-5469`).

### 6.7 Recent models
Persist an ordered, de-duplicated list of the last 10 `(providerId, model)`
selections; show them at the top of the model picker.

### 6.8 DSH features Ovid lacks
Finalized from Phase 0 capture (candidate: message-level copy/retry affordances,
session/thread affordances, attachment/context display, keyboard shortcuts).
Each gets an explicit outcome and task once listed.

## 7. Testing

- Pure formatter unit tests (K/M/B boundaries).
- Widget tests: preview pill absent; hint faint; question card scrolls under a
  tall content set; recent models appear and cap at 10.
- Golden/geometry tests for the transcript where practical.
- Side-by-side screenshots vs the reference for the audit.
- Full `flutter test` + `flutter analyze` green.

## 8. Decisions

- Visual parity is reimplementation with `Aether`; no DSH strings in code.
- AppBar + composer unchanged.
- One shared compact-number formatter.
- Reference capture gates implementation; gaps are enumerated, not guessed.
