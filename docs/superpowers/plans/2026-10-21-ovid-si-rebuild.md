# Ovid Si — Full App Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a minimal, accessible, production-hard Android app for Ovid Si — 56 screens rebuilt on a new design system, backed by per-session isolation, working Studio/GitHub, Connectors, a per-session browser, and Free/Go/Plus/Pro plans.

**Architecture:** Flutter thin client (no local agent) talks REST + one multiplexed WebSocket to the TypeScript cloud gateway. The gateway owns authn, admission, rate limits and enqueues runs; the worker owns the agent loop, bwrap sandbox, Playwright browser and MCP runtime. Postgres is the durable record, Redis the live event bus, R2 the object store. The UI is replaced screen-by-screen on a new token system; ten P0 backend fixes land before the chat UI is rebuilt because the current per-user workspace breaks the "100% isolated session" promise.

**Tech Stack:** Flutter/Dart · Fastify 5 + TypeScript · Postgres 16 + Drizzle · Redis 7 + BullMQ · bubblewrap + cgroups v2 + nftables · Playwright Chromium · Cloudflare R2 + Worker CDN · Firebase Auth / App Check / FCM · LiteLLM · Google Play Billing + RevenueCat.

**Spec:** `docs/superpowers/specs/2026-10-21-ovid-si-product-spec.md` (complete product spec, v2) plus the founder brief delivered in-session 2026-10-20/21 and the verified codebase audit of 2026-10-21. This plan argues from the spec; executors read both.

---

## Global Constraints

- **Free plan:** 50,000,000 tokens per 24h, hard ceiling 1,500,000,000 per 30 days, **auto model only**, manual models greyed out. No shared pool — the allowance is per user.
- **Go ($5 / ₹499):** auto only, 1.5× auto allowance.
- **Plus ($18 / ₹1,799):** manual models + 5× auto.
- **Pro ($99 / ₹9,999):** manual models + 20× auto.
- **Storage:** Free 3 GB · Go 5 GB · Plus 15 GB · Pro 75 GB.
- **Uploads:** Free 50 files/day · paid 80 files/3 h. Project caps 80 / 100 / 150 / 250.
- **Custom connectors:** Free 0 · Go 5 · Plus 20 · Pro 20.
- **Sessions are 100% isolated.** No session may read another's workspace, files, or transcript unless the user `@`-mentions it or enables share-session-memory.
- **The user never sees a provider key or the LiteLLM base URL** on any platform.
- **Android only** for this plan. Web and desktop are explicitly out of scope.
- **Live preview never uses a tunnel.** Preview is served through the gateway proxy to a sandbox port.
- Every user-facing string lives in `lib/l10n/app_en.arb` (template) and `app_hi.arb`. No inline literals in new code.
- Minimum touch target 48 × 48 dp; WCAG AA contrast; every icon-only control carries a semantic label.
- Money is USD internally; INR is display-only for India.
- No new dependency without a named purpose in the task that adds it.

---

## Review Focus

1. **A user with no technical background** opens the app, does not know what a "model", "MCP" or "workspace" is — every label must still make sense, and no screen may dead-end without a next action.
2. **A session that shares nothing** — opening chat B must never reveal chat A's files, even after A has been hibernated, deleted, or forked.
3. **A free user at the 50M/day ceiling** — the run must stop with a clear, non-technical message and a plan CTA, never a raw 429 or an infinite retry.
4. **A Studio run where the remote branch moved** — the UI must surface "Sync latest changes" before any write, and must never silently overwrite.
5. **A 50-user Collab session with one slow model** — one turn in flight must disable every other Send without dropping anyone's draft.

---

## Decision Log

| ID | Decision | Consequence |
|---|---|---|
| D1 | Free = 50M tokens/24h per user, 1.5B/30d hard ceiling, auto only | Accepted business risk. Verified cost at `auto` blended $0.60/M is ≈$900/user/month if fully consumed. **Monitoring gate M1 below is mandatory before public launch.** |
| D2 | Model chip sits top-left, immediately after the hamburger | Chat AppBar order: `☰ · model chip · spacer · Studio · Browser · ⋮` |
| D3 | Live preview uses a gateway proxy to a sandbox port | No tunnels; `cloudflared`/`ngrok` stay blocked in `policy.ts` |
| D4 | Plans become free / go / plus / pro | Requires migrating `planMath.ts` seeds and Play product IDs |
| D5 | 56 screens, English + Hindi | Every screen spec below carries its ARB keys |
| D6 | Theme follows the device, light fallback; Stitch obsidian/violet is the dark theme | `OTheme` + `ThemeMode.system`; `OColors.dark` is the approved palette verbatim, `OColors.light` is derived |
| D7 | UI v2 ships behind `OVID_UI_V2` until parity tests pass | The live app keeps working while the 45 v2 screens land |

### Mandatory monitoring gate M1

Before the free tier is enabled in production, `watch` must alert when any free user's 24h spend exceeds $0.50, and a global free-tier daily spend cap must exist as a kill switch. Without M1, D1 can produce an unbounded bill.

---

## Screen Inventory — 52 current → 56 target

