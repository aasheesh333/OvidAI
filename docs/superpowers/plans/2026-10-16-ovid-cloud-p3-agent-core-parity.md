# Ovid Cloud P3 — Agent-Core Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision 2026-10-16 (pre-flight findings 1–14 + controller rulings R1–R5).** Execution order is **P2 BEFORE P3**: P2's Task 12 lands the tool-capable worker (RunDeps fields, transport, six-tool roster) and OWNS those files — this plan BUILDS ON that landed seam (R1). The canonical tool seam is P2's `AgentTool`, additively extended: `execute(args, ctx) → ToolResult { content, isError?, artifacts? }` (R2). Cache breakpoints are wired into the request path by Task 15, not unit-only (R3). `SessionAgentState` gains `mode`, `modelPin`, `activeSkillScopes` additively (R4). The P3-Q5 event count is restated in Task 12 against P2's already-landed `tool_*` members (R5).

**Goal:** Build `cloud/packages/agent-core` — the faithful TS port of `lib/core/agent_service.dart` loop semantics (spec §6.1 agent-core bullet) — and replace the worker's **P2 interim v1 tool loop** (P2 Task 12: bounded `MAX_TOOL_ROUNDS=50` loop, six-tool roster, `SYSTEM_PROMPT_V1`) with the full never-stop engine: dual transports, prompt-cache-stable prefix, tool roster with mode/plan/preset/subagent gates, tool implementations not covered by P2, WS approvals with a hierarchical grant store, subagents, lossless compaction, and the full hooks engine — every mechanism proven by Vitest cases ported from the named Dart tests (AG4).

