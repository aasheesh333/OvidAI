# Ovid Cloud P5 — McpRouter + Plugins + Free/Pro Tier Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Curated MCP servers work for every user as shared zero-per-user-RAM singletons; Pro users connect custom MCP servers (stdio-in-jail / Streamable HTTP / legacy SSE, incl. server-side OAuth PKCE); the plugin install pipeline lands third-party plugins atomically into user sandboxes; and the Free/Pro tier gate is enforced in router middleware, REST, and agent tools with a clean `pro_required` upgrade envelope.

**Architecture:** Two new workspace packages — `@ovid/mcp` (JSON-RPC 2025-06-18 client, 4 transports, client-side requests, SSRF-guarded egress, native handlers, REST-descriptor engine, curated catalog, envelope crypto, OAuth discovery/PKCE, system bus, McpRouter with tier gate) and `@ovid/plugins` (source resolver, archive validation, manifest normalization + CC/Codex adapters, capability grants, contribution registry, atomic install transaction). Additive extensions to `@ovid/shared` (WS system-channel ops + system event schemas + MCP/plugin DTOs), `@ovid/queue` (plugin-installs queue), `@ovid/db` (5 new tables + repos). Gateway gains `/cloud/v1/mcp/*` + `/cloud/v1/plugins/*` REST routes and the WS `system` channel hub; worker gains the MCP runtime (singletons live in the worker process; per-user data injected per call), the plugin-install processor, and the P3 roster seam (`McpToolProvider`).

