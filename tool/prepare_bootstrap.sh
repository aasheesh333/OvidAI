#!/bin/bash
# Verify pinned upstream assets before cache reuse or archive reads, then build
# a fresh deterministic agent-essential subset and per-ABI derivation manifest.
# Usage: tool/prepare_bootstrap.sh [--offline] [--verify-only] [abi ...]
# Requires: python3 (standard library), curl (only when cache is absent).
set -euo pipefail
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
exec python3 "$SCRIPT_DIR/bootstrap_supply.py" "$@"
