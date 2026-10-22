# Ovid Si — screens and features (current code)

**Audited:** 2026-10-22 against `lib/ui/v2/` and the production adapters in
`lib/ui/v2/app/`. This file describes what the code does **now**, not the
original plan. The registry is the source of truth for the 50 screens
(`lib/ui/v2/v2_registry.dart`); the adapters decide which of them are actually
reachable in the app.

Legend for **Wiring**:

- **Wired** — a production route/adapter constructs the screen with live data
  and every rendered control has a handler.
- **Partial** — the screen is real, but at least one section is honest-empty or
  hidden because the service behind it does not exist.
- **Gallery-only** — the screen is registered and tested, but no production
  route constructs it. It is a design surface, not a shipped destination.
- **Empty** — the screen is wired but always opens in its empty/unavailable
  state because its data source is missing.

Every gap named below has an owner and a file citation in
[`FEATURE_GAPS.md`](FEATURE_GAPS.md).

---

## 1. Identity (5)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `splash` | Mark, wordmark, one real startup progress bar, one status line. The host replaces it when boot finishes; a retry appears after a failure or a no-progress stall. | progress, failed, slow/timeout, ready | Wired (`v2_onboarding_gate.dart`) | Progress is host-injected; there is no independent offline probe on this screen. |
| `sign_in` | Google (filled primary) and phone (outlined). Phone opens the real OTP sheet; inline error with retry. No email form, no Apple button. | idle, requesting, error, cancellation | Wired (`v2_onboarding_gate.dart`) | No email/password or Apple backend exists by design. |
| `welcome` | First-run identity and one "Get started" action. Close only when the host can dismiss the tour. | idle, saving, save error | Wired (`v2_onboarding_gate.dart`) | None known. |
| `language_goal` | Voice language chips (English, हिन्दी, Hinglish, ਪੰਜਾਬੀ, தமிழ்) and first-goal chips; both persist. Continue is disabled until valid. | loading, selected/disabled, save error | Wired (`v2_onboarding_gate.dart`) | The UI itself is English-only; the choice is a voice/assistant preference, not app localization. |
| `paywall` | Free/Go/Plus/Pro cards, USD/INR, monthly/yearly, 3 bullets per card, purchase banner, restore and manage-subscription paths. | ready, purchasing, restore result, error, no price | Wired to RevenueCat (`v2_settings_actions.dart`) | Yearly SKUs are code-only; Play yearly products do not exist. Purchases depend on Play/RevenueCat setup. |

## 2. Chat (5)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `chat` | Top bar (menu · model chip · title · Studio · Browser · ⋮), greeting, three starting points, one-row composer, queue dock, send-error bar. | empty, loading, running, planLimited, offline, error | Wired (`v2_app_shell.dart`) | Starting points are fixed copy, not server-generated suggestions. Free/Go are Auto-only. |
| `live_chat` | Lazy transcript (user, assistant, thinking, tools, artifacts), artifact tile with thumbnail/menu, queue dock, stop, inline error bar. | running, ready, empty, error | Wired (`v2_app_shell.dart`) | No message edit/branch/regenerate; artifact preview opens the detail page rather than an inline renderer. |
| `model_picker` | Search over name, provider and cost, Auto recommendation, model rows, locked paid models with plan labels. | ready, loading, error, locked | Wired (`v2_app_shell.dart`) | No per-model speed or price telemetry exists, so no row states one. Cost reads `Included` on a plan that covers the model, `Your key` for a connected provider, and is omitted on a gated row. Manual models are Plus/Pro only. |
| `model_chip` | Quick menu: Auto, recent models, manage models, compare plans. | ready, locked | **Gallery-only** | The shell opens the full model picker from the chip instead; no production route shows this menu. |
| `system_states` | One tile per live blocking condition (offline, abuse, plan limit, rate limit, update) with one real exit; "All clear" when nothing is wrong. | active conditions, all-clear | **Gallery-only** | Chat renders its own inline plan/offline/error states; no production route constructs this page. |

