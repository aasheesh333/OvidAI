# Ovid Si at 100M users — scale plan

**Status:** design document, not implemented.
**Written:** 2026-10-21.
**Scope:** what breaks between today's single VPS and 100M registered users,
the target topology, the migration order, and the cost model.
**Companion:** `docs/architecture/FEATURE_GAPS.md` (what the product currently
does versus the v2 spec).

> Every number below is either labelled **measured** (taken from code or a
> checked-in load report) or **planning assumption** (a stated model). Do not
> quote a planning number as a measurement.

---

## 0. Read this first: what is actually running today

The landed deployment is a **single-region, single-box** stack. It is a good
v1, but almost every component has a hard ceiling that is below 1M users, let
alone 100M.

| Layer | Today | Where | Consequence at scale |
|---|---|---|---|
| Edge | Cloudflare (owner-configured) → Caddy on one VPS | `cloud/deploy/HARDENING.md`, `cloud/deploy/DEPLOY.md` | Caddy and the VPS are a single point of failure; no regional ingress |
| Gateway | One Fastify container, `mem_limit: 1g`, `cpus: 1.0` | `cloud/deploy/docker-compose.yml` | One process owns every socket and opens a dedicated Redis pub/sub connection per session subscription (§4.1); there is no horizontal fanout |
| Queue | One Redis (`maxmemory 1400mb`, `noeviction`) + BullMQ | `cloud/deploy/docker-compose.yml`, `cloud/packages/queue/src/queues.ts` | Job memory and throughput are bounded by one Redis; no regional isolation |
| Worker | One host systemd process, `MemoryMax=4096M`, `CPUQuota=600%` | `cloud/deploy/systemd/ovid-worker.service` | One process owns the sandbox manager and the browser engine |
| Sandboxes | 24 concurrent bwrap envs per box (`OVID_MAX_ACTIVE_SANDBOXES=24`), 512 MiB cap each, 8 vCPU / 22 GB host | `cloud/deploy/worker.env.example`, `cloud/packages/sandbox/src/config.ts` | 100M users ÷ 24 = 4.2M boxes if every run holds a sandbox |
| Sandbox identity | One numeric uid per **user**, pool `200000–209999` (10,000 uids) | `cloud/packages/sandbox/src/config.ts`, `cloud/packages/db/src/repos.ts` (`allocateSandboxUid`) | **Hard blocker:** user 10,001 cannot get a sandbox. 100M users is impossible with this allocator |
| Agent workspace | `{workspacesRoot}/{uid}/workspace`, shared by every session of that user | `cloud/packages/sandbox/src/manager.ts` (`workspaceDir`), `cloud/apps/worker/src/main.ts` | Violates “100% session isolation”: session B can read session A's files through the agent's file tools |
| Postgres | One `ovid_cloud` database, Drizzle migrations, no RLS, no partitions | `cloud/packages/db/src/schema.ts`, `cloud/packages/db/drizzle/` | One primary cannot hold 100M users' messages/runs/events; no defense-in-depth row isolation |
| Redis event log | One stream + one channel **per session**, a **dedicated pub/sub connection per WebSocket subscription** | `cloud/packages/events/src/eventLog.ts` (`subscribe`), `cloud/apps/gateway/src/ws.ts` | 1.5M sessions = 1.5M Redis connections. Redis default `maxclients` is 10k; this is the first wall |
| R2 | One bucket, `users/{uid}/...` keys, full-workspace tar on hibernate | `cloud/packages/storage/src/keys.ts`, `cloud/packages/storage/src/hibernate.ts` | Full tar rewrites at 3-min idle do not survive 144M runs/day |
| Plans | Free token caps enforced in Python mint; TS plan catalog still seeds Starter/Pro/Max | `server/mint/ovid_plans.py`, `cloud/apps/mint/src/planMath.ts` | Plan data and allowances drift between UI, billing and mint |
| Observability | `watch` alerts + load harness | `cloud/apps/watch`, `cloud/apps/load` | No per-cell saturation metrics, no tenant-level cost attribution |

### Measured baseline (read honestly)

The strongest checked-in evidence is the load report
`cloud/apps/load/reports/load-20261018-1500s.md`:

- 1,500 concurrent WebSocket users on one 8 vCPU / 22 GB box.
- 1,500 runs completed, 0 failed, with a **mock LLM** (not a real provider).
- Event delivery p95 7 ms, p99 10 ms (loopback).
- Gateway max RSS 650 MB; worker 177 MB.
- 20 sandbox-backed tool steps observed; the configured cap is 24.

That is a **harness capacity** result, not a production capacity claim. Real
runs hold sandboxes for their whole duration today, stream from remote
providers, and require egress. The report's own `admission.queuedAtCap` is
labelled a proxy because the worker does not expose exact queue depth.

The 100-user report (`load-20261018-100u-v2.md`) also failed two gates
(`scheduleRuns.missed`, `replay.samples`). Do not treat either report as a
release certificate.

---

## 1. Planning load

These are the assumptions the rest of the document uses. They are deliberately
round numbers; replace them with real telemetry once it exists.

