# Ovid Cloud P2 — SandboxManager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-user isolated command-execution environments for the cloud agent: an agent run executes shell/file commands inside a bubblewrap jail with cgroup caps and a 3-layer command policy, user terminals work over the gateway WS `pty` channel, and package installs hit per-user hardlink caches — proven by an isolation acceptance suite on the real host.

**Architecture:** Research doc `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/p2-bubblewrap-feasibility.md` is **BINDING** and corrects the spec: Option A — the worker runs as a **host systemd service** (root) inside a delegated `ovid-sandboxes.slice` and spawns bwrap per command/PTY/job (~5 ms/jail, ~2 MB overhead); stores are **per-user** on the `/workspaces` filesystem (shared RO store is unworkable: `fs.protected_hardlinks` EPERM + pnpm/uv write requirements); bwrap runs **as the user's sandbox uid** (`setpriv` after cgroup self-attach) so host files are owned by uid 200000+, gated on the week-1 bare-metal AppArmor verification with two documented fallbacks. New package `cloud/packages/sandbox` holds config, policy, invocation, cgroups, quota, manager, exec, pty, jobs, egress; the worker gains a tool seam (run_shell + file tools, P3 extends the roster); the gateway WS multiplexer gains a `pty` channel kind bridged to the worker's PTY supervisor over redis-q pub/sub.

**Tech Stack:** Node 22, TypeScript strict, Vitest, bubblewrap 0.9 (`0.9.0-1ubuntu0.3`), cgroups v2 (unified, host kernel 6.8), nftables, node-pty ^1.1.0, ioredis ^5.11.1, XFS project quotas (loopback image volume), Docker (rootfs build only), zstd, systemd.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` (§7 command guardrail, §9 capacity — **revised below for the 8 vCPU/22 GB box**, §11 isolation, §14 P2 row). Binding research: `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/p2-bubblewrap-feasibility.md`. Ledger: `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/progress.md` (ENVIRONMENT SHIFT 2026-10-16).

## Global Constraints

- Monorepo conventions (P1 Task 1): TS `strict`, ES2022, NodeNext; vitest ^2.1.9; pnpm 12 workspace with `allowBuilds` (esbuild, msgpackr-extract, @firebase/util — this plan adds `"node-pty": true`); ioredis ^5.11.1; `workspace:*` deps; per-package `outDir: dist` / `rootDir: src`; packages `@ovid/<name>`, `type: "module"`.
- Test env: `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390` (dev-services.sh containers; tests use disposable services, never live ones).
- Host-gated kernel tests: run only when `OVID_SANDBOX_HOST_TESTS=1` **and** `process.getuid?.() === 0` **and** the mechanism probe passes (bwrap present, jail spawns) — otherwise `describe.skipIf`. The week-1 AppArmor verification (Task 1) is the exception: it **must run for real on this host** (owner-gated step). Host-gated tests use throwaway names (`ovid-spike-*` netns/containers, `ovid-probe-*` cgroups, tmp workspaces), clean up every environment/cgroup/workspace/netns they create (try/finally + afterAll), and never touch `ovid-gateway-*` containers, `/opt/ovid-gateway`, the live Caddyfile, or production cgroup paths.
- Production boundary: never mutate `ovid-gateway-*` containers or `/opt/ovid-gateway`. New units/paths (`/opt/ovid-rootfs`, `/workspaces`, `/etc/systemd/system/ovid-*`, `/opt/ovid-cloud/nft`, host nft table) are **owner-gated activation steps** structured like P1 Task 11: artifacts + dry validation autonomous, activation the final owner-gated step with a stop-condition.
- Wire: JSON camelCase, UUIDv7 ids (`newId()` from `@ovid/db`), error envelope `{ "error": { "code", "message" } }`; new error codes this plan: `sandbox_busy`, `sandbox_unavailable`, `pty_gone`, `forbidden` (reused), `bad_message` (reused).
- Capacity (revised per ledger ENVIRONMENT SHIFT — supersedes spec §9's 12c/30GB numbers): box is **8 vCPU / 22 GB**. Parent slice `ovid-sandboxes.slice`: `CPUQuota=600%` (~6 cores; 2 left for gateway/DB/system), `MemoryMax=10G`, `MemorySwapMax=0`. Memory envelope: host+Docker 2G + Postgres 3G + Redis-Q 1.5G + LiteLLM 1G + Caddy/misc 0.5G + gateway+worker 2G + browser-pool reserve (P6) 2G = 12G non-sandbox ⇒ 10G slice. `MAX_ACTIVE_SANDBOXES=24` (env `OVID_MAX_ACTIVE_SANDBOXES`, default 24): 24 × 512 MiB = 12 GiB worst case binds at the 10G slice first (per-env OOM, host protected) — 24 assumes the spec §9 profile (10–20 executing at any instant), same shape as the spec's "32 at 16 GB".
- Per-env cgroup caps (spec §7.3, exact): `cpu.max` = `"100000 100000"` (1 core), `memory.max` = `536870912` (512 MiB), `memory.swap.max` = `0`, `pids.max` = `64`.
- Sandbox uids: dedicated per user from a **configurable 10 000-uid block** — `OVID_SANDBOX_UID_BASE` (default 200000) with `uidMax` default `base+9999` → production range **200000–209999** (spec §11 default); **P10 staging sets base 220000 → 220000–229999**, and config validation + the nft rules must accept it (rules key on the **configured** range, never a hardcoded one). The DB allocation sequence stays pinned to the production block — staging never runs it (P10 hash-allocates per its plan).
- Workspace quotas: `/workspaces/users/{uid}/workspace` default **500 MB** (Pro 2048 MB), store/cache subtree `/workspaces/users/{uid}/.cache` cap **2048 MB**; `MAX_WARM_GB` default 8 (ledger Q8 ruling; owner retunes at activation).
- Exact refusal copy (spec §7 — verbatim, one source of truth `REFUSAL_MESSAGE` in `@ovid/sandbox`, shims carry the identical string, parity pinned by test): *"Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead."*
- Rootfs: docker-export of `ubuntu:24.04` with pinned toolchain (node v22.20.0 official tarball — **not apt**, pnpm 10.34.0 via corepack, uv 0.13.1, python3/git/curl from apt), artifact `ubuntu-noble-min-<YYYYMMDD>-r<N>.tar.zst` + `manifest.json` + `SHA256SUMS`, installed at `/opt/ovid-rootfs/<name>` with atomic `current` symlink, keep 2 revisions (research §6).
- Egress: single host nftables `inet` table keyed on `meta skuid <configured sandbox range>` (prod 200000–209999, staging 220000–229999 per P10 — never a hardcoded range), dropping `10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16`, `::1/128, fe80::/10, fc00::/7`, and the VPS's own public IP (research §2.4/§8.5; `127/8`+`::1` are additions over spec §11 — the host loopback carries litellm :4000, the DB/redis proxies, so sandboxes must never reach it; sandboxes get a generated `resolv.conf` with public DNS, never `127.0.0.53`). **Plus an optional browser-engine section (gap G2, P6 Task 16d)**: when `OVID_BROWSER_EGRESS_UID` is set (value coordinated with this plan — must NOT overlap the sandbox range), the same table gains, for that uid/range ONLY, allow rules for the worker's internal endpoints (loopback always) placed BEFORE its drop rules over the same blocked sets — the browser engine runs as a worker-side uid, not a sandbox uid.
- Commit after every task; run `cd cloud && pnpm -r build && pnpm -r test` before committing. Host-gated suites additionally: `OVID_SANDBOX_HOST_TESTS=1 TEST_DATABASE_URL=… TEST_REDIS_URL=… sudo -E pnpm --filter @ovid/sandbox test`.

## Review Focus

1. **Blocked-command evasion** — `bash -c "gradle build"`, heredoc'd `make`, `CC=gcc make`, `$(gradle …)`, `eval`, `xargs make`, and the base64-decode-pipe forms layer 1 cannot see. Expected: layer-1 grammar parse blocks every direct/quoted/wrapped form with the exact refusal copy as tool result + `system_note`; anything that still reaches exec dies on the PATH shims with the identical copy; nothing on the allowlist (node/python/pnpm/pip/uv/git/apt-get/`flutter analyze|test`/`cargo test`) is blocked. Pinned by Task 4 corpora, Task 7 (no-spawn short-circuit), Task 15 (in-jail indirect corpus incl. documented layer-1 boundary).
2. **Workspace escape via path traversal or symlink** — `read_file("../../etc/passwd")`, `write_file("/etc/cron.d/x")`, a symlink inside the workspace pointing at `/opt`, jail writes to `/`, `/etc`, `/usr`. Expected: file tools confine to `{workspacesRoot}/{uid}/workspace` via realpath-of-nearest-ancestor; jail root is RO except `/workspace`, `/root`, `/tmp`; host paths are invisible inside. Pinned by Task 12 confinement corpus, Task 7 host-gated RO/invisibility tests, Task 15 acceptance corpus.
3. **Terminal reconnect race** — client disconnects and re-attaches with a stale `lastOffset` while output is streaming; or the 256 KB ring has already rolled. Expected: subscribe-before-snapshot ordering, offset-based dedupe (no lost or duplicated bytes), `truncated: true` on ring overflow so the client fully repaints; PTY survives the WS drop (reconnect, don't restart). Pinned by Task 13 bridge tests + Task 14 pty e2e.
4. **Resource hog / fork bomb in a sandbox** — memory balloon, `:(){ :|:& };:`, runaway process tree, detached grandchildren. Expected: `memory.max` OOM-kills only that env's cgroup (exit 137, `memory.events oom_kill ≥ 1`), `pids.max=64` stops forks, `cpu.max` throttles to 1 core (measured — research open item), `cgroup.kill` reaps the whole tree, slice caps protect gateway/DB, host unaffected. Pinned by Task 6 enforcement tests, Task 9 (job tree kill), Task 15.
5. **Sandbox egress to internal/metadata endpoints** — `curl 169.254.169.254`, `10.x`, own public IP, and `127.0.0.1:4000` (LiteLLM!) from a sandbox uid. Expected: uid-keyed nft drop with counters proving only sandbox-uid packets matched; root/worker traffic unaffected; the optional browser-uid section (G2) allows loopback/internal endpoints and drops the rest — allow-before-drop order verified. Pinned by Task 11 netns proof (self-contained: loopback listener + uid discrimination), re-run by Task 15 via the shared net-test kit.

---

### Task 1: Week-1 host mechanism verification (AppArmor/userns decision — runs for real on this host)

**Files:**
- Create: `cloud/deploy/sandbox/sandbox-probe.sh`
- Create: `cloud/deploy/sandbox/MECHANISM.md` (decision record, filled by the host run)
- Create: `cloud/deploy/sandbox/ovid-sandbox.apparmor` (fallback-b profile artifact, installed only if branch b is taken)

**Interfaces:**
- Consumes: nothing (host tools: `sysctl`, `setpriv`, `dmesg`, `aa-status`, `python3`, docker absent from the probe).
- Produces: `MECHANISM.md` with the line `DECISION: setuid` or `DECISION: rootmap` — Task 2's `OVID_SANDBOX_LAUNCH` default and Task 7's launcher implement the decision; the probe's jail-arg shape is the ancestor of Task 5's builder. `hostTestsAvailable()` (Task 2) re-runs the probe's core check.

- [ ] **Step 1: Write `sandbox-probe.sh`** (bash, `set -euo pipefail`, every mutation prefixed with a `MUTATION:` log line; sections exit non-zero with captured evidence on failure). Sections, in order: (S0) capture `uname -r`, the three sysctls (`kernel.unprivileged_userns_clone`, `user.max_user_namespaces`, `kernel.apparmor_restrict_unprivileged_userns`), `aa-status | head -5`, cgroup fs type; (S1) `[ -x /usr/bin/bwrap ] || apt-get install -y bubblewrap` (record installed version — candidate on this box: `0.9.0-1ubuntu0.3`); (S2) scratch dir `mktemp -d /tmp/ovid-probe.XXXX`; run spec-shaped jail (`--ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --dir /etc --proc /proc --dev /dev --unshare-user --uid 0 --gid 0 --unshare-pid --unshare-uts --unshare-ipc --die-with-parent --new-session -- /bin/sh -c 'id; cat /proc/self/uid_map; touch $PWD/probe'` with the scratch dir RW-bound) **as root** and **as uid 200000** via `setpriv --reuid=200000 --regid=200000 --clear-groups`; capture stdout/stderr/rc and `dmesg | grep apparmor | tail -20` after each failure; (S3) if S2-uid200000 failed: install `cloud/deploy/sandbox/ovid-sandbox.apparmor` (branch b — profile for `/usr/bin/bwrap` granting `userns_create`, modeled on the on-box `/etc/apparmor.d/flatpak` and `podman` precedents; the artifact file is written in this task) via `apparmor_parser -r`, re-run S2-uid200000; (S4) if still failed: branch-c smoke — root-run `unshare --user` PoC writing `0 200000 1` to a child's `uid_map` then exec bwrap **without** `--unshare-user` (prove outer ownership: `touch` lands uid 200000); (S5) ctty sanity: `python3 -c 'import pty,sys; pty.spawn([...bwrap --new-session ... /bin/sh -c "tty; stty size"])'` → expect a `/dev/pts/N` line and `24 80`-shape output (node-pty-specific confirmation lands in Task 9); (S6) `cpu.max` throttling measurement (research open item): scratch cgroup `/sys/fs/cgroup/ovid-probe-cpu.$$` (root mkdir at cgroup root is permitted; controllers already enabled in root `subtree_control` — verified on this box), write `cpu.max` `"50000 100000"`, run a 2-second busy loop, compare iteration count against an uncapped run (expect ≈50%), `rmdir`; (S7) cleanup: `rm -rf` scratch dirs, remove probe cgroups, leave installed bwrap/profile in place (they are production prerequisites) and record what was installed.
- [ ] **Step 2: Dry validation (autonomous).** Run: `bash -n cloud/deploy/sandbox/sandbox-probe.sh` → exit 0; `shellcheck cloud/deploy/sandbox/sandbox-probe.sh` if available (warnings only). Write `MECHANISM.md` skeleton: decision matrix a/b/c from research §8.2 (ordered, with the avoid-list: no `dpkg-statoverride` setuid bwrap, no disabling `kernel.apparmor_restrict_unprivileged_userns`), evidence placeholders, and the empty `DECISION:` line.
- [ ] **Step 3: Run the probe for real (OWNER-GATED — stop-condition: installs `bubblewrap` via apt and, only on branch b, loads an AppArmor profile on the live host; no other side effects, all scratch state removed).** Run: `sudo bash cloud/deploy/sandbox/sandbox-probe.sh 2>&1 | tee /tmp/ovid-probe-$(date -u +%Y%m%dT%H%M%S).log`. Expected gate: S2 succeeds in exactly one branch; the log shows `uid=0(root)` inside, `uid_map` line `0 200000 1`, and the `touch` file owned by 200000 on the host (`stat -c %u`).
- [ ] **Step 4: Record the decision.** Fill `MECHANISM.md`: `DECISION: setuid` (branch a or b — b records the installed profile path + `aa-status` evidence) or `DECISION: rootmap` (branch c — record the map-writer mechanics the Task 7 launcher must implement), plus S5 ctty result, S6 throttle numbers, and the full log excerpt. If **all** branches fail: STOP — escalate to owner before any later task (no plan fallback beyond research §8.2).
- [ ] **Step 5: Commit.** `git add cloud/deploy/sandbox && git commit -m "chore(cloud): P2 week-1 host mechanism probe + AppArmor/userns decision record"`

### Task 2: `@ovid/sandbox` scaffold + `SandboxConfig` + sandbox-uid allocation

**Files:**
- Create: `cloud/packages/sandbox/{package.json,tsconfig.json,vitest.config.ts}`, `cloud/packages/sandbox/src/{index.ts,config.ts,hostGate.ts}`, `cloud/packages/sandbox/bin/sandbox-enter.sh` (placeholder contract file — body lands in Task 7)
- Modify: `cloud/packages/db/src/schema.ts` (users table), `cloud/packages/db/src/repos.ts` (users repo), new drizzle migration under `cloud/packages/db/drizzle/`
- Test: `cloud/packages/sandbox/src/config.test.ts`, `cloud/packages/db/src/repos.test.ts` (extend)

**Interfaces:**
- Consumes: P1 workspace (Task 1 of the P1 plan); `@ovid/db` (`createDb`, `migrate`, `users.ensure`, `Db`).
- Produces (later tasks import from `@ovid/sandbox` / `@ovid/db`):

```ts
// packages/sandbox/src/config.ts
export interface SandboxLimits { cpuMax: string; memoryMaxBytes: number; memorySwapMaxBytes: number; pidsMax: number; }
export const DEFAULT_SANDBOX_LIMITS: SandboxLimits; // { cpuMax:"100000 100000", memoryMaxBytes:536_870_912, memorySwapMaxBytes:0, pidsMax:64 }
export type LaunchStrategy = "setuid" | "rootmap";  // Task 1 DECISION
export interface SandboxConfig {
  workspacesRoot: string;   // env OVID_WORKSPACES_ROOT,  default "/workspaces/users"
  rootfsPath: string;       // env OVID_ROOTFS,           default "/opt/ovid-rootfs/current"
  cgroupRoot: string;       // env OVID_CGROUP_ROOT,      default "/sys/fs/cgroup"
  cgroupBase: string;       // env OVID_CGROUP_BASE,      default "ovid-sandboxes.slice/ovid-worker.service"
  uidBase: number;          // env OVID_SANDBOX_UID_BASE, default 200000
  uidMax: number;           // env OVID_SANDBOX_UID_MAX,  default uidBase+9999 (209999 at base 200000)
  maxActiveSandboxes: number; // env OVID_MAX_ACTIVE_SANDBOXES, default 24
  acquireTimeoutMs: number; // env OVID_ACQUIRE_TIMEOUT_MS, default 60_000
  workspaceQuotaMb: number; // env OVID_WORKSPACE_QUOTA_MB, default 500
  proWorkspaceQuotaMb: number; // env OVID_PRO_WORKSPACE_QUOTA_MB, default 2048
  storeQuotaMb: number;     // env OVID_STORE_QUOTA_MB,   default 2048
  maxWarmGb: number;        // env OVID_MAX_WARM_GB,      default 8
  minFreeGb: number;        // fixed 2 (not env-tunable in v1)
  limits: SandboxLimits;    // env OVID_SANDBOX_{CPU_MAX,MEMORY_MAX_MB,SWAP_MAX_MB,PIDS_MAX} overrides
  sandboxDns: string[];     // env OVID_SANDBOX_DNS, comma list, default ["1.1.1.1","9.9.9.9"]
  bwrapPath: string;        // env OVID_BWRAP_PATH, default "/usr/bin/bwrap"
  launcherPath: string;     // env OVID_SANDBOX_LAUNCHER, default: <package root>/bin/sandbox-enter.sh (resolved via import.meta.url)
  launch: LaunchStrategy;   // env OVID_SANDBOX_LAUNCH, default per Task 1 DECISION ("setuid" unless MECHANISM.md says rootmap)
}
export function loadSandboxConfig(raw: NodeJS.ProcessEnv = process.env): SandboxConfig; // throws on malformed values (positive ints, uidBase≥100000, uidBase<uidMax≤uidBase+9999 — width fixed at 10 000, base configurable: prod 200000 (spec §11), staging 220000 per P10; launch enum, non-empty dns)

