# Ovid Si — Session Handoff

**Purpose:** this file carries the full working context so a different harness
agent can continue exactly where the previous session stopped. Read this file
first, then `docs/superpowers/plans/2026-10-23-ovid-architecture-gaps.md`.

**Last commit:** `4bbe80ef feat(connectors): 100 curated connectors (20 -> 100)`
**Branch:** `feat/ovid-si-rebuild`
**Working tree:** clean (except `docs/legal/PRIVACY.md`, which the human is
editing — do not touch it)

---

## 1. What this project is

**Ovid Si** — an always-on personal super-intelligent agent and coding
specialist. Flutter Android client + cloud orchestration backend (Fastify
gateway, BullMQ worker, agent runtime, LiteLLM-based model access).

The product spec is a long owner-authored document. Its binding sections are
reproduced in the task list below. **The spec wins over the code.** Where the
code and spec disagreed, the spec was followed (see §5 Rulings).

---

## 2. Repository layout

```
lib/                     Flutter app
  core/                  services, state, cloud client, connectors
  ui/v2/                 the shipping UI (v2 shell); v1 only behind a flag
cloud/
  apps/gateway/          Fastify HTTP API (/cloud/v1)
  apps/worker/           BullMQ run processor, sandbox wiring, browser
  apps/mint/             TypeScript port of the plan/billing logic
  apps/e2e/              hook-contract fixtures
  packages/agent-core/   the agent loop, tools, subagents, prompt
  packages/sandbox/      bwrap jail, per-user/per-session workspaces
  packages/browser/      cloud browser engine, screencast, tools
  packages/mcp/          MCP catalogue + REST engine (100 connectors)
  packages/db/           Drizzle schema + repos
server/mint/             Python mint (the LIVE enforcement point) + admin
server/account/          account lifecycle service
server/collaboration/    Collab session service
docs/                    plans, play runbooks, architecture notes
```

---

## 3. How to run the checks

```bash
# Flutter
export PATH=/root/flutter/bin:$PATH
flutter analyze            # must be clean
flutter test               # 5470 pass, 2 skipped

# TypeScript packages (each has its own vitest)
cd cloud/packages/agent-core && npx vitest run
cd cloud/packages/mcp        && npx vitest run
cd cloud/packages/sandbox    && npx vitest run
cd cloud/packages/browser    && npx vitest run
cd cloud/apps/worker         && npx vitest run
cd cloud/apps/mint           && npx vitest run

# Gateway and the worker DB suite need real Postgres
cd cloud/apps/gateway
export TEST_DATABASE_URL="postgres://w8:w8@127.0.0.1:55450/ovid_gapfix"
npx vitest run

cd cloud/apps/worker
export TEST_DATABASE_URL="postgres://w8:w8@127.0.0.1:55450/ovid_gapfix"
export TEST_REDIS_URL="redis://127.0.0.1:16420/4"
npx vitest run src/runProcessor.test.ts

# Python mint
python3 -m pytest server/mint/tests/ -q
```

**Typechecking:** `npx tsc` is NOT on PATH. Use
`./packages/sandbox/node_modules/.bin/tsc -p <pkg>/tsconfig.json --noEmit`
from `cloud/`.

**Cross-package types:** when you change an exported type in
`packages/sandbox` or `packages/browser` or `packages/agent-core`, the
consumers read `dist/*.d.ts`. Rebuild that package before typechecking a
consumer:
```bash
cd cloud/packages/sandbox && ./node_modules/.bin/tsc -p tsconfig.json
```

**Known pre-existing failure (NOT caused by recent work):**
`cloud/apps/worker/src/runProcessor.test.ts` → "dispatch_agent runs a real
child loop and returns the strict JSON summary" fails on the scratch DB
because the child needs a model config that DB lacks. Verified failing on the
base commit before any of this session's changes. Do not chase it unless the
human asks.

---

## 4. What is DONE (verified, committed)

### 4.1 Session isolation (the foundation)

- **Per-session sandbox workspace.** `SandboxManager.attachSession(userId,
  sessionId)` binds `{workspacesRoot}/{uid}/sessions/{sessionId}/workspace` at
  `/workspace`. One env (cgroup + `.home`) per user; only the bind differs, so
  a second chat does not burn a second admission slot.
