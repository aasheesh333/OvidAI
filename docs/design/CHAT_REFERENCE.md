# Chat surface reference — [CC] web · Meta Muse · Gemini mobile

A text-only teardown of three premium chat surfaces, written so an engineer can
rebuild Ovid Si's chat (`lib/ui/chat_screen.dart`, `lib/ui/v2/chat/chat_page.dart`)
without ever opening the screenshots. Every observation maps to Ovid's tokens
(`OColors`, `OType`, `OSpace`, `ORadius`, `OMotion` in `lib/ui/design/o_tokens.dart`)
and to the minimal-UI contract in `docs/design/MINIMAL_UI_CONTRACT.md`.

No proprietary asset, image, or copy string is reproduced here. Descriptions only.
Sources are listed at the end; all are public docs, public articles, or public
app-store pages, current as of October 2026.

---

## 1. [CC] on the web ( / )

The web client for cloud coding sessions. Left sidebar of sessions, one centered
chat column, a composer card at the bottom. The most "engineering-tool" of the
three references: calm, flat, monochrome with one warm accent.

### 1.1 Top bar

Contents, left → right:

1. **Sidebar toggle** — collapses the session list. Icon only.
2. **Session title** — plain text, one line, ellipsized; clicking opens a small
   dropdown (rename field, **Open in** → Terminal/Desktop hand-off, **Delete**).
   No avatar, no icon next to the title.
3. *(right side)* **Status / diff affordance** — while work exists, a compact
   `+N −M` diff counter that opens the diff view; when a PR exists, a CI status
   strip with an Auto-fix toggle sits above the transcript.
4. **Open in / share / overflow** — one or two quiet icon buttons and a menu.
   Nothing destructive is a top-level button (delete lives in the title
   dropdown, behind a confirm).

What it does NOT have: no model name in the bar on the session screen (model is
a composer/session concern), no breadcrumbs deeper than the title, no tabs.

### 1.2 Composer

A single rounded-rectangle card, centered on the same column as the transcript,
multi-line auto-growing textarea with a placeholder like "Describe a task" /
"Reply…". Structure:

- **Inside the card**: the text field; attachments paste/drop into it and show
  as small previews above the text.
- **Trailing send**: a return/arrow glyph; **while a run is active it becomes a
  stop square** and the field *stays editable* — sending mid-run creates a
  **queued message** rendered as a small card above the composer with an ✕;
  clicking ✕ retracts the text back into the field.
- **Selector chips below/beside the box** (task setup, not chat chrome):
  repository selector with a per-repo **branch** selector, **environment**
  selector, and the **permission-mode dropdown**. Model/effort are reachable
  but visually subordinate. On narrow widths these collapse into a menu.

The discipline that matters: **one text card + one row of context selectors**,
never two rows of buttons, never a status bar above the input. Run status is
shown in the transcript itself (status line), and the send button's shape is
the stop control.

### 1.3 Message list

- **User messages**: compact, right-aligned, light-neutral rounded bubble —
  the only bubble on the screen. It is clearly "yours" and takes minimal space.
- **Assistant messages**: **full-width, no bubble, no avatar, no chrome** —
  plain markdown prose on the page background: headings, lists, tables,
  fenced code blocks with a copy affordance and syntax highlighting.
- **Thinking**: a collapsed one-line disclosure ("Thinking…", then
  "Thought for N s") that expands in place.
- **Tool calls**: **one-line collapsible rows**, not cards — a small icon, the
  tool name, a one-line argument summary (a path, a command), a chevron.
  Expanded state shows input/output in mono. A running tool shows a subtle
  activity indicator inline. Done = quiet. Error = the only red on the page.
- **Plans/approvals**: a distinct bordered block with explicit accept/reject —
  visually heavier than a tool row, because it blocks progress.
- **Long answers**: structured markdown, generous paragraph spacing, code in a
  slightly inset block; the column width cap (~700–800 px) keeps line length
  readable; nothing is boxed.

### 1.4 Empty state

