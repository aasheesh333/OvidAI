# Stitch → v2 parity review

Read-only review of the 47 Stitch reference screens in
`docs/design/stitch/stitch_ovid_si_ai_assistant/*/screen.png` against the v2
implementation in `lib/ui/v2/`. No Flutter source was edited for this review.

- Visual authority: `screen.png` (inspected directly) plus `code.html` (text
  extracted from every reference folder to catch copy and structure that the
  screenshot crops).
- Behavioural authority: `docs/design/stitch/V2_SCREEN_SPECS.md`.
- Code authority: the 47 screen files under `lib/ui/v2/` listed in the last
  column.

## Status after the 2026-10-22 minimal-UI pass

The review below was written against the pre-refactor tree. A reduction pass
then rewrote every screen to `docs/design/MINIMAL_UI_CONTRACT.md` — one header,
smaller copy, one action per zone, no decorative chrome — and wired the
components that had been sitting unimported. Two things changed for this
document:

- **Parity is no longer the goal.** Where the PNG and the contract disagree, the
  contract now wins by decision: the PNG's second title row, its version pill,
  its gradients, its 39 pill variants and its card-inside-card previews are gone
  on purpose. A row marked `close` because the implementation is *quieter* than
  the PNG is not a defect.
- **Several rows closed for a different reason than the one written.** They were
  re-judged on 2026-10-22; see
  [Rows re-judged in this pass](#rows-re-judged-in-this-pass) and
  [Defect status after the minimal-UI pass](#defect-status-after-the-minimal-ui-pass).

## Rubric

| Status | Meaning |
|---|---|
| **match** | Every element in the spec row that defines the screen is present, and the PNG differences are icon/label/copy/size only. Data-bound strings may come from the caller. |
| **close** | The screen is built and recognisably the same screen, but at least one PNG element that materially shapes it is missing, or the layout structure differs (missing tabs, grid, chart, gauge, action, or a whole preview surface). |
| **missing** | No implementation of the screen or of a spec-required block. |

A persistent bottom navigation bar is drawn in **11 of the 47** reference
PNGs — `Chat · Projects · Artifacts · Settings` on the two home chats, live
chat, model picker and drawer; `Chat · Studio · Browser · Connectors ·
Artifacts` on Studio, Browser, Connectors and the Artifacts Library; and
`Session · Trajectory · Share · Compute` in the collaboration room. v2 now draws
a bar of its own below 600 dp (`Chat · Studio · Browser · Library`, with
Settings reached from the drawer) and a rail above it, so the *structure* exists
even where the tab set differs. The bar is counted once under
[System-wide gaps](#system-wide-gaps) instead of being repeated in every row,
so the table below judges the screen body itself.

This is a structural/text comparison, not a pixel diff. Spacing, weight and
exact colour values were not measured; where the PNG and the spec disagree the
row names both.

Snapshot note: the parity table and the design-defect audit were first written
against the tree at **2026-10-21 12:26 UTC**. Everything marked as re-judged or
as fixed was re-checked against the code on **2026-10-22**. Rows not touched by
that pass still describe 2026-10-21 and should be re-checked before acting.

## Results

Totals over 48 rows covering 47 screens (the credentials PNG is one file that
the spec splits into two screens). After the 2026-10-22 re-judge: **30 match ·
17 close · 0 missing**, judged over 47 rows — was 30 · 18 · 0 over 48. Rows 23
and 28 moved to `match` because the components they were missing are now
imported; row 20 moved to `close` because the minimal-UI pass deliberately
dropped its ring and period tabs; row 13 dropped out because its screen no
longer exists (search is inline in the drawer).

### Rows re-judged in this pass

| # | Screen | Was | Now | Evidence |
|---|---|---|---|---|
| 13 | `ovid_si_search` | match | **removed** | `sidebar/search_page.dart` is gone. Search is a field at the top of the drawer that filters the session and project index in place; the contract's one-screen-one-job rule made a second navigation surface for the same data the wrong shape. |
| 16 | `ovid_si_artifact_detail` | close | close | `artifact_preview.dart` is now imported, so the stage renders a real thumbnail/code/document instead of a drawn mock. Still no device frame, no `Responsive View` header and no `Expand Frame`. |
| 20 | `ovid_si_usage` | match | **close** | The minimal-UI pass replaced the ring, the monthly quota bar and the Today/7/30 tabs with one hero number plus one chart. Deliberate reduction, not a regression. |
| 23 | `ovid_si_storage` | close | **match** | `storage_breakdown.dart` is imported; the legend now has Chats, Artifacts, Uploads, Memory, Cache and Previews — the PNG's four categories plus two. |
| 28 | `ovid_si_studio_workspace` | close | **match** | `file_tree.dart` (searchable tree) and `code_viewer.dart` (line-number gutter, diff kinds) are imported. The PNG's `Find / File / Folder` toolbar is now the tree's search field. |
| 31 | `ovid_si_live_preview` | close | close | `V2LivePreviewData` now has a `frame` field and the page renders a real image when one arrives, but no caller supplies one: `livePreviewDataFor` still returns `V2PreviewStatus.empty`. The screen can show real pixels; nothing produces them yet. |
| 32 | `ovid_si_autonomous_browser` | close | close | `viewport.dart` and `tab_strip.dart` are imported and `BrowserLivePage` feeds real tabs, url and frames, so the "No page open" dead end is gone. Still no fps label, no action log and no "Ovid is driving" card. |
| 39 | `ovid_si_schedule_runs` | close | close | `run_timeline.dart` is imported (outcome, Retry run, Open artifact). Still no large stat tiles and no upcoming-queue card. |
| 42 | `ovid_si_collaboration_live` | close | close | `turn_banner.dart` is imported and `Request turn` exists. Still no `Raise priority` and no Session/Trajectory/Share/Compute tabs. |

### Onboarding

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 1 | `ovid_si_splash` | close | PNG shows a `v2.4 Autonomous Engine` pill and an `Encrypted & Isolated Sandbox` footer line and **no** progress bar. Implementation shows the centred mark, "Ovid Si", `CHAT. CODE. CREATE.`, thin progress bar and a status label, with no version pill and no sandbox line. The progress bar is what the spec asks for, so the screen follows the spec over the PNG. | `lib/ui/v2/onboarding/splash_page.dart` |
| 2 | `ovid_si_sign_in` | match | — (implementation adds "Continue with phone"; the brief allows Google or phone only, so the Apple button in the PNG is kept *and* phone is added — see concerns) | `lib/ui/v2/onboarding/sign_in_page.dart` |
| 3 | `ovid_si_onboarding_welcome` | close | "Continue with Google" CTA between "Get started" and "I already have an account"; PNG's nested-ring orb with the small green dot. Implementation has the orb, engine pill, headline, subtitle, both spec CTAs, version + language pills and the terms line. | `lib/ui/v2/onboarding/onboarding_welcome.dart` |
| 4 | `ovid_si_language_goal` | match | — (goal cards are chips in both; PNG's per-card check marks are the selected state) | `lib/ui/v2/onboarding/language_goal_page.dart` |
| 5 | `ovid_si_paywall_upgrade` | match | Plan bullets follow the product truth ("Ovid Flash unlimited", "All Pro models") instead of the PNG's "Ovid Flash 2.5 unlimited" / "Pro 1.5 + the model Sonnet". INR prices and the USD/INR toggle are present, and the choice now persists. The `Compare all plans` button is **gone** rather than disabled: the paywall has no comparison surface, and `plan_compare_table.dart` lives on Plan & billing (row 19) where the comparison actually belongs. | `lib/ui/v2/onboarding/paywall_page.dart` |

### Chat

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 6 | `ovid_si_home_chat_2` | match | Top bar order matches the spec exactly (hamburger · `Auto ⌄` · "Ovid Si" · spacer · Studio · Browser · ⋮). PNG extras not required by the spec: notification bell + avatar, bottom nav. | `lib/ui/v2/chat/chat_page.dart` |
| 7 | `ovid_si_home_chat_1` | match | Same screen with a two-row app bar (title "Ovid Si"/"Chat", bell, avatar). The v2 bar merges those rows; the spec fixes the single-row order, so this variant is intentionally not reproduced. | `lib/ui/v2/chat/chat_page.dart` |
| 8 | `ovid_si_live_chat_artifacts` | close | Artifact card has no inline thumbnail, no "Interactive HTML5 Canvas" meta row, no **Preview** button and no copy control (only Download); no full-screen artifact preview sheet; thinking row collapses but does not list the "Decisions made" sub-bullets as a nested block. Everything else (user bubble right, markdown assistant text, tool card with progress, collapsed thinking, stop while running, "Ovid is generating code… Press stop to pause") is present. | `lib/ui/v2/chat/live_chat_page.dart` |
| 9 | `ovid_si_model_picker` | match | PNG section check-circles are the row selection state; presence of search, Auto card with "Recommended", standard/advanced groups, locked rows and "Manage models" all match. | `lib/ui/v2/chat/model_picker_sheet.dart` |
| 10 | `ovid_si_model_chip_menu` | match | "Compare plans" reads `From $18/mo` (spec Plus price) rather than the PNG's `$20/mo` — deliberate, documented in the group report. | `lib/ui/v2/chat/model_chip_menu.dart` |

### Navigation and library

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 11 | `ovid_si_navigation_drawer` | match | `⌘K` hint on the search row and the numeric badges (`Artifacts 12`) are not drawn; "New session" replaces "New chat" to obey the copy rule that "Chat" is the only product noun. Pinned/Projects/Today/Yesterday and the Schedule · Artifacts · Settings footer are all present (`Earlier` is added). | `lib/ui/v2/sidebar/sidebar.dart`, `lib/ui/v2/sidebar/sidebar_footer.dart` |
| 12 | `ovid_si_projects` | close | No "Sort by recent" control, and the "Active Workspaces · 3" header is replaced by a "Projects" section header with a count pill. Project cards omit the PNG's per-card status chips (`Active schedule`, `Cron: 00:00 UTC daily`, `v2.4 sync`, "Only you"/"Yesterday"); the new-project sheet has no `Step 1 of 2` header and no "Sync Vector Store" toggle. Present: explainer, filter + New, cards with shared/personal pill, chats/storage, member stack with `+N` and "Updated …", empty state, name + colour sheet. | `lib/ui/v2/sidebar/projects_page.dart` |
| 13 | `ovid_si_search` | n/a | Screen removed. Search is now a field at the top of the drawer that filters the session and project index in place; there is no separate results page. The contract's "one screen, one job" rule made a second navigation surface for the same data the wrong shape. | `lib/ui/v2/sidebar/sidebar.dart` |
| 14 | `ovid_si_session_actions_sheet` | match | The PNG shows the transcript behind the sheet; the v2 sheet shows title/time/message count/model in its own header. All actions, the Branch pill and the deletion footnote are present. | `lib/ui/v2/sidebar/session_actions_sheet.dart` |
| 15 | `ovid_si_artifacts_library` | match | Adds source chips (All/Generated/Uploaded) on top of the spec's kind chips, a library summary card and a per-card overflow menu. `See what Ovid can make` callout and the `New artifact` FAB are present. | `lib/ui/v2/library/artifacts_page.dart` |
| 16 | `ovid_si_artifact_detail` | close | The page now renders through the shared `library/artifact_preview.dart` with the artifact's real thumbnail (image), code or document stage. Still missing: a device frame, the `Responsive View` / `Live Preview · 100% Retina` header and `Expand Frame`. Details grid, tabs, Download, Share link, Open in Studio and source-chat row are present. | `lib/ui/v2/library/artifact_detail_page.dart` |

### Settings

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 17 | `ovid_si_settings_hub` | match | Exact section order and row ids enforced by `_canonicalOrder`; profile card with plan pill, "Add" on Connectors, "Show reasoning" switch, and "Log out of …" present. PNG's "Display & Graphics" app-bar title is a Stitch leftover. | `lib/ui/v2/settings/settings_hub.dart` |
| 18 | `ovid_si_account` | match | Fields are injected (`V2AccountField`) and currently wired to display name + email; avatar, connected Google/GitHub rows (Apple is not a provider, so it is not drawn), Credentials row, Sign out and the delete flow are present. Phone, language and region fields the PNG lists are not wired, so they do not render. | `lib/ui/v2/settings/account_page.dart` |
| 19 | `ovid_si_plan_billing` | match | Current plan card, upgrade cards, USD/INR + monthly/yearly, "Most popular", Restore purchases, legal line. Adds a plan-limits table and payment history. | `lib/ui/v2/settings/plan_billing_page.dart` |
| 20 | `ovid_si_usage` | close | The ring, the Today/7/30 tabs and the monthly quota bar are gone by decision: the screen is now one hero number ("Tokens today", its cap and the reset) plus one activity chart and the per-model split. Everything it says is real; it is quieter than the PNG. PNG model names (`GPT-4o / Mini`, `the model Sonnet`) were always caller data. | `lib/ui/v2/settings/usage_page.dart` |
| 21 | `ovid_si_memory` | close | "Context Accuracy Rating 88%" ring card is absent; the PNG's dismissible (×) notice has no close affordance. Toggle, global memory with Edit, project rows, session files with download, Export memory and Reset all memory are present (plus Share session memory). | `lib/ui/v2/settings/memory_page.dart` |
| 22 | `ovid_si_data_control` | match | Intro + last-backup line, export/import with size limits, Permissions, Crash reports toggle, Storage row with percentage, Delete your data, Reset memory, confirm dialog. | `lib/ui/v2/settings/data_control_page.dart` |
| 23 | `ovid_si_storage` | close | Legend differs: PNG is Chats / Artifacts / Memory / Previews, the page shows Artifacts / Sessions / Cache (previews appear only as a "Clear previews" row). `settings/storage_breakdown.dart` already implements the four PNG categories but is **not imported by any page**. Adds "Items by size" and "Trash" rows. Donut, used/free line, Clear previews, Delete old chats and the Go/Plus upgrade block are present. | `lib/ui/v2/settings/storage_page.dart`, unwired `lib/ui/v2/settings/storage_breakdown.dart` |
| 24 | `ovid_si_appearance` | match | System/Light/Dark preview cards (System default), 4 accent dots with violet selected, text-size slider, Reduce motion, High contrast, live preview card, "These settings apply to this device". Adds density, code font and voice language. The fourth accent is amber where the PNG shows coral. | `lib/ui/v2/settings/appearance_page.dart` |
| 25 | `ovid_si_credentials_account_health` (credentials half) | match | Protected & Encrypted hero, Google, GitHub OAuth, masked PAT with Add/Replace, Revoke all with confirm. Adds browser logins with masked passwords. | `lib/ui/v2/settings/credentials_page.dart` |
| 26 | `ovid_si_credentials_account_health` (health half) | match | "All systems normal", continuous scan, last security check, active sign-ins with Review/Revoke, zero-knowledge note. Adds a security score, service status and region support. | `lib/ui/v2/settings/account_health_page.dart` |

### Studio

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 27 | `ovid_si_studio_repo_picker` | match | Connect GitHub hero, "Pick a repository to start", "Ovid copies it to your private cloud workspace…", repo list with search, personal-token row, Advanced options, read-only security note. | `lib/ui/v2/studio/repo_picker_page.dart` |
| 28 | `ovid_si_studio_workspace` | close | Explorer toolbar is missing: no `Find`, `File`, `Folder` actions above the tree; the editor has no line-number gutter (PNG 01–14). `studio/file_tree.dart` (searchable tree) and `studio/code_viewer.dart` (line numbers, diff kinds) exist but are **not imported**. Repo/branch chips, sync banner + "Sync latest changes", tree, editor with filename/Saved/Copy, live-workspace note and the 3-files-changed / Commit / Preview dock are present. | `lib/ui/v2/studio/studio_workspace_page.dart`, unwired `lib/ui/v2/studio/file_tree.dart`, `lib/ui/v2/studio/code_viewer.dart` |
| 29 | `ovid_si_branch_picker` | match | Search, "Switch branch", current branch with "Default · Synced with remote / Active", recent branches with last-commit labels, Create new branch, stash note. | `lib/ui/v2/studio/branch_picker_sheet.dart` |
| 30 | `ovid_si_changes_diff` | match | "3 changed · +48 −12", expandable files, unified diff with old/new line numbers and green/coral rows, per-hunk Copy, commit message with counter, Commit & push, "Sync latest first · N behind". | `lib/ui/v2/studio/changes_page.dart` |
| 31 | `ovid_si_live_preview` | close | The phone frame renders a **synthesised** marketing page from injected fields (`siteName`, `eyebrow`, `primaryCta`, `featureTitle`…). `V2LivePreviewData` has no frame/thumbnail field at all, so no real preview pixels can ever reach this screen — every live preview reads as demo content. Refresh/open-in-browser, url chrome, "Live · Preview from workspace", expiry + "+30 min", Share link and Stop preview are present. | `lib/ui/v2/studio/live_preview_page.dart` |

### Browser

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 32 | `ovid_si_autonomous_browser` | close | No live page render: the page uses its own placeholder slot (`viewportChild ?? _ViewportPlaceholder()`) and the route is opened with an empty `V2BrowserData()`, so in-app it lands on the "No page open" empty state. `browser/viewport.dart` (frame + agent cursor + take-control overlay + fps strip) and `browser/tab_strip.dart` exist but are **not imported** — the page still carries its own `_TabStrip`. Tab strip with the **disabled** `+` ("Ovid opens tabs"), read-only address with lock/copy, "4 fps" label, action log, "Ovid is driving" card, Stop and Take control are present. | `lib/ui/v2/browser/browser_page.dart`, unwired `lib/ui/v2/browser/viewport.dart`, `lib/ui/v2/browser/tab_strip.dart` |
| 33 | `ovid_si_browser_take_control` | match | Countdown pill, scrim, "You can tap, type, and scroll…", Show keyboard, Trackpad, Start controlling, Stay watching, resume note; adds a "What pauses" list and a session-ended state. | `lib/ui/v2/browser/take_control_sheet.dart` |

### Connectors

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 34 | `ovid_si_connectors` | close | `Installed (n)` / `Available (n)` tabs match the design's tab pair, and Available rows carry a per-row `Add`. Missing: the 2-column "Popular Connectors" grid with `+ Connect` tiles — Available is one flat catalogue list. Search, installed toggles with Connected/Paused, connected-first ordering, the plan note and Upgrade are present. | `lib/ui/v2/connectors/connectors_page.dart` |
| 35 | `ovid_si_connector_detail` | match | Icon, Connected pill, description, account/synced row, permission checklist, "Used by" main agent + subagents with access labels, automatic sync, Disconnect with consequence copy; adds Tools, Usage and Recent activity cards. | `lib/ui/v2/connectors/connector_detail_page.dart` |
| 36 | `ovid_si_add_connector` | match | Catalog suggestions with Add, custom name + server URL/command, auth chips (OAuth / API key / None), Test connection, Read / Write / Execute switches, trust warning and the plan-limit line. Adds a "Plugins are added here, not in chat" block. | `lib/ui/v2/connectors/add_connector_page.dart` |

### Schedules

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 37 | `ovid_si_schedules` | close | No total-rule summary (`4 total rules`) above the groups, and no "No custom schedules yet?" CTA card at the bottom of a populated list (the CTA only appears in the empty state). Explainer, Active/Paused groups, human rule, next run, toggle, Paused pill and the failed + Retry block are present. | `lib/ui/v2/schedules/schedules_page.dart` |
| 38 | `ovid_si_schedule_editor` | match | Prompt + "Natural instructions", Once/Daily/Weekly/Custom, run time, day chips with "Runs Mon – Fri", timezone, notify toggle, plain preview sentence, Save. Adds a description field and source-session row. | `lib/ui/v2/schedules/schedule_editor_page.dart` |
| 39 | `ovid_si_schedule_runs` | close | No large `24` / `23` stat tiles (the summary is a single sentence plus a success bar), no "Upcoming scheduled queue" card, and no "Inspect log trace" link in the failed-run diagnostic. `schedules/run_timeline.dart` (per-run outcome, Retry run, Open artifact) exists but is **not imported**; the page has its own cards. Grouped days, All/Succeeded/Failed filters, failed expand + Retry now, result preview, Open chat and View artifact are present. | `lib/ui/v2/schedules/schedule_runs_page.dart`, unwired `lib/ui/v2/schedules/run_timeline.dart` |

### Share and collaboration

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 40 | `ovid_si_share_sheet` | match | Link + Copy, "Anyone with the link can view", "Show my name", WhatsApp/Gmail/Slack/More targets, Stop sharing, "never includes your files or connectors". Adds a Collab/Read only mode selector and a fork note for viewers. | `lib/ui/v2/share/share_sheet.dart` |
| 41 | `ovid_si_share_chat_sheet` | match | Wraps the generic sheet with the chat title, "can view or fork it" and the fork-into-your-account note; same toggles and targets. Telegram is not a separate target (grouped under More). | `lib/ui/v2/share/share_chat_sheet.dart` |
| 42 | `ovid_si_collaboration_live` | close | No `Raise priority` action anywhere, no "Request turn" that also shows the estimated wait, and no Session/Trajectory/Share/Compute tab bar. `collab/turn_banner.dart` (turn holder, position-in-line, queue rows, one-at-a-time note) exists but is **not imported**. Members + `+46`, typing banner, pinned "Only one person can send at a time", multi-speaker transcript, tool result card, storage pill, disabled composer with "Wait for the turn" and queue list are present. | `lib/ui/v2/collab/collab_live_page.dart`, unwired `lib/ui/v2/collab/turn_banner.dart` |
| 43 | `ovid_si_collab_members` | match | "50 of 50 members", search, Owner/Can chat/View only roles, `(you)` marker, creator-pays-storage card with percentage, Leave chat and its consequence line. Adds a Room full / seats-left tag and turn-queue note. | `lib/ui/v2/collab/collab_members_page.dart` |

### Runs and subagents

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 44 | `ovid_si_run_trajectory_1` | close | No "Collapse all" control for the step list (and `runs/timeline.dart`, which has per-item expand/collapse, is **not imported**; the page draws its own rail). Timeline steps, sources chips, file chip, preview thumb, per-step durations, expandable detail, footer model/tokens/duration, Share run and the "no raw JSON" treatment are present. | `lib/ui/v2/runs/run_trajectory_page.dart`, unwired `lib/ui/v2/runs/timeline.dart` |
| 45 | `ovid_si_run_trajectory_2` | close | Alternate composition (pipeline checklist + inline code snippet + metrics panel) is not reproduced; the same data renders through the single timeline layout. `Copy snippet`, `Execution Metrics` and `Rerun task` (the screen has "Run again") are absent as distinct elements. | `lib/ui/v2/runs/run_trajectory_page.dart` |
| 46 | `ovid_si_subagent_card` | close | No "Context window 128k / 200k" gauge; console stream is a log preview list rather than the PNG's full-width `Subagent console stream` card with `View full log (42 lines)` (v2 has "View full log (N lines)" + "Read full log"). Working dot, name, instance, progress, step, pace, elapsed, 8 h limit, files chips, task summary, Stop subagent and "Subagents cannot start other subagents." are present. | `lib/ui/v2/runs/subagent_page.dart` |
| 47 | `ovid_si_subagent_detail` | close | Same file, same gaps: no context-window gauge; the PNG's `Started` / `Time limit` / `Files touched` tiles are a details card rather than tiles. Adds a ≤300-token JSON summary block that the PNG does not show. | `lib/ui/v2/runs/subagent_page.dart` |

### States

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 48 | `ovid_si_system_states` | match | Four framed states — empty chat ("Start with a hello" + Try an example prompt), offline ("Your messages will send when you reconnect" + Retry connection), error (Try again + View error details), daily limit (resets pill + See plans) — plus the calm footer note. | `lib/ui/v2/states/system_states_page.dart` |

## System-wide gaps

> Re-checked 2026-10-22 after the minimal-UI pass. Items 1, 3 and 6 are closed;
> the original finding is kept where it still explains the reference.

1. ~~**No bottom navigation anywhere.**~~ **Closed.** `lib/ui/v2/app/bottom_nav.dart`
   draws the persistent bar below 600 dp and `v2_app_shell.dart` swaps it for a
   fixed 280 dp rail (600–899 dp) or 300 dp rail (900 dp+) above that — one
   navigation per band, never two. `v2ChatNavItems` and `v2WorkNavItems` cover
   both reference tab sets. The collaboration room's
   `Session · Trajectory · Share · Compute` bar is still not reproduced.
2. **No notification or avatar entry point in the v2 top bars.** The PNGs show
   a bell and an avatar on Chat, Studio, Browser, Connectors and Artifacts;
   v2 routes those through the drawer profile row only.
3. ~~**Browser is routed empty.**~~ **Closed.** `v2_work_routes.dart` pushes
   `BrowserLivePage`, which subscribes to the browser client and feeds
   `BrowserPage` the real tab list, url, frame and take-control state. With no
   session it lands on the honest "No page open" state instead of a placeholder
   slot.
4. **Preview surfaces.** Live preview (screen 31) can now render a real frame —
   `V2LivePreviewData.frame` exists and the page draws it — but no producer
   supplies one, so in the app it stays in its waiting state. The artifact stage
   (screen 16) now uses the shared `artifact_preview.dart` with the artifact's
   real thumbnail when there is one. Neither has a device frame or
   `Responsive View` chrome, which is now a deliberate choice.
5. **Copy that must not be copied from the PNGs.** The references contain
   `Claude 3.7 Sonnet`, `GPT-4o / Mini`, `$20/mo`, `10 GB` Go storage and
   `SSH keys`; the brief fixes these to plan-defined values and forbids
   third-party model names. Rows marked `match` follow the brief, not the PNG.
6. ~~**Parity components exist that no page imports.**~~ **Closed.** Every
   component listed below is now imported by a screen or a route; a scan of all
   132 files under `lib/ui/v2/` leaves only the entry points (`v2_app_shell`,
   `v2_onboarding_gate`, `app_lock_gate`, the gallery) and two `_io.dart` saver
   helpers without a screen import, which is correct. The table is kept as the
   record of what each one closed:

   | Unwired component | Would close |
   |---|---|
   | `browser/viewport.dart`, `browser/tab_strip.dart` | live frame, agent cursor, fps strip, stream-lost retry (row 32) |
   | `library/artifact_preview.dart` | thumbnail/page artifact stage (row 16) |
   | `studio/file_tree.dart`, `studio/code_viewer.dart` | searchable tree and line-number gutter (row 28) |
   | `studio/commit_sheet.dart`, `studio/studio_gate.dart` | commit sheet for Changes (row 30), studio gate |
   | `runs/timeline.dart` | per-step expand/collapse rail (row 44) |
   | `schedules/run_timeline.dart` | run outcome, Retry run, Open artifact (row 39) |
   | `collab/turn_banner.dart` | turn holder, position in line, queue rows (row 42) |
   | `settings/storage_breakdown.dart` | Chats / Artifacts / Memory / Previews legend (row 23) |
   | `settings/plan_compare_table.dart` | "Compare all plans" (row 5) |
   | `settings/usage_charts.dart` | usage chart variants (row 20) |
   | `library/artifact_filters.dart` | artifact filter chips (row 15) |
   | `schedules/cadence_picker.dart` | Once/Daily/Weekly/Custom control (row 38) |
   | `states/state_tiles.dart` | offline / plan limit / storage full / suspended tiles (row 48) |
   | `runs/subagent_summary.dart` | ≤300-token contract block (rows 46–47) |
   | `sidebar/project_memory_editor.dart` | project memory editing (row 12) |
   | `sidebar/search_filters.dart` | search filter surface (row 13) |
   | `sidebar/sidebar_footer.dart` | footer destinations (row 11 already has a local copy) |
   | `share/share_link_card.dart` | share link card (rows 40–41) |
   | `chat/permission_sheet.dart`, `chat/composer_plus_sheet.dart`, `chat/model_chip.dart` | composer `+`, permission chip, model chip (rows 6–8) |
   | `onboarding/purchase_banner.dart`, `onboarding/step_progress.dart`, `onboarding/phone_auth_sheet.dart` | purchase banner, step progress, phone sign-in (rows 1–5) |
   | `settings/settings_search.dart`, `settings/export_picker_sheet.dart`, `settings/confirm_typed_sheet.dart` | settings search, export picker, typed confirm (settings rows) |
   | `settings_extra/legal_page.dart` | legal document page (not in the PNG set) |
   | `connectors/connector_permissions.dart`, `connectors/catalog_data.dart` | permission editor and catalog seed (rows 34–36) |

   `sidebar/search_filters.dart` was deleted together with the standalone
   search screen; filtering now lives in the drawer's search field.

   As of 2026-10-22 every other row in this table is imported, including
   `chat/message_blocks.dart` and `chat/queue_dock.dart`.

## Concerns

1. ~~**Bottom nav needs a decision, not a screen fix.**~~ **Settled.** The shell
   owns it: a bottom bar below 600 dp, a 280 dp rail from 600 dp and a 300 dp
   rail from 900 dp, with the drawer removed above 600 dp so there is never a
   second navigation.
2. **The wiring pass is done; what is left is genuinely missing service
   surface.** The remaining `close` gaps need a producer, not more UI: projects
   sort/status chips, the memory accuracy card, schedules' total and CTA, run
   stat tiles and the upcoming-queue card, the collab raise-priority action,
   and a real live-chat artifact thumbnail.
3. **Artifact card in live chat.** The PNG's thumbnail + Preview + Copy is what
   makes generated output feel real; v2 opens the artifact detail (chevron) and
   offers Download, with no inline thumbnail and no Copy.
4. **Sign-in: Apple and the email form are both gone.** `onApple` was never
   passed by `v2_onboarding_gate.dart`, and the email/password field, "Forgot
   password" and "Create account" only set the inline error "Use Google or
   phone to sign in." Both were removed under the contract's no-control-without-
   a-service rule; the step now offers Google (filled) and phone (outlined).
5. **Splash parity is spec-driven.** It has a progress line and no version
   pill / sandbox badge, which is correct per the spec row even though it does
   not resemble the PNG. Do not "fix" it toward the PNG without amending the
   spec.
6. **Method limit.** This review compares structure and copy from PNG +
   `code.html` + source. It does not measure spacing, radii, weights or
   contrast, and it does not assert that the screens survive 320 dp /
   200 % text — the per-group tests and `a11y_ratchet_test.dart` own that.

---

# Design defects found

Read-only audit of every `lib/ui/v2/**` screen against the shared design layer
in `lib/ui/design/**`, run after the parity pass above. It answers a different
question from the parity table: not "is the Stitch element present" but "did
copying the Stitch element break the design system". Fixes are limited to
`lib/ui/design/**`; anything that needs a screen edit is marked **no** and
listed again under [Screen-level work still open](#screen-level-work-still-open).

Method: static scan of all 115 files under `lib/ui/v2` (`grep` for literals,
`OPressable`/`OCard`/pill class inventory) plus contrast computed with
`OContrast.ratio` — translucent tokens are composited over the surface they are
painted on before measuring, so the numbers below are what the eye sees, not
the raw hex pair.

## Summary

| # | Class | Findings | Fixed in `lib/ui/design/` |
|---|---|---|---|
| 1 | Spacing off the `OSpace` scale | 5 recurring literals, 168 sites | tokens added |
| 2 | Colours outside `OColors` | 1 | no (screen) |
| 3 | Type sizes bypassing `OType` | 5 | yes (design's own 2) |
| 4 | Radius bypassing `ORadius` | 20 | token added + 1 fixed |
| 5 | Touch targets under 48 dp | 2 | yes (1 of 2) |
| 6 | Contrast failures | 4 pairs | yes (token) |
| 7 | Duplicate components | 39 pills, 5 sheet headers, 3 section headers, 10 cards, 1 merged action | yes (OPill) |
| 8 | Stitch-specific mistakes | 7 | 1 (popup shadow) |

## Defect status after the minimal-UI pass

The table above is the audit as it was run. The pass that followed rewrote every
screen, so this is the state of each finding on 2026-10-22 (re-checked against
the code, not assumed):

| # | Class | State | Evidence |
|---|---|---|---|
| 1 | Spacing off the `OSpace` scale | **mostly fixed** | Design layer uses the new tokens. Screen-side literals fell from 168 to **18** `EdgeInsets` sites; 6 of those are `OSpace` values written as numbers (16/8/4) and 12 are 1–5 dp optical nudges. |
| 2 | Colours outside `OColors` | **1 remains** | `app/v2_settings_actions.dart:629` still has `TextStyle(color: Colors.red)` on a destructive dialog button. |
| 3 | Type sizes bypassing `OType` | **fixed** | Only two `fontSize:` overrides survive: `fontSize: 1` on the deliberately invisible OTP field, and `fontSize: 13` on one artifact filter chip. `TextScaler.noScaling` is gone. `OType.bodySm.copyWith(fontWeight: w600)` → 0 sites (`bodySmStrong`). |
| 4 | Radius bypassing `ORadius` | **12 remain** | Down from 20. All `BorderRadius.circular(2)` / `(3)` on bars, swatches and thumbnails; `ORadius.xs` exists for exactly this case. |
| 5 | Touch targets under 48 dp | **fixed** | `OButton.compact` keeps a 48 dp height in the design layer and `_MemoryChip` was deleted with the drawer rewrite. |
| 6 | Contrast failures | **fixed** | `OContrast.audit` now measures 34 pairs per theme and all pass; `test/design` is green (64 tests). |
| 7 | Duplicate components | **fixed** | Zero screen-local `_Tag/_Pill/_Badge/_Card/_Section/_Header/_Chip/_Row` classes remain; `test/design/no_local_primitives_test.dart` enforces it with an **empty** allowlist. 41 `OPill`, 65 `OCard`, 13 `OSheetHeader` call sites. |
| 8 | Stitch-specific mistakes | **1 remains** | Connector hero, paywall radial glow, splash halo, `OShadow.glow` and the popup drop shadow are all gone. `settings/usage_page.dart:337` still sets the daily token count in `OType.display`. |

### Screen-level list, item by item

| Was | State |
|---|---|
| Connector detail centred `h1` hero | **fixed** — name is the header title, body leads with a status row |
| `_MemoryChip` 22 dp hit area | **fixed** — widget deleted |
| `model_chip` `fontSize: 10` + `noScaling` | **fixed** — badge uses `OType.caption` |
| `Colors.red` in the destructive confirm | **remains** |
| 39 local pill classes + 4 chips + 5 sheet headers + hand-rolled cards | **fixed** — shared primitives, ratcheted |
| Paywall radial glow | **fixed** — no gradient anywhere in `lib/ui/v2` |
| Usage hero at `OType.display` | **remains** |
| 20 radius literals, 9 one-off spacings | **partly** — 12 radius, 18 `EdgeInsets` |
| 68 `bodySm` + w600 overrides, 168 literal spacings | **fixed** for the type half, mostly fixed for spacing |

## 1. Spacing that is not on the `OSpace` scale

The scale had `4 / 8 / 12 / 16 / 24 / 32 / 48` and nothing else, so every
sub-4 dp optical measurement and every component inset was a bare literal. Four
values account for almost all of it:

| Value | Sites | Token now | Worst offenders |
|---|---|---|---|
| `2` | **107** | `OSpace.xxs` | `lib/ui/v2/settings/account_page.dart:786`, `lib/ui/v2/connectors/connector_detail_page.dart:1133`, `lib/ui/v2/runs/subagent_page.dart:725`, `lib/ui/v2/app/bottom_nav.dart:153`, `lib/ui/v2/connectors/add_connector_page.dart:1072,1077` |
| `6` | **27** | `OSpace.iconGap` | `lib/ui/v2/onboarding/paywall_page.dart:365,410,566`, `lib/ui/v2/onboarding/onboarding_welcome.dart:274,313,354`, `lib/ui/v2/runs/run_trajectory_page.dart:755`, `lib/ui/v2/library/artifacts_page.dart:895-899` |
| `10` | **20** | `OSpace.pillPad` | `lib/ui/v2/chat/model_chip.dart:101`, `lib/ui/v2/sidebar/sidebar.dart:497`, `lib/ui/v2/sidebar/session_actions_sheet.dart:352,386`, `lib/ui/v2/collab/collab_members_page.dart:501`, `lib/ui/v2/chat/model_picker_sheet.dart:665`, `lib/ui/v2/studio/branch_picker_sheet.dart:380` |
| `14` | 6 | `OSpace.controlPad` | `lib/ui/v2/runs/run_trajectory_page.dart:745`, `lib/ui/v2/connectors/connectors_page.dart:659`, `lib/ui/v2/library/artifact_filters.dart:526`, `lib/ui/v2/browser/take_control_sheet.dart:173` |

One-off values with no token and no pattern to justify one — **screen owner**
must move these to the nearest scale value:

| File:line | Value | Nearest token |
|---|---|---|
| `lib/ui/v2/settings/appearance_page.dart:1305` | `EdgeInsets.all(7)` | `OSpace.s` (8) |
| `lib/ui/v2/chat/model_chip.dart:165` | `horizontal: 5, vertical: 1` | `OSpace.xs` (4) / `OSpace.xxs` |
| `lib/ui/v2/chat/chat_page.dart:1094` | `EdgeInsets.only(top: 3, right: OSpace.s)` | `OSpace.xs` (4) |
| `lib/ui/v2/settings/usage_charts.dart:714` | `only(top: 5)` | `OSpace.xs` (4) |
| `lib/ui/v2/studio/studio_workspace_page.dart:507` | `only(top: 5)` | `OSpace.xs` (4) |
| `lib/ui/v2/studio/studio_workspace_page.dart:720` | `symmetric(horizontal: OSpace.m, vertical: 1)` | `OSpace.xxs` (2) |
| `lib/ui/v2/app/app_lock_gate.dart:434` | `horizontal: 5` | `OSpace.xs` (4) |
| `lib/ui/v2/collab/turn_banner.dart:603` | `horizontal: 6, vertical: 1` | `OSpace.iconGap` / `OSpace.xxs` |
| `lib/ui/v2/settings_extra/notifications_page.dart:996` | `left: 18 + OSpace.m` | `OSpace.xxl` (32) or `OSpace.iconTile + OSpace.m` |

Design-layer status: `OSpace.xxs`, `OSpace.iconGap`, `OSpace.pillPad`,
`OSpace.controlPad`, `OSpace.buttonPad` (20) and `OSpace.iconTile` (36) added;
`o_components.dart` and `o_theme.dart` now use them instead of `2 / 6 / 10 /
14 / 20 / 36 / 12 / 4`. The 168 screen sites still hold literals because they
are outside this task's files.

## 2. Colours outside the token set

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/v2/app/v2_settings_actions.dart:570` | `const TextStyle(color: Colors.red)` on the destructive confirm button. It ignores both themes (Material red is #F44336, not `OColors.danger`). It is the only non-transparent `Colors.*` value and the only raw colour in `lib/ui/v2` — `grep 'Color(0x' lib/ui/v2` returns **0** hits and every other `Colors.` hit is `Colors.transparent`. Should be `OColors.of(dialogContext).danger`. | no |

`lib/ui/design/o_theme.dart:57` sets `ColorScheme.shadow: const Color(0xFF000000)`.
That is Material plumbing (there is no `OColors.shadow`), not a painted app
colour, so it is left as is.

## 3. Type sizes that bypass `OType`

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/v2/chat/model_chip.dart:178,181` | Subagent-count badge is `TextScaler.noScaling` + `fontSize: 10`. It is the only text in the app below the 11 sp floor **and** the only text that refuses to scale — at 200 % text it stays 10 px. Should be `OType.caption` (12) and scale with the rest. | no |
| `lib/ui/v2/chat/model_chip.dart:123` | `OType.label.copyWith(fontSize: 13)` — a size that is not a rung. | no |
| `lib/ui/v2/settings_extra/notifications_page.dart:828` | `fontSize: 13` on a body label. | no |
| `lib/ui/v2/library/artifact_filters.dart:614` | `fontSize: 13` on a chip label. | no |
| `lib/ui/v2/onboarding/phone_auth_sheet.dart:742` | `fontSize: 1` — an invisible OTP field. Intentional, not a defect. | no |
| `lib/ui/design/o_components.dart:68` (was) | `OButton` compact label overrode `OType.label` to 13. | **yes** |
| `lib/ui/design/o_components.dart:467` (was) | `OChip` label overrode `OType.label` to 13. | **yes** |

The root cause was a missing rung, not the call sites: 68 places write
`OType.bodySm.copyWith(fontWeight: FontWeight.w600)`. `OType.bodySmStrong`
(14 sp / w600 / 1.45) is now part of the scale, so those become a plain token
reference.

## 4. Radius values that bypass `ORadius`

`ORadius` had no rung below 8, so 19 sites invented `2` or `3` for mini bars,
thumbnails and legend swatches, and one invented `4`:

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/v2/settings/appearance_page.dart:1314,1324,1335,1344` | `BorderRadius.circular(2)` / `(3)` on theme-preview bars | no |
| `lib/ui/v2/library/artifacts_page.dart:641,714,729` | `circular(2)` / `(3)` on thumbnails and bars | no |
| `lib/ui/v2/studio/commit_sheet.dart:183,545` | `circular(2)` / `(3)` | no |
| `lib/ui/v2/settings/storage_breakdown.dart:584` | `circular(3)` legend swatch | no |
| `lib/ui/v2/schedules/schedule_runs_page.dart:322` | `circular(3)` | no |
| `lib/ui/v2/studio/changes_page.dart:425` | `circular(3)` | no |
| `lib/ui/v2/library/artifact_preview.dart:548` | `circular(2)` | no |
| `lib/ui/v2/chat/voice_reply_card.dart:405` | `circular(2)` | no |
| `lib/ui/v2/browser/take_control_sheet.dart:113` | `circular(2)` | no |
| `lib/ui/v2/settings/confirm_typed_sheet.dart:194` | `circular(2)` | no |
| `lib/ui/v2/sidebar/project_memory_editor.dart:463` | `circular(2)` | no |
| `lib/ui/v2/onboarding/phone_auth_sheet.dart:334` | `circular(2)` | no |
| `lib/ui/v2/studio/branch_picker_sheet.dart:116` | `circular(2)` | no |
| `lib/ui/v2/collab/collab_live_page.dart:540` | `Radius.circular(4)` on the message bubble corner — should be the new `ORadius.xs` | no |
| `lib/ui/design/o_components.dart:1052` (was) | `showOSheet` grabber: a 4 dp bar with `circular(2)`. | **yes** — now `ORadius.pill` |

`ORadius.xs` (4 dp) added for the thumbnail/bar case. A 4–6 dp bar that should
read as a stadium uses `ORadius.pill`, never a literal.

## 5. Touch targets under 48 dp

The screens are mostly disciplined here — `OChip`, `OIconButton`, `OListRow`,
`_SourceChip`, `_CategoryChip`, `_GoalChip`, `_LanguagePill` and the browser
tab strip all wrap their visual in an explicit `minHeight: OSpace.touch`. Two
real offenders:

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/v2/sidebar/sidebar.dart:760-813` | `_MemoryChip` is an interactive `OPressable` whose entire hit area is the 22 dp chip (`minHeight: 22`, `vertical: 2`). It is the smallest target in the app and it opens the memory editor. Needs the `_SourceChip` treatment (`ConstrainedBox(minHeight: OSpace.touch)` around the 22 dp visual). | no |
| `lib/ui/design/o_components.dart:40` (was) | `OButton(size: OButtonSize.compact)` was **44 dp** tall, used by 9 screens (`settings/credentials_page.dart:560,880,887`, `schedules/schedules_page.dart:225`, `studio/repo_picker_page.dart:412`, …). The brief's 48 dp floor applies to every interactive element. | **yes** — compact now keeps a 48 dp height and gets its compactness from 12 dp horizontal padding |

## 6. Contrast

Measured with `OContrast.ratio`; `accentSoft` and the 12 % status tints are
composited over the surface before measuring. Rows in **bold** failed.

| Pair | Light | Dark | Gate | Verdict |
|---|---|---|---|---|
| `text` on `surface` | 18.69 | 18.04 | 4.5 body | pass |
| `textMuted` on `surface` | 6.70 | 7.11 | 4.5 body | pass |
| `textFaint` on `surface` | 5.26 | 3.73 | 3.0 large | pass, **not body-safe in dark** |
| `textFaint` on `surfaceRaised` | 4.39 | 3.23 | 3.0 large | pass, **not body-safe** |
| `accent` on `surface` | 6.49 | 10.59 | 4.5 body | pass |
| `accent` on `accentSoft` (over `surface`) | 5.80 | 9.45 | 4.5 body | pass |
| `textMuted` on `accentSoft` (over `surface`) | 5.99 | 6.34 | 4.5 body | pass |
| `onAccent` on `accentFill` | 5.79 | 4.62 | 4.5 body | pass (was 4.35 dark) |
| `onDanger` on `danger` | 4.83 | 6.62 | 4.5 body | pass |
| `success` on `surface` | 4.72 | 9.39 | 3.0 graphic | pass (was 3.39 light) |
| `success` on `surfaceAlt` | 4.19 | 8.91 | 3.0 graphic | pass (was 3.01 light) |
| `success` on `surfaceRaised` | 3.94 | 8.13 | 3.0 graphic | pass (was 2.83 light) |
| `success` on its 12 % tint (`OPill.success`) | 4.02 | 7.56 | 3.0 large | pass (was 2.95 light) |
| `warn` on `surfaceRaised` | 4.19 | 9.36 | 3.0 graphic | pass |
| `danger` on `surfaceRaised` | 4.03 | 5.65 | 3.0 graphic | pass |
| `danger` on its 12 % tint | 4.03 | 5.53 | 3.0 large | pass |

Four pairs failed before this audit, all in the token layer:

| Change | Before → after | Effect |
|---|---|---|
| `dark.accentFill` `#7C5CFF` → `#7857FA` (and `accentSoft` re-derived as `0x1F7857FA`) | white label 4.35 → **4.62** | primary labels clear AA body in dark and the pill tint matches the fill again; the Stitch hue is preserved |
| `light.success` `#0E9F6E` → `#0B8457` | pill 2.95 → **4.02**, `surfaceRaised` 2.83 → **3.94**, `surfaceAlt` 3.01 → **4.19**, `surface` 3.39 → **4.72** | every green status label, dot and icon clears 3:1 on every surface |

Two body-size uses of the faint token were the real cause of the "faint text"
complaint and are fixed in the theme, not by lightening the token:

* `lib/ui/design/o_theme.dart:136` — the input **hint** was `OType.body` (16 sp)
  in `textFaint` (3.73:1 in dark, under the 4.5:1 body gate). Now `textMuted`.
  `textFaint` stays the 3:1 token for 11–12 sp captions, chevrons and icons, so
  the hierarchy survives.

`OContrast.audit` now measures 34 pairs per theme (was 21): `accent` and
`textMuted` on `accentSoft`, `success`/`warn`/`danger` on all three card
surfaces, and each `OPill` tint under its own label. The old
`dark/accentFill/onAccent` known gap is closed and its entry deleted.

## 7. Inconsistent component usage

`OPill` exists, is correct, and is used 67 times — but 39 screen-local classes
re-implement it. Three of them are verbatim copies of its tone `switch`:

| Duplicate | file:line | Why it is a duplicate |
|---|---|---|
| `_Tag` | `lib/ui/v2/collab/collab_members_page.dart:479` | same 5-tone switch, same 24 dp min height, same pill radius, same dot — an exact `OPill` |
| `_Tag` | `lib/ui/v2/chat/model_picker_sheet.dart:647` | same switch, same `OType.caption w600`, only the padding differs |
| `_PlanTag` | `lib/ui/v2/chat/model_chip_menu.dart:214` | same switch, same tokens, one less `vertical` |

The rest are the same job with a different inset, icon or tone source:
`_PlanPill` (`sidebar.dart:487`), `_MemoryChip` (`sidebar.dart:760`),
`_VersionPill` (`onboarding_welcome.dart:290` — its own doc comment says it
"mirrors `OPill`"), `_EnginePill` (`:253`), `_LanguagePill`
(`onboarding_welcome.dart:329` and `sign_in_page.dart:517` — two copies),
`_HeroPill` (`paywall_page.dart:544`), `_PopularBadge` (`:800`),
`_TrailingPill` (`session_actions_sheet.dart:377`), `_MetricPill`
(`model_picker_sheet.dart:690`), `_SubagentCountBadge` (`model_chip.dart:154`),
`_NoPromptsTag` (`permission_sheet.dart:373`), `_SummaryChip`
(`subagent_summary.dart:350`), `_WorkingPill` (`subagent_page.dart:325`),
`_FileChip` (`:484`), `_MetricTile` (`:528`), `_SourceChip`
(`run_trajectory_page.dart:734`), `_LiveChip` (`live_preview_page.dart:894`),
`_BindingChip` (`studio_workspace_page.dart:398`), `_SyncChip` (`:546`),
`_MetaPill` (`code_viewer.dart:585` **and** `changes_page.dart:782`),
`_StatusBadge` (`repo_picker_page.dart:1040`), `_ActiveBadge`
(`branch_picker_sheet.dart:372`), `_TreeBadge` (`file_tree.dart:624`),
`_HeadlessBadge` (`tab_strip.dart:360`), `_ControllingBadge`
(`viewport.dart:745`), `_InfoChip` (`control_bar.dart:269`), `_CountBadge`
(`connectors_page.dart:529`), `_StoragePill` (`collab_live_page.dart:727`),
`_TimeLeftPill` (`turn_banner.dart:530`), `_CountdownPill`
(`take_control_sheet.dart:163`).

**Which survives: `OPill`.** It gained the two things the copies had that it
lacked — an optional leading `icon` and an optional `semanticLabel` override —
so `_PopularBadge` (star icon), `_FileChip`, `_LiveChip`, `_SyncChip` and
`_MetricPill` can collapse into it with no API loss. `_MetricPill` keeps a
coloured value; that is a different widget (a stat), not a tag.

Same pattern in three other places:

| Duplicate | file:line | Survives |
|---|---|---|
| `_CategoryChip`, `_GoalChip`, `_AttachmentChip`, `_ToolChip` | `connectors_page.dart:617`, `language_goal_page.dart:576`, `composer_attachments.dart:251`, `take_control_sheet.dart:391` | `OChip` — all four are a 48 dp tappable label with a selected state. `_CategoryChip` differs only in using `ORadius.pill` instead of `ORadius.m`, so the *same* filter chip looks like a chip on one screen and a pill on another. Pick one radius on `OChip` and delete all four. |
| `_Section` | `runs/subagent_summary.dart:317` | `OSectionHeader` — it hand-rolls the uppercase `overline` + trailing meta. `sidebar.dart:317` already delegates to `OSectionHeader` correctly and is the pattern to copy. |
| `_Header` | `session_actions_sheet.dart:273`, `export_picker_sheet.dart:378`, `composer_plus_sheet.dart:279`, `project_memory_editor.dart:361`, `phone_auth_sheet.dart:468` | the `title` block inside `showOSheet` (`o_components.dart:1059`) — five sheets draw their own title row instead of passing `title:` to `showOSheet`. |
| `_CurrentBranchCard`, `_SelectedRepoCard`, `_SyncFirstCard`, `_StorageCard` (×2), `_DrivingCard`, `_StreamLostPanel`, `_LanguageCard`, `_PlanCard` | `branch_picker_sheet.dart:290`, `repo_picker_page.dart:576`, `commit_sheet.dart:636`, `project_detail_page.dart:434`, `collab_members_page.dart:532`, `browser_page.dart:471`, `viewport.dart:628`, `language_goal_page.dart:466`, `paywall_page.dart:583` | `OCard` — each hand-rolls `surface` + `ORadius.l` + `hairline`, which is exactly `OCard`. `_SectionCard` (`settings_hub.dart:446`) shows the right shape: `OCard(padding: EdgeInsets.zero, child: rows)`. |

### Nested action merged into its parent's semantics node

Found while checking whether the overflow menus on cards are reachable:

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/design/o_components.dart:153` (was) | `OButton` and `OIconButton` wrapped their `Semantics` without `container: true`, so a button nested inside a tappable `OCard`/`OPressable` had its label merged into the parent's node and its tap action swallowed by the parent. The projects card proved it: the whole card became one node labelled `"Mobile App Redesign\nShared\n12 chats · 340 MB\nProject options for Mobile App Redesign"` with a single tap action — a screen reader could not open the overflow menu at all, and `test/v2/navigation/projects_page_test.dart` could not find the button. | **yes** — both now declare `container: true`, so the card keeps its own label and the menu keeps its own node |

## 8. Stitch-specific mistakes

| File:line | Defect | Fixed in design/? |
|---|---|---|
| `lib/ui/v2/connectors/connector_detail_page.dart:751-770` | **Hero card in a settings-style detail page.** Connector name at `OType.h1` (28 sp), centred, over a centred `bodySm` description inside a circle-icon card — while every other block on the same page (permissions, tools, usage, activity, sync) is left-aligned. This is the clearest "followed the Stitch screen too literally" case: a list detail got a marketing hero. Should be a left-aligned `h2` row with a 36 dp icon tile. | no |
| `lib/ui/v2/onboarding/paywall_page.dart:283` | **Decorative radial gradient.** A 280×200 `RadialGradient` accent glow behind the hero, with a comment admitting it is "the only gradient on this screen". Nothing else in the app glows. | no |
| `lib/ui/v2/onboarding/splash_page.dart:65` | Second decorative `RadialGradient` (the orb halo). Defensible as brand art, but it is the only other one and it is not a token. | no |
| `lib/ui/v2/browser/viewport.dart:832` | `OShadow.glow` — a violet halo on the take-control badge. Every other surface in v2 is flat (`grep BoxShadow lib/ui/v2` → only `OShadow.floating`/`sheet` on overlays). | no (token documented as legacy) |
| `lib/ui/design/o_theme.dart:245` (was) | `popupMenuTheme.elevation: 8` — the only drop shadow in the design system, against `elevation: 0` on app bar, sheets, buttons and cards. | **yes** — elevation 0 + hairline |
| `lib/ui/v2/settings/usage_page.dart:405-420` | **Oversized hero stat.** The daily token count is `OType.display` at `w700` inside a 200 dp ring — the largest type in the app used for a number, not a heading. | no |
| `lib/ui/v2/onboarding/paywall_page.dart:320` | `OType.display` centred heading. Acceptable for a marketing paywall, listed for completeness. | no |

Centred body copy: apart from the connector hero above, the remaining
`TextAlign.center` uses are legitimate (empty states via `OEmptyState`, the
splash/welcome/sign-in heroes, and one-line footnotes under centred cards).
No true **card-inside-card** was found in v2 chrome — the nested surfaces are
inside the synthesised phone preview (`live_preview_page.dart:814`) and the
collab message bubble (`collab_live_page.dart:540`), both intentional.

## Verification

Re-run 2026-10-22 after the minimal-UI pass:

```
flutter analyze                        → No issues found! (27.3 s)
flutter test                           → 4,599 passed, 2 skipped, 0 failed
flutter test test/design               → 64 tests, All tests passed!
flutter test test/v2/navigation        → 102 tests, All tests passed!
flutter test test/v2/a11y_ratchet_test.dart
                                       → 100 tests, All tests passed!
                                         (50 screens × light/dark at 320 dp /
                                          200 % text)
flutter test test/v2/semantics_audit_test.dart
                                       → 113 tests, All tests passed!
                                         (empty known-gaps map)
flutter test test/v2/header_consistency_test.dart
test/v2/responsive_audit_test.dart
test/design/no_local_primitives_test.dart
                                       → green
```

`flutter test` is green end to end (4,599 passed, 2 skipped, 0 failed). Earlier
in the same pass the text-budget word ceiling and one Language & goal semantics
assertion were red; both were fixed before this run.

`test/design` was updated alongside the tokens because it pinned the old
palette: `o_theme_test.dart` asserted `dark.accentFill == 0xFF7C5CFF` and a
4.3 floor, and `o_contrast_test.dart` carried a `knownGaps` entry for
`dark/accentFill/onAccent`. Both now assert the new values (4.62:1, ≥ 4.5) and
the gap map is empty.

### Concurrency note

The original audit ran while `lib/ui/design/**` was being edited by another
agent. That is no longer the case: the design layer is now stable and the
minimal-UI pass is the last writer to every file under `lib/ui/v2/`. The one
piece of that concurrent work still worth knowing about is that `OAppBar` and
`OScaffold` carry explicit `Semantics(sortKey:)` ordering — the reading-order
tests depend on it.

## Screen-level work still open

Ordered by user-visible impact. Every item is outside `lib/ui/design/**`, and
each one is a *defect*, not a missing feature.

1. `lib/ui/v2/app/v2_settings_actions.dart:629` — `Colors.red` → `c.danger`.
   It is the last raw colour in `lib/ui/v2` and ignores both themes.
2. `lib/ui/v2/settings/usage_page.dart:337` — step the daily token count down
   from `OType.display`; it is the largest type in the app used for a number.
3. The 12 remaining radius literals (`BorderRadius.circular(2)`/`(3)` on bars,
   swatches and thumbnails) — `ORadius.xs` is the token for exactly this.
4. The 12 one-off spacing literals (1–5 dp optical nudges in
   `appearance`-style rows, `code_viewer`, `commit_sheet`, `cadence_picker`,
   `artifact_filters`, `tab_strip`) and the 6 `OSpace` values written as numbers
   in the route builders.
5. `lib/ui/v2/library/artifact_filters.dart:615` — `fontSize: 13` → `OType.label`.

Fixed by the pass, kept here so the list is not re-opened: the connector hero,
`_MemoryChip`, the model-chip badge, all 39 local pill classes and the other
duplicate primitives, the paywall glow, the splash halo, `OShadow.glow`, the
popup drop shadow, and the 68 `bodySm`+w600 overrides.
