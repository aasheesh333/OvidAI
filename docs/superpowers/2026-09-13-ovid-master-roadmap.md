# Ovid Master Roadmap — post-P6 request batch (2026-09-13)

**Status:** Active. This is the single tracker for the large 2026-09-12/13 request
batch. Each project below has a design spec (`specs/`) and an implementation plan
(`plans/`). Execute **one project at a time**, top to bottom, using
`superpowers:subagent-driven-development` (one implementer per task, read-only
reviewer, fix rounds max 5, per-plan ledger under `.superpowers/sdd/<plan>/`).

## Global rules

- **No DSH references in `lib/` or `test/`** (existing repo rule). Visual parity
  is a reimplementation using Ovid's `Aether` theme tokens; never copy DSH
  branding, assets, icons, product copy, or CSS token names. `.dsh/` workspace
  paths are exempt (functional).
- Every project: RED test first, then implement; keep `flutter test` green and
  `flutter analyze` clean.
- Toolchain: Flutter `/root/flutter/bin/flutter`, `ANDROID_HOME=/opt/android-sdk`,
  Java 17. Full suite baseline at start of this roadmap: **1120/1120**.
- Device-only checks stay `NOT EXECUTED` until hardware exists; never claim
  on-device success.
- Commit + push after each completed project.

## Projects

| ID | Project | Spec | Plan | Status |
|----|---------|------|------|--------|
| P0 | Reliability bug bundle | `specs/2026-09-13-reliability-bug-bundle-design.md` | `plans/2026-09-13-reliability-bug-bundle.md` | IN PROGRESS (ovid-pkg `.gz`-first, apt CRLFile, inbuilt install routing, marketplace object-source + real parse errors, provider ambiguity all done; `gh` install still open) |
| P1 | DSH web visual parity (home + chat + theme) | `specs/2026-09-13-dsh-visual-parity-design.md` | `plans/2026-09-13-dsh-visual-parity.md` | IN PROGRESS (theme, formatter, hero pill, hint, question scroll, recents, transcript geometry done; streaming + feature gaps open) |
| P2 | Control mode + overlay | `specs/2026-09-13-control-mode-overlay-design.md` | `plans/2026-09-13-control-mode-overlay.md` | IN PROGRESS (one-time disclosure, background-only overlay, lower opacity + stroke, control-mode briefing done; overlay questions + mic open) |
| P3 | 24/7 background operation | `specs/2026-09-13-background-24-7-design.md` | `plans/2026-09-13-background-24-7.md` | NOT STARTED |
| P4 | Studio + browser | `specs/2026-09-13-studio-browser-design.md` | `plans/2026-09-13-studio-browser.md` | NOT STARTED |
| P5 | Voice input (mic) | `specs/2026-09-13-voice-input-design.md` | `plans/2026-09-13-voice-input.md` | NOT STARTED |
| P6 | Token efficiency (no-folder) | `specs/2026-09-13-token-efficiency-design.md` | `plans/2026-09-13-token-efficiency.md` | NOT STARTED |

## Source requirements (verbatim, user 2026-09-12/13)

These are the raw asks, grouped by project. Nothing here is dropped; anything
deferred gets an explicit note.

### P0 — reliability
- `apt update` in sandbox: `[ovid-pkg] fetch index → …/Packages` then
  `curl: (22) … error: 404` noise although the index is ready. (Root cause: the
  script tries `.xz` first, which does not exist on the mirror; `.gz` works.)
- Inbuilt plugins/MCP: clicking install opens "add marketplace" instead of
  installing in real time.
- `catalog_add_marketplace obra/superpowers-marketplace` → "No marketplace.json
  found" although `.claude-plugin/marketplace.json` exists (CC object-form
  `source`; parse error swallowed).
- Claude-Code / Codex plugins & MCP "architecture not in Ovid" — improve
  compatibility (marketplace object `source`, `skills/<name>/SKILL.md`, `.mcp.json`).
- Different providers exposing the same model id must never conflict.
- `gh` (GitHub CLI) install error.
- `apt` `CRLFile` fix (already in working tree) — commit.

### P1 — DSH web visual parity
- Home screen + chat screen 100% visually like DSH web (theme too).
- Keep Ovid's existing features; additionally implement DSH features Ovid lacks.
- AppBar and composer **unchanged** (Ovid's own).
- Remove boxed response style; match DSH streaming send/receive layout, thinking
  animation/font/layout, output font/layout.
- Remove blue "Preview" text from home first screen.
- Shorten long numbers (`25708k` → `2.5M` / `2.5B`) in usage screen, time
  displays, and chat box.
- Chat box hint text lower opacity.
- AI question box must be scrollable (overflows screen today).
- Model selector: recent-selected models, max 10.

### P2 — control mode + overlay
- Control-mode permission popup must appear **only once** (first switch), not
  every switch.
- Overlay must appear **only when the app is minimized**.
- Overlay: lower opacity (see-through), professional, light live-control feedback,
  cross/close icon.
- AI must know it is in control mode (no confusion).
- AI question/notice in control mode should pop up as an overlay.
- Mic option in the overlay too.

### P3 — 24/7
- Ovid runs 24/7 until the user stops it via the notification (in-app stop),
  phone off, or force-quit. Best-effort; OEM/Doze caveats disclosed.

### P4 — studio + browser
- Sandbox folder selection only in Studio mode.
- Studio GitHub device login opens the **external** browser, not in-app.
- Replace "Sandbox ready" text with a colored dot: green logged-in, red not.
- New session: browser data shared across all sessions, tabs fresh.
- In-app browser Google sign-in fails ("this browser is not secure").

### P5 — voice input
- Make the mic work in the composer and add one to the overlay.

### P6 — token efficiency
- Selecting any model and sending with no folder selected consumes too many
  tokens; reduce fixed per-request cost.

## Progress log

| Date | Project | Change | Commit |
|------|---------|--------|--------|
| 2026-09-13 | P2 | One-time control disclosure; background-only overlay; overlay 70% alpha + stroke; control-mode briefing | pending |
| 2026-09-13 | P0 | ovid-pkg `.gz`-first index probe; inbuilt plugin/MCP direct install; marketplace object-form source + real parse errors; provider model-id ambiguity returns null | 34d636e |
| 2026-09-13 | P1 | DSH reference captured (dark theme tokens, geometry, markdown, empty state) | 13ea40b |
| 2026-09-13 | P1 | Theme palette → reference ramp; compact-number formatter; hero preview pill removed; composer hint faint; question card scrollable; recent models (max 10); transcript geometry (bubble 22px, code block, markdown line-heights) | pending |
| 2026-09-13 | P1 | Roadmap + specs/plans authored | 297206c |
| 2026-09-12 | — | apt `CRLFile` root cause fixed | 297206c |
