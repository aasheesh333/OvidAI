# Ovid sandbox prefix — plugin & MCP failure: root cause and fix

## Symptom

Plugins and MCP servers never work in the Ovid app. Every stdio MCP server in the
catalog is launched as:

```
npx -y @modelcontextprotocol/server-<name>
```

…and every one of them fails to connect. The user-visible result is that
installing a plugin or connecting an MCP server appears to do nothing.

## Root cause

Ovid's **native sandbox** (the bionic / Termux-style prefix at
`/data/data/com.dhanuk.ovidai/files/sandbox`) was populated from **Termux
packages**. Those packages bake the *Termux* app id into their files:

```
#!/data/data/com.termux/files/usr/bin/env node
```

Android gives every app a private SELinux label, so
`/data/data/com.termux/...` is **unreadable** from Ovid. The kernel cannot
resolve those interpreters, so every affected script dies with:

```
bad interpreter: Permission denied
```

`node` itself is a real ELF binary and runs fine — but the **script** entry
points that wrap it are all dead:

| entry point | state before fix |
| --- | --- |
| `bin/npm` | dead (bad interpreter) |
| `bin/npx` | dead (bad interpreter) |
| `bin/pip`, `bin/pip3` | dead (bad interpreter) |
| 18 `libexec/git-core/*` helpers | dead (bad interpreter) |
| `etc/ssh/ssh_config`, `sshd_config` | unparsable |

Because **every stdio MCP server is launched through `npx`**, a single broken
shebang takes down the entire MCP subsystem — which is exactly the reported
symptom.

### Second defect — `bin/npm` was a copy, not a symlink

`npm-cli.js` does `require('../lib/cli.js')`. That relative require only resolves
when the file is reached **through** the symlink
`bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js`. On this device `bin/npm` had
been *copied* into `bin/`, so even after the shebang was fixed npm died with:

```
Error: Cannot find module '../lib/cli.js'
```

`bin/npx` was still a correct symlink — which is why the bug was easy to miss.

### Third defect — symlinks hide the real target

`bin/npm` and `bin/npx` are symlinks into `lib/node_modules/npm/bin/`. Patching
the path `bin/npm` does nothing, because the kernel reads the **target** file's
shebang. The real targets must be patched.

## Fix

`tools/fix_sandbox_prefix.py` repairs all three defects, idempotently, and never
touches binary files (binaries legitimately contain the Termux string internally;
rewriting them would corrupt them).

It is safe to run on every app start.

```bash
# repair the real on-device prefix
python3 tools/fix_sandbox_prefix.py

# repair any prefix (used by the tests)
OVID_PREFIX=/tmp/fake python3 tools/fix_sandbox_prefix.py
```

### Wiring into the app

Call the repair immediately after the sandbox finishes installing, and on every
app start (it is idempotent and cheap — it only reads and rewrites scripts that
still contain the Termux prefix). The natural home is
`lib/core/sandbox_service.dart`, next to the existing `selfHeal` hook that
already writes the `startup_last_failure_sandbox.selfHeal` preference.

## Verification

`tools/test_fix_sandbox_prefix.py` — **20/20 green**:

```bash
python3 tools/test_fix_sandbox_prefix.py
```

Each test builds a throwaway fake prefix reproducing the on-device corruption
and asserts the repair, including:

* Termux shebang rewritten in `bin/`
* the **real target behind a symlink** rewritten
* a copied `bin/npm` converted back into a symlink
* `libexec/git-core` scripts and `etc/` configs rewritten
* **ELF binaries byte-identical** (never rewritten)
* idempotency — a second run changes nothing
* executable bit preserved
* a missing prefix exits non-zero with a clear message

### On-device evidence

After the repair, on the real device:

```
npm      ok: 11.19.1
npx      ok: 11.19.1
pip      ok: pip 26.2.1 from /data/user/0/com.dhanuk.ovidai/files/sandbox/lib
python3  ok: Python 3.14.6
git      ok: git version 2.55.0
RESULT: prefix healthy
```

A real MCP JSON-RPC handshake (`initialize` → `notifications/initialized` →
`tools/list`) driven exactly as `mcp_service.dart` does it — `npx -y <pkg>` over
stdio (`tools/mcp_probe.py`):

