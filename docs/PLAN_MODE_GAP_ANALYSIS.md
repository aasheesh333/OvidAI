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

---

## 6. Resolution — 2026-09-27 (opencode `plan`-agent parity)

The requirement changed: plan mode must be a **research agent over the current
directory**, and the plan must **not** be presented inside a question/approval
card.

### 6.1 What changed

| Area | Before | After |
|---|---|---|
| Plan delivery | The plan rode in the `exit_plan_mode` tool argument and was rendered in a dedicated `_PlanReviewCard` (markdown, 260 px scroll, Approve / Decline / Chat-about-it) | The plan is a **normal assistant message**. The tool argument is only a short recap. `_PlanReviewCard` is deleted; `exit_plan_mode` routes through the existing `_QuestionsCard` as **one yes/no question** |
| Exit question | "Approve this plan?" (approve/deny an artefact) | `"Plan complete. Would you like to switch to the build agent and start implementing?"` — Yes / No, i.e. opencode's `plan_exit` wording |
| Shell in plan mode | `run_shell` **refused** by the allowlist | `run_shell` **allowed** — opencode's plan agent leaves `bash` at `"*": "allow"` and denies only `edit` |
| Read-only enforcement | Gate only (tool-name based) | Gate **plus** a plan-mode system-prompt section — the `session/prompt/plan.txt` equivalent, because a shell command's effect cannot be decided from its name |
| Plan-mode briefing | None (only the `plan` preset persona, which applied only when that preset was selected) | A `planMode`-gated prompt block, so the plan command, the preset and any other entry point all get the same read-only briefing |

### 6.2 Accepted trade-off (explicit user decision)

Allowing `run_shell` in plan mode **weakens** the hard default-deny allowlist:
the gate can no longer stop a planning agent from running a mutating command.
This is deliberate — it is exactly what opencode does, and enforcement is
prompt guidance in both. Everything that mutates state *by tool identity*
(`file_write`, `fs_edit`, `commit`, `run_code`, `repo_sync`, `git_push`,
`job_start`, `preview`, every `device_*`, every plugin/MCP tool) stays refused
by the gate. Residual risk: a planning agent that ignores its instructions can
mutate the workspace through the shell. A user who wants the old hard
guarantee should not enter plan mode.

Note: plan mode also forces `mode = safe` (via the `plan` preset), and
`_maybeApprove` prompts for `run_shell` in `safe` mode — so shell research in a
plan session still asks per command unless the user taps *Always allow*.

---

## 7. Closure — 2026-09-27 (G1–G7)

§6 shipped the research-agent flow. §7 closes the gaps §5 ranked, in the order
§5 recommended (G1+G2 first, because they are the same state problem).

> **Audited 2026-09-28.** Every row below was re-checked against the working
> tree, and three claims in the first draft of this section did not survive:
> G2's Stop landing (the `finally` guard skipped it, so the flag sat in prefs
> until the next message), the G2 briefing splice (missing entirely — the roster
> is read per request, the briefing was assembled once), and G4's "exact
> projection" (the plan filter runs *after* the preset filter, and `catalogue`
> is a superset of `allowedTools` by design). The Read-Only interaction was
> missing too. Each row now names the mechanism **and** the guard or ordering
> that carries it; §7.3 lists what is still true after the fix.

### 7.1 What changed, gap by gap

