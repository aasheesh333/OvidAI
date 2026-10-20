# Ovid Si — master spec v2 delta plan (2026-10-19)

Source: the owner's master product & architecture specification pasted 2026-10-19.
This plan covers only what is **not already built**; the audit waves and recovery work
already landed (chat, isolation, Studio files, browser live view, schedules, Artifact
Vault, usage, queue retention, plan facts from server).

Owner decisions taken 2026-10-19: **new tiers** Free / Ovid Go $5 / Ovid Plus $18 /
Ovid Pro $99, and **RevenueCat** as the billing path.

## Workstreams

### W1 — Projects
- New `projects` table (id, uid, name, created_at, updated_at) + `project_memory_files`
  (or reuse private_memory_files with a `project:<id>` scope — prefer reuse).
- Sessions gain `project_id` (nullable, owned).
- Server routes: list/create/rename/delete projects, move session, project memory CRUD.
- Sidebar: Projects section above Sessions, move-to-project, project file counts.
- Per-project file caps by plan: 80/100/150/250.
- Project memory injected into Main Agent runs for sessions in that project (and only then).

### W2 — Subagent orchestration (spec §2.A)
- Main Agent only may dispatch; subagents may never spawn subagents (enforced server-side).
- Up to 50 parallel subagents per session (plan/soft cap), each with its own run.
- 300-token JSON handoff: subagent writes verbose log to
  `/workspace/.ovid/logs/subagent_{id}.log`; returns only the strict summary object.
- 8-hour hard runtime cap with checkpoint + notify.
- Main Agent can read a subagent log via `@subagent_id`.
- Durable background execution: dispatch must not block the Main Agent turn.
- FCM push when a background task completes while the app is closed.

### W3 — Studio GitHub (spec §3 Screen 2)
- Repo/branch selection gate in STUDIO mode; cannot send until selected.
- GitHub OAuth + PAT entry; list repos/branches; clone into the user workspace.
- Auto `git fetch && git status` before tasks; "Sync latest changes" chip.
- Ephemeral credential helper over the gateway — never write tokens into `.git/config`.
- Live preview proxy for web builds.

### W4 — Browser upgrades (spec §3 Screen 3)
- Agent-first tab creation; user sees tabs only after the agent opens one.
- 45-second grace before converting to headless (currently immediate on detach).
- Tab switching, pinch-zoom, mobile keyboard in Take Control.
- Credentials Vault (AES-256-GCM) + agent login autofill without exposing secrets.
- File upload/download bridge between browser and workspace / Artifact Vault.

### W5 — Plans, storage, RevenueCat
- Replace the mint plan table with Free/Go/Plus/Pro (USD+INR).
- Storage quotas 3/5/15/75 GB, per-account usage accounting, upload-rate caps.
- Auto-mode multipliers 1.5x/5x/20x; manual selector gating by tier.
- RevenueCat SDK + server webhook + entitlement mapping; keep `/billing/verify` for legacy.
- Billing/Usage/Sidebar/Account read the server table.

### W6 — Connectors & MCP UI
- Connectors marketplace screen (built-ins + custom), enable/disable per user.
- Custom MCP limits by tier (0/5/20/20), `+` gated for Free.
- Server-side validation before activation; chat/workspace cannot self-install.
- Worker roster must actually contribute enabled connector tools to runs.

### W7 — Sharing & Collab
- Read-only share: full-history snapshot + "Continue in Ovid" deep clone of history and
  artifacts into the recipient's account/storage.
- Collab: up to 50 concurrent users, per-user model/quota, turn lock (Send greyed while
  another participant streams), host-owned storage for generated files.
- Single share store (retire the duplicate Python/TS ownership).

### W8 — Image models
- Worker tools for generation/editing using LiteLLM image models + capability cards.
- Inline images, receipts, artifact events; truthful availability by plan.

### W9 — Chat UX owner (single writer for `chat_screen.dart`)
- `@` autocomplete over sessions, projects and active subagents.
- Model lock during a turn; queued-next semantics + red Stop dispatching the queue.
- Three-dots menu: Trajectory, Share (Read-only/Collab), Rename, Add to Project, Pin, Delete.
- Studio repo chip gate; permission mode selector (GENERAL/STUDIO/custom).
- Vernacular voice-first mode (Hindi/Hinglish/Tamil/English) with voice reply + summary card.

### W10 — Settings v2 (5 cards)
Account (profile, sign-out cache restore, 24h deletion grace + subscription check,
credentials vault, plans, usage), Personalization, Models (connectors, presets, wait
limit), Data Control (export guardrails 64 MB/1,000/20,000, permissions, crash reports,
storage, delete/reset), Advanced (notifications after first response, account health,
about).

### W11 — Security & admin
- Multi-IP anomaly auto-block with email.
- SuperAdmin web panel: users, plans, spend, storage, IP logs, block/unblock, reset key,
  change plan, adjust free caps, inspect subagents.
- Master system prompt + subagent worker system prompt injected on every task.

### W12 — Cloudflare R2 CDN (owner request 2026-10-19)
- Signed-token CDN URLs (`cdn.ovidsi.com/o/<key>?t=…&e=…`) served by a Cloudflare Worker that
  validates an HMAC token, streams from R2, supports Range/HEAD/download disposition, and sets
  cache headers. Immutable content-addressed objects get long TTL; named/mutable objects short TTL.
- Gateway returns CDN URLs when configured, falling back to the existing presigned URLs.
- Chat text is NOT public-CDN cached (per-user, mutable, private). Safe wins only: edge
  compression, ETag/304 conditional GET on message pages, pagination, and offloading large
  immutable payloads (tool output, images, attachments) to R2 objects behind signed CDN URLs.
- Owner dashboard steps: custom domain, Worker route, cache rules; env `OVID_CDN_BASE_URL`,
  `OVID_CDN_SIGNING_SECRET`, `OVID_CDN_TTL_SECONDS`.

### W13 — Unified per-user accounting (owner request 2026-10-19)
"Every user's every thing counts in storage and usage."
- **Usage ledger:** one row per billable action — LLM call (tokens), image generate/edit/resize
  (units + resolution/steps as priced), browser/tool usage where priced — with model, provider,
  unit counts, price basis and computed cost. Prices from LiteLLM; unpriced models are marked
  `priced=false` and units still counted. Retries must not double-count.
- **Storage accounting:** per-user bytes for chat text, attachments, artifacts/workspace objects
  and stored browser state, with per-session and per-artifact breakdown; incremental on
  write/delete plus periodic reconciliation; quota enforcement by plan (3/5/15/75 GB).
- **APIs:** `GET /cloud/v1/usage/storage` (totals + breakdown) and extended usage history with
  per-model, per-kind, per-day, per-session totals. The app shows percentages, not money;
  admin sees underlying cost.
- Consumes the W5 plan table and the W8 image tools; no duplicate counters.

## Rules for every workstream
- Owner rules R1–R5 still apply (session isolation, shared per-user Studio/browser,
  screencast only while viewing, truthful UI, test before fix).
- Only W9 edits `lib/ui/chat_screen.dart`; everyone else coordinates through it.
- Migrations are sequential: deployed `0017` immutable; `0018` chat; `0019` memory;
  new work takes `0020+` in coordination.
- No push/deploy/production changes without owner approval.
- Capacity load runs are owned by one agent at a time.
