# Native bootstrap payload & runtime architecture audit — 2026-10-06

**Scope.** What the bundled Termux-derived bootstrap payload actually is, how it
is extracted and executed, why `targetSdk 29+` blocks that execution, and the
concrete runtime-architecture options (with feasibility and required code
changes) for running the on-device sandbox on a modern target. Read-only audit;
no source files were modified.

**Evidence method.** Facts marked **PROVEN** were read directly out of the
tracked payload files, the Dart/Kotlin/Python sources, or reproduced with a
read-only command (commands + observed output in §8). Facts marked
**REPO-ASSERTED** are stated in repo comments/docs but were not independently
re-verified here. **HYPOTHESIS** marks inference or a design option that was not
executed. Network fetch to developer.android.com failed in this environment, so
the Android-platform behavior change is recorded as **REPO-ASSERTED**, not
re-fetched.

---

## 1. What the bundled payload is

**PROVEN — it is a ZIP archive renamed to `.so`, not an ELF library.**

```
$ file android/app/src/main/jniLibs/*/libovid_bootstrap.so
arm64-v8a/libovid_bootstrap.so:   Zip archive data, at least v1.0 to extract, compression method=store
armeabi-v7a/libovid_bootstrap.so: Zip archive data, at least v1.0 to extract, compression method=store
x86_64/libovid_bootstrap.so:      Zip archive data, at least v1.0 to extract, compression method=store
```

The `.so` name is a packaging trick so Android places the bytes under
`lib/<abi>/` in the APK; the bytes are a zip of the Termux userland
(`lib/core/sandbox_service.dart:21-47`, `android/app/build.gradle.kts:94-104`).
`release_inventory.py:111-127` treats the container as `kind='bootstrap_zip'`
and descends into it. `android/app/build.gradle.kts:94-104` sets
`keepDebugSymbols += "**/libovid_bootstrap.so"` because `llvm-strip` cannot parse
a zip.

**PROVEN — three ABIs are shipped and tracked.** The `.gitignore:70` rule
ignores new matching files, but all three are tracked in git
(`git ls-files android/app/src/main/jniLibs` lists them; `git check-ignore
--no-index` still matches). Sizes and payload ELF architecture (read from the
`bin/*` ELF headers inside each zip):

| APK ABI dir | zip size (bytes) | `bin/bash` ELF class | `e_machine` | architecture |
|---|---|---|---|---|
| `arm64-v8a` | 16,040,053 | 2 (64-bit) | `0xB7` | AArch64 |
| `armeabi-v7a` | 13,287,941 | 1 (32-bit) | `0x28` | ARM |
| `x86_64` | 15,712,724 | 2 (64-bit) | `0x3E` | x86-64 |

Each payload contains exactly **102 ELF files** (arm64: 438 total members, 102
ELF; arm32/x86_64: 244 total members, 102 ELF). This matches the prior release
report (`.superpowers/sdd/.../parallel-release-report.md:7,61`).

**PROVEN — payload contents (agent-essential subset).** From the arm64 zip:

- `bin/` — 35 executables: `apt apt-cache apt-config apt-get apt-key apt-mark
  bash bzip2 coreutils curl dash dpkg dpkg-deb dpkg-divert dpkg-query
  dpkg-realpath dpkg-split dpkg-trigger find gpgv grep gunzip gzip less pkill ps
  sed tar termux-exec-ld-preload-lib termux-exec-system-linker-exec top xargs xz
  zcat zstd`.
- `lib/` — 68 `*.so` including `libcurl.so`, `libgnutls.so`, `libcrypto.so.3`,
  `libzstd.so.1.5.7`, `libreadline.so.8.3`, and the `termux-exec` family
  (`libtermux-exec-direct-ld-preload.so` — the one `_sandboxEnv` preloads).
- `lib/apt/methods/` — `copy gpgv http https file store rsh cdrom` (per
  `bootstrap_supply.py:32`).
