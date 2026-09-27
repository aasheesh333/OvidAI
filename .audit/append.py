#!/usr/bin/env python3
"""Append a fix-status section to docs/ENGINEERING_AUDIT.md."""
import io
import os

REPO = os.path.normpath(os.path.dirname(os.path.abspath(__file__)) + "/..")
p = os.path.join(REPO, 'docs/ENGINEERING_AUDIT.md')
src = io.open(p, encoding='utf-8').read()

APPEND = '''
---

## 10. Fix status — patches applied (2026-09-27)

Four fixes are **applied to the working tree** (uncommitted). They target the
issues that are both high-impact and provably safe to change in isolation.

| # | Issue | File | Change |
|---|---|---|---|
| 1 | `renameSession` threw `StateError` | `lib/core/state.dart:5090` | Replaced the unguarded `sessions.firstWhere(...)` with the existing `sessionById(id)` + null-return guard |
| 2 | Invisible card borders in dark mode (1.00:1) | `lib/core/theme.dart:21` | `_hairlineD` `0x232324` → `0x3A3A40`; `_hairlineStrongD` `0x313134` → `0x4A4A54` |
| 3 | System font scale ignored in chat (U2) | `lib/ui/chat_screen.dart:102` | Now **composes** `MediaQuery.textScalerOf(context).scale(1) * chatFontScale` instead of replacing it |
| 4 | `lastSessionPersistFailed` was write-only | `lib/ui/shell.dart` | Added a 3s watchdog + non-dismissible `_PersistWarningBanner`; the flag now has a reader |

**Measured contrast improvement (fix 2):**

| Border | on `surface` | on `surfaceRaised` | on `bg` |
|---|---|---|---|
| `hairline` before | **1.00** | 1.30 | — |
| `hairline` after | **1.39** | 1.07 | 1.61 |
| `hairlineStrong` before | — | 1.07 | — |
| `hairlineStrong` after | 1.79 | 1.38 | 2.08 |

**How these were verified (no Dart toolchain available):**
- Every patch was applied to the **live bytes** with an exact-match assertion
  (each pattern had to occur exactly once, else the script aborted).
- A comment/string-stripping delimiter-balance check compared the working tree
  against `git HEAD` for all four files: **all four balance identically**, so
  no stray `{`/`(`/`[` was introduced.
- Each change was re-read from the file after writing.

**Not verified:** `flutter analyze` / `flutter test` have **not** run. Treat
these as *unverified until CI is green*.

### Deliberately NOT changed (would be unsafe to do blind)

| Issue | Why deferred |
|---|---|
| Light-theme contrast (20 failing pairs) | The clean fix is making `accent`/`success`/`warn`/`danger` context-aware getters, but they appear in **~22 `const` expressions** across `lib/ui` (`const TextStyle(color: Aether.danger)`, `const _ChaseDot(Aether.accent)`, …). `const` requires compile-time constants, so this is a **compile-breaking** refactor that cannot be validated without `flutter analyze`. |
| `firstWhere` without `orElse` in `rest_descriptors_*.dart` (~11 sites) | Each capability needs a null/descriptor-missing fallback designed per plugin; a blind `orElse` risks a `LateInitializationError` or a wrong descriptor. |
| Splitting `agent_service.dart` (19,951 LOC) | Large mechanical refactor; needs the analyzer and the full test suite at every step. |

### Tooling hazard discovered (important for future edits)

`file_read` / `fs_edit view` serve a **stale snapshot** for this repo — e.g.
`chat_screen.dart` reads as **1,107 lines** when the live file is **8,034**,
and `state.dart` reads as 1,073 lines vs 8,708 live. Editing through those
tools can silently clobber thousands of lines. All patches above were applied
against the live bytes via shell with exact-match assertions. **Always confirm
a file's live line count (`wc -l`) before editing it in this repo.**

---

*Audit generated from branch `hoplite/gortyn-77773150` @ `f817418`.
`flutter analyze` / `flutter test` were not run in this environment — run them
in CI or a Flutter-enabled sandbox before treating any finding as closed.*
'''

# Replace the old trailing line with the new sections.
old_tail = ('---\n\n*Generated from branch `hoplite/gortyn-77773150` @ `f817418`. '
            '`flutter analyze` / `flutter test` were not run in this environment; '
            'run them in CI or a Flutter-enabled sandbox before treating any '
            'finding as closed.*\n')
assert src.count(old_tail) == 1, 'tail not found exactly once: %d' % src.count(old_tail)
src = src.replace(old_tail, APPEND.lstrip('\n'), 1)
io.open(p, 'w', encoding='utf-8').write(src)
print('appended fix-status section; file is now %d lines' % (src.count('\n') + 1))
