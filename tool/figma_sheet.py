#!/usr/bin/env python3
"""Generate a Figma-importable design sheet for every Ovid Si screen.

The sheet is one SVG: paste it into a Figma file and every frame lands as an
editable layer group. Colours come from the same three-colour system the app
uses, so the design file and the shipped UI cannot drift.

  Paper       #F4F1EA
  Ink         #1B1B1B
  Signal Red  #E5484D   (the agent only)
  Stone       #8A867D   (secondary text only)

Usage:
  python3 tool/figma_sheet.py            # writes build/figma/ovid-si-screens.svg
  python3 tool/figma_sheet.py --dark     # dark theme sheet
"""

from __future__ import annotations

import argparse
import html
import math
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Palette
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Palette:
    bg: str
    surface: str
    surface_alt: str
    hairline: str
    text: str
    muted: str
    faint: str
    agent: str
    on_agent: str


LIGHT = Palette(
    bg="#F4F1EA",
    surface="#F8F6F0",
    surface_alt="#EDE9E0",
    hairline="#DDD8CC",
    text="#1B1B1B",
    muted="#605C55",
    faint="#837F76",
    agent="#E5484D",
    on_agent="#0F0F0F",
)

DARK = Palette(
    bg="#141413",
    surface="#1B1B1A",
    surface_alt="#232322",
    hairline="#333331",
    text="#F4F1EA",
    muted="#A8A399",
    faint="#8A867D",
    agent="#FF6B6F",
    on_agent="#0F0F0F",
)

# --------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------


def esc(value: str) -> str:
    return html.escape(value, quote=True)


def rect(
    x: float,
    y: float,
    w: float,
    h: float,
    fill: str,
    *,
    rx: float = 0,
    stroke: str | None = None,
    stroke_width: float = 1,
    opacity: float | None = None,
) -> str:
    attrs = [
        f'x="{x:.1f}"',
        f'y="{y:.1f}"',
        f'width="{w:.1f}"',
        f'height="{h:.1f}"',
        f'fill="{fill}"',
    ]
    if rx:
        attrs.append(f'rx="{rx:.1f}"')
    if stroke:
        attrs.append(f'stroke="{stroke}"')
        attrs.append(f'stroke-width="{stroke_width}"')
    if opacity is not None:
        attrs.append(f'opacity="{opacity}"')
    return f"<rect {' '.join(attrs)}/>"


def text(
    x: float,
    y: float,
    value: str,
    size: float,
    fill: str,
    *,
    weight: int = 400,
    anchor: str = "start",
    opacity: float | None = None,
    letter_spacing: float | None = None,
) -> str:
    attrs = [
        f'x="{x:.1f}"',
        f'y="{y:.1f}"',
        f'font-family="Inter, -apple-system, Segoe UI, Roboto, sans-serif"',
        f'font-size="{size:.1f}"',
        f'font-weight="{weight}"',
        f'fill="{fill}"',
    ]
    if anchor != "start":
        attrs.append(f'text-anchor="{anchor}"')
    if opacity is not None:
        attrs.append(f'opacity="{opacity}"')
    if letter_spacing is not None:
        attrs.append(f'letter-spacing="{letter_spacing:.2f}"')
    return f"<text {' '.join(attrs)}>{esc(value)}</text>"


def circle(cx: float, cy: float, r: float, fill: str) -> str:
    return f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{fill}"/>'


def line(x1: float, y1: float, x2: float, y2: float, stroke: str, width: float = 1) -> str:
    return (
        f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
        f'stroke="{stroke}" stroke-width="{width}"/>'
    )