## 3. Navigation (3)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `sidebar` | Drawer/rail: profile + plan, New chat, inline search over sessions and projects, pinned, projects, today/yesterday/earlier sessions, footer (Schedules/Artifacts/Settings). | loading, content, error | Wired (`v2_app_shell.dart`) | Search is inline only. |
| `projects` | Project list with name, chat count, storage and member stack; create, open, rename, delete, edit memory. | loading, content, error | Wired (`v2_app_shell.dart`) | Sort chips (Recent/Name/Chats) at 4+ projects; no status chip because the product has no project status; shared-project membership is display-only here. |
| `session_actions` | Pin, rename, move to project, share, duplicate, export Markdown, delete. Per-row progress and inline failure; rows without handlers are hidden. | loading, content, empty, error, per-row busy | Wired (`v2_app_shell.dart`) | Legacy callbacks are still accepted for host migration; no bulk actions. |

## 4. Work (7)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `repo_picker` | GitHub connection (OAuth or PAT), searchable repo list, branch step, one primary action. | loading, content, empty, error, needs-auth | Wired (`v2_work_routes.dart`) | GitHub OAuth/PAT must be configured in the build; no GitHub App installation flow. |
| `studio_workspace` | File tree + line-numbered editor, branch chip, sync, navigation to Changes/Live preview. Split view at 600 dp+. | loading, content, empty, error, syncing | Wired (`v2_studio_routes.dart`) | Changed-file count and sync count are always 0: there is no git-status source. |
| `branch_picker` | List/search branches, create a branch, switch; current branch marked. | loading, content, empty, error | Wired (`v2_studio_routes.dart`) | The registry summary promises a "stash note" but the sheet renders none; there is no stash action. |
| `changes` | Changed-file rows, inline diff and commit dock. | loading, content, empty, error | **Empty** (`v2_studio_routes.dart`) | Always opens empty: no app-side git status/diff client and no commit transport. |
| `live_preview` | One real frame, status pill, expiry and share/open/stop controls; controls disappear when no handler exists. | connecting, live, lost, error, expired, unavailable | **Empty** (`v2_studio_routes.dart`) | Always `unavailable`: no preview producer, tunnel or frame source. |
| `browser` | Agent-owned tabs, live frame, take-control pill/dock, address and menu. | loading, empty, error, content | Wired (`v2_work_routes.dart` → `BrowserLivePage`) | Server cannot yet expose history, upload, download or closing a tab; those controls are removed. Gateway does not expose `fps`/`headless` fields. |
| `take_control` | Hand-over sheet: one title/line, "Start controlling" and "Stay watching"; loading, ended and error states reuse the same shape. | ready, loading, ended, error | Wired (`browser_live_page.dart`) | No countdown (the server puts no timer on human control), no keyboard/trackpad mode picker and no resume/stop pair; input transport depends on the browser service. |

## 5. Connectors (3)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `connectors` | Installed/Available tabs with counts over one catalogue, search and filter menu scoped to the active tab, per-row enable switch and plan cap; Available rows add through the preset setup flow. | loading, content, error | Wired (`v2_app_shell.dart` → `ConnectorsPage`) | No per-tool permission summary. |
| `connector_detail` | Status, account, permissions, test connection (real HTTP probe), disconnect. | loading, content, error | Wired (`connectors_page.dart`) | `tools` is empty for every catalog row, so per-tool permissions cannot be listed. Activity/agents fields are not rendered. |
| `add_connector` | Searchable catalog, custom connector form (name/URL/key), permission selection, test, save; plan cap enforced. | loading, content, error, blocked | Wired (`connectors_page.dart`) | Catalog rows carry no tool manifest; "test" is an HTTP probe, not a provider-specific capability check. |

## 6. Library (2)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `artifacts` | Lifetime library grid with search, type/source/chat/date/sort filters and a visible/total size summary. | loading, content, empty, error | Wired (`v2_work_routes.dart`) | No version history; the `totalSizeLabel` field is not rendered. |
| `artifact_detail` | Lightweight preview (image, code, document metadata, data), ≤3 metadata rows, open externally, share, download, delete. | loading, content, error, missing | Wired (`v2_work_routes.dart`) | No document renderer by design; no version history. Version/origin/headline fields are constructed but not rendered. |

## 7. Schedules (3)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `schedules` | One summary line (`3 schedules · next in 4h`, or `· all paused`) then one card per schedule: prompt, cadence, next run, enable switch, run now, edit, delete. Cards are ordered next-to-run first, paused last. | loading, content, empty, error | Wired (`v2_work_routes.dart` → `SchedulesFlow`) | No separate upcoming queue by design — the ordered list is the queue. No total-runs or success-rate figure: the list model carries no run counts. |
| `schedule_editor` | Prompt, cadence chips, time, timezone, save, delete. | loading, content, error, missing, saving | Wired (`schedules_flow.dart`) | No "once" cadence; no per-schedule notification override. |
| `schedule_runs` | Summary line plus day-grouped run timeline with status, duration, artifact and retry. | loading, content, empty, error | Wired (`schedules_flow.dart`) | The computed average runtime is not rendered; retry re-runs the schedule, not one historical run. |

