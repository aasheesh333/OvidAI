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
`Session · Trajectory · Share · Compute` in the collaboration room. None of
them exist in v2. The bar is counted once under
[System-wide gaps](#system-wide-gaps) instead of being repeated in every row,
so the table below judges the screen body itself.

This is a structural/text comparison, not a pixel diff. Spacing, weight and
exact colour values were not measured; where the PNG and the spec disagree the
row names both.

Snapshot note: this worktree is shared with other P3 agents. Several
`lib/ui/v2/**` files were being edited while this review ran; findings reflect
the tree at **2026-10-21 12:26 UTC**. Re-check a row before acting on it.

## Results

Totals over 48 rows covering 47 screens (the credentials PNG is one file that
the spec splits into two screens): **30 match · 18 close · 0 missing**.

### Onboarding

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 1 | `ovid_si_splash` | close | PNG shows a `v2.4 Autonomous Engine` pill and an `Encrypted & Isolated Sandbox` footer line and **no** progress bar. Implementation shows the centred mark, "Ovid Si", `CHAT. CODE. CREATE.`, thin progress bar and a status label, with no version pill and no sandbox line. The progress bar is what the spec asks for, so the screen follows the spec over the PNG. | `lib/ui/v2/onboarding/splash_page.dart` |
| 2 | `ovid_si_sign_in` | match | — (implementation adds "Continue with phone"; the brief allows Google or phone only, so the Apple button in the PNG is kept *and* phone is added — see concerns) | `lib/ui/v2/onboarding/sign_in_page.dart` |
| 3 | `ovid_si_onboarding_welcome` | close | "Continue with Google" CTA between "Get started" and "I already have an account"; PNG's nested-ring orb with the small green dot. Implementation has the orb, engine pill, headline, subtitle, both spec CTAs, version + language pills and the terms line. | `lib/ui/v2/onboarding/onboarding_welcome.dart` |
| 4 | `ovid_si_language_goal` | match | — (goal cards are chips in both; PNG's per-card check marks are the selected state) | `lib/ui/v2/onboarding/language_goal_page.dart` |
| 5 | `ovid_si_paywall_upgrade` | match | Plan bullets follow the product truth ("Ovid Flash unlimited", "All Pro models") instead of the PNG's "Ovid Flash 2.5 unlimited" / "Pro 1.5 + the model Sonnet". INR prices and the USD/INR toggle are present. `Compare all plans` renders disabled: no caller passes `onComparePlans` and `settings/plan_compare_table.dart` is not wired. | `lib/ui/v2/onboarding/paywall_page.dart` |

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
| 13 | `ovid_si_search` | match | "Best matches" label, grouped Chats/Projects/Artifacts, highlighted matches, recent searches with Clear all, no-results copy and suggestion chips all present. The PNG's `Simulate "No Results" Variant` block is a design artefact, not UI. | `lib/ui/v2/sidebar/search_page.dart` |
| 14 | `ovid_si_session_actions_sheet` | match | The PNG shows the transcript behind the sheet; the v2 sheet shows title/time/message count/model in its own header. All actions, the Branch pill and the deletion footnote are present. | `lib/ui/v2/sidebar/session_actions_sheet.dart` |
| 15 | `ovid_si_artifacts_library` | match | Adds source chips (All/Generated/Uploaded) on top of the spec's kind chips, a library summary card and a per-card overflow menu. `See what Ovid can make` callout and the `New artifact` FAB are present. | `lib/ui/v2/library/artifacts_page.dart` |
| 16 | `ovid_si_artifact_detail` | close | No device-framed live HTML render, no `Responsive View` / `Live Preview · 100% Retina` header and no `Expand Frame`. The page draws its own compact stage (image/code/document); `library/artifact_preview.dart` would close most of this (it accepts a `pageThumbnail`) but is **not imported by any page**. Details grid, tabs, Download, Share link, Open in Studio and source-chat row are present. | `lib/ui/v2/library/artifact_detail_page.dart`, unwired `lib/ui/v2/library/artifact_preview.dart` |

### Settings

| # | Screen | Status | Missing vs PNG | Owning file |
|---|---|---|---|---|
| 17 | `ovid_si_settings_hub` | match | Exact section order and row ids enforced by `_canonicalOrder`; profile card with plan pill, "Add" on Connectors, "Show reasoning" switch, and "Log out of …" present. PNG's "Display & Graphics" app-bar title is a Stitch leftover. | `lib/ui/v2/settings/settings_hub.dart` |
| 18 | `ovid_si_account` | match | Fields are injected (`V2AccountField`) rather than hard-coded labels, so name/email/phone/language/region come from wiring; avatar + change photo, linked Google/Apple/GitHub with "N of M linked", Credentials row, Sign out and the 24 h delete flow are present. | `lib/ui/v2/settings/account_page.dart` |
| 19 | `ovid_si_plan_billing` | match | Current plan card, upgrade cards, USD/INR + monthly/yearly, "Most popular", Restore purchases, legal line. Adds a plan-limits table and payment history. | `lib/ui/v2/settings/plan_billing_page.dart` |
| 20 | `ovid_si_usage` | match | Ring `12.4M of 50M`, reset countdown, monthly quota bar, Today/7/30 tabs, bar chart, per-model split and the "Free plan uses Auto only" note are all present. PNG model names (`GPT-4o / Mini`, `the model Sonnet`) are caller data, not copy in the screen. | `lib/ui/v2/settings/usage_page.dart` |
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
| 34 | `ovid_si_connectors` | close | No `Installed (3)` / `Available (37)` tab pair and no 2-column "Popular Connectors" grid with `+ Connect` tiles; v2 uses a category strip and flat rows split into "Connectors" and "Plugins & MCP". Search, installed toggles with Connected/Paused, connected-first ordering, the plan note and Upgrade are present. | `lib/ui/v2/connectors/connectors_page.dart` |
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

1. **No bottom navigation anywhere.** 11 of 47 PNGs draw a persistent bar
   (4-tab `Chat · Projects · Artifacts · Settings`; 5-tab
   `Chat · Studio · Browser · Connectors · Artifacts` on Studio, Browser,
   Connectors, Artifacts Library; and `Session · Trajectory · Share · Compute`
   in the collaboration room). `lib/ui/design/` has no nav component and
   `lib/ui/v2/app/v2_app_shell.dart` only provides a drawer plus app-bar
   actions. This is the single largest structural difference between the
   references and v2.
2. **No notification or avatar entry point in the v2 top bars.** The PNGs show
   a bell and an avatar on Chat, Studio, Browser, Connectors and Artifacts;
   v2 routes those through the drawer profile row only.
3. **Browser is routed empty.** `lib/ui/v2/app/v2_work_routes.dart:89` pushes
   `BrowserPage(data: V2BrowserData())` with no session source, so screen 32
   can never reach its content state in the app, and the viewport is a
   placeholder slot even when it does.
4. **Preview surfaces are synthesised, not rendered.** Live preview
   (screen 31) composes injected marketing fields and its data model has no
   frame field, and the artifact stage (screen 16) draws its own compact mock
   instead of the unwired `artifact_preview.dart` that accepts a page
   thumbnail. Neither screen can show a real page image today.
5. **Copy that must not be copied from the PNGs.** The references contain
   `Claude 3.7 Sonnet`, `GPT-4o / Mini`, `$20/mo`, `10 GB` Go storage and
   `SSH keys`; the brief fixes these to plan-defined values and forbids
   third-party model names. Rows marked `match` follow the brief, not the PNG.
6. **Parity components exist that no page imports.** As of
   **2026-10-21 12:26 UTC**, 33 untracked component files under `lib/ui/v2/`
   have no `import` anywhere. The tree is being edited by other P3 agents while
   this review runs, so re-check before acting. The ones that map to a table row:

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

   Only `chat/message_blocks.dart` and `chat/queue_dock.dart` from that wave are
   imported by a page. Adopt these before writing more UI, otherwise the same
   gaps get implemented twice.

## Concerns

1. **Bottom nav needs a decision, not a screen fix.** It is owned by the shell
   and `lib/ui/design/`, both outside the per-screen files. Until it exists,
   every top-level screen is one drawer gesture away from the reference
   behaviour.
2. **The wiring pass is the highest-leverage next step.** 33 component files are
   unimported (gap 6); several `close` rows would move to `match` with no
   new UI. The remaining `close` gaps are genuinely absent UI: projects sort
   control, memory accuracy card, connectors tabs + popular grid, schedules
   total/CTA, run stat tiles + upcoming-queue card, explorer toolbar, collab
   raise-priority, and the live-chat artifact thumbnail/Preview.
3. **Artifact card in live chat is the weakest content screen.** The PNG's
   thumbnail + Preview + Copy is what makes generated output feel real; v2
   offers Download only.
4. **Sign-in offers Google, phone and Apple.** The brief says Google or phone
   only; the PNG shows Apple. Both are shipped in
   `sign_in_page.dart`, which is a product-truth question for whoever owns
   onboarding, not a visual-parity one.
5. **Splash parity is spec-driven.** It has a progress line and no version
   pill / sandbox badge, which is correct per the spec row even though it does
   not resemble the PNG. Do not "fix" it toward the PNG without amending the
   spec.
6. **Method limit.** This review compares structure and copy from PNG +
   `code.html` + source. It does not measure spacing, radii, weights or
   contrast, and it does not assert that the screens survive 320 dp /
   200 % text — the per-group tests and `a11y_ratchet_test.dart` own that.