| Gap | Fix |
|---|---|
| **G1** — `AgentRun.planMode` write-only (5 writers, 0 readers) | **Field deleted**, with its run-start seeding and the two subagent-inheritance writes. The session's `planMode` is the one source of truth. The inheritance line claimed a child could not mutate "while the parent is still planning", but nothing read it — and the plan gate refuses `dispatch_agent` outright (it is a harness tool, and the gate consults `PlanModePolicy.allows`, which does not exempt the harness set), so a child can never be spawned from a planning session anyway. Enforced where it can be enforced: the gate |
| **G2** — no turn-boundary queue | A plan-mode transition requested while a turn is **open** is **queued** on the session (`ChatSession.planModePending`, persisted) and landed at the **turn boundary**: `_runTaskBody`'s turn loop calls `_applyPendingPlanMode(s)` at the top of every turn, so a turn always finishes under the policy it started with (dsh's `queued`). The **unwind** path is the run's `finally`, and its guard is the whole story: `if (ownsRun || !busyFor(s.id)) { _applyPendingPlanMode(s); … }`. The second arm is the **Stop** path — `_cancelBucket` has already nulled `activeRunId`, so this run no longer owns the bucket and an `ownsRun`-only guard skipped the landing entirely, stranding the flag in prefs until the user happened to send another message (a turn late). When a Stop instead **promoted a queued continuation**, `activeRunId` is the NEW run's id and `busyFor` is true, so the new run lands the transition at its own turn boundary instead. `exit_plan_mode` **approval** applies immediately (`_applyPlanModeNow`) — an explicit user decision tied to that tool result, and the model is about to build; queueing it would lock the approved plan out of the tools it just earned. A direct access-mode pick also applies immediately. The composer chip renders `Plan…` / `Plan off…` while a transition is queued, from the persisted field, so a queued change is never silent |
| **G2 (second half — the briefing)** | The plan BRIEFING rides in the system prompt, and the system prompt is assembled **once**, before the turn loop — while the tool roster (`_tools`) is read **per request** inside `_callLlm`. So a transition landing at the boundary sent the NEW roster with the OLD briefing. Fixed with a token splice: the template carries `const planSectionToken = '<<<PLAN_MODE_SECTION>>>'` and `String buildSys() => sysTemplate.replaceAll(planSectionToken, planMode ? PlanModePolicy.promptSection : '');` re-derives the prompt from the live flag. The boundary re-derives and swaps the stale system row **in place** (index-agnostic: hook notes insert at index 0, so the system row is not reliably `msgs[0]`) and refreshes `s.systemPromptSnapshot`; the `finally` re-derives it a second time for the Stop landing, because — the code's own words — "else the transcript would record a briefing the run had already outgrown". The splice is exact in both states (the token becomes the section, or the empty string), so provider prefix caching still hits |
| **G3** — planning could not use a different model or sampling params | `AgentPreset.model` and `AgentPreset.temperature` (both nullable, persisted). Snapshotted per run at run start into `AgentRun.modelSnapshot` / `temperatureSnapshot` (`bucket.modelSnapshot = runPreset.model ?? s.model;`) — the same run-scoped seam the model already used — and sent as `temperature` in both request builders, **skipped on Anthropic runs with a thinking budget** (the API rejects the pair). `null` means "let the provider decide": no synthetic default is ever injected. A preset that pins either emits one `think` line naming the settings. The effective model is **not just the request body**: `AgentService.effectiveModelForSession(s)` (`r?.modelSnapshot ?? s.model`) is what the **context-window / compaction budget** reads (`contextWindowForSession` → `_maybeCompactLocked`, `_forceCompactLocked`, `contextUsageFraction`, the analytics `contextLimit`) and what the **usage and cost record** is written under (`UsageEntry.model`, `estimatedCostForModel`). Before that, a pin to a cheap fast model was priced as the chat model and measured against the chat model's window — compaction fired late for a small pin and early for a large one. An empty or whitespace pin is ignored: `AgentPreset.fromJson` collapses a blank `model` to `null` with a `.trim()` guard, and the Settings picker only offers ids already in `provider.models`, so a blank pin cannot be authored. (The guard is at **decode**; the run-start assignment itself is unconditional.) Residual: see §7.3 |
| **G4** — the `plan` preset and plan mode were two half-mechanisms | The dispatch gate **and** the model-visible roster read the **same resolved policy object**, `PresetRegistry.planPolicyFor(preset)`. While plan mode is on, `_tools` withholds everything the gate would refuse, so the model is never offered (or billed for) a tool it cannot use, and `exit_plan_mode` stays advertised because it is on the allowlist. The old `rosterAllows` kept *harness* tools visible regardless — `dispatch_agent` was therefore offered while being refused. That drift is gone: the roster filter is `PlanModePolicy.allows(name, policy: …)`, which does not exempt the harness set. **Two qualifiers, though, before calling it an "exact projection".** (1) The plan filter runs **after** the preset filter, so a preset's `planAllowedTools` can only SUBTRACT from that preset's roster. The code, in order, is `final gated = preset.allowedTools.isEmpty && preset.deniedTools.isEmpty ? tools : tools.where((t) { … return name != null && PresetRegistry.allows(preset, name); }).toList();` and then `final planGated = planMode ? gated.where((t) { … return name != null && PlanModePolicy.allows(name, policy: PresetRegistry.planPolicyFor(preset)); }).toList() : gated;`. A plan allowlist therefore cannot re-add a tool the preset's `deniedTools` (or its `allowedTools` allowlist) removed. (2) `PlanModePolicy.catalogue` is a deliberate **superset** of `allowedTools` — five entries (`commit`, `file_write`, `fs_edit`, `repo_sync`, `run_code`) are on it precisely so a user can author a **wider** custom policy — so a catalogue entry is not a promise that the gate allows it |
| **G5** — policy not user-authorable | `AgentPreset.planAllowedTools`: a custom preset may carry its **own** plan allowlist, which **replaces** the built-in one while that preset is planning (a replacement, not an additive escape from default-deny). Resolved in exactly one place, `PresetRegistry.planPolicyFor`, shared by the gate and the roster. Edited in Settings → Agent Presets → duplicate a preset (the picker block renders for custom presets only), with chips drawn from `PlanModePolicy.catalogue` |
| **G6** — no attachments when entering plan mode | Attachments staged in the composer already rode along (the `/plan` prompt goes through `_sendPrompt` → `runTask`, which stamps and consumes them). What was missing was visibility and a guarantee: the command now reports *"Plan mode on — N attachments will be included"*, and a test pins that `/plan` does not clear them |
| **G7** — not modular | New `lib/core/plan_mode.dart` holds `PlanModePolicy`: the allowlist, the harness set, the briefing text, the resolution helper (`allows(name, {policy})`) and the settings catalogue (+ `readOnlyBlocked`). `agent_service.dart` and `presets.dart` import it; the service's allowlist is now a named alias for the module's set, and the prompt interpolates `PlanModePolicy.promptSection` through `buildSys()`. One definition, four consumers (gate, roster, briefing, the Settings picker) |
| **Read-Only × the plan policy** (missing from the first draft) | The `plan` preset forces `mode = safe`, so every plan run is also a Read-Only run and hits `AgentService._readOnlyBlock` **after** the plan gate. `PlanModePolicy.readOnlyBlocked` = `{commit, file_write, fs_edit, run_code}` names the catalogue entries that gate refuses outright, and the picker renders them with a `*` + footnote. Detail and residual: §7.2 |

