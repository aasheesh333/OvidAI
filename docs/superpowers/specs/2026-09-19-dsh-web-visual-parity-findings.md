# DSH Web Visual Parity — Measured Findings

Captured 2026-09-19 from a live `dsh web` session (1272×662 viewport, dark
theme, model `deepseek-v4.1-flash` via InferHub). Method: computed-style/DOM
reads (no image input). This is the current-state measurement for Ovid's
home/chat visual parity work.

## Layout (measured)

| Region | Value |
|---|---|
| Sidebar width | 280px |
| Center column | 992px (280 → 1272) |
| Conversation column | 680px, centered (x=431 at this width) |
| Composer card | 708px wide (column + 28), input 14/24 |
| Chat flow gap | 8px |

## Empty state ("home")

| Element | Value |
|---|---|
| Headline | 26px/32px weight 500, `#f9fafb` (e.g. "Into the Unknown") |
| Preview badge | 12px/18px weight 500, bg `#34415b`, radius 24px, pad `1px 7px 0` |
| Workspace / mode labels | 13px/20px weight 500, `#f9fafb` |
| Composer placeholder | 14px/24px, `#81858c` — "Describe what you want to build, / commands, @ files or sessions" |
| Access-mode trigger | 13px/20px weight 500, `#cfd3d6` ("Workspace Write") |
| Model trigger | 13px/20px weight 500, `#cfd3d6` ("deepseek-v4.1-flash") |

## Transcript

| Element | Value |
|---|---|
| User bubble | bg `#2c2c2e`, radius **22px**, pad `10px 16px`, 14/22/400, no border, max-w 477px |
| Assistant markdown | 680px, 14/24/400, `#f9fafb`, transparent, **no border/box** |
| Paragraph | margin `16px 0` |
| Code block | bg `#1b1b1c`, radius 12px, margin `16px 0 11px`, no border |
| Code banner | h 36px, radius `12px 12px 0 0`, bg `#151517` (current build) |
| Code `pre` | 11px/19px, pad 16px, radius bottom 12px |
| Table `th` | 13/22/500, pad `10px 16px 10px 0`, 1px bottom border |
| Table `td` | 13/22/400, pad `10px 16px 10px 0` |

## Animation library (exact keyframes)

| Name | Keyframes | Applied to |
|---|---|---|
| `_dsh-state-dot-chase` | `0%,12.4%{opacity:1} 12.5%,24.9%{.6} 25%,37.4%{.35} 37.5%,100%{.15}` | three-dot thinking chase |
| `_dsh-turn-status-shimmer` | `100%{background-position:0 0}` | streaming status text |
| `Sixlwa_retry-shimmer` | `0%{bg-pos:100% center} 100%{bg-pos:0 center}` | retry status |
| `o3BgMG_dsh-tool-row-sweep` | `0%{left:-300px} 90%,100%{left:100%}` | tool/bash/skill/command/reasoning rows (glare sweep) |
| `eGxaPq_dsh-turn-mark-busy` | `0%,100%{opacity:1} 50%{opacity:.35}` | turn-rail mark while busy |
| `eGxaPq_dsh-turn-mark-enter` | `0%{opacity:0} 100%{opacity:1}` | turn marks |
| `hHd-Xa_wide-in`, `bhn1Oq_wide-in` | `0%{opacity:0}` | sidebar reveals, 0.2s |
| `YDXeBa_row-in` | `0%{opacity:0}` | session rows, 0.15s |
| `pXSMma_hero-fish-swim` | `0%,100%{none} 35%{rotate(-4deg) translate(-.4px,-.9px)} 70%{rotate(1.6deg) translate(.3px,.2px)}` | empty-state hero mark |
| `_dockHintIn` | `0%{opacity:0;scale(.98)} 100%{opacity:1}` | dock hints |
| `gSkjMW_file-card-progress` | `0%{translate(-70%)} 100%{translate(220%)}` | file-card progress bar |

**Streaming status shimmer gradient (exact):**
`linear-gradient(90deg, #4176e6 0%, #4176e6 40%, #d3e2ff 50%, #4176e6 60%, #4176e6 100%)`
with `background-size: 250% 100%`, `background-position: 100% 0`,
`animation: 1.8s linear infinite`, `background-clip: text`,
`-webkit-text-fill-color: transparent`.

**Easing:** `cubic-bezier(.4, 0, .2, 1)`; entrance durations 0.15s–0.2s.

## Session naming (observed)

DSH auto-titled the new session from the prompt: "Write a short paragraph
about the ocean…" → **"Ocean Paragraph and Sea Creature Table"**. This matches
the dynamic naming Ovid now implements.

## Ovid gap list (prioritized)

Ovid already has: user/assistant rows, reasoning disclosure, tool cards,
markdown + code, copy/edit/revert/like, per-session stop/queue, model picker,
attachments, commands, `/` and `@` triggers, usage screen, subagents, session
analytics, dynamic titles.

Still to close for visual parity:

1. **Streaming status shimmer** — Ovid has `_ShimmerText`; verify the exact
   gradient/`background-size:250%`/`1.8s linear` and that it applies to the
   live status line, not just the collapsed summary.
2. **Three-dot thinking chase** — exact opacity ladder (1/.6/.35/.15) on a
   1s ease loop; verify Ovid's `_AgentDot`/dot row matches.
3. **Tool/reasoning row glare sweep** — the `-300px → 100%` sweep on tool,
   bash, reasoning, skill and command rows. Ovid has a sweep on some rows;
   confirm coverage and timing (90% hold).
4. **Empty-state hero** — headline 26/32/500, preview badge (`#34415b`,
   radius 24), workspace + mode rows, and the composer placeholder copy.
5. **User bubble geometry** — radius 22, pad `10px 16px`, max-w 477.
6. **Code banner bg** — measured `#151517` in this build (reference doc said
   `#2c2c2e`); confirm which Ovid should match.
7. **Composer card width** = column + 28px; input 14/24.
8. **Turn-mark rail busy pulse** — `opacity 1↔0.35`, 0.15s enter.
9. **Session row entrance** — 0.15s fade; sidebar reveal 0.2s.

Items 1–3 (the live text/streaming animation the user called out) are the
highest value and should be verified against Ovid's current widgets first,
then aligned.
