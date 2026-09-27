# Plan Mode — Gap Analysis

**Ovid vs. opencode CLI vs. DeepSeek Harness (dsh)**

- **Ovid:** `hoplite/gortyn-77773150` @ `a611c53` (this repo)
- **opencode:** [opencode.ai/docs/agents](https://opencode.ai/docs/agents/) · [opencode.ai/docs/permissions](https://opencode.ai/docs/permissions/) · [agentscli.com — Tab between plan and build](https://www.agentscli.com/course/opencode/the-tui/plan-build-toggle/)
- **dsh:** [Plan Mode reference](https://deepseek-harness.github.io/deepseek-harness/en/reference/subsystems/plan) · [packages/plan/plan-mode](https://github.com/deepseek-ai/deepseek-harness/tree/master/packages/plan/plan-mode)

---

## 1. How each one actually works

### opencode — plan mode is a *different agent*, not a mode

- Two built-in **primary agents**: **Build** (all tools enabled) and **Plan** (restricted). You cycle them with the **Tab** key or the `switch_agent` keybind, or invoke with `@` mention.
- Restriction is expressed as **per-agent permissions** with three outcomes: *run automatically*, *prompt*, or *blocked*. Example from their docs: `permission: { bash: deny }`, `permission: { edit: deny }`.
- Agents are **markdown files with frontmatter** (`description`, `mode`, `model`, `temperature`, `topP`, `maxSteps`, `prompt`, `permissions`, `disable`, `hidden`, `color`). `opencode agent create` walks you through generating one and *"lets you select which permissions the agent should be allowed (anything you don't select is denied)."*
- Because Plan is a full agent, it can have **its own model, temperature and prompt** — e.g. a stronger model for planning, a cheaper one for building.
- Note: as of v1.1.1 the legacy `tools` boolean config is deprecated and merged into `permission`.

### dsh — plan mode is *soft guidance*, owned by an optional package

- Owned by the **`dsh-plan-mode`** package; contributes the `plan:policy` prompt section, registers the `exit_plan_mode` tool and the `/plan` command. **"The package is optional, and the agent loop does not depend on it."**
- **"Plan mode is soft guidance. Sandbox mode and approval policy enforce restrictions independently; neither reads or writes plan state, so deployments configure them separately."** And per the package README, **"every tool remains available."**
- State is a **log-only, whole-value-replace session event** — `plan/mode ({active: boolean})` — durable and replayable, **"never in the model transcript."** Clients get a cropped `{active, pending}` projection.
- **Turn-boundary semantics.** `set(agent, active)` returns `'committed' | 'queued' | 'cancelled' | 'noop'`. Between turns it commits immediately; **during an open turn the change stays `pending` until the next accepted in-turn pre-step**. Repeated selection of the current/pending state is a no-op.
- `/plan` accepts an optional message **or ordered image and file attachments**; `/plan off` exits. The exact argument `off` "also cancels a pending entry before it is appended and becomes visible to a request."

### Ovid — plan mode is a *hard allowlist on a session boolean*

| Mechanism | Location |
|---|---|
| `ChatSession.planMode` (bool, persisted) + `ChatSession.planPreMode` (mode to restore) | `lib/core/state.dart:1148`, `:1158` |
| `/plan [message\|off]` command | `lib/core/commands.dart:157-176` |
| `planMode` getter/setter bridging session state | `lib/core/agent_service.dart:1082-1098` |
| **Default-deny allowlist** of ~45 read/search/plan tools | `lib/core/agent_service.dart:17158-17211` |
| Gate — refuses any unlisted tool | `lib/core/agent_service.dart:11278` |
| `exit_plan_mode` tool schema | `lib/core/agent_service.dart:6420-6445` |
| `exit_plan_mode` handler → `ApprovalRequest(planBody:)` | `lib/core/agent_service.dart:17307-17345` |
| "Plan review" card (markdown, 260px scroll; Chat about it / Decline / Approve) | `lib/ui/chat_screen.dart:6494-6545` |
| `plan` AgentPreset (persona only, no tool lists) | `lib/core/presets.dart:151-162` |

Enforcement is a **hard allowlist, not a blocklist**: an unlisted tool — *including plugin/MCP contributions and any tool added later* — is refused by default. On approve, `planMode` is cleared and the pre-mode restored; on decline with a note, the note is handed back to the model and plan mode stays on. Approvals auto-deny after **120s**; `exit_plan_mode` is exempt from the normal tool timeout (30 min) because it waits on a human; subagents are explicitly denied `exit_plan_mode`.

---

## 2. Comparison

### 2.1 Enforcement model

| | opencode | dsh | **Ovid** |
|---|---|---|---|
| What restricts tools | per-agent **permissions** (allow/ask/deny) | **sandbox + approval policy**, independent of plan state | **plan-mode allowlist** (default-deny) |
| Plan state's role | agent identity | **soft prompt guidance only** | **the enforcement mechanism itself** |
| Can the model bypass by ignoring the prompt? | no — permission denies | **yes by design** ("every tool remains available") | no — dispatch gate |
| Adding a new safe tool | add to that agent's permissions | nothing to do (no gate) | **must edit the allowlist or it's blocked** |

### 2.2 State & lifecycle

| | opencode | dsh | **Ovid** |
|---|---|---|---|
| Storage | agent config | **log-only session event**, replayable, **not in transcript** | `planMode` in session JSON (`state.dart:1321`) |
| Mid-turn change | agent switch | **`queued` → applies at next in-turn pre-step** | **immediate mutation, no queue** |
| Per-run snapshot | n/a | folded via `stateOf()` | `AgentRun.planMode` — **written 5×, read 0×** ⚠️ |
| Restore previous mode | free (agent switch) | logged state | `planPreMode` ✅ |
| Enter with attachments | via `@` mention | **yes** — ordered image/file attachments | no |
| Modularity | built-in agents | **optional package; loop doesn't depend on it** | inside `agent_service.dart` (19,951 LOC) |

### 2.3 Planning identity

| | opencode | dsh | **Ovid** |
|---|---|---|---|
| Separate planning prompt | **yes** (agent system prompt) | yes (`plan:policy` section) | partial — `plan` preset persona |
| **Different model for planning** | **yes** (`model` in frontmatter) | deployment-defined | **no** — `AgentPreset` has no model field |
| Temperature / topP / maxSteps for planning | **yes** | deployment-defined | no |
| User-authored plan policies | **`opencode agent create`** + markdown files | deployment config | **hardcoded in Dart** |
| Approval of the plan | permission prompt | `exit_plan_mode` | **Plan review card + free-text "Chat about it"** ✅ |

---

## 3. Gaps, ranked

### G1 — `AgentRun.planMode` is write-only state (correctness smell) · **High confidence**

`lib/core/agent_service.dart:604` declares `bool planMode = false;` on `AgentRun`. It is **written at 5 sites** — `:1097`, `:4228`, `:8715`, `:18741`, `:18834` — and **read at 0 sites**.

The comment at `:8713-8714` states the intent:

> *"Plan mode is persisted on the session — seed the run bucket from it so gate checks inside the run see the user's last /plan state."*

But the only gate (`:11278`) reads the **live** `AgentService.planMode` getter, which resolves to `(_runSession ?? AppState.I.activeSession)?.planMode`. So the "run bucket" is never consulted. Consequences:

- The run's recorded plan policy is a lie — it goes stale the moment `planMode` changes mid-run.
- A maintainer reading `:8715` would reasonably conclude enforcement is run-scoped. It isn't.
- There is **no run-scoped plan policy at all**, so a mid-run change immediately re-gates (or un-gates) the *remaining* tool calls of the in-flight turn.

**dsh's design eliminates this class entirely**: state is log-only, and `ctx.planMode` reads it through `stateOf()` with an explicit fold, so there is exactly one authoritative source and no shadow copy.

**Fix:** either read `_runResolved.planMode` in the gate and make it the authority for the turn, or delete the field and the seeding at `:8715`. Do not keep both.

### G2 — No turn-boundary queue for plan-mode transitions · **High**

dsh's `set()` returns `queued` for a change requested during an open turn, and applies it at the next accepted in-turn pre-step. Ovid mutates `s.planMode` immediately (`:1088`, `:4264`, `:17333`, `:17342`).

This is precisely the class of edge case Ovid's own comments wrestle with — `:1090-1112` (entry order, persisted-state combos) and `:4243-4270` (the `/permission read-only` interaction). Concretely: when the user **approves** a plan, `planMode = false` takes effect at once, so every *remaining* tool call in the same turn runs outside plan mode with no record of the approved plan as the boundary.

**Fix:** mirror dsh — queue the transition and apply it at the turn boundary; surface the pending state in the UI (`{active, pending}`, exactly dsh's client projection).

### G3 — Planning cannot use a different model or sampling params · **Medium**

opencode's Plan agent carries `model`, `temperature`, `topP`, `maxSteps`. Ovid's `AgentPreset` (`presets.dart:30-60`) has only `id/label/description/allowedTools/deniedTools/persona` — **no model field**. So planning always burns the chat's model at the chat's settings, even though planning and execution are very different workloads (planning wants reasoning; execution wants speed/cheapness).

**Fix:** add an optional `model` (and `temperature`) to `AgentPreset`, applied when `planMode` is active or the `plan` preset is selected.

### G4 — The `plan` preset and plan mode are two overlapping half-mechanisms · **Medium**

`presets.dart:151-162` defines a `plan` preset with `allowedTools: []` and `deniedTools: []`, with a comment stating *"the mode gate is what enforces read-only."* So the preset contributes **only a persona string**, while enforcement lives in an unrelated hardcoded set. A user selecting the "Plan" preset gets the persona but **not** the read-only gate unless they also enter plan mode; conversely `/plan` sets the gate but not the preset persona. Two switches, one concept.

**Fix:** make the `plan` preset *drive* plan mode (selecting it sets `planMode`), or have the preset's `allowedTools` be the plan allowlist. opencode collapses these into one thing — the agent.

### G5 — Plan-mode policy is not user-authorable · **Medium**

opencode ships `opencode agent create` (interactive, deny-by-default permission picking) and markdown frontmatter files. dsh is deployment-configurable. Ovid's allowlist is a `static const Set` in a 19,951-line file — changing it requires a code change, rebuild and release. Ovid *does* already have a preset editor (`saveCustom`, `_custom`, `customPresets`) — the plumbing exists but plan policies are not routed through it.

**Fix:** let a custom preset carry the plan allowlist, and reuse the existing preset persistence.

### G6 — No attachments when entering plan mode · **Low**

dsh: `/plan` optionally takes a message **or ordered image and file attachments**. Ovid: `lib/core/commands.dart:157-176` takes `[message|off]` only.

### G7 — Plan mode is not modular · **Low (architectural)**

dsh: optional package, and *"the agent loop does not depend on it."* Ovid: gate, allowlist, tool schema, handler, preset and UI card are spread across `agent_service.dart` (19,951 LOC) and `chat_screen.dart` (8,034 LOC).

### G8 — Allowlist maintenance burden (acknowledged in-code) · **Low**

`agent_service.dart:17148-17157` documents the trade-off honestly: *"An allowlist makes the default refusal, so a new tool is blocked until someone deliberately decides it is safe to plan with."* That is the **right** call for safety, but dsh avoids the cost by separating guidance from enforcement — a new tool is simply available for reading and still bounded by the sandbox.

---

## 4. Where Ovid is ahead — do not regress these

1. **Default-deny is safer than dsh's soft guidance.** dsh's own docs say *"every tool remains available"* and that restrictions come from sandbox + approval policy configured *separately*. For an on-device agent that has `run_shell`, `device_*` (tap/type/screenshot on *other apps*) and arbitrary plugin/MCP tools, a prompt-only plan mode would be a real safety hole. Ovid's dispatch-level refusal is the stronger design.
2. **Structured plan review with free-text revision.** The "Plan review" card renders the plan as markdown and offers *Chat about it* alongside Decline/Approve; the note is handed back so the model revises rather than guesses (`agent_service.dart:17325-17332`).
3. **120s auto-deny** on the approval (`:14949-14964`) — no indefinite hang. Note the code comment records that this was once *silently auto-denied after 5s*, and was fixed.
4. **Ledger record** of the approval decision (`:17322-17329`).
5. **Subagents cannot call `exit_plan_mode`** (`_childDeniedTools`, `:8431`) — a child can't hijack the parent's composer with a plan review.
6. **Human-waiting tools are exempt from the tool timeout** (30 min, `:10111`).
7. **`planPreMode`** restores the previous mode on exit — opencode gets this free from agent switching; Ovid had to build it.

---

## 5. Recommended order

| # | Change | Effort | Why |
|---|---|---|---|
| 1 | Resolve G1 — make `AgentRun.planMode` authoritative **or** delete it | 30m | Removes a misleading shadow state; zero behaviour risk |
| 2 | G2 — queue plan-mode transitions to the turn boundary, show `{active, pending}` | 1–2d | Closes the edge-case class Ovid's comments already document |
| 3 | G4 — make the `plan` preset drive plan mode (one concept, two entry points) | 3h | Removes a confusing double switch |
| 4 | G3 — optional `model`/`temperature` on `AgentPreset` for planning | 4h | Real cost/quality lever |
| 5 | G5 — user-authorable plan policy via the existing custom-preset plumbing | 1d | No rebuild to change policy |
| 6 | G6 — `/plan` attachments | 2h | Parity |

**Deliberately not recommended:** adopting dsh's *soft-guidance* enforcement model. Its cleanliness comes from pushing enforcement into a separate sandbox/approval layer that Ovid does not have in the same form; dropping the allowlist without that layer would be a security regression.

---

*Every Ovid claim above was verified against the live tree at `a611c53`. Line numbers may drift; the surrounding comments are distinctive enough to re-locate.*