# A 24x24 icon set drawn with strokes, so the sheet needs no external assets.
ICONS: dict[str, list[str]] = {
    "menu": ["M4 7h16", "M4 12h16", "M4 17h16"],
    "back": ["M15 5l-7 7 7 7"],
    "plus": ["M12 5v14", "M5 12h14"],
    "send": ["M12 19V5", "M6 11l6-6 6 6"],
    "mic": ["M12 4a3 3 0 013 3v5a3 3 0 01-6 0V7a3 3 0 013-3z", "M5 11a7 7 0 0014 0", "M12 18v3"],
    "search": ["M11 4a7 7 0 100 14 7 7 0 000-14z", "M20 20l-3.5-3.5"],
    "chevron": ["M9 6l6 6-6 6"],
    "dots": ["M12 6h.01", "M12 12h.01", "M12 18h.01"],
    "terminal": ["M5 6h14v12H5z", "M9 10l2 2-2 2", "M13 14h3"],
    "globe": ["M12 3a9 9 0 100 18 9 9 0 000-18z", "M3 12h18", "M12 3c3 3.5 3 14 0 18"],
    "check": ["M5 13l4 4L19 7"],
    "lock": ["M7 11V8a5 5 0 0110 0v3", "M6 11h12v9H6z"],
    "spark": ["M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z"],
    "file": ["M7 4h7l4 4v12H7z", "M14 4v4h4"],
    "folder": ["M4 7h6l2 2h8v10H4z"],
    "clock": ["M12 4a8 8 0 100 16 8 8 0 000-16z", "M12 8v4l3 2"],
    "card": ["M3 7h18v10H3z", "M3 11h18"],
    "chart": ["M4 19V5", "M4 19h16", "M8 15v-4", "M12 15V8", "M16 15v-6"],
    "key": ["M14 8a4 4 0 10-4 4", "M11 12l-6 6v2h2l6-6"],
    "bell": ["M6 16V11a6 6 0 1112 0v5l2 2H4z", "M10 20a2 2 0 004 0"],
    "user": ["M12 4a4 4 0 100 8 4 4 0 000-8z", "M4 20a8 8 0 0116 0"],
    "trash": ["M5 7h14", "M9 7V5h6v2", "M7 7l1 13h8l1-13"],
    "pin": ["M12 3l2 6h6l-5 4 2 7-5-4-5 4 2-7-5-4h6z"],
    "share": ["M12 16V4", "M8 8l4-4 4 4", "M5 14v6h14v-6"],
    "sun": ["M12 8a4 4 0 100 8 4 4 0 000-8z", "M12 2v2", "M12 20v2", "M2 12h2", "M20 12h2"],
    "moon": ["M20 14A8 8 0 0110 4a8 8 0 1010 10z"],
    "stop": ["M7 7h10v10H7z"],
    "play": ["M8 5l11 7-11 7z"],
}


def icon(name: str, x: float, y: float, size: float, color: str, width: float = 1.6) -> str:
    """Draw a 24-unit icon scaled into `size`, with its box at (x, y)."""
    paths = ICONS.get(name, ICONS["spark"])
    scale = size / 24.0
    body = "".join(
        f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width / scale:.2f}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>'
        for d in paths
    )
    return f'<g transform="translate({x:.1f},{y:.1f}) scale({scale:.4f})">{body}</g>'


# --------------------------------------------------------------------------
# Screen frame
# --------------------------------------------------------------------------

W, H = 360, 780  # phone frame used for every screen
GAP = 48
COLS = 5


