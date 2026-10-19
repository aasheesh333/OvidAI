# Ovid Cloud release evidence — 20261018

- generated: 2026-10-18T15:54:02Z
- mode: full
- result: **PASS**
- duration: 731s
- git HEAD: 572eacb026a40ce8e0d5fad255db8e39bf3a5cf7 (branch feat/ovid-cloud, 7 dirty path(s))
- host: vps-6bc54f43-vps-ovh-ca
- kernel: Linux 6.8.0-136-generic
- cpus: 8
- memory: 23463 MiB total, 19088 MiB available
- disk /: 52976 MiB free of 197316 MiB
- node: v22.23.3
- pnpm: 12.11.2
- docker: Docker version 29.9.1, build dfc520d
- staging script: /root/OvidAI/cloud/scripts/staging.sh
- acceptance script: /root/OvidAI/cloud/scripts/acceptance.sh
- ACCEPTANCE_REQUIRE_FULL_SECURITY: 1
- ACCEPTANCE_REQUIRE_OWNER_GATES: 0

## Gate summary

| Gate | Name | Result | Notes |
|---|---|---|---|
| 1 | build | PASS |  |
| 2 | typecheck | PASS |  |
| 3 | staging-isolation-and-bring-up | PASS |  |
| 4 | full-suite-and-security | PASS |  |
| 4b | security-regressions | PASS |  |
| 5 | load-smoke10 | PASS |  |
| 6 | chaos-worker-kill | PASS |  |
| 7 | canary-sweep | PASS |  |
| 7b | canary-stack | PASS |  |
| 8 | live-unaffected | PASS |  |
| 8b | watch-self-test | OWNER-GATED | not configured |
| 8c | r2-verification | OWNER-GATED | not configured |
| 9 | teardown | PASS |  |
| 10 | release-evidence | PASS | this file |

## Security corpus (Review Focus #4)

- summary: security corpus: 12 ran, 0 SKIPPED
- ran: 12
- skipped: 0
- release-box requirement: skips fail the gate

## Load

- report: /root/OvidAI/cloud/apps/load/reports/load-smoke10-20261018.md
- json: /root/OvidAI/cloud/apps/load/reports/load-smoke10-20261018.json
- positive-data gates: see GATE 5 output (missing measurements fail)
- canary workload report: /root/OvidAI/cloud/apps/load/reports/load-smoke10-canary-20261018.md
- canary workload json: /root/OvidAI/cloud/apps/load/reports/load-smoke10-canary-20261018.json

## Chaos

- scenario: worker-kill
- report: /root/OvidAI/cloud/apps/load/reports/chaos-20261018.md
- required assertions: precondition PASS + inject PASS + zero FAIL rows

## Canary

- captures: /tmp/ovid-acceptance.udD4uo/canary
- gateway log: /tmp/ovid-acceptance.udD4uo/gateway.log
- result: see GATE 7 output (zero leaks required)

## Live-unaffected

- baseline: /tmp/ovid-acceptance.udD4uo/live-baseline.txt (captured at the start of GATE 3)
- assertion: https://api.ovidsi.com/healthz == 200, every ovid-gateway-* Up, StartedAt identical
- result: see GATE 8 output

## Owner-gated

- GATE 8b watch --self-test: see gate summary (OWNER-GATED when no sink is configured)
- GATE 8c R2 verification: see gate summary (OWNER-GATED when OVID_R2_* is absent)

## Raw gate output

### GATE 1 build — PASS

~~~text
Scope: all 19 workspace projects
✓ Lockfile passes supply-chain policies (verified 15h ago)
Lockfile is up to date, resolution step is skipped
Done in 45ms using pnpm v12.11.2
apps/watch build$ tsc -p tsconfig.json
packages/money build$ tsc -p tsconfig.json
packages/shared build$ tsc -p tsconfig.json
packages/money build: Done
apps/watch build: Done
packages/shared build: Done
packages/browser build$ tsc -p tsconfig.json
packages/events build$ tsc -p tsconfig.json
packages/db build$ tsc -p tsconfig.json
packages/mcp build$ tsc -p tsconfig.json
packages/browser build: Done
packages/queue build$ tsc -p tsconfig.json
packages/events build: Done
packages/storage build$ tsc -p tsconfig.json
packages/db build: Done
apps/mint build$ tsc -p tsconfig.json
packages/mcp build: Done
packages/account build$ tsc -p tsconfig.json
packages/queue build: Done
packages/agent-core build$ tsc -p tsconfig.json
packages/account build: Done
packages/escrow build$ tsc -p tsconfig.json && chmod +x dist/rotateMasterKey.js
packages/storage build: Done
packages/sandbox build$ tsc -p tsconfig.json && chmod +x dist/renderNftCli.js
packages/escrow build: Done
apps/gateway build$ tsc -p tsconfig.json
packages/agent-core build: Done
packages/sandbox build: Done
apps/worker build$ tsc -p tsconfig.json
apps/gateway build: Done
apps/worker build: Done
apps/load build$ tsc -p tsconfig.json
apps/mint build: Done
apps/e2e build$ tsc -p tsconfig.json
apps/e2e build: Done
apps/load build: Done
~~~

### GATE 2 typecheck — PASS

~~~text
~~~

### GATE 3 staging-isolation-and-bring-up — PASS

~~~text
[staging] wrote live baseline to /tmp/ovid-acceptance.udD4uo/live-baseline.txt
LIVE CHECK (check):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] guard OK: /root/OvidAI/cloud/deploy/.env.staging
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] starting staging compose project 'ovid-cloud-staging' (auth=test)
 Network ovid-cloud-staging Creating 
 Network ovid-cloud-staging Creating 
 Network ovid-cloud-staging Created 
 Network ovid-cloud-staging Created 
 Container ovid-cloud-staging-redis-q-1 Creating 
 Container ovid-cloud-staging-redis-mint-1 Creating 
 Container ovid-cloud-staging-postgres-1 Creating 
 Container ovid-cloud-staging-redis-q-1 Created 
 Container ovid-cloud-staging-postgres-1 Created 
 Container ovid-cloud-staging-redis-mint-1 Created 
 Container ovid-cloud-staging-postgres-1 Starting 
 Container ovid-cloud-staging-redis-mint-1 Starting 
 Container ovid-cloud-staging-redis-q-1 Starting 
 Container ovid-cloud-staging-postgres-1 Started 
 Container ovid-cloud-staging-redis-mint-1 Started 
 Container ovid-cloud-staging-redis-q-1 Started 
[staging] running migrations against postgres://postgres:staging@127.0.0.1:15432/ovid_cloud_staging
[migrate] applying migrations…
[migrate] done — schema up to date
 Image ovid-cloud-staging-gateway Building 
 Image ovid-cloud-staging-mint Building 
#1 [internal] load local bake definitions
#1 reading from stdin 956B done
#1 DONE 0.0s

#2 [mint internal] load build definition from Dockerfile.mint
#2 transferring dockerfile: 4.26kB done
#2 DONE 0.0s

#3 [gateway internal] load build definition from Dockerfile.gateway
#3 transferring dockerfile: 4.03kB done
#3 DONE 0.0s

#4 [gateway] resolve image config for docker-image://docker.io/docker/dockerfile:1
#4 DONE 1.5s

#5 [gateway] docker-image://docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
#5 resolve docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e 0.0s done
#5 CACHED

#6 [mint internal] load metadata for docker.io/library/node:22-slim
#6 DONE 1.4s

#7 [gateway internal] load metadata for docker.io/library/node:22-alpine
#7 DONE 1.4s

#8 [mint internal] load .dockerignore
#8 transferring context: 419B done
#8 DONE 0.0s

#9 [mint build 1/9] FROM docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392
#9 resolve docker.io/library/node:22-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 0.0s done
#9 DONE 0.0s

#10 [gateway build 1/9] FROM docker.io/library/node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402
#10 resolve docker.io/library/node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402 0.0s done
#10 DONE 0.0s

#11 [mint internal] load build context
#11 transferring context: 137.01kB 0.0s done
#11 DONE 0.0s

#12 [gateway internal] load build context
#12 transferring context: 137.01kB 0.0s done
#12 DONE 0.0s

#13 [mint build 5/9] COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
#13 CACHED

#14 [mint build 4/9] RUN apt-get update  && apt-get install -y --no-install-recommends python3 make g++  && rm -rf /var/lib/apt/lists/*
#14 CACHED

#15 [mint build 2/9] WORKDIR /repo
#15 CACHED

#16 [mint build 3/9] RUN corepack enable
#16 CACHED

#17 [mint build 6/9] COPY packages ./packages
#17 CACHED

#18 [gateway build 4/9] RUN apk add --no-cache python3 make g++ linux-headers
#18 CACHED

#19 [gateway build 5/9] COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
#19 CACHED

#20 [gateway build 2/9] WORKDIR /repo
#20 CACHED

#21 [gateway build 3/9] RUN corepack enable
#21 CACHED

#22 [gateway build 6/9] COPY packages ./packages
#22 CACHED

#23 [mint build 7/9] COPY apps ./apps
#23 DONE 0.1s

#24 [gateway build 7/9] COPY apps ./apps
#24 DONE 0.1s

#25 [mint build 8/9] RUN pnpm install --frozen-lockfile
#25 0.213 ! Corepack is about to download https://registry.npmjs.org/pnpm/-/pnpm-12.11.2.tgz
#25 0.928 Downloading the pnpm 12.11.2 binary for linux-x64...
#25 2.313 Scope: all 19 workspace projects
#25 2.335 ? Verifying lockfile against supply-chain policies (503 entries)...
#25 2.427 Update available! 12.11.2 → 12.14.0.
#25 2.427 Changelog: https://pnpm.io/v/12.14.0
#25 2.427 To update, run: curl -fsSL https://get.pnpm.io/install.sh | sh -
#25 2.473 Packages are hard linked from the content-addressable store to the virtual store.
#25 2.473   Content-addressable store is at: /root/.local/share/pnpm/store/v11
#25 2.473   Virtual store is at:             node_modules/.pnpm
#25 2.824 Downloading node-pty@1.1.0: 0.00 B/15.46 MB
#25 3.016 Downloading googleapis@186.0.0: 0.00 B/23.72 MB
#25 4.385 ✓ Lockfile passes supply-chain policies (503 entries in 2.1s)
#25 4.385 Lockfile is up to date, resolution step is skipped
#25 4.390 Packages: +380
#25 4.390 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#25 4.420 Progress: resolved 380, reused 0, downloaded 380, added 380, done
#25 4.424 .../node_modules/msgpackr-extract install$ node-gyp-build-optional-packages
#25 4.424 .../esbuild@0.18.20/node_modules/esbuild postinstall$ node install.js
#25 4.424 .../esbuild@0.25.12/node_modules/esbuild postinstall$ node install.js
#25 4.424 .../esbuild@0.28.2/node_modules/esbuild postinstall$ node install.js
#25 4.432 .../node_modules/@firebase/util postinstall$ node ./postinstall.js
#25 4.487 .../esbuild@0.18.20/node_modules/esbuild postinstall: Done
#25 4.494 .../esbuild@0.25.12/node_modules/esbuild postinstall: Done
#25 4.502 .../node_modules/@firebase/util postinstall: Done
#25 4.504 .../esbuild@0.28.2/node_modules/esbuild postinstall: Done
#25 4.512 .../node-pty@1.1.0/node_modules/node-pty install$ node scripts/prebuild.js || node-gyp rebuild
#25 4.520 .../node_modules/msgpackr-extract install: Done
#25 4.520 .../esbuild@0.21.5/node_modules/esbuild postinstall$ node install.js
#25 4.550 .../node-pty@1.1.0/node_modules/node-pty install: > Checking prebuilds...
#25 4.550 .../node-pty@1.1.0/node_modules/node-pty install: > Rebuilding because directory /repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/prebuilds/linux-x64 does not exist
#25 4.579 .../esbuild@0.21.5/node_modules/esbuild postinstall: Done
#25 4.586 .../node-pty@1.1.0/node_modules/node-pty install: gyp info it worked if it ends with ok
#25 4.586 .../node-pty@1.1.0/node_modules/node-pty install: gyp info using node-gyp@12.3.0
#25 4.586 .../node-pty@1.1.0/node_modules/node-pty install: gyp info using node@22.23.3 | linux | x64
#25 4.629 .../node-pty@1.1.0/node_modules/node-pty install: gyp info find Python using Python version 3.11.2 found at "/usr/bin/python3"
#25 4.697 .../node-pty@1.1.0/node_modules/node-pty install: 
#25 4.698 .../node-pty@1.1.0/node_modules/node-pty install: gyp http GET https://nodejs.org/download/release/v22.23.3/node-v22.23.3-headers.tar.gz
#25 4.756 .../node-pty@1.1.0/node_modules/node-pty install: gyp http 200 https://nodejs.org/download/release/v22.23.3/node-v22.23.3-headers.tar.gz
#25 7.806 .../node-pty@1.1.0/node_modules/node-pty install: gyp http GET https://nodejs.org/download/release/v22.23.3/SHASUMS256.txt
#25 7.826 .../node-pty@1.1.0/node_modules/node-pty install: gyp http 200 https://nodejs.org/download/release/v22.23.3/SHASUMS256.txt
#25 ...