| Current (verified) | Target | Change |
|---|---|---|
| Splash, login gate, account-not-ready, welcome, first-run | 1–7 | Restyle, add onboarding |
| ChatScreen | 8 | Rebuild |
| Model picker, mode sheet, attach, voice, overflow, jobs | 9–14 | Restyle |
| SessionsSidebar, projects, project dialog, add-to-project | 15–19 | Rebuild + pinned section |
| Studio, binding sheet (dead), editor, tree | 20–25 | Rebuild + repo/branch/diff/preview (net +4) |
| Browser | 26–27 | Rebuild + tab strip |
| Artifacts, preview | 28–30 | Rebuild + share/delete (+1) |
| Share sheet, collab join/live/members/report | 31–35 | Rebuild |
| Schedule list/editor | 36–39 | Rebuild + runs (+2) |
| Settings hub + 17 sub-screens | 40–56 | Reorder, add Connectors, Connector detail, Account health, Delete data, Reset memory |
| Trajectory, subagent, shared conversation | — | Kept, restyled |

---

## File Structure

### New Flutter files

| Path | Responsibility |
|---|---|
| `lib/ui/design/tokens.dart` | Colors, type scale, spacing, radius, elevation, duration curves |
| `lib/ui/design/components.dart` | `OButton`, `OCard`, `ORow`, `OSheet`, `OPill`, `OEmpty`, `OLoading`, `OError` |
| `lib/ui/design/motion.dart` | Shared durations + curves; reduced-motion check |
| `lib/ui/design/empty_state.dart` | One empty-state component used by every list |
| `lib/ui/nav/app_shell.dart` | Navigation shell, rail vs drawer, deep-link handling |
| `lib/ui/screens/chat/…` | `chat_page.dart`, `chat_appbar.dart`, `composer.dart`, `transcript.dart` |
| `lib/ui/screens/sidebar/…` | `sidebar.dart`, `session_tile.dart`, `project_tile.dart` |
| `lib/ui/screens/settings/…` | One file per settings screen |
| `lib/ui/screens/studio/…` | `repo_picker.dart`, `branch_picker.dart`, `studio_page.dart`, `diff_page.dart`, `preview_page.dart` |
| `lib/ui/screens/connectors/…` | `connectors_page.dart`, `connector_detail.dart`, `add_connector.dart` |
| `lib/ui/screens/library/…` | `artifacts_page.dart`, `artifact_detail.dart` |

Old `lib/ui/*.dart` files are deleted only after their replacement ships and a test covers the route.

### New cloud files

| Path | Responsibility |
|---|---|
| `cloud/packages/sandbox/src/sessionWorkspace.ts` | Per-session workspace path resolution |
| `cloud/packages/sandbox/src/gitCredential.ts` | Ephemeral askpass helper |
| `cloud/apps/gateway/src/routes/preview.ts` | Preview proxy token mint + proxy |
| `cloud/apps/gateway/src/rateLimit.ts` | Per-uid / per-IP / per-route limits |
| `cloud/apps/gateway/src/routes/plans.ts` | Plan catalog + per-plan model gating |

---

# Track 0 — Foundation

**Goal:** A design system, localization pipeline, and navigation shell that every later screen consumes. No screen work starts before Task 0.5.

### Task 0.1: Design tokens

**Files:**
- Create: `lib/ui/design/tokens.dart`
- Test: `test/design/tokens_test.dart`

**Interfaces:**
- Produces: `OColors`, `OType`, `OSpace`, `ORadius`, `OMotion`, and `OTheme.light` / `OTheme.dark`.

- [ ] **Step 1: Write the failing test**

```dart
test('spacing scale is 4-based and monotonic', () {
  const s = [OSpace.xs, OSpace.s, OSpace.m, OSpace.l, OSpace.xl, OSpace.xxl];
  expect(s, [4.0, 8.0, 12.0, 16.0, 24.0, 32.0]);
});
test('every text style has a line height of at least 1.35', () {
  for (final st in OType.all) {
    expect(st.height, greaterThanOrEqualTo(1.35));
  }
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/design/tokens_test.dart`
Expected: FAIL — `OSpace` is not defined.

- [ ] **Step 3: Implement the token classes**

Single accent color, neutral surfaces, one danger color, one success color. Light and dark are both first-class. No gradients except the splash.

- [ ] **Step 4: Verify**

Run: `flutter test test/design/tokens_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/design/tokens.dart test/design/tokens_test.dart
git commit -m "feat(design): token system for the rebuild"
```

### Task 0.2: Component library

**Files:**
- Create: `lib/ui/design/components.dart`, `lib/ui/design/empty_state.dart`, `lib/ui/design/motion.dart`
- Test: `test/design/components_test.dart`

**Interfaces:**
- Consumes: `OColors`, `OType`, `OSpace`, `ORadius`, `OMotion`.
- Produces: `OButton.primary/.secondary/.danger/.ghost`, `OCard`, `ORow`, `OPill`, `OSheet.show`, `OEmpty`, `OLoading`, `OError`.

- [ ] **Step 1: Write failing widget tests** for: primary button minimum size 48dp, disabled state announces `Semantics.enabled == false`, `OEmpty` requires a title and renders an action when given one.
- [ ] **Step 2: Run and fail** — `flutter test test/design/components_test.dart`
- [ ] **Step 3: Implement components** with `Semantics` labels, 150 ms transitions, and reduced-motion support.
- [ ] **Step 4: Verify** — tests pass.
- [ ] **Step 5: Commit** — `feat(design): shared components and empty states`

### Task 0.3: Localization pipeline

**Files:**
- Modify: `lib/l10n/app_en.arb`, create `lib/l10n/app_hi.arb`, `l10n.yaml`
- Test: `test/l10n_parity_test.dart`

**Interfaces:**
- Produces: every new key exists in both ARB files; `context.l10n` is the only access path.