### 7.2 The Read-Only interaction (added 2026-09-28)

`PlanModePolicy.readOnlyBlocked` exists because the plan policy is
user-authorable and may be widened past what planning needs, while
`_readOnlyBlock` is an independent hard gate: the `plan` preset forces
`mode = safe`, so ticking one of these in a custom plan allowlist would
advertise a tool to the model and then have dispatch reject it — exactly the
roster/gate drift this module exists to remove.

- **Which four, and why.** Of the 43 `catalogue` names, exactly `commit`,
  `file_write` and `run_code` appear in `_readOnlyBlock`'s unconditional
  `case` list. `fs_edit` is refused for every use the picker advertises: the
  gate lets only its `view` subcommand through, and the catalogue entry IS the
  editing use. The remaining catalogue entries either fall through the switch
  (`default: return null`) or are decided by argument (`run_shell`,
  `browser_cookies`).
- **How it is surfaced.** The Settings picker renders `'$tool*'` for a
  `readOnlyBlocked` name and prints the footnote: *"Read-Only mode refuses this
  outright — and the plan preset forces Read-Only — so ticking it only widens
  the plan policy; Read-Only still blocks it. (`run_shell` carries no marker:
  Read-Only runs its read-only commands.)"* — a labelling fix: the chip's
  selection logic and the saved value are untouched.
