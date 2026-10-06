# Target SDK 36 Runtime Architecture

**Date:** 2026-10-06
**Author:** opencode (research/spike worker)
**Status:** Design — awaiting user review
**Scope:** A concrete, evidence-based architecture that lets Ovid ship a
`targetSdkVersion >= 36` artifact on Google Play while preserving the
on-device terminal / Studio / MCP runtime, or an explicit, reviewed
decision to move that capability off-device.
**Mode:** Read-only research. This document makes **no source changes**.
Every factual claim is tied to a repository anchor or a dated external
source; anything not directly verified is marked **HYPOTHESIS (Hn)** and
registered in §9.

Related documents:
- Master audit: [`2026-10-03-ovid-master-audit.md`](../audits/2026-10-03-ovid-master-audit.md) (W16.04, W06.05)
- Master repair plan: [`2026-10-03-ovid-master-repair-plan.md`](../plans/2026-10-03-ovid-master-repair-plan.md) (W16.04)
- Native 16 KB triage: [`2026-10-06-release-inventory-triage.md`](../audits/2026-10-06-release-inventory-triage.md)
- Remaining closure / A3 blocker: [`2026-10-06-remaining-closure.md`](../audits/2026-10-06-remaining-closure.md)
- Signing/target runbook: [`2026-10-06-production-signing-runbook.md`](../audits/2026-10-06-production-signing-runbook.md)
- Engineering audit P0-3: [`../../../ENGINEERING_AUDIT.md`](../../ENGINEERING_AUDIT.md)
- Native sandbox plugin spec: [`2026-09-16-native-sandbox-plugins-design.md`](2026-09-16-native-sandbox-plugins-design.md)
- Cloud gateway spec: [`2026-10-01-ovid-cloud-gateway-design.md`](2026-10-01-ovid-cloud-gateway-design.md)
- Concurrent bootstrap/runtime audit: [`2026-10-06-native-bootstrap-runtime.md`](../audits/2026-10-06-native-bootstrap-runtime.md)

---

## 1. Problem statement

Ovid is a Flutter Android app whose core Studio/agent capability is a
Termux-derived Linux userland. It installs a bootstrap ZIP into app-private
storage and execs `bash`/`python`/`node`/`git` from there.

Current architecture (evidence):

- The bootstrap ships as `jniLibs/<abi>/libovid_bootstrap.so`, which is a
  **ZIP archive, not an ELF** (`android/app/build.gradle.kts:94-104`;
  `lib/core/sandbox_service.dart:21-47`; triage §1b).
- On first Studio open it is unzipped into `<app-support>/sandbox` (the
  `$PREFIX`), `chmod +x` is applied, and commands run as
  `$PREFIX/bin/bash -lc ...` (`sandbox_service.dart:813-996`,
  `_sandboxEnv()` at `:2143-2217`, `exec()` at `:3018-3049`).
- `targetSdk = 28` is deliberate (`build.gradle.kts:119`), and the
  `ExpiredTargetSdkVersion` lint is disabled (`:121-127`), because Android 10
  (API 29) enforces W^X: an untrusted app targeting API 29+ cannot `execve()`
  **or** `exec-mmap` a file under its writable home directory
  (`app_data_file`). See `build.gradle.kts:111-118`,
  `sandbox_service.dart:985-995`, `ENGINEERING_AUDIT.md` P0-3 (`:50-53`),
  and `2026-10-06-remaining-closure.md:100-103`.
- The in-app probe `isDataExecAllowed` (`MainActivity.kt:1439-1458`) and the
  preflight gate (`sandbox_service.dart:87-110, 782-786`) exist precisely to
  detect ROMs that block app-data exec.

Why this cannot stand:

- Google Play requires **target API 36 (Android 16)** for new apps and app
  updates since **2026-08-31**, with a possible extension to **2026-11-01**
  (official: <https://support.google.com/googleplay/android-developer/answer/11926878>,
  fetched 2026-10-06). Target 28 is not submittable.
- The repository's own production gate already enforces the floor:
  `release_inventory.py:318-322` adds `production requires target API 36 or
  newer`, and `build.yml:186-189` requests `target=36` when
  `production_release=true`.
- A target-only bump is explicitly rejected as insufficient by every current
  document: the sandbox would die with `EACCES` at the first `bash` exec
  (`build.gradle.kts:111-118`; triage §5a.1; remaining-closure A3.2).

**The problem is therefore not the SDK number. It is the execution model:**
the app currently relies on a writable, executable app-private directory,
which modern Android and Play both disallow.