A new session is the **start surface**: centered column, a short heading, the
composer card already in place, and the repository/branch/environment selectors
under it. Recent sessions live in the sidebar, not as cards on the canvas.
No mascot, no illustration, at most a small mark.

### 1.5 Typography and spacing

- One sans family across the UI; **body ~15–16 px**, relaxed line height
  (~1.5); titles are barely larger than body (weight, not size, carries
  hierarchy). Code/paths in a mono face ~13 px.
- Side padding ~24 px; transcript column capped and centered; user bubble
  roughly 70–75 % of the column, sized to content.
- Vertical rhythm is paragraph-scale (12–16 px between blocks), not list-scale.

### 1.6 Colour

- Light theme: warm off-white / white page, near-black text, **one warm clay
  accent** used sparingly (primary buttons, active states). Dark theme: warm
  near-black page, slightly lighter surfaces.
- Depth is a **hairline border + one surface step**; shadows only under menus
  and popovers. Flat, layered-by-tone, never glossy.

### 1.7 Why it feels premium

Deliberately absent: avatars on every row, bubbles around prose, per-message
timestamps, emoji reactions, gradient anything, badges that don't change, a
second toolbar row. The screen is 95 % content. Controls appear exactly where
their state lives (diff count where the diff is, stop where send was, queue
above the box). Nothing pulses when it's done.

---

## 2. Meta Muse (mobile app)

Meta's personal agent (launched Sept 2026). The most "consumer-messaging" of
the three: it looks like texting a person, because the design thesis is one
long interruptible conversation with a named agent that also works in the
background.

### 2.1 Top bar

There is **no conventional app bar** on the chat screen. Instead, top-center:

1. **The agent's avatar in a circle** (a plush-doll face the user picked and
   named — launch examples were names like "Veda"; the default is a doll).
2. **The agent's name** under the avatar.
3. **A one-line live status** under the name ("Checking price…") — this is the
   activity indicator; there is no spinner row in the transcript header.

**Tapping the avatar** opens a sheet/panel: the avatar large, the same status,
a **Stop** control for the running task, then a segmented control —
**activity / approvals / permissions / upcoming** — with the matching list,
grouped by day. All transparency (what is it doing, what did I approve) is one
tap on the face, not a persistent dock.

A search affordance sits at a top corner; global navigation is a **floating
bottom bar: five icons, no labels** — Chat (home), Feed, Ideas, Goals, Library.

### 2.2 Composer

A single rounded text field at the bottom of the chat:

- Text field with a short hint; an **attach affordance** (links, screenshots,
  documents, photos, voice notes are all attachable) and a **voice** entry.
- Send is a simple arrow/glyph button.
- **While the agent is working the composer stays fully enabled.** Muse is not
  turn-by-turn: you can interrupt it or send several tasks at once without
  waiting for the last reply. There is no "disabled while running" state at
  all; the Stop control lives in the avatar sheet and on the running task's
  status, not in the composer.
- Attachments resolve to in-chat content (a sent screenshot renders as an image
  bubble, not a filename chip).

### 2.3 Message list

- **Chat bubbles, deliberately.** The design post states why: once messages can
  arrive out of turn (proactive agent) and users send several in a row, a flat
  transcript stops being readable — bubbles "mark where one thought ends and
  the next begins."
- **Agent bubbles**: neutral grey; **user bubbles**: light blue. Both with
  **large corner radii**, sized to content, aligned left (agent) / right
  (user). No per-message avatars — the face at the top is the only one.
- **Tool use**: a **small chip per action** in the flow ("Checking price") that
  taps open to the underlying call. Ambient, inline, dismissible by scroll.
- **Approvals**: real **cards inside the conversation** — a plain-language
  summary, the exact action spelled out, and **scope buttons**:
  *once / this conversation / always*. This is the deterministic control the
  team calls non-negotiable; conversation alone is not enough for spending or
  sending.
- **Artifacts**: finished deliverables (pages, trackers, documents) arrive as
  **preview tiles** in the chat and also live in the Library tab.