#26 [gateway build 8/9] RUN pnpm install --frozen-lockfile
#26 0.231 ! Corepack is about to download https://registry.npmjs.org/pnpm/-/pnpm-12.11.2.tgz
#26 1.020 Downloading the pnpm 12.11.2 binary for linux-x64...
#26 2.381 Scope: all 19 workspace projects
#26 2.429 ? Verifying lockfile against supply-chain policies (503 entries)...
#26 2.536 Update available! 12.11.2 → 12.14.0.
#26 2.536 Changelog: https://pnpm.io/v/12.14.0
#26 2.536 To update, run: curl -fsSL https://get.pnpm.io/install.sh | sh -
#26 4.983 Progress: resolved 379, reused 0, downloaded 1, added 0
#26 5.052 Packages are hard linked from the content-addressable store to the virtual store.
#26 5.052   Content-addressable store is at: /root/.local/share/pnpm/store/v11
#26 5.052   Virtual store is at:             node_modules/.pnpm
#26 5.104 Downloading googleapis@186.0.0: 0.00 B/23.72 MB
#26 6.105 Progress: resolved 379, reused 0, downloaded 336, added 320
#26 6.128 Downloading node-pty@1.1.0: 0.00 B/15.46 MB
#26 6.897 ✓ Lockfile passes supply-chain policies (503 entries in 4.5s)
#26 6.897 Lockfile is up to date, resolution step is skipped
#26 6.913 Packages: +379
#26 6.913 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#26 6.977 Progress: resolved 379, reused 0, downloaded 379, added 379, done
#26 6.983 .../node_modules/msgpackr-extract install$ node-gyp-build-optional-packages
#26 6.983 .../esbuild@0.25.12/node_modules/esbuild postinstall$ node install.js
#26 6.983 .../esbuild@0.18.20/node_modules/esbuild postinstall$ node install.js
#26 6.983 .../esbuild@0.28.2/node_modules/esbuild postinstall$ node install.js
#26 6.983 .../node_modules/@firebase/util postinstall$ node ./postinstall.js
#26 7.043 .../node_modules/@firebase/util postinstall: Done
#26 7.053 .../node-pty@1.1.0/node_modules/node-pty install$ node scripts/prebuild.js || node-gyp rebuild
#26 7.058 .../esbuild@0.28.2/node_modules/esbuild postinstall: Done
#26 7.058 .../esbuild@0.18.20/node_modules/esbuild postinstall: Done
#26 7.063 .../esbuild@0.25.12/node_modules/esbuild postinstall: Done
#26 7.090 .../node-pty@1.1.0/node_modules/node-pty install: > Checking prebuilds...
#26 7.090 .../node-pty@1.1.0/node_modules/node-pty install: > Rebuilding because directory /repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/prebuilds/linux-x64 does not exist
#26 7.097 .../esbuild@0.21.5/node_modules/esbuild postinstall$ node install.js
#26 7.108 .../node_modules/msgpackr-extract install: Done
#26 7.138 .../node-pty@1.1.0/node_modules/node-pty install: gyp info it worked if it ends with ok
#26 7.139 .../node-pty@1.1.0/node_modules/node-pty install: gyp info using node-gyp@12.3.0
#26 7.139 .../node-pty@1.1.0/node_modules/node-pty install: gyp info using node@22.23.3 | linux | x64
#26 7.182 .../esbuild@0.21.5/node_modules/esbuild postinstall: Done
#26 7.212 .../node-pty@1.1.0/node_modules/node-pty install: gyp info find Python using Python version 3.14.8 found at "/usr/bin/python3"
#26 7.218 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn /usr/bin/python3
#26 7.218 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args [
#26 7.218 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp/gyp/gyp_main.py',
#26 7.218 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'binding.gyp',
#26 7.218 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-f',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'make',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build/config.gypi',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp/addon.gypi',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/usr/local/include/node/common.gypi',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dlibrary=shared_library',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dvisibility=default',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_root_dir=/usr/local',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_gyp_dir=/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_lib_file=/usr/local/$(Configuration)/node.lib',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dmodule_root_dir=/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty',
#26 7.219 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_engine=v8',
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--depth=.',
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--no-parallel',
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--generator-output',
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'build',
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Goutput_dir=.'
#26 7.220 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args ]
#26 7.479 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn make
#26 7.479 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args [ 'BUILDTYPE=Release', '-C', 'build' ]
#26 7.480 .../node-pty@1.1.0/node_modules/node-pty install: make: Entering directory '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build'
#26 7.481 .../node-pty@1.1.0/node_modules/node-pty install:   TOUCH Release/obj.target/../../../node-addon-api@7.1.1/node_modules/node-addon-api/node_addon_api_except.stamp
#26 7.486 .../node-pty@1.1.0/node_modules/node-pty install:   CXX(target) Release/obj.target/pty/src/unix/pty.o
#26 ...

