# Signed x86_64 sideload release

This runbook covers the reproducible **sideload** APK inputs and inspection
tooling. It does not claim Play qualification, an emulator pass, or a signed
artifact until the commands below have actually completed successfully.

## Inputs and safety gates

Run from the Flutter repository root. The release lane requires:

- Flutter on `PATH`, Java, Git, and Android build-tools 36.0.0 (`aapt2`,
  `apksigner`, and `zipalign`).
- `ANDROID_SIGNING_CERT_SHA256` set to the release certificate's 64-hex
  SHA-256 fingerprint. This is a certificate fingerprint, not a keystore
  password.
- These operator-supplied files, all ignored by Git and all exactly mode
  `0600`:
  - `android/release-keystore.jks`
  - `android/keystore.properties`
  - `android/app/google-services.json`

Never copy these files into an evidence directory or print their contents.
To correct metadata only:

```bash
chmod 600 android/release-keystore.jks android/keystore.properties \
  android/app/google-services.json
```

Restore the generated Gradle launcher files from a trusted original checkout.
The helper validates the JAR ZIP structure and hashes, preserves source modes,
and refuses to overwrite different destination bytes:

```bash
export OVID_ORIGINAL_WORKTREE=/path/to/read-only/original-checkout
bash tool/restore_release_wrapper.sh
python3 tool/release_input_hygiene.py verify \
  --original "$OVID_ORIGINAL_WORKTREE" --destination .
```

A missing original wrapper or a hash/ZIP mismatch is a blocker. Do not delete a
conflicting local wrapper to bypass the refusal. Ignore certification uses
`git check-ignore --no-index`, including Git's escaping, negation, directory,
and nested-rule behavior; if that authoritative check is unavailable, input
verification fails closed.

## Build and inspect (separate acceptance gate)

Choose a **fresh** APK path and a **fresh, non-existent evidence directory**.
The script refuses existing files, directories, and symlinks for evidence;
inventory evidence files are also created exclusively without following
symlinks. After any failed attempt, choose another fresh evidence path rather
than reusing the old one. Then run:

```bash
tool/release_sideload.sh \
  --apk-out /absolute/fresh/output/app-release.apk \
  --evidence-out /absolute/evidence/directory
```

The script performs these steps in order:

1. Reject nonempty inherited demo, login-bypass, Play-build, and RevenueCat Test
   Store inputs, and require App Check off plus production mode. Force the
   alternate Gradle `ovid.play` property off with `-Povid.play=false` for
   signing validation and the higher-priority JVM project property
   `-Dorg.gradle.project.ovid.play=false` for Flutter's internal Gradle build;
   these override inherited environment and `GRADLE_USER_HOME` properties.
   The restored `gradlew` evaluates JVM option strings, so both signing and
   Flutter invocations replace inherited `JAVA_OPTS` and `GRADLE_OPTS` with
   fixed values; untrusted option text is never appended or evaluated by the
   release script.
2. Verify wrapper structure and secret ignore/mode metadata without reading
   credential payloads.
3. Run `:app:validateProductionReleaseSigning`, which proves possession of the
   private key and matches its valid, non-debug certificate to `certSha256`.
4. Run only this build command:

   ```bash
   flutter build apk --release --target-platform android-x64 --dart-define=OVID_APPCHECK=false --dart-define=OVID_PRODUCTION=true
   ```

   The Android `release` variant is minified and targets API 36. The command
   accepts no additional build defines.
5. Reject a missing or disguised non-APK output, then inspect it with
   `release_inventory.py --mode production --profile sideload
   --expected-target 36 --expected-abis x86_64`. The production inventory gate
   requires the pinned signer, exact ABI/target/package contract,
   non-debuggable manifest, 16 KB native alignment, and ZIP alignment. It also
   rejects the actual Play-only manifest marker in a sideload artifact instead
   of trusting the requested `--profile` alone.

Evidence is written to:

- `release-inputs.json`: wrapper hashes plus secret ignore/mode metadata only.
- `release-inventory.json`: final APK path, size, SHA-256, verified signer,
  source commit (`source_revision`), fixed `build_command`, manifest/native
  inspection, and the real `passed` result.

A failed inventory gate is not a releasable artifact. The tooling-slice change
does **not** run this signed build; its successful artifact remains a later
acceptance gate.

## Emulator acceptance (after a passing build)

Use a fresh x86_64 API 36 emulator and the exact inspected APK. Record the
emulator image/API/ABI, APK SHA-256, install/update result, and signer again on
the delivered file. At minimum:

1. Install with `adb install`, launch, and confirm the package is not
   debuggable.
2. Repeat installation with `adb install -r` to check update continuity; a
   signer mismatch or downgrade is a failure.
3. Exercise real sign-in and a cloud request with App Check off. No debug App
   Check provider, demo billing, login bypass, Play manifest profile, or Test
   Store configuration is acceptable.
4. Check a production backend flow and the Android log for release-only
   crashes or attestation/store fallbacks.

These device steps, like the actual signed build and private-key validation,
are **not established by static/tooling tests alone**. No Play Console action
is part of this sideload gate.
