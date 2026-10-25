#!/usr/bin/env bash
# Actual signed-release on-device audio acceptance. This does not build an APK.
# UNEXECUTED during authoring. Requires explicit emulator/account/audio/server
# opt-ins documented in android_audio_evidence.py; voice flags are never changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tool/android_audio_evidence.py" "$@"