- [ ] **Step 1: Write the parity test** — every key in `app_en.arb` exists in `app_hi.arb`, and no key is empty.
- [ ] **Step 2: Run and fail** — `flutter test test/l10n_parity_test.dart`
- [ ] **Step 3: Add the initial key set** for the shell, sidebar and chat screens.
- [ ] **Step 4: Verify** — `flutter gen-l10n && flutter test test/l10n_parity_test.dart` passes.
- [ ] **Step 5: Commit** — `feat(l10n): Hindi bundle and parity gate`

### Task 0.4: Navigation shell

**Files:**
- Create: `lib/ui/nav/app_shell.dart`
- Modify: `lib/ui/app_router.dart`, `lib/main.dart`
- Test: `test/nav/app_shell_test.dart`

**Interfaces:**
- Consumes: existing sealed `AppRoute`.
- Produces: routes `/`, `/c/:id`, `/s/:token`, `/settings`, `/settings/:section`, `/studio`, `/browser`, `/artifacts`, `/connectors`, `/connectors/:id`, `/schedule/:id`, `/preview/:sessionId`.
- Produces: `AppShell` that renders a rail at width ≥ 900 dp and a drawer below it.

- [ ] **Step 1: Write failing tests** — a deep link to `/connectors` opens the connectors page; a notification tap while settings is open pops to the root first; an unknown route falls back to home.
- [ ] **Step 2: Run and fail** — `flutter test test/nav/app_shell_test.dart`
- [ ] **Step 3: Implement the shell** — one `Navigator`, one `ScaffoldMessenger`, drawer state owned by the shell, not by the chat page.
- [ ] **Step 4: Verify** — tests pass, plus `flutter test test/app_router_test.dart` still passes.
- [ ] **Step 5: Commit** — `feat(nav): single-shell navigation for the rebuild`

### Task 0.5: Accessibility ratchet

**Files:**
- Modify: `test/a11y/*` existing suite
- Test: `test/a11y/rebuild_ratchet_test.dart`

- [ ] **Step 1: Write the ratchet** — every widget in `lib/ui/screens/` must have no icon-only control without a semantic label, and no text below 12 sp.
- [ ] **Step 2: Run and fail** on the first new screen.
- [ ] **Step 3: Fix the screen** rather than the test.
- [ ] **Step 4: Verify** — ratchet passes.
- [ ] **Step 5: Commit** — `test(a11y): ratchet for the rebuild`

---

# Track 1 — Security and Isolation (P0)

**Goal:** Make the product's promises true. Nothing in Track 5 may ship on top of the current per-user workspace.

### Task 1.1: Per-session workspace

**Files:**
- Create: `cloud/packages/sandbox/src/sessionWorkspace.ts`
- Modify: `cloud/packages/sandbox/src/manager.ts:347-374`, `cloud/packages/storage/src/workspacePaths.ts`, `cloud/packages/db/src/schema.ts`
- Test: `cloud/packages/sandbox/src/sessionWorkspace.test.ts`, `cloud/apps/e2e/src/security/session-isolation.test.ts`

**Interfaces:**
- Produces: `sessionWorkspaceDir(uid: number, sessionId: string): string` returning `{workspacesRoot}/{uid}/sessions/{sessionId}/workspace`.
- Produces: `attach(userId, {tier, sessionId})` — `sessionId` becomes required.

- [ ] **Step 1: Write the failing test** — create two sessions for one user, write `a.txt` in session A's jail, assert the file is absent from session B's jail and from the host path of B.
- [ ] **Step 2: Run and fail** — `pnpm -C cloud --filter @ovid/sandbox test sessionWorkspace`
- [ ] **Step 3: Implement** path resolution and pass `sessionId` through every `attach` caller; migrate existing archives to the session path with a one-off script.
- [ ] **Step 4: Verify** — isolation test passes, plus `pnpm -C cloud --filter @ovid/sandbox test`.
- [ ] **Step 5: Commit** — `feat(sandbox): per-session workspace isolation`

### Task 1.2: Ephemeral git credentials

**Files:**
- Create: `cloud/packages/sandbox/src/gitCredential.ts`, `cloud/apps/gateway/src/routes/gitToken.ts`
- Modify: `cloud/packages/sandbox/src/etcFiles.ts`, `cloud/packages/agent-core/src/tools/git.ts`
- Test: `cloud/packages/sandbox/src/gitCredential.test.ts`, `cloud/apps/e2e/src/security/git-token.test.ts`

**Interfaces:**
- Produces: `installGitCredential({ homeDir, token, uid, host })` writing a `GIT_ASKPASS` script with mode `0700` and a `.gitconfig` that sets only `credential.helper=!f() { ...; }; f`.
- Produces: `GIT_ASKPASS` and `OVid_GIT_TOKEN` are injected into the exec env, never written to `.git/config`.

- [ ] **Step 1: Write the failing test** — after a clone and push in the jail, `grep -r <token> /workspace/.git` returns nothing, and `git config --list` contains no secret.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** the askpass script and per-exec env injection; delete the file after the command.
- [ ] **Step 4: Verify** — both tests pass.
- [ ] **Step 5: Commit** — `feat(sandbox): ephemeral git credentials, never on disk`

### Task 1.3: Stop exposing provider keys

**Files:**
- Modify: `cloud/apps/mint/src/mintRoutes.ts:148-160`, `lib/core/ovid_cloud_service.dart:700-790`, `lib/core/state.dart:5042-5060`
- Test: `cloud/apps/mint/src/mintRoutes.test.ts`, `test/cloud_key_secrecy_test.dart`

