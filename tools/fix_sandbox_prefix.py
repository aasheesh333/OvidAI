#!/usr/bin/env python3
"""
fix_sandbox_prefix.py — repair the Ovid native sandbox prefix.

WHY THIS EXISTS
---------------
Ovid's native (bionic / Termux-style) sandbox prefix is populated from Termux
packages.  Those packages bake the *Termux* app id into their files:

    #!/data/data/com.termux/files/usr/bin/env node
    Include /data/data/com.termux/files/usr/etc/ssh/ssh_config.d/*.conf

Ovid's prefix is /data/data/com.dhanuk.ovidai/files/sandbox.  Android gives every
app a private SELinux label, so /data/data/com.termux/... is unreadable from
Ovid.  The kernel therefore cannot resolve those interpreters and every affected
script dies with:

    bad interpreter: Permission denied

That single defect is why "no plugin and no MCP works":

  * bin/npm and bin/npx  -> dead
  * every stdio MCP server is launched as `npx -y <package>` -> all dead
  * pip / python entry points -> dead
  * 18 git-core helpers (git-submodule, git-subtree, git-filter-branch,
    git-merge-*, git-send-email ...) -> dead
  * ssh/sshd configs -> unparsable

Three distinct defects are repaired:

  1. Shebangs and embedded paths in executable scripts (bin/, libexec/,
     libexec/git-core/).  Symlinks are followed to their real targets, because
     bin/npm and bin/npx ARE symlinks into lib/node_modules/npm/bin/.
  2. bin/npm and bin/npx must be symlinks, not copies.  npm-cli.js does
     `require('../lib/cli.js')`, which only resolves when reached through
     ../lib/node_modules/npm/bin/.
  3. Text config files under etc/ (recursively: ssh_config, sshd_config, apt
     confs, profile.d) that point at the Termux prefix.

Idempotent: safe to run on every app start.  Binary files are never touched.

USAGE
-----
    python3 fix_sandbox_prefix.py                 # repair the real prefix
    OVID_PREFIX=/tmp/fake python3 fix_sandbox_prefix.py   # repair any prefix
"""

import os
import stat
import subprocess
import sys

DEFAULT_PREFIX = "/data/data/com.dhanuk.ovidai/files/sandbox"
PREFIX = os.environ.get("OVID_PREFIX", DEFAULT_PREFIX)
TERMUX = "/data/data/com.termux/files/usr"

BIN = os.path.join(PREFIX, "bin")
LIBEXEC = os.path.join(PREFIX, "libexec")
ETC = os.path.join(PREFIX, "etc")

# directories whose scripts carry shebangs
SCRIPT_DIRS = [BIN, LIBEXEC, os.path.join(LIBEXEC, "git-core")]

# text configs that may embed the Termux prefix (walked recursively)
CONFIG_DIRS = [ETC]

# entry points that must be symlinks into lib/node_modules/npm/bin/
NPM_LINKS = {
    "npm": "../lib/node_modules/npm/bin/npm-cli.js",
    "npx": "../lib/node_modules/npm/bin/npx-cli.js",
}

