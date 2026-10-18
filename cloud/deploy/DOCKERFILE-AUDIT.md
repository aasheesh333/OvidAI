# Cloud Dockerfile runtime import-map audit

**Date:** 2026-10-17
**Targets:** `cloud/deploy/Dockerfile.gateway`, `cloud/deploy/Dockerfile.mint`
**Mode:** static only. No `docker build` was run (the lockfile is knowingly stale — the known wave-merger blocker). No live container, `/opt`, or Caddyfile was touched.

Method:

- Walked every non-test `apps/<app>/src` and `packages/*/src` TypeScript file for `import`/`export ... from "@ovid/<pkg>"`, `import("@ovid/<pkg>")`, and computed dynamic imports.
- Cross-checked the true dependency closure with pnpm itself:
  `pnpm --filter @ovid/gateway... exec pwd` and `pnpm --filter @ovid/mint... exec pwd`.
- Reproduced the runtime-stage `pnpm install --frozen-lockfile` importer validation in throwaway `/tmp` workspaces (no network, no Docker) to establish exactly what pnpm does with absent workspace directories and stale importers.

---

## Verdict up front

- **Both runtime import maps are COMPLETE.** Every workspace package imported at runtime by either app has **both** its `package.json` COPY and its `dist` COPY in the runtime stage.
- **CRITICAL (would fail to boot) findings: none.** No imported package is missing a COPY.
- Both images nevertheless **fail to build today**, for two reasons outside the import map:
  1. the known stale lockfile (`apps/e2e` → `@ovid/mint`, the wave-merger carry);
  2. `node-pty`'s source build in the build stage with no compiler toolchain in either base image.
- The **gateway runtime stage** also trips the stale-lockfile check, because it copies `apps/e2e/package.json`. The **mint runtime stage is clean** (its importer subset matches the lockfile).

---

## 1. `Dockerfile.gateway`

### 1.1 True transitive runtime import closure

Entry: `apps/gateway/src/main.ts` → `index.ts` (the composition root).

| Edge (from → to) | Where | Kind |
|---|---|---|
| `@ovid/gateway` → `@ovid/account` | `src/index.ts`, `src/routes/account.ts` | static |
| `@ovid/account` → `@ovid/db` | `packages/account/src/store.ts`, `adapters.ts` | static |
| `@ovid/db` → `@ovid/shared` | `packages/db/src/repos.ts`, `scheduleRepos.ts` | static |
| `@ovid/gateway` → `@ovid/db` | `src/index.ts`, `ws.ts`, `routes/*.ts` | static |
| `@ovid/gateway` → `@ovid/escrow` | `src/routes/byok.ts` | static |
| `@ovid/escrow` → `@ovid/db` | `packages/escrow/src/provider.ts`, `rotateMasterKey.ts` | static |
| `@ovid/gateway` → `@ovid/events` | `src/index.ts`, `ws.ts` | static |
| `@ovid/events` → `@ovid/shared` | `packages/events/src/eventLog.ts`, `systemBus.ts` | static |
| `@ovid/gateway` → `@ovid/mcp` | `src/index.ts`, `routes/plugins.ts`, `routes/mcpServers.ts`, `routes/mcpCatalog.ts` | static |
| `@ovid/mcp` → `@ovid/shared` | `packages/mcp/src/plugins/input.ts` | static |
| `@ovid/mcp` → `@ovid/db` | `packages/mcp/src/router.ts`, `oauth/flow.ts`, `plugins/install.ts` | **computed dynamic** relative `import(spec)` → `../../db/dist/index.js` (and deeper variants) |
| `@ovid/gateway` → `@ovid/queue` | `src/index.ts`, `routes/messages.ts`, `routes/plugins.ts`, `routes/workspace.ts` | static |
| `@ovid/queue` → `@ovid/shared` | `packages/queue/src/queues.ts` | static |
| `@ovid/gateway` → `@ovid/storage` | `src/index.ts`, `routes/workspace.ts` | static |
| `@ovid/storage` → `@ovid/shared` | `packages/storage/src/hibernate.ts`, `artifacts.ts`, `archive/uiTree.ts` | static |

**Closure set (workspace packages):** `gateway`, `account`, `db`, `escrow`, `events`, `mcp`, `queue`, `shared`, `storage`.

