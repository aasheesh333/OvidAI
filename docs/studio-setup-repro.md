# Studio sandbox setup: reproduction, root cause and fix (2026-10-13)

The owner reported that Studio setup in the sideload build (`com.dhanuk.ovidai`)
still fails with "hundreds of errors". Three earlier fixes (255fffd, 6ef524e,
e508c61, c870c90) were written without anyone running the setup. This time the
failure was reproduced on a real Android runtime first, the design was
researched, and the fix was proven end to end on the same runtime.

## 1. Environment and harness

| Item | Value |
|---|---|
| Host | x86_64, 12 cores, KVM |
| SDK | `/opt/android-sdk` (reused): emulator 36.x, `system-images;android-34;google_apis;x86_64` |
| AVD | `ovid34`: Pixel 6, API 34, 4 GB RAM, 8 GB data, 4 vCPU, headless (`-no-window -gpu swiftshader_indirect`) |
| ABI | process `x86_64`. The app reads `lib/x86_64/libovid_bootstrap.so` and uses the `x86_64` Termux repo (`aptArchFor`), so the emulator runs the same code paths as an arm64 phone with an x86_64 payload. No ARM translation is involved. |
| Build | `flutter build apk --debug --target-platform android-x64 --dart-define=OVID_E2E_SKIP_LOGIN=true` (sideload profile: targetSdk 28, sandbox on) |
| Payload | Regenerated with `tool/prepare_bootstrap.sh`, as CI does before every build. **The payload committed in `jniLibs/` is stale** (282 entries, no `var/lib/dpkg/status`). CI's script output differs from it, so a local build that skips the script does not match the phone. Runs 01 and 02 below used the stale payload; run 03 and later used the CI-equivalent payload. |
| Termux | `termux-app_v0.118.3+github-debug_x86_64.apk`, installed and bootstrapped for the "Termux installed" runs |

Two small, debug-only additions make the setup observable and drivable. Neither
bypasses the setup code:

* `StudioSetupCoordinator` mirrors every setup line to
  `files/studio-setup.log`, ending with a `# result:` line. The in-memory log
  used to die with the process. Read it with
  `adb exec-out run-as com.dhanuk.ovidai cat files/studio-setup.log`.
* `LoginGate.e2eSkipLogin` (`kDebugMode && OVID_E2E_SKIP_LOGIN`). The emulator
  has no Google account and this checkout has no Firebase config. The flag is
  compiled out of profile and release builds.

The harness is `scripts/studio_e2e.sh` (boots or reuses the AVD, installs,
drives Chat → Studio → **Install sandbox** / **Retry install** with uiautomator
and `input tap`, waits for `# result:`, collects the setup log, logcat, the tree
and a screenshot, counts error classes, and with `--assert` runs the runtime
checks through `files/sandbox/bin/ovid-shell`).

```sh
tool/prepare_bootstrap.sh x86_64                      # same payload as CI
scripts/studio_e2e.sh --build --assert                # fresh install (pm clear)
scripts/studio_e2e.sh --keep-data                     # upgrade / resume
scripts/studio_e2e.sh --rerun --assert                # re-run over a ready sandbox
adb shell cmd connectivity airplane-mode enable; scripts/studio_e2e.sh   # offline
```

Logs from every run are in `docs/studio-setup-evidence/` (`NN-*.txt`, setup logs plus `*.assert.txt` runtime checks).

## 2. Reproduced failure (before the fix)

| Run | Payload | Termux app | Result | Log lines |
|---|---|---|---|---|
| 01 | stale committed | no | failed after 413 s | 256 |
| 02 | stale committed | yes | failed after 402 s | 256 |
| 03 | CI-equivalent | yes | failed after 387 s | 220 |

Error classes and their counts (run 03 / runs 01 and 02):