## 8. Sharing (3)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `share_chat` | Creator share sheet (the `ShareSheet` link surface) or recipient read-only transcript with one Fork action; mode availability and revocation state are explicit. | live, revoked, expired, unavailable | Wired (`v2_app_shell.dart`) | Forking requires the share backend; no OS share-target grid. |
| `collab_live` | One turn line, lazy transcript, composer gated by connection/turn, ended state. | loading, empty, error, ready, ended; connecting/connected/disconnected | Wired (`v2_collab_routes.dart`) | No server turn queue: `queueLabel` is null and `turnQueue` empty. No raise-priority control. |
| `collab_members` | Roster with role, invite, role change, remove, leave; 50-seat cap. | loading, empty, error, ready | Wired (`v2_collab_routes.dart`) | Presence and storage-share percent are not rendered; capacity is display + server rejection only. |

## 9. Runs (2)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `trajectory` | Ordered timeline of real steps (message/plan/search/write/preview/finish), status, duration, sources, subagent launches. | loading, empty, error, ready | Wired (`v2_run_routes.dart`) | The old prompt/model/token/duration header was removed; the registry summary still says "token usage". No token accounting on this screen. |
| `subagent` | Status, the five-key summary (status/files/artifacts/findings/error), one live progress line while running, the goal, the files touched and the log tail, plus one log action. | loading, empty, error, ready, running | Wired (`v2_run_routes.dart`) | The session records no measured percent, so the screen shows no progress bar; `timeLimit` and `remaining` are not recorded either. |

## 10. Settings (16)

