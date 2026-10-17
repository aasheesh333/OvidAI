# Real-Python hook contract harness (P9 Task 17)

This directory is the single most important correctness proof of the P9 money
migration: it runs the **unmodified** Python LiteLLM hook
(`server/mint/litellm_hook/ovid_pools.py` + `server/mint/ovid_plans.py`)
against Redis state written by the **TypeScript** mint projection.

Nothing here imports, patches or reimplements the Python hook. A mismatch is a
real TS↔Python parity bug; never weaken an assertion to make it pass.

## Files

| File | Role |
| --- | --- |
| `seed.ts` | Writes settings, per-user tiers and `config:model_groups` through `storeSettings` + `createProjection` (Postgres authority → db2). Imported by `src/money.test.ts`. |
| `conftest.py` | Wires **both** Python source dirs onto `sys.path` from `__file__` and asserts `import ovid_plans` succeeds before collection. Skips when `HOOK_CONTRACT_REDIS_URL` is unset. |
| `test_hook_contract.py` | The six pinned assertions (pass-through, 429 contract, slow mode, auto routing, accounting, settings shape parity). |

## The `sys.path` trap

`ovid_pools.py` inserts only `server/mint/litellm_hook/` and then does
`import ovid_plans`, which lives one directory up in `server/mint/`. Both
directories must be on `sys.path` **before** `ovid_pools` is imported.
`conftest.py` does exactly that, derived from `__file__` (never the cwd), and
fails loudly if the import does not resolve to the expected file.

## Running

The Vitest wrapper does everything (seeds through TS, shells out to pytest,
asserts the tests actually ran):

```bash
cd cloud
TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/ovid_mint_t17 \
TEST_MINT_REDIS_URL=redis://127.0.0.1:6390/9 \
HOOK_CONTRACT_REDIS_URL=redis://127.0.0.1:6390/9 \
pnpm --filter @ovid/e2e exec vitest run src/money.test.ts
```

Standalone pytest (state must already have been seeded):

```bash
HOOK_CONTRACT_REDIS_URL=redis://127.0.0.1:6390/9 \
HOOK_CONTRACT_FIXTURE='{"freeUid":"…","slowUid":"…","autoUid":"…","accUid":"…","autoAccUid":"…"}' \
PYTHONPATH=/tmp/ovid-t17-deps \
python3 -m pytest cloud/apps/e2e/hook-contract -q
```

### Python dependencies

`python3` is required. `pytest` and `redis` (redis-py, including
`redis.asyncio`) are needed. If the system interpreter lacks them, install
them outside the repository and point `HOOK_CONTRACT_PYTHONPATH` at the
target directory:

```bash
python3 -m pip install --target /tmp/ovid-t17-deps pytest redis
export HOOK_CONTRACT_PYTHONPATH=/tmp/ovid-t17-deps
```

The Vitest wrapper probes `python3 -c "import pytest, redis.asyncio"` (with
`HOOK_CONTRACT_PYTHONPATH` prepended when set). When the interpreter or deps
are unavailable it **skips loudly** with a printed warning and the reason; it
never reports a silent green. On developer boxes and CI (where `python3`
exists) the wrapper asserts pytest actually executed tests.

## Redis safety

The harness uses db 9 as instructed but **never calls `FLUSHDB`**. It writes
only its own five per-run uids plus `config:limits`,
`config:base_daily_usd` and `config:model_groups`; `cleanupHookContract`
restores the prior values of those three keys and deletes only its own keys.
The hook itself only ever touches the same db2 key shapes mint projects.