// packages/sandbox/src/hostGate.ts
export function hostTestsAvailable(): boolean; // OVID_SANDBOX_HOST_TESTS==="1" && process.getuid?.()===0
export function jailMechanismAvailable(cfg: SandboxConfig): boolean; // bwrapPath exists && a trivial spawn probe succeeded (cached); used by describe.skipIf

// packages/db — schema.ts addition: users.sandboxUid = integer("sandbox_uid") unique
// migration adds: CREATE SEQUENCE users_sandbox_uid_seq START WITH 200000 MINVALUE 200000 MAXVALUE 209999;
// (sequence pinned to the PRODUCTION block — staging (P10) sets OVID_SANDBOX_UID_BASE=220000 and hash-allocates, never touching this sequence; config-level uid range is base-relative so staging validates)
export const users: {
  ensure(db: Db, uid: string, email: string | null): Promise<UserRow>; // unchanged (P1)
  allocateSandboxUid(db: Db, uid: string): Promise<number>; // idempotent: nextval once, UPDATE … SET sandbox_uid=$n WHERE uid=$1 AND sandbox_uid IS NULL RETURNING; no row → re-read existing; sequence exhaustion (nextval maxvalue error) → throw Error("sandbox uid pool exhausted")
};
```

- [ ] **Step 1: Write failing tests.** `config.test.ts`: defaults equal the pinned values above (assert `DEFAULT_SANDBOX_LIMITS.memoryMaxBytes === 536_870_912`, `pidsMax === 64`, `cpuMax === "100000 100000"`, `maxActiveSandboxes === 24`, `uidBase === 200000`, `uidMax === 209999`); every env override applies; **uid-base configurability (G4)**: `OVID_SANDBOX_UID_BASE=220000` alone → `{uidBase:220000, uidMax:229999}` (staging validates — P10); `OVID_SANDBOX_UID_BASE=220000 OVID_SANDBOX_UID_MAX=229999` → same; malformed values throw naming the variable (`OVID_MAX_ACTIVE_SANDBOXES=0`, `OVID_SANDBOX_UID_BASE=199999` — below the 100000 floor, `OVID_SANDBOX_UID_BASE=220000 OVID_SANDBOX_UID_MAX=230000` — width > 9999, `OVID_SANDBOX_LAUNCH=nope`, `OVID_SANDBOX_DNS=""`). `repos.test.ts` additions (TEST_DATABASE_URL-gated, unique test uids, cleanup rows + `setval` reset in afterAll): `allocateSandboxUid` twice same user → identical uid; two users → distinct uids; every allocated uid within `[200000, 209999]`; `setval('users_sandbox_uid_seq', 209999, true)` → next allocation for a fresh user throws `/pool exhausted/`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm --filter @ovid/sandbox test` (module missing) and `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db test` — Expected: FAIL.
- [ ] **Step 3: Implement.** Scaffold the package mirroring `cloud/packages/events` (package.json deps: `@ovid/db workspace:*`, `@ovid/shared workspace:*`; devDeps typescript/vitest/@types/node; scripts build/test; `vitest.config.ts` with `testTimeout: 30_000` for later host suites). Write config/hostGate per the signatures. Add `sandboxUid` to the users table + generate the migration (`pnpm --filter @ovid/db exec drizzle-kit generate`) — hand-adjust the generated SQL to include the sequence (drizzle-kit does not emit sequences). Implement `allocateSandboxUid`. `bin/sandbox-enter.sh`: create with the usage header only (Task 7 writes the body).
- [ ] **Step 4: Run to verify pass.** `bash cloud/scripts/dev-services.sh; cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db test && pnpm --filter @ovid/sandbox test` — Expected: all PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/sandbox cloud/packages/db && git commit -m "feat(cloud): @ovid/sandbox scaffold, config, sandbox-uid allocation (200000-209999)"`

### Task 3: Rootfs build pipeline + PATH shim wrappers

**Files:**
- Create: `cloud/deploy/rootfs/{versions.env,Dockerfile.noble,build.sh,install.sh,smoke-jail.sh}`
- Create: `cloud/deploy/rootfs/shims/{gcc,g++,make,gradle,gradlew,kotlinc,javac,sdkmanager,ndk-build,cargo,docker,flutter,ovid}`
- Create: `cloud/packages/sandbox/src/rootfs.ts`; Modify: `cloud/packages/sandbox/src/index.ts`
- Modify: `cloud/deploy/.gitignore` (add `rootfs/dist/`)
- Test: `cloud/packages/sandbox/src/rootfs.test.ts`, `cloud/packages/sandbox/src/shims.test.ts`

**Interfaces:**
- Consumes: docker + zstd on this host (both present); `REFUSAL_MESSAGE` does not exist yet — shims carry the literal string; Task 4 pins parity against them.
- Produces:

```ts
// packages/sandbox/src/rootfs.ts
export interface RootfsManifest { name: string; baseImage: string; baseImageDigest: string; nodeVersion: string; pnpmVersion: string; uvVersion: string; aptPackages: string[]; buildDate: string; builderCommit: string; }
export function parseRootfsManifest(json: unknown): RootfsManifest; // zod; throws on missing/ill-typed fields
export interface ResolvedRootfs { path: string; manifest: RootfsManifest; }
export function resolveRootfs(rootfsPath: string): Promise<ResolvedRootfs>; // reads <path>/manifest.json (path may be the `current` symlink), checks usr/bin/env, usr/local/bin/node, usr/local/bin/pnpm, usr/local/bin/uv, usr/bin/git, usr/bin/python3, usr/local/bin/ovid exist relative to it → else throw RootfsUnavailable (message names the missing piece)
export class RootfsUnavailable extends Error {}

// cloud/deploy/rootfs/versions.env (exact pins — build.sh fails if a checksum mismatch occurs)
// UBUNTU_IMAGE=ubuntu:24.04            (digest resolved+recorded by build.sh at build time)
// NODE_VERSION=v22.20.0                (official nodejs.org tarball; build verifies against SHASUMS256.txt — never apt node, research §6)
// PNPM_VERSION=10.34.0                 (corepack prepare + activate; store v10 mechanics measured in research §5)
// UV_VERSION=0.13.1                    (GitHub release tarball, sha256 verified against the release checksums file)
// APT_PACKAGES="ca-certificates curl git openssh-client procps python3 python3-venv xz-utils"
```

Shim contract (all shims `#!/bin/sh`, mode 755, baked at `/usr/local/bin` — ahead of `/usr/bin` in the jail PATH): unconditional shims (`gcc g++ make gradle gradlew kotlinc javac sdkmanager ndk-build`) print the refusal copy **verbatim to stdout** and `exit 126`; conditional shims refuse only the spec §7 subcommand forms and otherwise `exec` the real binary if one exists outside `/usr/local/bin`, else print `<name>: not installed in cloud workspaces` to stderr, `exit 127`:

```sh
#!/bin/sh
# cargo — blocks `cargo build` only (spec §7); everything else passes through.
if [ "${1:-}" = "build" ]; then
  echo "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead."
  exit 126
fi
for d in /usr/bin /bin; do [ -x "$d/cargo" ] && exec "$d/cargo" "$@"; done
echo "cargo: not installed in cloud workspaces" >&2; exit 127
```

(`docker`: refuse when `$1 = build`; `flutter`: refuse when `$1 = build` and `$2` ∈ `apk|appbundle|ios` — `flutter analyze|test` must pass through per spec §7. `gradlew` is unconditional — `./gradlew` bypasses PATH but has no JDK to run: the rootfs ships **no** java/gcc/make toolchain, which Task 15 asserts.) `ovid` CLI (v1 dispatch, extended in Task 10): `ovid install [pkgs…]` → `package.json` present ⇒ `pnpm add`/`pnpm install --prefer-offline`; else `pyproject.toml` ⇒ `uv add`/`uv sync`; else error to stderr exit 2; `ovid --help`.
`build.sh` contract: `set -euo pipefail`; NAME=`ubuntu-noble-min-$(date -u +%Y%m%d)-r${REVISION:-1}`; `docker pull ubuntu:24.04` and record `RepoDigests`; `docker build` with versions.env as build-args (Dockerfile verifies node/uv checksums inline); container name `ovid-rootfs-build-$NAME` with `trap 'docker rm -f …' EXIT`; `docker export | zstd -19 -T0 -o dist/$NAME.tar.zst`; manifest.json (incl. `dpkg -l` snapshot); SHA256SUMS; `docker rmi` the build tag. `install.sh` (OWNER-GATED): extract to `/opt/ovid-rootfs/$NAME.tmp` → `mv` → `ln -sfn` via `current.tmp` + `mv -T current` → prune to 2 revisions → run `smoke-jail.sh`. `smoke-jail.sh`: minimal bwrap jail (RO-bind root at `/`, `--proc --dev`, `--unshare-user --uid 0 --gid 0 --unshare-pid --die-with-parent`) running `node -e 'console.log(process.version)'`, `python3 -V`, `pnpm -v`, `uv -V`, `git --version`, `gcc` (expects refusal copy + rc 126) — gate: versions match versions.env.

