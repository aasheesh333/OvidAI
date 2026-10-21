# Per-screen audit brief (UI v2)

You are auditing **one** screen. The screen already exists. Do not rebuild it,
do not restyle it, and do not touch any other screen.

## Read first

1. `docs/design/stitch/V2_CONTRACT.md`
2. The row for your screen in `docs/design/stitch/V2_SCREEN_SPECS.md`
3. `lib/ui/design/o_tokens.dart`, `o_theme.dart`, `o_components.dart`,
   `o_motion.dart`
4. Your screen file and its test.

## Audit checklist

- [ ] Light **and** dark render with no hard-coded colours.
- [ ] 320 dp wide + 200 % text: no RenderFlex overflow, no clipped text.
      Use `Flexible`/`Expanded`/`Wrap`/`maxLines` + ellipsis or a scrollable
      body. Never shrink fonts or delete content to make it fit.
- [ ] Correct states: loading, empty (with the next action), error (with
      retry), content. A static screen may legitimately skip list states.
- [ ] Every control is at least 48 dp, has a semantic label, and disabled
      states are announced.
- [ ] Motion uses `OFadeSlide`/`OStagger`/`OMove`; reduced motion hides no
      content.
- [ ] No `AppState`, network, Firebase, or global singleton imports. Data is
      injected; callbacks go out.
- [ ] No demo/sample values leaking into production defaults.
- [ ] `TODO(l10n)` markers on user-facing copy.

## Allowed edits

- Your screen file.
- Your screen's test file.
- Nothing else. No shared files, `main.dart`, router, `pubspec.yaml`, other
  groups, no commits.

## Commands

```bash
export PATH=/root/flutter/bin:$PATH
flutter test <your test file>
flutter analyze <your screen file> <your test file>
```

Both must be clean. Do not run the full suite.

## Report

Append to `.superpowers/sdd/2026-10-21-ovid-si-rebuild/reports/screens/<screen>.md`:

- status: PASS / FIXED / BLOCKED
- what you checked
- what you changed (if anything)
- test + analyze result
- remaining concerns
