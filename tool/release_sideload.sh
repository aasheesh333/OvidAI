#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: tool/release_sideload.sh --apk-out <path> --evidence-out <dir>\n' >&2
}

refuse() {
  printf 'Production sideload refused: %s\n' "$1" >&2
  exit 1
}

apk_out=''
evidence_out=''
while (($#)); do
  case "$1" in
    --apk-out)
      (($# >= 2)) || { usage; exit 2; }
      [[ -z "$apk_out" ]] || refuse '--apk-out supplied more than once'
      apk_out="$2"
      shift 2
      ;;
    --evidence-out)
      (($# >= 2)) || { usage; exit 2; }
      [[ -z "$evidence_out" ]] || refuse '--evidence-out supplied more than once'
      evidence_out="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
[[ -n "$apk_out" && -n "$evidence_out" ]] || { usage; exit 2; }
[[ "$apk_out" == *.apk ]] || refuse '--apk-out must end in .apk'
# Refuse existing paths (including dangling symlinks) before canonicalization.
[[ ! -e "$apk_out" && ! -L "$apk_out" ]] || refuse 'APK output already exists; choose a fresh path'
[[ ! -e "$evidence_out" && ! -L "$evidence_out" ]] || refuse 'evidence output must be a fresh path'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk_out="$(realpath -m -- "$apk_out")"
evidence_out="$(realpath -m -- "$evidence_out")"
[[ ! -e "$apk_out" && ! -L "$apk_out" ]] || refuse 'APK output already exists; choose a fresh path'
[[ ! -e "$evidence_out" && ! -L "$evidence_out" ]] || refuse 'evidence output must be a fresh path'
mkdir -p -- "$(dirname -- "$apk_out")" "$(dirname -- "$evidence_out")"
# Atomic creation prevents a pre-existing evidence directory/symlink from being
# reused; every subsequent evidence file starts within this fresh directory.
mkdir -- "$evidence_out"

cert="${ANDROID_SIGNING_CERT_SHA256:-}"
cert="${cert//:/}"
[[ "$cert" =~ ^[0-9A-Fa-f]{64}$ ]] || refuse 'ANDROID_SIGNING_CERT_SHA256 must pin a 64-hex certificate'
command -v flutter >/dev/null 2>&1 || refuse 'flutter is not on PATH'

# The restored launcher evaluates JVM option strings with eval. Never append to
# inherited text: use fixed values at both boundaries so comments, separators,
# substitutions, and earlier Play properties cannot reach that evaluation.
fixed_gradle_opts='-Dorg.gradle.project.ovid.play=false'
fixed_java_opts=''

# Metadata-only input checks happen before Gradle reads signing properties.
python3 "$ROOT/tool/release_input_hygiene.py" check-build-environment
python3 "$ROOT/tool/release_input_hygiene.py" verify --destination "$ROOT" \
  > "$evidence_out/release-inputs.json"

(
  cd "$ROOT/android"
  # Command-line project properties override inherited environment and
  # GRADLE_USER_HOME/gradle.properties values for this signing gate.
  env JAVA_OPTS="$fixed_java_opts" GRADLE_OPTS="$fixed_gradle_opts" \
    ORG_GRADLE_PROJECT_ovid.play=false \
    ./gradlew -Povid.play=false :app:validateProductionReleaseSigning --no-daemon
)

build_command=(
  flutter build apk --release
  --target-platform android-x64
  --dart-define=OVID_APPCHECK=false
  --dart-define=OVID_PRODUCTION=true
)
build_command_text='flutter build apk --release --target-platform android-x64 --dart-define=OVID_APPCHECK=false --dart-define=OVID_PRODUCTION=true'
(
  cd "$ROOT"
  # Flutter does not expose -P; its Gradle launcher receives only the fixed
  # JVM options plus the higher-priority environment project property.
  env JAVA_OPTS="$fixed_java_opts" GRADLE_OPTS="$fixed_gradle_opts" \
    ORG_GRADLE_PROJECT_ovid.play=false "${build_command[@]}"
)

apk_source="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
python3 "$ROOT/tool/release_input_hygiene.py" check-apk "$apk_source"
if [[ "$apk_source" != "$apk_out" ]]; then
  cp -- "$apk_source" "$apk_out"
fi
chmod 0644 -- "$apk_out"
artifact_created=true
cleanup_unapproved_artifact() {
  if [[ "$artifact_created" == true && "$apk_source" != "$apk_out" ]]; then
    rm -f -- "$apk_out"
  fi
}
trap cleanup_unapproved_artifact EXIT

source_commit="$(git -C "$ROOT" rev-parse HEAD)"
GITHUB_SHA="$source_commit" \
OVID_RELEASE_BUILD_COMMAND="$build_command_text" \
python3 "$ROOT/tool/release_inventory.py" "$apk_out" \
  --mode production \
  --profile sideload \
  --expected-target 36 \
  --expected-abis x86_64 \
  --certificate-sha256 "$cert" \
  --output "$evidence_out/release-inventory.json"

artifact_created=false
trap - EXIT
printf 'Signed sideload APK: %s\nEvidence: %s\n' "$apk_out" "$evidence_out/release-inventory.json"
