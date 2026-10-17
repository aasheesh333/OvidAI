# P6 browser egress uid — real fix report

Status: FIXED. The nftables browser-egress rules now match real browser
processes; there is no root fallback.

## 1. Mechanism (confirmed)

- `OVID_BROWSER_EGRESS_UID` was consumed only by the nftables renderer
  (`packages/sandbox/src/renderNftCli.ts` / `net.ts`).
- `packages/browser` never dropped uid/gid: Lightpanda spawned with default
  credentials, Chromium launched through `chromium.launch()`, and the worker
  runs as root (`deploy/systemd/ovid-worker.service` `User=root`).
- The rendered `meta skuid <browser-range>` rules therefore matched nothing.
- The parser correctly refuses uid < 100000, so the worker uid (0) could not
  be used as the key. `BROWSERS.md` §(d) called it "the worker uid", which was
  the contradiction.

## 2. Chosen fix

- **Dedicated browser uid** configurable via `OVID_BROWSER_EGRESS_UID`
  (single uid or range; the engine uses the first uid, the renderer keys the
  whole range). Validated `>= 100000` and disjoint from the sandbox block
  parsed from `OVID_SANDBOX_UID_BASE` / `OVID_SANDBOX_UID_MAX`.
- **Lightpanda**: `child_process.spawn(..., { uid, gid, env })` for both
  `serve` and one-shot `fetch` (`packages/browser/src/lightpanda.ts`).
- **Chromium**: Playwright 1.64.1 has no uid/gid launch option — its
  `LaunchOptions` exposes none and its internal `launchProcess` spawns with
  `{ detached, env, cwd, shell, stdio }` only. The engine therefore generates
  a root-owned 0755 `setpriv` shim at boot and passes it as
  `executablePath` (`packages/browser/src/uidDrop.ts`). The shim:
  1. receives Playwright's root-created `--user-data-dir=<path>`;
  2. chowns it to the browser uid;
  3. `exec`s `setpriv --reuid=<uid> --regid=<uid> --clear-groups <chromium>`.
  Every Chromium child (zygote, renderers, crashpad) inherits the uid.
- The engine creates a per-engine runtime tree (`HOME`, `TMPDIR`, `XDG_*`,
  downloads), chowns it to the uid, and passes it in the browser env. The shim
  stays root-owned so the browser uid can traverse but not rewrite it.
- **Fail-closed config**: `OVID_BROWSER_UID_DROP` = `auto` (default) |
  `required` | `disabled`. `disabled` is dev/test only and is refused when
  `NODE_ENV=production`; production *requires* `OVID_BROWSER_EGRESS_UID`.
- **Boot fail-loud**: engine construction rejects (worker boot fails, no root
  fallback) when the worker is non-root, the uid is invalid/overlapping,
  `setpriv` is missing, Chromium is missing/non-executable, or the uid-drop
  probes fail. Probes: `/bin/true` spawned as the uid, then
  `chromium --version` through the generated shim.

## 3. Evidence

- End-to-end host probe with the **generated** shim and a real Chromium
  156.0.8078.4: page loaded (`TITLE uid-e2e`), and `ps` showed the browser,
  renderer, zygote, and crashpad processes all at uid/gid **230000**.
- `uidDrop.test.ts` (root-gated) spawns through the shim with a stand-in
  executable and asserts the child reports `id -u` = 230000 and the
  Playwright profile dir is chowned to 230000.
- `lightpanda.test.ts` asserts `uid`/`gid`/`env` are present in both the
  `serve` and `fetch` spawn options.
- `pool.test.ts` asserts the prepared shim is wired into Playwright's
  `executablePath`/`env`/`downloadsPath`, and that no such wiring appears
  when no uid is configured.
- `config.test.ts` / `net.test.ts` assert rejection of `< 100000`, the
  production block (200000-209999), the staging block (220000-229999), and
  malformed values; `engine.test.ts` asserts a uid-drop preparation failure
  rejects engine construction.

## 4. Commit

`<FILLED AFTER COMMIT>`

## 5. Gate outputs

- `pnpm --filter @ovid/browser build` — PASS
- `pnpm --filter @ovid/browser test` — PASS (218 passed, 29 skipped)
- `pnpm --filter @ovid/sandbox build` — PASS
- `pnpm --filter @ovid/sandbox test` — PASS (324 passed, 42 skipped)
- `pnpm --filter @ovid/worker build` — PASS (worker wiring untouched)

## 6. Owner actions / notes

- Set `OVID_BROWSER_EGRESS_UID=230000` in `/opt/ovid-cloud/worker.env`
  (templates now ship it) and re-run `deploy/net/install-nft.sh`.
- Ensure `/opt/ovid-browsers` and the installed Chromium are traversable and
  executable by uid 230000 (production installs there, not under `/root`).
- `OVID_BROWSER_UID_DROP=disabled` is for non-production dev/test only; the
  production worker now refuses to boot without a dedicated uid.
- `deploy/OWNER-GATES.md` §3.13's blocker is resolved by this implementation:
  fill the uid, do not use the worker uid, and do not leave it empty in
  production. (That doc was not edited here — it is a separate owner-gate
  lane.)
