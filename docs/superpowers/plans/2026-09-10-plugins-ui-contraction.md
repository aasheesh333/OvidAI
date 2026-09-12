# Plugins/MCP UI Contraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plugins/MCP settings has one GitHub-only install story behind a single "+", and every runtime row shows its durable canonical status + reason.

**Architecture:** Contract `showPluginSourceChooser` to the GitHub route; merge marketplace-add into one `showPluginAddSheet` behind one AppBar "+"; record every MCP outcome into `runtimeStatusStore` and render durable-only with a neutral no-record state.

**Spec:** `docs/superpowers/specs/2026-09-10-plugins-ui-design.md`

## Global Constraints

- GitHub-only UI: the only install routes are GitHub repo fetch and marketplace add (marketplaces are GitHub repos). No local folder / ZIP / npm / pasted-config / hand-typed MCP server UI.
- Exactly one "+" entry: one AppBar `Icons.add` → one sheet. Refresh stays separate.
- Durable-first display: runtime rows read `statusFor(canonicalId)` only; no record → neutral "Not started" (never `serviceStatus`, never `connected`/`installed`/`enabled` inference). Legacy no-`runtimeId` rows keep current display.
- Core install transaction (`PluginSource` types, inspect → approval → `installPlugin`), `addCustomMcpServer`, and the `file_picker` dependency stay untouched.
- Preserve all green tests (full `flutter test` 987/987 at baseline `7abbddd`); tests pinning removed UI are updated deliberately, never silently deleted without a plan-mandated reason.
- Flutter binary `/root/flutter/bin/flutter`, `ANDROID_HOME=/opt/android-sdk` (this PC; the old `/home/ubuntu/...` path does not exist).

---

### Task 1: GitHub-only source chooser

**Files:**
- Modify: `lib/ui/plugins_screen.dart`
- Modify: `test/core_regression_test.dart` (Task-11 seam tests)
- Create: `test/plugins_ui_github_only_test.dart`

**Interfaces:**
- `showPluginSourceChooser` keeps only the GitHub route (`_githubSourceFromInput` → `_runSourceInstall` → single install flow); `pluginPickDirectoryForTest` / `pluginPickZipFileForTest` seams and `FilePicker` call sites in this file are removed.

- [ ] **Step 1: Write failing tests** — chooser source has the GitHub field/button and no local/ZIP/npm/paste/direct-MCP routes or file-picker seams.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** — delete the five non-GitHub sections + seams; keep the header/approval copy accurate (GitHub-only wording).
- [ ] **Step 4: Run GREEN + retarget/remove seam tests deliberately, analyze.**
- [ ] **Step 5: Commit** `feat: github-only plugin install UI`

---

### Task 2: Single "+" sheet

**Files:**
- Modify: `lib/ui/plugins_screen.dart`
- Modify: `test/core_regression_test.dart` (removed-entry tests)
- Modify: `test/plugins_ui_github_only_test.dart` (extend)

**Interfaces:**
- `showPluginAddSheet(context)`: GitHub plugin fetch + marketplace add/list in one sheet. AppBar keeps refresh + one `Icons.add` (tooltip 'Add plugin or marketplace'). Detail-screen Install fallback opens the sheet.

- [ ] **Step 1: Write failing tests** — one "+" action exists; no standalone marketplace button, no extension install button, no `_AddMcpTile`/`_addMcpDialog`/`_importMcpConfig` entries; sheet routes both GitHub fetch and marketplace add; empty MCP list hints at "+".
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** — new sheet (reuse marketplace dialog body + GitHub field), rewire AppBar + detail fallback, delete the three removed dialogs/tile.
- [ ] **Step 4: Run GREEN + touched suites, analyze.**
- [ ] **Step 5: Commit** `feat: single add sheet for plugins and marketplaces`

---

### Task 3: Durable MCP status end-to-end

**Files:**
- Modify: `lib/core/state.dart` (record MCP outcomes durably)
- Modify: `lib/ui/plugins_screen.dart` (durable-only rendering + neutral no-record)
- Create: `test/plugins_mcp_durable_status_test.dart`

**Interfaces:**
- `toggleMcpServer` / `_connectMcpForStartup` (and any sibling writing `serviceStatus['mcp:…']`) also record `runtimeStatusStore`: `ready`/`failed`/`needsSetup`/`disabled` + reason under the canonical id. UI: durable-only `McpCard`, detail header status, diagnostics row; no-record → faint help + "Not started".

- [ ] **Step 1: Write failing tests** — toggle success/failure records durable `ready`/`failed` with reason; credential-blocked records `needsSetup`; disconnect records `disabled`; no-record renders neutral; diagnostics row never binary.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** core recording + UI rendering (keep Connect/Disconnect toggle + Unsupported/Needs-setup banners).
- [ ] **Step 4: Run GREEN + MCP/plugin suites, analyze.**
- [ ] **Step 5: Commit** `feat: durable MCP status with reasons`

---

### Task 4: Verification, audit, README

**Files:**
- Create: `test/plugins_ui_parity_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-plugins-ui-contraction.md`
- Modify: `README.md`

- [ ] **Step 1: Add end-to-end test** (GitHub-only routes, single "+", durable reasons incl. no-record neutral).
- [ ] **Step 2: Run full verification** (`flutter test`, analyze, `build apk --debug` (expected to fail on missing gitignored `google-services.json` — record honestly), `git diff --check`).
- [ ] **Step 3: Write audit + README; mark device checks NOT EXECUTED.**
- [ ] **Step 4: Commit** `docs: verify plugins UI contraction`

---

## Execution Order

```text
1 github-only chooser -> 2 single "+" sheet -> 3 durable MCP status -> 4 verification
```
