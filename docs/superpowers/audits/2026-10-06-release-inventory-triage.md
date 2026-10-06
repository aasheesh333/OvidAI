# 2026-10-06 — Native 16 KB alignment/RELRO triage (the 158 findings)

Scope: read-only triage of the 158 native alignment findings produced by
`tool/release_inventory.py`. No source, workflow, or artifact was modified. This
document owns only itself; it does not change any gate.

Related: [production signing runbook](2026-10-06-production-signing-runbook.md)
(signing and target-36 blockers), [wave2 release report](../../../.superpowers/sdd/2026-10-03-ovid-master-repair-plan/wave2-release-report.md)
(original 158 discovery), [master audit](2026-10-03-ovid-master-audit.md)
(policy reconciliation).

## 0. Reproduction (exact)

Artifact: `build/app/outputs/flutter-apk/app-release.apk`
(universal, mtime 2026-09-18, SHA-256
`b9a758fe3d65c45e5a7e492cb6fe6d34f55af21c481936e1261011cd503fadfd`, 115,854,915
bytes, package `com.dhanuk.ovidai`, minSdk 23, targetSdk 28, non-debuggable,
**Android Debug signer**).

```
python3 tool/release_inventory.py build/app/outputs/flutter-apk/app-release.apk \
  --mode debug --expected-target 28 --output /tmp/opencode/triage-debug.json
# passed: true, errors: 0, alignment_findings: 158

python3 tool/release_inventory.py build/app/outputs/flutter-apk/app-release.apk \
  --mode production --expected-target 28 \
  --certificate-sha256 8bca7dd58db032573d9a9f430605729f42659aa6174696ecd14e08dc65b081a3 \
  --output /tmp/opencode/triage-prod.json
# passed: false, errors: 160
```

The production run reports **160** errors = 158 alignment + 1 signing
(`debug certificate is forbidden for production`) + 1 API 36 floor
(`production requires target API 36 or newer`). The wave2 report recorded 159;
the extra API 36 floor error is a later code addition. **The 158 count is
unchanged and is the subject of this triage.**

Note: this artifact is the 2026-09-18 debug-signed target-28 universal APK, not a
build of current `HEAD` (`0171ea9`). The findings are real for that artifact.

## 1. The 158 findings, exactly

- **One reason only:** every finding is `GNU_RELRO end is not 16 KB aligned`.
  **Zero PT_LOAD failures.** The tool checks both independently
  (`release_inventory.py:64-70`); only the RELRO end criterion fails. RELRO end
  remainder is `(p_vaddr + p_memsz) % 16384` (`release_inventory.py:61`).
- **By ABI:** `arm64-v8a` 81, `x86_64` 77, `armeabi-v7a` 0. 32-bit ELFs never
  produce alignment errors; `elf_inventory` only computes them for `ELFCLASS64`
  (`release_inventory.py:65-70`), and `alignment_scope` for 32-bit is
  `"32-bit inventory only"` (`release_inventory.py:73`).
- **By container:** 5 findings are in outer real ELFs; 153 are nested ELFs inside
  the `libovid_bootstrap.so` ZIP payloads. 5 + 153 = 158.

### 1a. Outer real-ELF findings (5)

Files stored directly under `lib/<abi>/` that really are ELF:

| Path | RELRO end remainder |
|---|---:|
| `lib/arm64-v8a/libflutter.so` | 12288 |
| `lib/arm64-v8a/libsqlite3.so` | 4096 |
| `lib/arm64-v8a/libdatastore_shared_counter.so` | 8192 |
| `lib/x86_64/libsqlite3.so` | 12288 |
| `lib/x86_64/libdatastore_shared_counter.so` | 8192 |

`lib/arm64-v8a/libapp.so`, `lib/arm64-v8a/libdartjni.so`, and
`lib/x86_64/libflutter.so` are clean (RELRO remainder 0). The ARM64/x86_64
asymmetry for `libflutter.so` is real.

### 1b. Bootstrap ZIP payload findings (153)

