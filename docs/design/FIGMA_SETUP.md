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
