# Settings recovery status — R1 private memory (agent worktree a769e6b7)

Branch: `worktree-agent-a769e6b7def3c7073`. Scope: the parent-approved
bounded private-memory plan (migration 0019, DB repo, agent-core store port,
hard-boundary tests) plus the Wave 4 Settings work already checkpointed in
`1787b84d`.

## What changed

- **Migration 0019_private_memory** (`cloud/packages/db/drizzle/0019_private_memory.sql`
  + `meta/0019_snapshot.json`): `private_memory_files` table — PK
  `(user_id, scope, name)`, FK `user_id → users.uid` ON DELETE CASCADE, FK
  `session_id → sessions.id` ON DELETE CASCADE, CHECK constraints for
  scope/session pairing, content ≤ 32 KiB (octet_length), canonical name
  (≤80 chars, `[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*\.md`, no
  lowercase entrypoint variant), index on `session_id`. Chain generated from
  the chat branch's 0018_attachment_message snapshot chain (0017 `bc9f03af`
  → 0018 `3c5e5198` → 0019 prevId `3c5e5198`); deployed 0017 untouched.
  0018 confirmed final/canonical by its owner (chat agent).
- **DB repo** (`cloud/packages/db/src/privateMemory.ts`): every operation
  rechecks live-session ownership inside its transaction (advisory
  `pg_advisory_xact_lock` per `uid:scope` namespace serializes
  count/name/revision guards), optimistic revision baseline (save of an
  existing file requires `ifRevision` matching sha256 of current content;
  absent file baseline = sha256("")), UTF-8 ≤32 KiB, max 32 files counting
  the virtual MEMORY.md, case-conflict refusal, atomic upsert, and driver
  exceptions are never relayed (SQL bind values could hold private facts).
- **agent-core MemoryStore port** (`cloud/packages/agent-core/src/tools/memory.ts`):
  `createMemoryTools` now REQUIRES a `PrivateMemoryStore` — the sandbox
  dependency and all workspace path logic are gone. No sandbox fallback, no
  `.ovid/memory` reads, no private facts in `users.preferences` or agent
  state. Memory OFF removes the whole tool family; sharing OFF restricts
  tools to the current session scope; sharing ON opens the shared scope;
  explicit @-refs stay read-only and owner-checked.
- **Worker** (`cloud/apps/worker/src/runProcessor.ts`): the production roster
  builds memory tools with `createPrivateMemoryStore(deps.db)` ONLY.
- **Gateway** (`cloud/apps/gateway/src/routes/memory.ts`): /memory API rides
  the DB store directly — zero worker file-service calls, zero workspace
  paths. Store errors map to 404/409/400/503 without driver detail.

## Release blocker — legacy workspace memory exposure (explicit, unfixed)

**No overall hard-R1 claim can be made while this stands.** The new private
store is a hard boundary for everything written through it, but PRE-EXISTING
`.ovid/memory/` and `.ovid/session-memory/<sessionId>/` files in users'
shared workspaces remain readable by the agent's generic filesystem tools
(read_file / shell / Studio browser) because the workspace itself is shared
per user (R2). Per the approved plan these legacy files are **PRESERVED — no
automatic import, delete or move** — so old facts stay exposed until the
owner decides a migration path. Until then:

- Memory saved AFTER this change never lands in the workspace (tested).
- Memory saved BEFORE this change in the legacy dirs is still readable by
  the same user's own agent runs through FS tools (by design of the shared
  workspace, but it violates the R1 promise for those older facts).
- Recommended follow-up (owner decision, not taken here): a one-time
  user-consented migration that moves legacy memory content into the private
  store and scrubs the workspace copies, or a FS-tool deny-rule on
  `.ovid/**` in the sandbox adapter.

## Honest gaps

- `memoryDirectoryFor`/`MEMORY_DIR` in `@ovid/shared` are now dead exports
  in this branch (no production consumers); left in place to avoid churn in
  other branches that may still import them.
- BYOK regenerate-hookup remains deferred (endpoint gated) as instructed;
  ordinary-send BYOK correctness (owner-validated key selection, immutable
  job key/model, no Ovid billing for valid owner key) is unchanged and
  covered by existing tests.
- The Flutter UI still shows the memory screen against the same
  `/memory?sessionId=` API; its contract is unchanged (list/read/write with
  ifRevision/delete), so no client change was needed for the store swap.

## Test evidence (commands and counts)

- `npx vitest run src/privateMemory.test.ts` (packages/db, scratch DB
  `settings_mem_a769e6b7def3c7073` on ovid-dev-pg :5433): **5/5 passed** —
  isolation (A's fact absent from B, foreign owner denied, absent from
  preferences/agent state), shared scope requires live owned chat, atomic
  same-revision races (exactly one winner), canonical name/UTF-8/count
  safeguards, cascade on chat/account deletion.
- `npx vitest run src/tools/memory.test.ts` (packages/agent-core): **21/21
  passed** — includes the R1 hard-boundary tests: fact exists nowhere in the
  (fake) workspace, legacy files never read/imported, child runs inherit
  the session scope and sharing restriction.
- `npx vitest run src/routes/accountSettings.test.ts` (apps/gateway, same
  scratch DB): **10/10 passed** — settings/presets unchanged; memory API
  now DB-only (list/read/edit/conflict/delete, ownership, sharing opens
  only the shared scope, no implicit chat selection).
- `pnpm --filter @ovid/shared build && pnpm --filter @ovid/db build &&
  pnpm --filter agent-core build && pnpm --filter @ovid/worker build &&
  pnpm --filter @ovid/gateway build`: all compile clean.
- `/root/flutter/bin/flutter test test/settings_memory_presets_test.dart
  test/cloud_byok_ui_test.dart`: **17/17 passed**.
