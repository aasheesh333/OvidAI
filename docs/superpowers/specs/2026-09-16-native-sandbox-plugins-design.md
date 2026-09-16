# Native Sandbox-Backed Plugins (NP3) Spec

**Date:** 2026-09-16
**Author:** opencode
**Status:** Awaiting user review
**Scope:** NP3 only — `Shell History`, `Git Workbench`, `PDF Tools`. (Docker-in-Sandbox, Rust Toolchain, Go Toolchain seeds were removed per user request and are NOT part of this spec. NP4/NP5 are separate specs.)

---

## 1. Executive Summary

Three seeded catalog rows can only work inside the on-device Linux sandbox: `Shell History` (searchable terminal history), `Git Workbench` (clone/branch/commit/push), and `PDF Tools` (merge/split/compress/extract). Today all three install as `unsupported`.

This spec defines their in-process native implementations following the NP1 framework (`NativePluginCapability`, registry, `plugin__<slug>__<tool>` roster, `catalog_configure_plugin`). Sandbox access goes **directly through `SandboxService.I.exec`** behind an injectable `SandboxRunner` typedef (Approach A, approved) — one hop, honest errors, no new privilege (the agent can already exec via `run_shell`), hermetic unit tests via fake runners.

---

## 2. Architecture & Data Flow

```
+------------------------------------------------------------------+
|                        Chat & Agent Loop                         |
|   plugin__shell_history__search / plugin__git_workbench__clone /  |
|   plugin__pdf_tools__merge  (+ catalog_configure_plugin)         |
+-------------------------------+----------------------------------+
                                |
                                v
+-------------------------------+----------------------------------+
|                          AgentService                            |
|  (NP1 wiring, unchanged: roster, plugin__ dispatch, gating)      |
+-------------------------------+----------------------------------+
                                |
                                v
+-------------------------------+----------------------------------+
|                       NativePluginRegistry                       |
|  shell_history / git_workbench / pdf_tools capabilities          |
+-------------------------------+----------------------------------+
                                |
                                v
+-------------------------------+----------------------------------+
|  SandboxRunner typedef:                                        |
|  Future<String> Function(                                         |
|    List<String> args, {String? cwd, Duration? timeout})           |
|  default impl: (args, {cwd, timeout}) =>                          |
|    SandboxService.I.exec(args, cwd: cwd)                          |
|      .timeout(timeout ?? const Duration(seconds: 60))             |
+--------------------------------+---------------------------------+
                                 |
                                 v
                    SandboxService.I.exec → sandbox
```

New file: `lib/core/native_plugins/sandbox_utilities.dart` — `SandboxRunner` typedef, three capability classes, `registerSandboxUtilities()`. One-line wiring into `registerAllNativePlugins()` in `lib/core/state.dart`. No UI changes (registry-driven `nativeCapability` routing already covers install). No new pubspec dependencies. No secrets (no credentials anywhere in NP3).

---

## 3. Cross-Cutting Rules (bind all three plugins)

1. **Presence gate.** Every `callTool` first checks `SandboxService.I.isInstalled` (synchronous, injected as `bool Function()? isSandboxInstalled` for tests, defaulting to the real getter). When false, return exactly: `Sandbox is not installed — open Studio once to install it, then retry.` The exec layer's own `sandbox not installed` throw is the backstop, never the primary message.
2. **Timeouts.** Each network/mutating tool accepts `timeout_seconds` (clamped 5..600, MCP convention). Defaults: reads 60s; `clone`/`push`/`merge`/`compress` 300s.
3. **Output bound.** Results truncate at 6000 chars head+tail with an exact omission notice (MCP trim convention).
4. **Error taxonomy.** `ArgumentError` = bad/missing args; `FormatException` = malformed content (bad ranges); exec failures pass through exec's own `'<output>\n(exit code N)'` text. Never a fake success.
5. **Paths.** All file/dir args are sandbox paths (absolute, or relative to the sandbox home). No new file plumbing; the agent resolves attachments to sandbox paths with existing tools.
6. **Gating.** `plugin__*` mutating/read-only coverage already applies; no per-tool permission model beyond it.

---

## 4. Plugin Specifications

### 4.1 Shell History (`shell_history`, no config)

