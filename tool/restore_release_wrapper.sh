#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${OVID_ORIGINAL_WORKTREE:-}" ]]; then
  printf 'OVID_ORIGINAL_WORKTREE must name the read-only original worktree\n' >&2
  exit 2
fi

python3 "$ROOT/tool/release_input_hygiene.py" restore \
  --original "$OVID_ORIGINAL_WORKTREE" \
  --destination "$ROOT"
