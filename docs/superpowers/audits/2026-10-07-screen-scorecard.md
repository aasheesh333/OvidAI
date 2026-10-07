# Ovid 45-screen UI/UX scorecard

**Audit date:** 2026-10-07  
**Scope:** `lib/ui/**`, `lib/main.dart`, and navigation call sites in the UI layer  
**Constraint:** Read-only product audit. No app code was changed.

## Executive summary

Ovid has a coherent chat-first product frame with a strong visual language, a
substantial amount of state-aware UI, and unusually good investment in complex
workflows such as Studio, sandbox installation, plugin runtime status, and
authentication recovery. The main UX debt is not a lack of screens; it is the
number of high-consequence states that remain implicit, silent, or hard to
recover from. The most important examples are approval/send safety, destructive
session deletion, browser zero-tab handling, silent Studio/plugin failures, and
settings affordances that do not always expose their actual state.

**Overall score: 74/100**

| Dimension | Weight | Score | Basis |
|---|---:|---:|---|
| Information architecture and wayfinding | 20 | 16 | Chat-first shell and grouped Settings are clear; deep feature breadth is spread across pushes and modal layers rather than a discoverable route model. |
| Interaction clarity and task completion | 20 | 15 | Strong primary flows and reusable action primitives; several destructive, disabled, or no-op states do not explain themselves. |
| Visual/system consistency | 20 | 17 | `Aether` primitives, cards, section titles, buttons, status dots, and responsive Studio metrics provide a credible system. |
| State, feedback, and error resilience | 20 | 13 | Many screens model loading/progress/partial states; silent catches, infinite spinners, stale indices, and blank failure states reduce trust. |
| Accessibility and responsive behavior | 20 | 13 | Chat text scaling, semantic labels/tooltips, safe areas, and breakpoints are present; narrow layouts and modal/keyboard edge cases remain uneven. |

### Score interpretation

- **90–100:** release-ready, exemplary surface
- **80–89:** strong surface with targeted polish needed
- **70–79:** usable and coherent, but meaningful UX debt remains
- **60–69:** functional with recurring friction or trust issues
- **Below 60:** material usability, safety, or recovery gaps

## Evidence and method

### Inventory method

`lib/main.dart:98-103` establishes `LoginGate(child: OvidShell())` as the app
root. There is no centralized named-route table in the inspected UI code. The
effective route inventory is therefore reconstructed from:

1. root composition in `main.dart`;
2. top-level composition and drawer behavior in `shell.dart`;
3. navigation pushes in `sidebar.dart` and feature screens;
4. public `*Screen` classes;
5. modal sheet/dialog entry points and their public widgets/panels.

`MaterialPageRoute` is used repeatedly for feature navigation—for example
Schedule, Trajectory, and Settings in `sidebar.dart:224-267`, Providers to
Billing in `providers_screen.dart:160-164`, and plugin/MCP detail routes in
`plugins_screen.dart:1401-1402` and `3150-3151`. Sheets and dialogs are counted
as user-facing surfaces where they represent a complete task or stateful flow,
not as separate application destinations.

### Per-surface scoring

Each row uses five equal 20-point criteria:

1. **IA** — purpose, hierarchy, entry/exit, and wayfinding;
2. **IX** — action clarity, affordances, and task completion;
3. **VIS** — visual consistency, hierarchy, density, and feedback styling;
4. **STATE** — loading, empty, success, error, persistence, and recovery;
5. **A11Y** — semantics, text scaling, keyboard/safe-area behavior, and responsive layout.

Scores are code-evidence-based heuristics, not a substitute for a live usability
study or visual sign-off. Existing audit evidence is incorporated where useful,
especially the prior file/line UI sweep and the objective screenshot metrics in
`docs/superpowers/audits/2026-10-06-ui-screenshot-review.md`.

## 45-surface scorecard

The **Type** column distinguishes actual app destinations from gate states,
panels, sheets, and embedded widgets. File/line references point to the
implementation or the route entry that makes the surface user-facing.