```
### filesystem server ###
OK: initialize -> secure-filesystem-server 0.2.0
OK: tools/list -> 14 tools: ['read_file', 'read_text_file', 'read_media_file', ...]

### memory server ###
OK: initialize -> memory-server 0.6.3
OK: tools/list -> 9 tools: ['create_entities', 'create_relations', ...]
```

The **Superpowers** plugin (`obra/superpowers`) runs its real SessionStart hook
and injects its skill content:

```
$ bash "$CLAUDE_PLUGIN_ROOT/hooks/run-hook.cmd" session-start
{"hookSpecificOutput":{"hookEventName":"SessionStart",
 "additionalContext":"<EXTREMELY_IMPORTANT>\nYou have superpowers. ..."}}
```

`git clone` over HTTPS also works, and the `templates not found` warning is gone.

## Remaining known limitation

`@modelcontextprotocol/server-puppeteer` now *installs* successfully (npm works),
but still fails to connect because it needs a Chromium binary that is not present
in the sandbox. That is a genuine missing dependency, not a shebang defect.

## [CC] / Codex parity — verified status

Ovid parses the [CC] plugin format correctly. `ovid-plugin.json` generated
from `obra/superpowers`:

```
format: claudeCode
skills: list[15]      agents: list[0]       commands: list[0]
hooks: list[1]        mcpServers: list[0]   dependencies: dict(['packages'])
requestedCapabilities: [workspaceRead, hooksObserve, shellExecute]
```

The captured hook is faithful — payload, matcher and shell are all preserved:

```
event: session_start   type: command
payload: "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start
matcher: startup|clear|compact
unknownFields: {shell: bash, async: false}
```

Unknown fields are *retained* rather than dropped, and `mcpServers` is a
first-class field on the model — so plugin-bundled MCP servers are supported.

### End-to-end proof through Ovid's OWN MCP service

The strongest evidence: an MCP server was added to Ovid's catalog and then
driven through **Ovid's own MCP integration** — not the raw transport.

Ovid connected, enumerated all 14 tools, and executed a full write→read
roundtrip:

```
catalog_add_mcp("Ovid Filesystem Test", command: npx,
                args: [-y, @modelcontextprotocol/server-filesystem, <ws>])
  -> MCP server added (transport: stdio)

mcp__ovid_filesystem_test__list_allowed_directories()
  -> Allowed directories: /data/data/com.dhanuk.ovidai/files/workspaces/ws_...

mcp__ovid_filesystem_test__write_file(mcp_roundtrip.txt)
  -> Successfully wrote to .../mcp_roundtrip.txt

mcp__ovid_filesystem_test__read_text_file(mcp_roundtrip.txt)
  -> Ovid MCP roundtrip OK — written through Ovid's MCP service ...
```

Ovid's MCP subsystem is therefore **working end to end** after the prefix repair.



| server | launch | result |
| --- | --- | --- |
| `server-filesystem` | `npx -y` | OK — `secure-filesystem-server 0.2.0`, 14 tools |
| `server-memory` | `npx -y` | OK — `memory-server 0.6.3`, 9 tools |
| `server-postgres` | `npx -y` | OK — `example-servers/postgres 0.1.0`, 1 tool |
| `server-puppeteer` | `npx -y` | installs; needs a Chromium binary |
| `@playwright/mcp` | `npx -y` | `Error: Unsupported platform: android` (upstream) |

The **plumbing is sound**; the only failures are servers that require a bundled
desktop browser, which cannot exist on Android.

### Startup latency — the one real remaining risk

A **warm** `npx` cache starts a server in **16s**. A **cold** start must download
the package first (18s for a small one; hundreds of seconds for puppeteer-sized
packages). Ovid's connect timeout is ~120s, so a cold, large MCP server can still
time out on first connect even though nothing is broken.

Recommended follow-ups:

1. Prewarm the `npx` cache when a server is added (run `npx -y <pkg> --version`
   in the background), so the first real connect is warm.
2. Raise the connect timeout for stdio servers, or surface a "downloading…"
   progress state instead of a bare timeout.
3. Report an honest, specific error for browser MCPs instead of a generic
   connect failure.

## Note on repo scope

This repository snapshot does **not** contain `lib/core/mcp_service.dart`,
`test/`, or `android/gradlew`. The shebang defect above is independent of those
files and is fixed here. The sandbox/terminal hardening plan that references
`spawnProot`, `checkPolicy`, `execProotChecked` and `ensureUbuntuToolchains`
targets a newer build than this snapshot.