| Screen | What it does now | States handled | Wiring | Honest gaps |
|---|---|---|---|---|
| `settings` | Five sections of one-line rows, one search action that reveals/highlights a row; rows without handlers are removed. | loading, ready, empty, error | Wired (`v2_settings_routes.dart`) | No standalone search screen; search is inline in the hub. The "Crash reports" row routes to Data control, which has no crash consent control (A13). |
| `account` | Profile, editable display name, email/verification, connected accounts, data control link, sign out, typed-confirmation delete, deletion grace/restore. | loading, ready, empty, error, deletion pending | Wired (`v2_settings_routes.dart`) | No avatar upload (no storage endpoint; the avatar is read-only from Firebase `photoURL`); no email-verification resend. |
| `plan_billing` | Plan cards with currency/period toggles, purchase, restore, manage subscription, payment history when present. | loading, ready, empty, error, purchasing | Wired to RevenueCat (`v2_settings_routes.dart`) | Yearly selection calls `ovid_*_yearly`, which Play/RevenueCat do not have, so the purchase fails with the store error (it no longer falls back to the monthly SKU). Payment history has no source and is hidden. |
| `usage` | Daily token hero, live reset countdown, 30-day caption, today's request/image counters, 7/30-day activity chart. | loading, ready, empty, error | Wired (`/usage` + `/usage/history`) | The model-share chart exists but is **gallery-only**; `models` is not mounted on this screen (C18). The counter line is `/usage`'s `today.requests` / `today.images`, falling back to the ledger's today bucket for requests only. |
| `memory` | Master switch, global facts (add/edit/forget), project memory, session files, reset. | loading, ready, empty, error | Wired (`v2_settings_routes.dart`) | No memory-accuracy card; share-session-memory toggle was removed. |
| `data_control` | Export (scope picker, per-chat selection), import with preview, cache clear with measured bytes, typed-confirmation delete. | loading, ready, error, exporting, importing, clearing, deleting | Wired (`v2_settings_routes.dart`) | **No crash-report consent control on this page**, although the Settings hub's "Crash reports" row routes here; the adapter still passes `crashReports`/`onCrashReportsChanged` and the page ignores both. Permission/storage/memory rows live on their own screens; their legacy hooks are unread. |
| `storage` | Quota bar, breakdown legend (artifacts/chats/cache), measured cache clear, upgrade. | loading, ready, empty, error | Wired (`v2_settings_routes.dart`) | Largest items, trash, preview cleanup and offline note are dead fields; only the bar/legend/cache are live. |
| `appearance` | Theme (system/light/dark), text size, voice language, reduce motion. | ready, error | Wired (`v2_settings_routes.dart`) | Memory/reasoning controls were removed; their data fields (`shareSessionMemory`) remain unread. |
| `credentials` | Google, GitHub (OAuth/PAT), provider key, cloud key, browser logins; masked values and real save/remove. | loading, ready, error | Wired (`v2_settings_routes.dart`) | Cloud-key status labels are dead; secrets are never revealed after save. |
| `account_health` | One derived status line and four facts: plan, today's usage, storage, deletion state. | loading, ready, error, deletion pending | Wired (`v2_settings_routes.dart`) | No device list or 2FA service; those sections are absent, not disabled. |
| `about` | App name, real build/version, privacy, terms, licences. | ready, legal loading/error | Wired (`v2_settings_routes.dart`) | No status row, support row or delete row; those retained host hooks are unread. |
| `notifications` | Master switch, four channels, quiet hours, one sound; real Android permission state and prompt. | loading, ready, empty, error, permission prompt | Wired (`v2_settings_routes.dart`) | Vibration is a device channel and is not app-controlled; quiet-hours label is dead. |
| `presets` | Built-in + custom presets; apply, create, edit, duplicate, delete, model pin. | loading, ready, empty, error | Wired (`v2_settings_routes.dart`) | No per-preset tool/connector grants; preset scope is model + wait + access mode. |
| `response_wait` | Slider and preset chips persist `responseTimeoutSec` (30–600 s), the same value the stall watchdog reads. | ready, error | Wired (`v2_settings_routes.dart`) | No auto-extend and no notify-at-limit; the watchdog only flags "still working". |
| `permissions` | Camera, microphone, photos, notifications, files with real platform status and one action per row; re-read on resume. | loading, ready, empty, error | Wired (`v2_settings_routes.dart`) | Android snapshot only; no iOS implementation. |
| `memory_files` | List with scope filter and counts, view, edit, delete, export all, export one file. | loading, ready, empty, error | Wired (`MemoryFilesPage.live()`) | "Export all" works through `onExport`; the older `onExportAll` field is dead. `totalSizeLabel` is constructed but never rendered. No version history or conflict UI beyond the revision check. |

---

## Cross-cutting facts (current)

- **Sessions** are isolated; `@` mentions read another session. Each session can
  have an auto-written `.md` memory, but the agent-side write path is a server
  concern.
- **Subagents**: max 50 per session, no nesting, 8 h ceiling, full log at
  `/workspace/.ovid/logs/subagent_{id}.log`, strict 300-token JSON summary.
- **Queue**: a message sent during a run waits; Stop dispatches it; dispatched
  subagents keep running.
- **Plans**: Free 3 GB · Go 5 GB · Plus 15 GB · Pro 75 GB. Connectors 0 / 5 / 20
  / 20. Manual models on Plus/Pro only.
- **Security**: keys stay server-side; the app lock covers every route; Studio
  tokens are injected per operation and never written to `.git/config`.

## Dead data (constructed but never rendered)

A number of `V2*Data` fields are still constructed by the adapters but no
widget reads them. They are not gaps in behaviour; they are stale surface that
makes the model look richer than the screen. The full table (class, fields and
constructing file) is the appendix in [`FEATURE_GAPS.md`](FEATURE_GAPS.md#appendix--dead-data-no-widget-reads).
Do not delete them in the audit pass; remove them together with the screen
change that makes them unnecessary.

## Registry truth notes

Two registry entries are **not reachable in the production app**:
`model_chip` and `system_states`. They are kept for the gallery
and component tests. `share_sheet` is no longer a registry screen: `ShareSheet`
is the creator body of `share_chat`, not a separate destination. `changes` and
`live_preview` are reachable but always open
empty/unavailable. Everything else is constructed by a production adapter.

`docs/audit/SCREEN_INVENTORY.md` matches the screen: Account health lists only
the plan, today's usage, storage and deletion. The screen itself carries no
devices, sign-ins or 2FA copy; the only remaining device wording in
`lib/ui/v2` is the disabled "New sign-ins" notification row
(`settings_extra/notifications_page.dart:172`), which belongs to Notifications.
