#!/usr/bin/env python3
"""
test_normalize_cc_plugins.py — real tests for the [CC]/Codex plugin normalizer.

Each test builds a throwaway plugin install that reproduces the exact on-device
shape (hooks/, commands/, agents/, .mcp.json, ovid-plugin.json) and asserts the
normalizer rewrites the unexpanded [CC] path variables.

    python3 tools/test_normalize_cc_plugins.py

Exit code 0 = all green.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
NORM = os.path.join(HERE, "normalize_cc_plugins.py")

PASS, FAIL = [], []


def check(name, cond, detail=""):
    if cond:
        PASS.append(name)
        print(f"  ok   {name}")
    else:
        FAIL.append(name)
        print(f"  FAIL {name} {detail}")


# ---------------------------------------------------------------------------
# fake [CC] plugin install — mirrors the on-device layout
# ---------------------------------------------------------------------------

def build_plugin(root):
    """Create a miniature [CC] plugin with every surface Ovid parses."""
    os.makedirs(os.path.join(root, "hooks"), exist_ok=True)
    os.makedirs(os.path.join(root, "commands"), exist_ok=True)
    os.makedirs(os.path.join(root, "agents"), exist_ok=True)
    os.makedirs(os.path.join(root, "skills", "hello"), exist_ok=True)

    # the hook payload Ovid actually executes (this is the broken one)
    with open(os.path.join(root, "ovid-plugin.json"), "w") as fh:
        json.dump({
            "id": "acme/cc-full",
            "format": "claudeCode",
            "hooks": [{
                "pluginId": "acme/cc-full",
                "event": "session_start",
                "type": "command",
                "payload": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" session-start",
                "matcher": "startup|clear|compact",
            }],
            "mcpServers": [{
                "name": "synthetic-fs",
                "command": "npx",
                "args": ["-y", "@modelcontextprotocol/server-filesystem",
                         "${CLAUDE_PLUGIN_ROOT}/data"],
            }],
        }, fh, indent=2)

    with open(os.path.join(root, "hooks", "hooks.json"), "w") as fh:
        json.dump({"hooks": {"SessionStart": [{"hooks": [{
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run.sh\" session-start",
            "shell": "bash",
        }]}]}}, fh, indent=2)

    with open(os.path.join(root, ".mcp.json"), "w") as fh:
        json.dump({"mcpServers": {"synthetic-fs": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem",
                     "${CLAUDE_PLUGIN_ROOT}/data"],
            "env": {"PLUGIN_DATA": "${CLAUDE_PLUGIN_DATA}"},
        }}}, fh, indent=2)

    with open(os.path.join(root, "commands", "hello.md"), "w") as fh:
        fh.write("Read ${CLAUDE_PLUGIN_ROOT}/commands/hello.md and greet.\n")

    with open(os.path.join(root, "agents", "hello.md"), "w") as fh:
        fh.write("Root: ${CLAUDE_PLUGIN_ROOT}\n")

    with open(os.path.join(root, "skills", "hello", "SKILL.md"), "w") as fh:
        fh.write("---\nname: hello\ndescription: synthetic\n---\n# Hello\n")

    # hook script, deliberately NOT executable
    hook = os.path.join(root, "hooks", "run.sh")
    with open(hook, "w") as fh:
        fh.write("#!/usr/bin/env bash\n"
                 'echo \'{"hookSpecificOutput":{"additionalContext":"ok"}}\'\n')
    os.chmod(hook, 0o600)

    # a binary that embeds the token and must never be rewritten
    with open(os.path.join(root, "blob.bin"), "wb") as fh:
        fh.write(b"\x7fELF" + b"\x00" * 8 + b"${CLAUDE_PLUGIN_ROOT}" + b"\x00" * 8)
    return root


def run_norm(root, *extra):
    return subprocess.run(
        [sys.executable, NORM, "--plugin-root", root, *extra],
        capture_output=True, text=True, timeout=120,
    )


def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def main():
    if not os.path.exists(NORM):
        print(f"FATAL: normalizer not found at {NORM}")
        return 2

    # ---------------------------------------------------------------- hooks
    print("\n[test] rewrites the hook payload Ovid executes")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        r = run_norm(root)
        check("exits 0", r.returncode == 0, r.stderr[-300:])
        ovid = json.load(open(os.path.join(root, "ovid-plugin.json")))
        payload = ovid["hooks"][0]["payload"]
        check("ovid-plugin.json payload expanded",
              "${CLAUDE_PLUGIN_ROOT}" not in payload, payload)
        check("payload points at real hook",
              os.path.join(root, "hooks/run.sh") in payload, payload)
        check("hook script exists at that path",
              os.path.exists(os.path.join(root, "hooks/run.sh")))

        hooks = json.load(open(os.path.join(root, "hooks", "hooks.json")))
        cmd = hooks["hooks"]["SessionStart"][0]["hooks"][0]["command"]
        check("hooks.json command expanded",
              "${CLAUDE_PLUGIN_ROOT}" not in cmd, cmd)

        mcp = json.load(open(os.path.join(root, ".mcp.json")))
        srv = mcp["mcpServers"]["synthetic-fs"]
        check(".mcp.json args expanded",
              "${CLAUDE_PLUGIN_ROOT}" not in json.dumps(srv), srv)
        check(".mcp.json data dir is absolute",
              os.path.join(root, "data") in json.dumps(srv), srv)

        check("commands/*.md expanded",
              "${CLAUDE_PLUGIN_ROOT}" not in read(os.path.join(root, "commands", "hello.md")))
        check("agents/*.md expanded",
              "${CLAUDE_PLUGIN_ROOT}" not in read(os.path.join(root, "agents", "hello.md")))

    # -------------------------------------------------------------- perms
    print("\n[test] makes hook scripts executable")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        hook = os.path.join(root, "hooks", "run.sh")
        before = os.stat(hook).st_mode
        check("precondition: hook not executable", not (before & stat.S_IXUSR))
        run_norm(root)
        after = os.stat(hook).st_mode
        check("hook now executable", bool(after & stat.S_IXUSR))

    # ------------------------------------------------------------- binary
    print("\n[test] never rewrites binary files")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        blob = os.path.join(root, "blob.bin")
        with open(blob, "rb") as fh:
            before = fh.read()
        run_norm(root)
        with open(blob, "rb") as fh:
            after = fh.read()
        check("binary byte-identical", before == after)
        check("binary still holds its token", b"${CLAUDE_PLUGIN_ROOT}" in after)

    # --------------------------------------------------------- idempotent
    print("\n[test] is idempotent")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        run_norm(root)
        snap = {}
        for dirpath, _, files in os.walk(root):
            for f in files:
                p = os.path.join(dirpath, f)
                if os.path.isfile(p):
                    with open(p, "rb") as fh:
                        snap[p] = fh.read()
        r2 = run_norm(root)
        check("second run exits 0", r2.returncode == 0, r2.stderr[-300:])
        changed = []
        for p, before in snap.items():
            with open(p, "rb") as fh:
                if fh.read() != before:
                    changed.append(p)
        check("second run changed nothing", not changed, changed[:3])
        check("second run reports no rewrites",
              "0 file" in r2.stdout or "files rewritten: 0" in r2.stdout,
              r2.stdout[-300:])

    # ----------------------------------------------------------- real exec
    print("\n[test] the normalized hook actually executes")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        run_norm(root)
        ovid = json.load(open(os.path.join(root, "ovid-plugin.json")))
        payload = ovid["hooks"][0]["payload"]
        proc = subprocess.run(["bash", "-c", payload],
                              capture_output=True, text=True,
                              cwd=root, timeout=60)
        check("hook exits 0", proc.returncode == 0,
              f"rc={proc.returncode} err={proc.stderr[-200:]}")
        check("hook emitted hookSpecificOutput",
              "hookSpecificOutput" in proc.stdout, proc.stdout[:200])

    # ------------------------------------------------------------- report
    print("\n[test] reports a clean summary line")
    with tempfile.TemporaryDirectory() as tmp:
        root = build_plugin(os.path.join(tmp, "content"))
        r = run_norm(root)
        check("prints RESULT line", "RESULT:" in r.stdout, r.stdout[-200:])

    # -------------------------------------------------------- missing root
    print("\n[test] missing plugin root exits non-zero with a message")
    r = run_norm("/nonexistent/plugin/root")
    check("non-zero exit", r.returncode != 0, str(r.returncode))
    check("explains the problem", len((r.stderr or r.stdout).strip()) > 0)

    print("\n" + "=" * 66)
    print(f"passed: {len(PASS)}   failed: {len(FAIL)}")
    if FAIL:
        print("FAILURES: " + ", ".join(FAIL))
        return 1
    print("ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