- `etc/` (113 files), `share/terminfo/` (55), `share/termux-keyring/` (10 gpg
  keys), `var/lib/dpkg/` (190).
- `SYMLINKS.txt` — **1177 lines**, format `target←linkPath` using U+2190, e.g.
  `coreutils←./bin/comm`, `zstd←./bin/zstdmt`
  (`sandbox_service.dart:1395-1409` splits on `←`).
- **No node/python/git.** Those arrive later via `apt` in install phase 7
  (`sandbox_service.dart:1084-1086`).

**PROVEN — the three payloads are not uniform, and not reproducible from the
current recipe.**

- `arm64-v8a` uses `share/terminfo/` and ships `share/termux-keyring/*.gpg`
  (12 members).
- `armeabi-v7a` and `x86_64` use a **top-level `terminfo/`** (not
  `share/terminfo/`) and ship **no `share/termux-keyring` at all**.
- The current recipe (`bootstrap_supply.py:33,49-54,85-91`) keeps only
  `etc/`, `share/terminfo/`, `share/termux-keyring/`, `var/lib/dpkg/`, the
  `BINS` set, `lib/*.so*`, and apt methods; and `build()` **raises** if
  `share/termux-keyring/*.gpg` or `share/terminfo/` are absent. Therefore the
  committed arm32/x86_64 archives could not have been produced by the current
  recipe. This matches the prior release report
  (`.superpowers/sdd/.../parallel-release-report.md:53`).
- **No derivation manifest is committed.** `build()` writes
  `libovid_bootstrap.manifest.json` beside the payload
  (`bootstrap_supply.py:114`), but no such file exists in the tree, so the
  committed bytes are not bound to any upstream digest by a checked-in
  artifact. The code compensates for the missing keyring by shipping
  `assets/termux-keyring/*.gpg` (9 files) and seeding them
  (`sandbox_service.dart:1623-1686`).

**PROVEN — upstream provenance pins.** `bootstrap_supply.py:17-23` pins the
upstream release `bootstrap-2026.08.23-r1+apt.android-7` from
`termux/termux-packages` with per-ABI size + SHA-256
(aarch64 32,672,724 / `f902017c…`, arm 29,365,088 / `27fb2eaa…`, x86_64
32,584,674 / `5f7c54e8…`). Those are the **full upstream** assets; the shipped
derived payloads are the 13–16 MB subset. CI regenerates the payloads every
build (`.github/workflows/build.yml:82-85`, `device-test.yml:58-59`).

---

## 2. How it is extracted and executed

Install is owned by Studio first-open (`SandboxService.install` →
`_installImpl`, `sandbox_service.dart:750-1044`). Phases:

1. **Phase 0 — device facts + gate.** `_deviceFacts()` calls the
   `ovid/native` channel for `getProcessAbi`, `getSdkInt`, `isDataExecAllowed`
   (`sandbox_service.dart:2061-2088`). `sandboxPreflightGate` permanently
   rejects `sdkInt < 24` and `dataExecAllowed == false`
   (`sandbox_service.dart:88-110`).
2. **Phase 1 — read payload.** `_readBootstrapPayload()` invokes native
   `readBootstrapPayload` (`sandbox_service.dart:2102-2138`). Kotlin
   `readInstalledBootstrap` (`MainActivity.kt:44-72`) opens the base APK +
   `splitSourceDirs`, selects `lib/<processAbi>/libovid_bootstrap.so`, and
   returns its bytes. Process ABI comes from the last segment of
   `applicationInfo.nativeLibraryDir` (`MainActivity.kt:528-541`). Fallback:
   an already-extracted file in `nativeLibraryDir`.
3. **Phase 2 — extract.** `decodeAndExtractPayload` runs in a worker isolate
   (`compute`) to avoid ANR; it `ZipDecoder().decodeBytes`, parses
   `SYMLINKS.txt`, and writes every file to
   `<files>/sandbox-staging-<generation>` (`sandbox_service.dart:57-65,813-831`).