**Interfaces:**
- Produces: `POST /mint` response `{ tier, plan, limits }` — no `key`, no `base_url`.
- Produces: the client sends all traffic through `/cloud/v1`; no provider config is written locally.

- [ ] **Step 1: Write the failing tests** — the mint response has no `key` field; the client makes no request to a LiteLLM host.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** the response change and remove the client's provider write.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(security): provider keys never reach the client`

### Task 1.4: Postgres row-level security

**Files:**
- Create: `cloud/packages/db/drizzle/0023_rls.sql`
- Modify: `cloud/packages/db/src/client.ts`
- Test: `cloud/apps/e2e/src/security/rls.test.ts`

**Interfaces:**
- Produces: every tenant table has `ENABLE ROW LEVEL SECURITY` and a `USING (user_id = current_setting('ovid.uid')::text)` policy; `messages`, `runs`, `session_event_mirror` gain a `user_id` column and a policy.

- [ ] **Step 1: Write the failing test** — with `ovid.uid` set to B, a raw `SELECT` on A's session returns zero rows.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** the migration and set `ovid.uid` per request/transaction.
- [ ] **Step 4: Verify** — the full route sweep still passes.
- [ ] **Step 5: Commit** — `feat(db): row-level security on every tenant table`

### Task 1.5: Gateway rate limiting

**Files:**
- Create: `cloud/apps/gateway/src/rateLimit.ts`
- Modify: `cloud/apps/gateway/src/app.ts:323-386`
- Test: `cloud/apps/gateway/src/rateLimit.test.ts`

**Interfaces:**
- Produces: defaults `send: 30/min/uid`, `upload: 20/min/uid`, `read: 600/min/uid`, `auth: 60/min/IP`; Redis-backed sliding window; `429` with `retry_after`.

- [ ] **Step 1: Write the failing test** — the 31st send in a minute returns 429 with a `retry_after` header.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** — limits do not trip the existing load test.
- [ ] **Step 5: Commit** — `feat(gateway): per-uid and per-ip rate limits`

### Task 1.6: Browser tool consent and approval

**Files:**
- Modify: `cloud/packages/browser/src/tools/navigation.ts`, `cloud/packages/browser/src/tools/interaction.ts`, `cloud/packages/agent-core/src/roster.ts:174-191`
- Test: `cloud/apps/e2e/src/security/browser-consent.test.ts`

**Interfaces:**
- Produces: first navigation to a host asks for consent and persists a `grants` row; `browser_cookies` returns names only unless the specific cookie is approved; `browser_evaluate` is Read-Only/never in auto unless approved.

- [ ] **Step 1: Write the failing test** — in `auto` mode, `browser_open("https://new-host")` emits `approval_requested`.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(browser): per-host consent and gated secret tools`

### Task 1.7: Sandbox syscall and egress hardening

**Files:**
- Modify: `cloud/packages/sandbox/src/invocation.ts:64-110`, `cloud/packages/sandbox/src/net.ts:168-199`
- Create: `cloud/deploy/sandbox/seccomp.json`
- Test: `cloud/packages/sandbox/src/verification/isolation.test.ts`

- [ ] **Step 1: Write the failing test** — a payload calling a denied syscall (e.g. `mount`) is killed by seccomp; a connect to a non-allowlisted host on 443 is refused.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** `--seccomp` and a destination allowlist for package registries and the configured APIs.
- [ ] **Step 4: Verify** — the acceptance suite passes.
- [ ] **Step 5: Commit** — `feat(sandbox): seccomp profile and destination egress allowlist`

### Task 1.8: Revocation, deletion fence, workspace purge

**Files:**
- Modify: `cloud/apps/gateway/src/auth.ts:111`, `cloud/apps/gateway/src/index.ts:162-165`, `cloud/packages/account/src/adapters.ts:436-440`
- Test: `cloud/apps/e2e/src/security/revocation.test.ts`

- [ ] **Step 1: Write the failing tests** — a revoked token gets 401 on every `/cloud/v1` route; a deletion-fenced account gets 403 on send; account deletion removes `/workspaces/{uid}` from the host.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(security): revocation, deletion fence, host purge`

---

# Track 2 — Studio, GitHub, Live Preview

### Task 2.1: GitHub connect (revive the dead sheet)

**Files:**
- Modify: `lib/ui/github_login_sheet.dart`, `lib/core/github_service.dart`, `lib/ui/screens/studio/repo_picker.dart`
- Test: `test/studio/github_connect_test.dart`

- [ ] **Step 1: Write the failing test** — tapping "Connect GitHub" on the Studio empty state opens the device-flow sheet.
- [ ] **Step 2: Run and fail** — no caller exists today.
- [ ] **Step 3: Wire the sheet** into the Studio repo picker.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(studio): reachable GitHub connect`

### Task 2.2: Production `StudioBindingPort`

**Files:**
- Modify: `lib/core/chat_integration_ports.dart:148-152`, `lib/main.dart`
- Create: `lib/core/studio_binding_controller.dart`
- Test: `test/studio/binding_port_test.dart`

**Interfaces:**
- Produces: `StudioBindingController` implementing `StudioBindingPort` with `listRepos`, `listBranches`, `bind`, `syncLatest`, `bindingFor`.

- [ ] **Step 1: Write the failing test** — in production wiring, `StudioBindingPort.instance` is non-null.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** and install at startup.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(studio): production binding port`

### Task 2.3: Repo and branch pickers

