# TalkBack / semantics checklist — UI v2

Scope: every screen in `lib/ui/v2/v2_registry.dart` (51 screens at the time of
writing). The automated gate lives in `test/v2/semantics_audit_test.dart`; this
document explains the rules, owns the skip list, and covers the manual checks
that a widget test cannot make.

## Run the gate

```bash
export PATH=/root/flutter/bin:$PATH
flutter test test/v2/semantics_audit_test.dart
flutter analyze test/v2/semantics_audit_test.dart
```

The test pumps every registry entry in **light and dark**, at **320 dp wide**
with **200 % text**, walks the complete semantics tree (including nodes built
off-screen), and fails on any undocumented violation. Each screen/theme pair is
one test, so a failure names the screen and theme.

Last run: **103 tests passed** (51 screens × 2 themes + 1 detector unit test).

## Automated rules

| Rule | What is checked |
| --- | --- |
| Name | Every interactive node has an accessible name from its own `label`/`tooltip` or a labelled **interactive** ancestor. |
| Enabled | Every interactive node announces `enabled=true` or `enabled=false`, either on the node, an ancestor, or the actionable child that carries the state. Silence is a failure. |
| No repeated label | A single node must not contain the same non-empty line twice (for example `"Search\nSearch"`). |
| Image label | Every node with `SemanticsFlag.isImage` must have its own non-empty label. |
| Skip hygiene | Every documented skip must be observed in the run. Fixing a screen makes its skip stale and fails the gate, so debt cannot silently outlive the fix. |

“Interactive” means a control flag (`button`, `link`, `textField`, `slider`,
`toggled`, `checked`, `selected`, mutually-exclusive group) or a manipulation
action (`tap`, `longPress`, `increase`, `decrease`). Progress bars, headings and
plain text are not treated as controls.

Names may be inherited from an ancestor because the shared primitives emit an
outer labelled `Semantics` node plus an inner tap target. The gate checks what
TalkBack reads; it does not require the inner implementation node to duplicate
the text. A control with no name anywhere in its branch still fails.

## Documented skips

All entries are in `_knownGaps` in the test. They are grouped by owner below.

### 1. Keyboard-dismiss bridge (2 screens)

| Screen | Gap | Why |
| --- | --- | --- |
| `sign_in` | Empty tap node with no accessible name | Full-screen `GestureDetector` dismisses the keyboard. It is not a visible control and has no target of its own. |
| `add_connector` | Empty tap node with no accessible name | Same bridge pattern. |

Owner: shared app shell. Exit: the bridge should not create a focusable
semantics node (`excludeFromSemantics`, or a non-semantic gesture recognizer).

### 2. Inline switch has no accessible name (1 screen)

| Screen | Gap | Why |
| --- | --- | --- |
| `session_actions` | Pin switch (`toggled=false`) | The labelled row owns the name, but the switch is emitted as a separate node with no label of its own. |

Owner: design primitives (`OListRow` + `Switch`). Exit: label the switch, or
exclude it and let the row expose the toggle state.

### 3. `OSelectable` does not announce enabled (screen `model_chip`, 3 nodes)

| Label | Why |
| --- | --- |
| `Auto, Included free` | `OSelectable` sets `selected` but never `hasEnabledState`. |
| `Manage models` | Same. |
| `Compare plans, From $18/mo` | Same. |

Owner: design primitives (`OSelectable`). Exit: set `enabled` from the tap
callback so disabled and enabled tiles are distinguishable.

### 4. Repeated label text (15 nodes)

Most of these come from `OListRow`, which merges the row label with the visible
child text, so TalkBack reads the same name twice. The avatar, status-chip and
decorative-bullet rows are listed separately below.

| Screen | Node label | Why |
| --- | --- | --- |
| `sidebar` | `Profile, Ovid user, Free plan\nOvid user\nOU\nOvid user\nFree plan` | Profile row merges name and subtitle lines. |
| `sidebar` | `Search\nSearch`, `Schedule\nSchedule`, `Artifacts\nArtifacts`, `Settings\nSettings` | Row label plus visible title. |
| `session_actions` | `Rename chat\nRename chat`, `Move to project\nMove to project`, `Duplicate chat\nDuplicate chat\nBranch` | Row label plus visible title/branch text. |
| `repo_picker` | `G\nG` | Avatar initials merged with the avatar label. |
| `browser` | `Action log\nAction log` | Row label plus visible title. |
| `account_health` | `Email verification\nEmail verification\nVerified` | Row title merged with the status chip. |
| `about` | `Privacy policy\nPrivacy policy`, `Terms of service\nTerms of service`, `Open-source licences\nOpen-source licences` | Row label plus visible title. |

Owner: design primitives (`OListRow`, avatar). Exit: exclude the visible child
from semantics, or stop passing the same string as the row label.
`artifact_detail` also has `Ready\n•\n•`; the decorative bullets should be
`excludeFromSemantics` rather than merged into the status label.

## Manual TalkBack pass (release candidate)

Do this on a physical Android device with TalkBack, once per screen group, in
light and dark. Use the device at 200 % font size and 320 dp width where the
device allows it.

- [ ] Enable TalkBack and navigate with one-finger swipe. The focus order
      follows reading order; no focus lands on an empty or duplicate node.
- [ ] Every button, link, field, switch, checkbox, chip and tab announces a
      name and its role.
- [ ] Disabled controls announce “disabled” and do not activate on
      double-tap. Loading controls keep their name and stay non-activatable.
- [ ] Text fields announce their label, value, and validation errors; the error
      is announced when it appears, not only when the field is focused.
- [ ] Switches/checkboxes announce both the state and the change after
      activation.
- [ ] Images and avatars have a meaningful label, or are excluded when
      decorative. Icons inside labelled buttons are not read twice.
- [ ] Sheets and dialogs move focus into the sheet, keep it there, and return
      it to the trigger on dismiss. The scrim/back action is announced.
- [ ] List rows with `onLongPress` expose the action (custom action) and the
      action sheet is reachable.
- [ ] Live updates (streaming reply, queue, run progress, errors, plan limits)
      are announced without stealing focus. Use polite live regions for
      progress and assertive only for failures that need action.
- [ ] 48 dp minimum touch targets; adjacent targets are separated. Verify with
      “Show tap targets” in Android developer options.
- [ ] Both themes: contrast and focus highlight are visible; no state is
      conveyed by colour alone.
- [ ] Text at 200 % does not clip, overlap, or lose a control. The automated
      ratchet covers exceptions; this covers readability and reachability.
- [ ] Rotate the device and repeat the sheet/dialog focus checks.

## Adding or removing a skip

1. Confirm the violation is in shared code you do not own this wave, or is a
   deliberate decorative node.
2. Add a `_KnownGap` with the exact screen, kind and label, plus a one-line
   reason. Add the same row to this document with an owner and exit criterion.
3. Run the gate. An unused skip fails: delete it immediately when the primitive
   is fixed.
4. Do not skip a whole screen. Skip the smallest reproducible node.

## What this gate does not prove

The semantics tree is necessary but not sufficient. It cannot verify speech
output, pronunciation, gesture handling, announcement timing, focus trapping in
real TalkBack, or whether a label makes sense to a person. Those stay in the
manual pass above.
