# Ovid Si — screens and features

Canonical list. 50 screens in `lib/ui/v2/v2_registry.dart`, grouped by the job
the user is doing, not by the code layout.

Legend: **Wired** = every control reaches real state. **Partial** = the screen
is complete but a backend it needs does not exist yet. **Missing** = the
feature is specified but not built.

---

## 1. Identity (5)

| Screen | What it does | Features |
|---|---|---|
| `splash` | First paint while state loads | Wordmark, one progress bar, status line, retry on failure. Wired. |
| `welcome` | First run | Wordmark, one line, "Get started". Wired. |
| `language_goal` | First run | Voice language (English, Hindi, Hinglish, Punjabi, Tamil) + first goal. Both persist. Wired. |
| `sign_in` | Auth | Google + phone only. Inline error with retry. Email form deliberately absent. Wired. |
| `paywall` | Plan choice | Free / Go / Plus / Pro, USD + INR, 3 bullets each, "Continue with Free". Wired to RevenueCat. |

## 2. Chat (5)

| Screen | What it does | Features |
|---|---|---|
| `chat` | Empty chat | Top bar (menu · model chip · title · Studio · Browser · ⋮), greeting, 3 starting points, one-row composer. Wired. |
| `live_chat` | Active chat | Transcript, thinking, tools, artifacts, queue dock, stop, inline error bar. Wired. |
| `model_picker` | Model choice | Auto + manual models. Free/Go see them locked. Wired. |
| `model_chip` | Quick model switch | Auto, recent models, manage. Wired. |
| `system_states` | Offline / limited / blocked / error | One tile per state with a real action. Wired. |

## 3. Navigation (3)

| Screen | What it does | Features |
|---|---|---|
| `sidebar` | Drawer / rail | Profile + plan, New chat, inline search (sessions + projects), Projects, Sessions, footer (Schedule / Artifacts / Settings). Wired. |
| `projects` | Project list | Name, chat count, per-project memory. Create / rename / delete. Wired. |
| `session_actions` | Chat menu | Share, rename, add to project, pin, duplicate, export, delete. Wired. |

## 4. Studio (7)

| Screen | What it does | Features |
|---|---|---|
| `repo_picker` | GitHub repo + branch | PAT or OAuth, searchable repos, branch step, one primary action. Wired. |
| `studio_workspace` | The IDE | File tree + editor, branch chip, one-click sync. Split view at 600 dp+. Wired. |
| `branch_picker` | Switch branch | Search, create, switch. Wired. |
| `changes` | Diff + commit | File rows with +N −N, inline diff, commit in header. Partial — no app-side diff client. |
| `live_preview` | Run the app | Frame, status pill, share / open / stop. Partial — no preview client. |
| `browser` | Agent browser | Tabs (agent-opened only), live frame 3–5 fps, take control, download / upload. Wired. |
| `take_control` | Hand over | One title, one line, two buttons. Wired. |

## 5. Connectors (3)

| Screen | What it does | Features |
|---|---|---|
| `connectors` | Installed add-ons | Search, filter menu, per-row switch, plan cap. Wired. |
| `connector_detail` | One connector | Status, test connection (real HTTP probe), 3 permissions, disconnect. Wired. |
| `add_connector` | Add one | Name, URL, key, permissions, test, save. Cap enforced: Free 0 / Go 5 / Plus 20 / Pro 20. Wired. |

## 6. Library (2)

| Screen | What it does | Features |
|---|---|---|
| `artifacts` | Everything the agent made | Card grid, type/source/chat/date/sort filters, search. Wired. |
| `artifact_detail` | One artifact | Preview (code / document / image), ≤3 metadata rows, open, share, download. Wired. |

## 7. Schedules (3)

| Screen | What it does | Features |
|---|---|---|
| `schedules` | Recurring tasks | Prompt, cadence, next run, enable switch, run now, delete. Wired. |
| `schedule_editor` | Create / edit | Prompt, cadence chips, time, save. Wired. |
| `schedule_runs` | History | Summary line, day-grouped timeline with status + duration. Wired. |