**Files:**
- Create: `lib/ui/screens/studio/repo_picker.dart`, `lib/ui/screens/studio/branch_picker.dart`
- Test: `test/studio/pickers_test.dart`

- [ ] **Step 1: Write failing widget tests** — repo list shows search, empty state ("No repositories"), and a connect CTA; branch picker shows the default branch first.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(studio): repo and branch pickers`

### Task 2.4: Sync chip and diff

**Files:**
- Create: `lib/ui/screens/studio/diff_page.dart`
- Modify: `lib/ui/screens/studio/studio_page.dart`
- Test: `test/studio/sync_diff_test.dart`

- [ ] **Step 1: Write the failing tests** — when the remote is ahead, a "Sync latest changes" chip appears before any save; the diff page lists changed files.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** on top of `git fetch && git status` in the worker.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(studio): remote sync and diff review`

### Task 2.5: Live preview through the gateway

**Files:**
- Create: `cloud/apps/gateway/src/routes/preview.ts`, `cloud/apps/gateway/src/previewToken.ts`, `lib/ui/screens/studio/preview_page.dart`
- Modify: `cloud/apps/worker/src/fileService.ts`
- Test: `cloud/apps/gateway/src/preview.test.ts`, `test/studio/preview_test.dart`

**Interfaces:**
- Produces: `POST /cloud/v1/sessions/:id/preview` → `{ url, expiresAt }`.
- Produces: `GET /preview/:token/*` proxies to `127.0.0.1:{allocatedPort}` inside the session's jail.
- Produces: ports allocated from `OVID_PREVIEW_PORT_BASE` in 1000-port blocks per session.

- [ ] **Step 1: Write the failing test** — a server listening on the session's allocated port is reachable through the proxy URL; another session's port is not.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** token minting + proxy; keep `cloudflared` blocked.
- [ ] **Step 4: Verify** — the preview test and the existing egress test both pass.
- [ ] **Step 5: Commit** — `feat(studio): sandbox-port live preview`

---

# Track 3 — Connectors

### Task 3.1: Connectors catalog UI

**Files:**
- Create: `lib/ui/screens/connectors/connectors_page.dart`, `connector_detail.dart`, `add_connector.dart`
- Test: `test/connectors/connectors_page_test.dart`

**Interfaces:**
- Consumes: `GET /cloud/v1/mcp/catalog`, `GET/POST /cloud/v1/plugins`, `GET/POST /cloud/v1/mcp/servers`.
- Produces: sections `Installed` / `Available`; search; `+` opens `add_connector.dart`.

- [ ] **Step 1: Write failing widget tests** — Free shows the `+` disabled with "Upgrade to add"; Go shows a 5-slot counter.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(connectors): catalog, detail and add flow`

### Task 3.2: Wire MCP into production runs

**Files:**
- Modify: `cloud/apps/worker/src/main.ts:880-930`, `cloud/apps/worker/src/runProcessor.ts:1560-1660`
- Test: `cloud/apps/worker/src/mcpRuntime.test.ts`

- [ ] **Step 1: Write the failing test** — a run for a user with an enabled MCP server advertises that server's tools and dispatches a call.
- [ ] **Step 2: Run and fail** — today `createMcpToolProvider` is never called from `main.ts`.
- [ ] **Step 3: Implement** the provider wiring and roster inclusion.
- [ ] **Step 4: Verify** — the MCP contract suite passes.
- [ ] **Step 5: Commit** — `feat(worker): dispatch MCP tools in production runs`

### Task 3.3: Custom MCP trust gate

**Files:**
- Modify: `cloud/packages/mcp/src/router.ts:1136-1163`, `cloud/apps/gateway/src/routes/mcpServers.ts`, `cloud/apps/worker/src/mcpTools.ts:413-447`
- Test: `cloud/apps/e2e/src/security/mcp-trust.test.ts`

- [ ] **Step 1: Write the failing test** — adding a custom server requires an explicit capability grant; the agent cannot add one on its own.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(connectors): explicit trust for custom MCP`

---

# Track 4 — Browser per session

### Task 4.1: Per-session browser

**Files:**
- Modify: `cloud/packages/shared/src/browser.ts:123`, `cloud/apps/worker/src/main.ts:890-905`
- Test: `cloud/packages/shared/src/browser.test.ts`

**Interfaces:**
- Produces: `sessionBrowserKey(uid, sessionId)`; the legacy `userBrowserKey` is deleted.

- [ ] **Step 1: Write the failing test** — two sessions get different keys and different contexts.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(browser): one browser per session`

### Task 4.2: Browser screen rebuild

**Files:**
- Create: `lib/ui/screens/browser/browser_page.dart`, `tab_strip.dart`
- Test: `test/browser/browser_page_test.dart`

- [ ] **Step 1: Write failing widget tests** for read-only mode (no input sent), take-control, and the 45s headless notice.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** on top of the existing `BrowserStreamClient`.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(browser): minimal viewer with tab strip`

---

# Track 5 — UI replacement

Every screen below follows the same task shape: widget test → fail → implement with `OEmpty` / `OLoading` / `OError` → verify → commit. Only the distinctions are recorded.

### Task 5.1: Chat page

**Files:** `lib/ui/screens/chat/chat_page.dart`, `chat_appbar.dart`, `composer.dart`, `transcript.dart`
**AppBar:** `☰ · model chip · spacer · Studio · Browser · ⋮` (D2).
**Composer:** `+` · mode chip · studio chip · spacer · mic · send/stop.
**States:** empty (3 starter prompts + voice CTA), loading history, running, approval, offline queue, plan-limited, error.
**Tests:** `test/chat/chat_appbar_test.dart`, `composer_test.dart`, `empty_state_test.dart`.