4. **Phase 3 — exec bits.** `chmod -R 755` on `bin`, `lib/apt/methods`,
   `libexec` (`sandbox_service.dart:833-836,1986-2040`).
5. **Phase 4 — symlinks.** Creates each `SYMLINKS.txt` link; absolute
   `/data/data/com.termux/files/usr/…` targets are rewritten to the **final**
   prefix, relative targets are kept verbatim (`sandbox_service.dart:838-871`).
6. **Phase 5 — text config rewrite.** `_rewritePrefixInConfigs` replaces the
   Termux prefix inside `etc/`, `share/termux*`, `bin/`, `libexec/` text files
   and rewrites Termux shebangs (`sandbox_service.dart:1545-1570`). Binary
   files are never patched.
7. **Phase 6 — publish + sanity exec.** Before publishing, it runs
   `staging/bin/bash --version` with `LD_LIBRARY_PATH` and
   `LD_PRELOAD=…/libtermux-exec-direct-ld-preload.so`; on success it renames
   staging → `<files>/sandbox` (the `$PREFIX`), writes `etc/profile`,
   `etc/apt/ovid-apt.conf`, the `usr` self-symlink, and seeds the keyring
   (`sandbox_service.dart:878-996`).
8. **Phase 7 — runtimes.** `apt update` + `apt install` of
   `nodejs npm python python-pip uv git curl zlib make binutils ripgrep openssh
   rsync jq unzip tmux gh`, with mirror rotation, shebang patching, and a
   signed `ovid-pkg` curl+dpkg fallback (`sandbox_service.dart:998-1283`,
   `sandbox_pkg.dart`).
9. **Phase 8 — self-test** (git/curl/npm ping) (`sandbox_service.dart:1289`).

**Execution path.** `exec`/`execChecked` run
`<prefix>/bin/<arg0>` (or an absolute path) with the environment from
`_sandboxEnv()` (`sandbox_service.dart:2143-2217,3018-3094,3143-3184`):
`PREFIX`, `TERMUX__PREFIX`, `HOME`, `TMPDIR`,
`PATH=$PREFIX/bin:/system/bin:/system/xbin`, `LD_LIBRARY_PATH=$PREFIX/lib`,
and `LD_PRELOAD=$PREFIX/lib/libtermux-exec-direct-ld-preload.so`. The
`termux-exec` shim is **REPO-ASSERTED** to read `TERMUX__PREFIX` and redirect
the hardcoded `/data/data/com.termux/...` paths compiled into the binaries
(`sandbox_service.dart:37-42`). There is internal tension: the apt-config
comment says that LD_PRELOAD redirect is **SELinux-blocked on many devices**,
which is why apt gets an explicit `Dir` tree instead
(`sandbox_service.dart:1572-1621`). So the shim is relied on for general
binaries but treated as unreliable for apt.

---

## 3. Why `targetSdk 29+` blocks app-data execution

**REPO-ASSERTED (consistent with Android 10 behavior changes; not re-fetched
here).** The app pins `targetSdk = 28` precisely so it can `exec` from its
writable data dir (`android/app/build.gradle.kts:107-127`):

> "The native sandbox execs bash/python/node from the app's files dir
> (Termux-style `$PREFIX`). Android 10+ blocks `execve()` AND exec-mmap of
> anything under `/data/user/<u>/<pkg>` for apps targeting API 29+ (SELinux
> `neverallow` on `app_data_file`) — the sandbox dies with `EACCES` no matter
> the ABI or file mode."

The same claim appears at `sandbox_service.dart:990-995`,
`docs/ENGINEERING_AUDIT.md:50-53`, and
`docs/superpowers/audits/2026-10-06-production-signing-runbook.md:174-185`.
The prior release report cites the official behavior-change page
(`#execute-permission`) and distinguishes interpreted scripts from executable
binaries (`.superpowers/sdd/.../parallel-release-report.md` and
`2026-10-03-ovid-feature-matrix.md:88`).

