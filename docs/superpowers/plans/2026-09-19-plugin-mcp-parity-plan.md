# Plugin / MCP / Hooks / Skills Parity Plan

> Status: PLAN (no implementation yet). Owner: build session 2026-09-19.
> Branch: `hoplite/gortyn-77773150`. Source: 4 parallel read-only audits.
> Goal: every plugin, MCP server, hook, skill, agent and folder layout that
> works in Claude Code / Codex works the same way in Ovid — same files, same
> semantics, same lifecycle.

---

## 0. What is already real (do not regress)

The normalized plugin runtime is genuinely built and tested:

- Atomic install with rollback + prior-version restore (`plugin_runtime.dart`).
- Digest-bound capability grants, fail-closed (`plugin_permissions.dart`).
- Session/global activation scopes with one-restart promotion (`plugin_runtime.dart`).
- Symlink-hardened skill discovery and containment checks (`skills.dart`).
- Secret scrubbing from plugin metadata; secrets in secure storage (`plugin_manifest.dart`).
- Real stdio MCP spawn (argv list, no shell injection) and Streamable-HTTP POST RPC.
- 14 hook events wired with ordering, timeout, recursion guard, circuit breaker.
- Archive/source resolution hardened against traversal and oversized payloads.

Everything below is additive or a correction; none of it requires replacing this core.

---

## 1. Blockers (a documented feature cannot work today)

| # | Blocker | Evidence | Fix direction |
|---|---------|----------|---------------|
| B1 | Codex `.agents/skills/**/SKILL.md` parse but never mount | `plugin_adapters.dart:597`; blocked by `skills.dart:563-576` | Accept `.agents/skills/` + `.agents/personas/` in `_pathMatchesKind`, or normalize paths in the Codex adapter |
| B2 | Codex personas parse but never mount | `plugin_adapters.dart:598-602`; `skills.dart:573-574` | Same path-normalization fix |
| B3 | Stock Codex `config.toml` fails install on invented identity rule | `plugin_adapters.dart:573-578,420-430` | Derive `publisher/name` from source id when absent (as `GenericMcpAdapter` does) |
| B4 | Codex hooks never parsed | `plugin_adapters.dart:560-629` (no hook block) | Add a hook parser or remove the README claim |
| B5 | `.codex/skills` never discovered | no `.codex` reference in `lib/` | Add to workspace roots |
| B6 | `AGENTS.md` stored but never injected | `plugin_adapters.dart:580-585` | Inject contained, depth-limited instruction files into plugin system context |
| B7 | `.claude/` workspace-local folders not discovered (skills/commands/agents/settings) | `agent_service.dart:14051-14071` scans only `.dsh`, `.agents`, `agents` | Add `.claude/` roots + settings layer |
| B8 | CC `.claude/settings.json` / `settings.local.json` unsupported (no settings layer at all) | grep: no settings.json reader in `lib/` | Add a settings-scope loader (user/project/local precedence) |
| B9 | Hook matcher `*` (CC wildcard) silently never fires | `hook_service.dart:147-155` treats `*` as an invalid regex | Treat empty/`*` as "match all" before regex compilation |
| B10 | Legacy CC-native hook names dropped at import | `state.dart:5871,5891,5913,5921` filter to 6 legacy names | Route legacy imports through `canonicalHookEvent` |
| B11 | Settings-level MCP config (`mcpServers` in settings, `enableAllProjectMcpServers`, enabled/disabled lists) unsupported | no reader in `lib/` | Add settings-MCP reader + allow/deny lists |
| B12 | `${VAR}` / `${VAR:-default}` env interpolation absent everywhere | `mcp_config_parse.dart` copies values verbatim | Add one `interpolateMcpValue()` applied to args/env/url/headers/cwd |
| B13 | Legacy SSE transport hard-rejected | `mcp_service.dart:222-228` | Implement GET `/sse` + POST `/message`, or a visible migration path |

---

