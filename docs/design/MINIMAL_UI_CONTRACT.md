# Ovid Si — minimal UI contract

Every screen must follow this file. If a rule here conflicts with an older
screen, **this file wins**. The goal is one calm surface: less text, one header
pattern, one spacing scale, and layouts that survive 320 dp → tablet.

## 0. What changed in this pass (2026-10-22)

One pass took all 50 registered screens to the rules below. It was a reduction
pass: copy, controls and chrome were removed until each screen had one header,
one job and one action. The numbers below are decisions, not aspirations — each
one has a gate under `test/`.

**One header per screen.** Every screen has exactly one bar and one title line,
`OType.h2`, ≤ 3 words, optional subtitle ≤ 6 words, never repeated as a body
heading. Leading is menu on a drawer root, back on a pushed page, close on a
sheet. Destructive actions never live in the header. Two implementations, one
pattern:

- 36 screen files render through `OScreen` → `OAppBar`; sheets use
  `OSheetHeader` or `showOSheet(title:)`. `OScreen` takes **at most 2 header
  actions** (1 below 360 dp) and drops the rest, so a screen cannot overflow its
  own bar.
- The four onboarding steps (welcome, language & goal, sign-in, paywall) use
  `OnboardingStepScaffold` — back only with a real previous step, close only
  when it leaves the tour. Chat, Live chat, Browser, Projects and System states
  draw their own single `AppBar` row because the header carries a control the
  shared bar does not model (model chip, address field, filter, four framed
  states). Chat and Live chat are the one exception to the two-action budget:
  they keep **3** (Studio, Browser, overflow), and only above 360 dp — below
  that Studio and Browser fold into the overflow menu. Splash and the lock
  screen have no header at all.

Gate: `test/v2/header_consistency_test.dart`, registry-wide, with an empty
known-gaps map — zero accepted violations.

**Text budgets.** Header title 3 words / subtitle 6; section header 3; row title
4; row subtitle 10; empty-state title 4 / body 18; button label 3; helper text
10; toast 8. `test/v2/text_budget_test.dart` scans every role-bearing literal in
`lib/ui/v2` and enforces **0 over-budget strings**, plus a ratchet on the *total*
role-bearing word count so short-but-redundant copy cannot accumulate. The
ceiling lives in the test; lower it when copy is deleted, never raise it to make
the suite pass. The banned phrases are "not available yet", "coming soon",
"tap to", "nothing here yet", "simply", "just", "please" and "in order to".

**Three responsive bands.** One source of truth, `OBreakpoints` in
`lib/ui/design/o_screen.dart`:

| Window | Navigation | Content |
|---|---|---|
| `< 600` | drawer (max 340 dp, or 86 % of the window) + bottom bar | full width (∞ cap) |
| `600–899` | fixed **280 dp** rail; no drawer and no bottom bar | **640 dp** cap |
| `>= 900` | fixed **300 dp** rail; no drawer and no bottom bar | **720 dp** cap |

Side padding is 16 dp on a phone and 24 dp on a tablet. Header actions are 2,
or 1 below 360 dp. Card lists use 1 / 2 / 3 columns below 600 / 600–999 /
1000+; rows never become columns. Gate: `test/v2/responsive_audit_test.dart`
(every screen at 320/360/412/600/800/1024/1280 dp, 100 % and 200 % text, light
and dark) plus `test/v2/app/shell_responsive_test.dart`.

**Content caps.** ∞ / 640 / 720 by band. A wider window adds margin, not line
length. The one exception is Browser: from 900 dp it is a window, so it gets
**1100 dp**; below 900 dp it keeps the band cap.

**Composer: one row, fixed order.** `+` → permission chip → field → mic → send.
Send becomes stop while a turn runs. There is no second row of controls and no
status row above the input — the run status is the field's hint. Attachments and
errors sit above the row. `V2ComposerRow` owns the order and is used by both the
home and the live composer. When the row cannot fit three 48 dp targets plus at
least one 48 dp field (320 dp at 200 % text), the permission chip is dropped
from the row — it is never wrapped to a second line — and the composer's own
`+` sheet carries it as its first row, so the permission stays reachable.

**No control without a service.** A control whose backing service does not
exist is removed, not disabled and not wired to a toast. A control may still be
disabled for a *temporary state* (empty draft, turn running, loading); it may
not be disabled because the feature is absent. This is why the account-health
device review / 2FA rows are hidden, why Schedules renders no create or toggle
control when the flow supplies no handler, and why the paywall no longer shows a
"Compare all plans" button with nothing behind it.

## 1. The five rules

1. **One header per screen, always.** Every screen has exactly one top bar.
   No screen may start with content flush against the status bar.
2. **Text is a cost.** Every string must earn its place. If a label repeats
   what an icon already says, delete the label.
3. **One action per zone.** A screen has one primary action. Secondary actions
   go in the top-right menu, never as a third full-width button.
