"""Wire the UNMODIFIED Python pools hook into this harness's import path.

THE sys.path TRAP (plan P9 Task 17, repeated here so nobody "simplifies" it):

``server/mint/litellm_hook/ovid_pools.py`` does::

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ovid_plans

That inserts ONLY ``server/mint/litellm_hook/``. ``ovid_plans.py`` actually
lives one directory up, in ``server/mint/``. Unless ``server/mint`` is ALSO on
``sys.path`` the import dies at collection with ModuleNotFoundError. Both
paths are derived from ``__file__`` (never the process cwd) and inserted here,
before anything imports ``ovid_pools``; the assertion below makes a future
layout change fail loudly instead of silently skipping the proof.

The harness runs against a disposable Redis populated by the TypeScript
projection (``seed.ts`` driven by ``src/money.test.ts``). It never writes to
the repository and never imports mint's production code: ``ovid_pools.py`` and
``ovid_plans.py`` are read exactly as they ship.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# cloud/apps/e2e/hook-contract/conftest.py -> repo root
REPO_ROOT = Path(__file__).resolve().parents[4]
MINT_DIR = REPO_ROOT / "server" / "mint"
HOOK_DIR = MINT_DIR / "litellm_hook"

# Belt and braces: ovid_pools self-inserts HOOK_DIR, but it needs MINT_DIR too.
for candidate in (str(HOOK_DIR), str(MINT_DIR)):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

# Assert the import succeeds BEFORE pytest collects the suite. A failure here
# is an infrastructure error, not a test result: it must never be swallowed.
try:
    import ovid_plans as _ovid_plans
except ImportError as exc:  # pragma: no cover - only on a broken checkout
    raise RuntimeError(
        "hook-contract: `import ovid_plans` failed. Both source directories "
        f"must be on sys.path; MINT_DIR={MINT_DIR!s} HOOK_DIR={HOOK_DIR!s}"
    ) from exc

_EXPECTED_PLANS_FILE = (MINT_DIR / "ovid_plans.py").resolve()
assert Path(_ovid_plans.__file__).resolve() == _EXPECTED_PLANS_FILE, (
    "hook-contract: imported the wrong ovid_plans module: "
    f"{_ovid_plans.__file__!r} != {str(_EXPECTED_PLANS_FILE)!r}"
)

if not os.environ.get("HOOK_CONTRACT_REDIS_URL"):
    pytest.skip(
        "HOOK_CONTRACT_REDIS_URL is unset - real-Python hook contract skipped",
        allow_module_level=True,
    )