## 2. High-severity correctness / security gaps

| # | Gap | Evidence | Severity |
|---|-----|----------|----------|
| H1 | Per-server MCP timeout > 60 s silently capped at 60 s | `mcp_service.dart:620-626`; `catalog_set_mcp_timeout` writes a field that cannot raise it | High |
| H2 | Untrusted hook matcher regex → ReDoS (sync, no timeout) | `hook_service.dart:147-155` | High |
| H3 | Hook payload forwards raw tool args (incl. provider keys) to any observing plugin | `hook_service.dart:344-373`; `agent_service.dart:8972` | High |
| H4 | Prompt-type hook without explicit `type` runs as shell | `plugin_adapters.dart:281-285`; `hook_service.dart:519` | High |
| H5 | Duplicate canonical id throws, crashing skill publish and session switch | `skills.dart:216-224`; reached from `agent_service.dart:6980` | High |
| H6 | Unlocked read-modify-write on grants → lost approvals/revokes | `plugin_permissions.dart:311-341` | High |
| H7 | Unlocked read-modify-write on activation/rows → lost installs | `plugin_runtime.dart:705-724,792-812,1692-1695` | High |
| H8 | Native Fetch is unrestricted SSRF + unbounded read | `native_mcp.dart:909-953` | High |
| H9 | `SandboxService.spawn` bypasses `checkPolicy`; ownerless MCP `cwd` uncontained | `sandbox_service.dart:2593-2630`; `mcp_service.dart:930-936` | High |
| H10 | MCP stream subscriptions / process groups / per-call HTTP clients leak | `mcp_service.dart:900-922,1061-1073`; `native_mcp.dart:22,812` | High |

---

## 3. Partial parity (works, but not the way the real tools do)

| # | Item | Evidence |
|---|------|----------|
| P1 | Skill `allowed-tools` parsed, never enforced | `skills.dart:415-426` |
| P2 | Skill `supportingFiles` discovered but never exposed to model/loader | `skills.dart:464-466,752-798`; `agent_service.dart:14385,14516` |
| P3 | Skill `model`, `argumentHint`, `catalogLine` parsed/unused | `skills.dart:30-31,76-78,427-430` |
| P4 | Plugin agent `model`/`tools` frontmatter ignored by dispatch | `plugin_manifest.dart:211-249`; `agent_service.dart:14861-14899` |
| P5 | Workspace agents discovered but not dispatchable (`agentsForSession` dead) | `skills.dart:155,174-175` |
| P6 | Slash commands: no `$ARGUMENTS`/`$1` substitution, no namespace dirs | `chat_screen.dart:1613-1615`; `plugin_adapters.dart:67-70` |
| P7 | `prompt`-type hooks skipped | `hook_service.dart:478-491` |
| P8 | CC blocking limited to `pre_tool`/`permission_request` | `plugin_manifest.dart:276` |
| P9 | `.claude-plugin/marketplace.json` metadata unread (adapter marker only) | `plugin_adapters.dart:712-714` |
| P10 | Streamable HTTP incomplete: no GET SSE, no `MCP-Protocol-Version`, no pagination, no `notifications/cancelled`, no `DELETE` session end | `mcp_service.dart:730-738,878-886,1254-1259,1354-1355,1371-1380` |
| P11 | Initialize result (negotiated version/capabilities) ignored | `mcp_service.dart:701-705,851-855` |
| P12 | Two divergent plugin-MCP install paths (normalized vs legacy bare-name) | `state.dart:5627-5713` vs `5740-5817`; `agent_service.dart:9919` |
| P13 | Ownerless connected server loses its tool schema when a same-named plugin server is active | `agent_service.dart:3569-3583` |
| P14 | Fuzzy `mcp_<name>` resolution can bind the wrong server | `agent_service.dart:5932-5939` |
| P15 | UI format badge derives from catalog, so Codex shows `[CC]` | `plugins_screen.dart:1075-1080` |
| P16 | Shared memory graph across all memory MCP servers | `mcp_service.dart:555-567` |
| P17 | No filesystem watcher: editing SKILL.md/hooks.json needs a manual refresh | grep: no `FileSystemWatcher` |
| P18 | Flat `.md` at any scanned root becomes a skill (over-ingestion) | `skills.dart:349-361` |
| P19 | Hand-rolled frontmatter: no block scalars, no lists, no nested maps | `skills.dart:389-434` |
| P20 | Capability vocabulary only partially inferred (`workspaceWrite`, `sessionRead/Write`, `deviceControl` never inferred/enforced) | `plugin_adapters.dart:434-451` |