---

## 2. Precise platform mechanism (what exactly is blocked)

Established Android 10 behavior change (official:
<https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission>):

> "Untrusted apps that target Android 10 cannot invoke `exec()` on files
> within the app's home directory. This execution of files from the writable
> app home directory is a W^X violation. Apps should load only the binary
> code that's embedded within an app's APK file."

Corroborated by the Termux project, which pins target 28 for exactly this
reason (<https://github.com/termux/termux-packages/wiki/Termux-and-Android-10>,
fetched 2026-10-06):

> "Google requires the target SDK level to be set to at least 29 … But due to
> new operating system behavior changes we cannot do so and have to use SDK
> level 28."

Consequences that the design must account for:

1. **All app-writable locations are non-executable.** The app home dir
   (`filesDir`, `cacheDir`, `codeCacheDir`, `noBackupFilesDir`, device-
   protected storage) is exec-denied by SELinux; external app-specific dirs
   are `noexec` mounts. There is no writable+executable app-owned path.
2. **Both `execve` and `PROT_EXEC` mmap are denied** for `app_data_file`
   under targetSdk>=29, so `LD_PRELOAD` shims (the Termux path-redirect
   `libtermux-exec-direct-ld-preload.so`, `sandbox_service.dart:39-42,
   2163`) are blocked too when loaded from app data.
3. **The only exec-allowed app-owned location is `nativeLibraryDir`**, the
   read-only directory populated at install time from `jniLibs/`
   (`ENGINEERING_AUDIT.md:53`; chaosgoo, 2026-06-13; u1f383, 2025-06-15).
   Files there are labeled as native libraries and granted execute by policy.
   A file is extracted there only if it is named `lib*.so` and
   `android:extractNativeLibs="true"` (or legacy packaging) is set.
4. **Installing from Play does not relax the SELinux rule.** The dynamic-code
   policy is a separate, additional constraint (§3), not a platform
   permission.

**HYPOTHESIS H1 (decisive):** On a modern target-36 build, an arbitrary
*bionic* ELF (not a real shared object) placed in `nativeLibraryDir` and
named `lib*.so` can actually be `execve`'d. Evidence conflicts:
chaosgoo (2026-06-13) and u1f383 (2025-06-15, tested on Android 16 / Pixel
8a) report success; `shiaho777/web-to-app#795` (2026-09-06) reports that on
its target-35 host build "`untrusted_app` … cannot exec its own native libs
either, and memfd `execveat` is denied too", and that only a user-mode
loader (fork + mmap + entry jump, zero `execve`) worked. **H1 must be
resolved on-device before any large migration.** The spike in §8.1 exists to
settle it.

**HYPOTHESIS H2:** Versioned/SONAME shared libraries (`libz.so.1`,
`libcrypto.so.3`, `libreadline.so.8.3`) survive the `lib*.so` extraction
filter and resolve through `DT_NEEDED`/`LD_LIBRARY_PATH`. The extraction
pattern only admits names ending in `.so`, while the dynamic linker resolves
by SONAME (`libz.so.1`); `nativeLibraryDir` is read-only, so no symlink can
be created there. Triage §1b shows the payload already contains exactly such
versioned names (`lib/libcrypto.so.3`, `lib/libreadline.so.8.3`,
`lib/libz.so.1.3.2`).

**HYPOTHESIS H3:** The bionic linker honors `LD_LIBRARY_PATH`/`LD_PRELOAD`
pointing into `nativeLibraryDir`, and the termux-exec preload still performs
its prefix rewrite from there.

---

## 3. Policy constraints (Google Play)

From the Device and Network Abuse policy, full text
(<https://support.google.com/googleplay/android-developer/answer/9888379>,
fetched 2026-10-06):

> "An app distributed via Google Play may not modify, replace, or update
> itself using any method other than Google Play's update mechanism.
> Likewise, an app may not **download executable code (such as dex, JAR,
> .so files) from a source other than Google Play**. This restriction does
> not apply to code that runs in a virtual machine or an interpreter where
> either provides indirect access to Android APIs (such as JavaScript in a
> webview or browser)."

> "Apps or third-party code, like SDKs, with interpreted languages
> (JavaScript, Python, Lua, etc.) loaded at run time (for example, not
> packaged with the app) must not allow potential violations of Google Play
> policies."

Implications for the current implementation:

- **Bundled code is compliant; downloaded code is not.** Code packaged in
  the APK/AAB (including native ELFs delivered via `jniLibs`) is allowed.