- **Why `run_shell` carries no marker.** `_readOnlyBlock` runs
  `_isReadOnlyCommand` and refuses only the mutating commands, so ticking it in
  a custom plan policy genuinely takes effect; marking it would be a lie in the
  other direction. (In `safe` mode `_maybeApprove` still asks per command
  unless auto-run-safe covers a read-only command or the user taps *Always
  allow*.)
- **Residual.** `repo_sync` is the one mutating catalogue entry that is neither
  on the built-in plan allowlist **nor** refused by `_readOnlyBlock` (it is not
  in that switch, so it falls to `default: return null`). It carries no `*`
  because the marker mirrors the Read-Only gate, not the plan gate — so a
  custom plan policy that ticks it gets no warning. And there is **no approval
  prompt to fall back on**: `repo_sync`'s handler does not call
  `_maybeApprove` — unlike `file_write`, `commit`, `git_clone`/`git_push`/
  `git_pull`, `fs_edit` (create/str_replace/insert), `run_shell` and
  `browser_open`/`browser_navigate`/`browser_new_tab` — so a Read-Only
  session that dispatches it performs a network fetch plus workspace writes
  with no user prompt. The repo tools are registered on the `githubSync`
  toggle alone, with no access-mode gate (unlike `device_*`, which the
  roster omits outside Control mode).

### 7.3 Residuals — what is still true after §7

- **G2.** No functional residual. The post-Stop landing is designed to be a
  no-op when the Stop promoted a continuation (`busyFor` is true, the promoted
  run lands it at its own boundary), so the transition is never lost — it lands
  one turn later, in the run that is actually streaming.
