# syntax=docker/dockerfile:1
# Ovid Cloud mint image — the Node port of server/mint/mint.py.
# Build context = the cloud/ monorepo root:
#   docker build -f deploy/Dockerfile.mint <cloud-dir>
# (docker compose does this automatically — context `..` in docker-compose.yml.)
#
# Multi-stage: full workspace install + tsc build, then a slim runtime with
# ONLY the dist trees, the drizzle/ migrations folder and production deps.
#
# ── RUNTIME IMPORT MAP (do not trim without re-grepping) ────────────────────
# `apps/mint` imports these workspace packages DIRECTLY:
#   @ovid/db, @ovid/money, @ovid/shared
# and @ovid/db imports @ovid/shared transitively. NOTHING else under
# packages/ is reachable from the mint process today (verified with
#   grep -rn '"@ovid/' apps/mint/src packages/{db,money,shared}/src
# after excluding tests; there are no dynamic imports of workspace packages).
# If a later task adds an import, add BOTH its package.json COPY line (the
# frozen-lockfile install validates present importers) and its dist COPY line
# here — a missing dist tree fails at `node dist/main.js` import time, exactly
# the Dockerfile.gateway P7-review bug this file must not repeat.

FROM node:22-slim AS build
WORKDIR /repo
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages ./packages
COPY apps ./apps
RUN pnpm install --frozen-lockfile
# Build the mint app and its workspace dependency graph only (shared → db →
# mint; money). Keeps the build stage honest about the runtime import map.
RUN pnpm --filter @ovid/mint... build

FROM node:22-slim
ENV NODE_ENV=production
WORKDIR /repo
RUN corepack enable
# Workspace manifests for every importer that EXISTS in this image. pnpm
# validates the importers it can see against the lockfile; the other
# workspace packages are deliberately not copied (their code never loads).
# allowBuilds from pnpm-workspace.yaml applies — firebase-admin needs
# @firebase/util's postinstall to place postinstall.mjs.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/shared/package.json packages/shared/
COPY packages/db/package.json packages/db/
COPY packages/money/package.json packages/money/
COPY apps/mint/package.json apps/mint/
# Built output the mint process loads at runtime. drizzle/ is required by
# @ovid/db's migrate() (resolved relative to the package root) — the mint
# process itself does not migrate, but the deploy's provision path and the
# migration scripts reuse this image layout.
COPY --from=build /repo/packages/shared/dist ./packages/shared/dist
COPY --from=build /repo/packages/db/dist ./packages/db/dist
COPY --from=build /repo/packages/db/drizzle ./packages/db/drizzle
COPY --from=build /repo/packages/money/dist ./packages/money/dist
COPY --from=build /repo/apps/mint/dist ./apps/mint/dist
# Production deps only: typescript/vitest never reach the runtime image.
RUN pnpm install --frozen-lockfile --prod
# MINT_STATE_DIR (audit JSONL + limits mirrors) is a compose volume. The
# directory must exist in the image owned by `node` or a fresh named volume
# inherits root ownership and the audit writer fails on first boot.
RUN mkdir -p /data && chown node:node /data
USER node
# Public listener 8091 (/healthz); the admin console listens on 8092 and is
# never exposed through Caddy. node:22-slim has no curl — probe with fetch.
HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8091/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
# main.ts is the process entry (direct-run guard around main() from index.ts).
CMD ["node", "apps/mint/dist/main.js"]