### Task 5.2: Sidebar

**Files:** `lib/ui/screens/sidebar/sidebar.dart`, `session_tile.dart`, `project_tile.dart`
**Order:** profile + plan → New chat → Search → Pinned → Projects → Sessions → Schedule · Artifacts · Settings.
**States:** empty, searching, sync failed, offline.
**Tests:** `test/sidebar/sidebar_test.dart`.

### Task 5.3–5.9: Settings (one task each)

| Task | Screen | Keys |
|---|---|---|
| 5.3 | Settings hub | `settings.account`, `.plan`, `.usage`, `.credentials` |
| 5.4 | Account | `account.profile`, `.details`, `.linked`, `.danger` |
| 5.5 | Plan & billing | `billing.current`, `.plans`, `.restore` |
| 5.6 | Usage | `usage.window`, `.by_model`, `.history` |
| 5.7 | Memory + editor | `memory.files`, `.edit`, `.share` |
| 5.8 | Data control | `data.export`, `.import`, `.storage`, `.delete`, `.reset` |
| 5.9 | Advanced | `advanced.notifications`, `.health`, `.about` |

### Task 5.10: Studio screens

**Files:** `lib/ui/screens/studio/studio_page.dart`, `editor.dart`, `file_tree.dart`
**States:** no repo, connecting, cloning, ready, conflict, offline.

### Task 5.11: Library

**Files:** `lib/ui/screens/library/artifacts_page.dart`, `artifact_detail.dart`
**States:** empty, searching, load more, missing/unavailable.

### Task 5.12: Sharing and Collab

**Files:** `lib/ui/screens/share/*`, `collab/*`
**Constraint:** 50 members; send disabled while any turn is in flight.

### Task 5.13: Schedules

**Files:** `lib/ui/screens/schedules/*`
**States:** none, one-off, daily, cron error, run history.

### Task 5.14: Onboarding and auth

**Files:** `lib/ui/screens/onboarding/*`
**Flow:** language → "what do you want to do?" → 3 examples → first result in under 60 s.

---

# Track 6 — Plans, Billing, Usage

### Task 6.1: Plan catalog migration

**Files:** `cloud/apps/mint/src/planMath.ts:202-205`, `server/mint/ovid_plans.py`
**Tests:** `planMath.test.ts`

- [ ] Migrate `free/go/plus/pro` with the prices in Global Constraints and a test that `auto` resolves to a member for every plan.

### Task 6.2: Per-plan model gating

**Files:** `cloud/apps/gateway/src/keys.ts:33-37`, `cloud/apps/gateway/src/routes/plans.ts`
**Tests:** `cloud/apps/gateway/src/plans.test.ts`

- [ ] **Step 1: Write the failing test** — a free-plan send with `model: "big-pro"` returns 403 `model_not_in_plan`; `auto` succeeds.
- [ ] **Step 2: Run and fail** — the comment "every plan may use every catalog model" is the current behaviour.
- [ ] **Step 3: Implement** the per-plan allowlist.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(plans): per-plan model allowlist`

### Task 6.3: Free-tier ceiling

**Files:** `cloud/apps/mint/src/windows.ts`, `cloud/packages/shared/src/rest.ts`
**Tests:** `cloud/apps/mint/src/windows.test.ts`

- [ ] **Step 1: Write the failing test** — 50M tokens in 24h returns `429 free_daily_cap`; 1.5B in 30 days returns `429 free_monthly_cap`.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** the counters in the LiteLLM hook and the gateway copy.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(plans): free 50M/day and 1.5B/30d ceilings`

### Task 6.4: RevenueCat

**Files:** `lib/core/billing/revenuecat.dart`, `cloud/apps/mint/src/billing/revenuecatWebhook.ts`
**Tests:** `test/billing/revenuecat_test.dart`, `revenuecatWebhook.test.ts`

- [ ] **Step 1: Write failing tests** — a webhook upgrades the tier; an unknown product is ignored.
- [ ] **Step 2: Run and fail.**
- [ ] **Step 3: Implement** the webhook and the client purchase flow, keeping Play Billing as the sandbox path.
- [ ] **Step 4: Verify.**
- [ ] **Step 5: Commit** — `feat(billing): RevenueCat entitlements`

### Task 6.5: Usage screen

**Files:** `lib/ui/screens/settings/usage_page.dart`
- [ ] Graphs per model (auto + custom), images, and remaining allowance; no money shown to the user.

---

# Track 7 — Scale and Ops

| Task | Deliverable | Test |
|---|---|---|
| 7.1 | Multi-host sandbox scheduler; `MAX_ACTIVE_SANDBOXES` per host | capacity harness at 1k concurrent |
| 7.2 | Browser pool per session, 4 per host | pool soak test |
| 7.3 | Queue sharding by uid | replay test |
| 7.4 | Postgres read replicas + partitioning | migration dry run |
| 7.5 | Ops dashboard: plan edit, key view, block/unblock, refund, impersonate | admin route tests |
| 7.6 | **M1 monitoring gate** — free spend alert at $0.50/user/day, global kill switch | `watch` check test |

---

# Track 8 — Product completeness (features that were implied, now explicit)

These close gaps between the founder brief and the original plan. Each is a
test-first task with a named acceptance check from the product spec.

### Task 8.1: Session @mentions and read-only context injection

