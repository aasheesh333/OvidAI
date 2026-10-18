# Task 11 — I4 fix report (cross-run borrowing of the sampling context)

**Repo:** `/root/OvidAI`, branch `feat/ovid-cloud`.
**Scope:** `cloud/packages/mcp/src/router.ts`, `cloud/packages/mcp/src/router.test.ts`, and the release wiring in `cloud/apps/worker/src/runProcessor.ts` / `cloud/apps/worker/src/main.ts`.
**Test DB:** dedicated empty `ovid_mcp_t11_i4` on `127.0.0.1:5433` (created for this task; the shared dev DB and live containers were not used).

---

## 1. The defect (verified before changing code)

`AsyncLocalStorage` is exact for in-process call chains (curated native handlers and
Streamable HTTP response bodies), but it does **not** propagate across a transport read
loop. A stdio process's `stdout` data handler and a legacy-SSE `readLoop` are async
resources created when the connection was spawned/opened; their callbacks always carry
the **spawn-time** store. The router used that store to pick the sampler, so:

- a stdio process lazily spawned by run A served every later run's
  `sampling/createMessage`, answering with run A's model/API key;
- `connectForRun` (which may carry no sampler) spawned the process, and every later
  call's sampling request used that no-sampler context instead of the caller's;
- the old test passed only because `FakeStdioProcess` delivered the request
  synchronously from `writeLine`, i.e. inside the caller's ALS context.

I reproduced this before touching the implementation with an async-delivery fake whose
stdout is pumped by a `setInterval` created at spawn (the same async-resource semantics
as `child.stdout`). Pre-fix output:

```
× McpRouter > a lazily spawned stdio process belongs to its run (async stdout delivery) 42ms
  → run B borrowed run A's connection: ["sampled-A","sampled-A"]
```

Pre-fix router suite: `4 failed | 21 passed (25)` (the other three failures are the new
per-run keying/release assertions; the existing tests stayed green).

Also confirmed in the source: `connectForRun`/`releaseRun` had no production caller
(`mcpRuntime.ts` only constructs the router; `mcpTools.ts` calls `resolveTool`/`callTool`),
so lazy spawn followed by cross-run reuse was the real production sequence, and stdio
processes lived until `shutdown()` (`sweepIdle` skipped stdio).

---

## 2. Design

### 2.1 Per-run connection keys

- `stdio` and legacy `sse` custom connections are keyed by **`(uid, runId)`**:
  `<row id>#run:<runId>` (`entryKeyFor`). Row ids are UUIDs, so uid scoping is implicit.
- Streamable HTTP stays per-uid/shared: its requests are request-scoped.
- `LiveEntry` gained `baseKey` (run-independent identity) so update/remove/status can
  address every incarnation of one server.
- `findLiveEntry(ref, runCtx)`:
  - with a run: the exact per-run incarnation;
  - without a run (tool enumeration): the most recently used **connected** incarnation,
    preserving the pinned single-spawn TUI flow without letting a *call* attach to
    another run's process.
- `ensureLive` never reassigns `ownerRunId` to a different run. A call from the **same**
  run may refresh `ownerRun` (sampler) — the key already proves it is the same run.

### 2.2 Attribution by connection ownership

`clientHooks.runCtx()` now resolves:

- per-run stdio/SSE entry → `entry.ownerRun` (captured at spawn, refreshed only by the
  same run). This is the only correct source: the read loop's ALS store is spawn-time.
- shared HTTP/native entry → `runStorage.getStore()` (exact inside the call's async
  chain), falling back to `entry.activeRun` for out-of-band pushes — the documented
  last-writer-wins fallback.

The false comment claiming ALS is "exact for per-run stdio" was removed and replaced
with the actual semantics (both in `LiveEntry` and on `runStorage`).

### 2.3 Release per run

- **Worker wiring:** `FullRunDeps` gained an additive optional
  `mcpReleaseRun(uid, {sessionId, runId})`. `main.ts` wires
  `mcpRuntime.router.releaseRun`. The full processor calls it in its terminal
  `finally` (covers completion, run-level failures, prepass `finish`, cancellation),
  before `bumpActivity`, best-effort (`catch(() => {})`). This is the release half of
  the preferred wiring; `connectForRun` is deliberately not called eagerly — lazy spawn
  already runs under the correct run context, and eager connect would spawn every
  configured stdio server for runs that never use MCP.
- **Router backstop:** `sweepIdle` no longer skips stdio; all custom connections are
  reaped after `idleTtl`. `releaseRun` disposes both stdio and legacy-SSE entries whose
  `ownerRunId` matches, and clears `activeRun` on shared entries.
- `enforceCustomCap` never evicts another run's live per-run connection (that would kill
  an in-use process and reintroduce cross-run interference).

### 2.4 Tier / namespace / single-spawn regressions

- I1: `teardownCustom` still scans every custom entry; `needsAuth` is now keyed by
  `baseKey` (auth is a server property, not a run property). All gate re-reads unchanged.
