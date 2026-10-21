# Ovid Si v2 — screen build contract

Every screen in `lib/ui/v2/` follows this contract. It is deliberately strict so
nine parallel implementers can land files that compile and look like one app.

## Read first

1. `docs/design/stitch/stitch_ovid_si_ai_assistant/ovid_si/DESIGN.md` — the
   approved palette, type, spacing, radii, elevation.
2. The screen's own reference: `docs/design/stitch/.../<screen>/screen.png`
   (visual) and `code.html` (structure only — never copy the HTML).
3. `lib/ui/design/o_tokens.dart`, `o_theme.dart`, `o_components.dart`,
   `o_motion.dart`.

## Hard rules

- Import only `package:flutter/material.dart` plus the four design files.
- Colours: `final c = OColors.of(context);` — no `Color(0x...)` literals in a
  screen. Status colours come from `c.success / c.warn / c.danger`.
- Type: `OType.*` only. Never `TextStyle(fontSize: ...)` in a screen.
- Spacing: `OSpace.*`. Radii: `ORadius.*`. Motion: `OMotion.*` / `OMove.*`.
- Minimum touch target 48 dp. Icon-only controls use `OIconButton` with a
  `semanticLabel`.
- Every screen is a `StatelessWidget` or `StatefulWidget` with **injected data
  and callbacks**. No `AppState`, no network, no globals, no singletons. This
  keeps the screen testable and lets the wiring pass own the live data.
- Constructor data classes are immutable and defined in the same file, named
  `V2<Screen>Data` (plus small row models as needed).
- Every scrollable list has four states: loading (`OSkeletonList`), empty
  (`OEmptyState` with a next action), error (`OErrorState` with retry), and
  content. A screen with no list still needs an empty/error path where it can
  fail.
- Every screen uses `OScaffold` + `OAppBar`. Top-level tabs/sheets may omit the
  app bar only when the reference does.
- Entrance motion: wrap the page body in `OFadeSlide`; lists use `OStagger`
  for the first 8 rows. Buttons/cards use `OButton` / `OCard` (already
  press-animated). Never write a raw `AnimationController` unless the design
  needs a continuous animation (pulse/shimmer already exist).
- Strings are English, plain, grade-5 reading level. No jargon ("MCP",
  "workspace", "token bucket") in user-facing copy. A `// TODO(l10n)` comment
  is allowed for this wave; the ARB pass follows.
- Dark and light must both look correct. Never assume dark.
- No gradients except the splash halo and the paywall hero glow.

## File layout

```
lib/ui/v2/<group>/<screen>.dart
test/v2/<group>/<screen>_test.dart
```

One screen per file. Do not edit files outside your group. Do not touch
`lib/main.dart`, `lib/ui/app_router.dart`, `pubspec.yaml`, the design files, or
another group's folder.

## Required tests

Each screen test file must cover:

1. the screen renders its title and primary content;
2. the empty state renders and its action fires;
3. the primary callback fires (tap the main CTA / row);
4. one interaction specific to the screen (toggle, tab, chip, expansion).

Use `MaterialApp(theme: OTheme.light(), home: ...)` and also pump one dark
case (`OTheme.dark()`) for the main render. Do not use golden files.

Run only your own tests:

```
export PATH=/root/flutter/bin:$PATH
flutter test test/v2/<group>/
flutter analyze lib/ui/v2/<group> test/v2/<group>
```

Both must be clean before you report.

## Report

Write your full report to the report path given in the dispatch. Return only:
status, files created, test command + result, analyze result, and any concern.