---

## 4. Public-repo security (repo is now PUBLIC — act first)

| # | Finding | Severity |
|---|---------|----------|
| S1 | Third-party GitHub App `usehoplite` has `workflows: write` + `contents: write` and has committed to this repo; a `hoplite/**` push runs the branch's own workflow with signing + Firebase secrets, so that app can exfiltrate the release signing key | CRITICAL |
| S2 | No branch protection / rulesets on any branch; force-push and deletion allowed | CRITICAL |
| S3 | Release signing key + Firebase config live as repo secrets while the repo is public (masked in logs, but readable by any write-capable workflow) | HIGH |
| S4 | `docs/ovidai_roadmap.html` + PDF marked CONFIDENTIAL (pricing, margins, growth targets) are public | HIGH |
| S5 | Competitor design-token extraction reference doc is public | HIGH |
| S6 | `docs/HARDENING_TRACKER.md` + `SecurityCheck.kt` disclose the exact anti-tamper defenses | HIGH |
| S7 | Actions pinned to mutable tags; `allowed_actions: all`; no SHA pinning | MEDIUM |
| S8 | Public debug APK (un-obfuscated) + artifacts embed Firebase config; `device-test.yml` uploads logcat/screenshot | MEDIUM |
| S9 | No LICENSE / SECURITY.md / CODEOWNERS; bundled fonts lack OFL text | MEDIUM |
| S10 | `tool/prepare_bootstrap.sh` downloads the Termux payload with no checksum verification | MEDIUM |

---

## 5. Root cause: three parallel plugin systems

The single biggest architectural drag. A "plugin" can be:

1. **Legacy catalog rows** — `PluginItem` with `hooks: Map<String,String>`, executed via `legacy:` ids (`state.dart:313-515`).
2. **Normalized runtime** — `NormalizedPluginManifest` + registry + atomic install (the good path).
3. **Native in-process capabilities** — hardcoded Dart, not folder-discovered (`native_plugin.dart:144-168`).

`HookService._resolveHooks` stitches (1)+(2); `AgentService._tools` stitches all three.
Consequence: every feature must be implemented up to three times, and parity bugs
hide in the seams (B10, P12, P13).

**Direction:** make the normalized manifest the single source of truth. Keep legacy
rows as a read-only import that produces normalized manifests; make native
capabilities register through the same registry. One lifecycle, one grant model.

---

## 6. Implementation phases

Ordered so each phase is independently shippable and verifiable. TDD for every item.

### Phase A — Public-repo security (do before anything else)
1. Restrict/remove `usehoplite` app permissions (drop `workflows`, `administration`, `actions`); audit its 11 commits.
2. Add branch protection/rulesets on `main`, `ci/**`, `hoplite/**`: require PR review + status checks, block force-push/deletion.
3. Gate release signing behind a protected Environment with required reviewers; stop running secret-bearing jobs from wildcard branches.
4. Pin all actions to commit SHAs; set `allowed_actions` to a selected list.
5. Remove confidential docs (roadmap HTML/PDF, master roadmap, DSH reference, hardening tracker details) from HEAD and history; rotate the signing key + Firebase config.
6. Add LICENSE, font OFL text, SECURITY.md, CODEOWNERS.

