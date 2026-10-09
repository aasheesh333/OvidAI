# Request Accounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Account for every device-originated model attempt without inventing measured usage or moving execution to the server.

**Architecture:** Introduce a standalone versioned attempt record and account-scoped durable journal. Integrate it into transport boundaries, then switch usage presentation to provenance-aware aggregates. Preserve existing session analytics and server allowance authority.

**Tech Stack:** Dart, Flutter, existing crypto and filesystem dependencies, Flutter test loopback SSE fixtures.

**Spec:** `docs/superpowers/specs/2026-10-08-device-execution-and-usage-design.md`

## Global Constraints

- Execution stays on the initiating device.
- Unknown usage and cost are not zero; explicit provider zero remains zero.
- Preserve existing dirty code and the unrelated `.superpowers` report.
- No commits, pushes, deployment or paid model calls without a direct request.
- Flutter verification uses `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1` and focused tests only.
- One writer owns each production file. Model/store work precedes state integration; state integration precedes transport/UI integration.

## Task 1: Standalone attempt model

Files: create `lib/core/usage_attempt.dart`, `test/usage_attempt_test.dart`.

Interface: immutable `UsageAttempt`, `UsageTokenCount`, `UsageProvenance`, `UsageOutcome`; `UsageAttempt.toJson()` and `UsageAttempt.fromJson(Map<String,dynamic>)`. Include attempt/request IDs, revision, source device, provider identity, requested/reported model, purpose, optional session/run association, start/completion timestamps, elapsed duration, dispatch stage, and nullable provenance-bearing token counts. Agree exact constructors with downstream workers after this task completes.

- [ ] Write failing round-trip and unknown/zero distinction tests, including:
  ```dart
  expect(UsageTokenCount.unknown().value, isNull);
  expect(UsageTokenCount.reported(0).value, 0);
  ```
- [ ] Run `test/usage_attempt_test.dart`, confirm missing implementation failure.
- [ ] Implement immutable records and strict versioned parsing; reject negative counts, malformed identities, unsupported schema and contradictory provenance/value pairs. Never accept arbitrary payload/error maps.
- [ ] Test mixed provenance totals, round-trip, explicit zero, malformed fields and unknown model identity; run targeted analyzer.

## Task 2: Durable account journal and legacy migration

Files: create `lib/core/usage_attempt_store.dart`, `test/usage_attempt_store_test.dart`; later modify only usage persistence/account-transition sections in `lib/core/state.dart` and `lib/core/cloud_usage_store.dart`.

Interface: journal accepts Task 1 records; account root is supplied by caller. Upsert by attempt ID/revision, read immutable snapshots, expose integer change revision. Flush before acknowledging durable writes. Report write failures. Retain pending attempts separately from bounded terminal history.

- [ ] Write restart/idempotency tests: upsert identical record twice, reopen journal, assert one attempt; conflicting same revision must fail without replacement.
- [ ] Run the new store test and confirm failure before implementation.
- [ ] Implement atomic journal persistence, bounded reads, revision checks and interrupted-at-restart classification without dispatching requests.
- [ ] Test malformed journals, injected write failure, old revisions, terminal-history pruning, pending retention and separate account roots.
- [ ] Migrate legacy records once with persisted unique IDs, preserving equal-valued duplicate rows and legacy-unspecified provenance. Add migration tests before modifying AppState.
- [ ] Replace list-length-only cache invalidation with journal revision and test updates without insertion. Preserve account callback fencing.

## Task 3: Transport capture

Files: modify `lib/core/agent_service.dart`; create `test/agent_attempt_accounting_test.dart`; reuse `test/agent_usage_attribution_test.dart`.

Consumes: Task 1 immutable attempt model and Task 2 durable store. Each actual HTTP request gets a new attempt ID; a logical invocation retains its request ID across fallback/retry. Purpose is supplied by user/helper call sites.

- [ ] Add loopback tests counting two outbound requests on retry and two distinct attempts under one logical request, with one record on duplicate completion.
- [ ] Run focused tests and confirm missing accounting failure.
- [ ] Record preparation before dispatch and update transmission stage conservatively. Finalize from available stream usage in success, cancellation, timeout and failure paths; raw exceptions never enter records.
- [ ] Cover OpenAI, Anthropic, reasoning-effort fallback and tool-schema fallback at actual dispatch sites; cover helpers/title/compaction/fanout/children through shared recorder.
- [ ] Remove main-loop usage append only after transport owns capture; retain session analytics. Test account switch and same-UID re-login stale callbacks.
- [ ] Run attempt, attribution, provider-control and relevant retry suites with the shared lock.

## Task 4: Provenance-aware usage presentation

Files: modify `lib/ui/usage_screen.dart`; create `test/usage_attempt_presentation_test.dart`.

Consumes: journal snapshot/revision and immutable attempts. Server allowance remains independently sourced from CloudUsageStore.

- [ ] Add widget tests asserting unknown usage is not displayed as measured zero, estimates are labeled, legacy values are not measured, and cloud attempts do not change server allowance.
- [ ] Run and confirm assertions fail on existing UI.
- [ ] Aggregate attempt counts separately from known token totals; group by reported model or explicitly unresolved requested alias. Include cloud/free/custom history, retained-history labels and incomplete-capture state. Unknown prices remain unavailable.
- [ ] Run widget tests and targeted analyzer; verify revision updates change displayed aggregates without adding rows.

## Task 5: Integration review

- [ ] Review model/store and transport independently for spec compliance and quality.
- [ ] Run focused combined regressions after integration; record commands and outcomes.
- [ ] Inspect `git diff --check` and final diff for unrelated changes.
- [ ] Report source/test completion separately from absent cloud sync, deployment and device verification.

## Parallel review wave

Alongside Task 1, independent read-only workers verify existing permission replay, memory account fencing, plugin mounting, UI regressions, stream attribution, performance, and backend deletion prerequisites. Findings feed bounded follow-ups; review agents must not edit shared production files or launch full suites. Sync and collaboration require their own specifications after accounting; this plan does not authorize a server execution service.