**Files:** `cloud/packages/agent-core/src/mentions.ts`, `cloud/apps/gateway/src/routes/sessions.ts`, `lib/ui/v2/chat/composer.dart`
**Test:** `cloud/packages/agent-core/src/mentions.test.ts`
- [ ] Failing test: `@session:abc` resolves only if the caller owns abc; the injected transcript is capped at 8K tokens and marked read-only.
- [ ] Implement autocomplete data (`GET /cloud/v1/mentions?q=`), composer chips, and the read-only context block.
- [ ] Verify: another user's id returns 404, never content.

### Task 8.2: Per-session memory writer and merge order

**Files:** `cloud/packages/agent-core/src/memory.ts`, `cloud/apps/worker/src/runProcessor.ts`
**Test:** `cloud/packages/agent-core/src/memory.test.ts`
- [ ] Failing test: after a turn, `{workspace}/.ovid/memory/{sessionId}.md` is updated, capped at 32 KB; merge order is global → project → session.
- [ ] Implement the writer, the cap, and the Settings editor read/write route.
- [ ] Verify: deleting a session deletes its memory file.

### Task 8.3: Queue semantics and Stop

**Files:** `cloud/packages/agent-core/src/queue.ts`, `lib/ui/v2/chat/chat_page.dart`
**Test:** `cloud/packages/agent-core/src/queue.test.ts`
- [ ] Failing test: a send during a run is queued; Stop cancels the run and dispatches the queued message immediately; order is preserved.
- [ ] Implement queue state in the run event mirror and the composer queue strip.
- [ ] Verify: no duplicate dispatch when Stop and completion race.

### Task 8.4: Share-session memory, fork, and read-only links

**Files:** `server/shares/*`, `cloud/apps/gateway/src/routes/shares.ts`, `lib/ui/v2/share/*`
**Test:** `cloud/apps/e2e/src/shares/fork.test.ts`
- [ ] Failing test: a read-only link never exposes files/connectors; fork copies messages and memory into the recipient's account, not the workspace.
- [ ] Implement the share toggle, fork endpoint and UI.
- [ ] Verify: revoking a link invalidates the token immediately.

### Task 8.5: Voice locales and app language

**Files:** `lib/core/voice.dart`, `lib/l10n/*.arb`, `lib/ui/v2/chat/composer.dart`
**Test:** `test/voice_locale_test.dart`
- [ ] Failing test: Hindi, Hinglish, Punjabi and Tamil map to the right STT locale; the selected locale survives restart.
- [ ] Implement the locale picker and ARB bundles.
- [ ] Verify: unsupported locale falls back to English.

### Task 8.6: Offline queue and notification deep links

**Files:** `lib/core/offline_queue.dart`, `lib/core/push_service.dart`, `lib/main.dart`
**Test:** `test/offline_queue_test.dart`, `test/push_route_test.dart`
- [ ] Failing test: a message sent offline is persisted, retried on reconnect and never duplicated; a push tap while signed out is queued until the account is ready.
- [ ] Implement the queue and route resolution for run/schedule/share targets.
- [ ] Verify: a cold-start tap lands on the right chat after hydration.

### Task 8.7: App lock (biometric)

**Files:** `lib/core/app_lock.dart`, `lib/ui/v2/settings/account_page.dart`
**Test:** `test/app_lock_test.dart`
- [ ] Failing test: when enabled, a resumed app requires biometrics; five failures fall back to device credentials; disabling requires biometrics.
- [ ] Implement with `local_auth` (new dependency, named purpose) and a secure-storage flag.
- [ ] Verify: the flag is off by default and never blocks first-run onboarding.

### Task 8.8: Android share intent (receive text/files)

**Files:** `android/app/src/main/AndroidManifest.xml`, `lib/core/share_intake.dart`
**Test:** `test/share_intake_test.dart`
- [ ] Failing test: a shared image/text opens a new chat with the attachment staged; a shared URL becomes a link chip.
- [ ] Implement the intent filter and staging.
- [ ] Verify: the intake never bypasses the 50-file/day free cap.

### Task 8.9: Collab 50 members, one sender, creator pays

**Files:** `server/collaboration/migrate.py:108`, `cloud/apps/gateway/src/routes/collab.ts`, `lib/ui/v2/collab/*`
**Test:** `cloud/apps/e2e/src/collab/limits.test.ts`
- [ ] Failing test: the 51st join is refused; a second sender gets 409 `turn_in_flight`; storage is charged to the creator.
- [ ] Implement the constraint migration, turn lock and storage attribution.
- [ ] Verify: a dropped sender releases the lock within 10 s.

### Task 8.10: Subagent log contract and 8-hour cap

**Files:** `cloud/packages/agent-core/src/subagents.ts`, `cloud/apps/worker/src/subagentRuntime.ts`
**Test:** `cloud/packages/agent-core/src/subagents.test.ts`
- [ ] Failing test: the summary is ≤300 tokens and matches the exact JSON keys; a subagent cannot dispatch another; at 8 h it stops with `status: "timeout"`.
- [ ] Implement the log path `/workspace/.ovid/logs/subagent_{id}.log`, schema validation and cap.
- [ ] Verify: the parent transcript receives only the summary.

### Task 8.11: Browser 45-second headless and downloads

