#!/usr/bin/env bash
# One-command verification for the UI v2 rebuild.
# Usage: tool/verify_v2.sh
set -euo pipefail

export PATH=/root/flutter/bin:$PATH
cd "$(dirname "$0")/.."

echo "==> flutter analyze"
flutter analyze

echo "==> design system tests"
flutter test test/design/

echo "==> v2 screen tests"
flutter test test/v2/

echo "==> 320 dp / 200 % text ratchet"
flutter test test/v2/a11y_ratchet_test.dart

echo "==> full app suite"
flutter test

echo "All checks passed."