| # | Surface / route | Type | Evidence | IA | IX | VIS | STATE | A11Y | Total |
|---:|---|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Splash / Firebase initialization | Gate state | `login_gate.dart:145-180` | 17 | 16 | 17 | 17 | 16 | **83** |
| 2 | Firebase unavailable / retry | Gate state | `login_gate.dart:123-126`, `_UnavailableScreen` at `236` | 16 | 15 | 16 | 11 | 15 | **73** |
| 3 | Account not ready | Gate state | `login_gate.dart:127-132`, `_AccountNotReadyScreen` at `288` | 15 | 14 | 16 | 12 | 15 | **72** |
| 4 | Login / sign-in | Gate screen | `_LoginScreen` at `login_gate.dart:546`, `auth_screen.dart:22-32` | 17 | 16 | 17 | 14 | 14 | **78** |
| 5 | Post-login welcome | Gate overlay | `_PostLoginWelcomeGate` at `login_gate.dart:368-447` | 16 | 15 | 17 | 15 | 14 | **77** |
| 6 | Ovid shell / chat-first frame | Route shell | `shell.dart:54-60`, `209-245` | 18 | 16 | 18 | 16 | 15 | **83** |
| 7 | Sessions sidebar / drawer | Navigation widget | `sidebar.dart:26-36`, `49-281` | 18 | 16 | 18 | 13 | 15 | **80** |
| 8 | Chat workspace / composer | Primary screen | `chat_screen.dart:766-802`, shell entry at `shell.dart:211` | 18 | 16 | 18 | 14 | 16 | **82** |
| 9 | In-app Browser | Route | `browser_screen.dart:22-34`, `176-180` | 16 | 15 | 17 | 10 | 14 | **72** |
| 10 | Studio coding workspace | Route | `studio_screen.dart:105-127`, `114-117` | 17 | 16 | 18 | 14 | 15 | **80** |
| 11 | Sandbox setup/install | Route | `sandbox_setup.dart:67-82`, `155-168` | 16 | 16 | 17 | 15 | 14 | **78** |
| 12 | Settings hub | Route | `settings_screen.dart:45-57`, sections `59-240` | 18 | 16 | 18 | 16 | 15 | **83** |
| 13 | Account auth settings | Nested route | `auth_screen.dart:22-32`, route push at `settings_screen.dart:374` | 16 | 15 | 16 | 13 | 14 | **74** |
| 14 | Providers / BYOK | Nested route | `providers_screen.dart:43`, provider sheets at `485`, `609` | 17 | 16 | 17 | 14 | 14 | **78** |
| 15 | Billing / plan | Nested route | `billing_screen.dart:16-20`, `110-139` | 16 | 15 | 17 | 14 | 14 | **76** |
| 16 | Permissions | Nested route | `permissions_screen.dart:31-38`, confirmation at `441` | 16 | 15 | 16 | 14 | 14 | **75** |
| 17 | Memory files | Nested route | `memory_screen.dart:29-35`, file sheet at `605` | 16 | 16 | 17 | 15 | 14 | **78** |
| 18 | Plugins catalog | Nested route | `plugins_screen.dart:803-814` | 17 | 15 | 18 | 13 | 14 | **77** |
| 19 | Plugin detail | Detail route | `plugins_screen.dart:1679`, push at `1401-1402` | 16 | 16 | 17 | 15 | 14 | **78** |
| 20 | MCP server detail | Detail route | `plugins_screen.dart:3331-3339`, push at `3150-3151` | 15 | 15 | 17 | 14 | 13 | **74** |
| 21 | Usage overview | Nested route | `usage_screen.dart:107`, push at `settings_screen.dart:437` | 16 | 15 | 17 | 14 | 13 | **75** |
| 22 | Provider usage detail | Detail route | `usage_screen.dart:763-771`, push at `649-650` | 15 | 15 | 16 | 14 | 13 | **73** |
| 23 | Image receipts | Detail route | `usage_screen.dart:296`, `image_receipt_panel.dart:11-24` | 15 | 15 | 16 | 14 | 13 | **73** |
| 24 | Health / diagnostics | Nested route | `health_screen.dart:18-28`, repair route at `78-79` | 16 | 15 | 17 | 11 | 14 | **73** |
| 25 | Settings health | Nested route | `settings_health_screen.dart:15-22` | 15 | 14 | 16 | 14 | 13 | **72** |
| 26 | Backup / restore | Nested route | `settings_backup_screen.dart:14-20` | 16 | 16 | 16 | 15 | 14 | **77** |
| 27 | Storage management | Nested route | `_StorageScreen` at `settings_screen.dart:776-782` | 15 | 15 | 16 | 14 | 13 | **73** |
| 28 | Export chats | Task route | `_ExportChatsScreen` at `settings_screen.dart:1444-1450` | 15 | 15 | 16 | 14 | 13 | **73** |
| 29 | About | Nested route | `_AboutScreen` at `settings_screen.dart:1533` | 16 | 13 | 16 | 14 | 14 | **73** |
| 30 | Skills manager | Nested route | `SkillsScreen` at `settings_screen.dart:1665-1671` | 16 | 15 | 17 | 14 | 13 | **75** |
| 31 | Agent presets | Nested route | `_PresetsScreen` at `settings_screen.dart:1953` | 16 | 15 | 17 | 14 | 13 | **75** |
| 32 | AI response timeout | Nested settings screen | `_TimeoutScreen` at `settings_screen.dart:1194` | 16 | 16 | 16 | 15 | 14 | **77** |
| 33 | Context and output model settings | Nested settings screen | `_ContextModelScreen` at `settings_screen.dart:1298` | 16 | 15 | 16 | 15 | 13 | **75** |
| 34 | Schedule editor/list | Route + sheet | `schedule_screen.dart:18-26`, edit sheet at `182-190` | 16 | 15 | 17 | 14 | 13 | **75** |
| 35 | Trajectory / event ledger | Route | `trajectory_screen.dart:15-23`, detail dialog at `59-61` | 16 | 15 | 17 | 11 | 13 | **72** |
| 36 | Subagent transcript | Route | `subagent_screen.dart:21-36`, push at `28-29` | 16 | 15 | 17 | 13 | 14 | **75** |
| 37 | Diff viewer | Embedded detail route | `_DiffViewerScreen` at `chat_screen.dart:4010` | 15 | 15 | 17 | 14 | 13 | **74** |
| 38 | HTML artifact viewer / fullscreen | Embedded viewer | `html_artifact_view.dart:16`, fullscreen route at `230-240` | 16 | 15 | 17 | 14 | 13 | **75** |
| 39 | GitHub login / device-code sheet | Modal sheet | `github_login_sheet.dart:14-30`, states at `162-172` | 16 | 15 | 17 | 15 | 14 | **77** |
| 40 | Plugin permission sheet | Modal sheet | `plugin_permission_sheet.dart:19-34`, capability rows at `253` | 17 | 16 | 17 | 15 | 14 | **79** |
| 41 | MCP OAuth sheet | Modal sheet | `mcp_oauth_sheet.dart:55-73` | 15 | 15 | 16 | 14 | 13 | **73** |
| 42 | Conversation share sheet | Modal sheet | `conversation_share_sheet.dart:15`, widget at `27-40` | 16 | 16 | 17 | 15 | 14 | **78** |
| 43 | Startup progress panel | Embedded progress widget | `startup_progress_panel.dart:82-115`, rows at `398` | 17 | 16 | 17 | 16 | 14 | **80** |
| 44 | Plugin install progress | Modal progress flow | `plugin_install_progress.dart:97`, sheet at `173-190` | 16 | 16 | 17 | 15 | 14 | **78** |
| 45 | Account deletion panel | Destructive task widget | `account_deletion_panel.dart:7-26` | 15 | 15 | 16 | 14 | 13 | **73** |