- **The current runtime supply chain is non-compliant on Play.** The app
  downloads Termux `.deb` packages (`nodejs`, `python`, `git`, …) over the
  network via apt / `ovid-pkg` (`sandbox_service.dart:1050-1232`,
  `sandbox_pkg.dart:112-260`), and downloads an Ubuntu rootfs, JDK, Kotlin
  compiler and Flutter SDK (`sandbox_service.dart:3506-3560, 3686-3827,
  3914-4051`). These are executable-code downloads from outside Play.
- **The interpreter/VM exception is real but narrow.** Running Python/JS
  *scripts* is exempt; downloading the *interpreter binary itself* is not,
  and interpreted code "loaded at run time" must not facilitate further
  violations (e.g. `npm install` fetching prebuilt `.node` native addons).
- **No developer-tool / arbitrary-native-execution exemption is documented.**
  "specialUse" foreground service, an interpreter label, or a metadata flag
  does not grant one. **HYPOTHESIS H10:** a Play review *might* accept a
  narrowly scoped interpreter-based coding assistant, but no such exemption
  is documented and it must not be planned around.

Net policy requirement for a Play build: **every byte that executes must be
packaged in the artifact**, or execute inside a bundled VM/interpreter.

---

## 4. Additional constraints

- **16 KB page size (targetSdk 35+).** Every 64-bit native object must have
  16 KB-aligned `PT_LOAD` and GNU_RELRO. Current inventory: 153 nested
  bootstrap ELFs + 5 outer prebuilts fail the RELRO criterion
  (`2026-10-06-release-inventory-triage.md` §1; enforced only in
  `production` mode, `release_inventory.py:299-300`). Any migration that
  ships those ELFs as real native libs inherits this blocker and must
  rebuild/re-pin the payload with 16 KB-aligned RELRO (triage §5b).
- **Artifact size / delivery.** Bundling node, Python, git, gh and the base
  userland removes the on-demand download but grows the base. Play uses
  AAB; base-module download limits and Play Asset Delivery strategy must be
  decided. (Exact current limits not verified in this spike — treat as an
  open item, not a blocker.)
- **`minSdk = 23` remains** (`build.gradle.kts:110`), so API 23/24 devices
  must keep working (the phone-terminal toybox tier,
  `sandbox_service.dart:44-47`).
- **Release tooling contract** already encodes the target: `--expected-target`
  must equal the manifest, and production additionally requires `>= 36`
  (`release_inventory.py:313-322`).

---

## 5. Options analysis

Each option is scored on: does it satisfy target 36, is it Play-compliant,
does it preserve the on-device Linux toolchain, and effort/risk.

### Option A — Extract to an app-owned dir with a "noexec workaround" — **REJECTED**

There is no workaround. The denial is an SELinux type rule on
`app_data_file`, independent of mount options and file mode bits; the app
cannot mount filesystems, and every writable app-owned path is either
`app_data_file` (exec-denied) or a `noexec` external mount. `chmod +x` is
irrelevant (the current code already does it, `sandbox_service.dart:833-836`,
and still needs target 28). **HYPOTHESIS H11:** a few custom OEM ROMs may
enforce differently; the existing `isDataExecAllowed` probe remains the
correct detector, but no standard path makes this option viable.

### Option B — Immutable packaged runtime via `jniLibs` / `nativeLibraryDir` — **PRIMARY CANDIDATE**

Ship every executable and shared library as `lib<name>.so` under
`src/main/jniLibs/<abi>/`, set `android:extractNativeLibs="true"`, and exec
from `applicationInfo.nativeLibraryDir`. Writable state (home, work dirs,
apt/dpkg state, caches, symlink farm) stays in app data — read-only is fine
for configs; only *executables* must live in `nativeLibraryDir`.

- **Target 36:** yes, if H1 holds.
- **Play:** yes, because all executable code is packaged in the artifact
  (chaosgoo "compliance" note; policy §3). Requires eliminating runtime
  downloads in the Play flavor.
- **Capability preserved:** yes, in principle — it is the same bionic
  userland, just relocated.
- **Effort/risk:** very high. This is the "immutable packaged-code
  architecture" named in triage §5a.1 and `ENGINEERING_AUDIT.md:53`.