**PROVEN — the app probes this at runtime.** `isDataExecAllowed`
(`MainActivity.kt:1439-1458`) writes a `#!/system/bin/sh` script into
`applicationInfo.dataDir`, `chmod +x`, then execs it via `/system/bin/sh`; a
non-zero rc means exec is blocked. If it returns false the preflight gate
throws `SandboxUnsupportedException` before extraction
(`sandbox_service.dart:101-108,782-786`). On an Android 10+ device with
`targetSdk 29+`, this probe will fail and the sandbox refuses to install.

**Why the payload cannot simply be chmod'd around it.** The restriction is not
a file-mode problem: it is the SELinux label of the `app_data_file` inode plus
the `targetSdk` gate. `nativeLibraryDir` is a different, read-only location
labeled by PackageManager with an exec-permitting context
(**REPO-ASSERTED**, `MainActivity.kt:643-653`). That is the only path the repo
identifies as exec-allowed for `targetSdk 29+`.

**Current mitigations that do not solve it for a modern target:**

- The "phone-terminal tier (toybox)" only runs shell **scripts** through
  `/system/bin/sh`; it cannot run the ELF toolchain
  (`sandbox_service.dart:44-47`).
- The proot-Ubuntu fallback exists on demand for glibc-only commands
  (`sandbox_service.dart:232-240,3060-3093`) but proot is itself a Termux ELF
  and would need an exec-allowed home.

---

## 4. Runtime-architecture options

Legend — feasibility: **Works today**, **Partial**, **Research**, **Strategic**.

### Option A — Keep `targetSdk 28` (status quo)
- **Mechanism:** app-data exec is allowed for `targetSdk < 29`; nothing changes.
- **Evidence:** `android/app/build.gradle.kts:107-127`; current install path is
  exercised end-to-end by `_installImpl`.
- **Feasibility: Works today.** No code change.
- **Cost:** Play-ineligible; `ExpiredTargetSdkVersion` lint disabled; the
  production gate requires target ≥ 36 (`release_inventory.py:318-322`). This is
  a distribution decision, not an engineering one.

### Option B — Relocate the fixed bootstrap into `nativeLibraryDir` (partial)
- **Mechanism:** repackage the payload's executables/libs as APK native libs
  (`lib/<abi>/lib<name>.so`) so PackageManager extracts them into the
  exec-allowed `nativeLibraryDir`; keep writable state in app-data.
- **Blockers (PROVEN):**
  - PackageManager only extracts `lib/<abi>/*.so`; the payload is one zip. Every
    executable/lib must be renamed/packaged individually. Requires
    `extractNativeLibs=true` / `useLegacyPackaging=true` (currently
    `extractNativeLibs=false`, per the release report and
    `MainActivity.kt:1389-1397`).
  - `nativeLibraryDir` is **read-only**, so `SYMLINKS.txt` links cannot be
    created there and `apt install` cannot write executables there. The 35
    bootstrap tools could run, but node/python/git installed in phase 7 land in
    app-data and remain exec-blocked — i.e. the agent's real runtime still
    breaks.
  - The nested ELFs currently fail 16 KB RELRO-end alignment (78/102 arm64,
    75/102 x86_64, 80/102 arm32 — release report §; `release_inventory.py:65-70`
    enforces it in production), and the upstream prebuilt cannot be retrofitted.
- **Required code changes:** new packaging task; change `_readBootstrapPayload`
  to read a mapping/manifest instead of a zip; point `PREFIX/bin` and
  `LD_LIBRARY_PATH` at `nativeLibraryDir`; replace symlink creation with
  PATH-wrapper shims; split apt `Dir` state (app-data) from binaries
  (`nativeLibraryDir`); extend `release_inventory.py`.
- **Feasibility: Partial.** Solves only the immutable toolchain, not
  apt-installed runtimes.