## Strengths by code evidence

### 1. Strong product frame and visual system

- `main.dart:98-103` makes the app entry predictable: authenticated users land
  in the chat shell, while login/configuration states are handled before it.
- `shell.dart:213-241` gives the same chat destination a desktop embedded sidebar
  and a mobile drawer, avoiding two separate information architectures.
- `sidebar.dart:69-87`, `214-268` uses a clear primary action and a consistent
  footer navigation band for Schedule, Trajectory, and Settings.
- `settings_screen.dart:38-44` and `59-240` show deliberate grouping rather
  than a flat preference dump. `AetherCard`, `AetherSectionTitle`, and shared
  action rows create a recognizable design language.
- `aether_primitives.dart:145-242`, `505-648`, and `861-908` provide shared
  cards, buttons, fields, status pills, and empty states, which is a better
  foundation than per-screen bespoke chrome.

### 2. High-quality handling in several complex workflows

- Chat applies user text scaling through `_ChatTextScaler` and bounds transcript
  width (`chat_screen.dart:62-73`, `124-135`), directly supporting readability.
- Studio documents and implements breakpoint-driven behavior: the file tree
  docks, overlays, or collapses by width/height (`studio_screen.dart:105-117`).
- Studio translates infrastructure failures into human-facing state while
  retaining detail (`studio_screen.dart:109-112`, `140-148`), and it exposes
  sync progress rather than only a spinner (`146-148`, `255-258`).