- **Known hard sub-problems:** H1 (exec viability), H2 (versioned SONAMEs
  vs. the `lib*.so` extraction filter and read-only dir), H3
  (`LD_LIBRARY_PATH`/`LD_PRELOAD` from `nativeLibraryDir`), H4 (16 KB RELRO
  rebuild of the whole payload), H5 (symlink farm and rewritten shebangs
  cannot live in the read-only dir), H6 (Play scanner behavior on non-ELF
  `lib*.so`), H7 (`extractNativeLibs=true` and AAB split delivery).
- **Required changes:** see §7.

### Option C — In-process interpreters (WebAssembly / embedded CPython via JNI) — **PARTIAL FALLBACK**

Bundle a real native lib (WASM engine such as Wasmtime/WAMR, or CPython via
Chaquopy/libpython) and load it with `System.loadLibrary` (allowed), running
user scripts in-process. Play's interpreter/VM exception applies.

- **Covers:** Python scripts (PDF tools, data utilities), JS via an embedded
  engine. **Does not cover:** native MCP servers (`npx`/`uvx`), `git`/`gh`
  CLI, `apt`, `node-gyp`, or arbitrary shell pipelines. This is a capability
  regression, not a drop-in.
- **HYPOTHESIS H8:** WASM32-WASI CPython cannot run native Python wheels
  (numpy/pandas/lxml), so many real tool dependencies remain unavailable;
  this must be measured before relying on it.
- **Effort/risk:** high; new runtime subsystem, MCP transport rework,
  product-scope reduction.

### Option D — proot — **NOT A STANDALONE FIX**

`proot` is itself a Termux ELF that must be exec'd, and its guest binaries
are still `execve`'d by the kernel from the rootfs. It therefore inherits the
identical app-data exec block. It also downloads an Ubuntu rootfs
(`sandbox_service.dart:3506-3560, 3686-3827`), which is a Play violation.
proot is only useful *layered on* Option B (proot + guest ELFs shipped as
`lib*.so` in `jniLibs`) or with a user-mode loader. **HYPOTHESIS H9:** a
user-mode loader could map and jump into a guest image without `execve`, but
a full multi-process shell still needs per-child `execve`, so this does not
scale to the toolchain.

### Option E — Play policy exemption — **REJECTED**

No documented exemption covers arbitrary downloaded/executed native code for
a developer-tool app (§3). "specialUse" FGS and interpreter labels are not
exemptions. This cannot be the plan (H10).

### Option F — Server-side execution (remote Studio) — **COMPLIANT FALLBACK**

Move terminal/agent tool execution to an Ovid-owned server; the app keeps
chat, browser, device control and UI. No executable code is downloaded to or
run on the device, so both the platform W^X rule and the dynamic-code policy
are satisfied.

- **Pros:** guaranteed Play-compliant, no 16 KB/native-payload work, works on
  any API.
- **Cons:** requires network; recurring server cost; code and credentials
  leave the device (privacy/trust); loses offline on-device Studio; the
  existing cloud gateway spec currently covers *models*, not *execution*
  (`2026-10-01-ovid-cloud-gateway-design.md:357` explicitly leaves
  "sandbox/tools/subagents/hooks untouched").
- **Effort/risk:** medium-high, but architecturally simpler and lower
  technical risk than B.

### Option G — Stay target 28 + extension — **NOT ELIGIBLE**

The extension (to 2026-11-01) only helps existing apps and does not create a
targetSdk-36-eligible runtime. Excluded by the goal.

### Summary

| Option | Target 36 | Play | On-device toolchain | Verdict |
|---|---|---|---|---|
| A noexec workaround | n/a | n/a | no | rejected (no such workaround) |
| B jniLibs immutable runtime | yes if H1 | yes if bundled-only | full | **primary, spike-gated** |
| C in-process interpreters | yes | yes | partial | fallback for Python/JS subset |
| D proot | only under B | only if bundled | partial | not standalone |
| E exemption | n/a | no | n/a | rejected |
| F server-side execution | yes | yes | remote | **compliant fallback** |
| G target 28 + extension | no | no | full | not eligible |

---

## 6. Recommended architecture

**Recommendation:** pursue **Option B** as the primary target-36-eligible
architecture, *gated behind a decisive on-device spike* (§8.1) that resolves
H1–H3. Run **Option F** as a parallel, guaranteed-compliant fallback if the
spike disproves H1, and keep **Option C** as a bounded capability subset if a
full userland is not viable.

Do **not**: bump the target alone; rely on a noexec workaround; assume a Play
exemption; or keep any runtime download in the Play flavor.