### Option C — Full immutable packaged-code architecture (strategic)
- **Mechanism:** ship **all** exec'd code (bootstrap + node/python/git + every
  `dlopen`'d lib) inside the APK as native libs; app-data holds only
  data/cache. This is what `docs/ENGINEERING_AUDIT.md:53` calls the "only real
  path", and what the production runbook calls the required
  "immutable packaged-code architecture"
  (`2026-10-06-production-signing-runbook.md:174-185,200`).
- **Blockers:** large APK size; per-ABI ELF renaming; dynamic-linker namespace
  and `DT_NEEDED` resolution; 16 KB alignment/RELRO of every shipped ELF;
  `apt install` must become a bundled-package mechanism (you cannot write to
  `nativeLibraryDir`). `release_inventory.py:10-13,284` explicitly notes its
  checks are static inventory only and do not establish device qualification.
- **Required code changes:** packaging pipeline for the full toolchain; replace
  the apt-install runtime step with pre-bundled packages or an
  app-data-download + allowed-location loader; rework `_installImpl` phases
  6–7; update the inventory gate; device validation.
- **Feasibility: Strategic/large.** This is the only path that is both
  `targetSdk 36`-compatible and preserves the full agent runtime.

### Option D — Userspace ELF loader / anonymous-mmap exec shim (research)
- **Mechanism:** ship a small native launcher in `nativeLibraryDir` that reads
  a target ELF from the APK (or app-data), `mmap`s its `PT_LOAD` segments into
  **anonymous** executable memory, applies relocations, and jumps to entry.
  Anonymous RX mappings are normal for an app process (JIT/AOT), so this
  bypasses the `app_data_file` exec/exec-mmap restriction without moving every
  file.
- **Blockers:** implementing a dynamic loader (relocations, TLS, bionic
  compatibility, `DT_NEEDED` resolution) is substantial; libs would still need
  to be loadable (from `nativeLibraryDir` or via the same shim). No precedent
  in this repo.
- **Required code changes:** new native C/C++ component + JNI bridge; route
  `exec` through it; build for all three ABIs.
- **Feasibility: Research.** High risk/effort, but it is the most direct
  "run app-data payloads under `targetSdk 36`" mechanism.

### Option E — proot-mediated execution with proot in `nativeLibraryDir` (research)
- **Mechanism:** proot loads guest binaries itself via `ptrace` rather than
  kernel `execve`, so guest ELFs could stay in app-data while the proot binary
  (and its libs) live in the exec-allowed `nativeLibraryDir`.
- **Evidence:** proot scaffolding already exists — `prootBinaryPath`,
  `ubuntuRootfsPath`, `execProot`, `execProotChecked`, and the glibc fallback
  (`sandbox_service.dart:232-240,3060-3093,3832-3885`).
- **Blockers:** contradicts the "NO proot" primary architecture
  (`sandbox_service.dart:21-23`); overhead and known Android compatibility
  issues; whether proot's `ptrace`-based loading escapes the SELinux
  exec-mmap restriction is **unverified**.
- **Feasibility: Research.** Lower new-code cost than D because the scaffolding
  exists; performance/compat unproven.

### Option F — Distribution decision: sideload-only (or Play companion)
- **Mechanism:** accept Option A permanently and distribute the APK directly;
  optionally ship a reduced Play build that omits the sandbox.
- **Feasibility: Works today.** No sandbox code change; a product/policy call.

---

## 5. Recommendation

1. **Near term:** keep `targetSdk 28` and sideload distribution (Option A/F)
   while the modern-target work is designed; do not bump target alone — the
   repo and its own gate both state a target-only bump cannot qualify runtime
   behavior (`release_inventory.py:317-322`).
2. **Medium term:** pursue **Option C** (full immutable packaged-code) as the
   only path that is both `targetSdk 36`-compatible and preserves
   node/python/git; use **Option B** only if a fixed-toolchain-only sandbox is
   acceptable. Validate **Option E** as the cheapest experiment (existing
   scaffolding) before committing to Option D.
