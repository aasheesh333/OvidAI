# Moving UI v2 copy into ARB

This is the working guide for the localization pass over `lib/ui/v2`. The
inventory tool lives at `tool/l10n_scan.py`; it **reads** Dart, never rewrites
it. The pass itself is manual, file by file, so each screen can be reviewed in
light/dark at 320 dp and 200 % text while its copy moves.

Nothing in this pass changes Dart. No commits.

## Snapshot

Run on 2026-10-21 while screen work was still landing, so treat these as
illustrative and re-run the command below before starting a batch:

| Metric | Count |
| --- | ---: |
| Dart files scanned in `lib/ui/v2` | 108 |
| User-facing literals found | 3,976 |
| Files containing at least one literal | 107 |
| Files already marked `TODO(l10n)` | 93 |
| Literals inside marked files | 3,265 |
| Literals in unmarked files (`--skip-todo`) | 711 |
| Literals with interpolation (`$x` / `${...}`) | 458 |
| Distinct texts repeated more than once | 546 (1,172 redundant rows) |
| Largest area: `connectors` | 958 |
| `settings` | 625 |
| `app` adapters | 324 |
| `studio` | 232 |

Largest files at that moment: `connectors/catalog_data.dart` (516),
`connectors/connectors_page.dart` (295), `v2_registry_web.dart` (160),
`v2_registry.dart` (158), `app/v2_app_shell.dart` (106).