| # | Class | Count | Sample |
|---|---|---|---|
| A | dpkg refuses to run (`apt-get install` exit 100) | 2 / 3 | `dpkg: error: 6 expected programs not found in PATH or not executable` |
| A2 | per-tool dpkg PATH warnings | 8 / 14 | `dpkg: warning: 'sh' not found in PATH` (also rm, tar, diff, dpkg-deb, start-stop-daemon) |
| A3 | apt reports the dpkg failure | 2 / 3 | `E: Sub-process /data/user/0/com.dhanuk.ovidai/files/sandbox/bin/dpkg returned an error code (2)` |
| B | dpkg failure misread as TLS, healthy mirror rotated away | 0 / 1 | `[apt] cert/TLS error — sandbox CA bundle may be broken; rotating mirror` |
| C | ovid-pkg fallback rejects the whole index | 27 / 27 | `[ovid-pkg] invalid dependency metadata: 0verkill` |
| D | ovid-pkg index fetch 404 on one mirror | 10+5 / 10+5 | `curl: (22) … 404` / `mirror … rejected` |
| E | essential group failed | 6 / 6 | `Could not install nodejs npm. Last error: …` (also python, python-pip, uv, git, curl) |
| F | optional group unavailable | 9 / 9 | make, binutils, ripgrep, openssh, rsync, jq, unzip, tmux, gh |
| G | final probes | 7 / 7 | `node … ⚠ exit 127: node: command not found` (also npm, npx, python, pip, git, uvx) |
| H | mirror probe timeouts | 2 / 2 | `termux.cdn.lumito.net: timeout` (harmless) |

Each run shows about 70 error lines. Each failed group also prints multi-line
apt/dpkg output and the user taps Retry several times, which together produces
the "hundreds of errors" on the phone.

### Root causes

1. **dpkg cannot work with `--root=<prefix>`** (classes A, A3). The old
   design passed `DPkg::Options "--root=$p"`. dpkg checks its required tools as
   `<root><PATH entry>/<tool>`, so with PATH=`$p/bin` it looks for
   `$p$p/bin/sh`, which never exists. The `data/data/com.termux/files/usr`
   alias only covers members extracted under the Termux path, not PATH.
2. **The bootstrap subset is incomplete** (class A2, and it persists without
   `--root`). `tool/bootstrap_supply.py` kept a hand-picked binary list, which
   dropped `diff`, `cmp` and `start-stop-daemon` (all required by dpkg) plus
   about 230 other tools. `var/lib/dpkg/status` still listed their packages as
   installed. A prototype under proot without `--root` still failed:
   `dpkg: error: 2 expected programs not found` (diff, start-stop-daemon).
3. **The fallback installer is broken** (class C). The ovid-pkg awk validator
   rejects any `Architecture` containing `_`, so on x86_64 it aborts on the
   first record (`0verkill`). On aarch64 this check passes, so the phone gets
   further into the fallback, which is another source of errors.
4. **Misclassification** (class B). `_looksLikeAptTls` matched `openssl` and
   `ca-certificates` in apt's package list.