- Sandbox setup models real phases, progress, logs, partial completion, and
  gate-mode handoff (`sandbox_setup.dart:64-75`, `108-168`).
- Plugin/MCP surfaces distinguish unsupported, installed, enabled, migration,
  runtime, and credential states (`plugins_screen.dart:63-76`, `104-126`), a
  meaningful improvement over binary connected/disconnected UI.
- The shell surfaces failed session persistence with a durable warning banner
  (`shell.dart:17-45`, `91-99`, `227`), protecting user trust around chat history.

### 3. Good investment in explicit modal states

The GitHub sheet includes starting, code, done, expired, and error states
(`github_login_sheet.dart:162-172`). Plugin permission and install flows are
also separated into dedicated sheets rather than hiding consequential choices
inside a generic snackbar. This pattern should become the default for all
network, destructive, and runtime operations.

## Issues and score deductions

### P0 — Safety and data-loss risks

1. **Approval lock can be bypassed by the send button.** The previous file/line
   audit identifies `chat_screen.dart:1106-1107` and `4173-4186`: the text field
   is locked while approval is pending, but the circular send action does not
   enforce the same condition. This is the largest score deduction because it
   undermines an explicit safety gate.
2. **Session deletion lacks recovery.** `sidebar.dart:332-348` uses swipe-to-
   delete without confirmation or undo. A high-frequency navigation gesture
   should not irreversibly remove user history.
3. **Global stop scope is not obvious.** `chat_screen.dart:4177-4181` calls
   `cancelAllRuns()`, which can affect parallel sessions/subagents from a
   per-chat control. The action needs visible scope disclosure.

### P1 — Blank, stale, or silent states

4. **Browser zero-tab state is not robust.** The prior sweep flags
   `browser_screen.dart:325-333`: an empty `IndexedStack` and stale active index
   can create a blank or assertion-prone surface instead of a “new tab” state.
5. **Studio sync failure can disappear.** The earlier audit identifies a broad
   catch around `_autoSync` in `studio_screen.dart`; failure should leave a
   retryable inline state, not only a stopped spinner.
6. **Trajectory and Health lack complete failure coverage.** The previous audit
   points to `trajectory_screen.dart:30-39` and `health_screen.dart:81-110` as
   paths where thrown loads can leave stale content or an indefinite spinner.
7. **Plugin marketplace failure is too quiet.** `plugins_screen.dart` has a
   catalog whose sync failure should preserve the last-known catalog and expose
   a retry/status message.
8. **Plugin zero-results need an intentional empty state.** Search/filtering
   should explain whether the catalog is empty, filtered, unavailable, or still
   loading.

### P1 — Misleading or weak affordances

9. **Settings contains no-op or misleading rows.** The prior sweep found several
   rows that look interactive but have empty handlers, including appearance,
   voice, browser, notifications, and about-related controls. A disabled/info
   treatment or “coming soon” state is more honest than a tappable dead end.
10. **Voice status can contradict chat behavior.** The earlier audit cites a
    dead mic affordance in `chat_screen.dart:4130` alongside settings copy that
    advertises voice input as on.
11. **Studio’s first-open auth is interruptive.** The implementation deliberately
    triggers GitHub auth from the first-open flow (`studio_screen.dart:203-252`).
    A contextual connect CTA may preserve momentum better than an unsolicited
    modal.
12. **Destructive operations need consistent recovery language.** Account
    deletion, session deletion, storage clearing, and plugin deletion should all
    share confirmation, consequence, and post-action recovery conventions.

### P2 — Density, responsive, and accessibility debt

