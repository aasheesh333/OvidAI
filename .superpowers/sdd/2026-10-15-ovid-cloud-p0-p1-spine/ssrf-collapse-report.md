# SSRF classifier collapse — report

Status: COMPLETE

## Goal

Collapse the four duplicate copies of the security-critical
`isNonPublicAddress` SSRF classifier into one shared implementation in
`@ovid/shared`, with no behavioural change for any real call path and no
weakened tests.

## The four copies

| Package | Path | Notes |
|---|---|---|
| `@ovid/agent-core` | `packages/agent-core/src/ssrf.ts:174` | canonical; superset (also has `embeddedIpv4`, `isMetadataOrLinkLocalAddress`) |
| `@ovid/escrow` | `packages/escrow/src/address.ts:131` | copy; header already asked for this collapse |
| `@ovid/mcp` | `packages/mcp/src/ssrf.ts:147` | copy; local parser had different helper names |
| `@ovid/browser` | `packages/browser/src/url.ts:147` | copy; `bareHost` / `parseAddressBytes` also used by the guard |

## Plan

1. New `packages/shared/src/netAddress.ts` holding the classification layer
   ONCE (`parseIpv4Bytes`, `parseHexGroup`, `parseIpv6Bytes`, `bareHost`,
   `parseAddressBytes`, `isNonPublicIpv4Bytes`, `embeddedIpv4`,
   `isNonPublicAddress`, `isMetadataOrLinkLocalAddress`), exported from
   `packages/shared/src/index.ts`.
2. `agent-core/src/ssrf.ts` imports from `@ovid/shared`; keeps
   `SsrfBlockedError`, `SsrfResolver`, `SsrfGuard`, `createSsrfGuard`,
   `createGuardedEgressFetch` and the resolution logic local. Re-exports
   `isNonPublicAddress` / `isMetadataOrLinkLocalAddress` so existing
   `./ssrf.js` consumers and the package barrel keep working.
3. `escrow/src/address.ts` becomes a thin re-export of
   `@ovid/shared`'s `isNonPublicAddress` (file kept so `address.test.ts`
   resolves).
4. `mcp/src/ssrf.ts` and `browser/src/url.ts` import from `@ovid/shared`;
   their own guard/fetch behaviour stays local.
5. Add `"@ovid/shared": "workspace:*"` to `packages/escrow/package.json`
   and run `pnpm install --lockfile-only`.

## Differential check before the change

Corpus: ~149k inputs (every address in the four test suites, IPv4 boundary
grids, generated IPv6 compressed/uncompressed forms, 20k random IPv4, 20k
random IPv6, 20k fuzz strings). Compared agent-core, escrow, mcp.

- agent-core vs escrow: **0 differences**.
- agent-core vs browser: textually identical classifier (only comments
  differ), so no difference.
- agent-core vs mcp: identical on every valid IP except one zone-indexed
  form, plus differences on invalid/malformed strings (mcp's parser did not
  use `isIP`, so it accepted some malformed forms agent-core fails closed
  on, and rejected bracketed/trailing-dot forms agent-core normalizes).
  Details in "Behavioural differences found" below.

## Behavioural differences found (agent-core vs mcp)

1. `2606:4700::1%eth0` (a scoped global IPv6 literal): agent-core returns
   non-public (fail-closed, because it does not strip zone ids); mcp strips
   the zone and returns public. This input cannot reach either guard: URL
   hostnames never carry a zone id, and DNS resolvers do not return one.
2. Malformed strings (e.g. `1:2:3:4:5:6:7:8::`) that `net.isIP` rejects:
   mcp's hand parser accepted some of them and classified them public;
   agent-core fails closed. Moving to the canonical version is strictly
   safer.
3. Bracketed/trailing-dot forms (`[8.8.8.8]`, `8.8.8.8.`): agent-core
   normalizes them; mcp returned non-public. Call sites already strip
   brackets/dots before classification, so this is unreachable.

No difference affects a valid, reachable egress target. The consolidation
uses the canonical (agent-core) implementation as instructed.

## Result

- `packages/shared/src/netAddress.ts` now holds the ONLY copy of the
  classifier and is exported from the shared barrel.
- `agent-core/src/ssrf.ts` imports `bareHost`, `parseAddressBytes`,
  `isNonPublicAddress` and `isMetadataOrLinkLocalAddress` from
  `@ovid/shared`; it re-exports both classifiers so `./ssrf.js` consumers and
  the package barrel are unchanged. All guard/resolution code stayed local.
- `escrow/src/address.ts` is now `export { isNonPublicAddress } from
  "@ovid/shared";` (file kept for `address.test.ts` and the barrel).
- `mcp/src/ssrf.ts` imports/re-exports `isNonPublicAddress` and uses
  `parseAddressBytes` for its loopback exemption; `createGuardedFetch`,
  `SsrfBlockedError` and its resolver stayed local.
- `browser/src/url.ts` imports `bareHost`, `parseAddressBytes` and
  `isNonPublicAddress`; `navigableUrlReason`, `assertPublicHost`,
  `createSsrfGuardedFetch`, self-block and resolution stayed local.
- Added `"@ovid/shared": "workspace:*"` to `packages/escrow/package.json`
  and regenerated `pnpm-lock.yaml` (then `pnpm install --frozen-lockfile`
  created the workspace symlink needed by the build).

No test assertion was deleted or weakened.

## Verification

Old canonical (git `HEAD`) vs new shared implementation, differential run
over 167,840 inputs (random IPv4, generated IPv6, fuzz strings, every
test-suite address):

- `isNonPublicAddress`: **0 differences**
- `isMetadataOrLinkLocalAddress`: **0 differences**

Grep proof (packages, `.ts`, excluding `dist`/`node_modules`):

```
$ grep -rn "function isNonPublicAddress" packages --include='*.ts' \
    --exclude-dir=dist --exclude-dir=node_modules
packages/shared/src/netAddress.ts:145:export function isNonPublicAddress(ip: string): boolean {
```

## Gates — all passed

Build (`shared`, `agent-core`, `escrow`, `mcp`, `browser`, `worker`,
`gateway`): exit 0.

Tests (`TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`,
`TEST_REDIS_URL=redis://127.0.0.1:6390/7`; no FLUSHDB):

| Package | Test files | Tests |
|---|---|---|
| `@ovid/shared` | 11 passed | 200 passed |
| `@ovid/agent-core` | 33 passed | 798 passed |
| `@ovid/escrow` | 5 passed | 71 passed |
| `@ovid/mcp` | 27 passed | 444 passed |
| `@ovid/browser` | 16 passed | 238 passed, 9 skipped (247) |

The four required suites (`agent-core/src/ssrf.test.ts`,
`escrow/src/address.test.ts`, `mcp/src/ssrf.test.ts`,
`browser/src/url.test.ts`) all pass unchanged.

