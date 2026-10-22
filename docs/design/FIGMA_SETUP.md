# Figma design file and access

The Ovid Si Figma file holds **all 50 screens in both themes** — light and
dark — as **editable vector frames**, one frame per screen per theme. Nothing
is a flattened image: every rectangle, text run and icon is a layer, so a
designer can move, restyle or rename it.

The file is generated from code, not drawn by hand:

- frames are **360 × 780** (the phone the design system is measured against);
- colours come from the same palette the app uses (`Paper #F4F1EA`,
  `Ink #1B1B1B`, `Signal Red #E5484D` for the agent only, `Stone #8A867D` for
  secondary text), plus the dark equivalents;
- screen ids match `lib/ui/v2/v2_registry.dart` one for one (verified: 50 ids
  in the generator, 50 registered screens, no extras and none missing).

The generator keeps its **own copy** of the palette (`Palette` in
`tool/figma_sheet.py`); it does not import the Dart tokens. A colour change in
`lib/ui/design/o_tokens.dart` must be mirrored there by hand, then the sheet
regenerated and re-pasted.

The generated SVG is checkable: it contains 50 screen groups, one per id
(`grep -o 'id="[a-z_]*"' build/figma/ovid-si-screens.svg | sort -u`). What is
inside the external Figma file is a paste the owner performed, and the file
itself is **unverified** from here.

## Regenerate the sheet

```bash
python3 tool/figma_sheet.py           # build/figma/ovid-si-screens.svg      (light)
python3 tool/figma_sheet.py --dark    # build/figma/ovid-si-screens-dark.svg (dark)
```

Each run prints the screen count and size, e.g. `wrote build/figma/ovid-si-screens.svg (50 screens, N KB)`.
The generator is `tool/figma_sheet.py` (shared primitives + the first three
screens) plus `tool/figma_screens_extra.py` (the remaining 47). Both are plain
Python 3 with no third-party dependency; they do not need Flutter.

`--out <path>` writes the light sheet somewhere else. With `--dark`, the output
name is forced to `ovid-si-screens-dark.svg` next to `--out`'s parent, so use
the default paths if you want the standard names.

## Paste procedure (what worked)

The sheet is one SVG that Figma converts into a frame with a group per screen.

1. Copy the SVG as **plain text**, not as an image type:

   ```bash
   xclip -selection clipboard -i < build/figma/ovid-si-screens.svg
   ```

   Do **not** pass `-t image/svg+xml`; Figma only converts when the clipboard
   text starts with `<svg`.

2. In the Figma file, **click the canvas** (not a frame, not the layers panel).
3. Press **Escape twice** — this clears the current selection so the paste
   lands at the canvas root instead of inside the last-selected frame.
4. Press **Ctrl+V** (Cmd+V on macOS).
5. The sheet lands as one frame with every screen inside it. Repeat with the
   dark file for the dark set.

If the paste lands as a single uneditable image, the clipboard type was wrong —
re-copy as plain text and repeat from step 2.

## Token and access

- Logged in as `aasheeshkatheriya@gmail.com` (Free plan).
- Token: `ovid-si-full-access`, 15 scopes, **expires 20 Jan 2027**. Figma Free
  caps personal access tokens at 90 days; "never expire" is a paid-plan option,
  so this token must be regenerated before that date.
- Stored in `~/.bashrc` as `FIGMA_API_KEY`.
- Create a replacement at: Figma → Settings → Security → Personal access
  tokens → Generate new token. Scopes needed:
  - `File content` (read) — required to read a file
  - `Dev resources` (read/write) — only for `figma connect publish`

## 1. Figma CLI (official)

```
figma --version          # 2.0.2
figma connect --help
```

This is `@figma/code-connect`, the only official Figma CLI. It maps a Figma
component to a code component so a designer's frame and the app's widget stay
linked. Commands:

```
figma connect publish --token <FIGMA_TOKEN>
figma connect --dir lib/ui/v2 --token <FIGMA_TOKEN>
```

Use it when a Figma component should be bound to a specific Flutter widget.

## 2. Figma MCP server (read designs)

```
figma-developer-mcp --stdio
```

Registered in `~/.config/opencode/opencode.jsonc` under `mcp.figma`, reading
`FIGMA_API_KEY` from the environment. This is what lets the agent read a Figma
file directly: frames, layer names, fills, type styles, spacing and the
exported images. That is the useful one for "make the UI look like this design".

The MCP server is read-only (`get_figma_data`, `download_figma_images`). To have
the agent *build* screens in Figma rather than paste a sheet, either give it a
link to a file that already contains the design frames, or use a plugin/token
with write scope — the current API does not expose writes to personal access
tokens.

## Environment note

The Figma editor needs WebGL. Chrome on this box must run headed on the VNC
display with SwiftShader, otherwise the editor shows "Could not initialize
WebGL":

```
DISPLAY=:1 chrome --remote-debugging-port=9222 --remote-allow-origins=* \
  --no-sandbox --use-gl=angle --use-angle=swiftshader \
  --enable-unsafe-swiftshader --user-data-dir=/tmp/opencode/chrome-profile-8099
```

## Verification

```
figma --version                       # 2.0.2
figma-developer-mcp --stdio           # errors clearly when FIGMA_API_KEY is unset
python3 tool/figma_sheet.py           # prints "50 screens"
```

Both binaries are on `PATH` (`/usr/bin/figma`, `/usr/bin/figma-developer-mcp`).