External (non-workspace) imports made directly by the gateway, all declared in `apps/gateway/package.json`: `fastify`, `@fastify/websocket`, `firebase-admin`, `ioredis`, `ws`, `zod`. Transitive workspace packages declare their own externals in their manifests (which are copied), so pnpm installs them too.

Not in the closure (confirmed by both source grep and `pnpm --filter @ovid/gateway...`): `@ovid/agent-core`, `@ovid/browser`, `@ovid/money`, `@ovid/sandbox`. In particular, `@ovid/mcp` does **not** import sandbox/escrow/queue — those are structural mirrors in `packages/mcp/src`; the only real transitive edge out of mcp is the dynamic `@ovid/db` one. `@ovid/storage` does **not** import `@ovid/escrow`.

### 1.2 Package-by-package check

| Package | Imported at runtime? | `package.json` COPY | `dist` COPY | Verdict |
|---|---|---|---|---|
| `@ovid/shared` | yes — direct + via db/events/mcp/queue/storage/account/escrow | line 28 | line 48 | **OK** |
| `@ovid/db` | yes — direct + via account/escrow/mcp | line 29 | line 49 (+ `drizzle` line 50) | **OK** |
| `@ovid/events` | yes — direct | line 30 | line 51 | **OK** |
| `@ovid/queue` | yes — direct | line 31 | line 52 | **OK** |
| `@ovid/storage` | yes — direct | line 35 | line 53 | **OK** |
| `@ovid/account` | yes — direct | line 36 | line 54 | **OK** |
| `@ovid/escrow` | yes — direct | line 37 | line 55 | **OK** |
| `@ovid/mcp` | yes — direct | line 38 | line 56 | **OK** |
| `@ovid/agent-core` | no | no | no | Not needed |
| `@ovid/browser` | no | no | no | Not needed |
| `@ovid/money` | no | no | no | Not needed |
| `@ovid/sandbox` | no | no | no | Not needed |

Apps and the remaining workspace importers:

| Importer | Imported by gateway? | Manifest COPY | `dist` COPY | Verdict |
|---|---|---|---|---|
| `apps/gateway` | entry | line 39 | line 57 | **OK** |
| `apps/worker` | no | line 40 | no | Unnecessary; harmless |
| `apps/e2e` | no | line 41 | no | Unnecessary; **surfaces the stale lockfile in the runtime stage** |
| `apps/mint` | no | line 45 | no | Unnecessary; causes mint's prod deps to be installed (image bloat) |
| `apps/load`, `apps/watch` | no | no | no | Not needed; absent directories are ignored by pnpm |

### 1.3 Findings

**CRITICAL (would fail to boot):** none. Every closure member has both COPY lines.

**HIGH — H1: build stage cannot compile `node-pty` (both Dockerfiles).**
The build stage copies all packages/apps and runs `pnpm install --frozen-lockfile`. `pnpm-workspace.yaml` sets `allowBuilds: node-pty: true`, so `packages/sandbox`'s `node-pty@1.1.0` install script runs. Its `install` script is `node scripts/prebuild.js || node-gyp rebuild`; the published tarball's `prebuilds/` directory contains only darwin/win32 binaries (no Linux `pty.node`), so on Linux it always falls through to `node-gyp rebuild`. `node:22-alpine` (gateway build stage) has no `python3`, `make`, or `g++`; neither does `node:22-slim` (mint build stage). The install therefore fails once the stale lockfile is refreshed.
Fix (either):
- add a toolchain before install — gateway: `RUN apk add --no-cache python3 make g++ linux-headers`; mint: `RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++`; or
- install/build only the app closure — gateway: `pnpm --filter @ovid/gateway... install --frozen-lockfile` + `pnpm --filter @ovid/gateway... build`; mint: add `--filter @ovid/mint...` to its install (its build is already filtered).
The filtered-install option is smaller and avoids dragging `node-pty`/`playwright-core` into either build.

**HIGH — H2: stale lockfile (known wave-merger blocker), and it reaches the gateway runtime stage.**
Reproduced in a scratch copy of all 19 importers: `ERR_PNPM_OUTDATED_LOCKFILE` — `importers["apps/e2e"]` has `@ovid/mint@workspace:*` added. This blocks both build stages. It also blocks the gateway runtime stage, because line 41 copies `apps/e2e/package.json`; the same check fails there. The mint runtime subset (shared, db, money, mint) passes the frozen check. This is the known blocker, not a new import-map defect; after the lockfile is regenerated in the full workspace, the runtime subsets pass (pnpm ignores absent workspace directories — verified with a synthetic workspace where a present app depended on a deleted package: frozen install exited 0 and created a dangling link).