- **Long-press a bubble**: reaction tray + contextual rows — Reply, Copy,
  Select, Share, View sources (when cited), Delete (own messages only).

### 2.4 Empty state

First run is a **checklist, not a slideshow**: a few points about what the
agent is, then setup items ticked off as they complete. The chat itself opens
with the avatar header and the agent greeting you (it is proactive by design).
Discovery of "what can it do" is pushed to the **Ideas tab** (a grid of
suggestions grouped by life area, tap to send) rather than chips cluttering the
empty chat.

### 2.5 Typography and spacing

- One family (Meta's Optimistic) at **three or four sizes**; **large, friendly
  headings with tight letter-spacing**; **generous line-height inside bubbles**.
- Status/caption lines are small (12–13 px class); bubble body ~15–16 px class.
- Wide side margins around bubbles; big breathing room around the avatar
  header; the floating nav bar hovers ~12 px above the bottom edge.

### 2.6 Colour

- Warm, light, soft: off-white canvas, **grey agent bubbles**, **light-blue
  user bubbles**, dark text. Flat fills, big radii, almost no borders — depth
  comes from the floating pill bar's blur, not from shadows on messages.

### 2.7 Why it feels premium

Personality carries the chrome: the face at the top *changes with state*, so
the app feels alive without a single spinner. Everything else is removed: no
labels on the nav, no toolbar in the chat, no visible settings gear on the home
surface, no model pickers, no effort sliders. Deterministic UI appears only
where money or irreversibility is involved (approval cards with scope), which
makes those cards feel important rather than noisy.

---

## 3. Gemini mobile app (2026 "Neural Expressive" redesign)

Google's consumer assistant, redesigned May 2026 (iOS first, Android followed).
The most "motion-led" of the three: state is communicated with light and
movement instead of widgets.

### 3.1 Top bar

Minimal to the point of near-invisibility:

1. **Top-left**: a two-line menu icon (drawer) with the **model picker tucked
   under a chevron beside it** — an inconspicuous dropdown, deliberately not a
   hero element. (It moved *out* of the composer, where it used to sit.)
2. **Top-right**: a single **temporary-chat** button (dotted-line bubble with a
   pen).
3. **Not in the bar**: the Google account avatar — moved to the **bottom of the
   navigation drawer**, next to a settings gear. No title text, no greeting in
   the bar, nothing else.

### 3.2 Composer

- A **pill-shaped prompt box**, visually **detached/floating** above the
  keyboard on the home surface, surrounded by the gradient background.
- Exactly **three controls**: **"+"** on the left, **dictation (mic)** and
  **Gemini Live** on the right. Voice and Live are visually distinct entries —
  dictation transcribes into the box; Live opens the conversational mode.
- The **+ opens a bottom sheet**: a carousel (Photos, Camera, recent images)
  with Files/Notebooks/uploads, and below it the **tools as a list with
  descriptions** (Images, Videos, Music, Canvas, Deep Research, Guided
  Learning) — capabilities are legible words, not a row of cryptic icons.
- **While a prompt is being answered**: the field stays; the state signal is
  ambient — **the entire top half of the screen glows**, a gradient cycling
  through the brand's colors. No spinner row, no progress bar.

### 3.3 Message list

- **User messages**: right-aligned **bubbles** (surface-tonal, Material).
- **Assistant messages**: **full-width plain text** with the small spark mark;
  rich markdown, images, and code with copy. The app increasingly returns
  designed layouts (visual/dynamic views) instead of walls of text.
- **Thinking**: **removed from the inline transcript** — "See thinking steps"
  lives in the message overflow menu and opens as a **bottom sheet**. The
  conversation column stays clean.
- **Long answers**: full-width structured markdown; a row of actions (copy,
  share, feedback, listen) under the finished response rather than on every
  paragraph.
- Long-press / overflow carries the rest (export, sources, etc.).

### 3.4 Empty state

The signature screen: **centered, large, personalized greeting** — "Hi [name],
what's on your mind?" — with the **spark mark just above it**, on a soft
blue-white **pulsating gradient**. The greeting **rotates** between visits
("ask away", "the mic is yours"). **Suggestion chips were deleted** in the
redesign: the old home (small greeting + chip grid + five buttons under the
box) was judged "bland and overcrowded". The composer pill is the only
interactive element.

### 3.5 Typography and spacing

- Google Sans; the greeting is the **largest text on the screen** and centered.
- Body ~16 px with comfortable line height; iconography is a **thin, rounded
  outline set** — even the icons lost weight in the redesign.
- The composer pill has generous internal padding; side margins are wide
  enough that the pill reads as a floating object, not a docked bar.

### 3.6 Colour

- Light, airy base with a **blue-white gradient** as the brand moment; dark
  theme is a deep neutral. Material dynamic color underneath.
- Color is spent on **one surface at a time**: the home gradient, the thinking
  glow. The chat transcript itself is nearly monochrome.

### 3.7 Why it feels premium

Subtraction plus motion. The redesign removed the suggestion grid, the
under-box button row, the account avatar, and the inline thinking — and spent
the budget on **one** expressive behavior (the glow) with haptics and fluid
transitions. State is *felt* (glow, pulse) rather than *labeled* (spinner +
text). One pill, three icons, nothing else.

---

## 4. What Ovid Si should copy — and what it should not

Ovid's contract (`MINIMAL_UI_CONTRACT.md`) already lands close to the best of
these three: one header, one composer row, flat surfaces, text budgets. This
section is the opinionated diff — what to tighten to reach the reference bar.

### 4.1 Copy

1. **Assistant prose goes chromeless. ([CC], Gemini)**
   Assistant messages render **full-width on `OColors.bg`** — no `AetherSurface`
   card, no hairline border, no shadow. `ChatMessageRow` keeps its card for
   **user** messages only. Hierarchy comes from `OType` and spacing, not boxes.
   *Change*: assistant branch of `ChatMessageRow` → plain padded `Column`,
   horizontal `OSpace.screen`/`OSpace.l` padding, no `Decoration`.

2. **User bubble: compact, tinted, right-aligned, sized to content. (All three)**
   Keep `ChatLayout.userBubbleMaxWidth` (75 % of the column) and the right
   alignment. Fill it with `OColors.accentSoft` (Ovid's violet-tint equivalent
   of Muse's light-blue / Gemini's tonal bubble) with `ORadius.l`–`xl` corners.
   **No border, no shadow on the bubble.** Text in `OType.body`.

3. **Tool calls are one-line rows, not cards. ([CC])**
   `ChatToolCallCard` collapses to: 14 px icon + tool name (`OType.bodySmStrong`)
   + one-line mono arg summary (`OType.mono`, `OColors.textMuted`) + chevron,
   separated by a `OColors.hairline` bottom rule — **fill and border removed**.
   The state pill shrinks to a colored 8 px dot (accent = running, success =
   done, danger = error, warn = stopped). Expanded detail keeps the mono block
   on `OColors.codeBg`. Running rows may animate the dot (`OMotion.ambient`,
   respects reduced motion); done rows are static.

4. **Thinking stays inline but collapsed. ([CC])**
   Keep `_ReasoningCard` ("Thinking… 4s" → "Thought for 6s") — it already
   matches [CC]. **Do not** adopt Gemini's thinking-in-a-bottom-sheet; an agent
   transcript needs reasoning verifiable in place, and the contract already
   bans sheets that duplicate transcript content.

5. **Composer keeps one row; the field never locks mid-run. ([CC], Muse)**
   The contract's `+ → permission chip → field → mic → send` order stands.
   Change the *running* behavior: the **text field stays enabled** while a turn
   runs, Send becomes Stop (already true via `_RoundAction`), and a mid-run
   send lands in the existing `_QueueDock` as a queued card with an ✕ that
   returns the text to the field — [CC]'s retract pattern, which Ovid's queue
   dock already half-implements. Hint text switches to the working state (per
   contract: "the run status is the field's hint"), matching
   `v2-chat-composer`'s `'Ovid is working...'` hint.

6. **The + sheet owns everything that isn't the one row. (Gemini)**
   Attachments, photos, camera, files, voice modes, and any tool toggles live
   in the `+` bottom sheet as **worded rows with one-line descriptions**
   (Gemini's tools list), not as extra icons on the bar. The bar never grows
   past five targets (`+`, chip, field, mic, send).

7. **Model selection stays in the header, once. (Gemini)**
   `V2ModelChip` in `_ChatTopBar` is the single model control. Do **not** add
   [CC]'s composer-level model/effort rail — a second picker is exactly the
   "busy" the reference UIs removed. Effort/permission stays the one
   permission chip in the row (or in the `+` sheet below 360 dp, per contract).

8. **Status is one quiet line, in one place. (Muse)**
   Muse's avatar-sheet pattern maps to Ovid as: **one status line under the
   header title or above the composer** (`OType.caption`, `OColors.textMuted`),
   fed by `_SubagentActivityDock`/goal state — and the heavy docks
   (goal bar, todo dock, stats line) collapse into it or move behind the
   overflow menu. Tapping the status line may open a sheet with the activity
   list and a Stop control (Muse's sheet), which retires the always-on docks.

9. **Approval requests are cards with scope buttons. (Muse)**
   `_ApprovalDock` becomes an in-transcript card: plain-language summary,
   the exact action, and **Allow once / Allow for this chat / Always allow** —
   `OButton` ghost ×2 + one filled (`OColors.accentFill` / `OColors.onAccent`).
   This is the one place extra chrome is *correct*: blocked, consequential,
   and rare.

10. **Send/Stop is the round accent button. (All three)**
    Keep `_RoundAction`: 48 dp circle, `OColors.accentFill` with
    `OColors.onAccent` up-arrow; running → `OColors.danger` stop square;
    disabled (empty draft) → `OColors.surfaceRaised` with `OColors.textFaint`.
    Already matches the references; do not regress it to an icon button.

11. **Composer card: floating, hairlined, flat. (Gemini, [CC])**
    The `_Composer` card (`OColors.surface`, `ORadius.xl`, 1 px
    `OColors.hairline`, no shadow) is exactly right. Keep `OShadow` reserved
    for menus/popovers only — never on the composer or messages.

12. **Empty state: one greeting, one line, ≤3 quiet chips. (Gemini, contract)**
    Center the column: greeting in `OType.h2` (≤4 words, e.g. the existing
    "How can I help?"), one muted line (`OType.bodySm`, `OColors.textMuted`,
    ≤18 words), then **at most three** `OChip` suggestions (the current V2
    `_HomeContent` behavior). Remove the 52 px brand tile from the Aether
    `_EmptyState` — the header already carries identity; Gemini's lesson is
    that the greeting *is* the brand moment. No rotating greetings, no
    illustrations (contract text budgets; rule 4).

13. **Column discipline stays. ([CC])**
    `ChatLayout`/`OContent` caps (680–920 pane-relative on the Aether screen;
    640/720 band caps on V2) match [CC]'s centered column. Composer may be
    `composerWidth` (column + 32) — keep the slight width step; it reads as
    intentional, not misaligned.

### 4.2 Do NOT copy

1. **Gemini's pulsating gradient / thinking glow.** The Ovid contract bans
   decorative gradients and glow (rule 4; `OShadow` doc). Ovid's equivalent of
   "state you can feel" is the hint swap + the send→stop morph + one
   `OMotion.ambient` dot on the active tool row. Nothing full-screen.
2. **Gemini's rotating personalized greetings.** Violates the empty-state text
   budget and adds a string-rotation system for zero function.
3. **Muse's avatar theater.** No plush face, no naming ceremony, no
   state-posed mascot. Ovid's identity is the mark in the header; personality
   lives in copy tone, not a character. (The *status line* pattern — yes; the
   *doll* — no.)
4. **Muse's bubbles for the agent.** Bubbles suit proactive out-of-turn
   consumer chat; Ovid's transcript is an engineering record with code, diffs
   and tool output — full-width prose + one-line tool rows ([CC]) carry that
   better, and bubbles would re-introduce the card-per-row busyness.
5. **[CC]'s composer selector strip (repo/branch/environment/mode/model).**
   Five chips under the box is right for a cloud-runner start surface and wrong
   for Ovid's one-row contract. Repo/branch/environment context belongs in the
   session's overflow menu or a session-info sheet, not beside the field.
6. **[CC]'s `/`-command-first discoverability in the UI.** Slash commands stay
   typed (Ovid already has the slash menu); do not surface a command palette
   bar in the composer.
7. **Reaction trays / emoji on messages (Muse).** Long-press keeps only:
   Copy, Select, Share, View sources (when cited), Delete (own messages) —
   matching Ovid's existing overflow actions. No reactions row.
8. **Gemini's model-picker-as-nearly-hidden.** Ovid's model chip must stay
   visible in the header (users switch models often); Gemini hides it because
   consumers never switch. Different product, keep Ovid's affordance.
9. **Anything that pulses, loops, or glows after its job is done.** Contract
   section 7 already says it; the references confirm that premium = motion
   that ends.

### 4.3 Token cheat-sheet for the rebuild

| Element | Token / widget |
|---|---|
| Page background | `OColors.bg` |
| Assistant text | `OType.body` (16/1.45) on bg, `OSpace.l` side padding |
| User bubble | `OColors.accentSoft` fill, `ORadius.l`, `OType.body`, ≤ `ChatLayout.userBubbleMaxWidth` |
| Composer card | `OColors.surface`, `ORadius.xl`, 1 px `OColors.hairline`, `OSpace.s` padding |
| Send/Stop | 48 dp circle: `accentFill`/`onAccent` → `danger`/`onDanger`; disabled `surfaceRaised`/`textFaint` |
| Tool row | icon 14 + `OType.bodySmStrong` + `OType.mono` summary (`textMuted`) + `hairline` rule; state = 8 px dot |
| Thinking | collapsed disclosure, `OType.caption` label, body `OType.bodySm` muted on expand |
| Code block | `OType.mono` (JetBrainsMono 13/1.5) on `OColors.codeBg`, `ORadius.s` |
| Status line | `OType.caption`, `OColors.textMuted`, one line, one location |
| Approval card | `OColors.surface` + `hairlineStrong` border, scope buttons: ghost, ghost, `accentFill` |
| Header | `_ChatTopBar`/`OAppBar`, `OType.h2` title, `V2ModelChip`, ≤3 actions above 360 dp, 1 px `hairline` bottom |
| Motion | `OMotion.fast`/`base` for state changes; `ambient` only for the live dot; honor reduced motion |

---

## Sources

- [CC] cloud/web documentation (cloud sessions, session sidebar, diff view,
  queued-message retract, permission-mode control, Open in → Terminal),
  code. docs, 2026.
- [CC] desktop redesign announcement (sidebar filters, view modes, usage
  button),  blog, April 2026.
- AI UX Playground, "Claude composer UX: model picker, skills & attachments"
  teardown (calm default card, + menu, right-rail model/effort, voice
  confirm), June 2026.
- "How We Designed Muse", introducing.muse.ai, September 2026 (bubbles
  rationale, avatar + status, Goals/Ideas tabs, approval cards, artifacts).
- nanoMuse `docs/design.md` — a public study of Muse's published screenshots
  and walkthrough videos (bubble colors, five-icon floating bar, chip-per-tool,
  approval scope buttons).
- Muse store listings (App Store / Google Play) and the Mac walkthrough
  (window attach beside the composer; in-composer replies).
- Android Authority / 9to5Google coverage of the Gemini 2026 "Neural
  Expressive" redesign (pill composer, three-button row, + bottom sheet with
  described tools, centered rotating greeting, chips removed, thinking moved
  to a bottom sheet, glow-as-state, model picker top-left, account in drawer),
  May 2026.
