# Preinstalled Plugin & MCP Runtime Audit — Task 10 (spec §10)

Date: 2026-09-08 · Branch `hoplite/gortyn-77773150` · Baseline `b232410`

This is the **pinned tested manifest** for the preinstalled (seeded) plugin and
MCP catalog. Every bundled MCP coordinate below was verified live against
`registry.npmjs.org` / `pypi.org` on 2026-09-07 (Task 10 recon) and re-checked
on 2026-09-08. The regression test
`PLUGIN10: bundled MCP seeds carry only pinned, registry-verified coordinates`
(test/core_regression_test.dart) enforces that no seed row carries a package
coordinate outside this manifest — adding a fictional package to the seed
fails CI.

## 1. Catalog division (spec §10)

| Tier | Rule | Rows |
|---|---|---|
| Core built-ins | Real Ovid functions with live handlers; stay installed+enabled only while `_pluginToolNames` resolves them | Web Search, Image Studio, File Reader, Sandbox Runtime (see §2) |
| Bundled MCP definitions | Verified package coordinates; seed `disconnected`, never `connected: true` | Filesystem, GitHub, Fetch, Memory, Puppeteer, Postgres, Playwright (see §3) |
| Discoverable catalog entries | No bundled executable content; labeled `Available` (installed: false); cannot claim tools or health | DeepThink Reasoning, MCP Server Hub, Web Fetch & Reader, Voice Input, … , 80 community rows |

## 2. Seeded plugins — capability audit

Gate: `AgentService._pluginToolNames` (agent_service.dart). A row seeded
`installed: true` MUST resolve ≥ 1 real contribution (tool/skill/hook/MCP).

| Plugin | Seed state | Real handler | Verdict |
|---|---|---|---|
| Web Search | installed+enabled | `web_search` → `_ddgSearch` (DuckDuckGo HTML, keyless) | keep installed |
| Image Studio | installed+enabled | `generate_image` → Pollinations (real bytes) | keep installed |
| File Reader | installed+enabled | `read_attachment` → attachment reader (real) | keep installed; claimed tool name corrected `file_read` → `read_attachment` (the `file_read` core tool is always-on and unrelated to this row) |
| Sandbox Runtime | installed+enabled | `run_shell`/fs tools in `_coreTools`, needs SandboxService | keep installed (core built-in; probes cover sandbox in Health screen) |
| DeepThink Reasoning | **was** installed+enabled | none — reasoning UI is gated by the `showReasoning` preference, never by this row | **demoted to Available** (marketing-only; mounts nothing) |
| Web Fetch & Reader | installed, not enabled | `fetch_url` (real HTTP GET → markdown) | discoverable-by-default row: installed-not-enabled is honest (installs on enable, tool gates on `installed && enabled`) |
| MCP Server Hub / 13 catalog rows / 80 community rows | not installed | none | discoverable catalog entries — labeled Available, install-time honesty reporting already reports "contributes no agent tools" where applicable |

Seed order preserved (Web Search first) — existing regression tests depend on it.

## 3. Bundled MCP servers — pinned tested manifest

| Server | Command/args | Registry status (2026-09-08) | Credentials | Seed state |
|---|---|---|---|---|
| Filesystem | `npx -y @modelcontextprotocol/server-filesystem` | npm 200, current | — | disconnected |
| GitHub | `npx -y @modelcontextprotocol/server-github` | npm 200, **deprecated** upstream | `GITHUB_TOKEN` | disconnected, description notes deprecation |
| Fetch | `uvx mcp-server-fetch` | PyPI 200 (needs python+uv in sandbox) | — | disconnected |
| Memory | `npx -y @modelcontextprotocol/server-memory` | npm 200, current | — | disconnected |
| Puppeteer | `npx -y @modelcontextprotocol/server-puppeteer` | npm 200, **deprecated** upstream (→ Playwright) | — | disconnected, description notes deprecation |
| Postgres | `npx -y @modelcontextprotocol/server-postgres` | npm 200, **deprecated** upstream | `DATABASE_URL` | disconnected, description notes deprecation |
| Playwright | `npx -y @playwright/mcp` | npm 200, current | — | disconnected |

### Removed rows (22) — nonexistent package coordinates (npm 404)

The following seed rows pointed at packages that do not exist on the registry.
Per the spec's release gate ("missing/unpublished package names are removed or
replaced with real implementations") they were **removed from the seed**:

Chrome DevTools (`@ovidai/chrome-devtools-mcp` — also carried a hardcoded
`connected: true` with no handshake; the real browser capability is the
always-on inbuilt-WebView `browser_*` core tools, independent of this row),
Brave Search (`@smithery/brave-search`), Slack (`@smithery/slack-mcp`),
GitLab (`@smithery/gitlab-mcp`), Google Drive (`@google/mcp-drive`),
Firebase (`@firebase/mcp`), Supabase (`@supabase/mcp`), Vercel (`@vercel/mcp`),
Docker (`@docker/mcp`), Kubernetes (`@k8s/mcp`), MongoDB (`@mongodb/mcp`),
Redis (`@redis/mcp`), S3 (`@aws/mcp-s3`), Notion (`@notion/mcp`),
Linear (`@linear/mcp`), Figma (`@figma/mcp`), [OI] DALL·E (`@openai/mcp-dalle`),
ElevenLabs (`@elevenlabs/mcp`), Twilio (`@twilio/mcp`), Discord (`@discord/mcp`),
Jira (`@atlassian/mcp-jira`), Obsidian (`@obsidian/mcp`).

Users can still add any of these as custom servers with real coordinates via
Add server / mcp.json import.

## 4. Status derivation (no hardcoding)

- `McpServer.connected` is only ever set after `McpService.connect()` and
  re-checked with `McpService.isConnected(canonicalId)` (handshake-truthful,
  Task 9). The single hardcoded `connected: true` (Chrome DevTools) is gone
  with the row.
- `AppState.reconnectServices()` (boot + resume, main.dart:148/:166) now
  **probes** every installed+enabled plugin via
  `AgentService.pluginToolNames`: resolving capability →
  `ServiceHealth.working` with detail `probe ok · tools: …`; nothing resolved →
  `ServiceHealth.failed` with `probe failed: … contributes no agent tools…`.
  The old blanket `working / 'enabled'` stamp is removed.
- The Plugins screen enable/install paths use the same probe-derived stamp
  (no unverified `working`).
- Credential-dependent MCPs (envHint set): card shows `Not configured`, detail
  screen shows `Needs setup: <ENV> …` and they never auto-spawn (connected
  intent is empty on fresh seed; auto-reconnect only respawns servers in the
  persisted intent list).
- Android/stdio incompatibility: `mcpUnsupportedReason()` (plugins_screen.dart)
  returns the structural reason (sandbox not installed / which runtime is
  needed); the MCP card shows `Unsupported` and the detail screen shows
  `Unsupported on this device: <reason>`.

## 5. Release-gate checklist (spec §10)

- [x] No seeded plugin marked installed unless `_pluginToolNames` resolves ≥ 1
      real contribution — enforced by
      `PLUGIN10: every preinstalled enabled plugin has real capability…`.
- [x] No seeded MCP marked connected unless `McpService.isConnected(name)` is
      true after handshake — same test.
- [x] Package coordinates verified against the registry; pinned manifest (this
      document) enforced by test — 22 nonexistent rows removed.
- [x] Credential-dependent MCPs show setup requirements and never auto-spawn
      until configured.
- [x] Android-incompatible desktop servers show `Unsupported on this device`
      with the missing runtime reason.
- [x] Startup health derived from probes, never hardcoded.

## 6. Task 12 smoke gate — 2026-09-08

Static/unit gates (run on branch `hoplite/gortyn-77773150`):

- `flutter analyze` — **0 issues** (HEAD, after removing 4 test-file
  lint nits flagged during this gate).
- `flutter test` — **550/550 passing** (all PLUGIN1–PLUGIN11 groups plus the
  full regression suite; 539 cases in `test/core_regression_test.dart` alone).
- `flutter build apk --debug` — **builds** the artifacts under
  `build/app/outputs/flutter-apk/app-debug.apk`.

Device smoke checklist (spec §12.10, plan Task 12 Step 3). Each item has
automated coverage in the named PLUGIN group; the interactive on-device pass
(one fixture [CC] plugin with command+skill+hook+stdio MCP, plus one
Streamable-HTTP MCP) is **recorded below as not executed in this
environment** — the harness has no attached Android device/emulator. Status of
each criterion as verified by tests:

| Smoke item | Evidence | Status |
|---|---|---|
| Approve once (consolidated sheet, first approval / reapproval on delta) | PLUGIN5 | covered by tests |
| Current-session activation for agent install | PLUGIN7/PLUGIN11 | covered by tests |
| No other-session access before restart | PLUGIN4/PLUGIN7/PLUGIN9 (session-scoped alias + owner gating) | covered by tests |
| One-restart global promotion (exactly once per boot) | PLUGIN7, PLUGIN11 boot-single-owner pin | covered by tests |
| Hook firing per request/tool | PLUGIN8 (all lifecycle points, ordering) | covered by tests |
| Dependencies (runtime provisioning, degraded signals) | PLUGIN6/PLUGIN7 | covered by tests |
| Namespaced tools and alias resolution | PLUGIN4/PLUGIN9 | covered by tests |
| Disable/uninstall cleanup (registrations, MCP servers, secrets) | PLUGIN7/PLUGIN9 | covered by tests |
| Accurate health (probe-derived, never hardcoded) | PLUGIN10 | covered by tests |

Residual risk: the physical on-device pass remains outstanding for the
release owner with hardware attached; nothing in static/unit gates covers
device-specific ABI facts beyond the `Unsupported on this device` reporting
path (itself test-pinned).