@dataclass
class Screen:
    """One screen's contents, in frame-local coordinates."""

    id: str
    title: str
    note: str
    parts: list[str] = field(default_factory=list)
    palette: Palette = LIGHT

    # -- building blocks ---------------------------------------------------

    def header(self, title: str, *, leading: str = "back", actions: list[str] | None = None) -> None:
        p = self.palette
        actions = actions or []
        y = 0
        self.parts.append(rect(0, 0, W, 56, p.bg))
        if leading == "menu":
            self.parts.append(icon("menu", 16, 16, 24, p.text))
        elif leading == "back":
            self.parts.append(icon("back", 16, 16, 24, p.text))
        self.parts.append(text(56 if leading != "none" else 16, 35, title, 17, p.text, weight=600))
        for i, name in enumerate(actions):
            self.parts.append(icon(name, W - 40 - i * 40, 16, 24, p.muted))
        self.parts.append(line(0, 56, W, 56, p.hairline))

    def section(self, y: float, label: str) -> float:
        p = self.palette
        self.parts.append(
            text(16, y, label.upper(), 10.5, p.faint, weight=600, letter_spacing=0.8)
        )
        return y + 18

    def row(
        self,
        y: float,
        title: str,
        *,
        value: str | None = None,
        icon_name: str | None = None,
        chevron: bool = True,
        switch: bool = False,
        switch_on: bool = False,
        danger: bool = False,
        subtitle: str | None = None,
        agent_dot: bool = False,
    ) -> float:
        p = self.palette
        h = 56 if subtitle is None else 68
        self.parts.append(rect(0, y, W, h, p.bg))
        x = 16
        if icon_name:
            self.parts.append(rect(x, y + 12, 32, 32, p.surface_alt, rx=8))
            self.parts.append(icon(icon_name, x + 6, y + 18, 20, p.muted))
            x += 44
        tx = x
        self.parts.append(
            text(tx, y + (28 if subtitle is None else 30), title, 15, p.agent if danger else p.text)
        )
        if subtitle:
            self.parts.append(text(tx, y + 46, subtitle, 11.5, p.faint))
        if agent_dot:
            self.parts.append(circle(tx - 10, y + 24, 3, p.agent))
        right = W - 16
        if switch:
            self.parts.append(
                rect(right - 40, y + 18, 40, 22, p.agent if switch_on else p.surface_alt, rx=11)
            )
            cx = right - 11 if switch_on else right - 29
            self.parts.append(circle(cx, y + 29, 9, p.bg if switch_on else p.muted))
        elif value:
            self.parts.append(text(right - (16 if chevron else 0), y + 32, value, 13, p.muted, anchor="end"))
        if chevron and not switch:
            self.parts.append(icon("chevron", right - 16, y + 18, 18, p.faint))
        self.parts.append(line(16 if icon_name else 16, y + h, W, y + h, p.hairline))
        return y + h

    def card(self, x: float, y: float, w: float, h: float, *, raised: bool = False) -> None:
        p = self.palette
        self.parts.append(
            rect(
                x,
                y,
                w,
                h,
                p.surface_alt if raised else p.surface,
                rx=14,
                stroke=p.hairline,
            )
        )

    def chip(self, x: float, y: float, label: str, *, selected: bool = False, w: float | None = None) -> float:
        p = self.palette
        width = w if w is not None else 12 + len(label) * 7.2
        self.parts.append(
            rect(
                x,
                y,
                width,
                32,
                p.text if selected else p.surface,
                rx=16,
                stroke=None if selected else p.hairline,
            )
        )
        self.parts.append(
            text(
                x + width / 2,
                y + 21,
                label,
                12.5,
                p.bg if selected else p.text,
                anchor="middle",
                weight=500,
            )
        )
        return x + width + 8

    def button(
        self,
        x: float,
        y: float,
        w: float,
        label: str,
        *,
        primary: bool = True,
        h: float = 48,
    ) -> None:
        p = self.palette
        self.parts.append(
            rect(x, y, w, h, p.text if primary else p.bg, rx=12, stroke=None if primary else p.hairline)
        )
        self.parts.append(
            text(
                x + w / 2,
                y + h / 2 + 5,
                label,
                14.5,
                p.bg if primary else p.text,
                anchor="middle",
                weight=600,
            )
        )

    def composer(self, y: float, hint: str = "Ask Ovid anything") -> None:
        p = self.palette
        self.parts.append(rect(0, y, W, 88, p.bg))
        self.parts.append(rect(12, y + 12, W - 24, 56, p.surface, rx=28, stroke=p.hairline))
        self.parts.append(icon("plus", 26, y + 28, 22, p.muted))
        self.parts.append(text(60, y + 45, hint, 14, p.faint))
        self.parts.append(icon("mic", W - 88, y + 28, 22, p.muted))
        self.parts.append(circle(W - 40, y + 40, 20, p.text))
        self.parts.append(icon("send", W - 51, y + 29, 22, p.bg))

    def agent_mark(self, cx: float, cy: float, r: float = 14) -> None:
        """The one place Signal Red is allowed: Ovid itself."""
        p = self.palette
        self.parts.append(circle(cx, cy, r, p.agent))
        self.parts.append(icon("spark", cx - r * 0.55, cy - r * 0.55, r * 1.1, p.on_agent, width=1.8))

    # -- output ------------------------------------------------------------

    def svg(self, x: float, y: float) -> str:
        p = self.palette
        body = "".join(self.parts)
        return (
            f'<g id="{esc(self.id)}" transform="translate({x:.1f},{y:.1f})">'
            f'<g id="{esc(self.id)}-label">'
            f'{text(0, -26, self.title, 15, p.text, weight=600)}'
            f'{text(0, -8, self.note, 11.5, p.muted)}'
            f"</g>"
            f'<g id="{esc(self.id)}-frame">'
            f"{rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline)}"
            f'<g clip-path="url(#clip-{esc(self.id)})">{body}</g>'
            f"{rect(0, 0, W, H, 'none', rx=20, stroke=p.hairline)}"
            f"</g></g>"
            f'<clipPath id="clip-{esc(self.id)}">'
            f'{rect(0, 0, W, H, "#fff", rx=20)}'
            f"</clipPath>"
        )


# --------------------------------------------------------------------------
# The screens
# --------------------------------------------------------------------------