| Metric | Planning value | Derivation |
|---|---:|---|
| Registered users | 100,000,000 | brief |
| Monthly active | 35,000,000 | 35% of registered |
| Daily active | 12,000,000 | 12% of registered / 34% of MAU |
| Peak concurrent sockets | 1,500,000 | 12.5% of DAU, 1.0 device each |
| Runs per DAU per day | 12 | chat + schedules + subagents |
| Runs per day | 144,000,000 | 12M × 12 |
| Average runs/second | 1,667 | 144M / 86,400 |
| Peak runs/second | 5,000 | 3× average |
| Average run wall time | 75 s | agent loop with tools |
| Peak concurrent runs | 375,000 | 5,000/s × 75 s |
| Share of run time in a tool step | 25% | planning; tool calls are bursty |
| **Peak sandbox leases (target)** | **~100,000** | 375k × 25%, rounded up |
| Peak sandbox leases if held for the whole run (today's model) | 375,000 | no lease release between steps |
| Subagents per active run | 0.2 | planning; 50 cap is a ceiling, not an average |
| Concurrent subagent model streams | ~75,000 | 375k × 0.2; they share the root sandbox |
| Live browser viewers at peak | ~5,000 | 0.33% of sockets; live view is a paid, short-lived surface |
| Average stored bytes per registered user | 250 MB | planning; 3 GB is a cap, not an average |
| Total stored bytes | ~25 PB | 100M × 250 MB |
| Messages per run | 4 | user + assistant + tool/system rows |
| Messages per day | 576,000,000 | 144M × 4 |
| Events per run | 20 | deltas, tool events, terminal event |
| Events per day | 2,880,000,000 | 144M × 20 |

### What the load actually implies

- **Runs are cheap to keep in memory, expensive to give a sandbox.** A run
  spends most of its life waiting on a model stream. The expensive resource is
  the local tool step, which is why the worker already separates
  `OVID_AGENT_RUN_CONCURRENCY` from `OVID_MAX_CONCURRENT_TOOL_STEPS`
  (`cloud/apps/worker/src/main.ts`). The current config sets both to roughly
  the same number (24 runs / 200 steps); at scale they must be separated by an
  order of magnitude.
- **The sandbox is the unit of cost, not the socket.** 375k run-level sandboxes
  at 512 MiB is ~183 TiB of RAM cap; 100k step-level leases is ~49 TiB of cap.
  Even at 25% average utilisation, the difference is hundreds of thousands of
  dollars per month.
- **Postgres cannot be the event firehose.** 2.9B events/day × ~300 B is
  ~870 GB/day before indexes. Events belong in a columnar/object store; PG
  keeps the durable message rows and a short replay window.
- **R2 is the sleeper cost.** 25 PB at $0.015/GB-month is ~$375k/month before
  operations. A full-workspace tar on every hibernate is not affordable; the
  archive format must become incremental.

---

## 2. Target topology

```
                           ┌──────────────────────────────┐
                           │ Cloudflare edge              │
                           │ WAF · bot · rate limits      │
                           │ TLS · Argo/anycast · CDN     │
                           └──────────────┬───────────────┘
                                          │ regional steering
        ┌─────────────────────────────────┼─────────────────────────────────┐
        │                                 │                                 │
 ┌──────▼──────┐                   ┌──────▼──────┐                   ┌──────▼──────┐
 │ Region APAC │                   │ Region IN   │                   │ Region EU/US│
 │  (cell 0..N)│                   │  (cell 0..N)│                   │  (cell 0..N)│
 └──────┬──────┘                   └──────┬──────┘                   └──────┬──────┘
        │                                 │                                 │
 ┌──────▼─────────────────────────────────▼─────────────────────────────────▼──────┐
 │ CELL (failure domain, ~20–25k sockets)                                          │
 │                                                                                 │
 │  gateway × 4–8        queue shard set        worker pool        sandbox fleet    │
 │  (stateless REST,     (BullMQ shards,        (agent loop,       (bwrap slots,    │
 │   WS + fanout)         one Redis cluster)     tools, browser)    per-node uids)  │
 │                                                                                 │
 │  Redis: events + queue + tickets        Postgres shard (uid hash)  R2 bucket     │
 └─────────────────────────────────────────────────────────────────────────────────┘

 Global control plane (multi-region):
   auth directory · plan/billing · scheduler source of truth · admin/kill switch
   object-store inventory · cost/usage ledger · schema migrations
```

### Design rules

1. **A cell is the blast radius.** A cell owns its gateway processes, queue
   shards, worker pool, sandbox fleet, Redis cluster and Postgres shard. One
   cell failing loses at most ~25k sockets / ~1.5k sandboxes.
2. **Users are assigned to a cell by `hash(uid)`.** The same user always lands
   on the same cell for their queue and Postgres shard. WebSocket connections
   may land on any gateway in the cell; the fanout layer routes by session.
3. **No cross-cell joins.** Cross-user surfaces (shares, collaboration,
   reports) live in a small global database with opaque IDs; they never join
   to a shard's message tables.
4. **The control plane is small.** Auth, plans, billing, kill switches and
   migrations are global and low-QPS. The data plane carries the load.
5. **Every service is horizontally replaceable.** No process holds durable
   state that is not also in Postgres, Redis (with a defined recovery story),
   or R2.

---

## 3. Edge

**Today:** Cloudflare is in front of the live Caddy. Caddy terminates TLS and
proxies `/cloud/*` to one gateway port. The gateway publishes a ticket for the
WebSocket; the client connects with `?ticket=...` (`cloud/apps/gateway/src/tickets.ts`).

**What must change:**

| Concern | Change | Why |
|---|---|---|
| Origin failure | Replace the single Caddy VPS with regional L4/L7 load balancers (Cloudflare Tunnel or cloud NLB) in front of ≥2 gateway cells per region | One Caddy is one reboot away from a full outage |
| WebSocket flood | Require the single-use ticket **before** the upgrade; cap concurrent sockets per IP and per uid at the edge; reject upgrades without a ticket | A ticketless upgrade flood costs a gateway process |
| Auth | Verify Firebase ID tokens at the gateway, not the edge; keep App Check at the gateway (`OVID_APPCHECK_MODE=required`) | Edge auth would duplicate revocation logic |
| Rate limits | Cloudflare rules for coarse IP/ASN limits; gateway token buckets for per-uid/per-route limits | Rate limiting is **not enforced** on the gateway path today. A Python token-bucket helper (`server/security/rate_limits.py`) exists and is tested, but no account/gateway route calls it |
| DDoS/bot | Managed WAF, bot fight, Turnstile on sign-up if abuse appears | Free tier + 50M token cap is an abuse target |
| Data residency | Route Indian accounts to the India region when that becomes a contract requirement | INR pricing and local expectations |
| TLS pinning | Pin the API host's SPKI in the app only when two pins (current + backup) are maintained; keep it off until then (`lib/core/cert_pinning.dart`) | Cloudflare rotates leaf certs; leaf pinning breaks the app |
| Egress | R2 through Cloudflare; no public bucket; signed URLs only | Prevents object-store bypass and egress bills |
| Observability | Edge logs → central pipeline; trace IDs propagated to gateway | Debugging a single user's failed run across cells |

**WebSocket framing budget.** 1.5M sockets at one heartbeat per 30 s is 50k
frames/s just for liveness. A 1 KB event per active session every 5 s adds
~300 MB/s at peak. The edge must not buffer per-connection; the gateway must
drop frames before it drops events (see §4).

---

## 4. Gateway

The gateway should stay a thin Fastify service; the work is in **removing its
per-connection Redis cost** and **bounding every queue**.

### 4.1 The first wall: one Redis connection per subscription

`createRedisEventLog().subscribe()` calls `redis.duplicate()` for **every
session subscription** (`cloud/packages/events/src/eventLog.ts`), and
`cloud/apps/gateway/src/ws.ts` tears down one such connection per session on
close. The browser channel opens two more per attached viewer
(`cloud/apps/gateway/src/browserChannel.ts`). At 1.5M sockets this is ~1.5M
Redis connections; Redis's default `maxclients` is 10,000. Even a tuned Redis
will not survive this.

**Target:** a gateway-local **fanout** service with a fixed subscriber pool.

```
Redis Cluster (sharded pub/sub, hash tag {s:<sessionId>})
        │  16–32 shared subscriber connections per gateway process
        ▼
  Fanout (in-process)
        │  local map sessionId → Set<WebSocket>
        ▼
  gateway sockets
```

- One subscriber connection can `SSUBSCRIBE` to thousands of channels. A
  gateway with 25k sessions needs 25k channel subscriptions spread over
  16–32 connections, not 25k connections.
- Use Redis 7 sharded pub/sub (`SSUBSCRIBE`) with `{s:<sessionId>}` hash tags so
  a channel lives on one shard. Classic `SUBSCRIBE` broadcasts cluster-wide.
- Keep the replay ordering contract: subscribe first, then `XRANGE`, then
  flush buffered live events, dedupe by stream id (`ws.ts` already does this).
- Do the same for the browser channel: one shared subscriber for frames per
  gateway, not two connections per viewer.
- Above ~10M concurrent sockets, replace Redis pub/sub with NATS JetStream
  (subject per session, consumer per gateway). Keep the fanout interface
  (`subscribe`/`unsubscribe`) so the rest of `ws.ts` does not change.

### 4.2 Cell sizing

| Item | Per gateway process | Cell (4–8 gateways) |
|---|---:|---:|
| Concurrent sockets | 20,000–25,000 | 100,000–200,000 |
| RSS budget | 2 GB | 8–16 GB |
| Outbound queue per socket | 64 frames hard cap | same |
| Heartbeat | 30 s ping, 2 misses → close | same |
| Graceful drain | 120 s, close 1001 | drain one process at a time |

At 1.5M sockets: ~60–75 gateway processes, 8–12 cells, 3 regions.

### 4.3 Backpressure and admission

- On a full outbound buffer, **drop frames, never events**. The client
  reconnects and replays from its last seq; a dropped delta is recoverable, a
  dropped terminal event is not.
- Admit a send only if the user's queue depth and run concurrency are under the
  plan limit. Otherwise return `503` with `Retry-After`, not a silent hang.
- Keep the current `agent-runs` `jobId: runId` idempotency. A retry of
  `POST /messages` must return the same run, not a second one.
- The gateway already checks mint on every send (`provisionKey`,
  `cloud/apps/gateway/src/routes/messages.ts`). Keep that as the single
  authoritative admission/quota point; cache only the model catalog, never the
  verdict.

### 4.4 State ownership

| State | Owner | Recovery |
|---|---|---|
| WS tickets | Redis (single-use, short TTL) | Reconnect; client fetches a new ticket |
| Session events | Redis stream + PG mirror | `readSince`; fall back to REST snapshot if the stream aged out |
| Run queue | Redis/BullMQ (or NATS) | PG run row + reconciler re-enqueue |
| Approvals | Redis pub/sub + PG ledger | Timeout policy; unattended auto-deny |
| Browser frames | Redis pub/sub (binary) | Newest-frame-wins; no replay |
| PTY | Redis bridge | Attach by pty id; survives gateway reconnect |

Nothing above requires sticky sessions. Keep it that way; sticky routing makes
cell drains and rolling deploys much harder.

---

## 5. Queue

**Today:** five BullMQ queues (`agent-runs`, `hibernate`, `hydrate`,
`schedules`, `plugin-installs`) on one Redis, `attempts: 1`,
`removeOnComplete: { age: 3600, count: 5000 }`, stalled check 30 s
(`cloud/packages/queue/src/queues.ts`). Worker concurrency 24
(`OVID_AGENT_RUN_CONCURRENCY=24`). Priority 1 for paid, 2 for free
(`messages.ts`).

**At 5,000 sends/s and 375k active runs, one queue is the wrong shape.**

### Target queue topology

| Queue | Shards | Key | Notes |
|---|---:|---|---|
| `agent-runs` | 64 logical, 8 per cell | `hash(uid) % 64` | Each shard is its own BullMQ queue name (`agent-runs:07`); workers subscribe to their cell's shards |
| `schedules` | 64 | `hash(scheduleId) % 64` | Delayed job + DB claim ledger (already the source of truth) |
| `hibernate` / `hydrate` | 16 each | `hash(sessionId) % 16` | Storage jobs; low priority, bounded concurrency |
| `plugin-installs` | 8 | `hash(userId) % 8` | Low volume, `attempts: 1` stays |
| `browser-jobs` | 16 | `hash(sessionId) % 16` | New; keeps browser work off agent workers |

### Fairness and limits

- **Per user:** at most 1 active root run on Free, 2 on paid. The 50-subagent
  cap is per session, not a licence to run 50 model streams on one account.
- **Per session:** exactly 1 active run; queued messages wait. The worker
  already enforces a session turn queue (`OVID_RUN_QUEUE_WAIT_MS`).
- **Weighted fair queuing across users** so one user with 50 subagents cannot
  starve a cell. BullMQ priority alone is not fair; add a per-uid active
  counter in Redis and re-enqueue behind it.
- **Backpressure:** if a shard's waiting count exceeds a threshold, the gateway
  returns 503/Retry-After. Autoscale workers on `waiting` and `oldest job age`,
  not CPU.
- **DLQ:** model retries stay inside the processor (5 attempts, 3/9/27/60 s
  backoff per the existing ruling). A crashed worker is covered by stalled-job
  detection + the stale-run sweeper. Do not add a second retry layer.

### When to leave BullMQ

BullMQ on Redis is fine at 5k jobs/s if sharded. It becomes the wrong tool when:

- sustained >50k jobs/s, or
- >1M active jobs, or
- you need cross-region replication of the queue itself.

At that point move `agent-runs` to NATS JetStream or Kafka/SQS and keep BullMQ
for low-volume control jobs. The job payload contract (`AgentRunJob`) is already
Zod-validated and additive; the migration is transport-level.

### Scheduler at 100M

The current delayed-job mirror works because the DB row is authoritative
(`scheduleRepairs` + claim ledger). At 100M schedules:

- Bucket delayed jobs by minute (`schedules:YYYYMMDDHHmm`) instead of keeping
  one delayed set with millions of entries.
- A scheduler service claims due occurrences with `FOR UPDATE SKIP LOCKED` and
  enqueues runs; the queue is only a wake-up.
- Cap catch-up per user (the existing missed-run policy already does this) so a
  region restart cannot enqueue a storm.

---

## 6. Sandbox pool

This is the largest architectural change and the largest cost line.

### 6.1 Two hard blockers in the current design

**A. The uid pool is 10,000.** `OVID_SANDBOX_UID_BASE=200000`,
`OVID_SANDBOX_UID_MAX=209999`, and `allocateSandboxUid` consumes a Postgres
sequence and stores `users.sandbox_uid` permanently
(`cloud/packages/sandbox/src/config.ts`, `cloud/packages/db/src/repos.ts`).
User 10,001 cannot be sandboxed. Any 100M plan must replace this before
anything else.

Options, in preference order:

1. **Rootless user namespaces.** Launch bwrap with `--unshare-user` and map the
   sandbox to a node-local uid. The kernel namespace, not a global Postgres
   sequence, provides isolation. This removes the 10k ceiling entirely and is
   the cleanest long-term answer. It requires re-validating the launcher,
   cgroup ownership and nftables rules against the kernel/host.
2. **Node-local uid slots.** Each worker node owns 10k uids and reuses them
   across different users; the workspace path includes a per-user hash so a
   stale uid does not collide. The DB stores `(node_id, uid)` rather than a
   global `sandbox_uid`. This is a smaller change but makes node affinity part
   of the data model.
3. Keep per-user uids and raise the block to 100M. **Do not do this** unless
   the host kernel and every tool tolerate a 100M-entry uid space; it does not
   fit the current `uidBase + 9999` validator or XFS project quota design.

**B. The agent workspace is per user, not per session.**
`SandboxManager.attach(userId)` builds `{uid}/workspace`; only the browser and
P7 hydration use `{uid}/sessions/{sessionId}`
(`cloud/packages/sandbox/src/manager.ts`, `cloud/apps/worker/src/main.ts`).
The spec's “100% isolation” is therefore a database guarantee, not a
filesystem guarantee. A session can open another session's files through the
agent's file tools.

Fix: make the jail's `/workspace` bind mount
`{uid}/sessions/{sessionId}` (or a per-session overlay) for every run, and
keep `{uid}/workspace` only as a legacy/global area if a product surface needs
it. This must land before any “isolation” marketing claim.

### 6.2 Lease model: release the sandbox between tool steps

Today a run attaches a sandbox at the start and holds it until the run ends
(`runProcessor.ts` around `deps.sandbox!.attach`). At 375k concurrent runs that
is 375k sandboxes. Most of those runs are waiting on a token stream.

Target:

- The run holds a **run context** (prompt, transcript, model stream).
- A **sandbox lease** is acquired only around a tool step (exec, file read/write,
  git, browser handoff, MCP call) and released afterwards.
- The session workspace is a persistent volume; the sandbox is an ephemeral
  jail over it. Re-attach is cheap (bwrap + cgroup + setuid).
- A per-session lock prevents two steps from mutating the same workspace at
  once (`workspaceMutationLock` already exists for storage).

Result: peak leases ≈ peak tool-step concurrency (~100k), not peak runs
(~375k). That is a 3.75× reduction in RAM and a much smaller fleet.

If a run truly needs a long-lived environment (e.g. a dev server for Live
Preview), give it a **pinned lease** with its own quota and TTL; do not let
every run hold one.

### 6.3 Pool sizing

Per node: 64 vCPU, 256 GB RAM, 4 TB NVMe, 10 GbE. Two possible slot counts:

| Dimension | Limit | Slots |
|---|---|---:|
| RAM at 512 MiB cap | 256 GB / 0.5 GB | 512 (minus OS) |
| CPU at 1 vCPU per active step | 64 vCPU / 1 | 64 |
| Disk at 2 GB workspace | 4 TB / 2 GB | 2,000 |
| PIDs at 64 per env | host pids limit | ~1,000 |

Tool steps are mostly I/O-bound (file, git, shell), so 96–192 slots per node is
a realistic operating point; CPU is the bursty constraint, and the worker's
step limiter is the backstop. Plan **96 slots** for capacity and **192** as an
optimisation target after measuring real CPU per step.

At 100k leases: **~520 nodes at 192 slots, ~1,040 at 96 slots.** Add 30% for
region headroom and drain: **~700–1,350 nodes.**

### 6.4 Warm pool and hibernation

- Maintain a 5–10% warm slot buffer per cell so acquire p95 stays under 2 s.
- Keep the session workspace on local NVMe while warm. Current warm cache is
  `OVID_MAX_WARM_GB=8` per box; at 100M that is a rounding error. The warm
  tier must be a per-cell LRU with a real capacity target (e.g. 20% of the
  cell's active workspaces), and cold data in R2.
- Hibernate after the current 3-minute idle is too aggressive at scale; it
  creates a full tar write per idle session. Make it a tiered policy:
  - 0–15 min: warm, no upload
  - 15 min–24 h: warm, incremental snapshot if dirty
  - 1–30 days: cold in R2, hydratable
  - >30 days (Free) / >90 days (paid): archive or delete per plan
- Replace the full `.tar.zst` with an incremental, content-addressed archive
  (see §9). The current `r2Keys.workspaceArchive` full-tar design is the
  single biggest R2 write amplifier.

### 6.5 Browser fleet

Keep browsers off the agent sandbox fleet.

- Current `BrowserPool` runs one Chromium process with `maxLiveBrowsers: 4`
  and a tier-1 fallback (`cloud/packages/browser/src/pool.ts`,
  `cloud/packages/browser/src/config.ts`).
- At 5k live viewers, plan ~1,250 browser workers if each serves 4 live
  contexts; more realistically 2,000–3,000 to leave headroom for tier-1.
- Stream via the existing WS binary frames at 3–5 fps. Budget ~80–150 KB per
  frame; 5k viewers × 4 fps × 100 KB = 2 GB/s, or ~5 PB/month. This is a
  first-class cost line. If it grows, move live view to WebRTC or a regional
  media relay; do not put 5 PB/month through the gateway.
- Keep the 45 s idle→headless rule (`OVID_WATCH_IDLE_HEADLESS_MS=45000`). It is
  also a cost control.
- Browser uploads/downloads go through the Artifact Vault
  (`browserToolAdapter.ts`, `engine.ts`), not the sandbox filesystem.

### 6.6 Isolation hardening

The current sandbox has bwrap, a numeric uid, cgroups v2, an nftables egress
filter and a read-only rootfs. It does **not** have a seccomp profile (grep
`seccomp` under `cloud/packages/sandbox/src` is empty). Add:

- a deny-by-default seccomp profile for every jailed process;
- `no_new_privs` on all leaves (verify current launcher);
- per-session mount root, not per-user;
- per-node nftables rules keyed on the sandbox uid range;
- an explicit egress allowlist per tool (GitHub, package registries, the
  provider origin) rather than a shared netns default.

---

## 7. Postgres

**Today:** one database, Drizzle schema, no RLS, no partitions
(`cloud/packages/db/src/schema.ts`). This is correct for the first million
users and wrong after that.

### 7.1 Shard, then partition

| Data | Strategy | Why |
|---|---|---|
| `users`, auth mapping | **Directory DB** (small, replicated) | Needs global lookup by uid/email/phone; 100M rows is fine in one DB |
| `sessions`, `messages`, `runs`, `attachments`, `private_memory_files`, `run_usage` | **Shard by `hash(uid)`**, 16 shards initially, 64 max | Every query is owner-scoped; no cross-user joins |
| `session_event_mirror` | **ClickHouse/S3**, not PG | 2.9B events/day; PG is the wrong store |
| `shares`, `reports`, `collab_*` | **Global DB** | Cross-user by design; opaque IDs only |
| `plans`, `billing_purchases`, `devices`, `notifications` | Global or shard by uid | Low volume; billing needs a single ledger |

The shard key is deterministic: `shard = hash(uid) % 16`. No directory lookup
on the hot path. Keep a small `user_shard` table only for migrations/ops.

### 7.2 Partition the append-only tables

Use declarative `RANGE` partitioning by time for:

- `messages` — monthly partitions; PK `(id, created_at)`, index
  `(session_id, id)`.
- `runs` — monthly; PK `(id, created_at)`, partial index on
  `(status, last_active_at) WHERE status='running'` for the sweeper.
- `run_usage` — monthly; index `(user_id, created_at)`.
- `attachments` — monthly; index `(session_id, created_at)`.
- `notifications` — monthly; TTL by partition detach.
- `schedule_runs` — monthly.
- `billing_purchases` — monthly or yearly.

**Important Postgres constraint:** a partitioned table's primary/unique key
must include the partition key. Today `messages.id` is the PK and
`(session_id, client_msg_id)` is a partial unique index. Partitioning by
`created_at` means the global client-id idempotency guarantee cannot be a
simple unique index. Options:

1. Keep a small unpartitioned `message_keys(session_id, client_msg_id, message_id)`
   table for idempotency, written in the same transaction.
2. Accept per-partition uniqueness and rely on the client's single-flight plus
   the gateway's `resolveClientMsgId` logic.
3. Partition by `hash(session_id)` instead of time for `messages`, and detach
   whole sessions when they age out. This preserves the unique key but makes
   time-range queries hit every partition.

Recommendation: (1) for correctness, with the tiny key table cleaned by the
same retention job.

### 7.3 RLS and connection pooling

- Add `ROW LEVEL SECURITY` on every owner-scoped table, policy
  `USING (user_id = current_setting('ovid.uid')::text)`. The gateway/worker sets
  `SET LOCAL ovid.uid = $1` at the start of each transaction. This is
  defense-in-depth on top of the repo-layer ownership checks.
- Use **PgBouncer in transaction mode** per shard. 16 shards × 100 backend
  connections is manageable; 64 shards × 100 needs a pooler layer.
- Set `statement_timeout`, `idle_in_transaction_session_timeout`, and
  `lock_timeout` per role. The current code has advisory locks for memory and
  project files; long transactions will pile up at scale.

### 7.4 Retention and archive

| Data | Hot | Cold |
|---|---|---|
| Messages | 90 days | Parquet in R2, queryable via Athena/ClickHouse |
| Runs / usage | 90 days | Aggregate daily per user; keep 13 months |
| Events | 7 days in Redis + ClickHouse | 30 days in object storage |
| Attachments/artifacts | life of account | R2 lifecycle to IA after 30 days |
| Deleted accounts | 24 h grace | hard delete + R2 prefix delete |

The current account deletion path already has a prefix deleter
(`createR2PrefixDeleterFromEnv`); it must run per shard and be idempotent.

### 7.5 Migration order

1. Add RLS and the `ovid.uid` setting to the current single DB (low risk,
   high value).
2. Add monthly partitions to `messages`, `runs`, `run_usage` in place.
3. Stand up 4 shards; dual-write new rows by `hash(uid)`; backfill in uid
   ranges; verify counts and checksums per shard.
4. Cut reads per shard behind a feature flag; keep the old DB read-only for
   rollback.
5. Expand to 16, then 64, by splitting shards (logical replication + catch-up).
6. Move `session_event_mirror` reads to ClickHouse; stop writing PG for every
   delta. Keep terminal events in PG for the run ledger.

Drizzle cannot express partitions or RLS. Use raw SQL migrations for those and
keep the Drizzle schema for types and ordinary tables.

---

## 8. Redis

Redis is used for four different jobs with different failure semantics. Split
them.

| Class | Today | Target | Policy |
|---|---|---|---|
| Queue | `redis-q`, `noeviction`, 1.4 GB | One cluster per cell, 8–16 shards | `noeviction`; AOF everysec; replica per shard |
| Session events | Same `redis-q` | Same cluster, hash-tagged streams | `MAXLEN 10k`, TTL 48 h; replica |
| Cache/activity | `redis-c`, `allkeys-lru`, 256 MB | Per-cell cache cluster | LRU, no AOF; loss is fine |
| Tickets/approvals/system bus | `redis-q` | Same as queue (small keys) | Short TTL; replicated |

### Sizing

- Active sessions at peak: 1.5M. Average live tail: 500 events × 300 B = 150 KB
  per session → ~225 GB. With allocator overhead and replication, plan
  **450 GB–1 TB**.
- 12 shards × 64 GB RAM = 768 GB, plus one replica per shard = 1.5 TB. That is
  a realistic cell/cluster size; use 2–4 clusters, not one global Redis.
- Queue: 375k active jobs × ~2 KB = 750 MB; retained completed jobs bounded at
  5k/queue. Fine.
- Tickets: 1.5M × ~100 B = 150 MB.

### Connection budget

| Consumer | Connections |
|---|---:|
| Gateway fanout (16–32 per process × 60) | ~1,000–2,000 |
| Worker queue consumers (8 per shard × 64) | ~512 |
| Worker event publishers | ~100 |
| Browser frame fanout | ~200 |
| Admin/observability | ~50 |

This is why the shared subscriber pool in §4.1 is non-negotiable: the current
design would be 1.5M+.

### Keyspace

Use hash tags so multi-key operations stay on one shard:

```
{s:<sessionId>}:events
{s:<sessionId>}:live
{u:<uid>}:queue:active
{u:<uid>}:runs
ticket:<token>
```

Streams and channels for the same session must share a tag. Queue keys are
already prefixed by BullMQ (`bull:agent-runs:...`); add a shard suffix in the
queue name, not in the key prefix.

### Failure behaviour

- A full queue Redis must fail **loudly** (`noeviction` → write error), never
  silently drop jobs. Keep the current rule.
- A cache Redis may evict; never point queue/event traffic at it.
- On failover, the queue consumer retries; idempotent `jobId: runId` prevents
  duplicates. The event log is replayable from PG beyond the stream TTL.
- Do not use Redis as the only source of truth for anything that costs money
  (runs, usage, approvals). PG remains authoritative.

---

## 9. R2 / object storage

### 9.1 The current layout is good; the write pattern is not

`r2Keys` already separates workspaces, browser state and artifacts by user and
session (`cloud/packages/storage/src/keys.ts`). Keep that shape. The problem is
**how often and how much** is written:

- `hibernate` uploads a full `users/{uid}/workspaces/{sid}.tar.zst` after
  3 minutes idle (`cloud/packages/storage/src/hibernate.ts`).
- At 144M runs/day, even a 50% hibernate rate is tens of millions of tar
  writes/day. A 100 MB workspace turns into petabytes/day of write
  amplification.

**Target format:** incremental, content-addressed workspace snapshots.

```
users/{uid}/workspaces/{sid}/manifest.json      # file list + blob hashes + mode
users/{uid}/workspaces/{sid}/blobs/{sha256}     # only changed blobs
users/{uid}/workspaces/{sid}/snapshots/{gen}.json
```

- On snapshot, hash files, upload only blobs not already present.
- On hydrate, fetch the manifest and the missing blobs.
- Keep a per-session generation; a stale snapshot is ignored (the existing
  `generation` claim logic already provides this).
- Pack small files into 4–8 MB blobs to avoid millions of tiny objects.
- A full tar remains a fallback for export/import, not the hot path.

This also makes account deletion a prefix delete plus an inventory check, and
makes cross-session dedupe possible when two sessions share a repo checkout.

### 9.2 Budget

| Average stored per registered user | Total | R2 storage/month @ $0.015/GB |
|---:|---:|---:|
| 50 MB | 5 PB | ~$75k |
| 250 MB | 25 PB | ~$375k |
| 1 GB | 100 PB | ~$1.5M |
| 3 GB (plan cap fully used) | 300 PB | ~$4.5M |

The 3 GB Free cap is a liability if users actually fill it. Enforce the plan
quota **before** upload. The P3 foundation exists
(`cloud/packages/storage/src/quota.ts`, `cloud/apps/gateway/src/planGate.ts`),
but no upload route reserves against it yet; the only enforced limit today is
the 500 MB/2 GB XFS workspace quota (see gaps doc).

### 9.3 Lifecycle

- Abort incomplete multipart uploads after 7 days (already in provisioning).
- Transition cold workspaces/artifacts to R2 Infrequent Access after 30 days.
- Expire deleted-account prefixes immediately after the 24 h grace.
- Keep versioning off for workspace blobs; keep object lock for legal holds
  only if required.
- Use `Cache-Control: immutable` for content-addressed artifacts (already done
  in `contentAddressedArtifact`).
- Presigned GET TTL ≤ 1 h; CDN signed URL TTL ≤ 15 min when enabled
  (`OVID_CDN_*`).

### 9.4 CDN and egress

R2 egress through Cloudflare is free; gateway/browser WebSocket egress is not.
Keep artifacts on the CDN path and live browser frames on the media path.
Do not proxy large artifacts through the gateway by default; the current
range-reader exists for inline preview, not for bulk download.

---

## 10. Cost model

All prices are planning assumptions in USD, 2026. They are deliberately round
and must be replaced with real invoices. The point is the **shape** of the
cost, not the last dollar.

### 10.1 Unit assumptions

| Unit | Assumption |
|---|---|
| Sandbox node | 64 vCPU / 256 GB / 4 TB NVMe dedicated, ~$650/month, 96 slots |
| Gateway node | 16 vCPU / 32 GB, ~$280/month, 25k sockets |
| Redis | 12 shards × 64 GB + replicas, ~$2,000/month per cluster; 2 clusters |
| Postgres | ~$2,000 per shard-month (8 vCPU / 32 GB primary + replica + backup) |
| Event store | ClickHouse 3–6 nodes + object storage, ~$15k/month |
| R2 | $0.015/GB-month storage; operations small relative to storage |
| Edge/WAF/WS egress | $50k–$150k/month at this volume |
| Observability/control plane | ~$40k/month |
| Blended auto model | $0.15–$0.60 per 1M tokens |
| Tokens per run | 15k–50k (input + output + cache) |

### 10.2 Monthly infrastructure (excluding model tokens)

| Line | 16 shards / 96-slot nodes | 64 shards / 96-slot nodes |
|---|---:|---:|
| Sandbox fleet (100k leases) | $677k | $677k |
| Gateway (60 nodes) | $17k | $17k |
| Redis (2 clusters) | $25k | $25k |
| Postgres | $32k | $128k |
| Event store | $15k | $15k |
| R2 (25 PB) | $375k | $375k |
| Edge / WS egress | $75k | $75k |
| Observability / control | $40k | $40k |
| **Infra total** | **~$1.26M** | **~$1.35M** |

At 96 slots per sandbox node the fleet alone is $677k. At 192 slots (the
measured optimisation target) it is $339k, which lowers the 16-shard total to
~$0.92M. This is **~$0.08–$0.11 per DAU per month** at the planning load
(and ~$0.009–$0.014 per registered user per month). The per-DAU cost is what
matters for unit economics; model tokens below are ~25× larger.

If runs keep a sandbox for their whole duration (375k leases), the sandbox
line grows 3.75× to ~$1.3M–$2.5M/month. That is the single strongest reason to
move to step-level leases.

### 10.3 Model tokens dominate

Monthly tokens = 144M runs/day × 30 days × tokens/run.

| Tokens/run | Tokens/month | @ $0.15/M | @ $0.30/M | @ $0.60/M |
|---:|---:|---:|---:|---:|
| 15k | 64.8T | $9.7M | $19.4M | $38.9M |
| 25k | 108T | $16.2M | $32.4M | $64.8M |
| 50k | 216T | $32.4M | $64.8M | $129.6M |

**Model tokens dominate.** At the central case (25k tokens/run at $0.30/M)
they are ~96% of total cost; across the sensitivity table they range from
~89% to ~99%. Infrastructure optimisation is real but secondary; model
routing, prompt caching, context compaction and per-user budgets are the
levers that decide whether 100M users is a business.

### 10.4 Unit economics guardrails

| Item | Value at $0.30/M |
|---|---:|
| Cost per 1M tokens | $0.30 |
| Free user at 50M tokens/day | **$15/day = $450/month** |
| Free user at 1M tokens/day | $0.30/day = $9/month |
| Paid user at 9M tokens/month | $2.70/month |
| Paid Plus at $18/month, 9M tokens | ~85% gross margin before infra |
| Paid Pro at $99/month, 90M tokens | ~73% gross margin before infra |

The spec's **50M tokens/day** is only survivable if it is an abuse ceiling that
almost nobody reaches. If even 1% of 12M DAU hits it:

- 120,000 users × $15/day = **$1.8M/day = $54M/month**.

Recommendations:

1. **Keep the USD budget as the real control.** The current
   `free_daily_usd = 0.15` (`server/mint/ovid_plans.py`) is what actually caps
   spend; the token ceiling is a second gate. Do not remove it until there is
   an equivalent USD guard.
2. **Add a global daily spend cap and a per-plan concurrency cap.** M1's
   per-user $0.50 alert is a monitor, not a cap.
3. **Cap subagents by plan** (e.g. 5 Free / 10 Go / 25 Plus / 50 Pro). Today
   every tier can run 50, and subagents are token multipliers.
4. **Route `auto` to the cheapest capable model** and cache aggressively;
   every $0.10/M reduction is ~$10.8M/month at 108T tokens.
5. **Charge for extra storage** or enforce the plan cap; 3 GB Free × 100M is a
   300 PB liability.

### 10.5 Cost attribution

Add a `usage_ledger` row per run with: user, plan, run, model, input/output/
cache tokens, sandbox seconds, storage bytes, browser seconds. The existing
`run_usage` table is a start (`cloud/packages/db/src/schema.ts`), but it lacks
sandbox/browser/storage units. Without this ledger you cannot answer “which
feature loses money” at 100M.

---

## 11. Migration phases

Do not attempt 100M in one step. Each phase has an exit criterion; if it is
not met, the next phase will fail in a predictable way.

### Phase 0 — make the current box honest (now → 50k sockets)

- Fix the uid pool and per-session workspace (§6.1).
- Replace per-subscription Redis connections with a fanout pool (§4.1).
- Wire the existing rate-limit helper and plan gates: import
  `server/security/rate_limits.py`, `planGate.ts` and
  `cloud/packages/storage/src/quota.ts` into the routes that currently bypass them; add RLS.
- Add the usage ledger and per-cell saturation metrics.
- Enforce plan storage and upload quotas; enforce manual-model gating
  server-side.
- Fix the v2 wiring gaps in `FEATURE_GAPS.md` before calling the app “done”.

**Exit:** 50k concurrent sockets on 2 gateway processes; 1k sandboxes; 100
runs/s; no Redis `maxclients` errors; RLS on every owner table.

### Phase 1 — single region, multi-AZ (→ 1M users / 250k sockets)

- 3 AZs, 2 cells, Postgres primary + synchronous replica, Redis cluster with
  replicas, PgBouncer.
- Step-level sandbox leases; sandbox fleet 10k slots.
- BullMQ sharded 8 ways; fair queuing per uid.
- Incremental workspace snapshots.
- Plan/billing source of truth consolidated (one plan catalog, not UI + TS +
  Python seeds).

**Exit:** 250k sockets; 10k sandboxes; 1k runs/s; p95 send→202 < 200 ms;
sandbox acquire p95 < 2 s.

### Phase 2 — multi-region (→ 10M users / 500k sockets)

- 3 regions; 6–8 cells; geo steering; per-region R2 buckets.
- 16 Postgres shards; ClickHouse for events.
- 64 queue shards; scheduler service.
- Browser fleet separated; live-view budget enforced.
- Per-region cost dashboards.

**Exit:** 500k sockets; 50k sandboxes; 3k runs/s; a single-region loss keeps
the other regions serving.

### Phase 3 — 100M users (1.5M sockets / 100k leases / 5k sends/s)

- 64 shards (or 16 very large shards with partition pruning, if measurements
  justify it).
- Dedicated sandbox and browser fleets with 30% headroom per region.
- Data residency for India if required.
- Global admission control and spend caps.
- Chaos drills: kill a cell, kill a Redis shard, lose an AZ, exhaust R2.

**Exit:** the SLOs below hold during a cell drain and a regional failover.

---

## 12. SLOs and autoscaling signals

| SLO | Target |
|---|---|
| Gateway availability | 99.95% |
| Run acceptance (send → 202) p95 | < 200 ms |
| First token p95 (provider-dependent) | < 2 s |
| WS event delivery p95 | < 250 ms |
| Reconnect replay p95 | < 1 s |
| Sandbox acquire p95 | < 2 s |
| Run success rate (excluding user cancel) | > 99% |
| Crash-free sessions (client) | ≥ 99.5% |

Autoscale on the **queue**, not CPU:

- `agent-runs` waiting count and oldest-job age per shard.
- Sandbox lease wait p95.
- Gateway socket count and outbound drop rate.
- Redis memory / evicted keys (should be zero for queue/events).
- R2 upload error rate and p95 latency.

Scale up in 90 s; scale down in 10 min. Keep a 20–30% buffer per cell so a
cell drain never causes a global queue spike.

---

## 13. Risks and hard blockers

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | 10k uid pool | Cannot sandbox user 10,001 | Rootless user namespaces or node-local uids (§6.1) |
| 2 | Per-user workspace | Cross-session file reads; fails acceptance #4 | Bind `/workspace` to the session dir (§6.1) |
| 3 | Redis connection-per-subscription | First wall at ~10k sockets | Shared fanout pool + sharded pub/sub (§4.1) |
| 4 | Full-workspace tar on hibernate | R2 write amplification; cost blowout | Incremental content-addressed snapshots (§9) |
| 5 | Run-level sandbox leases | 3.75× sandbox fleet | Step-level leases (§6.2) |
| 6 | No enforced rate limits / no RLS | Abuse and cross-tenant risk | Wire the existing Python limiter + edge/gateway limits; add RLS (§3, §7.3) |
| 7 | Free token economics | 1% at cap = $54M/month | USD cap, concurrency caps, cheap routing (§10.4) |
| 8 | Plan catalog drift | Users charged for features the server does not grant | Single plan source of truth; server gates (§10.4, gaps doc) |
| 9 | Single region / single Caddy | Full outage on one failure | Multi-AZ then multi-region (§11) |
| 10 | Event firehose in PG | 870 GB/day before indexes | ClickHouse + short PG replay window (§7.1) |
| 11 | Browser frame egress | Potentially PB/month | Cap live view, paid-only, consider WebRTC (§6.5) |
| 12 | No cost attribution | Cannot find the losing feature | `usage_ledger` per run (§10.5) |
| 13 | Drizzle cannot express partitions/RLS | Migration friction | Raw SQL migrations; Drizzle for types (§7.5) |
| 14 | Live preview missing | Product gap, not scale | Add the gateway proxy before launch (gaps doc) |

---

## 14. Decision log

| ID | Decision | Consequence |
|---|---|---|
| S1 | Cells of ~25k sockets, 8–12 cells per 1.5M | Bounded blast radius; more operational units |
| S2 | Step-level sandbox leases, not run-level | 3.75× smaller fleet; requires engine refactor around `SandboxPort` |
| S3 | Rootless user namespaces over a global uid sequence | Removes the 10k ceiling; requires launcher/cgroup/nft revalidation |
| S4 | Postgres sharded by `hash(uid)`, 16 → 64 | No cross-user joins; global tables stay small |
| S5 | Events in ClickHouse, messages in PG | PG stays writable at 576M messages/day |
| S6 | Incremental R2 snapshots, not full tars | Avoids PB/day write amplification; more code in storage |
| S7 | Keep a USD budget as the real free-tier cap | The 50M token ceiling alone is not economically survivable |
| S8 | Shared gateway fanout; NATS beyond 10M sockets | Removes the connection wall; one more abstraction |
| S9 | BullMQ sharded first, NATS/Kafka only past 50k jobs/s | Avoids an early rewrite; keeps the job contract |
| S10 | Usage ledger per run | Makes cost a first-class product metric |

---

## 15. How to verify this document against the code

```bash
# The current sandbox ceiling and uid block
grep -n "OVID_MAX_ACTIVE_SANDBOXES\|OVID_SANDBOX_UID_BASE\|OVID_SANDBOX_UID_MAX" cloud/deploy/worker.env.example
grep -n "maxActiveSandboxes\|uidBase\|uidMax" cloud/packages/sandbox/src/config.ts

# The per-user workspace (isolation gap)
grep -n "workspaceDir\|workspaceDirFor" cloud/packages/sandbox/src/manager.ts
grep -n "sandboxHandleFor\|manager.attach" cloud/apps/worker/src/main.ts

# The per-subscription Redis connection (fanout wall)
grep -n "duplicate()\|subscribe(" cloud/packages/events/src/eventLog.ts
grep -n "dedicated redis pub/sub connection" cloud/apps/gateway/src/ws.ts

# No RLS, no partitions
grep -rn "ROW LEVEL SECURITY\|CREATE POLICY\|PARTITION BY" cloud/packages/db || true

# The full-tar hibernate path
grep -n "workspaceArchive\|tar.zst\|hibernate" cloud/packages/storage/src/hibernate.ts cloud/packages/storage/src/keys.ts

# Plan/cap source of truth
grep -n "free_daily_usd\|seed_plans\|FREE_DAILY_TOKENS" server/mint/ovid_plans.py
grep -n "seedPlans\|free_daily_usd" cloud/apps/mint/src/planMath.ts
```