#25 [mint build 8/9] RUN pnpm install --frozen-lockfile
#25 8.567 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn /usr/bin/python3
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args [
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp/gyp/gyp_main.py',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'binding.gyp',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-f',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'make',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build/config.gypi',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp/addon.gypi',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-I',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '/root/.cache/node-gyp/22.23.3/include/node/common.gypi',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dlibrary=shared_library',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dvisibility=default',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_root_dir=/root/.cache/node-gyp/22.23.3',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_gyp_dir=/root/.cache/node/corepack/v1/pnpm/12.11.2/dist/node_modules/node-gyp',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_lib_file=/root/.cache/node-gyp/22.23.3/<(target_arch)/node.lib',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dmodule_root_dir=/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Dnode_engine=v8',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--depth=.',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--no-parallel',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '--generator-output',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args 'build',
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args '-Goutput_dir=.'
#25 8.568 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args ]
#25 8.738 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn make
#25 8.738 .../node-pty@1.1.0/node_modules/node-pty install: gyp info spawn args [ 'BUILDTYPE=Release', '-C', 'build' ]
#25 8.739 .../node-pty@1.1.0/node_modules/node-pty install: make: Entering directory '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build'
#25 8.740 .../node-pty@1.1.0/node_modules/node-pty install:   TOUCH Release/obj.target/../../../node-addon-api@7.1.1/node_modules/node-addon-api/node_addon_api_except.stamp
#25 8.744 .../node-pty@1.1.0/node_modules/node-pty install:   CXX(target) Release/obj.target/pty/src/unix/pty.o
#25 10.04 .../node-pty@1.1.0/node_modules/node-pty install:   SOLINK_MODULE(target) Release/obj.target/pty.node
#25 10.09 .../node-pty@1.1.0/node_modules/node-pty install:   COPY Release/pty.node
#25 10.09 .../node-pty@1.1.0/node_modules/node-pty install: make: Leaving directory '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build'
#25 10.10 .../node-pty@1.1.0/node_modules/node-pty install: gyp info ok 
#25 10.11 .../node-pty@1.1.0/node_modules/node-pty install: Done
#25 10.11 .../node-pty@1.1.0/node_modules/node-pty postinstall$ node scripts/post-install.js
#25 10.15 .../node-pty@1.1.0/node_modules/node-pty postinstall: > Cleaning release folder...
#25 10.15 .../node-pty@1.1.0/node_modules/node-pty postinstall: > Moving conpty.dll...
#25 10.15 .../node-pty@1.1.0/node_modules/node-pty postinstall:   SKIPPED (not Windows)
#25 10.15 .../node-pty@1.1.0/node_modules/node-pty postinstall: Done
#25 10.37 
#25 10.37 devDependencies:
#25 10.37 + vitest 2.1.9
#25 10.37 
#25 10.37 Done in 8.1s using pnpm v12.11.2
#25 ...

#26 [gateway build 8/9] RUN pnpm install --frozen-lockfile
#26 9.114 .../node-pty@1.1.0/node_modules/node-pty install:   SOLINK_MODULE(target) Release/obj.target/pty.node
#26 9.138 .../node-pty@1.1.0/node_modules/node-pty install:   COPY Release/pty.node
#26 9.140 .../node-pty@1.1.0/node_modules/node-pty install: make: Leaving directory '/repo/node_modules/.pnpm/node-pty@1.1.0/node_modules/node-pty/build'
#26 9.142 .../node-pty@1.1.0/node_modules/node-pty install: gyp info ok 
#26 9.150 .../node-pty@1.1.0/node_modules/node-pty install: Done
#26 9.150 .../node-pty@1.1.0/node_modules/node-pty postinstall$ node scripts/post-install.js
#26 9.180 .../node-pty@1.1.0/node_modules/node-pty postinstall: > Cleaning release folder...
#26 9.184 .../node-pty@1.1.0/node_modules/node-pty postinstall: > Moving conpty.dll...
#26 9.184 .../node-pty@1.1.0/node_modules/node-pty postinstall:   SKIPPED (not Windows)
#26 9.192 .../node-pty@1.1.0/node_modules/node-pty postinstall: Done
#26 9.512 
#26 9.512 devDependencies:
#26 9.512 + vitest 2.1.9
#26 9.512 
#26 9.527 Done in 7.2s using pnpm v12.11.2
#26 DONE 10.8s

#27 [gateway build 9/9] RUN pnpm -r build
#27 0.529 packages/money build$ tsc -p tsconfig.json
#27 0.529 apps/watch build$ tsc -p tsconfig.json
#27 0.529 packages/shared build$ tsc -p tsconfig.json
#27 ...

#25 [mint build 8/9] RUN pnpm install --frozen-lockfile
#25 DONE 12.6s

#28 [mint build 9/9] RUN pnpm --filter @ovid/mint... build
#28 0.577 packages/shared build$ tsc -p tsconfig.json
#28 0.578 packages/money build$ tsc -p tsconfig.json
#28 1.997 packages/money build: Done
#28 4.231 packages/shared build: Done
#28 4.232 packages/db build$ tsc -p tsconfig.json
#28 7.907 packages/db build: Done
#28 7.907 apps/mint build$ tsc -p tsconfig.json
#28 ...

#27 [gateway build 9/9] RUN pnpm -r build
#27 2.295 apps/watch build: Done
#27 2.387 packages/money build: Done
#27 4.958 packages/shared build: Done
#27 4.958 packages/events build$ tsc -p tsconfig.json
#27 4.958 packages/db build$ tsc -p tsconfig.json
#27 4.958 packages/browser build$ tsc -p tsconfig.json
#27 4.961 packages/mcp build$ tsc -p tsconfig.json
#27 9.777 packages/browser build: Done
#27 9.777 packages/queue build$ tsc -p tsconfig.json
#27 11.23 packages/events build: Done
#27 11.23 packages/storage build$ tsc -p tsconfig.json
#27 12.28 packages/mcp build: Done
#27 12.46 packages/db build: Done
#27 12.46 apps/mint build$ tsc -p tsconfig.json
#27 12.46 packages/account build$ tsc -p tsconfig.json
#27 16.02 packages/queue build: Done
#27 16.02 packages/agent-core build$ tsc -p tsconfig.json
#27 16.21 packages/account build: Done
#27 16.21 packages/escrow build$ tsc -p tsconfig.json && chmod +x dist/rotateMasterKey.js
#27 19.74 packages/storage build: Done
#27 19.74 packages/sandbox build$ tsc -p tsconfig.json && chmod +x dist/renderNftCli.js
#27 19.78 packages/escrow build: Done
#27 19.78 apps/gateway build$ tsc -p tsconfig.json
#27 ...

#28 [mint build 9/9] RUN pnpm --filter @ovid/mint... build
#28 18.59 apps/mint build: Done
#28 DONE 18.7s

#29 [mint stage-1  7/15] COPY packages/money/package.json packages/money/
#29 CACHED

#30 [mint stage-1 12/15] COPY --from=build /repo/packages/money/dist ./packages/money/dist
#30 CACHED

#31 [mint stage-1  9/15] COPY --from=build /repo/packages/shared/dist ./packages/shared/dist
#31 CACHED

#32 [mint stage-1 13/15] COPY --from=build /repo/apps/mint/dist ./apps/mint/dist
#32 CACHED

#33 [mint stage-1  6/15] COPY packages/db/package.json packages/db/
#33 CACHED

#34 [mint stage-1 10/15] COPY --from=build /repo/packages/db/dist ./packages/db/dist
#34 CACHED

#35 [mint stage-1  4/15] COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
#35 CACHED

#36 [mint stage-1  5/15] COPY packages/shared/package.json packages/shared/
#36 CACHED

#37 [mint stage-1 11/15] COPY --from=build /repo/packages/db/drizzle ./packages/db/drizzle
#37 CACHED

#38 [mint stage-1  8/15] COPY apps/mint/package.json apps/mint/
#38 CACHED

#39 [mint stage-1 14/15] RUN pnpm install --frozen-lockfile --prod
#39 CACHED

#40 [mint stage-1  3/15] RUN corepack enable
#40 CACHED

#41 [mint stage-1 15/15] RUN mkdir -p /data && chown node:node /data
#41 CACHED

#27 [gateway build 9/9] RUN pnpm -r build
#27 ...

#42 [mint] exporting to image
#42 exporting layers done
#42 exporting manifest sha256:b7c6b2c7ba1fc0ae126b81afc2f2236e5bc0323cc355df4e29b147ac7d73d9e7 done
#42 exporting config sha256:3ed1536c442de35cc5a525d4bc88142e03622dfec8fdab74d90fe7749524af91 done
#42 exporting attestation manifest sha256:db450aa3b7cf9e5e306e0559e8c2a9bc4229a856a52c79d74adf6760905e3053 done
#42 exporting manifest list sha256:6743ae44e0abc92d81858e73a8b48964d7e471ef42c2fad49770934fe3b76703 done
#42 naming to docker.io/library/ovid-cloud-staging-mint:latest done
#42 unpacking to docker.io/library/ovid-cloud-staging-mint:latest done
#42 DONE 0.1s

#43 [mint] resolving provenance for metadata file
#43 DONE 0.0s

#27 [gateway build 9/9] RUN pnpm -r build
#27 21.48 packages/agent-core build: Done
#27 23.90 packages/sandbox build: Done
#27 23.90 apps/worker build$ tsc -p tsconfig.json
#27 24.69 apps/gateway build: Done
#27 26.81 apps/mint build: Done
#27 27.99 apps/worker build: Done
#27 27.99 apps/e2e build$ tsc -p tsconfig.json
#27 27.99 apps/load build$ tsc -p tsconfig.json
#27 29.09 apps/e2e build: Done
#27 31.36 apps/load build: Done
#27 DONE 31.4s

#44 [gateway stage-1  4/27] COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
#44 CACHED

#45 [gateway stage-1  7/27] COPY packages/events/package.json packages/events/
#45 CACHED

#46 [gateway stage-1 11/27] COPY packages/escrow/package.json packages/escrow/
#46 CACHED

#47 [gateway stage-1 23/27] COPY --from=build /repo/packages/account/dist ./packages/account/dist
#47 CACHED

#48 [gateway stage-1 25/27] COPY --from=build /repo/packages/mcp/dist ./packages/mcp/dist
#48 CACHED

#49 [gateway stage-1  3/27] RUN corepack enable
#49 CACHED

#50 [gateway stage-1 10/27] COPY packages/account/package.json packages/account/
#50 CACHED

#51 [gateway stage-1 21/27] COPY --from=build /repo/packages/queue/dist ./packages/queue/dist
#51 CACHED

#52 [gateway stage-1 20/27] COPY --from=build /repo/packages/events/dist ./packages/events/dist
#52 CACHED

#53 [gateway stage-1 19/27] COPY --from=build /repo/packages/db/drizzle ./packages/db/drizzle
#53 CACHED

#54 [gateway stage-1  6/27] COPY packages/db/package.json packages/db/
#54 CACHED

#55 [gateway stage-1 14/27] COPY apps/worker/package.json apps/worker/
#55 CACHED

#56 [gateway stage-1 26/27] COPY --from=build /repo/apps/gateway/dist ./apps/gateway/dist
#56 CACHED

#57 [gateway stage-1  5/27] COPY packages/shared/package.json packages/shared/
#57 CACHED

#58 [gateway stage-1 17/27] COPY --from=build /repo/packages/shared/dist ./packages/shared/dist
#58 CACHED

#59 [gateway stage-1 18/27] COPY --from=build /repo/packages/db/dist ./packages/db/dist
#59 CACHED

#60 [gateway stage-1 12/27] COPY packages/mcp/package.json packages/mcp/
#60 CACHED

#61 [gateway stage-1 15/27] COPY apps/e2e/package.json apps/e2e/
#61 CACHED

#62 [gateway stage-1 16/27] COPY apps/mint/package.json apps/mint/
#62 CACHED

#63 [gateway stage-1  9/27] COPY packages/storage/package.json packages/storage/
#63 CACHED

#64 [gateway stage-1 13/27] COPY apps/gateway/package.json apps/gateway/
#64 CACHED

#65 [gateway stage-1  8/27] COPY packages/queue/package.json packages/queue/
#65 CACHED

#66 [gateway stage-1 22/27] COPY --from=build /repo/packages/storage/dist ./packages/storage/dist
#66 CACHED

#67 [gateway stage-1 24/27] COPY --from=build /repo/packages/escrow/dist ./packages/escrow/dist
#67 CACHED

#68 [gateway stage-1 27/27] RUN pnpm install --frozen-lockfile --prod
#68 CACHED

#69 [gateway] exporting to image
#69 exporting layers done
#69 exporting manifest sha256:3ef367adc9a24a70e9a469c19445ea224287ac6068c0f74f3a121f421e4f2dfb
#69 exporting manifest sha256:3ef367adc9a24a70e9a469c19445ea224287ac6068c0f74f3a121f421e4f2dfb done
#69 exporting config sha256:89beb99a86816a78b250c546803fac0a53bba984541fa502c4af4f2bd74869dc done
#69 exporting attestation manifest sha256:72d7f215bb2da271111bd8d31b80b0c87ce1845931a850f540e599e7bba9a7d8 done
#69 exporting manifest list sha256:756cb77b8e63d91830144416529ae6fa835fece9f2c196997275dab137600248 done
#69 naming to docker.io/library/ovid-cloud-staging-gateway:latest done
#69 unpacking to docker.io/library/ovid-cloud-staging-gateway:latest done
#69 DONE 0.1s

#70 [gateway] resolving provenance for metadata file
#70 DONE 0.0s
 Image ovid-cloud-staging-mint Built 
 Image ovid-cloud-staging-gateway Built 
 Container ovid-cloud-staging-postgres-1 Running 
 Container ovid-cloud-staging-redis-q-1 Running 
 Container ovid-cloud-staging-redis-mint-1 Running 
 Container ovid-cloud-staging-mock-llm-1 Creating 
 Container ovid-cloud-staging-mint-1 Creating 
 Container ovid-cloud-staging-mock-llm-1 Created 
 Container ovid-cloud-staging-mint-1 Created 
 Container ovid-cloud-staging-gateway-1 Creating 
 Container ovid-cloud-staging-gateway-1 Created 
 Container ovid-cloud-staging-mock-llm-1 Starting 
 Container ovid-cloud-staging-postgres-1 Waiting 
 Container ovid-cloud-staging-redis-mint-1 Waiting 
 Container ovid-cloud-staging-mock-llm-1 Started 
 Container ovid-cloud-staging-redis-mint-1 Healthy 
 Container ovid-cloud-staging-postgres-1 Healthy 
 Container ovid-cloud-staging-mint-1 Starting 
 Container ovid-cloud-staging-mint-1 Started 
 Container ovid-cloud-staging-redis-q-1 Waiting 
 Container ovid-cloud-staging-postgres-1 Waiting 
 Container ovid-cloud-staging-mint-1 Waiting 
 Container ovid-cloud-staging-redis-q-1 Healthy 
 Container ovid-cloud-staging-postgres-1 Healthy 
 Container ovid-cloud-staging-mint-1 Healthy 
 Container ovid-cloud-staging-gateway-1 Starting 
 Container ovid-cloud-staging-gateway-1 Started 
[staging] loaded staging egress table inet sandbox_egress_staging (uids 220000-229999)
[staging] waiting for the staging mint boot re-sync (redis-mint db2 config:limits)
[staging] mint projection ready (config:limits present on redis-mint db2)
[staging] polling http://127.0.0.1:18082/cloud/v1/health
[staging] gateway healthy: {"status":"ok","checks":{"db":true,"redisQ":true}}
[staging] live stack unchanged (healthz=200, every ovid-gateway-* Up, StartedAt identical)
[staging] staging up: gateway http://127.0.0.1:18082 (mock 14000, mint 18091/18092)
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] mock LiteLLM already listening on 127.0.0.1:14000 (staging compose service) — nothing to do
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] starting staging worker (workspaces /workspaces-staging, uid base 220000)
[staging] staging worker pid 3846486 (pidfile /tmp/opencode/ovid-staging-worker.pid, log /tmp/opencode/ovid-staging-worker.log)
LIVE CHECK (after):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
~~~

### GATE 4 full-suite-and-security — PASS