5. **Fundamental cause.** Every Termux binary, script, conffile and maintainer
   script has `/data/data/com.termux/files/usr` compiled in. Ovid's prefix is
   `/data/user/0/com.dhanuk.ovidai/files/sandbox`. That path is longer, so
   binaries cannot be patched in place. With Termux installed, the compiled-in
   path belongs to another uid (EACCES). Without Termux it does not exist
   (ENOENT). The previous design patched around this one tool at a time: dpkg
   `--root` plus an alias symlink, binary-patching dpkg's CONFIGDIR, `sed` over
   shebangs, APT_CONFIG with explicit Dir values, CA, git and python env
   overrides, npm and npx wrapper scripts over package files, and a custom
   curl+dpkg installer. Every new package (python's prefix, perl's @INC, git's
   templates, postinst scripts, openssl's config dir…) reopens the problem, and
   rewriting package files breaks dpkg's conffile hashes. **The approach is
   unsound and was replaced, not patched again.**

## 3. Research and the design chosen

How other projects run Termux packages outside `com.termux`:

* **Rebuild every package for a new prefix** (Termux README, "Forking":
  changing the package name *"will require building the bootstrap zip
  packages and other packages with the new `$PREFIX`"*). This is correct, but
  Ovid would have to build and host its own repository of thousands of
  packages. Not feasible here.
* **termux-exec (LD_PRELOAD)** only rewrites exec and shebang interpreter
  paths (`/bin/sh`, `/usr/bin/env`). It does not relocate open() or stat(), so
  it cannot fix dpkg, python, git or configs.
* **In-place binary or text patching** is the old design (see root cause 5).
  It breaks on every new package and on every upgrade.
* **proot path translation**, as used by `termux-chroot` (`-b $PREFIX:/usr`),
  proot-distro, UserLAnd, AnLinux and Andronix. ptrace rewrites path arguments
  of every syscall in the whole process tree, so compiled-in paths resolve to
  the app's own directory for every package without modification.

**Decision: run the stock Termux userland under proot.** Every sandbox process
(apt, dpkg, the agent shell, the Studio terminal, MCP servers, background jobs)
is started as:

```
$P/bin/proot --kill-on-exit \
  -b $P/.termux-root:/data/data/com.termux        # private glue dir
  -b $P:/data/data/com.termux/files/usr           # the prefix
  -b $P/home:/data/data/com.termux/files/home \
  -w <host cwd>  /data/data/com.termux/files/usr/bin/env \
  LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so <cmd>
```

* **Glue directory.** The real `/data/data/com.termux` is never touched, so
  the "Termux installed" EACCES case cannot occur. apt's `Dir::Cache`
  (`/data/data/com.termux/cache`) also lands inside the sandbox.
* **Host paths still work.** Workspaces under `files/workspaces`, credential
  files and the plugin runtime roots are used unchanged. The Studio terminal
  ran `npm init` and `npm install` in its workspace.
* **termux-exec runs inside the guest only**, exactly as in the Termux app, so
  `#!/bin/bash` and `#!/usr/bin/env node` scripts work. It never hooks proot.
* **proot ships in the payload.** proot, libtalloc and libandroid-shmem are the
  signed Termux repository debs, vendored in `tool/vendor/termux-debs/<arch>/`
  (444 KB for 3 ABIs) and pinned by SHA-256 in `bootstrap_supply.py`. They are
  merged into the payload and registered in `var/lib/dpkg/status`, so
  `apt upgrade` maintains them. Setup works with no extra download.
  (Termux mirrors keep only the latest version, so pinning a download URL
  would break CI after an upgrade.)
* **Full payload.** The upstream bootstrap is kept except `share/man`,
  `share/info`, `share/doc`, `include`, `libexec/installed-tests` and
  `share/LICENSES`. Per ABI the payload grows from 16 MB to 22 MB (58 MB
  expanded). Every package that dpkg's status says is installed is actually
  present.
* **Nothing is rewritten.** Configs, shebangs and binaries stay stock, and
  dpkg conffile hashes keep matching. The only additions are
  `etc/apt/apt.conf.d/99ovid` (`--force-confdef/--force-confold`,
  Assume-Yes, timeouts), the mirror in `sources.list`, the `.ovid-layout`
  marker and `bin/ovid-shell`, a debug launcher. Absolute Termux symlink
  targets in SYMLINKS.txt become relative.
* **Stock apt is the only installer.** A failed attempt retries apt on the
  next healthy mirror. The ovid-pkg fallback, shebang patching and npm/npx
  wrappers are not used under proot.
* **Resume.** Before apt runs, an interrupted dpkg journal or packages left
  `unpacked`/`half-configured` trigger `dpkg --configure -a`.
* **Migration.** A prefix from the old design (no marker, but
  `etc/apt/ovid-apt.conf` or the alias symlink present) is reported as not
  installed. Nothing is deleted at boot. The next setup installs a fresh core
  and moves the old `home/` into it (`carryHomeOver`, never over a non-empty
  home), dropping only the app-written legacy `.bashrc`. On failure the move
  is rolled back. Workspaces live outside the prefix and are unaffected.

Trade-offs:

* **Speed.** ptrace adds overhead. Measured on the emulator: proot startup
  about 340 ms (`bash -c true`: 338 ms vs 25 ms native); each exec inside a
  running proot about 20 ms; `node -v` about 1.1 s, `npm -v` about 3.4 s,
  `npm install is-number` 25 s, `pip install six` 9 s. A full install of
  node, npm, python, pip, uv, git, curl and the optional tools takes
  7–8.5 minutes, about the same as the old (failing) run, dominated by
  download and unpack.
* **Kernel dependence.** proot depends on ptrace being available. It works on
  stock Android 7–15 (proot-distro, UserLAnd), but a ROM that blocks ptrace
  would block the sandbox. The old exec gate already covers the
  exec-from-data case.
* **APK size.** About 6 MB more per ABI payload.
* **Residual code.** The native code paths are kept only for legacy prefixes
  in host unit tests. In production a legacy prefix is always replaced.
  Removing that code is a follow-up.
* **Ubuntu fallback.** The lazy proot-Ubuntu provisioning script calls
  `proot -R` from inside the sandbox shell, which is now proot inside proot.
  It was not exercised here. `execProot` itself starts the host proot directly
  and now receives `PROOT_LOADER`.

## 4. Verification on the emulator (after the fix)

| Run | Scenario | Result | Errors |
|---|---|---|---|
| 10 | upgrade over run 03's broken prefix, Termux installed | **ready in 510 s**, `home/keep-me.txt` carried over | 0 (`ld` probe; fixed to probe `as`) |
| 11 | re-run setup over the ready sandbox (`--rerun`) | **ready in 23 s**, nothing reinstalled | 0 |
| 12 | fresh install (`pm clear`), Termux installed | **ready in 423 s** | 0 (only "optional pnpm unavailable: corepack not found", since Node 26 dropped corepack) |
| 13 | force-stop while dpkg was unpacking libicu (journal 0000–0003 left), then resume | **ready in 424 s**, `dpkg --configure -a` ran first | 0 |
| 14 | airplane mode | **fails in 23 s**: "No package mirror is reachable. Check the internet connection, Private DNS / VPN settings, then tap Retry." Network back on, then **Retry install** tapped: **ready in 454 s** | 0 |
| 15 | fresh install, Termux **not** installed | **ready in 500 s** | 0 |
| 20→21 | **final commit 6fd73db** (`--build`): the base build seeds a broken legacy prefix (failed after 370 s, same classes as run 03), then the final build upgrades it | **ready in 423 s**, HOME kept, all `--assert` checks pass | 0 |
| 22 | final build, `--rerun --assert` | **ready in 20 s**, all checks pass | 0 |

Runtime checks (`--assert`, run through `files/sandbox/bin/ovid-shell` as the
app uid; runs 12 and 21 match):

```
node -v              v26.4.0
npm -v / npx -v      11.20.0
python -V            Python 3.14.6
pip -V               pip 26.2.1 from /data/data/com.termux/files/usr/lib/python3.14/site-packages/pip (python 3.14)
git --version        git version 2.56.0
curl --version       curl 8.22.0 (x86_64-pc-linux-android) … OpenSSL/3.6.5
uv --version         uv 0.13.0 (x86_64-linux-android)
npm install is-number@7 && node -e …   added 1 package · true
pip install six==1.16.0 && python -c … 1.16.0
git init + commit                      1 commit
```

In the app itself: the setup's own verification step runs
`node --version && npm --version && npx --version`, `python/pip/uv/uvx`,
`git` and `curl` through `SandboxService.execChecked`, and all pass. The
Studio terminal (`SandboxService.spawn(['bash'])`) printed `v26.4.0` for
`node -v`, and its `npm init -y`, `npm install is-number` and
`pip install requests` produced `files/workspaces/ws_…/node_modules/is-number`
and `site-packages/requests`.

## 5. What still differs from a real phone

* The emulator ABI is x86_64. The phone uses the aarch64 payload and repo
  (same code, other vendored debs). The aarch64 payload is built and its debs
  are verified by SHA-256 pin, but arm64 proot was never executed. Two
  cross-check attempts failed, both because ARM translation cannot run these:
  the arm64 debug APK (`adb install --abi arm64-v8a`) crashes in
  FlutterLoader, and arm64 Termux binaries plus proot under
  `ndk_translation` die on `LD_LIBRARY_PATH` / EM_AARCH64 mismatches. An
  arm64 system image does not run under KVM on this x86_64 host.
* Emulator I/O and CPU differ, so timings will differ. ptrace overhead on
  arm64 phones is usually lower than the 340 ms startup measured here.
* Vendor kernels and ROMs (e.g. Samsung or Xiaomi seccomp or ptrace
  restrictions, phantom-process killing on Android 12+ for long setups) are
  not represented by the Google API image.
* The emulator used the app uid through `run-as` (domain `runas_app`) for the
  assert commands. In-app commands run as `untrusted_app_27`; the in-app
  verification and terminal runs above cover that domain.