**Files:** `cloud/packages/browser/src/manager.ts`, `cloud/packages/browser/src/tools/download.ts`
**Test:** `cloud/packages/browser/src/manager.test.ts`
- [ ] Failing test: closing the viewer schedules headless mode at 45 s and cancels it on reconnect; a download is written to artifacts and capped at 100 MB.
- [ ] Implement the timer, reconnect cancellation and artifact handoff.
- [ ] Verify: the run keeps going and pushes a notification when done.

### Task 8.12: Accessibility, telemetry and quality gates

**Files:** `test/a11y/*`, `lib/core/telemetry.dart`, `lib/ui/v2/**`
**Test:** `test/a11y/v2_ratchet_test.dart`
- [ ] Failing test: every v2 screen passes 320 dp + 200 % text + TalkBack label checks; reduced motion hides no content.
- [ ] Add the ratchet, cold-start/first-token traces, and the crash-free/ANR dashboards.
- [ ] Verify: the gate runs in CI on every PR.

### Task 8.13: Session pinning

**Files:** `lib/core/chat_pins.dart`, `lib/ui/v2/sidebar/sidebar.dart`
**Test:** `test/chat_pins_test.dart` (existing store contract)
- [x] Per-account pin persistence already ships in `ChatPinsStore` (account-scoped key, load/toggle/persist). The legacy chat header and project port already use it.
- [x] Decision: do **not** add a second `ChatSession.pinnedAt` source of truth. The sidebar adapter reads `ChatPinsStore.I.pinned`; a duplicate field was implemented, reviewed, and reverted the same day.
- [ ] Sidebar adapter splits pinned from Today/Yesterday and passes the pinned set (wiring pass).

---

# Execution Order

```
W1–W2   Track 0   design tokens, components, motion, theme
W1–W5   Track 1   isolation and runtime (parallel)
W4–W7   Track 2   model gateway and plans
W5–W8   Track 3   studio, browser, subagents
W6–W8   Track 4   collaboration and sharing
W2–W8   Track 5   all v2 screens (parallel waves)
W8–W15 Track 6   billing, usage, account
W10–W12 Track 7  security hardening and launch
W6–W14 Track 8   product completeness (@mentions, queue, offline,
                  app lock, share intake, collab 50, subagent cap)
```

Launch gate: Track 1 complete, M1 live, Track 5 all screens covered by tests,
Track 8 acceptance checks passing, and the 50-user collab soak passing.

**Current wave (2026-10-21):** Track 0 complete; Track 5 screen groups 1–9 in
flight behind `OVID_UI_V2`; Track 8 tasks queued behind the runtime tracks.
The live app is unchanged until the flag is flipped.

---

# Design Reference — Stitch (Android)

**Project:** Ovid Si AI Assistant — <https://stitch.withgoogle.com/projects/3288101158504867095>
**Mode:** App · Android phone frames · model **Balanced** · generated 2026-10-21.

44 screens were generated and are the visual source of truth for Track 5. The
exported folder actually contains 47 screens (three are alternate states), and
every one is catalogued in `docs/design/stitch/V2_SCREEN_SPECS.md`. They are
reference, not production code — Track 5 re-implements them with the token
system and the real states in this plan.

> **Home screen supersession:** the project contains two home variants. The **later** one (top bar `☰ · Auto ⌄ · Ovid Si · spacer · Studio · Browser · ⋮`) is the source of truth; the earlier one (model chip in the right cluster) is superseded. Track 5 follows the later variant and D2.

| Batch | Screens |
|---|---|
| Core | Home/chat empty, Sidebar, Model picker sheet, Live chat |
| Work surfaces | Studio repo picker, Studio workspace, Live preview, Browser, Connectors, Connector detail |
| Settings | Hub, Account, Plan & billing, Usage, Memory, Data control |
| Library | Artifacts library, Artifact detail, Schedules, Schedule editor |
| Identity | Onboarding welcome, Language & goal, Paywall, Share chat, Collab live, Run trajectory |
| System | Splash, Sign in, Search, Projects, Session actions, Model chip menu, State matrix (empty/offline/error/limit) |
| Studio states | Branch picker, Take control, Changes/diff, Add connector, Appearance, Credentials & account health |
| Gaps | Subagent detail, Collab members, Schedule runs, Storage |

### Locked visual tokens

- **Theme follows the device** (`ThemeMode.system`), **light is the fallback**;
  light and dark are both first-class.
- Dark (approved Stitch palette, verbatim): background `#0E0E10`, surface
  `#16161A`, hairline `#26262C`; accent violet `#7C5CFF`; success `#34D399`;
  danger `#F87171`.
- Light (derived from the same violet): background `#F7F7FA`, surface
  `#FFFFFF`, hairline `#E3E3EA`; accent fill `#6A45E8`; the same success/danger
  families, darkened for contrast.
- Inter or geometric sans; scale 28 / 20 / 16 / 14 / 12 sp; line-height 1.4.
- 16 dp card radius, 24 dp screen padding, 48 dp minimum target.
- 180–220 ms spring transitions; fade + 8 dp slide for list entry; reduce-motion obeys the OS setting.
- Icon **plus** text label; icon-only controls only in the top bar, and always with a semantic label.
- No gradients except the splash halo.

### Surfaces not separately drawn

These reuse the patterns above and need no new visual language: account-not-ready, first-run tips, add-to-project, file tree/editor split (drawn inside Studio workspace), artifact preview (drawn as Artifact detail), collab join, collab report, notification settings, About, and the remaining settings rows.

### Rule for Track 5

If an implementation detail is not visible in the Stitch reference, it is decided by this plan and the token system — never by inventing a new component. Any new component must be added to `lib/ui/design/o_components.dart` with a widget test first.