`libovid_bootstrap.so` is **not an ELF**. It is a ZIP archive of the Termux
userland shipped with an `.so` name so AGP packages it into `jniLibs`
(`android/app/build.gradle.kts:94-104`). Each of the three archives contains
**102 real ELFs** (`elf_count=102` per ABI, 306 total; 204 are 64-bit). The tool
descends into the ZIP and parses each nested ELF
(`release_inventory.py:111-127`).

- `arm64-v8a`: 78 of 102 nested ELFs fail (78 distinct members).
- `x86_64`: 75 of 102 nested ELFs fail (75 distinct members).
- `armeabi-v7a`: 0 (32-bit inventory only).

Composition of the failing members:

| ABI | `bin/` executables | `lib/apt/methods/` helpers | `lib/*.so` shared libs | total |
|---|---:|---:|---:|---:|
| `arm64-v8a` | 21 | 6 | 51 | 78 |
| `x86_64` | 22 | 5 | 48 | 75 |

The payload is the Termux base system: `bash`, `apt`/`dpkg` tooling, `curl`,
`tar`, `gzip`/`xz`/`zstd`, `find`/`coreutils`/`grep`/`less`, and shared
libraries such as `libcrypto.so.3`, `libssl.so.3`, `libgnutls.so`,
`libapt-pkg.so`, `libreadline.so.8.3`, `libncursesw.so.6.5`, and the
`libtermux-exec-*.so` preloads. Full member list in Appendix A.

## 2. Why: ZIP-in-.so payload vs real ELF

These are two different problems with different owners and different fixes.

1. **Outer real ELFs (5 findings).** Genuine 64-bit shared objects built by
   third parties / toolchains: the Flutter engine (`libflutter.so`), SQLite
   (`libsqlite3.so`), and the DataStore counter (`libdatastore_shared_counter.so`).
   Their PT_LOAD alignment already passes; only the GNU_RELRO segment end is not
   a multiple of 16384. Fixing requires rebuilding/upgrading each prebuilt with a
   linker that emits 16 KB-aligned RELRO (NDK r28+ / AGP 8.5.1+ class of
   toolchains). This is not something the current AGP/NDK can retrofit into
   prebuilt inputs.

2. **Bootstrap ZIP payload (153 findings).** The outer container is legitimately a
   ZIP, not a disguised ELF. The failing objects are the genuine ELFs *inside*
   it. They come from a pinned upstream `termux-packages` bootstrap release
   (`tool/bootstrap_supply.py:18-22` `PINS`/`BASE`) and are re-derived into
   `libovid_bootstrap.so` by `tool/prepare_bootstrap.sh`. Their RELRO end
   alignment was determined by however Termux built that release. Fixing
   requires an upstream/bootstrap rebuild with 16 KB-aligned RELRO and a re-pin
   of `PINS` size/sha256, then regeneration.

Because the container is a ZIP, a native-lib scanner that only parses files
matching `lib/**/*.so` as ELF will not see the 153 nested failures. **This
repo's gate is stricter than a naive scan**: it opens the ZIP and checks the
nested ELFs (`release_inventory.py:111-127`). Whether Google Play's automated
16 KB scan descends into a ZIP-in-`.so` payload is **not established by this
audit** and is listed under unverified (§6).

## 3. Play-blocking vs sideload-only

### Sideload-only: not blocked today

Under `--mode release` (the push release-candidate path; `build.yml:186` uses
`mode=release, target=28`) and `--mode debug`, alignment findings are **recorded
but never added to `report['errors']`**:

- `release_inventory.py:299-305`: production folds `native['alignment_errors']`
  into errors; debug/release only set `alignment_scope` and keep the findings in
  `report['native']['alignment_errors']`.
- ZIP alignment is likewise recorded, not enforced, outside production
  (`release_inventory.py:336-343`).

Therefore the current target-28 sideload candidate passes its gate **with all
158 findings present**. This matches the reproduction: debug mode
`passed: true`, 0 errors, 158 alignment findings; and the release-candidate mode
is tested to accept target 28 (`release_inventory_test.py:208-216`).