**Tech Stack:** Node 22, pnpm workspaces, TypeScript strict, Vitest, Drizzle ORM (postgres.js), Fastify 5, @fastify/websocket, BullMQ 5, ioredis, zod, node:crypto (AES-256-GCM), undici fetch.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` — §6.1 (McpRouter), G9 (tier gate), D3 (escrow/secrets), §11 (MCP OAuth PKCE server-side), §16 (curated-MCP lineup is builder's latitude — the choice made here is documented in Task 6).

**Behavioral references (Dart, AG4):** `lib/core/mcp_service.dart`, `mcp_client_requests.dart`, `mcp_oauth_discovery.dart`, `native_mcp.dart`, `mcp_config_parse.dart`, `mcp_catalog_tools.dart`, `plugin_runtime.dart`, `plugin_source_resolver.dart`, `plugin_adapters.dart`, `plugin_manifest.dart`, `plugin_permissions.dart`, `native_plugins/rest_engine.dart`, `native_plugins/rest_descriptors_*.dart`, `ssrf_guard.dart`. Ported modules carry ported test cases where the Dart suite pins exact values (trim notice, backoff ladder, page caps, error codes).

**Cross-phase seams (read before dispatching any task):**

- **P2 (`@ovid/sandbox` or as-landed name):** `SandboxSpawner` (long-lived jailed stdio process: writable stdin, line-streamed stdout, kill) and `SandboxFiles` (read/write/list/stat/remove + `uploadDir` + one-shot `exec`, uid-scoped) are DEFINED in `@ovid/sandbox` by P2's revision and IMPORTED by P5's packages — `@ovid/mcp` (stdio transport) and `@ovid/plugins` (installer) each declare `@ovid/sandbox workspace:*`; P5 does NOT re-define them. Task 3 specifies the explicit mapping of the stdio transport onto P2's long-lived-process primitive. If P2 lands with drifted member names, adapt ONLY inside `cloud/apps/worker/src/sandboxSeam.ts` — every P5 test uses fakes, so no other file changes. If P2 has not landed when Task 3/14 dispatch, the controller sequences P2's seam-defining task first; `createUnavailableSandbox()` (Task 16) makes stdio/filesystem/memory/plugin installs fail with `sandbox_unavailable` while everything else works.
- **P3 (roster):** the seam is `McpToolProvider` (Task 16), registered through the canonical tool seam (`execute(args, ctx) → ToolResult {content, isError?, artifacts?}`). If P3 has not landed, P5 ships the router-level API + tests only (this plan's fallback, per controller brief); P3 later calls `createMcpToolProvider(router)` and routes `mcp__` tool-calls through the canonical `execute` seam.
- **P8 (GitHub OAuth):** the GitHub singleton reads the token from the per-user MCP config secret `GITHUB_TOKEN` (Task 5). P8 swaps in a `GitHubTokenProvider` at the same injection point.
- **P9 (escrow — CANONICAL interface):** P9's `EnvelopeCrypto` in `@ovid/escrow` is the canonical interface: `encrypt(plaintext, recordId): EncryptedEnvelope` / `decrypt(e, recordId)`, structured `EncryptedEnvelope { wrappedDek, iv, ciphertext, tag }` (all base64), AES-256-GCM with a per-record DEK wrapped under `OVID_MASTER_KEY`, AAD = recordId on BOTH layers, `EnvelopeAuthError` on any failure. Task 8's `crypto.ts` is a thin shim aligned EXACTLY to that interface shape — same method names, same recordId parameter, same envelope structure; it lives in `@ovid/mcp` only until P9 lands `@ovid/escrow`, at which point P5's call sites swap imports mechanically. P9 executes after P5 and consolidates — it does not redesign.
- **P1 (queue priority):** `plugin-installs` jobs use P1's existing mapping — `priority = tier === "free" ? 2 : 1` (gateway install route reads `users.getTier`).

## Global Constraints

- Wire format: JSON, **camelCase**; ids are **UUIDv7**; timestamps ISO-8601 UTC.
- New code only under `cloud/`; deploy target `/opt/ovid-cloud`. Never edit `/opt/ovid-gateway/*` or the live Caddyfile; `cloud/deploy/caddy-snippet.conf` edits are repo-only and owner-gated at activation (ledger T11/T12 precedent).
- Route prefix: all new HTTP under `/cloud/v1/*`; WS at `/cloud/ws`. Public (unauthenticated) routes are EXACTLY: `/cloud/v1/health`, `/cloud/v1/mcp/oauth/callback`, `/cloud/ws` (ticket IS the auth).
- Redis split (AG3): BullMQ + Streams + system-channel pub/sub on `redis-q` (noeviction). Tests use the dev containers only: `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390`; DB/Redis suites skip (not fail) when unset.
- Auth on every REST/WS handshake: Firebase ID token + App Check; dev bypass `OVID_AUTH_MODE=test`; refused when `NODE_ENV=production`.
- Error envelope (REST): `{ "error": { "code": string, "message": string } }`. REST codes ADDED by this plan: `pro_required` (HTTP **402**), `oauth_failed` (400), `unavailable` (503 when an mcp/plugins route's dependency is absent). The failure-family codes `archive_unsafe`, `invalid_source`, `grant_denied`, and `install_failed` are NOT REST response codes — they surface as WS system-event outcome reasons and `PluginDto` status/reason text (install failures arrive as events, never REST bodies). `sandbox_unavailable` is the shared sandbox-unavailable wire code (P2's `SandboxCapacityError` — tool-result text and run-failure codes, not a REST code).
- `@ovid/shared` and `@ovid/queue` extensions are strictly **ADDITIVE**: new union variants, new exports, new optional interface fields. Never edit or reorder existing members (shipped P1 code consumes them).
- Secrets NEVER in logs, events, WS frames, error messages, or plaintext columns. At rest: AES-256-GCM envelope (`OVID_MASTER_KEY` env, 64 hex chars = 32 bytes; no default value ever). Every DTO masks secret material (`hasSecrets: boolean`, never values). System-event payloads carry previews/labels only.
- Stdio MCP servers and plugin dependency scripts run ONLY inside P2 jails, never in the worker process. Worker-side staging downloads and validates archives but NEVER executes downloaded code.
- Curated MCPs are **provably shared singletons**: one handler instance per worker process, per-user data (tokens, workspace paths) injected per call. Test: two users' calls hit one server instance (Task 6 + Task 16).
- MCP protocol: client speaks `2025-06-18`; negotiated server version remembered and echoed via `MCP-Protocol-Version`; fallback when a server omits it: `2024-11-05`.
- Model-call retry policy unchanged (5 attempts, 3/9/27/60 s, in the run processor): sampling forwards to the run's transport and adds NO second retry layer.
- Capacity baseline 8 vCPU / 22 GB: curated servers cost zero per-user RAM; custom connections are bounded (`MAX_CUSTOM_CONNECTIONS`, default 64, LRU-evicted; stdio connections live only for the leasing run).
- Approvals default-deny after 120 s (spec §6.2): sampling, elicitation, plugin grants.
- Commit after every task; run `pnpm -r build && pnpm -r test` from `cloud/` before committing.

## Review Focus

1. **Hostile or flaky MCP server** — infinite `tools/list` pagination (repeated/oversized cursors), multi-MB tool results, garbage JSON-RPC frames, death mid-call. Expected: pages capped at 50, cursor ≤4096 chars and never repeated, results trimmed head+tail at 6000 chars with the exact omission notice, malformed frames answered as JSON-RPC errors, disconnect → backoff 500 ms→30 s, give up after 10, never reconnect after an explicit close. Pinned by Task 1/2 tests.
2. **Malicious plugin archive** — zip-slip (`../` entries), absolute paths, symlink escape, >64 MB payload, non-regular files. Expected: rejected during worker-side staging validation BEFORE anything is written into the sandbox; install fails `archive_unsafe`; staging discarded. Pinned by Task 12 tests.
3. **Tier-gate bypass** — Free user posts a custom server config straight at the router (not REST), a Pro user is downgraded mid-session with live custom connections, or the agent calls `catalog_add_mcp`/`agent_install_plugin` for a Free user. Expected: the gate re-checks `users.tier` at EVERY decision point (REST create, router add/connect/dispatch, install job start, agent tool), custom connections of a downgraded user are refused at next dispatch with `pro_required`, curated keep working. Pinned by Task 11/14/15/16 tests.
4. **Secret exfiltration** — MCP env secrets, OAuth tokens, plugin user-config values appearing in logs, WS system frames, session events, DTOs, or error envelopes. Expected: sealed at rest (structured `EncryptedEnvelope` via the P9-aligned crypto shim, Task 8), masked in every DTO (`hasSecrets`), never present in any emitted frame/event payload (tests grep serialized output for the literal secret). Pinned by Task 8/10/15 tests.
5. **SSRF via user-controlled URLs** — Fetch-handler target, custom HTTP/SSE MCP URL, REST-descriptor `host` extra (self-hosted GitLab/Jira), plugin ZIP download URL. Expected: one guarded egress client resolves DNS and refuses when ANY resolved address is non-public (RFC1918/loopback/link-local/CGNAT/metadata/IPv6-embedded-IPv4), ports 443/80 only. Pinned by Task 3/6/12 tests.

---

### Task 1: `@ovid/mcp` scaffold — JSON-RPC core, McpClient handshake, pagination, trim

**Files:**
- Create: `cloud/packages/mcp/package.json`, `tsconfig.json`, `vitest.config.ts`, `src/index.ts`
- Create: `cloud/packages/mcp/src/jsonrpc.ts`, `src/transport.ts`, `src/client.ts`
- Test: `cloud/packages/mcp/src/client.test.ts`
- Modify: `cloud/pnpm-workspace.yaml` (no change needed if glob `packages/*` — verify only)

**Interfaces:**
- Consumes: Task 1 monorepo conventions from P1 (package.json shape copied from `cloud/packages/shared/package.json`; deps: `zod ^3.25.76`; devDeps: `typescript ^5.6.0`, `vitest ^2.1.9`).
- Produces (everything later tasks import from `@ovid/mcp`):

```ts
// jsonrpc.ts
export interface JsonRpcRequest { jsonrpc: "2.0"; id: number | string; method: string; params?: Record<string, unknown>; }
export interface JsonRpcResponse { jsonrpc: "2.0"; id: number | string; result?: unknown; error?: { code: number; message: string; data?: unknown }; }
export interface JsonRpcNotification { jsonrpc: "2.0"; method: string; params?: Record<string, unknown>; }
export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;
export function isServerRequest(m: JsonRpcMessage): m is JsonRpcRequest; // has method AND id
export function isResponse(m: JsonRpcMessage): m is JsonRpcResponse;

// transport.ts
export interface McpTransport {
  start(): Promise<void>;
  send(msg: JsonRpcMessage): Promise<void>;
  onMessage(cb: (msg: JsonRpcMessage) => void): void;
  onClose(cb: (info: { expected: boolean }) => void): void;
  close(): Promise<void>; // expected close → onClose({expected:true}); NEVER triggers reconnect
}

// client.ts
export const MCP_PROTOCOL_VERSION = "2025-06-18";
export const PROTOCOL_FALLBACK_VERSION = "2024-11-05";
export const CLIENT_INFO = { name: "ovid-cloud", version: "1.0.0" } as const;
export const MAX_TOOL_RESULT_CHARS = 6000;
export const MAX_TOOL_LIST_PAGES = 50;
export const MAX_CURSOR_CHARS = 4096;
export interface McpToolDef { name: string; description?: string; inputSchema?: Record<string, unknown>; }
export interface McpToolCallResult { text: string; isError: boolean; content: unknown[]; }
export interface McpInitializeResult { protocolVersion: string; capabilities: Record<string, unknown>; serverInfo?: { name?: string; version?: string }; }
export interface McpClientHooks {
  onServerRequest?(req: JsonRpcRequest): Promise<JsonRpcResponse>; // Task 4 plugs in here
  onNotification?(n: JsonRpcNotification): void;
  onUnexpectedDisconnect?(): void;
}
export class McpRpcError extends Error { constructor(readonly code: number, message: string); }
export class McpTimeoutError extends Error {}
export function trimToolResult(text: string): string;
export class McpClient {
  constructor(transport: McpTransport, opts?: { requestTimeoutMs?: number; hooks?: McpClientHooks });
  get connected(): boolean;
  get protocolVersion(): string | null;
  initialize(): Promise<McpInitializeResult>;
  listTools(): Promise<McpToolDef[]>;
  callTool(name: string, args: Record<string, unknown>, opts?: { timeoutMs?: number }): Promise<McpToolCallResult>;
  request(method: string, params?: Record<string, unknown>, opts?: { timeoutMs?: number }): Promise<unknown>;
  close(): Promise<void>;
}
```

- [ ] **Step 1: Write the failing tests** in `src/client.test.ts` against an in-file `FakeTransport` (records sent messages, lets the test push responses/notifications, `close()` fires `onClose({expected})`). Test names + pinned assertions:
  - `initialize sends 2025-06-18 with roots/sampling/elicitation capabilities` — sent params deep-equal `{protocolVersion:"2025-06-18", capabilities:{roots:{listChanged:false}, sampling:{}, elicitation:{}}, clientInfo:{name:"ovid-cloud",version:"1.0.0"}}`; a response `{protocolVersion:"2024-11-05",capabilities:{tools:{}}}` → `client.protocolVersion === "2024-11-05"`; response omitting `protocolVersion` → falls back to `"2024-11-05"`.
  - `listTools follows nextCursor and merges pages` — two pages (cursor `"c1"` then none) → merged defs in page order; request params carry `{cursor:"c1"}` on page 2.
  - `listTools rejects repeated cursor` / `rejects oversized cursor` / `gives up after 50 pages` — repeated `"c1"` and a 4097-char cursor throw; 51 distinct cursors throws (count sent requests === 50 + 1 handshake-free).
  - `callTool trims at 6000 chars with the exact omission notice` — a 10 000-char single text block → `result.text === head(3000) + "\n\n[…4000 characters omitted — ask again with a narrower query to see the middle…]\n\n" + tail(3000)` (exact em-dash `—` and ellipsis `…` characters, copied from `mcp_service.dart:840`); ≤6000 chars returned verbatim.
  - `callTool joins text blocks and reports isError` — content `[{type:"text",text:"a"},{type:"image",data:"AAAA",mimeType:"image/png"},{type:"text",text:"b"}]` → `text === "a\n\n[image 3 bytes]\n\nb"`, `isError` mirrors `result.isError === true`; base64 byte size computed by decoding.
  - `JSON-RPC error response throws McpRpcError` (code preserved), `timeout throws McpTimeoutError` (fake timers, default `requestTimeoutMs` 30 000), `server request is answered via hooks.onServerRequest` (push a `{id:7,method:"ping"}` → hook response sent with id 7), `notification routed to hooks.onNotification`, `unexpected close fires onUnexpectedDisconnect and connected === false`, `close() is expected — no onUnexpectedDisconnect`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm install && pnpm --filter @ovid/mcp test` — Expected: FAIL (exports missing).
- [ ] **Step 3: Implement.** `package.json` copied from `@ovid/shared` (name `@ovid/mcp`, same scripts/exports map). `client.ts`: monotonically increasing integer ids; pending-request map keyed by `String(id)`; `isServerRequest` checked BEFORE response matching (a server request must never be mistaken for our response — Dart parity). `trimToolResult`: head/tail `MAX_TOOL_RESULT_CHARS ~/ 2` = 3000 each, notice `\n\n[…${omitted} characters omitted — ask again with a narrower query to see the middle…]\n\n`. `index.ts` re-exports all three modules.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS. `pnpm --filter @ovid/mcp build` clean.
- [ ] **Step 5: Commit.** `git add cloud/packages/mcp && git commit -m "feat(cloud): @ovid/mcp scaffold — JSON-RPC core, McpClient handshake, tools/list pagination, 6000-char trim"`

### Task 2: Streamable HTTP + legacy SSE transports, reconnect backoff

**Files:**
- Create: `cloud/packages/mcp/src/transports/http.ts`, `src/transports/sse.ts`, `src/backoff.ts`
- Test: `cloud/packages/mcp/src/transports/http.test.ts`, `src/transports/sse.test.ts`, `src/backoff.test.ts`

**Interfaces:**
- Consumes: `McpTransport`, `JsonRpcMessage`, `isServerRequest` (Task 1).
- Produces:

```ts
// transports/http.ts
export interface HttpTransportOptions {
  url: string;
  headers?: Record<string, string>;
  fetchImpl?: typeof fetch;               // tests inject; production passes the guarded fetch (Task 3)
  accessToken?: () => Promise<string | null>; // OAuth bearer (Task 9 wires it)
}
export class McpAuthRequiredError extends Error { constructor(readonly status: number, readonly wwwAuthenticate: string | null); }
export class McpSessionExpiredError extends Error {}
export interface HttpTransport extends McpTransport { setProtocolVersion(v: string): void; } // typed member — the router hands it the negotiated version (no cast)
export function createHttpTransport(opts: HttpTransportOptions): HttpTransport; // keeps Mcp-Session-Id from the initialize response header, echoes it + MCP-Protocol-Version (set via setProtocolVersion) on later requests

// transports/sse.ts
export function createSseTransport(opts: HttpTransportOptions): McpTransport; // GET url (Accept: text/event-stream) → `endpoint` event gives the POST target; all JSON-RPC both directions over the two channels. NO setProtocolVersion: legacy SSE (2024-11-05 era) has no MCP-Protocol-Version header — the router echoes the negotiated version on Streamable HTTP only

// backoff.ts
export const RECONNECT_INITIAL_MS = 500;
export const RECONNECT_MAX_MS = 30_000;
export const RECONNECT_MAX_ATTEMPTS = 10;
export interface ReconnectorOptions { connect: () => Promise<boolean>; initialMs?: number; maxMs?: number; maxAttempts?: number; schedule?: (ms: number, fn: () => void) => () => void; }
export class McpReconnector {
  constructor(opts: ReconnectorOptions);
  scheduleUnexpected(): void;  // delay = clamp(initial * 2^(attempt-1), initial, max); attempt > max → give up silently
  cancel(): void;              // user-initiated disconnect: clears timer AND attempt counter
  markConnected(): void;       // resets attempts to 0
  get attempts(): number;
}
```

- [ ] **Step 1: Write failing tests.**
  - `http.test.ts` runs a real `node:http` fixture server on `127.0.0.1:0`: `initialize round-trip captures Mcp-Session-Id and echoes it` (server asserts header on request 2); `SSE-formatted response body is parsed` (server replies `content-type: text/event-stream` with `data: {…}\n\n` → response resolves); `JSON response body parses`; `401 throws McpAuthRequiredError carrying WWW-Authenticate`; `404 on a remembered session throws McpSessionExpiredError`; `MCP-Protocol-Version header sent after initialize` (set via the `setProtocolVersion(v)` member of the returned `HttpTransport` — typed on the interface, not a cast).
  - `sse.test.ts` fixture server: `endpoint event provides POST target and messages flow both ways` (server sends `event: endpoint\ndata: /msg?sid=1\n\n`; client POSTs initialize there; server pushes the response as `event: message`); `GET refusal surfaces as transport start error`; `server closing the stream fires onClose unexpected`.
  - `backoff.test.ts` with an injected fake `schedule`: `delays double 500→1000→…→30000 cap` (pin exact sequence for attempts 1..8: 500,1000,2000,4000,8000,16000,30000,30000); `gives up after 10 attempts` (11th `scheduleUnexpected` schedules nothing); `markConnected resets`; `cancel clears pending timer and counter`; `successful connect() === true stops rescheduling`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/mcp test` — FAIL (modules missing).
- [ ] **Step 3: Implement.** HTTP transport: every outgoing message is a POST with `Accept: application/json, text/event-stream`, `Content-Type: application/json`; parse response by content-type (JSON directly; SSE → accumulate `data:` lines until the frame whose `id` matches — notifications/server-requests arriving on the stream are dispatched through `onMessage` immediately). A 202 (notification POST) resolves send(). SSE transport: line-buffered parser shared shape with `apps/worker/src/liteLlm.ts`'s reader (partial lines across chunks, `:` comments skipped); relative `endpoint` targets resolved against the GET URL. Backoff: pure timer logic via the injectable `schedule` (default `setTimeout` + unref).
- [ ] **Step 4: Run to verify pass.** `pnpm --filter @ovid/mcp test` — PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): MCP Streamable HTTP + legacy SSE transports with reconnect backoff (500ms→30s, max 10)"`

### Task 3: SSRF-guarded egress, stdio-in-sandbox transport, native transport

**Files:**
- Create: `cloud/packages/mcp/src/ssrf.ts`, `src/transports/stdio.ts`, `src/transports/native.ts`
- Test: `cloud/packages/mcp/src/ssrf.test.ts`, `src/transports/stdio.test.ts`, `src/transports/native.test.ts`

**Interfaces:**
- Consumes: `McpTransport` (Task 1); `SandboxSpawner` imported from `@ovid/sandbox` (P2's revision defines it — see seam list).
- Produces:

```ts
// ssrf.ts — port of lib/core/ssrf_guard.dart (classifier comments copied)
export type HostResolver = (host: string) => Promise<string[]>; // IP strings
export function isNonPublicAddress(ip: string): boolean;
// IPv4: 0/8, 10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.0.0/24, 192.168/16,
// 198.18/15, 224/4, 240/4, 255.255.255.255. IPv6: ::, ::1, fc00::/7, fe80::/10,
// fec0::/10, ff00::/8, ::ffff:a.b.c.d, ::a.b.c.d, 64:ff9b::/96, 2002::/16 — embedded
// IPv4 classified by the IPv4 rules. Hostname literals "localhost"/"*.localhost"/"*.local" → blocked.
export class SsrfBlockedError extends Error {}
export interface GuardedFetchOptions { resolver?: HostResolver; allowedPorts?: number[]; fetchImpl?: typeof fetch; }
export type GuardedFetch = (url: string, init?: RequestInit) => Promise<Response>;
export function createGuardedFetch(opts?: GuardedFetchOptions): GuardedFetch;
// https/http only; default allowedPorts [443, 80]; resolves the host and throws
// SsrfBlockedError when ANY resolved address is non-public (mixed record sets cannot
// slip one internal target in); loopback exemption ONLY when NODE_ENV !== "production"
// (tests/dev fixture servers run on 127.0.0.1).

// transports/stdio.ts — SandboxSpawner comes from @ovid/sandbox (P2: long-lived jailed stdio
// process with WRITABLE STDIN, LINE-STREAMED STDOUT, KILL). @ovid/mcp declares
// `@ovid/sandbox workspace:*`; P5 does NOT re-declare the interface (adapt member names only in
// worker sandboxSeam.ts if P2 as-landed differs).
// EXPLICIT MAPPING onto P2's primitive (this adapter's whole job):
//   McpTransport.send(msg)        → ONE `JSON.stringify(msg)` line written to the process's stdin
//   each stdout line               → parsed as a JsonRpcMessage → onMessage (partial lines buffered, never emitted)
//   McpTransport.close()           → process kill() → onClose({expected:true})
//   process exit not from close()  → onClose({expected:false}) → reconnector territory (Task 2/11)
// spawn(uid, {command, args, env?, cwd?}) starts the jailed long-lived process under the caller's uid.
export class McpConfigError extends Error {}
export const LAUNCHER_ONLY_COMMANDS = ["npx", "uvx", "bunx", "pnpm", "yarn"] as const;
export function createStdioTransport(spawner: SandboxSpawner, uid: string, spec: { command: string; args: string[]; env?: Record<string, string>; cwd?: string }): McpTransport;

// transports/native.ts
export interface NativeMcpHandler {
  initialize(params: Record<string, unknown>): Promise<Record<string, unknown>>;
  listTools(): Promise<McpToolDef[]>;
  callTool(name: string, args: Record<string, unknown>, ctx: McpCallContext): Promise<McpToolCallResult>;
  dispose?(): Promise<void>;
}
export interface McpCallContext {           // per-call, per-user injection — the singleton contract
  uid: string;
  secrets: Record<string, string>;           // decrypted user config (Task 8/11); NEVER logged
  workspace: WorkspaceFiles;                 // Task 5
  fetchImpl: GuardedFetch;
  systemBus?: UserSystemBus;                 // Task 10 (approvals/elicitation)
  sampler?: (req: SamplingRequest) => Promise<SamplingResult | null>; // Task 4 types, P3 wires
}
export function createNativeTransport(handler: NativeMcpHandler, ctxProvider: () => McpCallContext): McpTransport;
```

(`WorkspaceFiles`, `SamplingRequest`, `SamplingResult`, `UserSystemBus` are forward references — defined in Tasks 5/4/10; Task 3 declares them as imported types only where needed, `McpCallContext` fields optional until then. Keep the type graph acyclic: all these interfaces live in `@ovid/mcp`.)

- [ ] **Step 1: Write failing tests.**
  - `ssrf.test.ts` (injected resolver, no real DNS): `blocks literal private ranges` (parametrized: `10.0.0.1`, `127.0.0.1`, `169.254.169.254`, `192.168.1.1`, `100.100.100.200`, `198.18.0.1`, `::1`, `fc00::1`, `fe80::1`, `::ffff:127.0.0.1`, `64:ff9b::a00:1`, `2002:7f00:1::1`); `blocks hostnames resolving to any private address` (resolver returns `["93.184.216.34","127.0.0.1"]` → blocked); `allows public addresses on 443/80`; `rejects non-http schemes and odd ports` (`ftp://`, `https://x:8443` → SsrfBlockedError); `blocks localhost name forms`; `production mode blocks loopback` (with `NODE_ENV=production` stub, `http://127.0.0.1:1234` blocked; test mode allows).
  - `stdio.test.ts` with a `FakeSpawner`: `JSON-RPC lines flow over stdin/stdout` (initialize written as ONE line, response line parsed); `unrunnable launcher rejected` — `{command:"npx", args:["--yes"]}` throws `McpConfigError` (no spawn call recorded); `{command:"npx", args:["-y","mcp-server-x"]}` spawns; `process exit fires onClose unexpected`; `close() kills the process and fires expected close`; `spawn is only ever called through the injected SandboxSpawner` (the module imports NO node:child_process — assert via `grep -c "child_process" src/transports/stdio.ts === 0` in a test reading its own source file).
  - `native.test.ts`: `requests bridge to handler methods` (initialize/listTools/callTool with ctx from ctxProvider); `handler throw becomes JSON-RPC error response, never a transport crash`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/mcp test` — FAIL.
- [ ] **Step 3: Implement.** ssrf.ts: use `node:net` `isIP` for literals, `node:dns/promises` `resolve4/resolve6` (both, concatenated) as the default resolver; URL parse first, scheme/port check, then resolve-and-classify EVERY address. stdio.ts: line buffer over `onStdoutLine`, `send` = `writeLine(JSON.stringify(msg))`; launcher check: basename of command in `LAUNCHER_ONLY_COMMANDS` and no arg that is non-flag (doesn't start with `-`) → throw. native.ts: in-memory bridging transport (request → handler → response), `close()` calls `handler.dispose?.()`.
- [ ] **Step 4: Run to verify pass.** `pnpm --filter @ovid/mcp test` — PASS (Tasks 1–3 green).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): SSRF-guarded egress client + MCP stdio-in-sandbox and native transports"`

### Task 4: Client-side requests — ping, roots/list, sampling, elicitation, notifications

**Files:**
- Create: `cloud/packages/mcp/src/clientRequests.ts`
- Test: `cloud/packages/mcp/src/clientRequests.test.ts`

**Interfaces:**
- Consumes: `JsonRpcRequest`, `JsonRpcResponse` (Task 1).
- Produces (port of `mcp_client_requests.dart`; every missing injected handler degrades to the spec's refusal shape, NEVER a hang):

```ts
export interface McpRoot { uri: string; name?: string; }
export interface SamplingRequest { server: string; messages: { role: "user" | "assistant"; text: string }[]; maxTokens: number; systemPrompt?: string; temperature?: number; modelHints: string[]; preview: string; }
export interface SamplingResult { role: "assistant"; content: { type: "text"; text: string }; model?: string; stopReason?: string; }
export interface ElicitationField { name: string; type: "string" | "number" | "integer" | "boolean"; title?: string; description?: string; enumValues: string[]; defaultValue?: unknown; }
export interface ElicitationRequest { server: string; message: string; fields: ElicitationField[]; required: string[]; }
export type ElicitationResponse = { action: "accept"; content: Record<string, unknown> } | { action: "decline" } | { action: "cancel" };
export interface ClientRequestHandlers {
  rootsProvider?(server: string): McpRoot[];
  samplingApprover?(req: SamplingRequest): Promise<boolean>;
  sampler?(req: SamplingRequest): Promise<SamplingResult | null>;
  elicitor?(req: ElicitationRequest): Promise<ElicitationResponse>;
}
export const JSONRPC_METHOD_NOT_FOUND = -32601;
export const JSONRPC_INVALID_PARAMS = -32602;
export const JSONRPC_INTERNAL_ERROR = -32603;
export const JSONRPC_USER_REJECTED = -1;           // MCP: "User rejected sampling request"
export const SAMPLING_PREVIEW_MAX_CHARS = 1500;    // preview truncates with "…"
export const MAX_SERVER_LOGS = 200;                // notifications/message ring per server
export function parseSamplingRequest(server: string, params: Record<string, unknown>): SamplingRequest | null;
export function parseElicitationRequest(server: string, params: Record<string, unknown>): ElicitationRequest | null;
export function validateElicitationResponse(req: ElicitationRequest, res: ElicitationResponse): ElicitationResponse; // type-coerce + enum + required → cancel on violation (Dart `validated`)
export function createClientRequestHandler(h: ClientRequestHandlers): (server: string, req: JsonRpcRequest) => Promise<JsonRpcResponse>;
export interface NotificationSink { log(entry: { server: string; level: string; logger?: string; data?: unknown; at: string }): void; progress(p: { server: string; token: string; progress: number; total?: number; message?: string }): void; }
export function createNotificationHandler(sink: NotificationSink): (server: string, n: JsonRpcNotification) => boolean; // true when handled
```

- [ ] **Step 1: Write failing tests** (port the Dart `mcp_client_requests` cases): `ping answers {}`; `roots/list returns provider roots as {uri,name}` and `[]` when no provider; `sampling without approver or sampler → error -1 "User rejected sampling request"`; `sampling denied by approver → -1`; `sampling approved → sampler result passed through`; `sampler null → -32603 "sampling failed"`; `sampling parse: non-text content summarized as "[<type> content omitted]"`, `maxTokens default 1024`, `modelHints from modelPreferences.hints[].name`, `preview truncated at 1500 + "…"`; `elicitation without elicitor → {action:"cancel"}`; `elicitation parse rejects non-flat schemas` (property type "object" → null → `-32602`); `validateElicitationResponse coerces "42"→42 for integer, rejects enum violation → cancel, missing required → cancel`; `unknown method → -32601 "Method not found: <m>"`; `handler never throws` (throwing elicitor → `-32603`); notifications: `notifications/message recorded per server capped at 200`, `notifications/progress routed with token/progress/total`, `unhandled notification returns false`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/mcp test` — FAIL.
- [ ] **Step 3: Implement** `clientRequests.ts` exactly per signatures; wire `createClientRequestHandler` into `McpClientHooks.onServerRequest` at construction sites (router, Task 11 — no client.ts change needed).
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): MCP client-side requests — ping, roots/list, sampling with approval, elicitation, notifications"`

### Task 5: Native in-process handlers — GitHub, Filesystem, Fetch, Memory

**Files:**
- Create: `cloud/packages/mcp/src/workspace.ts`, `src/native/github.ts`, `src/native/filesystem.ts`, `src/native/fetch.ts`, `src/native/memory.ts`
- Test: `cloud/packages/mcp/src/native/github.test.ts`, `filesystem.test.ts`, `fetch.test.ts`, `memory.test.ts`

**Interfaces:**
- Consumes: `NativeMcpHandler`, `McpCallContext`, `GuardedFetch` (Task 3), `McpToolDef`, `McpToolCallResult`, `trimToolResult` (Task 1).
- Produces:

```ts
// workspace.ts — the P2 file seam (same adaptation rule as SandboxSpawner)
export interface WorkspaceEntry { name: string; type: "file" | "dir"; size: number; mtime: string; }
export interface WorkspaceFiles {
  read(uid: string, path: string): Promise<{ content: string; bytes: number } | null>;
  write(uid: string, path: string, content: string): Promise<void>;
  list(uid: string, dir: string): Promise<WorkspaceEntry[]>;
  stat(uid: string, path: string): Promise<{ type: "file" | "dir"; size: number; mtime: string } | null>;
  remove(uid: string, path: string): Promise<void>;
}
export const WORKSPACE_ROOT = "/workspace"; // jail-internal cwd; P2 adapter maps to /workspaces/users/{uid}
export function resolveWorkspacePath(base: string, p: string): string; // throws on absolute-escape or ".." above base

// native/*.ts — tool sets ported 1:1 from lib/core/native_mcp.dart
export const GITHUB_TOOLS: readonly string[];      // search_repositories, get_file_contents, create_issue, list_issues, get_issue, add_issue_comment, create_pull_request, list_pull_requests, fork_repository, list_commits, get_user
export const FILESYSTEM_TOOLS: readonly string[];  // read_file, write_file, create_or_update_file, delete_file, list_directory, get_file_info, search_files
export const FETCH_TOOLS: readonly string[];       // fetch
export const MEMORY_TOOLS: readonly string[];      // create_entities, create_relations, add_observations, search_nodes, open_nodes, read_graph
export function createGitHubHandler(deps: { apiBase?: string }): NativeMcpHandler;   // token = ctx.secrets.GITHUB_TOKEN; missing → "Configure GitHub token first: …" (never the value)
export function createFilesystemHandler(): NativeMcpHandler;                          // ALL paths through resolveWorkspacePath + ctx.workspace
export function createFetchHandler(): NativeMcpHandler;                               // ctx.fetchImpl (SSRF-guarded); html→text strip; maxChars arg default 5000, hard cap MAX_TOOL_RESULT_CHARS
export function createMemoryHandler(deps: { dir?: string }): NativeMcpHandler;        // graph persisted at {workspace}/.ovid/memory/memory.json via ctx.workspace (per user)
```

- [ ] **Step 1: Write failing tests** (fake `WorkspaceFiles` in-memory map; fake `fetchImpl` recording URLs):
  - github: `missing token → configure-first message, no HTTP call`; `search_repositories GETs {apiBase}/search/repositories?q=…&per_page=…&page=… with Accept: application/vnd.github+json and Bearer token`; `create_issue POSTs body {title,body}`; `unknown tool → isError "Unknown tool \"x\" for github MCP"`; `results trimmed via trimToolResult`.
  - filesystem: `read_file returns content`; `write_file then read_file round-trips`; `path escape rejected` (`../../etc/passwd` and absolute `/etc/passwd` → isError, workspace fake untouched); `list_directory returns entries`; `search_files matches by name substring`.
  - fetch: `fetches http(s) URL via ctx.fetchImpl and returns text`; `non-2xx → isError with status line`; `oversized body trimmed at 6000`.
  - memory: `create_entities then read_graph round-trips through the per-uid workspace file`; `two uids get separate graphs` (same handler instance, different ctx — the singleton contract); `add_observations merges; search_nodes substring-matches name/observations`; `create_relations + open_nodes traverse`.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement.** Port handler bodies from `native_mcp.dart` (tool schemas: copy `inputSchema` maps verbatim from the Dart source; GitHub REST paths verbatim). Memory JSON shape: `{entities:[{name,entityType,observations[]}], relations:[{from,to,relationType}]}`. Every handler is stateless except memory (state lives in the user's workspace) — this is what makes singletons safe.
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): native MCP handlers — GitHub, Filesystem, Fetch (SSRF-guarded), Memory"`

### Task 6: REST descriptor engine + curated catalog singletons (lineup decision)

**Files:**
- Create: `cloud/packages/mcp/src/rest/engine.ts`, `src/rest/descriptors/dev.ts`, `src/rest/descriptors/data.ts`, `src/rest/descriptors/comms.ts`, `src/rest/descriptors/index.ts`, `src/catalog.ts`
- Test: `cloud/packages/mcp/src/rest/engine.test.ts`, `src/catalog.test.ts`

**Interfaces:**
- Consumes: `NativeMcpHandler`, `McpCallContext`, `GuardedFetch`, `trimToolResult`.
- Produces:

```ts
// rest/engine.ts — port of native_plugins/rest_engine.dart (A: declarative descriptors)
export type RestAuthKind = "none" | "bearer" | "apiKeyHeader" | "basic" | "queryKey";
export interface RestToolDef { name: string; description: string; method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE"; path: string; inputSchema: Record<string, unknown>; queryArgs?: string[]; jsonBodyArg?: string; formBodyArg?: string; }
export interface CredentialField { key: string; label: string; secret: boolean; hint?: string; }
export interface RestServiceDescriptor {
  curatedId: string; displayName: string; description: string;
  baseUrl: string;                       // may contain {placeholders} filled from args/config (e.g. Jira https://{host}/rest/api/3)
  auth: RestAuthKind; authHeader?: string; authPrefix?: string; authParam?: string;
  credentialKey: string; credentialLabel: string;
  extraConfig?: CredentialField[];       // non-secret extras (host, region…) + secret siblings
  tools: RestToolDef[];
}
export const REST_DEFAULT_TIMEOUT_S = 30; export const REST_MIN_TIMEOUT_S = 5; export const REST_MAX_TIMEOUT_S = 300;
export function createRestHandler(d: RestServiceDescriptor): NativeMcpHandler;
// Engine rules (Dart parity): timeout_seconds arg tolerant-parsed, default 30, clamped 5..300;
// path {arg} substitution from args then ctx.secrets/config; queryArgs → query params;
// jsonBodyArg single map arg → JSON body; formBodyArg → x-www-form-urlencoded;
// missing credential → isError text "Configure <credentialLabel> first: open the MCP settings for <displayName>." (secret value NEVER in the message);
// non-2xx → isError with status line + body verbatim; results through trimToolResult; ALL egress via ctx.fetchImpl (SSRF-guarded).

// rest/descriptors/*.ts
export const DEV_DESCRIPTORS: readonly RestServiceDescriptor[];    // gitlab, jira, linear, figma, sentry, exa
export const DATA_DESCRIPTORS: readonly RestServiceDescriptor[];   // notion, google-drive, airtable, supabase, firebase, mongodb, s3
export const COMMS_DESCRIPTORS: readonly RestServiceDescriptor[];  // slack, discord, telegram
export const CURATED_DESCRIPTORS: readonly RestServiceDescriptor[]; // all 16, re-exported from index.ts

// catalog.ts
export interface CatalogManifestEntry { curatedId: string; displayName: string; description: string; credentialFields: CredentialField[]; tools: McpToolDef[]; }
export const CURATED_IDS: readonly string[]; // 20 ids pinned below, in this order
export const CURATED_MANIFEST: readonly CatalogManifestEntry[]; // pure data — gateway serves this without instantiating handlers
export interface CuratedCatalog { entries(): readonly CatalogEntry[]; get(curatedId: string): CatalogEntry | undefined; }
export interface CatalogEntry extends CatalogManifestEntry { handler: NativeMcpHandler; }
export function createCuratedCatalog(deps: { fetchImpl: GuardedFetch; workspace: WorkspaceFiles; githubApiBase?: string }): CuratedCatalog; // instantiates each handler EXACTLY ONCE
```

**Lineup decision (spec §16 builder's latitude — document in `catalog.ts` header comment):** 20 curated servers = 4 native (`github, filesystem, fetch, memory`) + 16 REST: dev — `gitlab, jira, linear, figma, sentry, exa`; data — `notion, google-drive, airtable, supabase, firebase, mongodb, s3`; comms — `slack, discord, telegram`. Descriptor tool sets ported from `rest_descriptors_{dev,backend,comms,aimedia}.dart`. **Excluded, with reasons:** bitbucket/trello (GitHub+Jira cover the demand); stripe (money surface is P9's); the whole infra family — vercel/railway/heroku/digitalocean/cloudflare/docker/kubernetes/terraform/zapier/make (write-heavy deploy/mutate actions on the Free tier are an incident risk; revisit as a post-launch curated expansion); redis (raw TCP RESP client from the worker to arbitrary user hosts — SSRF surface beyond HTTP; excluded until a jailed proxy exists); obsidian (local-vault concept doesn't exist in cloud workspaces); dall-e/elevenlabs/youtube (billable media generation belongs to P9's images pipeline); firebase-adjacent niches appwrite/pocketbase/vector-db (low usage); cal.com/twilio/whatsapp (cost/PII-heavy comms); discord-bot-builder (duplicate of discord).

- [ ] **Step 1: Write failing tests.**
  - `engine.test.ts` (fake fetchImpl): `path+query substitution` (GitLab `list_projects` with `{search}` → GET `{baseUrl}/projects?search=x`); `auth injection per kind` (bearer prefix, apiKeyHeader name e.g. `PRIVATE-TOKEN`, basic base64, queryKey param); `baseUrl {host} placeholder from config` (Jira without host → configure-first message, WITH host → `https://{host}/rest/api/3/…`); `jsonBodyArg posts the map` (Linear GraphQL `{query,variables}`); `formBodyArg posts urlencoded` (Stripe-style — engine capability stays even though Stripe isn't curated); `missing credential → exact configure-first text, no fetch`; `timeout_seconds clamps` (arg "999" → 300 s used; arg "abc" → isError FormatException-style message); `non-2xx verbatim`; `result trimmed at 6000`.
  - `catalog.test.ts`: `CURATED_IDS has exactly the 20 pinned ids`; `CURATED_MANIFEST entries each have ≥1 tool and credentialFields with secret:true for the credential`; `createCuratedCatalog instantiates each handler once` — call `catalog.get("fetch")!.handler.callTool(...)` as user A and user B (different ctx uids, fake workspace/fetch) and assert (a) `catalog.get("fetch")` returns the SAME object identity both times, (b) a counting wrapper records exactly one handler construction, (c) both calls succeeded with their own ctx (fetch fake saw 2 requests, workspace fake saw 2 distinct uids). THIS is the shared-singleton proof required by the brief.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement.** Port the descriptor DATA verbatim from the Dart files (names, paths, schemas, credential labels) for the 16 chosen services; the 4 native entries reuse Task 5 handlers (`filesystem`/`memory` need `workspace`; credentialFields `[]` for fetch/filesystem/memory, `[{key:"GITHUB_TOKEN",…secret:true}]` for github). `CURATED_MANIFEST` is built at module load from pure tool-def constants (each handler module exports its `*_TOOLS` defs so the manifest needs no deps).
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): REST descriptor engine + curated MCP catalog (20 shared singletons)"`

### Task 7: `.mcp.json` / Codex-TOML config parser with `${VAR}` interpolation

**Files:**
- Create: `cloud/packages/mcp/src/configParse.ts`
- Test: `cloud/packages/mcp/src/configParse.test.ts`

**Interfaces:**
- Consumes: nothing (pure module).
- Produces (port of `mcp_config_parse.dart`):

```ts
export class ConfigParseError extends Error {}
export interface McpOAuthConfigInput { authorizationUrl?: string; tokenUrl?: string; clientId?: string; scopes?: string[]; redirectUri?: string; }
export interface ImportedMcp {
  name: string;
  transport: "stdio" | "http" | "sse";
  command?: string; args?: string[]; cwd?: string; env?: Record<string, string>;
  url?: string; headers?: Record<string, string>;
  oauth?: McpOAuthConfigInput;
}
export function interpolateMcpValue(value: string, env: Record<string, string>): string;
// ${VAR} → env[VAR]; ${VAR:-default} → env[VAR] ?? "default"; UNRESOLVED ${VAR} stays literal
// (the credential gate must still see it — Dart parity).
export function parseMcpConfig(raw: string, opts?: { env?: Record<string, string> }): ImportedMcp[];
// Accepts JSON (Claude-Code .mcp.json) or TOML (Codex config.toml [mcp_servers.<name>] sections).
// Top-level server-map key must be exactly ONE of mcpServers | mcp_servers | servers → else ConfigParseError.
// Entry → transport inference: has command → stdio; has url + type:"sse" → sse; has url → http; neither → ConfigParseError.
// env/headers/url/command/args values all pass through interpolateMcpValue.
// The TOML subset parser is hand-rolled (Dart parity): sections, dotted subkeys (env.X, headers.X),
// quoted strings, arrays of strings; duplicate section or duplicate key → ConfigParseError.
```

- [ ] **Step 1: Write failing tests** (port Dart `mcp_config_parse` cases): `CC json with mcpServers parses stdio+http+sse entries`; `mcp_servers and servers aliases accepted`; `two different top-level keys → ConfigParseError`; `entry with neither command nor url → ConfigParseError`; `${VAR} interpolated from env`; `${VAR:-fallback} uses fallback when unset`; `unresolved ${VAR} stays literal`; `env and headers values interpolated`; `oauth block parsed (snake_case authorization_url/token_url/redirect_uri + scopes)`; `toml [mcp_servers.x] with command/args/env.X/headers.X parses`; `toml duplicate section rejected`; `garbage input rejected with ConfigParseError`; `empty map → []`.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement** per signature; reuse `shellSplitArgs` semantics for string-form `args` (split respecting quotes — port the small helper from `state.dart` usage).
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): .mcp.json/Codex-TOML config parser with \${VAR} interpolation"`

### Task 8: Envelope crypto + DB tables/repos (mcp servers, oauth, plugins, grants)

**Files:**
- Create: `cloud/packages/mcp/src/crypto.ts`
- Modify: `cloud/packages/db/src/schema.ts` (ADDITIVE tables), `cloud/packages/db/src/repos.ts` (ADDITIVE namespaces + `users.getTier`), `cloud/packages/db/drizzle/NNNN_<timestamp>_<name>.sql` (generated — the controller assigns NNNN at dispatch; P5 takes the number after P4's @ovid/db migration in the same wave)
- Test: `cloud/packages/mcp/src/crypto.test.ts`, `cloud/packages/db/src/mcpRepos.test.ts`

**Interfaces:**
- Consumes: `@ovid/db` conventions (`timestamptz` helper, `char(36)` UUIDv7 ids, `newId()`, ownership-scoped gets returning `null`).
- Produces:

```ts
// crypto.ts — thin shim aligned EXACTLY to P9's canonical EnvelopeCrypto (@ovid/escrow, P9 Task 11):
// same method names (encrypt/decrypt), same recordId parameter, same structured envelope. It lives
// in @ovid/mcp only until P9 lands @ovid/escrow, at which point P5's call sites swap imports
// mechanically and this shim is deleted.
export interface EncryptedEnvelope { wrappedDek: string; iv: string; ciphertext: string; tag: string; } // all base64
export interface EnvelopeCrypto { encrypt(plaintext: string, recordId: string): EncryptedEnvelope; decrypt(e: EncryptedEnvelope, recordId: string): string; }
export class EnvelopeAuthError extends Error {}
export function createEnvelopeCrypto(masterKeyHex: string): EnvelopeCrypto;
// masterKeyHex: exactly 64 hex chars (32 bytes) else throw at construction.
// encrypt: per-record random 32-byte DEK → AES-256-GCM(plaintext, DEK); DEK wrapped with
// AES-256-GCM under the master key (own IV); AAD = UTF-8 recordId on BOTH layers (a record-swap
// across rows fails auth). decrypt failure (wrong key, wrong recordId, ANY flipped byte,
// malformed envelope) → EnvelopeAuthError (never returns garbage, never throws raw crypto errors).
// recordId convention (PINNED so P9's consolidation needs no data migration):
//   mcp_servers:{row.id} · mcp_oauth_tokens:{server_id} · mcp_oauth_flows:{state} · plugins:{row.id}

// schema.ts additions (columns pinned; indexes builder's choice)
mcp_servers    { id char(36) PK, user_id text FK users.uid, name text, transport text, curated_id text|null,
                 config jsonb,               // NON-secret: {url?, command?, args?, cwd?, type?}
                 secrets_sealed jsonb,       // EncryptedEnvelope of {env?, headers?, oauth?} (recordId mcp_servers:{id})
                 enabled boolean default true, created_at, updated_at, UNIQUE(user_id, name) }
mcp_oauth_tokens { id char(36) PK, user_id text, server_id char(36) FK mcp_servers.id ON DELETE CASCADE,
                 tokens_sealed jsonb NOT NULL, // EncryptedEnvelope of {accessToken, refreshToken?, expiresAt?, registration?} (recordId mcp_oauth_tokens:{server_id})
                 updated_at, UNIQUE(server_id) }
mcp_oauth_flows { state text PK, user_id text, server_id char(36), verifier_sealed jsonb, config jsonb,
                 expires_at timestamptz, used boolean default false, created_at }
plugins        { id char(36) PK, user_id text, plugin_id text,      // canonical "publisher/name"
                 version text, source jsonb, status text,            // installing|pending_grant|active|degraded|failed|uninstalling
                 content_dir text, manifest jsonb, probe_failures jsonb, config_sealed jsonb,
                 installed_at, updated_at, UNIQUE(user_id, plugin_id) }
plugin_grants  { id char(36) PK, user_id text, plugin_id text, capabilities jsonb, env_names jsonb,
                 manifest_digest text, allow_dependency_scripts boolean default false, granted_at,
                 UNIQUE(user_id, plugin_id) }

// repos.ts additions — every read/write ownership-scoped (uid), wrong owner === not found (null)
export const mcpServers = { create(db, input): Promise<McpServerRow>; list(db, uid): Promise<McpServerRow[]>;
  get(db, id, uid): Promise<McpServerRow | null>; update(db, id, uid, patch): Promise<McpServerRow | null>;
  remove(db, id, uid): Promise<boolean>; findByName(db, uid, name): Promise<McpServerRow | null>; };
export const mcpOauthTokens = { put(db, input): Promise<void>; get(db, serverId, uid): Promise<McpOauthTokenRow | null>; remove(db, serverId, uid): Promise<void>; };
export const mcpOauthFlows = { create(db, input): Promise<void>;
  consume(db, state): Promise<McpOauthFlowRow | null>; }; // ATOMIC one-use: UPDATE … SET used=true WHERE state=$1 AND used=false AND expires_at > now() RETURNING *
export const plugins = { upsert(db, input): Promise<PluginRow>; list(db, uid): Promise<PluginRow[]>;
  get(db, id, uid): Promise<PluginRow | null>; getByPluginId(db, uid, pluginId): Promise<PluginRow | null>;
  setStatus(db, id, uid, status, extra?): Promise<void>; remove(db, id, uid): Promise<boolean>; };
export const pluginGrants = { put(db, input): Promise<void>; get(db, uid, pluginId): Promise<PluginGrantRow | null>; remove(db, uid, pluginId): Promise<void>; };
users.getTier(db, uid): Promise<string>; // row?.tier ?? "free" — missing user is Free
```

- [ ] **Step 1: Write failing tests.**
  - `crypto.test.ts` (no DB): `encrypt/decrypt round-trips unicode`; `serialized envelope never contains the plaintext`; `same plaintext twice → different ciphertexts` (random DEK/IVs); `decrypt with a different recordId → EnvelopeAuthError` (P9 pin — a record-swap across rows must fail auth); `tampered ciphertext → EnvelopeAuthError` (flip one base64 char); `wrong master key → EnvelopeAuthError`; `bad key length throws at construction`; `decrypt of a malformed/garbage envelope → EnvelopeAuthError`.
  - `mcpRepos.test.ts` (gated on `TEST_DATABASE_URL`; LOCAL `openTestDb()` + `testUid()` helpers defined IN-FILE — the small `apps/gateway/src/test/db.ts` conventions copied as literal code, NOT imported: a `@ovid/db` package test must not import from an app): `mcpServers CRUD round-trip + UNIQUE(user_id,name) violation surfaces`; `ownership: get/update/remove with wrong uid → null/false, row untouched`; `mcpOauthFlows.consume is one-use` (second consume → null; expired → null — insert with past `expires_at`); `plugins.upsert updates on (user_id,plugin_id) conflict`; `pluginGrants.put upserts capabilities`; `users.getTier missing row → "free"`, `tier "pro" round-trips`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/mcp test && pnpm --filter @ovid/db test` — FAIL.
- [ ] **Step 3: Implement.** schema/repo additions per signatures; generate migration: `cd cloud/packages/db && pnpm exec drizzle-kit generate` (journal appends `NNNN_<timestamp>_<name>.sql` — the controller assigns the migration number at dispatch, because P4 adds a migration to the same journal in the same wave; never edit or renumber an already-landed migration). Verify the generated SQL creates exactly the 5 tables + FKs and nothing else.
- [ ] **Step 4: Run to verify pass.** Both packages PASS; `pnpm -r build && pnpm -r test` green (existing P1 suites unaffected — additions only).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): envelope crypto (AES-256-GCM, OVID_MASTER_KEY) + mcp/plugin tables and repos"`

### Task 9: MCP OAuth — discovery (RFC 9728/8414 + DCR) and server-side PKCE flow

**Files:**
- Create: `cloud/packages/mcp/src/oauth/discovery.ts`, `src/oauth/flow.ts`
- Test: `cloud/packages/mcp/src/oauth/discovery.test.ts`, `src/oauth/flow.test.ts`

(Task 9 deliberately touches NO deploy files: the `ovidsi.com/oauth/callback` → gateway reverse-proxy block in `cloud/deploy/caddy-snippet.conf` is owned canonically by Task 15 — the task that creates the callback route — and this task's `DEFAULT_MCP_REDIRECT_URI` merely targets it.)

**Interfaces:**
- Consumes: `EnvelopeCrypto`, `mcpOauthTokens`, `mcpOauthFlows` (Task 8), `GuardedFetch` (Task 3). Task 10's `UserSystemBus` is NOT re-declared here — flow.ts depends only on the narrow structural `SystemEventPublisher` below, which Task 10's bus satisfies (the `UserSystemBus` type itself is declared ONCE, in Task 10).
- Produces (port of `mcp_oauth_discovery.dart` + the PKCE half of `mcp_service.dart`):

```ts
// oauth/discovery.ts
export interface DiscoveredOAuthConfig {
  authorizationUrl: string; tokenUrl: string; registrationUrl?: string;
  clientId?: string; clientSecret?: string; scopes: string[];
  resource?: string; issuer?: string; discovered: boolean;
}
export class McpOAuthError extends Error { constructor(readonly kind: "discovery" | "registration" | "token" | "callback", message: string); }
export function requireOAuthEndpoint(value: string, what: string): URL; // https OR loopback-http only; userinfo-in-URL rejected
export function discoverOAuthConfig(opts: { serverUrl: string; wwwAuthenticate?: string | null; fetchImpl?: GuardedFetch; register?: boolean; redirectUri?: string; clientName?: string }): Promise<DiscoveredOAuthConfig>;
// 1) RFC 9728 PRM: challenge resource_metadata → path-aware /.well-known/oauth-protected-resource → root;
//    declared resource must match the server origin; first authorization_servers entry = issuer.
// 2) RFC 8414/OIDC AS metadata (oauth-authorization-server path-aware, openid-configuration, trailing variants);
//    issuer mismatch → McpOAuthError; code_challenge_methods_supported present without S256 → McpOAuthError.
// 3) No PRM + no ASM → 2025-03-26 fallback: /authorize, /token, /register on the MCP origin.
// 4) register:true → RFC 7591 DCR as PUBLIC client (token_endpoint_auth_method:"none",
//    grant_types:["authorization_code","refresh_token"], PKCE S256, redirect_uris:[redirectUri]).
export const OAUTH_CLIENT_NAME = "Ovid";

// oauth/flow.ts
export const OAUTH_FLOW_TTL_MS = 600_000;                     // ten-minute, one-use attempt (Dart parity)
export const DEFAULT_MCP_REDIRECT_URI = "https://ovidsi.com/oauth/callback";
export function pkcePair(random?: (n: number) => Buffer): { verifier: string; challenge: string }; // S256, base64url no padding
export function buildAuthorizeUrl(cfg: DiscoveredOAuthConfig, o: { state: string; codeChallenge: string; redirectUri: string }): string; // includes resource (RFC 8707) when set
export interface SystemEventPublisher { publish(uid: string, event: { kind: string; requiresResponse?: boolean; payload: Record<string, unknown> }): Promise<void>; } // structural subset — Task 10's UserSystemBus satisfies it
export interface OAuthFlowDeps { db: Db; crypto: EnvelopeCrypto; systemBus: SystemEventPublisher; fetchImpl?: GuardedFetch; redirectUri?: string; } // every crypto call carries its recordId (Task 8 convention: mcp_oauth_tokens:{serverId} / mcp_oauth_flows:{state})
export interface OAuthFlow {
  start(uid: string, serverId: string): Promise<{ authorizeUrl: string }>;
  handleCallback(params: { state: string; code?: string; error?: string; iss?: string }): Promise<{ uid: string; serverId: string; ok: boolean; reason?: string }>;
  getAccessToken(uid: string, serverId: string): Promise<string | null>;   // refreshes via refresh_token when expired (sealed store)
  disconnect(uid: string, serverId: string): Promise<void>;                // forget ALL oauth material (Dart disconnectAndForgetOAuth)
}
export function createOAuthFlow(deps: OAuthFlowDeps): OAuthFlow;
```

- [ ] **Step 1: Write failing tests** (fixture AS on `127.0.0.1` http — allowed by the Task-3 loopback exemption in test mode; fake `fetchImpl` for unit-level discovery):
  - discovery: `PRM from WWW-Authenticate resource_metadata wins`; `path-aware well-known then root`; `PRM naming a different origin → McpOAuthError`; `ASM issuer mismatch → error`; `no S256 → error`; `2025-03-26 fallback endpoints when PRM+ASM missing`; `scopes from challenge scope, then PRM scopes_supported`; `DCR posts public-client registration and returns clientId`; `http non-loopback server URL rejected by requireOAuthEndpoint`; `userinfo URL rejected`.
  - flow: `start persists a one-use flow row (sealed verifier) and returns authorizeUrl with state+challenge+resource`; `handleCallback with valid state+code exchanges at token endpoint (code_verifier matches sealed value), seals tokens, publishes mcp_oauth_completed {serverId, ok:true}`; `replayed state → {ok:false, reason:"oauth_failed"}` (consume is atomic — Task 8); `expired flow → ok:false`; `iss param mismatch vs cfg.issuer → ok:false`; `error param → publishes mcp_oauth_failed`; `getAccessToken refreshes when expiresAt passed and re-seals`; `disconnect removes tokens row`; **secret-hygiene pin:** JSON.stringify of every systemBus.publish payload and every DB row's non-sealed columns never contains the fixture access token.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement** per signatures. Callback HTML response body (gateway renders, Task 15): minimal "Authorization complete — you can close this window." / failure text; flow.ts returns the data, routes own the HTML.
- [ ] **Step 4: Run to verify pass.** PASS (flow tests gated on `TEST_DATABASE_URL`; fake systemBus in unit tests).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): server-side MCP OAuth — RFC 9728/8414 discovery, DCR, PKCE flow with sealed token store"`

### Task 10: WS system channel — shared schemas (additive), gateway hub, worker system bus

**Files:**
- Create: `cloud/packages/shared/src/system.ts`, `cloud/apps/gateway/src/systemChannel.ts`, `cloud/packages/mcp/src/systemBus.ts`
- Modify: `cloud/packages/shared/src/ws.ts` (ADDITIVE variants only), `cloud/packages/shared/src/index.ts`, `cloud/apps/gateway/src/ws.ts`, `cloud/apps/gateway/src/ws.test.ts` (ADDITIVE cases only — see Step 1), `cloud/apps/gateway/src/app.ts` (deps), `cloud/apps/gateway/src/main.ts` (wiring)
- Test: `cloud/packages/shared/src/system.test.ts`, `cloud/apps/gateway/src/systemChannel.test.ts`, `cloud/packages/mcp/src/systemBus.test.ts`

**Interfaces:**
- Consumes: P1 `WsClientMsg`/`WsServerMsg` discriminated unions, gateway `handleWsConnection` (uid known after ticket verify), ioredis on redis-q.
- Produces:

```ts
// @ovid/shared src/system.ts (ADDITIVE module; ws.ts gains two union variants, existing ones untouched)
export type SystemEventKind =
  | "mcp_sampling_approval" | "mcp_elicitation" | "plugin_grant_approval"
  | "plugin_install_progress" | "mcp_oauth_completed" | "mcp_oauth_failed";
export interface SystemEventEnvelope { id: string; kind: SystemEventKind; requiresResponse: boolean; payload: Record<string, unknown>; ts: string; }
export function systemEventEnvelope(input: unknown): SystemEventEnvelope; // zod, throws
// ws.ts additions:
//   WsServerMsg variant: { op: "system_event"; event: SystemEventEnvelope }
//   WsClientMsg variant: { op: "system_response"; id: string; payload: Record<string, unknown> }

// gateway systemChannel.ts
export interface SystemHub {
  attach(uid: string, send: (e: SystemEventEnvelope) => void): () => void;  // returns detach
  publishOut(uid: string, event: SystemEventEnvelope): Promise<void>;       // gateway-originated (oauth callback)
  respond(uid: string, id: string, payload: Record<string, unknown>): Promise<void>;
  close(): Promise<void>;
}
export function createSystemHub(redis: Redis): SystemHub;
// Redis channels: sys:{uid}:out (worker/gateway → sockets), sys:{uid}:in (sockets → worker).
// One shared pub/sub subscription per uid across that uid's sockets; attach before any frame can arrive.

// @ovid/mcp systemBus.ts (worker side)
export interface UserSystemBus {
  publish(uid: string, event: Omit<SystemEventEnvelope, "ts"> & { ts?: string }): Promise<void>;
  request(uid: string, kind: SystemEventKind, payload: Record<string, unknown>, opts?: { timeoutMs?: number }): Promise<SystemResponse | null>;
  close(): Promise<void>;
}
export interface SystemResponse { id: string; payload: Record<string, unknown>; }
export const APPROVAL_TIMEOUT_MS = 120_000;   // spec §6.2 default-deny
export function createRedisSystemBus(redis: Redis, opts?: { idGen?: () => string }): UserSystemBus;
// request(): publish {id, kind, requiresResponse:true, payload} on sys:{uid}:out, await matching id on
// sys:{uid}:in; timeout → resolve null (CALLER treats null as deny); ids UUIDv7.
```

- [ ] **Step 1: Write failing tests.**
  - `system.test.ts`: envelope round-trip; unknown kind rejected; `wsServerMsg({op:"system_event",…})` and `wsClientMsg({op:"system_response",…})` parse; **regression pin:** every P1 variant still parses unchanged (copy the four existing shapes into the test).
  - `systemChannel.test.ts` (gated `TEST_REDIS_URL`, two uids): `publishOut on redis → attached socket callback receives envelope`; `two sockets same uid both receive` (fan-out); `respond publishes on sys:{uid}:in`; `detach stops delivery and releases the subscription` (subscribe-count returns to baseline).
  - `systemBus.test.ts` (gated `TEST_REDIS_URL`; a test harness subscribes to `sys:{uid}:out` and replies on `sys:{uid}:in`): `request round-trips response by id`; `timeout → null` (timeoutMs: 50); `publish fills ts and defaults requiresResponse:false`; `mismatched id ignored`; `close releases connections`.
  - gateway `ws.test.ts` ADDITION (modify existing file additively): `authenticated socket receives system_event frames pushed via systemHub` and `system_response frame from client reaches systemHub.respond`; unparseable system_response → `bad_message` error frame, connection survives.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/shared test && pnpm --filter @ovid/gateway test && pnpm --filter @ovid/mcp test` — FAIL.
- [ ] **Step 3: Implement.** Hub: `Map<uid, {sockets:Set, sub}>`, lazy ioredis `duplicate()` subscriber per uid (P1 convention: each subscribe owns its connection; detach unsubscribes when the set empties). ws.ts: after ticket verify, `const detachSystem = deps.systemHub?.attach(uid, …)` registered in the SAME teardown bookkeeping block as session subs (before any await — P1 Task-8 lesson); `processFrame` gains the `system_response` case → `deps.systemHub?.respond(uid, …)`. `GatewayDeps` gains `systemHub?: SystemHub` — the ONE canonical name for this dependency (Task 15 consumes the SAME field; no second `system:`/`hub:` alias), ADDITIVE-OPTIONAL so P1-only wiring and its untouched tests compile (ws.ts skips the system attach and answers an incoming `system_response` with a `bad_message` error frame when the field is absent); main.ts constructs `createSystemHub(redisQ)` and passes it. Worker bus: one subscriber on `sys:{uid}:in` per pending request (or a shared per-uid map — builder's choice, tests pin behavior only).
- [ ] **Step 4: Run to verify pass.** All PASS; `pnpm -r build && pnpm -r test` green (P1 gateway/worker/e2e suites untouched).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): WS system channel — additive shared schemas, gateway hub, worker system bus (120s default-deny)"`

### Task 11: McpRouter — tier gate middleware, tool naming/aliases, per-run lifecycle

**Files:**
- Create: `cloud/packages/mcp/src/toolNames.ts`, `src/router.ts`
- Test: `cloud/packages/mcp/src/toolNames.test.ts`, `src/router.test.ts`

**Interfaces:**
- Consumes: Tasks 1–10 (`McpClient`, transports, `CuratedCatalog`, `EnvelopeCrypto`, `mcpServers`/`mcpOauthTokens` repos, `users.getTier`, `UserSystemBus`, `createClientRequestHandler`, `McpReconnector`, `OAuthFlow.getAccessToken`).
- Produces (THE central P5 interface):

```ts
// toolNames.ts (Dart parity: McpConnectedTool._safe / legacyToolName / resolveTool)
export function safeServerName(name: string): string;              // lowercase, [^a-z0-9_-]+ → "_", trim "_" edges
export function toolNameFor(serverName: string, toolName: string): string; // `mcp__${safeServerName(serverName)}__${toolName}`
export function canonicalToolId(serverId: string, toolName: string): string; // `mcp:${serverId}/${toolName}`

// router.ts
export class ProRequiredError extends Error { readonly code = "pro_required"; }
export const PRO_REQUIRED_MESSAGE =
  "Custom MCP servers and third-party plugins are a Pro feature. Upgrade to Pro to connect your own servers and install plugins.";
export function isCurated(server: { curatedId: string | null }): boolean;
export interface RunContext { sessionId: string; runId: string; sampler?: (req: SamplingRequest) => Promise<SamplingResult | null>; }
export interface McpServerSummary { id: string; name: string; transport: string; curatedId: string | null; enabled: boolean; hasSecrets: boolean; status: "connected" | "disconnected" | "needs_auth"; }
export interface McpToolListing { name: string; canonicalId: string; serverId: string; curatedId: string | null; description?: string; inputSchema?: Record<string, unknown>; }
export interface ResolvedTool { listing: McpToolListing; server: McpServerSummary; }
export type AddServerInput = { imported: ImportedMcp } | { curatedId: string; name?: string };
export interface McpRouterDeps {
  db: Db; crypto: EnvelopeCrypto; catalog: CuratedCatalog; systemBus: UserSystemBus;
  spawner: SandboxSpawner; workspace: WorkspaceFiles; fetchImpl: GuardedFetch;
  oauth: Pick<OAuthFlow, "getAccessToken" | "start">;
  maxCustomConnections?: number;   // default 64, LRU-evict
  idleTtlMs?: number;              // default 600_000 for cached http/sse clients
  now?: () => Date;
}
export interface McpRouter {
  listServers(uid: string): Promise<McpServerSummary[]>;               // curated (from catalog, merged with the user's credential rows) + custom rows
  addServer(uid: string, input: AddServerInput): Promise<McpServerSummary>; // custom → TIER GATE (throws ProRequiredError); duplicate name → Error("server_exists")
  updateServer(uid: string, serverId: string, patch: { enabled?: boolean; secrets?: Record<string, unknown> }): Promise<McpServerSummary>;
  removeServer(uid: string, serverId: string): Promise<void>;          // curated: deletes only the credential row
  listTools(uid: string, runCtx?: RunContext): Promise<McpToolListing[]>; // connects what's needed lazily; curated always; custom only when tier !== "free"
  resolveTool(uid: string, name: string): Promise<ResolvedTool | null>;
  // Resolution order: exact published name → exact canonicalId → UNIQUE bare alias (exactly one
  // connected server exposes that tool name); ambiguous or unknown → null (never guess).
  callTool(uid: string, name: string, args: Record<string, unknown>, runCtx: RunContext): Promise<McpToolCallResult>;
  // tier re-checked per call for custom servers (downgrade takes effect immediately → ProRequiredError)
  connectForRun(uid: string, runCtx: RunContext): Promise<void>;        // stdio spawned per run (jailed), http/sse cached
  releaseRun(uid: string, runCtx: RunContext): Promise<void>;           // stdio killed; http/sse stay until idleTtl/LRU
  shutdown(): Promise<void>;
}
export function createMcpRouter(deps: McpRouterDeps): McpRouter;
```

- [ ] **Step 1: Write failing tests** (`router.test.ts` gated `TEST_DATABASE_URL`; fake spawner/workspace/bus/fetch; catalog built over fakes; tier flipped directly on the users row):
  - naming (expectations derived from Dart `_safe`): `safeServerName("My Server!") === "my_server"` (non-`[a-z0-9_-]` runs collapse to `_`, edge `_`s trimmed) and `toolNameFor("My Server!", "do_thing") === "mcp__my_server__do_thing"`; `canonicalToolId("0192…","search") === "mcp:0192…/search"`.
  - `free user addServer(custom http) throws ProRequiredError with code pro_required`; `free user callTool on a hand-inserted custom row throws ProRequiredError` (gate is in the router, not REST — Review Focus 3); `pro downgrade mid-session: tier flipped to free while connected → next callTool throws ProRequiredError and the connection is torn down`; `curated works for free users` (fetch singleton call succeeds).
  - `listTools merges curated + custom with published names` and `resolveTool: exact, canonical, unique-alias, ambiguous-null, unknown-null` (two servers exposing `search` → bare `"search"` resolves null; `mcp__a__search` resolves a).
  - lifecycle: `connectForRun spawns stdio via fake spawner with decrypted env` (secret value present in spawn spec, absent from any bus payload/log capture); `releaseRun kills stdio`; `http client cached between runs, evicted after idleTtl` (fake now); `LRU eviction at maxCustomConnections=1`; `unexpected stdio exit schedules reconnect via McpReconnector` (attempts observed), `removeServer cancels it`.
  - client-requests wiring: server sends `sampling/createMessage` → bus `request` observed with kind `mcp_sampling_approval` and preview payload; bus null (timeout) → JSON-RPC `-1` returned to the fake server; approve + runCtx.sampler → sampler result returned. `elicitation/create` → bus kind `mcp_elicitation`, accept-response validated and returned.
  - singleton-through-router pin: two uids call `mcp__fetch__fetch` → fake fetchImpl saw 2 requests, catalog handler instance count still 1.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement.** Router keeps `Map<serverRowId, {client, transport, reconnector, lastUsed}>`; curated entries keyed `curated:<id>:<uid>` share ONE handler but get a per-uid thin McpClient over `createNativeTransport(handler, () => ctxFor(uid, runCtx))` — the handler object identity stays shared (that's the pinned contract); ctx built per call: secrets decrypted lazily from `mcp_servers.secrets_sealed` (curated credential rows) via `crypto.decrypt(sealed, "mcp_servers:" + serverRowId)` — the Task-8 recordId convention, workspace/fetch/bus/sampler from deps+runCtx. OAuth: http transport `accessToken: () => oauth.getAccessToken(uid, serverId)`; `McpAuthRequiredError` during connect → summary status `needs_auth` (caller starts the flow via Task 15 REST). Tier read via `users.getTier` at EVERY gate point (no caching).
- [ ] **Step 4: Run to verify pass.** PASS; `pnpm -r build && pnpm -r test` green.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): McpRouter — Free/Pro tier gate middleware, mcp__ tool naming with unique-alias resolution, per-run stdio lifecycle"`

### Task 12: Plugin source resolver + two-pass archive validation

**Files:**
- Create: `cloud/packages/plugins/package.json`, `tsconfig.json`, `vitest.config.ts`, `src/index.ts`, `src/sources.ts`, `src/archive.ts`, `cloud/packages/shared/src/plugins.ts`
- Modify: `cloud/packages/shared/src/index.ts` (additive re-export)
- Test: `cloud/packages/plugins/src/sources.test.ts`, `src/archive.test.ts`

**Interfaces:**
- Consumes: `GuardedFetch`, `SsrfBlockedError` from `@ovid/mcp`; `parseMcpConfig` (paste source may contain `.mcp.json`).
- Produces:

```ts
// @ovid/shared src/plugins.ts (ADDITIVE module — the wire shape shared by REST bodies, the
// plugin-installs queue job and @ovid/plugins, per the ledger's "contracts live in shared" ruling)
export type PluginSourceInput =
  | { kind: "github"; owner: string; repo: string; ref?: string }
  | { kind: "npm"; package: string; version?: string }
  | { kind: "zip"; url: string }
  | { kind: "paste"; label: string; config: string };
export const pluginSourceInputSchema: z.ZodType<PluginSourceInput>; // discriminated union on "kind"

// @ovid/plugins src/sources.ts (re-exports PluginSourceInput from @ovid/shared)
export interface PluginProvenance { kind: string; githubRepo?: string; resolvedRef?: string; revision?: string; npmPackage?: string; npmVersion?: string; integrity?: string; url?: string; }
export interface ResolvedSource { stagingDir: string; bytes: number; provenance: PluginProvenance; discard(): Promise<void>; }
export const MAX_PAYLOAD_BYTES = 64 * 1024 * 1024;
export const MAX_METADATA_BYTES = 4 * 1024 * 1024;
export const MAX_PASTE_BYTES = 1 * 1024 * 1024;
export class PluginSourceError extends Error {}   // invalid_source family
export class ArchiveUnsafeError extends Error {}  // archive_unsafe family
export interface SourceResolverDeps { fetchImpl?: GuardedFetch; githubApiBase?: string; npmRegistryBase?: string; stagingRoot?: string; }
export function createSourceResolver(deps?: SourceResolverDeps): { resolve(input: PluginSourceInput, onProgress?: (bytes: number) => void): Promise<ResolvedSource>; };

// archive.ts
export function validateAndExtractArchive(input: { bytes: Uint8Array; format: "zip" | "tar" }, destDir: string): Promise<{ fileCount: number }>;
// TWO-PASS (Dart parity): pass 1 walks EVERY entry — reject absolute paths, any ".." segment climbing
// above root, symlink/hardlink entries whose target is absolute or escapes staging, non-regular
// non-directory entries (devices/fifos); pass 2 writes regular files + dirs ONLY (symlinks are
// SKIPPED, never created). Enforces MAX_PAYLOAD_BYTES on decoded size (zip-bomb guard: sum of
// entry sizes checked BEFORE writing; abort mid-stream when the sum exceeds the cap).
```

- [ ] **Step 1: Write failing tests.**
  - `archive.test.ts` (build fixture archives in-test with `node:zlib` tar + a minimal zip writer or checked-in binary fixtures under `src/__fixtures__/`): `safe tar extracts all files preserving relative layout`; `safe zip extracts`; `entry "../evil" rejected BEFORE any file written` (dest dir empty afterwards); `absolute path entry rejected`; `symlink escaping staging rejected (zip and tar)`; `contained symlink skipped, not created`; `fifo/device entry rejected`; `declared-size sum over 64MB rejected without writing` (craft a tar header claiming a huge size); `fileCount reported`.
  - `sources.test.ts` (fake fetchImpl; local fixture servers not needed): `github: trees API → raw downloads into staging, provenance carries repo/ref/sha`; `github tree metadata over 4MB rejected`; `npm: registry doc → tarball URL + dist.integrity sha512 VERIFIED (matching base64 sha512 of fixture bytes)`; `npm integrity mismatch → PluginSourceError, staging discarded`; `zip url: SSRF-guarded fetch` (fetchImpl fake asserting it is the guarded one; a `http://10.0.0.1/x.zip` input → SsrfBlockedError surfaces as PluginSourceError); `zip download exceeding 64MB aborted`; `paste: >1MB rejected; valid .mcp.json/plugin.json written into staging`; `npm name validation rejects "../evil" and bad chars`; `resolve() progress callback receives byte counts`; `discard() removes the staging dir`.
- [ ] **Step 2: Run to verify fail.** `pnpm install && pnpm --filter @ovid/plugins test` — FAIL.
- [ ] **Step 3: Implement.** Package scaffold copied from `@ovid/mcp` (deps: `@ovid/mcp workspace:*`, `@ovid/shared workspace:*` — sources.ts re-exports `PluginSourceInput` from `@ovid/shared`, so the dep is required, `zod`). Tar parsing: hand-rolled 512-byte-header reader (ustar) — no new dependency; zip: central-directory parse + `node:zlib` inflateRaw (or add `fflate ^0.8` — allowed, pin the choice in the commit; prefer fflate for correctness on zip64/UTF-8 names). Staging root default `os.tmpdir()/ovid-plugin-staging/<txid>`; txid = UUIDv7. GitHub raw downloads via `{githubApiBase|https://api.github.com}/repos/{owner}/{repo}/…` + `codeload` tarball shortcut allowed (builder's choice; tests pin provenance only).
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): plugin source resolver (GitHub/npm-SRI/ZIP/paste) + two-pass archive validation"`

### Task 13: Manifest normalization, CC/Codex adapters, capabilities, grants, contribution registry

**Files:**
- Create: `cloud/packages/plugins/src/manifest.ts`, `src/adapters/claudeCode.ts`, `src/adapters/codex.ts`, `src/capabilities.ts`, `src/grants.ts`, `src/registry.ts`
- Test: `cloud/packages/plugins/src/manifest.test.ts`, `src/grants.test.ts`, `src/registry.test.ts`

**Interfaces:**
- Consumes: `parseMcpConfig`, `ImportedMcp` from `@ovid/mcp`.
- Produces (port of `plugin_manifest.dart` + `plugin_adapters.dart` + `plugin_permissions.dart`):

```ts
// manifest.ts
export type PluginCapability = "workspaceRead" | "workspaceWrite" | "shellExecute" | "networkConnect"
  | "processSpawn" | "environmentRead" | "mcpRegister" | "hooksObserve" | "hooksBlock";
// NOT ported (device-era, removed by D5): sessionRead, sessionWrite, deviceControl — an adapter
// encountering them strips them and records a warning in manifest.warnings.
export interface PluginCommand { name: string; description?: string; file: string; }
export interface PluginSkill { name: string; description?: string; file: string; }   // SKILL.md
export interface PluginAgent { name: string; description?: string; file: string; }
export interface PluginHook { event: string; type: "command"; command: string; canBlock: boolean; ordinal: number; }
export interface PluginMcpServerContribution { name: string; imported: ImportedMcp; }
export interface NormalizedPluginManifest {
  pluginId: string;              // canonical "publisher/name" (lowercase, [a-z0-9-_.]+ segments)
  version: string; format: "claudeCode" | "codex" | "native";
  commands: PluginCommand[]; skills: PluginSkill[]; agents: PluginAgent[];
  hooks: PluginHook[]; mcpServers: PluginMcpServerContribution[];
  capabilities: PluginCapability[]; envNames: string[]; warnings: string[];
  rootPath: string;              // filled at install time (jail path)
}
export class ManifestError extends Error {}
export function adaptPlugin(rootDir: string): Promise<NormalizedPluginManifest>;
// .claude-plugin/plugin.json → Claude-Code adapter (commands/, skills/, agents/, hooks, .mcp.json,
// inline mcpServers incl. "./.mcp.json" pointer form); codex.toml/config shape → Codex adapter;
// bare plugin.json → native. Missing publisher identity (author) → ManifestError.
export function pluginManifestDigest(m: NormalizedPluginManifest): string; // sha256 over the canonical JSON of contributions+capabilities+envNames (NOT rootPath/version)
export function canonicalContributionId(pluginId: string, kind: "command" | "skill" | "agent" | "hook" | "mcp" | "setting", name: string, ordinal?: number): string;
// plugin:<id>/command:<name> | …/skill:<name> | …/agent:<name> | …/hook:<event>:<ordinal> | …/mcp:<name> | …/setting:<key>

// capabilities.ts (Dart inferRequestedCapabilities parity)
export function inferRequestedCapabilities(m: NormalizedPluginManifest): Set<PluginCapability>;
// any file contribution → workspaceRead; hooks → hooksObserve (+hooksBlock when canBlock,
// +shellExecute when type==="command"); mcpServers → mcpRegister (+processSpawn for stdio,
// +networkConnect for http/sse); envNames.length → environmentRead.

// grants.ts — NEVER auto-approved (Dart plugin_permissions parity)
export interface PluginGrantInput { capabilities: PluginCapability[]; envNames: string[]; manifestDigest: string; allowDependencyScripts: boolean; }
export function capabilityDelta(requested: ReadonlySet<PluginCapability>, granted: PluginGrantInput | null): PluginCapability[];
export function grantCovers(requested: ReadonlySet<PluginCapability>, granted: PluginGrantInput | null): boolean; // delta empty
export const CAPABILITY_EXPLANATIONS: Record<PluginCapability, string>; // one-line human copy per capability (approval sheet)

// registry.ts — the P3 seam (hook EXECUTION is P3's engine; this is registration only)
export interface ContributionRecord { canonicalId: string; kind: string; pluginId: string; name: string; rootPath: string; data: Record<string, unknown>; }
export interface ContributionRegistry {
  register(recs: ContributionRecord[]): void;            // existing canonicalId → IDEMPOTENT UPSERT (the record is replaced — reinstall/upgrade re-registers the same version-independent ids, so it must NOT throw); duplicate canonicalId WITHIN one register() call → throws
  unregisterPlugin(pluginId: string): number;            // returns removed count
  list(filter?: { kind?: string; pluginId?: string }): ContributionRecord[];
  get(canonicalId: string): ContributionRecord | undefined;
}
export function createContributionRegistry(): ContributionRegistry;
export function contributionsFromManifest(m: NormalizedPluginManifest): ContributionRecord[]; // canonical ids per kind
```

- [ ] **Step 1: Write failing tests** (fixture plugin trees written to `mkdtemp` in-test):
  - manifest: `claude-code bundle normalizes` (`.claude-plugin/plugin.json` + `commands/foo.md` + `.mcp.json` + hooks json → contributions with exact canonical ids `plugin:acme/demo/command:foo`, `plugin:acme/demo/mcp:bar`, `plugin:acme/demo/hook:PreToolUse:0`); `inline mcpServers and "./.mcp.json" pointer both parsed`; `codex adapter normalizes`; `missing author → ManifestError`; `unknown capability in a declaration stripped + warning recorded`; `digest stable across rootPath change, changes when a command is added`; `capability inference` (command hook → shellExecute+hooksObserve+hooksBlock+workspaceRead; stdio mcp → mcpRegister+processSpawn; env names → environmentRead).
  - grants: `capabilityDelta of a null grant = every requested capability`; `exact grant → delta []`; `update adding a hook → delta [shellExecute,…] non-empty (re-approval forced)`; `grantCovers` inverse.
  - registry: `register/list/get/unregisterPlugin`; `re-registering an existing canonicalId upserts idempotently` (reinstall pin — no throw, record replaced, total count unchanged); `duplicate canonicalId within a single register() call throws`; `unregisterPlugin removes only that plugin's records`.
- [ ] **Step 2: Run to verify fail.** FAIL.
- [ ] **Step 3: Implement.** Adapters read the fixture shapes exactly as the Dart adapters do (field-by-field port; Dart tests in `test/` for plugin_manifest are the case source per AG4 — port the pinned ones).
- [ ] **Step 4: Run to verify pass.** PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): plugin manifest normalization, CC/Codex adapters, capability inference + grants, contribution registry"`

### Task 14: Atomic install transaction into the sandbox + plugin-installs queue + WS progress/approvals

**Files:**
- Create: `cloud/packages/plugins/src/install.ts`, `cloud/apps/worker/src/pluginInstallProcessor.ts`
- Modify: `cloud/packages/queue/src/queues.ts` (ADDITIVE)
- Test: `cloud/packages/plugins/src/install.test.ts`, `cloud/packages/queue/src/pluginQueue.test.ts`

**Interfaces:**
- Consumes: Task 12 resolver/archive, Task 13 manifest/grants/registry, Task 8 `plugins`/`pluginGrants` repos + crypto, Task 10 `UserSystemBus`, `SandboxSpawner` + `SandboxFiles` imported from `@ovid/sandbox` (P2's revision defines them — see seam list).
- Produces:

```ts
// SandboxFiles comes from @ovid/sandbox (P2's revision): read/write/list/stat/remove +
// uploadDir(uid, localDir, remoteDir) + one-shot exec(uid, {command, args, cwd?, env?, timeoutMs?}).
// @ovid/plugins imports it (`@ovid/sandbox workspace:*`) — P5 does NOT define or re-declare it here
// (a package must not consume a type defined in an app).

// @ovid/queue additions (ADDITIVE — QueueServices gains an optional member; existing consumers compile.
// Package deps gain `@ovid/shared workspace:*` for the PluginSourceInput type.)
export const PLUGIN_INSTALLS = "plugin-installs";
export const PLUGIN_INSTALL_JOB_NAME = "plugin-install";
export interface PluginInstallJob { installId: string; userId: string; pluginId: string; mode: "install" | "uninstall"; source?: PluginSourceInput; } // PluginSourceInput imported from @ovid/shared — NO new workspace dep shape drift
export const pluginInstallJobSchema: z.ZodType<PluginInstallJob>;
export const PLUGIN_INSTALL_JOB_DEFAULTS = { attempts: 1 } as const;  // rollback lives in the processor (P1 ruling pattern)
export function createPluginInstallsWorker(conn: { url: string }, processor: Processor<PluginInstallJob>): Worker;
// QueueServices: pluginInstalls?: Queue<PluginInstallJob> (created by createQueues when the new
// optional flag { withPluginInstalls: true } is passed — default keeps P1 behavior byte-identical).

// install.ts
export type InstallPhase = "resolved" | "normalized" | "pending_grant" | "deps" | "probe" | "activate" | "committed" | "rolled_back" | "failed"; // "pending_grant" everywhere — same vocabulary as the plugins.status column, no second name
export interface PluginInstallOutcome { status: "active" | "degraded" | "failed"; pluginId: string; version?: string; probeFailures: string[]; reason?: string; }
export interface InstallerDeps {
  db: Db; crypto: EnvelopeCrypto; systemBus: UserSystemBus;
  resolver: { resolve(input: PluginSourceInput, onProgress?): Promise<ResolvedSource> };
  sandbox: { files: SandboxFiles; spawner: SandboxSpawner }; // both imported from @ovid/sandbox (P2)
  registry: ContributionRegistry;
  approvalTimeoutMs?: number;             // default APPROVAL_TIMEOUT_MS (120 s)
}
export function createPluginInstaller(deps: InstallerDeps): {
  install(job: PluginInstallJob): Promise<PluginInstallOutcome>;
  uninstall(job: PluginInstallJob): Promise<void>;
};
export function pluginDir(pluginId: string, version: string): string;   // `${WORKSPACE_ROOT}/.ovid/plugins/${pluginId}/${version}`
export function pluginStagingDir(pluginId: string, version: string): string; // `${pluginDir}.staging-${installId}`
```

**Transaction (Dart `plugin_runtime.dart` 8 steps, cloud-adapted):** ①resolve source into worker staging (progress events `resolved`) → ②`adaptPlugin` + digest (`normalized`) → ③grant check: stored grant covers `inferRequestedCapabilities` AND digest matches → continue; else status `pending_grant` + `systemBus.request(plugin_grant_approval, {installId, pluginId, version, capabilities:[{name, explanation}], envNames, allowDependencyScripts:false}, 120s)`; null/deny → `rolled_back` + outcome failed `grant_denied`; approve → `pluginGrants.put` (row status `pending_grant` → `active` at step ⑦) → ④`files.uploadDir(uid, stagingDir, pluginStagingDir(...))` → ⑤deps: staging contains `package.json` → `spawner`-side one-shot `exec(uid, {command:"npm", args:["install","--prefix",dir, ...(allowDependencyScripts ? [] : ["--ignore-scripts"])], cwd:dir})`; non-zero exit → rollback (`deps` phase failure) → ⑥probe: `files.stat` every contribution file; missing → recorded in `probeFailures` (status `degraded`, NOT failed — Dart parity) → ⑦write `plugins.upsert` (manifest jsonb with `rootPath = pluginDir`, sealed user config carried over from a previous install) + `registry.register(contributionsFromManifest)` (`activate`; register is an IDEMPOTENT UPSERT — Task 13 — so a reinstall/upgrade re-registering the same version-independent canonicalIds never throws) → ⑧COMMIT: `exec(uid, {command:"mv", args:[stagingDir, activeDir]})` — the atomic rename; mv failure → registry.unregisterPlugin + row status `failed` + staging removed (prior active version untouched — the upgrade-rollback guarantee); success → remove the previous version dir, publish `committed`. ANY failure before ⑧: staging discarded (`ResolvedSource.discard` + remote staging rm), no registry entries survive, row `failed`/`rolled_back`. Every phase publishes `plugin_install_progress {installId, pluginId, phase, message?}` (requiresResponse:false). `${user_config.x}` substitution: at ⑦, plugin manifest env values containing `${user_config.x}` are resolved from the row's sealed `config_sealed` map; unresolved → literal (credential gate shows it). Uninstall: `unregisterPlugin` + remote `rm -rf pluginDir` + row/grant removal.

- [ ] **Step 1: Write failing tests.** `install.test.ts` (gated `TEST_DATABASE_URL`; fake SandboxFiles over an in-memory fs map + fake spawner + fake resolver serving a fixture tree; real systemBus replaced by a fake that auto-responds):
  - `happy path: phases published in order resolved→normalized→(grant)→deps→probe→activate→committed; row active; registry populated with canonical ids; content at pluginDir (staging renamed)`
  - `no stored grant → pending_grant + approval request payload carries explanations, NEVER a secret; approve → grant row persisted with digest + allowDependencyScripts`
  - `approval timeout (fake bus returns null) → rolled_back, outcome failed grant_denied, NO remote dir, NO registry entries, NO grant row`
  - `deny response → same as timeout`
  - `digest change on reinstall forces re-approval` (second install with modified manifest → approval requested again; after approval the install COMMITS and the registry re-registers the same canonicalIds idempotently — upsert per Task 13, no duplicate-canonicalId throw, record count unchanged)
  - `deps: npm install invoked with --ignore-scripts by default; with allowDependencyScripts grant → without the flag; non-zero exit → rolled_back, staging gone, prior version row untouched`
  - `probe: missing contribution file → status degraded + probeFailures lists it (commit still happens)`
  - `rename failure (fake exec mv exit 1) → registry emptied, row failed, previous active version still present and registered`
  - `uninstall removes dir, rows, registry entries`
  - `user_config substitution: manifest env "${user_config.api_key}" resolved from sealed config at activation; unresolved stays literal`
  - `tier re-check: users.getTier flipped to free before job start → outcome failed pro_required` (gate at job start — Review Focus 3)
  - secret hygiene: JSON.stringify of every bus payload contains no fixture secret values.
  - `pluginQueue.test.ts` (gated `TEST_REDIS_URL`): `schema accepts/rejects`; `worker consumes a job added with priority 2` (round-trip through real BullMQ, processor stub).
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/plugins test && pnpm --filter @ovid/queue test` — FAIL.
- [ ] **Step 3: Implement.** `pluginInstallProcessor.ts`: claim-by-status (`plugins.setStatus(id, uid, "installing")` guarded — a job whose row is already terminal no-ops), call installer, map outcome → final status, job COMPLETES on run-level failure (P1 attempts:1 ruling pattern); only infra throws propagate.
- [ ] **Step 4: Run to verify pass.** PASS; `pnpm -r build && pnpm -r test` green.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): atomic plugin install transaction into sandbox + plugin-installs queue + WS progress/grant approvals"`

### Task 15: Gateway REST — /cloud/v1/mcp/*, /cloud/v1/plugins/*, OAuth endpoints, system responses

**Files:**
- Create: `cloud/apps/gateway/src/routes/mcpServers.ts`, `src/routes/mcpCatalog.ts`, `src/routes/mcpOauth.ts`, `src/routes/plugins.ts`, `src/routes/systemResponses.ts`, `cloud/packages/shared/src/mcpRest.ts` (DTO module)
- Modify: `cloud/apps/gateway/src/app.ts` (register routes + public callback scope), `src/env.ts` (`OVID_MASTER_KEY`, `OVID_MCP_REDIRECT_URI`), `src/main.ts`, `cloud/packages/shared/src/index.ts` (additive re-export), `cloud/deploy/.env.example` (if present — else `DEPLOY.md` env table), `cloud/deploy/docker-compose.yml` (env passthrough for gateway+worker: `OVID_MASTER_KEY`)
- Test: `cloud/apps/gateway/src/routes/mcpServers.test.ts`, `mcpCatalog.test.ts`, `mcpOauth.test.ts`, `plugins.test.ts`, `systemResponses.test.ts`

**Interfaces:**
- Consumes: `parseMcpConfig`, `CURATED_MANIFEST`, `createEnvelopeCrypto`, `createOAuthFlow`, repos (Task 8), `SystemHub.respond/publishOut`, `PLUGIN_INSTALLS` queue, `users.getTier`, P1 route helpers (`sendError/badRequest/notFound/zodBadRequest/isUuid/parsePageLimit`).
- Produces:

```ts
// @ovid/shared src/mcpRest.ts (ADDITIVE DTOs)
export interface McpServerDto { id: string; name: string; transport: "stdio" | "http" | "sse" | "native"; curatedId: string | null; url?: string; command?: string; enabled: boolean; hasSecrets: boolean; needsAuth: boolean; createdAt: string; updatedAt: string; }
export interface CatalogServerDto { curatedId: string; displayName: string; description: string; credentialFields: { key: string; label: string; secret: boolean; hint?: string }[]; tools: { name: string; description?: string }[]; configured: boolean; }
export interface PluginDto { id: string; pluginId: string; version: string; status: string; source: { kind: string; label: string }; capabilities: string[]; probeFailures: string[]; installedAt: string; updatedAt: string; }
export interface PluginInstallResponse { installId: string; status: "queued"; }
export const mcpServerDtoSchema / catalogServerDtoSchema / pluginDtoSchema: z.ZodType<…>;

// routes (all under the authenticated /cloud/v1 scope EXCEPT the oauth callback)
POST   /cloud/v1/mcp/servers            // body {name, pasted: string} | {name, transport, url?|command?, args?, env?, headers?}; free+custom → 402 pro_required (PRO_REQUIRED_MESSAGE); env/headers sealed; curatedId body variant {curatedId, secrets} allowed for ALL tiers
GET    /cloud/v1/mcp/servers            // McpServerDto[] (+ curated entries merged, configured flag)
GET    /cloud/v1/mcp/servers/:id        // 404 unknown/wrong-owner (never 403)
PATCH  /cloud/v1/mcp/servers/:id        // {enabled?, secrets?} — secrets REPLACE the sealed blob
DELETE /cloud/v1/mcp/servers/:id
GET    /cloud/v1/mcp/catalog            // {items: CatalogServerDto[]} from CURATED_MANIFEST + configured flags
GET    /cloud/v1/mcp/oauth/start?serverId=…   // → {authorizeUrl}; starts Task-9 flow (needsAuth prerequisite)
GET    /cloud/v1/mcp/oauth/callback           // PUBLIC scope; query {state, code?, error?, iss?} → HTML page; publishes mcp_oauth_completed/failed via systemHub.publishOut
POST   /cloud/v1/mcp/oauth/disconnect         // {serverId} → forget tokens
GET    /cloud/v1/plugins                      // PluginDto[]
POST   /cloud/v1/plugins/install              // {source: PluginSourceInput} validated with @ovid/shared pluginSourceInputSchema (no @ovid/plugins dep in the gateway); free → 402 pro_required; creates plugins row (status queued→installing by worker) + enqueues PluginInstallJob {priority: tier free?2:1}; → 202 PluginInstallResponse
GET    /cloud/v1/plugins/:id
PATCH  /cloud/v1/plugins/:id/config           // {config: Record<string,string>} → sealed into config_sealed (for ${user_config.x})
DELETE /cloud/v1/plugins/:id                  // enqueues mode:"uninstall" → 202
POST   /cloud/v1/system/responses             // {id, payload} → systemHub.respond(uid, …) — the REST answer path for ANY pending approval (spec §6.2 "client answers via REST/WS")
```

`GatewayDeps` gains (additive optional fields so P1 tests compile untouched): `crypto?: EnvelopeCrypto; oauth?: OAuthFlow;` — plus the `systemHub?: SystemHub` field Task 10 already added (ONE canonical name; this task consumes that field, it does not add a second one). mcp/plugins routes return 503 `unavailable` when their dep is absent (keeps P1-only wiring bootable). `loadGatewayEnv` gains `masterKey: string` (required when `authMode === "firebase"`; test mode: required only if the mcp routes are exercised — tests pass a fixed 64-hex constant) and `mcpRedirectUri` (default `https://ovidsi.com/oauth/callback`).

- [ ] **Step 1: Write failing tests** (inject()-level, P1 gateway test conventions — `OVID_AUTH_MODE=test`, `openTestDb`, `testUid`):
  - mcpServers: `POST custom as free → 402 {error:{code:"pro_required",message:PRO_REQUIRED_MESSAGE}}` (exact message); `POST custom as pro (tier row flipped) → 201, stored row's secrets_sealed holds an EncryptedEnvelope whose JSON serialization contains NO env value, and the response has hasSecrets:true and NO env values`; `POST pasted .mcp.json parses via parseMcpConfig (stdio entry as pro)`; `POST curated credential {curatedId:"github", secrets:{GITHUB_TOKEN:"x"}} as FREE → 201` (curated is not gated); `duplicate name → 409 server_exists`; `GET list masks everything` (JSON.stringify contains no secret); `PATCH secrets replaces; DELETE removes; wrong owner → 404 everywhere`.
  - mcpCatalog: `GET returns 20 entries with tools and configured flags reflecting the caller's credential rows`.
  - mcpOauth: `start returns authorizeUrl containing state` (flow over fake fetchImpl + real db); `callback is reachable WITHOUT auth headers` (public scope pin) and `valid state → 200 HTML + systemHub.publishOut observed`; `unknown state → 400 oauth_failed HTML`; `disconnect removes the tokens row`.
  - plugins: `install as free → 402 pro_required`; `install as pro → 202 {installId,status:"queued"} + BullMQ job observed (fake queue) with priority 1`; `free-tier priority 2 for a pro-downgraded…` — pin: priority read from users.getTier at request time; `PATCH config seals values`; `DELETE enqueues uninstall`; `GET list masks config secrets`.
  - systemResponses: `POST {id,payload} → systemHub.respond called with the caller's uid`; `malformed body → 400`.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/gateway test` — FAIL.
- [ ] **Step 3: Implement** routes + wiring; register the callback in the PUBLIC scope next to health (explicit no-auth comment, mirroring P1's ws scope pattern); compose file gains `OVID_MASTER_KEY=${OVID_MASTER_KEY}` for gateway+worker and `caddy-snippet.conf` gains the `ovidsi.com/oauth/callback` reverse-proxy block (repo-only; DEPLOY.md notes activation is owner-gated) — THIS task canonically owns the caddy edit (Task 9 touches no deploy files and points at this block).
- [ ] **Step 4: Run to verify pass.** PASS; `docker compose -f cloud/deploy/docker-compose.yml config -q` exits 0 (dry validation only — never `up`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): gateway REST — mcp servers CRUD (sealed secrets), catalog, plugins + installs, oauth flow endpoints, system responses"`

### Task 16: Worker MCP runtime, P3 roster seam, agent catalog/install tools, router-level e2e

**Files:**
- Create: `cloud/apps/worker/src/mcpRuntime.ts`, `cloud/apps/worker/src/mcpTools.ts`, `cloud/apps/worker/src/sandboxSeam.ts` (`createSandboxSeam`/`createUnavailableSandbox` — the P2 adaptation file), `cloud/apps/e2e/src/mcpTierGate.test.ts`
- Modify: `cloud/apps/worker/src/main.ts` (wiring), `cloud/apps/e2e/src/index.ts` (export the harness helpers if needed)
- Test: `cloud/apps/worker/src/mcpRuntime.test.ts`, `src/mcpTools.test.ts`, `cloud/apps/e2e/src/mcpTierGate.test.ts`

**Interfaces:**
- Consumes: everything above; P1 `createAgentRunProcessor` deps (read-only — the roster seam is documented, not wired into runProcessor unless P3 has landed).
- Produces:

```ts
// mcpRuntime.ts
export interface McpRuntime { router: McpRouter; registry: ContributionRegistry; installer: ReturnType<typeof createPluginInstaller>; shutdown(): Promise<void>; }
export interface McpRuntimeDeps { db: Db; redisQ: Redis; masterKey: string; sandbox: { spawner: SandboxSpawner; files: SandboxFiles } | null; fetchImpl?: GuardedFetch; githubApiBase?: string; }
export function createMcpRuntime(deps: McpRuntimeDeps): McpRuntime;
// sandbox === null → createUnavailableSandbox(): every spawner/files call rejects with
// SandboxUnavailableError (code sandbox_unavailable) — curated fetch/github/rest + custom http/sse
// still work; stdio/filesystem/memory/plugin installs fail cleanly.
export class SandboxUnavailableError extends Error { readonly code = "sandbox_unavailable"; }

// sandboxSeam.ts
export function createSandboxSeam(): { spawner: SandboxSpawner; files: SandboxFiles } | null;
// Returns null until P2 lands. ADAPTATION POINT: when P2 has landed, this is the ONLY app file
// that constructs the P2-backed pair (SandboxSpawner/SandboxFiles are DEFINED in @ovid/sandbox —
// every package imports them unchanged) and, where shapes differ, maps SandboxFiles onto the
// @ovid/mcp WorkspaceFiles used for ctx.workspace. P2's "{workspacesRoot}/{uid}/workspace"
// layout is absorbed here too.
export function createUnavailableSandbox(): { spawner: SandboxSpawner; files: SandboxFiles };

// mcpTools.ts — the P3 roster seam (documented; P3 calls these from the run loop).
// CANONICAL TOOL SEAM (P2's landed AgentTool, additively extended): every MCP tool and catalog
// tool registers as execute(args, ctx) → ToolResult { content, isError?, artifacts? } — never a
// bespoke list/call pair. The wire-level McpToolCallResult {text, isError, content} maps to
// {content: text, isError} at this seam.
export interface ToolResult { content: string; isError?: boolean; artifacts?: unknown[]; } // P2's landed {content, isError} + optional artifacts; isError omitted === false
export interface McpToolContext { uid: string; sessionId: string; runId: string; }          // the subset of P2's ToolContext the MCP surface needs (RunContext rides alongside)
export interface McpAgentTool {
  readonly name: string;                          // published name mcp__<server>__<tool>
  readonly description: string;
  readonly parameters: Record<string, unknown>;    // JSON Schema object sent to the model
  execute(args: Record<string, unknown>, ctx: McpToolContext): Promise<ToolResult>; // validates args itself; user errors → isError result, never a throw
}
export interface McpToolProvider {
  tools(uid: string): Promise<McpAgentTool[]>;   // one McpAgentTool per McpToolListing, sorted by name (prompt-cache-stable, P3 contract); execute → router.resolveTool → router.callTool; unresolved → {content:"Unknown tool: <name>", isError:true}
  specs(uid: string): Promise<ModelToolSpec[]>;  // [OI] function specs derived from tools() (ModelToolSpec imported from P2's tools/types), same sort
}
export function createMcpToolProvider(router: McpRouter): McpToolProvider;
export const CATALOG_AGENT_TOOLS: readonly McpAgentTool[];
// catalog_list_mcp {scope?: "curated"|"custom"|"all"}, catalog_add_mcp {config: string},
// agent_install_mcp {server: string}, agent_install_plugin {source: string}
export interface CatalogToolDeps { router: McpRouter; db: Db; queues: { pluginInstalls: Queue<PluginInstallJob> }; }
export function createCatalogTools(deps: CatalogToolDeps): McpAgentTool[];
// Tool rules: a GATED refusal is a normal tool result {content: PRO_REQUIRED_MESSAGE, isError: true}
// (the agent can adapt and tell the user — never a thrown error into the run loop).
// catalog_add_mcp: parseMcpConfig → first entry → router.addServer (tier gate inside).
// agent_install_plugin: source-string parse ("owner/repo" → github, "npm:<pkg>" → npm, http(s) URL → zip,
//   otherwise paste) → tier gate (free → pro_required result) → plugins row + enqueue (priority by tier).
```

**Seam documentation (write as the header comment of `mcpTools.ts`):** P3's roster builder calls `mcpToolProvider.tools(uid)`/`specs(uid)` alongside native tools when assembling the sorted tool list, and routes any model tool-call whose name starts with `mcp__` (or resolves via `router.resolveTool`) to that tool's canonical `execute(args, ctx)` (ctx carries uid + session/run ids; the provider closes over `RunContext` from the active run, whose `sampler` is a closure over the run's `ModelTransport` + the run's API key — one completion call, NO retry layer; reword the sampler note when P9's `RunDeps.keys: KeyResolver` lands). `catalog` agent tools register as ordinary roster tools owned by P3 through the SAME canonical seam; until P3 lands, they are exercised here at router level.

- [ ] **Step 1: Write failing tests.**
  - `mcpRuntime.test.ts` (gated DB+Redis): `createMcpRuntime with sandbox null → curated fetch call works, filesystem call → isError sandbox_unavailable`; `router+bus+installer share one runtime instance`; `shutdown closes bus + router`.
  - `mcpTools.test.ts`: `tools() returns canonical McpAgentTool registrations sorted by name; specs() returns sorted [OI] function defs for curated servers`; `execute on mcp__fetch__fetch routes through the router → {content, isError:false}`; `execute with an unknown name → {content:"Unknown tool: x", isError:true}`; `catalog_add_mcp execute as free → {content: PRO_REQUIRED_MESSAGE, isError:true} (not a throw)`; `catalog_add_mcp as pro persists the server row`; `catalog_list_mcp {scope:"all"} → content names all 20 curated ids; {scope:"custom"} for a user with no custom servers → curated omitted, empty list` (the previously-untested fourth catalog tool, now pinned); `agent_install_plugin "acme/demo" → github source parsed, job enqueued with priority from tier`; `agent_install_plugin as free → pro_required result, nothing enqueued`; `agent_install_mcp {server:"github"} for a user with credentials → connected summary text includes the tool count`.
  - `mcpTierGate.test.ts` (e2e, gated DB+Redis, fakes for sandbox/model): **the brief's acceptance tests** — ① free user: catalog lists 20; fetch singleton call succeeds; custom http server POST → 402 pro_required; router-level addServer → ProRequiredError; ② pro user: custom http server (fixture server on 127.0.0.1) connects, tools list, call round-trips; stdio server (fake spawner echoing a canned tools/list + call) works; ③ **shared singleton across users:** users A (free) and B (pro) both call `mcp__fetch__fetch` → fixture fetch server saw 2 requests, catalog instance count 1; ④ downgrade B → free mid-flight → next custom callTool → pro_required, curated still works; ⑤ plugin install as pro with auto-approving fake bus → row active + registry entries + progress events observed on sys:{uid}:out in phase order.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/worker test && pnpm --filter @ovid/e2e test` — FAIL.
- [ ] **Step 3: Implement** runtime + tools + seam; wire `main.ts`: `createMcpRuntime` (sandbox seam → `createSandboxSeam()` returning null until P2 lands), `createPluginInstallsWorker` consuming `plugin-installs` with the Task-14 processor, graceful shutdown extended (runtime.shutdown + plugin worker close). Queue creation: `createQueues({url}, {withPluginInstalls:true})` in BOTH gateway main (producer) and worker main (consumer).
- [ ] **Step 4: Run to verify pass.** PASS. Full gate: `cd cloud && pnpm -r build && pnpm -r test` — ALL workspace suites green (P1 spine included).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): worker MCP runtime, P3 roster seam (McpToolProvider), agent catalog/install tools, tier-gate e2e"`

---

## Self-Review

**1. Spec coverage.**
- G9 tier gate: Tasks 11 (router middleware, per-dispatch re-check), 15 (REST 402 pro_required), 14 (install-job re-check), 16 (agent tools) — all four gate points, matching Review Focus 3.
- §6.1 McpRouter: 4 transports (T1–T3, T5 native), OAuth PKCE with `https://ovidsi.com/oauth/callback` relayed to the client (T9 flow + T10 system event + T15 callback route), elicitation/sampling over WS system channel (T4 + T10 + T11 wiring).
- §11 secrets: envelope encryption with `OVID_MASTER_KEY` (T8), tokens per user encrypted (T8/T9), SSRF-guarded egress for ALL agent HTTP out of the MCP surface (T3, consumed by T5/T6/T9/T12).
- Escrow: T8's `crypto.ts` is a thin shim aligned EXACTLY to P9's canonical `EnvelopeCrypto` (encrypt/decrypt + recordId AAD on both layers + structured `EncryptedEnvelope` + `EnvelopeAuthError`); when P9 lands `@ovid/escrow`, P5's call sites swap imports mechanically and the shim is deleted (seam list).
- §16 curated lineup: decided + documented in T6 (20 servers; exclusions reasoned).
- Plugin pipeline: sources/validation (T12), manifests/adapters/capabilities (T13), atomic transaction + grants + deps + progress (T14), REST/agent entry points (T15/T16), contribution registry canonical ids incl. hook registration-only seam for P3 (T13).
- Brief items verified present: `.mcp.json` parser (T7), pagination/backoff/trim/naming (T1/T2/T11), ping/roots/sampling/elicitation (T4), DCR (T9), two-pass archive validation + SRI + size caps (T12), `--ignore-scripts` default (T14), `${user_config.x}` (T14), shared-singleton proof test (T6 + T11 + T16 ③), queue priority coordination (T14/T15/T16 via P1's free=2/pro=1).
- Gap accepted (documented, not silently dropped): prompts/resources catalog tools (`catalog_mcp_list_prompts` etc. from `mcp_catalog_tools.dart`) are NOT in P5 — the curated lineup is tools-only; prompts/resources ride a later increment. The Dart catalog renderer's 6000-char bounding is preserved via `trimToolResult` everywhere results are rendered.

**2. Step scan.** Every step names one action with a checkable result; test steps carry exact names + the spec-pinned values (6000/50/4096/500→30 s/10/120 s/10 min/64 MiB/4 MiB/1 MiB/30 s clamp 5..300/−1/−32601/−32602/−32603/402/pro_required). Implementation steps give signatures + pinned values and leave bodies to the implementer, except where the algorithm IS the decision (P9-aligned envelope construction, two-pass validation, transaction order) — those are specified in prose, not code. No "TBD"/"handle edge cases" lines. Two spots deliberately defer to builder's choice with the choice pinned in the commit: zip library (fflate vs hand-rolled, T12) and GitHub download route (trees API vs codeload, T12).

**3. Type consistency.** `McpTransport/McpClient` (T1) ← T2/T3 transports (`HttpTransport extends McpTransport` carries `setProtocolVersion`); `NativeMcpHandler/McpCallContext` (T3) ← T5/T6 handlers; `WorkspaceFiles` (T5) ← T6/T11; `SandboxSpawner`/`SandboxFiles` ← DEFINED in `@ovid/sandbox` (P2's revision) and imported by T3 (stdio adapter maps onto the long-lived jailed-stdio primitive), T14 (`InstallerDeps.sandbox`) and T16; the worker `sandboxSeam.ts` maps `SandboxFiles` → `WorkspaceFiles` where shapes differ — the only drift surface; `UserSystemBus` (T10) ← T11, T14, T16, with T9 depending only on the structural `SystemEventPublisher` (the bus type is declared once); `EnvelopeCrypto` (T8, P9-aligned) ← T9/T11/T14/T15; `ImportedMcp` (T7) ← T11 (`AddServerInput`), T13 (`PluginMcpServerContribution`), T15; `PluginSourceInput` (T12) ← T14 job, T15/T16 install entry points; `ContributionRegistry` (T13) ← T14/T16; `RunContext` (T11) ← T16 provider; `PluginInstallJob` (T14) ← T15/T16 enqueue sites; tool registration (T16) goes through the canonical seam `execute(args, ctx) → ToolResult {content, isError?, artifacts?}` (P2's `AgentTool` additively extended). `users.getTier` (T8) is the single tier read used by T11/T14/T15/T16. Forward references inside T3's `McpCallContext` are declared in-package (acyclic: types only).

**4. Review Focus coverage.** #1 → T1 (pagination caps, trim, malformed frames) + T2 (backoff ladder, expected-vs-unexpected close); #2 → T12 (every traversal/symlink/size case, "nothing written" assertions); #3 → T11 (router-direct + downgrade), T14 (job-start re-check), T15 (REST 402), T16 (agent tools + e2e ④); #4 → T8 (sealed at rest), T9/T14 (hygiene pins on bus payloads), T15 (DTO masking + response-stringify grep); #5 → T3 (classifier incl. IPv6-embedded forms + production loopback block), T6 (host-extra egress via ctx.fetchImpl), T12 (zip URL guarded).

**5. Proportion.** The spec's P5 surface (§6.1 McpRouter + G9 + §11 + §14 row) is ~25 lines of spec plus ~9 000 lines of Dart behavioral reference; this plan is 16 tasks of interfaces + pinned tests, with porting decisions (which descriptor families, which capability set, which transaction order) rather than transcribed bodies. Code blocks are signatures and test names, not implementations.

**Known risks carried (for the controller):**
- P2/P3 interface drift: contained to `sandboxSeam.ts` + `mcpTools.ts` headers by design; if P2 lands after P5 starts, T16's `createUnavailableSandbox` path keeps the suite green.
- Descriptor port volume (16 services × 2–4 tools) is mechanical but large; T6 is the longest task — a reviewer may split descriptor data from engine if the diff is unwieldy (engine tests gate correctness either way).
- `mcp_oauth_flows` on Postgres (not Redis) is deliberate: one-use atomicity via conditional UPDATE, durable across gateway restarts mid-flow; TTL cleanup piggybacks on `consume` (expired rows ignored; a maintenance sweep is P10's).
- The system channel's Redis pub/sub on redis-q adds no eviction risk (pub/sub is not stored), but every attached uid holds one subscriber connection — the hub shares one per uid across sockets (pinned in T10).
