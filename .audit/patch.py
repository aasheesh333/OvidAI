#!/usr/bin/env python3
"""Verified, assertion-guarded patches for the Ovid audit fixes.

fs_edit/file_read serve a STALE snapshot for this repo (chat_screen.dart reads
as 1,107 lines when it is really 8,034), so every edit here is applied against
the LIVE bytes and asserted to match exactly once.
"""
import io
import os
import sys

REPO = os.path.dirname(os.path.abspath(__file__)) + "/.."
REPO = os.path.normpath(REPO)


def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    c = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def R(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


print("=== hairline contrast BEFORE ===")
print("  hairlineD 232324 on surface 232324  = %.3f  (IDENTICAL -> invisible)"
      % R('232324', '232324'))
print("  hairlineD 232324 on surfaceRaised 353638 = %.3f" % R('232324', '353638'))
print("  hairlineStrongD 313134 on surfaceRaised = %.3f" % R('313134', '353638'))

print()
print("=== candidates (new hairline) ===")
for c in ['2E2E31', '34343A', '3A3A40', '3D3D45']:
    print("  %s  surface %.2f  surfaceAlt %.2f  surfaceRaised %.2f  bg %.2f"
          % (c, R(c, '232324'), R(c, '2C2C2E'), R(c, '353638'), R(c, '151517')))
print("=== candidates (new hairlineStrong) ===")
for c in ['45454F', '4A4A54', '4F4F5A']:
    print("  %s  surface %.2f  surfaceRaised %.2f  bg %.2f"
          % (c, R(c, '232324'), R(c, '353638'), R(c, '151517')))

EDITS = []

# ── Fix 2: theme hairline (dark) ───────────────────────────────────────────
EDITS.append((
    'lib/core/theme.dart',
    '  static const _hairlineD = Color(0xFF232324);\n'
    '  static const _hairlineStrongD = Color(0xFF313134);\n',
    '  // VISIBILITY (2026-09-27): _hairlineD was byte-identical to _surfaceD\n'
    '  // (both 0xFF232324), so every `Border.all(color: Aether.hairline)` on a\n'
    '  // card drew at 1.00:1 contrast — no visible edge at all on 82 call sites.\n'
    '  // Raised to a step that reads on surface AND surfaceRaised.\n'
    '  static const _hairlineD = Color(0xFF3A3A40);\n'
    '  static const _hairlineStrongD = Color(0xFF4A4A54);\n',
))

# ── Fix 3: renameSession crash guard ───────────────────────────────────────
EDITS.append((
    'lib/core/state.dart',
    '  void renameSession(String id, String title) {\n'
    '    sessions.firstWhere((s) => s.id == id).title = title;\n',
    '  void renameSession(String id, String title) {\n'
    '    // A rename can arrive for a session that was deleted in the same\n'
    '    // frame (search results, ledger replay, queued rename). The previous\n'
    '    // `sessions.firstWhere(...)` had no orElse and threw StateError.\n'
    '    final s = sessionById(id);\n'
    '    if (s == null) return;\n'
    '    s.title = title;\n',
))

# ── Fix 1: compose (not replace) the OS text scale in chat ─────────────────
EDITS.append((
    'lib/ui/chat_screen.dart',
    '        return MediaQuery(\n'
    '          data: MediaQuery.of(\n'
    '            context,\n'
    '          ).copyWith(textScaler: TextScaler.linear(AppState.I.chatFontScale)),\n',
    '        return MediaQuery(\n'
    '          // A11Y (U2): COMPOSE the OS text scale with the in-app chat size\n'
    '          // instead of replacing it. This previously assigned\n'
    '          // `TextScaler.linear(AppState.I.chatFontScale)` outright, so a\n'
    '          // user who set Android font size to 200% saw no change at all in\n'
    '          // the transcript. Multiplying the resolved OS factor keeps the\n'
    '          // default case (OS scale 1.0) behaviourally identical.\n'
    '          data: MediaQuery.of(context).copyWith(\n'
    '            textScaler: TextScaler.linear(\n'
    '              MediaQuery.textScalerOf(context).scale(1) *\n'
    '                  AppState.I.chatFontScale,\n'
    '            ),\n'
    '          ),\n',
))

ok = True
for rel, old, new in EDITS:
    path = os.path.join(REPO, rel)
    with io.open(path, encoding='utf-8') as fh:
        src = fh.read()
    n = src.count(old)
    if n != 1:
        print("!! ABORT %s: expected exactly 1 match, found %d" % (rel, n))
        ok = False
        continue
    with io.open(path, 'w', encoding='utf-8') as fh:
        fh.write(src.replace(old, new, 1))
    print("OK  patched %s (+%d bytes)" % (rel, len(new) - len(old)))

print()
if not ok:
    print("RESULT: some edits FAILED — no partial write for those files.")
    sys.exit(1)
print("RESULT: all %d edits applied." % len(EDITS))
