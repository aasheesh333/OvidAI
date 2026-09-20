#!/usr/bin/env python3
"""
test_fix_sandbox_prefix.py — real tests for the sandbox prefix repair.

Runs anywhere with python3 (no device, no Flutter needed): each test builds a
throwaway fake prefix in a temp dir that reproduces the exact corruption seen on
device, runs the fixer against it, and asserts the repair.

    python3 tools/test_fix_sandbox_prefix.py

Exit code 0 = all green.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIXER = os.path.join(HERE, "fix_sandbox_prefix.py")

TERMUX = "/data/data/com.termux/files/usr"

PASS, FAIL = [], []


def check(name, cond, detail=""):
    if cond:
        PASS.append(name)
        print(f"  ok   {name}")
    else:
        FAIL.append(name)
        print(f"  FAIL {name} {detail}")


# ---------------------------------------------------------------------------
# fake prefix builder — mirrors the on-device layout
# ---------------------------------------------------------------------------

def build_fake_prefix(root, *, npm_as_copy=False):
    """Create a miniature sandbox prefix reproducing the Termux corruption."""
    bin_dir = os.path.join(root, "bin")
    libexec = os.path.join(root, "libexec")
    gitcore = os.path.join(libexec, "git-core")
    etc_ssh = os.path.join(root, "etc", "ssh")
    npm_bin = os.path.join(root, "lib", "node_modules", "npm", "bin")
    for d in (bin_dir, gitcore, etc_ssh, npm_bin):
        os.makedirs(d, exist_ok=True)

    def write(path, text, exec_bit=True):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        if exec_bit:
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)

    # a plain script with a Termux shebang  (like pip)
    write(os.path.join(bin_dir, "pip"), f"#!{TERMUX}/bin/python3.14\nprint('pip')\n")

    # a real ELF-ish binary that must NEVER be rewritten
    with open(os.path.join(bin_dir, "node"), "wb") as fh:
        fh.write(b"\x7fELF" + b"\x00" * 64 + TERMUX.encode())

    # npm payload (the symlink target) with a Termux shebang
    payload = f"#!{TERMUX}/bin/env node\nrequire('../lib/cli.js')\n"
    write(os.path.join(npm_bin, "npm-cli.js"), payload)
    write(os.path.join(npm_bin, "npx-cli.js"), payload)

    # bin/npm is either a correct symlink or the broken COPY seen on device
    npm_path = os.path.join(bin_dir, "npm")
    if npm_as_copy:
        write(npm_path, payload)
    else:
        os.symlink("../lib/node_modules/npm/bin/npm-cli.js", npm_path)

    # git-core helper with a Termux shebang (like git-submodule)
    write(os.path.join(gitcore, "git-submodule"),
          f"#!{TERMUX}/bin/sh\necho submodule\n")

    # config pointing at Termux (like ssh_config)
    write(os.path.join(etc_ssh, "ssh_config"),
          f"Include {TERMUX}/etc/ssh/ssh_config.d/*.conf\n", exec_bit=False)

    return bin_dir


def run_fixer(root):
    env = dict(os.environ)
    env["OVID_PREFIX"] = root
    return subprocess.run(
        [sys.executable, FIXER], capture_output=True, text=True, env=env, timeout=120
    )


def first_line(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        return fh.readline().rstrip("\n")


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def test_repairs_shebang():
    print("\n[test] repairs a Termux shebang in bin/")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        res = run_fixer(root)
        pip = os.path.join(root, "bin", "pip")
        check("fixer exits 0", res.returncode == 0, res.stdout + res.stderr)
        check("pip shebang rewritten",
              first_line(pip) == f"#!{root}/bin/python3.14",
              first_line(pip))


def test_repairs_symlink_target():
    print("\n[test] repairs the real target behind a symlink")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        run_fixer(root)
        target = os.path.join(root, "lib", "node_modules", "npm", "bin", "npm-cli.js")
        check("symlink target shebang rewritten",
              TERMUX not in first_line(target), first_line(target))
        npm = os.path.join(root, "bin", "npm")
        check("bin/npm still a symlink", os.path.islink(npm))
        check("bin/npm resolves to a clean script",
              TERMUX not in first_line(npm), first_line(npm))


def test_relinks_copied_npm():
    print("\n[test] converts a copied bin/npm back into a symlink")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root, npm_as_copy=True)
        npm = os.path.join(root, "bin", "npm")
        check("precondition: bin/npm is a regular file",
              not os.path.islink(npm))
        run_fixer(root)
        check("bin/npm is now a symlink", os.path.islink(npm))
        check("symlink target correct",
              os.readlink(npm) == "../lib/node_modules/npm/bin/npm-cli.js",
              os.readlink(npm) if os.path.islink(npm) else "-")


def test_repairs_libexec_and_configs():
    print("\n[test] repairs libexec/git-core scripts and etc/ configs")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        run_fixer(root)
        sub = os.path.join(root, "libexec", "git-core", "git-submodule")
        cfg = os.path.join(root, "etc", "ssh", "ssh_config")
        check("git-submodule shebang rewritten",
              first_line(sub) == f"#!{root}/bin/sh", first_line(sub))
        check("ssh_config path rewritten", TERMUX not in first_line(cfg),
              first_line(cfg))


def test_never_touches_binaries():
    print("\n[test] never rewrites binary files")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        node = os.path.join(root, "bin", "node")
        before = open(node, "rb").read()
        run_fixer(root)
        after = open(node, "rb").read()
        check("ELF binary byte-identical", before == after)
        check("binary still contains its embedded Termux string",
              TERMUX.encode() in after)


def test_idempotent():
    print("\n[test] is idempotent")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        run_fixer(root)
        snap = {}
        for base, _, files in os.walk(root):
            for f in files:
                p = os.path.join(base, f)
                if not os.path.islink(p):
                    snap[p] = open(p, "rb").read()
        res = run_fixer(root)
        check("second run exits 0", res.returncode == 0, res.stdout + res.stderr)
        same = all(
            open(p, "rb").read() == b for p, b in snap.items() if os.path.exists(p)
        )
        check("second run changed nothing", same)
        check("second run reports no script repairs",
              "scripts repaired: 0" in res.stdout, res.stdout)


def test_preserves_exec_bit():
    print("\n[test] preserves the executable bit")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        pip = os.path.join(root, "bin", "pip")
        check("precondition: pip executable", os.access(pip, os.X_OK))
        run_fixer(root)
        check("pip still executable after repair", os.access(pip, os.X_OK))


def test_reports_clean_prefix():
    print("\n[test] reports a clean prefix on the final line")
    with tempfile.TemporaryDirectory() as root:
        build_fake_prefix(root)
        res = run_fixer(root)
        check("prints 'RESULT: prefix healthy'",
              "RESULT: prefix healthy" in res.stdout, res.stdout[-300:])


def test_missing_prefix_is_reported():
    print("\n[test] missing prefix exits non-zero with a message")
    with tempfile.TemporaryDirectory() as root:
        env = dict(os.environ)
        env["OVID_PREFIX"] = os.path.join(root, "nope")
        res = subprocess.run([sys.executable, FIXER], capture_output=True,
                             text=True, env=env, timeout=60)
        check("non-zero exit", res.returncode != 0)
        check("explains the problem", "no prefix at" in res.stderr, res.stderr)


def main():
    print("=" * 66)
    print("fix_sandbox_prefix — test suite")
    print("=" * 66)
    for t in (
        test_repairs_shebang,
        test_repairs_symlink_target,
        test_relinks_copied_npm,
        test_repairs_libexec_and_configs,
        test_never_touches_binaries,
        test_idempotent,
        test_preserves_exec_bit,
        test_reports_clean_prefix,
        test_missing_prefix_is_reported,
    ):
        try:
            t()
        except Exception as exc:  # noqa: BLE001
            FAIL.append(t.__name__)
            print(f"  FAIL {t.__name__} raised {exc!r}")

    print("\n" + "=" * 66)
    print(f"passed: {len(PASS)}   failed: {len(FAIL)}")
    if FAIL:
        print("failed tests: " + ", ".join(FAIL))
        return 1
    print("ALL GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