Runtime caveat (not gate): on the 4 KB-page devices that dominate today these
have no effect. On a 16 KB-page device, an executed/dlopen'd nested Termux ELF
with a misaligned RELRO end can fail to load. **No device execution was
performed**, so this is a risk, not an observed failure.

### Play-blocking: every one of the 158

Under `--mode production`, `release_inventory.py:299-300` adds **all**
`alignment_errors` to `report['errors']`, and `passed` is `not errors`
(`release_inventory.py:346`). The gate is binary: a single misaligned 64-bit ELF
fails it. So for a production/API 36 artifact:

- The **5 outer findings** are unambiguously in scope for Play's own 64-bit
  native-lib 16 KB alignment check.
- The **153 nested findings** are in scope for *this repo's* production gate
  because the gate descends into the bootstrap ZIP. Their status under Play's
  scanner specifically is unverified (§6). They are nonetheless gate-blocking
  and are the bulk (96.8%) of the work.
- `armeabi-v7a` contributes 0 findings and is not part of the 64-bit page-size
  requirement.

## 4. Current mode semantics (from the code)

All modes share: APK/AAB only (`release_inventory.py:287-288`); SHA-256/size;
native structural checks (per-ABI ELF class/machine, bootstrap is a ZIP with
>=1 ELF, outer libs are real ELF, `libflutter.so` present per ABI, ABI set equals
expected — `release_inventory.py:92-147`); manifest `package == com.dhanuk.ovidai`,
`minSdk == --expected-min` (default 23), `targetSdk == --expected-target`
(`release_inventory.py:313-314`); signer inspection (APK via `apksigner`, AAB via
`release_verify_bundle.java`).

| Check | debug | release (candidate) | production |
|---|---|---|---|
| Artifact debuggable | allowed | **forbidden** | **forbidden** |
| Signer present | required (>=1 verified cert) | required, non-debug | required, non-debug, pinned |
| Debug cert `CN=Android Debug` | allowed | **forbidden** | **forbidden** |
| Pinned cert SHA-256 | ignored | enforced only if `--certificate-sha256` supplied | **required**, must equal signer set |
| targetSdk vs `--expected-target` | must equal | must equal | must equal |
| API 36 floor | no | no (28 allowed) | **yes**, `targetSdk >= 36` |
| 16 KB PT_LOAD/RELRO | recorded only | recorded only | **enforced** (all findings) |
| APK ZIP alignment (`zipalign -c -P 16 4`) | recorded only | recorded only | **enforced** |
| AAB ZIP alignment | n/a | n/a | n/a (reported N/A) |
| `target_policy.play_qualified` | always `false` | always `false` | always `false` |

Key code points: mode flags `production`/`release` (`release_inventory.py:279-281`);
debuggable enforcement `strict` (`:315-316`); signer logic
`check_apk_signer` (`:150-163`) and production pin requirement (`:324-329`);
API 36 floor (`:318-322`); alignment enforcement (`:299-300`); ZIP alignment
(`:336-343`). The workflow selects the mode/target automatically:
`if production_release: mode=production,target=36 else mode=release,target=28`
(`build.yml:186-189`); the debug inventory gate is `--mode debug --expected-target 28`
(`build.yml:110-111`).

`play_qualified` is hard-coded `False` in every mode (`release_inventory.py:320`)
and the docstring states none of the static checks establishes device or Play
qualification (`release_inventory.py:12-13,284`).

## 5. Exactly what must change to pass a production API 36 gate

The production gate currently fails on three independent groups. Fixing only the
158 is **not sufficient**.

### 5a. Blockers independent of the 158

1. **targetSdk 28 -> 36.** `android/app/build.gradle.kts:119` sets `targetSdk = 28`;
   production requires `targetSdk >= 36` (`release_inventory.py:318-322`). The
   workflow already requests 36 when `production_release=true` (`build.yml:186`),
   so the manifest must actually be 36. This is a **deliberate hold**: the native
   sandbox execs `bash`/`python`/`node` from the app data dir, and API 29+ blocks
   exec/exec-mmap of `app_data_file` (SELinux `neverallow`), so a target-only bump
   breaks the sandbox at runtime (`build.gradle.kts:111-118`). The immutable
   packaged-code architecture must be implemented and measured first; a target
   bump alone does not qualify runtime behavior.
