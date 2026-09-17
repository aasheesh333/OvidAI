# Native API Integrations + Remaining Utilities (NP4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 45 external-service integrations (declarative REST descriptors + 5 special engines + 3 prompt patterns) and 7 leftover utilities, so every remaining catalog row installs via `nativeCapability` routing and exposes real `plugin__<slug>__<tool>` tools with user-supplied credentials.

**Architecture:** `rest_engine.dart` (descriptor model + `RestApiCapability` executor + SigV4/RESP/file/prompt helpers) executes `rest_descriptors_*.dart` data files; `misc_utilities.dart` holds the 7 utilities; per-batch `registerX()` functions wire into `registerAllNativePlugins()`. Tests use `MockClient` (HTTP), loopback sockets (RESP), temp dirs (Obsidian).

**Tech Stack:** Dart, Flutter, `package:http` (+`testing`), `crypto`, `qr`, `cryptography` (both pure-Dart, no native code).

**Spec:** `docs/superpowers/specs/2026-09-16-native-api-integrations-design.md`

## Global Constraints

- Only new pubspec deps allowed: `qr`, `cryptography` (pure-Dart). Nothing else.
- Secrets live in secure storage via `NativePluginConfigStore`; NEVER echoed in messages (assert absence in tests).
- Tool naming `plugin__<plugin_slug>__<tool_name>`; slugs via `NativePluginRegistry.slugify`.
- `timeout_seconds` on every network tool (default 30, clamp 5..300); 6000-char truncation + notice; non-2xx verbatim.
- Missing credentials → exact `Configure <credentialLabel> first…` message naming the Configure path.
- Error taxonomy: `ArgumentError` = bad args; `FormatException` = malformed content.
- `flutter analyze` 0 issues; all tests green (only known pre-existing PR13 excepted).

---

### Task 1: REST Framework + Special Engines

**Files:**
- Create: `lib/core/native_plugins/rest_engine.dart`
- Create: `test/native_plugins_rest_test.dart`

**Interfaces:**
- Produces (exact spec §2 shapes): `RestAuthKind`, `RestToolDef`, `RestServiceDescriptor`, `RestApiCapability(descriptor, {client})`, `registerRestServices(List<RestServiceDescriptor>)`, SigV4 `s3Authorization(...)` helper, RESP `respEncode(List<String>)` + minimal `RespClient` with injectable socket factory, Obsidian `VaultFiles(root)` helper with root-escape refusal.
- `RestApiCapability.callTool`: unknown tool → `ArgumentError`; creds missing → configure-first message; path `{arg}` substitution (missing → `ArgumentError`); auth injection per kind; `queryArgs` → query params; `jsonBodyArg` or `formBodyArg` (Stripe); `http.Client` injected (default real); timeout + truncation + verbatim errors.

- [ ] **Step 1: Write failing framework tests** — descriptor→tools/configFields; all 5 auth kinds inject correctly (assert request headers/query); missing-cred message (assert secret value ABSENT from message); `{arg}` substitution + missing-arg error; non-2xx verbatim; timeout default/override captured; truncation notice; form-body encoding; SigV4 fixed test vector (`AKIDEXAMPLE`, known date → known signature); RESP round-trip against a loopback fake server; Obsidian `../escape` refusal.
- [ ] **Step 2: Run** `/root/flutter/bin/flutter test test/native_plugins_rest_test.dart` → FAIL.
- [ ] **Step 3: Implement** `rest_engine.dart` (engine + helpers, zero service data).
- [ ] **Step 4: Re-run** → PASS.
- [ ] **Step 5: Commit** `git add lib/core/native_plugins/rest_engine.dart test/native_plugins_rest_test.dart && git commit -m "feat(plugin): declarative REST engine with SigV4/RESP/file helpers"`

---

### Task 2: Leftover Utilities (NP2b, 7 items)

**Files:**
- Create: `lib/core/native_plugins/misc_utilities.dart`
- Create: `test/native_plugins_misc_test.dart`
- Modify: `pubspec.yaml` (+`qr`, +`cryptography`), `lib/core/state.dart` (wire `registerMiscUtilities()` immediately — small, no reason to defer)