**Architecture:** New package `@ovid/agent-core` (dependency direction: apps → packages only). The engine is composed entirely of injected ports (sandbox, approvals, hooks, compactor, state store, skills, egress, keys) so every mechanism is unit-testable with fakes; `apps/worker` owns the adapters (P2 SandboxManager → `SandboxPort`, Redis pub/sub → `ApprovalBridge`, mint `KeyProvider` → `KeyResolver`, P2 `AgentTool` roster → the canonical `Tool` seam). **P2 lands first and owns the worker files it touched** (R1): `RunDeps` there gains required `sandbox: SandboxManager` + `tools: ToolRegistry`, `liteLlm.ts` is tool-capable (`ChatMessage` role `"tool"`/`toolCalls`, `ModelTransport` returns `toolCalls`), and the six-tool roster (`run_shell, read_file, write_file, edit_file, glob_files, grep_files`) is live. P3 **builds on** that seam: the compatibility processor keeps P2's landed `RunDeps` shape and pinned behaviors (`SYSTEM_PROMPT_V1`, `MAX_TOOL_ROUNDS=50`, `tool_rounds_exhausted`, `sandbox_unavailable`) while a new `createFullAgentRunProcessor` wires the production engine with the P2 roster **adapted in additively alongside** P3's additional tools (P3 never re-implements or removes P2's six). The canonical tool seam (R2, binding P3/P5/P6) is P2's `AgentTool` additively extended: `execute(args, ctx) → ToolResult { content, isError?, artifacts? }` — `artifacts` is the optional additive channel for browser/file outputs (P6's `BrowserToolDef` bridges onto it via an adapter over its `execute(ctx)` closure; P5 registers MCP tools through the same seam). Subagents run as **in-process child loops** (decision + justification in Task 20), not nested BullMQ jobs. BYOK escrow storage lands in P9; P3 pins the `KeyResolver` seam (LiteLLM virtual-key path now, escrow path swapped later).

**Tech Stack:** Node 22, pnpm workspaces, TypeScript strict, Vitest, Drizzle ORM (postgres.js), BullMQ 5, ioredis, zod, `@ovid/{shared,db,events,queue}` (P1), P2 SandboxManager exec/PTY API and P2 worker tool seam (both consumed only through adapters in `apps/worker`).

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` — §6.1 agent-core bullet (the parity list), AG4 (the Dart test suite in `test/` is the behavioral contract), D3/D5, §8 (unattended approval behavior), §11 (SSRF-guarded egress). Dart reference modules: `lib/core/{agent_service.dart,plan_mode.dart,claude_code_tools.dart,grant_store.dart,structured_edits.dart,ssrf_guard.dart,prompt_cache.dart,subagent_tools.dart,skills.dart,presets.dart,commands.dart,hook_service.dart,session_search.dart,memory_store.dart,compaction/*.dart}`. Where Dart behavior and the spec conflict, the spec wins; record the deviation in a code comment.

## Global Constraints

- Wire format: JSON, **camelCase**; ids are **UUIDv7** (time-sortable); timestamps ISO-8601 UTC.
- New code only under `cloud/`; deploy target `/opt/ovid-cloud`. Never edit `/opt/ovid-gateway/docker-compose.yml` or the live Caddyfile without a timestamped backup + `docker compose config` / `caddy validate` check first.
- Route prefix: all new HTTP under `/cloud/v1/*`; WS at `/cloud/ws`. Gateway binds `127.0.0.1:8081`.
- Redis split (AG3): `redis-q` (BullMQ + Streams + tickets + the P3 approval pub/sub channel) runs `maxmemory-policy noeviction`; caches go to a separate instance. Tests use disposable services (`TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390` via `cloud/scripts/dev-services.sh`), never the live ones.
- Auth on every REST/WS handshake: Firebase ID token + App Check (firebase-admin). Dev/test bypass `OVID_AUTH_MODE=test` (header `x-test-uid`); gateway must refuse to start with test mode when `NODE_ENV=production`.
- Retry policy for model calls (spec §6.1): 5 attempts, backoff 3/9/27/60 s, transient = network error, 429, 5xx (Anthropic: also 529 `overloaded_error`); 4xx (except 429) is terminal.
- Event ordering guarantee: per-session monotonic `seq` (Redis Stream ID); clients replay with `lastEventId` and dedupe by `seq`.
- Error envelope (REST): `{ "error": { "code": string, "message": string } }`; P1 codes stay valid; P3 adds `bad_request` for malformed approval responses.
- Commit after every task; run `pnpm -r build && pnpm -r test` from `cloud/` before committing.
- **ADDITIVE-only protocol changes:** never remove, rename, or change the semantics of existing `SessionEventType` members, `WsClientMsg`/`WsServerMsg` ops, or zod schemas in `@ovid/shared`. `cloud/apps/e2e/src/spine.test.ts` must pass **unmodified** through all of P3. A tool-less run must emit exactly the P1 sequence `run_started, message_delta+, message_completed, run_completed` — new event types may only fire when the corresponding mechanism actually engages.
- **Dependency direction:** `packages/*` never import from `apps/*`; `@ovid/agent-core` imports only `@ovid/{shared,db,events,queue}` + npm deps (pinned by a static test in Task 1). `KeyProvider`-style interfaces live in `@ovid/shared` (P1 ledger ruling, row 1).
- **P1+P2 suites stay green UNMODIFIED (R1):** `cloud/apps/worker/src/liteLlm.test.ts` and `runProcessor.test.ts` — P1 cases plus P2's Task-12 tool-call additions — keep passing (liteLlm.ts becomes a re-export shim in Task 4 over the P2 tool-capable contract); **P2's suite stays green unmodified** — tests may be EXTENDED additively, never rewritten. `RunDeps`/`ModelTransport`/`ChatMessage` references mean P2's landed shapes, not P1's v0 shapes.
- **AG4:** every ported mechanism carries ported Vitest cases derived from the Dart tests named in that task; a ported case that cannot hold in the cloud (on-device UI, control mode) is deleted-with-comment, never silently dropped.
- **D5:** `device_*` tools and Control mode never exist in the cloud roster; voice stays client-side.
- **Production boundary:** P3 never deploys, never touches `/opt/ovid-cloud`, the live gateway stack, or non-disposable containers.
- **8c/22GB box (ledger 2026-10-16):** no unbounded in-memory transcript growth — spill caps, compaction, and sequential (never parallel) subagent child loops are the memory discipline.

## Review Focus

1. **Approval answered after auto-deny fired** — a WS `approval_response` (or a second response) arriving after the 120 s timeout resolved must be a no-op: first decision wins, a late `always` never writes a grant, and exactly one `approval_resolved` event exists. Pinned by Task 12 tests (`approvalBridge` race case).
2. **Orphaned jail processes after tool timeout/cancel** — a timed-out or cancelled tool call must kill exactly that call's processes (`killCall(callKey)`) and its result must never reach the model; a run cancelled mid-tool leaks no writer into the workspace. Pinned by Task 9 tests (ported from `test/tool_timeout_cancel_test.dart`).
3. **Prompt-prefix drift silently killing provider cache** — any per-request volatility (timestamps, unsorted tools, hook notes inside the stable block) makes the prefix non-byte-identical and burns cost. Expected: system+tools bytes identical across two turns that include tool traffic; volatile context always last and never cache-marked. Pinned by Tasks 3/7 tests (ported from `test/prompt_cache_test.dart`) and — the request-path WIRING, ruling R3 — by Task 15's cache-stable request test (sorted tools + ≤4 marks on the captured `AgentRequest` end to end).
4. **SSRF via redirect hop or mixed DNS answers** — a granted public host that 302s to `169.254.169.254`, or a name resolving to public+private addresses, must be refused on every hop; only ports 80/443. Pinned by Tasks 2/10 tests (ported from `test/security_ssrf_guard_test.dart`).
5. **Steering message lost or answered twice** — a prompt POSTed mid-run joins the active run exactly once; its queued run row is claimed so the BullMQ delivery no-ops; the P1 double-send e2e stays green unmodified. Pinned by Tasks 14/16 tests (ported from `test/queue_inject_run_test.dart`, `test/chat_data_loss_safety_test.dart`).

---

### Task 1: `@ovid/agent-core` scaffold — domain types + ports

**Files:**
- Create: `cloud/packages/agent-core/package.json`, `cloud/packages/agent-core/tsconfig.json`, `cloud/packages/agent-core/src/index.ts`
- Create: `cloud/packages/agent-core/src/types.ts`, `cloud/packages/agent-core/src/ports.ts`
- Test: `cloud/packages/agent-core/src/types.test.ts`, `cloud/packages/agent-core/src/dependencyDirection.test.ts`

**Interfaces:**
- Consumes: P1 workspace conventions (`cloud/tsconfig.base.json`, `@ovid/shared` `SessionEvent`/`SessionEventType`, `@ovid/db` `Db`, `@ovid/events` `EventLog`).
- Produces (every later task imports these exact names):

```ts
// types.ts
export type SessionMode = "safe" | "auto" | "drive" | "studio";
export interface ToolCall { id: string; name: string; args: Record<string, unknown>; }
export interface AgentMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
  toolCallId?: string;        // role:"tool" — the ToolCall.id this answers
  toolCalls?: ToolCall[];     // role:"assistant"
  volatile?: boolean;         // true → never cache-marked, rides last (Task 3/7)
  cacheControl?: { type: "ephemeral"; ttl?: "5m" | "1h" };   // the typed home for Task 3's CacheMark — set ONLY by markCacheBreakpoints, serialized by the transports (Task 5 anthropic blocks; Task 15 wiring)
}
export interface ToolSpec { name: string; description: string; parameters: Record<string, unknown>; } // JSON Schema object
// CANONICAL TOOL SEAM (ruling R2 — binding P3/P5/P6): P2's AgentTool, additively extended.
// The result carries {content, isError?, artifacts?} — artifacts is the optional additive channel for
// browser/file outputs (P6 BrowserToolDef adapts onto this; P5 MCP tools register through it).
export interface ToolResult { content: string; isError?: boolean; artifacts?: unknown[]; }
export interface ToolContext {
  sessionId: string; runId: string; userId: string;
  mode: SessionMode; planMode: boolean; isSubagent: boolean; depth: number;
  unattended: boolean; callKey: string; signal: AbortSignal;
}
export interface Tool { spec: ToolSpec; timeoutMs: number; execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult>; }
// tool factories below return ToolResult; where a test pins a plain string it means result.content
export interface ToolRegistry { get(name: string): Tool | undefined; all(): readonly Tool[]; }
export function createToolRegistry(tools: readonly Tool[]): ToolRegistry;
export interface Usage { inputTokens: number; outputTokens: number; cacheReadTokens?: number; cacheWriteTokens?: number; }
export interface AgentRequest {
  model: string; baseUrl: string; apiKey: string;
  system: AgentMessage[]; messages: AgentMessage[]; tools: ToolSpec[];
  maxTokens?: number; temperature?: number; effort?: "low" | "medium" | "high";
  cacheMode: PromptCacheMode;              // defined HERE in types.ts (Tasks 3/5/6 consume — do NOT redefine in promptCache.ts); export type PromptCacheMode = "none" | "implicit" | "openaiBlocks" | "anthropicNative";
}
export interface AgentStreamHandlers { onTextDelta(text: string): void; onThinkingDelta?(text: string): void; }
export interface AgentResponse { content: string; thinking: string; toolCalls: ToolCall[]; finishReason: string | null; usage: Usage | null; }
export interface AgentTransport { readonly apiFormat: "openai" | "anthropic"; stream(req: AgentRequest, h: AgentStreamHandlers, signal: AbortSignal): Promise<AgentResponse>; }

// ports.ts
export interface SandboxPort {            // adapter over the P2 SandboxManager exec/PTY API lives in apps/worker (Task 9)
  exec(userId: string, o: { cmd: string; cwd?: string; timeoutMs?: number; callKey?: string; env?: Record<string, string> }): Promise<{ exitCode: number; stdout: string; stderr: string }>;
  killCall(userId: string, callKey: string): Promise<void>;
  readFile(userId: string, path: string): Promise<string>;
  writeFile(userId: string, path: string, content: string): Promise<void>;
  exists(userId: string, path: string): Promise<boolean>;
  listDir(userId: string, path: string): Promise<string[]>;
  jobStart(userId: string, o: { cmd: string; cwd?: string }): Promise<{ jobId: string }>;
  jobOutput(userId: string, jobId: string, o?: { offset?: number }): Promise<{ output: string; running: boolean; exitCode: number | null }>;
  jobList(userId: string): Promise<Array<{ jobId: string; cmd: string; running: boolean }>>;
  jobKill(userId: string, jobId: string): Promise<void>;
}
export type EgressFetch = (url: string, init?: RequestInit) => Promise<Response>;   // SSRF-guarded (Task 2)
export type ApprovalDecision = "allow" | "deny" | "always";
export interface ApprovalRequest {
  approvalId: string; kind: "tool" | "question" | "plan"; tool: string;
  summary: string; detail: string; allowAlways: boolean;
  pathTargets: string[]; hostTargets: string[];
  questions?: Array<{ question: string; options?: string[] }>;
}
export interface ApprovalBridge {         // worker implements over session events + Redis pub/sub (Task 12)
  ask(req: ApprovalRequest, o: { sessionId: string; userId: string; timeoutMs: number; signal: AbortSignal }): Promise<ApprovalDecision | "timeout">;
}
export interface ApprovalGate {           // grants + bridge + events (Task 12)
  approve(ctx: Pick<ToolContext, "sessionId" | "runId" | "userId" | "mode" | "planMode" | "unattended" | "signal">, req: ApprovalRequest): Promise<ApprovalDecision>;
}
export type HookEvent = "session_start" | "user_prompt_submit" | "pre_request" | "post_request" | "pre_tool" | "post_tool" | "stop" | "subagent_stop" | "notification";
export interface HookGateResult { decision: "allow" | "deny" | "ask"; updatedInput?: Record<string, unknown>; reason?: string | null; bypassPermission?: boolean; decidedByPlugin?: string | null; deniedByPlugin?: string | null; }
export type HookStopResult = { veto: false } | { veto: true; reason: string | null; vetoedByPlugin: string | null };
export interface HookEngine {
  hasListeners(event: HookEvent, sessionId: string): Promise<boolean>;
  fire(event: HookEvent, sessionId: string, payload: Record<string, unknown>): Promise<void>;                       // observe-only
  fireDetailed(event: HookEvent, sessionId: string, payload: Record<string, unknown>): Promise<{ output: string; systemMessages: string[]; promptBlockReason: string | null }>;
  fireGate(sessionId: string, payload: { tool: string; args: Record<string, unknown> }): Promise<HookGateResult>;   // pre_tool
  fireStop(sessionId: string, payload: Record<string, unknown>, event?: "stop" | "subagent_stop"): Promise<HookStopResult>;
  sessionContextFor(sessionId: string): string;
  promptContextFor(sessionId: string): string | null;
}
export interface Compactor {              // Task 19
  maybeCompact(i: { sessionId: string; messages: AgentMessage[]; windowTokens: number }): Promise<{ compacted: boolean; messages: AgentMessage[] }>;
  pruneOversizedToolResults(i: { sessionId: string; messages: AgentMessage[]; thresholdTokens: number }): Promise<{ pruned: number; messages: AgentMessage[] }>;
}
export interface TodoItem { content: string; status: "pending" | "in_progress" | "completed"; }
export interface SessionGoal { objective: string; notes: string; }
export interface CompactionStateJson { ledger: unknown; summary: string | null; cutoffMessageId: string | null; compactedAtCount: number; }
// ADDITIVE state fields (ruling R4): mode/modelPin give /permission and /model pinning storage;
// activeSkillScopes gives the skill tool (Task 17) its roster-scoping home. Dart's agent state is
// the parity reference for todos/goal/preset/plan fields; these three are cloud-session additions.
export interface SessionAgentState { todos: TodoItem[]; goal: SessionGoal | null; presetId: string | null; planMode: boolean; planPreMode: SessionMode | null; pendingPlanMode: boolean | null; compaction: CompactionStateJson | null; mode: SessionMode; modelPin: string | null; activeSkillScopes: string[]; }
export interface SessionStateStore {      // Task 13 (Postgres); in-memory fake for earlier tasks
  get(sessionId: string): Promise<SessionAgentState>;
  patch(sessionId: string, p: Partial<SessionAgentState>): Promise<void>;
}
export function createMemoryStateStore(): SessionStateStore;   // test/dev fake, exported for reuse
export interface SkillSummary { name: string; description: string; whenToUse: string; userInvocable: boolean; modelInvocable: boolean; }
export interface Skill { name: string; description: string; whenToUse: string; content: string; path: string; allowedTools: string[]; }
export interface SkillCatalog {           // Task 17
  list(sessionId: string): Promise<SkillSummary[]>;
  load(name: string, sessionId: string): Promise<Skill | null>;
}
export interface EventSink { emit(type: SessionEventType, payload: Record<string, unknown>): Promise<void>; }
export interface GitHubApiPort {          // Task 11
  getTree(userId: string, o: { owner: string; repo: string; ref?: string; recursive?: boolean }): Promise<Array<{ path: string; type: "blob" | "tree"; size?: number }>>;
}
```

- [ ] **Step 1: Write failing tests.** `types.test.ts`: `createToolRegistry([a,b])` — `get("a")` returns the tool, `get("missing")` is `undefined`, `all()` preserves insertion order (roster sorting happens later, in Task 8 — registry is a lookup, not an orderer). `createMemoryStateStore()` — `get` on an unknown session returns the zero state `{todos:[],goal:null,presetId:null,planMode:false,planPreMode:null,pendingPlanMode:null,compaction:null,mode:"auto",modelPin:null,activeSkillScopes:[]}` (mode default `"auto"` per Dart state.dart:1611); `patch` merges shallowly. `dependencyDirection.test.ts`: recursively read every `*.ts` under `cloud/packages/agent-core/src` and assert no import specifier matches `apps/`, `@ovid/gateway`, or `@ovid/worker` (dependency-direction constraint, machine-checked forever).
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm install && pnpm --filter @ovid/agent-core test` — Expected: FAIL (module not found).
- [ ] **Step 3: Implement.** `package.json` mirrors `@ovid/db`'s (name `@ovid/agent-core`, `type: module`, `build: tsc -p tsconfig.json`, `test: vitest run`, deps `@ovid/shared`, `@ovid/db`, `@ovid/events`, `zod`, `workspace:*` where used). `types.ts` + `ports.ts` exactly as the Produces block; `index.ts` re-exports both. No runtime logic beyond `createToolRegistry` and `createMemoryStateStore`.
- [ ] **Step 4: Verify pass.** `pnpm --filter @ovid/agent-core test` → PASS; `pnpm -r build` → OK.
- [ ] **Step 5: Commit.** `git add cloud/packages/agent-core && git commit -m "feat(cloud): agent-core scaffold — domain types, ports, dependency-direction guard"`

### Task 2: SSRF-guarded egress client

**Files:**
- Create: `cloud/packages/agent-core/src/ssrf.ts`
- Test: `cloud/packages/agent-core/src/ssrf.test.ts`
- Dart sources: `lib/core/ssrf_guard.dart`; ported cases from `test/security_ssrf_guard_test.dart`, `test/browser_scheme_guard_test.dart` (scheme allowlist cases only).

**Interfaces:**
- Consumes: nothing (pure + injected resolver/fetch).
- Produces:

```ts
export class SsrfBlockedError extends Error {}                       // message names the offending address/literal
export function isNonPublicAddress(ip: string): boolean;             // IPv4: 0.0.0.0/8, 10/8, 100.64/10 (CGNAT+metadata), 127/8, 169.254/16, 172.16/12, 192.168/16; IPv6: ::1, fc00::/7, fe80::/10, fec0::/10, ff00::/8, ::ffff:<v4> mapped (classify the v4); 0.0.0.0 and "::" included
export type SsrfResolver = (host: string) => Promise<string[]>;      // every A/AAAA record
export interface SsrfGuard {
  assertSafeUrl(rawUrl: string): Promise<URL>;                       // throws SsrfBlockedError; http/https only; port 80/443 only (explicit or default); IP-literal hosts classified directly; named hosts resolved (4 s lookup timeout) — refuse if ANY address is non-public; resolver failure = refuse (fail-closed)
  checkHost(host: string): Promise<boolean>;                         // true = safe (used per redirect hop and by the host-grant flow)
}
export function createSsrfGuard(o?: { resolver?: SsrfResolver; lookupTimeoutMs?: number }): SsrfGuard;   // default resolver = node:dns/promises lookup(all); default timeout 4000
export function createGuardedEgressFetch(guard: SsrfGuard, fetchImpl?: typeof fetch, maxRedirects?: number): EgressFetch; // manual redirect handling: assertSafeUrl on EVERY hop (default max 5, then SsrfBlockedError); AbortSignal passthrough
```

- [ ] **Step 1: Write failing tests** (port `security_ssrf_guard_test.dart` case-by-case): literals — `http://10.0.0.1/`, `http://192.168.1.1/`, `http://169.254.169.254/latest/meta-data/`, `http://127.0.0.1:8080/`, `http://[::1]/`, `http://100.64.0.1/`, `http://0.0.0.0/` all throw `SsrfBlockedError`; public literal `https://93.184.216.34/` passes. Stub resolver: host resolving to `["93.184.216.34","127.0.0.1"]` (mixed record set) refuses; all-public passes; resolver throwing refuses (fail-closed); resolver hanging > `lookupTimeoutMs` refuses. Scheme: `file://`, `ftp://`, `gopher://` refuse. Port: `https://example.com:8443/` refuses, `:443`/`:80`/default pass. `createGuardedEgressFetch` against a local `http.createServer` on 127.0.0.1 (guard stubbed with an allow-all-except-metadata resolver): 302 from allowed host → `http://169.254.169.254/` is blocked and the fetch rejects `SsrfBlockedError`; 302 → another allowed host follows; 6 chained redirects → blocked at `maxRedirects`.
- [ ] **Step 2: Verify fail** (`pnpm --filter @ovid/agent-core test ssrf`) → module not found.
- [ ] **Step 3: Implement `ssrf.ts`.** Address classification via `node:net` `isIP` + byte parsing (port the exact prefix list from `ssrf_guard.dart` lines 45–110 — including CGNAT `100.64/10` and IPv4-mapped IPv6). DNS via `dns/promises.lookup(host, { all: true, verbatim: true })`.
- [ ] **Step 4: Verify pass.** `pnpm --filter @ovid/agent-core test` → PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): agent-core SSRF guard — DNS-resolution check, per-hop redirect guard, port allowlist"`

### Task 3: Prompt-cache-stable prefix

**Files:**
- Create: `cloud/packages/agent-core/src/promptCache.ts`
- Test: `cloud/packages/agent-core/src/promptCache.test.ts`
- Dart sources: `lib/core/prompt_cache.dart` (pure functions); ported cases from `test/prompt_cache_test.dart`.

**Interfaces:**
- Consumes: `ToolSpec`, `AgentMessage`, `PromptCacheMode` (Task 1).
- Produces:

```ts
export const MAX_CACHE_BREAKPOINTS = 4;
export type PromptCacheOverride = "auto" | "on" | "off";
export function parsePromptCacheOverride(raw: string | null | undefined): PromptCacheOverride; // unknown → "auto"
export function cacheModeFor(apiFormat: "openai" | "anthropic", isNativeAnthropic: boolean, override: PromptCacheOverride): PromptCacheMode;
// "off" → none; native anthropic + on/auto → anthropicNative; openai-format with claude-route marker + on → openaiBlocks; else implicit
export function canonicalTools(tools: readonly ToolSpec[]): ToolSpec[];        // sorted by name (byte-stable order)
export function canonicalJson(value: unknown): string;                        // JSON.stringify with recursively sorted object keys — THE canonical serializer (canonicalToolJson is this applied to tool specs); Task 14 reuses it for guard canonArgs
export function canonicalToolJson(tools: readonly ToolSpec[]): string;         // canonicalJson(tools) — the byte-stability contract
export function markCacheBreakpoints(system: AgentMessage[], messages: AgentMessage[], tools: ToolSpec[]): { system: AgentMessage[]; messages: AgentMessage[]; tools: ToolSpec[] };
// ≤4 breakpoints, placed last-first: final tool, final system block, last two non-volatile messages; volatile:true messages are NEVER marked; marks are idempotent
// CacheMark has NO interface of its own — marks live on AgentMessage.cacheControl (Task 1), which is what transports serialize into Anthropic blocks; Task 15 wires this into the request path
```

- [ ] **Step 1: Write failing tests** (port `prompt_cache_test.dart`): `canonicalTools` sorts by name regardless of input order; `canonicalJson` is byte-identical for `{a:{y:1,x:2}}` vs `{a:{x:2,y:1}}` key orders (recursive key sort) and for arbitrary arg objects (Task 14 reuse); `markCacheBreakpoints` marks at most 4 positions, always the LAST tool and LAST system block, never a `volatile:true` message; marking twice is a no-op (idempotent); `parsePromptCacheOverride("OFF")` → `"off"`, garbage → `"auto"`; `cacheModeFor("anthropic", true, "auto")` → `"anthropicNative"`, `("openai", false, "auto")` → `"implicit"`, `("openai", true, "on")` → `"openaiBlocks"` (the claude-route marker branch, pinned), `(_, _, "off")` → `"none"`. Byte-stability pin (Review Focus #3): build the same request twice with an extra tool-result message appended — `canonicalToolJson` output and the stable system block bytes are identical across both.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (pure module, no I/O — mirror `prompt_cache.dart` structure) → **Step 4: Verify pass** (`pnpm --filter @ovid/agent-core test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): agent-core prompt-cache stable prefix — canonical sorted tools, ≤4 breakpoints, volatile-last"`

### Task 4: OpenAI-compatible agent transport (extends P1's)

**Files:**
- Create: `cloud/packages/agent-core/src/transport/errors.ts`, `cloud/packages/agent-core/src/transport/openai.ts`, `cloud/packages/agent-core/src/transport/legacy.ts`
- Modify: `cloud/apps/worker/src/liteLlm.ts` (becomes a re-export shim over the **P2 tool-capable** contract — its test file, P1 cases + P2's Task-12 tool-call additions, is untouched), `cloud/packages/agent-core/src/index.ts`
- Test: `cloud/packages/agent-core/src/transport/openai.test.ts`, `cloud/packages/agent-core/src/transport/legacy.test.ts`
- Dart sources: P1 `cloud/apps/worker/src/liteLlm.ts` SSE contract (kept verbatim); P2 Task 12's tool-call extensions (`ChatMessage` role `"tool"`/`toolCalls`, `ModelTransport` returning `toolCalls`, `ModelToolSpec`) — P3 inherits these as the landed baseline (ruling R1); tool-call parsing parity per `test/agent_prompt_transport_contract_test.dart`; retry taxonomy per `test/agent_retry_diagnostics_test.dart`.

**Interfaces:**
- Consumes: `AgentTransport`, `AgentRequest`, `AgentResponse`, `ToolCall` (Task 1); `canonicalTools` (Task 3) is applied by the CALLER (engine), not here. `LegacyChatMessage`/`LegacyModelTransport` are byte-for-byte P2's landed `ChatMessage`/`ModelTransport` (NOT the P1 v0 shapes — P2 extended them to carry tools, and P3 builds on that).
- Produces:

```ts
// errors.ts — moved verbatim from P1/P2 liteLlm.ts (same names, same taxonomy)
export class TransientModelError extends Error {}   // 429, 5xx, network/socket, mid-stream reset, truncated (no [DONE])
export class TerminalModelError extends Error {}    // any other 4xx
// openai.ts
export function createOpenAiAgentTransport(fetchImpl?: typeof fetch): AgentTransport;
// apiFormat "openai". POST {baseUrl}/chat/completions, body {model, messages, tools?: [{type:"function",function:{name,description,parameters}}], stream:true, stream_options:{include_usage:true}, temperature?, max_tokens?}.
// SSE reader = P1's byte-for-byte (partial-line buffering, ':' keep-alives, one-leading-space strip, [DONE] terminator, truncated-stream → TransientModelError).
// Tool-call accumulation = P2's landed semantics, re-homed: accumulates choices[0].delta.tool_calls fragments by index (id/name on first fragment, arguments concatenated across deltas; JSON.parse at end — malformed args JSON → TerminalModelError naming the tool call); delta.content → onTextDelta; delta.reasoning_content → onThinkingDelta; usage trailer → AgentResponse.usage (cache tokens from prompt_tokens_details.cached_tokens when present).
// legacy.ts — thin aliases over the P2 shapes P2's liteLlm.ts already exports
export interface LegacyChatMessage { role: "system" | "user" | "assistant" | "tool"; content: string; toolCalls?: ToolCall[]; toolCallId?: string; }   // P2's ChatMessage verbatim (roles + tool fields)
export interface LegacyStreamHandlers { onDelta(text: string): void; }
export interface LegacyModelTransport { stream(req: { baseUrl: string; apiKey: string; model: string; messages: LegacyChatMessage[]; tools?: Array<{ type: "function"; function: { name: string; description: string; parameters: Record<string, unknown> } }> }, h: LegacyStreamHandlers, signal: AbortSignal): Promise<{ finishReason: string | null; toolCalls: ToolCall[] }>; }   // P2's ModelTransport verbatim — toolCalls returned, NOT stripped
export function adaptLegacyTransport(t: LegacyModelTransport): AgentTransport;  // bidirectional: AgentRequest → legacy req (system prepended as {role:"system"} row, tools passed through), onTextDelta→onDelta, response toolCalls mapped through
export function createLegacyOpenAiTransport(fetchImpl?: typeof fetch): LegacyModelTransport; // the P1/P2 createOpenAiTransport, implemented over createOpenAiAgentTransport — MUST satisfy P2's liteLlm.test.ts tool-call legs
```

`apps/worker/src/liteLlm.ts` becomes a shim that re-exports from `@ovid/agent-core` under the SAME names P2 landed: `export { TransientModelError, TerminalModelError } from "@ovid/agent-core"; export type { LegacyChatMessage as ChatMessage, LegacyStreamHandlers as StreamHandlers, LegacyModelTransport as ModelTransport, ToolCall } from "@ovid/agent-core"; export const createOpenAiTransport = createLegacyOpenAiTransport;` — plus its own `export { ... } from "./tools/types"` passthrough lines if P2's liteLlm re-exported anything else, so `liteLlm.test.ts` (P1 cases AND P2's tool-call additions) and the e2e import surface pass unchanged. The shim must import `createLegacyOpenAiTransport` and any other names its current P2 state exports — enumerate them from the live file at execution time before flipping.

- [ ] **Step 1: Write failing tests.** `openai.test.ts` (local `http.createServer` SSE like P1's): text deltas concatenate exactly; **tool call streaming** — server emits `delta.tool_calls[0]` as `{index:0,id:"call_1",function:{name:"run_shell",arguments:'{"cm'}}` then `{index:0,function:{arguments:'d":"ls"}'}}` across two chunks plus `finish_reason:"tool_calls"` → response `toolCalls === [{id:"call_1",name:"run_shell",args:{cmd:"ls"}}]`, `content === ""`; two parallel tool calls with interleaved indexes reassemble correctly; malformed args JSON → `TerminalModelError`; 429 → Transient, 400 → Terminal, mid-stream socket destroy → Transient, no `[DONE]` → Transient (the four P1 taxonomy cases re-pinned at the new home); usage trailer maps to `AgentResponse.usage` including `cacheReadTokens`. `legacy.test.ts`: `adaptLegacyTransport` maps system+messages into the legacy request (system row first), passes `tools` through, fires `onDelta`, and returns the transport's `toolCalls` (a legacy transport CAN carry tools — P2's contract); `createLegacyOpenAiTransport` satisfies the exact P2 `ModelTransport` signature (tools in the request, `toolCalls` in the result) against the SSE mock.
- [ ] **Step 2: Verify fail.**
- [ ] **Step 3: Implement** errors.ts (move), openai.ts (extend P1's reader), legacy.ts (adapters); flip worker `liteLlm.ts` to the shim; add `@ovid/agent-core` to `apps/worker/package.json` deps.
- [ ] **Step 4: Verify pass — including the untouched P1 suites.** `cd cloud && pnpm -r build && pnpm --filter @ovid/worker test && pnpm --filter @ovid/agent-core test` → all PASS (`liteLlm.test.ts` green via the shim).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): OpenAI-compatible agent transport with tool-call streaming; worker liteLlm becomes a shim"`

### Task 5: Anthropic Messages native transport (BYOK)

**Files:**
- Create: `cloud/packages/agent-core/src/transport/anthropic.ts`
- Test: `cloud/packages/agent-core/src/transport/anthropic.test.ts`
- Dart sources: `lib/core/agent_service.dart` `_callAnthropicOnce` (~14655–14800) + `_anthropicRequestMessages`/`_anthropicTools`; ported cases from `test/anthropic_provider_control_test.dart`, `test/agent_prompt_transport_contract_test.dart` (Anthropic legs).

**Interfaces:**
- Consumes: `AgentTransport` (Task 1), errors (Task 4), `markCacheBreakpoints`/`MAX_CACHE_BREAKPOINTS` (Task 3), `EgressFetch` (Task 1/2 — BYOK egress MUST go through the SSRF guard per spec D3/§11).
- Produces:

```ts
export function createAnthropicTransport(egress: EgressFetch): AgentTransport;
// apiFormat "anthropic". POST {baseUrl}/v1/messages. Headers: x-api-key, anthropic-version: "2023-06-01", content-type, accept: text/event-stream.
// Body: {model, max_tokens (req.maxTokens ?? 8192 — Anthropic REQUIRES it), stream:true, system?: blocks[], messages, tools?: [{name,description,input_schema, cache_control?}], thinking?: {type:"enabled",budget_tokens:4096} when req.effort==="high" (temperature omitted whenever thinking is on)}
export function convertMessagesToAnthropic(msgs: readonly AgentMessage[]): { system: AnthropicBlock[]; messages: AnthropicMessage[] };
// system rows → system blocks (consecutive system rows merge order-preserving); assistant toolCalls → tool_use blocks (args as input JSON); tool rows → user-role message with tool_result block (tool_use_id = toolCallId); volatile messages land LAST and are never cache-marked; cacheControl marks from Task 3 serialize as cache_control:{type:"ephemeral",ttl?} on the marked block
export interface AnthropicBlock { type: "text" | "tool_use" | "tool_result" | "thinking"; [k: string]: unknown; }
export interface AnthropicMessage { role: "user" | "assistant"; content: AnthropicBlock[] | string; }
```

SSE event handling (named events, not just `data:`): `message_start` (usage input), `content_block_start` (tool_use → open a call buffer; thinking → onThinkingDelta stream), `content_block_delta` (`text_delta` → onTextDelta, `input_json_delta.partial_json` → append to the call's args buffer, `thinking_delta`), `content_block_stop` (finalize tool call — malformed accumulated JSON → `TerminalModelError`), `message_delta` (`stop_reason` → finishReason mapping: `end_turn`→`stop`, `tool_use`→`tool_calls`, `max_tokens`→`length`; usage output), `message_stop` (ends stream), `error` event or non-2xx: 429/5xx/529 `overloaded_error` → `TransientModelError`, other 4xx → `TerminalModelError`; stream ending without `message_stop` → `TransientModelError` (truncation parity with P1).

- [ ] **Step 1: Write failing tests.** Local `http.createServer` speaking Anthropic SSE: (a) text stream → content concatenated, `stop_reason:end_turn` → `finishReason:"stop"`; (b) tool_use across `input_json_delta` fragments reassembles `{id,name,args}` exactly and `finishReason:"tool_calls"`; (c) request-shape pin — capture the POST body: `max_tokens` present (default 8192), `anthropic-version` header `2023-06-01`, `x-api-key` header, tools carry `input_schema`, and with `cacheMode:"anthropicNative"` exactly the Task-3-marked blocks carry `cache_control` (≤4, never on a volatile block); (d) `effort:"high"` → body has `thinking:{type:"enabled",budget_tokens:4096}` and NO `temperature` even when provided; (e) error taxonomy: HTTP 529 with `{"error":{"type":"overloaded_error"}}` → Transient; 401 → Terminal; SSE `event: error` mid-stream → Transient; socket close before `message_stop` → Transient; (f) `convertMessagesToAnthropic`: a `tool` row becomes a user message with `tool_result` carrying `tool_use_id`; consecutive system rows merge in order; volatile rows are last.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass** (`pnpm --filter @ovid/agent-core test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): Anthropic Messages native transport — cache_control breakpoints, thinking budget, tool_use streaming"`

### Task 6: KeyResolver seam + provider routing (`auto` alias)

**Files:**
- Create: `cloud/packages/agent-core/src/keys.ts`, `cloud/packages/agent-core/src/routing.ts`
- Test: `cloud/packages/agent-core/src/routing.test.ts`
- Dart sources: `lib/core/state.dart` `ApiFormat.parse`, `_requestRoute` (agent_service.dart ~13198), preset model pin (`lib/core/presets.dart` G3); ported cases from `test/agent_dispatch_route_contract_test.dart`.

**Interfaces:**
- Consumes: `KeyProvider` (`@ovid/shared`, P1 ledger ruling), `AgentTransport` (Task 1).
- Produces:

```ts
// keys.ts — THE BYOK SEAM (documented): P3 resolves LiteLLM virtual keys; P9 swaps in the escrow resolver
// (byok_keys table, envelope-decrypted) WITHOUT touching routing/transports — only a new KeyResolver implementation.
export type ResolvedKey =
  | { kind: "litellm"; apiKey: string; baseUrl: string; model: string }
  | { kind: "byok-anthropic"; apiKey: string; baseUrl: string; model: string };  // baseUrl default https://api.anthropic.com
export interface KeyResolver { resolve(userId: string, requestedModel: string): Promise<ResolvedKey | null>; }
export function litellmKeyResolver(deps: { keys: KeyProvider; baseUrl: string; defaultModel: string }): KeyResolver;
// requestedModel in AUTO_ALIASES or empty → defaultModel; kind always "litellm"; null key → null (→ run_failed key_not_minted, P1 contract)
// routing.ts
export const AUTO_ALIASES = ["auto", "ovid-cloud/auto"] as const;
export function parseModelEffort(raw: string): { model: string; effort: "low" | "medium" | "high" | null }; // strips the "· low|medium|high" suffix (case-insensitive, per Dart RegExp r'·\s*(low|medium|high)$')
export interface RouteRequest { userId: string; requestedModel: string | null; preset?: { model?: string | null; temperature?: number | null } | null; }
export interface ResolvedRoute { transportKind: "openai" | "anthropic"; baseUrl: string; apiKey: string; model: string; effort: "low" | "medium" | "high" | null; temperature?: number; cacheMode: PromptCacheMode; }
export function resolveRoute(req: RouteRequest, deps: { keys: KeyResolver; litellmBaseUrl: string; defaultModel: string; cacheOverride?: PromptCacheOverride }): Promise<ResolvedRoute | null>;
// precedence: preset.model pin (non-null, non-empty) > requestedModel > AUTO alias → defaultModel; effort suffix parsed off the winner;
// byok-anthropic → transportKind "anthropic" + cacheMode from cacheModeFor("anthropic", true, override); litellm → "openai" + cacheModeFor("openai", false, override);
// preset.temperature carried ONLY when non-null (never a synthetic default — presets.dart G3); null route = no key.
```

- [ ] **Step 1: Write failing tests** (port `agent_dispatch_route_contract_test.dart`): alias routing — `requestedModel:"auto"` and `"ovid-cloud/auto"` both resolve to `{transportKind:"openai", model: defaultModel}` via a stub `KeyProvider`; preset pin wins over requested model; `parseModelEffort("claude-x · high")` → `{model:"claude-x", effort:"high"}`, no suffix → effort null; byok-anthropic key → `transportKind:"anthropic"`, `cacheMode:"anthropicNative"` (auto override); `cacheOverride:"off"` → `"none"` on both kinds; null key → `resolveRoute` returns null; `preset.temperature:null` → route has NO `temperature` property (`expect(route).not.toHaveProperty("temperature")` — never inject a synthetic default); `preset.temperature:0.3` → carried.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (both files; keys.ts has a header comment documenting the P9 escrow swap seam) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): agent-core key resolver seam + provider routing — auto alias, preset pins, effort suffix"`

### Task 7: System-prompt assembly (byte-stable base, volatile last)

**Files:**
- Create: `cloud/packages/agent-core/src/systemPrompt.ts`
- Test: `cloud/packages/agent-core/src/systemPrompt.test.ts`
- Dart sources: `buildSys`/`sysTemplate`/`volatileCtx` (agent_service.dart ~11762–12148), `lib/core/plan_mode.dart` `promptSection`, memory context (`agent_memory_context_integration_test.dart` behavior); ported cases from `test/prompt_cache_test.dart` (stability), `test/plan_mode_policy_test.dart` (briefing text), `test/agent_memory_context_integration_test.dart`.

**Interfaces:**
- Consumes: `SessionMode`, `TodoItem`, `SessionGoal`, `SkillSummary` (Task 1).
- Produces:

```ts
export interface SystemPromptInput {
  mode: SessionMode; planMode: boolean; isSubagent: boolean;
  persona: string;                          // preset persona preamble ("" when none) — rides ABOVE the base
  workspaceFolder: string; workspaceTreeSummary: string;   // tree summary is volatile
  skillsCatalog: readonly SkillSummary[];   // compact catalog lines (Task 17 fills; [] until then)
  memoryContext: string;                    // pre-rendered MEMORY.md context block (Task 13; "" until then)
  todos: readonly TodoItem[]; goal: SessionGoal | null;    // volatile session state
  subagentBriefing?: string;                // parent's dispatch prompt for a child (Task 20)
}
export function buildSystemPrompt(i: SystemPromptInput): { stable: string; volatile: string };
// stable = persona + base identity + mode section + plan briefing (planMode only) + skills catalog + memory context — a pure function of the inputs: same inputs ⇒ byte-identical output (no timestamps, no counters)
// volatile = workspace tree + todos + goal + subagent briefing — rendered LAST, appended as `${stable}\n\n${volatile}` for the snapshot (Dart systemPromptSnapshot parity) but kept SEPARATE for cache marking (Task 3 never marks it)
export function planBriefing(planMode: boolean): string;   // exact port of plan_mode.dart promptSection: read-only research phase text, the off-limits shell command list, "asks nothing" rule; "" when !planMode
export function modeSection(mode: SessionMode): string;    // safe: read-only; auto: general + workspace-confined with approvals outside; drive: full access; studio: workspace + repo (port Dart's per-mode description strings, state.dart 273–283, minus every device/control reference — D5)
```

- [ ] **Step 1: Write failing tests.** Byte-stability (Review Focus #3): two `buildSystemPrompt` calls with identical inputs but different `todos` produce identical `stable` bytes and different `volatile`; plan briefing appears in `stable` iff `planMode:true` and contains the read-only shell guidance; `persona:"P"` renders above the base identity line; `volatile` contains the tree summary, todo lines (`- [~]`/`- [ ]` rendering), and goal; `isSubagent:true` without briefing changes nothing (no device/control text may appear anywhere: assert `stable+volatile` never matches `/device_|Control mode/i` — D5); mid-run plan-mode transition pin: `buildSystemPrompt({...planMode:false})` vs `{...planMode:true}` differ ONLY within the plan section + mode section (the rest of `stable` is byte-identical — the G2 turn-boundary swap in Task 15 relies on this).
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): agent-core system prompt assembly — byte-stable base, plan/mode sections, volatile-context-last"`

### Task 8: Plan-mode policy + tool roster computation + presets

**Files:**
- Create: `cloud/packages/agent-core/src/planMode.ts`, `cloud/packages/agent-core/src/presets.ts`, `cloud/packages/agent-core/src/claudeCodeTools.ts`, `cloud/packages/agent-core/src/roster.ts`
- Test: `cloud/packages/agent-core/src/planMode.test.ts`, `cloud/packages/agent-core/src/roster.test.ts`, `cloud/packages/agent-core/src/claudeCodeTools.test.ts`
- Dart sources: `lib/core/plan_mode.dart` (allowlist, harness set, briefing), `lib/core/presets.dart`, `lib/core/claude_code_tools.dart`, `_tools` roster (agent_service.dart ~7350–7600), `_childDeniedTools`; ported cases from `test/plan_mode_allowlist_test.dart`, `test/plan_mode_policy_test.dart`, `test/plan_mode_jail_test.dart` (gate/roster agreement), `test/composer_modes_test.dart`, `test/core_regression_test.dart` (preset legs), `test/claude_code_subagent_parity_test.dart` (roster-projection legs).

**Interfaces:**
- Consumes: `ToolSpec`, `SessionMode`, `Skill` (Task 1); `canonicalTools` (Task 3).
- Produces:

```ts
// planMode.ts
export const PLAN_ALLOWED_TOOLS: ReadonlySet<string>;  // EXACT port of plan_mode.dart allowedTools (file_read, fs_view, fs_glob, fs_grep, view, read_attachment, read_image, repo_read, repo_tree, git_status, git_log, git_diff, run_shell, fetch_url, web_search, memory_search, memory_read, session_search, session_read, browser_read/list_tabs/find/wait_for/snapshot/outline/screenshot, job_list, job_output, get_goal, schedule_list, catalog_* readers, todo_write, ask_user_question, exit_plan_mode, list_agents, report, skill) — DEFAULT-DENY: anything else is refused by the gate AND withheld from the roster
export const HARNESS_TOOLS: ReadonlySet<string>;       // dispatch_agent, report, update_goal, get_goal, create_goal, memory_save (+ Dart's remaining harness entries) — available in every mode/preset
export const PLAN_HARD_DENIED_PREFIXES = ["device_", "plugin_", "mcp__"] as const;  // identity-mutating/3rd-party classes: hard gate, never prompt text
// presets.ts
export interface AgentPreset { id: string; label: string; description: string; allowedTools: string[]; deniedTools: string[]; persona: string; model: string | null; modelProviderId: string | null; temperature: number | null; }
export const BUILT_IN_PRESETS: readonly AgentPreset[];  // port the non-device presets from presets.dart (incl. the `plan` preset: planMode coupling + optional cheap-model pin); allowedTools empty = standard (nothing denied), deniedTools non-empty = denylist instead
export function presetById(id: string | null): AgentPreset | null;
// claudeCodeTools.ts — exact port of the translation table (hook matchers, subagent tools: scoping)
export const CC_TO_NATIVE: Readonly<Record<string, readonly string[]>>; // Bash→[run_shell,job_start,job_output,job_list,job_kill], Read→[file_read,read_image,read_attachment], Write→[file_write], Edit→[fs_edit], MultiEdit→[multi_edit], NotebookEdit→[notebook_edit], NotebookRead→[file_read], Glob→[fs_glob], LS→[fs_glob], Grep→[fs_grep], WebFetch→[fetch_url], WebSearch→[web_search], Agent/Task→[dispatch_agent], Workflow→[workflow], PowerShell→[run_shell], … full table from claude_code_tools.dart
export function ccToolName(native: string): string;                       // native → CC name a matcher/stdin sees
export function nativeToolsFor(entry: string): string[];                  // CC name, prefix '*', mcp__server[__tool|__*] patterns, 'Bash(git push *)'-style specifiers (specifier scopes the WHOLE tool)
// roster.ts
export interface RosterContext { mode: SessionMode; planMode: boolean; isSubagent: boolean; memoryEnabled: boolean; githubConnected: boolean; preset: AgentPreset | null; activeSkillScopes: readonly string[]; };
export function computeToolRoster(ctx: RosterContext, available: readonly ToolSpec[]): ToolSpec[];
// pipeline (single source of truth — the dispatch gate in Task 15 calls isToolPermitted with the SAME sets so gate and roster can never disagree):
// 1. drop device_* ALWAYS (D5 — control mode does not exist in cloud); 2. drop memory_* when !memoryEnabled — EXCEPT members of HARNESS_TOOLS (the harness exemption applies BEFORE the memory drop and in isToolPermitted alike: memory_save is in HARNESS_TOOLS, so `memoryEnabled:false` drops memory_search but KEEPS memory_save — the Step-1 test pins this and the pipeline as ordered must satisfy it);
// 3. drop repo_sync/repo_tree when !githubConnected; 4. planMode → keep only PLAN_ALLOWED_TOOLS ∪ HARNESS_TOOLS and never a PLAN_HARD_DENIED_PREFIXES match (P2's read-only spellings read_file/glob_files/grep_files are admitted alongside file_read/fs_glob/fs_grep — the roster carries P2's and P3's tool sets together, ruling R1);
// 5. isSubagent → drop CHILD_DENIED_TOOLS (spawn class: dispatch_agent + workflow — layer 2 of 3; management tools send_message/list_agents/interrupt_agent/report STAY);
// 6. preset allowedTools non-empty → intersection (harness always kept); else deniedTools → subtraction; 7. activeSkillScopes → intersect through nativeToolsFor;
// 8. canonicalTools sort (byte-stable order for the cache prefix)
export const CHILD_DENIED_TOOLS: ReadonlySet<string>;
export function isToolPermitted(name: string, ctx: RosterContext): boolean;  // gate-side twin of the roster filter — one implementation, two call sites
export function modePolicy(mode: SessionMode, planMode: boolean): { canMutate: boolean; confineToWorkspace: boolean; approvalForOutside: boolean };
// safe: {canMutate:false,…}; auto/studio: {canMutate:true, confineToWorkspace:true, approvalForOutside:true}; drive && !planMode: {canMutate:true, confineToWorkspace:false, approvalForOutside:false}; planMode forces safe-like mutation denial for identity-mutating tools regardless of mode (destructive-command confirmation still applies in ALL modes — Task 15 checks it before any hook allow)
export const exitPlanModeTool: Tool-spec-factory;  // export function createExitPlanModeTool(deps: { state: SessionStateStore; approvals: ApprovalGate }): Tool — marks pendingPlanMode:false via state.patch AFTER a kind:"plan" approval round-trip (Task 12 gate; fake in this task's tests); plan reviews WAIT (no 120 s auto-deny when attended — Dart: "question cards and plan reviews keep waiting")
```

- [ ] **Step 1: Write failing tests.** (port `plan_mode_allowlist_test.dart`): with `planMode:true`, a `file_write`/`fs_edit`/`commit`/`run_code`/`repo_sync`/`plugin__x__y`/`mcp__s__t` spec in `available` never reaches the roster, while every `PLAN_ALLOWED_TOOLS` member does; `isToolPermitted` agrees with the roster on ALL of {plan on/off} × {each available spec} (gate/roster can never disagree — `plan_mode_jail_test.dart` parity); (port `composer_modes_test.dart` + D5): `device_tap` in `available` is dropped in EVERY mode; `memoryEnabled:false` drops `memory_search` but keeps `memory_save` only if harness (it is — assert harness wins); `githubConnected:false` drops repo tools; preset allowlist `{allowedTools:["file_read"]}` → roster = file_read + harness only; denylist `{deniedTools:["run_shell"]}` → run_shell gone, rest standard; `isSubagent:true` → `dispatch_agent` gone, `send_message`/`list_agents`/`interrupt_agent`/`report` present; roster output is name-sorted (canonicalTools); `nativeToolsFor("Bash(git push *)")` → `["run_shell","job_start","job_output","job_list","job_kill"]`, `nativeToolsFor("mcp__srv")` → the mcp pattern expansion, `"Edit"` → `["fs_edit"]`; `ccToolName("fs_edit")==="Edit"`; `createExitPlanModeTool` with a fake gate returning "allow" clears planMode via `state.patch` (fake store), returning "deny" leaves it and the tool result starts with `DENIED`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** the four modules (copy the allowlist/harness/CC table verbatim from the Dart sources — they are the contract) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): tool roster — plan-mode default-deny projection, mode gates minus device tools (D5), presets, subagent + skill scoping"`

### Task 9: Workspace tools — structured edits, spill, per-tool timeouts, sandbox adapter

**Files:**
- Create: `cloud/packages/agent-core/src/tools/structuredEdits.ts`, `cloud/packages/agent-core/src/tools/spill.ts`, `cloud/packages/agent-core/src/tools/sandboxTools.ts`
- Create: `cloud/apps/worker/src/sandboxAdapter.ts` (P2 SandboxManager → `SandboxPort`; if P2's exports differ in name, adapt to P2's actual Produces block — the port shape here is the contract)
- Create: `cloud/apps/worker/src/tools/agentToolAdapter.ts` (P2 `AgentTool` → canonical `Tool`, rulings R1/R2: P3's tools are ADDITIVE alongside P2's landed six — run_shell, read_file, write_file, edit_file, glob_files, grep_files — which are NOT re-implemented; the adapter is how P2's roster joins the canonical seam. `spec` = `{name, description, parameters}` from the AgentTool's own fields; `timeoutMs` = the tool's own clamp (run_shell max 600_000) else 120_000; canonical `ToolContext` → P2 `ToolContext` with `callKey`/`signal`/`mode` passed as ADDITIVE optional fields on P2's ToolContext so P2's own tests are unaffected; `ToolResult` = `{content, isError}` passed through, `artifacts` left undefined)
- Test: `cloud/packages/agent-core/src/tools/structuredEdits.test.ts`, `cloud/packages/agent-core/src/tools/spill.test.ts`, `cloud/packages/agent-core/src/tools/sandboxTools.test.ts`, `cloud/apps/worker/src/sandboxAdapter.test.ts`, `cloud/apps/worker/src/tools/agentToolAdapter.test.ts`
- Dart sources: `lib/core/structured_edits.dart`, `spillToolOutput`/`_toolOutputCapFor` (agent_service.dart ~495, ~1271), per-call timeout+kill (~12675–12689); ported cases from `test/structured_edits_and_mcp_streaming_test.dart`, `test/tool_timeout_cancel_test.dart`, `test/readonly_command_security_test.dart`, `test/core_regression_test.dart` (spill legs), `test/sandbox_toolchains_test.dart` (interpreter-allowed legs only — the blocker itself is P2's).

**Interfaces:**
- Consumes: `SandboxPort`, `Tool`, `ToolContext`, `ToolResult` (Task 1).
- Produces:

```ts
// structuredEdits.ts — pure, I/O-free (atomic: throw ⇒ nothing written)
export class StructuredEditError extends Error {}
export interface TextEdit { oldString: string; newString: string; replaceAll: boolean; }
export function parseEditList(raw: unknown): TextEdit[];       // accepts Claude Code keys old_string/new_string/replace_all AND Ovid fs_edit spellings old_str/new_str; empty/non-array → StructuredEditError('edits must be a non-empty array of {old_string, new_string}')
export function applyMultiEdit(content: string, edits: readonly TextEdit[]): string;  // sequential; each oldString must match exactly once unless replaceAll; no match / multiple matches → StructuredEditError naming the edit index; oldString===newString → error
// spill.ts
export const SPILL_DEFAULT_CAP = 6000;
export function toolOutputCapFor(name: string): number;        // 6000 for everything (device_read's 24000 dies with D5); fetch_url uses 8000 at its own call site (Task 10)
export async function spillToolOutput(deps: { sandbox: SandboxPort; userId: string; workspaceRelDir: string }, toolName: string, text: string, cap?: number): Promise<string>;
// ≤cap → verbatim. Over cap → write FULL text to `.spill/<epochMs>.txt` under the session workspace via sandbox.writeFile, return head(cap/2) + "\n\n[…N characters omitted — full output saved to .spill/<id>.txt. <locator>…]\n\n" + tail(cap/2), locator per tool: run_shell → 'run_shell: `sed -n "L,LP" <rel>` for a line range, or `grep -n "<pattern>" <rel>` to find lines'; fs_grep/fs_glob → 're-run with a narrower `pattern` or an `include` glob; the full output is saved at <rel> (fs_edit view can page it)'; else → 'the full output is saved at <rel> — read it with fs_edit view (path .spill/<id>.txt) in chunks'
// sandboxTools.ts
export function createSandboxTools(deps: { sandbox: SandboxPort; }): Tool[];
// P3's ADDITIVE tool set (P2's six stay registered via agentToolAdapter, ruling R1 — they are NOT re-registered here):
// run_code (python|javascript only — else 'Unsupported language: <x>. Use python or javascript.'), file_read, file_write, fs_edit, multi_edit, notebook_edit, fs_glob, fs_grep, job_start, job_output, job_list, job_kill
// every exec-class tool passes ctx.callKey through to sandbox.exec; every result goes through spillToolOutput with toolOutputCapFor(name)
// spill.ts — THE dispatch timeout helper (single definition, single arity — Task 15 imports this exact shape):
export function withToolTimeout(promise: Promise<ToolResult>, o: { timeoutMs: number; callKey: string; onKill: () => Promise<void> }): Promise<ToolResult>;
// resolves with the promise, or after timeoutMs awaits o.onKill() (the dispatcher binds it to sandbox.killCall(userId, callKey)) and resolves {content: TOOL_TIMEOUT_MESSAGE(toolName, secs), isError: true}
export const TOOL_TIMEOUT_MESSAGE: (name: string, secs: number) => string;
// exact Dart copy: `Error: tool "${name}" timed out after ${secs}s and its processes were KILLED. It may have partially completed — check the current state (read the file, \`git status\`) before doing anything else, and do NOT re-run it blindly.`
```

Timeout enforcement lives in the loop's dispatch (Task 15) but the CONTRACT is pinned here: on timeout the dispatcher calls `sandbox.killCall(userId, callKey)` and the tool result is `TOOL_TIMEOUT_MESSAGE(name, budget)` — the timed-out call's late output never reaches the model. The contract covers the ADAPTED P2 tools too: `agentToolAdapter` threads `ctx.callKey`, so a dispatched `run_shell` (P2's implementation) is killable by callKey like any canonical tool. Spill wrapping on adapted P2 tools is the full-processor path's business (Task 16); the P2-compat path keeps P2's own caps byte-for-byte so its suite stays green.

- [ ] **Step 1: Write failing tests.** structuredEdits (port `structured_edits_and_mcp_streaming_test.dart` pure legs): single edit applies; `replaceAll:false` with two occurrences → throws naming index; zero occurrences → throws; `replaceAll:true` replaces all; edits apply sequentially (edit 2 sees edit 1's output); CC + Ovid key spellings both parse; empty array → the exact error string. spill (fake SandboxPort recording writes): text ≤ cap returned verbatim, zero writes; text > cap → one `writeFile` to `.spill/<id>.txt` with the FULL text, result = head+marker+tail with `omitted = len - cap` and the run_shell locator when toolName is run_shell; fs_grep gets its own locator. sandboxTools (fake SandboxPort): fs_grep passes `pattern`, `cwd`, `callKey` through to sandbox.exec and spills a >6000-char stdout; run_code with `lang:"ruby"` → the exact unsupported-language string, no exec call; job_start→jobOutput offset round-trip; file_write then file_read via the fake; **timeout/kill (port `tool_timeout_cancel_test.dart` at the port level)**: a fake exec-class tool whose `execute` never resolves + `withToolTimeout(promise, {timeoutMs, callKey, onKill})` — assert `onKill` (bound to `sandbox.killCall(userId, callKey)` in dispatch) was invoked with the exact callKey and the result equals `TOOL_TIMEOUT_MESSAGE("run_shell", 600)` with `isError:true`. `sandboxAdapter.test.ts` (shape test — it wraps P2's real manager, exercised in Task 16 integration; write it against the P2 plan's Produces block, `docs/superpowers/plans/2026-10-16-ovid-cloud-p2-sandbox-manager.md` if present, else spec §14 P2 row: one-shot exec, PTY, file tools, job_* processes, command interceptor; also pin the known drift absorptions from the C3 seam: a callKey→leaf/child map inside the adapter for `killCall` (P2's ExecRequest has no callKey and kills on timeout internally), and file methods synthesized over `workspaceDir` + `resolveConfined`). `agentToolAdapter.test.ts`: a fake P2 AgentTool recording input/ctx — the adapted Tool passes args + canonical ctx through; the AgentTool sees the bridged ctx carrying the additive `callKey`/`signal`/`mode` fields; its `{content, isError}` result passes through as `ToolResult.content/.isError`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (export `withToolTimeout` from `tools/spill.ts` alongside the cap helpers) → **Step 4: Verify pass** (`pnpm --filter @ovid/agent-core test && pnpm --filter @ovid/worker build`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): workspace tools — structured edits, output spill with locators, per-call timeout kill contract, P2 sandbox adapter"`

### Task 10: Web tools — fetch_url (SSRF + grants) and web_search

**Files:**
- Create: `cloud/packages/agent-core/src/tools/web.ts`, `cloud/packages/agent-core/src/htmlToMarkdown.ts`
- Test: `cloud/packages/agent-core/src/tools/web.test.ts`, `cloud/packages/agent-core/src/htmlToMarkdown.test.ts`
- Dart sources: `fetch_url` case (agent_service.dart ~15864–15887), `_webSearch`/`_ddgSearch` (~25462–25540), `_htmlToMarkdown` (~349); ported cases from `test/security_ssrf_guard_test.dart` (fetch legs), `test/core_regression_test.dart` (web_search parity legs), `test/browser_scheme_guard_test.dart`, `test/storage_privacy_fixes_test.dart` (scrub legs).

**Interfaces:**
- Consumes: `SsrfGuard`, `createGuardedEgressFetch` (Task 2), `spillToolOutput` (Task 9), `ApprovalGate` (Task 1 port — real gate lands Task 12; tests use a fake), `Tool`/`ToolContext`.
- Produces:

```ts
export function htmlToMarkdown(html: string): string;   // exact port of _htmlToMarkdown: strip script/style/head, block elements → newlines, <a href> → [text](href), <li> → "- ", entity decode, collapse whitespace
export function createFetchUrlTool(deps: { egress: EgressFetch; guard: SsrfGuard; approvals: ApprovalGate }): Tool;
// name "fetch_url", timeoutMs 60_000. Flow (Dart parity): parse URL → host approval check via deps.approvals (kind:"tool", hostTargets:[host], allowAlways:true) — decision "deny" → return EXACTLY 'DENIED by user'; GET with header {"user-agent":"OvidAgent/1.0"} through the guarded fetch (per-hop SSRF re-check built into the egress); body → htmlToMarkdown when content-type is html, else raw text; result = spillToolOutput(…, cap 8000); any throw → `fetch failed: ${message}`
export const WEB_SEARCH_MAX_QUERIES = 4;
export const WEB_SEARCH_MAX_RESULTS = 8;
export function createWebSearchTool(deps: { egress: EgressFetch; ddgBase?: string }): Tool;
// name "web_search", timeoutMs 60_000. args.queries: 1–4 items after trim+dedupe (first occurrence kept); empty → 'Error: queries must contain at least one query'; >4 → 'Error: queries must contain at most 4 queries'; all queries run CONCURRENTLY (Promise.all) — ONE failure fails the whole call → `Error: ${message}`; backend GET ${ddgBase ?? "https://html.duckduckgo.com/html/"}?q=<encoded> UA OvidAgent/1.0, non-200 → throw `search failed for "<q>" (HTTP <status>)`; parse result__a/result__snippet regex pairs, unwrap DDG /l/?uddg=<urlencoded> links, cap 8 per query; round-robin merge across queries (rank 1 of A, rank 1 of B, …) deduped by URL, capped at 8 total; render lines '- [${title||url}](${url})${snippet ? " — "+snippet : ""}'; zero results → 'No results found.'
```

- [ ] **Step 1: Write failing tests.** htmlToMarkdown: `<script>`/`<style>` content removed; `<a href="u">t</a>` → `[t](u)`; `<li>` → `- `; entities decoded; the exported Dart test fixture style (`htmlToMarkdownForTest` parity). fetch_url (fake gate + local HTTP server + real guard with stub resolver): happy path returns markdown spilled at 8000; gate decision "deny" → exact `DENIED by user` and NO fetch happened; 302 → `http://169.254.169.254/` → result starts with `fetch failed:` (guard blocked, Review Focus #4); server 500 → `fetch failed: …`. web_search (local stub of the DDG HTML shape): 2 queries round-robin merge order = [A1,B1,A2,B2,…] deduped by URL; duplicate queries run once (stub counts requests); 5 distinct queries → the exact at-most-4 error; one query's stub returning 500 → whole call `Error: search failed for "…"`; uddg-wrapped href unwrapped to the real URL; 0 matches → `No results found.`; >8 results capped.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): web tools — fetch_url with SSRF+grant gate and html→markdown, web_search DDG round-robin parity"`

### Task 11: Git/repo tools

**Files:**
- Create: `cloud/packages/agent-core/src/tools/git.ts`
- Test: `cloud/packages/agent-core/src/tools/git.test.ts`
- Dart sources: git_* + commit + repo_tree/repo_sync cases (agent_service.dart dispatch); ported cases from `test/agent_git_tools_test.dart`, `test/agent_commit_approval_test.dart`, `test/chat_commit_approval_test.dart`, `test/studio_commit_approval_test.dart`, `test/repo_cache_commit_safety_test.dart` (safety legs only — the on-device repo cache is NOT ported; cloud git runs in the session workspace jail).

**Interfaces:**
- Consumes: `SandboxPort` (Task 1), `ApprovalGate` (port), `GitHubApiPort` (Task 1), `spillToolOutput` (Task 9).
- Produces:

```ts
export function createGitTools(deps: { sandbox: SandboxPort; approvals: ApprovalGate; github: GitHubApiPort | null }): Tool[];
// git_status, git_log (args: limit default 20), git_diff (args: staged?: boolean, paths?: string[]), git_pull, git_clone (approval kind:"tool" with hostTargets of the remote before exec), git_push (ALWAYS approval kind:"tool", allowAlways:false — Dart parity: pushes are individually confirmed), commit (args: message; approval kind:"tool" summary showing the staged-file list first via `git diff --cached --name-only`; deny → 'DENIED by user')
// all git_* exec through sandbox.exec inside the workspace (cwd = workspace root), callKey threaded, output spilled; a non-zero exit returns stdout+stderr verbatim (the model adapts) prefixed `exit ${code}` 
export function createRepoTools(deps: { github: GitHubApiPort | null }): Tool[];   // null → repo_tree absent from the returned array (matches the Step-1 test and Task 16's FullRunDeps nullability — the roster never advertises what cannot run)
// repo_tree (args: {owner, repo, ref?, path?}) → github.getTree recursive, rendered 'TREE (N files, showing 120):\n' + first 120 paths joined (Dart line 17827 parity); repo_sync → 'repo_sync is not available in cloud workspaces — use git_pull/git_push in the workspace' (documented deviation: the device repo-cache sync does not exist server-side; spec wins over Dart)
```

- [ ] **Step 1: Write failing tests** (fake SandboxPort recording cmds, fake gate, fake GitHubApiPort): git_status passes `git status --porcelain=v1 -b` (or the exact Dart command strings — port them) with the ctx callKey; commit with gate "allow" execs `git commit -m …`, with "deny" returns `DENIED by user` and execs NOTHING; git_push ALWAYS prompts even when a path grant exists (assert gate called with allowAlways:false); git_clone prompts with the remote's hostTargets; non-zero exit → result starts `exit 1` and contains stderr; repo_tree renders the 120-path cap header exactly; repo_tree with `github:null` in deps → tool absent from the returned array (roster never advertises what cannot run); repo_sync returns the documented cloud-deviation string.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): git tools via sandbox exec + repo_tree via GitHub REST; push/commit approval parity"`

### Task 12: Approvals over WS + hierarchical grant store

**Files:**
- Modify: `cloud/packages/shared/src/events.ts` (ADDITIVE union members), `cloud/packages/shared/src/ws.ts` (ADDITIVE ops), `cloud/packages/shared/src/{events.test.ts,ws.test.ts}` (new cases appended; existing untouched)
- Modify: `cloud/packages/db/src/schema.ts` (grants table), `cloud/packages/db/src/repos.ts` (grants repo), Create: `cloud/packages/db/drizzle/0001_grants.sql` (via `drizzle-kit generate`)
- Create: `cloud/packages/agent-core/src/grants.ts`, `cloud/packages/agent-core/src/approvals.ts`
- Create: `cloud/apps/worker/src/approvalBridge.ts`
- Modify: `cloud/apps/gateway/src/ws.ts` (handle `approval_response` op → publish), `cloud/apps/gateway/src/buildGateway.ts` (pass redisQ publisher into WsDeps)
- Test: `cloud/packages/agent-core/src/grants.test.ts`, `cloud/packages/agent-core/src/approvals.test.ts`, `cloud/apps/worker/src/approvalBridge.test.ts`, `cloud/apps/gateway/src/ws.approval.test.ts`, `cloud/packages/db/src/repos.grants.test.ts`
- Dart sources: `lib/core/grant_store.dart`, `_maybeApprove`/approval dock (agent_service.dart ~19400–19620); ported cases from `test/grant_store_test.dart`, `test/grant_store_blank_path_test.dart`, `test/worker_d_grant_store_fixes_test.dart`, `test/tool_approval_always_allow_test.dart`, `test/agent_permission_request_execution_test.dart`, `test/approval_dock_safety_test.dart`, `test/security_plugin_grant_storage_test.dart`.

**Interfaces:**
- Consumes: `ApprovalBridge`/`ApprovalGate`/`ApprovalRequest` (Task 1), `EventSink` (Task 1), `Db`/`EventLog`.
- Produces:

```ts
// @ovid/shared events.ts — APPEND to SessionEventType + zod enum (never reorder/remove existing).
//   RULING R5 (recount vs P3-Q5): P2's Task 12 ALREADY landed "tool_started" | "tool_completed" — DETECT AND SKIP those two
//   (they are present; re-adding is a harmless union dedupe but the step must not assume they're P3's). P3 appends the
//   remaining NINE (the members P3-Q5 listed, with P2's tool_* members accounted for separately):
//   "approval_requested" | "approval_resolved" | "todo_updated" | "goal_updated" | "plan_mode_changed" | "run_cancelled" | "subagent_started" | "subagent_completed" | "compaction_completed"
// @ovid/shared ws.ts — APPEND ops:
//   WsClientMsg |= { op: "approval_response"; sessionId: string; approvalId: string; decision: "allow" | "deny" | "always" }
//   WsServerMsg |= { op: "approval_ack"; approvalId: string; decision: string }
export const APPROVAL_RESPONSES_CHANNEL = "ovid:approval-responses";   // redis-q pub/sub (queue instance, noeviction)
// @ovid/db schema.ts
export const grants: pgTable — { id: char(36) pk; userId: text ref users.uid; sessionId: char(36) ref sessions.id (session-scoped; the Dart global scope is NOT ported — 'the agent never consults them'); kind: text /* "path"|"host" */; pattern: text notNull; decision: text /* "allow"|"always"|"deny" */; mode: text (audit metadata only — decisions apply across modes); createdAt } + index (userId, sessionId)
// @ovid/db repos.ts
export const grantsRepo = { listForSession(db, userId, sessionId): Promise<GrantRow[]>; add(db, g: {userId, sessionId, kind, pattern, decision, mode}): Promise<GrantRow>; remove(db, grantId, userId): Promise<boolean>; };
// agent-core grants.ts — exact port of grant_store.dart matching semantics
export function grantMatchesPath(pattern: string, target: string): boolean;  // folder grant covers the folder itself + all children, NEVER siblings/parents; blank/near-blank patterns match nothing (grant_store_blank_path_test parity); normalized (no trailing-slash sensitivity)
export function grantMatchesHost(pattern: string, host: string): boolean;    // host covers itself + child domains (example.com ⊇ api.example.com) + every port/path; NOT sibling suffixes (notexample.com ⊄)
export function findApplicableGrant(grants: readonly GrantLike[], kind: "path" | "host", target: string): GrantLike | null;  // most specific pattern wins; explicit deny beats allow at equal specificity
// agent-core approvals.ts
export const APPROVAL_TIMEOUT_MS = 120_000;         // spec §6.2/§8 — attended AND unattended default
export function createApprovalGate(deps: { db: Db; bridge: ApprovalBridge; sinkFactory(sessionId: string): EventSink; timeoutMs?: number; timeoutPolicy?: (req: ApprovalRequest, ctx: { unattended: boolean }) => number }): ApprovalGate;
// timeoutMs OVERRIDES the 120 s default (Task 16 wires OVID_APPROVAL_TIMEOUT_MS here — the override has a documented seam into the gate, so the unattended-timeout test can inject a short timeout). timeoutPolicy, when provided, computes the per-request timeout (defaults to the fixed value) — this is the exported decision point P4's UnattendedApprovalHook will extend at its own seam.
// approve(ctx, req): 1) consult grants for pathTargets/hostTargets — a matching allow/always grant → "allow" with NO prompt; matching deny → "deny" with NO prompt;
// 2) emit approval_requested {approvalId, tool, kind, summary, detail, allowAlways, expiresAt}; 3) bridge.ask with timeoutMs = (deps.timeoutMs ?? APPROVAL_TIMEOUT_MS) — resolved via timeoutPolicy when set — (kind "question"/"plan" + attended → NO timeout: timeoutMs 0 means wait; unattended → 120 s for ALL kinds, spec §8);
// 4) first resolution wins (bridge guarantees); timeout → "deny"; 5) decision "always" + targets → grantsRepo.add (kind path/host per targets); 6) emit approval_resolved {approvalId, decision, reason?:"timeout"|"unattended_timeout"}; 7) denied targetless requests are remembered per session (denialKey = tool+summary hash) → an identical request auto-denies WITHOUT prompting until forgetDenial(sessionId, key) (Dart _deniedApprovals parity)
// apps/worker approvalBridge.ts
export function createRedisApprovalBridge(deps: { redisQ: Redis; events: EventLog; db: Db }): ApprovalBridge;
// SUBSCRIBE APPROVAL_RESPONSES_CHANNEL once; messages {approvalId, userId, decision} resolve the matching pending deferred ONLY if the userId owns the session (sessions.get check) — cross-user answers are dropped;
// ask(): register deferred, timer(timeoutMs) → resolve "timeout" (unless timeoutMs===0), cleanup on settle; a response after settle is a no-op (Review Focus #1); ABORT signal → "deny"
// apps/gateway ws.ts — on {op:"approval_response"}: validate ownership like subscribe (sessions.get(userId)) → unknown/foreign session → existing error op {code:"forbidden"}; else redisQ.publish(APPROVAL_RESPONSES_CHANNEL, JSON.stringify({approvalId, userId, decision})) → send {op:"approval_ack", approvalId, decision}; malformed decision → error op {code:"bad_request"}
```

- [ ] **Step 1: Write failing tests.** grants.test.ts (port `grant_store_test.dart` + blank-path + worker_d fix legs): `/ws/a` grant covers `/ws/a/b/c`, not `/ws/ab`, not `/ws`; `example.com` covers `api.example.com`, not `notexample.com`; deny beats allow at equal specificity; deeper pattern wins over shallower. approvals.test.ts (fake bridge + fake sink + real db on TEST_DATABASE_URL): grant hit → no bridge call, decision allow; prompt path emits `approval_requested` then `approval_resolved` in order; "always" with pathTargets writes a grants row (assert via grantsRepo.listForSession); timeout → deny + `approval_resolved {reason:"timeout"}`; **double-resolve race (Review Focus #1)**: bridge resolves "timeout", then a late publish arrives → second `approval_resolved` NEVER emitted, no grant written from the late "always"; remembered denial: second identical targetless request after a deny → auto-deny, bridge not called; unattended ctx with kind:"question" → timeoutMs 120000 passed to bridge; gate constructed with `timeoutMs: 500` → bridge receives 500 (the env-override seam, ruling-adjacent FINDING 4); gate with `timeoutPolicy` returning 750 for unattended reqs → bridge receives 750. approvalBridge.test.ts (real Redis on TEST_REDIS_URL): publish resolves the pending ask; wrong-user publish dropped; publish after timeout no-op; two concurrent asks resolve independently by approvalId. ws.approval.test.ts (gateway, test-auth): approval_response for a foreign session → error frame `forbidden`, nothing published; valid → approval_ack + published payload observed on a subscriber. db repos.grants.test.ts: add/list/remove round-trip, remove scoped by userId. shared events/ws tests: append round-trip cases for every new type/op + assert the OLD unions still parse (additive pin); the events step DETECTS P2's already-landed `tool_started`/`tool_completed` (assert present, do not re-append — ruling R5).
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (migration via `cd cloud/packages/db && pnpm exec drizzle-kit generate`; gateway/worker wiring as pinned) → **Step 4: Verify pass — full workspace.** `cd cloud && pnpm -r build && pnpm -r test` → green including the UNMODIFIED `apps/e2e` spine (new event types never fire on its tool-less path).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): approvals over WS — additive shared ops, hierarchical grant store in Postgres, redis approval bridge, 120s auto-deny"`

### Task 13: Session state tools — session_search (Postgres FTS), memory, goals/todos

**Files:**
- Modify: `cloud/packages/db/src/schema.ts` (`session_agent_state` table; `messages.searchVector` generated tsvector + GIN index), `cloud/packages/db/src/repos.ts` (`sessionState`, `messages.search`), Create: `cloud/packages/db/drizzle/0002_session_state_fts.sql` (drizzle-kit generate)
- Create: `cloud/packages/agent-core/src/stateStore.ts`, `cloud/packages/agent-core/src/tools/memory.ts`, `cloud/packages/agent-core/src/tools/sessionSearch.ts`, `cloud/packages/agent-core/src/tools/goalsTodos.ts`
- Test: `cloud/packages/db/src/repos.search.test.ts`, `cloud/packages/agent-core/src/tools/memory.test.ts`, `cloud/packages/agent-core/src/tools/sessionSearch.test.ts`, `cloud/packages/agent-core/src/tools/goalsTodos.test.ts`
- Dart sources: `lib/core/session_search.dart`, `lib/core/memory_store.dart`; ported cases from `test/session_search_test.dart`, `test/memory_store_test.dart`, `test/memory_entries_test.dart`, `test/memory_agent_test.dart`, `test/agent_memory_context_integration_test.dart`, `test/mcp_memory_isolation_test.dart`.

**Interfaces:**
- Consumes: `Db`, `SandboxPort`, `SessionStateStore`/`TodoItem`/`SessionGoal` (Task 1), `EventSink` (Task 1).
- Produces:

```ts
// @ovid/db schema.ts (additive)
export const sessionAgentState: pgTable — { sessionId: char(36) pk ref sessions.id; state: jsonb notNull default '{}' }   // SessionAgentState minus compaction internals is fine — store the WHOLE SessionAgentState JSON
// messages: ADD generated column — searchVector: tsvector GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED + GIN index messages_search_gin
// @ovid/db repos.ts
export const sessionState = { get(db, sessionId): Promise<SessionAgentState>; patch(db, sessionId, p: Partial<SessionAgentState>): Promise<void>; };  // upsert; get on missing row → zero state (Task 1 shape)
export async function searchMessages(db: Db, userId: string, query: string, o?: { limit?: number; offset?: number; sessionId?: string }): Promise<{ rows: Array<{ messageId: string; sessionId: string; role: string; rank: number; snippet: string }>; total: number }>;
// plainto_tsquery('simple', …) for bare queries, websearch_to_tsquery for quoted phrases (session_search.dart literal-phrase parity); ts_rank_cd ordering; ts_headline snippets; limit clamp ≤100 (maxLimit parity); query length clamp 4096 UTF-16 units; ownership join sessions.userId = userId (cross-user = zero rows, never an error); total = count over the same filter
// agent-core stateStore.ts
export function createPostgresSessionStateStore(db: Db): SessionStateStore;   // thin wrapper over sessionState repo
// agent-core tools/memory.ts — files under the USER workspace `.ovid/memory/` via SandboxPort (server-authoritative per D6; hibernates with the workspace — documented deviation from Dart's app-private dir)
export const MEMORY_LIMITS = { maxFileBytes: 32 * 1024, maxFiles: 32, maxContextChars: 16000 } as const;
export function validateMemoryName(name: string): void;  // throws MemoryFormatError unless /^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*\.md$/ and length ≤80 and (name.toLowerCase()==="memory.md" ⇒ name==="MEMORY.md") — error copy: 'Use a plain .md filename (max 80 characters); the entrypoint is MEMORY.md.'
export function validateMemoryContent(content: string): void; // >32 KiB UTF-8 or contains NUL → 'Memory must be UTF-8 text, at most 32 KiB, without NUL bytes.'
export function createMemoryTools(deps: { sandbox: SandboxPort }): Tool[];  // memory_read {name}, memory_save {name, content, expectedRevision?} (revision = sha256 of prior content; mismatch → conflict error naming both revisions — Dart's bounded rename semantics), memory_search {query} (substring scan over ≤32 files, results capped, per-file 16000-char context budget)
export function memoryContextBlock(docs: Array<{name,content}>): string;  // the standing MEMORY.md context injected by Task 7 (≤ maxContextChars, MEMORY.md first)
// agent-core tools/sessionSearch.ts
export function createSessionSearchTool(deps: { db: Db }): Tool;   // name "session_search" {query, sessionId?, limit?} → searchMessages scoped to ctx.userId; rendered 'sessionId messageId: …snippet…' lines; zero rows → 'No matches.'
// agent-core tools/goalsTodos.ts
export function createGoalTodoTools(deps: { state: SessionStateStore; sinkFactory(sessionId): EventSink }): Tool[];
// todo_write {todos: TodoItem[]} → state.patch + emit todo_updated {runId?, todos} (additive event); full-list replace semantics (Dart parity)
// create_goal {objective, notes?} / update_goal {objective?, notes?} / get_goal → state + goal_updated event; get_goal renders objective+notes+todo checklist
```

- [ ] **Step 1: Write failing tests.** repos.search.test.ts (TEST_DATABASE_URL; port `session_search_test.dart`): seeded messages across two users — a query returns only the caller's rows ranked with snippets; quoted-phrase query matches the literal phrase; `sessionId` filter; limit>100 clamped to 100; query >4096 chars rejected/clamped per port; ownership: user B searching user A's text → `rows: []`. memory.test.ts (fake SandboxPort): validateMemoryName accepts `MEMORY.md`, `notes-v2.md`; rejects `../x.md`, `memory.md` (lowercase entrypoint), 81-char names, `no-ext`; validateMemoryContent rejects 32 KiB+1 and NUL; memory_save with stale expectedRevision → conflict error; memory_search finds a substring across two files; >32 files → save refuses (maxFiles). goalsTodos.test.ts (memory state store + recording sink): todo_write replaces the list and emits `todo_updated` with the exact todos; get_goal renders `- [~]` for in_progress; create_goal then update_goal merges partials. sessionSearch.test.ts: stub db → tool renders rows / `No matches.`
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (migration via drizzle-kit generate — the generated SQL must contain `GENERATED ALWAYS AS (to_tsvector` and `USING gin`; hand-adjust only if drizzle-kit cannot express the generated column, keeping the file in `drizzle/` + journal) → **Step 4: Verify pass — full workspace** `pnpm -r build && pnpm -r test`.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): session state — Postgres FTS session_search (tsvector migration), memory tools, goals/todos with state events"`

### Task 14: Loop guards, steering queue, todo follow-through nudge

**Files:**
- Create: `cloud/packages/agent-core/src/guards.ts`, `cloud/packages/agent-core/src/steering.ts`
- Modify: `cloud/packages/db/src/repos.ts` (`runs.listQueuedForSession`)
- Test: `cloud/packages/agent-core/src/guards.test.ts`, `cloud/packages/agent-core/src/steering.test.ts`
- Dart sources: repeat/escalation guards (agent_service.dart ~12714–12753), todo nudge (~12516–12545), budget boundary (~12340, 12774–12790), `_drainQueueIntoMsgs`; ported cases from `test/core_regression_test.dart` (guard strings), `test/queue_inject_run_test.dart`, `test/queue_continuation_test.dart`, `test/queue_ids_test.dart`, `test/chat_data_loss_safety_test.dart`, `test/token_budget_test.dart` (boundary legs).

**Interfaces:**
- Consumes: `Db` (`runs`, `messages`), `EventSink`, `TodoItem` (Task 1).
- Produces:

```ts
// guards.ts — pure state machine, exact Dart strings
export interface GuardState { repeatKey: { name: string; canonArgs: string } | null; repeatStreak: number; consecutiveErrors: number; turnsWithoutProgress: number; todoNudgeSent: boolean; }
export function newGuardState(): GuardState;
export function recordToolResult(g: GuardState, name: string, args: Record<string, unknown>, result: string): { result: string; isError: boolean };
// canonArgs = canonicalJson(args) — Task 3's generic canonical serializer (recursive key-sort; canonicalToolJson is its tool-spec application — use canonicalJson directly, the tool-spec-specific wrapper cannot stringify arbitrary args); same tool+args → streak++, else streak=1;
// streak 3/5/8 append EXACTLY (Dart 12728–12741): '\n\n[note] Same tool + identical args repeated 3 times — re-read the tool output or change approach.' / '\n\n[note] Same call now repeated 5 times — stop, reconsider the goal, or ask/notify the user.' / '\n\n[note] Same call repeated 8 times — STOP looping. Explain the blockage to the user and try a different approach.';
// isError = looksLikeToolError(result) (port the classifier: startsWith 'Error'/'tool error'/'DENIED'/'fetch failed'/'search failed', exit-code prefixes) → consecutiveErrors++ else reset 0;
// consecutiveErrors ≥3 appends EXACTLY: `\n\n[CRITICAL ESCALATION] Tool calls have failed ${n} times consecutively. DO NOT continue repeating similar commands or querying missing files. Stop probing and clearly explain the exact problem to the user.`
export function isBudgetBoundary(turn: number): boolean;         // turn >= 12 && turn % 12 === 0
export const NO_PROGRESS_LIMIT = 6;                              // transient model retries only while turnsWithoutProgress < 6; any model output decrements (floor 0)
export function todoNudgeMessage(pending: readonly TodoItem[]): string;
// EXACT (Dart 12537–12542): '[system] Your SESSION TODOS still has pending items:\n' + pending.map(t => `- [${t.status==="in_progress"?"~":" "}] ${t.content}`).join("\n") + '\n\nContinue working on them. Mark each item in_progress before starting it and completed when done. If a pending item is already done or no longer relevant, update the list with todo_write. Then give your final answer.'
export function shouldSendTodoNudge(g: GuardState, todos: readonly TodoItem[]): boolean;  // pending exist && !todoNudgeSent && turnsWithoutProgress < 5
// steering.ts
export interface SteeringDeps { db: Db; sink: EventSink; }
export async function drainQueuedRuns(deps: SteeringDeps, o: { sessionId: string; activeRunId: string }): Promise<AgentMessage[]>;
// runs.listQueuedForSession(db, sessionId) oldest-first (NEW repo fn: status='queued' AND id != activeRunId, order createdAt,id); for each: claimNext (race-safe — a BullMQ delivery that wins the claim instead means THIS loop skips it, Review Focus #5); on claim: load its prompt message row, produce {role:"user", content: prompt}, runs.finish(completed), sink.emit("system_note", {code:"run_merged", mergedRunId, runId: activeRunId}); claimed-by-someone-else → skip silently; returns injected messages in queue order
// new repo: runs.listQueuedForSession(db, sessionId): Promise<RunRow[]>
```

- [ ] **Step 1: Write failing tests.** guards.test.ts (port `core_regression_test.dart` guard legs — assert the FULL appended strings byte-for-byte): identical call ×3 → note at exactly the 3rd; ×5, ×8 likewise; a different tool or different args resets streak to 1; 3 consecutive error results → CRITICAL ESCALATION text with `failed 3 times`; a success between errors resets; `recordToolResult` returns the mutated result and leaves the original object untouched; `isBudgetBoundary`: 11→false, 12→true, 13→false, 24→true; `shouldSendTodoNudge` false once sent, false at turnsWithoutProgress 5, pending `- [~]`/`- [ ]` rendering exact. steering.test.ts (TEST_DATABASE_URL): seed session with an active running run + two queued runs with prompts → drain returns both prompts in order, both run rows `completed`, two `system_note {code:"run_merged"}` events; **race pin**: pre-claim one queued run (simulating the BullMQ delivery winning) → drain skips it, no message injected, no merge note; empty queue → `[]` and zero writes.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass** (`pnpm --filter @ovid/agent-core test && pnpm --filter @ovid/db test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): loop guards (3/5/8 repeat, error escalation), steering drain with run-merge, todo nudge — exact Dart strings"`

### Task 15: Never-stop turn loop + engine composition

**Files:**
- Create: `cloud/packages/agent-core/src/loop.ts`, `cloud/packages/agent-core/src/engine.ts`
- Test: `cloud/packages/agent-core/src/loop.test.ts`, `cloud/packages/agent-core/src/engine.test.ts`
- Dart sources: the loop body (agent_service.dart ~12149–12765), `_callLlm` retry ladder (~13670–13744), stop/Stop-hook gate (~12546–12600), cancel/stale semantics; ported cases from `test/hard_stop_test.dart`, `test/session_stop_isolation_test.dart`, `test/agent_stop_fix_test.dart`, `test/agent_retry_diagnostics_test.dart`, `test/agent_double_response_test.dart`, `test/claude_style_chat_test.dart` (loop legs), `test/agent_run_code_contract_test.dart`.

**Interfaces:**
- Consumes: everything from Tasks 1–14 (ports + implementations that exist; `HookEngine`/`Compactor`/`SkillCatalog` still no-op fakes until Tasks 17–20).
- Produces:

```ts
// loop.ts
export interface NormalizedRunJob { runId: string; sessionId: string; userId: string; prompt: string; unattended: boolean; autonomy?: "safe" | "auto"; mode?: SessionMode; }   // mode: absent → engine resolves from state.mode (default "auto") — ToolContext.mode is fed from this for attended AND unattended runs (ruling R4)
export interface LoopDeps {
  db: Db; sink: EventSink; state: SessionStateStore; keys: KeyResolver;
  transports: { openai: AgentTransport; anthropic: AgentTransport };
  litellmBaseUrl: string; defaultModel: string;
  registry: ToolRegistry; approvals: ApprovalGate; hooks: HookEngine; compactor: Compactor; skills: SkillCatalog;
  sandbox: SandboxPort | null;                    // null → sandbox-backed tools absent from the roster
  windowTokens: number;                           // model context window for compaction (env, default 128_000)
  maxToolRounds?: number;                          // BOUNDED mode only (P2-compat processor passes 50 — MAX_TOOL_ROUNDS — preserving P2's tool_rounds_exhausted pin, ruling R1); undefined = never-stop
  systemPromptOverride?: string;                   // BOUNDED mode only (P2-compat passes SYSTEM_PROMPT_V1 so P2's suite stays green unmodified)
  sleep?: (ms: number) => Promise<void>; now?: () => Date;
}
export interface RunTime { cancelled: boolean; generation: number; }        // cancel token per session run
export async function runAgentLoop(job: NormalizedRunJob, deps: LoopDeps, rt: RunTime): Promise<{ status: "completed" | "failed" | "cancelled"; code?: string; message?: string }>;
// engine.ts
export interface AgentEngine {
  run(job: AgentRunJob & { unattended?: boolean; autonomy?: "safe" | "auto"; mode?: SessionMode }): Promise<void>;   // NEVER throws for run-level failures (P1 contract); infra errors propagate
  cancel(sessionId: string, reason?: string): Promise<boolean>;   // flips RunTime.cancelled + aborts the in-flight AbortController; false when no active run
  activeRun(sessionId: string): { runId: string } | null;
}
export interface AgentEngineDeps extends LoopDeps { events: EventLog; }      // sink built per session: append + eventMirror.put (P1 emit parity)
export function createAgentEngine(deps: AgentEngineDeps): AgentEngine;
```

Turn algorithm (pinned — Dart 12149–12765 order): claim handled by caller (Task 16 keeps `claimNext`); emit `run_started {runId}`; build history = newest ≤100 messages reversed (P1 `HISTORY_LIMIT` contract) + the prompt (already persisted); fire `hooks` session_start/user_prompt_submit once at entry; then `for (turn = 0; ; turn++)`: (1) cancel check → status cancelled, `runs.finish(cancelled)`, emit `run_cancelled {runId, reason?}`; (2) apply `pendingPlanMode` at the boundary + emit `plan_mode_changed` (a turn always finishes under the plan policy it started with — the Dart turn-boundary rule; `buildSystemPrompt`'s plan-section isolation (Task 7 test) is what keeps the rest of the stable block byte-identical across the swap); (3) rebuild system prompt (Task 7; `deps.systemPromptOverride` when set — P2-compat mode) — on change swap the stable block in place; (4) `pre_request` hook notes insert as leading system rows (observe-only block reason → continue); standing session/prompt hook contexts ride first; (5) `drainQueuedRuns` → user rows (steering joins EVERY request including the first); (6) model call via `resolveRoute` (preset pin from state.presetId) — **CACHE-STABLE REQUEST WIRING (ruling R3, not unit-only): before EVERY transport call the loop applies Task 3's pipeline to the actual request — `canonicalTools(computeToolRoster(...))` for byte-stable tool ordering, `markCacheBreakpoints(system, messages, tools)` to place ≤4 `AgentMessage.cacheControl` marks, volatile context last and never marked; the transports serialize the marks (anthropic: `cache_control` blocks per Task 5; openai-format: the stable prefix rides on LiteLLM's prompt cache with a `prompt_cache_key: sessionId` request header so consecutive turns of one session share a cache key)**; with the P1 ladder: ≤5 attempts, sleeps 3/9/27/60 (injectable), emit `run_started_retry {attempt: next, nextBackoffMs}` — but transient retries also require `turnsWithoutProgress < NO_PROGRESS_LIMIT`, else fail `model_transient_exhausted`; on text deltas emit `message_delta {runId, text}` (serialized promise-chain ordering, P1 parity); `onDelta` attempt-discard on retry (a failed attempt's partial text is dropped, never appended to — Dart `_discardLiveAttempt`); (7) `post_request` hook fire-and-forget; (8) context-overflow terminal (`_looksLikeContextOverflow` port: message matches /context.*(length|window)|too many tokens|maximum context/i) → force `compactor.maybeCompact` and REBUILD the request from compacted history (not insert-only — Dart C1 fix); (9) no tool calls → steering drain (queued msgs → continue), todo nudge (`shouldSendTodoNudge` → inject `todoNudgeMessage` as user row, continue), Stop-hook veto (`hooks.fireStop`; veto → inject `[system] A plugin hook vetoed the end of this run (reason: …). Continue…` and continue; user cancel always beats a veto), else finalize: persist assistant message, emit `message_completed {messageId, content}`, `runs.finish(completed)`, emit `run_completed {runId}`, return completed; **bounded mode**: when `deps.maxToolRounds` is set, a round that would exceed it → `run_failed {code:"tool_rounds_exhausted"}` (P2's pin, preserved by the compat processor — ruling R1); (10) tool calls → for EACH (sequential, Dart parity): emit `tool_started {runId, callId, name, args}`; `pre_tool` hook gate (deny → result `DENIED by hook (<plugin>): <reason>`; updatedInput merged before dispatch; ask → approvals; bypassPermission skips ONLY the ordinary user prompt — destructive-command confirmation and plan-mode "asks nothing" are checked FIRST and a hook allow can never widen them); roster/permission check via `isToolPermitted` (not permitted → `DENIED: <tool> is not available in <mode/plan> mode` — the gate and roster share Task 8's single source); approval for mutating tools per `modePolicy` (safe → deny identity-mutating outright; auto/studio → workspace-confined, outside targets prompt; drive → no prompt except destructive commands and git_push-class always-prompt tools); dispatch with `withToolTimeout(tool.execute(args, ctx), { timeoutMs: tool.timeoutMs, callKey: ctx.callKey, onKill: () => sandbox.killCall(userId, ctx.callKey) })` — the single arity pinned in Task 9; `recordToolResult` guards (fed `result.content`); spill; emit `tool_completed {runId, callId, name, ok: !result.isError, truncated?}`; **`post_tool` hook fire-and-forget with the tool name + result summary (Dart parity — the loop fires the FULL HookEvent set; T1 declares it and Task 18 implements it)**; append `{role:"tool", toolCallId, content: result.content}`; (11) steering drain again; (12) `isBudgetBoundary(turn)` → `compactor.maybeCompact`; if it folded, REBUILD msgs from the compacted history and inject the continuation nudge (Dart PR29 — appending to the stale array was the "compaction not working" bug); continue. `runs.bumpAttempt` per model attempt (P1 pin). Engine `run()` wraps the loop with claim + key-not-minted + terminal/infra error mapping preserving ALL P1 `run_failed` codes (`key_not_minted`, `model_transient_exhausted`, `model_terminal`) and the never-throw contract.

- [ ] **Step 1: Write failing tests** (stub transports/registries/gates; fake sleep recording the ladder). Tool-less parity battery (the P1 runProcessor.test.ts scenarios re-pinned at engine level): exact event sequence `run_started, message_delta+, message_completed, run_completed`; transient ×2 → 2 retry events + sleeps [3000,9000]; transient ×5 → `run_failed {code:"model_transient_exhausted"}`; terminal → immediate `model_terminal`; null key → `key_not_minted`; assistant row persisted with the full text. Loop mechanics: model returns one tool call → `tool_started`/`tool_completed` bracket the registry call, tool row appended with `toolCallId`, loop continues to a final text turn; unknown tool name → result `DENIED`-prefixed, loop continues (never crashes); repeat guard fires at streak 3 inside the tool row content; tool timeout (Task 9 fake) → killCall + exact timeout message; cancel mid-run (engine.cancel during a slow stub transport) → `run_cancelled`, status cancelled, abort signal seen by the transport; **user cancel beats Stop veto** (stub hooks.fireStop veto + cancel → cancelled, not continued); Stop veto without cancel → loop continues with the `[system] A plugin hook vetoed…` user row; todo nudge: stub state store with a pending todo + final-text turn → nudge row injected once (second stop finalizes); steering: a queued run seeded mid-loop joins the next request (via real db on TEST_DATABASE_URL) and merges per Task 14; budget boundary: stub `now`/turn counter to turn 12 → compactor.maybeCompact called and, when it reports folded, the rebuilt request no longer contains pre-cut rows (assert on the stub transport's captured messages); pre_tool gate updatedInput: registry sees the MERGED args; gate deny → `DENIED by hook (p1): reason` tool row; overflow recovery: first attempt terminal with a context-overflow message → compactor invoked and the retry request is the REBUILT (shorter) history; **cache-stable request wiring (ruling R3, end-to-end — not unit-only)**: stub transport capturing the `AgentRequest` — across two turns that include a tool round, the request's `tools` are name-sorted (canonicalTools) and byte-identical, ≤4 `cacheControl` marks sit on the stable system block and last non-volatile messages, no volatile row is marked, and the anthropic stub transport receives `cache_control` blocks (Task 5) while the openai stub receives the `prompt_cache_key: sessionId` header; **post_tool hook (F11)**: a stub HookEngine records events — a tool round fires `pre_tool` then, after `tool_completed`, `post_tool` (fire-and-forget, observe-only); **bounded mode (R1)**: LoopDeps with `maxToolRounds: 2` and a transport always returning a tool call → `run_failed {code:"tool_rounds_exhausted"}` after exactly 2 rounds; **mode feeding (R4)**: job without `mode` → `ToolContext.mode` resolved from the state store (`mode:"safe"` patched into state before the run reaches the tool); job with `mode:"drive"` → the ctx carries `drive`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** loop.ts + engine.ts → **Step 4: Verify pass** (`pnpm --filter @ovid/agent-core test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): never-stop turn loop + engine — steering, guards, hook/approval gates, stop veto, budget boundary, P1 event contract preserved"`

### Task 16: Worker integration v1 — replace the P2 interim tool loop

**Files:**
- Modify: `cloud/apps/worker/src/runProcessor.ts` (engine behind the P2-compat contract + full-deps variant), `cloud/apps/worker/src/main.ts` (production wiring), `cloud/apps/worker/src/index.ts` (exports), `cloud/apps/worker/package.json` (deps), `cloud/packages/queue/src/queues.ts` (`AgentRunJob` optional fields), `cloud/deploy/.env.example` (new vars)
- Test: `cloud/apps/worker/src/runProcessor.test.ts` (EXTEND — existing P1 cases untouched), `cloud/packages/queue/src/queues.test.ts` (append additive-field cases)
- Dart sources: n/a (integration); contract sources are P1's `runProcessor.ts` docblock and `cloud/apps/e2e/src/spine.test.ts` (must pass unmodified).

**Interfaces:**
- Consumes: `createAgentEngine`, `NormalizedRunJob` (Task 15), `createRedisApprovalBridge` + `createApprovalGate`'s timeout override seam (Task 12), `sandboxAdapter` + `agentToolAdapter` (Task 9 — P2's `AgentTool` roster → canonical `Tool`), all tool factories (Tasks 9–13), `litellmKeyResolver` (Task 6), `createOpenAiAgentTransport`/`createAnthropicTransport` (Tasks 4/5), `createGuardedEgressFetch`/`createSsrfGuard` (Task 2), `createPostgresSessionStateStore` (Task 13), P2's landed `RunDeps`/`ToolRegistry`/`SYSTEM_PROMPT_V1`/`MAX_TOOL_ROUNDS` (P2 Task 12 — the owned seam this task builds on, ruling R1).
- Produces:

```ts
// runProcessor.ts — the P2 export stays BIT-COMPATIBLE with P2's LANDED shape (ruling R1 — P2's RunDeps, not P1 v0's):
export interface RunDeps { db: Db; events: EventLog; keys: KeyProvider; transport: LegacyModelTransport; litellmBaseUrl: string; defaultModel: string; sandbox: SandboxManager; tools: ToolRegistry; sleep?: (ms: number) => Promise<void>; }   // `ToolRegistry`/`SandboxManager` = P2's local types (apps/worker/src/tools/registry.ts, @ovid/sandbox), unchanged in name and shape
// (P2's Task 12 made `sandbox` and `tools` REQUIRED and its ModelTransport tool-capable — P3 inherits that landed shape field-for-field)
export function createAgentRunProcessor(deps: RunDeps): (job: { data: AgentRunJob }) => Promise<void>;
// internally: claimNext gate (P1), then engine.run over the SAME landed machinery, in **P2-compat mode** — the engine runs with:
//   maxToolRounds = 50 (P2's MAX_TOOL_ROUNDS), systemPromptOverride = SYSTEM_PROMPT_V1 (P2's constant),
//   registry = deps.tools ADAPTED through agentToolAdapter (Task 9) — every P2 behavioral pin holds unmodified:
//   `tool_rounds_exhausted` after 50 rounds, sandbox attach errors (SandboxAdmissionError/SandboxCapacityError/RootfsUnavailable)
//   → `run_failed {code:"sandbox_unavailable"}` + finish('failed') no-throw, blocked commands → REFUSAL_MESSAGE tool result +
//   the `command_blocked` system_note, run_shell content format + caps byte-for-byte, P2's event sequence
//   (run_started, tool_started, tool_completed, message_delta*, message_completed, run_completed). P2's runProcessor.test.ts
//   cases pass UNMODIFIED against this path — they may only be appended to.
export interface FullRunDeps { db: Db; events: EventLog; keys: KeyProvider; redisQ: Redis; sandbox: SandboxPort; github: GitHubApiPort | null; litellmBaseUrl: string; defaultModel: string; anthropicBaseUrl: string; windowTokens?: number; approvalTimeoutMs?: number; sleep?: (ms: number) => Promise<void>; }
export function createFullAgentRunProcessor(deps: FullRunDeps): (job: { data: AgentRunJob & { unattended?: boolean; autonomy?: "safe" | "auto"; mode?: SessionMode } }) => Promise<void>;
// production path: real transports (openai + anthropic over guarded egress), real registry = P2's six tools ADAPTED (agentToolAdapter — additive alongside, never replacing) + P3 tools (sandbox tools + web + git/repo + memory/goals/todos/session_search + exit_plan_mode), redis approval bridge wired through createApprovalGate({... deps.approvalTimeoutMs ? { timeoutMs: deps.approvalTimeoutMs } : {}}) (Task 12's override seam), postgres state store, SSRF guard; mode feeding: job.mode ?? state.mode (default "auto") into NormalizedRunJob (ruling R4); NoopHooks/NoopCompactor until Tasks 18/19 wire them; stale-run sweeper untouched
// @ovid/queue queues.ts — ADDITIVE: agentRunJobSchema gains unattended: z.boolean().optional(), autonomy: z.enum(["safe","auto"]).optional(), mode: z.enum(["safe","auto","drive","studio"]).optional() (old payloads still parse; z.object was stripping them — P1 ledger Task 5 minor)
```

- [ ] **Step 1: Write failing tests.** runProcessor.test.ts APPENDS (never edits P1 or P2 cases): **P2-compat pins** — the compat processor over a stub transport scripting a tool round executes the ADAPTED P2 tool (fake P2 registry), appends the `role:"tool"` row, and a transport always returning a tool call fails `tool_rounds_exhausted` after exactly 50 rounds; stub sandbox attach rejecting `SandboxAdmissionError` → `run_failed {code:"sandbox_unavailable"}` no-throw; system row equals `SYSTEM_PROMPT_V1`; full-processor test: fake SandboxPort + local SSE mock serving a tool-call turn (`run_shell`) then a final text turn → events include `tool_started`/`tool_completed` between deltas, sandbox.exec received the command with a callKey, run completes; `unattended:true` job + a tool needing approval with no responder → `approval_resolved {reason:"unattended_timeout"}` (inject a short timeout by passing `approvalTimeoutMs: 500` into FullRunDeps — the Task 12 override seam — NOT an env read inside the test) and the run CONTINUES with a DENIED tool result (spec §8: reported, not crashed); `mode:"safe"` job with an identity-mutating tool → denied outright by `modePolicy` (R4 mode feeding, end-to-end); queues.test.ts: job payload with `unattended:true` (and `mode:"drive"`) survives schema validation; payload without the new fields parses unchanged.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (main.ts: build FullRunDeps from env — new vars `OVID_ANTHROPIC_BASE` (default `https://api.anthropic.com`), `OVID_WINDOW_TOKENS` (default 128000), `OVID_APPROVAL_TIMEOUT_MS` (default 120000; parsed into `FullRunDeps.approvalTimeoutMs` → `createApprovalGate`'s `timeoutMs` override — the gate reads it ONLY through this seam, never from env internally), `GITHUB_API_TOKEN` optional → `github` port null when absent; add to `deploy/.env.example`; keep the sweeper + graceful shutdown; wire `createSandboxAdapter` against P2's actual exports — read `docs/superpowers/plans/2026-10-16-ovid-cloud-p2-sandbox-manager.md` Produces blocks if present, else P2's `cloud/packages/sandbox/src` actual source at execution time; wire the P2 registry through `agentToolAdapter` (Task 9) into the full roster; the compat processor wires `transports.openai = adaptLegacyTransport(deps.transport)`, `maxToolRounds: 50`, `systemPromptOverride: SYSTEM_PROMPT_V1`) → **Step 4: Verify — the whole P1+P2+P3 surface.** `cd cloud && pnpm -r build && pnpm -r test` → green, with `apps/e2e/src/spine.test.ts` UNMODIFIED (`git diff --stat HEAD -- cloud/apps/e2e` must be empty), `liteLlm.test.ts` untouched since Task 4, and `runProcessor.test.ts` differing from P2's version ONLY by appended cases (`git diff` shows additions, no changed/deleted lines in the P1/P2 cases).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): worker v1 — full agent engine replaces the P2 interim tool loop behind the landed contracts; e2e spine green unmodified"`

### Task 17: Skills (SKILL.md loader + allowed-tools scoping) + slash commands

**Files:**
- Create: `cloud/packages/agent-core/src/skillsLoader.ts`, `cloud/packages/agent-core/src/commands.ts`, `cloud/packages/agent-core/src/tools/skills.ts`
- Modify: `cloud/apps/worker/src/runProcessor.ts` (wire skills catalog + command pre-pass into FullRunDeps engine), `cloud/apps/worker/src/main.ts`
- Test: `cloud/packages/agent-core/src/skillsLoader.test.ts`, `cloud/packages/agent-core/src/commands.test.ts`
- Dart sources: `lib/core/skills.dart`, `lib/core/commands.dart`, `lib/core/subagent_tools.dart` (policy filter reused for allowed-tools); ported cases from `test/skills_parsing_test.dart`, `test/skill_wiring_test.dart`, `test/skill_hot_reload_test.dart`, `test/workspace_skill_roots_test.dart`, `test/skills_discovery_identity_regression_test.dart`, `test/slash_command_args_test.dart`.

**Interfaces:**
- Consumes: `SandboxPort`, `SkillCatalog`/`Skill`/`SkillSummary` (Task 1), `SessionStateStore`, `Compactor` port (for `/compact` — no-op until Task 19), `nativeToolsFor` (Task 8).
- Produces:

```ts
// skillsLoader.ts
export function parseSkillFrontmatter(md: string): { attrs: Record<string, string>; body: string };  // leading --- fenced YAML-lite (key: value lines); malformed fence → attrs {} (skills_parsing_test parity)
export function createSkillCatalog(deps: { sandbox: SandboxPort }): SkillCatalog;
// discovery per session workspace: `.dsh/skills/<name>/SKILL.md` (bundle) and `.dsh/skills/<name>.md` (flat); frontmatter name/description/whenToUse/disable-model-invocation/user-invocable/allowed-tools (comma list); name collisions: bundle beats flat, first-wins across roots with a warning line in list() output (identity-regression parity); list() re-reads mtime via sandbox.listDir/stat per call — hot reload without a cache generation counter
export function skillAllowedTools(skill: Skill): string[];      // parsed allowed-tools entries expanded via nativeToolsFor
// tools/skills.ts
export function createSkillTool(deps: { catalog: SkillCatalog; onActivate(sessionId: string, scopes: string[]): Promise<void> }): Tool;
// name "skill" {name}: load → not found → 'No skill named "<n>". Available: …'; found → onActivate persists activeSkillScopes via `state.patch({activeSkillScopes: scopes})` (the SessionAgentState field from Task 1, ruling R4 — the runner's default onActivate writes the store; roster Task 8 step 7 narrows from the NEXT turn) → returns the skill CONTENT as the tool result (body verbatim, spilled at 6000)
// commands.ts
export interface CommandResult { prompt?: string; feedback?: string; clearInput: boolean; }
export function parseSlashCommand(input: string): { name: string; args: string } | null;  // only when input starts with '/'; args = remainder after first whitespace, quotes preserved for the handler (slash_command_args_test parity)
export interface CommandDeps { state: SessionStateStore; skills: SkillCatalog; presets: typeof presetById; compact(sessionId: string): Promise<string>; setMode(sessionId: string, mode: SessionMode): Promise<string>; }
export function createCommandRunner(deps: CommandDeps): (sessionId: string, input: string) => Promise<CommandResult | null>;
// BACKING (ruling R4 — every command has defined storage now that SessionAgentState carries mode/modelPin/activeSkillScopes):
//   /permission safe|auto|drive|studio → deps.setMode = state.patch({mode}) + feedback; /model <id> → state.patch({modelPin: id})
//   (Task 15's resolveRoute precedence: preset pin > modelPin — pass state.modelPin through to the route request) + feedback;
//   /compact → deps.compact is backed by the Compactor port (the manualRetain* path, Task 19; the no-op Compactor until then);
//   /todo renders from state.todos. All four persist across runs because the state store is the single source.
// seeded server-side set: /skill-name (rewrite: prompt = skill content + user args), /compact (immediate: manual compaction feedback), /plan on|off (preset toggle → pendingPlanMode + feedback), /permission safe|auto|drive|studio (mode set + feedback), /model <id> (state pin + feedback), /todo (renders checklist feedback); unknown /name → null (the prompt goes to the model verbatim — Dart parity: unknown commands are NOT errors)
// engine hook point: runAgentLoop's caller (engine.run) runs the command pre-pass BEFORE the loop when the prompt starts with '/' — a rewrite replaces the prompt row; feedback-only results finish the run with a message_completed carrying the feedback text (no model call)
```

- [ ] **Step 1: Write failing tests.** skillsLoader (fake SandboxPort serving fixture files): bundle + flat discovery; frontmatter parse incl. `disable-model-invocation: true` → `modelInvocable:false`; `/skill-name` user-invocable flag; allowed-tools `"Bash, Edit"` → expands via nativeToolsFor to the run_shell/job_* + fs_edit set; bundle-beats-flat collision. skill tool: unknown name lists available; known name returns body and calls onActivate with the scopes. commands (port `slash_command_args_test.dart`): `parseSlashCommand('/plan on')` → `{name:"plan",args:"on"}`; `/skill my-skill "two words"` keeps the quoted args; bare text → null; `/compact` returns feedback and calls deps.compact once; `/permission drive` sets mode (memory state store records `mode:"drive"` — R4 persistence); `/model claude-x` → state records `modelPin:"claude-x"`; skill activation persists `activeSkillScopes` in state; `/unknowncmd x` → null (verbatim-to-model parity); `/todo` renders `- [~]`/`- [ ]` lines. Engine-level (extend loop.test.ts): a `/plan on` prompt finishes WITHOUT a model call (message_completed carries the feedback) — assert stub transport saw zero requests.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** + worker wiring (catalog over the session workspace; command pre-pass in `engine.run`) → **Step 4: Verify pass** (`pnpm -r build && pnpm -r test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): skills — SKILL.md loader, skill tool with allowed-tools scoping; slash-command runner"`

### Task 18: Hooks engine (full Claude Code event set)

**Files:**
- Create: `cloud/packages/agent-core/src/hooks.ts`
- Modify: `cloud/apps/worker/src/runProcessor.ts` + `main.ts` (replace NoopHooks with the real engine; prompt evaluator = a quiet model call through the run's route), `cloud/apps/worker/src/index.ts`
- Test: `cloud/packages/agent-core/src/hooks.test.ts`
- Dart sources: `lib/core/hook_service.dart` (event map ~1361–1369, stdin/env contract ~445, 1848–1851, breaker ~460–560, 941–966, redaction ~1096), `lib/core/claude_code_tools.dart` (matchers); ported cases from `test/agent_hook_integration_test.dart`, `test/hook_stdin_test.dart`, `test/hook_security_test.dart`, `test/hook_matcher_parity_test.dart`, `test/hook_allow_bypass_test.dart`, `test/parallel_hooks_contract_test.dart`, `test/wave2_hooks_lifecycle_test.dart`, `test/wave2_hooks_agent_test.dart`, `test/claude_code_hooks_mcp_parity_test.dart`, `test/security_hook_env_scope_test.dart`, `test/hook_permission_request_contract_test.dart`, `test/hook_blocker_diagnostics_test.dart`, `test/hook_w07_test.dart`, `test/agent_hook_production_test.dart`, `test/superpowers_hook_e2e_test.dart`.

**Interfaces:**
- Consumes: `HookEngine`/`HookEvent`/`HookGateResult`/`HookStopResult` (Task 1), `SandboxPort` (command hooks execute in the session jail via P2 exec), `ccToolName` (Task 8), routing (Task 6) for prompt hooks.
- Produces:

```ts
export interface HookDefinition { id: string; pluginId: string; event: HookEvent; matcher?: string; type: "command" | "prompt"; command?: string; prompt?: string; timeoutMs?: number; }
export interface HookSource { hooksFor(sessionId: string): Promise<readonly HookDefinition[]>; }
export function createFileHookSource(deps: { sandbox: SandboxPort }): HookSource;  // workspace `.dsh/hooks.json` [{event, matcher?, type, command|prompt, timeoutMs?, id?}]; plugin-manifest sources plug in at P5 — the engine is source-agnostic
export const HOOK_BREAKER_THRESHOLD = 3;   // consecutive failures per (pluginId, sessionId) → that plugin's hooks are disabled for the session + a notification system_note ('…(circuit breaker) — re-enable the plugin to retry')
export type PromptHookEvaluator = (prompt: string, ctx: Record<string, unknown>) => Promise<string | null>;
export function parsePromptHookDecision(raw: string | null): { decision: "block" | "approve" | null; reason: string | null };  // JSON {"decision":"block"|"approve","reason":…} or plain-text block/approve heuristics; null/empty/throw → null = FAIL OPEN (Dart parity)
export function redactHookPayload(payload: Record<string, unknown>, secrets: readonly string[]): Record<string, unknown>;  // exact-substring replacement with [REDACTED] before stdin/env/ledger (hook_security_test parity)
export function createHookEngine(deps: { sandbox: SandboxPort; sources: readonly HookSource[]; promptEvaluator: PromptHookEvaluator; secrets?(): readonly string[]; }): HookEngine;
// command-hook execution contract (Dart ~445/1848): full JSON payload on STDIN (json.load(sys.stdin) parity); env OVID_HOOK_EVENT (declared event name), OVID_HOOK_PLUGIN, OVID_HOOK_SESSION, OVID_HOOK_PAYLOAD (redacted JSON) + Claude Code canonical spellings; matcher tested against ccToolName(tool) for tool events ('*' = all, exact, prefix'*'); exit 0 → stdout ≤2 KB is injected context (pre_request/user_prompt_submit/session_start only; session_start output becomes the STANDING sessionContextFor, user_prompt_submit the standing promptContextFor for the run); exit 2 → BLOCK: pre_tool → deny with stderr as reason; stop/subagent_stop → veto with stderr; user_prompt_submit → promptBlockReason; other exit/timeout → non-blocking error, counts toward the breaker; per-session re-entrancy: pre_tool gates SERIALIZE per session (Dart's dispatch queue rationale — a blocking hook must never fail-open a concurrent call) while observe events run concurrently (parallel_hooks_contract parity); prompt hooks: evaluator called with the hook prompt + payload ctx; decision parse as above; a prompt "block" on an OBSERVE event surfaces as promptBlockReason but cannot halt the run
```

- [ ] **Step 1: Write failing tests** (fake SandboxPort capturing cmd/env/stdin; stub evaluator): stdin/env contract — a pre_tool command hook receives the full payload JSON on stdin and the four OVID_HOOK_* env vars with the redacted payload (seed a secret, assert `[REDACTED]`); matcher parity — `Bash` matcher fires for `run_shell` (ccToolName), `Edit*` prefix fires for `fs_edit`, non-match → hook not executed; exit 2 on pre_tool → `{decision:"deny", reason:<stderr>}`; exit 2 on stop → veto; exit 0 with stdout on pre_request → `fireDetailed().output`; session_start stdout → standing `sessionContextFor`; breaker: 3 consecutive exit-1 failures → 4th event skips execution + notification; a success between failures resets; runtime errors (spawn failure) do NOT consume the breaker (Dart: runtimes remain retryable); `parsePromptHookDecision`: JSON block/approve, plain "block", garbage → null fail-open; prompt-hook throw → fail open; serialization: two concurrent `fireGate` calls for one session execute in order (fake sandbox records start/end interleaving), observe events overlap; `updatedInput`: a pre_tool hook emitting `{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{…}}}`-style JSON on stdout (port the exact Dart gate-output shape from hook_service.dart) → gate result carries updatedInput + bypassPermission.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** + worker wiring (promptEvaluator = quiet one-shot model call via `resolveRoute` + the run's transport, `streamToTranscript:false` parity — no deltas emitted) → **Step 4: Verify pass** (`pnpm -r build && pnpm -r test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): hooks engine — full Claude Code event set, stdin+env command contract via sandbox exec, prompt hooks, breaker, redaction"`

### Task 19: Lossless compaction (policy + ledger + checkpoint + replay)

**Files:**
- Create: `cloud/packages/agent-core/src/compaction/policy.ts`, `cloud/packages/agent-core/src/compaction/ledger.ts`, `cloud/packages/agent-core/src/compaction/checkpoint.ts`, `cloud/packages/agent-core/src/compaction/compactor.ts`
- Modify: `cloud/apps/worker/src/runProcessor.ts` + `main.ts` (replace NoopCompactor)
- Test: `cloud/packages/agent-core/src/compaction/compaction.test.ts`
- Dart sources: `lib/core/compaction/{compaction_policy.dart,compaction_ledger.dart,compaction_checkpoint.dart}`, `_maybeCompact*` + `_pruneOversizedToolDetailsBeforeCompact` (agent_service.dart ~10630–11300); ported cases from `test/lossless_compaction_test.dart`, `test/reset_ledger_readback_test.dart`, `test/providers_compact_test.dart`, `test/token_budget_test.dart`.

**Interfaces:**
- Consumes: `Compactor`, `AgentMessage`, `SessionStateStore` (Task 1), routing + a transport for the narrative summarizer call, `spillToolOutput` (Task 9), `EventSink`.
- Produces:

```ts
// policy.ts — constants EXACT (Dart 10632–10648)
export const COMPACTION = { thresholdRatio: 0.8, retainRatio: 0.16, absoluteThresholdTokens: 100_000, manualRetainMessages: 24, manualRetainTokens: 8_000, oversizedToolResultChars: 12_000 } as const;
export function estimateMessageTokens(text: string): number;      // Math.floor(len/4) + 4 per message (Dart heuristic)
export function checkpointBudgetTokens(window: number): number;   // round(window*0.12) clamped 2500..24000
export function compactionThresholdTokens(window: number): number; // min(round(window*0.8), 100_000)
export function splitsToolRun(msgs: readonly AgentMessage[], cutoff: number): boolean;  // retained tail must not start with a tool row whose issuing assistant turn was folded; a still-running tool never folds
export function snapCutoff(msgs: readonly AgentMessage[], from: number, cutoff: number): number;  // prefer a user-turn start keeping ≥half the intended fold, then any non-tool boundary ≤ cutoff, then nearest safe after; no safe cut → from (fold nothing)
// ledger.ts — deterministic, CUMULATIVE (never summarise a summary)
export interface LedgerUserMessage { seq: number; text: string; fullLength: number; attachments?: string[]; }  // toJson shape {s,t,n?,a?} — exact Dart wire keys
export interface CompactionLedger { users: LedgerUserMessage[]; actions: Array<{ tool: string; summary: string; ok: boolean }>; files: string[]; }
export function buildLedger(prev: CompactionLedger | null, folded: readonly AgentMessage[]): CompactionLedger;  // user rows verbatim (oversized pastes keep head+tail + fullLength marker); tool rows → one action line each; file paths touched extracted from tool args (path/file_path/pattern keys)
// checkpoint.ts
export interface CheckpointState { todos: readonly TodoItem[]; goal: SessionGoal | null; planMode: boolean; workingFolder: string | null; retainedMessages: number; }
export function renderCheckpoint(ledger: CompactionLedger, narrative: string | null, state: CheckpointState): string;  // sections: Current state (todos/goal/planMode/folder), Verbatim user instructions, Work log, Files touched, Narrative (when available); deterministic for identical inputs (no timestamps)
export const COMPACTED_SUMMARY_TAGS = { open: "<compacted-summary>", close: "</compacted-summary>" } as const;
export function compactedSystemBlock(summary: string): string;   // '…prior turns were folded into this checkpoint.\n\n<compacted-summary>\n' + summary + '\n</compacted-summary>' (Dart 10848 parity)
// compactor.ts
export function createCompactor(deps: { state: SessionStateStore; sandbox: SandboxPort; sink: EventSink; summarize(i: { messages: readonly AgentMessage[]; budgetTokens: number }): Promise<string | null>; }): Compactor;
// maybeCompact: measured = Σ estimateMessageTokens; threshold = compactionThresholdTokens(window); below → {compacted:false};
// above → FIRST pruneOversizedToolResults (any tool row content > 12_000 chars → spill full text to .spill/ via sandbox, replace with head+tail+locator ref — 'free' pressure relief; re-measure; below threshold now → {compacted:false} WITH the pruned messages returned);
// still above → cutoff = snapCutoff(msgs, 0, msgs.length - retainCount) where retainCount keeps the newest ~16% of window tokens verbatim; fold [0,cutoff) → buildLedger(prev ledger from state, folded) → narrative = deps.summarize(folded, checkpointBudgetTokens(window)) (LLM checkpoint; null on failure → deterministic ledger-only checkpoint, narrativeAvailable:false — NEVER block compaction on the model) → renderCheckpoint → persist state.compaction {ledger, summary, cutoffMessageId, compactedAtCount++} → emit compaction_completed {runId?, folded: cutoff, retained: msgs.length-cutoff, narrative: boolean} → return {compacted:true, messages: [compactedSystemBlock(summary-as-checkpoint-text) as a system row marked volatile:false-but-STABLE (it joins the cached prefix from here on), ...retainedTail]}
```

- [ ] **Step 1: Write failing tests** (port `lossless_compaction_test.dart` + `reset_ledger_readback_test.dart`): below-threshold → untouched; above-threshold → folded count + retained tail starts at a user row (never a tool row — construct a transcript whose naive cutoff splits a tool run and assert `snapCutoff` moved it); ledger cumulative: compact twice — the second ledger CONTAINS the first's user rows verbatim (no summarising of summaries) and `users` only grows; ledger JSON round-trips through `{s,t,n,a}` keys; deterministic: `renderCheckpoint` twice byte-identical; oversized-tool pruning: a 20 000-char tool row is spilled (fake sandbox received the full text) and replaced with a locator ref, and when pruning alone drops below threshold NO summarizer call happens (stub summarize asserts zero calls); summarizer failure → checkpoint still rendered (narrative-less) and compaction_completed emitted with `narrative:false`; replay pin: post-compaction request messages[0] contains `<compacted-summary>` and the retained tail is byte-identical to the pre-compaction tail; manual `/compact` path uses 24-message/8000-token retention.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** + worker wiring (`summarize` = quiet model call via route with `cacheMode:"none"`, budget = checkpointBudgetTokens) → **Step 4: Verify pass** (`pnpm -r build && pnpm -r test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): lossless compaction — 80% threshold, tool-result pruning to spill refs, safe cut points, cumulative ledger, LLM narrative checkpoint"`

### Task 20: Subagents — in-process child loops + management tools

**Files:**
- Create: `cloud/packages/agent-core/src/subagents.ts`, `cloud/packages/agent-core/src/tools/subagentTools.ts`
- Modify: `cloud/packages/db/src/schema.ts` + `repos.ts` (`sessions.parentSessionId`, `sessions.isSubagent` additive columns; `sessions.createChild`, `sessions.listChildren`), Create: `cloud/packages/db/drizzle/0003_subagent_lineage.sql`
- Modify: `cloud/apps/worker/src/runProcessor.ts` + `main.ts` (register subagent tools; child-loop supervisor)
- Test: `cloud/packages/agent-core/src/subagents.test.ts`, `cloud/packages/agent-core/src/tools/subagentTools.test.ts`
- Dart sources: `_runSubagentSession` + dispatch gates (agent_service.dart ~23006, 24482–25000), `lib/core/subagent_tools.dart`; ported cases from `test/claude_code_subagent_parity_test.dart`, `test/subagent_ceiling_test.dart`, `test/p2_subagent_races_test.dart`, `test/plugin_agent_subagent_test.dart`, `test/subagent_stop_hook_test.dart`, `test/subagent_rebuild_scope_test.dart`.

**Decision (writer, per brief): in-process child loops, NOT nested BullMQ jobs.** Justification: (1) Dart semantics are a synchronous nested run — the `dispatch_agent` tool call blocks until the child settles, and `send_message`/`interrupt_agent` coordinate with a LIVE child; a BullMQ round-trip would need a result-correlation store, adds queue latency to every dispatch, and its stalled/attempts machinery fights depth-limited recursion. (2) Cancellation is an AbortController flip instead of cross-job signaling. (3) Crash safety is already covered: child runs get their own `runs` rows, so the P1 stale-run sweeper terminalizes stranded children exactly like parents. (4) 8c/22GB discipline: children are SEQUENTIAL per parent (Dart parity — sub-calls never run in parallel); through the real flow only parent+child loops exist (the child roster drops dispatch_agent), so worst-case in-memory loops per job = 2 — the depth-2 grandchild loop exists only as defence in depth if the roster layer were bypassed, bounded at 3 total.

**Interfaces:**
- Consumes: `AgentEngine` (Task 15 — a child run is `engine.run` on a child session with `depth+1`), `SessionStateStore`, `HookEngine` (`subagent_stop`), `nativeToolsFor`/`CHILD_DENIED_TOOLS` (Task 8), `Db`.
- Produces:

```ts
// subagents.ts
export const MAX_SUBAGENT_DEPTH = 2;            // Dart _maxSubagentDepth (defence in depth — layer 1/2 are roster+dispatch refusals)
export const MAX_SUBAGENT_STOP_BLOCKS = 3;      // Dart _maxSubagentStopBlocks (Claude Code parity)
export function subagentToolPolicy(stored: readonly string[]): { allow: string[]; deny: string[] };  // exact port of SubagentToolPolicy.fromStored: '!'-prefixed deny entries, CC names via nativeToolsFor, mcp__server[__tool|__*] and mcp__* patterns, trailing-* prefix match, 'Bash(git push *)' specifiers scope the WHOLE tool; empty allow = inherit everything minus alwaysDenied
export interface ChildHandle { sessionId: string; runId: string; interrupt(reason: string): Promise<boolean>; sendMessage(text: string): Promise<void>; status(): "running" | "completed" | "failed" | "cancelled"; }
export interface SubagentSupervisor { dispatch(parent: ToolContext, args: { prompt: string; tools?: string[]; disallowedTools?: string[]; agentType?: string }): Promise<ChildHandle>; childrenOf(sessionId: string): readonly ChildHandle[]; }
export function createSubagentSupervisor(deps: { engine: AgentEngine; db: Db; state: SessionStateStore; hooks: HookEngine; sinkFactory(sessionId: string): EventSink; }): SubagentSupervisor;
// dispatch — REFUSAL PRECEDENCE (pinned, resolves the layer ambiguity): the lineage-based depth check runs FIRST (lineage = sessions.lineage chain via parentSessionId); depth >= 2 → refuse with message starting 'Subagent depth limit (2) reached — ' (Dart copy) and NO child created; the isSubagent-parent refusal (layer 3) is a BACKSTOP evaluated only when lineage data is unavailable (defence in depth — through the real flow grandchildren never occur: layer 2 drops dispatch_agent from every child roster, so a child can never dispatch in the first place). depth is 0-based: parent=0, child=1, grandchild=2; the depth-limit test FABRICATES a two-deep lineage directly against the supervisor (bypassing the roster) to exercise the depth check — the plan's own layers 2+3 make this unreachable through the real dispatch flow, which is exactly why the message is pinned at supervisor level; create child session (parentSessionId, isSubagent:true) + run row; child roster = parent's minus CHILD_DENIED_TOOLS (layer 2) filtered through subagentToolPolicy(tools/disallowedTools) persisted on the child's state; emit subagent_started {runId, childSessionId, childRunId, prompt(truncated 200)}; run the child loop IN-PROCESS (await), cancel wired to the parent's AbortSignal (parent cancel cascades — p2_subagent_races parity); child natural stop gated by hooks.fireStop(…, "subagent_stop") — a block re-enters the child loop with the reason injected, at most MAX_SUBAGENT_STOP_BLOCKS times, then the child stops anyway; settle → emit subagent_completed {childRunId, status}; dispatch_agent's TOOL RESULT = the child's final report text (report tool output when used, else last assistant message)
// tools/subagentTools.ts
export function createSubagentTools(deps: { supervisor: SubagentSupervisor; state: SessionStateStore; sink: EventSink }): Tool[];
// dispatch_agent {prompt, tools?, disallowedTools?, agentType?} timeoutMs 1_800_000; send_message {sessionId?, text} → routes to the child handle's steering queue (defaults to the newest running child); list_agents → renders children of the CURRENT session with status + first 80 chars of prompt; interrupt_agent {sessionId?, reason?} → handle.interrupt; report {summary} → records the child's final report (supervisor stores it as the dispatch result) + emits system_note {code:"report"} and returns 'Report delivered.'
// @ovid/db: sessions gains parentSessionId char(36) null + isSubagent boolean notNull default false (migration 0003); sessions.createChild(db, {parentSessionId, userId, title}) ; sessions.listChildren(db, parentSessionId); sessions.lineage(db, sessionId): Promise<string[]> (walk parentSessionId, bounded 8)
```

- [ ] **Step 1: Write failing tests.** subagents.test.ts (stub engine recording run calls, real db on TEST_DATABASE_URL): dispatch creates a child session with `isSubagent:true` + `parentSessionId`, emits `subagent_started` then `subagent_completed`; the child engine.run receives a roster WITHOUT `dispatch_agent` (layer 2) and with the `tools:["Read"]` allowlist projected (only file_read-class survive); depth: grandchild dispatch → the exact 'Subagent depth limit (2) reached — ' refusal and no third session row (FABRICATE a two-deep lineage directly against the supervisor — the real dispatch flow cannot reach depth 2 because layer 2 removes dispatch_agent from child rosters; this test exercises the defence-in-depth check, per the pinned precedence); a subagent parent calling dispatch → refusal (layer 3 — assert the depth-limit message does NOT fire first here, precedence pin: the lineage check wins when both rules match); subagent_stop block ×3 → child loop re-entered 3 times then stops (stub hooks counting); parent cancel cascades (abort the parent signal → child handle status "cancelled"); `subagentToolPolicy`: `["!Bash","Edit","mcp__srv__*","Grep(x*)"]` → deny includes run_shell+job_* (CC expansion), allow includes fs_edit + the mcp pattern + fs_grep. subagentTools.test.ts: list_agents renders status lines; send_message with no running child → 'No active subagent to message.'; interrupt_agent unknown id → error string, no throw; report → system_note + 'Report delivered.'; dispatch_agent result = child's report text when report was used, else last assistant content.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (migration via drizzle-kit generate; worker wiring registers the four tools only for non-child sessions) → **Step 4: Verify pass — FULL suite + e2e unmodified.** `cd cloud && pnpm -r build && pnpm -r test` → green.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): subagents — in-process depth-2 child loops, SubagentStop gating (≤3), send_message/interrupt_agent/list_agents/report, lineage schema"`

---

## Self-Review Notes (per writing-plans skill; run by the plan writer)

**1. Spec coverage (§6.1 agent-core bullet → task):** per-session run buckets + one-active-run (P1 `claimNext` kept — T15/T16); mid-run message queue/steering (T14); never-stop loop + transient retry 5×3/9/27/60 + no-progress 6 (T15, `NO_PROGRESS_LIMIT` T14); loop guards 3/5/8 + escalation (T14); per-tool timeouts killing exactly that call (T9 contract, T15 enforcement); dual transports (T4/T5); prompt-cache-stable prefix (T3, T7); lossless compaction ledger+checkpoint (T19); plan mode default-deny/classifier/jail (T8 policy + T15 gate; the read-only shell CLASSIFIER is carried as briefing text per plan_mode.dart's opencode-parity rationale — the hard gate covers identity-mutating tools); subagents depth-limited (T20); hooks engine incl. updatedInput + Stop/SubagentStop veto + breaker (T18, veto wiring T15); skills (T17); memory files (T13); session ledger → the P1 Redis-Stream + `session_event_mirror` IS the cloud ledger (no new work; `turn_start`/`checkpoint` barrier rows are the event stream itself — documented deviation). Approvals + 120 s + unattended §8 (T12, T16 test). BYOK direct via escrow → `KeyResolver` seam documented (T6), escrow lands P9. D5 device-tool removal (T8, asserted in T7/T8 tests). Presets (T8). ask_user_question/report (T12 kind:"question" / T20 report). session_search FTS + drizzle tsvector migration (T13). Slash commands (T17). `auto` alias passthrough (T6). Out of P3 by design: browser tools (P6), schedule_* (P4), catalog_*/MCP/plugin hooks sources (P5), image tools (P9), workflow/ralph orchestration (not in the P3 parity list; roster naturally omits unregistered tools). **No gaps found against the brief's list.**
**2. Step scan:** every code step carries a signature or pinned exact values; test steps name assertions and Dart sources; no "TBD"/"handle edge cases" lines. Two deliberate latitude notes (P2 adapter shape in T9/T16, drizzle generated-column hand-adjust in T13) are bounded by a named contract.
**3. Type consistency:** `AgentTransport`/`AgentRequest` used identically in T4/T5/T6/T15; `PromptCacheMode` declared in T1 (types.ts) and consumed by T3–T6 (single home — no promptCache.ts duplicate); `ApprovalGate.approve` signature matches T10/T11/T15 call sites; `SessionStateStore`/`TodoItem` shapes identical in T1/T13/T14/T19, and `SessionAgentState` now carries `mode`/`modelPin`/`activeSkillScopes` (R4) consumed by T7 (mode section), T8 (RosterContext/`isToolPermitted` mode gate — fed from `NormalizedRunJob.mode` resolved off `state.mode`), T15/T16 (mode feeding), T17 (setMode/model pin/skill scoping backed by `state.patch`); `withToolTimeout(promise, {timeoutMs, callKey, onKill})` defined once in T9's Produces and called with that exact arity in T15; `ToolResult {content, isError?, artifacts?}` is the canonical seam (R2) — every tool factory returns it, dispatch consumes `.content`/`.isError`, and `agentToolAdapter` (T9) bridges P2's `AgentTool` roster onto it; `canonicalJson` (T3) is the generic serializer T14's canonArgs reuses; `ccToolName`/`nativeToolsFor` defined T8, consumed T17/T18/T20; `EventSink` defined T1, used T12–T15/T19/T20. Legacy shim names (`LegacyModelTransport` etc. = P2's landed tool-capable shapes) consistent T4↔T16.
**4. Review Focus:** all five lines have their pinning tests inside the owning tasks (T12 race, T9 kill, T3/T7 byte-stability, T2/T10 redirect+DNS, T14/T16 steering exactly-once + unmodified e2e).
**5. Proportion:** 20 tasks for the largest phase; bodies are signatures + pinned constants + exact Dart copy strings, not transcripts. The plan is ~3× its spec section — justified: it carries the ported-value contract (exact strings/constants) that AG4 makes load-bearing.
