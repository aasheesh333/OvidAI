# Ovid Si Premium Share and Domain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a measured 95+ UX pass, app-capable session sharing with fork-and-continue, and a staged `api.ovidsi.com` migration.

**Architecture:** Keep the existing immutable share snapshot/public viewer as the read boundary, add a server-authorized idempotent fork path and platform link resolver, and migrate the gateway through DNS/TLS health gates before changing client constants.

**Tech Stack:** Flutter/Dart, Flutter widget tests, Python gateway/server tests, Caddy, Cloudflare DNS, PowerHost registrar, Android App Links/install referrer.

**Spec:** `docs/superpowers/specs/2026-10-07-premium-share-domain-design.md`

## Global Constraints

- Preserve social + phone authentication and existing Firebase ownership fences.
- Preserve immutable share snapshots, expiry, revocation, escaping, no-store, and no-index behavior.
- Never switch app URLs to `api.ovidsi.com` before DNS and TLS health checks pass.
- Keep the old gateway hostname as rollback until the migration verification gate passes.
- Do not expose credentials, hidden reasoning, tool state, or private metadata in shares.
- Every behavior change requires a focused failing test before production code.
- UI score improvements must correspond to implemented interaction/state/accessibility changes.

### Task 1: Share-link contract and fork API

**Files:**
- Inspect/modify: `lib/core/conversation_share_service.dart`
- Inspect/modify: server share route/service files discovered by existing tests
- Test: `test/conversation_share_service_test.dart` and server share tests

**Interfaces:**
- Preserve existing `ConversationShare` and immutable snapshot contracts.
- Add an authenticated fork operation returning the new owned session identifier.
- Require an idempotency request ID and reject cross-owner or expired tokens.

- [ ] Write failing service/server tests for authenticated fork success, expiry, revocation, owner isolation, idempotency replay, and secret exclusion.
- [ ] Run the focused tests and verify they fail for the missing fork contract.
- [ ] Implement the smallest server endpoint and client method using existing auth/request conventions.
- [ ] Run focused service/server tests and verify all pass.
- [ ] Commit with `feat(share): add authenticated fork continuation`.

### Task 2: App/web deep-link resolver

**Files:**
- Modify: Android intent/app-link configuration and Flutter startup link handling files identified in the existing platform setup.
- Create/modify: share resolver route/server deployment files.
- Test: deep-link parsing and startup routing tests.

**Interfaces:**
- Resolver URL: `https://ovidsi.com/s/<token>`.
- Installed app receives the token and opens the share viewer.
- Uninstalled app redirects to Play Store with a deferred token mechanism.

- [ ] Write failing tests for valid token parsing, malformed token rejection, installed-app routing, and post-install token restoration.
- [ ] Run the tests and verify they fail before adding routing.
- [ ] Implement Android App Links and a resolver response that preserves the token without logging it.
- [ ] Add an explicit `Continue in Ovid Si` action that authenticates before fork creation.
- [ ] Run Android/link tests and verify the original viewer, revoke, and expiry flows remain green.
- [ ] Commit with `feat(share): open shared sessions in app and continue safely`.

### Task 3: Premium UX implementation pass

**Files:**
- Modify: the 45 surfaces listed in `docs/superpowers/audits/2026-10-07-screen-scorecard.md`, grouped by shell, chat, Studio, browser, settings, auth, billing, plugins, and sheets.
- Test: corresponding existing widget tests plus new tests for each changed state.
- Update: `docs/superpowers/audits/2026-10-07-screen-scorecard.md` with before/after evidence.

**Interfaces:**
- Reuse `Aether`/Ovid Si primitives and existing navigation/state services.
- Each surface keeps its public route/API behavior.

- [ ] Group the 45 rows into implementation batches and identify the highest-impact sub-80 surfaces.
- [ ] For each batch, write failing tests for the missing primary action, loading/empty/error/retry, semantics, or responsive behavior.
- [ ] Implement one batch at a time with 200–300ms motion, reduced-motion handling, Paper/Ink/Signal Red tokens, and no unnecessary visual effects.
- [ ] Run each batch’s tests before moving to the next batch.
- [ ] Run screenshot/accessibility checks and re-score all 45 surfaces using the same weighted criteria.
- [ ] Commit each coherent batch with a scoped message.

### Task 4: Cloudflare and PowerHost DNS staging

**Files:**
- External: Cloudflare zones for `ovidsi.com` and `ovidsi.in`.
- External: PowerHost nameserver settings for both domains.
- Modify after activation: `/opt/ovid-gateway/caddy/Caddyfile` and gateway environment.

**Interfaces:**
- Create `api.ovidsi.com` only after the authoritative zone is active.
- Point it to the gateway origin using the correct proxy/TLS mode.

- [ ] Add `ovidsi.in` to Cloudflare and record assigned nameservers.
- [ ] Set both domains’ nameservers in the authenticated PowerHost account.
- [ ] Wait for both zones to become Active and verify authoritative DNS.
- [ ] Add the `api` record and configure Caddy certificate/routing for `api.ovidsi.com`.
- [ ] Probe `/health`, `/mint`, `/usage`, `/v1/models`, and image capabilities with expected auth responses.
- [ ] Keep the old hostname active until all probes pass.

### Task 5: Application hostname cutover

**Files:**
- Modify: `lib/core/ovid_cloud_service.dart`
- Modify: `lib/core/account_service.dart`
- Modify: `lib/core/image_studio.dart`
- Modify: `lib/core/state.dart`
- Modify: gateway `.env`, deployment snippets, and docs.
- Test: URL contract tests and endpoint smoke tests.

**Interfaces:**
- All Ovid-owned endpoints use `https://api.ovidsi.com`.
- Third-party provider URLs remain unchanged.

- [ ] Write failing URL contract tests that require the new hostname for Ovid-owned endpoints.
- [ ] Run them and confirm the old constants fail the contract.
- [ ] Change constants/config/docs and preserve third-party URLs.
- [ ] Verify DNS/TLS/endpoint probes before enabling the new app build.
- [ ] Run analyzer, focused cloud/share tests, full Flutter tests, and a debug build.
- [ ] Commit with `feat(infra): migrate Ovid gateway to api.ovidsi.com`.

### Task 6: Final quality gate

**Files:**
- Update: scorecard and migration audit documents.

- [ ] Run `flutter analyze`.
- [ ] Run the full Flutter suite and record passed/skipped/failed counts.
- [ ] Run `git diff --check`.
- [ ] Verify no old production hostname remains except rollback/deprecation documentation.
- [ ] Verify CI build and release artifacts.
- [ ] Confirm every external DNS action and unresolved blocker in the final report.
