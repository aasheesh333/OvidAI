
## ADDED 2026-10-17 — duplicate SSRF classifier (P9-T11 fix round)

`isNonPublicAddress` now exists in BOTH `@ovid/agent-core` (`src/ssrf.ts`) and `@ovid/escrow` (`src/address.ts`) — the escrow copy was made because the gateway cannot import agent-core without a new lockfile importer (forbidden during the parallel wave). Three copies of a security classifier will drift.

**Action:** when the lockfile is regenerated (step 2-3 above), make the gateway depend on `@ovid/agent-core` (or move the classifier to `@ovid/shared`) and delete the escrow copy, re-pointing `byok.ts` at the single export. Verify `address.test.ts`'s 31 assertions move with it. Do NOT leave two implementations of an SSRF classifier in the shipped tree.

## ADDED 2026-10-17 — P9-T9 workspace links

`apps/worker/package.json` gained `@ovid/escrow`; `packages/shared/package.json` gained `@types/node`. Neither importer is committed to the lockfile (wave rule). The P9-T9 implementer created local node_modules symlinks so tests could run — the wave-merger's `pnpm install` must record both.

## STATUS 2026-10-17 (late) — non-lockfile items

- **Env-example duplicate keys: DONE** (commit 0bc12a4). `worker.env.example` assigned
  `OVID_MAX_WARM_GB` twice (P2 sandbox block + P7 storage block, both `8`). Removed the
  P2 assignment, left a pointer comment; canonical definition stays in the P7 block
  (ruling R2). All four templates (`.env.example`, `worker.env.example`,
  `.env.staging.example`, `.env.staging.mint.example`) now: zero duplicate keys,
  `bash -n` clean, and each sources cleanly under `.`.
- **Barrel survival: DONE (verified, no change needed).** Every `packages/*/src/index.ts`
  import specifier resolves to a real source file. NOTE for future checks: the barrels
  use NodeNext `.js` specifiers that resolve to `.ts` sources — a naive
  `test -f ./foo.js` check reports ~150 false "missing" entries. Strip the `.js` before
  testing.
- **Lockfile regeneration: STILL BLOCKED** — fix rounds are actively committing
  (P4, P9, P10-T6, P8-T12, P8-T15). Regenerate only when `git status` is quiet for
  `cloud/**` and every lane below has committed.
- **Test-typecheck debt (144 errors): STILL OPEN** — the failing files are exactly the
  ones the live lanes are editing.
- **Duplicate SSRF classifier (`@ovid/agent-core` vs `@ovid/escrow`): STILL OPEN** —
  collapse only after the fix rounds stop editing `cloud/packages/**`.
- **`@ovid/load` typecheck debt: DONE** (commit bad63b4). T7's `workerKill.test.ts`
  fixtures predated `WorkerKillGateState.workerPid` (7 × TS2345). Fixture fixed, and the
  gate's previously-untested null-pidfile branch is now pinned. The package reports
  **0 errors** under `tsconfig.check.json` — strike it from the per-package debt table.


---

## DONE 2026-10-17 — lockfile regenerated (commit `873d993`)

`pnpm install --lockfile-only` (chosen over a full install so a concurrently
running agent's node_modules was not disturbed). **Proof:** a scratch copy with
only the 19 manifests + workspace files runs `pnpm install --frozen-lockfile
--offline` → "Lockfile is up to date, resolution step is skipped", 380
packages, exit 0.

**Correction to the importer table above:** it was written from the PLAN, not
the code. Several rows describe structural mirrors that were never real
imports — `@ovid/plugins` is not a package (the plugin code lives in
`packages/mcp/src/plugins/**`), and agent-core / mcp mention
money/sandbox/escrow/queue only in COMMENTS; mint does not import escrow or
queue. The lockfile reflects the actual graph, which is simpler.

## STILL OPEN

1. **144 test-source typecheck errors** (`pnpm -r --parallel exec tsc -p
   tsconfig.check.json --noEmit`). `@ovid/load` is now CLEAN (commit bad63b4).
   Run per-package so a regression is attributable.
2. **Duplicate SSRF classifier**: `isNonPublicAddress` exists in BOTH
   `packages/agent-core/src/ssrf.ts` and `packages/escrow/src/address.ts`
   (identical logic; the escrow copy differs only by non-null assertions).
   **The lockfile is now regenerated, so the blocker the escrow comment cited
   is GONE** — collapse them. Cleanest target: `@ovid/shared` (agent-core
   already depends on it; escrow would need ONE new edge, which now just means
   re-running `pnpm install --lockfile-only`).
3. **`packages/mcp` -> `@ovid/db` is an undeclared dynamic edge**: router.ts /
   oauth/flow.ts / plugins/install.ts do a computed `import("../../db/dist/...")`.
   Works only because the gateway copies db's dist. Declare `@ovid/db` in
   `packages/mcp/package.json` (then re-run `--lockfile-only`).
4. **Dockerfile build**: the import maps are complete (DOCKERFILE-AUDIT.md,
   commit 45c7033) and the node-pty toolchain is now installed in both build
   stages. With the lockfile fixed, a real `docker compose build` should now be
   possible — that is the remaining unproven step.


---

## CLOSED 2026-10-18

- **Test-typecheck debt: 174 -> 0.** Measured per package before: agent-core 24,
  browser 4, mcp 40, sandbox 35, e2e 3, gateway 31, mint 27, worker 10.
  `packages/account` was also missing its `tsconfig.check.json` entirely (added
  by P9 after P10-T3 made the other 16) — that config now exists and its 4
  errors are cleared. Commits: 6aba5c9 (sandbox), 9c96acd (agent-core+browser),
  4c08119 (mcp), ee3e211 (gateway), 1487667 (account), plus the e2e/mint/worker
  batch. Proof: `pnpm -r --parallel exec tsc -p tsconfig.check.json --noEmit`
  → **exit 0**.
- **CI now enforces it** (commit f71ed7a): the Typecheck step switched from
  `tsconfig.json` to `tsconfig.check.json`, so `*.test.ts` is gated. It was
  deliberately left on the production config while the debt existed.
- **SSRF classifier: 4 copies -> 1** (commit 37aee77). There were FOUR, not the
  two this file recorded: `agent-core/src/ssrf.ts`, `escrow/src/address.ts`,
  `mcp/src/ssrf.ts`, `browser/src/url.ts`. All now import
  `@ovid/shared`'s `netAddress.ts`. Differential test: 0 differences across
  167,840 inputs; the only deltas make it stricter (old mcp parser accepted
  some malformed IPv6 as public). Adding a reserved prefix is now a one-file
  change.
- **Lockfile** (commit 873d993): `pnpm install --frozen-lockfile --offline` on a
  scratch copy → "Lockfile is up to date", 380 packages, exit 0.

## STILL OPEN (not blockers)

- `packages/mcp` -> `@ovid/db` is an undeclared dynamic edge (computed
  `import("../../db/dist/...")`). Works because the gateway copies db's dist.
  Declaring it is a one-line change + `--lockfile-only`; do it when convenient.
- **A real `docker compose build` has never been run.** The import maps are
  complete (DOCKERFILE-AUDIT.md) and the node-pty toolchain is installed, and
  the lockfile is now valid — so it should work, but that is unproven. This is
  the last unverified deploy step.
