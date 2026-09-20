#!/usr/bin/env python3
"""
normalize_cc_plugins.py — make Claude Code / Codex plugins actually run on Ovid.

WHY THIS EXISTS
---------------
Ovid parses the [CC] plugin format correctly, but it does not expand the path
variables that the [CC] plugin spec defines.  The canonical hook in
`obra/superpowers` is:

    "command": "\\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\\" session-start"

Ovid stores that string verbatim as the hook `payload` and then runs it with
`bash -c`, with no `CLAUDE_PLUGIN_ROOT` in the environment.  Bash expands the
unset variable to the empty string, so the command becomes:

    "/hooks/run-hook.cmd" session-start

which fails:

    bash: line 1: /hooks/run-hook.cmd: No such file or directory
    exit 127

Ovid treats hooks as fail-open, so the failure is silent — the plugin "loads",
its skills are listed, and nothing ever actually runs.  The same unexpanded
token breaks plugin-bundled MCP servers (`.mcp.json`) and commands/agents.

WHAT THIS DOES
--------------
Resolves the [CC] path variables to absolute paths, in place, for every
installed plugin:

    ${CLAUDE_PLUGIN_ROOT}  -> the plugin's content dir
    ${CLAUDE_PLUGIN_DATA}  -> the plugin's persistent data dir (if resolvable)
    ${CLAUDE_PROJECT_DIR}  -> --project-dir, if given

Rewritten surfaces:
    ovid-plugin.json      (the hook payload Ovid actually executes)
    ovid-activation.json  (the same manifest, activation copy)
    hooks/*.json          (raw [CC] hook definitions)
    .mcp.json             (plugin-bundled MCP servers)
    commands/**           (slash commands)
    agents/**             (subagent definitions)

Also ensures hook scripts are executable, because Ovid runs them directly.

Safety:
  * binary files are never touched (detected by NUL bytes)
  * idempotent — a second run rewrites nothing
  * only files containing the token are considered

The durable fix is for Ovid to expand these variables at hook-exec time; this
script is the on-device remedy that works today, for every plugin, with no app
rebuild.

Usage:
    python3 normalize_cc_plugins.py --auto
    python3 normalize_cc_plugins.py --plugin-root <content-dir> [...]
"""

import argparse
import json
import os
import re
import stat
import sys

# [CC] path variables, in the order they must be substituted
TOKEN_ROOT = "${CLAUDE_PLUGIN_ROOT}"
TOKEN_DATA = "${CLAUDE_PLUGIN_DATA}"
TOKEN_PROJ = "${CLAUDE_PROJECT_DIR}"

# files/dirs under a plugin content root that may embed a token
TEXT_GLOBS = (
    "ovid-plugin.json",
    "ovid-activation.json",
    ".mcp.json",
    "mcp.json",
    "plugin.json",
)
TEXT_DIRS = ("hooks", "commands", "agents", "skills")

SKIP_DIRS = {".git", "node_modules", ".dart_tool", "build", ".spill"}


# ---------------------------------------------------------------------------
# io helpers
# ---------------------------------------------------------------------------