- [ ] **Step 1: Write failing tests.** `shims.test.ts` (portable — runs the shim files with the host's `sh`, no jail): each unconditional shim → stdout **exactly** the refusal copy, exit 126; `cargo build` refuses, `cargo test` does not (exit 127 "not installed", stdout empty); `docker build x` refuses, `docker ps` does not; `flutter build apk|appbundle|ios` refuses, `flutter analyze` and `flutter test` do not; `ovid install foo` with a stub `pnpm` first on PATH in a tmpdir containing `package.json` → stub captures `add foo`; with `pyproject.toml` only and stub `uv` → stub captures `add foo`; no manifest → exit 2. `rootfs.test.ts`: tmpdir fixture (fake tree + manifest) → `resolveRootfs` returns it; missing `usr/local/bin/uv` → `RootfsUnavailable` naming it; `parseRootfsManifest` rejects a manifest missing `baseImageDigest`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm --filter @ovid/sandbox test` — Expected: FAIL (modules/files missing).
- [ ] **Step 3: Implement** versions.env, Dockerfile.noble, the 13 shim scripts, build.sh/install.sh/smoke-jail.sh, rootfs.ts.
- [ ] **Step 4: Run to verify pass + build the artifact for real (autonomous — docker only, no host mutation; ~1 min warm, ~5 min cold).** `pnpm --filter @ovid/sandbox test` → PASS; `bash -n` on all scripts; `REVISION=1 bash cloud/deploy/rootfs/build.sh` → `dist/ubuntu-noble-min-*-r1.tar.zst` + manifest.json + SHA256SUMS exist, `zstd -t` passes, manifest node/pnpm/uv versions equal versions.env. Extract to a scratch dir (`zstd -dc … | tar -x -C /tmp/ovid-rootfs-test`) and keep the path — later host-gated suites point `OVID_ROOTFS` at it. Do **not** run install.sh here (owner-gated, Task 16 activation).
- [ ] **Step 5: Commit.** `git add cloud/deploy/rootfs cloud/packages/sandbox cloud/deploy/.gitignore && git commit -m "feat(cloud): pinned rootfs build pipeline (docker-export noble) + PATH shim blockers"`

### Task 4: Command policy layer (shell-grammar parse + denylist + exact refusal)

**Files:**
- Create: `cloud/packages/sandbox/src/{policy.ts,corpora.ts}`; Modify: `cloud/packages/sandbox/src/index.ts`
- Test: `cloud/packages/sandbox/src/policy.test.ts`

**Interfaces:**
- Consumes: shim files from Task 3 (parity test reads them).
- Produces (Task 7 exec, Task 9 jobs, Task 12 run_shell, Task 15 import verbatim):

```ts
// packages/sandbox/src/policy.ts
export const REFUSAL_MESSAGE =
  "Heavy native compilation (APK/Gradle/Kotlin builds) is disabled on live cloud workspaces. Use GitHub Actions CI or syntax/lint preview mode instead.";
export interface PolicyVerdict { allowed: true } | { allowed: false; matched: string; segment: string }
export function splitShellSegments(command: string): string[][]; // quote/escape-aware tokenizer; splits on ; && || | & ( ) newlines and here-doc bodies; joins quoted fragments ("g""cc" → gcc)
export function checkCommandPolicy(command: string): PolicyVerdict;
export class CommandBlockedError extends Error { constructor(readonly refusal: string, readonly matched: string) } // Task 9 job start throws this

// packages/sandbox/src/corpora.ts — ONE corpus, consumed by Task 4 unit tests, Task 12 tool tests, Task 15 in-jail acceptance
export interface BlockedCorpusEntry { command: string; expect: "layer1" | "shim"; } // "shim" = documented layer-1 boundary (e.g. base64|sh); Task 15 proves the shim refusal in-jail
export const BLOCKED_COMMAND_CORPUS: BlockedCorpusEntry[];
export const ALLOWED_COMMAND_CORPUS: string[];
export const PATH_ESCAPE_CORPUS: string[]; // Task 12/15: "../../etc/passwd", "/etc/passwd", "/workspace/../../etc/shadow", "/workspaces/users/999999/x", "a/../../..", "" …
```

Matching rules (pin exactly): per segment, strip leading `VAR=value` assignments and wrapper heads (`sudo nice nohup time command builtin xargs env`); recursive descent: head ∈ `bash sh zsh dash ksh` with a `-c`-style flag → parse the argument as a command string; head `eval` → parse remaining words joined; otherwise match the head word's **basename** against the denylist set `gradle gradlew kotlinc javac gcc g++ make sdkmanager ndk-build` (exact), any word exactly `assembleDebug`/`assembleRelease`, `flutter build (apk|appbundle|ios)`, `cargo build`, `docker build` (positional: word[1]/word[2]), and fork-bomb regexes `:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:` plus the general `(\w+)\s*\(\)\s*\{\s*\1\s*\|\s*\1\s*&\s*\}\s*;\s*\1`. First match wins; `segment` is the offending segment text. BLOCKED_COMMAND_CORPUS ≥ 25 entries covering every spec §7 form + Review Focus #1 evasions (`bash -c 'gradle build'`, `sh -c "gcc x.c"`, `CC=gcc make`, `echo hi | gcc -x c -`, `$(gradle build)`, `eval "$(echo gradle) build"`, `sudo make`, `xargs make < list.txt`, `sh <<'EOF'\nmake\nEOF`, `cd app && ./gradlew assembleRelease`, `"g""cc" x.c`, the fork bomb, one `echo Z3JhZGxlIHg= | base64 -d | sh` entry with `expect:"shim"`); ALLOWED_COMMAND_CORPUS ≥ 15 entries per spec §7 "Allowed" (`node -e …`, `python3 x.py`, `pnpm i`, `pnpm add is-number`, `npm install`, `pip install six`, `uv add six`, `apt-get install -y jq`, `git commit -m x`, `flutter analyze`, `flutter test`, `cargo test`, `cargo run`, `makefile`-as-filename, `echo "gcc is great"`, `touch gradlew.txt`).

- [ ] **Step 1: Write failing tests.** `policy.test.ts`: every BLOCKED entry with `expect:"layer1"` → `{allowed:false}` and the matched segment non-empty; every ALLOWED entry → `{allowed:true}` (Review Focus #1 negative half); `splitShellSegments` unit cases (quotes preserve `;` inside strings, `&&` vs `&`, here-doc body becomes segments, `$( )` subshell content parsed); parity: for each unconditional shim file read from `cloud/deploy/rootfs/shims/`, its stdout string equals `REFUSAL_MESSAGE` byte-for-byte (and the three conditional shims contain it too); `CommandBlockedError.refusal === REFUSAL_MESSAGE`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm --filter @ovid/sandbox test` — Expected: FAIL.
- [ ] **Step 3: Implement** policy.ts + corpora.ts (tokenizer: single pass with quote/escape state, operator boundaries, here-doc detection `<<-?['"]?(\w+)` capturing until the delimiter line).
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git add cloud/packages/sandbox && git commit -m "feat(cloud): command policy layer — shell-aware denylist + exact refusal copy"`

### Task 5: Invocation builder + private minimal /etc + home dotfiles

**Files:**
- Create: `cloud/packages/sandbox/src/{invocation.ts,etcFiles.ts}`; Modify: `cloud/packages/sandbox/src/index.ts`
- Test: `cloud/packages/sandbox/src/{invocation.test.ts,etcFiles.test.ts}`

**Interfaces:**
- Consumes: `SandboxConfig` (Task 2).
- Produces (Task 7 exec, Task 9 pty/jobs, Task 8 manager import verbatim):

```ts
// packages/sandbox/src/invocation.ts
export interface JailSpec {
  rootfs: string; workspaceDir: string; homeDir: string; etcDir: string;
  cwd?: string;                       // jail path; default "/workspace"
  env?: Record<string, string>;       // merged over BASE_JAIL_ENV (sorted for golden determinism)
  argv: string[];                     // payload, e.g. ["/bin/bash","-c","echo hi"]
}
export const JAIL_WORKSPACE = "/workspace";
export const BASE_JAIL_ENV: Readonly<Record<string, string>>; // PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin, HOME=/root, LANG=C.UTF-8, TERM=xterm-256color, NPM_CONFIG_STORE_DIR=/root/.cache/pnpm-store, UV_CACHE_DIR=/root/.cache/uv, UV_LINK_MODE=hardlink
export function buildBwrapArgs(spec: JailSpec, cfg: Pick<SandboxConfig, "launch" | "bwrapPath">): string[]; // full argv INCLUDING bwrapPath at [0]

// packages/sandbox/src/etcFiles.ts
export interface EtcBundle { passwd: string; group: string; hosts: string; resolvConf: string; nsswitch: string; }
export function renderEtcBundle(opts: { dns: string[] }): EtcBundle;
export function renderHomeDotfiles(): { npmrc: string };  // "store-dir=/root/.cache/pnpm-store\nfund=false\naudit=false\n"
export async function writeEnvFiles(opts: { etcDir: string; homeDir: string; bundle: EtcBundle; dotfiles: { npmrc: string }; ownerUid: number }): Promise<void>; // 0644 (npmrc 0644), chown ownerUid, mkdir -p
```

`buildBwrapArgs` flag order (golden-pinned): `--ro-bind {rootfs} /`, `--dev /dev`, `--proc /proc`, `--tmpfs /tmp`, `--dir /etc`, `--ro-bind {rootfs}/etc/ld.so.cache /etc/ld.so.cache`, `--ro-bind {rootfs}/etc/ssl /etc/ssl`, `--ro-bind {rootfs}/etc/ca-certificates /etc/ca-certificates`, `--ro-bind {etcDir}/{passwd,group,hosts,resolv.conf,nsswitch.conf} /etc/<same>`, `--bind {workspaceDir} /workspace`, `--bind {homeDir} /root`, launch-strategy flags (`setuid` → `--unshare-user --uid 0 --gid 0`; `rootmap` → **no** `--unshare-user` — the launcher pre-creates the userns per Task 1 MECHANISM.md), `--unshare-pid --unshare-ipc --unshare-uts --die-with-parent --new-session`, `--clearenv` + `--setenv` pairs (BASE_JAIL_ENV merged with `spec.env`, keys sorted), `--chdir {cwd ?? "/workspace"}`, then `...spec.argv`. **No `--unshare-net`** (shared netns; the Task 11 nft filter is the egress boundary — research §8.5). `renderEtcBundle`: passwd = root + nobody lines only; resolvConf = one `nameserver` line per `dns` entry (must never render `127.0.0.53`); hosts = `127.0.0.1 localhost` + `::1 localhost`; nsswitch = `passwd: files / group: files / hosts: files dns`.

- [ ] **Step 1: Write failing tests.** `invocation.test.ts`: golden `toEqual` of the full argv for a fixed spec under `launch:"setuid"` (exact flag order above); `launch:"rootmap"` golden differs only by the three user-ns flags; env merge: caller env overrides BASE, keys sorted, `NPM_CONFIG_STORE_DIR`/`UV_CACHE_DIR`/`UV_LINK_MODE=hardlink` present; no `--unshare-net` anywhere; `--die-with-parent` and `--new-session` present; workspace/home binds use the spec's host dirs. `etcFiles.test.ts`: golden bundle strings; `renderEtcBundle({dns:["1.1.1.1"]}).resolvConf` contains `nameserver 1.1.1.1` and never `127.0.0.53`; `writeEnvFiles` against a tmpdir creates all five etc files + `.npmrc`, mode 0644, owner = `process.getuid()` (portable variant of the chown assertion).
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** → **Step 4: Verify pass.** `cd cloud && pnpm --filter @ovid/sandbox test`.
- [ ] **Step 5: Commit.** `git add cloud/packages/sandbox && git commit -m "feat(cloud): bwrap invocation builder + private minimal /etc + home dotfiles"`

### Task 6: cgroups v2 manager (leaf-first bootstrap, per-env caps, enforcement)

**Files:**
- Create: `cloud/packages/sandbox/src/cgroups.ts`; Modify: `cloud/packages/sandbox/src/index.ts`
- Test: `cloud/packages/sandbox/src/cgroups.test.ts` (portable, tmpdir-rooted), `cloud/packages/sandbox/src/cgroups.host.test.ts` (host-gated)

**Interfaces:**
- Consumes: `SandboxLimits`, config paths (Task 2).
- Produces (Tasks 7–9, 16 import verbatim):

```ts
export interface CgroupManager {
  init(): Promise<void>; // leaf-first bootstrap (research §3 gotcha 1): mkdir {base}/worker, move own pid there, then enable "+cpu +memory +pids" on {base}/cgroup.subtree_control; idempotent; still-EBUSY after self-move → throw CgroupSetupError (loud: another process is parked in the base)
  envPath(uid: number): string;             // {cgroupRoot}/{cgroupBase}/sandbox-{uid}
  leafPath(uid: number, name: string): string; // {envPath}/…/{name}   (names: exec-*, pty-*, job-*)
  createEnv(uid: number, limits: SandboxLimits): Promise<void>;  // mkdir; enable +cpu +memory +pids on env subtree_control; write memory.max (bytes string), memory.swap.max ("0"), pids.max, cpu.max — EXACT values from limits
  createLeaf(uid: number, name: string): Promise<string>;        // mkdir under envPath; returns absolute path
  attachPid(path: string, pid: number): Promise<void>;           // write to cgroup.procs
  procsFile(path: string): string;                               // {path}/cgroup.procs — handed to the Task 7 launcher
  kill(path: string): Promise<void>;   // write 1 to cgroup.kill, poll cgroup.procs empty (50 ms × 100), rmdir
  remove(path: string): Promise<void>; // rmdir (must be empty)
  readFile(path: string, file: string): Promise<string>;          // memory.events, pids.events, cpu.stat — tests + observability
  listChildren(path: string): Promise<string[]>;
}
export class CgroupSetupError extends Error {}
export function createCgroupManager(cfg: Pick<SandboxConfig, "cgroupRoot" | "cgroupBase">): CgroupManager;
```

Implementation is plain fs reads/writes against `{cgroupRoot}/{cgroupBase}` — the same class serves unit tests (tmpdir root: files are inert) and production (`/sys/fs/cgroup`, kernel enforces).

- [ ] **Step 1: Write failing portable tests** (`cgroups.test.ts`, `cgroupRoot: mkdtemp`): `init()` creates `worker/` and writes `+cpu +memory +pids` into the base's `subtree_control` file; `createEnv(200001, DEFAULT_SANDBOX_LIMITS)` → dir `sandbox-200001` with file contents **exactly** `memory.max`=`"536870912"`, `memory.swap.max`=`"0"`, `pids.max`=`"64"`, `cpu.max`=`"100000 100000"`; `createLeaf` path shape `…/sandbox-200001/exec-1`; `attachPid` writes the pid into `cgroup.procs`; `kill` on a tmpdir cgroup writes `cgroup.kill` and rmdirs; double `init()` is a no-op.
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** → **Step 4: Verify pass.** `cd cloud && pnpm --filter @ovid/sandbox test`.
- [ ] **Step 5: Write host-gated enforcement tests** (`cgroups.host.test.ts`, `describe.skipIf(!hostTestsAvailable())`, real root `/sys/fs/cgroup`, base `ovid-probe-cg-{pid}-{rand}`, full cleanup in afterAll; every hog double-bounded per research §3: container-less but capped allocations): (a) memory: env limits `{memoryMaxBytes: 67_108_864, pidsMax: 32, …}`, python hog allocating 8 MB chunks capped at 128 MB → child exit 137 and `readFile(env,"memory.events")` shows `oom_kill` ≥ 1 (Review Focus #4); (b) pids: `pids.max=16`, `sh -c 'while :; do sleep 10 & done'` → fails to fork ("Cannot fork"/EAGAIN), `pids.events` shows `max` ≥ 1, host process count unaffected; (c) cpu throttle (research open item): `cpu.max="50000 100000"` busy-loop 2 s vs uncapped → capped iterations ≈ 50 % (assert < 75 % of uncapped); (d) tree kill: leaf with `sh -c '(sleep 300 &) ; sleep 300'` → `kill(leaf)` → within 2 s no host process with that marker cmdline remains (scan `/proc` for the unique marker) and the leaf dir is gone; (e) EBUSY loudness: park a `sleep` subprocess in a fresh base dir → `init()` throws `CgroupSetupError` (kill the sleeper in cleanup).
- [ ] **Step 6: Run host suite.** `cd cloud && OVID_SANDBOX_HOST_TESTS=1 sudo -E pnpm --filter @ovid/sandbox test` — Expected: portable + host suites PASS; `/sys/fs/cgroup` contains no `ovid-probe-*` dirs afterwards (`ls /sys/fs/cgroup | grep ovid-probe` → empty).
- [ ] **Step 7: Commit.** `git add cloud/packages/sandbox && git commit -m "feat(cloud): cgroups v2 manager — leaf-first bootstrap, per-env caps, enforcement proofs"`

### Task 7: Exec API — one-shot jail spawn via the `sandbox-enter` launcher

**Files:**
- Create: `cloud/packages/sandbox/src/{types.ts,launcher.ts,exec.ts}`; Modify: `cloud/packages/sandbox/bin/sandbox-enter.sh` (body), `cloud/packages/sandbox/src/index.ts`
- Test: `cloud/packages/sandbox/src/exec.test.ts` (portable, stub launcher), `cloud/packages/sandbox/src/exec.host.test.ts` (host-gated)

**Interfaces:**
- Consumes: `buildBwrapArgs`/`JailSpec` (Task 5), `checkCommandPolicy`/`REFUSAL_MESSAGE` (Task 4), `CgroupManager` (Task 6), `SandboxConfig` (Task 2).
- Produces (Tasks 8/9/12/15 import verbatim):

```ts
// packages/sandbox/src/types.ts
export interface JailContext {
  config: SandboxConfig; launcher: JailLauncher; cgroups: CgroupManager;
  uid: number; rootfs: string;          // resolved rootfs path
  workspaceDir: string; homeDir: string; etcDir: string; // HOST paths
}
export interface ExecRequest { command?: string; argv?: string[]; cwd?: string; env?: Record<string, string>; timeoutMs?: number; stdin?: string; maxOutputBytes?: number; } // exactly one of command/argv
export interface ExecResult { exitCode: number | null; stdout: string; stderr: string; timedOut: boolean; truncated: boolean; blocked: boolean; refusal: string | null; }
export const EXEC_TIMEOUT_DEFAULT_MS = 120_000;
export const EXEC_TIMEOUT_MAX_MS = 600_000;
export const EXEC_OUTPUT_CAP_BYTES = 1_048_576;

// packages/sandbox/src/launcher.ts
export interface JailLauncher {
  spawn(bwrapArgv: string[], opts: { uid: number; gid: number; cgroupProcsFile: string; cwd: string; env?: NodeJS.ProcessEnv }): ChildProcessLike; // ChildProcessLike = { pid: number; stdout: Readable|null; stderr: Readable|null; stdin: Writable|null; kill(signal): boolean; once(event, fn) } — node:child_process shape; node-pty adapters wrap it in Task 9
  spawnPty(bwrapArgv: string[], opts: { uid: number; gid: number; cgroupProcsFile: string; cwd: string; cols: number; rows: number }): PtyChildLike; // PtyChildLike = node-pty IPty extended with { pid: number } — same launcher contract (bash sandbox-enter.sh), spawned on a pty master
}
export function createSetuidLauncher(config: Pick<SandboxConfig, "launcherPath">): JailLauncher; // spawns: bash sandbox-enter.sh <procsFile> <uid> <gid> <argvFile>
export function createRootmapLauncher(config: Pick<SandboxConfig, "launcherPath">): JailLauncher; // only if Task 1 DECISION=rootmap; mechanics per MECHANISM.md

// packages/sandbox/src/exec.ts
export async function execOnce(ctx: JailContext, req: ExecRequest): Promise<ExecResult>;
export function makeJailContext(deps: { config: SandboxConfig; cgroups: CgroupManager; launcher: JailLauncher; uid: number; rootfs: string; workspaceDir: string; homeDir: string; etcDir: string }): JailContext;
```

`execOnce` semantics (pin): normalize `argv` requests to a policy-checkable command string (shell-quote words) → `checkCommandPolicy` → blocked ⇒ return `{blocked:true, refusal:REFUSAL_MESSAGE, exitCode:null, …}` **without creating a cgroup leaf or spawning** (Review Focus #1, zero side effects); else create leaf `exec-{n}-{rand}` under the env cgroup, write a NUL-separated argv file (mktemp), `launcher.spawn(buildBwrapArgs(...), {uid, gid: uid, cgroupProcsFile: cgroups.procsFile(leaf), cwd: workspaceDir})` — the launcher child self-attaches to the cgroup **before** `setpriv` drops to the sandbox uid (research §3 ordering), collect stdout/stderr capped at `maxOutputBytes ?? EXEC_OUTPUT_CAP_BYTES` (keep draining, discard beyond cap, set `truncated`), timeout `min(timeoutMs ?? EXEC_TIMEOUT_DEFAULT_MS, EXEC_TIMEOUT_MAX_MS)` ⇒ `cgroups.kill(leaf)` + `timedOut:true`, finally remove the leaf and unlink the argv file.

`sandbox-enter.sh` body (exact — the setuid path):

```bash
#!/bin/bash
# usage: sandbox-enter.sh <cgroup-procs-file> <uid> <gid> <nul-separated-argv-file>
set -euo pipefail
procs="$1"; uid="$2"; gid="$3"; argvfile="$4"
echo $$ > "$procs"                       # attach BEFORE dropping privileges (research §3)
args=(); while IFS= read -r -d '' a; do args+=("$a"); done < "$argvfile"
exec setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "${args[@]}"
```

- [ ] **Step 1: Write failing portable tests** (`exec.test.ts` — stub `JailLauncher` recording spawns, tmpdir-rooted `CgroupManager`): `execOnce({command:"echo hi"})` with a stub child emitting stdout → `{exitCode:0, stdout:"hi\n", blocked:false}`; `{command:"gradle build"}` → `{blocked:true, refusal:REFUSAL_MESSAGE}` and the stub launcher recorded **zero** spawns and the tmp cgroup tree has **no** new leaf; argv request `["node","-e","x"]` policy-checked via its quoted join; timeout path: stub child that never exits + `timeoutMs:50` → `timedOut:true`, `kill` called on the leaf, leaf removed; output cap: 2 MB stdout with `maxOutputBytes:1024` → `truncated:true`, `stdout.length ≤ 1024`; leaf cgroup.procs file path passed to the launcher equals `cgroups.procsFile(leaf)` (ordering contract).
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** types/launcher/exec + sandbox-enter.sh body (`bash -n` it).
- [ ] **Step 4: Verify portable pass.** `cd cloud && pnpm --filter @ovid/sandbox test`.
- [ ] **Step 5: Write host-gated tests** (`exec.host.test.ts`, `skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))`; config: `rootfsPath` from env `OVID_ROOTFS` (Task 3 scratch extract), `workspacesRoot` = mkdtemp, `cgroupBase` = `ovid-probe-exec-{pid}`, real `createSetuidLauncher`; uid fixed 200099; full cleanup): (a) `echo hello` → exit 0, stdout `hello\n`; (b) **uid map**: `cat /proc/self/uid_map` → parsed triple `(0, 200099, 1)` (research §2.2 corrected semantics) and `id -u` → `0`; (c) **host ownership**: `touch /workspace/owned.txt` → host `statSync({workspaceDir}/owned.txt).uid === 200099`; (d) **RO root**: `sh -c 'echo x > /etc/pwn'` → exit ≠ 0, stderr mentions read-only; `/usr/bin` write fails; (e) **host invisibility**: `ls /workspaces` → exit ≠ 0 (ENOENT); `ls /opt` → ENOENT; (f) **pid isolation**: `sh -c 'cat /proc/self/cgroup'` contains `sandbox-200099`, and `ps -e` inside lists ≤ a handful of pids, not the test runner's pid; (g) **die-with-parent**: spawn `sleep 300` jail from a forked node child, SIGKILL the child → within 2 s no host process with marker cmdline `sleep 300 dwp-{rand}` survives; (h) **blocked**: `{command:"make"}` → `blocked:true`, no leaf created in the real cgroup tree; (i) **cgroup attribution + enforcement recap**: run the memory hog from Task 6 through `execOnce` with env limits 64 MB → exit 137.
- [ ] **Step 6: Run host suite.** `cd cloud && OVID_SANDBOX_HOST_TESTS=1 OVID_ROOTFS=/tmp/ovid-rootfs-test sudo -E pnpm --filter @ovid/sandbox test` — Expected: PASS; no `ovid-probe-*` cgroups or mkdtemp workspaces left behind.
- [ ] **Step 7: Commit.** `git add cloud/packages/sandbox && git commit -m "feat(cloud): sandbox exec API — one-shot bwrap spawn via sandbox-enter launcher"`

### Task 8: SandboxManager — lifecycle, admission (24), quotas, recovery

**Files:**
- Create: `cloud/packages/sandbox/src/{manager.ts,quota.ts}`; Modify: `cloud/packages/sandbox/src/index.ts`
- Test: `cloud/packages/sandbox/src/{manager.test.ts,quota.test.ts}` (portable), `cloud/packages/sandbox/src/manager.host.test.ts` (host-gated)

**Interfaces:**
- Consumes: Tasks 2/5/6/7 (`SandboxConfig`, `writeEnvFiles`/`renderEtcBundle`/`renderHomeDotfiles`, `CgroupManager`, `makeJailContext`/`execOnce`/`JailLauncher`).
- Produces (**the P3-facing surface — import verbatim**; Task 9 grows `SandboxHandle` with `createPty`/`getPty`/`jobs`/`spawnProcess`; `workspaceDir(userId, sessionId)` below is the **P6 `BrowserToolsDeps` seam** — ruling P6-Q2 — and the per-user tree it exposes is what **P5's `SandboxFiles`** adapts onto inside its `sandboxSeam.ts`):

```ts
// packages/sandbox/src/quota.ts
export interface QuotaBackend { readonly kind: "xfs" | "noop"; applyQuota(path: string, projectId: number, hardBytes: number): Promise<void>; }
export function workspaceProjectId(uid: number): number;  // uid
export function cacheProjectId(uid: number): number;      // uid + 100_000
export async function selectQuotaBackend(workspacesRoot: string): Promise<QuotaBackend>; // statfs XFS magic 0x58465342 + xfs_quota binary present → xfs (xfs_io -c chproj -r + xfs_quota -x limit bhard), else noop (log-once warning)
export function createNoopQuotaBackend(): QuotaBackend;

