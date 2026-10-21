# Ovid Si v2 — screen specs

One row per built screen. The PNG is the visual authority; this table is the
behavioural authority. Read the row and the PNG together. All copy is English
and plain; no jargon.

| # | Target file | Reference folder | Must include |
|---|---|---|---|
| 1 | `onboarding/splash_page.dart` | `ovid_si_splash` | Centred mark, "Ovid Si", "Chat. Code. Create.", thin progress line. No actions. Soft violet halo only. |
| 2 | `onboarding/sign_in_page.dart` | `ovid_si_sign_in` | Google, Apple, email + password with show toggle, "Sign in", "Forgot password?", "Create an account", language selector. Loading + error states. |
| 3 | `onboarding/onboarding_welcome.dart` | `ovid_si_onboarding_welcome` | Headline "Your always-on personal agent.", subtitle, orb, "Get started", "I already have an account". |
| 4 | `onboarding/language_goal_page.dart` | `ovid_si_language_goal` | Progress dots, language grid English / हिन्दी / ਪੰਜਾਬੀ / தமிழ், goal chips, sticky Continue. |
| 5 | `onboarding/paywall_page.dart` | `ovid_si_paywall_upgrade` | Go $5/₹499, Plus $18/₹1,799 (Most popular), Pro $99/₹9,999; USD/INR toggle; trial CTA; Google Play note; compare plans. |
| 6 | `chat/chat_page.dart` | `ovid_si_home_chat_2` | Top bar exactly `☰ · Auto ⌄ · Ovid Si · spacer · Studio · Browser · ⋮`. Empty state "What should we build today?" + 3 suggestions. Composer: +, General chip, mic, send. Thin "Auto · 50M tokens left today" row. |
| 7 | `chat/live_chat_page.dart` | `ovid_si_live_chat_artifacts` | User bubble right, assistant markdown, tool card with progress, collapsed thinking row, artifact card with download, stop button while running. |
| 8 | `chat/model_picker_sheet.dart` | `ovid_si_model_picker` | Search, highlighted Auto card "best for most tasks", model rows, paid rows locked with "Plus plan", "Manage models". Free plan note. |
| 9 | `chat/model_chip_menu.dart` | `ovid_si_model_chip_menu` | Compact menu: Auto checked, three locked rows, "Manage models", "Compare plans". |
| 10 | `sidebar/sidebar.dart` | `ovid_si_navigation_drawer` | Profile + "Free plan" pill, New chat, Search, PINNED, PROJECTS, TODAY / YESTERDAY, footer Schedule · Artifacts · Settings. |
| 11 | `sidebar/projects_page.dart` | `ovid_si_projects` | Explainer, project cards with chats/storage/avatars, Shared pill, empty state, New project sheet (name + colour). |
| 12 | `sidebar/search_page.dart` | `ovid_si_search` | Recent searches, grouped Chats / Projects / Artifacts, highlighted matches, empty + suggestion chips. |
| 13 | `sidebar/session_actions_sheet.dart` | `ovid_si_session_actions_sheet` | Pin, Rename, Move to project, Share, Duplicate, Export markdown, Delete (danger). Footnote about deleting files + memory. |
| 14 | `settings/settings_hub.dart` | `ovid_si_settings_hub` | Exact order — Account: Account, Plan & billing, Usage, Credentials. Chat: Appearance, Memory, Shared memory, Memory files, Show reasoning. Models: Connectors (+), Agent presets, Response wait limit. Data control: Export or import, Permissions, Crash reports, Storage, Delete data, Reset memory. Advanced: Notifications, Account health, About. |
| 15 | `settings/account_page.dart` | `ovid_si_account` | Avatar + change photo, name/email/phone/language/region, connected Google/Apple, Sign out, Delete account. |
| 16 | `settings/plan_billing_page.dart` | `ovid_si_plan_billing` | Free current card ($0, 3 GB, Auto only), 4 plan cards, USD/INR toggle, "Most popular" on Plus, Restore purchases, legal. |
| 17 | `settings/usage_page.dart` | `ovid_si_usage` | Ring "12.4M of 50M tokens used today", reset countdown, month bar 1.5B, Today/7/30 tabs, bar chart, model split, "Free plan uses Auto only." No money. |
| 18 | `settings/memory_page.dart` | `ovid_si_memory` | Memory toggle, global memory preview + Edit, project memory rows, session files, Export memory, Reset all memory (danger). |
| 19 | `settings/data_control_page.dart` | `ovid_si_data_control` | Export/import (64 MB · 1,000 sessions · 20,000 messages), Permissions, Crash reports toggle, Storage bar, Delete your data, Reset memory. |
| 20 | `settings/storage_page.dart` | `ovid_si_storage` | Donut 1.2/3 GB, legend Chats/Artifacts/Memory/Previews, Clear previews, Delete old chats, Trash, Go upgrade CTA. |
| 21 | `settings/appearance_page.dart` | `ovid_si_appearance` | **System (default) / Light / Dark** segmented with previews, accent dots (violet selected), text size slider, Reduce motion, High contrast, live preview card. |
| 22 | `settings/credentials_page.dart` | `ovid_si_credentials_account_health` | Google, GitHub, personal access token (masked + Add), Revoke all. |
| 23 | `settings/account_health_page.dart` | `ovid_si_credentials_account_health` | "All systems normal", last security check, sign-in devices + Review. |
| 24 | `studio/repo_picker_page.dart` | `ovid_si_studio_repo_picker` | Connect GitHub, explanation "Ovid copies it to your private cloud workspace", repo list with search, PAT advanced row, empty. |
| 25 | `studio/studio_workspace_page.dart` | `ovid_si_studio_workspace` | Repo + branch chips, sync banner "Remote has 3 new changes — Sync latest changes", file tree, editor, status Saved, "3 files changed", Commit, Preview. |
| 26 | `studio/branch_picker_sheet.dart` | `ovid_si_branch_picker` | Search, Current main, branches with last commit, Create new branch, stash note. |
| 27 | `studio/changes_page.dart` | `ovid_si_changes_diff` | "3 changed · +48 −12", expandable files, unified diff green/coral, message field, Commit & push, Sync latest first. |
| 28 | `studio/live_preview_page.dart` | `ovid_si_live_preview` | Phone frame preview, refresh, open in browser, "Live · Preview from your workspace", share link, stop, expires timer. |
| 29 | `browser/browser_page.dart` | `ovid_si_autonomous_browser` | Tab strip (plus disabled with "Ovid opens tabs"), read-only address with lock, page viewport, "Ovid is driving", "Take control", "watching live · 4 fps". |
| 30 | `browser/take_control_sheet.dart` | `ovid_si_browser_take_control` | Countdown "Ovid paused · 4:59", Start controlling, Stay watching, keyboard/trackpad, scrim. |
| 31 | `connectors/connectors_page.dart` | `ovid_si_connectors` | Search, Installed/Available tabs, installed rows with toggles, Popular 2-col grid, plan note "Free 0 · Go 5". |
| 32 | `connectors/connector_detail_page.dart` | `ovid_si_connector_detail` | Icon, Connected pill, description, permission checklist, Disconnect (danger), Used by main agent + subagents. |
| 33 | `connectors/add_connector_page.dart` | `ovid_si_add_connector` | Catalog suggestions, custom name/URL/auth chips/key, Test connection, Read/Write/Execute switches, trust warning, plan limit. |
| 34 | `library/artifacts_page.dart` | `ovid_si_artifacts_library` | Filter chips All/Images/Documents/Code/Data, 2-col cards, FAB New artifact, empty with "See what Ovid can make". |
| 35 | `library/artifact_detail_page.dart` | `ovid_si_artifact_detail` | Preview, filename/type/size/date, Preview/Details tabs, Download, Share link, Open in Studio, source chat. |
| 36 | `schedules/schedules_page.dart` | `ovid_si_schedules` | Explainer, schedule cards with human rule + next run + toggle, Paused pill, failed + Retry, empty Create. |
| 37 | `schedules/schedule_editor_page.dart` | `ovid_si_schedule_editor` | Prompt, Once/Daily/Weekly/Custom, time, day chips, timezone, notify toggle, plain preview sentence, Save. |
| 38 | `schedules/schedule_runs_page.dart` | `ovid_si_schedule_runs` | "24 runs · 23 succeeded · 1 failed", grouped rows, failed expand + Retry now, result preview + Open chat, empty. |
| 39 | `share/share_sheet.dart` | `ovid_si_share_sheet` | Link + Copy, "Anyone with the link can view", "Show my name", targets WhatsApp/Gmail/Slack/More, Stop sharing, "never includes files or connectors". |
| 40 | `share/share_chat_sheet.dart` | `ovid_si_share_chat_sheet` | Chat variant: read-only link, fork-into-own-account note, same toggles/targets. May wrap the generic sheet. |
| 41 | `collab/collab_live_page.dart` | `ovid_si_collaboration_live` | Avatars + "+46", typing banner, multi-speaker transcript, pinned "Only one person can send at a time", greyed send + "Wait for the turn", "50 members · Creator pays storage". |
| 42 | `collab/collab_members_page.dart` | `ovid_si_collab_members` | "50 of 50 members", search, roles Owner/Can chat/View only, you highlighted, creator pays storage, Leave chat. |
| 43 | `runs/run_trajectory_page.dart` | `ovid_si_run_trajectory_1` | Timeline steps, source chips, file chip, preview thumb, durations, expandable detail, footer model/tokens/duration, Share run. No raw JSON by default. |
| 44 | `runs/subagent_page.dart` | `ovid_si_subagent_card` | Working dot, name, progress, started/time limit 8h/files chips, task summary, log preview + View full log, Stop subagent, "Subagents cannot start other subagents." |
| 45 | `states/system_states_page.dart` | `ovid_si_system_states` | Four framed states: empty chat, offline (messages send later + Retry), error (Try again), daily limit (resets + See plans). Calm, never alarming. |

## Shared data contracts

Keep these shapes stable so wiring is mechanical:

- Plans: `id, name, priceUsd, priceInr, storageGb, autoOnly, popular`.
- Sessions: `id, title, updatedAt, modelLabel, pinned, projectId`.
- Projects: `id, name, chatCount, storageLabel, shared`.
- Models: `id, name, subtitle, speed, costHint, locked`.
- Connectors: `id, name, description, connected, category`.
- Artifacts: `id, name, kind, createdAt, sizeLabel, thumbnail`.
- Schedules: `id, title, rule, nextRun, enabled, lastRunFailed`.
- Runs: `id, steps[], model, tokens, duration`.
- Collab members: `id, name, role, isYou`.
- Share state: `link, anyoneCanView, showName, active`.

## Copy rules

- "Chat", "Project", "Connector", "Schedule", "Artifact" are the only product
  nouns. Never say MCP, PAT, branch protection, token bucket.
- A limit always says what happens next: "Resets in 6h 12m", "Upgrade to add
  connectors", "Messages will send when you reconnect".
- Danger copy names the consequence: "Deleting removes this chat's files and
  memory from the cloud."