Counts only go down as copy moves out; the scanner also finds strings that do
not need translation (see [What not to extract](#what-not-to-extract)), so do
not chase the number to zero.

## Generate the inventory

```bash
python3 tool/l10n_scan.py --out /tmp/l10n/literals.csv --per-file
```

The CSV is written with a header and repo-relative paths:

```csv
file,line,text
lib/ui/v2/app/app_lock_gate.dart,27,App locked
lib/ui/v2/app/app_lock_gate.dart,28,Enter your PIN to continue.
lib/ui/v2/app/app_lock_gate.dart,300,Too many attempts. Try again in ${seconds}s.
```

- `line` points at the first fragment of a concatenated string; adjacent Dart
  string literals are merged, so a sentence split across lines stays one row.
- Interpolations stay in the text (`$name`, `${count}`) because each one becomes
  an ARB placeholder.
- Newlines inside triple-quoted strings are shown as `\n`, so every row stays on
  one physical CSV line.
- The summary goes to stderr, so stdout stays pipeable:
  `python3 tool/l10n_scan.py > /tmp/l10n.csv`.
- `--skip-todo` ignores files that already carry a `TODO(l10n)` marker. This is
  useful for finding unmarked files; the full scan is the real inventory.
- `--per-file` prints a count table to stderr, sorted descending.
- `--self-test` runs the embedded lexer/classification cases.

Work a file with normal shell tools:

```bash
grep '^lib/ui/v2/settings/appearance_page.dart,' /tmp/l10n/literals.csv
python3 tool/l10n_scan.py lib/ui/v2/settings/appearance_page.dart
```

The scanner can also be pointed at another tree, for example the shared design
widgets: `python3 tool/l10n_scan.py lib/ui/design`.

## What to extract

Translate copy the person reads or hears:

- `Text`, `SelectableText`, `TextSpan` content, and text passed to the v2
  components (`OAppBar`, `OEmptyState`, `OErrorState`, `OSheet`, `ODialog`, …).
- Named copy parameters: `label`, `title`, `subtitle`, `message`, `hintText`,
  `labelText`, `helperText`, `tooltip`, `semanticLabel`, `errorText`,
  `emptyMessage`, `description`, `summary`, `tagline`, and their siblings.
- Button/row/chip/menu labels, dialog titles and bodies, snackbar copy, empty
  and error states, loading labels, onboarding and paywall copy.
- Accessibility: `Semantics.label`, `semanticLabel`, tooltips announcing icon
  buttons. Translate these as separate keys; do not derive them by
  concatenating translated fragments.
- Counts and plurals (`'$count files'`), relative time labels, and copy that
  embeds a name (`'Delete ${project.name}?'`).

### What not to extract

Leave these alone (the scanner should mostly skip them; when it does not, ignore
the row):

- IDs, slugs, enum wire values, route names, asset paths, font families, color
  tokens, MIME types, URLs, format patterns, JSON keys, cache keys.
- `toString()`, `debugPrint`, `assert` messages, exception text, log lines.
- Generated files (`lib/l10n/app_localizations*.dart`).
- Server-provided text. Render it as data; translate only copy the app owns.
- Code samples and example payloads shown in previews (`const answer = 42;`).
- Brand/product names that stay untranslated (`Ovid Si`, `GitHub`, `OAuth`).
  Keep them in the English string rather than making a key just for a brand.

The scanner is heuristic: it uses the call site, named parameter, declared
name, and sentence shape. It can both over-report (demo data, example copy) and
under-report (a lone lowercase word, copy assembled with `+`, copy in a
generated file). Skim the CSV for the file you are about to edit.

## Pick a batch

1. Start with one screen plus its private helpers and state classes, not with a
   whole directory. The v2 screens are presentational, so their copy is
   self-contained.
2. Check the `TODO(l10n)` marker at the top of the file. Remove it only when
   that file's inventory is empty.
3. Search for duplicates before inventing keys. Existing generic keys already
   cover common actions: `actionRetry`, `actionCancel`, `actionSave`,
   `actionDelete`. The snapshot had 20 `Clear search`, 35 `Settings`, 31
   `Chat`, and 16 `Cancel` occurrences; reuse a key only when the meaning and
   surrounding context are truly the same.
4. Add the file to the ratchet **before** editing (see
   [Ratchet mechanics](#ratchet-mechanics)).
5. Extract in reviewable chunks: actions/titles first, then empty/error states,
   then long prose and plurals.

Data-heavy files such as `connectors/catalog_data.dart` need a strategy rather
than a mechanical sweep. Prefer storing stable keys/enums on the model and
resolving copy at render time (or passing `AppLocalizations` into a `describe`
function) instead of baking English strings into const data.

## Add ARB entries

The template is `lib/l10n/app_en.arb`; `l10n.yaml` generates
`lib/l10n/app_localizations*.dart` from it. Every message needs an
`@description` — the ratchet test fails without one.

Key naming follows existing families: `schedule*`, `storage*`, `cloud*`,
`providerFetch*`, `settings*`, `backup*`, plus generic `action*` keys. Use
camelCase, a screen/area prefix, and a semantic suffix. Never rename existing
keys as part of extraction; that is separate churn.

```json
"chatRenameTitle": "Rename chat",
"@chatRenameTitle": {
  "description": "Title of the dialog that renames the current chat."
},
```

Interpolations become typed placeholders. Use named arguments from Dart:

```json
"projectDeleteConfirm": "Delete {name}?",
"@projectDeleteConfirm": {
  "description": "Confirmation title before deleting a project.",
  "placeholders": {
    "name": { "type": "String", "example": "Website redesign" }
  }
}
```

Counts use ICU plurals, not string concatenation or `count == 1 ?` in Dart:

```json
"filesCount": "{count, plural, =0{No files} =1{1 file} other{{count} files}}",
"@filesCount": {
  "description": "Number of files in the current view.",
  "placeholders": {
    "count": { "type": "int", "example": "3" }
  }
}
```

For `select`-style variants (plan tier, role, mode), keep the whole sentence in
one key and let ICU choose the branch, so translators can reorder it. Existing
examples to copy from: `storageCookiesPartial`, `cloudModelCount`,
`scheduleStopBackgroundMessage`.

Do not build a sentence from separately translated fragments. If the scanner
shows `'$a of $b'` and `'$count selected'` as separate rows, decide which are
whole user-visible sentences and give each one a key; fragments that only exist
inside a `Semantics` label can be a dedicated interpolation key.

## Replace the Dart literal

Import the helper once per file. Most v2 screens live under
`lib/ui/v2/<area>/`, so `lib/l10n` is three levels up:

```dart
import '../../../l10n/l10n.dart';
```

Then:

```dart
// before
const Text('Rename chat')
// after
Text(context.l10n.chatRenameTitle)        // drop const when the parent allows it
```

```dart
// before
OAppBar(title: 'Subagent')
// after
OAppBar(title: context.l10n.runsSubagentTitle)
```

```dart
// before
Text('$count ${count == 1 ? 'run' : 'runs'}')
// after
Text(context.l10n.runsCount(count))
```

```dart
// before
OIconButton(icon: Icons.download, semanticLabel: 'Download ${file.name}')
// after
OIconButton(
  icon: Icons.download,
  semanticLabel: context.l10n.memoryDownloadFile(file.name),
)
```

Practical notes:

- `context.l10n` is an extension with an English fallback, so widget tests that
  pump a bare `MaterialApp` keep working.
- Removing `const` can cascade: a `const Row(...)` containing `Text('…')`
  becomes non-const. Prefer hoisting `final l10n = context.l10n;` at the top of
  `build` when replacing many strings in one widget.
- Top-level `const` label lists cannot read `context`. Convert them to a
  function that takes `AppLocalizations` and call it from `build`, or store
  stable IDs on the model and map them to `l10n` getters at render time.
- In data constructors, keep injected fields as data. Do not localize in an
  adapter (`lib/ui/v2/app/`) and then pass English down as if it were state;
  localize where the widget has a `BuildContext`.
- Keep tooltips and semantic labels in sync with the visible label, but give
  them their own keys when the wording differs (`Close` vs `Close {title}`).
- Do not interpolate raw exceptions into copy. Route failures through
  `friendlyError`/the existing error keys instead of `'$e'`.
- Dates, times, file sizes, and percentages are formatted by `intl` helpers,
  not baked into ARB strings. ARB may hold the surrounding sentence with a
  preformatted label placeholder.

## Regenerate and verify

```bash
export PATH=/root/flutter/bin:$PATH

flutter gen-l10n
flutter analyze lib/ui/v2
flutter test test/l10n_literal_ratchet_test.dart
flutter test test/v2
python3 tool/l10n_scan.py --out /tmp/l10n/after.csv
```

`flutter pub get` also regenerates localizations when `generate: true` is set
in `pubspec.yaml`.

Before/after check for the file you touched:

```bash
grep '^lib/ui/v2/settings/appearance_page.dart,' /tmp/l10n/after.csv | wc -l
```

The only acceptable direction is down. Rows may remain for strings you
intentionally keep (IDs, data, code samples); the ratchet count is the gate.

## Ratchet mechanics

`test/l10n_literal_ratchet_test.dart` is the gate. Its regex is narrower than
this scanner (it mainly catches `Text('…')` and a fixed set of named
parameters), so **never copy a scanner count into the baseline**. Add an entry
with the number the test reports, then lower it as you remove literals:

```dart
'lib/ui/v2/settings/appearance_page.dart': 42, // use the count the test reports
```

Rules:

- Files not listed are not gated. Add the file when you start, or new copy can
  slip in unnoticed.
- The count may only go down. If you add a new string temporarily, add its ARB
  key in the same change instead of raising the baseline.
- Keep the entry at `0` after the file is clean; do not remove the key.
- Do not weaken the regex or add allow-list exceptions to make a file pass.

The same test also enforces that every ARB message has a description and that
`MaterialApp` wires the delegates.

## Review checklist

For each extracted screen:

- Light and dark themes both read correctly; no hard-coded colors added.
- 320 dp wide at 200 % text: no overflow, no clipped buttons, 48 dp targets.
- Empty, loading, error (with retry) and content states all still render.
- Every icon-only control has a translated semantic label or tooltip; disabled
  states are announced.
- Plurals cover 0, 1 and many; no `count == 1` strings left in Dart.
- Interpolated names/values are placeholders, not concatenated fragments.
- No raw exception text, no `TODO(l10n)` left in a file whose inventory is
  empty.
- `flutter analyze` and the ratchet test pass for the touched files.

## Scanner internals

`tool/l10n_scan.py` is a small lexer, not a Dart parser:

- Skips `//` and nested `/* ... */` comments, and drops import/export/part
  paths.
- Understands raw (`r'…'`) and triple-quoted strings, escapes, and `${…}`
  interpolation (including strings inside the interpolation).
- Merges adjacent string literals separated only by whitespace.
- Keeps a literal when the callee is a known widget/component, the named
  parameter or declared name is copy-shaped, or the literal reads like a
  sentence. It rejects paths, URLs, extensions, color hex, identifier lists,
  regex-like raw strings, log/assert plumbing, and `toString`/`search`
  helpers.
- Output is sorted by path, line, then column and deduplicated per location.

Run `python3 tool/l10n_scan.py --self-test` after changing the heuristics; the
embedded cases pin comments, raw strings, interpolation, list labels, and the
log/error exclusions. When you add a heuristic, add a case there rather than
adding a Dart test.