2. **Production signing.** Today the artifact is debug-signed
   (`debug certificate is forbidden for production`). Requires real
   `keystore.properties` inputs and the pinned
   `ANDROID_SIGNING_CERT_SHA256` value (`release_inventory.py:324-329`). See the
   signing runbook.
3. **Manifest contract / ZIP alignment** already pass: package
   `com.dhanuk.ovidai`, minSdk 23, non-debuggable, `zipalign -c -P 16 4` exit 0.

### 5b. The 158 alignment findings

Every 64-bit ELF under `lib/arm64-v8a/` and `lib/x86_64/` must satisfy
`(p_vaddr + p_memsz) % 16384 == 0` for its `PT_GNUTERELRO` segment. PT_LOAD
alignment already passes for all of them. Concretely:

1. **Outer prebuilts (5).** Produce a 16 KB-RELRO `libflutter.so` for arm64 (use a
   Flutter engine built for 16 KB pages), and 16 KB-RELRO `libsqlite3.so` and
   `libdatastore_shared_counter.so` for arm64 and x86_64 (upgrade the providing
   plugin/NDK). Then rebuild the APK/AAB.
2. **Bootstrap payload (153).** Rebuild/re-pin the Termux bootstrap so its 78
   ARM64 + 75 x86_64 ELFs have 16 KB-aligned RELRO. The current source is the
   pinned prebuilt in `tool/bootstrap_supply.py:18-22`; update `PINS`
   size/sha256 to a 16 KB-aligned build (or relink the payload), regenerate with
   `tool/prepare_bootstrap.sh`, and confirm the gate's nested scan goes green.
3. **Re-run the gate.** `python3 tool/release_inventory.py ... --mode production
   --expected-target 36` must report `passed: true` (0 alignment errors) for both
   APK and AAB. Note AAB ZIP alignment is reported N/A; the alignment findings
   still apply to AAB because the nested scan is container-agnostic.
4. `keepDebugSymbols += "**/libovid_bootstrap.so"` (`build.gradle.kts:103`) is
   only there because the ZIP is not a valid object file; it does not affect
   alignment and needs no change.

No source change is proposed or made here; this is the required change set.

## 6. What remains unverified

- **No production-signed artifact exists.** All 158 observations are against the
  2026-09-18 debug-signed target-28 universal APK, not a build of current `HEAD`.
- **No 16 KB device/emulator run.** No load/exec of any failing ELF was
  performed; no `getconf PAGE_SIZE == 16384` runtime test. The failures are
  static checks against the documented criterion, not reproduced crashes.
- **No Play Console / internal-track / pre-launch evidence.** `play_qualified`
  is always `false` and is never asserted true.
- **Play's scanner behavior on ZIP-in-`.so` is unknown.** Only this repo's gate is
  known to descend into the bootstrap ZIP and count the 153 nested findings.
- **AAB / delivered splits.** No AAB for current HEAD was inspected, and no
  bundletool-delivered APK split set was generated or alignment-checked; AAB ZIP
  alignment is explicitly N/A (`release_inventory.py:311`).
- **libflutter.so asymmetry** (arm64 fails, x86_64 clean) is not independently
  explained beyond the observed remainders; the engine's own 16 KB status was not
  verified from its source/build.
- **CI has not exercised the production gate** with the current workflow; the last
  successful run used the old workflow (see wave2 report).

## Appendix A — failing bootstrap members

`arm64-v8a` (78):

