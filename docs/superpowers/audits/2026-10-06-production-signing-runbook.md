# Production signing runbook — 2026-10-06

**Scope:** How to enable and trigger the manual production release path in
`.github/workflows/build.yml`, what the API 36 gate requires, and the current
blocker. Documentation only. No workflow edits. No secret values appear here.

**Repository:** `aasheesh333/OvidAI` (default branch `main`).
**Workflow:** `.github/workflows/build.yml` — `Validate and Build Android`.

## 1. Two release paths (do not conflate)

| Path | Trigger | Signer | targetSdk gate | cert SHA source |
|---|---|---|---|---|
| Release candidate | push to `main` / `ci/verified-android-build-20260827` / `hoplite/**`, when `ANDROID_KEYSTORE_BASE64` exists | non-debug release keystore | 28 (`build.yml:186`) | computed on the runner from the keystore (`build.yml:149-156`) |
| Production | manual `workflow_dispatch` with `production_release=true` | pinned release keystore | **36** (`build.yml:186`) | repo variable `vars.ANDROID_SIGNING_CERT_SHA256` (`build.yml:72`, `build.yml:184`) |

The push/release-candidate path never needs the repo variable: it derives the
fingerprint with `keytool` and exports it (`build.yml:149-156`). Only the
production path reads `vars.ANDROID_SIGNING_CERT_SHA256` and fails when it is
empty (`tool/release_prepare.py:13-17`).

## 2. Required GitHub secrets/variables vs. what exists

Checked with `gh secret list`, `gh variable list`, and `gh secret/variable list
--env Preview|Production` on 2026-10-06.

### Secrets (repo scope) — all present

| Name | Consumed by | Present |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | `KEYSTORE_B64` (`build.yml:68`) | yes |
| `ANDROID_KEYSTORE_PASSWORD` | `KEYSTORE_PASSWORD` (`build.yml:69`) | yes |
| `ANDROID_KEY_ALIAS` | `KEY_ALIAS` (`build.yml:70`) | yes |
| `ANDROID_KEY_PASSWORD` | `KEY_PASSWORD` (`build.yml:71`) | yes |
| `GOOGLE_SERVICES_JSON` | `GOOGLE_SERVICES` (`build.yml:73`) | yes |

### Variables

| Name | Scope required | Consumed by | Present |
|---|---|---|---|
| `ANDROID_SIGNING_CERT_SHA256` | **repository** | `build.yml:72`, `build.yml:184` | **NO — missing** |

Observed `gh variable list` (repo) → `[]`. Observed `gh variable list --env
Preview` → `[]` and `--env Production` → `[]`. The `build` job has no
`environment:` key, so an environment-scoped variable would **not** be visible;
this must be set at **repository** scope.

## 3. Set `ANDROID_SIGNING_CERT_SHA256` (repository variable)

The value is the SHA-256 of the **release signing certificate** (DER encoding),
64 lowercase hex characters, colons optional. This is exactly what
`validateProductionSigning()` computes at `android/app/build.gradle.kts:46-49`
and what `tool/release_prepare.py:18-20` accepts (`[0-9a-f]{64}` after stripping
colons and lowercasing).

### Compute it from the keystore (preferred)

```bash
export KEY_ALIAS='<alias>'
export KEYSTORE_PASSWORD='<store password>'
keytool -list -v -keystore android/release-keystore.jks -alias "$KEY_ALIAS" \
  -storepass "$KEYSTORE_PASSWORD" \
  | sed -n 's/.*SHA256: *//p' | head -n1 | tr -d ':' | tr '[:upper:]' '[:lower:]'
```

`keytool -list` needs only the store password (not the key password) to read
certificate metadata. This is the same derivation the push path uses
(`build.yml:149-150`).

### Compute it from an already signed APK (cross-check)

```bash
"$ANDROID_HOME"/build-tools/36.0.0/apksigner verify --print-certs app-release.apk \
  | sed -n 's/.*certificate SHA-256 digest: *//p' | head -n1 \
  | tr -d ':' | tr '[:upper:]' '[:lower:]'
```

Both must print the same 64-hex value. If they differ, the wrong alias/keystore
was used.

### Set the variable

```bash
gh variable set ANDROID_SIGNING_CERT_SHA256 --repo aasheesh333/OvidAI --body '<64-hex>'
```

Confirm:

```bash
gh variable list --repo aasheesh333/OvidAI
```

## 4. Trigger the production release

`workflow_dispatch` has a boolean input `production_release` (default `false`,
`build.yml:10-15`). It is not branch-filtered, but the workflow file must exist
on the ref you dispatch; use `main`.

```bash
gh workflow run "Validate and Build Android" \
  --repo aasheesh333/OvidAI \
  --ref main \
  -f production_release=true
```

Watch it:

```bash
gh run list --repo aasheesh333/OvidAI --workflow "Validate and Build Android" --limit 5
gh run watch --repo aasheesh333/OvidAI <run-id>
```

What the production dispatch does, in order (`build.yml`):

1. `Prepare release signing` (`build.yml:65-74`) runs `tool/release_prepare.py`
   with `ANDROID_SIGNING_CERT_SHA256: ${{ vars.ANDROID_SIGNING_CERT_SHA256 }}`,
   writing `android/release-keystore.jks`, `android/keystore.properties`, and
   `android/app/google-services.json`. It refuses on missing/blank inputs,
   malformed digest, invalid keystore/Firebase JSON, or pre-existing
   destination files (`tool/release_prepare.py:12-31,63-66`).
