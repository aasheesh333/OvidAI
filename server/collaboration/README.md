# Live collaboration authority (PostgreSQL)

The PostgreSQL authority stores the 50-member cap, the single-sender turn lock
(`collab_turns`) and creator-paid storage accounting (`collab_storage_files`,
`collab_storage_usage`). The repository never performs startup DDL; deployment
is an explicit, repeatable operation.

## Deploy

Run from the reviewed source checkout with `psycopg` installed, against the same
database/schema as the account lifecycle tables (`account_deletions`). The DSN
is read from the named environment variable, never from a default:

```sh
# Fresh database only: install the account lifecycle bootstrap first.
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 -f server/account/schema.sql

# Collaboration bootstrap + schema_extensions.sql, in one transaction:
python3 -m server.collaboration.migrate \
  --destination-dsn-env ACCOUNT_DATABASE_URL --schema public schema

# Print the persisted authority identity for the service environment:
python3 -m server.collaboration.migrate \
  --destination-dsn-env ACCOUNT_DATABASE_URL --schema public identity
```

`schema` is idempotent: it installs `server/account/schema_collaboration.sql`
and then `server/collaboration/schema_extensions.sql`, so re-running it repairs
a partial deployment. The extension file:

- creates `collab_turns`, `collab_storage_files` and `collab_storage_usage`;
- adds `collab_turns_uid`, `collab_storage_files_owner` and
  `collab_storage_files_session` indexes;
- adds validated foreign keys from both child tables to
  `collab_sessions(session_id)` with `ON DELETE CASCADE`;
- replaces the historical `max_uses BETWEEN 1 AND 9` invite check with
  `BETWEEN 1 AND 50` (the owner-inclusive member cap is still 50).

Existing account databases that deploy collaboration through SQL instead of the
Python CLI apply the equivalent migration after the bootstrap:

```sh
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f server/account/migrations/004_live_collaboration.sql
psql "$ACCOUNT_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f server/account/migrations/005_collaboration_contract.sql
```

Migration `005_collaboration_contract.sql` and `schema_extensions.sql` must stay
equivalent; `tests/test_deployment.py` enforces that.

## Verify

```sh
# Static deployment checks (no PostgreSQL required):
python3 -m pytest server/collaboration/tests/test_deployment.py -q

# Full collaboration suite against a disposable PostgreSQL 16 database:
COLLAB_TEST_POSTGRES_DSN=postgresql:///collab_test \
  python3 -m pytest server/collaboration/tests -q
```

The live deployment test creates a fresh schema, applies the account bootstrap,
runs the `schema` migration twice, and then exercises the member cap, turn lock
and creator-paid storage through the real PostgreSQL repository.