- **Two shared surfaces, per USER, never per chat:** `/studio`
  (`{uid}/workspace`, the cloned repos) and `/browser` (`{uid}/browser`).
- **Cross-user isolation is test-pinned, not assumed:**
  - `cloud/packages/sandbox/src/crossUserIsolation.test.ts` — distinct uids,
    no path ever under another user's tree, only this user's trees bound into
    the jail, `sessionId` cannot escape.
  - `cloud/apps/worker/src/tools/confinement.isolation.test.ts` — `..`,
    absolute paths and symlinks cannot reach another user's directory.

### 4.2 Subagents

- **The 50 cap is CONCURRENT, not lifetime** (owner correction). A settled
  child frees its slot on every settle path. `activeCount(sessionId)` exposes
  the count.
- **`dispatch_agents` (plural)** runs N children in parallel in one tool call.
  The loop is sequential per tool call, so without it 85% delegation would be
  serialised. Per-task failures stay per-task. Children cannot use it.
- **A dead child still reports its work.** On `failed` / `cancelled` /
  `timeout` the handoff's `key_findings` carries a bounded TAIL of the child's
  streamed output behind an explicit "unverified" label, under a 1,000-token
  failure budget. A COMPLETED child keeps the strict contract: its prose is
  still rejected (that is the prompt-injection boundary).
- **8-hour checkpoint.** On timeout the child's log gets a
  `subagent_checkpoint` line with the streamed work so far, and the handoff's
  error text tells the parent the progress is saved and to dispatch again.
- **`subagent_id`** is in the handoff JSON (spec 2.A.2), so the main agent can
  address one child's log. The key list is now SIX keys, not five.
- **Log path:** `/workspace/.ovid/logs/subagent_{id}.log` (spec path, kept).
- **No nesting:** three layers — roster denial, runtime refusal, depth/lineage.

### 4.3 Connectors / MCP

- **100 curated connectors** (owner directive): 4 native + 96 declarative REST.
  The first 20/16 ids are pinned forever — users already have them configured,
  so a reorder would silently re-map their credentials.
- **The screen reads the GATEWAY**, not a local list: `GET /mcp/catalog` +
  `GET /mcp/servers`. Before this, enabling a connector only set a local flag
  and the agent received no tool at all.
- **Plan caps enforced:** Free 0, Go 5, Plus/Pro 20 custom connectors.
  Curated rows never consume a custom slot.

### 4.4 Studio

- **Folder gate:** a Studio message cannot be sent until a repo is bound. A
  shared `V2StudioFolderGate` row above the composer opens the repo picker, so
  a disabled send is never unexplained.
- **The agent can switch branches** via `git_switch`: refuses a dirty tree
  unless `force`, refuses option-looking branch names, individually confirmed.
- **Read-only run log** in the workspace header (the session trajectory). No
  shell, no PTY — spec requires zero direct user shell.
- **GitHub credential survives restart:** token in the Keystore-backed
  SecureStore under the SAME key the Settings→Credentials row writes
  (`ovid_credential_key_github`), so a pasted PAT is what Studio uses.

### 4.5 Plans & money

- **Auto multipliers now follow the spec:** Free 1× · Go **1.5×** · Plus **5×**
  · Pro **20×**. Changed in all five places the number lives (Python mint seed,
  TS mint seed, offline fallback, two UI tables, e2e fixture) because that
  number is what the pools hook multiplies the Free daily allowance by — a
  drift is a silent revenue bug. A test pins it.
- **Tier aliases stay `3x` / `7x` / `15x`** — those are the values in
  `users.tier` for existing subscribers. Only the multiplier moved.
- **Upload window enforced:** Free 50 files/24 h, paid 80/3 h, counted from the
  account's own attachment rows, checked before presigning and before any row.
- **Free token ceilings:** 50M/24 h and 1.5B/30 d (already existed).
- **Manual-model gate** is server-side (`assertModelAllowed` at send + settings).

### 4.6 Memory

- **Session memory exists at the spec path** `/workspace/.ovid/session_memory.md`:
  the private store stays the durable copy; `mirrorSessionMemory` writes it out
  before the first turn, and `memory_save` writes through on the entrypoint.
  Best-effort — a sandbox write failure never fails a run.