**Interfaces:**
- Produces: 7 capabilities + `registerMiscUtilities()`. Exact names: `'QR Generator'`, `'SSH Key Manager'`, `'Mermaid Diagrams'`, `'Excalidraw Bridge'`, `'Icon Library'`, `'Font Preview'`, `'Audio Notes'`. Tools per spec §3.

- [ ] **Step 1: Write failing tests** — QR PNG base64 header (`iVBOR`) + capacity-overflow honesty; SSH ed25519 pub format (`ssh-ed25519 AAAA…`) + save/get/list + fingerprint shape; Mermaid validate ok/bad + render with MockClient SVG passthrough + offline honest message; Excalidraw stats/add/merge + malformed → FormatException; Icon search MockClient hit parsing; Font search + preview_url shape; Audio transcribe MockClient text + missing-key message.
- [ ] **Step 2: Run** test file → FAIL.
- [ ] **Step 3: Implement** (add the two deps first: `flutter pub add qr cryptography` — if an API differs from expectation, adapt via TDD, do not invent shims).
- [ ] **Step 4: Re-run** → PASS. Also run `dart analyze` (new-dep lints).
- [ ] **Step 5: Commit + push** `git add lib/core/native_plugins/misc_utilities.dart test/native_plugins_misc_test.dart pubspec.yaml pubspec.lock lib/core/state.dart && git commit -m "feat(plugin): seven leftover native utilities" && git push origin hoplite/gortyn-77773150`

---

### Task 3: Comms Batch (8 services)

**Files:**
- Create: `lib/core/native_plugins/rest_descriptors_comms.dart`
- Create: `test/rest_comms_test.dart`
- Modify: `lib/core/state.dart` (wire `registerComms()`)

**Interfaces:**
- Produces descriptors (spec §4.1, exact names/bases/auth/tools): `'Slack Notify'`, `'Discord MCP'`, `'Discord Bot Builder'`, `'Telegram MCP'`, `'Twilio MCP'`, `'Cal.com MCP'`, `'WhatsApp Bridge'`, `'Email Drafts'` (prompt capability via `NativePromptCapability` — import `prompt_framework.dart`, `draft(to, subject, context)`; sending out, description says so).

- [ ] **Step 1: Write failing tests** — per tool: MockClient canned response; assert REQUEST url/method/auth header/query + secret correctness; missing-creds message; one error-passthrough; Email draft prompt contains fields + honest no-send note; roster halves for 2 services.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** descriptors + `registerComms()` + wiring. **Step 4: Re-run** → PASS.
- [ ] **Step 5: Commit + push** `... && git commit -m "feat(plugin): comms integrations batch" && git push origin hoplite/gortyn-77773150`

---

### Task 4: Dev Platforms Batch (8 services)

**Files:**
- Create: `lib/core/native_plugins/rest_descriptors_dev.dart`
- Create: `test/rest_dev_test.dart`
- Modify: `lib/core/state.dart` (wire `registerDevPlatforms()`)

**Interfaces:**
- Produces descriptors (spec §4.2): `'GitLab MCP'`, `'Bitbucket MCP'` (bearer-preferred, basic fallback), `'Jira MCP'`, `'Trello MCP'`, `'Linear Sync'` (GraphQL POST), `'Figma Bridge'`, `'Sentry Watch'`, `'Exa Search MCP'`.

- [ ] **Step 1–5:** Same TDD cycle as Task 3 (per-tool MockClient asserts incl. GraphQL body shape for Linear, basic-auth encoding for Jira/Bitbucket-fallback, queryKey params for Trello; roster halves for 2). Commit `feat(plugin): dev-platform integrations batch` + push.

---

### Task 5: Backend & Data Batch (10 services)

**Files:**
- Create: `lib/core/native_plugins/rest_descriptors_backend.dart`
- Create: `test/rest_backend_test.dart`
- Modify: `lib/core/state.dart` (wire `registerBackend()`)

**Interfaces:**
- Produces descriptors (spec §4.3): `'Firebase MCP'`, `'Supabase MCP'` (query-map passthrough), `'Airtable MCP'`, `'Appwrite MCP'`, `'PocketBase MCP'`, `'Vector DB MCP'`, `'MongoDB MCP'` (Data API scope), `'S3 MCP'` (SigV4 engine), `'Redis MCP'` (RESP engine, loopback-tested), `'Obsidian MCP'` (file engine, root-escape tests).