def build_screens(p: Palette) -> list[Screen]:
    out: list[Screen] = []

    # 1. Chat (empty) ------------------------------------------------------
    s = Screen("chat", "Chat", "Empty state · one greeting, three starting points", palette=p)
    s.header("Ovid Si", leading="menu", actions=["terminal", "globe", "dots"])
    s.agent_mark(30, 96)
    s.parts.append(text(56, 101, "Ovid Si", 17, p.text, weight=600))
    s.parts.append(text(56, 120, "Auto", 12, p.muted))
    s.parts.append(text(W / 2, 260, "What should we build?", 22, p.text, anchor="middle", weight=600))
    yy = 300
    for label, ic in [
        ("Build a landing page", "globe"),
        ("Research a topic", "search"),
        ("Fix a repo bug", "terminal"),
    ]:
        s.parts.append(rect(24, yy, W - 48, 48, p.surface, rx=12, stroke=p.hairline))
        s.parts.append(icon(ic, 38, yy + 13, 22, p.muted))
        s.parts.append(text(70, yy + 29, label, 14, p.text))
        s.parts.append(icon("chevron", W - 46, yy + 15, 18, p.faint))
        yy += 58
    s.composer(H - 88)
    out.append(s)

    # 2. Live chat ---------------------------------------------------------
    s = Screen("live_chat", "Live chat", "Transcript · thinking, tool, artifact, queue", palette=p)
    s.header("Auth refresh", leading="menu", actions=["terminal", "globe", "dots"])
    s.parts.append(text(16, 78, "Working", 12, p.muted))
    s.parts.append(rect(W - 190, 66, 174, 20, p.surface_alt, rx=10))
    s.parts.append(text(W - 178, 80, "Ovid 2 Pro", 11, p.text))
    # user bubble
    s.parts.append(rect(96, 108, W - 112, 52, p.surface_alt, rx=16))
    s.parts.append(text(112, 130, "Refresh the auth token before", 13.5, p.text))
    s.parts.append(text(112, 148, "the session opens.", 13.5, p.text))
    # thinking row
    s.parts.append(text(16, 196, "Thought for 2 s", 13, p.muted))
    s.parts.append(icon("chevron", W - 34, 184, 18, p.faint))
    s.parts.append(line(16, 212, W - 16, 212, p.hairline))
    # tool row
    s.parts.append(icon("check", 16, 224, 18, p.text))
    s.parts.append(text(42, 238, "Search the workspace", 13.5, p.text))
    s.parts.append(icon("chevron", W - 34, 226, 18, p.faint))
    s.parts.append(line(16, 254, W - 16, 254, p.hairline))
    # assistant prose
    s.parts.append(text(16, 288, "I will refresh the token once and retry", 14, p.text))
    s.parts.append(text(16, 308, "before failing, so a cold start no", 14, p.text))
    s.parts.append(text(16, 328, "longer signs you out.", 14, p.text))
    # artifact card
    s.parts.append(rect(16, 352, W - 32, 60, p.surface, rx=12, stroke=p.hairline))
    s.parts.append(icon("file", 30, 370, 22, p.muted))
    s.parts.append(text(62, 380, "auth_service.dart", 13.5, p.text, weight=500))
    s.parts.append(text(62, 398, "lib/core · +14 −6", 11.5, p.faint))
    # queue dock
    s.parts.append(rect(16, 452, W - 32, 36, p.surface_alt, rx=10))
    s.parts.append(text(30, 475, "1 queued", 12.5, p.muted))
    s.parts.append(text(W - 30, 475, "Send now", 12.5, p.text, anchor="end", weight=500))
    s.composer(H - 88, "Ovid is working…")
    out.append(s)

    # 3. Sidebar -----------------------------------------------------------
    s = Screen("sidebar", "Sidebar", "Drawer · profile, new chat, search, projects, sessions", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.agent_mark(34, 40)
    s.parts.append(text(60, 36, "Aasheesh", 15, p.text, weight=600))
    s.parts.append(text(60, 54, "Ovid Plus", 11.5, p.muted))
    s.button(16, 80, W - 32, "New chat")
    s.parts.append(rect(16, 140, W - 32, 40, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(icon("search", 28, 149, 20, p.faint))
    s.parts.append(text(56, 165, "Search", 13.5, p.faint))
    y = 208
    y = s.section(y, "Projects")
    for name, count in [("Ovid Si", "3 chats"), ("Portfolio", "1 chat")]:
        s.parts.append(icon("folder", 16, y + 8, 20, p.muted))
        s.parts.append(text(46, y + 22, name, 14, p.text))
        s.parts.append(text(W - 16, y + 22, count, 11.5, p.faint, anchor="end"))
        y += 40
    y += 8
    y = s.section(y, "Sessions")
    for title, when, active in [
        ("Auth token refresh", "now", True),
        ("Landing page build", "2h", False),
        ("Billing audit", "Yesterday", False),
        ("Studio clone fix", "Mon", False),
    ]:
        if active:
            s.parts.append(rect(0, y, 2, 44, p.agent))
        s.parts.append(text(16, y + 20, title, 14, p.text))
        s.parts.append(text(16, y + 37, when, 11, p.faint))
        y += 48
    # footer
    fy = H - 150
    s.parts.append(line(0, fy, W, fy, p.hairline))
    for label, ic in [("Schedule", "clock"), ("Artifacts", "file"), ("Settings", "dots")]:
        s.parts.append(icon(ic, 16, fy + 18, 20, p.muted))
        s.parts.append(text(46, fy + 32, label, 14, p.text))
        fy += 44
    out.append(s)

    # 4. Settings hub ------------------------------------------------------
    s = Screen("settings", "Settings", "Hub · five sections, one search icon", palette=p)
    s.header("Settings", actions=["search"])
    y = 84
    y = s.section(y, "Account")
    y = s.row(y, "Aasheesh Singh", icon_name="user", value="Ovid Plus")
    y = s.row(y, "Plan & billing", icon_name="card")
    y = s.row(y, "Usage", icon_name="chart")
    y = s.row(y, "Credentials", icon_name="key")
    y += 12
    y = s.section(y, "Chat")
    y = s.row(y, "Appearance", icon_name="sun")
    y = s.row(y, "Memory", icon_name="spark")
    y += 12
    y = s.section(y, "Models")
    y = s.row(y, "Connectors", icon_name="plus")
    y = s.row(y, "Agent presets", icon_name="dots")
    out.append(s)

    # 5. Plan & billing ----------------------------------------------------
    s = Screen("plan_billing", "Plan & billing", "Four cards, USD/INR, current plan marked", palette=p)
    s.header("Plan & billing")
    x = 16
    for label in ["USD", "INR"]:
        sel = label == "USD"
        s.parts.append(rect(x, 72, 56, 30, p.text if sel else p.surface, rx=15, stroke=None if sel else p.hairline))
        s.parts.append(text(x + 28, 92, label, 12, p.bg if sel else p.text, anchor="middle", weight=500))
        x += 64
    yy = 120
    plans = [
        ("Ovid Free", "$0", "Auto model · 3 GB", False),
        ("Ovid Go", "$5", "Auto model · 5 GB", False),
        ("Ovid Plus", "$18", "Auto + manual · 15 GB", True),
        ("Ovid Pro", "$99", "Auto + manual · 75 GB", False),
    ]
    for name, price, line_txt, current in plans:
        s.card(16, yy, W - 32, 104, raised=current)
        if current:
            s.parts.append(rect(16, yy, 2, 104, p.agent))
        s.parts.append(text(34, yy + 28, name, 15, p.text, weight=600))
        s.parts.append(text(W - 34, yy + 30, price, 17, p.text, anchor="end", weight=600))
        s.parts.append(text(34, yy + 50, line_txt, 12, p.muted))
        s.button(34, yy + 62, W - 68, "Current plan" if current else "Choose", primary=not current, h=30)
        yy += 116
    out.append(s)

    # 6. Usage -------------------------------------------------------------
    s = Screen("usage", "Usage", "One hero number, one chart, one range switch", palette=p)
    s.header("Usage")
    s.parts.append(text(16, 108, "Tokens today", 12, p.muted))
    s.parts.append(text(16, 148, "18.4M", 34, p.text, weight=600))
    s.parts.append(text(16, 170, "of 50M · resets in 9 h", 12, p.faint))
    for i, label in enumerate(["7 days", "30 days"]):
        sel = i == 0
        x = W - 140 + i * 62
        s.parts.append(rect(x, 96, 56, 28, p.text if sel else p.surface, rx=14, stroke=None if sel else p.hairline))
        s.parts.append(text(x + 28, 115, label, 11.5, p.bg if sel else p.text, anchor="middle"))
    # bar chart
    base = 330
    heights = [0.35, 0.52, 0.44, 0.71, 0.62, 0.83, 0.58]
    bw = (W - 32) / len(heights)
    for i, hgt in enumerate(heights):
        bh = 150 * hgt
        s.parts.append(rect(16 + i * bw + 4, base - bh, bw - 8, bh, p.text, rx=4, opacity=0.85))
    s.parts.append(line(16, base, W - 16, base, p.hairline))
    out.append(s)

    # 7. Artifacts ---------------------------------------------------------
    s = Screen("artifacts", "Artifacts", "Card grid, filters as one chip row", palette=p)
    s.header("Artifacts", actions=["search"])
    x = 16
    for label, sel in [("All", True), ("Code", False), ("Image", False), ("Doc", False)]:
        x = s.chip(x, 72, label, selected=sel)
    yy = 124
    for row in range(3):
        for col in range(2):
            cx = 16 + col * ((W - 40) / 2 + 8)
            cw = (W - 40) / 2
            s.card(cx, yy, cw, 118)
            s.parts.append(icon("file", cx + 12, yy + 12, 20, p.muted))
            s.parts.append(text(cx + 12, yy + 56, ["auth_service.dart", "index.html", "plan.md", "logo.svg", "notes.txt", "run.log"][row * 2 + col], 12, p.text))
            s.parts.append(text(cx + 12, yy + 76, ["Code · 2h", "Page · 4h", "Doc · 1d", "Image · 2d", "Doc · 3d", "Log · 4d"][row * 2 + col], 10.5, p.faint))
        yy += 130
    out.append(s)

    # 8. Schedules ---------------------------------------------------------
    s = Screen("schedules", "Schedules", "Prompt, cadence, next run, one switch", palette=p)
    s.header("Schedules", actions=["plus"])
    yy = 80
    for prompt, cadence, on in [
        ("Check my Delhi train and find a cheap hotel", "Daily 09:00 · next in 3 h", True),
        ("Summarise the repo issues each morning", "Daily 08:00 · next in 2 h", True),
        ("Weekly usage report", "Weekly Mon · paused", False),
    ]:
        s.card(16, yy, W - 32, 96)
        s.parts.append(text(30, yy + 28, prompt[:34], 13.5, p.text))
        if len(prompt) > 34:
            s.parts.append(text(30, yy + 46, prompt[34:68], 13.5, p.text))
        s.parts.append(text(30, yy + 72, cadence, 11.5, p.muted))
        s.parts.append(rect(W - 56, yy + 38, 40, 22, p.agent if on else p.surface_alt, rx=11))
        s.parts.append(circle(W - 27 if on else W - 45, yy + 49, 9, p.bg if on else p.muted))
        yy += 108
    out.append(s)

    # 9. Studio workspace --------------------------------------------------
    s = Screen("studio_workspace", "Studio workspace", "Tree + editor, branch chip, one-click sync", palette=p)
    s.header("ovid-app", actions=["clock"])
    s.parts.append(rect(W - 116, 16, 72, 26, p.surface_alt, rx=13))
    s.parts.append(text(W - 102, 33, "main", 11.5, p.text))
    s.parts.append(line(120, 56, 120, H, p.hairline))
    ty = 76
    for name, depth, folder in [
        ("lib", 0, True), ("core", 1, True), ("auth.dart", 2, False),
        ("state.dart", 2, False), ("ui", 1, True), ("chat.dart", 2, False),
        ("main.dart", 0, False), ("pubspec.yaml", 0, False),
    ]:
        ix = 12 + depth * 14
        s.parts.append(icon("folder" if folder else "file", ix, ty, 16, p.muted))
        s.parts.append(text(ix + 22, ty + 12, name, 11.5, p.text))
        ty += 26
    # editor
    ex = 132
    s.parts.append(text(ex, 78, "auth.dart", 12.5, p.text, weight=500))
    s.parts.append(text(ex, 96, "Unsaved", 10, p.faint))
    for i in range(16):
        s.parts.append(text(ex, 124 + i * 18, f"{i + 1:>3}", 10, p.faint))
        w = [90, 120, 70, 140, 60, 110][i % 6]
        s.parts.append(rect(ex + 26, 116 + i * 18, w, 8, p.text, rx=2, opacity=0.75))
    out.append(s)

    # 10. Browser ----------------------------------------------------------
    s = Screen("browser", "Browser", "Agent-opened tab, live frame, take control", palette=p)
    s.header("", leading="back")
    s.parts.append(rect(48, 14, W - 96, 28, p.surface, rx=14, stroke=p.hairline))
    s.parts.append(icon("lock", 58, 20, 16, p.faint))
    s.parts.append(text(80, 33, "ovid.ai", 12, p.text))
    s.parts.append(icon("dots", W - 44, 18, 20, p.muted))
    s.parts.append(rect(16, 72, W - 32, 420, p.surface_alt, rx=12, stroke=p.hairline))
    # page inside
    s.parts.append(text(40, 116, "Ovid", 24, p.text, weight=700))
    s.parts.append(text(40, 140, "Your always-on agent", 13, p.muted))
    for i in range(3):
        s.parts.append(rect(40, 164 + i * 44, W - 120, 32, p.surface, rx=8, stroke=p.hairline))
        s.parts.append(text(52, 184 + i * 44, ["Build", "Research", "Ship"][i], 12, p.text))
    s.parts.append(rect(W / 2 - 70, 430, 140, 36, p.text, rx=18))
    s.parts.append(text(W / 2, 453, "Take control", 12.5, p.bg, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 520, "Live · 4 fps", 11, p.faint, anchor="middle"))
    out.append(s)

    # 11. Share sheet ------------------------------------------------------
    s = Screen("share_sheet", "Share sheet", "Collab vs Read only, then the link", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(W / 2 - 18, 12, 36, 4, p.hairline, rx=2))
    s.parts.append(text(16, 46, "Share chat", 17, p.text, weight=600))
    s.parts.append(icon("dots", W - 40, 30, 22, p.muted))
    yy = 76
    for title, line_txt, sel in [
        ("Collab", "Up to 50 people, one at a time", True),
        ("Read only", "Anyone with the link can fork", False),
    ]:
        s.card(16, yy, W - 32, 72, raised=sel)
        if sel:
            s.parts.append(rect(16, yy, 2, 72, p.agent))
        s.parts.append(text(34, yy + 28, title, 15, p.text, weight=600))
        s.parts.append(text(34, yy + 48, line_txt, 12, p.muted))
        if sel:
            s.parts.append(icon("check", W - 46, yy + 26, 20, p.text))
        yy += 84
    s.parts.append(rect(16, yy + 8, W - 32, 44, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(text(30, yy + 35, "ovid.ai/s/8f3k…", 12.5, p.text))
    s.parts.append(icon("share", W - 48, yy + 20, 20, p.muted))
    s.button(16, yy + 72, W - 32, "Copy link")
    s.parts.append(text(W / 2, yy + 148, "Stop sharing", 12.5, p.agent, anchor="middle"))
    out.append(s)

    # 12. Onboarding: welcome ---------------------------------------------
    s = Screen("welcome", "Welcome", "First run · one line, one action", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.agent_mark(W / 2, 260, 34)
    s.parts.append(text(W / 2, 340, "Ovid Si", 26, p.text, anchor="middle", weight=600))
    s.parts.append(text(W / 2, 368, "Ovid builds, ships and answers.", 13.5, p.muted, anchor="middle"))
    s.button(24, H - 96, W - 48, "Get started")
    s.parts.append(text(W / 2, H - 34, "STEP 1 OF 4", 10.5, p.faint, anchor="middle", letter_spacing=0.8))
    out.append(s)

    # 13. Paywall ----------------------------------------------------------
    s = Screen("paywall", "Paywall", "Four plans, three bullets each", palette=p)
    s.header("Choose a plan", leading="none", actions=["dots"])
    yy = 80
    for name, price, bullets, sel in [
        ("Ovid Free", "$0", ["Auto model", "3 GB storage", "50M tokens a day"], False),
        ("Ovid Plus", "$18", ["Auto + manual models", "15 GB storage", "Priority runs"], True),
    ]:
        s.card(16, yy, W - 32, 150, raised=sel)
        if sel:
            s.parts.append(rect(16, yy, 2, 150, p.agent))
        s.parts.append(text(34, yy + 30, name, 16, p.text, weight=600))
        s.parts.append(text(W - 34, yy + 32, price, 18, p.text, anchor="end", weight=600))
        for i, b in enumerate(bullets):
            s.parts.append(icon("check", 34, yy + 52 + i * 24, 16, p.muted))
            s.parts.append(text(58, yy + 65 + i * 24, b, 12.5, p.muted))
        yy += 162
    s.button(16, H - 130, W - 32, "Continue with Plus")
    s.parts.append(text(W / 2, H - 62, "Continue with Free", 13, p.muted, anchor="middle"))
    out.append(s)

    # 14. Model picker -----------------------------------------------------
    s = Screen("model_picker", "Model picker", "Auto first, manual rows gated by plan", palette=p)
    s.parts.append(rect(0, 0, W, H, p.bg, rx=20, stroke=p.hairline))
    s.parts.append(rect(W / 2 - 18, 12, 36, 4, p.hairline, rx=2))
    s.parts.append(text(16, 48, "Select model", 17, p.text, weight=600))
    s.parts.append(icon("dots", W - 40, 32, 22, p.muted))
    yy = 72
    s.card(16, yy, W - 32, 92, raised=True)
    s.parts.append(rect(16, yy, 2, 92, p.agent))
    s.agent_mark(46, yy + 34, 14)
    s.parts.append(text(70, yy + 30, "Auto", 15, p.text, weight=600))
    s.parts.append(text(70, yy + 50, "Picks the fastest model per request", 11.5, p.muted))
    s.parts.append(icon("check", W - 46, yy + 26, 20, p.text))
    yy += 104
    for name, meta, locked in [
        ("Ovid 2 Flash", "Fast · 1 credit", False),
        ("Ovid 2 Pro", "Deeper · 4 credits", True),
    ]:
        s.card(16, yy, W - 32, 72)
        s.parts.append(icon("lock" if locked else "spark", 34, yy + 26, 20, p.faint if locked else p.text))
        s.parts.append(text(64, yy + 32, name, 14, p.text if not locked else p.muted, weight=500))
        s.parts.append(text(64, yy + 52, meta, 11.5, p.faint))
        if locked:
            s.parts.append(rect(W - 96, yy + 24, 62, 24, p.surface_alt, rx=12))
            s.parts.append(text(W - 65, yy + 40, "Plus", 10.5, p.faint, anchor="middle"))
        yy += 84
    out.append(s)

    # 15. Artifact detail --------------------------------------------------
    s = Screen("artifact_detail", "Artifact detail", "Preview fills, three rows, one action", palette=p)
    s.header("auth_service.dart", actions=["dots"])
    s.parts.append(rect(16, 72, W - 32, 320, p.surface, rx=12, stroke=p.hairline))
    for i in range(14):
        s.parts.append(text(32, 100 + i * 20, f"{i + 1:>3}", 10, p.faint))
        s.parts.append(rect(58, 92 + i * 20, [120, 80, 150, 60, 100][i % 5], 8, p.text, rx=2, opacity=0.72))
    yy = 412
    for k, v in [("Type", "Dart source"), ("Size", "4.2 KB"), ("Created", "2 hours ago")]:
        s.parts.append(text(16, yy, k, 12, p.faint))
        s.parts.append(text(W - 16, yy, v, 12.5, p.text, anchor="end"))
        yy += 28
    s.button(16, yy + 12, W - 32, "Open")
    out.append(s)

    # 16. Connectors -------------------------------------------------------
    s = Screen("connectors", "Connectors", "Flat rows, one filter menu, plan cap", palette=p)
    s.header("Connectors", actions=["plus"])
    s.parts.append(rect(16, 72, W - 32, 40, p.surface, rx=10, stroke=p.hairline))
    s.parts.append(icon("search", 28, 81, 20, p.faint))
    s.parts.append(text(56, 97, "Search connectors", 13, p.faint))
    yy = 128
    for name, status, on in [
        ("GitHub", "Connected", True),
        ("Google Drive", "Connected", True),
        ("Notion", "Paused", False),
        ("Context7", "Not connected", False),
    ]:
        s.parts.append(icon("plus", 16, yy + 14, 22, p.muted))
        s.parts.append(text(52, yy + 22, name, 14, p.text))
        s.parts.append(text(52, yy + 40, status, 11.5, p.faint))
        s.parts.append(rect(W - 56, yy + 18, 40, 22, p.text if on else p.surface_alt, rx=11))
        s.parts.append(circle(W - 27 if on else W - 45, yy + 29, 9, p.bg if on else p.muted))
        s.parts.append(line(16, yy + 56, W, yy + 56, p.hairline))
        yy += 58
    out.append(s)

    return out


# --------------------------------------------------------------------------
# Sheet
# --------------------------------------------------------------------------


def build_sheet(p: Palette, dark: bool) -> str:
    screens = build_screens(p)
    cols = COLS
    rows = math.ceil(len(screens) / cols)
    cell_w = W + GAP
    cell_h = H + GAP + 24
    width = cols * cell_w + GAP
    height = rows * cell_h + GAP + 90

    title = "Ovid Si — dark" if dark else "Ovid Si — light"
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">',
        f'<rect width="{width}" height="{height}" fill="{p.bg}"/>',
        text(GAP, 52, title, 30, p.text, weight=700),
        text(
            GAP,
            76,
            "Paper #F4F1EA · Ink #1B1B1B · Signal Red #E5484D (agent only) · Stone #8A867D",
            12.5,
            p.muted,
        ),
    ]
    for i, screen in enumerate(screens):
        col = i % cols
        row = i // cols
        x = GAP + col * cell_w
        y = 120 + row * cell_h
        parts.append(screen.svg(x, y))
    parts.append("</svg>")
    return "\n".join(parts)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dark", action="store_true", help="emit the dark sheet")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("build/figma/ovid-si-screens.svg"),
    )
    args = parser.parse_args()

    sheet = build_sheet(DARK if args.dark else LIGHT, args.dark)
    out = args.out if args.dark is False else args.out.with_name("ovid-si-screens-dark.svg")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(sheet, encoding="utf-8")
    count = len(build_screens(DARK if args.dark else LIGHT))
    print(f"wrote {out} ({count} screens, {len(sheet) // 1024} KB)")


if __name__ == "__main__":
    main()