Rationale: B is the only option that preserves the product's defining
on-device Linux capability while satisfying both the platform rule and the
Play policy. Its single existential uncertainty (H1) is cheap to test before
committing to the expensive migration, which is why the spike is the first
deliverable.

### 6.1 Primary design — Option B, components

**Build-time packaging (`tool/prepare_bootstrap.sh`, `tool/bootstrap_supply.py`).**
Replace the single `libovid_bootstrap.so` ZIP with a generated `jniLibs`
tree per ABI plus a manifest:

```
android/app/src/main/jniLibs/<abi>/lib<logical>.so      # every exec'd/dlopen'd ELF
android/app/src/main/assets/ovid-runtime/manifest.json  # logical name -> lib name, per ABI
android/app/src/main/assets/ovid-runtime/symlinks.txt   # sh->dash, ls->coreutils, ...
android/app/src/main/assets/ovid-runtime/shebang-map.json
```

- Only ELFs that are executed or `dlopen`'d go into `jniLibs` (Option B
  constraint). Pure data (`terminfo`, apt lists, TLS CA, keyring) stays as
  assets and is copied to writable app data at install.
- Names must satisfy the `lib*.so` extraction filter; versioned SONAMEs are
  handled per H2 (e.g. patch `DT_NEEDED`/SONAME to unversioned names, or
  provide a loader shim).
- The payload must be rebuilt/re-pinned with 16 KB-aligned RELRO (H4).

**Install-time (`MainActivity.kt`, `sandbox_service.dart`).**

- PackageManager extracts `jniLibs` to `nativeLibraryDir`; the app reads
  `applicationInfo.nativeLibraryDir` (already exposed at
  `MainActivity.kt:643-653`). No executable extraction or `chmod` is needed
  for binaries.
- Create the writable `$PREFIX` in app data containing only: `home/`, `tmp/`,
  `etc/` (profile, apt config, TLS), `var/lib/dpkg`, caches, and a `bin/`
  symlink farm pointing at `nativeLibraryDir/lib*.so`.
- Shebangs in scripts are rewritten to the absolute
  `nativeLibraryDir/libsh.so` (or to the writable `bin/sh` symlink, whose
  target is exec-allowed).

**Exec (`sandbox_service.dart`).**

- `_sandboxEnv()` (`:2143-2217`) changes: `PATH` =
  `<writable bin>:<nativeLibraryDir>:/system/bin`; `LD_LIBRARY_PATH` =
  `nativeLibraryDir`; `LD_PRELOAD` =
  `nativeLibraryDir/libtermux-exec-direct-ld-preload.so`.
- `exec()` (`:3018-3049`) resolves `args[0]` against
  `nativeLibraryDir/lib<name>.so` instead of `$PREFIX/bin/<name>`.
- The path jail (`checkPolicy`, `:2914-2988`) is unchanged; only the
  executable lookup changes. Work dirs, git credential file, and quota logic
  stay in app data.

**Updates.** `nativeLibraryDir` changes on every install/update; recompute
it. Writable state persists in app data; binaries are replaced by
PackageManager atomically. `checkExisting()` (`:569-640`) validates
`nativeLibraryDir` contents rather than a writable prefix.

**Runtimes and Play flavor.** Bundle `node`/`python`/`git`/`gh` and the
compiler as `jniLibs` for the Play build. Remove the `apt`/`ovid-pkg` and
proot-Ubuntu/Flutter/JDK/Kotlin download routes from the Play flavor, or move
them behind a non-Play build flavor. Lazy on-demand installs become
build-time packaging decisions.

**Error handling.** Preserve the honest failure taxonomy: a missing/incompatible
`nativeLibraryDir` ELF surfaces as a permanent `SandboxUnsupportedException`
(`:71-76`), not a retry loop; ABI mismatch keeps the existing
`processAbi`/payload diagnostics (`MainActivity.kt:528-541, 1399-1430`).

**Data flow (target state):**

```
PackageManager install
  jniLibs/<abi>/lib*.so  ->  nativeLibraryDir (read-only, exec-allowed)
assets/ovid-runtime/*    ->  copied to <app-data>/sandbox (config/symlinks)

exec(name, args)
  -> resolve nativeLibraryDir/lib<name>.so
  -> Process.start(that, args, env{ PATH, LD_LIBRARY_PATH, LD_PRELOAD, PREFIX, HOME, TMPDIR })
  -> child writes only to <app-data>/sandbox/{home,work,tmp,...}
```

---

## 7. Required code changes (Option B)

No changes are made by this document; this is the required change set.

