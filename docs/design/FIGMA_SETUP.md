# Figma access (installed)

Two tools are installed on this machine. Both need a Figma token; nothing works
without one.

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

## Token

Create a personal access token at:

  Figma → Settings → Security → Personal access tokens → Generate new token

Scopes needed:
- `File content` (read) — required to read a file
- `Dev resources` (read/write) — only for `figma connect publish`

Then export it for the session:

```
export FIGMA_API_KEY="figd_..."
```

For it to persist for the MCP server, add the same line to your shell profile
(`~/.bashrc`) or put it in `~/.config/opencode/.env`.

## What to give the agent

Two things, and only these:

1. The token (`FIGMA_API_KEY`).
2. The Figma file URL, e.g.
   `https://www.figma.com/design/<fileKey>/<name>?node-id=12-345`

With those, the agent can read the frame and rebuild the screen against the
existing tokens (`OColors`, `OType`, `OSpace`, `ORadius`) instead of guessing.

## Verification

```
figma --version                       # 2.0.2
figma-developer-mcp --stdio           # errors clearly when FIGMA_API_KEY is unset
```

Both are on `PATH` (`/usr/bin/figma`, `/usr/bin/figma-developer-mcp`).


## Status (live)

- Logged in as `aasheeshkatheriya@gmail.com` (Free plan).
- Token: `ovid-si-full-access`, 15 scopes, expires **20 Jan 2027** (Figma Free
  caps personal access tokens at 90 days; "never expire" is a paid-plan
  option). Stored in `~/.bashrc` as `FIGMA_API_KEY`.
- **No Ovid design file existed in the account.** Figma search returned
  "No file, folder, team, or people results matching Ovid", so there was
  nothing to read.
- A sheet was generated from the real code instead and pasted into a new
  Figma file: 16 screens at 360×780, light theme, as editable vectors.

### The sheet

```
python3 tool/figma_sheet.py           # build/figma/ovid-si-screens.svg
python3 tool/figma_sheet.py --dark    # build/figma/ovid-si-screens-dark.svg
```

Paste procedure (what worked):
1. `xclip -selection clipboard -i < build/figma/ovid-si-screens.svg`
   (plain text, not `-t image/svg+xml` — Figma converts a leading `<svg>`).
2. Click the canvas, press Escape twice, then Ctrl+V.
3. The sheet lands as one frame with every screen inside it.

### Environment note

The Figma editor needs WebGL. Chrome on this box must run headed on the VNC
display with SwiftShader, otherwise the editor shows "Could not initialize
WebGL":

```
DISPLAY=:1 chrome --remote-debugging-port=9222 --remote-allow-origins=* \
  --no-sandbox --use-gl=angle --use-angle=swiftshader \
  --enable-unsafe-swiftshader --user-data-dir=/tmp/opencode/chrome-profile-8099
```

### Still needed

The MCP server is read-only (`get_figma_data`, `download_figma_images`). To
have the agent *build* screens in Figma rather than paste a sheet, either:

- give a link to a file that already contains the design frames, so the MCP
  can read them, or
- use a Figma plugin/token with write scope, which the current API does not
  expose to personal access tokens.