## 8. Sharing (4)

| Screen | What it does | Features |
|---|---|---|
| `share_sheet` | Share a chat | Collab (max 50, one sender, creator pays storage) vs Read only (fork into own account). Wired. |
| `share_chat` | Shared chat view | Read-only transcript + fork. Wired. |
| `collab_live` | Live room | Turn banner, transcript, composer gated by turn. Wired. |
| `collab_members` | Roster | Avatar, name, role, remove. 50 cap. Wired. |

## 9. Runs (2)

| Screen | What it does | Features |
|---|---|---|
| `trajectory` | What the agent did | Ordered steps, status, duration, subagent links. Wired. |
| `subagent` | One worker | Status, 5 contract fields, log, stop. Wired. |

## 10. Settings (16)

| Screen | What it does | Features |
|---|---|---|
| `settings` | Hub | 5 sections, one search icon. Wired. |
| `account` | You | Avatar, name, plan, edit profile, sign-in methods, data control, delete. Wired. |
| `plan_billing` | Plans | 4 cards, USD/INR, monthly/yearly, current plan marked, restore. Wired to RevenueCat. |
| `usage` | Detailed usage | Hero number, 7/30 range, one chart. Wired. |
| `memory` | What Ovid remembers | Scope filter, per-entry forget, reset. Wired. |
| `memory_files` | The .md files | List, view, edit, delete, export. Wired. |
| `shared_memory` | Cross-session memory | Master switch + scope switches. Wired. |
| `data_control` | Export / import / wipe | 64 MB / 1k sessions / 20k chats limits, 4 rows. Wired. |
| `storage` | Space used | One bar + legend + clear cache. Wired. |
| `appearance` | Look | Theme tiles (system / light / dark), text size, voice language. Wired. |
| `credentials` | Saved logins | Masked keys, add / remove. Wired. |
| `account_health` | Account summary | Status, deletion state, sign-in methods. Partial — no device/2FA service. |
| `about` | Legal + version | Version, build, privacy, terms, licences. Wired. |
| `notifications` | Alerts | Master, channels, quiet hours, sound. Wired. |
| `presets` | Agent presets | List, apply, create, delete. Wired. |
| `response_wait` | Patience | Slider + presets, drives the stall watchdog. Wired. |

---

## Cross-cutting features

**Sessions** — 100 % isolated. `@` mentions another session to read or continue
it. Sharing is a settings toggle. Every session owns an auto-written `.md`
memory, and the main agent aligns its subagents from it.

**Subagents** — max 50 per session, no nesting, 8 h ceiling, full log at
`/workspace/.ovid/logs/subagent_{id}.log`, strict 300-token JSON back to the
main agent.

**Queue** — a message sent while the agent is working waits; Stop dispatches it
immediately; dispatched subagents keep running.

**Models** — Auto on every plan. Manual models on Plus/Pro only. The selected
model drives both the main agent and its subagents. Cloud models expose the
integrated image models; every request is metered per LiteLLM.

**Plans** — Free 3 GB · Go 5 GB · Plus 15 GB · Pro 75 GB. Free caps at 50M
tokens / 24 h and 1.5B / 30 d, Auto only. Connectors: 0 / 5 / 20 / 20.

**Security** — no key ever leaves the server; a key seen from many IPs is
blocked and the account is emailed; the app lock covers every route; Studio
tokens are injected per operation and never written to `.git/config`.

---

## Honest gaps

| Feature | State |
|---|---|
| Studio diff + commit | Screen is honest-empty; no app-side git status/diff client. |
| Live preview | Waits honestly; no preview client or tunnel. |
| Yearly billing | Yearly SKUs are code-only; Play/RevenueCat yearly products do not exist yet. |
| Account health devices / 2FA | No device or 2FA service; the sections are removed rather than faked. |
| Connector per-tool permissions | Catalog rows carry no tool manifest; the tools card is hidden. |
| i18n | English UI only. The language picker is a voice/assistant preference. |
| Collab turn queue | No server queue API; the banner states the wait instead of showing a dead button. |