**LOW — L1: extra app manifests in the gateway runtime.**
`apps/worker`, `apps/e2e`, and `apps/mint` are not in the gateway closure. They are not needed for the frozen check either: pnpm only validates **present** manifests, and ignores absent workspace directories. Keeping them has real side effects: `pnpm install --prod` installs the prod dependencies of every present workspace project, so `apps/mint` pulls `googleapis`/`google-auth-library` into the gateway image, and `apps/e2e` is what currently trips the stale-lockfile check in this stage. Recommend deleting lines 40–45 from the runtime stage (or at least `apps/e2e` and `apps/mint`). Note the header comment's claim that `--frozen-lockfile` "validates every importer's presence" is inaccurate; the accurate rule is "every present manifest must match the lockfile."

**LOW — L2: `@ovid/mcp` → `@ovid/db` is an undeclared dynamic edge.**
`packages/mcp/package.json` declares only `@ovid/shared`, but `router.ts`, `oauth/flow.ts`, and `plugins/install.ts` dynamically import `../../db/dist/index.js` (computed specifier, to avoid tsc pulling db's types). In the image this resolves to `/repo/packages/db/dist/index.js`, which line 49 copies; db's manifest (line 29) makes pnpm install its deps. Works today, but it is a latent coupling: trimming db from the gateway closure would make MCP router/OAuth/plugin-install paths throw at call time. Consider declaring `@ovid/db` in `packages/mcp/package.json` when the wave merger lands.

**LOW — L3: `msgpackr-extract` on musl.**
`bullmq` → `msgpackr` → optional `msgpackr-extract@3.0.4`. Its prebuilt platform packages include `linux-x64` (glibc) but no musl variant. On `node:22-alpine` the native module may fail to load; `msgpackr` catches that and falls back to pure-JS decoding (the same note is already in `pnpm-workspace.yaml`). Not a boot failure.

**LOW — L4: zstd requires Node ≥ 22.15.**
`@ovid/storage` calls `zlib.zstdDecompressSync` / `zlib.zstdCompressSync` (`archive/readIndex.ts`, `extract.ts`, `pack.ts`). These exist from Node 22.15.0. `node:22-alpine` floats to the latest 22.x (verified locally: v22.23.3), so the current tag is fine; pinning an older 22.x digest would break archive reads/writes. Add a Node minor guard or pin a known-good 22.x if reproducibility matters.

**LOW — L5: non-root write paths.**
The gateway has no local filesystem writes in non-test source (no `writeFile`/`appendFile`/`mkdir`/`createWriteStream`); workspace writes are proxied to the host worker (`routes/workspace.ts`) and production storage is R2 (`storageEnv.ts` throws if `fs` is selected with `NODE_ENV=production`). `/repo` is root-owned but read-only for `node`, which is fine. If future gateway code writes to `/repo` or `/workspaces`, it will fail as `node`.

### 1.4 COPY lines to add

**None for the runtime import closure.** Every closure member already has both lines.

Do **not** add manifests for `@ovid/agent-core`, `@ovid/browser`, `@ovid/money`, or `@ovid/sandbox` to the gateway runtime: none is imported, and `@ovid/sandbox` would drag `node-pty` into the runtime `pnpm install --prod` (which has no toolchain and would fail). Template for any future import:

```dockerfile
COPY packages/<pkg>/package.json packages/<pkg>/
COPY --from=build /repo/packages/<pkg>/dist ./packages/<pkg>/dist
```

---

## 2. `Dockerfile.mint`

### 2.1 True transitive runtime import closure

Entry: `apps/mint/src/main.ts` → `index.ts`.

| Edge (from → to) | Where | Kind |
|---|---|---|
| `@ovid/mint` → `@ovid/db` | `src/index.ts`, `adminAudit.ts`, `adminRoutes.ts`, `settings.ts`, `verifier.ts`, `keyMint.ts`, `projection.ts`, `mintRoutes.ts`, `billing/*`, `images/*` | static |
| `@ovid/db` → `@ovid/shared` | `packages/db/src/repos.ts`, `scheduleRepos.ts` | static |
| `@ovid/mint` → `@ovid/money` | `src/index.ts`, `adminRoutes.ts`, `settings.ts`, `usage.ts`, `planMath.ts`, `background.ts`, `images/*` | static |
| `@ovid/mint` → `@ovid/shared` | `src/internalAuth.ts`, `src/internalRoutes.ts` | static |

**Closure set (workspace packages):** `mint`, `db`, `money`, `shared`.

External runtime imports made directly by mint, all declared in `apps/mint/package.json`: `decimal.js`, `fastify`, `firebase-admin`, `google-auth-library` (dynamic in `billing/pushAuth.ts`), `googleapis` (dynamic in `billing/play.ts`), `ioredis`, `zod`.

Nothing else under `packages/` is reachable: no `@ovid/account`, `@ovid/events`, `@ovid/escrow`, `@ovid/mcp`, `@ovid/queue`, `@ovid/storage`, `@ovid/sandbox`, `@ovid/browser`, or `@ovid/agent-core` import exists in mint's non-test source. The Dockerfile header's import map is accurate.

### 2.2 Package-by-package check

| Package | Imported at runtime? | `package.json` COPY | `dist` COPY | Verdict |
|---|---|---|---|---|
| `@ovid/shared` | yes — direct + via db | line 43 | line 51 | **OK** |
| `@ovid/db` | yes — direct | line 44 | line 52 (+ `drizzle` line 53) | **OK** |
| `@ovid/money` | yes — direct | line 45 | line 54 | **OK** |
| `@ovid/account` | no | no | no | Not needed |
| `@ovid/agent-core` | no | no | no | Not needed |
| `@ovid/browser` | no | no | no | Not needed |
| `@ovid/escrow` | no | no | no | Not needed |
| `@ovid/events` | no | no | no | Not needed |
| `@ovid/mcp` | no | no | no | Not needed |
| `@ovid/queue` | no | no | no | Not needed |
| `@ovid/sandbox` | no | no | no | Not needed |
| `@ovid/storage` | no | no | no | Not needed |

| Importer | Imported by mint? | Manifest COPY | `dist` COPY | Verdict |
|---|---|---|---|---|
| `apps/mint` | entry | line 46 | line 55 | **OK** |

### 2.3 Build-filter check

`pnpm --filter @ovid/mint... exec pwd` returns exactly:

```
packages/money
packages/shared
packages/db
apps/mint
```

`apps/mint`'s `dependencies` are `@ovid/db`, `@ovid/money`, `@ovid/shared`; `@ovid/db` depends on `@ovid/shared`; `@ovid/money` has no workspace dependencies. The `...` closure flag therefore covers every package mint needs, in topological order. `pnpm --filter @ovid/mint... build` is correct.

### 2.4 Findings

**CRITICAL (would fail to boot):** none. Every closure member has both COPY lines.

**HIGH — H1: same `node-pty` build-toolchain problem.**
The mint build stage runs the **unfiltered** `pnpm install --frozen-lockfile`, so it installs `packages/sandbox` → `node-pty` even though mint never uses it. `node:22-slim` has no `python3`/`make`/`g++`; `node-pty` has no Linux prebuild. Fix: add `RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++`, or change the install to `pnpm --filter @ovid/mint... install --frozen-lockfile` (matching the build filter). The filtered install is smaller and avoids installing sandbox/browser entirely.

**HIGH — H2: stale lockfile (known), build stage only.**
The build stage's unfiltered `pnpm install --frozen-lockfile` fails on `apps/e2e` → `@ovid/mint` exactly as the gateway does. Unlike the gateway, the mint **runtime** stage copies only shared/db/money/mint, and its frozen check passes (verified). No import-map change is needed here; the fix is the same lockfile regeneration.

**LOW — L1: `drizzle/` is copied but the mint process never migrates.**
`apps/mint/src` does not import `migrate`; the copy supports the deploy provision/migration scripts that reuse this image layout, per the header comment. Harmless and intentional.

**LOW — L2: non-root permissions are correct.**
`RUN mkdir -p /data && chown node:node /data` (line 61) runs before `USER node`. `apps/mint/src/adminAudit.ts` is the only state writer: `appendFile(join(MINT_STATE_DIR, "admin-audit.jsonl"))`, with `MINT_STATE_DIR` defaulting to `/data`. A fresh named volume inherits the image directory's ownership, so the audit writer works on first boot. No `/workspaces` use in mint.

**LOW — L3: base image / native deps.**
`node:22-slim` is glibc and all mint runtime deps are pure JS (`googleapis`, `google-auth-library`, `firebase-admin`, `fastify`, `ioredis`, `decimal.js`, `zod`). The images path (`apps/mint/src/images/*`) uses `node:zlib` `deflateSync`/`inflateSync` and `fetch`; there is no `sharp`, no `child_process`, and no external binary. No native runtime dependency.

**LOW — L4: healthcheck port.**
The hardcoded `8091` matches `DEFAULT_PUBLIC_PORT` in `apps/mint/src/env.ts` and the compose `PUBLIC_PORT: "8091"`. OK.

### 2.5 COPY lines to add

**None.** The closure is complete. Template for a future import:

```dockerfile
COPY packages/<pkg>/package.json packages/<pkg>/
COPY --from=build /repo/packages/<pkg>/dist ./packages/<pkg>/dist
```

---

## 3. Cross-cutting notes and evidence

### 3.1 pnpm frozen-lockfile semantics (why the COPY sets behave as they do)

Verified in scratch workspaces:

- A lockfile importer whose directory is **entirely absent** is ignored; the install succeeds. This is why `apps/load`, `apps/watch`, and the non-copied packages do not break either runtime stage.
- A **present** `package.json` that is not represented (or whose specifiers do not match) in the lockfile triggers `ERR_PNPM_OUTDATED_LOCKFILE`. This is why the copied `apps/e2e/package.json` matters in the gateway runtime.
- A present importer may depend on a workspace package whose directory is absent; frozen install creates a dangling symlink and exits 0. This is why `apps/worker`'s references to `@ovid/sandbox`/`@ovid/browser`/`@ovid/agent-core` do not break the gateway runtime.

### 3.2 Native / base-image checks

| Need | Where | Runtime base | Verdict |
|---|---|---|---|
| zstd (`zlib.zstdDecompressSync`, `zstdCompressSync`) | `packages/storage/src/archive/*` | Node ≥ 22.15; `node:22-alpine` floats to latest 22.x | OK, but pin/guard if reproducibility matters |
| `node-pty` (native, no Linux prebuild) | `packages/sandbox` | not in either runtime closure; **build stage** lacks toolchain | **HIGH build blocker** |
| `playwright-core` | `packages/browser` | not in either runtime closure; no postinstall download in `playwright-core` | OK |
| `msgpackr-extract` (optional native) | `packages/queue` | alpine/musl: glibc prebuild may not load; msgpackr falls back to JS | OK |
| `sharp` / image binaries | `apps/mint/src/images/*` | none imported | OK |
| `escrow` native deps | `packages/escrow` | `node:crypto` only | OK |

### 3.3 Non-root ownership

- **Gateway:** `USER node`; no local writes in non-test source; `/repo` root-owned but read-only. No `/data` or `/workspaces` volume needed by the gateway.
- **Mint:** `USER node`; `/data` created and chowned; the audit JSONL is the only writer. Correct.

### 3.4 Known blocker (not introduced by this audit)

`pnpm-lock.yaml` is stale: `apps/e2e/package.json` declares `@ovid/mint@workspace:*`, which the lockfile's `apps/e2e` importer does not record. This fails `--frozen-lockfile` in both build stages and in the gateway runtime stage. Regenerating the lockfile in the full workspace is the fix; it is the wave-merger carry already tracked elsewhere.

---

## 4. Summary

| Question | Answer |
|---|---|
| Does `Dockerfile.gateway` have a missing runtime COPY? | **No.** Closure = account, db, escrow, events, mcp, queue, shared, storage + gateway; all have manifest + dist. |
| Does `Dockerfile.mint` have a missing runtime COPY? | **No.** Closure = db, money, shared + mint; all have manifest + dist. |
| Any imported-but-not-copied package? | **None.** |
| Any copied-but-not-imported package? | Gateway: `apps/worker`, `apps/e2e`, `apps/mint` manifests (harmless, but `apps/e2e` surfaces the stale lockfile and `apps/mint` adds prod-dep bloat). Mint: none. |
| Boot-blocking import-map defect? | **None.** |
| Build-blocking issues (non-import-map) | Stale lockfile (known); `node-pty` toolchain missing in both build stages. |
