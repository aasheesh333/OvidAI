# Task 1 Report: Share-link Contract and Fork API

## Status

Implemented and verified the canonical authenticated share fork contract.

## Changed files

- `lib/core/conversation_share_service.dart`
  - Added `ConversationShareService.fork`, which validates the opaque share ID,
    sends the authenticated `POST /shares/{id}/fork` request with a required
    idempotency request ID, and validates the returned owned session ID.
  - Preserved existing auth, App Check, account-change fencing, error handling,
    and immutable snapshot APIs.
- `test/conversation_share_service_test.dart`
  - Added focused client contract coverage for authenticated fork requests and
    response parsing.
- `server/shares/snapshot.py`
  - Added the strict, extra-field-forbidden `ForkShare` request schema.
- `server/shares/api.py`
  - Added authenticated `POST /shares/{token}/fork` using the existing verified
    UID and admission conventions.
- `server/shares/repository.py`
  - Added durable per-recipient idempotency receipts and atomic fork creation.
  - Forks require a live, non-revoked source snapshot and generate a new owned
    session ID without modifying the source snapshot or source owner record.
  - Fork receipts are removed by the durable account-deletion cleanup fence.
- `server/shares/tests/test_shares.py`
  - Added coverage for successful fork, idempotent replay, recipient isolation,
    immutable source content, expiry, revocation, and rejected secret fields.
- `server/shares/README.md`
  - Documented the fork endpoint and its security/idempotency contract.

## TDD and test output

The new Dart test was run before implementation and failed at compilation with
the expected missing-contract error:

```text
The method 'fork' isn't defined for the type 'ConversationShareService'.
```

Focused client tests after implementation:

```text
/root/flutter/bin/flutter test --no-pub test/conversation_share_service_test.dart
00:00 +6: All tests passed!
```

Focused server tests after implementation:

```text
/tmp/opencode/images-venv/bin/python -m unittest server.shares.tests.test_shares
............
----------------------------------------------------------------------
Ran 12 tests in 77.051s

OK
```

Additional static checks:

```text
/root/flutter/bin/flutter analyze lib/core/conversation_share_service.dart test/conversation_share_service_test.dart
No issues found! (ran in 3.8s)

(no output; passed)
```

The system `flutter` and `python` command aliases were unavailable. The
repository Flutter installation and the existing `/tmp/opencode/images-venv`
Python environment were used instead.

## Design decisions

1. Forking is a new authenticated server operation rather than a client-side
   copy. The server remains the security boundary and returns only the newly
   owned session identifier.
2. Fork idempotency is keyed by `(recipient UID, request ID)`. Replaying the
   same request returns the same session; reusing the request ID for another
   share returns a conflict.
3. The source token is checked against the live snapshot at transaction time,
   so expiry and revocation cannot be bypassed. The source share is never
   updated during a fork.
4. The recipient may differ from the source owner, as required for shared-link
   continuation. Each recipient receives a separately generated session ID,
   preventing cross-owner mutation or session reuse.
5. The fork request schema is strict and contains only `request_id`; no snapshot
   data, credentials, metadata, or secret-bearing fields can enter the fork
   path. Existing snapshot allowlisting and secret exclusion remain unchanged.
6. Fork receipts use the same durable SQLite transaction and account-deletion
   fence as the existing share data.

## Concerns

- The share service returns a new session identifier, but session materialization
  in the broader app/session store is outside Task 1 and remains for the later
  app continuation work.
- The server suite was run in the repository's existing image virtualenv because
  the base Python installation has no `pip`/FastAPI environment.