- `search(query, limit=50)`: `query` required non-empty (`ArgumentError` otherwise). History source priority: `$HISTFILE` when set and non-empty (probed via `echo $HISTFILE`), else `~/.bash_history`. Reads the newest 5000 lines of the resolved file, filters in Dart (case-insensitive substring), returns newest-first up to `limit`. When neither file exists, return: `No shell history file found in the sandbox yet — run some commands in Studio terminal first.`
- `recent(limit=20)`: same sources, last `limit` lines newest-first. Same absent-file message.
- Rationale for read-then-filter (not `grep` in-sandbox): avoids shell-quoting hell for arbitrary queries; 5000-line cap bounds memory.

### 4.2 Git Workbench (`git_workbench`, one non-secret pref)

- Config: `default_path` (non-secret prefs string, default = sandbox home). Every tool takes optional `path`, falling back to `default_path`.
- `status(path?)` → `git -C <path> status --short --branch`.
- `log(path?, limit=20)` → `git -C <path> log --oneline -n <limit>` (`limit` tolerant-parsed, 1..200).
- `branch(path?)` → `git -C <path> branch -a` plus current-branch marker line.
- `clone(url, path?)` → `git clone <url> [<path>]` run in the sandbox home. `url` required non-empty. `path` is the optional destination directory; when omitted, git derives the directory name from the URL. Default 300s timeout.
- `commit(path?, message)` → `git -C <path> add -A` then `git -C <path> commit -m <message>`. `message` required non-empty (`ArgumentError`). Surfaces git's own error when identity is unconfigured.
- `push(path?, remote=origin, branch?)` → `git -C <path> push <remote> <branch?>`. Default 300s timeout. Surfaces auth/network errors verbatim.
- No separate `command -v git` probe: git's own exit-127 stderr is surfaced honestly (fewer round trips, same honesty).
- Exec policy (`checkPolicy` inside `exec`) continues to enforce path safety; nothing new here.

### 4.3 PDF Tools (`pdf_tools`, no config)

- Backend probe per invocation, preference order: `python3 -c "import pypdf"` → `qpdf --version`. Probed via the runner (`command -v python3` / `command -v qpdf` + import check). When neither backend exists, return: `No PDF backend in the sandbox (needs python3+pypdf or qpdf) — install one, then retry.`
- `merge(inputs, output)`: `inputs` = 2+ existing sandbox PDFs (`ArgumentError` otherwise). pypdf: `PdfMerger` script via `python3 -c`; qpdf: `qpdf --empty --pages <inputs...> -- <output>`.
- `split(input, ranges, out_prefix?)`: `ranges` = comma list of `N` or `N-M` 1-based pages (`FormatException` on malformed). One output per range: `<out_prefix>-<i>.pdf` (default prefix = input basename minus extension, e.g. `doc.pdf` → `doc-1.pdf`).
- `compress(input, output)`: pypdf re-write (content-stream compress); qpdf `--linearize`/`--object-streams=generate`. Best-effort size reduction; reports input/output byte sizes honestly (may report "no reduction" rather than claiming compression).
- `extract_text(input, pages?)`: `pages` uses the same `N`/`N-M` comma syntax as `split` (null = all pages). Returns page text + `{pages, chars}` stats. The AGENT summarizes; the tool does not call the model (keeps NP3 dependency-free and model-independent).
- `info(input)`: page count, byte size, producer/title when readable.

---

## 5. Registration & Install

- `registerSandboxUtilities()` registers all three capabilities; called from `registerAllNativePlugins()` in `lib/core/state.dart` (one line).
- Install flows through existing `PluginInstallKind.nativeCapability` (registry-driven); `Git Workbench`'s `default_path` is editable via the existing Configure sheet / `catalog_configure_plugin`.
- `_pluginToolNames` derives from `capability.tools` (NP1 mechanism, no new code).

---

## 6. Verification Plan

- `test/native_plugins_sandbox_test.dart` (TDD): fake `SandboxRunner` keyed on command signature → canned stdout/exit codes.
  - Presence gate: `isSandboxInstalled=false` → exact Studio message for one tool per plugin.
  - Shell History: search filters newest-first with limit; absent-file message; empty query → `ArgumentError`.
  - Git: status/log/branch happy paths; clone/commit/push arg validation; git-missing stderr (exit 127) surfaced verbatim; `default_path` fallback + override.
  - PDF: qpdf-missing + pypdf-present routing; neither-backend message; malformed ranges → `FormatException`; merge arg-count validation; compress size report shape.
  - Timeout default respected (runner captures timeout); output truncation notice.
- Roster test (Task-3 pattern): installed+enabled → `plugin__git_workbench__clone` present; disabled → absent.
- Gates: `dart analyze lib test` 0 issues; full `flutter test` green (only the known pre-existing PR13 failure excepted).