### Phase B — Unblock real Codex/CC parity
7. B1/B2 — accept `.agents/skills` and `.agents/personas` at mount (behavior test: publish → dispatch).
8. B3 — derive Codex identity from the source id.
9. B5/B7 — add `.codex/` and `.claude/` workspace roots for skills/commands/agents.
10. B8/B11 — settings layer + settings-level MCP with enable/disable lists.
11. B9 — treat `*`/empty matcher as match-all.
12. B10 — route legacy hook imports through `canonicalHookEvent`.
13. B4/B6 — implement Codex hooks + `AGENTS.md` injection, or remove the claims.

### Phase C — MCP runtime completeness
14. B12 — `${VAR}` / `${VAR:-default}` interpolation.
15. H1 — decouple the test seam from the production cap; make `toolTimeoutS` actually raise the ceiling.
16. B13 — legacy SSE transport (or visible migration path).
17. P10/P11 — protocol-version header, parse initialize result, pagination, `notifications/cancelled`, `DELETE` session end, GET SSE stream.
18. P12/P13/P14 — one install path; canonical tool name for ownerless servers; exact (non-fuzzy) resolution.
19. H10 — cancel subscriptions, bound stderr, kill process groups, close per-call clients.
20. H8/H9 — URL policy (scheme allowlist, block loopback/private/link-local, size cap) for fetch/HTTP; enforce `checkPolicy` in `spawn` + cwd containment.

### Phase D — Hooks/skills correctness
21. H2 — matcher matching without unbounded regex (literal/regex with a step budget).
22. H3 — redact secrets from hook payloads; document the risk in the approval sheet.
23. H4 — require explicit `type`, or infer `prompt` when only `prompt` is present.
24. H5 — dedupe canonical ids instead of throwing.
25. H6/H7 — serialize grant + activation stores (reuse the `_writeChain` pattern).
26. P1 — enforce skill `allowed-tools` at dispatch.
27. P2 — expose `supportingFiles` to the skill loader.

### Phase E — Architecture consolidation
28. Single manifest source of truth; legacy rows become an importer; native capabilities register through the registry.
29. P17 — filesystem watcher for workspace skill/hook/AGENTS edits.
30. P15/P18/P19/P20 — format badge from `manifest.format`, root `.md` allowlist, real frontmatter parser, complete capability inference.

---

## 7. Verification gates

- `dart analyze lib test` → 0 issues.
- `flutter test` → all green, including new behavior tests:
  - Codex skill/persona mount + dispatch.
  - CC `hooks.json` → `fireGate` end-to-end, including `matcher: "*"`.
  - MCP timeout honors a > 60 s setting.
  - `${VAR}` interpolation in args/env/url/headers.
  - Duplicate canonical id does not crash publish.
  - Concurrent grant/activation writes do not lose updates.
- `./gradlew :app:compileDebugKotlin` → BUILD SUCCESSFUL.
- CI run → success.
- Public-release checklist (§4) fully checked.

---

## 8. Explicit non-goals

- Not rewriting the normalized runtime — it is sound.
- Not adding new user-facing plugin features before parity is correct.
- Not silently dropping features: every "unsupported" claim in README must either
  become supported or be removed from the docs.

---

## Execution status (2026-09-19)

Shipped in commits `5598f9e`, `da3d7ba`, `619abc9` (branch
`hoplite/gortyn-77773150`). Full suite **1980 green**, analyze clean,
Kotlin compiles, CI run `35449961081` fully green (debug APK + signed
release APK + AAB + artifact uploads).

### Done
- **Public-repo security:** repo made public per request; branch protection
  on `main` (1 review + `build` status check, no force-push/delete); CI actions
  pinned to SHAs; actions restricted to GitHub-owned + verified + two
  allowlisted patterns; LICENSE, SECURITY.md, CODEOWNERS, THIRD_PARTY_NOTICES;
  confidential roadmap/PDF and competitor-reference docs removed from HEAD.