| File | Change | Reason |
|---|---|---|
| `android/app/build.gradle.kts` | `targetSdk = 36`; remove the `ExpiredTargetSdkVersion` disable; set `extractNativeLibs = true` (legacy packaging) in the manifest; keep `keepDebugSymbols` only for the real ZIP if any remains | Target floor + make PackageManager extract libs (`:119-127`, `:94-105`) |
| `android/app/src/main/AndroidManifest.xml` | `android:extractNativeLibs="true"` on `<application>` | Required for native-lib extraction |
| `android/app/src/main/jniLibs/<abi>/` | Replace `libovid_bootstrap.so` ZIP with real per-binary `lib*.so` ELFs | Executables must live in an exec-allowed dir |
| `tool/prepare_bootstrap.sh` / `tool/bootstrap_supply.py` | Emit the per-ABI jniLibs tree + manifest/symlink/shebang maps; re-pin a 16 KB-RELRO bootstrap | Packaging source of truth (`bootstrap_supply.py:18-22`) |
| `android/.../MainActivity.kt` | Keep `getNativeLibraryDir`; add an exec probe for `nativeLibraryDir`; optionally a memfd/user-mode loader probe | H1/H2 resolution and runtime exec |
| `lib/core/sandbox_service.dart` | Prefix layout split (exec from `nativeLibraryDir`, writable state in app data); `_sandboxEnv()`/`exec()`/`checkExisting()`/`_readBootstrapPayload()` rework; remove download routes in Play flavor | The actual relocation (`:2143-2217, 3018-3049, 569-640, 2102-2138`) |
| `lib/core/sandbox_pkg.dart` | Disable network package install in the Play flavor | Dynamic-code policy (§3) |
| `tool/release_inventory.py` / `.github/workflows/build.yml` | Keep API 36 floor; ensure production builds the bundled-only flavor | Gate already correct (`:318-322`, `build.yml:186`) |
| Outer prebuilts (`libflutter.so`, `libsqlite3.so`, `libdatastore_shared_counter.so`) | Upgrade to 16 KB-RELRO builds (NDK r28+/AGP) | Triage §5b.1 |

---

## 8. Acceptance plan

### 8.1 S0 — decisive exec spike (do this first; cheap)

Purpose: settle H1/H2/H3 and the exec model before any migration.

Build a throwaway target-36 flavor that contains:

- `libprobe_bionic.so` — a small bionic PIE executable renamed to `lib*.so`.
- `libprobe_static.so` — a statically linked probe (to reproduce the
  "Bad system call" glibc/static case noted by u1f383).
- A versioned-name probe (`libz.so.1`-style) to test H2 extraction/resolution.
- A JNI `dlopen` probe and (optional) a memfd + `execveat` probe.

Instrumentation test records, per device: whether each probe executes from
`nativeLibraryDir`; whether an identical copy in `filesDir` fails; the
`/proc/self/attr/current` SELinux context; logcat `avc: denied` lines;
`getconf PAGE_SIZE`. Matrix: API 29/30/33/34/35/36 (emulators + ≥1 real
device), arm64-v8a / armeabi-v7a / x86_64.

**Pass criteria:** at least one *bionic* ELF executes from
`nativeLibraryDir` with exit 0 on every tested API >= 29, while the
`filesDir` copy fails with EACCES, and the SELinux context is
`untrusted_app`. If all probes fail (H1 disproved), stop Option B and switch
to Option F/C.

### 8.2 S1–S5 — migration (only if S0 passes)

1. **S1 packaging:** generate the jniLibs tree + manifest from the pinned
   bootstrap; validate extraction on device (count, names, `getconf` ABI).
2. **S2 exec relocation:** move `exec()`/`_sandboxEnv()` to
   `nativeLibraryDir`; writable state stays in app data; run the full
   Studio/terminal/MCP flows.
3. **S3 bundling:** ship node/python/git/gh as jniLibs; remove Play-flavor
   downloads; re-run MCP `npx`/`uvx` and `git clone/push`.
4. **S4 16 KB:** rebuild/re-pin the payload and outer prebuilts; production
   gate must report zero alignment errors.
5. **S5 release:** build signed APK/AAB with `--mode production
   --expected-target 36`; install delivered splits on the device matrix;
   upload to the Play internal track and run the pre-launch report.

### 8.3 Test/verification commands