2. `Validate production key before release compilation` (`build.yml:168-171`)
   runs `./gradlew :app:validateProductionReleaseSigning` (`build.gradle.kts:74-78`).
3. `Build signed release APK + AAB` (`build.yml:173-177`).
4. `Gate release artifacts` (`build.yml:181-190`) runs `tool/release_inventory.py`
   with `--mode production --expected-target 36` on both the APK and AAB.
5. Credentials are removed with `if: always()` (`build.yml:221-223`).

### What `validateProductionSigning()` enforces (`android/app/build.gradle.kts:26-65`)

- readable `android/keystore.properties` (debug signing is never a release fallback);
- non-blank `storeFile`, `storePassword`, `keyAlias`, `keyPassword`, `certSha256`;
- configured keystore file exists;
- key loads as a `PrivateKey` and cert is an `X509Certificate` and currently valid;
- subject is **not** `CN=Android Debug` and alias is **not** `androiddebugkey`;
- certificate SHA-256 equals `certSha256` (colons stripped, lowercased);
- a sign/verify challenge succeeds with the resolved algorithm
  (`SHA256withRSA` / `SHA256withECDSA` / `SHA256withDSA`).

It also runs automatically whenever any task whose name contains `Release` is in
the task graph (`build.gradle.kts:69-73`).

## 5. API 36 gate requirements

The production gate is `tool/release_inventory.py --mode production
--expected-target 36` (`build.yml:186,188-189`). In production mode it enforces:

- **targetSdk ≥ 36** — `api36_floor_met`; the `--expected-target` contract cannot
  lower it (`release_inventory.py:318-322`). A mismatch against the explicit
  package/minSdk/targetSdk contract also errors (`release_inventory.py:313-314`).
- **Package** `com.dhanuk.ovidai` and **minSdk** 23 (`release_inventory.py:313`).
- **Non-debuggable** manifest (`release_inventory.py:315-316`).
- **Pinned signer** — `ANDROID_SIGNING_CERT_SHA256` must be present/valid and the
  artifact's signer set must equal exactly that digest; a debug certificate is
  forbidden (`release_inventory.py:150-163,324-329`).
- **16 KB LOAD/RELRO alignment** of 64-bit native ELFs, including nested ELFs
  inside `libovid_bootstrap.so` (`release_inventory.py:64-74,299-300`).
- **APK ZIP alignment** via `zipalign -c -P 16 4` (`release_inventory.py:336-343`).
- Full native inventory: ABI set `arm64-v8a,armeabi-v7a,x86_64`, valid bootstrap
  ZIP and outer ELF and `libflutter.so` per ABI (`release_inventory.py:137-147`).

Note (`release_inventory.py:10-13,284`): these are static inventory checks only;
none of them establishes device or Google Play qualification. AAB ZIP alignment
is reported as not applicable (`release_inventory.py:311`).

## 6. Current blocker

**Production cannot pass today. Two independent blockers:**

1. **Missing repository variable `ANDROID_SIGNING_CERT_SHA256`.** Without it,
   `Prepare release signing` fails at `tool/release_prepare.py:15-17` and the
   production gate errors "required production certificate SHA-256 is
   absent/invalid" (`release_inventory.py:324-325`). Fix: §3.

2. **`targetSdk = 28`** (`android/app/build.gradle.kts:119`), but production
   requires target ≥ 36 (`release_inventory.py:318-322`; `build.yml:186`). This
   is a deliberate, documented hold, not an oversight: the native sandbox execs
   bash/python/node from the app data dir, and Android 10+ blocks exec/exec-mmap
   of app-data files for apps targeting API 29+ (SELinux `neverallow` on
   `app_data_file`), so the sandbox dies with `EACCES` (`build.gradle.kts:111-118`).
   `ExpiredTargetSdkVersion` lint is disabled for the target-28 build
   (`build.gradle.kts:121-127`). A target-only bump cannot qualify runtime
   behavior, downloaded code, or distribution; the immutable packaged-code
   architecture must be implemented and measured from the app process first.
   Setting the variable in §3 removes blocker 1 but **not** blocker 2; production
   still fails the API 36 gate until the targetSdk work lands.

## 7. Verification evidence (2026-10-06)

- `python3 -m unittest discover -s tool -p 'release_*test.py'` → `Ran 32 tests`,
  `OK`. This includes `tool/release_workflow_test.py`, which pins the API 36 gate
  (`target=36`), the target-28 candidate gate, and that the push release path
  does not require `production_release`.
- `gh secret list` → the five secrets in §2 are present.
- `gh variable list` (repo, and `--env Preview` / `--env Production`) → `[]`;
  `ANDROID_SIGNING_CERT_SHA256` is absent.

## 8. Minimal operator checklist

1. Set the repo variable with the value from §3.
2. Land the targetSdk 36 / packaged-code architecture change (blocker 2).
3. Dispatch: `gh workflow run "Validate and Build Android" --ref main -f production_release=true`.
4. Confirm `tool/release_inventory.py` reports `"passed": true` for both APK and
   AAB in the `Ovid-release-evidence` artifact.

No workflow edits and no secret values are part of this runbook.