def read_text(path):
    """Return the file's text, or None if it is binary / unreadable."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError:
        return None
    if b"\x00" in raw[:8192]:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def write_text(path, text):
    try:
        mode = os.stat(path).st_mode
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(path, mode)
        return True
    except OSError as exc:
        print(f"  ! cannot write {path}: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# plugin discovery
# ---------------------------------------------------------------------------

def find_plugin_roots(app_flutter):
    """Yield every `<owner>/<name>/<version>/content` dir under plugin-runtime."""
    runtime = os.path.join(app_flutter, "plugin-runtime")
    if not os.path.isdir(runtime):
        return []
    out = []
    for owner in sorted(os.listdir(runtime)):
        op = os.path.join(runtime, owner)
        if not os.path.isdir(op):
            continue
        for name in sorted(os.listdir(op)):
            np = os.path.join(op, name)
            if not os.path.isdir(np):
                continue
            for ver in sorted(os.listdir(np)):
                cp = os.path.join(np, ver, "content")
                if os.path.isdir(cp):
                    out.append(cp)
    return out


def plugin_id_for(root):
    """Recover `<owner>/<name>` from a .../plugin-runtime/<owner>/<name>/<v>/content path."""
    parts = root.rstrip("/").split(os.sep)
    if len(parts) >= 3 and parts[-2] != "content":
        return None
    try:
        i = parts.index("plugin-runtime")
    except ValueError:
        return None
    if len(parts) < i + 4:
        return None
    return f"{parts[i + 1]}/{parts[i + 2]}"


def storage_root_for(root, app_flutter=None):
    """Return the plugin-storage dir that pairs with a plugin-runtime root."""
    if app_flutter:
        return os.path.join(app_flutter, "plugin-storage")
    parts = root.rstrip("/").split(os.sep)
    try:
        i = parts.index("plugin-runtime")
    except ValueError:
        return None
    return os.sep.join(parts[:i] + ["plugin-storage"])


def data_dir_for(root, app_flutter=None):
    """Resolve ${CLAUDE_PLUGIN_DATA} for this plugin, creating it if possible."""
    pid = plugin_id_for(root)
    sroot = storage_root_for(root, app_flutter)
    if not pid or not sroot:
        return None
    owner, name = pid.split("/", 1)
    d = os.path.join(sroot, f"{owner}_{name}")
    try:
        os.makedirs(d, exist_ok=True)
        return d
    except OSError:
        return None


# ---------------------------------------------------------------------------
# normalization
# ---------------------------------------------------------------------------

def candidate_files(root):
    """Every text file under the plugin that could embed a [CC] token."""
    seen = set()

    for name in TEXT_GLOBS:
        p = os.path.join(root, name)
        if os.path.isfile(p):
            seen.add(p)

    for d in TEXT_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, files in os.walk(base):
            dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
            for f in files:
                seen.add(os.path.join(dirpath, f))

    return sorted(seen)


def normalize_file(path, root, data_dir, project_dir):
    """Rewrite tokens in one file. Returns True if it changed."""
    text = read_text(path)
    if text is None or TOKEN_ROOT not in text and TOKEN_DATA not in text \
            and TOKEN_PROJ not in text:
        return False

    new = text.replace(TOKEN_ROOT, root)
    if data_dir:
        new = new.replace(TOKEN_DATA, data_dir)
    if project_dir:
        new = new.replace(TOKEN_PROJ, project_dir)

    if new == text:
        return False
    return write_text(path, new)


def ensure_executable_hooks(root):
    """Ovid runs hook scripts directly — make sure they can be executed."""
    fixed = []
    base = os.path.join(root, "hooks")
    if not os.path.isdir(base):
        return fixed
    for dirpath, dirnames, files in os.walk(base):
        dirnames[:] = [x for x in dirnames if x not in SKIP_DIRS]
        for f in files:
            p = os.path.join(dirpath, f)
            if read_text(p) is None:      # binary
                continue
            mode = os.stat(p).st_mode
            want = mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            if want != mode:
                try:
                    os.chmod(p, want)
                    fixed.append(os.path.relpath(p, root))
                except OSError:
                    pass
    return fixed


def normalize_plugin(root, app_flutter=None, project_dir=None, verbose=True):
    if not os.path.isdir(root):
        print(f"no plugin content dir at {root}", file=sys.stderr)
        return None

    data_dir = data_dir_for(root, app_flutter)

    changed = []
    for p in candidate_files(root):
        if normalize_file(p, root, data_dir, project_dir):
            changed.append(os.path.relpath(p, root))

    execs = ensure_executable_hooks(root)

    # any token still present?
    left = []
    for p in candidate_files(root):
        t = read_text(p)
        if t and (TOKEN_ROOT in t or TOKEN_DATA in t or TOKEN_PROJ in t):
            left.append(os.path.relpath(p, root))

    if verbose:
        print(f"plugin: {root}")
        print(f"  files rewritten: {len(changed)}")
        for c in changed:
            print(f"    - {c}")
        if execs:
            print(f"  made executable: {len(execs)} ({', '.join(execs[:4])})")
        if data_dir:
            print(f"  data dir: {data_dir}")
        if left:
            print(f"  unresolved tokens remain in: {left[:4]}")

    return {"changed": changed, "execs": execs, "left": left}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plugin-root", action="append", default=[],
                    help="plugin content dir (repeatable)")
    ap.add_argument("--auto", action="store_true",
                    help="discover all plugins under app_flutter/plugin-runtime")
    ap.add_argument("--app-flutter",
                    default="/data/data/com.dhanuk.ovidai/app_flutter",
                    help="app_flutter dir (for --auto and data-dir resolution)")
    ap.add_argument("--project-dir", default=None,
                    help="value for ${CLAUDE_PROJECT_DIR}")
    args = ap.parse_args()

    roots = list(args.plugin_root)
    if args.auto:
        roots += find_plugin_roots(args.app_flutter)

    if not roots:
        print("no plugins to normalize (pass --plugin-root or --auto)",
              file=sys.stderr)
        return 1

    bad = 0
    total_changed = 0
    total_left = 0
    for root in roots:
        res = normalize_plugin(root, app_flutter=args.app_flutter,
                               project_dir=args.project_dir)
        if res is None:
            bad += 1
            continue
        total_changed += len(res["changed"])
        total_left += len(res["left"])
        print()

    if total_left:
        print(f"RESULT: {total_changed} file(s) rewritten, "
              f"{total_left} file(s) still hold unresolved tokens")
    else:
        print(f"RESULT: all plugins normalized ({total_changed} file(s) rewritten)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