- **[CC] runtime parity (the reported bug):** a real `obra/superpowers`-shaped
  plugin now works end to end — SessionStart context is captured and injected
  as a standing system message; matchers are event-aware (SessionStart matches
  the session source, `*` matches all); `CLAUDE_PLUGIN_ROOT` is exported;
  hook/script executables keep `+x` after extraction.
- **Codex:** identity derived from source id when absent; hooks parsed
  (inline TOML + `hooks/hooks.json`); `.agents/skills`, `.agents/personas`,
  `.claude/skills|commands|agents`, `.codex/skills` all mount; root-only TOML
  scalars stop nested-key identity spoofing.
- **Hooks:** prompt hooks are never coerced to shell; canonical-id duplicates
  dedupe instead of crashing publish; oversized/nested-quantifier matchers
  refused (ReDoS); payloads redact secret-named keys.
- **MCP:** `${VAR}` / `${VAR:-default}` interpolation in args/env/url/headers/
  cwd; per-server timeout no longer capped at 60 s; settings-level `mcpServers`
  with enable/disable lists; SSE rejected honestly at add.
- **Security:** Native Fetch URL policy + streamed read cap + reused client;
  `SandboxService.spawn` enforces the sandbox policy; legacy CC hook names
  preserved; serialized grant/activation stores (lost-update races fixed);
  install durability failure surfaced.

### Deferred (needs a human decision)
- **History purge + key rotation:** the confidential docs were removed from
  HEAD but remain in git history. Purging requires `git filter-repo` +
  force-push, and the Android release signing key + Firebase config should be
  treated as exposed and rotated. This is destructive/irreversible, so it is
  left to the owner.
- **`usehoplite` app permissions:** the third-party GitHub App still has
  `workflows`/`contents`/`administration`/`actions` write. Revoking or
  downscoping it is an owner action on the GitHub App installation.
- **Remaining plan items:** Phase C streamable-HTTP completeness (GET SSE,
  pagination, `notifications/cancelled`, `DELETE` session end), Phase D skill
  `allowed-tools` enforcement + supporting-file exposure, Phase E architecture
  consolidation, and the P1/P2 partial-parity list.

---

## Execution status — round 2 (2026-09-19)

Commits `84993ae`, `34c20ca`, `0c76468`. Full suite **2031 green** (verified
three consecutive runs), analyze clean, CI `35459645737` fully green
(debug APK + signed release APK + AAB + artifact uploads).

### Done
- **MCP Streamable HTTP completeness:** `MCP-Protocol-Version` on every
  post-initialize request (negotiated value), initialize result parsed
  (version + capabilities), `tools/list` pagination with a bounded cursor
  loop, `notifications/cancelled` on timeout, `DELETE` session on disconnect,
  and `structuredContent` / `audio` / `resource.blob` tool results.
- **Skill tool-scoping:** a loaded skill's `allowed-tools` scopes the run;
  out-of-scope tools are refused with an instructive message and the `skill`
  tool stays open so the model can switch. Applied to both the `skill` tool
  and plugin-contribution paths.
- **Skill supporting files:** bundled files are surfaced with the skill
  content (small text inlined, larger listed with a readable path).
- **Skill parsing:** YAML block scalars (`>`/`|`) and block-list
  `allowed-tools`; root `.md` allowlist so `AGENTS.md`/`README.md` are not
  ingested as skills; `Skill.sourcePath` distinguishes the markdown file from
  its bundle directory.
- **Skill hot reload:** an edited/added/removed workspace `SKILL.md` is picked
  up on the next load via a catalog fingerprint (root + source-file mtimes).
- **Slash-command arguments:** `$ARGUMENTS`, `$@`, `$1..$N` substitution with
  `\$` escaping; the legacy trailer is kept only when the body has no
  placeholders (no regression for existing commands).
- **MCP memory isolation:** per-server stores (`mcp-memory/<id>.json`) with a
  one-time copy of the legacy shared graph.