```
bin/apt bin/apt-cache bin/apt-config bin/apt-mark bin/bash bin/bzip2
bin/coreutils bin/curl bin/dash bin/dpkg bin/dpkg-query bin/dpkg-split
bin/dpkg-trigger bin/find bin/gpgv bin/gzip bin/pkill bin/tar bin/xargs
bin/xz bin/zstd
lib/apt/methods/copy lib/apt/methods/file lib/apt/methods/gpgv
lib/apt/methods/http lib/apt/methods/rsh lib/apt/methods/store
lib/libacl.so lib/libandroid-glob.so lib/libandroid-posix-semaphore.so
lib/libapt-pkg.so lib/libapt-private.so lib/libassuan.so lib/libc++_shared.so
lib/libcap-ng.so lib/libcharset.so lib/libcrypto.so.3 lib/libcurl.so
lib/libdrop_ambient.so lib/libevent-2.1.so lib/libevent_core-2.1.so
lib/libevent_extra-2.1.so lib/libevent_pthreads-2.1.so lib/libffi.so
lib/libgcrypt.so lib/libgmp.so lib/libgnutls-dane.so lib/libgnutls.so
lib/libgnutlsxx.so lib/libgpg-error.so lib/libhistory.so.8.3
lib/libhogweed.so.6.11 lib/libidn2.so lib/liblsof.so lib/liblz4.so
lib/liblzma.so.5.8.3 lib/libmagic.so lib/libmd.so lib/libncursesw.so.6.5
lib/libnghttp2.so lib/libngtcp2.so lib/libngtcp2_crypto_ossl.so lib/libnpth.so
lib/libp11-kit.so lib/libpcre2-8.so lib/libpcre2-posix.so lib/libreadline.so.8.3
lib/libsmartcols.so lib/libssl.so.3 lib/libtasn1.so
lib/libtermux-core_nos_c_tre.so lib/libtermux-core_nos_cxx_tre.so
lib/libtermux-exec-direct-ld-preload.so lib/libtermux-exec-ld-preload.so
lib/libtermux-exec-linker-ld-preload.so lib/libtermux-exec_nos_c_tre.so
lib/libxxhash.so.0.8.3 lib/libz.so.1.3.2
```

`x86_64` (75):

```
bin/apt bin/apt-cache bin/apt-config bin/apt-mark bin/bash bin/bzip2 bin/curl
bin/dpkg-deb bin/dpkg-divert bin/dpkg-query bin/dpkg-split bin/dpkg-trigger
bin/find bin/gpgv bin/grep bin/gzip bin/less bin/pkill bin/tar bin/xargs bin/xz
bin/zstd
lib/apt/methods/copy lib/apt/methods/file lib/apt/methods/gpgv
lib/apt/methods/rsh lib/apt/methods/store
lib/libandroid-glob.so lib/libandroid-posix-semaphore.so lib/libapt-pkg.so
lib/libapt-private.so lib/libbz2.so.1.0.8 lib/libc++_shared.so lib/libcap-ng.so
lib/libcharset.so lib/libcrypto.so.3 lib/libdrop_ambient.so lib/libevent-2.1.so
lib/libevent_core-2.1.so lib/libevent_extra-2.1.so lib/libevent_pthreads-2.1.so
lib/libffi.so lib/libgmp.so lib/libgnutlsxx.so lib/libgpg-error.so
lib/libhistory.so.8.3 lib/libhogweed.so.6.11 lib/libiconv.so lib/libidn2.so
lib/liblsof.so lib/libmagic.so lib/libmd.so lib/libncursesw.so.6.5
lib/libnettle.so.8.11 lib/libnghttp2.so lib/libngtcp2.so
lib/libngtcp2_crypto_ossl.so lib/libnpth.so lib/libp11-kit.so lib/libpcre2-32.so
lib/libpcre2-8.so lib/libpcre2-posix.so lib/libprocps.so lib/libreadline.so.8.3
lib/libsmartcols.so lib/libssl.so.3 lib/libtermux-core_nos_cxx_tre.so
lib/libtermux-exec-direct-ld-preload.so lib/libtermux-exec-ld-preload.so
lib/libtermux-exec-linker-ld-preload.so lib/libtermux-exec_nos_c_tre.so
lib/libtirpc.so lib/libunistring.so lib/libxxhash.so.0.8.3 lib/libzstd.so.1.5.7
```

## Appendix B — evidence artifacts (outside the repo)

- `/tmp/opencode/triage-debug.json` — debug-mode inventory (passed, 158 recorded).
- `/tmp/opencode/triage-prod.json` — production-mode inventory (160 errors).
- `/tmp/opencode/triage_dump.json` — full parsed native inventory.