- `flutter analyze` → 0 issues.
- `flutter test` → green (existing seams: `sandboxEnvForTest()`
  `sandbox_service.dart:2700`, `resetCheckExistingForTest()` `:562-567`,
  `processStartForTest` `:2450-2457`; suites `test/studio_first_open_test.dart`,
  `test/mcp_runtime_gate_test.dart`, `test/native_plugins_sandbox_test.dart`).
- New Dart tests asserting: resolved exec path is under `nativeLibraryDir`;
  no app-data exec path remains; `LD_PRELOAD`/`LD_LIBRARY_PATH` point at
  `nativeLibraryDir`; missing-lib error is a permanent
  `SandboxUnsupportedException`.
- `./gradlew :app:testDebugUnitTest` + the S0 instrumentation test.
- `python3 tool/release_inventory.py <apk|aab> --mode production
  --expected-target 36 --certificate-sha256 <pinned>` → `passed: true`,
  0 alignment errors (`release_inventory.py:299-322, 346`).
- Play internal-track install + pre-launch report; `play_qualified` remains
  `false` until console evidence exists (`:320`).

### 8.4 Explicit non-goals of the acceptance

A green local gate does not establish device execution, split delivery, 16 KB
runtime behavior, or Play qualification (triage §6; `release_inventory.py:284`).
Those require the device matrix and Play console evidence.

---

## 9. Hypotheses register

| ID | Hypothesis | Status | How resolved |
|---|---|---|---|
| H1 | A bionic ELF named `lib*.so` executes from `nativeLibraryDir` under target 36 | **Unproven / contested** | S0 on API 29–36, arm64/x86_64/arm |
| H2 | Versioned SONAME libs survive extraction and resolve via `DT_NEEDED`/`LD_LIBRARY_PATH` in the read-only dir | **Unproven** | S0/S1; else patch SONAMEs or add a loader |
| H3 | `LD_LIBRARY_PATH`/`LD_PRELOAD` into `nativeLibraryDir` work, including termux-exec rewrite | **Unproven** | S0/S2 |
| H4 | A 16 KB-RELRO rebuild/re-pin of the Termux payload exists | **Unproven** | S4; check upstream releases / relink |
| H5 | A symlink farm + rewritten shebangs in writable app data can point into `nativeLibraryDir` | **Unproven** | S1/S2 |
| H6 | Play's scanner accepts non-ELF files named `lib*.so` | **Unproven** | Play internal track + pre-launch |
| H7 | `extractNativeLibs=true` + AAB split delivery preserves the payload per ABI | **Unproven** | S1/S5 with bundletool |
| H8 | WASM/embedded-CPython covers the app's Python/JS tool needs without native wheels | **Unproven** | Option C spike (only if B fails) |
| H9 | A user-mode loader could substitute for `execve` for a full multi-process shell | **Unproven / likely no** | literature + S0 optional probe |
| H10 | Play would grant a developer-tool exemption | **Unproven / no documented basis** | Play console; not planned around |
| H11 | Some OEM ROMs allow app-data exec under target 36 | **Unproven** | existing `isDataExecAllowed` probe |

---

## 10. Risks, open decisions, out of scope

**Risks.**
- H1 may be false on some OEM/SELinux policies even if true on Pixel/emulator;
  mitigation: S0 across a real-device matrix, plus Option F fallback.
- Repackaging a full userland into `jniLibs` is a large, error-prone change
  (hundreds of binaries/libs, SONAMEs, symlinks, shebangs).
- Play scanner behavior on the packaged payload is unknown until submission.
- Bundling runtimes changes app size and the lazy-install UX.
- The product's core premise (an agent that runs user-fetched code) remains a
  policy risk even after the platform fix, because interpreted code loaded at
  run time "must not allow potential violations" (§3).

**Open decisions (require the owner).**
1. Is Ovid a Play product, or does it remain sideload/F-Droid? (The master
   audit sets Play production as the goal, so this design assumes Play.)
2. If H1 fails: is Option F (server-side execution) acceptable, or is Option
   C (reduced capability) preferred?
3. How much of the runtime must be bundled vs. delivered via Play Asset
   Delivery?
4. Is a non-Play "power" flavor (keeping target 28 + downloads) acceptable in
   parallel with the Play flavor?

**Out of scope.** Firebase/provider console work; release signing execution;
16 KB device hardware procurement; billing; accessibility/Control policy
(referenced in the master audit, not solved here).

---

## 11. Relationship to the concurrent 2026-10-06 bootstrap audit