// packages/sandbox/src/manager.ts
export interface SandboxHandle {
  readonly userId: string; readonly uid: number;
  readonly workspaceDir: string;        // host: {workspacesRoot}/{uid}/workspace
  readonly homeDir: string;             // host: {workspacesRoot}/{uid}/.home
  readonly jailWorkspaceDir: string;    // "/workspace"
  exec(req: ExecRequest): Promise<ExecResult>;
  destroy(): Promise<void>;             // kill all live leaves (ptys/jobs from Task 9), kill+rmdir env cgroup, deregister, release admission slot; workspace DATA persists (purge = P9 account deletion)
}
export interface SandboxInfo { userId: string; uid: number; createdAt: string; }
export interface SandboxManager {
  attach(userId: string, opts?: { tier?: "free" | "pro" }): Promise<SandboxHandle>; // create-if-needed; FIFO admission queue beyond maxActiveSandboxes; rejects SandboxAdmissionError after acquireTimeoutMs, SandboxCapacityError on disk pressure
  get(userId: string): SandboxHandle | undefined;
  destroy(userId: string): Promise<void>;
  list(): SandboxInfo[];
  activeCount(): number;
  workspaceDir(userId: string, sessionId: string): Promise<string>; // P6 seam (ruling P6-Q2, consumed by P6 Task 16d BrowserToolsDeps.workspaceDir): allocateUid (idempotent — NO jail/cgroup/env creation), mkdir -p `{workspacesRoot}/{uid}/sessions/{sessionId}`, apply the per-user workspace quota project id (`workspaceProjectId(uid)` — quota semantics stay PER-USER, shared with the agent workspace), return the HOST path
  recover(): Promise<void>;   // boot: scan workspacesRoot numeric dirs → known envs (cold); orphan env cgroups without a workspace → kill+rmdir; attach() re-warms cold envs (recreate cgroup + rewrite etc/home files, never touches data); also sweep `{uid}/sessions/*` dirs whose sessionId no longer exists in the DB → P7 hibernation owns eviction (v1: leave them)
  close(): Promise<void>;     // destroy all — worker shutdown
}
export class SandboxAdmissionError extends Error {}  // wire code "sandbox_busy"
export class SandboxCapacityError extends Error { constructor(readonly reason: "disk_pressure") } // wire code "sandbox_unavailable"
```

**On-disk layout reconciliation (G1, ruling P6-Q2):** per-user uid directories remain the root of everything (`{workspacesRoot}/{uid}/…`) — nft, cgroups, and XFS quotas all keep keying on the sandbox **uid**. The agent workspace stays `{uid}/workspace` (bound at `/workspace` in the jail, `SandboxHandle.workspaceDir` unchanged). Session-scoped consumers (P6 browser uploads/downloads) get a **sibling subtree** `{uid}/sessions/{sessionId}/` — this is P6's `{root}/{userId}/sessions/{sessionId}` default reconciled: keyed by the sandbox uid instead of the userId string, under the same per-user tree, so the per-user quota and the egress/cgroup uid keying stay exact. P6 injects `manager.workspaceDir` as its `BrowserToolsDeps.workspaceDir(userId, sessionId)` dep (its default layout is only a test fallback). P5's `SandboxFiles` (read/write/list/stat/remove + one-shot `exec` scoped to the workspace) is absorbed by this plan's surface with no new API: host-side file ops via `SandboxHandle.workspaceDir` + `resolveConfined` (Task 12) + `execOnce` for exec — P5 maps its `uid` onto the user tree inside `cloud/apps/worker/src/sandboxSeam.ts` per its own adaptation rule.
export interface SandboxManagerDeps {
  config: SandboxConfig;
  allocateUid(userId: string): Promise<number>;       // prod: (u) => users.allocateSandboxUid(db, u)
  cgroups: CgroupManager; quota: QuotaBackend; launcher: JailLauncher;
  rootfs: ResolvedRootfs;                             // Task 3 resolveRootfs
  diskUsage?(): Promise<{ freeGb: number; warmGb: number }>; // default: statvfs(workspacesRoot) + du of warm dirs; injected in tests
  clock?(): Date;
}
export function createSandboxManager(deps: SandboxManagerDeps): SandboxManager;
```

`attach` create flow (pin order): admission gate (queue with timeout) → `allocateUid` → disk guard (`freeGb < config.minFreeGb || warmGb >= config.maxWarmGb` ⇒ `SandboxCapacityError("disk_pressure")`, log loudly, release slot) → `mkdir -p` `{uid}/{workspace,.home,.cache/pnpm-store,.cache/uv,etc}` + chown each created dir to the uid → `quota.applyQuota(workspace, workspaceProjectId(uid), quotaMb(tier) * 2^20)` and `(.cache, cacheProjectId(uid), storeQuotaMb * 2^20)` → `writeEnvFiles` (etc bundle + `.npmrc`) → `cgroups.createEnv(uid, config.limits)` → build handle. Concurrent `attach` for the same userId dedupes to one create (in-flight promise map). Quota by tier: `free`→`workspaceQuotaMb`, anything else→`proWorkspaceQuotaMb`.