~~~text
gate 4: dedicated test database ovid_accept_3840286 (staging DB untouched)
gate 4: dedicated test Redis on 127.0.0.1:32774
Scope: 18 of 19 workspace projects
$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/watch

 ✓ src/checks.test.ts (17 tests) 10ms
 ✓ src/main.test.ts (5 tests) 28ms
 ✓ src/alertState.test.ts (9 tests) 7ms
 ✓ src/alertSink.test.ts (8 tests) 37ms

 Test Files  4 passed (4)
      Tests  39 passed (39)
   Start at  15:43:34
   Duration  976ms (transform 117ms, setup 0ms, collect 214ms, tests 82ms, environment 1ms, prepare 212ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/money

 ✓ src/money.test.ts (18 tests) 12ms
 ✓ src/pyCompat.test.ts (10 tests) 9ms

 Test Files  2 passed (2)
      Tests  28 passed (28)
   Start at  15:43:35
   Duration  367ms (transform 130ms, setup 0ms, collect 178ms, tests 21ms, environment 0ms, prepare 136ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/shared

 ✓ src/workspace.test.ts (27 tests) 28ms
 ✓ src/events.test.ts (12 tests) 16ms
 ✓ src/rest.test.ts (21 tests) 31ms
 ✓ src/schedules.test.ts (25 tests) 21ms
 ✓ src/ws.test.ts (26 tests) 29ms
 ✓ src/triggers.test.ts (30 tests) 107ms
 ✓ src/pty.test.ts (14 tests) 30ms
 ✓ src/internalAuth.test.ts (8 tests) 6ms
 ✓ src/browser.test.ts (16 tests) 11ms
 ✓ src/system.test.ts (12 tests) 26ms
 ✓ src/notifications.test.ts (9 tests) 19ms

 Test Files  11 passed (11)
      Tests  200 passed (200)
   Start at  15:43:36
   Duration  942ms (transform 471ms, setup 0ms, collect 1.33s, tests 325ms, environment 2ms, prepare 1.04s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/browser

stderr | src/bridge.test.ts > createRedisBrowserBridge (real redis, harness plays the gateway) > a stale viewer is swept to zero without any leave (gateway crash ⇒ screencast stops)
[browser-bridge] viewer sweep dropped 1 stale viewer(s) on session f7bf5b00-7fbd-4399-9c42-770fa4049ed8 

stderr | src/bridge.test.ts > createRedisBrowserBridge (real redis, harness plays the gateway) > delivers only schema-valid input events, in arrival order, surviving bad payloads
[browser-bridge] ignoring schema-invalid input event on browser:d3901203-2bba-4a50-befd-2ae6e90466aa:input 
[browser-bridge] ignoring malformed input JSON on browser:d3901203-2bba-4a50-befd-2ae6e90466aa:input: not-json 

 ✓ src/lightpanda.test.ts (12 tests | 9 skipped) 19ms
 ✓ src/bridge.test.ts (11 tests) 573ms
 ✓ src/storageState.test.ts (18 tests) 94ms
 ✓ src/researchBrowser.test.ts (12 tests) 170ms
 ✓ src/stateStore.test.ts (13 tests) 200ms
 ✓ src/config.test.ts (18 tests) 48ms
 ✓ src/sessions.test.ts (25 tests) 3261ms
   ✓ BrowserSessionRegistry (chromium) > open() returns an entry with tabs.length===1, activeIndex===0, instrumented page 310ms
   ✓ BrowserSessionRegistry (chromium) > console buffer cap: 250 logs → length 200, newest present, oldest gone 364ms
   ✓ BrowserSessionRegistry (chromium) > addTab: 2 tabs, active switched, new tab instrumented into the SHARED buffer 509ms
   ✓ BrowserSessionRegistry (chromium) > closeTab(0) with two tabs: page closed, remaining tab active; last tab refused 350ms
   ✓ BrowserSessionRegistry (chromium) > popup: window.open records the URL and closes the popup page 382ms
 ✓ src/uidDrop.test.ts (10 tests) 232ms
 ✓ src/screencast.test.ts (13 tests) 3209ms
   ✓ screencast (chromium) > startScreencast(jpeg) on /animated: ≥3 frames in ≤10 s, every frame jpeg-magic, framesSent() matches 687ms
   ✓ screencast (chromium) > stop(): no further frames for 500 ms, and a second stop() resolves without throwing 818ms
   ✓ screencast (chromium) > adjust({quality:40,everyNthFrame:4}) keeps delivering frames afterwards (stop+restart, same format) 522ms
   ✓ screencast (chromium) > captureScreenshot: default jpeg q70 → FFD8 magic and >1 KB; explicit png → PNG magic 435ms
 ✓ src/pool.test.ts (13 tests) 4866ms
   ✓ BrowserPool > acquireLive lazily launches chromium and returns a handle whose page navigates to the fixture 421ms
   ✓ BrowserPool > wires the prepared uid-drop shim into chromium.launch (executablePath/env/downloadsPath) 419ms
   ✓ BrowserPool > re-acquiring the same sessionId returns the SAME handle object (touch, no new context) 318ms
   ✓ BrowserPool > queues a 3rd distinct live session and admits waiters in FIFO enqueue order 596ms
   ✓ BrowserPool > rejects a live waiter that exceeds queueTimeoutMs with BrowserPoolBusyError 413ms
   ✓ BrowserPool > tier-1 leases queue beyond tier1FallbackContexts and release() frees the slot 384ms
   ✓ BrowserPool > isolation pin: cookies set in session s1's context are invisible to session s2 (Review Focus #1) 366ms
   ✓ BrowserPool > close() rejects queued waiters, zeroes stats, and kills the browser process (Review Focus #2) 315ms
   ✓ BrowserPool > health: browser death rejects all waiters, clears maps, and the next acquire relaunches 572ms
 ✓ src/url.test.ts (15 tests) 46ms
 ✓ src/staticExtract.test.ts (9 tests) 54ms
 ✓ src/input.test.ts (12 tests) 2291ms
 ✓ src/engine.test.ts (11 tests) 7004ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > openSession: the peer sees {live:true} once a viewer joins (the screencast-start publish) 728ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > viewer_join starts the screencast: ≥1 frame within 10 s, prefix byte matches the published frameFormat, and the probe restored the user's page 985ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > viewer_leave stops the cast: frames go quiet (500 ms) and screencastCount()===0 1346ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > input through the peer flips the /click fixture to CLICKED (end-to-end injection, arrival-ordered) 723ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > takeover ctl flags the registry, publishes takeover state, and a tool call returns exactly TAKEOVER_REFUSAL 505ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > state publish includes url/title after browser_open via engine.tools 318ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > idle eviction: injected clock + idleEvictMs:200 ⇒ the peer sees {live:false} and persistence received the login_tok cookie state 353ms
   ✓ BrowserEngine facade (real redis + chromium, harness plays the gateway) > close() flushes a session that was never published: goto timeout AFTER Set-Cookie still persists the cookie (I1) 1748ms
 ✓ src/tools/toolsInteraction.test.ts (31 tests) 9522ms
   ✓ browser tools II > browser_click clicks the fixture button 738ms
   ✓ browser tools II > browser_click reports a missing selector without throwing 358ms
   ✓ browser tools II > browser_double_click and browser_hover reach the fixture 495ms
   ✓ browser tools II > browser_tap_at maps through applyInputEvent 452ms
   ✓ browser tools II > browser_swipe maps through applyInputEvent and clicks 386ms
   ✓ browser tools II > browser_long_press holds for the requested duration 486ms
   ✓ browser tools II > browser_long_press resolves a selector to its box center 508ms
   ✓ browser tools II > browser_drag drops between the fixture drop zones 475ms
   ✓ browser tools II > browser_type fills and submits through the fixture form handler 388ms
   ✓ browser tools II > browser_fill fills every field in order 427ms
   ✓ browser tools II > browser_fill reports MISSING and continues (Dart parity) 321ms
   ✓ browser tools II > browser_scroll scrolls the page down and reports the new position 1293ms
 ✓ src/tools/toolsNavigation.test.ts (24 tests) 18152ms
   ✓ browser tools I > browser_open returns title + final URL + article markdown and notifies once 477ms
   ✓ browser tools I > browser_navigate is the same implementation as browser_open 349ms
   ✓ browser tools I > opens the same session twice on one live context 565ms
   ✓ browser tools I > browser_back / forward / reload report title + url 543ms
   ✓ browser tools I > browser_read extracts markdown and caps it with a truncation note 3337ms
   ✓ browser tools I > browser_outline lists the fixture button and form field 324ms
   ✓ browser tools I > browser_snapshot returns an accessibility tree containing the button 312ms
   ✓ browser tools I > browser_wait_for returns timeout as a result, never an error 376ms
   ✓ browser tools I > browser_wait_for timeoutMs:0 is clamped to the 10s default (never an infinite wait) 10222ms

 Test Files  16 passed (16)
      Tests  238 passed | 9 skipped (247)
   Start at  15:43:37
   Duration  19.83s (transform 1.11s, setup 0ms, collect 10.61s, tests 49.74s, environment 4ms, prepare 1.87s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/db

 ✓ src/moneyRepos.test.ts (9 tests) 791ms
 ✓ src/repos.test.ts (14 tests) 692ms
 ✓ src/reposStorage.test.ts (10 tests) 639ms
 ✓ src/scheduleRepos.test.ts (12 tests) 646ms
 ✓ src/mcpRepos.test.ts (8 tests) 551ms
 ✓ src/scheduleService.test.ts (15 tests) 606ms
 ✓ src/repos.search.test.ts (10 tests) 758ms
 ✓ src/schemaTables.test.ts (4 tests) 496ms
 ✓ src/repos.grants.test.ts (4 tests) 492ms
 ✓ src/deviceRepos.test.ts (3 tests) 483ms
 ✓ src/migrate-cli.test.ts (5 tests) 2146ms
   ✓ migrate-cli against real postgres > applies migrations to a fresh database and exits 0 675ms
   ✓ migrate-cli against real postgres > is idempotent — a second run against the migrated database exits 0 413ms
   ✓ migrate-cli against real postgres > exits 1 with a diagnostic on an unreachable database 393ms
   ✓ migrate-cli against real postgres > exits 1 with usage when no DATABASE_URL argument is given 395ms

 Test Files  11 passed (11)
      Tests  94 passed (94)
   Start at  15:43:57
   Duration  14.52s (transform 306ms, setup 0ms, collect 4.42s, tests 8.30s, environment 2ms, prepare 572ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/events

 ✓ src/eventLog.test.ts (7 tests) 414ms
 ✓ src/systemBus.test.ts (4 tests) 612ms

 Test Files  2 passed (2)
      Tests  11 passed (11)
   Start at  15:44:12
   Duration  1.01s (transform 131ms, setup 0ms, collect 275ms, tests 1.03s, environment 0ms, prepare 111ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/mcp

 ✓ src/plugins/install.test.ts (25 tests) 621ms
 ✓ src/router.test.ts (26 tests) 2584ms
   ✓ McpRouter > a reconnect scheduled before the downgrade does not respawn for a Free user 814ms
   ✓ McpRouter > unexpected stdio exit schedules a reconnect; removeServer cancels it 1321ms
 ✓ src/oauth/flow.test.ts (17 tests) 282ms
 ✓ src/plugins/manifest.test.ts (36 tests) 99ms
 ✓ src/rest/engine.test.ts (38 tests) 34ms
 ✓ src/plugins/sources.test.ts (29 tests) 81ms
 ✓ src/oauth/discovery.test.ts (18 tests) 21ms
 ✓ src/clientRequests.test.ts (34 tests) 18ms
 ✓ src/native/filesystem.test.ts (18 tests) 12ms
 ✓ src/configParse.test.ts (30 tests) 16ms
 ✓ src/client.test.ts (19 tests) 25ms
 ✓ src/native/github.test.ts (13 tests) 14ms
 ✓ src/systemBus.test.ts (7 tests) 311ms
 ✓ src/native/memory.test.ts (11 tests) 9ms
 ✓ src/transports/http.test.ts (9 tests) 67ms
 ✓ src/plugins/archive.test.ts (19 tests) 172ms
 ✓ src/native/fetch.test.ts (13 tests) 14ms
 ✓ src/plugins/registry.test.ts (7 tests) 9ms
 ✓ src/catalog.test.ts (5 tests) 16ms
 ✓ src/crypto.test.ts (10 tests) 10ms
 ✓ src/transports/stdio.test.ts (6 tests) 6ms
 ✓ src/ssrf.test.ts (36 tests) 21ms
 ✓ src/transports/native.test.ts (4 tests) 6ms
 ✓ src/backoff.test.ts (7 tests) 7ms
 ✓ src/transports/sse.test.ts (3 tests) 67ms
 ✓ src/plugins/grants.test.ts (6 tests) 5ms
 ✓ src/toolNames.test.ts (6 tests) 4ms

 Test Files  27 passed (27)
      Tests  452 passed (452)
   Start at  15:44:13
   Duration  11.07s (transform 637ms, setup 0ms, collect 2.35s, tests 4.53s, environment 5ms, prepare 1.36s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/queue

 ✓ src/pluginQueue.test.ts (10 tests) 74ms
 ✓ src/queues.test.ts (37 tests) 166ms

 Test Files  2 passed (2)
      Tests  47 passed (47)
   Start at  15:44:25
   Duration  663ms (transform 151ms, setup 0ms, collect 558ms, tests 240ms, environment 0ms, prepare 114ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/storage

 ✓ src/archive/pack.test.ts (11 tests) 249ms
 ✓ src/artifacts.test.ts (7 tests) 210ms
 ✓ src/archive/uiTree.test.ts (9 tests) 121ms
 ✓ src/sweeper.test.ts (6 tests) 258ms
 ✓ src/hibernate.test.ts (14 tests) 453ms
 ✓ src/archive/readIndex.test.ts (19 tests) 58ms
 ↓ src/r2.live.test.ts (4 tests | 4 skipped)
 ✓ src/warmLru.test.ts (15 tests) 504ms
 ✓ src/activity.test.ts (10 tests) 32ms
 ✓ src/workspacePaths.test.ts (6 tests) 26ms
 ✓ src/archive/recover.test.ts (8 tests) 69ms
 ✓ src/r2Adapter.test.ts (16 tests) 50ms
 ✓ src/fsAdapter.test.ts (16 tests) 376ms
 ✓ src/hydrate.test.ts (23 tests) 1136ms
 ✓ src/prefixDeleter.test.ts (6 tests) 20ms
 ✓ src/storageEnv.test.ts (15 tests) 14ms
 ✓ src/archive/zstdFrames.test.ts (12 tests) 478ms
 ✓ src/keys.test.ts (10 tests) 7ms
 ✓ src/browserState.test.ts (5 tests) 40ms
 ✓ src/rangeReader.test.ts (5 tests) 18ms
 ✓ src/sandboxEviction.test.ts (3 tests) 23ms
 ✓ src/archive/extract.test.ts (16 tests) 2843ms
   ✓ extract — read path over a rich fixture > (d) extractAll workers=1 restores the tree byte-exactly 727ms
   ✓ extract — read path over a rich fixture > (d) extractAll workers=4 (worker_threads) restores the tree byte-exactly 446ms
   ✓ extract — read path over a rich fixture > extractAll restoreMeta=false writes contents without modes/mtimes 364ms

 Test Files  21 passed | 1 skipped (22)
      Tests  232 passed | 4 skipped (236)
   Start at  15:44:26
   Duration  3.86s (transform 1.16s, setup 0ms, collect 7.95s, tests 6.99s, environment 4ms, prepare 1.44s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/mint

 ✓ src/images/routes.test.ts (29 tests) 250ms
stdout | src/adminRoutes.test.ts > /admin JSON API + console (adminRoutes.ts) > I3: a Redis projection failure after the Postgres commit is a sanitized 500, logged and audited
[mint] settings projection failed after postgres commit: Error

stdout | src/adminRoutes.test.ts > /admin JSON API + console (adminRoutes.ts) > I3: a Redis projection failure after the Postgres commit is a sanitized 500, logged and audited
[mint] user update projection failed after postgres commit: Error

 ✓ src/adminRoutes.test.ts (33 tests) 3362ms
   ✓ /admin JSON API + console (adminRoutes.ts) > plans-as-data: add, edit, disable (stop selling) keeps existing users, re-enable 321ms
   ✓ /admin JSON API + console (adminRoutes.ts) > audit list is newest-first and the JSONL file mirrors it oldest-first 437ms
   ✓ /admin JSON API + console (adminRoutes.ts) > I1: {all:true} is the explicit ALL-users shape; reset_month_free:'false' stays false 339ms
   ✓ /admin JSON API + console (adminRoutes.ts) > I4: all-users operations only touch mint-provisioned users (chat-only rows excluded) 395ms
 ✓ src/planMath.test.ts (62 tests) 25ms
stdout | src/mintRoutes.test.ts > public mint endpoints (mintRoutes.ts) > upstream error matrix matches _catalog_error
[mint] model catalog upstream status 401
[mint] model catalog upstream status 403
[mint] model catalog upstream status 400
[mint] model catalog upstream status 401
[mint] model catalog upstream status 429
[mint] model catalog upstream status 429
[mint] model catalog upstream status 502
[mint] model catalog upstream status 500

stdout | src/mintRoutes.test.ts > public mint endpoints (mintRoutes.ts) > network failure → 503 catalog_unavailable
[mint] model catalog failed: Error

 ✓ src/mintRoutes.test.ts (26 tests) 868ms
 ✓ src/images/probes.test.ts (23 tests) 44ms
 ✓ src/images/ledger.test.ts (26 tests) 796ms
 ✓ src/usage.test.ts (16 tests) 887ms
 ✓ src/billing/service.test.ts (18 tests) 583ms
 ✓ src/billing/routes.test.ts (13 tests) 1060ms
stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > serves a default card until the background tick, then a probed one
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > stores the static card before spending on probes
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > re-extracts on a fingerprint change and keeps history
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > re-probes weekly and on an admin force
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > backs off exponentially after a transient failure
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > cards survive a restart (same store, no runner)
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > cards survive a restart (same store, no runner)
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > without a probe key only the static card is published
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > uses provider metadata when the base URL exposes it
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > M3: copies edit_transport from discovered params so DirectEdit is reachable
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > tracks priced state live and warns once per unpriced model
[mint] unpriced image model "u/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > CardManager + Postgres CardStore (cardmanager.py / cardstore.py) > L5: the catalog projection is live, not a boot snapshot
[mint] unpriced image model "cb/one" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)
[mint] unpriced image model "cb/two" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > images admin routes (admin.py) > rejects a missing or wrong master key with the exact forbidden body
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > images admin routes (admin.py) > returns cards with history/probe_state and the probe budget, no-store
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > images admin routes (admin.py) > refresh-prices returns the live priced map
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > images admin routes (admin.py) > reprobe accepts a model or slug, rejects unknown, and validates the body
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

stderr | src/images/cardManager.test.ts > images admin routes (admin.py) > maps malformed and unsupported-content-type reprobe bodies to invalid_request
[mint] unpriced image model "cb/m" discovered: unpriced: set the model's price in LiteLLM (input/output cost per token, or output cost per image) (user traffic is skipped until priced)

 ✓ src/images/cardManager.test.ts (18 tests) 1458ms
 ✓ src/windows.test.ts (16 tests) 792ms
stdout | src/litellmAdmin.test.ts > keyUpdate > 4xx → resolves (logged, not thrown) — Python parity: failures print status
[mint] key/update 400

stdout | src/litellmAdmin.test.ts > keyUpdate > keyUpdateStatus returns the HTTP status (0 on a network error)
[mint] key/update 400
[mint] key/update error: TypeError

 ✓ src/litellmAdmin.test.ts (27 tests) 144ms
 ✓ src/images/capabilities.test.ts (22 tests) 16ms
 ✓ src/images/routing.test.ts (20 tests) 14ms
 ✓ src/images/costing.test.ts (20 tests) 15ms
stdout | src/keyMint.test.ts > key minting (keyMint.ts) > re-issues an unusable (404/expired) stored key after /key/delete
[mint] re-issuing unusable key for dead-m

stdout | src/keyMint.test.ts > key minting (keyMint.ts) > re-issues an unusable (404/expired) stored key after /key/delete
[mint] key/delete 404

 ✓ src/keyMint.test.ts (10 tests) 718ms
 ✓ src/projection.test.ts (7 tests) 997ms
   ✓ db2 projection > importFromRedisOnce: one-shot seeding of Postgres from live db2 (never deletes) 454ms
 ✓ src/slowMode.test.ts (8 tests) 614ms
stdout | src/antiAbuse.test.ts > anti-abuse (antiAbuse.ts) > 13th new signup in the window → 429 exact detail, and the IP is NOT banned
[mint] ALERT signup_velocity: IP 203.0.113.12 exceeded 12 new accounts / window

 ✓ src/antiAbuse.test.ts (9 tests) 125ms
 ✓ src/billing/domain.test.ts (14 tests) 11ms
 ✓ src/images/directEdit.test.ts (8 tests) 29ms
 ✓ src/hookContract.test.ts (11 tests) 518ms
 ✓ src/internalRoutes.test.ts (7 tests) 717ms
 ✓ src/env.test.ts (25 tests) 11ms
stdout | src/adminAudit.test.ts > audit() (adminAudit.ts) > a failing sink is logged, never thrown (redis down / db down / missing state dir)
[mint] audit redis error: Error
[mint] audit db error: Error

 ✓ src/adminAudit.test.ts (3 tests) 6592ms
   ✓ audit() (adminAudit.ts) > caps the Redis list at AUDIT_MAX (5001 writes → LLEN 5000) but never trims Postgres or the file 6100ms
 ✓ src/settings.test.ts (7 tests) 1435ms
   ✓ settings authority (Postgres) > an existing install (users, no settings) seeds paid windows at 720h 446ms
   ✓ settings authority (Postgres) > getOverride / userFreeDaily read the per-user override from Postgres 468ms
 ✓ src/images/admission.test.ts (9 tests) 8ms
 ✓ src/billing/tierSink.test.ts (4 tests) 479ms
 ✓ src/app.test.ts (6 tests) 95ms
 ✓ src/images/discovery.test.ts (4 tests) 4ms
stdout | src/alerts.test.ts > createAlerter > sends at most once per bucket and carries an abort timeout
[mint] ALERT daily_spend: over

stdout | src/alerts.test.ts > createAlerter > never throws when delivery fails
[mint] ALERT x: y
[mint] alert send failed: Error

 ✓ src/alerts.test.ts (2 tests) 10ms
 ✓ src/images/extraction.test.ts (2 tests) 4ms

 Test Files  32 passed (32)
      Tests  505 passed (505)
   Start at  15:44:30
   Duration  39.58s (transform 696ms, setup 0ms, collect 11.80s, tests 22.68s, environment 5ms, prepare 1.64s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/account

 ✓ src/adapters.test.ts (21 tests) 808ms
 ✓ src/domain.test.ts (36 tests) 28ms
 ✓ src/store.test.ts (4 tests) 520ms

 Test Files  3 passed (3)
      Tests  61 passed (61)
   Start at  15:45:10
   Duration  3.07s (transform 205ms, setup 0ms, collect 1.21s, tests 1.36s, environment 0ms, prepare 150ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/escrow

 ✓ src/envelope.test.ts (10 tests) 10ms
 ✓ src/endpoints.test.ts (21 tests) 36ms
 ✓ src/address.test.ts (31 tests) 12ms
 ✓ src/provider.test.ts (5 tests) 73ms
 ✓ src/rotateMasterKey.test.ts (6 tests) 127ms

 Test Files  5 passed (5)
      Tests  73 passed (73)
   Start at  15:45:13
   Duration  981ms (transform 372ms, setup 0ms, collect 1.59s, tests 258ms, environment 1ms, prepare 320ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/sandbox

 ↓ src/cgroups.host.test.ts (5 tests | 5 skipped)
 ↓ src/pty.host.test.ts (10 tests | 10 skipped)
 ✓ src/verification/isolation.test.ts (13 tests | 8 skipped) 115ms
 ↓ src/exec.host.test.ts (9 tests | 9 skipped)
 ✓ src/exec.test.ts (22 tests) 237ms
 ✓ src/jobs.test.ts (17 tests) 242ms
stderr | src/manager.test.ts > disk guard > freeGb < minFreeGb ⇒ SandboxCapacityError(disk_pressure), slot released
sandbox attach: DISK PRESSURE — free 1.00 GB (min 2), warm 0.00 GB (max 8); refusing to create sandbox for u1

stderr | src/manager.test.ts > disk guard > warmGb >= maxWarmGb ⇒ the same SandboxCapacityError
sandbox attach: DISK PRESSURE — free 100.00 GB (min 2), warm 8.00 GB (max 8); refusing to create sandbox for u1
sandbox attach: DISK PRESSURE — free 100.00 GB (min 2), warm 8.00 GB (max 8); refusing to create sandbox for u1

 ✓ src/policy.test.ts (119 tests) 87ms
 ↓ src/caches.host.test.ts (5 tests | 5 skipped)
 ✓ src/invocation.test.ts (14 tests) 9ms
 ✓ src/manager.test.ts (22 tests) 528ms
 ↓ src/manager.host.test.ts (3 tests | 3 skipped)
 ✓ src/shims.test.ts (45 tests) 193ms
 ✓ src/cgroups.test.ts (14 tests) 102ms
 ✓ src/config.test.ts (6 tests) 7ms
 ✓ src/ring.test.ts (8 tests) 10ms
 ✓ src/etcFiles.test.ts (6 tests) 18ms
 ✓ src/rootfs.test.ts (11 tests) 51ms
 ✓ src/quota.test.ts (5 tests) 11ms
 ↓ src/net.host.test.ts (2 tests | 2 skipped)
 ✓ src/caches.test.ts (12 tests) 7ms
 ✓ src/net.test.ts (36 tests) 3134ms

 Test Files  15 passed | 6 skipped (21)
      Tests  342 passed | 42 skipped (384)
   Start at  15:45:14
   Duration  3.53s (transform 929ms, setup 0ms, collect 2.24s, tests 4.75s, environment 5ms, prepare 1.48s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/packages/agent-core

 ✓ src/hooks.test.ts (77 tests) 89ms
 ✓ src/transport/anthropic.test.ts (24 tests) 125ms
 ✓ src/tools/web.test.ts (21 tests) 99ms
 ✓ src/tools/git.test.ts (32 tests) 19ms
 ✓ src/roster.test.ts (39 tests) 33ms
 ✓ src/tools/sandboxTools.test.ts (26 tests) 28ms
 ✓ src/compaction/compaction.test.ts (39 tests) 646ms
 ✓ src/subagents.test.ts (19 tests) 135ms
 ✓ src/skillsLoader.test.ts (26 tests) 26ms
 ✓ src/ssrf.test.ts (78 tests) 147ms
 ✓ src/promptCache.test.ts (33 tests) 13ms
 ✓ src/commands.test.ts (38 tests) 14ms
 ✓ src/transport/openai.test.ts (19 tests) 209ms
 ✓ src/tools/memory.test.ts (17 tests) 30ms
 ✓ src/systemPrompt.test.ts (25 tests) 13ms
 ✓ src/guards.test.ts (35 tests) 10ms
 ✓ src/routing.test.ts (21 tests) 10ms
 ✓ src/grants.test.ts (19 tests) 9ms
 ✓ src/approvals.test.ts (25 tests) 848ms
 ✓ src/tools/structuredEdits.test.ts (28 tests) 13ms
 ✓ src/tools/goalsTodos.test.ts (11 tests) 14ms
 ✓ src/tools/spill.test.ts (12 tests) 14ms
 ✓ src/transport/legacy.test.ts (4 tests) 56ms
 ✓ src/tools/subagentTools.test.ts (16 tests) 15ms
 ✓ src/tools/sessionSearch.test.ts (8 tests) 9ms
 ✓ src/claudeCodeTools.test.ts (10 tests) 7ms
 ✓ src/engine.test.ts (10 tests) 344ms
 ✓ src/planMode.test.ts (7 tests) 6ms
 ✓ src/htmlToMarkdown.test.ts (11 tests) 11ms
 ✓ src/dependencyDirection.test.ts (1 test) 11ms
 ✓ src/loop.test.ts (55 tests) 1567ms
 ✓ src/steering.test.ts (6 tests) 189ms
 ✓ src/types.test.ts (9 tests) 5ms

 Test Files  33 passed (33)
      Tests  801 passed (801)
   Start at  15:45:18
   Duration  3.11s (transform 1.72s, setup 0ms, collect 7.03s, tests 4.76s, environment 6ms, prepare 2.20s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/gateway

 ✓ src/ws.test.ts (30 tests) 2766ms
   ✓ gateway /cloud/ws (real redis + postgres) > unsubscribe tears down that subscription only; the sibling keeps streaming 329ms
   ✓ gateway /cloud/ws (stub EventLog — deterministic replay/live race) > client dropping during the ticket verify never creates a subscription (no leaked redis subscriber) 460ms
   ✓ gateway /cloud/ws (stub EventLog — deterministic replay/live race) > I3 — subscription cap 64: 65th distinct session refused (too_many_subscriptions), re-subscribe replaces, unsubscribe frees a slot 351ms
 ✓ src/routes/workspace.test.ts (24 tests) 1336ms
   ✓ gateway workspace routes (real postgres + redis) > cold row that stays cold (hydrateWaitMs=300) → 202 {status:'hydrating'} and a hydrate job is queued 526ms
 ✓ src/routes/messages.test.ts (21 tests) 739ms
stderr | src/browserChannel.test.ts > gateway /cloud/ws browser_* ops (real redis + postgres) > browser_attach: viewer_join on ctl; nothing until the worker publishes; invalid state dropped; state + binary frame relayed (prefix stripped)
[browser-channel] ignoring schema-invalid state payload on browser:01a14fb0-8886-7b3b-bf81-d4e251f0f280:state 

 ✓ src/browserChannel.test.ts (12 tests) 2353ms
   ✓ gateway /cloud/ws browser_* ops (real redis + postgres) > browser_attach: viewer_join on ctl; nothing until the worker publishes; invalid state dropped; state + binary frame relayed (prefix stripped) 542ms
   ✓ gateway /cloud/ws browser_* ops (real redis + postgres) > browser_detach → viewer_leave + connections quit; a later socket close publishes NO second leave 594ms
   ✓ handleWsConnection browser channel (stub socket, real redis) > slow client: a frame buffered above the high-water is DROPPED; the connection stays open and later frames flow 362ms
 ✓ src/shares/routes.test.ts (16 tests) 511ms
 ✓ src/routes/schedules.test.ts (11 tests) 297ms
 ✓ src/routes/sessions.test.ts (16 tests) 248ms
 ✓ src/routes/byok.test.ts (13 tests) 504ms
 ✓ src/routes/mcpServers.test.ts (12 tests) 249ms
 ✓ src/routes/plugins.test.ts (11 tests) 223ms
 ✓ src/wsPty.test.ts (8 tests) 723ms
   ✓ createRedisPtyBridge (real redis, harness plays the worker) > attach — Review Focus #3: pty:out subscribed BEFORE the ctl publish; a live chunk covered by the snapshot is dropped (snapshot wins), a chunk beyond endOffset arrives 323ms
 ✓ src/auth.test.ts (22 tests) 102ms
 ✓ src/routes/runs.test.ts (7 tests) 238ms
 ✓ src/routes/events.test.ts (10 tests) 1284ms
   ✓ gateway session-event routes (real postgres) > limit clamps: 0/negative/garbage → default 200; >1000 → 1000 775ms
 ✓ src/routes/mcpOauth.test.ts (8 tests) 211ms
stderr | src/routes/attachments.test.ts > gateway attachment routes (real postgres) > no presigner configured → loud 503 attachments_not_configured (never a silent no-op, never a 500)
[gateway] attachment upload refused: no presigner configured (GatewayDeps.presigner missing)

 ✓ src/routes/attachments.test.ts (8 tests) 256ms
 ✓ src/routes/import.test.ts (7 tests) 317ms
 ✓ src/ws.approval.test.ts (5 tests) 1024ms
 ✓ src/internalMint.test.ts (7 tests) 201ms
 ✓ src/routes/artifacts.test.ts (2 tests) 193ms
 ✓ src/routes/reports.test.ts (7 tests) 293ms
 ✓ src/systemChannel.test.ts (6 tests) 675ms
 ✓ src/routes/account.test.ts (8 tests) 80ms
 ✓ src/shares/snapshot.test.ts (51 tests) 30ms
 ✓ src/routes/devices.test.ts (7 tests) 154ms
 ✓ src/shutdown.test.ts (1 test) 1002ms
   ✓ gateway SIGTERM drain (real process) > SIGTERM closes the live WS with 1001 'server restarting' and the process exits 0 1001ms
 ✓ src/routes/health.test.ts (7 tests) 1190ms
   ✓ GET /cloud/v1/health > hung backends hit the ~1s probe timeout instead of hanging the request 1009ms
 ✓ src/routes/mcpCatalog.test.ts (2 tests) 146ms
 ✓ src/routes/systemResponses.test.ts (3 tests) 115ms
 ✓ src/tickets.test.ts (6 tests) 20ms
 ✓ src/app.test.ts (4 tests) 98ms
 ✓ src/keys.test.ts (1 test) 14ms

 Test Files  32 passed (32)
      Tests  353 passed (353)
   Start at  15:45:22
   Duration  45.47s (transform 830ms, setup 0ms, collect 22.64s, tests 17.59s, environment 6ms, prepare 1.65s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/worker

 ✓ src/runProcessor.test.ts (44 tests) 4301ms
   ✓ createAgentRunProcessor (real Postgres + real Redis event log) > cancel checks are throttled to one per second: a flip inside the window is caught by the next windowed check 1123ms
   ✓ createAgentRunProcessor (real Postgres + real Redis event log) > v1 transport always returning a tool call → tool_rounds_exhausted after exactly 50 rounds, unknown_tool result each round 345ms
   ✓ createAgentRunProcessor (real Postgres + real Redis event log) > P3 compat: cancel-then-next-run — the cancelled run's terminal event precedes the successor's run_started 540ms
   ✓ createAgentRunProcessor (real Postgres + real Redis event log) > full processor: unattended approval timeout → approval_resolved{unattended_timeout}, DENIED tool result, run CONTINUES 538ms
stderr | src/schedulerSettle.test.ts > settleScheduleRuns (real Postgres, injected clock) > (k) M3: a crashed-mid-run occurrence swept by the real stale sweeper retries (canonical run_lost)
[staleRuns] swept run {
  runId: '01a14fb1-2fd2-77ce-90de-2f365e2959f3',
  detail: 'run_lost: stale sweep'
}

 ✓ src/schedulerSettle.test.ts (15 tests) 594ms
 ✓ src/schedulerTick.test.ts (11 tests) 576ms
 ✓ src/mcpTools.test.ts (12 tests) 157ms
 ✓ src/fileService.test.ts (13 tests) 297ms
 ✓ src/liteLlm.test.ts (19 tests) 139ms
 ✓ src/ptyBridge.test.ts (8 tests) 938ms
   ✓ startWorkerPtyBridge (real redis) > close ctl → session killed, exit published, registry key gone (poll) 314ms
   ✓ startWorkerPtyBridge (real redis) > heartbeat refreshes the registry TTL — the key outlives ttlMs 505ms
 ✓ src/pluginInstallProcessor.test.ts (10 tests) 16ms
 ✓ src/sandboxAdapter.test.ts (16 tests) 94ms
 ✓ src/tools/fileTools.test.ts (15 tests) 515ms
 ✓ src/sandboxSeam.test.ts (5 tests) 20ms
stderr | src/notify.test.ts > createFcmPushSender (construction smoke) > resolves {ok:false,code:'error'} on every send when credentials are unset — never throws
[notify] FCM push unavailable: GOOGLE_APPLICATION_CREDENTIALS is not set

 ✓ src/notify.test.ts (8 tests) 103ms
 ✓ src/scheduleTools.test.ts (8 tests) 122ms
stderr | src/keyResolver.test.ts > createServerKeyResolver > returns null (never throws) when internal mint answers 402
[worker] internal mint refused the request { uid: 'user-7', status: 402 }

 ✓ src/keyResolver.test.ts (11 tests) 13ms
stderr | src/staleRuns.test.ts > sweepStaleRuns (real Postgres + real Redis event log) > stale running run → run_failed {runId, code:'run_lost'} in stream AND mirror, run failed with lastError, count 1
[staleRuns] swept run {
  runId: '01a14fb1-5c34-7875-9d8f-504183ac9098',
  detail: 'run_lost: stale sweep'
}

stderr | src/staleRuns.test.ts > sweepStaleRuns (real Postgres + real Redis event log) > two stale running runs → both swept in one pass, count 2, each with its own run_failed
[staleRuns] swept run {
  runId: '01a14fb1-5c6a-7825-a221-8b7f21280dd6',
  detail: 'run_lost: stale sweep'
}

stderr | src/staleRuns.test.ts > sweepStaleRuns (real Postgres + real Redis event log) > two stale running runs → both swept in one pass, count 2, each with its own run_failed
[staleRuns] swept run {
  runId: '01a14fb1-5c70-79c1-b4b8-224a6d3caa00',
  detail: 'run_lost: stale sweep'
}

stderr | src/staleRuns.test.ts > sweepStaleRuns (real Postgres + real Redis event log) > concurrent sweeps emit exactly one run_failed for the same stale row
[staleRuns] swept run {
  runId: '01a14fb1-5c82-746a-a5ea-5e744fb9b426',
  detail: 'run_lost: stale sweep'
}

 ✓ src/staleRuns.test.ts (6 tests) 167ms
stderr | src/schedulerMirror.test.ts > resyncScheduleMirror + createScheduleFireProcessor (real db + real redis) > (c) processor fires a due occurrence, no-ops stale mirrors, completes malformed data
[scheduler] invalid mirror job — completing without retry [
  {
    code: 'too_small',
    minimum: 1,
    type: 'string',
    inclusive: true,
    exact: false,
    message: 'String must contain at least 1 character(s)',
    path: [ 'scheduleId' ]
  }
]

 ✓ src/schedulerMirror.test.ts (5 tests) 139ms
 ✓ src/approvalBridge.test.ts (7 tests) 1593ms
   ✓ createRedisApprovalBridge (real redis + postgres) > a WRONG-USER publish is dropped (cross-user answers never resolve) 405ms
   ✓ createRedisApprovalBridge (real redis + postgres) > a malformed decision on the channel is dropped, not resolved 305ms
   ✓ createRedisApprovalBridge (real redis + postgres) > timeoutMs 0 with no answer stays pending (attended question/plan wait) 303ms
 ✓ src/modelCapabilities.test.ts (14 tests) 12ms
 ✓ src/tools/agentToolAdapter.test.ts (6 tests) 10ms
 ✓ src/storageScans.test.ts (1 test) 125ms
 ✓ src/unattended.test.ts (6 tests) 85ms
 ✓ src/browserToolAdapter.test.ts (8 tests) 6ms
 ✓ src/mcpRuntime.test.ts (2 tests) 69ms
 ✓ src/tools/confinement.test.ts (10 tests) 11ms
 ✓ src/accountSweep.test.ts (4 tests) 7ms
 ✓ src/main.browser.test.ts (5 tests) 5ms
 ✓ src/tools/registry.test.ts (5 tests) 4ms

 Test Files  27 passed (27)
      Tests  274 passed (274)
   Start at  15:46:07
   Duration  27.30s (transform 1.01s, setup 0ms, collect 12.82s, tests 10.12s, environment 4ms, prepare 1.40s)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/e2e

 ✓ src/scheduler.test.ts (8 tests) 1878ms
   ✓ scheduler e2e (real gateway + real worker + real Postgres/Redis, injected clock) > flow F (T10 carry a) — a scheduler-shaped job (job.data.schedule, no explicit unattended flag) is UNATTENDED: default-deny policy applies and auto-denials are ledgered 331ms
stderr | src/security/route-sweep.test.ts > route sweep — 404 not 403 > every ownership route answers its OWNER with 2xx (positive control)
[gateway] workspace activity bump skipped: no ActivityTracker configured (GatewayDeps.activity missing)

 ✓ src/security/route-sweep.test.ts (22 tests) 386ms
stdout | src/security/sandbox-isolation.test.ts > security — sandbox isolation corpus (host-gated)
security corpus: 12 ran, 0 SKIPPED

 ✓ src/security/sandbox-isolation.test.ts (12 tests) 62509ms
   ✓ security — sandbox isolation corpus (host-gated) > (1) path confinement — host /etc, /root/.ssh and the prod workspaces tree are unreachable; RO surfaces reject writes; /workspace is RW 554ms
   ✓ security — sandbox isolation corpus (host-gated) > (4) egress — the staging nft rules block metadata/private/loopback/own-IP (counters prove it) while allowed egress works 45616ms
   ✓ security — sandbox isolation corpus (host-gated) > (5) pids.max — an in-jail fork storm stops at 64, leaves no host processes, and the live stack stays Up 10124ms
   ✓ security — sandbox isolation corpus (host-gated) > (6) memory.max — the 512 MiB cap OOM-kills the allocator (137), memory.peak stays bounded, the host is not drained 344ms
   ✓ security — sandbox isolation corpus (host-gated) > (7) command-policy denylist — the in-jail PATH shims refuse every execution form (direct, shells, chains, pipes, env indirection, base64, path-qualified) 5235ms
   ✓ security — sandbox isolation corpus (host-gated) > (8) device & mount confinement — host devices are absent, mknod is refused, and the jail's mount namespace is private (host mounts unaffected) 358ms
 ✓ src/spine.test.ts (5 tests) 2709ms
   ✓ cloud spine e2e (real gateway + real worker + real Postgres/Redis) > flow a — REST send → 202; WS delivers run_started → deltas → message_completed → run_completed in order; deltas == assistant content; GET messages user→assistant; users + run rows 691ms
   ✓ cloud spine e2e (real gateway + real worker + real Postgres/Redis) > flow b — abrupt disconnect mid-run, resume with lastEventId: remaining events arrive exactly once (live leg) and replay-from-cursor returns the same tail post-completion (replay leg), monotonic, no gaps vs readSince ground truth 619ms
   ✓ cloud spine e2e (real gateway + real worker + real Postgres/Redis) > flow e — two rapid sends to one session: run2's run_started strictly AFTER run1's run_completed; no interleaved deltas; transcript user1,user2,assistant1,assistant2 960ms
 ✓ src/tools.test.ts (4 tests) 1292ms
   ✓ cloud e2e — agent tool loop (real gateway + real worker, stubbed sandbox) > flow a — two tool rounds then text: exact event order run_started, tool_started, tool_completed ×2, message_delta+, message_completed, run_completed; notes.md written in the fake workspace; model request carried system prompt + tools + role:tool results 375ms
 ↓ src/realjail.test.ts (3 tests | 3 skipped)
 ✓ src/browser.e2e.test.ts (6 tests) 1709ms
   ✓ cloud browser e2e (real gateway + real engine + real chromium + real Postgres/Redis) > leg b — viewer attaches mid-run: browser_state {live:true, screencast:true} then ≥2 binary frames within 15 s whose magic bytes match the state's frameFormat 679ms
   ✓ cloud browser e2e (real gateway + real engine + real chromium + real Postgres/Redis) > leg f — boundaries: user B's browser_attach to A's session → {op:"error",code:"forbidden"}; the intruder received ZERO binary frames (tracked across the whole suite) 326ms
 ↓ src/money.test.ts (6 tests | 6 skipped)
stderr | src/storage.e2e.test.ts > storage statehydrator e2e (real gateway + real worker file service)
[storage-e2e] execArgv= ["--conditions","development","--conditions","node"] parallelism= 8

stderr | src/storage.e2e.test.ts > storage statehydrator e2e (real gateway + real worker file service) > (d) PUT cold writes through; the write survives re-hibernation (generation 2)
[storage-e2e] hydrate start 01a14fb2-bf48-78c7-99d2-03031b723c72~1 {
  sessionId: '01a14fb2-bf48-78c7-99d2-03031b723c72',
  userId: 'storage-e2e-mve01vsq-3872604',
  generation: 1,
  reason: 'write'
}

stderr | src/storage.e2e.test.ts > storage statehydrator e2e (real gateway + real worker file service) > (d) PUT cold writes through; the write survives re-hibernation (generation 2)
[storage-e2e] hydrate done 01a14fb2-bf48-78c7-99d2-03031b723c72~1 { status: 'hydrated', files: 5, ms: 13 }

stderr | src/storage.e2e.test.ts > storage statehydrator e2e (real gateway + real worker file service) > (e) POST hydrate → warm with full-tree checksum identity
[storage-e2e] hydrate start 01a14fb2-bf48-78c7-99d2-03031b723c72~2 {
  sessionId: '01a14fb2-bf48-78c7-99d2-03031b723c72',
  userId: 'storage-e2e-mve01vsq-3872604',
  generation: 2,
  reason: 'manual'
}

stderr | src/storage.e2e.test.ts > storage statehydrator e2e (real gateway + real worker file service) > (e) POST hydrate → warm with full-tree checksum identity
[storage-e2e] hydrate done 01a14fb2-bf48-78c7-99d2-03031b723c72~2 { status: 'hydrated', files: 5, ms: 11 }

 ✓ src/storage.e2e.test.ts (6 tests) 633ms
   ✓ storage statehydrator e2e (real gateway + real worker file service) > (d) PUT cold writes through; the write survives re-hibernation (generation 2) 319ms
 ✓ src/mcpTierGate.test.ts (5 tests) 219ms
 ✓ src/staging-guard.test.ts (38 tests) 6534ms
   ✓ NEW-1: worker-start --env overrides are validated > accepts a lowered stale threshold via --env (the chaos harness path) 3425ms
 ✓ src/security/auth-surface.test.ts (9 tests) 325ms
 ↓ src/security/canary-stack.test.ts (1 test | 1 skipped)
 ✓ src/security/secrets-at-rest.test.ts (4 tests) 207ms
stdout | src/security/skipReport.test.ts > security corpus skip reporting (Review Focus #4) > the summary line is printed and counted — skips cannot hide
SKIPPED: path confinement: bwrap missing
SKIPPED: egress rules: nft staging ruleset missing

 ✓ src/security/skipReport.test.ts (10 tests) 11ms

 Test Files  12 passed | 3 skipped (15)
      Tests  129 passed | 10 skipped (139)
   Start at  15:46:35
   Duration  94.12s (transform 1.14s, setup 0ms, collect 13.21s, tests 78.41s, environment 2ms, prepare 763ms)

$ vitest run

 RUN  v2.1.9 /root/OvidAI/cloud/apps/load

stdout | src/smoke.test.ts > load harness integration (real gateway + worker + Postgres/Redis) > 10 users / 20 s: zero loss/dups vs the real event log, floor held, spike held
load integration: runsStarted=55 runsCompleted=55 delivery.p95=3ms samples=260 integrity={"lostEvents":0,"duplicateEvents":0,"gapsVsMirror":0} floor.p95=0.058982999998988817ms pending=0 schedules.created=1 spike.runs=5 spike.held=5 spike.drainMs=0

 ✓ src/smoke.test.ts (6 tests) 23229ms
   ✓ load harness (unit: self-contained mock gateway) > smoke run: zero loss/duplicates vs readSince ground truth, harness under the latency floor 3019ms
   ✓ load harness integration (real gateway + worker + Postgres/Redis) > 10 users / 20 s: zero loss/dups vs the real event log, floor held, spike held 20049ms
stderr | src/chaos/scenarios/clockSkew.test.ts > sweepStaleRuns under injected clock skew (real Postgres + Redis) > forward jump terminalizes only genuinely stale runs
[staleRuns] swept run {
  runId: '01a14fb3-58fe-7a4c-a630-0a151d1fc430',
  detail: 'run_lost: stale sweep'
}

stderr | src/chaos/scenarios/clockSkew.test.ts > sweepStaleRuns under injected clock skew (real Postgres + Redis) > double-claim under skew: two concurrent sweeps emit exactly one run_failed
[staleRuns] swept run {
  runId: '01a14fb3-5930-72da-9212-a32919e03916',
  detail: 'run_lost: stale sweep'
}

 ✓ src/chaos/scenarios/clockSkew.test.ts (20 tests) 140ms
stderr | src/chaos/scenarios/diskPressure.test.ts > the scenario seam drives the shipped enforceWarmCap (F4) > evicts oldest-first through the real engine
[warm-lru] disk usage 95.0% >= alert 80.0% (50 bytes free)

 ✓ src/chaos/scenarios/diskPressure.test.ts (32 tests) 145ms
 ✓ src/chaos/runner.test.ts (15 tests) 11ms
 ✓ src/chaos/scenarios/workerKill.test.ts (32 tests) 11ms
 ✓ src/metrics.test.ts (19 tests) 10ms
 ✓ src/thresholds.test.ts (12 tests) 8ms
debug: master key is c0decba032f24c05de3336314b2024739a0ce9cbebd59e477aea22274d97c3fc
run completed: 3 events, 0 failures
warning: nothing to report
stdout | src/canarySweep.test.ts > runCanarySweep > in-process stack mode drives the shipped gateway/worker with canary config
canary-sweep: in-process stack: database=ovid_canary_f30e474752 redis-db=3
canary-sweep: injecting 6 canaries (masterKey, byokKey, mintKey, redisPassword, dbPassword, litellmKey)
canary-sweep: DATABASE_URL/REDIS_Q_URL carry canary passwords; OVID_MASTER_KEY/OVID_INTERNAL_API_SECRET/LITELLM_MASTER_KEY are canaries
canary-sweep: workload: shipped gateway + worker stack (e2e canary-stack test)


 RUN  v2.1.9 /root/OvidAI/cloud/apps/e2e

 ✓ src/security/canary-stack.test.ts (1 test) 560ms

 Test Files  1 passed (1)
      Tests  1 passed (1)
   Start at  15:48:38
   Duration  2.52s (transform 649ms, setup 0ms, collect 1.78s, tests 560ms, environment 0ms, prepare 50ms)

stdout | src/canarySweep.test.ts > runCanarySweep > in-process stack mode drives the shipped gateway/worker with canary config
canary-sweep: proof: run=01a14fb3-6d07-786d-915a-2c33124a01da terminal=run_completed byok=01a14fb3-6d41-73f1-ac75-feb789528a46 mirror=6 streams=1

stdout | src/canarySweep.test.ts > runCanarySweep > in-process stack mode drives the shipped gateway/worker with canary config
canary-sweep: scanned 5 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: PASS — zero leaks

 ✓ src/canarySweep.test.ts (6 tests) 3062ms
   ✓ runCanarySweep > in-process stack mode drives the shipped gateway/worker with canary config 3048ms
 ✓ src/chaos/scenarios/gates.test.ts (22 tests) 9ms
 ✓ src/chaos/scenarios/queuePrefix.test.ts (3 tests) 7ms
 ✓ src/chaos/helpers.test.ts (6 tests) 4ms
 ✓ src/chaos/scenarios/gatewayDrain.test.ts (4 tests) 88ms

 Test Files  12 passed (12)
      Tests  177 passed (177)
   Start at  15:48:09
   Duration  36.06s (transform 886ms, setup 0ms, collect 6.38s, tests 26.72s, environment 2ms, prepare 624ms)

gate 4: the suite stopped the staging worker (staging-guard) — restarting it for gates 5-7
SECURITY CORPUS SUMMARY: security corpus: 12 ran, 0 SKIPPED
SECURITY CORPUS RAN: 12
SECURITY CORPUS SKIPPED: 0
SECURITY GATE: PASS (corpus ran 12 case(s), 0 SKIPPED)
~~~

### GATE 4b security-regressions — PASS

~~~text
[ok]   tunnels/proxies/scanners/miners refused
[ok]   heavy native toolchains refused
[ok]   outbound 443 allowed — open
[ok]   outbound 22/25/7844/3333 dropped
[ok]   postinstall script did not execute — evil probe.txt 
[ok]   host /etc/shadow and other users unreadable — denied
[ok]   cloud metadata endpoint dropped — SHUT
[ok]   RFC1918 egress dropped — SHUT

security regressions: 8 passed, 0 failed
SECURITY REGRESSION GATE: PASS (sandbox boundary holds)
~~~

### GATE 5 load-smoke10 — PASS

~~~text
load: profile=smoke10 users=10 durationMs=120000 target=http://127.0.0.1:18082
report written: /root/OvidAI/cloud/apps/load/reports/load-smoke10-20261018.md
json written: /root/OvidAI/cloud/apps/load/reports/load-smoke10-20261018.json
thresholds: PASS
PASS report present: LoadReport object
PASS users=10: 10
PASS runsStarted>0: 60
PASS runsCompleted>0: 60
PASS runsCompleted==runsStarted: 60/60
PASS eventDelivery.samples>0: 300
PASS eventDelivery.p95Ms present: 3
PASS integrity.lostEvents=0: 0
PASS integrity.duplicateEvents=0: 0
PASS integrity.gapsVsMirror=0: 0
PASS harness.maxPendingFrames present: 0
PASS harness.latencyFloorP95Ms present: 0.13387000000511762
PASS threshold failures empty: []
positive-data: PASS (all required measurements present)
PASS report present: LoadReport object
PASS users=10: 10
PASS runsStarted>0: 60
PASS runsCompleted>0: 60
PASS runsCompleted==runsStarted: 60/60
PASS eventDelivery.samples>0: 300
PASS eventDelivery.p95Ms present: 3
PASS integrity.lostEvents=0: 0
PASS integrity.duplicateEvents=0: 0
PASS integrity.gapsVsMirror=0: 0
PASS harness.maxPendingFrames present: 0
PASS harness.latencyFloorP95Ms present: 0.13387000000511762
PASS threshold failures empty: []
positive-data: PASS (all required measurements present)
LOAD GATE: PASS (thresholds + positive data)
~~~

### GATE 6 chaos-worker-kill — PASS

~~~text
[chaos] worker-kill: PASS (25946ms)
[chaos]   PASS precondition: 1 run(s) provably in flight with the mock gate held; staging worker pid 3878559 alive; health ok; target is staging
[chaos]   PASS inject: failure injected after the precondition gate passed
[chaos]   PASS worker-stays-dead: worker observed dead for 20101ms (required 20000ms)
[chaos]   PASS run-lost-emitted: run_failed code="run_lost"
[chaos]   PASS run-lost-within-budget: run_lost emitted 1767ms after the worker restart (budget 95000ms = 15s stale + 60s sweep + 20s slack); emitted-after-restart: true
[chaos]   PASS run-row-failed: run row status is failed
[chaos]   PASS exactly-one-run-failed: run_failed events: stream 1, mirror 1 (claim-then-emit must produce exactly 1)
[chaos]   PASS fresh-run-completes: a fresh run started after the restart reached run_completed
[chaos]   PASS worker-restarted: staging worker is alive and consuming again
[chaos]   PASS live-unaffected-after: healthz=200, 7 ovid-gateway-* container(s) Up, StartedAt unchanged
[chaos] report: /root/OvidAI/cloud/apps/load/reports/chaos-20261018.md
[chaos] all selected scenarios passed
CHAOS GATE: PASS (precondition proven, failure injected, all assertions green)
~~~

### GATE 7 canary-sweep — PASS

~~~text
canary-sweep: injecting 6 canaries (masterKey, byokKey, mintKey, redisPassword, dbPassword, litellmKey)
canary-sweep: workload: bash /tmp/ovid-acceptance.udD4uo/canary-workload.sh
load: profile=smoke10 users=10 durationMs=120000 target=http://127.0.0.1:18082
report written: /root/OvidAI/cloud/apps/load/reports/load-smoke10-canary-20261018.md
json written: /root/OvidAI/cloud/apps/load/reports/load-smoke10-canary-20261018.json
thresholds: PASS
canary-sweep: scanned 8 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: PASS — zero leaks
PASS report present: LoadReport object
PASS users=10: 10
PASS runsStarted>0: 60
PASS runsCompleted>0: 60
PASS runsCompleted==runsStarted: 60/60
PASS eventDelivery.samples>0: 300
PASS eventDelivery.p95Ms present: 2
PASS integrity.lostEvents=0: 0
PASS integrity.duplicateEvents=0: 0
PASS integrity.gapsVsMirror=0: 0
PASS harness.maxPendingFrames present: 0
PASS harness.latencyFloorP95Ms present: 0.10299099999974715
PASS threshold failures empty: []
positive-data: PASS (all required measurements present)
CANARY GATE: PASS (zero leaks over 8 corpus location(s); workload measured positively)
~~~

### GATE 7b canary-stack — PASS

~~~text
canary-sweep: in-process stack: database=ovid_canary_3404d1278f redis-db=12
canary-sweep: injecting 6 canaries (masterKey, byokKey, mintKey, redisPassword, dbPassword, litellmKey)
canary-sweep: DATABASE_URL/REDIS_Q_URL carry canary passwords; OVID_MASTER_KEY/OVID_INTERNAL_API_SECRET/LITELLM_MASTER_KEY are canaries
canary-sweep: workload: shipped gateway + worker stack (e2e canary-stack test)

 RUN  v2.1.9 /root/OvidAI/cloud/apps/e2e

 ✓ src/security/canary-stack.test.ts (1 test) 543ms

 Test Files  1 passed (1)
      Tests  1 passed (1)
   Start at  15:53:46
   Duration  2.49s (transform 641ms, setup 0ms, collect 1.75s, tests 543ms, environment 0ms, prepare 57ms)

canary-sweep: proof: run=01a14fb8-1e04-7d21-a456-bf1e778a5167 terminal=run_completed byok=01a14fb8-1e3e-75ae-ae67-9a6f2b18505d mirror=6 streams=1
canary-sweep: scanned 5 corpus location(s)
canary-sweep: workload exit=0
canary-sweep: PASS — zero leaks
proof: run=01a14fb8-1e04-7d21-a456-bf1e778a5167 terminal=run_completed byok=01a14fb8-1e3e-75ae-ae67-9a6f2b18505d mirror=6 events=6
CANARY-STACK GATE: PASS (canaries were the shipped stack's real config; a real run and a BYOK upload executed)
~~~

### GATE 8 live-unaffected — PASS

~~~text
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] live stack unchanged (healthz=200, every ovid-gateway-* Up, StartedAt identical)
LIVE GATE: PASS (healthz 200, all ovid-gateway-* Up, StartedAt identical)
~~~

### GATE 8b watch-self-test — OWNER-GATED

~~~text
(no output captured)
~~~

### GATE 8c r2-verification — OWNER-GATED

~~~text
(no output captured)
~~~

### GATE 9 teardown — PASS

~~~text
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] staging worker stopped (graceful)
LIVE CHECK (after):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] no mock pidfile at /tmp/opencode/ovid-staging-mock.pid — nothing to stop
LIVE CHECK (before):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
[staging] stopping staging compose project (volumes kept)
 Container ovid-cloud-staging-mock-llm-1 Stopping 
 Container ovid-cloud-staging-gateway-1 Stopping 
 Container ovid-cloud-staging-mock-llm-1 Stopped 
 Container ovid-cloud-staging-mock-llm-1 Removing 
 Container ovid-cloud-staging-mock-llm-1 Removed 
 Container ovid-cloud-staging-gateway-1 Stopped 
 Container ovid-cloud-staging-gateway-1 Removing 
 Container ovid-cloud-staging-gateway-1 Removed 
 Container ovid-cloud-staging-redis-q-1 Stopping 
 Container ovid-cloud-staging-mint-1 Stopping 
 Container ovid-cloud-staging-redis-q-1 Stopped 
 Container ovid-cloud-staging-redis-q-1 Removing 
 Container ovid-cloud-staging-redis-q-1 Removed 
 Container ovid-cloud-staging-mint-1 Stopped 
 Container ovid-cloud-staging-mint-1 Removing 
 Container ovid-cloud-staging-mint-1 Removed 
 Container ovid-cloud-staging-redis-mint-1 Stopping 
 Container ovid-cloud-staging-postgres-1 Stopping 
 Container ovid-cloud-staging-postgres-1 Stopped 
 Container ovid-cloud-staging-postgres-1 Removing 
 Container ovid-cloud-staging-postgres-1 Removed 
 Container ovid-cloud-staging-redis-mint-1 Stopped 
 Container ovid-cloud-staging-redis-mint-1 Removing 
 Container ovid-cloud-staging-redis-mint-1 Removed 
 Network ovid-cloud-staging Removing 
 Network ovid-cloud-staging Removed 
[staging] removed staging egress table inet sandbox_egress_staging
LIVE CHECK (after):
  healthz=200
  container=ovid-gateway-account-dev-1 status=Up 2 days started_at=2026-10-16T12:53:34.915995415Z
  container=ovid-gateway-caddy-1 status=Up 2 days started_at=2026-10-16T12:53:35.202658238Z
  container=ovid-gateway-img-edit-shim-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.153911558Z
  container=ovid-gateway-litellm-1 status=Up 2 days started_at=2026-10-16T12:53:35.056790951Z
  container=ovid-gateway-mint-1 status=Up 2 days started_at=2026-10-16T12:53:35.702178364Z
  container=ovid-gateway-postgres-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.032065486Z
  container=ovid-gateway-redis-1 status=Up 2 days (healthy) started_at=2026-10-16T12:53:24.278996234Z
~~~


GATE 10 release-evidence: PASS (/root/OvidAI/cloud/apps/load/reports/RELEASE-EVIDENCE-20261018.md)