- [ ] **Step 1–5:** Same TDD cycle (SigV4 header asserted on S3 calls; RESP bytes asserted against loopback fake; Obsidian temp-dir vault incl. escape refusal; roster halves for 2). Commit `feat(plugin): backend and data integrations batch` + push.

---

### Task 6: Deploy & Infra Batch (11 services)

**Files:**
- Create: `lib/core/native_plugins/rest_descriptors_infra.dart`
- Create: `test/rest_infra_test.dart`
- Modify: `lib/core/state.dart` (wire `registerInfra()`)

**Interfaces:**
- Produces descriptors (spec §4.4): `'Vercel MCP'`, `'Vercel Deploy'` (+create/cancel), `'Railway MCP'` (GraphQL), `'Heroku MCP'` (+Accept header), `'DigitalOcean MCP'`, `'Cloudflare MCP'`, `'Docker MCP'` (unreachable-honest), `'Kubernetes MCP'` (bearer-only scope), `'Terraform MCP'`, `'Zapier MCP'` (webhook), `'Make.com MCP'`.

- [ ] **Step 1–5:** Same TDD cycle (Railway GraphQL body; Heroku Accept header; Docker-unreachable honest message test with connection-refused MockClient exception; K8s cert-cluster honest scope in description asserted by source test? No — behavior test with 403 body passthrough; roster halves for 2). Commit `feat(plugin): deploy and infra integrations batch` + push.

---

### Task 7: AI, Media & Productivity Batch (8 services)

**Files:**
- Create: `lib/core/native_plugins/rest_descriptors_aimedia.dart`
- Create: `test/rest_aimedia_test.dart`
- Modify: `lib/core/state.dart` (wire `registerAiMedia()`)

**Interfaces:**
- Produces (spec §4.5): `'OpenAI DALL·E MCP'` (exact middle-dot name; URL-returning, no binary), `'ElevenLabs MCP'` (2000-char cap, base64+count), `'Notion Sync'` (+version header), `'Google Drive MCP'` (incl. multipart upload), `'Stripe MCP'` (form bodies), `'YouTube Summarizer'` (`get_details`, no-captions honesty), `'LangChain MCP'` + `'AutoGPT Bridge'` (prompt capabilities).

- [ ] **Step 1–5:** Same TDD cycle (multipart body shape for Drive upload; form encoding for Stripe; ElevenLabs cap enforcement test; YouTube thin-metadata message; prompt-pattern template tests; roster halves for 2). Commit `feat(plugin): AI media and productivity integrations batch` + push.

---

### Task 8: Full Verification

**Files:** none (verification only, unless fixes needed)

- [ ] **Step 1: Run** `/root/flutter/bin/dart analyze lib test` → 0 issues.
- [ ] **Step 2: Run** `/root/flutter/bin/flutter test` → all green (only known pre-existing PR13 excepted; verify any other failure against its base).
- [ ] **Step 3: Coverage audit** — script-assert every MCP/Tool seed with an external service maps to a registered capability or a documented exclusion (npx-mapped trio, Hub, Screen Awareness): fail the audit otherwise. (Implementer writes the audit as a test in `test/rest_coverage_test.dart`: enumerate `AppState` seeds, assert registry coverage/exclusion. This is the plan's completeness gate — NOT optional.)
- [ ] **Step 4: Commit** test if new + push.

---

## Self-Review

**1. Spec coverage:** §2 framework → T1. §3 NP2b → T2. §4.1→T3, §4.2→T4, §4.3→T5, §4.4→T6, §4.5→T7. §5 verification → per-task tests + T8 coverage-audit gate (enumerates seeds — nothing silently dropped).
**2. Placeholder scan:** exact commands/messages/shapes/commits throughout; no TBD/TODO.
**3. Type consistency:** descriptor field names identical T1–T7; per-batch `registerX()` names match §4 headers; plugin names seed-verbatim (incl. `OpenAI DALL·E MCP` middle dot, `Make.com MCP` dot); `FANOUT`/prompt reuse references the landed NP5 mechanism without modifying it.