- **G3.** `AgentRun.modelSnapshot` is what the **request body, the context
  budget and the usage/cost record** read, but the hook payloads still pass
  `model: s.model` (the session's chat model) at every hook site
  (`user_prompt_submit`, `pre_request`, `stop`, `pre_tool`,
  `permission_request`, `notification`, `pre_compact`/`post_compact`), and
  `HookService` writes that value into the payload JSON as `'model': ?model`
  (also exported as `PLUGIN_MODEL`). The `session_search` index likewise stores
  `model: s.model`. A plugin that reports "the model" for a planning run
  therefore sees the chat model, not the pin.
- **G4.** (a) The ordering asymmetry in §7.1 is real and by design: a plan
  allowlist subtracts, it cannot re-add. (b) `catalogue` ⊃ `allowedTools` is
  deliberate. (c) `PlanModePolicy.rosterTools` and
  `PlanModePolicy.rosterAllows` are now **unused in production** — their only
  references are the module itself and a comment in the test — and they still
  encode the old "harness tools are always visible" rule. Re-wiring the roster
  through `rosterAllows` would restore the drift the G4 fix removed.
- **G5.** A custom policy is a **replacement**: a user who authors one gets no
  built-in entries at all (the chips start unchecked), so the `*` footnote is
  the only warning that Read-Only still refuses four of them.
- **G8.** Acknowledged, not closed — see the status table below.

### 7.4 Gap status after §7

| Gap | Status |
|---|---|
| G1 | **Closed** (field removed; one source of truth) |
| G2 | **Closed** (turn-boundary queue, unwind landing under `ownsRun || !busyFor`, UI projection, briefing re-derived with the roster) |
| G3 | **Closed for the request, the budget and the billing** (per-preset model + temperature, run-snapshotted). Residual: hook payloads and the session-search index still name the session's chat model (§7.3) |
| G4 | **Closed, with two qualifiers** — the roster withholds everything the gate refuses and the harness-tool drift is gone, but the plan filter runs after the preset filter and `catalogue` is a deliberate superset (§7.1) |
| G5 | **Closed** (per-preset plan allowlist, one resolution point) |
| G6 | **Closed** (verified + surfaced + tested) |
| G7 | **Closed** (`lib/core/plan_mode.dart`) |
| G8 | **Acknowledged, not closed.** The allowlist still needs maintenance as tools are added. Default-deny means a new tool is refused until someone deliberately allows it — which is the safe direction. The catalogue in `plan_mode.dart` is now the one place to look |

### 7.5 Tests

- **New** `test/plan_mode_policy_test.dart` — one group per gap: G1 (no
  `run.planMode =` / `_runFor(child.id).planMode` / `_runResolved.planMode`
  anywhere in the source, plus the session field is authoritative), G2 (queue vs
  immediate, the boundary landing, approval opens the gate now, the pending flag
  round-trips), G3 (pin round-trip, `0.0` survives as a real value, the run
  snapshot exists), G4 (the roster hides every gate-refused tool while planning
  and restores it after), G5 (a custom policy replaces the built-in one and is
  still a replacement), G6 (staged attachments survive), G7 (the service
  allowlist *is* the module set; the preset harness set *is* the module set; the
  briefing splice is pinned at all three halves — the token literal, its use in
  the template and the `buildSys()` swap; the `readOnlyBlocked` label matches
  the Read-Only gate it mirrors).
- **What the suite does *not* pin** (read, not run — see below): the G4
  ordering (§7.1) and the G3 decode-time `.trim()` guard are stated in this
  document and verified by inspection, but no test asserts either. The
  `rosterTools` / `rosterAllows` leftovers are not flagged by any test either.
- **Audited (2026-09-28)** — the suite is hermetic and every assertion is
  falsifiable. `setUp` pins `SessionLedger.rootOverrideForTest` to a scratch
  temp dir (no repo writes, no path_provider channel) and `tearDown` releases
  the process-global run bucket / run-session override / staged attachments /
  custom presets. No test dispatches a mutating tool: a gate that wrongly let
  one through would really write into the repo, so "allowed" is asserted
  through the roster projection and `PlanModePolicy` instead. Fixed in the same
  pass: G7's briefing check asserted a `${planMode ? … }` interpolation literal
  that appears nowhere in `agent_service.dart` (the source splices the section
  through the `<<<PLAN_MODE_SECTION>>>` token and a plain-Dart ternary in
  `buildSys()`), so it could never pass; G4 now asserts the policy before the
  roster so its loop cannot pass vacuously for a feature-gated tool; and the
  "the gate is open once planMode is off" probe in the allowlist suite was
  not hermetic — in `auto` mode `run_shell` auto-approves and really
  EXECUTES, so it now probes `commit`, whose handler returns "no pending
  changes" before it can push.
- **Updated** `test/plan_mode_allowlist_test.dart` (the probe swap above;
  its other `run_shell`/mutating assertions still hold against the module
  set) and `test/core_regression_test.dart` (the plan-preset comment now
  describes the G4 roster projection).

*Verification: static only. Every claim in §7 was re-checked against the working
tree by grep and by set comparison over `plan_mode.dart`'s declarations
(`catalogue` vs `allowedTools`, `catalogue` vs `_readOnlyBlock`'s unconditional
`case` list, the `finally` guard, the `buildSys()` splice, the
`effectiveModelForSession` call sites), and each row above is written so it can
be re-checked by one grep or one set comparison. `flutter analyze` and
`flutter test` were not run locally (no Dart/Flutter SDK on this host); CI is
the verifier.*