- [ ] **Step 1: Write failing portable tests.** `quota.test.ts`: `workspaceProjectId(200001)===200001`, `cacheProjectId(200001)===300001`; noop backend resolves and records nothing; `selectQuotaBackend(tmpdir-on-ext4-or-overlay)` → `kind:"noop"` (portable assertion: not "xfs" unless the CI fs is XFS — assert it matches the statfs probe result). `manager.test.ts` (tmpdir workspacesRoot, tmpdir cgroupRoot, recording stub launcher, stub `allocateUid` 200001+, stub `diskUsage`): attach creates the exact dir layout (all five subdirs), etc files exist with the resolv.conf from config.dns, env cgroup files hold the exact cap values, handle.workspaceDir path shape; second attach returns the **same** handle (identity) and `allocateUid` called once; `destroy` → env cgroup dir gone, `activeCount()` 0, workspace files still on disk; admission: `maxActiveSandboxes:2` + `acquireTimeoutMs:5_000` → third attach pending → destroy one → third resolves with a handle (assert FIFO: two waiters resolve in enqueue order); timeout: `maxActiveSandboxes:1`, `acquireTimeoutMs:50` → second rejects `SandboxAdmissionError`; disk: `{freeGb:1}` → `SandboxCapacityError` reason `disk_pressure`; quota stub recorded calls `[(workspacePath, 200001, 524_288_000), (cachePath, 300001, 2_147_483_648)]` for tier free (500 MB = 500×2^20 = 524288000; pin the byte math); tier "pro" → 2048×2^20; recovery: pre-create `{tmp}/200005/workspace` + an orphan cgroup `sandbox-209999` → `recover()` → `list()` empty (cold envs are not active), orphan cgroup removed, subsequent attach for a user mapped to 200005 re-warms without recreating data (write a file, recover, attach, file still there). **`workspaceDir(userId, sessionId)` seam (G1)**: returns `{tmp}/{uid}/sessions/{sess}` with the dir created (assert the exact path shape against the stub allocator's uid); NO env cgroup created for it and `activeCount()` unchanged (provisioning is not an attach); same `(userId, sessionId)` twice → same path, dir still there; two sessionIds → sibling dirs; quota stub records the `workspaceProjectId(uid)` call for the sessions dir (per-user quota shared with the agent workspace — no session-scoped quota); existing sandbox for the user already attached → reuses its uid without calling `allocateUid` again.
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** → **Step 4: Verify pass.** `cd cloud && pnpm --filter @ovid/sandbox test`.
- [ ] **Step 5: Host-gated test** (`manager.host.test.ts`, gated like Task 7, uid via stub allocator 200098, real cgroups under `ovid-probe-mgr-{pid}`): attach → every created dir/file `stat.uid === 200098`; `handle.exec({command:"id -u"})` → stdout `0` (inner) while host files land 200098; destroy → cgroup gone, `ps` shows no processes of uid 200098 (scan `/proc`), data dir persists. Cleanup everything.
- [ ] **Step 6: Run host suite** (command as Task 6 Step 6) — Expected: PASS, no `ovid-probe-*` remnants.
- [ ] **Step 7: Commit.** `git add cloud/packages/sandbox && git commit -m "feat(cloud): SandboxManager — lifecycle, FIFO admission (24), quotas, recovery"`

### Task 9: PTY sessions (node-pty) + background jobs with process-tree cleanup

**Files:**
- Create: `cloud/packages/sandbox/src/{ring.ts,pty.ts,jobs.ts}`; Modify: `cloud/packages/sandbox/src/manager.ts` (handle grows `createPty`/`getPty`/`jobs`; `destroy` kills ptys + `jobs.killAll()` first), `cloud/packages/sandbox/src/index.ts`, `cloud/pnpm-workspace.yaml` (allowBuilds `"node-pty": true`), `cloud/packages/sandbox/package.json` (dep `node-pty ^1.1.0`)
- Test: `cloud/packages/sandbox/src/{ring.test.ts,jobs.test.ts}` (portable), `cloud/packages/sandbox/src/pty.host.test.ts` (host-gated)

**Interfaces:**
- Consumes: Tasks 4–8 (`CommandBlockedError`, `buildBwrapArgs`, `CgroupManager`, `JailLauncher.spawnPty`, `JailContext`).
- Produces (Task 13 bridge, Task 15, P3 job tools — import verbatim; `spawnLongRunning`/`SpawnedProcess` back **P5's `SandboxSpawner`** stdio-MCP seam):

```ts
// packages/sandbox/src/ring.ts
export interface RingChunk { offset: number; data: string } // data = base64; offset = byte position of the chunk's first byte in the session's lifetime stream
export interface ChunkRing {
  push(data: Buffer): RingChunk;                       // chunks > 64 KiB are split; evicts oldest beyond capBytes
  since(offset: number | null): { truncated: boolean; chunks: RingChunk[]; endOffset: number }; // null → everything retained; offset below the retained window → truncated:true + all retained chunks; chunks returned have start offsets > offset (never re-delivers covered bytes)
  readonly endOffset: number; readonly byteLength: number;
}
export function createChunkRing(capBytes: number): ChunkRing;
export const PTY_SCROLLBACK_BYTES = 262_144;   // spec §6.2: 256 KB
export const JOB_OUTPUT_RING_BYTES = 1_048_576;

// packages/sandbox/src/pty.ts
export interface PtyRequest { sessionId: string; cols?: number; rows?: number; env?: Record<string, string>; } // cols default 80 (clamp 1..500), rows default 24
export interface PtyHandlers { onData(chunk: RingChunk): void; onExit(exitCode: number | null): void; }
export interface PtySession {
  readonly id: string; readonly sessionId: string; readonly ring: ChunkRing; // cap PTY_SCROLLBACK_BYTES
  write(data: Buffer): void; resize(cols: number, rows: number): void;
  kill(): Promise<void>;                       // cgroup.kill leaf + pty kill; idempotent
  readonly exit: Promise<number | null>; readonly alive: boolean;
}
export function createPtySession(ctx: JailContext, req: PtyRequest, handlers: PtyHandlers): Promise<PtySession>; // leaf pty-{id}; payload ["/bin/bash"]; TERM from BASE_JAIL_ENV

// packages/sandbox/src/jobs.ts
export interface JobRequest { command: string; cwd?: string; env?: Record<string, string>; timeoutMs?: number; }
export interface JobInfo { id: string; command: string; state: "running" | "exited" | "killed"; exitCode: number | null; startedAt: string; endOffset: number; }
export interface JobOutput { truncated: boolean; chunks: RingChunk[]; endOffset: number; }
export interface JobRegistry {
  start(req: JobRequest): Promise<JobInfo>;                    // policy-checked: blocked → throws CommandBlockedError (no spawn)
  list(): JobInfo[]; output(id: string, afterOffset?: number | null): JobOutput | null; // null = unknown id
  kill(id: string): Promise<void>;                             // cgroup.kill (whole tree) → state "killed"
  killAll(): Promise<void>; readonly size: number;
}
export function createJobRegistry(ctx: JailContext): JobRegistry; // leaf job-{id}; payload ["/bin/bash","-c",command]; per-job ring JOB_OUTPUT_RING_BYTES; max 16 concurrent jobs per env → start throws Error("job_limit")

// packages/sandbox/src/jobs.ts — long-lived jailed process with PIPES (the P5 stdio-MCP backing capability, gap G3)
// Same machinery as jobs, minus the tty and minus the shell: launcher.spawn with stdin kept open, stdout/stderr as pipes.
export interface SpawnedProcess {
  readonly pid: number;
  writeLine(line: string): void;                     // utf8 + "\n" (appended if absent) → child stdin; never throws
  onStdoutLine(cb: (line: string) => void): void;    // stdout split on "\n", trailing empty line dropped; stderr NOT line-streamed (collected, surfaced on exit)
  onExit(cb: (code: number | null) => void): void;
  kill(): Promise<void>;                             // end stdin, cgroup.kill leaf (whole tree), rmdir; idempotent; exit cb fires
}
export interface SpawnRequest { argv: string[]; cwd?: string; env?: Record<string, string>; } // argv ONLY — no shell, no checkCommandPolicy (operator-configured launchers, not model-authored text; P5 enforces its own LAUNCHER_ONLY_COMMANDS allowlist at the seam)
export function spawnLongRunning(ctx: JailContext, req: SpawnRequest): Promise<SpawnedProcess>; // leaf spawn-{id}; cgroup leaf + die-with-parent like every spawn; exit ⇒ leaf removed
```

`SandboxHandle` additions (Task 8 interface extended — final shape): `createPty(req: PtyRequest, handlers: PtyHandlers): Promise<PtySession>`, `getPty(ptyId: string): PtySession | undefined`, `readonly jobs: JobRegistry`, `spawnProcess(req: SpawnRequest): Promise<SpawnedProcess>` (bound to the env, live leaves tracked + killed first by `destroy`).

**P5 seam mapping (gap G3, ruling "seam names SandboxSpawner/SandboxFiles reconcile against P2 plan"):** P5's `SandboxSpawner.spawn(uid, { command, args, env, cwd })` → `handle.spawnProcess({ argv: [command, ...args], env, cwd })`; `SandboxProcessHandle {writeLine,onStdoutLine,onExit,kill}` is structurally `SpawnedProcess` (P5 adapts names inside `cloud/apps/worker/src/sandboxSeam.ts` per its plan's adaptation rule). PTY sessions are NOT used for stdio MCP (tty echo/CRLF would corrupt the JSON-RPC line channel) — pipes only.

- [ ] **Step 1: Write failing portable tests.** `ring.test.ts`: push/since ordering — offsets are cumulative byte counts; `since(null)` returns all; `since(k)` excludes chunks ending ≤ k, never duplicates; overflow: cap 100 B, push 3×60 B → `byteLength ≤ 100`, `since(0)` → `truncated:true` with only retained chunks; 128 KiB single push splits into ≤64 KiB chunks with contiguous offsets; base64 round-trip of binary data (push `Buffer.from([0,255,128])`). `jobs.test.ts` (stub launcher + tmp cgroups): `start({command:"make"})` throws `CommandBlockedError` with refusal === REFUSAL_MESSAGE and spawns nothing; `start({command:"sleep 5"})` → `list()[0].state === "running"`; stub child emits output → `output(id)` chunks decode to it with rising `endOffset`; `output(id, afterOffset)` skips covered bytes; `kill(id)` → `cgroups.kill` called on the job leaf, state `"killed"`; unknown id → `output` null, `kill` no-op; 17th concurrent start throws `job_limit`. **`spawnLongRunning` (G3)** (stub launcher child = node `PassThrough` stdin/stdout): `writeLine('{"jsonrpc":"2.0"...}')` → stub child's stdin received the line + `\n`; stub child emits two JSON lines in ONE stdout chunk → `onStdoutLine` fires twice, one line each (no tty echo/CRLF transformation — assert `spawnPty` was NOT called); `onExit` fires with the stub exit code and the `spawn-*` leaf is removed from the cgroup tree; `kill()` on a live child → cgroup.kill on its leaf, idempotent second call; `handle.spawnProcess` uses the same env cgroup (leaf sibling of `job-*`).
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** ring/pty/jobs + manager wiring + allowBuilds + `pnpm install` (node-pty builds native — verify `pnpm --filter @ovid/sandbox build` links it) → **Step 4: Verify portable pass.**
- [ ] **Step 5: Host-gated pty+jobs tests** (`pty.host.test.ts`, gated like Task 7; this also closes research open item "node-pty through bwrap --new-session"): pty — create → write `tty\n` → ring output contains `/dev/pts/`; `resize(100, 30)` then write `stty size\n` → output contains `30 100`; write `gradle build\n` → **the shim refusal copy appears verbatim in the ring** (Review Focus #1 layer 2 in a live terminal); `kill()` → `exit` resolves, leaf cgroup gone, `alive === false`; two ptys in one env coexist (distinct leaves). jobs — `start({command:'for i in 1 2 3; do echo j$i; sleep 0.2; done'})` → output eventually contains `j1 j2 j3`, state `exited`, exitCode 0; tree kill: `start({command:"(sleep 300 jobmark-$rand &) ; sleep 300 jobmark-$rand"})` → `kill` → within 2 s zero host processes match `jobmark-$rand` (scan `/proc/*/cmdline`); pids cap: env limits overridden to `pidsMax:16` via test config → a forkbomb-ish job (`while :; do sleep 5 & done`) stalls at the cap and the HOST stays responsive (assert the test's own spawn still works), `pids.events max ≥ 1` (Review Focus #4). Cleanup all. **spawn (G3)**: `spawnLongRunning({argv:["/usr/local/bin/node","-e","process.stdin.on('data',d=>process.stdout.write(String(d).trim().toUpperCase()+'\\n'))"]})` → `writeLine("hello")` → `onStdoutLine` receives `"HELLO"` (real pipes through the jail — the P5 stdio-MCP proof shape); child exiting on its own → `onExit(null|code)` + leaf gone.
- [ ] **Step 6: Run host suite** — Expected: PASS, no remnants (no `jobmark-*` processes, no probe cgroups).
- [ ] **Step 7: Commit.** `git add cloud/packages/sandbox cloud/pnpm-workspace.yaml cloud/pnpm-lock.yaml && git commit -m "feat(cloud): PTY sessions (node-pty) + background jobs with cgroup tree-kill"`

### Task 10: Per-user package caches + `ovid install` fast path

**Files:**
- Modify: `cloud/deploy/rootfs/shims/ovid` (add `cache-prune`; harden dispatch), `cloud/packages/sandbox/src/invocation.ts` (only if a store-env gap surfaces — BASE_JAIL_ENV already carries `NPM_CONFIG_STORE_DIR`, `UV_CACHE_DIR`, `UV_LINK_MODE=hardlink`)
- Create: `cloud/packages/sandbox/src/caches.ts`
- Test: `cloud/packages/sandbox/src/caches.test.ts` (portable), `cloud/packages/sandbox/src/caches.host.test.ts` (host-gated)

**Interfaces:**
- Consumes: Task 3 rootfs (`ovid`, pnpm/uv inside), Task 5 env wiring, Task 8 quota (store lives in the `.cache` project-quota subtree, same filesystem as `/workspace` — the research §5 hardlink precondition).
- Produces:

```ts
// packages/sandbox/src/caches.ts
export const STORE_PATHS: Readonly<{ pnpmStore: string; uvCache: string }>; // jail paths: /root/.cache/pnpm-store, /root/.cache/uv (host: {uid}/.home/.cache/…)
export function ovidInstallArgv(packages: string[]): string[];      // ["/usr/local/bin/ovid","install",...packages]
export function cachePruneArgv(): string[];                          // ["/usr/local/bin/ovid","cache-prune"] → pnpm store prune + uv cache prune (P7 hibernate consumes this)
export function installEnv(): Record<string, string>;                // the exact env subset installs run with (store dirs + UV_LINK_MODE) — re-exported from BASE_JAIL_ENV for tool-side assertions
```

Design notes to encode in `caches.ts` header comment: per-user stores (research §5 — shared RO store is unworkable: `protected_hardlinks` EPERM, pnpm needs a writable store, uv refuses RO caches); same-filesystem hardlinks proven; `UV_LINK_MODE=hardlink` pinned (stores live on the workspace XFS volume → same fs; if ever cross-device, uv warns and flips to copy — flip the pin to `copy` then); XFS reflink **seed stores** are a future owner decision (needs the XFS volume from Task 16; no seeding in v1 — first install per user pays network cost, subsequent installs hit the per-user store).

- [ ] **Step 1: Write failing portable tests.** `caches.test.ts`: `STORE_PATHS` jail paths exact; `ovidInstallArgv(["is-number"])` shape; `installEnv()` contains `NPM_CONFIG_STORE_DIR=/root/.cache/pnpm-store`, `UV_CACHE_DIR=/root/.cache/uv`, `UV_LINK_MODE=hardlink`; extend the Task 3 shim harness: `ovid cache-prune` with stub pnpm/uv → both prunes invoked; `ovid install` precedence (package.json wins over pyproject.toml). Rebuild the rootfs artifact if `shims/ovid` changed (`REVISION` bump, re-run build.sh).
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** → **Step 4: Verify portable pass.**
- [ ] **Step 5: Host-gated proof** (`caches.host.test.ts`, gated like Task 7; needs network egress for the first install — the sandbox uid is NOT yet nft-filtered in test context, and registry access is allowed traffic anyway): via `handle.exec`: (a) `pnpm store path` → stdout `/root/.cache/pnpm-store`; (b) in `/workspace`: `npm init -y && pnpm add is-number` → exit 0, then `stat -c '%h %i' node_modules/is-number/index.js` and a `find /root/.cache/pnpm-store -inum <inode>` hit → **links ≥ 2 and the store contains the same inode** (hardlink install, research §5 reproduced per-user); (c) **fast path**: second project `/workspace/p2` + `pnpm add is-number --prefer-offline` → exit 0, wall time recorded via `Date.now()` around exec; assert `< 2_000 ms` as the hard sanity gate and `console.info` the measurement against the **<100 ms target** (a warm-store no-op `ovid install is-number` re-run is the number recorded in the task report — do not fail the suite on the 100 ms target itself; record it for the owner); (d) uv: `uv venv && uv pip install six` → `site-packages/six.py` links ≥ 2, no cross-device warning in stderr; (e) cache files live under `.cache` (host path `{uid}/.home/.cache/pnpm-store` exists, owned by the sandbox uid). Cleanup workspaces + cgroups.
- [ ] **Step 6: Run host suite** → PASS; record the (c)/(d) timings in the commit body.
- [ ] **Step 7: Commit.** `git add cloud/packages/sandbox cloud/deploy/rootfs/shims/ovid && git commit -m "feat(cloud): per-user pnpm/uv caches + ovid install fast path (hardlink proof)"`

### Task 11: Egress filtering — nftables renderer, artifacts, netns proof

**Files:**
- Create: `cloud/packages/sandbox/src/{net.ts,renderNftCli.ts,netTestKit.ts}`, `cloud/deploy/net/{install-nft.sh,ovid-sandbox-nft.service}`; Modify: `cloud/packages/sandbox/src/index.ts`, `cloud/packages/sandbox/package.json` (bin entry `render-nft`)
- Test: `cloud/packages/sandbox/src/net.test.ts` (portable), `cloud/packages/sandbox/src/net.host.test.ts` (host-gated, disposable netns)

**Interfaces:**
- Consumes: `SandboxConfig` uid range (Task 2).
- Produces:

```ts
// packages/sandbox/src/net.ts
export interface EgressConfig { uidRange: [number, number]; blockedV4: string[]; blockedV6: string[]; ownPublicIp: string; table?: string; browserUidRange?: [number, number]; browserAllowedV4?: string[]; } // table default "ovid_sandbox"; browserUidRange = the P6 worker/browser-engine uid (gap G2, P6 Task 16d) — OPTIONAL: unset → browser section omitted; MUST NOT overlap uidRange (renderNftRuleset throws naming both ranges — distinct keyspaces); browserAllowedV4 = the worker's internal endpoints the browser uid must still reach (loopback 127.0.0.0/8 is ALWAYS allowed for the browser range and never configurable — LiteLLM :4000 and the pg/mint proxies live there)
export const DEFAULT_BLOCKED_V4: readonly string[]; // ["10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]
export const DEFAULT_BLOCKED_V6: readonly string[]; // ["::1/128","fe80::/10","fc00::/7"]
export function renderNftRuleset(cfg: EgressConfig): string; // complete `nft -f` text: flush-on-reload safe (`table inet <t>` + `delete table` guard pattern), interval sets blocked_v4/blocked_v6, chain output (type filter hook output priority 0; policy accept), rules: meta skuid {a}-{b} ip daddr @blocked_v4 counter drop / ip6 daddr @blocked_v6 counter drop / ip daddr <ownPublicIp> counter drop — EVERY drop rule keyed on a uid range (research §2.4 mechanism). When browserUidRange is set (gap G2) the chain gains, for `meta skuid {browser a}-{b}`, in this ORDER: (1) ALLOW rules — `ip daddr 127.0.0.0/8 accept`, `ip6 daddr ::1/128 accept`, then one `ip daddr <cidr> accept` per browserAllowedV4 entry (the worker's internal endpoints: Postgres/Redis/mint/LiteLLM proxy addresses); (2) DROP rules — the SAME blocked sets + own public IP keyed on the browser range (127/8 and ::1 are allowed, not dropped, for THIS range only). Allow-internal-then-drop ordering IS the security contract (P6 Task 16d): the browser uid reaches internal services and nothing else in the blocked sets.
export function parseBrowserEgressUid(v: string | undefined): [number, number] | undefined; // accepts "230000" (single uid → [u,u]) or "230000-230099"; undefined/empty → undefined; malformed → throw naming OVID_BROWSER_EGRESS_UID
// renderNftCli.ts: reads OVID_SANDBOX_UID_BASE/OVID_SANDBOX_UID_MAX (uidMax DEFAULTS to base+9999 — the rules key on the CONFIGURED range, never a hardcoded one: gap G4; prod 200000-209999 and P10 staging 220000-229999 both render)/OVID_PUBLIC_IP (required — exit 1 with a usage message if unset)/OVID_SANDBOX_EXTRA_BLOCKED (optional csv)/OVID_BROWSER_EGRESS_UID (optional — set at P6 activation; single uid or range per parseBrowserEgressUid)/OVID_BROWSER_EGRESS_ALLOW (optional csv of internal-endpoint CIDRs for the browser range); prints the ruleset to stdout. Validation: browserUidRange overlapping the configured sandbox range → exit 1 naming both ranges (distinct keyspaces — the browser engine never shares a sandbox uid; P6 coordinates the value with this plan's uid reservation)
// netTestKit.ts (exported for Task 15 reuse)
export interface NetnsProof { blockedRc: number; counterPackets: number; rootRc: number; browserLoopbackRc: number | null; browserBlockedRc: number | null; }
export async function runEgressNetnsProof(opts: { ownPublicIp: string; uid: number; browserUid?: number; }): Promise<NetnsProof>; // creates netns ovid-spike-egress-<pid>-<rand>, lo up, python3 listener on 127.0.0.1:8999, loads renderNftRuleset inside the netns (browserUid set → browser range [browserUid,browserUid]), curls as `uid` (expect rc 28 timeout + rule counter > 0) and as root (expect rc 0 — uid-keying proof); when browserUid is set ALSO curls as browserUid: to 127.0.0.1:8999 (expect rc 0 — allow-internal-then-drop: the loopback exemption) and to 169.254.169.254 (expect rc 28 — the drop side); those two fields are null when browserUid is unset. Tears the netns DOWN in finally
```

Artifacts: `ovid-sandbox-nft.service` — `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=/usr/sbin/nft -f /opt/ovid-cloud/nft/ovid-sandbox.nft`, `ExecStop=/usr/sbin/nft delete table inet ovid_sandbox`, ordered `Before=ovid-worker.service`. `install-nft.sh` (owner-gated at Task 16): render via `node packages/sandbox/dist/renderNftCli.js` (requires `OVID_PUBLIC_IP`; passes through `OVID_SANDBOX_UID_BASE`/`OVID_SANDBOX_UID_MAX` — staging (P10) renders 220000-229999 from the same script — and, when present, `OVID_BROWSER_EGRESS_UID`/`OVID_BROWSER_EGRESS_ALLOW` for the P6 browser range) → write `/opt/ovid-cloud/nft/ovid-sandbox.nft` → `nft -c -f` validate → install+enable unit → gate `nft list table inet ovid_sandbox`.

- [ ] **Step 1: Write failing portable tests.** `net.test.ts`: rendered ruleset golden-contains `meta skuid 200000-209999` on **every** drop rule; all DEFAULT_BLOCKED_V4/V6 elements present with `flags interval`; own IP rule present; `hook output priority 0`; no rule lacks the skuid key (regex sweep: every `drop` line contains `skuid`); CLI contract: missing `OVID_PUBLIC_IP` → the render function/CLI errors (test the CLI via `execFile node dist/renderNftCli.js` after build, or export a `renderCli(env)` pure helper and test that — pin the pure helper `renderCli(env: NodeJS.ProcessEnv): string`). **Configured range (G4)**: `renderCli({OVID_SANDBOX_UID_BASE:"220000", …})` → every drop rule keys `meta skuid 220000-229999`, no literal `200000` anywhere; uidMax defaults to base+9999. **Browser range (G2)**: with `browserUidRange:[230000,230099]` → `meta skuid 230000-230099` present; for the browser range ONLY: `ip daddr 127.0.0.0/8 accept` and `ip6 daddr ::1/128 accept` lines appear BEFORE every `skuid 230000-230099 … drop` line (allow-internal-then-drop ordering — assert index order), each `browserAllowedV4` entry renders an accept rule before the drops, and the browser drop rules cover the same blocked sets + own IP; the SANDBOX rules are byte-identical with and without the browser section (200000-209999 untouched); `browserUidRange:[205000,205999]` (overlapping the sandbox range) → throws naming both ranges; `parseBrowserEgressUid("230000")` → `[230000,230000]`, `"230000-230099"` → the pair, `undefined`/`""` → undefined, `"abc"` → throws naming `OVID_BROWSER_EGRESS_UID`.
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** net.ts + renderNftCli.ts (+ `renderCli`) + netTestKit.ts + artifacts (`bash -n`, `systemd-analyze verify` the unit with `--root` if available, else structural review).
- [ ] **Step 4: Host-gated netns proof** (`net.host.test.ts`, `skipIf(!hostTestsAvailable())`, requires `nft`, `ip`, `curl`, `python3`): `runEgressNetnsProof({ownPublicIp:"203.0.113.7", uid:200050})` → `blockedRc === 28` (curl timeout — 127.0.0.1:8999 is inside the blocked `127.0.0.0/8`), `counterPackets > 0`, `rootRc === 0` (root reaches the same listener — proves uid-keying, Review Focus #5); also assert a `169.254.169.254` curl as the sandbox uid increments the v4-set counter (metadata path). **Browser range (G2)**: `runEgressNetnsProof({ownPublicIp:"203.0.113.7", uid:200050, browserUid:210050})` → additionally `browserLoopbackRc === 0` (browser-uid curl to 127.0.0.1:8999 succeeds — allow-internal) and `browserBlockedRc === 28` (browser-uid curl to 169.254.169.254 times out — then-drop; 210050 is outside the sandbox range by the overlap rule). `finally`: `ip netns del` — assert no `ovid-spike-egress-*` netns remains (`ip netns list`).
- [ ] **Step 5: Verify + full package run.** `cd cloud && OVID_SANDBOX_HOST_TESTS=1 sudo -E pnpm --filter @ovid/sandbox test` → PASS; `ip netns list | grep ovid-spike` → empty.
- [ ] **Step 6: Commit.** `git add cloud/packages/sandbox cloud/deploy/net && git commit -m "feat(cloud): uid-keyed nftables egress filter — renderer, artifacts, netns proof"`

### Task 12: Worker tool seam — run_shell + file tools + tool-call loop v1

**Files:**
- Create: `cloud/apps/worker/src/tools/{types.ts,registry.ts,shellTool.ts,confinement.ts,fileTools.ts,systemPrompt.ts}`
- Modify: `cloud/apps/worker/src/{liteLlm.ts,runProcessor.ts,main.ts,index.ts}`, `cloud/packages/shared/src/events.ts` (union += `tool_started`, `tool_completed` + zod enum), `cloud/packages/queue/src/queues.ts` (`AgentRunJob.tier?`), `cloud/apps/gateway/src/routes/messages.ts` (pass `tier: user.tier` in the job payload)
- Test: `cloud/apps/worker/src/tools/{confinement.test.ts,fileTools.test.ts,registry.test.ts}`, extend `cloud/apps/worker/src/{liteLlm.test.ts,runProcessor.test.ts}`

**Interfaces:**
- Consumes: `SandboxManager`/`SandboxHandle`/`ExecResult`/`REFUSAL_MESSAGE` (`@ovid/sandbox`), `RunDeps`/`ModelTransport` (P1 Task 9), `EventLog`.
- Produces (**the P3 roster seam — import verbatim**):

```ts
// apps/worker/src/tools/types.ts
export interface ToolResult { content: string; isError: boolean; }
export interface ModelToolSpec { type: "function"; function: { name: string; description: string; parameters: Record<string, unknown> } } // defined ONCE here; liteLlm.ts and registry.ts both import it
export interface ToolContext { sandbox: SandboxHandle; userId: string; sessionId: string; runId: string;
  emitEvent(type: SessionEventType, payload: Record<string, unknown>): Promise<void>; }
export interface AgentTool { readonly name: string; readonly description: string;
  readonly parameters: Record<string, unknown>;            // JSON Schema object sent to the model
  execute(input: unknown, ctx: ToolContext): Promise<ToolResult>; } // validates input itself (zod); invalid input → {content:"invalid_input: …", isError:true}, never throws for user errors

// apps/worker/src/tools/registry.ts
export interface ToolRegistry { readonly tools: AgentTool[]; get(name: string): AgentTool | undefined; specs(): ModelToolSpec[]; } // specs() sorted by name (prompt-cache-stable prefix, spec §6.1)
export function createToolRegistry(): ToolRegistry; // v1 roster EXACTLY: run_shell, read_file, write_file, edit_file, glob_files, grep_files — P3 extends this list, nothing else

// apps/worker/src/tools/confinement.ts
export class ConfinementError extends Error {}
export async function resolveConfined(root: string, p: string): Promise<string>; // accepts workspace-relative or "/workspace/…"-prefixed; rejects absolute-after-strip and any ".." escape; realpath of nearest existing ancestor must stay within realpath(root)+"/" (symlink escape proof); returns the HOST path. File tools map ConfinementError → {content: "confined: <path> is outside the workspace", isError: true} (exact prefix pinned — Task 14 asserts it)

// apps/worker/src/tools/systemPrompt.ts
export const SYSTEM_PROMPT_V1: string; // constant: identity + "commands run in an isolated Linux workspace at /workspace (ubuntu noble; node/python/git/pnpm/uv preinstalled)" + the heavy-compilation refusal notice + one line per tool
export const MAX_TOOL_ROUNDS = 50;
export const TOOL_RESULT_CAP_BYTES = 32_768;   // run_shell content cap ("[truncated]" suffix)
export const TOOL_EVENT_CONTENT_CAP = 8_192;   // tool_completed event payload cap

// liteLlm.ts (extended, v0-compatible)
export interface ToolCall { id: string; name: string; arguments: string } // arguments = raw JSON string from the model
export interface ChatMessage { role: "system" | "user" | "assistant" | "tool"; content: string; toolCalls?: ToolCall[]; toolCallId?: string; }
export interface ModelTransport { stream(req: { baseUrl; apiKey; model; messages: ChatMessage[]; tools?: ModelToolSpec[] }, h: StreamHandlers, signal: AbortSignal): Promise<{ finishReason: string | null; toolCalls: ToolCall[] }>; } // ModelToolSpec imported from tools/types.ts
// SSE aggregation: delta.tool_calls[] merged by `index` (id/name once, arguments concatenated); wire mapping message.tool_calls / role:"tool" + tool_call_id
```

`runProcessor.ts` v1 semantics (pin): `RunDeps` gains `sandbox: SandboxManager; tools: ToolRegistry` (both **required** — `main.ts` is wired in THIS task so the workspace compiles at commit: `loadSandboxConfig` → `resolveRootfs` (boot fails loudly with `RootfsUnavailable` when missing — the systemd unit must not run before rootfs install) → `createCgroupManager(...)` + `init()` (leaf-first, Task 6) → `selectQuotaBackend` → `createSetuidLauncher` (or rootmap per `config.launch`) → `createSandboxManager({..., allocateUid: (u) => users.allocateSandboxUid(db, u)})` → `manager.recover()` → RunDeps `{sandbox: manager, tools: createToolRegistry()}`; shutdown: `manager.close()` before the existing drain. Task 13 only adds the pty bridge on top of this wiring). After claim + key + history load: `handle = await deps.sandbox.attach(userId, { tier: job.data.tier })` — `SandboxAdmissionError`/`SandboxCapacityError`/`RootfsUnavailable` ⇒ `run_failed {code:"sandbox_unavailable", message}` + `finish('failed')` (no throw). Messages = `[system SYSTEM_PROMPT_V1, ...history]`. Loop rounds 1..`MAX_TOOL_ROUNDS`: `transport.stream({...req, tools: deps.tools.specs()})` with the v0 delta/flush/retry machinery unchanged; on resolve with `toolCalls.length > 0`: append the assistant message (content + toolCalls) to the in-run array, then per call **sequentially**: emit `tool_started {runId, callId, name, input}` (input = JSON.parse(arguments), or `{raw: arguments}` on parse failure) → `registry.get(name)?.execute(input, toolCtx)` (unknown name → `{content:"unknown_tool: <name>", isError:true}`) → append `{role:"tool", toolCallId, content}` → emit `tool_completed {runId, callId, name, isError, content: content.slice(0, 8192), truncated: content.length > 8192}`; continue to the next round. No tool calls → v0 completion path (persist assistant text, `message_completed`, `run_completed`). Rounds exhausted → `run_failed {code:"tool_rounds_exhausted"}`. `run_shell` tool: input `{command: string, timeoutMs?: number}` (clamp default 120_000/max 600_000); `blocked` result ⇒ `ctx.emitEvent("system_note", {code:"command_blocked", message: REFUSAL_MESSAGE, command})` **and** return `{content: REFUSAL_MESSAGE, isError: true}` (spec §7: refusal is the tool result + a user system note); otherwise content = `stdout` + `\n[stderr]\n…` when non-empty + `\n[exit <code>]`, capped, `isError = exitCode !== 0 || timedOut`. File tools operate **host-side** on `ctx.sandbox.workspaceDir` through `resolveConfined` (no jail spawn): `read_file {path}` → utf8 content ≤ 256 KiB (`[truncated]` suffix; NUL in first 8 KiB → isError "binary file"); `write_file {path, content}` → mkdir -p parents, returns `wrote <n> bytes`; `edit_file {path, oldString, newString, replaceAll?}` → exactly-one-match rule (0 or >1 without replaceAll → isError naming the count); `glob_files {pattern, path?}` → glob→regex translation (`**`→`.*`, `*`→`[^/]*`, `?`→`[^/]`, `{a,b}`→`(a|b)`, everything else escaped), walk skipping symlinks, sorted relative paths ≤ 1000 + `[truncated]`; `grep_files {pattern, path?, maxResults?}` → JS RegExp (invalid → isError), files ≤ 1 MiB, skip binaries, lines `path:line:text` (1-based, text ≤ 500 chars) ≤ maxResults (default 200).

- [ ] **Step 1: Write failing tests.** `liteLlm.test.ts` additions (local SSE server): tool-call deltas split mid-JSON across frames aggregate to exact `ToolCall[]` (two parallel calls, index-merged, arguments reassembled byte-identical); `finishReason:"tool_calls"`; a text-only stream still yields `toolCalls: []` (v0 tests untouched and green). `confinement.test.ts`: tmpdir root with a symlink `evil → /etc` and `sub/`; every PATH_ESCAPE_CORPUS entry (Task 4) + `evil/passwd` rejects `ConfinementError`; `sub/ok.ts`, `/workspace/sub/ok.ts` resolve inside root. `fileTools.test.ts`: write→read roundtrip; read cap + binary rejection; edit 0/1/2-match behaviors + replaceAll; glob `**/*.ts` finds nested, not `node_modules`-external misses, ≤ cap; grep line numbers, maxResults, invalid regex isError. `registry.test.ts`: specs sorted by name; roster is exactly the six names. `runProcessor.test.ts` additions (stub transport scripting rounds, stub `SandboxManager` with a fake handle over a tmpdir workspace — file tools hit the real tmpdir): happy tool run → event sequence `run_started, tool_started, tool_completed, message_delta*, message_completed, run_completed` and round-2 transport messages include the `role:"tool"` message; blocked `gradle build` → tool_completed `isError:true` content === REFUSAL_MESSAGE **exactly** + one `system_note` event + fake `exec` never invoked; attach rejects `SandboxAdmissionError` → `run_failed {code:"sandbox_unavailable"}`, run failed, job completes (no throw); transport always returning a tool call → `tool_rounds_exhausted` after exactly 50 rounds; tool event content > 8 KiB → `truncated:true` and payload ≤ cap.
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** (incl. shared events union + queue `tier?` + gateway payload one-liner + the `main.ts` SandboxManager wiring pinned above — `main.ts` stays untested-thin per the P1 composition-root convention, Task 14's e2e exercises it; regenerate nothing — `tier` is optional so old payloads parse) → **Step 4: Verify pass.** `cd cloud && pnpm -r build && pnpm -r test` (all packages green — shared/queue/gateway suites must not regress).
- [ ] **Step 5: Commit.** `git add cloud && git commit -m "feat(cloud): worker tool seam — run_shell + file tools, tool-call loop v1"`

### Task 13: Terminal over WS — shared pty protocol, worker bridge, gateway `pty` channel

**Files:**
- Create: `cloud/packages/shared/src/pty.ts`, `cloud/apps/gateway/src/wsPty.ts`, `cloud/apps/worker/src/ptyBridge.ts`
- Modify: `cloud/packages/shared/src/{ws.ts,index.ts}` (pty ops), `cloud/apps/gateway/src/{ws.ts,app.ts,index.ts}` (dispatch + wiring), `cloud/apps/worker/src/{main.ts,index.ts}` (SandboxManager + bridge wiring)
- Test: `cloud/packages/shared/src/pty.test.ts`, `cloud/apps/gateway/src/wsPty.test.ts`, `cloud/apps/worker/src/ptyBridge.test.ts`

**Interfaces:**
- Consumes: `SandboxManager`/`PtySession`/`RingChunk` (Tasks 8/9), Redis (redis-q), `WsClientMsg`/`WsServerMsg` machinery (P1 Task 8), `sessions.get` ownership rule.
- Produces (P3/P8 client contract — import verbatim):

```ts
// packages/shared/src/pty.ts
export function ptyCtlChannel(ptyId: string): string;  // `pty:ctl:${ptyId}`
export function ptyOutChannel(ptyId: string): string;  // `pty:out:${ptyId}`
export function ptyRegistryKey(ptyId: string): string; // `pty:reg:${ptyId}` (Redis HASH: userId, sessionId, cols, rows, createdAt)
export const PTY_CTL_PATTERN = "pty:ctl:*";            // worker PSUBSCRIBE
export const PTY_REGISTRY_TTL_MS = 90_000; export const PTY_HEARTBEAT_MS = 30_000; // both injectable in tests
export type PtyCtlMsg = { type: "open"; ptyId: string; userId: string; sessionId: string; cols: number; rows: number; replyChannel: string }
  | { type: "attach"; ptyId: string; lastOffset: number | null; replyChannel: string }
  | { type: "input"; ptyId: string; data: string /* base64 */ }
  | { type: "resize"; ptyId: string; cols: number; rows: number }
  | { type: "close"; ptyId: string };
export type PtyReplyMsg = { type: "opened"; ptyId: string; sessionId: string }
  | { type: "opened_failed"; ptyId: string; code: "sandbox_busy" | "sandbox_unavailable" | "internal"; message: string }
  | { type: "attach_reply"; ptyId: string; truncated: boolean; chunks: RingChunkWire[]; endOffset: number }
  | { type: "attach_failed"; ptyId: string; code: "pty_gone" | "internal"; message: string };
export type PtyOutMsg = { type: "output"; ptyId: string; offset: number; data: string /* base64 */ } | { type: "exit"; ptyId: string; exitCode: number | null };
export interface RingChunkWire { offset: number; data: string }
export const ptyCtlMsg: z.ZodType<PtyCtlMsg>; export const ptyReplyMsg: z.ZodType<PtyReplyMsg>; export const ptyOutMsg: z.ZodType<PtyOutMsg>; // + parse fns

// packages/shared/src/ws.ts — union additions (discriminant "op")
// client: {op:"pty_open"; sessionId; cols; rows} | {op:"pty_attach"; ptyId; lastOffset?: number|null} | {op:"pty_input"; ptyId; data} | {op:"pty_resize"; ptyId; cols; rows} | {op:"pty_close"; ptyId}
// server: {op:"pty_opened"; ptyId; sessionId} | {op:"pty_attached"; ptyId; truncated} | {op:"pty_output"; ptyId; data; offset} | {op:"pty_exit"; ptyId; exitCode: number|null}
// existing error op gains optional ptyId. Validation: cols/rows integers 1..500; data matches /^[A-Za-z0-9+/=]*$/ and decodes ≤ 16_384 bytes; lastOffset non-negative integer or null.

// apps/gateway/src/wsPty.ts
export interface PtyBridge {
  open(ptyId: string, meta: { userId: string; sessionId: string; cols: number; rows: number }, timeoutMs: number): Promise<void>; // resolves on `opened`; rejects PtyBridgeError(code) on opened_failed/timeout
  attach(ptyId: string, lastOffset: number | null, onOut: (m: PtyOutMsg) => void, timeoutMs: number): Promise<{ truncated: boolean; chunks: RingChunkWire[]; endOffset: number; detach(): Promise<void> }>; // SUBSCRIBES pty:out FIRST, then publishes the attach request (events-channel ordering rule); live chunks with offset < snapshot endOffset are dropped inside the bridge (offset dedupe — Review Focus #3)
  send(ptyId: string, msg: { type: "input"; data: string } | { type: "resize"; cols: number; rows: number } | { type: "close" }): Promise<void>;
  lookup(ptyId: string): Promise<{ userId: string; sessionId: string } | null>; // registry HGETALL → null when missing/expired
}
export class PtyBridgeError extends Error { constructor(readonly code: string, message: string) }
export function createRedisPtyBridge(redis: Redis, opts?: { replyTimeoutMs?: number }): PtyBridge;
export const PTY_OPEN_TIMEOUT_MS = 30_000; export const PTY_REPLY_TIMEOUT_MS = 10_000;

// apps/worker/src/ptyBridge.ts
export interface WorkerPtyDeps { sandbox: SandboxManager; redis: Redis; }
export function startWorkerPtyBridge(deps: WorkerPtyDeps, opts?: { ttlMs?: number; heartbeatMs?: number }): Promise<() => Promise<void>>; // PSUBSCRIBE pty:ctl:*; returns stop()
```

Gateway `ws.ts` dispatch (extends the P1 handler; `WsDeps` gains `pty: PtyBridge`; `GatewayDeps` gains `pty: PtyBridge`; `index.ts` main wires `createRedisPtyBridge(redisQ)`): `pty_open` → `sessions.get(sessionId, uid)` ownership (null ⇒ `{op:"error",code:"forbidden",sessionId}`) → `ptyId = newId()` → `bridge.open(ptyId, {userId: uid, sessionId, cols, rows}, PTY_OPEN_TIMEOUT_MS)` → `bridge.attach(ptyId, null, forward, PTY_REPLY_TIMEOUT_MS)` → send `{op:"pty_opened", ptyId, sessionId}` then live `pty_output` frames; `PtyBridgeError` ⇒ `{op:"error", code, ptyId}` (connection survives). `pty_attach` → `bridge.lookup` → `userId !== uid` or null ⇒ `{op:"error",code:"forbidden",ptyId}` → attach(lastOffset ?? null) → `{op:"pty_attached", ptyId, truncated}` → snapshot chunks as `pty_output` frames → live frames. `pty_input`/`pty_resize`/`pty_close` → allowed when this connection opened/attached that ptyId, else `lookup` ownership check → `bridge.send`. `pty_exit` from the bridge → forward `{op:"pty_exit"}` and drop the sub. Socket close → `detach()` all pty subs (**ptys survive** — reconnect re-attaches; only explicit `pty_close` or worker shutdown kills them). Worker side: `open` → `sandbox.attach(userId)` (errors map: `SandboxAdmissionError`→`sandbox_busy`, `SandboxCapacityError`/`RootfsUnavailable`→`sandbox_unavailable`) → `handle.createPty(...)` with handlers publishing `{type:"output", offset, data}` per ring chunk to `pty:out` and `{type:"exit"}` + registry HDEL on exit → HSET registry + PEXPIRE + 30 s heartbeat refresh → publish `opened` to replyChannel. `attach` → registry/pty missing ⇒ `attach_failed pty_gone`; else `ring.since(lastOffset)` → `attach_reply`. Worker `main.ts` (Task 12 already wired the SandboxManager chain): this task adds `startWorkerPtyBridge({ sandbox: manager, redis: redisQ })` after `manager.recover()`; shutdown order becomes: stop bridge → `manager.close()` → existing drain.

- [ ] **Step 1: Write failing tests.** `shared/pty.test.ts`: every msg variant parses; `{type:"nope"}` throws; ws pty ops parse; `cols: 0`/`cols: 501` reject; `data` with non-base64 chars rejects; 20 KiB base64 data rejects; server/client unions still round-trip (P1 tests green). `ptyBridge.test.ts` (worker side; TEST_REDIS_URL-gated; stub SandboxManager whose fake handle creates ring-backed fake PtySessions, ttl/heartbeat overrides 300/100 ms): publish `open` ctl → `opened` reply on replyChannel + registry hash fields exact + TTL > 0; fake pty data → `pty:out` receives `{type:"output", offset, data}` with monotonic offsets; kill → `exit` published + registry key gone (poll); `attach` on live pty → `attach_reply` chunks equal `ring.since(lastOffset)` and never re-deliver covered bytes; `attach` unknown ptyId → `attach_failed pty_gone`; `input` → fake pty received the decoded buffer; `resize` → recorded; admission: stub attach throwing `SandboxAdmissionError` → `opened_failed` code `sandbox_busy`; heartbeat: registry TTL refreshed (observe PEXPIRE rise). `wsPty.test.ts` (gateway side; real redis; a test harness that plays the worker protocol): `open` resolves on ack; ack `opened_failed` → `PtyBridgeError.code` passes through; no ack within `replyTimeoutMs` (override 200 ms) → rejects; **ordering/dedupe** (Review Focus #3): harness subscribes to the ctl channel and, between the gateway's `pty:out` SUBSCRIBE and its `attach_reply`, publishes a live chunk fully covered by the snapshot → `onOut` receives it exactly once (snapshot wins), and a chunk beyond `endOffset` arrives; `lookup` returns registry fields / null. Gateway `ws` integration (extend `ws.test.ts` harness with a stub `PtyBridge`): `pty_open` happy → frames `pty_opened` then `pty_output`s in order; other user's session → forbidden (no bridge call); `pty_attach` with a registry owned by another uid → `{op:"error",code:"forbidden",ptyId}`; `pty_input` on a pty never opened/attached on this conn and unknown to `lookup` → forbidden; malformed `pty_resize` (`cols:"x"`) → `bad_message`; socket close → stub `detach` called for every attached pty and `send close` NOT called (ptys survive).
- [ ] **Step 2: Run to verify fail** → **Step 3: Implement** shared/pty + ws unions, gateway wsPty + ws dispatch + app/index wiring, worker ptyBridge + main wiring → **Step 4: Verify pass.** `cd cloud && pnpm -r build && TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm -r test`.
- [ ] **Step 5: Commit.** `git add cloud && git commit -m "feat(cloud): terminal over WS — shared pty protocol, worker bridge, gateway pty channel"`

### Task 14: e2e — agent tool run + WS terminal (stubbed everywhere; real-jail host-gated)

**Files:**
- Create: `cloud/apps/e2e/src/{tools.test.ts,realjail.test.ts}`
- Modify: `cloud/apps/e2e/package.json` (dep `@ovid/sandbox workspace:*`)

**Interfaces:**
- Consumes: `buildGateway` + pty wiring (Task 13), `createAgentRunProcessor`/`createToolRegistry` (Task 12), `createSandboxManager` + friends (Tasks 2–11), P1 spine harness (`spine.test.ts` composition pattern: real gateway + real worker in-process, mock LiteLLM SSE server, test auth, real Postgres/Redis).
- Produces: the P2 regression harness P3 extends (fake-sandbox pattern for tool-flow tests; real-jail pattern for acceptance).

- [ ] **Step 1: Write `tools.test.ts`** (always-runs; spine.test.ts harness + a `FakeSandboxManager`: `attach` returns a handle whose `workspaceDir` is a real mkdtemp and whose `exec` records commands and returns canned `{exitCode:0, stdout:"hi\n", ...}`; mock LiteLLM scripted per test). Flows (one `it` each): (a) **tool run**: script = round 1 `tool_calls [run_shell {command:"echo hi > out.txt"}]`, round 2 `tool_calls [write_file {path:"notes.md", content:"# x"}]`, round 3 text "done" → WS event stream asserts exact order `run_started, tool_started(run_shell), tool_completed, tool_started(write_file), tool_completed, message_delta+, message_completed, run_completed`; `notes.md` exists in the fake workspace with content `# x`; GET messages shows user + "done"; (b) **blocked command**: script calls `run_shell {command:"./gradlew assembleDebug"}` then finishes → `tool_completed.content === REFUSAL_MESSAGE` verbatim, `isError:true`, and exactly one `system_note` event with `code:"command_blocked"` reaches the WS client; fake `exec` recorded nothing; (c) **sandbox unavailable**: FakeSandboxManager attach rejects `SandboxAdmissionError` → `run_failed {code:"sandbox_unavailable"}`, run row failed, job completed (queue not stuck — a second run with a working fake proceeds); (d) **file confinement**: script calls `read_file {path:"../../etc/passwd"}` → tool_completed isError, content starts with the pinned prefix `confined:` (Task 12), workspace untouched.
- [ ] **Step 2: Write `realjail.test.ts`** (`describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg) || !process.env.OVID_ROOTFS)`; real `createSandboxManager` — tmp `workspacesRoot`, real cgroups base `ovid-probe-e2e-{pid}`, noop-safe quota, real launcher/rootfs; same in-process gateway+worker composition; mock LiteLLM scripts real commands; full cleanup: `manager.close()`, rm workspaces tmp, rmdir probe cgroups). Flows: (a) **echo + file write through the stack** (spec §14 P2 "working software"): script = `run_shell {command:"echo hello > /workspace/out.txt && cat /workspace/out.txt"}` then `write_file {path:"agent.txt", content:"written-by-agent"}` then text → tool_completed(run_shell) content contains `hello`; host file `{workspacesRoot}/{uid}/workspace/out.txt` exists **owned by the sandbox uid**; `agent.txt` exists; events streamed over WS in order; (b) **WS terminal full chain**: connect WS → `pty_open {sessionId, cols:100, rows:30}` → `pty_opened` → `pty_input "echo ptytest-$rand\n"` (base64) → `pty_output` frames reassemble to contain `ptytest-$rand` → `pty_resize {cols:120, rows:40}` → `pty_input "stty size\n"` → output contains `40 120` → **disconnect, reconnect, `pty_attach {ptyId, lastOffset:null}`** → `pty_attached` + snapshot chunks contain `ptytest-$rand` (repaint, Review Focus #3 at integration level) → `pty_close` → `pty_exit`; (c) **blocked in real jail**: `run_shell {command:"bash -c 'gradle build'"}` → refusal copy (layer 1) AND via `pty_input "gradle\n"` → shim refusal copy in output (layer 2).
- [ ] **Step 3: Run.** `cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/e2e test` → tools flows PASS (realjail skipped without the host env); then `OVID_SANDBOX_HOST_TESTS=1 OVID_ROOTFS=/tmp/ovid-rootfs-test TEST_DATABASE_URL=… TEST_REDIS_URL=… sudo -E pnpm --filter @ovid/e2e test` → all PASS. Wiring-only fixes allowed in this task (unit suites must stay green and unmodified in behavior).
- [ ] **Step 4: Full check.** `cd cloud && pnpm -r build && pnpm -r test` → all green.
- [ ] **Step 5: Commit.** `git add cloud/apps/e2e && git commit -m "test(cloud): P2 e2e — agent tool run (stubbed + real jail) and WS terminal flows"`

### Task 15: Isolation acceptance suite (the P2 verification deliverable)

**Files:**
- Create: `cloud/packages/sandbox/src/verification/isolation.test.ts`
- Modify: `cloud/packages/sandbox/src/corpora.ts` (extend entries as gaps surface — the corpora stay the single source)
- Test: the suite itself (host-gated in full)

**Interfaces:**
- Consumes: `createSandboxManager` + real launcher/cgroups (Tasks 7/8), the corpora (Task 4 — the single source; this suite never re-lists commands), `runEgressNetnsProof` + `renderCli` (Task 11 netTestKit/net.ts), the rootfs artifact (Task 3), `REFUSAL_MESSAGE` + `SYSTEM_PROMPT_V1` (Tasks 4/12). The tool-side confinement corpus stays pinned in Task 12's portable tests (packages never import apps) — this suite proves the **jail-side** guarantees; the suite header comment cross-references them.
- Produces: the phase acceptance gate — one command that proves spec §7/§11 on the real host.

Suite contents (one `it` per numbered guarantee; `describe.skipIf(!hostTestsAvailable() || !jailMechanismAvailable(cfg))`; manager with tmp workspaces root, probe cgroup base, real launcher, limits overridden small where hogs run; setup creates one env for a fixed test uid; afterAll destroys + removes everything):
1. **Path confinement (jail)**: for each PATH_ESCAPE_CORPUS entry → `execOnce({command: "cat <entry>"})` exits ≠ 0 or output empty; writes to `/`, `/etc`, `/usr`, `/opt`, `/root/..` fail EROFS; `/workspaces` and `/opt` do not exist inside; only `/workspace`, `/root`, `/tmp` writable.
2. **Blocked commands (layer 1 + layer 2)**: every BLOCKED_COMMAND_CORPUS entry through `execOnce` — `expect:"layer1"` → `blocked:true` + refusal exact; `expect:"shim"` → runs, stdout contains REFUSAL_MESSAGE verbatim, exit 126; direct in-terminal forms: spawn a real PTY, write `make\n`, `gradle build\n`, `bash -c 'gcc x.c'\n` → ring contains the refusal copy each time (Review Focus #1).
3. **Allowlist**: every ALLOWED_COMMAND_CORPUS entry through `execOnce` → `blocked:false` (spawn success, not exit code — missing binaries are fine).
4. **Uid map + ownership**: `/proc/self/uid_map` = `0 {uid} 1`; `id -u` = 0 inside; files created inside land host-owned by `{uid}`; sandbox write to its own `/etc/passwd` fails (RO) and the HOST `/etc/passwd` is byte-identical before/after the whole suite (hash it in beforeAll/afterAll).
5. **Pid isolation**: test-runner pid not visible in jail `ps -e`; `/proc/self/cgroup` inside contains `sandbox-{uid}`.
6. **Resource caps** (Review Focus #4, small-limit overrides): memory hog → exit 137 + `memory.events oom_kill ≥ 1`; in-jail fork bomb written to a file and executed (`sh bomb.sh` — bypasses layer 1 by design) → contained: `pids.events max ≥ 1`, suite's own subsequent spawn still works, host load unaffected; job tree-kill leaves zero marker processes.
7. **Egress** (Review Focus #5): `runEgressNetnsProof` asserts (rc 28, counter > 0, root rc 0, 169.254.169.254 counter) — shared kit, disposable netns; PLUS drift check: `renderCli({...env with OVID_PUBLIC_IP:"203.0.113.7"})` output === committed golden ruleset file content (regenerate golden when the renderer changes intentionally).
8. **Die-with-parent**: launcher-parent SIGKILL → jail process gone within 2 s (unique marker).
9. **Rootfs hygiene** (portable `describe`, gated only on an extracted rootfs path): no `javac`, `java`, `gcc`, `g++`, `make`, `gradle`, `kotlinc` binaries anywhere under the rootfs (`walk + basename set`); all 13 shims present in `usr/local/bin` and each unconditional shim's stdout string === `REFUSAL_MESSAGE`; `usr/local/bin/ovid` exists.
10. **Copy parity**: `REFUSAL_MESSAGE` appears byte-identical in `policy.ts`, every shim file, and `SYSTEM_PROMPT_V1`'s refusal notice quotes the same sentence (grep-style file reads — fails loudly on any copy drift).

- [ ] **Step 1: Write the suite** (expected to pass against Tasks 3–13 as built — any failure is a real isolation bug: fix the owning module, never weaken an assertion; record any corpus extension in corpora.ts so unit suites inherit it).
- [ ] **Step 2: Run (host).** `cd cloud && OVID_SANDBOX_HOST_TESTS=1 OVID_ROOTFS=/tmp/ovid-rootfs-test sudo -E pnpm --filter @ovid/sandbox test` — Expected: all PASS. Then run the portable half without the host env → skips cleanly, workspace green: `pnpm -r test`.
- [ ] **Step 3: Remnant audit.** `ls /sys/fs/cgroup | grep ovid-probe` → empty; `ip netns list | grep ovid-spike` → empty; `docker ps -a --filter name=ovid-spike --format '{{.Names}}'` → empty; tmp workspaces removed; `grep -c 200 /etc/passwd`-style uid check: no host passwd entries created in 200000–209999 (`awk -F: '$3>=200000 && $3<=209999' /etc/passwd` → empty).
- [ ] **Step 4: Commit.** `git add cloud/packages/sandbox && git commit -m "test(cloud): isolation acceptance suite — confinement, blocked commands, uid map, egress"`

### Task 16: Deploy artifacts — worker compose→systemd transition, slice, nft/workspaces install, docs (activation owner-gated)

**Files:**
- Create: `cloud/deploy/systemd/{ovid-sandboxes.slice,ovid-worker.service}`, `cloud/deploy/workspaces/setup-workspaces.sh`, `cloud/deploy/worker.env.example`
- Modify: `cloud/deploy/docker-compose.yml` (drop `worker` service; redis-q += `ports: ["127.0.0.1:${REDIS_Q_HOST_PORT:-6391}:6379"]`; add `net-proxy-pg` + `net-proxy-mint` socat services on the `internal` network publishing `127.0.0.1:5434→ovid-gateway-postgres-1:5432` and `127.0.0.1:6392→ovid-gateway-redis-1:6379`; pinned `alpine/socat` tag resolved at artifact time and recorded), delete `cloud/deploy/Dockerfile.worker`, `cloud/deploy/.env.example` (new host-port vars + a "worker moved to systemd" pointer), `cloud/deploy/DEPLOY.md` (new §11 P2 activation + §5/§10 corrections), `cloud/deploy/HARDENING.md` (new item H + coverage-map rows)
- Consumes: Task 11 (`install-nft.sh`, nft unit), Task 3 (`install.sh`, `smoke-jail.sh`), Task 13 (`startWorkerPtyBridge`-wired `dist/main.js`).

**Interfaces:**
- Produces: the activation runbook (DEPLOY.md §11) and the capacity envelope on the wire:

```ini
# cloud/deploy/systemd/ovid-sandboxes.slice
[Unit]
Description=Ovid sandbox parent slice (protects gateway/DB — spec §7.3, revised 8c/22GB envelope)
[Slice]
CPUQuota=600%
MemoryMax=10G
MemorySwapMax=0
```

```ini
# cloud/deploy/systemd/ovid-worker.service
[Unit]
Description=Ovid cloud worker (agent runs + SandboxManager)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Slice=ovid-sandboxes.slice
User=root            # research §8.1: root needed for cgroup.procs pre-setuid attach, /workspaces binds, nftables adjacency; de-rooting path (Delegate=yes + leaf-first, research §3 TEST C) documented in HARDENING item H
MemoryMax=4096M      # G5 (P6 pre-flight ruling): caps the worker unit INSIDE the 10G slice — worker proper ~2G + P6 browser pool ~2G run under this unit; jail envs get the remaining ≥6G of the slice; slice MemoryMax=10G and the Global-Constraints envelope arithmetic are unchanged
WorkingDirectory=/opt/ovid-cloud/repo/cloud
EnvironmentFile=/opt/ovid-cloud/worker.env
ExecStart=/usr/bin/node apps/worker/dist/main.js
Restart=always
RestartSec=5
TimeoutStopSec=35    # worker drains SIGTERM in ≤30 s (P1)
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
```

`worker.env.example` (host worker reaches the compose network over loopback proxies — the live `ovid-gateway` stack is untouched): `DATABASE_URL=postgres://ovid_cloud:…@127.0.0.1:5434/ovid_cloud`, `REDIS_Q_URL=redis://:…@127.0.0.1:6391`, `REDIS_MINT_URL=redis://:…@127.0.0.1:6392/2`, `OVID_LITELLM_BASE=http://127.0.0.1:4000` (litellm already publishes on host loopback — DEPLOY.md §0), `OVID_DEFAULT_MODEL`, `NODE_ENV=production`, plus every `OVID_*` sandbox var with its Task 2 default and `OVID_PUBLIC_IP=CHANGE_ME` (this box: `148.113.44.36`). `setup-workspaces.sh`: idempotent; `fallocate -l ${OVID_WORKSPACES_SIZE_GB:-32}G /opt/ovid-workspaces.img` → `mkfs.xfs` → fstab line `/opt/ovid-workspaces.img /workspaces xfs loop,defaults,prjquota,nofail 0 2` → `mount -a` → `install -d -m 755 /workspaces/users` → gate `stat -fc %T /workspaces` = `xfs` and `mount | grep prjquota`.

- [ ] **Step 1: Write the artifacts** (units, setup-workspaces.sh, worker.env.example, compose edits — keep the P1 comment style; compose `docker compose config -q` must pass with a scratch env).
- [ ] **Step 2: Write DEPLOY.md §11 "P2 activation (owner-run, ordered)"** with per-step gates + rollbacks: (1) prerequisites `apt-get install -y bubblewrap zstd xfs-progs util-linux` (bwrap likely already present from Task 1) + repo build on host (`pnpm install --frozen-lockfile && pnpm -r build` — node-pty compiles); (2) rootfs: `build.sh` → `install.sh` → `smoke-jail.sh` gate (versions + shim refusal); (3) `setup-workspaces.sh` gate (`xfs` + `prjquota`); (4) nft: fill `OVID_PUBLIC_IP` → `install-nft.sh` gate (`nft list table inet ovid_sandbox`, counters zeroed); (5) units: install slice + worker unit, `systemd-analyze verify`, `daemon-reload`; (6) compose transition: if a P1 compose `worker` is running → `docker compose stop worker && docker compose rm -f worker` (queue data untouched); `docker compose up -d` (picks up redis-q port + proxies) → gates: `curl -sf 127.0.0.1:8082/cloud/v1/health` ok, `redis-cli -p 6391 ping` (auth'd) PONG, `psql -h 127.0.0.1 -p 5434 …` connects; (7) author `/opt/ovid-cloud/worker.env` (chmod 600) → `systemctl enable --now ovid-worker ovid-sandbox-nft` → gates: `systemctl status` active, `journalctl -u ovid-worker` shows `consuming agent-runs` and no `RootfsUnavailable`, `cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/cgroup.subtree_control` shows `cpu memory pids` (leaf-first bootstrap ran), `cat /sys/fs/cgroup/ovid-sandboxes.slice/cpu.max`-equivalent quota check via `systemctl show ovid-sandboxes.slice -p CPUQuotaPerSecUSec` = 6s, `systemctl show ovid-worker -p MemoryMax` = 4294967296 (4G unit cap — G5); (8) functional smoke (owner): real message whose run executes `run_shell echo` + `write_file` (thin client or the Task 14 harness pointed at production), watch `tool_started/tool_completed` on the WS event channel, open a terminal via `pty_open`. Rollback per step: systemctl disable --now ovid-worker (+ optional `nft delete table inet ovid_sandbox`), compose worker service restorable from git history, `/workspaces` umount + fstab line removal, rootfs `current` symlink back-flip to the previous revision. **Update §5/§10**: worker is no longer a compose service (redeploy = `git pull && pnpm -r build && systemctl restart ovid-worker`).
- [ ] **Step 3: Write HARDENING.md item H "Sandbox surface (P2)"** (checkbox + exact-command rows, matching the file's item A–G style): uid range 200000–209999 reserved — verify no human/system accounts land in it (`awk -F: '$3>=200000 && $3<=209999 {print}' /etc/passwd` → empty; re-run after any useradd tooling change); AppArmor mechanism state — mirror `MECHANISM.md` DECISION here, if branch b: `/etc/apparmor.d/ovid-sandbox` loaded (`aa-status | grep ovid-sandbox`) and the kernel restriction stays ON (`sysctl kernel.apparmor_restrict_unprivileged_userns` = 1 — never disable it); nft table `ovid_sandbox` — `nft list table inet ovid_sandbox` matches the rendered golden (Task 15 §7), review counters monthly (`nft list ruleset | grep -A2 counter` — nonzero drop counters are expected, growth after quiet periods is a signal); worker runs as **root** in `ovid-sandboxes.slice` — rationale + the de-rooting trigger (research §3 TEST C `Delegate=yes` pattern) recorded as a review item; loopback proxies 5434/6391/6392 — `ss -tlnp | grep -E '5434|6391|6392'` shows `127.0.0.1`-only binds, each backend requires its password; `/workspaces` budget — `df -h /workspaces`, alert at 80 % (owner: any external pinger from item F), `OVID_MAX_WARM_GB` tuning note; rootfs rebuild cadence — monthly or on CVE scan: `build.sh` → `smoke-jail.sh` → `install.sh` (atomic symlink, 2 revisions kept, instant rollback); per-env caps reference table (cpu.max 100000 100000 / memory.max 536870912 / memory.swap.max 0 / pids.max 64 / slice CPUQuota=600 % MemoryMax=10G / worker unit MemoryMax=4096M — worker ~2G + P6 browser pool ~2G inside the slice / quotas 500MB+2GB). Add the spec §11 coverage-map rows: jail+uid+RO-rootfs → Tasks 5/7/8 + item H; egress → Task 11 + item H; cgroup caps → Task 6 + item H; "no host /proc view" → Task 15 §5. Cross-link DEPLOY.md §11 from item H and from §0 facts (8 vCPU/22 GB box, `/workspaces` absent until step 3).
- [ ] **Step 4: Dry validation (autonomous).** `docker compose -f cloud/deploy/docker-compose.yml config -q` (scratch env vars) → OK; `bash -n` every script → OK; `systemd-analyze verify cloud/deploy/systemd/ovid-*.{slice,service}` → no errors (warnings acceptable, record them); render the nft ruleset with `OVID_PUBLIC_IP=203.0.113.7` and `nft -c -f` it (check mode, root, no mutation) → `OK`; `grep -rn "Dockerfile.worker" cloud/deploy` → only historical mentions; DEPLOY.md/HARDENING.md internal links resolve (manual read-through gate).
- [ ] **Step 5: Activate (OWNER-GATED — stop-condition: installs host packages/units, creates the /workspaces volume, loads live nft rules, and transitions the worker deployment; side effects outside the repo + security-sensitive).** Execute DEPLOY.md §11 steps 1–8 in order with the owner present, recording each gate output. If the P1 compose stack was never activated on this box (true as of 2026-10-16: no `ovid-cloud-*` containers running), §11 steps 5–7 stand alone: bring the compose stack up per DEPLOY.md §4–§6 first (P1 activation gate, still owner-run) or activate P2-only with the gateway absent and note it in the decision log.
- [ ] **Step 6: Commit.** `git add cloud/deploy && git commit -m "feat(cloud): P2 deploy artifacts — systemd worker + sandbox slice, nft/workspaces install, compose transition (activation owner-gated)"`

---

## Self-Review Notes (completed per writing-plans skill)

- **Spec coverage:** §7 three layers → Tasks 4 (pre-parse + exact copy), 3/9/15 (PATH shims incl. live-terminal refusal), 6/16 (cgroup caps + slice); §7 allowlist → Task 4 corpus + Task 15 §3. §9 (revised 8c/22GB per ledger) → Global Constraints derivation, Task 8 admission (`MAX_ACTIVE_SANDBOXES=24`), Task 16 slice (`CPUQuota=600%`, `MemoryMax=10G`). §11 → uid range 200000+ (Tasks 2/8; base configurable — prod default 200000-209999 per spec §11, staging 220000-229999 per P10, gap G4), private minimal /etc + RO rootfs + RW workspace + die-with-parent (Tasks 5/7), nftables egress incl. metadata + own IP (Task 11, with the documented `127/8`+`::1` addition), workspace quotas 500MB/Pro 2GB (Task 8). §14 P2 row "working software": agent executes echo + file write with streamed output (Task 14a), user terminal over WS (Tasks 13/14b), `ovid install` fast path (Task 10), job management (Task 9), deploy artifacts + HARDENING cross-refs (Task 16), isolation verification suite (Task 15). Research bindings: Option A systemd worker (Tasks 12/13 main wiring + Task 16 units), week-1 AppArmor verification with fallbacks a/b/c (Task 1, seam `LaunchStrategy` in Tasks 2/5/7), per-user stores with measured evidence (Tasks 8/10), uid-mapping handling — bwrap runs as the sandbox uid via setpriv-after-cgroup-attach (Tasks 7/8), cgroup delegation leaf-first wiring (Task 6 `init()`), egress recommendations (Task 11), rootfs pipeline §6 (Task 3), open items — cpu.max throttle (Task 6), node-pty ctty (Tasks 9/14). Deferred with pointers: hibernate/hydrate + reflink seed stores + `MAX_WARM_GB` LRU eviction → P7 (Task 10 header comment); job_* agent tools + full roster → P3 (Task 12 registry is the seam); account-deletion workspace purge → P9 (Task 8 `destroy` keeps data).
- **Step scan:** every step names one artifact/action with its gate; bodies appear only where the signature+tests don't determine them (launcher script, shim example, nft rule keys, slice/service units, refusal copy); no TBDs. The three owner-gated activations (Task 1 Step 3, Task 16 Step 5; Task 3's install.sh runs inside Task 16 §11) carry explicit stop-conditions per the P1 Task 11 pattern.
- **Type consistency:** `SandboxHandle`/`SandboxManager` defined Task 8, extended Task 9 (`createPty/getPty/jobs`), consumed verbatim by Tasks 12/13/14; `ExecRequest/ExecResult` Task 7 = Task 12 shellTool usage; `RingChunk {offset,data}` Task 9 = shared `RingChunkWire` Task 13 (deliberate structural twin — the wire type lives in `@ovid/shared` so the gateway never imports `@ovid/sandbox`); `REFUSAL_MESSAGE` single source (Task 4) with parity pins (Tasks 3/12/15); `PolicyVerdict.blocked` → `ExecResult.blocked/refusal` → tool result + `system_note` chain uses the identical string at every hop; cgroup names `sandbox-{uid}` / leaves `exec-*|pty-*|job-*` consistent across Tasks 6/7/8/9/15; `SandboxAdmissionError`→`sandbox_busy`, `SandboxCapacityError`/`RootfsUnavailable`→`sandbox_unavailable` mapping identical in Tasks 12 and 13. **Cross-plan seams (G1–G3):** `SandboxManager.workspaceDir(userId, sessionId)` (Task 8) is P6's `BrowserToolsDeps.workspaceDir` (ruling P6-Q2) — layout `{workspacesRoot}/{uid}/sessions/{sessionId}` reconciled under the per-user uid tree (nft/cgroup/quota keep keying on uid; P6's `{root}/{userId}/sessions/{sessionId}` default is its test fallback only), quota semantics per-user (shared `workspaceProjectId`); `spawnLongRunning`/`SpawnedProcess` (Task 9 — pipes, never a pty: tty echo/CRLF would corrupt JSON-RPC lines) back P5's `SandboxSpawner`/`SandboxProcessHandle` (`spawn(uid,{command,args,env,cwd})` → `handle.spawnProcess({argv:[command,...args],env,cwd})`, names adapted inside P5's `sandboxSeam.ts`); P5's `SandboxFiles` needs no new API — `workspaceDir`/`SandboxHandle.workspaceDir` + `resolveConfined` (Task 12) + `execOnce` absorb it; uid range is base-relative end-to-end (Task 2 `loadSandboxConfig` → Task 11 renderer/CLI) so P10's staging base 220000 validates and renders 220000-229999 while prod stays 200000-209999; the optional browser-uid nft section (Task 11, G2) never overlaps the sandbox range and leaves the sandbox rules byte-identical.
- **Review Focus:** all five pinned to owning tasks with named tests (see the section); #1 additionally spans three layers by design (unit corpus → no-spawn short-circuit → in-jail shim), #3's ordering rule reuses the P1 subscribe-before-replay precedent at both bridge and e2e level.
- **Proportion:** ~16 tasks for a spec phase that spans a new package, two app integrations, a protocol extension, host plumbing, and an acceptance suite; code blocks are signatures/goldens/exact-copy only — algorithm prose covers the tokenizer, ring dedupe, launcher ordering, and admission queue without transcribing them.
