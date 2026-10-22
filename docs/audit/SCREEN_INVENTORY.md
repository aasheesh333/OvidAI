# Screen inventory (canonical)

50 screens registered in `lib/ui/v2/v2_registry.dart` (50 entries, every one with a builder; 7 of them are sheets), across 10 groups.

The web gallery (`v2_registry_web.dart`) has **87** entries: 49 of these 50 screens plus 38 component/sheet previews. `account` is native-only — the gallery test asserts the web registry never imports it.

Regenerate this file from the registry, not from memory: the id, title and summary below are the registry strings verbatim.

## Identity
- `splash` — Splash — Mark, tagline, startup progress and a retry path
- `sign_in` — Sign in — Google and phone sign-in with inline errors
- `welcome` — Welcome — First-run introduction with language choice
- `language_goal` — Language & goal — Hindi, Hinglish, Punjabi, Tamil plus what to build first
- `paywall` — Paywall — Free, Go, Plus and Pro with monthly/yearly and INR

## Chat
- `chat` — Chat (empty) — Top bar, model chip, suggestions and composer
- `live_chat` — Live chat — Transcript, thinking, tools, artifacts and stop
- `model_picker` — Model picker *(sheet)* — Auto recommendation, search and locked paid models
- `model_chip` — Model chip menu *(sheet)* — Quick model switch from the top bar
- `system_states` — System states — Plan limit, offline, error and empty variants

## Navigation
- `sidebar` — Sidebar — Profile, new chat, pinned, projects and sessions
- `projects` — Projects — Shared projects, storage and member stacks
- `session_actions` — Chat actions *(sheet)* — Pin, rename, move, share, duplicate, export and delete

## Work
- `repo_picker` — Studio repo picker — GitHub connection and repository choice
- `studio_workspace` — Studio workspace — File tree, editor, sync and changes
- `branch_picker` — Branch picker *(sheet)* — Switch or create a branch with a stash note
- `changes` — Changes & diff — Changed files, diff hunks and commit dock
- `live_preview` — Live preview — Sandbox preview, expiry and share controls
- `browser` — Browser — Agent-driven tab, live frames, take control
- `take_control` — Take control *(sheet)* — Human control, 45 s countdown and keyboard/trackpad

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
- `share_chat` — Share chat *(sheet)* — Chat-specific share with fork note
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
- `account_health` — Account health — Plan, today's usage, storage and deletion state
- `about` — About — Version, legal, support and system status
- `notifications` — Notifications — Runs, schedules, security and delivery
- `presets` — Agent presets — General, Coder, Researcher, Writer and custom
- `response_wait` — Response wait limit — How long Ovid waits before asking
- `permissions` — Permissions — Camera, microphone, photos, notifications, files
- `memory_files` — Memory files — Global, project and session files

**Total: 50 screens.**

## Wiring rule

Every screen is "wired" only when every interactive element has a non-null
handler that reaches real state (`AppState`, a route builder in
`lib/ui/v2/app/*_routes.dart`, or a service). A visible control whose handler
is null, or that only shows a SnackBar saying "coming soon", is a bug. Under the
minimal-UI contract a control with no backing service is removed, not disabled.

## Registry summary vs app wiring

The summaries above describe what each screen's builder can render; they are not
a claim that the app wires every option. There are no known mismatches on
`sign_in`: the screen renders exactly the two providers the app supports
(Google and phone), and the summary says so. The email/password form and the
Apple button were removed rather than left as dead controls.