- **`@` picker lists sessions, projects AND active subagents**
  (`@subagent:<id>`).
- Global / project / session memory + the "share session memory" toggle were
  already correct (defaults: global ON, sharing OFF).

### 4.7 Security & correctness

- **Key-suspension email** is actually delivered (Resend transport, or
  `KEY_IP_EMAIL_FACTORY`). Copy reads a whitelist of event fields.
- **Browser downloads belong to the agent**: `ownPath` hands the file AND its
  directory to the sandbox uid (worker writes as root, the jail runs as the
  uid), so the agent can modify/move/delete what it downloaded. Refuses any
  path outside that user's own tree.
- **Collab turn lock:** a peer that is `streaming` holds the turn even when its
  status is `idle` (between tool calls). Before, every member could send in
  that window.

### 4.8 Settings

Five cards in spec order: **Account → Personalization → Models → Data control
→ Advanced**, with Connectors as ROW 1 of Models. Account row order: Account →
Credentials → Plan & billing → Usage.

---

## 5. Rulings made (so you do not re-litigate them)

Each was a decision where the spec and the code disagreed. The human was told;
these are settled.

| # | Decision | Why | Cost if wrong |
|---|---|---|---|
| 1 | Session handles share one env/cgroup per user; only `/workspace` differs | A per-chat env burns an admission slot per chat | cgroup caps shared across that user's chats |
| 2 | `/studio` and `/browser` are per-USER, `/workspace` per-chat | Owner: "studio and browser shared ho, sessions isolated" | a download is visible to the user's other chats (intended) |
| 3 | The 50 cap is concurrent | Owner correction | two workers on one root could each admit 50 (cannot happen today: one run per session) |
| 4 | A new `dispatch_agents` tool instead of parallelising the loop's tool round | The round body carries plan mode, approvals, guards, spill — duplicating it would drift | two tool names to maintain |
| 5 | Failure excerpt is TAIL-only and labelled unverified; completed path still rejects prose | Injection boundary | a dead child's last words reach the parent as data (bounded + labelled) |
| 6 | Plan multipliers follow the spec (1.5/5/20), aliases unchanged | Revenue correctness | none known |
| 7 | Connector cap refusal is 403 `connector_limit_reached`, not 402 | 402 stays "this plan cannot use the feature at all" | a client branching on 402 sees 403 |
| 8 | Upload window counted from `attachments` rows, not Redis | No generic redis seam; rows are the record | deleting then re-uploading frees a slot immediately |
| 9 | Suspension email recipient = `payload.email`, else `OVID_SECURITY_ALERT_TO` | Mint has no user-email store | until the account service stamps `email`, block notices go to the operator |
| 10 | GitHub token reuses `ovid_credential_key_github` | One secret, one truth; the Settings row already wrote it | a key rename breaks both together (contract test catches it) |
| 11 | `subagent_id` added to the handoff → six keys | Spec 2.A.2 names it | older readers expecting five keys must accept six |
| 12 | Studio folder gate is client-side; the server does not refuse a Studio send without a repo | The spec describes a UI gate; the server still isolates the workspace | an API caller could send Studio mode with no repo |

---

## 6. What is NOT done — the actual next work

Ordered by value. Nothing here is blocked on a decision except where noted.

### 6.1 Connector Add/save is still local-only  ← biggest user-visible gap

The LIST comes from the gateway, but **adding** a connector still writes
`SharedPreferences` via `V2PrefsConnectorStore`
(`lib/ui/v2/connectors/connector_store.dart`), so the server never learns it
and the agent gets no tool.

Fix: a `V2RemoteConnectorStore` that maps
`save → ConnectorApi.connectCurated / addCustom`,
`remove → disconnect`, `setEnabled → setEnabled`.
`ConnectorApi` already exists at `lib/core/connectors/connector_api.dart` and
is fully tested. The credential field key must come from the catalogue entry
(`ConnectorCatalogEntry.credentialFields.first.key`), not a hardcoded
`'TOKEN'`.

### 6.2 Subagent refusal emits no session event

`SubagentLimitError` reaches the MODEL with the right code, but the USER sees
nothing. Needs a new `SessionEventType` (crosses the shared wire schema, which
is why it was deferred rather than half-added) plus a UI row.