13. **Studio’s responsive model is strong but deserves runtime validation.** The
    code explicitly handles 840dp/600dp and short viewports, yet its editor/tree/
    terminal density makes this a high-risk surface for clipped content.
14. **Usage summary is vulnerable to narrow-width clipping.** The previous sweep
    identifies the four-expanded-stat row in `usage_screen.dart:206-217`.
15. **Approval details are truncated.** `chat_screen.dart:4853-4866` limits
    dangerous detail to eight lines without an obvious expand path.
16. **Large settings breadth increases scan cost.** The hub is well grouped, but
    it remains a long list with many nested destinations. Search, “recently
    changed,” or stronger summary state could reduce repeated scrolling.
17. **Modal surfaces need consistent keyboard and safe-area verification.** The
    code has strong examples such as `plugin_permission_sheet.dart:95-99` and
    `github_login_sheet.dart:163-170`, but not every sheet has the same visible
    evidence of scrollability, focus order, or keyboard avoidance.

## Top priorities

| Priority | Action | Why it matters | Primary evidence |
|---:|---|---|---|
| 1 | Enforce the approval lock in every send/queue path and make the blocked state explicit. | Prevents a safety gate from being bypassed. | `chat_screen.dart:1106-1107`, `4173-4186` |
| 2 | Add confirm/undo behavior for session deletion and unify destructive-action copy. | Protects conversation history and establishes a trustworthy interaction contract. | `sidebar.dart:332-348`; account/storage/plugin deletion surfaces |
| 3 | Give Browser a first-class zero-tab/new-tab state and clamp active-tab indices after close. | Removes blank-screen and assertion-risk behavior from a core destination. | `browser_screen.dart:151-154`, prior audit `325-333` |
| 4 | Replace silent catches and infinite spinners with retryable inline error states. | Makes Studio, Plugins, Health, and Trajectory diagnosable and recoverable. | `studio_screen.dart`; `plugins_screen.dart`; `health_screen.dart`; `trajectory_screen.dart` |
| 5 | Remove or relabel settings controls whose handlers do nothing, and reconcile voice status with actual chat behavior. | Stops users forming false expectations from the settings hub. | `settings_screen.dart`; prior sweep findings at settings `154-261` |
| 6 | Validate the 45 surfaces at 360×640, 420×1000, 720×1280, 780×1688, and 1024×768 with text scaling enabled. | Existing objective screenshot review found edge-touching heuristics on 7/15 captures; code review cannot establish visual clipping. | `docs/superpowers/audits/2026-10-06-ui-screenshot-review.md:41-57` |
| 7 | Add a common async-surface contract: loading, empty, error, retry, success, and persistence confirmation. | Reduces repeated screen-specific omissions and raises the entire 45-screen floor. | Cross-cutting: `AetherEmptyState`, startup panels, Studio, Health, Trajectory |
| 8 | Add route-level analytics or a route registry abstraction only if navigation breadth continues to grow. | The current push-based architecture works, but discoverability and route inventory are increasingly implicit. | `main.dart`; repeated `MaterialPageRoute` pushes |

## Recommended release gates for this UI set

Before calling the scorecard “release-ready,” verify the following as user
journeys rather than isolated widget snapshots:

1. A user with a pending approval cannot send, queue, or accidentally bypass the
   approval action.
2. A user can recover a deleted session or must explicitly confirm its permanent
   removal.
3. Opening Browser with no tabs produces a useful new-tab state; closing the
   final tab cannot leave a stale index.
4. Every network/runtime-backed destination has visible loading, empty, error,
   retry, and success states.
5. Every settings row either changes a value, navigates to a real surface, or is
   visibly informational/disabled.
6. The five gate states remain understandable when Firebase is unavailable,
   account setup is incomplete, or cloud binding fails.
7. The primary flows remain usable at the narrowest supported viewport with
   increased system text scale, keyboard open, and a long localized string.

## Audit conclusion

Ovid’s UI is beyond a prototype: the chat shell, Aether primitives, Studio,
sandbox, plugin, and auth surfaces demonstrate a consistent product direction
and meaningful state modeling. The **74/100** score reflects a system with good
foundations whose next gains come from trust mechanics—safe destructive actions,
explicit failures, truthful settings, and resilient boundary states—rather than
from adding more destinations or decorative polish.