- **Capability inference:** single source of truth (adapter delegates to the
  public inference point); `workspaceWrite`/`sessionRead`/`sessionWrite`/
  `deviceControl` are explicit-only and never guessed, so existing grants and
  manifest digests stay valid.
- **Plugin format badge:** derived from the runtime manifest, so a Codex
  plugin no longer renders as `[CC]`.
- **Hook approval sheet:** discloses that payload secrets are redacted before
  a hook runs.
- **Test reliability:** fixed the intermittent `studio_git_reliability` test
  (package:test's 30s default per-test timeout fired under full-suite load,
  then teardown deleted the temp dir mid-run); it now has an explicit
  per-test timeout.

### Deliberately deferred (with reasons)
- **Architecture consolidation (Phase E #28):** collapsing the three parallel
  plugin systems into one manifest source of truth is a large, high-risk
  refactor. The parity fixes above remove the user-visible consequences of the
  split; the refactor should be done incrementally behind the existing 2031
  tests, not as a big-bang change.
- **Prompt-type hook execution (P7):** real [CC] prompt hooks invoke the model.
  This is a new capability with cost/latency implications and needs its own
  design.
- **Expanded hook blocking (P8):** blocking is limited to `pre_tool` and
  `permission_request`. Widening it changes what can stop a run and needs a
  product decision.
- **`.claude-plugin/marketplace.json` metadata (P5):** metadata-only; the
  adapter already selects and parses the plugin correctly.
- **Plugin agent `model`/`tools` frontmatter + dispatchable workspace agents
  (P4/P5):** needs a subagent-dispatch design pass.
- **History purge + key rotation + `usehoplite` downscoping:** owner actions
  (see the public-repo checklist).

---

## Blocker report triage (2026-09-19, verified against real code)

A report claimed 6 blockers after installing `obra/superpowers`. Verified
each against the current tree (commit `9680c1f`) by reproducing failures and
running the real pipeline:

| # | Claim | Verdict | Evidence |
|---|-------|---------|----------|
| 1 | No session-start hook → plugin inert | **STALE — already fixed** | `hook_service.dart` `sessionContextFor`/`extractHookContext` + `CLAUDE_PLUGIN_ROOT`; injected in `agent_service.dart:7436`. Implemented in `da3d7ba`. |
| 2 | No skill registry → `skill()` not found | **STALE — already fixed** | `_scanPluginMount` + `PluginCatalogMount` mounts plugin skills per session (`da3d7ba`). |
| 3 | `marketplace.json` casts object fields to String | **REAL — fixed** | Reproduced `_Map<String, dynamic>` → `String?` at `state.dart`; now tolerant via `_marketplaceString`. |
| 4 | Plugin action dispatch is a stub (silent success) | **REAL — fixed** | Reproduced: unknown action returned "executed successfully". Now honest + lists real actions. |
| 5 | No real install mechanism from a repo | **REAL — fixed** | Added `agent_install_plugin(repo:)` + `catalog_add_plugin(source:)`; `catalog_add_plugin` previously only made a row. |
| 6 | Sandbox dependency / ARM64 native modules | **PARTIAL** | Sandbox gating is real; native `.node` on bionic ARM64 is a genuine limitation (needs an honest message). |

Root cause of the "inert plugin" experience: the agent reached for
`catalog_add_plugin`, which only created a catalog row and never installed —
so no skills mounted and no hooks registered. The install path is now wired.

**End-to-end proof:** `test/plugin_e2e_install_test.dart` inspects the real
plugin, grants, installs, mounts 15 skills for a session, and fires the
SessionStart hook to produce injectable context with `CLAUDE_PLUGIN_ROOT`
resolved. `test/marketplace_import_test.dart`,
`test/plugin_action_dispatch_test.dart`,
`test/plugin_direct_repo_install_test.dart` cover the fixes.

Still open from the report: the ARM64 native-module message (item 6) and the
porting-guide `references/ovid-tools.md` tool-mapping deliverable.