- I2: untouched.
- I3: the existing single-spawn test passes unchanged. No-run enumeration of
  stdio/SSE uses a transient connection (`transientCustomDefs`), so it no longer leaves
  a persistent cold-alias entry behind; with a run, "single spawn" is correctly read as
  **per (uid, run)**.

---

## 3. Files changed

- `/root/OvidAI/cloud/packages/mcp/src/router.ts` — per-run keys, ownership attribution,
  release/sweep, multi-incarnation update/remove, shared egress helper.
- `/root/OvidAI/cloud/packages/mcp/src/router.test.ts` — async-delivery fake, decisive
  tests, ownership test, per-run release test; corrected the old false-positive
  concurrent-sampler test to per-run semantics.
- `/root/OvidAI/cloud/apps/worker/src/runProcessor.ts` — `mcpReleaseRun` dep + terminal
  `finally` call.
- `/root/OvidAI/cloud/apps/worker/src/main.ts` — wires `mcpRuntime.router.releaseRun`.

---

## 4. Tests

New/changed in `router.test.ts`:

1. **`a lazily spawned stdio process belongs to its run (async stdout delivery)`** — the
   decisive test. `FakeSpawner.asyncDelivery` pumps inbound lines from a `setInterval`
   created inside `spawn()`, so the server request is delivered from the spawn-time
   async resource. Run A lazily spawns; run B calls the same tool. B must get its own
   process and `sampled-B`; A keeps `sampled-A`.
   Pre-fix failure:
   ```
   × a lazily spawned stdio process belongs to its run (async stdout delivery)
     → run B borrowed run A's connection: ["sampled-A","sampled-A"]
   ```
2. **`per-run stdio attributes requests to the connection owner, not spawn-time ALS`** —
   `connectForRun` spawns without a sampler, then the same run calls with a sampler.
   Async delivery means the read loop can only see the spawn-time (no-sampler) store;
   attribution must use the connection owner. Passes with the fix.
3. **`two concurrent lazy runs with distinct samplers never cross`** — two runs call the
   same tool concurrently; each spawns its own process and each answer matches its run.
4. **`per-run stdio ownership: releaseRun kills only its own process; a new run spawns
   fresh`** — two runs get two processes; releasing run 1 kills only its process; run 3
   spawns a third; releases are idempotent.
5. Corrected the old `concurrent sessions keep their own sampler` test: it no longer
   asserts both answers arrive on one shared process (the false positive). It now
   asserts one process per run and one answer per process.

### Mutation probes

- **Full pre-fix revert:** decisive test fails with
  `run B borrowed run A's connection: ["sampled-A","sampled-A"]` (captured above).
- **Ownership branch disabled on the fixed keying** (temporary, restored):
  ```
  × per-run stdio attributes requests to the connection owner, not spawn-time ALS
    → expected [ 'ERROR -32603: sampling failed' ] to deeply equal [ 'sampled-owner' ]
  ```
  i.e. the spawn-time ALS store cannot see the same run's sampler. This proves the
  ownership change itself is pinned, not just the keying.

---

## 5. Gates

Dedicated DB `ovid_mcp_t11_i4`:

```
$ TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/ovid_mcp_t11_i4 \
    pnpm --filter @ovid/mcp test
 Test Files  27 passed (27)
      Tests  447 passed | 5 skipped (452)
   router.test.ts: 26 passed
```

```
$ pnpm --filter @ovid/worker test
 Test Files  19 passed | 6 skipped (25)
      Tests  154 passed | 92 skipped (246)
```
The skipped worker suites are gated on `TEST_REDIS_URL` (and `TEST_DATABASE_URL`), and
Redis is not running in this environment; the non-gated worker suite is green.

```
$ cd cloud/packages/mcp && tsc -p tsconfig.check.json --noEmit   → exit 0
$ cd cloud/apps/worker  && tsc -p tsconfig.check.json --noEmit   → exit 0
```

---

## 6. Still open / notes

- **Legacy SSE** is fixed by the same mechanism (per-run key + owner attribution +
  release) but has no dedicated router-level concurrent-sampling test; the existing
  `transports/sse.test.ts` covers SSE framing. Adding a two-run SSE fixture is the one
  remaining test-coverage gap.
- **`connectForRun` remains uncalled in production.** This lane wired `releaseRun`, which
  closes the lifecycle gap; lazy spawn under `callTool` carries the correct per-run
  context. If P3 later wants pre-warming, it can call `connectForRun` around the run —
  the router now supports it per-run.
- **Cap semantics:** `enforceCustomCap` will not evict another run's live per-run
  connection, so concurrent runs can exceed `maxCustomConnections` transiently (bounded
  by worker concurrency). This is deliberate: evicting an in-use process would break a
  concurrent run.
- **Idle TTL backstop:** a per-run stdio/SSE entry whose consumer never calls
  `releaseRun` is reaped after `idleTtl` (default 10 min); it no longer lives until
  process shutdown.
- `releaseRun` is idempotent and only clears/disposes entries matching the run id; a
  concurrent release test is implicitly covered by the per-run ownership test (releases
  of RUN1/RUN2/RUN3 each affect only their own process).