# mirror lists are inert data — not worth rewriting
SKIP_DIR_NAMES = {"mirrors"}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _is_script(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(2) == b"#!"
    except OSError:
        return False


def _read_text(path):
    """Read a file only if it is genuinely text (no NUL bytes)."""
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


def _write_text(path, text, keep_mode=True):
    try:
        mode = os.stat(path).st_mode
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        if keep_mode:
            os.chmod(path, mode)
        return True
    except OSError as exc:
        print(f"  ! {path}: {exc}")
        return False


def _script_targets():
    """All real script files reachable from SCRIPT_DIRS (symlinks resolved)."""
    targets = set()
    for d in SCRIPT_DIRS:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if os.path.islink(p):
                real = os.path.realpath(p)
                if os.path.isfile(real) and _is_script(real):
                    targets.add(real)
            elif os.path.isfile(p) and _is_script(p):
                targets.add(p)
    return sorted(targets)


# ---------------------------------------------------------------------------
# defect 1 — shebangs / embedded paths in scripts
# ---------------------------------------------------------------------------

def fix_scripts():
    changed = []
    for p in _script_targets():
        text = _read_text(p)
        if text is None or TERMUX not in text:
            continue
        mode = os.stat(p).st_mode
        if _write_text(p, text.replace(TERMUX, PREFIX)):
            os.chmod(p, mode | stat.S_IXUSR | stat.S_IXGRP)
            changed.append(os.path.relpath(p, PREFIX))
    return changed


# ---------------------------------------------------------------------------
# defect 2 — npm/npx must be symlinks
# ---------------------------------------------------------------------------

def fix_npm_links():
    fixed, ok = [], []
    for name, target in NPM_LINKS.items():
        p = os.path.join(BIN, name)
        real = os.path.join(BIN, os.path.normpath(target))
        if not os.path.exists(real):
            print(f"  ! missing npm payload for {name}: {real}")
            continue
        if os.path.islink(p) and os.readlink(p) == target:
            ok.append(name)
            continue
        try:
            if os.path.islink(p) or os.path.exists(p):
                os.remove(p)
            os.symlink(target, p)
            fixed.append(name)
        except OSError as exc:
            print(f"  ! {name}: {exc}")
    return fixed, ok


# ---------------------------------------------------------------------------
# defect 3 — text configs under etc/
# ---------------------------------------------------------------------------

def fix_configs():
    changed = []
    for root_dir in CONFIG_DIRS:
        if not os.path.isdir(root_dir):
            continue
        for root, dirs, files in os.walk(root_dir):
            dirs[:] = [d for d in dirs if d not in SKIP_DIR_NAMES]
            for name in sorted(files):
                p = os.path.join(root, name)
                if not os.path.isfile(p) or os.path.islink(p):
                    continue
                text = _read_text(p)
                if text is None or TERMUX not in text:
                    continue
                if _write_text(p, text.replace(TERMUX, PREFIX)):
                    changed.append(os.path.relpath(p, PREFIX))
    return changed


# ---------------------------------------------------------------------------
# extra — git's compiled-in template dir still points at Termux
# ---------------------------------------------------------------------------

def fix_git_templates():
    """git warns 'templates not found in /data/data/com.termux/...'.

    The template dir exists under OUR prefix, so pin it in the user gitconfig.
    """
    tmpl = os.path.join(PREFIX, "share", "git-core", "templates")
    if not os.path.isdir(tmpl):
        return False
    home = os.path.join(PREFIX, "home")
    gitconfig = os.path.join(home, ".gitconfig")
    try:
        current = ""
        if os.path.exists(gitconfig):
            current = _read_text(gitconfig) or ""
        if "templateDir" in current:
            return False
        os.makedirs(home, exist_ok=True)
        with open(gitconfig, "a", encoding="utf-8") as fh:
            if current and not current.endswith("\n"):
                fh.write("\n")
            fh.write(f"[init]\n\ttemplateDir = {tmpl}\n")
        return True
    except OSError as exc:
        print(f"  ! gitconfig: {exc}")
        return False


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

def remaining_bad():
    bad = []
    for p in _script_targets():
        text = _read_text(p)
        if text and TERMUX in text.split("\n", 1)[0]:
            bad.append(os.path.relpath(p, PREFIX))
    return bad


def smoke_test():
    """Execute the fixed entry points.

    A 'bad interpreter' result is THE structural defect this script repairs, so
    it is fatal.  Any other failure (stub prefix, Exec format error) is advisory
    — it says nothing about the shebang repair.
    """
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env.get("PATH", "")
    env["PREFIX"] = PREFIX
    env["HOME"] = os.path.join(PREFIX, "home")
    env["GIT_ATTR_NOSYSTEM"] = "1"  # silence git's compiled-in Termux ETC path
    results, fatal = {}, 0
    probes = [
        ("npm", [os.path.join(BIN, "npm"), "--version"]),
        ("npx", [os.path.join(BIN, "npx"), "--version"]),
        ("pip", [os.path.join(BIN, "pip"), "--version"]),
        ("python3", [os.path.join(BIN, "python3"), "--version"]),
        ("git", [os.path.join(BIN, "git"), "--version"]),
    ]
    for name, argv in probes:
        if not os.path.exists(os.path.join(BIN, name)):
            results[name] = "absent"
            continue
        try:
            out = subprocess.run(
                argv, capture_output=True, text=True, timeout=90, env=env
            )
            blob = (out.stdout + out.stderr).strip()
            first = blob.splitlines()[0][:64] if blob else ""
            if out.returncode == 0:
                results[name] = f"ok: {first}"
            elif "bad interpreter" in blob:
                results[name] = f"BROKEN SHEBANG: {first}"
                fatal += 1
            else:
                results[name] = f"warn({out.returncode}): {first}"
        except Exception as exc:  # noqa: BLE001
            results[name] = f"warn: {exc}"
    return results, fatal


def main():
    if not os.path.isdir(BIN):
        print(f"no prefix at {BIN}", file=sys.stderr)
        return 1

    print(f"prefix: {PREFIX}")

    # Re-link FIRST: if bin/npx was missing, fix_npm_links creates the symlink
    # that makes lib/node_modules/npm/bin/npx-cli.js reachable, so fix_scripts
    # must run afterwards or that target is missed on the first pass.
    fixed, ok = fix_npm_links()
    print(f"npm entry points re-linked: {len(fixed)} ({', '.join(fixed) or '-'})")
    if ok:
        print(f"  already correct: {', '.join(ok)}")

    changed = fix_scripts()
    print(f"scripts repaired: {len(changed)}")
    for c in changed:
        print(f"  - {c}")

    cfgs = fix_configs()
    print(f"configs repaired: {len(cfgs)}")
    for c in cfgs:
        print(f"  - {c}")

    if fix_git_templates():
        print("git init.templateDir pinned to the Ovid prefix")

    print("smoke test:")
    results, fatal = smoke_test()
    for name, res in results.items():
        print(f"  {name:<8} {res}")

    bad = fatal
    left = remaining_bad()
    if left:
        print(f"STILL BROKEN ({len(left)}): {left[:8]}")
        bad += 1

    if bad:
        print("RESULT: prefix still has problems")
        return 1
    print("RESULT: prefix healthy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