A parallel read-only audit, [`2026-10-06-native-bootstrap-runtime.md`](../audits/2026-10-06-native-bootstrap-runtime.md),
independently reached the same platform conclusion and is complementary. To
avoid label confusion, the mapping is:

| This design | Concurrent audit |
|---|---|
| Option A (noexec workaround — rejected) | (not proposed) |
| Option B (immutable packaged runtime, primary) | its Option B "partial" + Option C "full immutable packaged-code" combined |
| Option C (in-process interpreters) | (not proposed) |
| Option D (proot — not standalone) | its Option E "proot-mediated execution" (research) |
| (not proposed) | its Option D "userspace ELF loader / anonymous-mmap exec" (research) |
| Option F (server-side execution) | its Option F "sideload-only / Play companion" (different fallback) |

Two points of reconciliation:

- The concurrent audit labels its "Option C (full immutable packaged-code)"
  as the only target-36 path that preserves node/python/git; this design
  agrees and calls that same architecture **Option B** (bundled runtimes in
  `jniLibs`). The naming differs, the substance does not.
- The concurrent audit states 32-bit arm32 ELFs also fail RELRO alignment
  (80/102). The authoritative gate (`2026-10-06-release-inventory-triage.md`
  §1, `release_inventory.py:65-70`) computes alignment only for
  `ELFCLASS64`, so `armeabi-v7a` contributes **0** gate findings and is
  **32-bit inventory only**. This design follows the gate: only arm64/x86_64
  alignment is Play-blocking, though 16 KB runtime behavior on 32-bit is not
  independently verified.

This design adds to the concurrent audit: the dated Play target-36 and
dynamic-code policy analysis (§1, §3), the H1 exec-viability conflict
(§2), the in-process interpreter and server-side fallbacks (§5), and the
decisive S0 spike + full acceptance plan (§8).

## 12. Evidence appendix

**Repository anchors (read this spike).**
- `android/app/build.gradle.kts:94-127` — ZIP-in-.so payload, target 28 hold,
  lint disable.
- `android/app/src/main/AndroidManifest.xml` — no `extractNativeLibs`.
- `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt:37-72,
  528-541, 643-653, 1389-1458` — payload read, `processAbi`,
  `nativeLibraryDir`, `isDataExecAllowed` probe.
- `lib/core/sandbox_service.dart:21-47, 87-110, 569-640, 750-1044,
  1050-1232, 2143-2217, 2748-2832, 3018-3096, 3506-3560, 3686-3827` —
  install, exec, env, downloads.
- `lib/core/sandbox_pkg.dart:112-260` — curl+dpkg network installer.
- `tool/bootstrap_supply.py:18-22` — pinned Termux assets; `PINS`.
- `tool/release_inventory.py:279-322, 346` — mode semantics, API 36 floor,
  16 KB enforcement.
- `.github/workflows/build.yml:173-190` — production `target=36` gate.

**External sources (fetched 2026-10-06).**
- Play target API requirements: <https://support.google.com/googleplay/android-developer/answer/11926878>
  — API 36 required 2026-08-31; extension to 2026-11-01.
- Device and Network Abuse: <https://support.google.com/googleplay/android-developer/answer/9888379>
  — downloaded executable code prohibited; interpreter/VM exception.
- Android 10 behavior change: <https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission>
  — app-home exec/W^X (page dated 2026-10-01; direct fetch timed out, text
  quoted via the Termux wiki and search result snippets).
- Termux and Android 10 wiki: <https://github.com/termux/termux-packages/wiki/Termux-and-Android-10>.
- Running native executables via jniLibs (2026-06-13): <https://chaosgoo.com/en/android-run-executable-binary-bypass/>.
- jniLibs execution tested on Android 16 / Pixel 8a (2025-06-15): <https://u1f383.github.io/android/2025/06/15/run-native-binary-on-android.html>.
- Contradicting report, target-35 host build: <https://github.com/shiaho777/web-to-app/issues/795> (2026-09-06).
- AOSP `untrusted_app_29.te`: <https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/untrusted_app_29.te>.
- CPython WASI: <https://github.com/python/cpython/blob/main/Platforms/WASI/README.md>.

**Repository documents this design must not contradict.**
- `2026-10-06-release-inventory-triage.md` §5a.1, §5b — the immutable
  packaged-code architecture and 16 KB rebuild are prerequisites.
- `2026-10-06-remaining-closure.md` A3.2 — W16.04 architecture-blocked.
- `ENGINEERING_AUDIT.md` P0-3 — jniLibs relocation is "the only real path".