3. **Independently required regardless of option:** fix the nested-ELF 16 KB
   RELRO alignment by rebuilding/re-pinning the upstream bootstrap
   (`docs/superpowers/audits/2026-10-06-release-inventory-triage.md:105-118`),
   and close the payload provenance gap (commit derivation manifests; reconcile
   the arm32/x86_64 payloads with the current recipe).

---

## 6. Open questions / not established here

- Whether Google Play's automated 16 KB scan descends into a ZIP-in-`.so`
  payload (raised as unverified in
  `2026-10-06-release-inventory-triage.md`).
- Whether `nativeLibraryDir` is truly exec-permitted on every OEM ROM
  (**REPO-ASSERTED**, not device-tested here).
- Whether proot `ptrace`-loading bypasses the SELinux exec-mmap restriction
  under `targetSdk 29+`.
- Whether anonymous-mmap userspace exec (Option D) is viable against bionic's
  linker namespace rules.
- The Android behavior-change text could not be re-fetched in this environment;
  the §3 claim rests on repo citations plus the runtime probe's design.

---

## 7. Key code references

| Concern | Location |
|---|---|
| Payload architecture description | `lib/core/sandbox_service.dart:21-47` |
| Preflight gate (`sdk<24`, `dataExecAllowed`) | `lib/core/sandbox_service.dart:88-110` |
| Install phases 0–8 | `lib/core/sandbox_service.dart:750-1044` |
| Payload read (native channel) | `lib/core/sandbox_service.dart:2102-2138` |
| Extraction worker | `lib/core/sandbox_service.dart:57-65` |
| Symlink parsing (`←`) | `lib/core/sandbox_service.dart:1395-1409` |
| Exec environment (`LD_PRELOAD`) | `lib/core/sandbox_service.dart:2143-2217` |
| Exec entry | `lib/core/sandbox_service.dart:3018-3094,3143-3184` |
| Native payload reader + ABI | `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:44-72,528-541,1389-1431` |
| Exec probe | `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:1439-1458` |
| `nativeLibraryDir` exec note | `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:643-653` |
| `targetSdk 28` + rationale | `android/app/build.gradle.kts:94-131` |
| Payload recipe/pins | `tool/bootstrap_supply.py:17-116` |
| CI regeneration | `.github/workflows/build.yml:82-85` |

---

## 8. Reproduction commands (read-only)

```bash
# It is a zip, not an ELF:
file android/app/src/main/jniLibs/*/libovid_bootstrap.so

# Per-ABI ELF machine of the contained binaries (0xB7=AArch64, 0x28=ARM, 0x3E=x86-64):
python3 - <<'EOF'
import zipfile, struct
for abi in ['arm64-v8a','armeabi-v7a','x86_64']:
    z=zipfile.ZipFile(f'android/app/src/main/jniLibs/{abi}/libovid_bootstrap.so')
    d=z.read('bin/bash'); print(abi, d[4], hex(struct.unpack('<H', d[18:20])[0]))
EOF

# Member inventory / ELF counts / keyring / terminfo layout:
python3 - <<'EOF'
import zipfile
for abi in ['arm64-v8a','armeabi-v7a','x86_64']:
    z=zipfile.ZipFile(f'android/app/src/main/jniLibs/{abi}/libovid_bootstrap.so')
    names=[n for n in z.namelist() if not n.endswith('/')]
    elf=sum(1 for n in names if z.read(n)[:4]==b'\x7fELF')
    print(abi, 'files', len(names), 'ELF', elf,
          'keyring', sum('termux-keyring' in n for n in names),
          'share/terminfo', sum(n.startswith('share/terminfo/') for n in names),
          'terminfo/', sum(n.startswith('terminfo/') for n in names))
EOF

# Tracked despite .gitignore:
git ls-files android/app/src/main/jniLibs
git check-ignore --no-index android/app/src/main/jniLibs/arm64-v8a/libovid_bootstrap.so
```

All three commands were run for this audit; outputs are reflected in §1.