### 6.3 Play Integrity attestation

Owner decision: **keep Play off for now** — this waits until the Play Store
launch. Today: Firebase App Check + a client-side root probe. No Play
Integrity token is minted or verified server-side.

### 6.4 Go plan net budget (₹295)

Owner handles this **in LiteLLM**; the code only needed the 1.5× multiplier,
which is done. Do not add a rupee model to the code.

### 6.5 Not run / not verified by a human

- 50-user live collaboration soak (never run).
- R2 activation steps 6.1–6.6 in `cloud/deploy/R2-PROVISIONING.md`
  (owner-run; irreversible once workspaces hibernate).
- `OVID_ACCOUNT_ENABLED` GitHub repo variable status is unknown. If the account
  service is live it must be `true`, or deletion/health stay unavailable.
- Play internal testing build verification (version 3 is live; Google sign-in,
  demo plan `(demo)` label and `pm get-app-links` were never confirmed by the
  human on a device).

### 6.6 After Play approval (not now)

Create the 6 subscriptions, validate RevenueCat credentials, attach
entitlements, test a real purchase, then build WITHOUT `OVID_BILLING_DEMO`.
See `docs/play/DEMO-BUILD.md` and `docs/play/PRODUCTION-RUNBOOK.md`.

---

## 7. How to work in this repo (conventions the previous agent followed)

- **TDD, always.** Write the failing test, run it, watch it fail for the right
  reason, then implement. A test that passes before the implementation is a
  finding about the test.
- **Server-first.** Every limit the spec calls a guarantee is enforced
  server-side. The client greys out; the server refuses.
- **Never invent numbers.** If a screen has no data source, it shows an honest
  empty state. There is a text-budget ratchet
  (`test/v2/text_budget_test.dart`) that fails on added copy — new copy
  replaces copy.
- **Do not change the UI layout** unless the task is a layout task. The human
  explicitly said the current UI/UX is correct.
- **Commit per task**, message `feat|fix|test(area): <what>`, with a body that
  says WHY (the constraint, not the diff).
- **Palette is fixed:** Paper `#F4F1EA`, Ink `#1B1B1B`, Signal Red `#E5484D`
  (agent only), Stone `#8A867D` (secondary text only). Flat: no gradients, no
  glow.
- **The failure-budget decision:** completed subagent summaries are 300 tokens;
  failures get 1,000 with a labelled tail. The human explicitly chose this over
  the spec's flat 300.

---

## 8. Environment facts

- Flutter: `export PATH=/root/flutter/bin:$PATH` (root warning is harmless).
- Scratch Postgres: `postgres://w8:w8@127.0.0.1:55450/ovid_gapfix`
  (container `w8-scratch-pg`). Create it if missing:
  `docker exec w8-scratch-pg psql -U w8 -d ovid_w8 -c "CREATE DATABASE ovid_gapfix;"`.
  `migrate()` needs an EMPTY database — reusing one with tables throws
  `relation ... already exists`.
- Scratch Redis: `redis://127.0.0.1:16420/4` (container `w8-scratch-redis`).
- Live stack lives in `/opt/ovid-gateway` (docker compose); LiteLLM admin on
  `127.0.0.1:8081` behind Caddy, user `ovidadmin`.
- Play app `com.dhanuk.ovidai`, internal testing, latest release **3 (1.0.0)**.
- Keystore `android/release-keystore.jks`, alias `mykey`.
- Google account used everywhere: `aasheeshkatheriya@gmail.com`.

---

## 9. The one-paragraph summary to paste into a fresh agent

> We are continuing **Ovid Si**, a Flutter Android + TypeScript cloud agent
> product, at commit `4bbe80ef` on branch `feat/ovid-si-rebuild` in this
> repository. Read `docs/HANDOFF.md` first — it has the full state, the
> rulings already made, the exact test commands and the remaining work. Then
> read `docs/superpowers/plans/2026-10-23-ovid-architecture-gaps.md`. Do not
> change the UI layout; the palette and screen design are settled. Work TDD,
> enforce limits server-side, and commit per task with a why-focused message.
> The highest-value remaining task is §6.1 (connector Add/save is still
> local-only). Do not touch `docs/legal/PRIVACY.md` — the human is editing it.
