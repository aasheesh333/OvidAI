#!/usr/bin/env bash
# Actual signed-release emulator acceptance. This does not build an APK.
# Required environment: ANDROID_SIGNING_CERT_SHA256, OVID_EMULATOR_ACCOUNT.
# The matching real release inventory is read from OVID_RELEASE_INVENTORY or
# release-inventory.json beside the APK. Raw secrets/account text are not logged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tool/release_emulator_evidence.py" "$@"
