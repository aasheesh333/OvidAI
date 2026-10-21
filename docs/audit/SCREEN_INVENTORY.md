# Screen inventory (canonical)
50 parsed screen blocks in `lib/ui/v2/v2_registry.dart` (51 native ids; 50 carry a builder). 88 entries in the web gallery (`v2_registry_web.dart`) = these 51 plus 37 component/sheet previews.

## Identity
- `splash` — Splash — Mark, tagline, startup progress and a retry path
- `sign_in` — Sign in — Email, password, Google, Apple and inline errors
- `welcome` — Welcome — First-run introduction with language choice
- `language_goal` — Language & goal — Hindi, Hinglish, Punjabi, Tamil plus what to build first
- `paywall` — Paywall — Free, Go, Plus and Pro with monthly/yearly and INR

## Chat
- `chat` — Chat (empty) — Top bar, model chip, suggestions and composer
- `live_chat` — Live chat — Transcript, thinking, tools, artifacts and stop
- `model_picker` — Model picker — Auto recommendation, search and locked paid models
- `model_chip` — Model chip menu — Quick model switch from the top bar
- `system_states` — System states — Plan limit, offline, error and empty variants

## Navigation
- `sidebar` — Sidebar — Profile, new chat, pinned, projects and sessions
- `projects` — Projects — Shared projects, storage and member stacks
- `session_actions` — Chat actions — Pin, rename, move, share, duplicate, export and delete

## Work
- `repo_picker` — Studio repo picker — GitHub connection and repository choice
- `studio_workspace` — Studio workspace — File tree, editor, sync and changes
- `branch_picker` — Branch picker — Switch or create a branch with a stash note
- `changes` — Changes & diff — Changed files, diff hunks and commit dock
- `live_preview` — Live preview — Sandbox preview, expiry and share controls
- `browser` — Browser — Agent-driven tab, live frames, take control
- `take_control` — Take control — Human control, 45 s countdown and keyboard/trackpad

## Connectors
- `connectors` — Connectors — Installed and available apps with categories
- `connector_detail` — Connector detail — Permissions, account, usage and disconnect
- `add_connector` — Add connector — Searchable catalog, plan limit and auth

## Library
- `artifacts` — Artifacts — Images, pages, files and code with filters
- `artifact_detail` — Artifact detail — Preview, metadata, versions and actions

## Schedules
- `schedules` — Schedules — Scheduled prompts, cadence and next run
- `schedule_editor` — Schedule editor — Prompt, cadence, timezone and notifications
- `schedule_runs` — Schedule runs — Run history, failures, retry and artifacts

## Sharing
- `share_sheet` — Share sheet — Read-only link, visibility and share targets
- `share_chat` — Share chat — Chat-specific share with fork note
- `collab_live` — Collaboration live — Up to 50 members, one sender and a turn queue
- `collab_members` — Collaboration members — Roles, capacity and creator-paid storage

## Runs
- `trajectory` — Run trajectory — Steps, tools, sources and token usage
- `subagent` — Subagent — Progress, files and the full log

## Settings
- `settings` — Settings hub — Account, chat, models, data control and advanced
- `account` — Account — Profile, email, sign-in methods and deletion
- `plan_billing` — Plan & billing — Free/Go/Plus/Pro, currency, history and restore
- `usage` — Usage — Daily and monthly allowance, models and storage
- `memory` — Memory — Master switch, shared memory and scopes
- `data_control` — Data control — Export, import, permissions and danger zone
- `storage` — Storage — Plan quota, breakdown and clean-up
- `appearance` — Appearance — System/Light/Dark, text size and motion
- `credentials` — Credentials — Sign-in providers, GitHub and the cloud key
- `account_health` — Account health — Security score, devices, sign-ins and services
- `about` — About — Version, legal, support and system status
- `notifications` — Notifications — Runs, schedules, security and delivery
- `presets` — Agent presets — General, Coder, Researcher, Writer and custom
- `response_wait` — Response wait limit — How long Ovid waits before asking
- `permissions` — Permissions — Camera, microphone, photos, notifications, files
- `memory_files` — Memory files — Global, project and session files

## Wiring rule

Every screen is "wired" only when every interactive element has a non-null
handler that reaches real state (`AppState`, a route builder in
`lib/ui/v2/app/*_routes.dart`, or a service). A visible control whose handler
is null, or that only shows a SnackBar saying "coming soon", is a bug.