4. **Nothing floats without a job.** No decorative gradients, no glow, no
   card-inside-card, no badge that does not change.
5. **Responsive is a layout, not a scale.** At 600 dp+ the content centres to a
   max width; lists become two columns only when the item is a card, never for
   rows.

## 2. Header contract

Use `OAppBar` (or `OScreen`) — never a hand-rolled `Row` in a `Container`.

| Screen kind | Header |
|---|---|
| Root tab (Chat, Studio, Browser, Library, Settings) | `leading: menu` + title + `actions: [at most 2 icons]` |
| Pushed page | `leading: back` + title + `actions: [at most 2 icons; prefer 1]` |
| Chat / Live chat | `leading: menu` + model chip + title + `actions: [Studio, Browser, ⋮]` above 360 dp, `[⋮]` below |
| Sheet | grabber + title row with close, then content |
| Onboarding step | no back arrow unless there is a real previous step; close only when it dismisses the whole flow |
| Full-screen state (splash, lock) | no header at all |

Rules:
- Title is one line, `OType.h2`, ellipsized. Subtitle is optional, one line,
  `OType.caption`, muted. **Never two subtitles.**
- A screen with a header must not repeat its title again in the body as a
  heading. One heading per screen.
- Destructive actions never live in the header; they go to the bottom of the
  screen or the menu.
- Back arrow appears only when `Navigator.canPop` is true, or when the screen
  is a tour step with a real previous step.

## 3. Text budget

| Element | Max |
|---|---|
| Header title | 3 words |
| Header subtitle | 6 words |
| Section header | 3 words |
| Row title | 4 words |
| Row subtitle | 10 words, one line, ellipsized |
| Empty state title | 4 words |
| Empty state body | 18 words, max 2 lines |
| Button label | 3 words |
| Helper text under a field | 10 words, only when the field is not obvious |
| Toast / snackbar | 8 words |

Delete on sight:
- Sentences that explain what the user can already see ("Tap to open").
- Two sentences where one clause works.
- "Please", "simply", "just", "in order to".
- Restating the plan name in every row of a plan list.
- Any string containing "not available yet" — wire it or remove the control.

## 4. Spacing and type

Only `OSpace` tokens: `xxs 2`, `xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`, `xxl 32`.
No literal numbers in padding except 0 and hairline 1.

Only `OType` styles. No `fontSize:` overrides. Text scales with the system; the
only allowed exception is a numeric badge that must not reflow, and it must
still be at least 11 sp.

Radius: `ORadius.xs 4`, `s 8`, `m 12`, `l 16`, `xl 24`, `pill`.
Touch target: 48 dp minimum, always.

## 5. Responsive contract

| Width | Layout |
|---|---|
| `< 360` | single column, 16 dp side padding, header icons max 1 |
| `360–599` | single column, 16 dp padding (phone default); drawer + bottom bar |
| `600–899` | fixed 280 dp rail, no drawer or bottom bar; content max width 640, centred; sheets become centred dialogs |
| `>= 900` | fixed 300 dp rail; content max width 720, centred |

Browser is the single exception: from 900 dp it may use 1100 dp because it is a
window, not a column of text. Below 900 dp it uses the band cap.

Implementation: `OBreakpoints`, `OScreen` and `OContent` in
`lib/ui/design/o_screen.dart`; rail widths in `Sidebar.railWidthTablet/Wide`.
Never hard-code a width above 600. Every list must be lazy (`ListView.builder` /
`SliverList`).

At 200 % text scale on 320 dp nothing may overflow. Long words wrap or
ellipsize; never clip.

## 6. States

Every screen that loads data implements all four, and each is a single
`OStateView`: loading (skeleton, no spinner text), empty (title + one line +
one action), error (one line + Retry), content.

An empty state must not say "Nothing here yet" — say what would be here.

## 7. Motion

One shared motion vocabulary (`OMotion`). No animation longer than 250 ms for
a state change. Nothing pulses or loops after its job is done. Reduced motion
is honoured everywhere.

## 8. Wiring rule

A control is allowed only if it reaches real state: `AppState`, a route in
`lib/ui/v2/app/*_routes.dart`, or a service. Otherwise it is removed.

Forbidden: a button whose handler is null, a toast that only says a feature is
unavailable, a switch that snaps back, a "Copied" confirmation with nothing
copied, a progress bar that always completes.

## 9. Checklist before a screen is done

- [ ] exactly one header, correct leading, ≤2 actions
- [ ] no repeated title in the body
- [ ] every string within the text budget
- [ ] only OSpace/OType/ORadius tokens
- [ ] 320 dp @ 200 % text, light and dark: no overflow
- [ ] 600 dp and 900 dp: content centred, not stretched
- [ ] loading / empty / error / content all implemented
- [ ] every control wired, or removed
- [ ] semantics: labelled, enabled state announced, reading order follows
      visual order
